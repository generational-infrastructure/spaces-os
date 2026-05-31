package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"
)

const defaultSocket = "/run/spaces-skill-config-default.sock"

func main() {
	socketPath := os.Getenv("SKILL_CONFIG_SOCKET")
	if socketPath == "" {
		socketPath = defaultSocket
	}

	// Remove a stale socket from a prior run before binding.
	_ = os.Remove(socketPath)

	l, err := net.Listen("unix", socketPath)
	if err != nil {
		log.Fatalf("listen %s: %v", socketPath, err)
	}
	defer l.Close()

	// Mode 0666: the parent dir's permissions (0777, root-owned tmpfiles
	// rule from spaces/pi-chat module) are the actual access boundary. The trust
	// model is "anything that can act as the user or root", which is the
	// same as for secrets.toml itself.
	if err := os.Chmod(socketPath, 0o666); err != nil {
		log.Fatalf("chmod %s: %v", socketPath, err)
	}

	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigs
		log.Printf("shutting down")
		l.Close()
	}()

	instance := os.Getenv("SPACES_PI_CHAT_INSTANCE")
	if instance == "" {
		instance = "unknown"
	}
	srv := NewServer(instance)
	log.Printf("listening on %s (instance=%s)", socketPath, instance)

	for {
		conn, err := l.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			log.Printf("accept: %v", err)
			continue
		}
		go handleConn(srv, conn)
	}
}

func handleConn(srv *Server, conn net.Conn) {
	defer conn.Close()

	dec := json.NewDecoder(conn)
	enc := json.NewEncoder(conn)

	// Probe the first message's "op" to decide which role we're talking to.
	// We re-decode into the concrete type after dispatching.
	var raw json.RawMessage
	if err := dec.Decode(&raw); err != nil {
		if !errors.Is(err, io.EOF) {
			log.Printf("decode: %v", err)
		}
		return
	}
	var probe struct {
		Op string `json:"op"`
	}
	if err := json.Unmarshal(raw, &probe); err != nil {
		_ = enc.Encode(Ack{Op: "error", Error: "malformed message"})
		return
	}

	switch probe.Op {
	case "request":
		var req Request
		if err := json.Unmarshal(raw, &req); err != nil {
			_ = enc.Encode(Ack{Op: "error", Error: "malformed request"})
			return
		}
		handleRequest(srv, conn, enc, req)
	case "subscribe":
		handleSubscribe(srv, conn, enc)
	case "list":
		_ = enc.Encode(ListReply{Requests: srv.list()})
	case "submit":
		var sub SubmitReq
		if err := json.Unmarshal(raw, &sub); err != nil {
			_ = enc.Encode(Ack{Op: "error", Error: "malformed submit"})
			return
		}
		if err := srv.submit(sub.RequestID, sub.Value); err != nil {
			_ = enc.Encode(Ack{Op: "error", Error: err.Error()})
			return
		}
		_ = enc.Encode(Ack{Op: "ok"})
	case "cancel":
		var c CancelReq
		if err := json.Unmarshal(raw, &c); err != nil {
			_ = enc.Encode(Ack{Op: "error", Error: "malformed cancel"})
			return
		}
		if err := srv.cancel(c.RequestID); err != nil {
			_ = enc.Encode(Ack{Op: "error", Error: err.Error()})
			return
		}
		_ = enc.Encode(Ack{Op: "ok"})
	default:
		_ = enc.Encode(Ack{Op: "error", Error: "unknown op: " + probe.Op})
	}
}

// handleRequest registers a pending request, writes the Registered ack, and
// blocks until a terminal Reply or the CLI's connection drops. On exit it
// always unregisters and (if the connection is still open) writes the
// terminal Reply to the CLI.
func handleRequest(srv *Server, conn net.Conn, enc *json.Encoder, req Request) {
	id, p := srv.register(req)
	defer srv.unregister(id)

	if err := enc.Encode(Registered{Op: "registered", RequestID: id}); err != nil {
		// CLI gave up before we could ack — nothing to do.
		return
	}

	// Watch for CLI disconnect so we can stop waiting if the agent goes away.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go watchPeerClose(conn, cancel)

	rep := p.waitReply(ctx, req.TimeoutSecs)
	_ = enc.Encode(rep) // best-effort: if peer is gone, this fails harmlessly
}

// watchPeerClose reads from conn until EOF/error, then triggers cancel.
// CLIs don't send anything else after Request, so any read activity means
// the connection has closed.
func watchPeerClose(conn net.Conn, cancel context.CancelFunc) {
	var buf [1]byte
	for {
		_, err := conn.Read(buf[:])
		if err != nil {
			cancel()
			return
		}
	}
}

// handleSubscribe sends the initial snapshot, then forwards every event from
// the subscriber's channel to the connection until either the peer
// disconnects or the daemon shuts down.
func handleSubscribe(srv *Server, conn net.Conn, enc *json.Encoder) {
	sub, snap := srv.addSubscriber()
	defer srv.removeSubscriber(sub)

	if err := enc.Encode(snap); err != nil {
		return
	}

	// Detect peer disconnect concurrently — writes alone won't notice
	// EOF, only reads do. Subscribers are not expected to send anything
	// after the initial subscribe.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go watchPeerClose(conn, cancel)

	for {
		select {
		case ev, ok := <-sub.ch:
			if !ok {
				return
			}
			if err := enc.Encode(ev); err != nil {
				return
			}
		case <-ctx.Done():
			return
		}
	}
}

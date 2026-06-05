// app-coordinator: per-user daemon mediating manifest-driven app
// launches on behalf of sandboxed callers (the spaces agent + any
// other apps holding the `wm.spawn-named-tasks` permission).
//
// Why a daemon? The sandboxed agent must not have the WM IPC socket
// or a shell — it would otherwise be able to spawn arbitrary code as
// the user. Instead, it gets a Unix socket to this coordinator, which
// only spawns apps that appear in the at-rest manifest the Nix module
// renders. The set of spawnable apps is a closed set defined by the
// operator at system-build time.
//
// Perimeter: the socket lives at $XDG_RUNTIME_DIR/spaces-app-coordinator.sock
// with mode 0600. The sandboxed app gets it only because its
// per-app launcher bind-mounts it in when `wm.spawn-named-tasks`
// is granted. The coordinator itself does no SO_PEERCRED check
// because every caller reaching the socket has already passed
// through the launcher's permission gate.
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

const (
	defaultManifestPath = "/etc/spaces/app-coordinator/manifest.json"
	socketEnv           = "APP_COORDINATOR_SOCKET"
	manifestEnv         = "APP_COORDINATOR_MANIFEST"
)

func main() {
	// journald already timestamps every message; suppress Go's own
	// date/time prefix so AUDIT lines start with the literal token
	// "AUDIT " (makes `journalctl ... | grep '^AUDIT '` work as
	// documented).
	log.SetFlags(0)

	socketPath := os.Getenv(socketEnv)
	if socketPath == "" {
		runtimeDir := os.Getenv("XDG_RUNTIME_DIR")
		if runtimeDir == "" {
			log.Fatalf("XDG_RUNTIME_DIR not set; pass %s explicitly", socketEnv)
		}
		socketPath = runtimeDir + "/spaces-app-coordinator.sock"
	}
	manifestPath := os.Getenv(manifestEnv)
	if manifestPath == "" {
		manifestPath = defaultManifestPath
	}

	srv, err := NewServer(manifestPath)
	if err != nil {
		log.Fatalf("load manifest: %v", err)
	}

	_ = os.Remove(socketPath)
	l, err := net.Listen("unix", socketPath)
	if err != nil {
		log.Fatalf("listen %s: %v", socketPath, err)
	}
	defer l.Close()
	// 0600: only the owning user can reach the socket. The launcher
	// then narrows further by only bind-mounting it into sandboxes
	// whose manifest grants `wm.spawn-named-tasks`.
	if err := os.Chmod(socketPath, 0o600); err != nil {
		log.Fatalf("chmod: %v", err)
	}

	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigs
		log.Print("shutting down")
		l.Close()
	}()

	log.Printf("listening on %s (apps=%d)", socketPath, len(srv.manifest.Apps))

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

	var req Request
	if err := dec.Decode(&req); err != nil {
		if !errors.Is(err, io.EOF) {
			_ = enc.Encode(Reply{Op: "error", Error: "malformed request"})
		}
		return
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	caller := callerAppID(conn)
	rep := srv.handle(ctx, req, caller)
	_ = enc.Encode(rep)
}

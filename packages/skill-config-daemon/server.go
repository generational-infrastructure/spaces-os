package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"sync"
	"time"
)

const defaultTimeout = 120 * time.Second

type pending struct {
	meta  Request
	reply chan Reply // capacity 1; written exactly once
}

// Server holds the in-memory pending-request map.
// All public methods are safe for concurrent use.
type Server struct {
	mu      sync.Mutex
	pending map[string]*pending
}

func NewServer() *Server {
	return &Server{pending: make(map[string]*pending)}
}

// register creates a pending entry and returns its ID plus the reply channel.
// Caller is responsible for waiting on the channel and calling unregister.
func (s *Server) register(req Request) (string, *pending) {
	id := newID()
	p := &pending{meta: req, reply: make(chan Reply, 1)}
	s.mu.Lock()
	s.pending[id] = p
	s.mu.Unlock()
	return id, p
}

func (s *Server) unregister(id string) {
	s.mu.Lock()
	delete(s.pending, id)
	s.mu.Unlock()
}

// list returns a snapshot of all pending requests. Order is unspecified.
func (s *Server) list() []PendingEntry {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]PendingEntry, 0, len(s.pending))
	for id, p := range s.pending {
		out = append(out, PendingEntry{
			RequestID:   id,
			Skill:       p.meta.Skill,
			Profile:     p.meta.Profile,
			Field:       p.meta.Field,
			Description: p.meta.Description,
			Secret:      p.meta.Secret,
		})
	}
	return out
}

// submit looks up the pending request and sends the value to its reply
// channel. Returns an error if the request_id is unknown or the channel
// has already been written.
func (s *Server) submit(id, value string) error {
	s.mu.Lock()
	p, ok := s.pending[id]
	s.mu.Unlock()
	if !ok {
		return errors.New("unknown request_id")
	}
	select {
	case p.reply <- Reply{Op: "submitted", Value: value}:
		return nil
	default:
		return errors.New("request already completed")
	}
}

// cancel signals dismissal to the waiting CLI.
func (s *Server) cancel(id string) error {
	s.mu.Lock()
	p, ok := s.pending[id]
	s.mu.Unlock()
	if !ok {
		return errors.New("unknown request_id")
	}
	select {
	case p.reply <- Reply{Op: "cancelled"}:
		return nil
	default:
		return errors.New("request already completed")
	}
}

// waitReply blocks until the request receives a Reply, the timeout fires,
// or the CLI's context is cancelled (peer disconnect).
func (p *pending) waitReply(ctx context.Context, timeoutSecs int) Reply {
	timeout := defaultTimeout
	if timeoutSecs > 0 {
		timeout = time.Duration(timeoutSecs) * time.Second
	}
	t := time.NewTimer(timeout)
	defer t.Stop()
	select {
	case rep := <-p.reply:
		return rep
	case <-t.C:
		return Reply{Op: "timeout"}
	case <-ctx.Done():
		// CLI disconnected. The reply we return won't reach anyone;
		// it's purely a sentinel for the handler to clean up.
		return Reply{Op: "cancelled"}
	}
}

func newID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	return fmt.Sprintf(
		"%s-%s-%s-%s-%s",
		hex.EncodeToString(b[0:4]),
		hex.EncodeToString(b[4:6]),
		hex.EncodeToString(b[6:8]),
		hex.EncodeToString(b[8:10]),
		hex.EncodeToString(b[10:16]),
	)
}

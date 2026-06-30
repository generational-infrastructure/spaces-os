package main

import (
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
)

// Defaults (docs/agent-integrations-poc-plan.md step 2). The broker runs as a
// --user service; systemd's StateDirectory= and %t supply the per-user paths,
// so these fallbacks only matter when run by hand.
const (
	defaultDefsDir = "/etc/spaces-integrations"
	// TPM2 enforced AND user-scoped: host+tpm2 (not pure tpm2, which is rejected
	// in --uid= mode), never "auto" (which silently drops to host-key only).
	defaultCredsEncrypt = "systemd-creds encrypt --user --uid=self --with-key=host+tpm2"
	defaultSystemctl    = "systemctl --user"
)

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// defaultSocket: %t/spaces-integrations.sock (the user runtime dir is 0700, so
// the socket is unreachable by other users even before the SO_PEERCRED check).
func defaultSocket() string {
	if rt := os.Getenv("XDG_RUNTIME_DIR"); rt != "" {
		return filepath.Join(rt, "spaces-integrations.sock")
	}
	return "/run/spaces-integrations.sock"
}

// defaultStateDir: $STATE_DIRECTORY (set by StateDirectory=spaces-integrationd)
// resolves to ~/.local/state/spaces-integrationd, matching the integration
// units' LoadCredentialEncrypted=...:%S/spaces-integrationd/<name>/<secret>.
func defaultStateDir() string {
	if sd := os.Getenv("STATE_DIRECTORY"); sd != "" {
		return strings.Split(sd, ":")[0]
	}
	if xs := os.Getenv("XDG_STATE_HOME"); xs != "" {
		return filepath.Join(xs, "spaces-integrationd")
	}
	if h := os.Getenv("HOME"); h != "" {
		return filepath.Join(h, ".local/state/spaces-integrationd")
	}
	return "/var/lib/spaces-integrationd"
}

func main() {
	socketPath := envOr("SPACES_INTEGRATIOND_SOCKET", defaultSocket())
	defsDir := envOr("SPACES_INTEGRATIOND_DEFS_DIR", defaultDefsDir)
	stateDir := envOr("SPACES_INTEGRATIOND_STATE_DIR", defaultStateDir())
	credsEncrypt := strings.Fields(envOr("SPACES_INTEGRATIOND_CREDS_ENCRYPT", defaultCredsEncrypt))
	systemctl := strings.Fields(envOr("SPACES_INTEGRATIOND_SYSTEMCTL", defaultSystemctl))

	// Remove a stale socket from a prior run before binding.
	_ = os.Remove(socketPath)

	l, err := net.Listen("unix", socketPath)
	if err != nil {
		log.Fatalf("listen %s: %v", socketPath, err)
	}
	defer l.Close()

	// 0600: only the owning user. Authorisation is per-connection via
	// SO_PEERCRED (uid == self) regardless.
	if err := os.Chmod(socketPath, 0o600); err != nil {
		log.Fatalf("chmod %s: %v", socketPath, err)
	}

	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigs
		log.Printf("shutting down")
		l.Close()
	}()

	srv := NewServer(defsDir, stateDir, credsEncrypt, systemctl)
	log.Printf("listening on %s (defs=%s state=%s)", socketPath, defsDir, stateDir)
	srv.Serve(l)
}

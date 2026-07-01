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
// --user service; systemd's StateDirectory=/RuntimeDirectory= and %t supply the
// per-user paths, so these fallbacks only matter when run by hand.
const (
	defaultDefsDir = "/etc/spaces-integrations"
	// TPM2 enforced AND user-scoped: host+tpm2 (not pure tpm2, which is rejected
	// in --uid= mode), never "auto" (which silently drops to host-key only).
	defaultCredsEncrypt = "systemd-creds encrypt --user --uid=self --with-key=host+tpm2"
	// Decrypt mirrors the encrypt scope; the broker unseals its own secrets blob
	// to a tmpfs working copy to edit a profile row, then re-seals.
	defaultCredsDecrypt = "systemd-creds decrypt --user --uid=self"
	defaultSystemctl    = "systemctl --user"
	// The store engine: skill-config reads/writes the config.toml + secrets.toml
	// blobs (one store implementation, shared with the agent-facing skills).
	defaultSkillConfig = "skill-config"
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
// units' LoadCredential[Encrypted]=...:%S/spaces-integrationd/<name>/<blob>.
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

// defaultRuntimeDir: $RUNTIME_DIRECTORY (RuntimeDirectory=spaces-integrationd),
// a tmpfs. Transient unsealed secrets live here for the duration of one edit.
func defaultRuntimeDir() string {
	if rd := os.Getenv("RUNTIME_DIRECTORY"); rd != "" {
		return strings.Split(rd, ":")[0]
	}
	if rt := os.Getenv("XDG_RUNTIME_DIR"); rt != "" {
		return rt
	}
	return os.TempDir()
}

func main() {
	socketPath := envOr("SPACES_INTEGRATIOND_SOCKET", defaultSocket())
	defsDir := envOr("SPACES_INTEGRATIOND_DEFS_DIR", defaultDefsDir)
	stateDir := envOr("SPACES_INTEGRATIOND_STATE_DIR", defaultStateDir())
	runtimeDir := envOr("SPACES_INTEGRATIOND_RUNTIME_DIR", defaultRuntimeDir())
	credsEncrypt := strings.Fields(envOr("SPACES_INTEGRATIOND_CREDS_ENCRYPT", defaultCredsEncrypt))
	credsDecrypt := strings.Fields(envOr("SPACES_INTEGRATIOND_CREDS_DECRYPT", defaultCredsDecrypt))
	systemctl := strings.Fields(envOr("SPACES_INTEGRATIOND_SYSTEMCTL", defaultSystemctl))
	skillConfig := strings.Fields(envOr("SPACES_INTEGRATIOND_SKILL_CONFIG", defaultSkillConfig))

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

	srv := NewServer(defsDir, stateDir, runtimeDir, credsEncrypt, credsDecrypt, systemctl, skillConfig)
	log.Printf("listening on %s (defs=%s state=%s)", socketPath, defsDir, stateDir)
	srv.Serve(l)
}

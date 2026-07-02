package main

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// testEnv wires a real unix-socket server against temp dirs and stub commands.
// Connections come from this test process, so SO_PEERCRED resolves to the
// current uid == the broker's own uid: checkPeer passes.
//
// The store engine is the REAL skill-config (found on PATH via the build's
// nativeCheckInputs) — mocking it would have hidden broker↔skill-config
// argument-vector bugs, exactly the class the POC's VM check surfaced. Only
// systemd-creds (needs a TPM) and systemctl are stubbed: encrypt prepends an
// "ENC" header line, decrypt strips it, so seal/unseal round-trips faithfully
// while a sealed blob is still observably not plaintext.
type testEnv struct {
	t         *testing.T
	sock      string
	defsDir   string
	stateDir  string
	sysctlLog string
}

const githubDef = `{
  "name": "github",
  "description": "GitHub",
  "multiProfile": true,
  "network": true,
  "connectPorts": [443],
  "autoRun": ["get_repo"],
  "config": {
    "owner": { "description": "Default owner/org", "required": false }
  },
  "secrets": {
    "token": { "description": "GitHub personal access token", "required": true }
  }
}`

func writeScript(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	return string(rune('0' + n))
}

// newTestEnv starts a server on a temp socket. systemctlExit non-zero makes the
// systemctl stub fail (after recording its argv).
func newTestEnv(t *testing.T, systemctlExit int) *testEnv {
	t.Helper()
	dir := t.TempDir()
	defsDir := filepath.Join(dir, "defs")
	stateDir := filepath.Join(dir, "state")
	runtimeDir := filepath.Join(dir, "run")
	for _, d := range []string{defsDir, stateDir, runtimeDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(defsDir, "github.json"), []byte(githubDef), 0o644); err != nil {
		t.Fatal(err)
	}
	// Stub encryptor/decryptor: argv is --name=secrets <in> <out>. encrypt
	// prepends an "ENC" header line; decrypt drops the first line — a faithful
	// round-trip whose sealed form is observably not the plaintext.
	credsEnc := filepath.Join(dir, "creds-encrypt")
	writeScript(t, credsEnc, "#!/bin/sh\n{ echo ENC; cat \"$2\"; } > \"$3\"\n")
	credsDec := filepath.Join(dir, "creds-decrypt")
	writeScript(t, credsDec, "#!/bin/sh\ntail -n +2 \"$2\" > \"$3\"\n")
	sysctlLog := filepath.Join(dir, "systemctl.log")
	sysctl := filepath.Join(dir, "systemctl")
	writeScript(t, sysctl,
		"#!/bin/sh\necho \"$@\" >> "+sysctlLog+"\nexit "+itoa(systemctlExit)+"\n")
	sock := filepath.Join(dir, "b.sock")
	l, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	srv := NewServer(defsDir, stateDir, runtimeDir,
		[]string{credsEnc}, []string{credsDec}, []string{sysctl}, []string{"skill-config"})
	go srv.Serve(l)
	return &testEnv{t: t, sock: sock, defsDir: defsDir, stateDir: stateDir, sysctlLog: sysctlLog}
}

// roundtripRaw sends one raw line and returns the single reply line parsed into
// a generic map.
func (e *testEnv) roundtripRaw(line string) map[string]any {
	e.t.Helper()
	conn, err := net.Dial("unix", e.sock)
	if err != nil {
		e.t.Fatal(err)
	}
	defer conn.Close()
	if _, err := conn.Write([]byte(line + "\n")); err != nil {
		e.t.Fatal(err)
	}
	reply, err := bufio.NewReader(conn).ReadBytes('\n')
	if err != nil {
		e.t.Fatalf("read reply: %v", err)
	}
	var m map[string]any
	if err := json.Unmarshal(reply, &m); err != nil {
		e.t.Fatalf("parse reply %q: %v", reply, err)
	}
	return m
}

func (e *testEnv) roundtrip(req Request) map[string]any {
	e.t.Helper()
	data, err := json.Marshal(req)
	if err != nil {
		e.t.Fatal(err)
	}
	return e.roundtripRaw(string(data))
}

func (e *testEnv) wantOK(m map[string]any) {
	e.t.Helper()
	if m["op"] != "ok" {
		e.t.Fatalf("want op=ok, got %v", m)
	}
}

func (e *testEnv) wantError(m map[string]any, substr string) {
	e.t.Helper()
	if m["op"] != "error" {
		e.t.Fatalf("want op=error, got %v", m)
	}
	if msg, _ := m["error"].(string); !strings.Contains(msg, substr) {
		e.t.Fatalf("want error containing %q, got %q", substr, msg)
	}
}

func (e *testEnv) enabledState() EnabledState {
	e.t.Helper()
	var st EnabledState
	data, err := os.ReadFile(filepath.Join(e.stateDir, "enabled.json"))
	if err != nil {
		e.t.Fatal(err)
	}
	if err := json.Unmarshal(data, &st); err != nil {
		e.t.Fatal(err)
	}
	return st
}

func (e *testEnv) systemctlCalls() []string {
	e.t.Helper()
	data, err := os.ReadFile(e.sysctlLog)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		e.t.Fatal(err)
	}
	return strings.Split(strings.TrimSpace(string(data)), "\n")
}

func (e *testEnv) setField(integration, profile, field, value string) {
	e.t.Helper()
	e.wantOK(e.roundtrip(Request{Op: "set-field", Integration: integration, Profile: profile, Field: field, Value: value}))
}

// githubInfo returns the single github IntegrationInfo from a `list` reply.
func (e *testEnv) githubInfo() map[string]any {
	e.t.Helper()
	m := e.roundtrip(Request{Op: "list"})
	e.wantOK(m)
	ints, ok := m["integrations"].([]any)
	if !ok || len(ints) != 1 {
		e.t.Fatalf("want 1 integration, got %v", m["integrations"])
	}
	return ints[0].(map[string]any)
}

func profileByName(gh map[string]any, name string) map[string]any {
	profiles, _ := gh["profiles"].([]any)
	for _, p := range profiles {
		pm := p.(map[string]any)
		if pm["name"] == name {
			return pm
		}
	}
	return nil
}

func TestPeerAllowedRejectsOtherUid(t *testing.T) {
	if !peerAllowed(1000, 1000) {
		t.Fatal("same uid must be allowed")
	}
	if peerAllowed(1001, 1000) {
		t.Fatal("a different uid must be rejected")
	}
}

func TestListEmptyState(t *testing.T) {
	e := newTestEnv(t, 0)
	gh := e.githubInfo()
	if gh["name"] != "github" || gh["description"] != "GitHub" || gh["enabled"] != false {
		t.Fatalf("unexpected integration: %v", gh)
	}
	if gh["multiProfile"] != true {
		t.Fatalf("want multiProfile=true, got %v", gh["multiProfile"])
	}
	if secrets := gh["secrets"].([]any); len(secrets) != 1 || secrets[0].(map[string]any)["name"] != "token" {
		t.Fatalf("want [token] secret schema, got %v", secrets)
	}
	if cfg := gh["config"].([]any); len(cfg) != 1 || cfg[0].(map[string]any)["name"] != "owner" {
		t.Fatalf("want [owner] config schema, got %v", cfg)
	}
	if profs := gh["profiles"].([]any); len(profs) != 0 {
		t.Fatalf("want no profiles on empty state, got %v", profs)
	}
}

func TestSetFieldStoresConfigPlainAndSecretSealed(t *testing.T) {
	e := newTestEnv(t, 0)
	e.setField("github", "work", "owner", "acme")
	e.setField("github", "work", "token", "hunter2")

	// Config is plaintext on disk.
	cfg, err := os.ReadFile(filepath.Join(e.stateDir, "github", "config.toml"))
	if err != nil || !strings.Contains(string(cfg), "acme") {
		t.Fatalf("config.toml missing owner value: %q %v", cfg, err)
	}
	// Secrets are sealed: the blob is not raw plaintext (carries the ENC header).
	sealed, err := os.ReadFile(filepath.Join(e.stateDir, "github", "secrets"))
	if err != nil || !strings.HasPrefix(string(sealed), "ENC\n") {
		t.Fatalf("secrets blob not sealed: %q %v", sealed, err)
	}
	// config.toml must never carry the secret.
	if strings.Contains(string(cfg), "hunter2") {
		t.Fatal("secret leaked into config.toml")
	}

	// list reflects the profile: owner value visible, token set (never value).
	p := profileByName(e.githubInfo(), "work")
	if p == nil {
		t.Fatal("profile 'work' not listed")
	}
	if got := p["config"].(map[string]any)["owner"]; got != "acme" {
		t.Fatalf("want owner=acme, got %v", got)
	}
	if p["secrets"].(map[string]any)["token"] != true {
		t.Fatalf("want token set, got %v", p["secrets"])
	}
	if p["complete"] != true {
		t.Fatalf("profile with required token set must be complete, got %v", p)
	}
}

func TestMultiProfileIsolation(t *testing.T) {
	e := newTestEnv(t, 0)
	e.setField("github", "work", "token", "w-tok")
	e.setField("github", "personal", "token", "p-tok")

	gh := e.githubInfo()
	if profileByName(gh, "work") == nil || profileByName(gh, "personal") == nil {
		t.Fatalf("both profiles must list, got %v", gh["profiles"])
	}
	// Decrypt the sealed blob (via the stub) and confirm both rows coexist.
	sealed, _ := os.ReadFile(filepath.Join(e.stateDir, "github", "secrets"))
	body := strings.SplitN(string(sealed), "\n", 2)[1] // drop the ENC header
	if !strings.Contains(body, "w-tok") || !strings.Contains(body, "p-tok") {
		t.Fatalf("both profile secrets must persist, got %q", body)
	}
}

func TestSetFieldUnknown(t *testing.T) {
	e := newTestEnv(t, 0)
	e.wantError(e.roundtrip(Request{Op: "set-field", Integration: "nope", Profile: "work", Field: "token", Value: "x"}), "unknown integration")
	e.wantError(e.roundtrip(Request{Op: "set-field", Integration: "github", Profile: "work", Field: "nope", Value: "x"}), "unknown field")
}

func TestEnableRequiresCompleteProfile(t *testing.T) {
	e := newTestEnv(t, 0)
	e.wantError(e.roundtrip(Request{Op: "enable", Integration: "github"}), "no complete profile")
	if calls := e.systemctlCalls(); calls != nil {
		t.Fatalf("systemctl must not run, got %v", calls)
	}
	// Optional config alone does not complete a profile (token is required).
	e.setField("github", "work", "owner", "acme")
	e.wantError(e.roundtrip(Request{Op: "enable", Integration: "github"}), "no complete profile")
	// Setting the required secret completes it.
	e.setField("github", "work", "token", "x")
	e.wantOK(e.roundtrip(Request{Op: "enable", Integration: "github"}))
}

func TestEnableStartsSocketUnit(t *testing.T) {
	e := newTestEnv(t, 0)
	e.setField("github", "work", "token", "x")
	e.wantOK(e.roundtrip(Request{Op: "enable", Integration: "github"}))

	calls := e.systemctlCalls()
	want := "start spaces-integration-github.socket"
	// calls[0] is set-field's try-restart; enable's socket start follows.
	if len(calls) != 2 || calls[1] != want {
		t.Fatalf("want second call %q, got %v", want, calls)
	}
	if !e.enabledState().Integrations["github"].Enabled {
		t.Fatal("want enabled=true in enabled.json")
	}
	if e.githubInfo()["enabled"] != true {
		t.Fatal("list must report enabled")
	}
}

func TestEnableRollsBackOnSystemctlFailure(t *testing.T) {
	e := newTestEnv(t, 1)
	e.setField("github", "work", "token", "x")
	e.wantError(e.roundtrip(Request{Op: "enable", Integration: "github"}), "systemctl start failed")

	if e.enabledState().Integrations["github"].Enabled {
		t.Fatal("enabled.json must be rolled back to enabled=false")
	}
	// The store survives the rollback: the profile is still complete.
	if profileByName(e.githubInfo(), "work")["complete"] != true {
		t.Fatal("rollback must not drop the store")
	}
}

func TestDisableStopsBothUnits(t *testing.T) {
	e := newTestEnv(t, 0)
	e.setField("github", "work", "token", "x")
	e.wantOK(e.roundtrip(Request{Op: "enable", Integration: "github"}))
	e.wantOK(e.roundtrip(Request{Op: "disable", Integration: "github"}))

	calls := e.systemctlCalls()
	wantStop := "stop spaces-integration-github.socket spaces-integration-github.service"
	// calls: [set-field try-restart, enable start, disable stop].
	if len(calls) != 3 || calls[2] != wantStop {
		t.Fatalf("want stop call %q, got %v", wantStop, calls)
	}
	if e.enabledState().Integrations["github"].Enabled {
		t.Fatal("want enabled=false after disable")
	}
}

// A running integration reads its credentials from a start-time snapshot
// (LoadCredential[Encrypted]), so a successful field write must bounce the
// service — try-restart: restarts a running unit, no-ops an inactive one
// (the socket stays up; the next connection re-activates with fresh creds).
func TestSetFieldTryRestartsService(t *testing.T) {
	e := newTestEnv(t, 0)
	e.setField("github", "work", "token", "x")

	calls := e.systemctlCalls()
	want := "try-restart spaces-integration-github.service"
	if len(calls) != 1 || calls[0] != want {
		t.Fatalf("want [%q], got %v", want, calls)
	}
}

func TestRemoveProfileTryRestartsService(t *testing.T) {
	e := newTestEnv(t, 0)
	e.setField("github", "work", "token", "w")
	e.wantOK(e.roundtrip(Request{Op: "remove-profile", Integration: "github", Profile: "work"}))

	calls := e.systemctlCalls()
	want := "try-restart spaces-integration-github.service"
	if len(calls) != 2 || calls[1] != want {
		t.Fatalf("want second call %q, got %v", want, calls)
	}
}

// The restart is best-effort: the store write is already durable and the next
// socket activation picks up the new values, so a failed try-restart must not
// fail the op.
func TestSetFieldSucceedsWhenRestartFails(t *testing.T) {
	e := newTestEnv(t, 1)
	e.setField("github", "work", "token", "x")

	calls := e.systemctlCalls()
	want := "try-restart spaces-integration-github.service"
	if len(calls) != 1 || calls[0] != want {
		t.Fatalf("try-restart must still be attempted, want [%q], got %v", want, calls)
	}
}

func TestRemoveProfile(t *testing.T) {
	e := newTestEnv(t, 0)
	e.setField("github", "work", "token", "w")
	e.setField("github", "personal", "token", "p")
	e.wantOK(e.roundtrip(Request{Op: "remove-profile", Integration: "github", Profile: "work"}))

	gh := e.githubInfo()
	if profileByName(gh, "work") != nil {
		t.Fatal("removed profile must not list")
	}
	if profileByName(gh, "personal") == nil {
		t.Fatal("other profile must survive removal")
	}
}

func TestBadNamesRejected(t *testing.T) {
	e := newTestEnv(t, 0)
	bad := []string{"../etc", "Git Hub", "a/b", "a@b", "", "UPPER"}
	for _, name := range bad {
		e.wantError(e.roundtrip(Request{Op: "enable", Integration: name}), "invalid integration name")
		e.wantError(e.roundtrip(Request{Op: "disable", Integration: name}), "invalid integration name")
		e.wantError(e.roundtrip(Request{Op: "set-field", Integration: name, Profile: "work", Field: "token", Value: "x"}), "invalid integration name")
		e.wantError(e.roundtrip(Request{Op: "set-field", Integration: "github", Profile: name, Field: "token", Value: "x"}), "invalid profile name")
	}
	if calls := e.systemctlCalls(); calls != nil {
		t.Fatalf("systemctl must not run for bad names, got %v", calls)
	}
}

func TestMalformedJSON(t *testing.T) {
	e := newTestEnv(t, 0)
	e.wantError(e.roundtripRaw(`{not json`), "malformed")
	e.wantError(e.roundtripRaw(`[1,2,3]`), "")
	e.wantError(e.roundtrip(Request{Op: "frobnicate"}), "unknown op")
	// Server survived all of the above.
	e.wantOK(e.roundtrip(Request{Op: "list"}))
}

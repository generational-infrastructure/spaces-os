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
  "network": true,
  "connectPorts": [443],
  "autoRun": ["get_repo"],
  "secrets": {
    "token": { "description": "GitHub personal access token" },
    "extra": { "description": "Second secret" }
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
	for _, d := range []string{defsDir, stateDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(defsDir, "github.json"), []byte(githubDef), 0o644); err != nil {
		t.Fatal(err)
	}
	// Stub encryptor: argv is --name=<secret> - <dest>; wraps stdin so the test
	// can assert the plaintext was consumed and transformed.
	creds := filepath.Join(dir, "creds-encrypt")
	writeScript(t, creds, "#!/bin/sh\ndest=\"$3\"\n{ printf 'ENC('; cat; printf ')'; } > \"$dest\"\n")
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
	srv := NewServer(defsDir, stateDir, []string{creds}, []string{sysctl})
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

func (e *testEnv) setSecret(integration, name, value string) {
	e.t.Helper()
	e.wantOK(e.roundtrip(Request{Op: "set-secret", Integration: integration, Name: name, Value: value}))
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
	m := e.roundtrip(Request{Op: "list"})
	e.wantOK(m)

	ints, ok := m["integrations"].([]any)
	if !ok || len(ints) != 1 {
		t.Fatalf("want 1 integration, got %v", m["integrations"])
	}
	gh := ints[0].(map[string]any)
	if gh["name"] != "github" || gh["description"] != "GitHub" || gh["enabled"] != false {
		t.Fatalf("unexpected integration: %v", gh)
	}
	secrets := gh["secrets"].([]any)
	if len(secrets) != 2 {
		t.Fatalf("want 2 secrets, got %v", secrets)
	}
	for _, s := range secrets {
		sm := s.(map[string]any)
		if sm["set"] != false {
			t.Fatalf("want set=false on empty state, got %v", sm)
		}
	}
}

func TestSetSecretWritesCredAndFlipsSet(t *testing.T) {
	e := newTestEnv(t, 0)
	e.setSecret("github", "token", "hunter2")

	// No extension: the cred path matches the unit's LoadCredentialEncrypted.
	cred := filepath.Join(e.stateDir, "github", "token")
	data, err := os.ReadFile(cred)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "ENC(hunter2)" {
		t.Fatalf("stub encryptor output mismatch: %q", data)
	}

	// Secret dir + state dir private; enabled.json owner-only.
	if fi, err := os.Stat(filepath.Join(e.stateDir, "github")); err != nil || fi.Mode().Perm() != 0o700 {
		t.Fatalf("secret dir perms: %v %v", fi.Mode(), err)
	}
	if fi, err := os.Stat(filepath.Join(e.stateDir, "enabled.json")); err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("enabled.json perms: %v %v", fi.Mode(), err)
	}

	st := e.enabledState()
	if !st.Integrations["github"].Secrets["token"] {
		t.Fatalf("want secrets.token=true, got %+v", st)
	}
	if st.Integrations["github"].Enabled {
		t.Fatal("set-secret must not enable")
	}

	// list reflects it.
	m := e.roundtrip(Request{Op: "list"})
	gh := m["integrations"].([]any)[0].(map[string]any)
	for _, s := range gh["secrets"].([]any) {
		sm := s.(map[string]any)
		want := sm["name"] == "token"
		if sm["set"] != want {
			t.Fatalf("secret %v: want set=%v", sm["name"], want)
		}
	}
}

func TestSetSecretUnknownNames(t *testing.T) {
	e := newTestEnv(t, 0)
	e.wantError(e.roundtrip(Request{Op: "set-secret", Integration: "nope", Name: "token", Value: "x"}), "unknown integration")
	e.wantError(e.roundtrip(Request{Op: "set-secret", Integration: "github", Name: "nope", Value: "x"}), "unknown secret")
}

func TestEnableFailsWithMissingSecrets(t *testing.T) {
	e := newTestEnv(t, 0)
	e.wantError(e.roundtrip(Request{Op: "enable", Integration: "github"}), "missing secrets: extra, token")
	if calls := e.systemctlCalls(); calls != nil {
		t.Fatalf("systemctl must not run, got %v", calls)
	}

	// One of two set: still missing the other.
	e.setSecret("github", "token", "x")
	e.wantError(e.roundtrip(Request{Op: "enable", Integration: "github"}), "missing secrets: extra")
}

func TestEnableStartsSocketUnit(t *testing.T) {
	e := newTestEnv(t, 0)
	e.setSecret("github", "token", "x")
	e.setSecret("github", "extra", "y")
	e.wantOK(e.roundtrip(Request{Op: "enable", Integration: "github"}))

	calls := e.systemctlCalls()
	want := "start spaces-integration-github.socket"
	if len(calls) != 1 || calls[0] != want {
		t.Fatalf("want [%q], got %v", want, calls)
	}
	if !e.enabledState().Integrations["github"].Enabled {
		t.Fatal("want enabled=true in enabled.json")
	}

	m := e.roundtrip(Request{Op: "list"})
	gh := m["integrations"].([]any)[0].(map[string]any)
	if gh["enabled"] != true {
		t.Fatalf("list must report enabled, got %v", gh)
	}
}

func TestEnableRollsBackOnSystemctlFailure(t *testing.T) {
	e := newTestEnv(t, 1)
	e.setSecret("github", "token", "x")
	e.setSecret("github", "extra", "y")
	e.wantError(e.roundtrip(Request{Op: "enable", Integration: "github"}), "systemctl start failed")

	st := e.enabledState()
	if st.Integrations["github"].Enabled {
		t.Fatal("enabled.json must be rolled back to enabled=false")
	}
	// Secrets survive the rollback.
	if !st.Integrations["github"].Secrets["token"] {
		t.Fatal("rollback must not drop secrets state")
	}
}

func TestDisableStopsBothUnits(t *testing.T) {
	e := newTestEnv(t, 0)
	e.setSecret("github", "token", "x")
	e.setSecret("github", "extra", "y")
	e.wantOK(e.roundtrip(Request{Op: "enable", Integration: "github"}))
	e.wantOK(e.roundtrip(Request{Op: "disable", Integration: "github"}))

	calls := e.systemctlCalls()
	wantStop := "stop spaces-integration-github.socket spaces-integration-github.service"
	if len(calls) != 2 || calls[1] != wantStop {
		t.Fatalf("want stop call %q, got %v", wantStop, calls)
	}
	if e.enabledState().Integrations["github"].Enabled {
		t.Fatal("want enabled=false after disable")
	}
}

func TestBadNamesRejected(t *testing.T) {
	e := newTestEnv(t, 0)
	bad := []string{"../etc", "Git Hub", "a/b", "a@b", "", "UPPER"}
	for _, name := range bad {
		e.wantError(e.roundtrip(Request{Op: "enable", Integration: name}), "invalid integration name")
		e.wantError(e.roundtrip(Request{Op: "disable", Integration: name}), "invalid integration name")
		e.wantError(e.roundtrip(Request{Op: "set-secret", Integration: name, Name: "token", Value: "x"}), "invalid integration name")
		e.wantError(e.roundtrip(Request{Op: "set-secret", Integration: "github", Name: name, Value: "x"}), "invalid secret name")
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

package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// testEnv wires a real unix-socket server against temp dirs and stub commands.
// Connections come from this test process, so SO_PEERCRED resolves to the
// current uid == the broker's own uid: checkPeer passes.
//
// The store engine is the REAL skill-config (found on PATH via the build's
// nativeCheckInputs), driven over its versioned `api` JSON seam — mocking it
// would have hidden broker↔skill-config seam bugs, exactly the class the
// POC's VM check surfaced back when the broker scraped the human CLI's argv
// and stdout. Only systemd-creds (needs a TPM) and systemctl are stubbed:
// encrypt prepends an "ENC" header line, decrypt strips it, so seal/unseal
// round-trips faithfully while a sealed blob is still observably not
// plaintext.
type testEnv struct {
	t           *testing.T
	l           net.Listener
	sysctl      string
	sysctlExit  int
	srv         *Server
	sock        string
	defsDir     string
	stateDir    string
	managedRoot string
	sysctlLog   string
	runtimeRoot string
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

const signalDef = `{
  "name": "signal",
  "description": "Signal",
  "multiProfile": false,
  "network": false,
  "connectPorts": [],
  "autoRun": ["threads"],
  "config": {},
  "secrets": {}
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
	managedRoot := filepath.Join(dir, "managed")
	runtimeDir := filepath.Join(dir, "run")
	// The setup sockets live at %t/spaces-integration-<name>-setup.sock; %t in
	// the tests is a short MkdirTemp dir so the AF_UNIX path stays under the
	// ~108-byte sun_path limit (t.TempDir() encodes the long test name).
	runtimeRoot, err := os.MkdirTemp("", "sr")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(runtimeRoot) })
	for _, d := range []string{defsDir, stateDir, runtimeDir, managedRoot} {
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
	srv := NewServer(defsDir, stateDir, managedRoot, runtimeDir, runtimeRoot,
		[]string{credsEnc}, []string{credsDec}, []string{sysctl}, []string{"skill-config"})
	t.Cleanup(func() { l.Close(); srv.Wait() })
	go srv.Serve(l)
	return &testEnv{t: t, srv: srv, sock: sock, defsDir: defsDir, stateDir: stateDir, managedRoot: managedRoot, sysctlLog: sysctlLog, runtimeRoot: runtimeRoot, l: l, sysctl: sysctl, sysctlExit: systemctlExit}
}

// drain closes the broker listener and outwaits every in-flight connection
// handler — including the post-stream unit work a setup flow performs AFTER
// the panel already saw its terminal event. Idempotent.
func (e *testEnv) drain() {
	e.l.Close()
	e.srv.Wait()
}

// slowSystemctl rewrites the systemctl stub to sleep before logging its argv,
// reproducing the nix sandbox's slow fork/exec: the window in which a setup
// flow's post-`done` unit work straggles behind the test body.
func (e *testEnv) slowSystemctl() {
	writeScript(e.t, e.sysctl,
		"#!/bin/sh\nsleep 0.1\necho \"$@\" >> "+e.sysctlLog+"\nexit "+itoa(e.sysctlExit)+"\n")
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

// writeDef drops an extra definition file into the running server's defsDir.
// Definitions are re-read per request, so the next op observes it.
func (e *testEnv) writeDef(name, body string) {
	e.t.Helper()
	if err := os.WriteFile(filepath.Join(e.defsDir, name+".json"), []byte(body), 0o644); err != nil {
		e.t.Fatal(err)
	}
}

// infoByName returns the named IntegrationInfo from a `list` reply.
func (e *testEnv) infoByName(name string) map[string]any {
	e.t.Helper()
	m := e.roundtrip(Request{Op: "list"})
	e.wantOK(m)
	ints, _ := m["integrations"].([]any)
	for _, it := range ints {
		im := it.(map[string]any)
		if im["name"] == name {
			return im
		}
	}
	e.t.Fatalf("integration %q not in list %v", name, m["integrations"])
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

// list must surface each definition's setup flag so the panel can gate its
// Set up / Link button: a def with setup:true reports "setup": true, one
// without the flag reports "setup": false.
func TestListReportsSetupFlag(t *testing.T) {
	e := newTestEnv(t, 0)
	if gh := e.githubInfo(); gh["setup"] != false {
		t.Fatalf("want github setup=false, got %v", gh["setup"])
	}
	e.writeDef("signal", signalSetupDef)
	if sig := e.infoByName("signal"); sig["setup"] != true {
		t.Fatalf("want signal setup=true, got %v", sig["setup"])
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

// A field-less definition (config={}, secrets={}) — signal — has no profile to
// complete and no LoadCredential* sources to stage, so enable must succeed with
// no provisioning, skip credential staging, and list must show empty schemas.
func TestEnableFieldlessDefinition(t *testing.T) {
	e := newTestEnv(t, 0)
	e.writeDef("signal", signalDef)

	// (a) enable succeeds with no profile provisioned.
	e.wantOK(e.roundtrip(Request{Op: "enable", Integration: "signal"}))
	if !e.enabledState().Integrations["signal"].Enabled {
		t.Fatal("want signal enabled in enabled.json")
	}

	// (b) no credential staging: a field-less manifest emits no LoadCredential*,
	// so the broker must not create config.toml or a sealed secrets blob.
	if _, err := os.Stat(filepath.Join(e.stateDir, "signal", "config.toml")); !os.IsNotExist(err) {
		t.Fatalf("field-less enable must not create config.toml (stat err=%v)", err)
	}
	if _, err := os.Stat(filepath.Join(e.stateDir, "signal", "secrets")); !os.IsNotExist(err) {
		t.Fatalf("field-less enable must not create a secrets blob (stat err=%v)", err)
	}

	// (c) list shows empty schemas + the enabled state, no profiles.
	info := e.infoByName("signal")
	if info["enabled"] != true {
		t.Fatalf("list must report signal enabled, got %v", info["enabled"])
	}
	if cfg := info["config"].([]any); len(cfg) != 0 {
		t.Fatalf("field-less config schema must be empty, got %v", cfg)
	}
	if sec := info["secrets"].([]any); len(sec) != 0 {
		t.Fatalf("field-less secret schema must be empty, got %v", sec)
	}
	if profs := info["profiles"].([]any); len(profs) != 0 {
		t.Fatalf("field-less integration needs no profiles, got %v", profs)
	}
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

// signalSetupDef is the signal definition with the setup channel enabled: it
// exercises the new Definition.Setup / .ExtraServices fields and the `setup` op.
const signalSetupDef = `{
  "name": "signal",
  "description": "Signal",
  "multiProfile": false,
  "network": false,
  "connectPorts": [],
  "autoRun": ["threads"],
  "config": {},
  "secrets": {},
  "setup": true,
  "extraServices": ["spaces-signal-cli.service", "spaces-signal-bridge.service"]
}`

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// writeEnabled overwrites enabled.json directly so a test can set the run state
// without going through the broker's enable path (which would start units).
func (e *testEnv) writeEnabled(st EnabledState) {
	e.t.Helper()
	data, err := json.Marshal(st)
	if err != nil {
		e.t.Fatal(err)
	}
	if err := os.MkdirAll(e.stateDir, 0o700); err != nil {
		e.t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(e.stateDir, "enabled.json"), data, 0o600); err != nil {
		e.t.Fatal(err)
	}
}

// startSetupHelper listens on the twin setup socket for one integration and,
// on the first connection, runs handler (scripting the NDJSON a real setup
// helper would emit). The broker dials this socket after `systemctl start`.
func (e *testEnv) startSetupHelper(integration string, handler func(conn net.Conn)) net.Listener {
	e.t.Helper()
	path := filepath.Join(e.runtimeRoot, "spaces-integration-"+integration+"-setup.sock")
	_ = os.Remove(path)
	ln, err := net.Listen("unix", path)
	if err != nil {
		e.t.Fatal(err)
	}
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		handler(conn)
	}()
	return ln
}

// openSetup dials the broker, sends a setup request, and returns the live
// connection plus a reader streaming the event lines.
func (e *testEnv) openSetup(integration string) (net.Conn, *bufio.Reader) {
	e.t.Helper()
	conn, err := net.Dial("unix", e.sock)
	if err != nil {
		e.t.Fatal(err)
	}
	req, err := json.Marshal(Request{Op: "setup", Integration: integration})
	if err != nil {
		e.t.Fatal(err)
	}
	if _, err := conn.Write(append(req, '\n')); err != nil {
		e.t.Fatal(err)
	}
	return conn, bufio.NewReader(conn)
}

// readEvent reads one NDJSON event line off a setup stream.
func (e *testEnv) readEvent(r *bufio.Reader) map[string]any {
	e.t.Helper()
	line, err := r.ReadBytes('\n')
	if len(line) == 0 && err != nil {
		e.t.Fatalf("read event: %v", err)
	}
	var m map[string]any
	if err := json.Unmarshal(bytes.TrimSpace(line), &m); err != nil {
		e.t.Fatalf("parse event %q: %v", line, err)
	}
	return m
}

// waitSystemctl polls the systemctl log until pred holds (the broker finishes a
// setup stream asynchronously) or a short deadline elapses.
func (e *testEnv) waitSystemctl(pred func([]string) bool) []string {
	e.t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		calls := e.systemctlCalls()
		if pred(calls) {
			return calls
		}
		if time.Now().After(deadline) {
			e.t.Fatalf("timeout waiting for systemctl; got %v", calls)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func hasPrefixIn(calls []string, prefix string) bool {
	for _, c := range calls {
		if strings.HasPrefix(c, prefix) {
			return true
		}
	}
	return false
}

func TestDefinitionParsesSetupFields(t *testing.T) {
	var d Definition
	if err := json.Unmarshal([]byte(signalSetupDef), &d); err != nil {
		t.Fatal(err)
	}
	if !d.Setup {
		t.Fatal("want Setup=true")
	}
	want := []string{"spaces-signal-cli.service", "spaces-signal-bridge.service"}
	if !equalStrings(d.ExtraServices, want) {
		t.Fatalf("want ExtraServices %v, got %v", want, d.ExtraServices)
	}
	// A definition without the fields defaults to false/nil.
	var g Definition
	if err := json.Unmarshal([]byte(githubDef), &g); err != nil {
		t.Fatal(err)
	}
	if g.Setup || g.ExtraServices != nil {
		t.Fatalf("want zero-value setup fields, got Setup=%v ExtraServices=%v", g.Setup, g.ExtraServices)
	}
}

func TestReconcileStartsEnabledDefined(t *testing.T) {
	e := newTestEnv(t, 0)
	e.writeDef("signal", signalDef)
	// github is defined too, but is NOT enabled -> not started. signal is both.
	e.writeEnabled(EnabledState{Integrations: map[string]IntegrationState{"signal": {Enabled: true}}})
	e.srv.ReconcileEnabled()
	if calls := e.systemctlCalls(); !equalStrings(calls, []string{"start spaces-integration-signal.socket"}) {
		t.Fatalf("want only signal socket started, got %v", calls)
	}
}

func TestReconcileSkipsEnabledUndefined(t *testing.T) {
	e := newTestEnv(t, 0)
	// "ghost" is enabled in state but has no definition file -> skipped.
	e.writeEnabled(EnabledState{Integrations: map[string]IntegrationState{"ghost": {Enabled: true}}})
	e.srv.ReconcileEnabled()
	if calls := e.systemctlCalls(); calls != nil {
		t.Fatalf("an undefined integration must not be started, got %v", calls)
	}
}

func TestReconcileIgnoresDisabled(t *testing.T) {
	e := newTestEnv(t, 0)
	// github IS defined (newTestEnv) but disabled -> untouched.
	e.writeEnabled(EnabledState{Integrations: map[string]IntegrationState{"github": {Enabled: false}}})
	e.srv.ReconcileEnabled()
	if calls := e.systemctlCalls(); calls != nil {
		t.Fatalf("a disabled integration must not be started, got %v", calls)
	}
}

func TestReconcileContinuesAfterFailure(t *testing.T) {
	e := newTestEnv(t, 1) // systemctl stub always fails
	e.writeDef("signal", signalDef)
	e.writeEnabled(EnabledState{Integrations: map[string]IntegrationState{
		"github": {Enabled: true},
		"signal": {Enabled: true},
	}})
	e.srv.ReconcileEnabled()
	want := []string{
		"start spaces-integration-github.socket",
		"start spaces-integration-signal.socket",
	}
	if calls := e.systemctlCalls(); !equalStrings(calls, want) {
		t.Fatalf("a failure on one must not block the next; want %v, got %v", want, calls)
	}
}

func TestSetupHappyPath(t *testing.T) {
	e := newTestEnv(t, 0)
	e.writeDef("signal", signalSetupDef)
	e.writeEnabled(EnabledState{Integrations: map[string]IntegrationState{"signal": {Enabled: true}}})

	qr := `{"event":"qr","uri":"sgnl://linkdevice?x=1","png":"UE5HAAo="}`
	ln := e.startSetupHelper("signal", func(conn net.Conn) {
		defer conn.Close()
		conn.Write([]byte(qr + "\n"))
		conn.Write([]byte(`{"event":"done"}` + "\n"))
	})
	defer ln.Close()

	conn, r := e.openSetup("signal")
	defer conn.Close()

	ev1 := e.readEvent(r)
	if ev1["event"] != "qr" || ev1["uri"] != "sgnl://linkdevice?x=1" || ev1["png"] != "UE5HAAo=" {
		t.Fatalf("want qr relayed verbatim, got %v", ev1)
	}
	ev2 := e.readEvent(r)
	if ev2["event"] != "done" {
		t.Fatalf("want done, got %v", ev2)
	}
	// After a done event the broker closes the connection.
	if _, err := r.ReadBytes('\n'); err == nil {
		t.Fatal("broker must close the connection after done")
	}
	want := []string{
		"start spaces-integration-signal-setup.socket",
		"try-restart spaces-integration-signal.service spaces-signal-cli.service spaces-signal-bridge.service",
		"stop spaces-integration-signal-setup.service spaces-integration-signal-setup.socket",
	}
	calls := e.waitSystemctl(func(c []string) bool { return len(c) >= 3 })
	if !equalStrings(calls, want) {
		t.Fatalf("want systemctl order %v, got %v", want, calls)
	}
}

// signalSetupRestartDef additionally pins setupRestart: the post-done
// try-restart must hit EXACTLY these units instead of the legacy set
// (own service + all extras). Signal's real manifest uses this to keep
// spaces-signal-cli.service alive after a link — the daemon already holds the
// freshly linked account live, and a restart triggers signal-cli's per-account
// network check which silently drops the account on failure.
const signalSetupRestartDef = `{
  "name": "signal",
  "description": "Signal",
  "multiProfile": false,
  "config": {},
  "secrets": {},
  "setup": true,
  "extraServices": ["spaces-signal-cli.service", "spaces-signal-bridge.service"],
  "setupRestart": ["spaces-integration-signal.service"]
}`

// With setupRestart present the post-setup try-restart hits ONLY the listed
// units; extras keep running untouched. Absent setupRestart keeps the legacy
// behavior (TestSetupHappyPath).
func TestSetupRestartLimitsPostSetupUnits(t *testing.T) {
	e := newTestEnv(t, 0)
	e.writeDef("signal", signalSetupRestartDef)
	e.writeEnabled(EnabledState{Integrations: map[string]IntegrationState{"signal": {Enabled: true}}})

	ln := e.startSetupHelper("signal", func(conn net.Conn) {
		defer conn.Close()
		conn.Write([]byte(`{"event":"done"}` + "\n"))
	})
	defer ln.Close()

	conn, r := e.openSetup("signal")
	defer conn.Close()
	if ev := e.readEvent(r); ev["event"] != "done" {
		t.Fatalf("want done, got %v", ev)
	}
	want := []string{
		"start spaces-integration-signal-setup.socket",
		"try-restart spaces-integration-signal.service",
		"stop spaces-integration-signal-setup.service spaces-integration-signal-setup.socket",
	}
	calls := e.waitSystemctl(func(c []string) bool { return len(c) >= 3 })
	if !equalStrings(calls, want) {
		t.Fatalf("want setupRestart-limited units %v, got %v", want, calls)
	}
}

// Setup on a DISABLED integration is the provisioning path (proton bootstrap:
// enable needs a complete profile, but bridge_password only exists after
// setup — the gate would deadlock). The flow must run; setupPark daemons are
// parked/unparked exactly as in the enabled case.
func TestSetupDisabledProvisions(t *testing.T) {
	e := newTestEnv(t, 0)
	e.writeDef("mail", mailSetupDef) // proton-shaped: fields + setup + setupPark
	ln := e.startSetupHelper("mail", func(conn net.Conn) {
		defer conn.Close()
		bufio.NewReader(conn).ReadBytes('\n') // action line
		conn.Write([]byte(`{"event":"done"}` + "\n"))
	})
	defer ln.Close()

	conn, r := e.openSetup("mail")
	defer conn.Close()
	if ev := e.readEvent(r); ev["event"] != "done" {
		t.Fatalf("want done (setup must run while disabled), got %v", ev)
	}
	want := []string{
		"stop spaces-proton-bridge.service",
		"start spaces-integration-mail-setup.socket",
		"try-restart spaces-integration-mail.service",
		"stop spaces-integration-mail-setup.service spaces-integration-mail-setup.socket",
		"start spaces-proton-bridge.service",
	}
	calls := e.waitSystemctl(func(c []string) bool { return len(c) >= 5 })
	if !equalStrings(calls, want) {
		t.Fatalf("want park/flow order %v, got %v", want, calls)
	}
}

// Setup on a disabled integration whose helper depends on its extraServices
// daemons (signal): the broker starts the non-parked extras for the duration
// and stops them on the way out — they are NOT running (disabled = socket
// down, nothing pulled them in).
func TestSetupDisabledStartsExtras(t *testing.T) {
	e := newTestEnv(t, 0)
	e.writeDef("signal", signalSetupDef) // extras, no setupPark, NOT enabled
	ln := e.startSetupHelper("signal", func(conn net.Conn) {
		defer conn.Close()
		conn.Write([]byte(`{"event":"done"}` + "\n"))
	})
	defer ln.Close()

	conn, r := e.openSetup("signal")
	defer conn.Close()
	if ev := e.readEvent(r); ev["event"] != "done" {
		t.Fatalf("want done, got %v", ev)
	}
	want := []string{
		"start spaces-signal-cli.service spaces-signal-bridge.service",
		"start spaces-integration-signal-setup.socket",
		"try-restart spaces-integration-signal.service spaces-signal-cli.service spaces-signal-bridge.service",
		"stop spaces-integration-signal-setup.service spaces-integration-signal-setup.socket",
		"stop spaces-signal-cli.service spaces-signal-bridge.service",
	}
	calls := e.waitSystemctl(func(c []string) bool { return len(c) >= 5 })
	if !equalStrings(calls, want) {
		t.Fatalf("want extras start/stop order %v, got %v", want, calls)
	}
}

func TestSetupDefWithoutSetup(t *testing.T) {
	e := newTestEnv(t, 0)
	// github is enabled but its definition exposes no setup flow.
	e.writeEnabled(EnabledState{Integrations: map[string]IntegrationState{"github": {Enabled: true}}})
	conn, r := e.openSetup("github")
	defer conn.Close()
	ev := e.readEvent(r)
	if ev["event"] != "error" || !strings.Contains(ev["error"].(string), "setup") {
		t.Fatalf("want a no-setup error event, got %v", ev)
	}
	if calls := e.systemctlCalls(); calls != nil {
		t.Fatalf("no unit must start for a setup-less integration, got %v", calls)
	}
}

func TestSetupHelperErrorNoRestart(t *testing.T) {
	e := newTestEnv(t, 0)
	e.writeDef("signal", signalSetupDef)
	e.writeEnabled(EnabledState{Integrations: map[string]IntegrationState{"signal": {Enabled: true}}})
	ln := e.startSetupHelper("signal", func(conn net.Conn) {
		defer conn.Close()
		conn.Write([]byte(`{"event":"message","text":"waiting for phone"}` + "\n"))
		conn.Write([]byte(`{"event":"error","error":"link timeout"}` + "\n"))
	})
	defer ln.Close()

	conn, r := e.openSetup("signal")
	defer conn.Close()
	m1 := e.readEvent(r)
	if m1["event"] != "message" || m1["text"] != "waiting for phone" {
		t.Fatalf("want message relayed verbatim, got %v", m1)
	}
	m2 := e.readEvent(r)
	if m2["event"] != "error" || m2["error"] != "link timeout" {
		t.Fatalf("want error relayed verbatim, got %v", m2)
	}
	if _, err := r.ReadBytes('\n'); err == nil {
		t.Fatal("broker must close after the helper error")
	}
	calls := e.waitSystemctl(func(c []string) bool { return hasPrefixIn(c, "stop ") })
	if hasPrefixIn(calls, "try-restart") {
		t.Fatalf("a helper error must not try-restart, got %v", calls)
	}
	want := []string{
		"start spaces-integration-signal-setup.socket",
		"stop spaces-integration-signal-setup.service spaces-integration-signal-setup.socket",
	}
	if !equalStrings(calls, want) {
		t.Fatalf("want %v, got %v", want, calls)
	}
}

func TestSetupClientDisconnectStopsUnits(t *testing.T) {
	e := newTestEnv(t, 0)
	e.writeDef("signal", signalSetupDef)
	e.writeEnabled(EnabledState{Integrations: map[string]IntegrationState{"signal": {Enabled: true}}})
	release := make(chan struct{})
	ln := e.startSetupHelper("signal", func(conn net.Conn) {
		defer conn.Close()
		conn.Write([]byte(`{"event":"qr","uri":"u","png":"p"}` + "\n"))
		<-release // stay open until the test releases it
	})
	defer ln.Close()
	defer close(release)

	conn, r := e.openSetup("signal")
	if ev := e.readEvent(r); ev["event"] != "qr" {
		t.Fatalf("want qr, got %v", ev)
	}
	// Client disconnects mid-stream.
	conn.Close()

	want := []string{
		"start spaces-integration-signal-setup.socket",
		"stop spaces-integration-signal-setup.service spaces-integration-signal-setup.socket",
	}
	calls := e.waitSystemctl(func(c []string) bool { return len(c) >= 2 })
	if !equalStrings(calls, want) {
		t.Fatalf("client disconnect must stop the setup units and never try-restart, got %v", calls)
	}
}

func TestSetupConcurrentListSucceeds(t *testing.T) {
	e := newTestEnv(t, 0)
	e.writeDef("signal", signalSetupDef)
	e.writeEnabled(EnabledState{Integrations: map[string]IntegrationState{"signal": {Enabled: true}}})
	release := make(chan struct{})
	ln := e.startSetupHelper("signal", func(conn net.Conn) {
		defer conn.Close()
		conn.Write([]byte(`{"event":"qr","uri":"u","png":"p"}` + "\n"))
		<-release
		conn.Write([]byte(`{"event":"done"}` + "\n"))
	})
	defer ln.Close()

	conn, r := e.openSetup("signal")
	defer conn.Close()
	if ev := e.readEvent(r); ev["event"] != "qr" {
		t.Fatalf("want qr, got %v", ev)
	}

	// While the setup stream is open (helper blocked), a list must still
	// succeed — the broker must not hold s.mu during streaming.
	info := e.infoByName("signal")
	if info["enabled"] != true {
		t.Fatalf("list during an open setup stream must work, got %v", info)
	}

	close(release) // let the helper finish so the stream drains cleanly
	if ev := e.readEvent(r); ev["event"] != "done" {
		t.Fatalf("want done, got %v", ev)
	}
}

// A setup flow keeps doing unit work AFTER the panel saw `done` — the
// post-stream try-restart and the deferred setup-unit stop. The harness must
// outwait that work before TempDir cleanup: with a slow systemctl (the nix
// sandbox's fork/exec latency) a straggling stub otherwise recreates
// systemctl.log mid-RemoveAll and the TempDir teardown fails ENOTEMPTY.
func TestSetupTeardownDrainsPostStreamWork(t *testing.T) {
	e := newTestEnv(t, 0)
	e.slowSystemctl()
	e.writeDef("signal", signalSetupDef)
	e.writeEnabled(EnabledState{Integrations: map[string]IntegrationState{"signal": {Enabled: true}}})
	ln := e.startSetupHelper("signal", func(conn net.Conn) {
		defer conn.Close()
		conn.Write([]byte(`{"event":"done"}` + "\n"))
	})
	defer ln.Close()

	conn, r := e.openSetup("signal")
	if ev := e.readEvent(r); ev["event"] != "done" {
		t.Fatalf("want done, got %v", ev)
	}
	conn.Close()

	e.drain()
	calls := e.systemctlCalls()
	if !hasPrefixIn(calls, "try-restart spaces-integration-signal.service") ||
		!hasPrefixIn(calls, "stop spaces-integration-signal-setup.service") {
		t.Fatalf("drain must outwait the post-stream unit work, got %v", calls)
	}
}

// mailSetupDef is a proton-shaped definition: config + secret fields, a setup
// flow, and a setupPark unit (the vendor daemon the broker displaces for the
// duration of link/remove). It exercises the v2 setup channel end to end.
const mailSetupDef = `{
  "name": "mail",
  "description": "Email (IMAP/SMTP)",
  "multiProfile": true,
  "network": true,
  "connectPorts": [443],
  "autoRun": [],
  "config": { "email": { "description": "Account email", "required": true } },
  "secrets": { "bridge_password": { "description": "Bridge password", "required": false } },
  "setup": true,
  "extraServices": [],
  "setupPark": ["spaces-proton-bridge.service"]
}`

func TestDefinitionParsesSetupPark(t *testing.T) {
	var d Definition
	if err := json.Unmarshal([]byte(mailSetupDef), &d); err != nil {
		t.Fatal(err)
	}
	if !equalStrings(d.SetupPark, []string{"spaces-proton-bridge.service"}) {
		t.Fatalf("want SetupPark [spaces-proton-bridge.service], got %v", d.SetupPark)
	}
	// A definition without the field defaults to nil.
	var g Definition
	if err := json.Unmarshal([]byte(signalSetupDef), &g); err != nil {
		t.Fatal(err)
	}
	if g.SetupPark != nil {
		t.Fatalf("want nil SetupPark, got %v", g.SetupPark)
	}
}

// enableMail writes the mail def + marks it enabled so a setup/remove flow can
// run against it.
func (e *testEnv) enableMail() {
	e.t.Helper()
	e.writeDef("mail", mailSetupDef)
	e.writeEnabled(EnabledState{Integrations: map[string]IntegrationState{"mail": {Enabled: true}}})
}

// The broker writes exactly one action line to the helper immediately after
// connecting, before any relay — {"action":"link"} for a default setup op.
func TestSetupActionLineFirst(t *testing.T) {
	e := newTestEnv(t, 0)
	e.writeDef("signal", signalSetupDef)
	e.writeEnabled(EnabledState{Integrations: map[string]IntegrationState{"signal": {Enabled: true}}})
	gotAction := make(chan string, 1)
	ln := e.startSetupHelper("signal", func(conn net.Conn) {
		defer conn.Close()
		line, _ := bufio.NewReader(conn).ReadBytes('\n')
		gotAction <- strings.TrimSpace(string(line))
		conn.Write([]byte(`{"event":"done"}` + "\n"))
	})
	defer ln.Close()

	conn, r := e.openSetup("signal")
	defer conn.Close()
	if ev := e.readEvent(r); ev["event"] != "done" {
		t.Fatalf("want done, got %v", ev)
	}
	select {
	case a := <-gotAction:
		if a != `{"action":"link"}` {
			t.Fatalf("want first line {\"action\":\"link\"}, got %q", a)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("helper never received the action line")
	}
}

// A panel reply line ({"value":...}) is forwarded verbatim to the helper.
func TestSetupPanelReplyReachesHelper(t *testing.T) {
	e := newTestEnv(t, 0)
	e.enableMail()
	gotReply := make(chan string, 1)
	ln := e.startSetupHelper("mail", func(conn net.Conn) {
		defer conn.Close()
		br := bufio.NewReader(conn)
		br.ReadBytes('\n') // action line
		conn.Write([]byte(`{"event":"text-field","field":"email","label":"Account email"}` + "\n"))
		line, _ := br.ReadBytes('\n')
		gotReply <- strings.TrimSpace(string(line))
		conn.Write([]byte(`{"event":"done"}` + "\n"))
	})
	defer ln.Close()

	conn, r := e.openSetup("mail")
	defer conn.Close()
	ev := e.readEvent(r)
	if ev["event"] != "text-field" || ev["field"] != "email" || ev["label"] != "Account email" {
		t.Fatalf("want text-field relayed verbatim, got %v", ev)
	}
	if _, err := conn.Write([]byte(`{"value":"me@proton.me"}` + "\n")); err != nil {
		t.Fatal(err)
	}
	if ev2 := e.readEvent(r); ev2["event"] != "done" {
		t.Fatalf("want done after reply, got %v", ev2)
	}
	select {
	case rep := <-gotReply:
		if rep != `{"value":"me@proton.me"}` {
			t.Fatalf("want reply forwarded verbatim, got %q", rep)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("helper never received the panel reply")
	}
}

// A set-field event is broker-consumed: executed via setField (store updated)
// and NEVER relayed — the panel sees the surrounding events but not the value.
func TestSetupSetFieldIntercepted(t *testing.T) {
	e := newTestEnv(t, 0)
	e.enableMail()
	ln := e.startSetupHelper("mail", func(conn net.Conn) {
		defer conn.Close()
		br := bufio.NewReader(conn)
		br.ReadBytes('\n') // action line
		conn.Write([]byte(`{"event":"message","text":"linking"}` + "\n"))
		conn.Write([]byte(`{"event":"set-field","profile":"default","field":"email","value":"me@proton.me"}` + "\n"))
		conn.Write([]byte(`{"event":"done"}` + "\n"))
	})
	defer ln.Close()

	conn, r := e.openSetup("mail")
	defer conn.Close()
	if m1 := e.readEvent(r); m1["event"] != "message" {
		t.Fatalf("want message, got %v", m1)
	}
	// The very next event the panel sees must be done — the set-field line and
	// its value must never be relayed.
	m2 := e.readEvent(r)
	if m2["event"] == "set-field" || m2["value"] != nil {
		t.Fatalf("set-field/value must not reach the panel, got %v", m2)
	}
	if m2["event"] != "done" {
		t.Fatalf("want done after the intercepted set-field, got %v", m2)
	}
	// The store was updated by the intercepted set-field.
	info := e.infoByName("mail")
	p := profileByName(info, "default")
	if p == nil {
		t.Fatal("intercepted set-field must have created the profile")
	}
	cfg, _ := p["config"].(map[string]any)
	if cfg["email"] != "me@proton.me" {
		t.Fatalf("want stored email me@proton.me, got %v", cfg)
	}
}

// A set-field the store rejects fails the flow closed: the broker synthesises
// an error event to the panel and aborts (no later helper event is relayed).
func TestSetupSetFieldFailureAborts(t *testing.T) {
	e := newTestEnv(t, 0)
	e.enableMail()
	ln := e.startSetupHelper("mail", func(conn net.Conn) {
		defer conn.Close()
		br := bufio.NewReader(conn)
		br.ReadBytes('\n') // action line
		conn.Write([]byte(`{"event":"set-field","profile":"default","field":"nope","value":"x"}` + "\n"))
		conn.Write([]byte(`{"event":"done"}` + "\n"))
	})
	defer ln.Close()

	conn, r := e.openSetup("mail")
	defer conn.Close()
	ev := e.readEvent(r)
	if ev["event"] != "error" || !strings.Contains(ev["error"].(string), "field") {
		t.Fatalf("want a synthesised set-field error, got %v", ev)
	}
	// Abort: the helper's done must not be relayed; the connection closes.
	if _, err := r.ReadBytes('\n'); err == nil {
		t.Fatal("broker must close after aborting on a set-field failure")
	}
}

// op:"remove-profile" on a setup-bearing integration drives the helper in
// remove mode (action line {"action":"remove","profile":p}) and only then
// removes the store row.
func TestRemoveProfileDrivesHelper(t *testing.T) {
	e := newTestEnv(t, 0)
	e.enableMail()
	e.setField("mail", "default", "email", "me@proton.me")
	gotAction := make(chan string, 1)
	ln := e.startSetupHelper("mail", func(conn net.Conn) {
		defer conn.Close()
		line, _ := bufio.NewReader(conn).ReadBytes('\n')
		gotAction <- strings.TrimSpace(string(line))
		conn.Write([]byte(`{"event":"done"}` + "\n"))
	})
	defer ln.Close()

	e.wantOK(e.roundtrip(Request{Op: "remove-profile", Integration: "mail", Profile: "default"}))
	select {
	case a := <-gotAction:
		if a != `{"action":"remove","profile":"default"}` {
			t.Fatalf("want remove action line, got %q", a)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("helper never received the remove action line")
	}
	if info := e.infoByName("mail"); profileByName(info, "default") != nil {
		t.Fatal("row must be removed after the helper reports done")
	}
}

// A helper error during the remove dispatch aborts before the store write: the
// row survives and the Ack carries the helper's error text.
func TestRemoveProfileHelperErrorLeavesRow(t *testing.T) {
	e := newTestEnv(t, 0)
	e.enableMail()
	e.setField("mail", "default", "email", "me@proton.me")
	ln := e.startSetupHelper("mail", func(conn net.Conn) {
		defer conn.Close()
		bufio.NewReader(conn).ReadBytes('\n') // action line
		conn.Write([]byte(`{"event":"error","error":"bridge logout failed"}` + "\n"))
	})
	defer ln.Close()

	e.wantError(e.roundtrip(Request{Op: "remove-profile", Integration: "mail", Profile: "default"}), "bridge logout failed")
	if info := e.infoByName("mail"); profileByName(info, "default") == nil {
		t.Fatal("row must survive a helper error during remove")
	}
}

// setupPark units are stopped before the setup units start and started again on
// the way out (after the post-done try-restart), in that order.
func TestSetupParkUnitsStoppedStarted(t *testing.T) {
	e := newTestEnv(t, 0)
	e.enableMail()
	ln := e.startSetupHelper("mail", func(conn net.Conn) {
		defer conn.Close()
		bufio.NewReader(conn).ReadBytes('\n') // action line
		conn.Write([]byte(`{"event":"done"}` + "\n"))
	})
	defer ln.Close()

	conn, r := e.openSetup("mail")
	defer conn.Close()
	if ev := e.readEvent(r); ev["event"] != "done" {
		t.Fatalf("want done, got %v", ev)
	}
	want := []string{
		"stop spaces-proton-bridge.service",
		"start spaces-integration-mail-setup.socket",
		"try-restart spaces-integration-mail.service",
		"stop spaces-integration-mail-setup.service spaces-integration-mail-setup.socket",
		"start spaces-proton-bridge.service",
	}
	calls := e.waitSystemctl(func(c []string) bool { return len(c) >= 5 })
	if !equalStrings(calls, want) {
		t.Fatalf("want park/unpark order %v, got %v", want, calls)
	}
}

// writeManaged drops managed.json into the injected managedRoot with a
// strictly-increasing mtime, so the broker's mtime-keyed cache always observes
// the change even when two writes land within one fs mtime tick.
func (e *testEnv) writeManaged(body string) {
	e.t.Helper()
	path := filepath.Join(e.managedRoot, "managed.json")
	var prev time.Time
	if fi, err := os.Stat(path); err == nil {
		prev = fi.ModTime()
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		e.t.Fatal(err)
	}
	next := time.Now()
	if !prev.IsZero() {
		next = prev.Add(time.Second)
	}
	if err := os.Chtimes(path, next, next); err != nil {
		e.t.Fatal(err)
	}
}

// writeManagedSecret stages a managed secret credential file so its stat-based
// set-status reads true (§10.5).
func (e *testEnv) writeManagedSecret(integration, profile, field, value string) {
	e.t.Helper()
	dir := filepath.Join(e.managedRoot, integration)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		e.t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "secret-"+profile+"-"+field), []byte(value), 0o644); err != nil {
		e.t.Fatal(err)
	}
}

func boolField(m map[string]any, key string) bool {
	v, _ := m[key].(bool)
	return v
}

// A managed profile REPLACES a same-named user profile in the reply (shadow):
// config comes from managed.json, the flags mark it managed+shadowed, and the
// integration's Nix enable verdict surfaces as enabledByNix. A user-only
// profile passes through unmanaged.
func TestListOverlaysManagedProfile(t *testing.T) {
	e := newTestEnv(t, 0)
	e.setField("github", "corp", "owner", "userowned")
	e.setField("github", "corp", "token", "user-tok")
	e.setField("github", "personal", "token", "p")

	e.writeManaged(`{
	  "integrations": {
	    "github": {
	      "enable": true,
	      "profiles": {
	        "corp": { "config": {"owner": "acme"}, "secrets": ["token"] }
	      }
	    }
	  }
	}`)
	e.writeManagedSecret("github", "corp", "token", "sealed")

	gh := e.githubInfo()
	if gh["enabledByNix"] != true {
		t.Fatalf("want enabledByNix=true, got %v", gh["enabledByNix"])
	}
	corp := profileByName(gh, "corp")
	if corp == nil {
		t.Fatal("managed corp profile missing")
	}
	if !boolField(corp, "managed") {
		t.Fatalf("want managed=true, got %v", corp)
	}
	if !boolField(corp, "shadowed") {
		t.Fatalf("want shadowed=true (user corp existed), got %v", corp)
	}
	if got := corp["config"].(map[string]any)["owner"]; got != "acme" {
		t.Fatalf("managed config must win: want owner=acme, got %v", got)
	}
	if corp["secrets"].(map[string]any)["token"] != true {
		t.Fatalf("staged managed secret must read set, got %v", corp["secrets"])
	}
	if corp["complete"] != true {
		t.Fatalf("managed profile with required secret staged must be complete, got %v", corp)
	}
	if personal := profileByName(gh, "personal"); personal == nil || boolField(personal, "managed") || boolField(personal, "shadowed") {
		t.Fatalf("user-only profile must pass through unmanaged, got %v", personal)
	}
}

// A managed profile with no same-named user twin is managed but NOT shadowed,
// and an integration with no enable key reports no enabledByNix verdict.
func TestListManagedOnlyProfileNotShadowed(t *testing.T) {
	e := newTestEnv(t, 0)
	e.writeManaged(`{"integrations":{"github":{"profiles":{"solo":{"config":{"owner":"x"},"secrets":["token"]}}}}}`)
	e.writeManagedSecret("github", "solo", "token", "s")
	gh := e.githubInfo()
	if gh["enabledByNix"] != nil {
		t.Fatalf("no enable key must leave enabledByNix absent, got %v", gh["enabledByNix"])
	}
	solo := profileByName(gh, "solo")
	if solo == nil || !boolField(solo, "managed") {
		t.Fatalf("want managed solo profile, got %v", solo)
	}
	if boolField(solo, "shadowed") {
		t.Fatalf("managed-only profile must not be shadowed, got %v", solo)
	}
}

// A managed secret's set-status is the stat of its staged file: unstaged reads
// unset and (for a required secret) leaves the profile incomplete.
func TestListManagedSecretSetStatus(t *testing.T) {
	e := newTestEnv(t, 0)
	e.writeManaged(`{"integrations":{"github":{"profiles":{"corp":{"config":{"owner":"a"},"secrets":["token"]}}}}}`)
	corp := profileByName(e.githubInfo(), "corp")
	if corp["secrets"].(map[string]any)["token"] != false {
		t.Fatalf("unstaged managed secret must read unset, got %v", corp["secrets"])
	}
	if corp["complete"] != false {
		t.Fatalf("profile missing required secret must be incomplete, got %v", corp)
	}
}

// set-field naming a managed profile is rejected with the stable message; a
// non-managed profile name is still writable.
func TestSetFieldRejectedOnManagedProfile(t *testing.T) {
	e := newTestEnv(t, 0)
	e.writeManaged(`{"integrations":{"github":{"profiles":{"corp":{"config":{},"secrets":[]}}}}}`)
	e.wantError(e.roundtrip(Request{Op: "set-field", Integration: "github", Profile: "corp", Field: "owner", Value: "x"}),
		"profile 'corp' is managed by system configuration")
	e.wantOK(e.roundtrip(Request{Op: "set-field", Integration: "github", Profile: "work", Field: "token", Value: "x"}))
}

// remove-profile naming a managed profile is rejected (the shadowed user copy is
// untouched; the managed row cannot be removed at runtime).
func TestRemoveProfileRejectedOnManagedProfile(t *testing.T) {
	e := newTestEnv(t, 0)
	e.writeManaged(`{"integrations":{"github":{"profiles":{"corp":{"config":{},"secrets":[]}}}}}`)
	e.wantError(e.roundtrip(Request{Op: "remove-profile", Integration: "github", Profile: "corp"}),
		"profile 'corp' is managed by system configuration")
}

// enable/disable on an integration carrying a Nix enable verdict are rejected;
// a rejected enable never touches systemctl.
func TestEnableRejectedByVerdict(t *testing.T) {
	e := newTestEnv(t, 0)
	e.writeManaged(`{"integrations":{"github":{"enable":true}}}`)
	e.wantError(e.roundtrip(Request{Op: "enable", Integration: "github"}),
		"integration 'github' enable state is managed by system configuration")
	if calls := e.systemctlCalls(); calls != nil {
		t.Fatalf("rejected enable must not touch systemctl, got %v", calls)
	}
}

func TestDisableRejectedByVerdict(t *testing.T) {
	e := newTestEnv(t, 0)
	e.writeManaged(`{"integrations":{"github":{"enable":false}}}`)
	e.wantError(e.roundtrip(Request{Op: "disable", Integration: "github"}),
		"integration 'github' enable state is managed by system configuration")
}

// A managed complete profile counts toward the enable-completeness gate: with no
// user profile at all, enable is blocked until the managed profile's required
// secret is staged, then succeeds off the managed profile alone.
func TestEnableGatedByManagedCompleteProfile(t *testing.T) {
	e := newTestEnv(t, 0)
	e.writeManaged(`{"integrations":{"github":{"profiles":{"corp":{"config":{"owner":"a"},"secrets":["token"]}}}}}`)
	e.wantError(e.roundtrip(Request{Op: "enable", Integration: "github"}), "no complete profile")
	e.writeManagedSecret("github", "corp", "token", "s")
	e.wantOK(e.roundtrip(Request{Op: "enable", Integration: "github"}))
	if !e.enabledState().Integrations["github"].Enabled {
		t.Fatal("want github enabled via managed complete profile")
	}
}

// reconcile folds a verdict true into enabled.json with source nix and starts
// the socket.
func TestReconcileFoldsVerdictTrue(t *testing.T) {
	e := newTestEnv(t, 0)
	e.writeManaged(`{"integrations":{"github":{"enable":true}}}`)
	e.srv.ReconcileEnabled()
	if !slices.Contains(e.systemctlCalls(), "start spaces-integration-github.socket") {
		t.Fatalf("verdict true must start the socket, got %v", e.systemctlCalls())
	}
	st := e.enabledState().Integrations["github"]
	if !st.Enabled || st.Source != sourceNix {
		t.Fatalf("want github {enabled:true, source:nix}, got %+v", st)
	}
}

// reconcile folds a verdict false into enabled.json with source nix and STOPS
// the unit — a Nix false overrides a pre-existing user enable.
func TestReconcileNixFalseOverridesUserEnable(t *testing.T) {
	e := newTestEnv(t, 0)
	e.writeEnabled(EnabledState{Integrations: map[string]IntegrationState{"github": {Enabled: true}}})
	e.writeManaged(`{"integrations":{"github":{"enable":false}}}`)
	e.srv.ReconcileEnabled()
	if !slices.Contains(e.systemctlCalls(), "stop spaces-integration-github.socket spaces-integration-github.service") {
		t.Fatalf("nix false must stop the unit, got %v", e.systemctlCalls())
	}
	st := e.enabledState().Integrations["github"]
	if st.Enabled || st.Source != sourceNix {
		t.Fatalf("want github {enabled:false, source:nix}, got %+v", st)
	}
}

// When a Nix verdict disappears, reconcile drops the source-nix entry (restoring
// user autonomy) and try-restarts the affected unit.
func TestReconcileDropsRemovedVerdict(t *testing.T) {
	e := newTestEnv(t, 0)
	e.writeManaged(`{"integrations":{"github":{"enable":true}}}`)
	e.srv.ReconcileEnabled()
	if st := e.enabledState().Integrations["github"]; st.Source != sourceNix {
		t.Fatalf("setup: want source nix, got %+v", st)
	}
	e.writeManaged(`{"integrations":{}}`)
	e.srv.reconcileManaged()
	if _, ok := e.enabledState().Integrations["github"]; ok {
		t.Fatalf("source-nix entry must be dropped when the verdict disappears")
	}
	if !slices.Contains(e.systemctlCalls(), "try-restart spaces-integration-github.service") {
		t.Fatalf("removed verdict must try-restart the affected unit, got %v", e.systemctlCalls())
	}
}

// A managed section content change (here a config value) triggers re-reconcile
// and a try-restart of the changed unit.
func TestManagedContentChangeReReconciles(t *testing.T) {
	e := newTestEnv(t, 0)
	e.writeManaged(`{"integrations":{"github":{"enable":true,"profiles":{"corp":{"config":{"owner":"a"},"secrets":["token"]}}}}}`)
	e.srv.ReconcileEnabled()
	before := len(e.systemctlCalls())
	e.writeManaged(`{"integrations":{"github":{"enable":true,"profiles":{"corp":{"config":{"owner":"b"},"secrets":["token"]}}}}}`)
	e.srv.reconcileManaged()
	after := e.systemctlCalls()
	if len(after) <= before {
		t.Fatalf("content change must re-reconcile, before=%d after=%v", before, after)
	}
	if !slices.Contains(after, "try-restart spaces-integration-github.service") {
		t.Fatalf("content change must try-restart the changed unit, got %v", after)
	}
}

// Rotating one managed secret changes only its hash inside managed.json (the
// sections are otherwise identical). Reconcile must try-restart exactly the
// affected integration's unit — no other integration is touched.
func TestSecretRotationRestartsOnlyAffectedIntegration(t *testing.T) {
	e := newTestEnv(t, 0)
	e.writeManaged(`{"integrations":{
	  "github":{"profiles":{"corp":{"config":{"owner":"a"},"secrets":["token"],"secretHashes":{"token":"hash-one"}}}},
	  "signal":{"profiles":{"main":{"config":{},"secrets":["key"],"secretHashes":{"key":"sig-hash"}}}}}}`)
	e.srv.ReconcileEnabled()
	before := len(e.systemctlCalls())
	e.writeManaged(`{"integrations":{
	  "github":{"profiles":{"corp":{"config":{"owner":"a"},"secrets":["token"],"secretHashes":{"token":"hash-two"}}}},
	  "signal":{"profiles":{"main":{"config":{},"secrets":["key"],"secretHashes":{"key":"sig-hash"}}}}}}`)
	e.srv.reconcileManaged()
	after := e.systemctlCalls()[before:]
	if !slices.Contains(after, "try-restart spaces-integration-github.service") {
		t.Fatalf("rotated secret hash must try-restart its integration, got %v", after)
	}
	for _, c := range after {
		if c != "try-restart spaces-integration-github.service" {
			t.Fatalf("rotation must touch ONLY the affected integration, got %v", after)
		}
	}
}

// A byte-identical managed.json rewrite (fresh mtime — e.g. a deploy that
// changed nothing but still ran the stager pre-content-awareness, or a manual
// touch) triggers nothing: no restarts without a real section change.
func TestReconcileManagedNoopOnByteIdenticalRewrite(t *testing.T) {
	e := newTestEnv(t, 0)
	body := `{"integrations":{"github":{"enable":true,"profiles":{"corp":{"config":{"owner":"a"},"secrets":["token"],"secretHashes":{"token":"h1"}}}}}}`
	e.writeManaged(body)
	e.srv.ReconcileEnabled()
	n := len(e.systemctlCalls())
	e.writeManaged(body)
	e.srv.reconcileManaged()
	if got := len(e.systemctlCalls()); got != n {
		t.Fatalf("unchanged managed.json must not trigger systemctl, before=%d after=%d", n, got)
	}
}

// An RPC (list) landing between a managed.json rewrite and the reconcile tick
// refreshes the mtime-keyed cache, so a prev-cache-vs-current comparison sees
// no change. reconcileManaged must compare against its own last-RECONCILED
// snapshot: the removed verdict still folds and the changed unit still
// try-restarts.
func TestReconcileManagedNotSwallowedByRPCCacheRefresh(t *testing.T) {
	e := newTestEnv(t, 0)
	e.writeManaged(`{"integrations":{"github":{"enable":true}}}`)
	e.srv.ReconcileEnabled()
	e.writeManaged(`{"integrations":{}}`)
	e.wantOK(e.roundtrip(Request{Op: "list"})) // refreshes the cache before the tick
	e.srv.reconcileManaged()
	if _, ok := e.enabledState().Integrations["github"]; ok {
		t.Fatalf("verdict removal must fold into enabled.json even after an RPC refreshed the cache")
	}
	if !slices.Contains(e.systemctlCalls(), "try-restart spaces-integration-github.service") {
		t.Fatalf("changed integration must try-restart, got %v", e.systemctlCalls())
	}
}

// op=setup forwards its action line to the helper verbatim; only ""/"link" is
// a legal setup action. Anything else (a raw "remove" would bypass the
// managed-profile guard and remove-profile's vendor/store atomicity) must be
// rejected with a setup-stream error event before any unit starts.
func TestSetupRejectsNonLinkAction(t *testing.T) {
	e := newTestEnv(t, 0)
	e.writeDef("signal", signalSetupDef)
	conn, err := net.Dial("unix", e.sock)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	req, err := json.Marshal(Request{Op: "setup", Integration: "signal", Action: "remove"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Write(append(req, '\n')); err != nil {
		t.Fatal(err)
	}
	ev := e.readEvent(bufio.NewReader(conn))
	if ev["event"] != "error" || !strings.Contains(ev["error"].(string), "action") {
		t.Fatalf("want an invalid-action error event, got %v", ev)
	}
	if calls := e.systemctlCalls(); calls != nil {
		t.Fatalf("a rejected action must not start setup units, got %v", calls)
	}
}

// A malformed managed.json (or a transient read failure) must NOT read as "no
// Nix opinion anywhere": that would delete every source-nix entry and stop
// nix-enabled units. The broker keeps the last-good state until a parseable
// file (or ENOENT) shows up.
func TestCorruptManagedKeepsLastGoodState(t *testing.T) {
	e := newTestEnv(t, 0)
	e.writeManaged(`{"integrations":{"github":{"enable":true}}}`)
	e.srv.ReconcileEnabled()
	n := len(e.systemctlCalls())
	e.writeManaged(`{"integrations": THIS IS NOT JSON`)
	e.srv.reconcileManaged()
	st := e.enabledState().Integrations["github"]
	if !st.Enabled || st.Source != sourceNix {
		t.Fatalf("corrupt managed.json must keep the last-good verdict, got %+v", st)
	}
	for _, c := range e.systemctlCalls()[n:] {
		if strings.HasPrefix(c, "stop ") {
			t.Fatalf("corrupt managed.json must not stop units, got %v", e.systemctlCalls())
		}
	}
}

// An ABSENT managed.json is authoritative (no Nix opinion anywhere): deleting
// the file still reverts source-nix entries — only errors keep the last-good
// state.
func TestManagedFileDeletedRevertsNixEntries(t *testing.T) {
	e := newTestEnv(t, 0)
	e.writeManaged(`{"integrations":{"github":{"enable":true}}}`)
	e.srv.ReconcileEnabled()
	if err := os.Remove(filepath.Join(e.managedRoot, "managed.json")); err != nil {
		t.Fatal(err)
	}
	e.srv.reconcileManaged()
	if _, ok := e.enabledState().Integrations["github"]; ok {
		t.Fatalf("deleting managed.json must revert the source-nix entry")
	}
}

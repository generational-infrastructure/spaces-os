// spaces-apps — operator CLI for the app-coordinator daemon.
//
// Wraps the line-JSON protocol the coordinator speaks on its Unix
// socket. Replaces the `echo '{"op":"…"}' | socat - UNIX-CONNECT:…`
// dance with named subcommands and human-readable output.
//
// Commands:
//   spaces-apps list                List every app in the manifest
//   spaces-apps info <name>         Show the manifest entry for one app
//   spaces-apps running             List currently running app units
//   spaces-apps kill <unit>         Stop a running unit (must look like an app-*.service)
//   spaces-apps spawn <name> [args] Launch an app via the coordinator
//   spaces-apps audit [-n N]        Show the last N AUDIT lines from the coordinator's journal
//   spaces-apps spawns [-n N]       Show recent launcher app-run events (effective permission sets)
//   spaces-apps cleanup [--apply]   Find (and optionally remove) grant files for apps that no longer exist
//   spaces-apps logs <unit> [-f]    Tail the journal for one running app unit (-f to follow)
//   spaces-apps verify              Diagnose the coordinator wiring (socket, service, manifest, launchers)
//   spaces-apps permissions         Print the permission catalogue (name → description)
//   spaces-apps grants <name>       Show runtime grants for one app
//   spaces-apps grant <name> <perm> Add a runtime grant to one app
//   spaces-apps revoke <name> <perm> Remove a runtime grant from one app
//
// Runtime grants are stored at $XDG_STATE_HOME/spaces/grants/<appId>.json
// (default $HOME/.local/state/spaces/grants/<appId>.json). The launcher
// does not yet read them — this is the persistence + CLI surface for the
// future grant integration; once the launcher is refactored it will
// union runtime grants with manifest grants at exec time.
//
// info accepts --describe to show each permission's description
// next to its name (instead of a bare list).
//
// Add `--json` to any command to get the raw coordinator reply
// (suitable for `jq`); the default output is human-readable.
//
// Socket resolution: `$APP_COORDINATOR_SOCKET` if set, otherwise
// `$XDG_RUNTIME_DIR/spaces-app-coordinator.sock`.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"os/exec"
	"sort"
	"strings"
)

// Mirrors the coordinator's protocol.go. Duplicated here rather
// than imported so spaces-apps stays a single-module Go package
// with no replace-directive plumbing.

type request struct {
	Op   string   `json:"op"`
	App  string   `json:"app,omitempty"`
	Args []string `json:"args,omitempty"`
	Unit string   `json:"unit,omitempty"`
}

type manifestApp struct {
	LauncherPath string   `json:"launcherPath"`
	AllowedArgs  []string `json:"allowedArgs"`
	SpawnableBy  []string `json:"spawnableBy"`
	AppId        string   `json:"appId,omitempty"`
	Granted      []string `json:"granted,omitempty"`
	Requested    []string `json:"requested,omitempty"`
	Denied       []string `json:"denied,omitempty"`
}

type runningApp struct {
	App  string `json:"app"`
	Unit string `json:"unit"`
}

type reply struct {
	Op      string       `json:"op"`
	Apps    []string     `json:"apps,omitempty"`
	Running []runningApp `json:"running,omitempty"`
	Unit    string       `json:"unit,omitempty"`
	Info    *manifestApp `json:"info,omitempty"`
	Error   string       `json:"error,omitempty"`
}

func usage() {
	fmt.Fprint(os.Stderr, `Usage: spaces-apps [FLAGS] COMMAND [ARGS...]

All flags must come BEFORE the command name (Go convention):
  spaces-apps --describe info browser    OK
  spaces-apps info --describe browser    NOT parsed

Commands:
  list                List apps in the manifest
  info NAME           Show the manifest entry for one app
  running             List currently running app units
  kill UNIT           Stop a running unit (must be an app-*.service)
  spawn NAME [ARGS]   Spawn an app via the coordinator
  logs UNIT           Tail the journal for one running app unit
  audit               Show recent AUDIT lines from the coordinator's journal
  spawns              Show recent launcher app-run events (effective permission sets)
  cleanup [--apply]   List (or remove) grant files for apps no longer in the manifest
  verify              Diagnose the coordinator wiring
  permissions         Print the permission catalogue (name → description)

Flags:
  --json              Output raw JSON (for piping to jq).
  --describe          info: show each permission's description.
  -f                  logs: follow the journal (like journalctl -f).
  -n N                audit: max number of lines to show (default 50).

Socket location:
  $APP_COORDINATOR_SOCKET if set,
  otherwise $XDG_RUNTIME_DIR/spaces-app-coordinator.sock.
`)
}

func main() {
	flag.Usage = usage
	jsonOut := flag.Bool("json", false, "raw JSON output")
	auditN := flag.Int("n", 50, "audit: max number of lines to show")
	follow := flag.Bool("f", false, "logs: follow the journal (like journalctl -f)")
	describe := flag.Bool("describe", false, "info: show description next to each permission")
	apply := flag.Bool("apply", false, "cleanup: actually remove stale grant files (default: dry-run)")
	flag.Parse()

	if flag.NArg() == 0 {
		usage()
		os.Exit(2)
	}

	cmd := flag.Arg(0)
	args := flag.Args()[1:]

	// `audit` and `logs` are local — they read journald rather than
	// the coordinator socket. Branch early so the rest of the flow
	// doesn't try to build a meaningless Request for them.
	if cmd == "audit" {
		if err := runAudit(*auditN, *jsonOut); err != nil {
			fmt.Fprintf(os.Stderr, "spaces-apps: %v\n", err)
			os.Exit(1)
		}
		return
	}
	if cmd == "spawns" {
		if err := runSpawns(*auditN, *jsonOut); err != nil {
			fmt.Fprintf(os.Stderr, "spaces-apps: %v\n", err)
			os.Exit(1)
		}
		return
	}
	if cmd == "cleanup" {
		if err := runCleanup(*apply); err != nil {
			fmt.Fprintf(os.Stderr, "spaces-apps: %v\n", err)
			os.Exit(1)
		}
		return
	}
	if cmd == "logs" {
		if len(args) != 1 {
			fmt.Fprintln(os.Stderr, "spaces-apps: logs: expected one unit name")
			os.Exit(2)
		}
		if err := runLogs(args[0], *follow); err != nil {
			fmt.Fprintf(os.Stderr, "spaces-apps: %v\n", err)
			os.Exit(1)
		}
		return
	}
	if cmd == "verify" {
		if err := runVerify(); err != nil {
			os.Exit(1)
		}
		return
	}
	if cmd == "permissions" {
		if err := runPermissions(*jsonOut); err != nil {
			fmt.Fprintf(os.Stderr, "spaces-apps: %v\n", err)
			os.Exit(1)
		}
		return
	}
	if cmd == "grants" || cmd == "grant" || cmd == "revoke" {
		if err := runGrants(cmd, args, *jsonOut); err != nil {
			fmt.Fprintf(os.Stderr, "spaces-apps: %v\n", err)
			os.Exit(1)
		}
		return
	}

	req, err := buildRequest(cmd, args)
	if err != nil {
		fmt.Fprintf(os.Stderr, "spaces-apps: %v\n", err)
		os.Exit(2)
	}

	rep, raw, err := call(req)
	if err != nil {
		fmt.Fprintf(os.Stderr, "spaces-apps: %v\n", err)
		os.Exit(1)
	}

	if *jsonOut {
		os.Stdout.Write(raw)
		if len(raw) > 0 && raw[len(raw)-1] != '\n' {
			fmt.Println()
		}
	} else {
		render(cmd, rep, *describe)
	}
	if rep.Op == "error" {
		os.Exit(1)
	}
}

func buildRequest(cmd string, args []string) (request, error) {
	switch cmd {
	case "list":
		return request{Op: "list"}, nil
	case "running":
		return request{Op: "running"}, nil
	case "info":
		if len(args) != 1 {
			return request{}, fmt.Errorf("info: expected one app name")
		}
		return request{Op: "info", App: args[0]}, nil
	case "kill":
		if len(args) != 1 {
			return request{}, fmt.Errorf("kill: expected one unit name")
		}
		return request{Op: "kill", Unit: args[0]}, nil
	case "spawn":
		if len(args) < 1 {
			return request{}, fmt.Errorf("spawn: expected an app name (and optionally args)")
		}
		return request{Op: "spawn", App: args[0], Args: args[1:]}, nil
	default:
		return request{}, fmt.Errorf("unknown command: %q (try 'spaces-apps' for usage)", cmd)
	}
}

func socketPath() (string, error) {
	if p := os.Getenv("APP_COORDINATOR_SOCKET"); p != "" {
		return p, nil
	}
	runtimeDir := os.Getenv("XDG_RUNTIME_DIR")
	if runtimeDir == "" {
		return "", fmt.Errorf("XDG_RUNTIME_DIR not set and APP_COORDINATOR_SOCKET not given")
	}
	return runtimeDir + "/spaces-app-coordinator.sock", nil
}

// call sends one request, reads one reply, returns both parsed and
// raw forms. Raw bytes are needed for --json mode so the user gets
// exactly what the coordinator wrote (including any new fields this
// CLI version might not know about).
func call(req request) (reply, []byte, error) {
	sock, err := socketPath()
	if err != nil {
		return reply{}, nil, err
	}
	conn, err := net.Dial("unix", sock)
	if err != nil {
		return reply{}, nil, fmt.Errorf("connect %s: %w", sock, err)
	}
	defer conn.Close()

	if err := json.NewEncoder(conn).Encode(req); err != nil {
		return reply{}, nil, fmt.Errorf("encode: %w", err)
	}

	// Read everything the coordinator sends (single-line reply but
	// some payloads contain JSON arrays we want intact).
	dec := json.NewDecoder(conn)
	var raw json.RawMessage
	if err := dec.Decode(&raw); err != nil {
		return reply{}, nil, fmt.Errorf("decode: %w", err)
	}
	var rep reply
	if err := json.Unmarshal(raw, &rep); err != nil {
		return reply{}, raw, fmt.Errorf("parse reply: %w", err)
	}
	return rep, raw, nil
}

func render(cmd string, rep reply, describe bool) {
	if rep.Op == "error" {
		fmt.Fprintf(os.Stderr, "error: %s\n", rep.Error)
		return
	}
	switch cmd {
	case "list":
		sort.Strings(rep.Apps)
		for _, a := range rep.Apps {
			fmt.Println(a)
		}
	case "running":
		if len(rep.Running) == 0 {
			fmt.Println("(no app units running)")
			return
		}
		for _, r := range rep.Running {
			fmt.Printf("%-40s  %s\n", r.Unit, r.App)
		}
	case "info":
		renderInfo(rep.Info, describe)
	case "spawn":
		fmt.Printf("ok: %s\n", rep.Unit)
	case "kill":
		fmt.Println("ok")
	}
}

func renderInfo(m *manifestApp, describe bool) {
	if m == nil {
		fmt.Println("(no info returned)")
		return
	}
	var descriptions map[string]string
	if describe {
		descriptions, _ = readPermissionDescriptions()
	}
	fmt.Printf("launcher:    %s\n", m.LauncherPath)
	printPermissionList("granted:    ", m.Granted, descriptions)
	printPermissionList("requested:  ", m.Requested, descriptions)
	printPermissionList("denied:     ", m.Denied, descriptions)
	printList("allowedArgs:", m.AllowedArgs)
	printList("spawnableBy:", m.SpawnableBy)
}

func printList(label string, items []string) {
	if len(items) == 0 {
		fmt.Printf("%s (none)\n", label)
		return
	}
	fmt.Printf("%s %s\n", label, strings.Join(items, ", "))
}

// printPermissionList prints either a comma-separated list (when
// descriptions is nil — the default `info` mode) or one permission
// per line with its description (when --describe was passed).
func printPermissionList(label string, items []string, descriptions map[string]string) {
	if len(items) == 0 {
		fmt.Printf("%s (none)\n", label)
		return
	}
	if descriptions == nil {
		fmt.Printf("%s %s\n", label, strings.Join(items, ", "))
		return
	}
	fmt.Printf("%s\n", label)
	for _, item := range items {
		desc := descriptions[item]
		if desc == "" {
			desc = "(no description)"
		}
		fmt.Printf("  %-32s  %s\n", item, desc)
	}
}

const permissionsPath = "/etc/spaces/permissions.json"

func readPermissionDescriptions() (map[string]string, error) {
	data, err := os.ReadFile(permissionsPath)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", permissionsPath, err)
	}
	var out map[string]string
	if err := json.Unmarshal(data, &out); err != nil {
		return nil, fmt.Errorf("parse %s: %w", permissionsPath, err)
	}
	return out, nil
}

// runPermissions prints the catalogue. Default rendering is one
// `name → description` per line, sorted. With --json the raw file
// contents (a JSON object) is written through unchanged.
func runPermissions(jsonOut bool) error {
	if jsonOut {
		data, err := os.ReadFile(permissionsPath)
		if err != nil {
			return fmt.Errorf("read %s: %w", permissionsPath, err)
		}
		os.Stdout.Write(data)
		if len(data) > 0 && data[len(data)-1] != '\n' {
			fmt.Println()
		}
		return nil
	}
	descriptions, err := readPermissionDescriptions()
	if err != nil {
		return err
	}
	names := make([]string, 0, len(descriptions))
	for name := range descriptions {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		fmt.Printf("%-40s  %s\n", name, descriptions[name])
	}
	return nil
}

// runAudit reads recent AUDIT lines from the coordinator's journal.
// Pure read-only — no socket connection. Shells out to journalctl
// because no Go stdlib reads sd-journal natively; the coordinator
// runs as a user systemd service so `journalctl --user -u
// spaces-app-coordinator.service` is the right query.
//
// `n` caps the number of AUDIT lines shown (after filtering); we
// pull `n*4` raw journal lines and grep down to give the kernel a
// chance to include enough AUDIT entries in the window.
//
// With `jsonOut`, lines are passed through verbatim (one
// JSON object per line, suitable for `jq -s '.'`). Otherwise each
// line is pretty-rendered as `TIMESTAMP CALLER OP[/result] APP …`.
func runAudit(n int, jsonOut bool) error {
	if n <= 0 {
		return fmt.Errorf("audit: -n must be positive")
	}
	cmd := exec.Command(
		"journalctl",
		"--user",
		"-u", "spaces-app-coordinator.service",
		"-o", "cat",
		"-n", fmt.Sprintf("%d", n*4),
		"--no-pager",
	)
	out, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("journalctl: %w", err)
	}
	var lines []string
	for _, line := range strings.Split(string(out), "\n") {
		if strings.HasPrefix(line, "AUDIT ") {
			lines = append(lines, strings.TrimPrefix(line, "AUDIT "))
		}
	}
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	if len(lines) == 0 {
		fmt.Fprintln(os.Stderr, "(no AUDIT entries in journal — coordinator may not have served any requests yet)")
		return nil
	}
	if jsonOut {
		for _, line := range lines {
			fmt.Println(line)
		}
		return nil
	}
	for _, line := range lines {
		var entry map[string]any
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			fmt.Println(line)
			continue
		}
		renderAuditEntry(entry)
	}
	return nil
}

// runLogs tails the user-journal for a single app unit. Defensive
// validation: the unit name must start with `app-` and end with
// `.service` so the operator can't accidentally pipe the output of
// some unrelated system unit through here. The work itself is just
// `journalctl --user -u <unit>` (+ `-f` when following).
//
// We exec the journalctl process so SIGINT (Ctrl-C in `-f` mode)
// kills it cleanly rather than us catching the signal and then
// trying to clean up — fewer moving parts.
func runLogs(unit string, follow bool) error {
	if !strings.HasPrefix(unit, "app-") || !strings.HasSuffix(unit, ".service") {
		return fmt.Errorf("logs: unit %q does not look like an app unit (expected app-*.service)", unit)
	}
	argv := []string{
		"journalctl",
		"--user",
		"-u", unit,
		"-o", "cat",
		"--no-pager",
	}
	if follow {
		argv = append(argv, "-f")
	}
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin
	if err := cmd.Run(); err != nil {
		// journalctl exits 1 if there are no entries for the unit;
		// surface that as a clean error rather than just "exit 1".
		if exitErr, ok := err.(*exec.ExitError); ok && exitErr.ExitCode() == 1 {
			return fmt.Errorf("logs: no journal entries for %q (unit may not have run)", unit)
		}
		return fmt.Errorf("journalctl: %w", err)
	}
	return nil
}

// ── Runtime grant store ──────────────────────────────────────────
//
// Grants are persisted at $XDG_STATE_HOME/spaces/grants/<appId>.json
// (default $HOME/.local/state/spaces/grants/<appId>.json). One file
// per app. Format:
//
//   {"version": 1, "granted": ["network", "wayland.virtual-keyboard"]}
//
// The launcher does not yet consume this — the persistence layer
// exists first so the operator can stage grants ahead of the
// launcher refactor. Validation happens here: permissions are
// checked against /etc/spaces/permissions.json, app names against
// the coordinator's manifest.

type grantsFile struct {
	Version int      `json:"version"`
	Granted []string `json:"granted"`
}

func grantsPath(appId string) (string, error) {
	state := os.Getenv("XDG_STATE_HOME")
	if state == "" {
		home := os.Getenv("HOME")
		if home == "" {
			return "", fmt.Errorf("neither XDG_STATE_HOME nor HOME is set")
		}
		state = home + "/.local/state"
	}
	return fmt.Sprintf("%s/spaces/grants/%s.json", state, appId), nil
}

func loadGrants(appId string) (grantsFile, error) {
	path, err := grantsPath(appId)
	if err != nil {
		return grantsFile{}, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return grantsFile{Version: 1}, nil
		}
		return grantsFile{}, fmt.Errorf("read %s: %w", path, err)
	}
	var gf grantsFile
	if err := json.Unmarshal(data, &gf); err != nil {
		return grantsFile{}, fmt.Errorf("parse %s: %w", path, err)
	}
	return gf, nil
}

func saveGrants(appId string, gf grantsFile) error {
	path, err := grantsPath(appId)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(grantsPath_dir(path), 0o700); err != nil {
		return fmt.Errorf("mkdir grants dir: %w", err)
	}
	gf.Version = 1
	data, err := json.MarshalIndent(gf, "", "  ")
	if err != nil {
		return fmt.Errorf("encode: %w", err)
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(data, '\n'), 0o600); err != nil {
		return fmt.Errorf("write %s: %w", tmp, err)
	}
	return os.Rename(tmp, path)
}

func grantsPath_dir(path string) string {
	for i := len(path) - 1; i >= 0; i-- {
		if path[i] == '/' {
			return path[:i]
		}
	}
	return "."
}

// resolveAppId asks the coordinator's info op for the app's
// manifest entry and returns its appId. Falls back to
// `spaces.app.<name>` (the lib's default) if the manifest's appId
// is empty — older coordinator builds may not have published it.
func resolveAppId(name string) (string, error) {
	rep, _, err := call(request{Op: "info", App: name})
	if err != nil {
		return "", err
	}
	if rep.Op == "error" {
		return "", fmt.Errorf("info %s: %s", name, rep.Error)
	}
	if rep.Info != nil && rep.Info.AppId != "" {
		return rep.Info.AppId, nil
	}
	return "spaces.app." + name, nil
}

func runGrants(cmd string, args []string, jsonOut bool) error {
	switch cmd {
	case "grants":
		if len(args) != 1 {
			return fmt.Errorf("grants: expected an app name")
		}
		appId, err := resolveAppId(args[0])
		if err != nil {
			return err
		}
		gf, err := loadGrants(appId)
		if err != nil {
			return err
		}
		if jsonOut {
			data, _ := json.MarshalIndent(gf, "", "  ")
			fmt.Println(string(data))
			return nil
		}
		if len(gf.Granted) == 0 {
			fmt.Println("(no runtime grants)")
			return nil
		}
		sort.Strings(gf.Granted)
		for _, p := range gf.Granted {
			fmt.Println(p)
		}
		return nil

	case "grant", "revoke":
		if len(args) != 2 {
			return fmt.Errorf("%s: expected app name and permission", cmd)
		}
		name, perm := args[0], args[1]
		descriptions, err := readPermissionDescriptions()
		if err != nil {
			return fmt.Errorf("permission catalogue unavailable: %w", err)
		}
		if _, known := descriptions[perm]; !known {
			return fmt.Errorf("%s: unknown permission %q (see `spaces-apps permissions`)", cmd, perm)
		}
		appId, err := resolveAppId(name)
		if err != nil {
			return err
		}
		gf, err := loadGrants(appId)
		if err != nil {
			return err
		}
		switch cmd {
		case "grant":
			if !contains(gf.Granted, perm) {
				gf.Granted = append(gf.Granted, perm)
				sort.Strings(gf.Granted)
			}
		case "revoke":
			gf.Granted = removeString(gf.Granted, perm)
		}
		if err := saveGrants(appId, gf); err != nil {
			return err
		}
		fmt.Printf("ok: %s %s for %s\n", cmd, perm, name)
		return nil
	}
	return fmt.Errorf("internal: unhandled grants command %q", cmd)
}

// runCleanup walks the grants directory and lists (or removes,
// with --apply) any grant file whose appId isn't in the current
// manifest. Stale grants accumulate when apps are renamed or
// removed from `services.spaces.apps` — they're harmless (the
// launcher only reads its own appId's file) but the operator
// should be able to see and reap them.
//
// Dry-run by default: prints what would be removed and an instruction
// to re-run with --apply. Exit code 0 in both modes (presence of
// stale files isn't a failure).
func runCleanup(apply bool) error {
	// Resolve the grants dir.
	state := os.Getenv("XDG_STATE_HOME")
	if state == "" {
		home := os.Getenv("HOME")
		if home == "" {
			return fmt.Errorf("neither XDG_STATE_HOME nor HOME is set")
		}
		state = home + "/.local/state"
	}
	grantsDir := state + "/spaces/grants"

	entries, err := os.ReadDir(grantsDir)
	if err != nil {
		if os.IsNotExist(err) {
			fmt.Println("(grants directory does not exist — nothing to clean)")
			return nil
		}
		return fmt.Errorf("read %s: %w", grantsDir, err)
	}

	// Build the set of valid appIds from the manifest.
	const manifestPath = "/etc/spaces/app-coordinator/manifest.json"
	manifestData, err := os.ReadFile(manifestPath)
	if err != nil {
		return fmt.Errorf("read manifest %s: %w", manifestPath, err)
	}
	var parsed struct {
		Apps map[string]manifestApp `json:"apps"`
	}
	if err := json.Unmarshal(manifestData, &parsed); err != nil {
		return fmt.Errorf("parse manifest: %w", err)
	}
	validAppIds := make(map[string]struct{}, len(parsed.Apps))
	for name, app := range parsed.Apps {
		appId := app.AppId
		if appId == "" {
			appId = "spaces.app." + name
		}
		validAppIds[appId] = struct{}{}
	}

	var stale []string
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		if !strings.HasSuffix(name, ".json") {
			continue
		}
		appId := strings.TrimSuffix(name, ".json")
		if _, ok := validAppIds[appId]; !ok {
			stale = append(stale, name)
		}
	}
	sort.Strings(stale)

	if len(stale) == 0 {
		fmt.Println("no stale grant files")
		return nil
	}

	verb := "would remove"
	if apply {
		verb = "removing"
	}
	for _, name := range stale {
		fmt.Printf("%s: %s/%s\n", verb, grantsDir, name)
		if apply {
			if err := os.Remove(grantsDir + "/" + name); err != nil {
				fmt.Fprintf(os.Stderr, "  failed: %v\n", err)
			}
		}
	}
	if !apply {
		fmt.Println("\n(dry-run; re-run with --apply to actually remove)")
	}
	return nil
}

func contains(xs []string, target string) bool {
	for _, x := range xs {
		if x == target {
			return true
		}
	}
	return false
}

func removeString(xs []string, target string) []string {
	out := make([]string, 0, len(xs))
	for _, x := range xs {
		if x != target {
			out = append(out, x)
		}
	}
	return out
}

// runVerify walks the coordinator wiring and reports a check
// summary. Each row is `✓ … OK` or `✗ … FAIL: <reason>`; the
// process exits non-zero iff any row failed. Used as a post-rebuild
// sanity check and a first-line diagnostic when something doesn't
// work — no surprise dependencies, no socket dial gymnastics
// before the check actually starts.
const (
	checkOK   = "✓"
	checkFail = "✗"
)

func runVerify() error {
	pass := true
	check := func(label, ok, fail string, condition bool) {
		if condition {
			fmt.Printf("%s  %s: %s\n", checkOK, label, ok)
		} else {
			fmt.Printf("%s  %s: %s\n", checkFail, label, fail)
			pass = false
		}
	}

	// 1. Coordinator socket
	sock, sockErr := socketPath()
	if sockErr != nil {
		check("coordinator socket", "", sockErr.Error(), false)
	} else {
		info, statErr := os.Stat(sock)
		switch {
		case statErr != nil:
			check("coordinator socket", "", fmt.Sprintf("%s missing", sock), false)
		case info.Mode()&os.ModeSocket == 0:
			check("coordinator socket", "", fmt.Sprintf("%s is not a socket", sock), false)
		default:
			mode := info.Mode().Perm()
			check("coordinator socket",
				fmt.Sprintf("%s (mode %#o)", sock, mode),
				"",
				mode == 0o600)
			if mode != 0o600 {
				fmt.Fprintf(os.Stderr, "  (expected mode 0600; the perimeter is set by the socket permissions)\n")
			}
		}
	}

	// 2. Coordinator user service active
	active := systemctlActive("spaces-app-coordinator.service")
	check("coordinator service",
		"spaces-app-coordinator.service is active",
		"spaces-app-coordinator.service is not active (try: systemctl --user status spaces-app-coordinator.service)",
		active)

	// 3. Manifest file
	const manifestPath = "/etc/spaces/app-coordinator/manifest.json"
	manifestData, manifestErr := os.ReadFile(manifestPath)
	check("manifest file",
		fmt.Sprintf("%s readable", manifestPath),
		fmt.Sprintf("%s not readable: %v", manifestPath, manifestErr),
		manifestErr == nil)

	// 4. For each app in the manifest, confirm its launcher is on PATH.
	if manifestErr == nil {
		var parsed struct {
			Apps map[string]manifestApp `json:"apps"`
		}
		if err := json.Unmarshal(manifestData, &parsed); err != nil {
			check("manifest parse", "", err.Error(), false)
		} else {
			names := make([]string, 0, len(parsed.Apps))
			for name := range parsed.Apps {
				names = append(names, name)
			}
			sort.Strings(names)
			for _, name := range names {
				app := parsed.Apps[name]
				_, statErr := os.Stat(app.LauncherPath)
				check(fmt.Sprintf("launcher: %s", name),
					app.LauncherPath,
					fmt.Sprintf("%s missing or unreadable: %v", app.LauncherPath, statErr),
					statErr == nil)
			}
		}
	}

	if !pass {
		fmt.Fprintln(os.Stderr, "\nverify FAILED — see crosses above")
		return fmt.Errorf("verify failed")
	}
	fmt.Println("\nverify OK")
	return nil
}

func systemctlActive(unit string) bool {
	out, err := exec.Command("systemctl", "--user", "is-active", unit).Output()
	if err != nil {
		// is-active exits non-zero when inactive; the output is
		// still the state name. We treat anything but "active" as
		// failure regardless of exit code.
	}
	return strings.TrimSpace(string(out)) == "active"
}

// runSpawns reads recent `app-run` JSON lines that the launcher
// emits to stderr at every spawn. Unlike coordinator AUDIT lines
// (which show the requested op + result), spawn events show what
// actually engaged: the resolved effective permission set after
// runtime grants and denies-last subtraction.
//
// The launcher's stderr lands in whichever unit's journal it was
// forked under — usually the coordinator's, but also user terminal
// for direct invocations. We scan the entire --user journal
// (no -u filter) for the `"event":"app-run"` marker.
//
// `n` caps the number of events shown. We pull `n*4` raw journal
// lines first so the filtered window stays healthy.
func runSpawns(n int, jsonOut bool) error {
	if n <= 0 {
		return fmt.Errorf("spawns: -n must be positive")
	}
	cmd := exec.Command(
		"journalctl",
		"--user",
		"-o", "cat",
		"-n", fmt.Sprintf("%d", n*4),
		"--no-pager",
	)
	out, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("journalctl: %w", err)
	}
	var events []string
	const marker = `"event":"app-run"`
	for _, line := range strings.Split(string(out), "\n") {
		idx := strings.Index(line, marker)
		if idx < 0 {
			continue
		}
		// Trim back to the opening `{` so the line is parseable JSON.
		start := strings.LastIndex(line[:idx], "{")
		if start < 0 {
			continue
		}
		events = append(events, line[start:])
	}
	if len(events) > n {
		events = events[len(events)-n:]
	}
	if len(events) == 0 {
		fmt.Fprintln(os.Stderr, "(no app-run events in journal — no apps have been launched yet)")
		return nil
	}
	if jsonOut {
		for _, line := range events {
			fmt.Println(line)
		}
		return nil
	}
	for _, line := range events {
		var entry map[string]any
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			fmt.Println(line)
			continue
		}
		renderSpawnEntry(entry)
	}
	return nil
}

func renderSpawnEntry(e map[string]any) {
	app, _ := e["app"].(string)
	appID, _ := e["appId"].(string)
	effective, _ := e["effective"].(string)
	if effective == "" {
		effective = "(none)"
	}
	fmt.Printf("%-32s  %-30s  effective: %s\n", appID, app, effective)
}

func renderAuditEntry(e map[string]any) {
	ts, _ := e["ts"].(string)
	caller, _ := e["caller"].(string)
	op, _ := e["op"].(string)
	result, _ := e["result"].(string)
	target, _ := e["app"].(string)
	if target == "" {
		target, _ = e["unit"].(string)
	}
	tag := op
	if result == "error" {
		tag = op + "/err"
	}
	if target != "" {
		fmt.Printf("%s  %-25s  %-10s  %s", ts, caller, tag, target)
	} else {
		fmt.Printf("%s  %-25s  %s", ts, caller, tag)
	}
	if errMsg, ok := e["error"].(string); ok && errMsg != "" {
		fmt.Printf("  — %s", errMsg)
	}
	fmt.Println()
}

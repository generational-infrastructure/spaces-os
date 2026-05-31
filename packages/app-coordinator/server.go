package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strings"
	"time"
)

// compiledApp is the runtime form of a manifest entry: regex patterns
// are compiled once at startup so the spawn hot-path doesn't recompile
// per call.
type compiledApp struct {
	launcherPath string
	allowedArgs  []*regexp.Regexp
	spawnableBy  []string
}

// Server holds the parsed at-rest manifest plus its compiled form.
// State is read-only at runtime; reload happens via systemd unit
// restart, not in-process.
type Server struct {
	manifest Manifest
	compiled map[string]compiledApp
}

func NewServer(manifestPath string) (*Server, error) {
	data, err := os.ReadFile(manifestPath)
	if err != nil {
		return nil, fmt.Errorf("read manifest %s: %w", manifestPath, err)
	}
	var m Manifest
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("parse manifest: %w", err)
	}
	compiled := make(map[string]compiledApp, len(m.Apps))
	for name, app := range m.Apps {
		patterns := make([]*regexp.Regexp, 0, len(app.AllowedArgs))
		for _, p := range app.AllowedArgs {
			re, err := regexp.Compile(p)
			if err != nil {
				return nil, fmt.Errorf("app %q: invalid allowedArgs regex %q: %w", name, p, err)
			}
			patterns = append(patterns, re)
		}
		compiled[name] = compiledApp{
			launcherPath: app.LauncherPath,
			allowedArgs:  patterns,
			spawnableBy:  app.SpawnableBy,
		}
	}
	return &Server{manifest: m, compiled: compiled}, nil
}

func (s *Server) handle(ctx context.Context, req Request, callerID string) Reply {
	var rep Reply
	switch req.Op {
	case "list":
		rep = s.list()
	case "spawn":
		rep = s.spawn(req, callerID)
	case "running":
		rep = s.running(ctx)
	case "kill":
		rep = s.kill(ctx, req.Unit)
	case "info":
		rep = s.info(req.App)
	default:
		rep = Reply{Op: "error", Error: "unknown op: " + req.Op}
	}
	audit(callerID, req, rep)
	return rep
}

// audit emits one structured JSON-line per dispatched op to stderr,
// which lands in the unit's journal under the coordinator service.
// Mutating ops (spawn, kill) are the interesting ones; read ops are
// also logged so a forensic timeline can show what the caller was
// inspecting. The line is prefixed with "AUDIT " for easy grepping.
func audit(callerID string, req Request, rep Reply) {
	entry := map[string]any{
		"ts":     time.Now().UTC().Format(time.RFC3339Nano),
		"caller": callerID,
		"op":     req.Op,
		"result": rep.Op,
	}
	if req.App != "" {
		entry["app"] = req.App
	}
	if req.Unit != "" {
		entry["unit"] = req.Unit
	}
	if len(req.Args) > 0 {
		entry["args"] = req.Args
	}
	if rep.Error != "" {
		entry["error"] = rep.Error
	}
	encoded, err := json.Marshal(entry)
	if err != nil {
		// Audit logging itself must never crash the coordinator.
		// Fall back to a non-JSON line so we at least leave a
		// trace.
		log.Printf("AUDIT (encode-failed) caller=%s op=%s result=%s", callerID, req.Op, rep.Op)
		return
	}
	log.Printf("AUDIT %s", encoded)
}

// info returns the raw manifest entry for an app. Pure introspection,
// no privilege check beyond the manifest membership — anyone who can
// reach the socket can already enumerate apps via `list`, this just
// gives them the full record. Used today by operators with `jq`;
// scaffolding for a future grant UI.
func (s *Server) info(name string) Reply {
	entry, ok := s.manifest.Apps[name]
	if !ok {
		return Reply{Op: "error", Error: fmt.Sprintf("unknown app: %q", name)}
	}
	return Reply{Op: "ok", Info: &entry}
}

func (s *Server) list() Reply {
	names := make([]string, 0, len(s.manifest.Apps))
	for n := range s.manifest.Apps {
		names = append(names, n)
	}
	sort.Strings(names)
	return Reply{Op: "ok", Apps: names}
}

// spawn fires the app's launcher and returns immediately. The launcher
// itself execs into `systemd-run --user --no-block --collect`, which
// queues a transient service unit and exits, so the child we Start()
// finishes promptly. We Wait on it in a goroutine to reap the zombie.
//
// Two checks run before fork:
//  1. `spawnableBy` — the caller's app-id (resolved via SO_PEERCRED +
//     /proc/<pid>/cgroup, or "host" when the peer isn't sandboxed)
//     must appear in the target's allow-list. Default `["*"]` accepts
//     any caller.
//  2. `allowedArgs` — runtime argv from the caller must each match at
//     least one regex pattern. Default `[]` rejects any runtime arg.
func (s *Server) spawn(req Request, callerID string) Reply {
	app, ok := s.compiled[req.App]
	if !ok {
		return Reply{Op: "error", Error: fmt.Sprintf("unknown app: %q", req.App)}
	}
	if !callerAllowed(callerID, app.spawnableBy) {
		return Reply{
			Op: "error",
			Error: fmt.Sprintf(
				"caller %q not in spawnableBy for app %q (allowed: %v)",
				callerID, req.App, app.spawnableBy,
			),
		}
	}
	for i, a := range req.Args {
		if !matchesAny(a, app.allowedArgs) {
			return Reply{
				Op: "error",
				Error: fmt.Sprintf(
					"arg[%d] %q does not match any allowedArgs pattern for app %q",
					i, a, req.App,
				),
			}
		}
	}
	cmd := exec.Command(app.launcherPath, req.Args...)
	// Inherit the coordinator's own env. The launcher requires HOME
	// and XDG_RUNTIME_DIR; both are present in a user-systemd unit.
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return Reply{Op: "error", Error: err.Error()}
	}
	// Reap the launcher's exit asynchronously. The actual app is
	// reparented to systemd, not to us.
	go func() { _ = cmd.Wait() }()
	// The launcher's --unit=app-<name>-$$ uses the launcher's own
	// PID, which we don't know without polling /proc. Return a glob
	// so callers can still identify the family via systemctl.
	return Reply{Op: "ok", Unit: fmt.Sprintf("app-%s-*.service", req.App)}
}

// matchesAny returns true iff at least one compiled pattern matches s.
// An empty pattern list returns false — that's how the default
// "no runtime args" posture is encoded.
func matchesAny(s string, patterns []*regexp.Regexp) bool {
	for _, p := range patterns {
		if p.MatchString(s) {
			return true
		}
	}
	return false
}

// running enumerates running app-* service units via systemctl. Authoritative
// view comes from systemd, not in-memory state, so a coordinator restart
// doesn't lose visibility of long-running apps.
func (s *Server) running(ctx context.Context) Reply {
	cmd := exec.CommandContext(ctx, "systemctl", "--user", "list-units",
		"--type=service", "--no-legend", "--plain", "app-*.service")
	out, err := cmd.Output()
	if err != nil {
		return Reply{Op: "error", Error: err.Error()}
	}
	var running []RunningApp
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		unit := fields[0]
		if !strings.HasPrefix(unit, "app-") || !strings.HasSuffix(unit, ".service") {
			continue
		}
		// app-<name>-<pid>.service → <name>
		stem := strings.TrimSuffix(strings.TrimPrefix(unit, "app-"), ".service")
		name := stem
		if idx := strings.LastIndex(stem, "-"); idx > 0 {
			name = stem[:idx]
		}
		if _, known := s.manifest.Apps[name]; !known {
			// Defensive: ignore service units that don't match a manifest
			// entry (could be a stray from a removed app, etc.).
			continue
		}
		running = append(running, RunningApp{App: name, Unit: unit})
	}
	return Reply{Op: "ok", Running: running}
}

// kill stops a running app service unit. Refuses any unit name that
// doesn't look like an app service so callers can't use this to
// terminate unrelated user units.
func (s *Server) kill(ctx context.Context, unit string) Reply {
	if unit == "" {
		return Reply{Op: "error", Error: "unit required"}
	}
	if !strings.HasPrefix(unit, "app-") || !strings.HasSuffix(unit, ".service") {
		return Reply{Op: "error", Error: "refusing to kill non-app unit"}
	}
	// Defensive: verify the embedded app name is in the manifest, so
	// a caller can't kill service units they made up.
	stem := strings.TrimSuffix(strings.TrimPrefix(unit, "app-"), ".service")
	name := stem
	if idx := strings.LastIndex(stem, "-"); idx > 0 {
		name = stem[:idx]
	}
	if _, known := s.manifest.Apps[name]; !known {
		return Reply{Op: "error", Error: fmt.Sprintf("unknown app in unit: %q", unit)}
	}
	cmd := exec.CommandContext(ctx, "systemctl", "--user", "stop", unit)
	if err := cmd.Run(); err != nil {
		return Reply{Op: "error", Error: err.Error()}
	}
	return Reply{Op: "ok"}
}

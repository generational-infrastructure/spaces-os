package main

// Nix-managed per-user integration profiles (docs/agent-integrations-design.md
// §10). A root stager materialises, per user, a read-only staged tree at
// <managedRoot>/ (default /run/spaces-integrations-managed/$USER) with a single
// managed.json the broker reads. Managed profiles layer ON TOP of the runtime
// store — they shadow (never delete) same-named user profiles and are fully
// read-only. Nix enable verdicts fold into enabled.json with source provenance
// so reconcile can restore user autonomy when a verdict disappears.
//
// Single writer: the stager (at boot/switch). Single reader: this broker.

import (
	"encoding/json"
	"errors"
	"log"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"time"
)

// managedTickInterval is the coarse timer cadence: the broker re-stats
// managed.json this often and reconciles when its mtime/generation changed,
// catching a re-stage that happened while no client op fired.
const managedTickInterval = 30 * time.Second

// ManagedState is the parsed managed.json (§10.4). generation is a monotonic
// counter the stager bumps on EVERY re-stage; it plus the file mtime drive the
// broker's change detection.
type ManagedState struct {
	Generation   int64                         `json:"generation"`
	Integrations map[string]ManagedIntegration `json:"integrations"`
}

// ManagedIntegration is one integration's Nix opinion. Enable is a *bool so an
// absent key (no Nix verdict, user autonomy) is distinct from an explicit
// false.
type ManagedIntegration struct {
	Enable   *bool                     `json:"enable,omitempty"`
	Profiles map[string]ManagedProfile `json:"profiles,omitempty"`
}

// ManagedProfile carries a managed profile's resolved config values and the
// declared secret FIELD names (values never appear — set-status is a stat of
// the staged secret-<profile>-<field> file).
type ManagedProfile struct {
	Config  map[string]string `json:"config,omitempty"`
	Secrets []string          `json:"secrets,omitempty"`
}

// managedFile is <managedRoot>/managed.json, the broker's single read.
func (s *Server) managedFile() string {
	return filepath.Join(s.managedRoot, "managed.json")
}

// managedState returns the current managed.json, cached by mtime: it re-stats
// per call and reloads only when the mtime changed (or the file appeared /
// disappeared). Caller MUST hold s.mu — the cache fields live under it. An
// absent file yields the empty state (no Nix opinion anywhere).
func (s *Server) managedState() ManagedState {
	path := s.managedFile()
	fi, err := os.Stat(path)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			log.Printf("stat managed.json: %v", err)
		}
		s.managedCache = ManagedState{}
		s.managedMtime = time.Time{}
		s.managedLoaded = true
		return s.managedCache
	}
	if s.managedLoaded && fi.ModTime().Equal(s.managedMtime) {
		return s.managedCache
	}
	s.managedCache = readManaged(path)
	s.managedMtime = fi.ModTime()
	s.managedLoaded = true
	return s.managedCache
}

// readManaged parses managed.json, returning the empty state on any read/parse
// error so one malformed stage cannot wedge the broker (mirrors loadDefs).
func readManaged(path string) ManagedState {
	empty := ManagedState{Integrations: map[string]ManagedIntegration{}}
	data, err := os.ReadFile(path)
	if err != nil {
		log.Printf("read managed.json: %v", err)
		return empty
	}
	var st ManagedState
	if err := json.Unmarshal(data, &st); err != nil {
		log.Printf("parse managed.json: %v", err)
		return empty
	}
	if st.Integrations == nil {
		st.Integrations = map[string]ManagedIntegration{}
	}
	return st
}

// managedSecretSet reports a managed secret's set-status: the stat of the
// staged secret-<profile>-<field> credential file (§10.5). Consumers never
// parse the filename for meaning — managed.json carries the authoritative
// (profile, field) list.
func (s *Server) managedSecretSet(integration, profile, field string) bool {
	_, err := os.Stat(filepath.Join(s.managedRoot, integration, "secret-"+profile+"-"+field))
	return err == nil
}

// mergeManagedProfiles overlays Nix-managed profiles onto the user profiles for
// one integration (§10.5): a managed profile REPLACES (shadows) a same-named
// user profile; its config comes from managed.json and each declared secret's
// set-status is the stat of its staged file. Returns the merged, name-sorted
// list; user profiles with no managed twin pass through unchanged.
func (s *Server) mergeManagedProfiles(d Definition, user []ProfileInfo, mi ManagedIntegration) []ProfileInfo {
	if len(mi.Profiles) == 0 {
		return user
	}
	userNames := make(map[string]bool, len(user))
	for _, p := range user {
		userNames[p.Name] = true
	}
	out := make([]ProfileInfo, 0, len(user)+len(mi.Profiles))
	for _, p := range user {
		if _, shadowed := mi.Profiles[p.Name]; shadowed {
			continue // the managed row below replaces it
		}
		out = append(out, p)
	}
	names := make([]string, 0, len(mi.Profiles))
	for name := range mi.Profiles {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		mp := mi.Profiles[name]
		config := make(map[string]string, len(mp.Config))
		for k, v := range mp.Config {
			config[k] = v
		}
		secrets := make(map[string]bool, len(mp.Secrets))
		for _, field := range mp.Secrets {
			secrets[field] = s.managedSecretSet(d.Name, name, field)
		}
		out = append(out, ProfileInfo{
			Name:     name,
			Config:   config,
			Secrets:  secrets,
			Complete: profileComplete(d, config, secrets),
			Managed:  true,
			Shadowed: userNames[name],
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// foldVerdicts merges Nix enable verdicts into an enabled.json state in place
// (§10.5), returning whether anything changed:
//   - a verdict (enable != nil) sets the entry to {Enabled: verdict, Source: "nix"};
//   - an entry with Source "nix" whose verdict has disappeared is DELETED,
//     restoring user autonomy (the integration reverts to the absent-entry
//     default, disabled).
//
// A user (source-empty) entry is never touched here except by an overriding
// verdict — a Nix false overrides a pre-existing user enable.
func foldVerdicts(st *EnabledState, managed ManagedState) bool {
	changed := false
	for name, entry := range st.Integrations {
		if entry.Source != "nix" {
			continue
		}
		if mi, ok := managed.Integrations[name]; !ok || mi.Enable == nil {
			delete(st.Integrations, name)
			changed = true
		}
	}
	for name, mi := range managed.Integrations {
		if mi.Enable == nil {
			continue
		}
		want := IntegrationState{Enabled: *mi.Enable, Source: "nix"}
		if st.Integrations[name] != want {
			st.Integrations[name] = want
			changed = true
		}
	}
	return changed
}

// changedIntegrations returns the sorted names whose managed section differs
// between two states (enable verdict or profiles) — the units reconcile must
// try-restart after a managed.json change.
func changedIntegrations(prev, cur ManagedState) []string {
	seen := map[string]bool{}
	var names []string
	consider := func(name string) {
		if seen[name] {
			return
		}
		seen[name] = true
		if !reflect.DeepEqual(prev.Integrations[name], cur.Integrations[name]) {
			names = append(names, name)
		}
	}
	for name := range prev.Integrations {
		consider(name)
	}
	for name := range cur.Integrations {
		consider(name)
	}
	sort.Strings(names)
	return names
}

// watchManaged is the coarse timer: on each tick it reconciles when managed.json
// changed since the last observation (mtime/generation), then try-restarts every
// integration whose managed section changed. Runs for the life of the broker.
func (s *Server) watchManaged(interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for range ticker.C {
		s.reconcileManaged()
	}
}

// reconcileManaged detects a managed.json change and, when one occurred,
// re-folds verdicts into enabled.json (starting/stopping sockets) and
// try-restarts every integration whose managed section changed so a unit picks
// up rotated managed credentials. Same ownership pattern as after a GUI write.
func (s *Server) reconcileManaged() {
	s.mu.Lock()
	defer s.mu.Unlock()
	prev := s.managedCache
	prevLoaded := s.managedLoaded
	cur := s.managedState()
	if prevLoaded && reflect.DeepEqual(prev, cur) {
		return
	}
	changed := changedIntegrations(prev, cur)
	s.reconcileLocked()
	for _, name := range changed {
		s.tryRestart(name)
	}
}

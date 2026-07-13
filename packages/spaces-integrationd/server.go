package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Integration and profile names build filesystem paths and systemd unit names;
// anything outside this set is rejected before it touches either.
var namePattern = regexp.MustCompile(`^[a-z0-9-]+$`)

// Field names additionally allow underscores (imap_host, refresh_token).
var fieldPattern = regexp.MustCompile(`^[a-z0-9_-]+$`)

// Server handles one JSON request per connection. Definitions are re-read from
// defsDir on every request; state mutations are serialised by mu. It runs as
// the user, so all state is that user's own:
//
//	<stateDir>/enabled.json          which integrations are on (0600)
//	<stateDir>/<integration>/config.toml   plaintext config rows (0700 dir)
//	<stateDir>/<integration>/secrets       host+tpm2-sealed secrets.toml blob
//
// The credential paths match the integration unit's
// LoadCredential=config:%S/spaces-integrationd/<int>/config.toml and
// LoadCredentialEncrypted=secrets:%S/spaces-integrationd/<int>/secrets.
type Server struct {
	defsDir      string
	stateDir     string
	managedRoot  string // Nix-managed staged tree root (managed.json + per-integration creds)
	runtimeDir   string // scratch base for staging work dirs (store.go workDir), distinct from runtimeRoot
	runtimeRoot  string // %t user runtime root: the twin setup sockets (…-setup.sock) live directly here
	selfUid      uint32
	credsEncrypt []string // argv prefix: <prefix...> --name=secrets <in> <out>
	credsDecrypt []string // argv prefix: <prefix...> --name=secrets <in> <out>
	systemctl    []string // argv prefix: <prefix...> start|stop <units...>
	skillConfig  []string // argv prefix: <prefix...> <verb> ...
	mu           sync.Mutex
	// managed.json cache, all guarded by mu: parsed state, its file mtime, and
	// whether a load has happened (to distinguish a fresh start from an absent
	// file). managedState() re-stats per call and reloads on an mtime change.
	managedCache  ManagedState
	managedMtime  time.Time
	managedLoaded bool
}

func NewServer(defsDir, stateDir, managedRoot, runtimeDir, runtimeRoot string, credsEncrypt, credsDecrypt, systemctl, skillConfig []string) *Server {
	return &Server{
		defsDir:      defsDir,
		stateDir:     stateDir,
		managedRoot:  managedRoot,
		runtimeDir:   runtimeDir,
		runtimeRoot:  runtimeRoot,
		selfUid:      uint32(os.Getuid()),
		credsEncrypt: credsEncrypt,
		credsDecrypt: credsDecrypt,
		systemctl:    systemctl,
		skillConfig:  skillConfig,
	}
}

func errAck(msg string) Ack { return Ack{Op: "error", Error: msg} }

// managedProfileErr / managedEnableErr build the stable GUI-contract rejection
// messages for Nix-managed state; the GUI keys its lock affordances off these
// exact strings, so their wire form must not change.
func managedProfileErr(profile string) Ack {
	return errAck("profile '" + profile + "' is managed by system configuration")
}

func managedEnableErr(integration string) Ack {
	return errAck("integration '" + integration + "' enable state is managed by system configuration")
}

// Unit-name helpers: the systemd unit names and the twin setup socket filename
// are each derived from the integration name in exactly one place.
func socketUnit(name string) string       { return fmt.Sprintf("spaces-integration-%s.socket", name) }
func serviceUnit(name string) string      { return fmt.Sprintf("spaces-integration-%s.service", name) }
func setupSocketUnit(name string) string  { return fmt.Sprintf("spaces-integration-%s-setup.socket", name) }
func setupServiceUnit(name string) string { return fmt.Sprintf("spaces-integration-%s-setup.service", name) }
func setupSockPath(name string) string    { return fmt.Sprintf("spaces-integration-%s-setup.sock", name) }

// Serve accepts connections until the listener is closed.
func (s *Server) Serve(l net.Listener) {
	for {
		conn, err := l.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			log.Printf("accept: %v", err)
			continue
		}
		go s.handleConn(conn)
	}
}

func (s *Server) handleConn(conn net.Conn) {
	defer conn.Close()
	enc := json.NewEncoder(conn)

	uc, ok := conn.(*net.UnixConn)
	if !ok {
		_ = enc.Encode(Ack{Op: "error", Error: "not a unix socket connection"})
		return
	}
	if err := s.checkPeer(uc); err != nil {
		log.Printf("rejecting peer: %v", err)
		_ = enc.Encode(Ack{Op: "error", Error: "permission denied"})
		return
	}

	var req Request
	if err := json.NewDecoder(conn).Decode(&req); err != nil {
		if !errors.Is(err, io.EOF) {
			_ = enc.Encode(Ack{Op: "error", Error: "malformed request"})
		}
		return
	}
	// "setup" is the one op that is not request/reply: it takes over the
	// connection and streams NDJSON events until the flow ends, so it never
	// goes through dispatch (which stays a pure one-shot switch).
	if req.Op == "setup" {
		s.setup(conn, req.Integration, req.Action)
		return
	}
	_ = enc.Encode(s.dispatch(req))
}

// peerAllowed authorises a connection: only the broker's own uid. A sibling
// user's uid is refused even if it somehow reached the socket.
func peerAllowed(peerUid, selfUid uint32) bool { return peerUid == selfUid }

// checkPeer reads the connecting process's uid via SO_PEERCRED and enforces
// peerAllowed against the broker's own uid.
func (s *Server) checkPeer(conn *net.UnixConn) error {
	raw, err := conn.SyscallConn()
	if err != nil {
		return err
	}
	var cred *syscall.Ucred
	var credErr error
	if err := raw.Control(func(fd uintptr) {
		cred, credErr = syscall.GetsockoptUcred(int(fd), syscall.SOL_SOCKET, syscall.SO_PEERCRED)
	}); err != nil {
		return err
	}
	if credErr != nil {
		return credErr
	}
	if !peerAllowed(cred.Uid, s.selfUid) {
		return fmt.Errorf("peer uid %d != broker uid %d", cred.Uid, s.selfUid)
	}
	return nil
}

func (s *Server) dispatch(req Request) any {
	switch req.Op {
	case "list":
		return s.list()
	case "set-field":
		return s.setField(req.Integration, req.Profile, req.Field, req.Value)
	case "remove-profile":
		return s.removeProfileDispatch(req.Integration, req.Profile)
	case "enable":
		return s.enable(req.Integration)
	case "disable":
		return s.disable(req.Integration)
	default:
		return Ack{Op: "error", Error: "unknown op: " + req.Op}
	}
}

// setup dial retry: `systemctl start ...-setup.socket` returns before the
// socket is necessarily accepting (socket activation), so the broker retries
// the connect briefly.
const (
	setupDialAttempts = 100
	setupDialInterval = 50 * time.Millisecond
	// setupLineBufSize caps one setup-channel NDJSON line (helper events can
	// embed data-URI images).
	setupLineBufSize = 1 << 20
)

// ReconcileEnabled reconciles run state at startup (and is re-invoked whenever
// managed.json changes): it folds Nix enable verdicts into enabled.json, then
// starts the sockets of every enabled+defined integration. It is the ONE place
// reconcile may STOP a unit — and only for a Nix enable=false verdict, which
// overrides a pre-existing user enable. A user-enabled unit the GUI never
// disabled is otherwise left untouched. Per-integration failures are logged,
// never fatal, and never block the remaining integrations.
func (s *Server) ReconcileEnabled() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.reconcileLocked()
}

// reconcileLocked is ReconcileEnabled's body; caller holds s.mu. Kept separate
// so the managed-change timer can reconcile under the lock it already holds.
func (s *Server) reconcileLocked() {
	defs := s.loadDefs()
	st := s.loadState()
	managed := s.managedState()
	if foldVerdicts(&st, managed) {
		if err := s.saveState(st); err != nil {
			log.Printf("reconcile: save enabled.json: %v", err)
		}
	}
	names := make([]string, 0, len(st.Integrations))
	for name := range st.Integrations {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		entry := st.Integrations[name]
		if entry.Enabled {
			if _, ok := defs[name]; !ok {
				log.Printf("reconcile: skip %s (no definition)", name)
				continue
			}
			unit := socketUnit(name)
			if msg, err := s.runSystemctl("start", unit); err != nil {
				log.Printf("reconcile: start %s: %s", unit, msg)
			}
			continue
		}
		// A Nix enable=false verdict actively stops the unit (overrides a user
		// enable); a plain user-disabled entry is left alone.
		if entry.Source == sourceNix {
			sock := socketUnit(name)
			svc := serviceUnit(name)
			if msg, err := s.runSystemctl("stop", sock, svc); err != nil {
				log.Printf("reconcile: stop %s %s: %s", sock, svc, msg)
			}
		}
	}
}

// setupSocketPath is the twin setup unit's %t/spaces-integration-<name>-setup.sock.
func (s *Server) setupSocketPath(integration string) string {
	return filepath.Join(s.runtimeRoot, setupSockPath(integration))
}

// setup drives the sandboxed setup channel for one integration. Unlike every
// other op it returns no Ack: it takes over the client connection and relays
// the setup helper's NDJSON events (both directions) until the flow ends
// (helper done/error, helper EOF, or client disconnect), then closes both
// sides and stops the transient setup units. setupPark vendor daemons are
// stopped for the duration and started again on the way out. It never holds
// s.mu while streaming, so list/enable stay responsive during a long flow.
func (s *Server) setup(conn net.Conn, integration, action string) {
	enc := json.NewEncoder(conn)
	fail := func(msg string) { _ = enc.Encode(SetupEvent{Event: "error", Error: msg}) }

	if !namePattern.MatchString(integration) {
		fail("invalid integration name")
		return
	}
	d, enabled, err := s.prepareSetup(integration)
	if err != nil {
		fail(err.Error())
		return
	}
	if action == "" {
		action = "link"
	}

	// Park single-instance vendor daemons before the setup units start; unpark
	// on the way out. Registered first so it runs LAST — after the post-`done`
	// try-restart and after the setup units stop.
	s.parkSetup(d.SetupPark)
	defer s.unparkSetup(d.SetupPark)

	// Provisioning path (integration disabled — proton bootstrap: enable
	// requires a complete profile, but the secret only exists after setup):
	// the socket never pulled the backing daemons in, so start the non-parked
	// extras the helper depends on (signal's daemon socket) for the duration
	// and stop them again on the way out. Enabled integrations already have
	// them running via the socket's Wants=.
	if !enabled {
		if extras := subtract(d.ExtraServices, d.SetupPark); len(extras) > 0 {
			if msg, err := s.runSystemctl("start", extras...); err != nil {
				log.Printf("systemctl start %v: %s", extras, msg)
			}
			defer func() {
				if msg, err := s.runSystemctl("stop", extras...); err != nil {
					log.Printf("systemctl stop %v: %s", extras, msg)
				}
			}()
		}
	}

	setupSock := setupSocketUnit(integration)
	setupSvc := setupServiceUnit(integration)
	if msg, err := s.runSystemctl("start", setupSock); err != nil {
		fail("systemctl start failed: " + msg)
		return
	}
	// The setup units may now be live: always stop them on the way out
	// (best-effort). Deferred, so it runs after any post-`done` try-restart.
	defer func() {
		if msg, err := s.runSystemctl("stop", setupSvc, setupSock); err != nil {
			log.Printf("systemctl stop %s %s: %s", setupSvc, setupSock, msg)
		}
	}()

	hc, err := s.dialSetup(integration)
	if err != nil {
		fail("connect setup helper: " + err.Error())
		return
	}
	defer hc.Close()

	// The action line is the first byte the helper sees. Best-effort: a helper
	// that never reads it (signal) ignores it, and a dead helper is caught by
	// the relay's EOF, so a write error here is not fatal.
	s.writeSetupAction(hc, action, "")

	if s.relay(conn, hc, integration) {
		s.postSetupRestart(integration, d.ExtraServices)
	}
}

// prepareSetup validates a setup request and stages the credential store files,
// all under s.mu, then returns the definition (and whether the integration is
// currently enabled) so the caller can stream without the lock. The integration
// must exist and expose a setup flow. Enabled is NOT required: setup on a
// disabled integration is the provisioning path — proton's enable gate needs a
// complete profile, but bridge_password only exists after setup, so gating
// setup on enable would deadlock the bootstrap.
func (s *Server) prepareSetup(integration string) (Definition, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	defs := s.loadDefs()
	d, ok := defs[integration]
	if !ok {
		return Definition{}, false, fmt.Errorf("unknown integration: %s", integration)
	}
	if !d.Setup {
		return Definition{}, false, fmt.Errorf("integration %s has no setup flow", integration)
	}
	// The setup service loads the same LoadCredential[Encrypted] sources as the
	// main service, so they must exist at start (same staging as enable).
	if err := s.stageStores(d, integration); err != nil {
		return Definition{}, false, err
	}
	return d, s.loadState().Integrations[integration].Enabled, nil
}

// subtract returns the elements of a not present in b (order preserved).
func subtract(a, b []string) []string {
	out := make([]string, 0, len(a))
	for _, x := range a {
		if !slices.Contains(b, x) {
			out = append(out, x)
		}
	}
	return out
}

// stageStores creates the integration's LoadCredential[Encrypted] sources when
// absent — an empty config.toml and a sealed empty secrets blob for whichever
// stores the definition declares — so the unit (or its setup twin) finds them
// at start. Shared by enable and prepareSetup; each caller applies its own
// error style to the wrapped result.
func (s *Server) stageStores(d Definition, integration string) error {
	if len(d.Config) > 0 {
		if err := ensureFile(s.configFile(integration)); err != nil {
			return fmt.Errorf("config store: %w", err)
		}
	}
	if len(d.Secrets) > 0 {
		if _, err := os.Stat(s.sealedSecrets(integration)); errors.Is(err, os.ErrNotExist) {
			if err := s.sealEmpty(integration); err != nil {
				return fmt.Errorf("secrets store: %w", err)
			}
		}
	}
	return nil
}

// dialSetup connects to the twin setup unit's socket, retrying briefly to ride
// out the gap between `systemctl start ...-setup.socket` returning and the
// socket accepting (socket activation).
func (s *Server) dialSetup(integration string) (net.Conn, error) {
	path := s.setupSocketPath(integration)
	var lastErr error
	for range setupDialAttempts {
		c, err := net.Dial("unix", path)
		if err == nil {
			return c, nil
		}
		lastErr = err
		time.Sleep(setupDialInterval)
	}
	return nil, lastErr
}

// relay copies NDJSON lines between the panel and the helper until the flow
// ends (helper done/error, helper EOF, or panel disconnect), returning true iff
// a `done` event was seen so the caller bounces services only on success.
//
// Panel -> helper: every line is forwarded verbatim (the v2 reply channel, e.g.
// {"value":...} answering a text-field/secret-field prompt). Helper -> panel:
// every line is relayed verbatim EXCEPT `set-field`, which is broker-consumed —
// executed via the setField path and never relayed (its value must not reach
// the panel). A setField failure synthesises an error event to the panel and
// aborts (fail closed). Unknown future events keep flowing to the panel.
func (s *Server) relay(client, helper net.Conn, integration string) bool {
	// Forward panel lines to the helper; a read error means the panel is gone,
	// so close the helper to unblock the loop below and tear the flow down.
	go func() {
		cr := bufio.NewReaderSize(client, setupLineBufSize)
		for {
			line, err := cr.ReadBytes('\n')
			if len(line) > 0 {
				if _, werr := helper.Write(line); werr != nil {
					break
				}
			}
			if err != nil {
				break
			}
		}
		helper.Close()
	}()

	r := bufio.NewReaderSize(helper, setupLineBufSize)
	for {
		line, err := r.ReadBytes('\n')
		if len(line) > 0 {
			var ev SetupEvent
			parsed := json.Unmarshal(bytes.TrimSpace(line), &ev) == nil
			if parsed && ev.Event == "set-field" {
				// Broker-consumed: execute the store write, never relay it. Fail
				// closed on a setField error.
				if ack := s.setField(integration, ev.Profile, ev.Field, ev.Value); ack.Op != "ok" {
					_ = json.NewEncoder(client).Encode(SetupEvent{Event: "error", Error: ack.Error})
					return false
				}
				if err != nil {
					return false // helper EOF right after the set-field line.
				}
				continue
			}
			if _, werr := client.Write(line); werr != nil {
				return false // panel gone: stop, do not restart.
			}
			if parsed {
				switch ev.Event {
				case "done":
					return true
				case "error":
					return false
				}
			}
		}
		if err != nil {
			return false // helper EOF/closed without a terminal event.
		}
	}
}

// postSetupRestart bounces the integration's own service plus every extra
// service after a successful setup so a freshly-linked account/state is picked
// up. Best-effort: try-restart no-ops inactive units and a failure is logged.
func (s *Server) postSetupRestart(integration string, extraServices []string) {
	units := append([]string{serviceUnit(integration)}, extraServices...)
	if msg, err := s.runSystemctl("try-restart", units...); err != nil {
		log.Printf("systemctl try-restart %v: %s", units, msg)
	}
}

// setupAction is the single NDJSON line the broker writes to the helper right
// after connecting: which mode to run (link | remove) and, for remove, the
// target profile.
type setupAction struct {
	Action  string `json:"action"`
	Profile string `json:"profile,omitempty"`
}

// writeSetupAction writes the one action line. Best-effort by contract: helpers
// that never read the connection ignore it, so a write error is logged, not
// surfaced (a genuinely dead helper is caught by the relay/consume EOF).
func (s *Server) writeSetupAction(w io.Writer, action, profile string) {
	if err := json.NewEncoder(w).Encode(setupAction{Action: action, Profile: profile}); err != nil {
		log.Printf("write setup action %q: %v", action, err)
	}
}

// parkSetup stops the single-instance vendor daemons a setup flow must displace
// so the sandboxed helper can spawn its own transient instance. Best-effort: a
// failure is logged and an already-stopped unit no-ops.
func (s *Server) parkSetup(units []string) {
	if len(units) == 0 {
		return
	}
	if msg, err := s.runSystemctl("stop", units...); err != nil {
		log.Printf("systemctl stop %v: %s", units, msg)
	}
}

// unparkSetup restarts the parked vendor daemons after a setup flow. `start`
// (not try-restart): a stopped unit would no-op under try-restart, and the
// units are ConditionPathExists-gated so a pre-onboarding start is inert.
func (s *Server) unparkSetup(units []string) {
	if len(units) == 0 {
		return
	}
	if msg, err := s.runSystemctl("start", units...); err != nil {
		log.Printf("systemctl start %v: %s", units, msg)
	}
}

// removeProfileDispatch routes op:"remove-profile". A setup-bearing integration
// first drives its helper's vendor removal (vendor state first, then the store
// row, so the two stay atomic); everything else takes the plain store-only path
// unchanged.
func (s *Server) removeProfileDispatch(integration, profile string) Ack {
	if !namePattern.MatchString(integration) {
		return errAck("invalid integration name")
	}
	if !namePattern.MatchString(profile) {
		return errAck("invalid profile name")
	}
	s.mu.Lock()
	d, ok := s.loadDefs()[integration]
	managed := s.managedState()
	s.mu.Unlock()
	// A Nix-managed profile is read-only (§10.5): the user copy it shadows is
	// untouched, but the managed row itself cannot be removed at runtime.
	if mi, mok := managed.Integrations[integration]; mok {
		if _, isManaged := mi.Profiles[profile]; isManaged {
			return managedProfileErr(profile)
		}
	}
	if ok && d.Setup {
		return s.removeProfileWithHelper(integration, profile, d)
	}
	return s.removeProfile(integration, profile)
}

// removeProfileWithHelper drives the setup helper in remove mode before the
// store-row removal. The profile must exist first (error before any helper
// work); a helper error/EOF aborts with the store untouched.
func (s *Server) removeProfileWithHelper(integration, profile string, d Definition) Ack {
	// 1. Validate the profile exists (and stage the stores the setup service
	// loads) before touching the helper.
	s.mu.Lock()
	profiles, err := s.storeProfiles(d)
	if err == nil {
		err = s.stageStores(d, integration)
	}
	s.mu.Unlock()
	if err != nil {
		return errAck("profiles: " + err.Error())
	}
	found := false
	for _, p := range profiles {
		if p.Name == profile {
			found = true
			break
		}
	}
	if !found {
		return errAck("unknown profile: " + profile)
	}

	// 2. Park vendor daemons + start the setup units. Same defers as setup: the
	// setup units stop, then unpark, both after the store removal below.
	s.parkSetup(d.SetupPark)
	defer s.unparkSetup(d.SetupPark)

	setupSock := setupSocketUnit(integration)
	setupSvc := setupServiceUnit(integration)
	if msg, err := s.runSystemctl("start", setupSock); err != nil {
		return errAck("systemctl start failed: " + msg)
	}
	defer func() {
		if msg, err := s.runSystemctl("stop", setupSvc, setupSock); err != nil {
			log.Printf("systemctl stop %s %s: %s", setupSvc, setupSock, msg)
		}
	}()

	hc, err := s.dialSetup(integration)
	if err != nil {
		return errAck("connect setup helper: " + err.Error())
	}
	defer hc.Close()

	// 3. Drive the helper in remove mode, then consume its events: done ->
	// proceed to the store-row removal; error/EOF -> abort, store untouched.
	s.writeSetupAction(hc, "remove", profile)
	if err := s.consumeRemoveEvents(hc); err != nil {
		return errAck(err.Error())
	}
	return s.removeProfile(integration, profile)
}

// consumeRemoveEvents reads the helper's NDJSON events during a broker-driven
// remove (no panel connection): a `done` event is success; an `error` event or
// EOF before any terminal event is failure.
func (s *Server) consumeRemoveEvents(helper net.Conn) error {
	r := bufio.NewReaderSize(helper, setupLineBufSize)
	for {
		line, err := r.ReadBytes('\n')
		if len(line) > 0 {
			var ev SetupEvent
			if json.Unmarshal(bytes.TrimSpace(line), &ev) == nil {
				switch ev.Event {
				case "done":
					return nil
				case "error":
					if ev.Error != "" {
						return errors.New(ev.Error)
					}
					return errors.New("setup helper reported an error")
				}
			}
		}
		if err != nil {
			return errors.New("setup helper closed without completing the removal")
		}
	}
}

// loadDefs reads every <defsDir>/*.json. Unreadable or malformed files are
// skipped with a log line so one broken definition cannot take down the broker.
func (s *Server) loadDefs() map[string]Definition {
	defs := make(map[string]Definition)
	entries, err := os.ReadDir(s.defsDir)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			log.Printf("read defs dir: %v", err)
		}
		return defs
	}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(s.defsDir, e.Name()))
		if err != nil {
			log.Printf("read %s: %v", e.Name(), err)
			continue
		}
		var d Definition
		if err := json.Unmarshal(data, &d); err != nil {
			log.Printf("parse %s: %v", e.Name(), err)
			continue
		}
		if !namePattern.MatchString(d.Name) {
			log.Printf("skip %s: bad integration name %q", e.Name(), d.Name)
			continue
		}
		defs[d.Name] = d
	}
	return defs
}

func (s *Server) enabledPath() string { return filepath.Join(s.stateDir, "enabled.json") }

// loadState returns enabled.json, or an empty state if absent.
func (s *Server) loadState() EnabledState {
	st := EnabledState{Integrations: make(map[string]IntegrationState)}
	data, err := os.ReadFile(s.enabledPath())
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			log.Printf("read enabled.json: %v", err)
		}
		return st
	}
	if err := json.Unmarshal(data, &st); err != nil {
		log.Printf("parse enabled.json: %v", err)
		return EnabledState{Integrations: make(map[string]IntegrationState)}
	}
	if st.Integrations == nil {
		st.Integrations = make(map[string]IntegrationState)
	}
	return st
}

// saveState writes enabled.json (0600, no secrets) inside the 0700 state dir.
func (s *Server) saveState(st EnabledState) error {
	if err := os.MkdirAll(s.stateDir, 0o700); err != nil {
		return err
	}
	data, err := json.Marshal(st)
	if err != nil {
		return err
	}
	return os.WriteFile(s.enabledPath(), data, 0o600)
}

func fieldInfos(m map[string]FieldSchema) []FieldInfo {
	names := make([]string, 0, len(m))
	for n := range m {
		names = append(names, n)
	}
	sort.Strings(names)
	out := make([]FieldInfo, 0, len(names))
	for _, n := range names {
		out = append(out, FieldInfo{Name: n, Description: m[n].Description, Required: m[n].Required})
	}
	return out
}

func (s *Server) list() any {
	s.mu.Lock()
	defer s.mu.Unlock()
	defs := s.loadDefs()
	st := s.loadState()
	managed := s.managedState()

	names := make([]string, 0, len(defs))
	for name := range defs {
		names = append(names, name)
	}
	sort.Strings(names)

	infos := make([]IntegrationInfo, 0, len(defs))
	for _, name := range names {
		d := defs[name]
		profiles, err := s.storeProfiles(d)
		if err != nil {
			log.Printf("list %s: %v", name, err)
			profiles = []ProfileInfo{}
		}
		var enabledByNix *bool
		if mi, ok := managed.Integrations[name]; ok {
			profiles = s.mergeManagedProfiles(d, profiles, mi)
			enabledByNix = mi.Enable
		}
		infos = append(infos, IntegrationInfo{
			Name:         name,
			Description:  d.Description,
			MultiProfile: d.MultiProfile,
			Enabled:      st.Integrations[name].Enabled,
			Config:       fieldInfos(d.Config),
			Secrets:      fieldInfos(d.Secrets),
			Profiles:     profiles,
			Setup:        d.Setup,
			EnabledByNix: enabledByNix,
		})
	}
	return ListReply{Op: "ok", Integrations: infos}
}

func (s *Server) setField(integration, profile, field, value string) Ack {
	if !namePattern.MatchString(integration) {
		return errAck("invalid integration name")
	}
	if !namePattern.MatchString(profile) {
		return errAck("invalid profile name")
	}
	if !fieldPattern.MatchString(field) {
		return errAck("invalid field name")
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	defs := s.loadDefs()
	d, ok := defs[integration]
	if !ok {
		return errAck("unknown integration: " + integration)
	}
	// A Nix-managed profile is read-only (§10.5): reject the write with the
	// stable message the GUI keys its lock affordance off.
	if mi, ok := s.managedState().Integrations[integration]; ok {
		if _, managed := mi.Profiles[profile]; managed {
			return managedProfileErr(profile)
		}
	}
	_, isConfig := d.Config[field]
	_, isSecret := d.Secrets[field]
	if !isConfig && !isSecret {
		return errAck("unknown field: " + field)
	}

	if err := os.MkdirAll(s.storeDir(integration), 0o700); err != nil {
		return errAck("state dir: " + err.Error())
	}
	work, err := s.workDir("set")
	if err != nil {
		return errAck("workdir: " + err.Error())
	}
	defer os.RemoveAll(work)
	schemaPath, err := writeSchema(work, d)
	if err != nil {
		return errAck("schema: " + err.Error())
	}
	secretsWork := filepath.Join(work, "secrets.toml")

	// Secret edits round-trip through the sealed blob so no plaintext persists.
	if isSecret {
		if err := s.unseal(s.sealedSecrets(integration), secretsWork); err != nil {
			return errAck("unseal: " + err.Error())
		}
	}
	req := skillRequest{Op: "set", Skill: integration, Profile: profile, Field: field, Value: &value}
	if err := s.callSkillConfig(s.skillEnv(integration, schemaPath, secretsWork, work), req, nil); err != nil {
		return errAck("set: " + err.Error())
	}
	if isSecret {
		if err := s.seal(secretsWork, s.sealedSecrets(integration)); err != nil {
			return errAck("seal: " + err.Error())
		}
	}
	s.tryRestart(integration)
	log.Printf("set-field %s.%s.%s", integration, profile, field)
	return Ack{Op: "ok"}
}

func (s *Server) removeProfile(integration, profile string) Ack {
	if !namePattern.MatchString(integration) {
		return errAck("invalid integration name")
	}
	if !namePattern.MatchString(profile) {
		return errAck("invalid profile name")
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	defs := s.loadDefs()
	d, ok := defs[integration]
	if !ok {
		return errAck("unknown integration: " + integration)
	}
	work, err := s.workDir("rm")
	if err != nil {
		return errAck("workdir: " + err.Error())
	}
	defer os.RemoveAll(work)
	schemaPath, err := writeSchema(work, d)
	if err != nil {
		return errAck("schema: " + err.Error())
	}
	secretsWork := filepath.Join(work, "secrets.toml")
	if err := s.unseal(s.sealedSecrets(integration), secretsWork); err != nil {
		return errAck("unseal: " + err.Error())
	}
	req := skillRequest{Op: "remove-profile", Skill: integration, Profile: profile}
	if err := s.callSkillConfig(s.skillEnv(integration, schemaPath, secretsWork, work), req, nil); err != nil {
		return errAck("remove: " + err.Error())
	}
	if err := s.seal(secretsWork, s.sealedSecrets(integration)); err != nil {
		return errAck("seal: " + err.Error())
	}
	s.tryRestart(integration)
	log.Printf("remove-profile %s.%s", integration, profile)
	return Ack{Op: "ok"}
}

func (s *Server) enable(integration string) Ack {
	if !namePattern.MatchString(integration) {
		return errAck("invalid integration name")
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	defs := s.loadDefs()
	d, ok := defs[integration]
	if !ok {
		return errAck("unknown integration: " + integration)
	}
	// A Nix enable verdict owns the run state (§10.5): the user cannot flip it.
	managed := s.managedState()
	if mi, ok := managed.Integrations[integration]; ok && mi.Enable != nil {
		return managedEnableErr(integration)
	}

	// A field-less definition (config={}, secrets={}) has no per-profile fields
	// to complete and, correspondingly, no LoadCredential[Encrypted] sources
	// (lib.nix emits none), so enable skips the completeness gate and the
	// credential staging below. Definitions WITH fields still require at least
	// one complete profile.
	if len(d.Config) > 0 || len(d.Secrets) > 0 {
		profiles, err := s.storeProfiles(d)
		if err != nil {
			return errAck("read store: " + err.Error())
		}
		// Managed complete profiles count toward the gate too.
		if mi, ok := managed.Integrations[integration]; ok {
			profiles = s.mergeManagedProfiles(d, profiles, mi)
		}
		complete := false
		for _, p := range profiles {
			if p.Complete {
				complete = true
				break
			}
		}
		if !complete {
			return errAck("no complete profile; set the required fields first")
		}
	}

	// The unit's LoadCredential[Encrypted] sources must exist at start.
	if err := s.stageStores(d, integration); err != nil {
		return errAck(err.Error())
	}

	st := s.loadState()
	st.Integrations[integration] = IntegrationState{Enabled: true}
	if err := s.saveState(st); err != nil {
		return errAck("write state: " + err.Error())
	}

	unit := socketUnit(integration)
	if msg, err := s.runSystemctl("start", unit); err != nil {
		// Roll back: enabled.json must not claim an integration whose socket
		// unit failed to start. Store survives the rollback.
		st.Integrations[integration] = IntegrationState{Enabled: false}
		if serr := s.saveState(st); serr != nil {
			log.Printf("rollback enabled.json: %v", serr)
		}
		return errAck("systemctl start failed: " + msg)
	}
	log.Printf("enable %s", integration)
	return Ack{Op: "ok"}
}

func (s *Server) disable(integration string) Ack {
	if !namePattern.MatchString(integration) {
		return errAck("invalid integration name")
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	defs := s.loadDefs()
	if _, ok := defs[integration]; !ok {
		return errAck("unknown integration: " + integration)
	}
	// A Nix enable verdict owns the run state (§10.5): the user cannot flip it.
	if mi, ok := s.managedState().Integrations[integration]; ok && mi.Enable != nil {
		return managedEnableErr(integration)
	}

	sock := socketUnit(integration)
	svc := serviceUnit(integration)
	if msg, err := s.runSystemctl("stop", sock, svc); err != nil {
		// Best-effort: the units may simply not be running. State still flips
		// to disabled so the gateway stops exposing the tools.
		log.Printf("systemctl stop %s %s: %s", sock, svc, msg)
	}

	st := s.loadState()
	st.Integrations[integration] = IntegrationState{Enabled: false}
	if err := s.saveState(st); err != nil {
		return errAck("write state: " + err.Error())
	}
	log.Printf("disable %s", integration)
	return Ack{Op: "ok"}
}

// ensureFile creates an empty file (and its 0700 parent) when absent.
func ensureFile(path string) error {
	if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			return err
		}
		return os.WriteFile(path, nil, 0o600)
	}
	return nil
}

// sealEmpty seals an empty secrets.toml so an all-optional-secret integration
// still has a `secrets` credential source at enable.
func (s *Server) sealEmpty(integration string) error {
	work, err := s.workDir("seal")
	if err != nil {
		return err
	}
	defer os.RemoveAll(work)
	empty := filepath.Join(work, "secrets.toml")
	if err := os.WriteFile(empty, nil, 0o600); err != nil {
		return err
	}
	if err := os.MkdirAll(s.storeDir(integration), 0o700); err != nil {
		return err
	}
	return s.seal(empty, s.sealedSecrets(integration))
}

// tryRestart bounces the integration's service after a successful store write.
// The unit reads its credentials from a start-time snapshot
// (LoadCredential[Encrypted]), so a running server would otherwise keep stale
// values until the next activation. `try-restart` restarts a running unit and
// no-ops an inactive one — the socket stays up either way, so the next
// connection re-activates with fresh credentials. Best-effort: the write is
// already durable, so a restart failure is logged, never surfaced as an error.
func (s *Server) tryRestart(integration string) {
	unit := serviceUnit(integration)
	if msg, err := s.runSystemctl("try-restart", unit); err != nil {
		log.Printf("systemctl try-restart %s: %s", unit, msg)
	}
}

// runSystemctl invokes the configured systemctl prefix with verb + units.
// Returns the trimmed stderr (or the exec error) alongside err.
func (s *Server) runSystemctl(verb string, units ...string) (string, error) {
	args := append(append([]string{}, s.systemctl[1:]...), verb)
	args = append(args, units...)
	cmd := exec.Command(s.systemctl[0], args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return msg, err
	}
	return "", nil
}

package main

import (
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
	"sort"
	"strings"
	"sync"
	"syscall"
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
	runtimeDir   string
	selfUid      uint32
	credsEncrypt []string // argv prefix: <prefix...> --name=secrets <in> <out>
	credsDecrypt []string // argv prefix: <prefix...> --name=secrets <in> <out>
	systemctl    []string // argv prefix: <prefix...> start|stop <units...>
	skillConfig  []string // argv prefix: <prefix...> <verb> ...
	mu           sync.Mutex
}

func NewServer(defsDir, stateDir, runtimeDir string, credsEncrypt, credsDecrypt, systemctl, skillConfig []string) *Server {
	return &Server{
		defsDir:      defsDir,
		stateDir:     stateDir,
		runtimeDir:   runtimeDir,
		selfUid:      uint32(os.Getuid()),
		credsEncrypt: credsEncrypt,
		credsDecrypt: credsDecrypt,
		systemctl:    systemctl,
		skillConfig:  skillConfig,
	}
}

func errAck(msg string) Ack { return Ack{Op: "error", Error: msg} }

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

	var raw json.RawMessage
	if err := json.NewDecoder(conn).Decode(&raw); err != nil {
		if !errors.Is(err, io.EOF) {
			_ = enc.Encode(Ack{Op: "error", Error: "malformed request"})
		}
		return
	}
	_ = enc.Encode(s.dispatch(raw))
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

func (s *Server) dispatch(raw json.RawMessage) any {
	var req Request
	if err := json.Unmarshal(raw, &req); err != nil {
		return Ack{Op: "error", Error: "malformed request"}
	}
	switch req.Op {
	case "list":
		return s.list()
	case "set-field":
		return s.setField(req.Integration, req.Profile, req.Field, req.Value)
	case "remove-profile":
		return s.removeProfile(req.Integration, req.Profile)
	case "enable":
		return s.enable(req.Integration)
	case "disable":
		return s.disable(req.Integration)
	default:
		return Ack{Op: "error", Error: "unknown op: " + req.Op}
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
		infos = append(infos, IntegrationInfo{
			Name:         name,
			Description:  d.Description,
			MultiProfile: d.MultiProfile,
			Enabled:      st.Integrations[name].Enabled,
			Config:       fieldInfos(d.Config),
			Secrets:      fieldInfos(d.Secrets),
			Profiles:     profiles,
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
	key := fmt.Sprintf("%s.%s.%s", integration, profile, field)
	if _, err := s.runSkillConfig(s.skillEnv(integration, schemaPath, secretsWork, work), "set", key, value); err != nil {
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
	if _, err := s.runSkillConfig(s.skillEnv(integration, schemaPath, secretsWork, work), "remove", integration, profile); err != nil {
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

	profiles, err := s.storeProfiles(d)
	if err != nil {
		return errAck("read store: " + err.Error())
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

	// The unit's LoadCredential[Encrypted] sources must exist at start.
	if len(d.Config) > 0 {
		if err := ensureFile(s.configFile(integration)); err != nil {
			return errAck("config store: " + err.Error())
		}
	}
	if len(d.Secrets) > 0 {
		if _, err := os.Stat(s.sealedSecrets(integration)); errors.Is(err, os.ErrNotExist) {
			if err := s.sealEmpty(integration); err != nil {
				return errAck("secrets store: " + err.Error())
			}
		}
	}

	st := s.loadState()
	st.Integrations[integration] = IntegrationState{Enabled: true}
	if err := s.saveState(st); err != nil {
		return errAck("write state: " + err.Error())
	}

	unit := fmt.Sprintf("spaces-integration-%s.socket", integration)
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

	sock := fmt.Sprintf("spaces-integration-%s.socket", integration)
	svc := fmt.Sprintf("spaces-integration-%s.service", integration)
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
	unit := fmt.Sprintf("spaces-integration-%s.service", integration)
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

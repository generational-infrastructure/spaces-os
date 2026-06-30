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

// Integration and secret names build filesystem paths and systemd unit names;
// anything outside this set is rejected before it touches either.
var namePattern = regexp.MustCompile(`^[a-z0-9-]+$`)

// Server handles one JSON request per connection. Definitions are re-read from
// defsDir on every request (a handful of small files); state mutations are
// serialised by mu. It runs as the user, so all state is that user's own:
//
//	<stateDir>/enabled.json          which integrations are on (0600)
//	<stateDir>/<integration>/<sec>   the host+tpm2 ciphertext (0700 dir)
//
// The ciphertext path matches the integration unit's
// LoadCredentialEncrypted=<sec>:%S/spaces-integrationd/<integration>/<sec>.
type Server struct {
	defsDir      string
	stateDir     string
	selfUid      uint32
	credsEncrypt []string // argv prefix, invoked as <prefix...> --name=<secret> - <dest>
	systemctl    []string // argv prefix, invoked as <prefix...> start|stop <units...>
	mu           sync.Mutex
}

func NewServer(defsDir, stateDir string, credsEncrypt, systemctl []string) *Server {
	return &Server{
		defsDir:      defsDir,
		stateDir:     stateDir,
		selfUid:      uint32(os.Getuid()),
		credsEncrypt: credsEncrypt,
		systemctl:    systemctl,
	}
}

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
	case "set-secret":
		return s.setSecret(req.Integration, req.Name, req.Value)
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
		istate := st.Integrations[name]

		secretNames := make([]string, 0, len(d.Secrets))
		for sn := range d.Secrets {
			secretNames = append(secretNames, sn)
		}
		sort.Strings(secretNames)
		secrets := make([]SecretInfo, 0, len(secretNames))
		for _, sn := range secretNames {
			secrets = append(secrets, SecretInfo{
				Name:        sn,
				Description: d.Secrets[sn].Description,
				Set:         istate.Secrets[sn],
			})
		}

		infos = append(infos, IntegrationInfo{
			Name:        name,
			Description: d.Description,
			Enabled:     istate.Enabled,
			Secrets:     secrets,
		})
	}
	return ListReply{Op: "ok", Integrations: infos}
}

func (s *Server) setSecret(integration, secret, value string) Ack {
	if !namePattern.MatchString(integration) {
		return Ack{Op: "error", Error: "invalid integration name"}
	}
	if !namePattern.MatchString(secret) {
		return Ack{Op: "error", Error: "invalid secret name"}
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	defs := s.loadDefs()
	d, ok := defs[integration]
	if !ok {
		return Ack{Op: "error", Error: "unknown integration: " + integration}
	}
	if _, ok := d.Secrets[secret]; !ok {
		return Ack{Op: "error", Error: "unknown secret: " + secret}
	}

	secretDir := filepath.Join(s.stateDir, integration)
	if err := os.MkdirAll(secretDir, 0o700); err != nil {
		return Ack{Op: "error", Error: "state dir: " + err.Error()}
	}
	// No extension: the path must equal the integration unit's
	// LoadCredentialEncrypted=<secret>:%S/spaces-integrationd/<name>/<secret>.
	dest := filepath.Join(secretDir, secret)

	args := append(append([]string{}, s.credsEncrypt[1:]...), "--name="+secret, "-", dest)
	cmd := exec.Command(s.credsEncrypt[0], args...)
	cmd.Stdin = strings.NewReader(value)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		// A failed encrypt may have created dest; leave no partial state.
		_ = os.Remove(dest)
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		log.Printf("encrypt %s/%s failed: %s", integration, secret, msg)
		return Ack{Op: "error", Error: "encrypt failed: " + msg}
	}

	st := s.loadState()
	istate := st.Integrations[integration]
	if istate.Secrets == nil {
		istate.Secrets = make(map[string]bool)
	}
	istate.Secrets[secret] = true
	st.Integrations[integration] = istate
	if err := s.saveState(st); err != nil {
		return Ack{Op: "error", Error: "write state: " + err.Error()}
	}
	log.Printf("set-secret %s/%s", integration, secret)
	return Ack{Op: "ok"}
}

func (s *Server) enable(integration string) Ack {
	if !namePattern.MatchString(integration) {
		return Ack{Op: "error", Error: "invalid integration name"}
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	defs := s.loadDefs()
	d, ok := defs[integration]
	if !ok {
		return Ack{Op: "error", Error: "unknown integration: " + integration}
	}

	st := s.loadState()
	istate := st.Integrations[integration]
	var missing []string
	for sn := range d.Secrets {
		if !istate.Secrets[sn] {
			missing = append(missing, sn)
		}
	}
	if len(missing) > 0 {
		sort.Strings(missing)
		return Ack{Op: "error", Error: "missing secrets: " + strings.Join(missing, ", ")}
	}

	istate.Enabled = true
	st.Integrations[integration] = istate
	if err := s.saveState(st); err != nil {
		return Ack{Op: "error", Error: "write state: " + err.Error()}
	}

	unit := fmt.Sprintf("spaces-integration-%s.socket", integration)
	if msg, err := s.runSystemctl("start", unit); err != nil {
		// Roll back: enabled.json must not claim an integration whose socket
		// unit failed to start. Secret state survives the rollback.
		istate.Enabled = false
		st.Integrations[integration] = istate
		if serr := s.saveState(st); serr != nil {
			log.Printf("rollback enabled.json: %v", serr)
		}
		return Ack{Op: "error", Error: "systemctl start failed: " + msg}
	}
	log.Printf("enable %s", integration)
	return Ack{Op: "ok"}
}

func (s *Server) disable(integration string) Ack {
	if !namePattern.MatchString(integration) {
		return Ack{Op: "error", Error: "invalid integration name"}
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	defs := s.loadDefs()
	if _, ok := defs[integration]; !ok {
		return Ack{Op: "error", Error: "unknown integration: " + integration}
	}

	sock := fmt.Sprintf("spaces-integration-%s.socket", integration)
	svc := fmt.Sprintf("spaces-integration-%s.service", integration)
	if msg, err := s.runSystemctl("stop", sock, svc); err != nil {
		// Best-effort: the units may simply not be running. State still flips
		// to disabled so the gateway stops exposing the tools.
		log.Printf("systemctl stop %s %s: %s", sock, svc, msg)
	}

	st := s.loadState()
	istate := st.Integrations[integration]
	istate.Enabled = false
	st.Integrations[integration] = istate
	if err := s.saveState(st); err != nil {
		return Ack{Op: "error", Error: "write state: " + err.Error()}
	}
	log.Printf("disable %s", integration)
	return Ack{Op: "ok"}
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

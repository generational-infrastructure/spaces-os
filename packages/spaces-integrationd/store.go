package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

// The store for one integration lives under <stateDir>/<name>/:
//
//	config.toml   plaintext config rows   (the `config` LoadCredential source)
//	secrets       host+tpm2-sealed secrets.toml blob (`secrets` LoadCredentialEncrypted)
//
// Writes go through skill-config (one store implementation, shared with the
// agent-facing skills). Secrets are unsealed to a tmpfs working copy for the
// edit and re-sealed, so no plaintext secret ever persists on disk. Reads for
// `list` also go through skill-config (--json), decrypting the blob into the
// same tmpfs working area.

func (s *Server) storeDir(integration string) string {
	return filepath.Join(s.stateDir, integration)
}

func (s *Server) configFile(integration string) string {
	return filepath.Join(s.storeDir(integration), "config.toml")
}

func (s *Server) sealedSecrets(integration string) string {
	return filepath.Join(s.storeDir(integration), "secrets")
}

// workDir is a per-op tmpfs scratch dir (RuntimeDirectory, memory-backed) for
// the schema file and the transient unsealed secrets.toml.
func (s *Server) workDir(tag string) (string, error) {
	base := s.runtimeDir
	if base == "" {
		base = os.TempDir()
	}
	return os.MkdirTemp(base, "store-"+tag+"-")
}

// writeSchema materialises the {config,secrets} field->description map that
// skill-config's SKILL_CONFIG_SCHEMA expects, so it routes fields to the right
// blob without any SKILL.md on disk.
func writeSchema(dir string, d Definition) (string, error) {
	m := map[string]map[string]string{"config": {}, "secrets": {}}
	for name, f := range d.Config {
		m["config"][name] = f.Description
	}
	for name, f := range d.Secrets {
		m["secrets"][name] = f.Description
	}
	data, err := json.Marshal(m)
	if err != nil {
		return "", err
	}
	p := filepath.Join(dir, "schema.json")
	return p, os.WriteFile(p, data, 0o600)
}

// skillEnv is the environment that points skill-config at this integration's
// store: the schema, the persistent config.toml, and a (tmpfs) secrets working
// copy. SPACES_PI_CHAT_STATE_DIR is pinned so instance auto-detection never
// scans /var/lib.
func (s *Server) skillEnv(integration, schemaPath, secretsWork, stateStub string) []string {
	env := append([]string{}, os.Environ()...)
	return append(env,
		"SKILL_CONFIG_SCHEMA="+schemaPath,
		"SKILL_CONFIG_CONFIG_FILE="+s.configFile(integration),
		"SKILL_CONFIG_SECRETS_FILE="+secretsWork,
		"SPACES_PI_CHAT_STATE_DIR="+stateStub,
	)
}

func (s *Server) runSkillConfig(env []string, args ...string) (string, error) {
	cmd := exec.Command(s.skillConfig[0], append(append([]string{}, s.skillConfig[1:]...), args...)...)
	cmd.Env = env
	var out, errb bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(errb.String())
		if msg == "" {
			msg = err.Error()
		}
		return "", fmt.Errorf("%s", msg)
	}
	return out.String(), nil
}

// seal encrypts plaintextFile -> dest (host+tpm2, --name=secrets). The blob is
// the `secrets` credential the integration unit decrypts read-only at start.
func (s *Server) seal(plaintextFile, dest string) error {
	args := append(append([]string{}, s.credsEncrypt[1:]...), "--name=secrets", plaintextFile, dest)
	return runCapture(s.credsEncrypt[0], args)
}

// unseal decrypts sealedFile -> plaintextDest (--name=secrets). A missing blob
// (no secret set yet) yields an empty working copy rather than an error.
func (s *Server) unseal(sealedFile, plaintextDest string) error {
	if _, err := os.Stat(sealedFile); errors.Is(err, os.ErrNotExist) {
		return os.WriteFile(plaintextDest, nil, 0o600)
	}
	args := append(append([]string{}, s.credsDecrypt[1:]...), "--name=secrets", sealedFile, plaintextDest)
	return runCapture(s.credsDecrypt[0], args)
}

func runCapture(bin string, args []string) error {
	cmd := exec.Command(bin, args...)
	var errb bytes.Buffer
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(errb.String())
		if msg == "" {
			msg = err.Error()
		}
		return fmt.Errorf("%s", msg)
	}
	return nil
}

// storeProfiles returns the provisioned profiles for an integration, with
// config values, secret set-status, and per-profile completeness against the
// schema's required fields. It decrypts the secrets blob into a tmpfs working
// copy and reads everything back via `skill-config list --json`.
func (s *Server) storeProfiles(d Definition) ([]ProfileInfo, error) {
	work, err := s.workDir("list")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(work)

	schemaPath, err := writeSchema(work, d)
	if err != nil {
		return nil, err
	}
	secretsWork := filepath.Join(work, "secrets.toml")
	if err := s.unseal(s.sealedSecrets(d.Name), secretsWork); err != nil {
		return nil, fmt.Errorf("unseal: %w", err)
	}

	out, err := s.runSkillConfig(
		s.skillEnv(d.Name, schemaPath, secretsWork, work),
		"list", d.Name, "--json",
	)
	if err != nil {
		return nil, err
	}

	var parsed struct {
		Profiles map[string]struct {
			Config  map[string]string `json:"config"`
			Secrets map[string]bool   `json:"secrets"`
		} `json:"profiles"`
	}
	if err := json.Unmarshal([]byte(out), &parsed); err != nil {
		return nil, fmt.Errorf("parse skill-config list: %w", err)
	}

	names := make([]string, 0, len(parsed.Profiles))
	for name := range parsed.Profiles {
		names = append(names, name)
	}
	sort.Strings(names)

	profiles := make([]ProfileInfo, 0, len(names))
	for _, name := range names {
		p := parsed.Profiles[name]
		if p.Config == nil {
			p.Config = map[string]string{}
		}
		if p.Secrets == nil {
			p.Secrets = map[string]bool{}
		}
		profiles = append(profiles, ProfileInfo{
			Name:     name,
			Config:   p.Config,
			Secrets:  p.Secrets,
			Complete: profileComplete(d, p.Config, p.Secrets),
		})
	}
	return profiles, nil
}

// profileComplete: every required config field has a non-empty value and every
// required secret field is set.
func profileComplete(d Definition, config map[string]string, secrets map[string]bool) bool {
	for name, f := range d.Config {
		if f.Required && config[name] == "" {
			return false
		}
	}
	for name, f := range d.Secrets {
		if f.Required && !secrets[name] {
			return false
		}
	}
	return true
}

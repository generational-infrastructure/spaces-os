package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Config holds the resolved settings for talking to a CardDAV server.
//
// Precedence (highest first): command-line flags, environment variables,
// the JSON config file. Nothing here is CardDAV-server specific: `Server`
// may be a bare domain (RFC 6764 discovery) or a full endpoint URL.
type Config struct {
	// Server is either a bare domain (e.g. "example.com") to bootstrap via
	// RFC 6764 discovery, or a full URL to a CardDAV endpoint.
	Server string `json:"server"`
	// Username for HTTP Basic authentication.
	Username string `json:"username"`
	// Password for HTTP Basic auth. Prefer PasswordCmd over storing this.
	Password string `json:"password"`
	// PasswordCmd is a shell command whose stdout (trimmed) is the password,
	// e.g. "passage show carddav". Evaluated only when Password is empty.
	PasswordCmd string `json:"passwordCmd"`
	// AddressBook is the path of the address book to operate on. When empty,
	// discovery runs and the first address book is used.
	AddressBook string `json:"addressbook"`
	// IncludePhotos controls whether inline-encoded media (base64 PHOTO/LOGO/
	// SOUND, or data: URIs) is kept in search/get output. Defaults to false so
	// bulky binary blobs do not pollute an agent's context window. The
	// `backup` command always preserves them regardless of this setting.
	IncludePhotos bool `json:"includePhotos"`
}

// configPath returns the location of the JSON config file, honouring
// XDG_CONFIG_HOME and falling back to ~/.config.
func configPath() string {
	if p := os.Getenv("CONTACTS_CONFIG"); p != "" {
		return p
	}
	base := os.Getenv("XDG_CONFIG_HOME")
	if base == "" {
		if home, err := os.UserHomeDir(); err == nil {
			base = filepath.Join(home, ".config")
		}
	}
	return filepath.Join(base, "contacts-cli", "config.json")
}

// loadConfig merges the config file, environment, and flag overrides.
func loadConfig(flags Config) (Config, error) {
	var c Config

	// 1. config file (lowest precedence)
	if data, err := os.ReadFile(configPath()); err == nil {
		if err := json.Unmarshal(data, &c); err != nil {
			return c, fmt.Errorf("parsing %s: %w", configPath(), err)
		}
	} else if !os.IsNotExist(err) {
		return c, fmt.Errorf("reading %s: %w", configPath(), err)
	}

	// 2. environment
	overlay(&c.Server, os.Getenv("CONTACTS_SERVER"))
	overlay(&c.Username, os.Getenv("CONTACTS_USERNAME"))
	overlay(&c.Password, os.Getenv("CONTACTS_PASSWORD"))
	overlay(&c.PasswordCmd, os.Getenv("CONTACTS_PASSWORD_CMD"))
	overlay(&c.AddressBook, os.Getenv("CONTACTS_ADDRESSBOOK"))
	if v := os.Getenv("CONTACTS_INCLUDE_PHOTOS"); v != "" {
		c.IncludePhotos = truthy(v)
	}

	// 3. flags (highest precedence)
	overlay(&c.Server, flags.Server)
	overlay(&c.Username, flags.Username)
	overlay(&c.Password, flags.Password)
	overlay(&c.PasswordCmd, flags.PasswordCmd)
	overlay(&c.AddressBook, flags.AddressBook)

	if c.Server == "" {
		return c, fmt.Errorf("no server configured (set --server, CONTACTS_SERVER, or config file)")
	}
	if c.Username == "" {
		return c, fmt.Errorf("no username configured (set --username, CONTACTS_USERNAME, or config file)")
	}
	return c, nil
}

// overlay sets *dst to v when v is non-empty.
func overlay(dst *string, v string) {
	if v != "" {
		*dst = v
	}
}

// truthy interprets common affirmative env-var spellings as true.
func truthy(s string) bool {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "1", "true", "yes", "on":
		return true
	}
	return false
}

// resolvePassword returns the password, running PasswordCmd if needed.
func (c Config) resolvePassword() (string, error) {
	if c.Password != "" {
		return c.Password, nil
	}
	if c.PasswordCmd == "" {
		return "", fmt.Errorf("no password available (set CONTACTS_PASSWORD or passwordCmd)")
	}
	out, err := exec.Command("sh", "-c", c.PasswordCmd).Output()
	if err != nil {
		return "", fmt.Errorf("password command %q failed: %w", c.PasswordCmd, err)
	}
	return strings.TrimRight(string(out), "\r\n"), nil
}

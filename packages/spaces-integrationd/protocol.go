package main

// Protocol messages for the spaces-integrationd socket.
//
// One JSON request per connection, one JSON reply, then close. The broker runs
// as the user in their own --user manager; SO_PEERCRED authenticates only that
// the caller is the SAME uid (a sibling user cannot reach %t/spaces-
// integrations.sock anyway — its dir is 0700 — but the check is the explicit
// authorisation primitive). Every op acts on this one user's own state.
//
// The store is a unified, profile-keyed skill-config store (config.toml +
// host+tpm2-sealed secrets blob) per integration; profiles are rows inside, so
// multi-account needs no rebuild. Contract:
// docs/agent-integrations-skill-migration-plan.md.

// client -> daemon. Op is one of "list", "set-field", "remove-profile",
// "enable", "disable". Integration is required for everything but "list";
// Profile for set-field/remove-profile; Field/Value only for set-field.
type Request struct {
	Op          string `json:"op"`
	Integration string `json:"integration,omitempty"`
	Profile     string `json:"profile,omitempty"`
	Field       string `json:"field,omitempty"`
	Value       string `json:"value,omitempty"`
}

// daemon -> client, terminal reply for set-field/remove-profile/enable/disable
// and the error case of every op.
type Ack struct {
	Op    string `json:"op"`              // "ok" | "error"
	Error string `json:"error,omitempty"` // populated on op=="error"
}

// daemon -> client, reply to "list".
type ListReply struct {
	Op           string            `json:"op"` // "ok"
	Integrations []IntegrationInfo `json:"integrations"`
}

type IntegrationInfo struct {
	Name         string        `json:"name"`
	Description  string        `json:"description"`
	MultiProfile bool          `json:"multiProfile"`
	Enabled      bool          `json:"enabled"`
	Config       []FieldInfo   `json:"config"`   // schema (sorted by name)
	Secrets      []FieldInfo   `json:"secrets"`  // schema (sorted by name)
	Profiles     []ProfileInfo `json:"profiles"` // provisioned accounts
}

type FieldInfo struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	Required    bool   `json:"required"`
}

type ProfileInfo struct {
	Name string `json:"name"`
	// Config field values (non-secret). Secret field -> set? (never the value).
	Config   map[string]string `json:"config"`
	Secrets  map[string]bool   `json:"secrets"`
	Complete bool              `json:"complete"` // all required fields present
}

// Definition mirrors the world-readable /etc/spaces-integrations/<name>.json the
// materialiser emits. The broker needs the field schema (to route config vs
// secret and gate completeness) + multiProfile for the panel; posture
// (network/ports) and the gateway's autoRun allowlist are other consumers'
// concerns and ignored here (unknown JSON fields are dropped).
type Definition struct {
	Name         string                 `json:"name"`
	Description  string                 `json:"description"`
	MultiProfile bool                   `json:"multiProfile"`
	Config       map[string]FieldSchema `json:"config"`
	Secrets      map[string]FieldSchema `json:"secrets"`
}

type FieldSchema struct {
	Description string `json:"description"`
	Required    bool   `json:"required"`
}

// Persistent state at <state>/enabled.json (no secrets): which integrations are
// on. Everything else (profiles, field values, secret set-status) is derived
// from the per-integration store, never duplicated here.
type EnabledState struct {
	Integrations map[string]IntegrationState `json:"integrations"`
}

type IntegrationState struct {
	Enabled bool `json:"enabled"`
}

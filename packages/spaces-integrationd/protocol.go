package main

// Protocol messages for the spaces-integrationd socket.
//
// One JSON request per connection, one JSON reply, then close. The broker runs
// as the user in their own --user manager; SO_PEERCRED authenticates only that
// the caller is the SAME uid (a sibling user cannot reach %t/spaces-
// integrations.sock anyway — its dir is 0700 — but the check is the explicit
// authorisation primitive). Every op acts on this one user's own state.
//
// Contract: docs/agent-integrations-poc-plan.md (step 2).

// client -> daemon. Op is one of "list", "set-secret", "enable", "disable".
// Integration is required for everything but "list"; Name/Value only for
// "set-secret".
type Request struct {
	Op          string `json:"op"`
	Integration string `json:"integration,omitempty"`
	Name        string `json:"name,omitempty"`
	Value       string `json:"value,omitempty"`
}

// daemon -> client, terminal reply for set-secret/enable/disable and the error
// case of every op.
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
	Name        string       `json:"name"`
	Description string       `json:"description"`
	Enabled     bool         `json:"enabled"`
	Secrets     []SecretInfo `json:"secrets"`
}

type SecretInfo struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	Set         bool   `json:"set"`
}

// Definition mirrors the world-readable /etc/spaces-integrations/<name>.json the
// materialiser emits. The broker needs only names + secret descriptions for the
// panel's provisioning form; posture (network/ports) and the gateway's autoRun
// allowlist are other consumers' concerns and ignored here (unknown JSON fields
// are dropped). Tool SCHEMAS are discovered at runtime, never declared.
type Definition struct {
	Name        string               `json:"name"`
	Description string               `json:"description"`
	Secrets     map[string]SecretDef `json:"secrets"`
}

type SecretDef struct {
	Description string `json:"description"`
}

// Persistent state at <state>/enabled.json (no secrets): which integrations are
// on, and which of their secrets have ciphertext present on disk.
type EnabledState struct {
	Integrations map[string]IntegrationState `json:"integrations"`
}

type IntegrationState struct {
	Enabled bool            `json:"enabled"`
	Secrets map[string]bool `json:"secrets"` // true = ciphertext present
}

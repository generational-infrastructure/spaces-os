package main

// Protocol messages for the spaces-integrationd socket.
//
// One JSON request per connection, one JSON reply, then close — except "setup",
// which keeps the connection open and streams SetupEvent NDJSON lines. The
// broker runs as the user in their own --user manager; SO_PEERCRED authenticates only that
// the caller is the SAME uid (a sibling user cannot reach %t/spaces-
// integrations.sock anyway — its dir is 0700 — but the check is the explicit
// authorisation primitive). Every op acts on this one user's own state.
//
// The store is a unified, profile-keyed skill-config store (config.toml +
// host+tpm2-sealed secrets blob) per integration; profiles are rows inside, so
// multi-account needs no rebuild. Contract:
// docs/agent-integrations-skill-migration-plan.md.

// client -> daemon. Op is one of "list", "set-field", "remove-profile",
// "enable", "disable", "setup". Integration is required for everything but
// "list"; Profile for set-field/remove-profile; Field/Value only for set-field.
// "setup" keeps the connection open and streams SetupEvent NDJSON lines.
type Request struct {
	Op string `json:"op"`
	// Action selects the setup helper's mode on the setup channel: "" or
	// "link" (default device-linking) or "remove" (drive the helper's vendor
	// removal). Only meaningful for op=="setup". Request.Action stays
	// client-only: the broker never constructs a Request; for broker-driven
	// removes (op=="remove-profile") it writes the equivalent setupAction
	// NDJSON line (writeSetupAction) directly to the helper socket.
	Action      string `json:"action,omitempty"`
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

// SetupEvent is one NDJSON line on the long-lived setup channel (broker ->
// panel). The broker relays the helper's lines verbatim and only ever
// synthesises the "error" variant itself (validation/transport failures). The
// v2 vocabulary (docs/agent-integrations-design.md §5.5): qr | message | done |
// error | text-field | secret-field are relayed to the panel; set-field is
// broker-consumed (executed via the setField path, never relayed). Unknown
// future events keep flowing to the panel unmodified.
type SetupEvent struct {
	Event string `json:"event"`
	Error string `json:"error,omitempty"`
	// text-field/secret-field prompts carry Field + Label (relayed). The
	// broker-consumed set-field carries Profile + Field + Value (executed, never
	// relayed — the value must not reach the panel). Panels answer a prompt with
	// a bare {"value":...} line, not a SetupEvent.
	Field   string `json:"field,omitempty"`
	Label   string `json:"label,omitempty"`
	Profile string `json:"profile,omitempty"`
	Value   string `json:"value,omitempty"`
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
	Setup        bool          `json:"setup"`    // definition exposes a setup flow
	// EnabledByNix is the Nix enable verdict (true|false); absent = no Nix
	// opinion (user autonomy). The GUI renders a static enable label when set.
	EnabledByNix *bool `json:"enabledByNix,omitempty"`
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
	// Managed marks a Nix-managed (read-only) profile. Shadowed marks that this
	// managed profile replaces a same-named user profile (GUI subtitle hint);
	// the user copy is never deleted and reappears when the Nix config is gone.
	Managed  bool `json:"managed,omitempty"`
	Shadowed bool `json:"shadowed,omitempty"`
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
	// setup=true when the manifest defines a setup command (lib.nix emits it):
	// the panel gates its Link/Setup button on it and the broker gates the
	// `setup` op on it. extraServices are the full user unit names the broker
	// try-restarts after a successful setup so a fresh link/state is picked up.
	Setup         bool     `json:"setup"`
	ExtraServices []string `json:"extraServices"`
	// setupPark names user units the broker stops for the duration of a setup
	// flow (link or remove) and starts again on the way out — single-instance
	// vendor daemons (e.g. Proton Bridge) the sandboxed helper must displace to
	// spawn its own transient instance. Default []; lib.nix lowers the
	// manifest's setupPark field.
	SetupPark []string `json:"setupPark"`
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
	// Source records provenance: "nix" when a Nix enable verdict set this entry
	// (reconcile owns it), empty for a user (GUI) enable. A "nix" entry whose
	// verdict later disappears is dropped by reconcile, restoring user autonomy.
	Source string `json:"source,omitempty"`
}

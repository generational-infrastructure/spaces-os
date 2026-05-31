package main

// Protocol messages for the skill-config-daemon socket.
//
// Two roles share the same socket:
//
//   - CLI (skill-config request-input): opens a connection, sends a Request,
//     receives an immediate Registered, then blocks until the daemon sends
//     a terminal Reply (Submitted, Cancelled, or Timeout).
//
//   - Frontend: opens a connection, sends List/Submit/Cancel, receives one
//     reply, closes.
//
// Each frame is a single line of newline-terminated JSON.

// CLI -> daemon
type Request struct {
	Op          string `json:"op"` // "request"
	Skill       string `json:"skill"`
	Profile     string `json:"profile"`
	Field       string `json:"field"`
	Description string `json:"description"`
	Secret      bool   `json:"secret"`
	TimeoutSecs int    `json:"timeout_secs,omitempty"` // 0 = use server default
}

// daemon -> CLI (immediate)
type Registered struct {
	Op        string `json:"op"` // "registered"
	RequestID string `json:"request_id"`
}

// daemon -> CLI (terminal — exactly one of these)
type Reply struct {
	Op    string `json:"op"`              // "submitted" | "cancelled" | "timeout"
	Value string `json:"value,omitempty"` // present iff op=="submitted"
}

// frontend -> daemon
type ListReq   struct{ Op string `json:"op"` } // "list"
type SubmitReq struct {
	Op        string `json:"op"` // "submit"
	RequestID string `json:"request_id"`
	Value     string `json:"value"`
}
type CancelReq struct {
	Op        string `json:"op"` // "cancel"
	RequestID string `json:"request_id"`
}

// daemon -> frontend
type PendingEntry struct {
	RequestID   string `json:"request_id"`
	Skill       string `json:"skill"`
	Profile     string `json:"profile"`
	Field       string `json:"field"`
	Description string `json:"description"`
	Secret      bool   `json:"secret"`
}
type ListReply struct {
	Requests []PendingEntry `json:"requests"`
}
type Ack struct {
	Op    string `json:"op"`              // "ok" | "error"
	Error string `json:"error,omitempty"` // populated on op=="error"
}

// frontend -> daemon (kept open for the lifetime of the subscription)
type SubscribeReq struct{ Op string `json:"op"` } // "subscribe"

// daemon -> subscriber. Instance is the value of $SPACES_PI_CHAT_INSTANCE the
// daemon was started with — same value for every event from a given socket.
// Plugins use it both to label which session asked for input, and to know
// which socket to send submit/cancel back to.
type Snapshot struct {
	Op       string         `json:"op"`       // "snapshot"
	Instance string         `json:"instance"`
	Requests []PendingEntry `json:"requests"`
}
type Added struct {
	Op       string       `json:"op"`       // "added"
	Instance string       `json:"instance"`
	Request  PendingEntry `json:"request"`
}
type Removed struct {
	Op        string `json:"op"`         // "removed"
	Instance  string `json:"instance"`
	RequestID string `json:"request_id"`
}

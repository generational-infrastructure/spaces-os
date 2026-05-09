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

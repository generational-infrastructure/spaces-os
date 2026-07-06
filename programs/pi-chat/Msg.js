.pragma library
// The message-entry record, as a module. .pragma library = stateless
// singleton, no QML scope — same pattern as BarParse.js, and unit-
// checked the same way (checks/pi-chat-msg-schema).
//
// Every bubble in a session's `messages` array is one flat record:
//
//   { id, from, text, ts, state, tries, ack, image, replyTo, type }
//
//   from  ∈ "me" | "peer"
//   state ∈ "sent" | "streaming"
//   type  ∈ "" (plain chat text) | "notification" | "confirm"
//         | "prompt" | "thinking" | "approval"
//
// plus per-kind extras (confirmTitle/confirmState, approval*,
// prompt*) carried only by the matching type. The record shape is a
// wire/persistence contract shared with the test probes and sibling
// clients — constructors here are the ONLY place it is built, so a
// forgotten field is a bug in one function instead of in whichever of
// nine call sites drifted. Consumers discriminate through the
// predicates below, never by poking `type` strings inline.

// ── constructors (one per message kind) ──────────────────────────────

function _base(id, from, ts) {
  return {
    id: id,
    from: from,
    text: "",
    ts: (ts === undefined || ts === null) ? Date.now() : ts,
    state: "sent",
    tries: 0,
    ack: "",
    image: "",
    replyTo: "",
    type: "",
  };
}

// Plain user text (optimistic local echo, remote mirror, history import).
function user(id, text, ts, replyTo) {
  const m = _base(id, "me", ts);
  m.text = text;
  m.replyTo = replyTo || "";
  return m;
}

// User image attachment: the path renders immediately; the base64
// payload travels in the prompt command, not in the record.
function userImage(id, path, ts, replyTo) {
  const m = _base(id, "me", ts);
  m.image = path;
  m.replyTo = replyTo || "";
  return m;
}

// Completed assistant text (history import).
function assistant(id, text, ts) {
  const m = _base(id, "peer", ts);
  m.text = text;
  return m;
}

// Assistant text bubble that is still receiving deltas.
function assistantStream(id, ts) {
  const m = _base(id, "peer", ts);
  m.state = "streaming";
  return m;
}

// Reasoning stream; rendered faded, hideable via visible() below.
function thinking(id, ts) {
  const m = _base(id, "peer", ts);
  m.state = "streaming";
  m.type = "thinking";
  return m;
}

// Centered system line (tool executions, retry notices, extension notify).
function notification(id, text, ts) {
  const m = _base(id, "peer", ts);
  m.text = text;
  m.type = "notification";
  return m;
}

// Shell-command confirmation card (extension_ui_request "confirm").
// confirmState ∈ pending | allowed | denied | resolved.
function confirm(id, text, ts, title) {
  const m = _base(id, "peer", ts);
  m.text = text;
  m.type = "confirm";
  m.confirmTitle = title || "Run shell command?";
  m.confirmState = "pending";
  return m;
}

// Integration tool-call approval card (gateway approval_request).
// meta: { integration, tool, args } — args already JSON-pretty-printed
// by the caller (it owns the event shape). approvalState ∈ pending |
// once | session | deny.
function approval(id, ts, meta) {
  meta = meta || {};
  const m = _base(id, "peer", ts);
  m.type = "approval";
  m.approvalIntegration = meta.integration || "";
  m.approvalTool = meta.tool || "";
  m.approvalArgs = meta.args || "";
  m.approvalState = "pending";
  return m;
}

// Skill-config credential request card (skill-config daemon).
// meta: { instance, skill, profile, field, secret }. promptState ∈
// pending | submitted | cancelled | retracted.
function prompt(id, text, ts, meta) {
  meta = meta || {};
  const m = _base(id, "peer", ts);
  m.text = text;
  m.type = "prompt";
  m.promptInstance = meta.instance || "";
  m.promptSkill = meta.skill || "";
  m.promptProfile = meta.profile || "";
  m.promptField = meta.field || "";
  m.promptSecret = !!meta.secret;
  m.promptState = "pending";
  return m;
}

// ── predicates ───────────────────────────────────────────────────────
// `type` may be absent on legacy records and stub fixtures, so every
// predicate reads it through the empty-string default.

function _type(m) { return (m && m.type) || ""; }

function isMine(m)         { return !!m && m.from === "me"; }
function isNotification(m) { return _type(m) === "notification"; }
function isConfirm(m)      { return _type(m) === "confirm"; }
function isPrompt(m)       { return _type(m) === "prompt"; }
function isThinking(m)     { return _type(m) === "thinking"; }
function isApproval(m)     { return _type(m) === "approval"; }

// Plain chat text — the empty-type case every ad-hoc `(m.type||"")===""`
// check used to spell out.
function isPlain(m) { return !!m && _type(m) === ""; }

// Assistant prose (streaming or settled): what "the assistant said",
// as opposed to its thinking, tool notices, or interaction cards.
function isPlainAssistant(m) { return !!m && m.from === "peer" && _type(m) === ""; }

// A prompt card still awaiting the user (absent promptState = pending);
// the retract sweeps in PiChatBackend gate on this.
function isPendingPrompt(m) {
  return isPrompt(m) && ((m.promptState === undefined || m.promptState === null)
    ? "pending" : m.promptState) === "pending";
}

// Slice of `messages` the history view renders given the "hide
// thinking" toggle. Never mutates — toggling reveals previously hidden
// bubbles in place rather than replaying them.
function visible(messages, showThinking) {
  if (showThinking) return messages;
  return messages.filter(m => !isThinking(m));
}

// ── patch helpers (streaming updates) ────────────────────────────────
// Pure array-in/array-out: callers reassign the whole property so QML
// change notification fires. Missing id returns the input array
// untouched (identity) — no half-copied allocation for a stale patch.

function patch(messages, id, props) {
  const i = messages.findIndex(m => m.id === id);
  if (i < 0) return messages;
  const arr = messages.slice();
  arr[i] = Object.assign({}, arr[i], props);
  return arr;
}

// Grow a streaming bubble by one delta.
function appendDelta(messages, id, delta) {
  const i = messages.findIndex(m => m.id === id);
  if (i < 0) return messages;
  const arr = messages.slice();
  arr[i] = Object.assign({}, arr[i], { text: arr[i].text + (delta || "") });
  return arr;
}

// Settle a streaming bubble: state → sent; a non-empty final `content`
// (text_end / thinking_end carry the full text) replaces the
// accumulated deltas, an empty one keeps them.
function finalizeStream(messages, id, content) {
  const i = messages.findIndex(m => m.id === id);
  if (i < 0) return messages;
  const arr = messages.slice();
  arr[i] = Object.assign({}, arr[i], { state: "sent", text: content || arr[i].text });
  return arr;
}

// Drop a bubble (empty thinking blocks are removed on thinking_end).
function remove(messages, id) {
  const i = messages.findIndex(m => m.id === id);
  if (i < 0) return messages;
  const arr = messages.slice();
  arr.splice(i, 1);
  return arr;
}

.pragma library
.import "Msg.js" as Msg
// The pi-event → conversation-state fold, as a pure module. Same
// .pragma library pattern as Msg.js, unit-checked the same way
// (checks/pi-chat-reducer) and cross-checked against the pi-web PWA's
// reducer (packages/pi-web/reducer.ts) through the shared fixture
// corpus in checks/pi-chat-reducer/fixtures — both clients fold the
// same daemon event grammar, so a drift between them turns a check red.
//
// Interface:
//
//   initial()                    → state
//   apply(state, ev, now)        → { state, effects }
//   importHistory(state, piMessages, now) → state
//
// `state` is a plain object — the slice of PiSession the fold owns:
//
//   messages                  the bubble array (Msg.js records)
//   typing                    agent_start → first text delta
//   busy                      a prompt turn is in flight (cleared on agent_end)
//   lastError                 last surfaced failure text ("" = none)
//   streamingId / thinkingId  bubble currently receiving deltas
//   assistantStartedAt        wall-clock stamp of the first text_start,
//   assistantLastTextBubbleId   for the tokens/second patch on message_end
//   pendingExtensionUI        unanswered extension_ui_request ids
//
// apply() never mutates its input: untouched fields keep their identity
// so the adapter (PiSession) can assign back only what changed and QML
// change signals fire exactly as often as before the extraction.
//
// `effects` are the fold's requests to the impure world, in order:
//
//   { kind: "notify", text }     → PiSession.incomingNotification(text)
//   { kind: "send", command }    → PiSession._send(command)
//   { kind: "log", args: […] }   → Logger.w("PiSession", id, …args)
//
// The `response` envelope never reaches this module — request/response
// correlation and model bookkeeping are transport concerns PiSession
// keeps; only the get_messages history payload comes back in through
// importHistory().

function initial() {
  return {
    messages: [],
    typing: false,
    busy: false,
    lastError: "",
    streamingId: "",
    thinkingId: "",
    assistantStartedAt: 0,
    assistantLastTextBubbleId: "",
    pendingExtensionUI: {},
  };
}

function _append(s, entry) {
  s.messages = s.messages.concat([entry]);
}

function apply(state, ev, now) {
  const s = Object.assign({}, state);
  const effects = [];
  if (!ev) return { state: s, effects: effects };

  switch (ev.type) {
  case "agent_start":
    s.typing = true;
    break;

  case "message_update":
    _messageUpdate(s, ev, now);
    break;

  case "agent_end":
    s.typing = false;
    s.busy = false;
    _finalizeStreaming(s);
    if (s.lastError) s.lastError = "";
    s.assistantStartedAt = 0;
    s.assistantLastTextBubbleId = "";
    break;

  // Lifecycle markers from pi >=0.70. Bracket events around every
  // committed message (user *and* assistant). For user messages we mirror
  // pi's content into a panel bubble so *sibling* clients (n:m sync)
  // see what was typed in a different client; the originator dedups
  // against its own optimistic bubble added in send(). Assistant text
  // arrives via message_update / text_delta so message_start/message_end
  // for the assistant side stays a quiet bracket.
  case "turn_start":
  case "turn_end":
    break;

  case "message_start":
    if (ev.message && ev.message.role === "user") {
      _mirrorRemoteUserMessage(s, ev.message, now);
    }
    break;

  case "message_end":
    _messageEnd(s, ev, now);
    break;

  case "tool_execution_start": {
    const summary = _summarizeTool(ev.toolName, ev.args);
    if (summary) {
      _append(s, Msg.notification("tool-" + (ev.toolCallId || now.toString(36)), summary, now));
    }
    break;
  }

  case "auto_retry_start":
    _appendNotice(s, "retrying (" + (ev.attempt || 1) + "): " + (ev.errorMessage || ""), now);
    break;

  case "auto_retry_end":
    if (!ev.success && ev.finalError) {
      s.lastError = ev.finalError;
    }
    break;

  case "extension_ui_request":
    _extensionRequest(s, ev, now, effects);
    break;

  case "extension_error":
    effects.push({ kind: "log", args: ["extension error", ev.error] });
    break;

  case "queue_update":
  case "session_info_changed":
  case "compaction_start":
  case "compaction_end":
  case "thinking_level_changed":
    // No-op for the chat panel.
    break;

  default:
    // Unrecognized but well-formed event. Log once at debug to keep
    // the journal quiet during pi version skews.
    effects.push({ kind: "log", args: ["unknown event", ev.type] });
  }

  return { state: s, effects: effects };
}

function _messageUpdate(s, ev, now) {
  const me = ev.assistantMessageEvent;
  if (!me) return;
  if (me.type === "text_start") {
    s.streamingId = "stream-" + now.toString(36);
    _append(s, Msg.assistantStream(s.streamingId, now));
    s.typing = false;
    // First text bubble of this assistant message starts the wall
    // clock for the tps calculation; the last text bubble wins as
    // the patch target when message_end arrives with usage.
    if (s.assistantStartedAt === 0) s.assistantStartedAt = now;
    s.assistantLastTextBubbleId = s.streamingId;
  } else if (me.type === "text_delta") {
    if (!s.streamingId) _messageUpdate(s, { assistantMessageEvent: { type: "text_start" } }, now);
    s.messages = Msg.appendDelta(s.messages, s.streamingId, me.delta);
  } else if (me.type === "text_end") {
    s.messages = Msg.finalizeStream(s.messages, s.streamingId, me.content);
    s.streamingId = "";
  } else if (me.type === "thinking_start") {
    s.thinkingId = "thinking-" + now.toString(36);
    _append(s, Msg.thinking(s.thinkingId, now));
  } else if (me.type === "thinking_delta") {
    if (!s.thinkingId) return;
    s.messages = Msg.appendDelta(s.messages, s.thinkingId, me.delta);
  } else if (me.type === "thinking_end") {
    if (!s.thinkingId) return;
    const cur = s.messages.find(x => x.id === s.thinkingId);
    if (cur) {
      const finalText = me.content || cur.text;
      // Empty thinking block (omitted/summarized) — remove it.
      if (!finalText) s.messages = Msg.remove(s.messages, s.thinkingId);
      else s.messages = Msg.finalizeStream(s.messages, s.thinkingId, finalText);
    }
    s.thinkingId = "";
  }
}

function _finalizeStreaming(s) {
  if (s.streamingId) {
    s.messages = Msg.patch(s.messages, s.streamingId, { state: "sent" });
    s.streamingId = "";
  }
  if (s.thinkingId) {
    s.messages = Msg.patch(s.messages, s.thinkingId, { state: "sent" });
    s.thinkingId = "";
  }
}

// Attach inference-speed (tokens/second) to the last text bubble of
// the assistant message that just ended. Pi forwards the full
// AgentMessage including provider usage on `message_end`; we use
// usage.output (output token count) over the wall clock since the
// first text_start. Skipped if usage is absent, output is zero, no
// bubble exists yet, or the elapsed clock is too small to be useful.
// The Panel renders this only when Settings.data.showInferenceSpeed
// is enabled, so unconditionally patching is safe.
function _messageEnd(s, ev, now) {
  const msg = ev.message;
  if (!msg || msg.role !== "assistant") return;
  const output = (msg.usage && msg.usage.output) || 0;
  if (output <= 0) return;
  if (!s.assistantLastTextBubbleId || s.assistantStartedAt === 0) return;
  const elapsedMs = now - s.assistantStartedAt;
  if (elapsedMs < 50) return;
  const tps = output / (elapsedMs / 1000);
  s.messages = Msg.patch(s.messages, s.assistantLastTextBubbleId, { tps: tps, outputTokens: output });
  // Reset for the next assistant message in this turn (tool → text again).
  s.assistantStartedAt = 0;
  s.assistantLastTextBubbleId = "";
}

function _summarizeTool(name, args) {
  if (!name) return "";
  if (name === "bash") return "$ " + String((args && args.command) || "").split("\n")[0].slice(0, 80);
  if (name === "read") return "read " + String((args && args.path) || "");
  if (name === "edit") return "edit " + String((args && args.path) || "");
  if (name === "write") return "write " + String((args && args.path) || "");
  return name;
}

function _appendNotice(s, text, now) {
  _append(s, Msg.notification("notice-" + now.toString(36), text, now));
}

function _extensionRequest(s, ev, now, effects) {
  if (ev.method === "confirm") {
    s.pendingExtensionUI = Object.assign({}, s.pendingExtensionUI);
    s.pendingExtensionUI[ev.id] = true;
    _append(s, Msg.confirm(ev.id, ev.message, now, ev.title));
    effects.push({ kind: "notify", text: ev.title || "confirm" });
    return;
  }
  if (ev.method === "notify") {
    _appendNotice(s, ev.message, now);
    return;
  }
  if (ev.method === "select" || ev.method === "input" || ev.method === "editor") {
    // No UI yet — auto-cancel so pi doesn't hang on the agent loop.
    effects.push({ kind: "send", command: { type: "extension_ui_response", id: ev.id, cancelled: true } });
    return;
  }
  // setStatus / setWidget / setTitle / set_editor_text are
  // fire-and-forget; ignore them.
}

// Fold a get_messages history payload (pi AgentMessages) into panel
// bubbles, prepended before whatever is already live. Text parts are
// joined; tool-call-only and malformed entries are skipped. A replay
// whose conversation is already on screen — the panel kept its bubbles
// across an idle stop (window closed → reap → reopen), or the daemon's
// attach-time event replay rebuilt the same turns — is dropped instead
// of prepended, or every bubble would render twice.
function importHistory(state, piMessages, now) {
  if (!Array.isArray(piMessages)) return state;
  const out = [];
  for (const m of piMessages) {
    if (!m || !m.role || !Array.isArray(m.content)) continue;
    const text = m.content
      .filter(c => c && c.type === "text")
      .map(c => c.text)
      .join("\n")
      .trim();
    if (!text) continue;
    const id = "hist-" + out.length + "-" + now.toString(36);
    const ts = m.timestamp || now;
    out.push(m.role === "user" ? Msg.user(id, text, ts, "") : Msg.assistant(id, text, ts));
  }
  if (out.length === 0) return state;
  if (_historyRepresented(state.messages, out)) return state;
  const s = Object.assign({}, state);
  s.messages = out.concat(s.messages);
  return s;
}

// True when the imported history carries nothing the panel isn't
// already showing. Compared through a plain-chat projection: only
// user/assistant prose counts (thinking, tool notices, and cards never
// appear in the daemon's history) and consecutive same-role texts join
// with "\n" — the live fold renders one bubble per text block while
// importHistory folds a whole AgentMessage into one, so run-joining is
// what makes the two granularities comparable. History already shown ⇔
// its runs are a prefix of the live runs; the last history run may
// itself be a text-prefix of the matching live run (the live side keeps
// growing while the get_messages response is in flight). On any
// mismatch we fall back to prepending — never drop unseen turns.
function _historyRepresented(existing, imported) {
  const h = _chatRuns(imported);
  const s = _chatRuns(existing);
  if (h.length === 0 || h.length > s.length) return false;
  for (let i = 0; i < h.length; i++) {
    if (s[i].role !== h[i].role) return false;
    if (s[i].text === h[i].text) continue;
    if (i === h.length - 1 && s[i].text.indexOf(h[i].text + "\n") === 0) continue;
    return false;
  }
  return true;
}

// Project bubbles into (role, text) runs of plain chat prose:
// non-prose bubbles are skipped, consecutive same-role texts join
// with "\n".
function _chatRuns(messages) {
  const runs = [];
  for (const m of messages) {
    if (!Msg.isPlain(m)) continue;
    const text = (m.text || "").trim();
    if (!text) continue;
    const last = runs.length > 0 ? runs[runs.length - 1] : null;
    if (last && last.role === m.from) last.text += "\n" + text;
    else runs.push({ role: m.from, text: text });
  }
  return runs;
}

// Append a user bubble from a pi message_start event when it didn't
// originate locally — i.e. another client (the PWA, another panel)
// attached to the same daemon session sent the prompt. The originating
// client's send() already added an optimistic "me" bubble; dedup by
// matching the most recent user bubble's text, scanning at most a 30s
// window so a legitimate identical prompt far later still renders.
function _mirrorRemoteUserMessage(s, message, now) {
  const text = _extractUserMessageText(message);
  if (!text) return;
  const cutoff = now - 30000;
  for (let i = s.messages.length - 1; i >= 0; i--) {
    const m = s.messages[i];
    if (!m || (m.ts || 0) < cutoff) break;
    if (Msg.isMine(m) && m.text === text) return; // own echo
  }
  _append(s, Msg.user(
    "user-" + now.toString(36) + "-" + Math.floor(Math.random() * 1e6).toString(36),
    text, message.timestamp || now, ""));
}

function _extractUserMessageText(message) {
  if (!message) return "";
  const c = message.content;
  if (typeof c === "string") return c;
  if (!Array.isArray(c)) return "";
  let out = "";
  for (const part of c) {
    if (part && part.type === "text" && typeof part.text === "string") {
      out += (out ? "\n" : "") + part.text;
    }
  }
  return out.trim();
}

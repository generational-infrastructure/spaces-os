// One chat session on a pi-sessiond executor, plus all the in-memory
// state the chat panel binds against. Lives inside PiChatBackend's
// reconciler so the lifecycle tracks the sessionsList.
//
// Transport: a WebSocket executor connection (PiExecutor). The daemon
// assigns a session id on create_session (or we re-attach to a
// persisted one); commands ride `command` envelopes carrying pi's own
// RPC shapes, events come back as `event` envelopes whose payload is
// fed to _handleEvent:
//
//   send  { type: "prompt", message, images? }
//         { type: "abort" }
//         { type: "get_messages" }
//         { type: "get_available_models" }
//         { type: "set_model", provider, modelId }
//         { type: "set_memory", enabled }
//         { type: "extension_ui_response", id, confirmed | value | cancelled }
//
//   recv  { type: "agent_start" }
//         { type: "message_update", assistantMessageEvent: { type, delta?, … }, message }
//         { type: "agent_end", messages }
//         { type: "tool_execution_start", toolName, args }
//         { type: "auto_retry_start" | "auto_retry_end", attempt, … }
//         { type: "extension_ui_request", id, method, … }
//         { type: "response", command, success, data?, error? }
//
// The component does not touch sessions.json — PiChatBackend persists
// the index. Conversation history lives daemon-side in session.jsonl,
// replayed via get_messages on every (re)attach.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Msg.js" as Msg
import "Reducer.js" as Reducer

QtObject {
  id: session

  // ── persisted by the backend ──
  required property string sessionId
  property string sessionName: "Chat"
  property string workspacePath
  property bool   trusted: false
  property int    unread: 0
  // last-selected model, "" = use the default from settings.json
  property string modelPref: ""

  // ── deployment env (set by the backend before spawn) ──
  property var    backend: null      // PiChatBackend, used for skill-config socket sends
  // The panel↔daemon correspondence registry (SessionRegistry). Owns
  // the daemonSessionId stamp on this entry: creates announce
  // themselves via beginCreate/resolveCreate/failCreate, and dropped
  // bindings (restart, stale recovery) release through it. Null when
  // this session runs without a backend (transport-level checks) — all
  // registry calls are guarded no-ops then.
  property var    registry: null
  // The pi-sessiond executor this session lives on (PiExecutor). Null
  // until the backend resolves the entry's executor id — spawn() is a
  // guarded no-op then.
  property var    executor: null
  // Long-term memory: per-session opt-out. Toggling sends `set_memory`
  // to the executor, which writes/removes the session's `memory-off`
  // marker; the memory extension picks that up on the next prompt
  // without a respawn.
  property bool   memoryEnabled: true

  // ── live state observable by Panel.qml via PiChatBackend.chat ──
  property string peerName: sessionName
  property bool   streaming: false   // process is up & RPC-ready
  property bool   busy: false        // a prompt turn is in flight (send → agent_end)
  property bool   typing: false      // agent_start → first delta
  property string lastError: ""
  property var    messages: []
  property var    replyTarget: null
  property var    models: []
  property string activeModel: ""
  // Chat-history fields the existing Panel/Bubble bind against.
  // We synthesize the simplest possible values so we don't have to
  // touch the consumer surface.
  readonly property int    relaysUp:    streaming ? 1 : 0
  readonly property int    relaysTotal: 1
  readonly property var    relays:      streaming ? ["pi"] : []

  // ── signals up to the backend ──
  signal needsPersist
  signal incomingNotification(string text)

  // ── internal ──
  property string _streamingId: ""    // id of the bubble currently receiving deltas
  property string _thinkingId: ""    // id of the bubble currently receiving thinking deltas
  // tps tracking: stamp on the first text_start of an assistant message;
  // patched onto the last text bubble when the matching message_end with
  // usage.output > 0 arrives. Reset on agent_end so the next turn starts
  // fresh. Approximation when one assistant message produces multiple
  // text bubbles — the tps gets attached to the final one only.
  property real _assistantStartedAt: 0
  property string _assistantLastTextBubbleId: ""
  property bool _shouldRun: false     // intent (true between spawn() and stop())
  // ── WebSocket transport state ──
  // Set by PiChatBackend when constructing this session from a persisted
  // entry that carries a `daemonSessionId` (auto-imported from a remote
  // executor's session list, or persisted from this entry's previous
  // create_session ack). Drives _wsSpawn to *attach* to that id instead
  // of minting a new one — preserving the conversation across panel
  // restarts and across PWA-created sessions.
  property string initialDaemonSessionId: ""
  property string _daemonSessionId: initialDaemonSessionId  // id the executor assigned on create / replays / imports
  property bool   _wsAttached: false
  // A create_session is in flight: sent (or queued behind whenConnected) but
  // not yet acked. Spawn is idempotent across this window — a second spawn()
  // (e.g. launchBackground's spawn() followed by send()→spawn()) must NOT mint
  // a second daemon session, which the panel entry can't hold and which the
  // `sessions` broadcast then re-imports as a dead duplicate.
  property bool   _wsCreating: false
  property var    _wsPending: []         // commands buffered until attached
  // Request/response correlation. Each entry is { resolve, reject }; pi
  // echoes the `id` we attach to outgoing commands on the matching
  // response, which _handleResponse uses to fulfill the promise.
  property var _inflight: ({})
  property int _nextReqId: 0
  // Cache of unanswered extension_ui_request ids so we can decline them
  // on shutdown. Confirm bubbles are stored in `messages` for the UI.
  property var _pendingExtensionUI: ({})

  // Pending integration tool approvals (gateway → panel, keyed by id).
  // The bubble in `messages` carries the UI; this mirrors
  // _pendingExtensionUI so a collapse/cleanup can find still-open ones.
  property var _pendingApprovals: ({})

  function _now() { return Date.now(); }

  function _localId() {
    return "local-" + _now().toString(36) + "-" + Math.floor(Math.random() * 1e6).toString(36);
  }

  function _appendMessage(entry) {
    const arr = messages.slice();
    arr.push(entry);
    messages = arr;
  }

  function patch(id, props) {
    messages = Msg.patch(messages, id, props);
  }

  // ── pi command surface — these are what Panel.qml/Bubble.qml call ──

  function send(text) {
    if (!text || !text.trim()) return;
    spawn();
    const id = _localId();
    _appendMessage(Msg.user(id, text, _now(), replyTarget ? replyTarget.id : ""));
    replyTarget = null;
    typing = true;
    busy = true;
    const prompt = { type: "prompt", message: text, streamingBehavior: "steer" };
    _send(prompt);
    needsPersist();
  }

  function sendFile(path, _unlink) {
    if (!path) return;
    if (path.startsWith("file://")) path = decodeURIComponent(path.slice(7));
    // Images get inlined as base64 via a one-shot panel-side reader and
    // travel inside the prompt command. Non-image paths only land in the
    // prompt text — the executor's sandbox must be able to see them
    // (workspace or a configured bind) for pi's Read tool to follow up.
    const lower = path.toLowerCase();
    const isImage = [".png", ".jpg", ".jpeg", ".gif", ".webp"].some(ext => lower.endsWith(ext));
    if (isImage) {
      _readImage(path);
    } else {
      send("Attached: " + path);
    }
  }

  function retry(_id) {
    // Pi handles transient failures internally via auto_retry_*. The
    // user-facing "force retry" is a no-op for now.
  }

  function cancel(_id) {
    _send({ type: "abort" });
  }

  function confirmRespond(id, confirmed) {
    _send({ type: "extension_ui_response", id: id, confirmed: !!confirmed });
    patch(id, { confirmState: confirmed ? "allowed" : "denied" });
    delete _pendingExtensionUI[id];
  }

  // Gateway → panel: the user picked once | session | deny for an
  // integration tool call. Mirror the verdict into the bubble and reply.
  function approvalRespond(id, decision) {
    _send({ type: "approval_response", id: id, decision: decision });
    patch(id, { approvalState: decision });
    delete _pendingApprovals[id];
  }

  // WS mode: another mirrored client answered this side channel first. Collapse
  // the local prompt — the daemon already forwarded the winning answer to pi
  // (first-answer-wins), so a second response from us would be dropped.
  function _onSidechannelResolved(id, by) {
    if (!_pendingExtensionUI[id]) return;
    patch(id, { confirmState: "resolved" });
    delete _pendingExtensionUI[id];
  }

  function promptRespond(id, value) {
    // Patch local state for immediate UI feedback, then push the value
    // to the skill-config daemon over the sidecar socket. The daemon
    // unblocks the waiting `skill-config request-input` CLI, which
    // writes the value to disk and exits 0 so pi sees the saved
    // confirmation in its bash tool output.
    patch(id, { promptState: "submitted", text: "" });
    if (backend) backend.skillConfigSend({ op: "submit", request_id: id, value: value });
  }

  function promptCancel(id) {
    patch(id, { promptState: "cancelled" });
    if (backend) backend.skillConfigSend({ op: "cancel", request_id: id });
  }

  // Wipe local UI and start a fresh conversation: drop the daemon
  // session backing this entry and mint a new one on the same executor.
  // Sessions are cheap daemon-side, so "restart" is delete + create
  // rather than an in-place rebind; deleting the old id also clears its
  // on-disk history, so no sibling client re-imports a ghost. The fresh
  // create_session carries modelPref, so the selected model survives
  // without a set_model replay.
  function restart() {
    messages = [];
    replyTarget = null;
    typing = false;
    busy = false;
    lastError = "";
    _streamingId = "";
    _thinkingId = "";
    if (!executor) return;
    const old = _daemonSessionId;
    if (old) {
      executor.unsubscribe(old);
      executor.detach(old);
      executor.deleteSession(old);
    }
    _shouldRun = false;
    _wsAttached = false;
    _wsCreating = false;
    _daemonSessionId = "";
    initialDaemonSessionId = "";
    // Clear the persisted mapping so a panel restart mid-create doesn't
    // re-attach to the deleted session.
    if (registry && registry.release(sessionId)) needsPersist();
    spawn();
  }

  function listModels() {
    if (!_shouldRun) spawn();
    _send({ type: "get_available_models" });
    // get_state is the authoritative source for the currently-active
    // model — pi reports what it actually loaded from settings.json
    // or the resumed session.jsonl, which beats any guess we could
    // make from modelPref alone.
    _send({ type: "get_state" });
  }

  function setModel(provider, modelId) {
    modelPref = provider + "/" + modelId;
    ModelFrecency.record(modelPref);
    needsPersist();
    if (_shouldRun) {
      _send({ type: "set_model", provider: provider, modelId: modelId });
    }
  }

  // Like setModel, but resolves only once pi acknowledges the change.
  // The background-launch path needs this: pi dispatches stdin lines as
  // fire-and-forget async tasks (see restart()), so the fire-and-forget
  // setModel() above followed immediately by send() races — the turn can
  // start on the default model. Awaiting the set_model response pins the
  // model before the prompt goes out. spawn() so a cold session has a
  // process for the request to land in.
  function setModelAndWait(provider, modelId) {
    modelPref = provider + "/" + modelId;
    ModelFrecency.record(modelPref);
    needsPersist();
    spawn();
    return _request({ type: "set_model", provider: provider, modelId: modelId });
  }

  // Backend-facing lifecycle.

  function spawn() {
    if (!executor) {
      // Executor not resolved yet — at panel startup the config FileView
      // (executor inventory) can still be loading when the first send
      // arrives. Record the intent; onExecutorChanged fires _wsSpawn the
      // moment the binding resolves, and commands sent meanwhile buffer
      // in _wsPending.
      _shouldRun = true;
      Logger.w("PiSession", sessionId, "spawn deferred: executor not resolved yet");
      return;
    }
    _wsSpawn();
  }

  // The backend rebinds `executor` when the inventory loads (or when the
  // entry is repinned). Pick up deferred spawn intent / buffered commands.
  onExecutorChanged: {
    if (executor && _shouldRun && !_wsAttached) {
      // _wsSpawn's coalescing guard keys on _shouldRun, which the deferred
      // spawn already set — clear the flag so the guard doesn't eat this.
      _wsCreating = false;
      _shouldRun = false;
      _wsSpawn();
    }
  }

  // Create the session on (or re-attach it to) the executor, buffering
  // commands until the daemon assigns an id and we subscribe.
  function _wsSpawn() {
    // Idempotent: already attached, or a create is still in flight (no id
    // yet) — repeat spawns coalesce onto that create (see _wsCreating). Safe
    // because _wsCreate retries across reconnects, so collapsing the
    // redundant spawns doesn't drop a create that races a connection flap.
    if (_shouldRun && (_wsAttached || _wsCreating)) return;
    _shouldRun = true;
    streaming = true;
    // Reapply the persisted memory intent; buffers until attached, so it
    // lands ahead of any prompt queued behind this spawn.
    _syncMemory();
    if (_daemonSessionId) {
      executor.subscribe(_daemonSessionId, session);
      executor.attach(_daemonSessionId);
      _wsAttached = true;
      _wsFlush();
      return;
    }
    _wsCreating = true;
    _wsCreate();
  }

  // Issue one create_session once the executor is welcomed. Each create
  // carries a client-minted requestId the daemon echoes on the ack, so the
  // ack routes here directly. On failure (the executor dropped mid-create,
  // failing the pending create) retry on the next welcome rather than
  // leaving the session cold with its prompt buffered — a single spawn()
  // must eventually attach even across a reconnect, since repeat spawns
  // coalesce in _wsSpawn instead of re-arming the create.
  function _wsCreate() {
    executor.whenConnected(() => {
      if (!_shouldRun) { _wsCreating = false; return; }
      // A reconnect-reattach (or a racing spawn) may have attached us already.
      if (_wsAttached || _daemonSessionId) { _wsCreating = false; return; }
      const opts = { name: sessionName };
      if (modelPref) opts.model = modelPref;
      const requestId = executor.createSession(opts, id => {
        // Runs synchronously inside the ack dispatch — everything stamped
        // here is visible before the daemon's follow-up `sessions`
        // broadcast (a later message) reaches the importer.
        _wsCreating = false;
        if (!_shouldRun) {
          // Stop raced the create: the daemon session exists but nobody
          // claims it — drop the pending claim so a later `sessions`
          // push may import it.
          executor.detach(id);
          if (registry) registry.failCreate(requestId);
          return;
        }
        _daemonSessionId = id;
        // Stamp the panel entry so a panel restart re-attaches to the
        // same daemon session (cross-restart history continuity) and so
        // an unsolicited `sessions` push that includes this id is dedup'd
        // against an existing entry instead of being auto-imported again.
        if (registry && registry.resolveCreate(requestId, id)) needsPersist();
        executor.subscribe(id, session);
        _wsAttached = true;
        _wsFlush();
      }, e => {
        Logger.w("PiSession", sessionId, "create_session failed", e);
        if (registry) registry.failCreate(requestId);
        if (_shouldRun) _wsCreate(); // executor dropped mid-create: retry on reconnect
        else _wsCreating = false;
      });
      // Announce the in-flight create: the registry defers adopting new
      // ids from this entry's executor until the ack resolves it, so a
      // created-but-unclaimed id never re-imports as a foreign session.
      // (The ack can't beat this line — it arrives via the event loop.)
      if (registry) registry.beginCreate(requestId, sessionId);
    });
  }

  function _wsFlush() {
    const q = _wsPending;
    _wsPending = [];
    for (const c of q) executor.command(_daemonSessionId, c);
  }

  // ── per-session memory toggle ──
  //
  // The marker convention is opt-out: file present → disabled. The
  // daemon owns the marker (set_memory writes/removes `memory-off` in
  // the session dir); the memory extension re-reads it at each hook
  // entry, so flipping the bit here propagates to the next prompt
  // without touching the live agent. Cold sessions buffer the command
  // in _wsPending until the next spawn attaches.
  function _syncMemory() {
    if (!executor) return;
    _send({ type: "set_memory", enabled: memoryEnabled });
  }
  onMemoryEnabledChanged: _syncMemory()

  function stop() {
    _shouldRun = false;
    if (executor && _daemonSessionId) {
      executor.detach(_daemonSessionId);
      executor.unsubscribe(_daemonSessionId);
    }
    _wsAttached = false;
    // Any in-flight create's ack callback sees _shouldRun false and
    // detaches the minted id; clear the flag so a later respawn isn't
    // wedged.
    _wsCreating = false;
    streaming = false;
    typing = false;
  }

  function _send(cmd) {
    if (_wsAttached && _daemonSessionId) executor.command(_daemonSessionId, cmd);
    else _wsPending.push(cmd);
  }

  // Send a command and resolve when the executor relays pi's matching
  // response. We attach a unique `id`; the daemon echoes it back on the
  // success/error response, which _handleResponse uses to fulfill the
  // promise. With the executor still unresolved the command buffers like
  // any other; the promise settles after attach (or rejects via
  // _rejectInflight on disconnect).
  function _request(cmd) {
    return new Promise((resolve, reject) => {
      _nextReqId += 1;
      const id = "q" + _nextReqId;
      _inflight[id] = { resolve: resolve, reject: reject };
      _send(Object.assign({}, cmd, { id: id }));
    });
  }

  // Drain pending requests when the process disappears (graceful stop or
  // crash). Without this, callers awaiting _request hang forever.
  function _rejectInflight(reason) {
    const pending = _inflight;
    _inflight = ({});
    for (const id in pending) {
      try { pending[id].reject(reason); } catch (e) { /* swallow */ }
    }
  }

  // ── pi event intake ──
  // An event envelope's payload (already parsed by PiExecutor) is the
  // pi event — feed it into the state machine.
  function _onEnvelopeEvent(payload) {
    if (payload) _handleEvent(payload);
  }

  // WS mode: the executor connection dropped. Mirror process-exit cleanup.
  function _onExecutorClosed() {
    _wsAttached = false;
    streaming = false;
    typing = false;
    _streamingId = "";
    _thinkingId = "";
    _rejectInflight("executor disconnected");
  }

  // WS mode: the executor reconnected and re-attached this session. The daemon
  // replays the events missed while we were gone (attach lastSeq); resume
  // sending and flush any commands buffered during the outage.
  function _onExecutorReattached() {
    _wsAttached = true;
    _wsFlush();
  }

  // WS mode: the daemon reported a session-scoped failure (routed here
  // by PiExecutor via the error envelope's sessionId). "no such session"
  // for a session we believed attached means our persisted daemon id is
  // stale — the daemon lost it (deleted by another client, state wiped).
  // Recover by dropping the mapping and minting a fresh daemon session;
  // without this the session wedges attached-but-dead and every command
  // (models, history, prompts) bounces forever.
  function _onSessionError(error) {
    if (error !== "no such session") return;
    if (!executor || !_daemonSessionId) return;
    Logger.w("PiSession", sessionId, "daemon lost session", _daemonSessionId, "- recreating");
    executor.unsubscribe(_daemonSessionId);
    _daemonSessionId = "";
    initialDaemonSessionId = "";
    _wsAttached = false;
    // Clear the persisted mapping so a panel restart doesn't chase the
    // dead id again.
    if (registry && registry.release(sessionId)) needsPersist();
    if (!_shouldRun) return;
    // Replay the attach-time bootstrap; these buffer in _wsPending and
    // flush once the fresh session acks (the originals bounced).
    _syncMemory();
    _send({ type: "get_available_models" });
    _send({ type: "get_state" });
    _send({ type: "get_messages" });
    if (!_wsCreating) {
      _wsCreating = true;
      _wsCreate();
    }
  }

  // The pi-event → conversation-state fold lives in Reducer.js (pure,
  // unit-checked by checks/pi-chat-reducer and cross-checked against
  // the pi-web reducer through the shared fixture corpus). This
  // component is only the lifecycle adapter: snapshot the fold-owned
  // properties, Reducer.apply, assign back what changed, run effects.
  // `response` envelopes stay here — request/response correlation and
  // model bookkeeping are transport, not conversation state.
  function _handleEvent(ev) {
    if (!ev) return;
    if (ev.type === "response") {
      _handleResponse(ev);
      return;
    }
    const r = Reducer.apply(_foldState(), ev, _now());
    _applyFold(r.state);
    for (const fx of r.effects) _runEffect(fx);
  }

  function _foldState() {
    return {
      messages: messages,
      typing: typing,
      busy: busy,
      lastError: lastError,
      streamingId: _streamingId,
      thinkingId: _thinkingId,
      assistantStartedAt: _assistantStartedAt,
      assistantLastTextBubbleId: _assistantLastTextBubbleId,
      pendingExtensionUI: _pendingExtensionUI,
      pendingApprovals: _pendingApprovals,
    };
  }

  // Assign only what changed (Reducer.apply preserves identity on
  // untouched fields) so property change signals — and the ListView
  // bound to `messages` — fire exactly as often as before the fold
  // was extracted.
  function _applyFold(s) {
    if (s.messages !== messages) messages = s.messages;
    if (s.typing !== typing) typing = s.typing;
    if (s.busy !== busy) busy = s.busy;
    if (s.lastError !== lastError) lastError = s.lastError;
    if (s.streamingId !== _streamingId) _streamingId = s.streamingId;
    if (s.thinkingId !== _thinkingId) _thinkingId = s.thinkingId;
    if (s.assistantStartedAt !== _assistantStartedAt) _assistantStartedAt = s.assistantStartedAt;
    if (s.assistantLastTextBubbleId !== _assistantLastTextBubbleId) _assistantLastTextBubbleId = s.assistantLastTextBubbleId;
    if (s.pendingExtensionUI !== _pendingExtensionUI) _pendingExtensionUI = s.pendingExtensionUI;
    if (s.pendingApprovals !== _pendingApprovals) _pendingApprovals = s.pendingApprovals;
  }

  function _runEffect(fx) {
    if (fx.kind === "notify") incomingNotification(fx.text);
    else if (fx.kind === "send") _send(fx.command);
    else if (fx.kind === "log") Logger.w("PiSession", sessionId, ...fx.args);
  }

  function _handleResponse(ev) {
    // Correlated reply from _request → fulfill the promise and stop;
    // by-command branches below handle responses for fire-and-forget
    // _send calls that didn't attach an id.
    if (ev.id && _inflight[ev.id]) {
      const slot = _inflight[ev.id];
      delete _inflight[ev.id];
      if (ev.success) slot.resolve(ev.data);
      else slot.reject(ev.error || ev.command + " failed");
      return;
    }
    if (!ev.success) {
      if (ev.error) lastError = ev.error;
      Logger.w("PiSession", sessionId, "response error", ev.command, ev.error);
      return;
    }
    if (ev.command === "get_available_models") {
      const list = (ev.data && Array.isArray(ev.data.models)) ? ev.data.models : [];
      const active = list.find(m => m.provider + "/" + m.id === modelPref);
      models = list.map(m => Object.assign({}, m, { active: active && m.provider === active.provider && m.id === active.id }));
      if (active) activeModel = active.provider + "/" + active.id;
      else if (list.length > 0 && !activeModel) activeModel = list[0].provider + "/" + list[0].id;
    } else if (ev.command === "set_model") {
      activeModel = ev.data.provider + "/" + ev.data.id;
      models = models.map(m => Object.assign({}, m, {
        active: m.provider === ev.data.provider && m.id === ev.data.id,
      }));
    } else if (ev.command === "get_messages") {
      _applyFold(Reducer.importHistory(_foldState(), ev.data && ev.data.messages, _now()));
    } else if (ev.command === "get_state") {
      // Authoritative model state from pi. Overrides whatever
      // get_available_models picked from modelPref alone — covers the
      // first-open case where pi's settings.json/session.jsonl default
      // disagrees with list[0] alphabetically.
      const m = ev.data && ev.data.model;
      if (m && m.provider && m.id) {
        activeModel = m.provider + "/" + m.id;
        models = models.map(x => Object.assign({}, x, {
          active: x.provider === m.provider && x.id === m.id,
        }));
      }
    }
  }

  function _readImage(path) {
    // Immediately show the user's attachment in the chat list so there's
    // visual feedback the moment the picker closes. The base64 encoding
    // runs asynchronously; the prompt is sent to pi on completion.
    const id = _localId();
    _appendMessage(Msg.userImage(id, path, _now(), replyTarget ? replyTarget.id : ""));
    replyTarget = null;
    needsPersist();
    const reader = _imageReaderComponent.createObject(session);
    reader._imagePath = path;
    reader.command = ["sh", "-c",
      "mt=$(file -b --mime-type \"$1\"); " +
      "b64=$(base64 -w0 \"$1\"); " +
      "printf '%s\\n%s' \"$mt\" \"$b64\"",
      "sh", path];
    reader.running = true;
  }

  // ── child components (Process, SplitParser) — declared as
  //    properties so they're owned by this QtObject without polluting
  //    the visible API.

  readonly property Component _imageReaderComponent: Component {
    Process {
      property string _imagePath: ""
      property string _staged: ""
      stdout: StdioCollector { onStreamFinished: _staged = text }
      onExited: code => {
        if (code === 0 && _staged) {
          const nl = _staged.indexOf("\n");
          const mt = nl > 0 ? _staged.slice(0, nl).trim() : "application/octet-stream";
          const b64 = nl > 0 ? _staged.slice(nl + 1) : "";
          session.spawn();
          session._send({
            type: "prompt",
            message: "",
            images: [{ type: "image", data: b64, mimeType: mt }],
            streamingBehavior: "steer",
          });
          session.typing = true;
          session.busy = true;
        }
      }
    }
  }
}

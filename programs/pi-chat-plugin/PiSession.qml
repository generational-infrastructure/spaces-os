// One pi --mode rpc process plus all the in-memory state the chat
// panel binds against. Lives inside PiChatBackend's Repeater so the
// lifecycle tracks the sessionsList.
//
// Wire-protocol summary (commands written to stdin, events read from
// stdout — both as JSON lines):
//
//   send  { type: "prompt", message, images? }
//         { type: "abort" }
//         { type: "get_messages" }
//         { type: "get_available_models" }
//         { type: "set_model", provider, modelId }
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
// the index. Per-session pi-managed history lives in pi's session.jsonl
// under stateDir, replayed via get_messages on every (re)spawn.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

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
  property string piBin              // /nix/store/.../bin/pi
  property string stateDir           // ~/.local/state/distro/pi
  property string piAgentDir         // <stateDir>/pi-agent
  property string llmUrl: "http://127.0.0.1:8012"
  property string memoryHigh: "4G"
  property bool   openrouterEnabled: false

  // ── live state observable by Panel.qml via PiChatBackend.chat ──
  property string peerName: sessionName
  property bool   streaming: false   // process is up & RPC-ready
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
  signal exitedWithError(int code)

  // ── internal ──
  property var _process: null
  property var _stopProcess: null
  property string _streamingId: ""    // id of the bubble currently receiving deltas
  property int _spawnSeq: 0           // bumps every spawn for diagnostic logs
  property bool _shouldRun: false     // intent (true between spawn() and stop())
  // Cache of unanswered extension_ui_request ids so we can decline them
  // on shutdown. Confirm bubbles are stored in `messages` for the UI.
  property var _pendingExtensionUI: ({})

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
    const arr = messages.slice();
    const i = arr.findIndex(x => x.id === id);
    if (i < 0) return;
    arr[i] = Object.assign({}, arr[i], props);
    messages = arr;
  }

  // ── pi command surface — these are what Panel.qml/Bubble.qml call ──

  function send(text) {
    if (!text || !text.trim()) return;
    spawn();
    const id = _localId();
    _appendMessage({
      id: id,
      from: "me",
      text: text,
      ts: _now(),
      state: "sent",
      tries: 0,
      ack: "",
      image: "",
      replyTo: replyTarget ? replyTarget.id : "",
      type: "",
    });
    replyTarget = null;
    typing = true;
    _send({ type: "prompt", message: text });
    needsPersist();
  }

  function sendFile(path, _unlink) {
    if (!path) return;
    if (path.startsWith("file://")) path = decodeURIComponent(path.slice(7));
    // We don't have a host→container hop in pi-chat mode; pi runs as
    // the user and can read paths directly. Images get inlined as
    // base64 via a one-shot file reader; non-image paths land in the
    // prompt text and pi can choose to read them with its Read tool.
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

  function promptRespond(id, value) {
    // Skill-config prompts live in messages but the daemon socket
    // owns them, so we just patch local state here. PiChatBackend's
    // skill-config sock send does the wire write.
    patch(id, { promptState: "submitted", text: "" });
  }

  function promptCancel(id) {
    patch(id, { promptState: "cancelled" });
  }

  // Wipe local UI and tell pi to start a fresh session in-place.
  // Pi's runtimeHost.newSession() tears down the current agent, swaps
  // the SessionManager to a new sessionId, and starts emitting events
  // for the new session — so the same proc keeps streaming RPC, just
  // against an empty history. Cold sessions get spawn()ed first so the
  // new_session command has a process to land in; the next user
  // message proceeds against that fresh session.
  function restart() {
    messages = [];
    replyTarget = null;
    typing = false;
    lastError = "";
    _streamingId = "";
    spawn();
    _send({ type: "new_session" });
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
    needsPersist();
    if (_shouldRun) {
      _send({ type: "set_model", provider: provider, modelId: modelId });
    }
  }

  // Backend-facing lifecycle.

  function spawn() {
    if (_shouldRun && _process) return;
    if (!piBin) {
      Logger.w("PiSession", "spawn without piBin", sessionId);
      return;
    }
    _shouldRun = true;
    _spawnSeq += 1;
    const proc = _processComponent.createObject(session);
    _process = proc;
    proc.command = _buildCommand();
    proc.running = true;
    streaming = true;
  }

  function stop() {
    _shouldRun = false;
    if (!_process) {
      streaming = false;
      typing = false;
      return;
    }
    // Graceful shutdown — systemctl --user stop sends SIGTERM, pi
    // flushes session.jsonl, then exits. The scope unit garbage-
    // collects via --collect on the spawn side.
    const sp = _stopComponent.createObject(session);
    _stopProcess = sp;
    sp.command = ["systemctl", "--user", "stop", "pi-chat-" + sessionId + ".service"];
    sp.running = true;
  }

  function _send(cmd) {
    if (!_process || !_process.running) return;
    try {
      _process.write(JSON.stringify(cmd) + "\n");
    } catch (e) {
      Logger.w("PiSession", sessionId, "write failed", e);
    }
  }

  function _buildCommand() {
    const xdgRuntime = String(Quickshell.env("XDG_RUNTIME_DIR"));
    const sessionState = stateDir + "/sessions/" + sessionId;
    const skillSockHost = xdgRuntime + "/distro-skill-config.sock";
    const skillsDefs = stateDir + "/skills-defs";
    const skillConfigStore = stateDir + "/skill-config";

    // systemd-run --user as a transient service (not --scope): user
    // scopes silently reject namespace-creating properties like
    // BindPaths/ProtectHome/PrivateTmp ("Unknown assignment"). The
    // service path supports the full sandbox bouquet AND --pipe wires
    // stdin/stdout/stderr back to us for the RPC channel.
    const cmd = [
      "systemd-run", "--user", "--pipe", "--quiet", "--collect",
      "--unit=pi-chat-" + sessionId + ".service",
      "--slice=pi-chat.slice",
      "--service-type=exec",
      "--working-directory=" + workspacePath,
      "--setenv=DISTRO_SESSION_ID=" + sessionId,
      "--setenv=PI_CODING_AGENT_DIR=" + piAgentDir,
      "--setenv=LLAMA_SWAP_BASE_URL=" + llmUrl,
      "--setenv=SKILL_CONFIG_SOCKET=" + skillSockHost,
      "--setenv=DISTRO_PI_CHAT_STATE_DIR=" + stateDir,
      "--setenv=PI_TELEMETRY=0",
      "--setenv=PI_OFFLINE=0",
      "--property=BindPaths=" + sessionState + ":" + sessionState,
      "--property=BindPaths=" + workspacePath + ":" + workspacePath,
      "--property=BindPaths=" + skillSockHost + ":" + skillSockHost,
      // skill-config needs the skill schemas (read-only nix-store
      // symlinks) and the user's config/secrets store (read-write).
      "--property=BindReadOnlyPaths=" + skillsDefs + ":" + skillsDefs,
      "--property=BindPaths=" + skillConfigStore + ":" + skillConfigStore,
      "--property=PrivateTmp=true",
      "--property=PrivateDevices=true",
      "--property=ProtectKernelTunables=true",
      "--property=ProtectKernelModules=true",
      "--property=ProtectKernelLogs=true",
      "--property=ProtectControlGroups=true",
      "--property=ProtectClock=true",
      "--property=ProtectProc=invisible",
      "--property=NoNewPrivileges=true",
      "--property=RestrictSUIDSGID=true",
      "--property=LockPersonality=true",
      "--property=RestrictNamespaces=true",
      "--property=SystemCallArchitectures=native",
      "--property=MemoryHigh=" + memoryHigh,
    ];
    // Trusted sessions skip the filesystem-narrowing properties. The
    // cgroup limits + kernel-protection set stay so even trusted pi
    // can't fiddle with /proc/sysrq-trigger and friends.
    if (!trusted) {
      cmd.push("--property=ProtectHome=tmpfs");
      // BindPaths (RW) not BindReadOnlyPaths: pi mkdir's a
      // `settings.json.lock` directory next to settings.json for
      // advisory locking. The settings files themselves are nix-store
      // symlinks so they remain immutable; only the lock mkdir needs
      // the parent dir writable.
      cmd.push("--property=BindPaths=" + piAgentDir + ":" + piAgentDir);
    }
    if (openrouterEnabled) {
      cmd.push("--property=LoadCredential=openrouter-api-key:/run/distro-secrets/openrouter-api-key");
    }
    cmd.push("--", piBin, "--mode", "rpc", "--session-dir", sessionState);
    // --continue picks the most recent jsonl in the session dir. On
    // first launch the dir is empty; pi falls back to a fresh session.
    if (_hasExistingSession()) cmd.push("--continue");
    return cmd;
  }

  function _hasExistingSession() {
    // We can't stat from QML directly; pi handles the empty case by
    // creating a new session, but its diagnostic noise is louder when
    // --continue resolves to nothing. PiChatBackend stamps a flag on
    // the session entry once the first agent_end has been observed.
    return !!_existingSessionFlag;
  }
  // Set true after the first agent_end; persisted by PiChatBackend.
  property bool _existingSessionFlag: false

  // ── pi RPC parser ──

  function _onLine(line) {
    if (!line) return;
    let ev;
    try { ev = JSON.parse(line); }
    catch (e) { Logger.w("PiSession", sessionId, "bad json", line); return; }
    _handleEvent(ev);
  }

  function _handleEvent(ev) {
    switch (ev.type) {
    case "agent_start":
      typing = true;
      break;

    case "message_update":
      _handleMessageUpdate(ev);
      break;

    case "agent_end":
      typing = false;
      _finalizeStreaming();
      _existingSessionFlag = true;
      if (lastError) lastError = "";
      break;

    // Lifecycle markers from pi >=0.70. The chat panel does not need
    // per-turn/per-message bracket events — text content arrives via
    // message_update, finalisation via agent_end — but pi emits these
    // around user message echoes and assistant turns, so silently
    // accept them instead of spamming the journal.
    case "turn_start":
    case "turn_end":
    case "message_start":
    case "message_end":
      break;

    case "tool_execution_start":
      _appendToolBubble(ev);
      break;

    case "auto_retry_start":
      _appendNoticeBubble("retrying (" + (ev.attempt || 1) + "): " + (ev.errorMessage || ""));
      break;

    case "auto_retry_end":
      if (!ev.success && ev.finalError) {
        lastError = ev.finalError;
      }
      break;

    case "extension_ui_request":
      _handleExtensionRequest(ev);
      break;

    case "extension_error":
      Logger.w("PiSession", sessionId, "extension error", ev.error);
      break;

    case "response":
      _handleResponse(ev);
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
      Logger.w("PiSession", sessionId, "unknown event", ev.type);
    }
  }

  function _handleMessageUpdate(ev) {
    const me = ev.assistantMessageEvent;
    if (!me) return;
    if (me.type === "text_start") {
      _streamingId = "stream-" + _now().toString(36);
      _appendMessage({
        id: _streamingId,
        from: "peer",
        text: "",
        ts: _now(),
        state: "streaming",
        tries: 0,
        ack: "",
        image: "",
        replyTo: "",
        type: "",
      });
      typing = false;
    } else if (me.type === "text_delta") {
      if (!_streamingId) _handleMessageUpdate({ assistantMessageEvent: { type: "text_start" } });
      const arr = messages.slice();
      const i = arr.findIndex(x => x.id === _streamingId);
      if (i >= 0) {
        arr[i] = Object.assign({}, arr[i], { text: arr[i].text + (me.delta || "") });
        messages = arr;
      }
    } else if (me.type === "text_end") {
      const arr = messages.slice();
      const i = arr.findIndex(x => x.id === _streamingId);
      if (i >= 0) {
        arr[i] = Object.assign({}, arr[i], { state: "sent", text: me.content || arr[i].text });
        messages = arr;
      }
      _streamingId = "";
    }
  }

  function _finalizeStreaming() {
    if (!_streamingId) return;
    const arr = messages.slice();
    const i = arr.findIndex(x => x.id === _streamingId);
    if (i >= 0) {
      arr[i] = Object.assign({}, arr[i], { state: "sent" });
      messages = arr;
    }
    _streamingId = "";
  }

  function _appendToolBubble(ev) {
    const summary = _summarizeTool(ev.toolName, ev.args);
    if (!summary) return;
    _appendMessage({
      id: "tool-" + (ev.toolCallId || _now().toString(36)),
      from: "peer",
      text: summary,
      ts: _now(),
      state: "sent",
      tries: 0,
      ack: "",
      image: "",
      replyTo: "",
      type: "notification",
    });
  }

  function _summarizeTool(name, args) {
    if (!name) return "";
    if (name === "bash") return "$ " + String((args && args.command) || "").split("\n")[0].slice(0, 80);
    if (name === "read") return "read " + String((args && args.path) || "");
    if (name === "edit") return "edit " + String((args && args.path) || "");
    if (name === "write") return "write " + String((args && args.path) || "");
    return name;
  }

  function _appendNoticeBubble(text) {
    _appendMessage({
      id: "notice-" + _now().toString(36),
      from: "peer", text: text, ts: _now(),
      state: "sent", tries: 0, ack: "", image: "", replyTo: "",
      type: "notification",
    });
  }

  function _handleExtensionRequest(ev) {
    if (ev.method === "confirm") {
      _pendingExtensionUI[ev.id] = true;
      _appendMessage({
        id: ev.id,
        from: "peer",
        text: ev.message || "",
        ts: _now(),
        state: "sent",
        tries: 0,
        ack: "", image: "", replyTo: "",
        type: "confirm",
        confirmTitle: ev.title || "Run shell command?",
        confirmState: "pending",
      });
      incomingNotification(ev.title || "confirm");
      return;
    }
    if (ev.method === "notify") {
      _appendNoticeBubble(ev.message || "");
      return;
    }
    if (ev.method === "select" || ev.method === "input" || ev.method === "editor") {
      // No UI yet — auto-cancel so pi doesn't hang on the agent loop.
      _send({ type: "extension_ui_response", id: ev.id, cancelled: true });
      return;
    }
    // setStatus / setWidget / setTitle / set_editor_text are
    // fire-and-forget; ignore them.
  }

  function _handleResponse(ev) {
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
      _importHistoricalMessages(ev.data && ev.data.messages);
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

  function _importHistoricalMessages(piMessages) {
    if (!Array.isArray(piMessages)) return;
    const out = [];
    for (const m of piMessages) {
      if (!m || !m.role || !Array.isArray(m.content)) continue;
      const text = m.content
        .filter(c => c && c.type === "text")
        .map(c => c.text)
        .join("\n")
        .trim();
      if (!text) continue;
      out.push({
        id: "hist-" + out.length + "-" + _now().toString(36),
        from: m.role === "user" ? "me" : "peer",
        text: text,
        ts: m.timestamp || _now(),
        state: "sent",
        tries: 0,
        ack: "",
        image: "",
        replyTo: "",
        type: "",
      });
    }
    if (out.length > 0) {
      messages = out.concat(messages);
      _existingSessionFlag = true;
    }
  }

  function _readImage(path) {
    // Immediately show the user's attachment in the chat list so there's
    // visual feedback the moment the picker closes. The base64 encoding
    // runs asynchronously; the prompt is sent to pi on completion.
    const id = _localId();
    _appendMessage({
      id: id,
      from: "me",
      text: "",
      ts: _now(),
      state: "sent",
      tries: 0,
      ack: "",
      image: path,
      replyTo: replyTarget ? replyTarget.id : "",
      type: "",
    });
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

  readonly property Component _processComponent: Component {
    Process {
      stdout: SplitParser { onRead: line => session._onLine(line) }
      stderr: SplitParser { onRead: line => Logger.w("PiSession", session.sessionId, "stderr", line) }
      onExited: code => {
        session.streaming = false;
        session.typing = false;
        session._streamingId = "";
        // Decline any in-flight extension UI so the agent loop doesn't
        // wait on a process that won't come back.
        for (const id in session._pendingExtensionUI) {
          session.patch(id, { confirmState: "denied" });
        }
        session._pendingExtensionUI = ({});
        session._process = null;
        if (code !== 0 && code !== 143 /* SIGTERM */ ) {
          session.lastError = "pi exited (" + code + ")";
          session.exitedWithError(code);
        }
      }
    }
  }

  readonly property Component _stopComponent: Component {
    Process {
      onExited: _ => {
        session._stopProcess = null;
      }
    }
  }

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
          });
          session.typing = true;
        }
      }
    }
  }
}

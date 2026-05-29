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
  property var    backend: null      // PiChatBackend, used for skill-config socket sends
  property string piBin              // /nix/store/.../bin/pi
  property string stateDir           // ~/.local/state/distro/pi
  property string piAgentDir         // <stateDir>/pi-agent
  property string llmUrl: "http://127.0.0.1:8012"
  property string memoryHigh: "4G"
  property bool   openrouterEnabled: false
  // Memory extension. memoryDbDir is the writable vector store the
  // sandbox bind-mounts; memoryHfHome is the absolute /nix/store
  // path that ships the pre-baked embedding model — reachable from
  // inside the sandbox without a bind because /nix/store is visible.
  // memoryEnabled is per-session; toggling it writes/removes a marker
  // file in the session state dir and the extension's hooks pick
  // that up on the next prompt without a respawn.
  property bool   memoryEnabled: true
  property string memoryDbDir: ""
  property string memoryHfHome: ""
  // Extra sandbox bind-mounts contributed by NixOS modules via
  // services.pi-chat.sandboxBinds. Each entry:
  //   { source: string, target?: string, mode: "ro"|"rw", optional?: bool }
  // Both source and target accept systemd specifiers `%h` (HOME) and
  // `%t` ($XDG_RUNTIME_DIR), expanded at session-spawn time. When
  // target is omitted, source is reused on both sides of the bind.
  // `optional: true` prefixes the source with `-` so a missing path
  // doesn't abort sandbox start — useful for sockets the publisher
  // may not have bound yet.
  property var    sandboxBinds: []

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
  property string _thinkingId: ""    // id of the bubble currently receiving thinking deltas
  // tps tracking: stamp on the first text_start of an assistant message;
  // patched onto the last text bubble when the matching message_end with
  // usage.output > 0 arrives. Reset on agent_end so the next turn starts
  // fresh. Approximation when one assistant message produces multiple
  // text bubbles — the tps gets attached to the final one only.
  property real _assistantStartedAt: 0
  property string _assistantLastTextBubbleId: ""
  property int _spawnSeq: 0           // bumps every spawn for diagnostic logs
  property bool _shouldRun: false     // intent (true between spawn() and stop())
  // Request/response correlation. Each entry is { resolve, reject }; pi
  // echoes the `id` we attach to outgoing commands on the matching
  // response, which _handleResponse uses to fulfill the promise.
  property var _inflight: ({})
  property int _nextReqId: 0
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
    _send({ type: "prompt", message: text, streamingBehavior: "steer" });
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

  // Wipe local UI and tell pi to start a fresh session in-place.
  // Pi's runtimeHost.newSession() tears down the current agent, swaps
  // the SessionManager to a new sessionId, and starts emitting events
  // for the new session — so the same proc keeps streaming RPC, just
  // against an empty history. Cold sessions get spawn()ed first so the
  // new_session command has a process to land in; the next user
  // message proceeds against that fresh session.
  //
  // pi's RPC pump dispatches stdin lines as fire-and-forget async tasks,
  // so we cannot fire set_model immediately after new_session — they'd
  // race and set_model would land on the dying session. _request awaits
  // the new_session response (which pi emits *after* rebindSession), so
  // the follow-up set_model is guaranteed to land on the fresh session.
  function restart() {
    messages = [];
    replyTarget = null;
    typing = false;
    lastError = "";
    _streamingId = "";
    _thinkingId = "";
    spawn();
    _request({ type: "new_session" })
      .then(() => {
        if (!modelPref) return;
        const slash = modelPref.indexOf("/");
        if (slash <= 0) return;
        _send({
          type: "set_model",
          provider: modelPref.slice(0, slash),
          modelId: modelPref.slice(slash + 1),
        });
      })
      .catch(e => Logger.w("PiSession", sessionId, "restart aborted", e));
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
    _syncMemoryMarker();
    const proc = _processComponent.createObject(session);
    _process = proc;
    proc.command = _buildCommand();
    proc.running = true;
    streaming = true;
  }

  // ── per-session memory toggle ──
  //
  // The marker convention is opt-out: file present → disabled. The
  // memory extension reads this from
  // $DISTRO_PI_CHAT_STATE_DIR/sessions/<id>/memory-off at each hook
  // entry, so flipping the bit here propagates to the next prompt
  // without a respawn. Reapplied on every spawn (and on startup) so
  // the marker matches the persisted intent even after the session
  // dir was wiped or pi was restarted.
  function _syncMemoryMarker() {
    if (!stateDir || !sessionId) return;
    const markerPath = stateDir + "/sessions/" + sessionId + "/memory-off";
    const cmd = memoryEnabled
      ? ["rm", "-f", markerPath]
      : ["sh", "-c", "mkdir -p \"$(dirname \"$0\")\" && touch \"$0\"", markerPath];
    const proc = _markerComponent.createObject(session);
    proc.command = cmd;
    proc.running = true;
  }
  onMemoryEnabledChanged: _syncMemoryMarker()
  Component.onCompleted: _syncMemoryMarker()

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

  // Send a command and resolve when pi emits the matching response.
  // We attach a unique `id`; pi echoes it back on the success/error
  // response, which _handleResponse uses to fulfill this promise.
  // Rejects immediately when the process is not running.
  function _request(cmd) {
    return new Promise((resolve, reject) => {
      if (!_process || !_process.running) {
        reject("process not running");
        return;
      }
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

  function _buildCommand() {
    const xdgRuntime = String(Quickshell.env("XDG_RUNTIME_DIR"));
    const sessionState = stateDir + "/sessions/" + sessionId;
    const skillSockHost = xdgRuntime + "/distro-skill-config.sock";
    const openUrlSockHost = xdgRuntime + "/distro-pi-open-url.sock";
    const skillsDefs = stateDir + "/skills-defs";
    const skillConfigStore = stateDir + "/skill-config";
    // Dedicated dir for the desktop notification-history file. Whatever
    // writer is running (noctalia configured to redirect here, a future
    // standalone bridge, etc.) writes its history JSON to
    // <notificationsDir>/history.json so we can bind this single dir
    // read-only without exposing any wider cache. The `notifications`
    // skill reads the file via DISTRO_NOTIFICATIONS_FILE.
    const notificationsDir = stateDir + "/notifications";
    const notificationsFile = notificationsDir + "/history.json";

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
      "--setenv=DISTRO_OPEN_URL_SOCKET=" + openUrlSockHost,
      "--setenv=DISTRO_PI_CHAT_STATE_DIR=" + stateDir,
      "--setenv=DISTRO_NOTIFICATIONS_FILE=" + notificationsFile,
      "--setenv=PI_TELEMETRY=0",
      "--setenv=PI_OFFLINE=0",
      // Propagate the chat shell's PATH into the transient unit.
      // `systemd-run --user` builds the unit's exec environment from
      // the user manager's Manager.Environment, which is just the
      // baked-in user@.service PATH (coreutils + systemd's bin) on
      // NixOS — none of /run/current-system/sw/bin or the user profile
      // makes it through. Without this, every skill CLI shelled out by
      // bare name from SKILL.md (signal, notifications, skill-config,
      // …) ENOENTs. niri-session imports the full env into the user
      // manager so the inheritance happens implicitly there, but we
      // can't rely on the compositor doing that for sway / hyprland /
      // GNOME hosts. Forwarding PATH explicitly closes the gap.
      "--setenv=PATH=" + String(Quickshell.env("PATH")),
      "--property=BindPaths=" + sessionState + ":" + sessionState,
      "--property=BindPaths=" + workspacePath + ":" + workspacePath,
      "--property=BindPaths=" + skillSockHost + ":" + skillSockHost,
      // `-` prefix: don't abort sandbox start if the open-url socket
      // hasn't been bound yet (the listener lives in the panel
      // process). google-cli falls back to local webbrowser.open when
      // the path isn't reachable.
      "--property=BindPaths=-" + openUrlSockHost + ":" + openUrlSockHost,
      // skill-config needs the skill schemas (read-only nix-store
      // symlinks) and the user's config/secrets store (read-write).
      "--property=BindReadOnlyPaths=" + skillsDefs + ":" + skillsDefs,
      "--property=BindPaths=" + skillConfigStore + ":" + skillConfigStore,
      "--property=BindReadOnlyPaths=" + notificationsDir + ":" + notificationsDir,
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
    if (memoryDbDir && memoryHfHome) {
      // SEDIMENT_DB is the vector store (bind-mounted RW so the
      // sandbox can write to the user's persistent state dir).
      // HF_HOME points at the /nix/store path that bakes the
      // embedding-model cache — already visible inside the sandbox
      // because /nix/store is not hidden by ProtectHome=tmpfs, so no
      // BindPath is needed. The per-session opt-out lives as a
      // marker file inside the already-bound session state dir, so
      // we don't need a separate sandbox flag for it.
      cmd.push("--setenv=SEDIMENT_DB=" + memoryDbDir + "/data");
      cmd.push("--setenv=HF_HOME=" + memoryHfHome);
      cmd.push("--property=BindPaths=" + memoryDbDir + ":" + memoryDbDir);
    }
    // Module-contributed binds (services.pi-chat.sandboxBinds). Pushed
    // last so the baseline pi-chat-owned binds above stay in a stable
    // position regardless of how many skills opt in. Anything malformed
    // is silently skipped — a typo in a downstream module must not be
    // able to abort sandbox setup.
    const homeDir = String(Quickshell.env("HOME"));
    function _expandSpecifiers(p) {
      return String(p || "").replace(/%h/g, homeDir).replace(/%t/g, xdgRuntime);
    }
    const extraBinds = sandboxBinds || [];
    for (let i = 0; i < extraBinds.length; i++) {
      const b = extraBinds[i];
      if (!b || !b.source) continue;
      const src = _expandSpecifiers(b.source);
      const tgt = b.target ? _expandSpecifiers(b.target) : src;
      const prop = b.mode === "ro" ? "BindReadOnlyPaths" : "BindPaths";
      const prefix = b.optional ? "-" : "";
      cmd.push("--property=" + prop + "=" + prefix + src + ":" + tgt);
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
      _assistantStartedAt = 0;
      _assistantLastTextBubbleId = "";
      break;

    // Lifecycle markers from pi >=0.70. The chat panel does not need
    // per-turn/per-message bracket events — text content arrives via
    // message_update, finalisation via agent_end — but pi emits these
    // around user message echoes and assistant turns, so silently
    // accept them instead of spamming the journal.
    case "turn_start":
    case "turn_end":
    case "message_start":
      break;

    case "message_end":
      _handleMessageEnd(ev);
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
      // First text bubble of this assistant message starts the wall
      // clock for the tps calculation; the last text bubble wins as
      // the patch target when message_end arrives with usage.
      if (_assistantStartedAt === 0) _assistantStartedAt = _now();
      _assistantLastTextBubbleId = _streamingId;
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
    } else if (me.type === "thinking_start") {
      _thinkingId = "thinking-" + _now().toString(36);
      _appendMessage({
        id: _thinkingId,
        from: "peer",
        text: "",
        ts: _now(),
        state: "streaming",
        tries: 0,
        ack: "",
        image: "",
        replyTo: "",
        type: "thinking",
      });
    } else if (me.type === "thinking_delta") {
      if (!_thinkingId) return;
      const arr = messages.slice();
      const i = arr.findIndex(x => x.id === _thinkingId);
      if (i >= 0) {
        arr[i] = Object.assign({}, arr[i], { text: arr[i].text + (me.delta || "") });
        messages = arr;
      }
    } else if (me.type === "thinking_end") {
      if (!_thinkingId) return;
      const arr = messages.slice();
      const i = arr.findIndex(x => x.id === _thinkingId);
      if (i >= 0) {
        const finalText = me.content || arr[i].text;
        if (!finalText) {
          // Empty thinking block (omitted/summarized) — remove it.
          arr.splice(i, 1);
        } else {
          arr[i] = Object.assign({}, arr[i], { state: "sent", text: finalText });
        }
        messages = arr;
      }
      _thinkingId = "";
    }
  }

  function _finalizeStreaming() {
    if (_streamingId) {
      const arr = messages.slice();
      const i = arr.findIndex(x => x.id === _streamingId);
      if (i >= 0) {
        arr[i] = Object.assign({}, arr[i], { state: "sent" });
        messages = arr;
      }
      _streamingId = "";
    }
    if (_thinkingId) {
      const arr = messages.slice();
      const i = arr.findIndex(x => x.id === _thinkingId);
      if (i >= 0) {
        arr[i] = Object.assign({}, arr[i], { state: "sent" });
        messages = arr;
      }
      _thinkingId = "";
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
  function _handleMessageEnd(ev) {
    const msg = ev.message;
    if (!msg || msg.role !== "assistant") return;
    const output = (msg.usage && msg.usage.output) || 0;
    if (output <= 0) return;
    if (!_assistantLastTextBubbleId || _assistantStartedAt === 0) return;
    const elapsedMs = _now() - _assistantStartedAt;
    if (elapsedMs < 50) return;
    const tps = output / (elapsedMs / 1000);
    patch(_assistantLastTextBubbleId, { tps: tps, outputTokens: output });
    // Reset for the next assistant message in this turn (tool → text again).
    _assistantStartedAt = 0;
    _assistantLastTextBubbleId = "";
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
        session._rejectInflight("process exited (" + code + ")");
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

  // Short-lived process for `touch`/`rm -f` of the memory-off marker.
  // Self-destructs on exit so we don't accumulate one per toggle.
  readonly property Component _markerComponent: Component {
    Process { onExited: _ => destroy(2000) }
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
            streamingBehavior: "steer",
          });
          session.typing = true;
        }
      }
    }
  }
}

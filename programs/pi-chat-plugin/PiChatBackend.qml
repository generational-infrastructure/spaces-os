// Pi RPC backend for the chat plugin.
//
// Loads the sessions index from disk, materializes one PiSession per
// entry, and exposes `chat` aliased to the active session so the
// existing Panel/Bubble surface keeps working unchanged. The plugin
// stays cold until a session is selected: spawn happens on the first
// send, model query, or explicit selectSession().
//
// Skill-config prompts come through a separate persistent subscriber
// socket — same NDJSON protocol the skill-config daemon publishes.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.UI

Item {
  id: root

  property var pluginApi: null
  function cfg(key) {
    const s = pluginApi?.pluginSettings || {};
    const d = pluginApi?.manifest?.metadata?.defaultSettings || {};
    return s[key] ?? d[key];
  }

  // ── module-derived config ──
  // The NixOS pi-chat module writes /etc/distro/pi-chat.json with all
  // the deployment-specific knobs (pi binary path, sandbox limits,
  // openrouter flag). Reading it via FileView keeps the QML
  // self-contained without forcing the user manager's
  // DefaultEnvironment to be wired up correctly.
  FileView {
    id: configFile
    path: "/etc/distro/pi-chat.json"
    printErrors: false
    JsonAdapter {
      id: configAdapter
      property string llmUrl: "http://127.0.0.1:8012"
      property string defaultModel: "gemma4:e4b"
      property string defaultProvider: "local"
      property string piBin: "pi"
      property string pluginId: "pi-chat"
      property int idleTimeoutMinutes: 10
      property string memoryHigh: "4G"
      property bool openrouterEnabled: false
      // Memory extension paths. memoryDbDir is $HOME-relative; the
      // QML resolves it against homeDir below. memoryHfHome is an
      // absolute /nix/store path that ships the pre-baked embedding
      // model — sediment reads it via HF_HOME and never downloads.
      // The pi-chat NixOS module is the single source of truth for
      // both; the per-chat opt-out lives on the session entry.
      property string memoryDbDir: ""
      property string memoryHfHome: ""
      // Extra sandbox bind-mounts contributed by NixOS modules via
      // services.pi-chat.sandboxBinds. List of
      //   { source, target?, mode: "ro"|"rw", optional?: bool }
      // Forwarded verbatim to each PiSession; %h/%t are expanded at
      // session-spawn time inside PiSession._buildCommand().
      property var sandboxBinds: []
    }
  }

  readonly property string homeDir: String(Quickshell.env("HOME"))
  readonly property string runtimeDir: String(Quickshell.env("XDG_RUNTIME_DIR"))
  readonly property string stateDir: homeDir + "/.local/state/distro/pi"
  readonly property string piAgentDir: stateDir + "/pi-agent"
  readonly property string workspacesDir: homeDir + "/.local/share/distro/workspaces"
  readonly property string sessionsIndexPath: stateDir + "/sessions.json"
  readonly property string piBin: configAdapter.piBin
  readonly property string llmUrl: configAdapter.llmUrl
  readonly property string memoryHigh: configAdapter.memoryHigh
  readonly property bool openrouterEnabled: configAdapter.openrouterEnabled
  // memoryDbDir is composed against $HOME; memoryHfHome is consumed
  // as-is because it points at a /nix/store path that's already
  // accessible inside the sandbox without an extra BindPath. Empty
  // strings stay empty so PiSession's sandbox setup skips wiring
  // anything when the module hasn't populated the JSON.
  readonly property string memoryDbDir: configAdapter.memoryDbDir
    ? homeDir + "/" + String(configAdapter.memoryDbDir).replace(/^\/+/, "")
    : ""
  readonly property string memoryHfHome: configAdapter.memoryHfHome
  readonly property var sandboxBinds: configAdapter.sandboxBinds || []
  readonly property int idleTimeoutMin: {
    const c = cfg("idleTimeoutMinutes");
    if (typeof c === "number" && c > 0) return c;
    return configAdapter.idleTimeoutMinutes > 0 ? configAdapter.idleTimeoutMinutes : 10;
  }
  readonly property string skillConfigSockPath: runtimeDir + "/distro-skill-config.sock"
  readonly property string openUrlSockPath: runtimeDir + "/distro-pi-open-url.sock"

  // ── sessions index ──
  // Plain-JS array so QML bindings re-evaluate on assignment.
  property var sessionsList: []        // [{id, name, workspacePath, trusted, model, createdAt, lastActiveAt, unread}]
  property string activeSessionId: ""

  // Active session state aggregated from the Repeater. Empty fallback
  // when no sessions exist so Panel.qml's bindings never read from
  // null without checks.
  property var chat: _activeSession || _nullSession

  // The Repeater publishes ready PiSession instances here via
  // _registerSession(). We keep them in a map keyed by id so lookups
  // are O(1); the Repeater handles construction/destruction.
  property var _sessionObjs: ({})
  readonly property var _activeSession: _sessionObjs[activeSessionId] || null

  // ── persistence ──
  FileView {
    id: sessionsFile
    path: root.sessionsIndexPath
    printErrors: false
    JsonAdapter {
      id: sessionsAdapter
      property int version: 1
      property var sessions: []
      property string activeSessionId: ""
    }
    onLoaded: root._loadFromAdapter()
  }

  function _loadFromAdapter() {
    const raw = sessionsAdapter.sessions || [];
    if (Array.isArray(raw) && raw.length > 0) {
      sessionsList = raw.slice();
      activeSessionId = sessionsAdapter.activeSessionId || raw[0].id;
    } else {
      // Bootstrap: auto-create one default session so the panel has
      // something to render on first run.
      const id = root._newId();
      sessionsList = [_freshSessionEntry(id, "Chat 1")];
      activeSessionId = id;
      _ensureSessionDirs(sessionsList[0].id, sessionsList[0].workspacePath);
      _persist();
    }
  }

  function _persist() {
    sessionsAdapter.version = 1;
    sessionsAdapter.sessions = sessionsList;
    sessionsAdapter.activeSessionId = activeSessionId;
    sessionsFile.writeAdapter();
  }

  function _newId() {
    // ULID-ish: 13 base36 chars of ms + 8 of randomness. Good enough
    // for filesystem-name + key uniqueness here.
    const t = Date.now().toString(36);
    const r = Math.floor(Math.random() * 0x10000000).toString(36).padStart(8, "0");
    return (t + r).slice(0, 21);
  }

  function _freshSessionEntry(id, name) {
    return {
      id: id,
      name: name,
      workspacePath: root.workspacesDir + "/" + id,
      trusted: false,
      model: "",
      createdAt: Date.now(),
      lastActiveAt: Date.now(),
      unread: 0,
      // Long-term memory recall/storage on by default; the panel
      // header surfaces a per-chat toggle that writes the opt-out
      // marker the extension reads at each hook entry.
      memoryEnabled: true,
    };
  }

  // BindPaths refuses to mount missing source paths, so both the
  // per-session workspace and the per-session pi state directory
  // must exist on disk before PiSession spawns its systemd-run.
  function _ensureSessionDirs(sessionId, workspacePath) {
    const proc = _oneShotProcess.createObject(root);
    proc.command = [
      "mkdir", "-p",
      workspacePath,
      root.stateDir + "/sessions/" + sessionId,
    ];
    proc.running = true;
  }

  // ── Repeater registration (PiSession instances publish themselves) ──

  function _registerSession(obj) {
    if (!obj || !obj.sessionId) return;
    const map = Object.assign({}, _sessionObjs);
    map[obj.sessionId] = obj;
    _sessionObjs = map;
  }

  function _unregisterSession(id) {
    if (!id || !_sessionObjs[id]) return;
    const map = Object.assign({}, _sessionObjs);
    delete map[id];
    _sessionObjs = map;
  }

  // ── public IPC surface (used by Main.qml's IpcHandler) ──

  function newSession(name) {
    const id = _newId();
    const entry = _freshSessionEntry(id, (name && String(name).trim()) || ("Chat " + (sessionsList.length + 1)));
    _ensureSessionDirs(entry.id, entry.workspacePath);
    sessionsList = sessionsList.concat([entry]);
    activeSessionId = id;
    _persist();
    return id;
  }

  function selectSession(id) {
    if (!id || !sessionsList.some(s => s.id === id)) return;
    activeSessionId = id;
    _touchActive();
  }

  function removeSession(id) {
    if (!id) return;
    const obj = _sessionObjs[id];
    if (obj) obj.stop();
    sessionsList = sessionsList.filter(s => s.id !== id);
    if (activeSessionId === id) {
      activeSessionId = sessionsList.length > 0 ? sessionsList[0].id : "";
    }
    _persist();
  }

  // Toggle long-term memory for a single chat. Persisted on the
  // session entry; PiSession handles the marker file atomically so
  // the running pi process honours the new state on the next prompt.
  function setSessionMemoryEnabled(id, enabled) {
    if (!id) return;
    const obj = _sessionObjs[id];
    if (obj) obj.memoryEnabled = !!enabled;
    sessionsList = sessionsList.map(s => s.id === id
      ? Object.assign({}, s, { memoryEnabled: !!enabled })
      : s);
    _persist();
  }

  // Wipe every stored memory item from the shared sediment DB.
  // Destructive and global: affects every chat session on this user.
  // The Panel guards with a confirmation dialog; this just runs the
  // rm. Empty/missing dir is fine — the next sediment write will
  // recreate the LanceDB layout.
  function wipeMemory() {
    if (!memoryDbDir) return;
    const proc = _oneShotProcess.createObject(root);
    proc.command = ["find", memoryDbDir, "-mindepth", "1", "-delete"];
    proc.running = true;
  }

  function sendTo(id, text) {
    if (!id) return;
    const obj = _sessionObjs[id];
    if (!obj) return;
    obj.send(text);
  }

  function listSessions() {
    return JSON.stringify(sessionsList.map(s => ({
      id: s.id,
      name: s.name,
      workspacePath: s.workspacePath,
      trusted: !!s.trusted,
      active: s.id === activeSessionId,
      unread: s.unread || 0,
    })));
  }

  function markRead() {
    if (!activeSessionId) return;
    sessionsList = sessionsList.map(s => s.id === activeSessionId
      ? Object.assign({}, s, { unread: 0 })
      : s);
    _persist();
  }

  function _touchActive() {
    sessionsList = sessionsList.map(s => s.id === activeSessionId
      ? Object.assign({}, s, { lastActiveAt: Date.now() })
      : s);
    _persist();
  }

  // ── lazy spawn / idle reap ──

  // When the panel is open AND a session is active, ensure that
  // session's pi process is running. On idle, schedule a stop.
  property bool _panelOpen: pluginApi?.panelOpenScreen != null
  onActiveSessionIdChanged: _maybeSpawn()
  on_PanelOpenChanged: {
    if (_panelOpen) {
      _maybeSpawn();
      idleTimer.stop();
    } else {
      idleTimer.restart();
    }
  }

  function _maybeSpawn() {
    const s = _activeSession;
    if (s && _panelOpen && !s.streaming) {
      s.spawn();
      s.listModels();
      s._send({ type: "get_messages" });
    }
  }

  Timer {
    id: idleTimer
    interval: root.idleTimeoutMin * 60 * 1000
    onTriggered: {
      for (const id in root._sessionObjs) {
        const o = root._sessionObjs[id];
        if (o && o.streaming) o.stop();
      }
    }
  }

  // ── skill-config sidecar socket ──
  // Same NDJSON protocol as the chat socket; only the socket path
  // changes. Bubbles land in the session whose id matches the daemon
  // event's `instance` field (set from DISTRO_SESSION_ID inside the
  // scope), falling back to the active session.

  Loader {
    id: skillSock
    sourceComponent: skillSockComponent
    readonly property bool connected: item?.connected ?? false
  }
  Component {
    id: skillSockComponent
    Socket {
      path: root.skillConfigSockPath
      connected: true
      parser: SplitParser { onRead: line => root._recvSkillConfig(line) }
      onConnectionStateChanged: {
        if (connected) {
          skillReconnect.stop();
          skillReconnect.interval = 500;
          write(JSON.stringify({ op: "subscribe" }) + "\n");
          flush();
        } else {
          skillReconnect.start();
          root._retractAllPendingPrompts();
        }
      }
      onError: (e) => {
        Logger.w("PiChat", "skill-config subscribe", e);
        skillReconnect.start();
      }
    }
  }
  Timer {
    id: skillReconnect
    interval: 500
    onTriggered: {
      skillSock.active = false; skillSock.active = true;
      interval = Math.min(interval * 2, 4000);
    }
  }
  Component {
    id: skillOneShotComponent
    Socket {
      property var payload: null
      connected: path !== ""
      onConnectionStateChanged: {
        if (!connected) return;
        write(JSON.stringify(payload) + "\n");
        flush();
      }
      onError: (e) => Logger.w("PiChat", "skill-config one-shot", e)
      parser: SplitParser { onRead: () => {} }
    }
  }

  function skillConfigSend(payload) {
    const c = skillOneShotComponent.createObject(root, {
      path: root.skillConfigSockPath,
      payload: payload,
    });
    Qt.callLater(() => c.destroy(2000));
  }

  // ── open-url socket ──────────────────────────────────────────────
  // The pi sandbox can't reach the user's browser. Sandboxed skills
  // (google-cli auth, future OAuth flows) write `{"url":"…"}\n` to
  // this socket; OpenUrlListener opens it in the real user session.
  OpenUrlListener {
    sockPath: root.openUrlSockPath
  }

  function _recvSkillConfig(raw) {
    let ev;
    try { ev = JSON.parse(raw); }
    catch (_e) { Logger.w("PiChat", "bad skill-config json", raw); return; }
    switch (ev.op) {
    case "snapshot":
      _reconcileSkillSnapshot(ev.instance, ev.requests || []);
      break;
    case "added":
      _pushSkillPrompt(ev.instance, ev.request);
      break;
    case "removed":
      _retractSkillPrompt(ev.request_id);
      break;
    default:
      Logger.w("PiChat", "unknown skill-config op", ev.op);
    }
  }

  function _routeTo(instance) {
    if (instance && _sessionObjs[instance]) return _sessionObjs[instance];
    return _activeSession;
  }

  function _pushSkillPrompt(instance, req) {
    if (!req || !req.request_id) return;
    const session = _routeTo(instance);
    if (!session) return;
    const id = req.request_id;
    if (session.messages.some(m => m.id === id)) return;
    const entry = {
      id: id,
      text: req.description || "",
      ts: Date.now(),
      ack: "", image: "", replyTo: "",
      state: "sent", tries: 0,
      from: "peer",
      type: "prompt",
      promptInstance: instance || "",
      promptSkill: req.skill || "",
      promptProfile: req.profile || "",
      promptField: req.field || "",
      promptSecret: !!req.secret,
      promptState: "pending",
    };
    const arr = session.messages.slice();
    arr.push(entry);
    session.messages = arr;
    session.incomingNotification((req.skill || "") + " · " + (req.field || ""));
  }

  function _retractSkillPrompt(rid) {
    for (const id in _sessionObjs) {
      const s = _sessionObjs[id];
      const i = (s.messages || []).findIndex(m => m.id === rid);
      if (i < 0) continue;
      const m = s.messages[i];
      if (m.type !== "prompt") continue;
      if ((m.promptState ?? "pending") !== "pending") continue;
      s.patch(rid, { promptState: "retracted" });
    }
  }

  function _retractAllPendingPrompts() {
    for (const id in _sessionObjs) {
      const s = _sessionObjs[id];
      const arr = (s.messages || []).slice();
      let changed = false;
      for (let i = 0; i < arr.length; i++) {
        const m = arr[i];
        if (m.type === "prompt" && (m.promptState ?? "pending") === "pending") {
          arr[i] = Object.assign({}, m, { promptState: "retracted" });
          changed = true;
        }
      }
      if (changed) s.messages = arr;
    }
  }

  function _reconcileSkillSnapshot(instance, requests) {
    const live = {};
    for (const r of requests) live[r.request_id] = r;
    for (const id in _sessionObjs) {
      const s = _sessionObjs[id];
      const arr = (s.messages || []).slice();
      let changed = false;
      for (let i = 0; i < arr.length; i++) {
        const m = arr[i];
        if (m.type !== "prompt") continue;
        if ((m.promptState ?? "pending") !== "pending") continue;
        if (!live[m.id]) {
          arr[i] = Object.assign({}, m, { promptState: "retracted" });
          changed = true;
        }
      }
      if (changed) s.messages = arr;
    }
    for (const r of requests) _pushSkillPrompt(instance, r);
  }

  // ── PiSession materialization ──
  //
  // Manual reconcile rather than a Repeater, because Repeater
  // recreates delegates on any sessionsList reassignment — that
  // would tear down a running pi process every time we update
  // lastActiveAt or unread. Instead, instances live in _sessionObjs
  // and reconcile in place when the list changes.

  Component {
    id: _piSessionComponent
    PiSession { }
  }

  onSessionsListChanged: _reconcileSessions()
  Component.onCompleted: _reconcileSessions()

  function _reconcileSessions() {
    const have = {};
    for (const s of sessionsList) {
      have[s.id] = true;
      let obj = _sessionObjs[s.id];
      if (!obj) {
        obj = _piSessionComponent.createObject(root, {
          backend: root,
          sessionId: s.id,
          sessionName: s.name,
          workspacePath: s.workspacePath,
          trusted: !!s.trusted,
          modelPref: s.model || "",
          unread: s.unread || 0,
          piBin: Qt.binding(() => root.piBin),
          stateDir: Qt.binding(() => root.stateDir),
          piAgentDir: Qt.binding(() => root.piAgentDir),
          llmUrl: Qt.binding(() => root.llmUrl),
          memoryHigh: Qt.binding(() => root.memoryHigh),
          openrouterEnabled: Qt.binding(() => root.openrouterEnabled),
          // Per-session opt-out; missing field (legacy sessions.json)
          // defaults to true so existing chats keep memory on.
          memoryEnabled: s.memoryEnabled !== false,
          memoryDbDir: Qt.binding(() => root.memoryDbDir),
          memoryHfHome: Qt.binding(() => root.memoryHfHome),
          sandboxBinds: Qt.binding(() => root.sandboxBinds),
        });
        const idCaptured = s.id;
        obj.needsPersist.connect(() => root._persist());
        obj.incomingNotification.connect((t) => root._notify(idCaptured, t));
        _registerSession(obj);
      } else {
        if (obj.sessionName !== s.name) obj.sessionName = s.name;
        if (obj.workspacePath !== s.workspacePath) obj.workspacePath = s.workspacePath;
        if (obj.trusted !== !!s.trusted) obj.trusted = !!s.trusted;
        const mp = s.model || "";
        if (obj.modelPref !== mp) obj.modelPref = mp;
        const u = s.unread || 0;
        if (obj.unread !== u) obj.unread = u;
        const me = s.memoryEnabled !== false;
        if (obj.memoryEnabled !== me) obj.memoryEnabled = me;
      }
    }
    for (const id in _sessionObjs) {
      if (!have[id]) {
        const obj = _sessionObjs[id];
        obj?.stop?.();
        _unregisterSession(id);
        obj?.destroy?.();
      }
    }
  }

  function _notify(sessionId, text) {
    if (!text) return;
    // Avoid noisy toasts when the panel is already showing the chat.
    if (_panelOpen && activeSessionId === sessionId) return;
    const title = (sessionsList.find(s => s.id === sessionId)?.name) || "pi-chat";
    Quickshell.execDetached([
      "notify-send", "-a", "pi-chat", "-c", "im.received",
      title,
      (text || "").replace(/\s+/g, " ").trim().slice(0, 200),
    ]);
    // Bump unread for non-active sessions.
    if (sessionId !== activeSessionId) {
      sessionsList = sessionsList.map(s => s.id === sessionId
        ? Object.assign({}, s, { unread: (s.unread || 0) + 1 })
        : s);
      _persist();
    }
  }

  // ── null session for when sessionsList is briefly empty ──
  readonly property QtObject _nullSession: QtObject {
    property string peerName: ""
    property bool streaming: false
    property bool typing: false
    property string lastError: ""
    property var messages: []
    property var replyTarget: null
    property var models: []
    property string activeModel: ""
    readonly property int relaysUp: 0
    readonly property int relaysTotal: 0
    readonly property var relays: []
    function send(_t) {}
    function sendFile(_p, _u) {}
    function retry(_id) {}
    function cancel(_id) {}
    function confirmRespond(_id, _ok) {}
    function promptRespond(_id, _v) {}
    function promptCancel(_id) {}
    function listModels() {}
    function setModel(_p, _m) {}
    function patch(_id, _p) {}
  }

  // ── helper components ──

  readonly property Component _oneShotProcess: Component {
    Process { onExited: _ => destroy(2000) }
  }
}

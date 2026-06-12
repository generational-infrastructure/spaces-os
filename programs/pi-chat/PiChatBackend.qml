// Executor backend for the chat panel.
//
// Loads the sessions index from disk, materializes one PiSession per
// entry (each pinned to a pi-sessiond executor — the loopback
// pi-sessiond-local by default), and exposes `chat` aliased to the
// active session so the existing Panel/Bubble surface keeps working
// unchanged. Sessions stay cold until selected: attach happens on the
// first send, model query, or explicit selectSession().
//
// Skill-config prompts come through a separate persistent subscriber
// socket — same NDJSON protocol the skill-config daemon publishes.
pragma ComponentBehavior: Bound
import QtQuick
import QtQml
import Quickshell
import Quickshell.Io
import qs.Commons

Item {
  id: root

  // True while the chat window is showing. The shell.qml root binds
  // this from its `visible` property so the backend can drive the
  // lazy spawn / idle-reap loop without knowing about windows.
  property bool panelVisible: false

  // Per-user preferences (maxHistory, defaultWorkspaceRoot, …) come
  // from the same Settings singleton the rest of the app uses. The
  // module-derived deployment knobs (executor inventory, idle timeout,
  // memory-wipe dir) still come from /etc/spaces/pi-chat.json via
  // the FileView below — those are root-owned and don't belong in
  // the user-writable settings file.
  function cfg(key) {
    return Settings.data[key];
  }

  // ── module-derived config ──
  // The NixOS pi-chat module writes /etc/spaces/pi-chat.json with the
  // deployment-specific knobs (executor inventory, default model, idle
  // timeout). Reading it via FileView keeps the QML self-contained
  // without forcing the user manager's DefaultEnvironment to be wired
  // up correctly.
  FileView {
    id: configFile
    // Test seam: headless checks point the backend at a fixture config via
    // $SPACES_PI_CHAT_CONFIG, because the build sandbox can't write the
    // root-owned /etc path. Unset in production.
    path: String(Quickshell.env("SPACES_PI_CHAT_CONFIG") || "") || "/etc/spaces/pi-chat.json"
    printErrors: false
    JsonAdapter {
      id: configAdapter
      property string llmUrl: "http://127.0.0.1:8012"
      property string defaultModel: "gemma4:e4b"
      property string defaultProvider: "local"
      property int idleTimeoutMinutes: 10
      // $HOME-relative dir of the sediment vector store; the panel only
      // needs it for the destructive "wipe memory" action — recall and
      // storage run inside the executor daemon.
      property string memoryDbDir: ""
      // Remote executor (pi-sessiond) WebSocket endpoint. When wsUrl is
      // non-empty the panel attaches sessions over WS instead of spawning
      // pi locally; wsToken is the pre-shared `hello` secret.
      property string wsUrl: ""
      property string wsToken: ""
      // Multi-homing: remote executors the panel attaches to at once; each chat
      // session is pinned to one by its id. wsUrl/wsToken are the single-executor
      // shorthand, folded into this list below.
      property var executors: []
      property string defaultExecutor: ""
      // Per-user loopback pi-sessiond (services.pi-chat.localExecutor):
      // { id, url }. Folded into `executors` below with the per-login
      // runtime token path; null when the module hasn't enabled it.
      property var localExecutor: null
    }
  }

  readonly property alias _cfg: configAdapter

  readonly property string homeDir: String(Quickshell.env("HOME"))
  readonly property string runtimeDir: String(Quickshell.env("XDG_RUNTIME_DIR"))
  readonly property string stateDir: homeDir + "/.local/state/spaces/pi"
  readonly property string workspacesDir: homeDir + "/.local/share/spaces/workspaces"
  readonly property string sessionsIndexPath: stateDir + "/sessions.json"
  readonly property string llmUrl: root._cfg.llmUrl
  // memoryDbDir is composed against $HOME. Empty stays empty so
  // wipeMemory() is a no-op when the module hasn't populated the JSON.
  readonly property string memoryDbDir: root._cfg.memoryDbDir
    ? homeDir + "/" + String(root._cfg.memoryDbDir).replace(/^\/+/, "")
    : ""
  readonly property string wsUrl: root._cfg.wsUrl
  readonly property string wsToken: root._cfg.wsToken
  readonly property int idleTimeoutMin: {
    const c = cfg("idleTimeoutMinutes");
    if (typeof c === "number" && c > 0) return c;
    return root._cfg.idleTimeoutMinutes > 0 ? root._cfg.idleTimeoutMinutes : 10;
  }
  readonly property string skillConfigSockPath: runtimeDir + "/spaces-skill-config.sock"
  readonly property string openUrlSockPath: runtimeDir + "/spaces-pi-open-url.sock"
  readonly property string signalPanelSockPath: runtimeDir + "/spaces-signal/panel.sock"

  // Bridge between the spaces-signal panel socket and the chat UI.
  // The panel sits *outside* the pi-chat sandbox, so it (not the
  // agent) is the only thing that can mint approvals on outbound
  // Signal sends. `pending` and `approve(token)` / `deny(token)`
  // are surfaced to Panel.qml through this object.
  SignalConfirm {
    id: signalConfirm
    sockPath: root.signalPanelSockPath
    active: true
  }
  readonly property var signalPendingSends: signalConfirm.pending
  readonly property bool signalBridgeConnected: signalConfirm.connected
  function signalApprove(token) { signalConfirm.approve(token); }
  function signalDeny(token) { signalConfirm.deny(token); }

  // Multi-homing: the panel attaches to every configured executor at once and
  // each PiSession routes over the one its entry is pinned to (design stage 4).
  // `wsUrl`/`wsToken` remain a single-executor shorthand.
  readonly property var executors: {
    const list = (root._cfg.executors || []).slice();
    if (list.length === 0 && root.wsUrl !== "")
      list.push({ id: "remote", url: root.wsUrl, token: root.wsToken });
    // Loopback pi-sessiond-local: the module advertises { id, url }; the
    // hello token is per-login, minted into the user runtime dir, so only
    // its path goes on the entry — PiExecutor reads it at connect time.
    const le = root._cfg.localExecutor;
    if (le && le.id && le.url)
      list.push({ id: String(le.id), url: String(le.url), token: "", tokenPath: root.runtimeDir + "/pi-sessiond-local/token" });
    // Test seam: a headless check injects the executor topology as JSON via
    // $SPACES_PI_CHAT_EXECUTORS because it can't write the root-owned
    // /etc/spaces/pi-chat.json. Synchronous (no FileView) so it never perturbs
    // config-load ordering; unset in production, where the list is already set.
    if (list.length === 0) {
      const raw = String(Quickshell.env("SPACES_PI_CHAT_EXECUTORS") || "");
      if (raw !== "") {
        try {
          const parsed = JSON.parse(raw);
          if (Array.isArray(parsed)) return parsed;
        } catch (e) {
          Logger.w("PiChat", "bad SPACES_PI_CHAT_EXECUTORS", e);
        }
      }
    }
    return list;
  }
  // Default executor for new/legacy sessions: the lone configured one (so an
  // old single-wsUrl deployment keeps putting sessions there), else "" = the
  // local in-process pi.
  readonly property string defaultExecutorId: root._cfg.defaultExecutor || (executors.length === 1 ? executors[0].id : "")

  property var _executorById: ({})
  Instantiator {
    id: executorPool
    model: root.executors
    delegate: PiExecutor {
      required property var modelData
      // The executor id from the inventory (kiwi / traube / …). Used so
      // auto-imports stamp the panel entry with the right `executor`
      // field — that's the id PiChatBackend.executorFor() resolves back
      // to this delegate.
      readonly property string inventoryId: modelData.id
      url: modelData.url
      token: modelData.token || ""
      tokenPath: modelData.tokenPath || ""
      active: modelData.url !== ""
      // Every list-shaping push from this executor (the daemon broadcasts
      // one on create_session / gcSession / cold→live attach, plus the
      // one-shot reply to our own list_sessions on welcome) triggers a
      // merge pass over the union of all executors' lists.
      onRemoteSessionsChanged: root._importRemoteSessions()
    }
    onObjectAdded: root._rebuildExecutors()
    onObjectRemoved: root._rebuildExecutors()
  }

  // Map each executor id to its live PiExecutor. Built from the model (so the
  // id's type is known to the linter); objectAt(i) aligns with executors[i].
  function _rebuildExecutors() {
    const m = ({});
    for (let i = 0; i < executorPool.count; i++) {
      const obj = executorPool.objectAt(i);
      if (obj && root.executors[i]) m[root.executors[i].id] = obj;
    }
    root._executorById = m;
  }

  // Resolve a session's executor id to its live PiExecutor (null = local pi).
  function executorFor(id) {
    if (!id) return null;
    return root._executorById[id] || null;
  }

  // ── sessions index ──
  // Plain-JS array so QML bindings re-evaluate on assignment.
  property var sessionsList: []        // [{id, name, workspacePath, trusted, model, createdAt, lastActiveAt, unread}]
  property string activeSessionId: ""

  // ms-since-epoch cutoff that filters _importRemoteSessions. Sessions
  // whose `updated` is ≤ this value are pre-existing daemon residue and
  // stay parked on the daemon (still reachable on explicit attach, but
  // not auto-added to sessionsList). Loaded/initialised by
  // _loadFromAdapter; advanced by _importRemoteSessions on every import.
  property double lastImportTime: 0

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
      // Cutoff (ms since epoch) above which remoteSessions entries are
      // eligible for auto-import. Initialised to Date.now() the first
      // time this file is loaded without the field, so the executor's
      // historical cold-session residue (every chat ever created on it)
      // doesn't flood the tab strip on upgrade — and advanced to the
      // highest `updated` we've imported so siblings created after that
      // point come in, but the residue stays parked.
      property double lastImportTime: 0
    }
    onLoaded: root._loadFromAdapter()
  }
  readonly property alias _sessions: sessionsAdapter

  // Ephemeral per-session activity feed for external consumers — the
  // noctalia bar's session indicator reads this. Kept out of
  // sessions.json because "working" is live runtime state, not part of
  // the persisted index.
  FileView {
    id: activityFile
    path: root.stateDir + "/activity.json"
    printErrors: false
    JsonAdapter {
      id: activityAdapter
      property int version: 1
      property string activeSessionId: ""
      property var sessions: []
    }
  }

  function _loadFromAdapter() {
    // JsonAdapter `var` properties surface as V4 sequence references
    // (QVariantList wrappers), NOT JS Arrays: Array.isArray() is false
    // even when entries exist. Guarding on it sent every panel restart
    // down the bootstrap branch below, which then _persist()ed the
    // fresh "Chat 1" over the loaded file — wiping the session index
    // on disk and orphaning the daemon sessions it pointed at.
    // slice.call normalizes any indexable sequence into a real Array.
    const raw = Array.prototype.slice.call(root._sessions.sessions || []);
    if (raw.length > 0) {
      sessionsList = raw;
      activeSessionId = root._sessions.activeSessionId || raw[0].id;
    } else {
      // Bootstrap: auto-create one default session so the panel has
      // something to render on first run.
      const id = root._newId();
      sessionsList = [_freshSessionEntry(id, "Chat 1")];
      activeSessionId = id;
      _ensureSessionDirs(sessionsList[0].id, sessionsList[0].workspacePath);
      _persist();
    }
    const stored = root._sessions.lastImportTime || 0;
    lastImportTime = stored > 0 ? stored : Date.now();
    if (stored <= 0) _persist();
    // An executor's `sessions` reply may have raced past this load with
    // lastImportTime still at 0 (no-op then); replay the import now that
    // the cutoff is durable.
    _importRemoteSessions();
  }

  function _persist() {
    root._sessions.version = 1;
    root._sessions.sessions = sessionsList;
    root._sessions.activeSessionId = activeSessionId;
    root._sessions.lastImportTime = lastImportTime;
    sessionsFile.writeAdapter();
    root._scheduleActivityWrite();
  }

  // Republish activity.json: one entry per chat with its live state
  // ("working" = a prompt turn is in flight, otherwise "waiting" for
  // user input). Coalesced via Qt.callLater so a burst of busy / list
  // changes collapses into a single write.
  function _scheduleActivityWrite() {
    Qt.callLater(root._writeActivity);
  }

  function _writeActivity() {
    const out = sessionsList.map(s => {
      const obj = _sessionObjs[s.id];
      return {
        id: s.id,
        name: s.name,
        state: (obj && obj.busy) ? "working" : "waiting",
      };
    });
    activityAdapter.version = 1;
    activityAdapter.activeSessionId = activeSessionId;
    activityAdapter.sessions = out;
    activityFile.writeAdapter();
  }

  function _newId() {
    // ULID-ish: 13 base36 chars of ms + 8 of randomness. Good enough
    // for filesystem-name + key uniqueness here.
    const t = Date.now().toString(36);
    const r = Math.floor(Math.random() * 0x10000000).toString(36).padStart(8, "0");
    return String(t + r).slice(0, 21);
  }

  function _freshSessionEntry(id, name, executor) {
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
      // Which executor this chat is pinned to. May be "" when minted
      // during startup before the config (and thus defaultExecutorId)
      // loaded — resolution falls back to the default executor, so such
      // entries self-heal instead of staying unroutable.
      executor: executor !== undefined ? executor : root.defaultExecutorId,
      // Daemon-side session id, set after the executor's first
      // create_session ack (or pre-populated when auto-imported from an
      // executor's `sessions` push). Empty on freshly-minted local
      // entries that haven't talked to a daemon yet.
      daemonSessionId: "",
    };
  }

  // The default per-chat workspace dir, surfaced through listSessions
  // for external consumers (session indicators etc.). Conversation
  // state itself lives on the executor.
  function _ensureSessionDirs(sessionId, workspacePath) {
    const proc = _oneShotProcess.createObject(root);
    proc.command = ["mkdir", "-p", workspacePath];
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

  // Called by PiSession after a fresh create_session ack assigns it a
  // daemon-side id — or with "" when restart() drops the old daemon
  // session. Stamping the value on the persisted entry locks the
  // (panel ↔ daemon) session correspondence so future panel restarts
  // attach to the same daemon session (history continues) and so the
  // daemon's broadcast of the new id is recognised as "already ours" by
  // _importRemoteSessions instead of being auto-imported as a duplicate.
  function _onDaemonSessionAssigned(panelId, daemonId) {
    if (!panelId) return;
    const dId = daemonId || "";
    let dirty = false;
    sessionsList = sessionsList.map(s => {
      if (s.id !== panelId || s.daemonSessionId === dId) return s;
      dirty = true;
      return Object.assign({}, s, { daemonSessionId: dId });
    });
    if (dirty) _persist();
  }

  // Merge every executor's `remoteSessions` view (populated by the
  // daemon's `list_sessions` reply on hello + every unsolicited
  // `kind:"sessions"` push) into sessionsList. New ids — sessions
  // created on this executor by *another* client (the PWA, another
  // panel) — land as panel entries pinned to the right executor with
  // daemonSessionId set, so the reconciler will `attach` (not create)
  // on their first spawn and `get_messages` will replay history.
  //
  // Filtered by `lastImportTime`: anything whose `updated` is at or
  // below the cutoff is pre-existing daemon residue (cold sessions
  // accumulated by older runs, every chat ever created) and would
  // otherwise carpet-bomb the tab strip on first attach. Live and
  // newly-touched sessions still come through; the cutoff advances to
  // the highest imported `updated` so each import only moves forward.
  function _importRemoteSessions() {
    if (lastImportTime <= 0) return; // sessions.json not loaded yet
    // Snapshot per-executor remoteSessions (only for *connected* execs)
    // so we treat disconnect-induced empties as "we don't know", not
    // as "they're gone".
    const liveByExec = ({});
    for (let i = 0; i < executorPool.count; i += 1) {
      const exec = executorPool.objectAt(i);
      if (!exec || !exec.connected) continue;
      const set = new Set();
      const list = exec.remoteSessions || [];
      for (const r of list) if (r && r.id) set.add(r.id);
      liveByExec[exec.inventoryId] = { exec: exec, ids: set };
    }

    const known = new Set();
    for (const s of sessionsList) {
      if (s.daemonSessionId) known.add(s.daemonSessionId);
    }

    // Symmetric of auto-import: entries whose daemon id has disappeared
    // from a *connected* executor's view were deleted upstream (by a
    // sibling client's delete_session). Drop them locally so the tab
    // strip mirrors the daemon's truth — the reconciler stop/destroys
    // the orphaned PiSession in the same pass.
    const removeIds = [];
    for (const s of sessionsList) {
      if (!s.daemonSessionId || !s.executor) continue;
      const view = liveByExec[s.executor];
      if (!view) continue; // executor offline → withhold judgement
      if (!view.ids.has(s.daemonSessionId)) removeIds.push(s.id);
    }

    // Additions: new ids past the time cutoff.
    const adds = [];
    let newCutoff = lastImportTime;
    for (const invId in liveByExec) {
      const view = liveByExec[invId];
      const list = view.exec.remoteSessions || [];
      for (let j = 0; j < list.length; j += 1) {
        const r = list[j];
        if (!r || !r.id || known.has(r.id)) continue;
        // Our own create_session in flight: the broadcast carrying this id
        // can be processed before the create promise's .then stamps the
        // panel entry (promise jobs drain after the socket's message
        // burst). The executor holds a claim for that window — skip, the
        // owning PiSession will bind it.
        if (view.exec.isPendingCreated(r.id)) continue;
        const updated = r.updated || 0;
        if (updated <= lastImportTime) continue;
        known.add(r.id);
        const entry = _freshSessionEntry(
          r.id,
          r.name || ("[" + invId + "] " + r.id.slice(0, 8)),
          invId
        );
        entry.daemonSessionId = r.id;
        adds.push(entry);
        _ensureSessionDirs(entry.id, entry.workspacePath);
        if (updated > newCutoff) newCutoff = updated;
      }
    }

    if (removeIds.length === 0 && adds.length === 0) return;
    const removeSet = new Set(removeIds);
    let next = sessionsList.filter(s => !removeSet.has(s.id));
    if (adds.length > 0) next = next.concat(adds);
    sessionsList = next;
    if (removeSet.has(activeSessionId)) {
      activeSessionId = next.length > 0 ? next[0].id : "";
    }
    if (adds.length > 0) lastImportTime = newCutoff;
    _persist();
  }

  // ── public IPC surface (used by Main.qml's IpcHandler) ──

  function newSession(name, executorId, opts) {
    const id = _newId();
    const entry = _freshSessionEntry(id, (name && String(name).trim()) || ("Chat " + (sessionsList.length + 1)), executorId);
    // opts.model is "provider/id"; persisted on the entry so the
    // reconciler binds it to the PiSession's modelPref. Shape is
    // extensible (cwd, skill) without touching callers. Without an
    // explicit model, inherit the user's most recent pick from the
    // frecency store so a new chat starts where they left off instead
    // of on pi's default. The inheritance lives only here, not in
    // _freshSessionEntry(). Sessions auto-imported from a remote
    // executor must keep "" because their model lives on the daemon
    // side.
    entry.model = (opts && opts.model) || ModelFrecency.mostRecent() || "";
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

  // ── model cache (for the quick-launch bar) ──
  //
  // The bar offers model completion *before* any PiSession exists, but
  // the model list is otherwise a per-session RPC. Cache it on the
  // backend: filled cheaply by a one-shot GET of /v1/models (covers the
  // default local-only llama-swap deployment with zero spawned agent)
  // and topped up from any live session's richer list. Entries are
  // { provider, id }.
  property var modelsList: []
  property bool modelsLoaded: false

  // One-shot GET of llmUrl/v1/models. curl --fail is the proven call in
  // this tree (no XMLHttpRequest precedent); StdioCollector is the
  // stdout-capture idiom. /v1/models returns bare ids, so each is keyed
  // to the configured default provider.
  function refreshModels() {
    const proc = _modelsProbeComponent.createObject(root);
    proc.command = ["curl", "--fail", "--silent", "--max-time", "5", root.llmUrl + "/v1/models"];
    proc.running = true;
  }

  // Merge entries into modelsList, deduped on provider+"/"+id. The
  // /v1/models cache and a live session's forwarded models collide on
  // the same id (both provider "local") and would otherwise double-list.
  // Entries without a provider (bare /v1/models ids) take the default.
  function _mergeModels(incoming) {
    if (!Array.isArray(incoming)) return;
    const seen = {};
    const out = [];
    for (const m of modelsList.concat(incoming)) {
      if (!m || !m.id) continue;
      const provider = m.provider || root._cfg.defaultProvider;
      const key = provider + "/" + m.id;
      if (seen[key]) continue;
      seen[key] = true;
      out.push({ provider: provider, id: m.id });
    }
    modelsList = out;
  }

  readonly property Component _modelsProbeComponent: Component {
    Process {
      id: probe
      property string _out: ""
      stdout: StdioCollector { onStreamFinished: probe._out = text }
      onExited: code => {
        if (code === 0 && probe._out) {
          try {
            const payload = JSON.parse(probe._out);
            const data = Array.isArray(payload.data) ? payload.data : [];
            root._mergeModels(data.map(m => ({ id: m.id })));
          } catch (e) {
            Logger.w("PiChat", "refreshModels parse failed", e);
          }
        }
        root.modelsLoaded = true;
        destroy(2000);
      }
    }
  }

  // ── quick-launch (fire-and-forget background agent) ──
  //
  // Sessions pending a completion notification: id → prompt summary.
  // A session lands here when launched from the quick bar while the
  // chat panel is closed; the reaper exempts it and the per-session
  // busy→idle hook fires the "Agent finished" toast off it.
  property var _pendingBg: ({})

  // First line of the prompt, trimmed to ~40 chars — the session title
  // and the completion-notification body.
  function promptSummary(prompt) {
    const first = String(prompt || "").split("\n")[0].trim();
    return first.length > 40 ? first.slice(0, 40) : first;
  }

  // True when `id` names a configured executor. The validation point for
  // /host: launches: an unknown id must be refused, never silently routed
  // to the default (mirrors how /model: refuses an unknown model).
  function _isKnownExecutor(id) {
    for (const e of executors) if (e && e.id === id) return true;
    return false;
  }

  // Launch an agent in the background: create a normal session, spawn
  // its pi worker *directly* (bypassing the panel-open gate in
  // _maybeSpawn, which would otherwise refuse to spawn while the panel
  // is closed), send the prompt, and mark it pending so the reaper
  // leaves it alone and completion notifies. The session is a
  // first-class index entry, continuable later via the chat panel.
  function launchBackground(prompt, opts) {
    if (!prompt || !String(prompt).trim()) return "";
    // /host:<id> pins the session to a configured executor. Refuse an
    // unknown id outright rather than letting it fall through to the
    // default — a session pinned to a non-existent executor would never
    // route. Empty ⇒ undefined ⇒ defaultExecutor (today's behaviour).
    const executor = (opts && opts.executor) || "";
    if (executor !== "" && !_isKnownExecutor(executor)) {
      Logger.w("PiChat", "launch refused: unknown executor", executor);
      return "";
    }
    const summary = promptSummary(prompt);
    const id = newSession(summary, executor !== "" ? executor : undefined, opts);
    const obj = _sessionObjs[id];
    if (!obj) return id;
    const map = Object.assign({}, _pendingBg);
    map[id] = summary;
    _pendingBg = map;
    // Spawn here so the worker comes up while the panel is hidden;
    // spawn() is idempotent, so setModelAndWait()/send() re-calling it
    // for the cold-session case is a harmless no-op.
    obj.spawn();
    const model = (opts && opts.model) || "";
    const slash = model.indexOf("/");
    if (slash > 0) {
      // Await pi's set_model before the prompt — a fire-and-forget
      // setModel would race and the turn could run on the default model
      // (see PiSession.setModelAndWait). On failure abort rather than
      // silently launch on the wrong model, and clear the background
      // pending mark (no turn will run, so onBusyChanged won't) so the
      // idle worker becomes reapable instead of leaking.
      obj.setModelAndWait(model.slice(0, slash), model.slice(slash + 1))
        .then(() => obj.send(prompt))
        .catch(e => {
          Logger.w("PiChat", "launch set_model failed; prompt not sent", e);
          const m2 = Object.assign({}, _pendingBg);
          delete m2[id];
          _pendingBg = m2;
          obj.stop();
        });
    } else {
      obj.send(prompt);
    }
    return id;
  }

  // A pending background session finished its turn (busy true→false).
  // Notify unless the user is already watching it (panel open + active),
  // then drop the pending mark — from here it's just a normal session.
  function _onBackgroundTurnFinished(id) {
    if (!_pendingBg.hasOwnProperty(id)) return;
    const summary = _pendingBg[id];
    const map = Object.assign({}, _pendingBg);
    delete map[id];
    _pendingBg = map;
    if (_panelOpen && activeSessionId === id) return;
    const proc = _oneShotProcess.createObject(root);
    proc.command = ["notify-send", "-a", "pi-chat", "-c", "im.received",
      "Agent finished", summary];
    proc.running = true;
  }

  function removeSession(id) {
    if (!id) return;
    const entry = sessionsList.find(s => s.id === id);
    const obj = _sessionObjs[id];
    if (obj) obj.stop();
    // If this entry maps to a daemon session, tell the executor to
    // delete it too — otherwise the daemon would keep the session.jsonl
    // on disk and the next `sessions` push would auto-import it right
    // back. The daemon's own broadcast will resolve sibling clients
    // (and our own re-importer skips it because it's gone from the
    // executor's view).
    if (entry && entry.daemonSessionId && entry.executor) {
      const exec = _executorById[entry.executor];
      if (exec) exec.deleteSession(entry.daemonSessionId);
    }
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
  // Mirrors `shell.qml`'s window `visible` so the backend can spawn
  // pi on first display and reap it on idle without holding a
  // reference to the window itself.
  readonly property bool _panelOpen: root.panelVisible
  onActiveSessionIdChanged: {
    _maybeSpawn();
    _scheduleActivityWrite();
  }
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
    onTriggered: root._reapIdle()
  }

  // Stop running sessions that are sitting idle to free their pi
  // worker. A session actively generating (busy) — or a pending
  // background launch — must SURVIVE: a fire-and-forget task that runs
  // for 30 min can't be killed 10 min after the panel closes. Cold
  // sessions (streaming false) have nothing to reap.
  function _reapIdle() {
    for (const id in root._sessionObjs) {
      const o = root._sessionObjs[id];
      if (!o || !o.streaming) continue;
      if (o.busy) continue;
      if (root._pendingBg.hasOwnProperty(id)) continue;
      o.stop();
    }
  }

  // ── skill-config sidecar socket ──
  // Same NDJSON protocol as the chat socket; only the socket path
  // changes. Bubbles land in the session whose id matches the daemon
  // event's `instance` field (set from SPACES_SESSION_ID inside the
  // scope), falling back to the active session.

  Socket {
    id: skillSock
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
    onError: e => {
      Logger.w("PiChat", "skill-config subscribe", e);
      skillReconnect.start();
    }
  }
  Timer {
    id: skillReconnect
    interval: 500
    onTriggered: {
      // Bounce the connection: setting connected=false closes the
      // socket, =true reopens it. Matches the old Loader recreate
      // semantics without losing the static Socket type.
      skillSock.connected = false;
      skillSock.connected = true;
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
      onError: e => Logger.w("PiChat", "skill-config one-shot", e)
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

  // Route a skill-config event to its owning session. `instance` is the
  // SPACES_SESSION_ID baked into the bash sandbox — the *daemon's*
  // session id — so match entries by daemonSessionId first; legacy
  // events carrying a panel id still hit the direct lookup.
  function _routeTo(instance) {
    if (instance) {
      if (_sessionObjs[instance]) return _sessionObjs[instance];
      const entry = sessionsList.find(s => s.daemonSessionId === instance);
      if (entry && _sessionObjs[entry.id]) return _sessionObjs[entry.id];
    }
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
    // Persist and notification routing live on the instance instead of
    // imperative `.connect()` calls in _reconcileSessions(): keeps the
    // signal targets statically typed for qmllint and removes the need
    // to capture sessionId out-of-band.
    PiSession {
      onNeedsPersist: backend._persist()
      onIncomingNotification: t => backend._notify(sessionId, t)
      onBusyChanged: {
        if (!busy)
          backend._onBackgroundTurnFinished(sessionId);
        backend._scheduleActivityWrite();
      }
      // A live session enumerates the authoritative list (e.g. OpenRouter
      // models /v1/models won't surface); fold it into the bar's cache.
      onModelsChanged: backend._mergeModels(models)
    }
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
          // Per-session opt-out; missing field (legacy sessions.json)
          // defaults to true so existing chats keep memory on.
          memoryEnabled: s.memoryEnabled !== false,
          // "" (entry minted before the executor inventory loaded, or a
          // pre-cutover legacy entry) falls back to the default executor.
          executor: Qt.binding(() => root.executorFor(s.executor || root.defaultExecutorId)),
          // Re-attach to an existing daemon session instead of minting a
          // new one. Populated when this entry was either:
          //   - auto-imported from an executor's remoteSessions push (a
          //     session created on this executor by another client — the
          //     PWA, another panel, …); or
          //   - persisted after a previous panel run's create_session
          //     (cross-restart history continuity).
          // Empty string falls through to create_session on first spawn.
          initialDaemonSessionId: s.daemonSessionId || "",
        });
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
    _scheduleActivityWrite();
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

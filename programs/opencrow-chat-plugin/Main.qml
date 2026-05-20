import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.UI

// Thin view layer. All state — history, dedup, outbox, reconnect —
// lives in opencrow. A single persistent unix socket carries NDJSON
// both ways: we write commands, the daemon writes events. On connect
// (and every reconnect) we send a replay; that's the whole resync
// protocol.
Item {
  id: root

  property var pluginApi: null
  property alias chat: chat

  function cfg(key) {
    const s = pluginApi?.pluginSettings || {};
    const d = pluginApi?.manifest?.metadata?.defaultSettings || {};
    return s[key] ?? d[key];
  }

  // XDG_RUNTIME_DIR is guaranteed by systemd-logind; without it rbw
  // (and thus the daemon) can't run either, so no fallback needed.
  // Quickshell.env returns QVariant — String() avoids "undefined/…".
  readonly property string sockPath:
    String(Quickshell.env("XDG_RUNTIME_DIR")) + "/opencrow-chat.sock"

  // Sidecar IPC socket for skill-config credential prompts. Same shape
  // as chat.sock (per-user symlink installed by opencrow-socket-link
  // pointing at the in-container /run/opencrow-<inst>/skill-config.sock).
  // Prompts arrive on a persistent `subscribe` connection and are
  // rendered as `type: "prompt"` bubbles in the chat history; submit
  // and cancel are short-lived one-shot connections per the daemon's
  // protocol.
  readonly property string skillConfigSockPath:
    String(Quickshell.env("XDG_RUNTIME_DIR")) + "/opencrow-skill-config.sock"

  // Host-side staging dir for file attachments (symlinked to the
  // socket dir's attachments/ subdirectory, which is bind-mounted
  // into the container).
  readonly property string attachDir:
    String(Quickshell.env("XDG_RUNTIME_DIR")) + "/opencrow-chat-attachments"
  // Matching path inside the container (bind-mount target).
  readonly property string containerAttachDir: "/run/opencrow-sock/attachments"

  // Mirror of the daemon's typed enums. QML has no real enum type for
  // dynamic JS, but a frozen object at least centralises the strings
  // so a rename is one grep instead of six.
  readonly property var ev: Object.freeze({
    status: "status", msg: "msg", sent: "sent", retry: "retry",
    ack: "ack", img: "img", error: "error", typing: "typing", delta: "delta",
    models: "models", confirm: "confirm",
  })
  readonly property var cmd: Object.freeze({
    send: "send", sendFile: "send-file", replay: "replay",
    markRead: "mark-read", retry: "retry", cancel: "cancel",
    listModels: "list-models", setModel: "set-model",
    confirmResponse: "confirm-response",
  })
  readonly property var state: Object.freeze({
    pending: "pending", sent: "sent", cancelled: "cancelled",
  })

  // Fallback: clear typing if no reply arrives within 2 minutes.
  Timer { id: typingTimer; interval: 120000; onTriggered: chat.typing = false }
  // Minimum visibility: keep indicator for at least 500ms so it doesn't flash.
  Timer { id: typingClearTimer; interval: 500; onTriggered: chat.typing = false }

  QtObject {
    id: chat
    property string peerName: ""   // from daemon's OPENCROW_CHAT_DISPLAY_NAME
    property bool streaming: false
    property int relaysUp: 0
    property int relaysTotal: 0
    property var relays: []        // connected URLs, for the header tooltip
    property string lastError: ""
    property bool typing: false
    property var messages: []   // [{id, from, text, ts, ack, image, replyTo, state, tries, type}]
    property var replyTarget: null  // {id, text} — set by Panel when user clicks a bubble

    // Model registry. populated by 'models' events from the daemon.
    // models: [{provider, id, contextWindow, reasoning, active}]
    // activeModel: "<provider>/<id>" or "" until set_model is observed.
    property var models: []
    property string activeModel: ""

    function send(text) {
      if (!text.trim()) return;
      typing = true;
      root.sockSend({
        cmd: root.cmd.send, text: text,
        replyTo: replyTarget ? replyTarget.id : undefined,
      });
      replyTarget = null;
    }
    function sendFile(path, unlink) {
      if (!path) return;
      // NFilePicker returns bare paths; strip file:// just in case.
      if (path.startsWith("file://")) path = decodeURIComponent(path.slice(7));
      // The daemon runs in a container that can't see host paths.
      // Stage the file into the shared attachments dir (bind-mounted
      // into the container) and send the container-side path instead.
      // cp prints the chosen basename on stdout; stageProc.onExited
      // turns that into a 'send-file' command. Without this hop the
      // file picker would silently no-op — the agent never sees it.
      const rmClause = unlink ? ' && rm -f -- "$1"' : "";
      stageProc.command = ["sh", "-c",
        'name="$(date +%s%N)-$(basename "$1")" && ' +
        'cp -- "$1" "' + root.attachDir + '/$name"' +
        rmClause + ' && printf "%s" "$name"',
        "sh", path];
      stageProc.running = true;
    }
    function retry(id)  { root.sockSend({ cmd: root.cmd.retry,  id: id }); }
    function cancel(id) { root.sockSend({ cmd: root.cmd.cancel, id: id }); }

    // Answer a pending confirm request. Patches the local message so
    // its Allow/Deny buttons disappear and an outcome label shows.
    function confirmRespond(id, confirmed) {
      root.sockSend({ cmd: root.cmd.confirmResponse, id: id, confirmed: confirmed });
      patch(id, { confirmState: confirmed ? "allowed" : "denied" });
    }

    // Answer a pending skill-config prompt. Submit sends the typed
    // value to the sidecar daemon's socket; cancel sends a `cancel`.
    // We optimistically patch local state — the daemon's `removed`
    // event on the subscribe stream is the authoritative ack.
    function promptRespond(id, value) {
      root.skillConfigSend({ op: "submit", request_id: id, value: value });
      patch(id, { promptState: "submitted", text: "" });
    }
    function promptCancel(id) {
      root.skillConfigSend({ op: "cancel", request_id: id });
      patch(id, { promptState: "cancelled" });
    }

    // Refresh model list from the daemon. Result arrives via 'models' event.
    function listModels() {
      root.sockSend({ cmd: root.cmd.listModels });
    }
    // Switch model. Daemon broadcasts a 'models' event with active flag set.
    function setModel(provider, modelId) {
      root.sockSend({ cmd: root.cmd.setModel, provider: provider, modelId: modelId });
    }

    // Patch a single message in place and reassign so ListView refreshes.
    function patch(id, props) {
      const arr = messages.slice();
      const i = arr.findIndex(x => x.id === id);
      if (i < 0) return;
      arr[i] = Object.assign({}, arr[i], props);
      messages = arr;
    }
  }

  // Host-side staging for chat.sendFile. The daemon lives in a
  // container; sending the host path would yield a 'no such file'
  // error there. We cp into the bind-mounted attachments dir and
  // hand the daemon the container-visible path.
  Process {
    id: stageProc
    property string staged: ""
    stdout: StdioCollector { onStreamFinished: stageProc.staged = text }
    onExited: (code) => {
      if (code === 0 && staged) {
        root.sockSend({ cmd: root.cmd.sendFile, path: root.containerAttachDir + "/" + staged });
      } else if (code !== 0) {
        chat.lastError = "attachment staging failed";
        errorTimer.restart();
      }
      staged = "";
    }
  }

  // Errors shouldn't outlive their toast. Per-bubble ⚠ is the durable
  // signal; this line is just transient context.
  Timer {
    id: errorTimer
    interval: 10000
    onTriggered: chat.lastError = ""
  }

  // Open the panel idempotently. Upstream openPluginPanel() has a bug:
  // when the slot already holds our plugin it calls panel.toggle(),
  // slamming it shut mid-read. Guard on panelOpenScreen ourselves.
  function showPanel() {
    if (pluginApi?.panelOpenScreen) { sockSend({ cmd: cmd.markRead }); return; }
    pluginApi?.withCurrentScreen(s => pluginApi.openPanel(s));
    sockSend({ cmd: cmd.markRead });
  }

  // Fire-and-forget desktop notification via libnotify. notify-send
  // talks to the org.freedesktop.Notifications service that noctalia
  // itself implements, so this surfaces as a normal toast/popup.
  function notifyIncoming(text) {
    // Skip when the panel is already on-screen: the user is looking at
    // the conversation, an extra desktop toast would just be noise.
    if (pluginApi?.panelOpenScreen) { sockSend({ cmd: cmd.markRead }); return; }
    const title = chat.peerName || "opencrow-chat";
    const body = (text || "").replace(/\s+/g, " ").trim().slice(0, 200);
    Quickshell.execDetached([
      "notify-send", "-a", "opencrow-chat", "-c", "im.received",
      title, body,
    ]);
  }

  // Persistent bidirectional socket. On connect we ask for a replay;
  // the daemon answers with status + recent messages on the same pipe.
  // A disconnect (daemon restart, suspend) just triggers the reconnect
  // timer — next connect replays again, so the ListView converges
  // without any booted/handshake dance.
  //
  // Loader wrapper: Quickshell's Socket keeps its QLocalSocket alive
  // after a failed connect (errorOccurred fires, disconnected doesn't),
  // and setConnected(true) only dials when that pointer is null — so
  // one refused/not-found leaves it wedged forever. Recreating the
  // whole Socket is the only QML-side way to drop the stale handle.
  Loader {
    id: sock
    sourceComponent: sockComponent
    readonly property bool connected: item?.connected ?? false
  }
  Component {
    id: sockComponent
    Socket {
      path: root.sockPath
      connected: true
      parser: SplitParser { onRead: line => root.recv(line) }
      onConnectionStateChanged: {
        if (connected) {
          reconnect.stop();
          reconnect.interval = 500;
          chat.lastError = "";
          // sock.item may still be null here (Loader hasn't published
          // it yet when QLocalSocket connects synchronously during
          // construction), so write through `this`, not sockSend().
          write(JSON.stringify({ cmd: root.cmd.replay, n: root.cfg("maxHistory") || 200 }) + "\n");
          // Pull current model list so the dropdown is populated by the
          // time the user opens the panel.
          write(JSON.stringify({ cmd: root.cmd.listModels }) + "\n");
          flush();
        } else {
          chat.streaming = false;
          reconnect.start();
        }
      }
      onError: (e) => {
        chat.lastError = "daemon unreachable";
        Logger.w("OpencrowChat", "socket", e, "path", path);
        reconnect.start();
      }
    }
  }
  Timer {
    id: reconnect
    interval: 500
    // Cap under the daemon's RestartSec so we're waiting when it
    // returns, not the other way round.
    onTriggered: {
      // Tear down and rebuild — see Loader comment for why a simple
      // `connected = true` can't recover from a refused connect.
      sock.active = false; sock.active = true;
      interval = Math.min(interval * 2, 4000);
    }
  }
  function sockSend(c) {
    if (!sock.item?.connected) return;  // replay-on-connect covers the gap
    sock.item.write(JSON.stringify(c) + "\n");
    sock.item.flush();
  }

  // ── skill-config sidecar socket ────────────────────────────────────
  // Persistent subscribe stream feeding `type: "prompt"` bubbles, plus
  // a one-shot sender for submit/cancel. Mirrors the chat-socket Loader
  // pattern (recreate-on-failure) for the same reason: QLocalSocket
  // wedges after a refused connect and the only QML-side recovery is
  // dropping the underlying Socket and creating a fresh one.
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
      parser: SplitParser { onRead: line => root.recvSkillConfig(line) }
      onConnectionStateChanged: {
        if (connected) {
          skillReconnect.stop();
          skillReconnect.interval = 500;
          write(JSON.stringify({ op: "subscribe" }) + "\n");
          flush();
        } else {
          // Daemon down (container restart, symlink missing, …). Mark
          // any pending prompt bubbles as retracted so the user doesn't
          // keep typing into a card that can't deliver.
          root.retractAllPendingPrompts();
          skillReconnect.start();
        }
      }
      onError: (e) => {
        Logger.w("OpencrowChat", "skill-config subscribe", e, "path", path);
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
      // Gate the dial on `path` being set — literal `connected: true`
      // triggers a connect at the default empty path before initial
      // properties land, which wedges QLocalSocket.
      connected: path !== ""
      onConnectionStateChanged: {
        if (!connected) return;
        write(JSON.stringify(payload) + "\n");
        flush();
      }
      onError: (e) => Logger.w("OpencrowChat", "skill-config one-shot", e)
      parser: SplitParser { onRead: () => {} }  // ack ignored — `removed` is the truth
    }
  }
  function skillConfigSend(payload) {
    const c = skillOneShotComponent.createObject(root, {
      path: root.skillConfigSockPath,
      payload: payload,
    });
    // Daemon closes after the ack — schedule destruction so we don't
    // leak QLocalSockets across many prompts.
    Qt.callLater(() => c.destroy(2000));
  }

  function retractAllPendingPrompts() {
    const arr = chat.messages.slice();
    let changed = false;
    for (let i = 0; i < arr.length; i++) {
      const m = arr[i];
      if (m.type === "prompt" && (m.promptState ?? "pending") === "pending") {
        arr[i] = Object.assign({}, m, { promptState: "retracted" });
        changed = true;
      }
    }
    if (changed) chat.messages = arr;
  }

  // One NDJSON line from the skill-config subscribe stream.
  function recvSkillConfig(raw) {
    let ev;
    try { ev = JSON.parse(raw); }
    catch (e) { Logger.w("OpencrowChat", "bad skill-config json", raw); return; }
    switch (ev.op) {
    case "snapshot":
      // Authoritative reset on (re)subscribe. Bubbles still flagged
      // pending locally but absent from the snapshot were served by a
      // peer subscriber (or timed out) while we were offline.
      _reconcilePromptSnapshot(ev.instance, ev.requests || []);
      break;
    case "added":
      _pushPrompt(ev.instance, ev.request);
      break;
    case "removed":
      _retractPrompt(ev.request_id);
      break;
    default:
      Logger.w("OpencrowChat", "unknown skill-config op", ev.op);
    }
  }

  function _pushPrompt(instance, req) {
    if (!req || !req.request_id) return;
    const id = req.request_id;
    const arr = chat.messages.slice();
    if (arr.some(x => x.id === id)) return;  // dup from snapshot/race
    arr.push({
      id: id,
      text: req.description || "",
      ts: Date.now(),
      ack: "", image: "", replyTo: "",
      state: root.state.sent, tries: 0,
      from: "peer",
      type: "prompt",
      promptInstance: instance || "",
      promptSkill: req.skill || "",
      promptProfile: req.profile || "",
      promptField: req.field || "",
      promptSecret: !!req.secret,
      promptState: "pending",
    });
    const max = cfg("maxHistory") || 200;
    chat.messages = arr.length > max ? arr.slice(-max) : arr;
    // Notify so a closed panel doesn't silently swallow the request.
    // The bubble itself is the durable affordance once the panel opens.
    root.notifyIncoming((req.skill || "") + " · " + (req.field || ""));
  }

  function _retractPrompt(rid) {
    const i = chat.messages.findIndex(m => m.id === rid);
    if (i < 0) return;
    const m = chat.messages[i];
    if (m.type !== "prompt") return;
    // Local submit/cancel already settled the state — preserve it.
    if ((m.promptState ?? "pending") !== "pending") return;
    chat.patch(rid, { promptState: "retracted" });
  }

  function _reconcilePromptSnapshot(instance, requests) {
    const live = {};
    for (const r of requests) live[r.request_id] = r;
    const arr = chat.messages.slice();
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
    if (changed) chat.messages = arr;
    for (const r of requests) _pushPrompt(instance, r);
  }

  // Container paths come back inside file messages because the daemon
  // lives in a container that only sees the bind-mount target. The
  // host attachments dir is a symlink to the same inode, so we just
  // rewrite the prefix for the Image element (file:// needs a path
  // the host process can stat).
  function hostPath(p) {
    if (!p) return "";
    if (p.indexOf(root.containerAttachDir + "/") === 0)
      return root.attachDir + p.slice(root.containerAttachDir.length);
    return p;
  }

  // One NDJSON line from the daemon.
  function recv(raw) {
    let ev;
    try { ev = JSON.parse(raw); }
    catch (e) { Logger.w("OpencrowChat", "bad ipc json", raw); return; }

    switch (ev.kind) {
    case root.ev.status:
      chat.streaming   = ev.streaming;
      chat.relaysUp    = ev.relaysUp || 0;
      chat.relaysTotal = ev.relaysTotal || chat.relaysTotal;
      chat.relays      = ev.relays || [];
      chat.peerName    = ev.name || chat.peerName;
      break;

    case root.ev.msg: {
      const m = ev.msg;
      // Daemon dedups; we just keep a bounded in-memory mirror for the
      // ListView. Insert-sort by ts since replay + live can interleave.
      const entry = {
        id: m.id, text: m.content, ts: m.ts * 1000, ack: m.ack,
        image: hostPath(m.image), replyTo: m.replyTo || "",
        state: m.state || state.sent, tries: 0,
        from: m.dir === "out" ? "me" : "peer",
        type: m.type || "",
      };
      let arr = chat.messages.slice();
      // Remove any streaming placeholder — the final message replaces it.
      if (m.dir === "in") arr = arr.filter(x => x.state !== "streaming");
      let i = arr.length;
      while (i > 0 && arr[i-1].ts > entry.ts) i--;
      // Skip if already mirrored (replay after a live insert).
      if (arr.some(x => x.id === entry.id)) return;
      // Drop [EMPTY] responses (agent produced no meaningful output).
      // Commit `arr` first so the streaming placeholder built up from
      // deltas — which already contains "[EMPTY]" — is also removed.
      if (m.dir === "in" && m.content.trim() === "[EMPTY]") {
        chat.messages = arr;
        typingTimer.stop();
        typingClearTimer.restart();
        return;
      }
      arr.splice(i, 0, entry);
      const max = cfg("maxHistory") || 200;
      if (arr.length > max) arr = arr.slice(-max);
      chat.messages = arr;

      // Clear typing indicator when a bot reply arrives.
      if (m.dir === "in") { typingTimer.stop(); typingClearTimer.restart(); }

      // Surface live bot replies as a desktop notification instead of
      // grabbing focus by popping the panel open. The daemon marks
      // replayed history as read, so shell startup stays quiet.
      if (m.dir === "in" && !m.read) root.notifyIncoming(m.content);
      break;
    }

    case root.ev.sent:
      if (ev.state === state.cancelled) {
        chat.messages = chat.messages.filter(x => x.id !== ev.target);
      } else {
        chat.patch(ev.target, { state: state.sent, tries: 0 });
      }
      break;

    case root.ev.retry:
      // Mark the specific bubble ⚠ — the user can tap to force a retry
      // or drop it. Toast only on the first failure so backoff doesn't
      // spam the notification stack.
      chat.patch(ev.target, { tries: ev.tries });
      if (ev.tries === 1)
        ToastService.showError((chat.peerName || "opencrow-chat") + ": send failed, retrying");
      break;

    case root.ev.ack:
      chat.patch(ev.target, { ack: ev.mark });
      break;

    case root.ev.img:
      chat.patch(ev.target, { image: hostPath(ev.image) });
      break;

    case root.ev.typing:
      chat.typing = true;
      typingTimer.restart();
      break;

    case root.ev.delta: {
      // Streaming text delta — append to existing message or create one.
      const id = ev.target;
      const delta = ev.text || "";
      if (!delta) break;
      let arr = chat.messages.slice();
      const idx = arr.findIndex(x => x.id === id);
      if (idx >= 0) {
        // Append delta to existing streaming message.
        arr[idx] = Object.assign({}, arr[idx], { text: arr[idx].text + delta });
      } else {
        // First delta — create a new streaming entry.
        arr.push({
          id: id, text: delta, ts: Date.now(), ack: "",
          image: "", replyTo: "", state: "streaming", tries: 0,
          from: "peer",
        });
      }
      chat.messages = arr;
      chat.typing = false;  // Replace typing indicator with streaming text.
      break;
    }

    case root.ev.error:
      // Startup races: warmup module and plugin both kick list-models at
      // boot, and the daemon serializes them with a transient "already in
      // progress" error. Harmless — the in-flight call still delivers the
      // models event — so swallow it instead of toasting on every login.
      if (/already in progress/i.test(ev.text || "")) break;
      chat.lastError = ev.text;
      errorTimer.restart();
      ToastService.showError((chat.peerName || "opencrow-chat") + ": " + ev.text);
      break;

    case root.ev.models: {
      const incoming = Array.isArray(ev.models) ? ev.models : [];
      // A 'models' event with a single entry marked active is the response
      // to set-model — patch the existing list rather than replacing it.
      if (incoming.length === 1 && incoming[0].active && chat.models.length > 0) {
        const m = incoming[0];
        chat.activeModel = m.provider + "/" + m.id;
        chat.models = chat.models.map(x => Object.assign({}, x, {
          active: x.provider === m.provider && x.id === m.id,
        }));
      } else {
        // Full list response from list-models.
        chat.models = incoming.map(m => Object.assign({}, m));
        const active = incoming.find(m => m.active);
        if (active) chat.activeModel = active.provider + "/" + active.id;
      }
      break;
    }

    case root.ev.confirm: {
      // Render the confirmation as a regular message bubble with a
      // pending state. Bubble renders Allow/Deny buttons when type ==
      // "confirm" and confirmState == "pending"; chat.confirmRespond()
      // patches it once the user clicks.
      const id = ev.confirmId || "";
      if (!id) break;
      let arr = chat.messages.slice();
      if (arr.some(x => x.id === id)) break;
      arr.push({
        id: id,
        text: ev.confirmBody || "",
        ts: Date.now(),
        ack: "", image: "", replyTo: "",
        state: root.state.sent, tries: 0,
        from: "peer",
        type: "confirm",
        confirmTitle: ev.confirmTitle || "",
        confirmState: "pending",
      });
      chat.messages = arr;
      break;
    }
    }
  }

  property real _lastTap: 0
  IpcHandler {
    target: "plugin:opencrow-chat"

    function tap() {
      const now = Date.now();
      if (now - root._lastTap < 400) toggle();
      root._lastTap = now;
    }
    function toggle() {
      sockSend({ cmd: root.cmd.markRead });
      pluginApi?.withCurrentScreen(s => pluginApi.togglePanel(s));
    }
    function send(text: string) { chat.send(text); }

    // Close the panel before a screenshot bind fires. Slurp can't
    // select through a layer-shell overlay, and you don't want the
    // chat in the capture anyway. The actual grim/slurp runs from
    // the niri keybind — spawning it *from* noctalia stacks slurp's
    // surface below the shell's own layers, making the crosshair
    // invisible. Compositor-spawned processes get correct ordering.
    function hide() {
      pluginApi?.withCurrentScreen(s => pluginApi.closePanel(s));
    }

    // Receives the captured path from the keybind script. Asks the
    // daemon to unlink after caching — the source is a mktemp in
    // $XDG_RUNTIME_DIR we don't want to accumulate. The paperclip
    // button calls chat.sendFile directly without this flag.
    function sendFile(path: string) { chat.sendFile(path, true); }
  }

}

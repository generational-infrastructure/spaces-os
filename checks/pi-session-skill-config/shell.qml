// Minimal test shell that hosts PiSession + a skill-config daemon
// subscriber, then exposes the result through `qs ipc call test:skill …`.
//
// Replicates _just_ the subscriber/push/retract/submit logic from
// PiChatBackend.qml so the test catches wiring bugs in the daemon
// protocol without pulling in noctalia or /etc/distro/pi-chat.json.
import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  readonly property string sockPath: Quickshell.env("TEST_SKILL_SOCK")

  // A single session. The subscriber routes all prompts here.
  PiSession {
    id: session
    sessionId: "test"
    piBin: "/bin/false"
    stateDir: Quickshell.env("TEST_STATE_DIR")
    piAgentDir: Quickshell.env("TEST_AGENT_DIR")
    workspacePath: Quickshell.env("TEST_WORKSPACE")
    llmUrl: "http://127.0.0.1:1"
  }

  // ── skill-config subscriber (mirror of PiChatBackend) ──────────

  Loader {
    id: skillSock
    sourceComponent: skillSockComponent
    readonly property bool connected: item?.connected ?? false
  }
  Component {
    id: skillSockComponent
    Socket {
      path: root.sockPath
      connected: true
      parser: SplitParser { onRead: line => root._recv(line) }
      onConnectionStateChanged: {
        if (connected) {
          skillReconnect.stop();
          skillReconnect.interval = 500;
          write(JSON.stringify({ op: "subscribe" }) + "\n");
          flush();
        } else {
          skillReconnect.start();
        }
      }
      onError: (e) => {
        console.warn("skill-config subscribe error:", e);
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

  // One-shot socket for submit/cancel.
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
      onError: (e) => console.warn("skill-config one-shot error:", e)
      parser: SplitParser { onRead: () => {} }
    }
  }
  // PiSession.promptRespond/promptCancel call this to push the value
  // back to the daemon. Same shape as PiChatBackend.skillConfigSend.
  function skillConfigSend(payload) {
    const c = skillOneShotComponent.createObject(root, {
      path: root.sockPath,
      payload: payload,
    });
    Qt.callLater(() => c.destroy(2000));
  }

  // ── event handling (straight from PiChatBackend) ───────────────

  function _recv(raw) {
    let ev;
    try { ev = JSON.parse(raw); }
    catch (_e) { console.warn("bad skill-config json", raw); return; }
    switch (ev.op) {
    case "snapshot":
      _reconcileSnapshot(ev.requests || []);
      break;
    case "added":
      _pushPrompt(ev.request);
      break;
    case "removed":
      _retractPrompt(ev.request_id);
      break;
    default:
      console.warn("unknown skill-config op", ev.op);
    }
  }

  function _pushPrompt(req) {
    if (!req || !req.request_id) return;
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
      promptInstance: "",
      promptSkill: req.skill || "",
      promptProfile: req.profile || "",
      promptField: req.field || "",
      promptSecret: !!req.secret,
      promptState: "pending",
    };
    const arr = session.messages.slice();
    arr.push(entry);
    session.messages = arr;
  }

  function _retractPrompt(rid) {
    const msgs = session.messages || [];
    const i = msgs.findIndex(m => m.id === rid);
    if (i < 0) return;
    const m = msgs[i];
    if (m.type !== "prompt") return;
    if ((m.promptState ?? "pending") !== "pending") return;
    session.patch(rid, { promptState: "retracted" });
  }

  function _reconcileSnapshot(requests) {
    const live = {};
    for (const r of requests) live[r.request_id] = r;
    const arr = (session.messages || []).slice();
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
    if (changed) session.messages = arr;
    for (const r of requests) _pushPrompt(r);
  }

  // ── IPC surface ────────────────────────────────────────────────

  IpcHandler {
    target: "test:skill"

    function messages(): string {
      return JSON.stringify(session.messages || []);
    }
    function submit(requestId: string, value: string) {
      session.promptRespond(requestId, value);
    }
    function cancel(requestId: string) {
      session.promptCancel(requestId);
    }
  }
}

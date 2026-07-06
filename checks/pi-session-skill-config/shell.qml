// Minimal test shell that hosts PiSession + a skill-config daemon
// subscriber, then exposes the result through `qs ipc call test:skill …`.
//
// Replicates _just_ the subscriber/push/retract/submit logic from
// PiChatBackend.qml so the test catches wiring bugs in the daemon
// protocol without pulling in noctalia or /etc/spaces/pi-chat.json.
import QtQuick
import Quickshell
import Quickshell.Io
import "Msg.js" as Msg

Item {
  id: root

  readonly property string sockPath: Quickshell.env("TEST_SKILL_SOCK")

  // A single session. The subscriber routes all prompts here.
  PiSession {
    id: session
    sessionId: "test"
    // No executor configured — spawn() is a no-op; the test only needs
    // the prompt-bubble surface (messages/patch/promptRespond).
    workspacePath: Quickshell.env("TEST_WORKSPACE")
    backend: root
  }

  // ── skill-config subscriber (mirror of PiChatBackend) ──────────

  NdjsonSocket {
    id: skillSock
    path: root.sockPath
    mode: "subscribe"
    hello: ({ op: "subscribe" })
    onMessage: ev => root._recv(ev)
    onErrored: e => console.warn("skill-config subscribe error:", e)
    onBadLine: raw => console.warn("bad skill-config json", raw)
  }

  // PiSession.promptRespond/promptCancel call this to push the value
  // back to the daemon. Same shape as PiChatBackend.skillConfigSend.
  function skillConfigSend(payload) {
    skillSock.request(payload);
  }

  // ── event handling (mirrors PiChatBackend; records via Msg.js) ─

  function _recv(ev) {
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
    const arr = session.messages.slice();
    arr.push(Msg.prompt(id, req.description, Date.now(), {
      skill: req.skill,
      profile: req.profile,
      field: req.field,
      secret: req.secret,
    }));
    session.messages = arr;
  }

  function _retractPrompt(rid) {
    const msgs = session.messages || [];
    const i = msgs.findIndex(m => m.id === rid);
    if (i < 0) return;
    if (!Msg.isPendingPrompt(msgs[i])) return;
    session.patch(rid, { promptState: "retracted" });
  }

  function _reconcileSnapshot(requests) {
    const live = {};
    for (const r of requests) live[r.request_id] = r;
    const arr = (session.messages || []).slice();
    let changed = false;
    for (let i = 0; i < arr.length; i++) {
      if (!Msg.isPendingPrompt(arr[i])) continue;
      if (!live[arr[i].id]) {
        arr[i] = Object.assign({}, arr[i], { promptState: "retracted" });
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

// Headless host for the chat history's stick-to-bottom / scrollback
// behaviour (issue #28).
//
// The real Panel is embedded with a stub backend whose `chat.messages`
// the driver mutates over IPC to mimic the executor: `streamDelta`
// regrows the newest bubble one token at a time (exactly what
// PiSession._handleMessageUpdate does on a text delta — reassign the
// whole array with the last message's text extended), `appendMsg` adds
// a new bubble. The driver then drives the history ListView through its
// public Flickable surface (`flick`, `contentY`, `originY`, `atYEnd`)
// to assert the view neither yanks a scrolled-up reader to the bottom
// while the agent streams, nor stops following when they were pinned.
//
// FloatingWindow over PanelWindow because the offscreen Qt platform
// ships no layer-shell; the chat history sizing is identical either way.
import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
  id: shell

  // Bare session: only the surface Panel/Bubble read. messages is the
  // one the driver drives.
  property QtObject chatStub: QtObject {
    property var messages: []
    property string peerName: "Tester"
    property bool streaming: true
    property bool typing: false
    property var models: []
    property string activeModel: ""
    property bool memoryEnabled: true
    property var replyTarget: null
    property string lastError: ""
    property var executor: null
    function listModels() {}
    function send(_t) {}
    function sendFile(_p, _b) {}
    function retry(_i) {}
    function cancel(_i) {}
    function confirmRespond(_i, _c) {}
    function promptRespond(_i, _v) {}
    function promptCancel(_i) {}
    function setModel(_p, _i) {}
    function restart() {}
  }

  property QtObject backendStub: QtObject {
    property var chat: shell.chatStub
    property var sessionsList: [{
      id: "scroll-test",
      name: "Tester",
      section: "chats",
      unread: 0
    }]
    property string activeSessionId: "scroll-test"
    property var executors: []
    property var signalPendingSends: []
    property bool signalBridgeConnected: false
    property var _sessionObjs: ({})
    function selectSession(id) { activeSessionId = id; }
    function signalApprove(_t) {}
    function signalDeny(_t) {}
    function newSession() {}
  }

  property var win: FloatingWindow {
    id: w
    implicitWidth: 480
    implicitHeight: 600
    visible: true

    Panel {
      id: panel
      anchors.fill: parent
      backend: shell.backendStub
      selectedConversationId: "scroll-test"
    }
  }

  // Depth-first search for the history ListView by objectName.
  function _find(obj, name) {
    if (!obj) return null;
    if (obj.objectName === name) return obj;
    const kids = obj.children || [];
    for (let i = 0; i < kids.length; i++) {
      const r = _find(kids[i], name);
      if (r) return r;
    }
    return null;
  }

  property var hist: null
  function _hist() {
    if (!shell.hist) shell.hist = _find(panel, "chatHistory");
    return shell.hist;
  }

  property var ipc: IpcHandler {
    target: "scroll"

    // Seed N alternating-author bubbles, each long enough to wrap so the
    // list is several screens tall and genuinely scrollable.
    function populate(n: int): string {
      const a = [];
      const now = Date.now();
      for (let i = 0; i < n; i++)
        a.push({ id: "m" + i, from: (i % 2 === 0 ? "peer" : "me"),
                 text: "message " + i + " body with enough words to wrap across a couple of lines in the narrow chat panel",
                 ts: now - (n - i) * 1000, state: "sent" });
      shell.chatStub.messages = a;
      return "ok";
    }
    // One streaming token: extend the newest message and reassign the
    // array, exactly like the executor's text-delta path. The added
    // chunk is long enough to grow the bubble's height (which is what
    // triggers the relayout snap the fix has to absorb).
    function streamDelta(): string {
      const arr = shell.chatStub.messages.slice();
      const i = arr.length - 1;
      arr[i] = Object.assign({}, arr[i], { text: arr[i].text + " and some more streamed words" });
      shell.chatStub.messages = arr;
      return "ok";
    }
    function appendMsg(): string {
      const arr = shell.chatStub.messages.slice();
      arr.push({ id: "appended" + arr.length, from: "peer",
                 text: "a freshly appended assistant message body", ts: Date.now(), state: "sent" });
      shell.chatStub.messages = arr;
      return "ok";
    }

    // Public Flickable surface the driver asserts on.
    function flick(vy: real): string {
      const h = shell._hist(); if (!h) return "no-hist";
      h.flick(0, vy);
      return "ok";
    }
    function moving(): string { const h = shell._hist(); return h ? String(h.moving) : "no-hist"; }
    function atYEnd(): string { const h = shell._hist(); return h ? String(h.atYEnd) : "no-hist"; }
    function contentY(): string { const h = shell._hist(); return h ? String(h.contentY) : "no-hist"; }
    function originY(): string { const h = shell._hist(); return h ? String(h.originY) : "no-hist"; }
    function count(): string { const h = shell._hist(); return h ? String(h.count) : "no-hist"; }
  }
}

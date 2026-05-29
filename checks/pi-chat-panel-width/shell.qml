// Headless host for the Panel sizing + signal-banner regressions.
//
// (1) Surface width: shell.qml asks the layer-shell PanelWindow to be
// 480 px wide. QQuickWindow uses its contentItem's implicitWidth as the
// window's own implicit size, so any implicitWidth Panel.qml advertises
// is what the wayland surface actually requests. A 1000 px implicit on
// the chat surface overrides the shell's 480 and the panel renders
// wider than the screen, with the rightmost columns of the header row
// and every bubble clipped off the display edge.
//
// (2) Signal-send banner: the pending-Signal approval cards are owned
// by PiChatBackend (signalPendingSends/signalApprove/signalDeny), not by
// the active session. The banner must read them off `backend`, not off
// `chat` (= backend.chat, a session with no such property). If it binds
// to `chat` the cards never render and the user can never approve a send.
//
// We embed the real Panel exactly the way shell.qml does (anchors.fill
// inside a window that wants 480 px) and expose the surface/panel sizes
// plus the banner state over IPC so the driver can assert both.
//
// FloatingWindow is used over PanelWindow because the offscreen Qt
// platform doesn't ship a layer-shell, but both windows route their
// size requests through the same QQuickWindow contentItem machinery
// and so reproduce the same propagation bug.
import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
  id: shell

  // Width regression: real Panel with no backend in a 480 px window.
  property var widthWindow: FloatingWindow {
    id: win
    implicitWidth: 480
    implicitHeight: 600
    visible: true

    Panel {
      id: panel
      anchors.fill: parent
      backend: null
    }
  }

  // Signal-banner regression: a stub backend whose pending Signal sends
  // live on the backend (mirroring PiChatBackend), while `chat` is a
  // bare session with no signal properties. A correct Panel reads the
  // pending list off `backend`; the bug reads it off `chat` and the
  // banner stays hidden.
  property QtObject sessionStub: QtObject {
    property var messages: []
    property string peerName: "Tester"
    property bool streaming: false
    property bool typing: false
    property var models: []
    property string activeModel: ""
    property bool memoryEnabled: true
    property var replyTarget: null
    property string lastError: ""
    function listModels() {}
    function send(_t) {}
  }

  property QtObject backendStub: QtObject {
    property var chat: shell.sessionStub
    property var sessionsList: []
    property string activeSessionId: ""
    property var signalPendingSends: [{
      token: "TESTTOKEN",
      recipient: "670d537e-0000-0000-0000-000000000000",
      display_name: "Kenji",
      body: "hi",
      created_at: 1
    }]
    function signalApprove(_t) {}
    function signalDeny(_t) {}
    function newSession() {}
  }

  property var signalWindow: FloatingWindow {
    id: sigWin
    implicitWidth: 480
    implicitHeight: 600
    visible: true

    Panel {
      id: signalPanel
      anchors.fill: parent
      backend: shell.backendStub
    }
  }

  // Depth-first search for the banner Rectangle by objectName.
  function _find(obj, name) {
    if (!obj)
      return null;
    if (obj.objectName === name)
      return obj;
    const kids = obj.children || [];
    for (let i = 0; i < kids.length; i++) {
      const r = _find(kids[i], name);
      if (r)
        return r;
    }
    return null;
  }

  property var banner: null
  function _banner() {
    if (!shell.banner)
      shell.banner = _find(signalPanel, "signalConfirmBanner");
    return shell.banner;
  }

  property var sizeIpc: IpcHandler {
    target: "test:panel-width"

    function panelImplicitWidth(): string { return String(panel.implicitWidth); }
    function panelWidth(): string { return String(panel.width); }
    function winWidth(): string { return String(win.width); }
    function winImplicitWidth(): string { return String(win.implicitWidth); }
  }

  property var signalIpc: IpcHandler {
    target: "test:signal-banner"

    function bannerVisible(): string {
      const b = shell._banner();
      return b ? String(b.visible) : "no-banner";
    }
    function bannerCount(): string {
      const b = shell._banner();
      return b ? String(b.items.length) : "no-banner";
    }
  }
}

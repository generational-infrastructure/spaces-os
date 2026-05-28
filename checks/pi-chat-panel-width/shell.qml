// Headless host for the Panel sizing regression.
//
// shell.qml asks the layer-shell PanelWindow to be 480 px wide.
// QQuickWindow uses its contentItem's implicitWidth as the window's
// own implicit size, so any implicitWidth Panel.qml advertises is
// what the wayland surface actually requests. A 1000 px implicit on
// the chat surface overrides the shell's 480 and the panel renders
// wider than the screen, with the rightmost columns of the header
// row and every bubble clipped off the display edge.
//
// We embed the real Panel exactly the way shell.qml does (anchors.fill
// inside a window that wants 480 px) and expose the surface and panel
// sizes over IPC so the driver can assert the Panel doesn't try to be
// bigger than the window it lives in.
//
// FloatingWindow is used over PanelWindow because the offscreen Qt
// platform doesn't ship a layer-shell, but both windows route their
// size requests through the same QQuickWindow contentItem machinery
// and so reproduce the same propagation bug.
import QtQuick
import Quickshell
import Quickshell.Io

FloatingWindow {
  id: win
  implicitWidth: 480
  implicitHeight: 600
  visible: true

  Panel {
    id: panel
    anchors.fill: parent
    backend: null
  }

  IpcHandler {
    target: "test:panel-width"

    function panelImplicitWidth(): string { return String(panel.implicitWidth); }
    function panelWidth(): string { return String(panel.width); }
    function winWidth(): string { return String(win.width); }
    function winImplicitWidth(): string { return String(win.implicitWidth); }
  }
}

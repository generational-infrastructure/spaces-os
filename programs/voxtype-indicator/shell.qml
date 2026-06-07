// voxtype-indicator standalone shell.
//
// A small round dot in the top-right corner that turns red whenever
// voxtype is capturing audio (recording OR streaming) and amber while it
// decodes (transcribing). Hidden when idle or when the daemon is down.
// This replaces the transient "voice recording started/stopped" toasts.
//
// Data source: `voxtype status --follow` prints one state word per line
// over inotify on the daemon's state file (state_file = "auto" is set by
// the spaces voxtype module). States: idle | recording | streaming |
// transcribing | stopped (see voxtype src/status_json.rs). With the
// parakeet streaming engine the live-capture state is `streaming`, not
// `recording`, so both must count as "mic live".
//
// Layer-shell Overlay surface, no keyboard focus, no exclusive zone — it
// floats above everything (incl. the noctalia bar) and never steals
// input or pushes content aside. Standalone on purpose: noctalia runs
// vanilla ("no plugin"), so this is its own tiny quickshell config.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

PanelWindow {
  id: ind

  // Latest daemon state; updated line-by-line from the follow process.
  property string state: "idle"
  readonly property bool capturing: ind.state === "recording" || ind.state === "streaming"
  readonly property bool busy: ind.capturing || ind.state === "transcribing"

  readonly property int dotSize: 12
  readonly property int edgeMargin: 8

  anchors {
    top: true
    right: true
  }
  // Window spans the dot plus its inset; the dot itself is anchored
  // inside (PanelWindow's own `margins` group isn't qmllint-resolvable,
  // so we inset the painted child instead — same idiom as QuickBar.qml).
  implicitWidth: ind.dotSize + ind.edgeMargin
  implicitHeight: ind.dotSize + ind.edgeMargin
  exclusiveZone: 0
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  color: "transparent"

  // Only on screen while voxtype is doing something.
  visible: ind.busy

  Rectangle {
    width: ind.dotSize
    height: ind.dotSize
    radius: width / 2
    anchors {
      top: parent.top
      right: parent.right
      topMargin: ind.edgeMargin
      rightMargin: ind.edgeMargin
    }
    color: ind.capturing ? "#e01b24" // red:   mic live (recording/streaming)
         : ind.state === "transcribing" ? "#e5a50a" // amber: decoding
         : "transparent"
  }

  // Follow the daemon state. The process is long-lived; if it ever exits
  // (daemon never started, state_file unset) fall back to hidden and
  // respawn after a short delay so the dot recovers on its own.
  Process {
    id: follow
    running: true
    command: ["voxtype", "status", "--follow"]
    stdout: SplitParser {
      onRead: line => ind.state = line.trim()
    }
    onExited: (code, status) => {
      ind.state = "stopped";
      respawn.start();
    }
  }

  Timer {
    id: respawn
    interval: 2000
    repeat: false
    onTriggered: follow.running = true
  }
}

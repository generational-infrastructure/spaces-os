// Spaces Voice Indicator — plugin "service" instance.
//
// Watches voxtype's state file ($XDG_RUNTIME_DIR/voxtype/state). voxtype
// rewrites it (truncate-in-place) on EVERY transition, including the
// autonomous recording→transcribing→idle steps, so a single FileView
// tracks the whole lifecycle with no polling. File removed = daemon down.
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  // Injected by the plugin host (PluginService.createObject).
  property var pluginApi: null

  // The voxtype lifecycle word, or "down" when the daemon isn't running.
  // (Named voiceState, not state, to avoid shadowing Item.state.)
  property string voiceState: "down"

  // $XDG_RUNTIME_DIR is always set under a systemd user service and equals
  // /run/user/$UID. uidProbe is a defensive fallback for degenerate launches
  // without it; under the bar service it never fires.
  property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""

  Process {
    id: uidProbe
    running: root.runtimeDir.length === 0
    command: ["id", "-u"]
    stdout: StdioCollector {
      onStreamFinished: {
        const uid = text.trim();
        if (uid.length > 0) {
          root.runtimeDir = "/run/user/" + uid;
          stateView.reload();
        }
      }
    }
  }

  readonly property string statePath: root.runtimeDir.length > 0
    ? root.runtimeDir + "/voxtype/state"
    : ""

  readonly property var _known: ["idle", "recording", "transcribing", "streaming"]

  function _apply(raw) {
    const w = String(raw).trim();
    // Unknown/empty (partial read or a future state word): keep previous.
    if (w.length > 0 && root._known.indexOf(w) !== -1)
      root.voiceState = w;
  }

  FileView {
    id: stateView
    path: root.statePath
    watchChanges: true
    printErrors: false
    onLoaded: root._apply(text())
    onFileChanged: reload()
    onLoadFailed: root.voiceState = "down"   // daemon down / file removed
  }

  // FileView 0.3.0 only arms the watcher on construction; prime the read.
  Component.onCompleted: stateView.reload()
}

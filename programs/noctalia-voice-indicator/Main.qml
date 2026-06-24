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

  // ── Whole-bar ambient "recording" pulse ──────────────────────────
  // A SECOND cue alongside the per-widget mic recolor: while voxtype is
  // capturing, the bar grows a breathing red edge-glow (BarPulse.qml).
  // Both cues read the same voiceState, so there is no second watcher.
  readonly property var cfg: pluginApi ? pluginApi.pluginSettings : ({})

  // Default ON; an explicit barPulse:false opts out (motion sensitivity).
  readonly property bool barPulseEnabled: !(cfg && cfg.barPulse === false)

  // Peak glow alpha at the bar edge (ambient; 0..1), with a tasteful
  // fallback when unset or out of range.
  readonly property real pulseIntensity: {
    const v = cfg ? cfg.barPulseIntensity : undefined;
    return (typeof v === "number" && v > 0 && v <= 1) ? v : 0.55;
  }

  // recording / streaming are live capture; transcribing / idle / down
  // are not. Mirrors BarWidget.qml's isRecording so the two cues agree.
  readonly property bool isRecording: voiceState === "recording" || voiceState === "streaming"
  readonly property bool pulseActive: barPulseEnabled && isRecording

  // The overlay is its own layer-shell surface (BarPulse.qml). It is only
  // reachable when the plugin host is present (pluginApi set); staying
  // inert without it keeps this service standalone-loadable, since
  // BarPulse pulls in noctalia's qs.Commons / layer-shell. Loaded once
  // when enabled; it maps a surface only while pulseActive.
  LazyLoader {
    id: barPulseLoader
    active: root.pluginApi !== null && root.barPulseEnabled
    source: Qt.resolvedUrl("BarPulse.qml")
  }

  Binding {
    target: barPulseLoader.item
    property: "service"
    value: root
    when: barPulseLoader.item !== null
  }
}

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

  // Transient "recording quality impeded" marker. "" normally; set to
  // "no_speech" when a recording ends without ever transcribing. With
  // energy VAD enabled (modules/nixos/voxtype.nix) voxtype rejects a
  // silence-only / too-quiet take *before* transcription and steps
  // recording→idle directly — it never writes "transcribing" and posts no
  // notification (verified in voxtype src/daemon.rs start_transcription_task:
  // the no-speech branch only plays the Cancelled sound, then resets to
  // idle). A real take always passes recording→transcribing→idle, so a
  // recording that returns to idle WITHOUT transcribing in between is the
  // observable signal for a VAD-rejected (or too-short) recording. The bar
  // widget recolours the idle mic and swaps the tooltip while this is set.
  property string qualityWarning: ""

  // Previous lifecycle word, tracked so onVoiceStateChanged can classify a
  // transition (the change handler doesn't get the old value).
  property string _prevVoiceState: "down"

  // How long the rejection warning stays up before auto-clearing (ms).
  // Tunable via the plugin's noSpeechWarningMs setting; 4s default when the
  // host injects no settings (e.g. the headless component test stubs it).
  readonly property int qualityWarningMs: {
    const s = root.pluginApi && root.pluginApi.pluginSettings ? root.pluginApi.pluginSettings : null;
    const v = s ? s.noSpeechWarningMs : undefined;
    return (typeof v === "number" && v > 0) ? Math.round(v) : 4000;
  }

  // Classify each lifecycle transition for the quality-warning inference.
  // A new take (recording/transcribing/streaming) clears any lingering
  // warning; a recording that falls back to idle WITHOUT having passed
  // through transcribing is a VAD rejection. Crucially this keys off the
  // *previous* word: a daemon that dies mid-recording goes recording→down
  // (not →idle), and a normal take reaches idle from transcribing, so
  // neither trips the warning.
  function _onTransition() {
    const prev = root._prevVoiceState;
    const cur = root.voiceState;
    if (prev === cur)
      return;
    if (cur === "recording" || cur === "transcribing" || cur === "streaming") {
      root.qualityWarning = "";
      qualityWarningTimer.stop();
    } else if (cur === "idle" && prev === "recording") {
      root.qualityWarning = "no_speech";
      qualityWarningTimer.restart();
    }
    root._prevVoiceState = cur;
  }

  onVoiceStateChanged: root._onTransition()

  Timer {
    id: qualityWarningTimer
    interval: root.qualityWarningMs
    repeat: false
    onTriggered: root.qualityWarning = ""
  }

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

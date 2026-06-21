// Spaces Voice Indicator — bar widget.
//
// voiceState → glyph → colour → motion (see the table in the design doc):
//   recording / streaming → red mic (mError) + opacity pulse
//   transcribing          → amber loader-2 (mPrimary) + rotation spin
//   idle                  → dim mic (mOnSurfaceVariant), no motion
//   no-speech warning     → caution mic (mTertiary), no motion
//   down (or hideWhenIdle+idle) → collapsed/hidden
// The warning sits on the (idle) mic for a few seconds after voxtype's
// energy VAD rejects a silent take (see Main.qml qualityWarning). mTertiary
// is the one accent guaranteed distinct from both the recording red
// (mError) and transcribing amber (mPrimary), and it never decides hover
// contrast: on hover the glyph is always mOnHover on the mHover fill.
// Hover swaps the glyph to mOnHover on an mHover fill (contrast). Click
// runs the voice-record-toggle wrapper.
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.Commons
import qs.Services.UI
import qs.Widgets

Item {
  id: root

  // Set by the plugin host / BarWidgetLoader.
  property var pluginApi: null
  property ShellScreen screen
  property string widgetId: ""
  property string section: ""
  // Declared so the bar's loader can assign them; unused per-instance.
  property int sectionWidgetIndex: -1
  property int sectionWidgetsCount: 0

  readonly property var svc: pluginApi ? pluginApi.mainInstance : null
  readonly property string voiceState: svc ? svc.voiceState : "down"
  readonly property string qualityWarning: svc ? svc.qualityWarning : ""
  readonly property var cfg: pluginApi ? pluginApi.pluginSettings : ({})
  readonly property bool hideWhenIdle: cfg ? cfg.hideWhenIdle === true : false

  readonly property bool isRecording: voiceState === "recording" || voiceState === "streaming"
  readonly property bool isTranscribing: voiceState === "transcribing"
  readonly property bool isIdle: voiceState === "idle"
  readonly property bool isDown: voiceState === "down" || voiceState.length === 0
  // A VAD-rejected take leaves a transient warning on the idle glyph.
  readonly property bool isWarning: qualityWarning.length > 0

  // Hidden when the daemon is down, and (optionally) when idle — but a
  // pending quality warning forces the (idle) glyph visible so the caution
  // recolour is actually seen even with hideWhenIdle set.
  readonly property bool shown: !isDown && (!(isIdle && hideWhenIdle) || isWarning)

  readonly property string screenName: screen ? screen.name : ""
  readonly property real capsuleHeight: Style.getCapsuleHeightForScreen(screenName)
  readonly property int itemSize: Style.toOdd(capsuleHeight)
  readonly property real iconPointSize: Style.fontSizeM

  readonly property string glyph: isTranscribing ? "loader-2" : "microphone"
  // Warning wins over the idle colour (it only ever fires at idle, but
  // ordering it first keeps the intent obvious). mTertiary is the caution
  // tone — distinct from recording red and transcribing amber.
  readonly property color stateColor: isWarning
    ? Color.mTertiary
    : (isRecording ? Color.mError : (isTranscribing ? Color.mPrimary : Color.mOnSurfaceVariant))
  readonly property string tooltipKey: isWarning
    ? "voice.tooltip-no-speech"
    : (isRecording ? "voice.tooltip-recording" : (isTranscribing ? "voice.tooltip-transcribing" : "voice.tooltip-idle"))

  implicitWidth: shown ? itemSize : 0
  implicitHeight: capsuleHeight
  visible: shown

  // The warning appears asynchronously (voxtype rejects the take, not the
  // user), so refresh an already-open tooltip when the state word it shows
  // changes — otherwise a user hovering across the rejection keeps reading
  // the stale "idle" text.
  onTooltipKeyChanged: {
    if (itemMouse.containsMouse && root.pluginApi)
      TooltipService.show(root, root.pluginApi.tr(root.tooltipKey), "bottom");
  }

  // Toggle recording via the spaces wrapper (which posts the start/stop
  // toast and calls voxtype). The home-manager module pins toggleCommand to
  // the absolute spaces-voice-record-toggle.
  function toggle() {
    const cmd = (cfg && cfg.toggleCommand && String(cfg.toggleCommand).trim())
      || "spaces-voice-record-toggle";
    Quickshell.execDetached(["sh", "-c", cmd]);
  }

  Rectangle {
    id: bg
    anchors.fill: parent
    radius: width / 2
    color: itemMouse.containsMouse ? Color.mHover : "transparent"

    NIcon {
      id: glyphIcon
      anchors.centerIn: parent
      icon: root.glyph
      pointSize: root.iconPointSize
      // Foreground MUST contrast its background: mOnHover on the hover
      // fill, otherwise the state colour on the transparent rest fill.
      color: itemMouse.containsMouse ? Color.mOnHover : root.stateColor

      // Recording: pulse opacity so "live" reads even without colour
      // (accessibility). An "on opacity" value source FREEZES opacity at its
      // last value when it stops — it does not revert — so snap back to
      // fully opaque on stop, otherwise the glyph is left dimmed after
      // recording ends.
      SequentialAnimation on opacity {
        running: root.isRecording && !itemMouse.containsMouse
        loops: Animation.Infinite
        alwaysRunToEnd: true
        onStopped: glyphIcon.opacity = 1.0
        NumberAnimation { to: 0.4; duration: 700; easing.type: Easing.InOutSine }
        NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutSine }
      }

      // Transcribing: spin the loader glyph. Mutually exclusive with the
      // pulse (different states), so the two value sources never fight. An
      // "on rotation" value source FREEZES rotation at its last angle when
      // it stops — it does not revert — so reset to 0 on stop, otherwise the
      // microphone glyph (shown again once transcribing ends) inherits the
      // leftover angle and can render upside-down.
      RotationAnimation on rotation {
        running: root.isTranscribing
        loops: Animation.Infinite
        from: 0
        to: 360
        duration: 1000
        onStopped: glyphIcon.rotation = 0
      }
    }
  }

  MouseArea {
    id: itemMouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.toggle()
    onContainsMouseChanged: {
      if (containsMouse && root.pluginApi)
        TooltipService.show(root, root.pluginApi.tr(root.tooltipKey), "bottom");
      else
        TooltipService.hide(root);
    }
  }
}

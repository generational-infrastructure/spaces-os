// Spaces Voice Indicator — bar widget.
//
// voiceState → glyph → colour → motion (see the table in the design doc):
//   recording / streaming → red mic (mError) + opacity pulse
//   transcribing          → amber loader-2 (mPrimary) + rotation spin
//   idle                  → dim mic (mOnSurfaceVariant), no motion
//   down (or hideWhenIdle+idle) → collapsed/hidden
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
  readonly property var cfg: pluginApi ? pluginApi.pluginSettings : ({})
  readonly property bool hideWhenIdle: cfg ? cfg.hideWhenIdle === true : false

  readonly property bool isRecording: voiceState === "recording" || voiceState === "streaming"
  readonly property bool isTranscribing: voiceState === "transcribing"
  readonly property bool isIdle: voiceState === "idle"
  readonly property bool isDown: voiceState === "down" || voiceState.length === 0

  // Hidden when the daemon is down, and (optionally) when idle.
  readonly property bool shown: !isDown && !(isIdle && hideWhenIdle)

  readonly property string screenName: screen ? screen.name : ""
  readonly property real capsuleHeight: Style.getCapsuleHeightForScreen(screenName)
  readonly property int itemSize: Style.toOdd(capsuleHeight)
  readonly property real iconPointSize: Style.fontSizeM

  readonly property string glyph: isTranscribing ? "loader-2" : "microphone"
  readonly property color stateColor: isRecording
    ? Color.mError
    : (isTranscribing ? Color.mPrimary : Color.mOnSurfaceVariant)
  readonly property string tooltipKey: isRecording
    ? "voice.tooltip-recording"
    : (isTranscribing ? "voice.tooltip-transcribing" : "voice.tooltip-idle")

  implicitWidth: shown ? itemSize : 0
  implicitHeight: capsuleHeight
  visible: shown

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

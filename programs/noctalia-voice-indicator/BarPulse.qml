// Spaces Voice Indicator — whole-bar "recording" pulse overlay.
//
// A SECOND, ambient "you are being recorded" cue that complements the
// per-widget mic recolor in BarWidget.qml: while voxtype is capturing, a
// red glow breathes along the bar's inner edge across its full width,
// WITHOUT recoloring any bar widget.
//
// Why a separate layer-shell surface and not the bar background itself:
// noctalia draws the bar background (Color.mSurface, ~0.93 opaque) and
// the bar widgets as two SEPARATE PanelWindows on the SAME WlrLayer.Top,
// in one client. A plugin's surface is created after both of them, so it
// can only stack ABOVE the widgets (which would tint them) or BELOW the
// near-opaque background (which would hide it) — there is no layer in
// between, and the plugin API exposes no bar-background colour hook. So
// the cue is its own click-through layer-shell strip flush against the
// bar's inner edge, where it can never sit on top of a widget.
//
// One surface per screen (Variants), tracking each screen's bar edge and
// size via the same Settings/Style singletons noctalia's bar windows use.
// Driven entirely by the service's voiceState through the `service`
// property bound by Main.qml — no second state watcher. The breathing
// animation only runs while recording and resets to nothing when it
// stops, and the surface is unmapped when idle, so an idle bar costs
// nothing.
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons

Variants {
  id: pulse

  // The plugin's Main.qml service, assigned by its LazyLoader. Carries
  // the voiceState-derived pulse state, so this overlay never re-watches
  // the state file.
  property var service: null
  readonly property bool pulseActive: pulse.service ? pulse.service.pulseActive === true : false
  // Peak glow alpha at the bar edge (ambient; 0..1), with a tasteful
  // fallback when the service hasn't supplied one.
  readonly property real intensity: {
    const v = pulse.service ? pulse.service.pulseIntensity : 0;
    return (v > 0 && v <= 1) ? v : 0.55;
  }

  // One glow surface per screen, mirroring noctalia's own bar windows.
  model: Quickshell.screens

  delegate: PanelWindow {
    id: glow
    required property ShellScreen modelData

    screen: modelData
    color: "transparent"
    // Map a surface only while recording: idle leaves no overlay surface
    // at all — no paint, no input, no cost.
    visible: pulse.pulseActive

    WlrLayershell.namespace: "spaces-voice-bar-pulse-" + (glow.screen ? glow.screen.name : "unknown")
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.exclusionMode: ExclusionMode.Ignore
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // Bar geometry, read from the same singletons noctalia's bar windows
    // read, so the glow tracks the bar edge and size on every screen.
    readonly property string barPosition: Settings.getBarPositionForScreen(glow.screen ? glow.screen.name : "")
    readonly property bool barTop: barPosition !== "bottom"
    readonly property bool barFloating: Settings.data.bar.barType === "floating"
    readonly property real barMarginV: Math.ceil(barFloating ? Settings.data.bar.marginVertical : 0)
    readonly property real barHeight: Style.getBarHeightForScreen(glow.screen ? glow.screen.name : "")
    // Distance from the screen edge to the bar's inner edge.
    readonly property real barOffset: barMarginV + barHeight
    // How far the glow blooms inward from that inner edge.
    readonly property real glowDepth: Math.max(6, Math.round(barHeight * 0.6))

    // Span the bar edge plus the bloom; the empty mask makes the whole
    // surface click-through, and we only paint past the bar (see bloom.y),
    // so the widgets are never covered or tinted.
    anchors {
      top: glow.barTop
      bottom: !glow.barTop
      left: true
      right: true
    }
    implicitHeight: glow.barOffset + glow.glowDepth
    mask: Region {}

    // The breathing glow: a red gradient strongest at the bar's inner
    // edge, fading to nothing as it blooms inward. Positioned past the
    // bar (y) so it never overlaps the widgets.
    Rectangle {
      id: bloom
      anchors.left: parent.left
      anchors.right: parent.right
      height: glow.glowDepth
      y: glow.barTop ? glow.barOffset : 0

      opacity: 0.0
      gradient: Gradient {
        orientation: Gradient.Vertical
        GradientStop {
          position: 0.0
          color: Qt.rgba(Color.mError.r, Color.mError.g, Color.mError.b, glow.barTop ? pulse.intensity : 0)
        }
        GradientStop {
          position: 1.0
          color: Qt.rgba(Color.mError.r, Color.mError.g, Color.mError.b, glow.barTop ? 0 : pulse.intensity)
        }
      }

      // Slow, ease-in-out breathing (~1.4s/cycle) — never strobing, for
      // accessibility — matching the per-widget mic pulse cadence. The
      // animation STOPS when recording ends and snaps opacity back to 0,
      // so nothing is left painted (an "on opacity" value source would
      // otherwise freeze at its last value).
      SequentialAnimation on opacity {
        running: pulse.pulseActive
        loops: Animation.Infinite
        onStopped: bloom.opacity = 0.0
        NumberAnimation {
          to: 1.0
          duration: 700
          easing.type: Easing.InOutSine
        }
        NumberAnimation {
          to: 0.4
          duration: 700
          easing.type: Easing.InOutSine
        }
      }
    }
  }
}

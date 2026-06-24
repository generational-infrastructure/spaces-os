// Spaces Voice Indicator — whole-bar "recording" pulse overlay.
//
// A SECOND, ambient "you are being recorded" cue that complements the
// per-widget mic recolor in BarWidget.qml: while voxtype is capturing, a
// red glow breathes along the bar's inner edge, WITHOUT recoloring any bar
// widget.
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
// One surface per screen (Variants). Each screen's surface mirrors that
// screen's bar via BarPulseGeometry, which reads the same Settings/Style
// singletons noctalia's bar windows use: it tracks all four bar positions
// (top/bottom/left/right, so the glow is a horizontal strip for horizontal
// bars and a vertical strip for vertical ones, blooming inward from the
// bar's inner edge), honours per-monitor visibility (no glow on a screen
// where the bar is hidden), and matches floating/framed insets (the glow
// lines up with the bar's real ends rather than spanning the whole edge).
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

    // Bar geometry for this screen, read from the same singletons
    // noctalia's bar windows read.
    BarPulseGeometry {
      id: geo
      screenName: glow.screen ? glow.screen.name : ""
      screenWidth: glow.screen ? glow.screen.width : 0
      screenHeight: glow.screen ? glow.screen.height : 0
    }

    // Map a surface only while recording AND only on screens that show the
    // bar: idle, or a bar-less monitor, leaves no overlay surface at all —
    // no paint, no input, no cost.
    visible: pulse.pulseActive && geo.barShown

    WlrLayershell.namespace: "spaces-voice-bar-pulse-" + (glow.screen ? glow.screen.name : "unknown")
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.exclusionMode: ExclusionMode.Ignore
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // Pin the surface to the bar's edge and ends exactly like noctalia's
    // bar window does, then let it grow inward by glowDepth (via the
    // implicit size) so the bloom can extend past the bar's inner edge.
    anchors {
      top: geo.surfTop
      bottom: geo.surfBottom
      left: geo.surfLeft
      right: geo.surfRight
    }
    margins {
      top: geo.surfMTop
      bottom: geo.surfMBottom
      left: geo.surfMLeft
      right: geo.surfMRight
    }
    implicitWidth: geo.surfImplicitWidth
    implicitHeight: geo.surfImplicitHeight

    // The empty mask makes the whole surface click-through, and the bloom
    // is offset past the bar (see bloom.x/y) so the widgets are never
    // covered or tinted.
    mask: Region {}

    // The breathing glow: a red gradient strongest at the bar's inner edge,
    // fading to nothing as it blooms inward. Positioned past the bar so it
    // never overlaps the widgets, and fills the bar's length.
    Rectangle {
      id: bloom
      x: geo.bloomLocalX
      y: geo.bloomLocalY
      width: geo.bloomLocalW
      height: geo.bloomLocalH

      opacity: 0.0
      gradient: Gradient {
        orientation: geo.gradientVertical ? Gradient.Vertical : Gradient.Horizontal
        GradientStop {
          position: 0.0
          color: Qt.rgba(Color.mError.r, Color.mError.g, Color.mError.b, geo.innerAtStart ? pulse.intensity : 0)
        }
        GradientStop {
          position: 1.0
          color: Qt.rgba(Color.mError.r, Color.mError.g, Color.mError.b, geo.innerAtStart ? 0 : pulse.intensity)
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

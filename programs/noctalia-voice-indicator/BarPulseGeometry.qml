// Spaces Voice Indicator — bar-pulse glow geometry, factored out of the
// PanelWindow so it can be exercised headless (no Wayland / layer-shell).
//
// Given a screen's name and pixel size, this computes where the recording
// glow surface sits and where the red bloom inside it paints, reading the
// SAME Settings/Style singletons noctalia's bar windows read so the glow
// tracks the real bar across all four positions, per-monitor visibility,
// and floating/framed insets. BarPulse.qml binds its PanelWindow
// anchors/margins/size and the bloom rectangle straight to these.
//
// Geometry mirrors noctalia's Modules/MainScreen/BarContentWindow.qml (the
// actual bar surface): same anchors, same per-barType margins. The only
// addition is that the surface is grown by glowDepth on the bar's inner
// axis so the bloom can extend past the bar's inner edge, and the bloom is
// offset by the bar thickness so it never paints over a widget.
pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons

QtObject {
  id: geo

  // Screen this glow belongs to (set by BarPulse's per-screen delegate).
  property string screenName: ""
  property real screenWidth: 0
  property real screenHeight: 0

  // ── Bar configuration (per-screen, override-aware) ──────────────────
  // getBarPositionForScreen / getBarHeightForScreen already fold in any
  // enabled per-screen override, so position and thickness follow the
  // real bar even when this monitor customises them.
  readonly property string barPosition: Settings.getBarPositionForScreen(geo.screenName)
  readonly property bool barIsVertical: barPosition === "left" || barPosition === "right"
  readonly property string barType: Settings.data.bar.barType
  readonly property bool barFramed: barType === "framed"
  readonly property bool barFloating: barType === "floating"
  readonly property real frameThickness: Settings.data.bar.frameThickness ?? 12
  // Floating margins inset the bar from the screen edges; simple/framed
  // bars carry none (framed insets via frameThickness instead). Ceil to
  // match BarContentWindow so the glow lands on the same pixel grid.
  readonly property real marginH: Math.ceil(barFloating ? Settings.data.bar.marginHorizontal : 0)
  readonly property real marginV: Math.ceil(barFloating ? Settings.data.bar.marginVertical : 0)
  readonly property real barThickness: Style.getBarHeightForScreen(geo.screenName)
  // How far the glow blooms inward from the bar's inner edge.
  readonly property real glowDepth: Math.max(6, Math.round(barThickness * 0.6))

  // Whether the bar — and therefore the glow — shows on this screen.
  // Mirrors Bar.qml exactly: an empty monitors list means every screen,
  // otherwise only the named ones. (A per-screen override's enabled:false
  // disables its customisations, not the bar itself, so it is not a
  // visibility gate here.)
  readonly property bool barShown: {
    var monitors = Settings.data.bar.monitors || [];
    if (!monitors || monitors.length === 0)
      return true;
    return monitors.indexOf(geo.screenName) !== -1;
  }

  // ── Gradient orientation / direction ────────────────────────────────
  // The bloom fades from the bar's inner edge inward, so it runs along the
  // axis perpendicular to the bar. innerAtStart marks whether the bar's
  // inner edge is at gradient position 0 (top/left bars) or 1 (bottom/right).
  readonly property bool gradientVertical: !barIsVertical
  readonly property bool innerAtStart: barPosition === "top" || barPosition === "left"

  // Inset along the bar's LONG axis (its length): floating uses the
  // matching margin, framed uses frameThickness, simple none.
  readonly property real longInset: barFramed ? frameThickness : (barIsVertical ? marginV : marginH)

  // ── PanelWindow surface (consumed verbatim by BarPulse.qml) ─────────
  // Anchors mirror BarContentWindow: pin both ends of the long axis and
  // the bar's own edge; the inner edge is left free so the surface can
  // grow inward by glowDepth.
  readonly property bool surfTop: barPosition === "top" || barIsVertical
  readonly property bool surfBottom: barPosition === "bottom" || barIsVertical
  readonly property bool surfLeft: barPosition === "left" || !barIsVertical
  readonly property bool surfRight: barPosition === "right" || !barIsVertical

  // Layer-shell margins, identical to BarContentWindow's: the bar-edge
  // side uses the floating margin (0 for simple/framed), the other sides
  // use frameThickness when framed, else the floating margin.
  readonly property real surfMTop: (barPosition === "top") ? marginV : (barFramed ? frameThickness : marginV)
  readonly property real surfMBottom: (barPosition === "bottom") ? marginV : (barFramed ? frameThickness : marginV)
  readonly property real surfMLeft: (barPosition === "left") ? marginH : (barFramed ? frameThickness : marginH)
  readonly property real surfMRight: (barPosition === "right") ? marginH : (barFramed ? frameThickness : marginH)

  // Bar thickness plus the inward bloom; the long axis is sized by anchors.
  readonly property real surfImplicitWidth: barIsVertical ? (barThickness + glowDepth) : geo.screenWidth
  readonly property real surfImplicitHeight: barIsVertical ? geo.screenHeight : (barThickness + glowDepth)

  // Effective on-screen surface extent (anchors collapse the implicit
  // value on a pinned-both-ends axis to span between the margins).
  readonly property real _surfW: barIsVertical ? (barThickness + glowDepth) : (geo.screenWidth - surfMLeft - surfMRight)
  readonly property real _surfH: barIsVertical ? (geo.screenHeight - surfMTop - surfMBottom) : (barThickness + glowDepth)
  readonly property real _surfX: surfLeft ? surfMLeft : (geo.screenWidth - surfMRight - _surfW)
  readonly property real _surfY: surfTop ? surfMTop : (geo.screenHeight - surfMBottom - _surfH)

  // ── Bloom rectangle, in surface-local coordinates ───────────────────
  // Offset past the bar thickness on the inner axis; fills the long axis.
  readonly property real bloomLocalX: barIsVertical ? (barPosition === "left" ? barThickness : 0) : 0
  readonly property real bloomLocalY: barIsVertical ? 0 : (barPosition === "top" ? barThickness : 0)
  readonly property real bloomLocalW: barIsVertical ? glowDepth : _surfW
  readonly property real bloomLocalH: barIsVertical ? _surfH : glowDepth

  // ── Bloom rectangle, in absolute screen coordinates (for tests) ─────
  readonly property real bloomX: _surfX + bloomLocalX
  readonly property real bloomY: _surfY + bloomLocalY
  readonly property real bloomW: bloomLocalW
  readonly property real bloomH: bloomLocalH
}

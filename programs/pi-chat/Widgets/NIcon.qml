// Icon renderer.
//
// noctalia uses an icon font (tabler-icons.ttf) and renders the
// codepoint through a Text. We use SVG files vendored under
// `<shellDir>/icons/<name>.svg` instead — same Tabler set, no font
// loader, no codepoint map, addable by drop-in.
//
// API surface matches noctalia's NIcon enough that call sites port
// unchanged: `icon` (name without .svg), `pointSize` (treated as
// visual size in px), `color` (recolours the stroke).
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

Item {
  id: root

  property string icon: ""
  property real pointSize: Style.fontSizeL
  property color color: Color.mOnSurface
  // Whether to honour a notional uiScale; kept for noctalia API parity,
  // currently ignored (Settings does not expose a scale knob in v1).
  property bool applyUiScale: true

  // Approximate "the visual icon should look like text at this point
  // size". 16-point SVG at our default font is ~16 px square; the
  // ratio approximates noctalia's font-driven sizing.
  readonly property real renderSize: Math.round(pointSize * 1.3)

  implicitWidth: renderSize
  implicitHeight: renderSize
  visible: icon !== ""

  // Raw SVG markup for the current icon, refreshed on `icon` change.
  property string _svg: ""

  // "#rrggbb" for the SVG stroke. Tabler icons stroke with
  // `currentColor`; QML has no way to feed an SVG a current colour, so
  // we substitute it in the markup below.
  function _hex(c) {
    return "#" + [c.r, c.g, c.b].map(v => Math.round(v * 255).toString(16).padStart(2, "0")).join("");
  }

  // The recoloured SVG the icon paints, as a data URI. Exposed (readonly)
  // so the live colour bake is observable to tests and debugging.
  //
  // We recolour by baking the stroke into the SVG markup rather than
  // tinting with MultiEffect.colorization: that blend is luminance-
  // weighted (output ≈ colorizationColor × source luminance), and Tabler
  // strokes render pure black (luminance ≈ 0), so the tint collapsed to
  // black for every colour — even on hardware GL. Black reads fine on a
  // light surface but vanishes on the dark hover background. Qt's raster
  // SVG renderer honours the baked colour and repaints live when `color`
  // changes.
  readonly property string imageSource: _svg === "" ? "" : ("data:image/svg+xml;utf8," + encodeURIComponent(_svg.replace(/currentColor/g, _hex(color))))

  FileView {
    id: svgFile
    path: root.icon === "" ? "" : (Quickshell.shellDir + "/icons/" + root.icon + ".svg")
    printErrors: false
    onLoaded: root._svg = text()
    // FileView 0.3.0 does not read on construction; prime it once and
    // reload whenever the icon name (and thus the path) changes.
    onPathChanged: { root._svg = ""; if (path !== "") reload(); }
    Component.onCompleted: reload()
  }

  Image {
    anchors.fill: parent
    sourceSize.width: root.renderSize
    sourceSize.height: root.renderSize
    fillMode: Image.PreserveAspectFit
    asynchronous: true
    source: root.imageSource
  }
}

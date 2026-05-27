// Icon renderer.
//
// noctalia uses an icon font (tabler-icons.ttf) and renders the
// codepoint through a Text. We use SVG files vendored under
// `<shellDir>/icons/<name>.svg` instead — same Tabler set, no font
// loader, no codepoint map, addable by drop-in.
//
// API surface matches noctalia's NIcon enough that call sites port
// unchanged: `icon` (name without .svg), `pointSize` (treated as
// visual size in px), `color` (recolors the SVG via ColorOverlay).
import QtQuick
import QtQuick.Effects
import Quickshell
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

  // Greyscale SVG source — Tabler outline icons are pure-stroke SVGs
  // with currentColor stroke; rendering at full width/height with the
  // sourceSize equal to the visual size gives crisp output at any DPI.
  Image {
    id: src
    anchors.fill: parent
    source: root.icon === "" ? "" : ("file://" + Quickshell.shellDir + "/icons/" + root.icon + ".svg")
    sourceSize.width: root.renderSize
    sourceSize.height: root.renderSize
    fillMode: Image.PreserveAspectFit
    visible: false
    asynchronous: true
  }

  // Recolour the SVG. SVGs from tabler use `currentColor` strokes
  // (rendered as black by default); MultiEffect's `colorization`
  // tints the entire visible content to `colorizationColor`.
  MultiEffect {
    anchors.fill: src
    source: src
    colorization: 1.0
    colorizationColor: root.color
    visible: src.status === Image.Ready
  }
}

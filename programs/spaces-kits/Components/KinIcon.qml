// KinIcon — renders a Kin line-icon glyph by name.
//
// QML can't feed an SVG a "currentColor", so (like pi-chat's NIcon) we bake
// the stroke colour into the markup and render it as a data-URI Image. The
// glyph bodies live in the Icons singleton; this wraps the chosen one in an
// <svg> frame with round caps/joins on a 24×24 grid.
import QtQuick
import qs.Commons

Item {
  id: root

  property string name: ""
  property real size: 20
  property real strokeWidth: 1.75
  property color color: Theme.ink900

  implicitWidth: root.size
  implicitHeight: root.size
  visible: root.name !== ""

  function _hex(c) {
    return "#" + [c.r, c.g, c.b].map(v => Math.round(v * 255).toString(16).padStart(2, "0")).join("");
  }

  readonly property string _inner: Icons.paths[root.name] ?? ""
  readonly property string _svg: root._inner === "" ? "" : ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="' + root._hex(root.color) + '" stroke-width="' + root.strokeWidth + '" stroke-linecap="round" stroke-linejoin="round">' + root._inner + '</svg>')

  Image {
    anchors.fill: parent
    source: root._svg === "" ? "" : ("data:image/svg+xml;utf8," + encodeURIComponent(root._svg))
    sourceSize.width: Math.round(root.size)
    sourceSize.height: Math.round(root.size)
    fillMode: Image.PreserveAspectFit
    smooth: true
  }
}

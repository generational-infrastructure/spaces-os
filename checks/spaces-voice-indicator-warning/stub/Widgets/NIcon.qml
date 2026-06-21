// Stand-in for noctalia's Widgets/NIcon — a glyph element exposing the
// `icon` / `pointSize` API BarWidget.qml sets. Backed by Text so it carries
// color/opacity/rotation/anchors for the animation bindings.
import QtQuick

Text {
  property string icon: ""
  property real pointSize: 12
  text: icon
}

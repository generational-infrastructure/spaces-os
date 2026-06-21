// KinIconButton — square, soft-rounded icon-only control (port of IconButton.jsx).
// Quiet ghost that warms on hover, or a filled variant.
import QtQuick
import qs.Commons
import qs.Components

Item {
  id: root

  property string icon: ""
  property string label: ""
  property string size: "md" // sm | md | lg
  property string variant: "ghost" // ghost | filled
  property bool active: false

  signal clicked

  readonly property int _dim: root.size === "lg" ? 40 : root.size === "sm" ? 28 : 34
  readonly property int _iconSz: root.size === "lg" ? 20 : root.size === "sm" ? 16 : 18
  readonly property bool _filled: root.variant === "filled" || root.active

  implicitWidth: root._dim
  implicitHeight: root._dim

  Rectangle {
    anchors.fill: parent
    radius: Theme.radiusMd
    color: root._filled ? Theme.ink100 : ma.containsMouse ? Theme.ink100 : "transparent"

    Behavior on color {
      ColorAnimation {
        duration: Theme.durFast
      }
    }

    KinIcon {
      anchors.centerIn: parent
      name: root.icon
      size: root._iconSz
      color: root.active ? Theme.ink900 : Theme.ink500
    }
  }

  MouseArea {
    id: ma
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}

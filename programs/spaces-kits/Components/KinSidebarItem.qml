// KinSidebarItem — a navigation row in the left rail (port of SidebarItem.jsx).
// Quiet by default; selected rows get a soft grey pill + dark ink.
import QtQuick
import qs.Commons
import qs.Components

Item {
  id: root

  property string icon: ""
  property string label: ""
  property bool selected: false

  signal clicked

  implicitHeight: 40

  Rectangle {
    anchors.fill: parent
    radius: Theme.radiusMd
    color: root.selected ? Theme.ink100 : ma.containsMouse ? Theme.ink50 : "transparent"

    Behavior on color {
      ColorAnimation {
        duration: Theme.durFast
      }
    }

    Row {
      anchors.left: parent.left
      anchors.leftMargin: 12
      anchors.right: parent.right
      anchors.rightMargin: 12
      anchors.verticalCenter: parent.verticalCenter
      spacing: 12

      KinIcon {
        visible: root.icon !== ""
        name: root.icon
        size: 19
        color: root.selected ? Theme.ink900 : Theme.ink400
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        text: root.label
        font.family: Theme.fontUI
        font.pixelSize: Theme.fsSm
        font.weight: root.selected ? Theme.fwSemibold : Theme.fwMedium
        color: root.selected ? Theme.ink900 : Theme.ink500
        anchors.verticalCenter: parent.verticalCenter
      }
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

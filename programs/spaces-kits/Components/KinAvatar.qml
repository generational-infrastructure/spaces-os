// KinAvatar — round Clan portrait (port of Avatar.jsx).
// Image when `src` is set, else a tinted initial. Optional presence dot.
import QtQuick
import qs.Commons

Item {
  id: root

  property string src: ""
  property string name: ""
  property int dim: 40
  property string status: "" // online | busy | offline | ""

  readonly property string _initial: root.name.trim().length > 0 ? root.name.trim().charAt(0).toUpperCase() : "?"
  readonly property int _dot: Math.max(8, Math.round(root.dim * 0.26))
  readonly property color _statusColor: root.status === "online" ? Theme.clanSuccess : root.status === "busy" ? Theme.clanError : Theme.ink400

  implicitWidth: root.dim
  implicitHeight: root.dim

  Rectangle {
    id: disc
    anchors.fill: parent
    radius: width / 2
    color: root.src !== "" ? Theme.ink100 : Theme.clanSecondary300
    border.width: 1
    border.color: Qt.rgba(0, 0, 0, 0.06)
    clip: true

    Text {
      anchors.centerIn: parent
      visible: root.src === ""
      text: root._initial
      color: Theme.white
      font.family: Theme.fontUI
      font.weight: Theme.fwSemibold
      font.pixelSize: Math.round(root.dim * 0.4)
    }
    Image {
      anchors.fill: parent
      visible: root.src !== ""
      source: root.src
      fillMode: Image.PreserveAspectCrop
      smooth: true
    }
  }

  Rectangle {
    visible: root.status !== ""
    width: root._dot
    height: root._dot
    radius: width / 2
    color: root._statusColor
    border.width: 2
    border.color: Theme.white
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.rightMargin: -1
    anchors.bottomMargin: -1
  }
}

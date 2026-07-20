// KinFileTile — a file/folder card in the Files grid (port of FileTile.jsx).
// A large soft-rounded tinted preview above a name + meta line; hover lifts it.
import QtQuick
import qs.Commons
import qs.Components

Item {
  id: root

  property string name: ""
  property string meta: ""
  property string kind: "doc" // doc | image | audio | archive | folder

  readonly property color _tintBg: root.kind === "folder" ? Qt.lighter(Theme.kinSky, 1.18) : root.kind === "audio" ? "#f1eef4" : root.kind === "archive" ? "#f4f0ea" : "#eef1f4"
  readonly property color _tintFg: root.kind === "folder" ? Theme.clanPrimary700 : root.kind === "audio" ? "#9483a8" : root.kind === "archive" ? "#a89674" : "#7d8a99"
  readonly property string _icon: root.kind === "folder" ? "folder" : "file"

  implicitHeight: width + 56

  Column {
    anchors.fill: parent
    spacing: 12

    Rectangle {
      id: preview
      width: parent.width
      height: parent.width
      radius: Theme.radiusLg
      color: root._tintBg
      y: ma.containsMouse ? -2 : 0
      border.width: 1
      border.color: Qt.rgba(0, 0, 0, 0.06)

      Behavior on y {
        NumberAnimation {
          duration: Theme.durBase
          easing.type: Easing.OutCubic
        }
      }

      KinIcon {
        anchors.centerIn: parent
        name: root._icon
        size: 44
        strokeWidth: 1.4
        color: root._tintFg
      }
    }

    Row {
      width: parent.width
      spacing: 8

      KinIcon {
        visible: root.kind === "folder"
        name: "folder"
        size: 18
        color: Theme.clanSecondary400
        anchors.verticalCenter: nameCol.verticalCenter
      }
      Column {
        id: nameCol
        width: parent.width - (root.kind === "folder" ? 26 : 0)
        spacing: 2

        Text {
          width: parent.width
          text: root.name
          elide: Text.ElideRight
          font.family: Theme.fontUI
          font.pixelSize: Theme.fsSm
          font.weight: Theme.fwSemibold
          color: Theme.ink900
        }
        Text {
          visible: root.meta !== ""
          width: parent.width
          text: root.meta
          elide: Text.ElideRight
          font.family: Theme.fontUI
          font.pixelSize: Theme.fsXs
          color: Theme.ink400
        }
      }
    }
  }

  MouseArea {
    id: ma
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
  }
}

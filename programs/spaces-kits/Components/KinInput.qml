// KinInput — soft-rounded text field (port of Input.jsx).
// Quiet grey well; lifts to white with an info-blue focus ring.
import QtQuick
import qs.Commons
import qs.Components

Item {
  id: root

  property string placeholder: ""
  property string iconLeft: ""
  property string size: "md" // sm | md | lg
  property alias text: input.text
  property alias inputItem: input

  signal accepted

  readonly property int _h: root.size === "lg" ? 48 : root.size === "sm" ? 34 : 40

  implicitHeight: root._h
  implicitWidth: 240

  Rectangle {
    id: well
    anchors.fill: parent
    radius: Theme.radiusMd
    color: input.activeFocus ? Theme.white : Theme.ink100
    border.width: input.activeFocus ? 2 : 0
    border.color: Theme.focusRing

    Behavior on color {
      ColorAnimation {
        duration: Theme.durFast
      }
    }

    Row {
      anchors.fill: parent
      anchors.leftMargin: 14
      anchors.rightMargin: 14
      spacing: 8

      KinIcon {
        visible: root.iconLeft !== ""
        name: root.iconLeft
        size: 18
        color: Theme.ink400
        anchors.verticalCenter: parent.verticalCenter
      }
      TextInput {
        id: input
        width: parent.width - (root.iconLeft !== "" ? 26 : 0)
        anchors.verticalCenter: parent.verticalCenter
        font.family: Theme.fontUI
        font.pixelSize: Theme.fsSm
        color: Theme.ink900
        clip: true
        selectionColor: Theme.clanInfo
        selectByMouse: true
        onAccepted: root.accepted()

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: root.placeholder
          visible: input.text === "" && !input.activeFocus
          font: input.font
          color: Theme.ink400
        }
      }
    }
  }
}

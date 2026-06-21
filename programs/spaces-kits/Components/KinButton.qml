// KinButton — the Spaces OS action pill (QML port of Button.jsx).
// Fully-rounded; five intents, three sizes, optional leading/trailing icon.
import QtQuick
import qs.Commons
import qs.Components

Item {
  id: root

  property string label: ""
  property string intent: "primary" // primary | secondary | outline | ghost | destructive
  property string size: "md" // sm | md | lg
  property string iconLeft: ""
  property string iconRight: ""

  signal clicked

  readonly property int _h: root.size === "lg" ? 48 : root.size === "sm" ? 32 : 40
  readonly property int _padH: root.size === "lg" ? 24 : root.size === "sm" ? 14 : 18
  readonly property int _fs: root.size === "lg" ? Theme.fsMd : root.size === "sm" ? Theme.fsXs : Theme.fsSm
  readonly property int _iconSz: root.size === "lg" ? 19 : root.size === "sm" ? 15 : 17

  readonly property color _bg: root.intent === "secondary" ? Theme.ink100 : root.intent === "ghost" || root.intent === "outline" ? "transparent" : root.intent === "destructive" ? Theme.clanError : Theme.ink900
  readonly property color _bgHover: root.intent === "secondary" ? Theme.ink200 : root.intent === "ghost" || root.intent === "outline" ? Theme.ink100 : root.intent === "destructive" ? Qt.lighter(Theme.clanError, 1.08) : Qt.lighter(Theme.ink900, 1.5)
  readonly property color _fg: root.intent === "secondary" || root.intent === "outline" ? Theme.ink900 : root.intent === "ghost" ? Theme.ink700 : Theme.white

  implicitHeight: root._h
  implicitWidth: contentRow.implicitWidth + root._padH * 2
  opacity: root.enabled ? 1.0 : 0.4

  Rectangle {
    id: bg
    anchors.fill: parent
    radius: Theme.radiusPill
    color: ma.containsMouse && root.enabled ? root._bgHover : root._bg
    border.width: root.intent === "outline" ? 1 : 0
    border.color: Theme.ink300
    scale: ma.pressed ? 0.97 : 1.0

    Behavior on color {
      ColorAnimation {
        duration: Theme.durFast
      }
    }
    Behavior on scale {
      NumberAnimation {
        duration: Theme.durFast
      }
    }

    Row {
      id: contentRow
      anchors.centerIn: parent
      spacing: 8

      KinIcon {
        visible: root.iconLeft !== ""
        name: root.iconLeft
        size: root._iconSz
        strokeWidth: 2
        color: root._fg
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        text: root.label
        font.family: Theme.fontUI
        font.pixelSize: root._fs
        font.weight: Theme.fwSemibold
        color: root._fg
        anchors.verticalCenter: parent.verticalCenter
      }
      KinIcon {
        visible: root.iconRight !== ""
        name: root.iconRight
        size: root._iconSz
        strokeWidth: 2
        color: root._fg
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }

  MouseArea {
    id: ma
    anchors.fill: parent
    hoverEnabled: true
    enabled: root.enabled
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}

// KinBadge — small status / category pill (port of Badge.jsx).
import QtQuick
import qs.Commons

Item {
  id: root

  property string label: ""
  property string tone: "neutral" // neutral | sky | success | magenta | ink | glass
  property bool small: false
  property bool dot: false

  readonly property color _bg: root.tone === "sky" ? Theme.kinSky : root.tone === "success" ? Qt.rgba(0.09, 0.7, 0.22, 0.16) : root.tone === "magenta" ? "#f9eaf4" : root.tone === "ink" ? Theme.ink900 : root.tone === "glass" ? Qt.rgba(1, 1, 1, 0.72) : Theme.ink100
  readonly property color _fg: root.tone === "sky" ? Theme.clanPrimary800 : root.tone === "success" ? Theme.clanSuccess600 : root.tone === "magenta" ? Theme.clanError600 : root.tone === "ink" ? Theme.white : Theme.ink700

  readonly property int _h: root.small ? 20 : 24
  readonly property int _pad: root.small ? 8 : 10

  implicitHeight: root._h
  implicitWidth: content.implicitWidth + root._pad * 2

  Rectangle {
    anchors.fill: parent
    radius: Theme.radiusPill
    color: root._bg

    Row {
      id: content
      anchors.centerIn: parent
      spacing: 6

      Rectangle {
        visible: root.dot
        width: 6
        height: 6
        radius: 3
        color: root._fg
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        text: root.label
        font.family: Theme.fontUI
        font.pixelSize: root.small ? Theme.fs2xs : Theme.fsXs
        font.weight: Theme.fwSemibold
        color: root._fg
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }
}

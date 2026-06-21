// KinSegmentedControl — grey track with a white sliding thumb behind the
// active segment (port of SegmentedControl.jsx). Drives the grid/list switch.
// `options` is a list of { value, icon }.
pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Components

Item {
  id: root

  property var options: []
  property string value: ""

  signal changed(string value)

  readonly property int _pad: 3
  readonly property int _cell: 48
  readonly property int _count: root.options.length

  function _indexOf(v) {
    for (var i = 0; i < root.options.length; i++) {
      if (root.options[i].value === v)
        return i;
    }
    return 0;
  }

  implicitHeight: 36
  implicitWidth: root._count * root._cell + root._pad * 2

  Rectangle {
    anchors.fill: parent
    radius: Theme.radiusPill
    color: Theme.ink100

    Rectangle {
      id: thumb
      y: root._pad
      height: parent.height - root._pad * 2
      width: root._cell
      radius: Theme.radiusPill
      color: Theme.white
      x: root._pad + root._indexOf(root.value) * root._cell

      Behavior on x {
        NumberAnimation {
          duration: Theme.durBase
          easing.type: Easing.OutCubic
        }
      }
    }

    Row {
      anchors.fill: parent
      anchors.margins: root._pad

      Repeater {
        model: root.options

        delegate: Item {
          id: seg
          required property var modelData
          width: root._cell
          height: parent ? parent.height : 0

          KinIcon {
            anchors.centerIn: parent
            name: seg.modelData.icon
            size: 17
            color: seg.modelData.value === root.value ? Theme.ink900 : Theme.ink500
          }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.changed(seg.modelData.value)
          }
        }
      }
    }
  }
}

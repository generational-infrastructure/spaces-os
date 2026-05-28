// Labeled push button. Used twice in the panel — once for the
// "Allow"/"Deny" confirmation pair, once for signal approval.
//
// Mirrors noctalia's NButton API for the props the plugin sets:
// `text`, `icon` (optional leading icon name), `onClicked`,
// `enabled`. Visual: pill-shaped with primary background.
pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons

Item {
  id: root

  property string text: ""
  property string icon: ""
  property color bgColor: Color.mPrimary
  property color fgColor: Color.mOnPrimary
  property bool hovering: hover.hovered

  signal clicked

  implicitHeight: Style.baseWidgetSize * 0.85
  implicitWidth: row.implicitWidth + Style.marginL * 2

  Rectangle {
    anchors.fill: parent
    color: hover.hovered && root.enabled ? Qt.lighter(root.bgColor, 1.1) : root.bgColor
    radius: Style.iRadiusM
    border.color: Color.mOutline
    border.width: Style.borderS
    opacity: root.enabled ? 1.0 : 0.6

    Behavior on color {
      ColorAnimation { duration: Style.animationFast; easing.type: Easing.InOutQuad }
    }
  }

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.marginXS

    NIcon {
      visible: root.icon !== ""
      icon: root.icon
      pointSize: Style.fontSizeM
      color: root.fgColor
      anchors.verticalCenter: parent.verticalCenter
    }
    NText {
      text: root.text
      pointSize: Style.fontSizeM
      color: root.fgColor
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  HoverHandler {
    id: hover
    cursorShape: root.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
  }
  TapHandler {
    enabled: root.enabled
    onTapped: root.clicked()
  }
}

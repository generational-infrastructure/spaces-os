// Square icon button with hover state and click signal.
//
// Stripped from noctalia's 133-line NIconButton to the surface the
// plugin uses: `icon`, `tooltipText` (treated as native Qt tooltip
// rather than noctalia's TooltipService), `onClicked`, `enabled`.
// Drops middle-click, right-click, wheel handling — none of the
// plugin's call sites bind those signals.
import QtQuick
import QtQuick.Controls
import qs.Commons

Item {
  id: root

  property real baseSize: Style.baseWidgetSize
  property string icon: ""
  // Surfaced as a native Qt tooltip. noctalia's TooltipService
  // doesn't exist standalone; the platform tooltip is good enough
  // for the chat panel's needs.
  property string tooltipText: ""
  property color colorBg: Color.mSurfaceVariant
  property color colorFg: Color.mPrimary
  property color colorBgHover: Color.mHover
  property color colorFgHover: Color.mOnHover
  property color colorBorder: Color.mOutline
  property bool hovering: hover.hovered
  // Reserved for noctalia API parity; the chat panel doesn't bind
  // these so they're inert here but worth keeping so future widget
  // ports compile without touching call sites.
  property bool applyUiScale: true
  property bool allowClickWhenDisabled: false

  signal clicked

  implicitWidth: baseSize
  implicitHeight: baseSize
  opacity: enabled ? 1.0 : 0.6

  Rectangle {
    id: bg
    anchors.fill: parent
    color: root.enabled && root.hovering ? root.colorBgHover : root.colorBg
    radius: Math.min(Style.iRadiusM, width / 2)
    border.color: root.colorBorder
    border.width: Style.borderS

    Behavior on color {
      ColorAnimation { duration: Style.animationFast; easing.type: Easing.InOutQuad }
    }

    NIcon {
      anchors.centerIn: parent
      icon: root.icon
      pointSize: Math.max(8, bg.width * 0.45)
      color: root.enabled && root.hovering ? root.colorFgHover : root.colorFg
    }
  }

  HoverHandler {
    id: hover
    cursorShape: root.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
  }

  TapHandler {
    enabled: root.enabled || root.allowClickWhenDisabled
    onTapped: root.clicked()
  }

  ToolTip.visible: root.tooltipText !== "" && hover.hovered
  ToolTip.text: root.tooltipText
  ToolTip.delay: 300
}

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Modules.Bar.Extras
import qs.Services.UI
import qs.Widgets

Item {
  id: root

  property var pluginApi: null
  property var chat: pluginApi?.mainInstance?.chat || null

  property ShellScreen screen
  property string widgetId: ""
  property string section: ""

  readonly property string screenName: screen ? screen.name : ""
  readonly property string barPosition: Settings.getBarPositionForScreen(screenName)
  readonly property bool isVerticalBar: barPosition === "left" || barPosition === "right"

  readonly property bool connected: chat?.streaming ?? false

  readonly property string currentIcon: connected ? "message-circle" : "message-circle-off"

  readonly property color iconColor: {
    if (!connected) return Color.mOnSurfaceVariant;
    return Color.mPrimary;
  }

  implicitWidth: pill.width
  implicitHeight: pill.height

  BarPill {
    id: pill
    screen: root.screen
    oppositeDirection: BarService.getPillDirection(root)
    icon: root.currentIcon
    autoHide: true
    customTextIconColor: root.iconColor

    onClicked: {
      if (pluginApi) {
        pluginApi.openPanel(root.screen, root);
      }
    }

    onRightClicked: {
      PanelService.showContextMenu(contextMenu, root, screen);
    }
  }

  NPopupContextMenu {
    id: contextMenu

    model: [
      {
        "label": pluginApi?.tr("menu.open-chat") ?? "Open Chat",
        "action": "open",
        "icon": "message-circle"
      },
      {
        "label": pluginApi?.tr("menu.settings") ?? "Settings",
        "action": "settings",
        "icon": "settings"
      }
    ]

    onTriggered: function(action) {
      contextMenu.close();
      PanelService.closeContextMenu(screen);
      if (action === "open") {
        if (pluginApi) {
          pluginApi.openPanel(root.screen, root);
        }
      } else if (action === "settings") {
        BarService.openPluginSettings(root.screen, pluginApi.manifest);
      }
    }
  }
}

// Spaces Agent Sessions — bar widget.
//
// Renders one icon per chat published in the activity feed (see
// Main.qml). Colour encodes the agent's state:
//   working  → Color.mPrimary  (amber) + a gentle pulse
//   waiting  → Color.mTertiary (green)
// The active chat gets a filled, outlined capsule. Hovering swaps to
// the hover background with its matching mOnHover foreground (contrast).
// Clicking focuses that chat in the pi-chat panel.
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Widgets

Item {
  id: root

  // Set by the plugin host / BarWidgetLoader.
  property var pluginApi: null
  property ShellScreen screen
  property string widgetId: ""
  property string section: ""
  // Declared so the bar's loader can assign them (it sets these on every
  // widget); we don't use per-instance bar settings ourselves.
  property int sectionWidgetIndex: -1
  property int sectionWidgetsCount: 0

  readonly property var svc: pluginApi ? pluginApi.mainInstance : null
  readonly property var sessions: svc ? svc.sessions : []
  readonly property string activeId: svc ? svc.activeSessionId : ""
  readonly property var cfg: pluginApi ? pluginApi.pluginSettings : ({})

  readonly property string screenName: screen ? screen.name : ""
  readonly property real capsuleHeight: Style.getCapsuleHeightForScreen(screenName)
  readonly property int itemSize: Style.toOdd(capsuleHeight)
  readonly property real iconPointSize: Style.fontSizeM

  readonly property bool hasSessions: sessions.length > 0

  implicitWidth: hasSessions ? row.implicitWidth : 0
  implicitHeight: capsuleHeight
  visible: hasSessions

  // Focus a chat: select it, then reveal the panel. Both go through the
  // pi-chat IPC (focusCommand is the `quickshell ipc -c pi-chat call
  // pi-chat` prefix; the home-manager module pins the absolute binary).
  // Session ids are base36 (PiChatBackend._newId), so no shell quoting
  // is needed.
  //
  // Two quirks of invoking quickshell from inside noctalia:
  //   1. noctalia sets QS_CONFIG_PATH to its own shell dir; the child
  //      quickshell turns that into --path, which collides with our
  //      -c pi-chat / --config ("--path excludes --config", exit 108).
  //      Clearing it lets the detached quickshell resolve pi-chat by
  //      name, exactly as pi-chat's own launcher does.
  //   2. `show` is also a `quickshell ipc` subcommand, so a bare
  //      `call pi-chat show` is parsed as `ipc show` (prints metadata,
  //      no-op). `--` forces every following token to be the call's
  //      function + args; we use it for both verbs for good measure.
  function focusSession(id) {
    const base = (cfg && cfg.focusCommand && String(cfg.focusCommand).trim()) || "quickshell ipc -c pi-chat call pi-chat";
    const cmd = "unset QS_CONFIG_PATH QS_CONFIG_NAME; " + base + " -- selectSession " + id + " && " + base + " -- show";
    Quickshell.execDetached(["sh", "-c", cmd]);
  }

  RowLayout {
    id: row
    anchors.centerIn: parent
    spacing: Style.marginXS

    Repeater {
      model: root.sessions

      delegate: Item {
        id: item
        required property var modelData

        readonly property bool working: modelData.state === "working"
        readonly property bool isActive: modelData.id === root.activeId
        readonly property color stateColor: working ? Color.mPrimary : Color.mTertiary

        Layout.preferredWidth: root.itemSize
        Layout.preferredHeight: root.itemSize

        Rectangle {
          id: bg
          anchors.fill: parent
          radius: width / 2
          color: itemMouse.containsMouse ? Color.mHover : (item.isActive ? Color.mSurfaceVariant : "transparent")
          border.width: item.isActive ? Math.max(1, Math.round(root.itemSize * 0.09)) : 0
          border.color: item.stateColor

          NIcon {
            id: glyph
            anchors.centerIn: parent
            icon: "message-chatbot"
            pointSize: root.iconPointSize
            // Foreground MUST contrast its background: mOnHover on the
            // hover fill, otherwise the state colour.
            color: itemMouse.containsMouse ? Color.mOnHover : item.stateColor

            // Pulse while working so the busy state reads even without
            // colour (accessibility) and feels alive. As an "on opacity"
            // value source, opacity reverts to its default 1.0 whenever
            // the animation isn't running.
            SequentialAnimation on opacity {
              running: item.working && !itemMouse.containsMouse
              loops: Animation.Infinite
              alwaysRunToEnd: true
              NumberAnimation { to: 0.4; duration: 700; easing.type: Easing.InOutSine }
              NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutSine }
            }
          }
        }

        MouseArea {
          id: itemMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.focusSession(item.modelData.id)
        }
      }
    }
  }
}

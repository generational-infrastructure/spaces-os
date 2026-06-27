pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtQuick.Effects
import qs.Commons
import qs.Widgets

Item {
  id: root

  property var backend: null

  property string selectedConversationId: ""
  property string listMode: "chats"
  property real _now: Date.now()

  readonly property bool inChat: selectedConversationId !== ""
  readonly property var selectedConversation: directory.conversationById(selectedConversationId)

  readonly property color dusk: "#1f231f"
  readonly property color ink: "#171717"
  readonly property color granite: "#6b6b6b"
  readonly property color muted: "#9ea39e"
  readonly property color cloud: "#cdd1cd"
  readonly property color dust: "#ebebeb"
  readonly property color sleet: "#f3f3f3"
  readonly property color ice: "#f8f8f8"
  readonly property color matcha: "#17b239"
  readonly property color warning: "#ff6157"
  readonly property color cardColor: Qt.rgba(250 / 255, 250 / 255, 250 / 255, 0.92)
  readonly property color navColor: Qt.rgba(255 / 255, 255 / 255, 255 / 255, 0.92)

  Timer {
    interval: 30000
    running: root.visible
    repeat: true
    onTriggered: root._now = Date.now()
  }

  function ago(ts) {
    if (!ts) return "";
    const s = Math.max(0, (root._now - ts) / 1000);
    if (s < 60) return "now";
    if (s < 3600) return Math.floor(s / 60) + "m";
    if (s < 86400) return Math.floor(s / 3600) + "h";
    return Qt.formatDateTime(new Date(ts), "ddd HH:mm");
  }

  KinConversations {
    id: directory
  }

  function openConversation(conversationId) {
    selectedConversationId = conversationId;
    Qt.callLater(() => {
      history.positionViewAtEnd();
      inputArea.forceActiveFocus();
    });
  }

  function closeConversation() {
    selectedConversationId = "";
  }

  function visibleConversations() {
    return directory.conversationsForMode(listMode);
  }

  function initials(name) {
    const parts = String(name || "?").split(/[ ,&]+/).filter(p => p.length > 0);
    if (parts.length === 0) return "?";
    if (parts.length === 1) return String(parts[0]).slice(0, 2).toUpperCase();
    return String(parts[0]).slice(0, 1).toUpperCase()
      + String(parts[1]).slice(0, 1).toUpperCase();
  }

  function visibleMessages() {
    return directory.messagesFor(selectedConversationId);
  }

  function submitMessage() {
    const text = inputArea.text.trim();
    if (text.length === 0) return;

    directory.addMessage(selectedConversationId, {
      author: "You",
      text,
      time: "now",
      avatarText: "Y",
      avatarColor: "#dff5e6",
      avatarTextColor: "#1f231f",
      online: false,
      mine: true,
    });

    inputArea.clear();
    Qt.callLater(() => history.positionViewAtEnd());
  }

  component Avatar: Item {
    id: avatar

    property string label: "?"
    property string iconName: ""
    property color baseColor: root.sleet
    property color textColor: root.dusk
    property bool online: false
    property bool snoozed: false
    property real side: 36

    implicitWidth: side
    implicitHeight: side

    Rectangle {
      anchors.fill: parent
      radius: 10
      color: avatar.baseColor
      clip: true

      NIcon {
        visible: avatar.iconName !== ""
        anchors.centerIn: parent
        icon: avatar.iconName
        pointSize: 14
        color: avatar.textColor
      }

      Text {
        visible: avatar.iconName === ""
        anchors.centerIn: parent
        text: avatar.label
        color: avatar.textColor
        font.family: Settings.data.ui.fontDefault
        font.pixelSize: avatar.label.length > 1 ? 12 : 15
        font.weight: 700
      }
    }

    Rectangle {
      visible: avatar.online || avatar.snoozed
      width: avatar.snoozed ? 14 : 12
      height: avatar.snoozed ? 14 : 12
      radius: width / 2
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.rightMargin: -2
      anchors.bottomMargin: -2
      color: avatar.snoozed ? root.warning : root.matcha
      border.color: root.cardColor
      border.width: 2

      Text {
        visible: avatar.snoozed
        anchors.centerIn: parent
        text: "z"
        color: "white"
        font.family: Settings.data.ui.fontDefault
        font.pixelSize: 8
        font.weight: 700
      }
    }
  }

  component ContactRow: Item {
    id: row

    property var conversation
    signal clicked

    implicitHeight: 60

    Rectangle {
      anchors.fill: parent
      anchors.leftMargin: 4
      anchors.rightMargin: 4
      radius: 12
      color: hover.hovered ? Qt.rgba(1, 1, 1, 0.86) : Qt.rgba(1, 1, 1, 0)
      Behavior on color { ColorAnimation { duration: 80 } }
    }

    Avatar {
      id: contactAvatar
      anchors.left: parent.left
      anchors.leftMargin: 16
      anchors.verticalCenter: parent.verticalCenter
      label: row.conversation.avatarText || root.initials(row.conversation.title)
      iconName: row.conversation.icon || ""
      baseColor: row.conversation.avatarColor || root.sleet
      textColor: row.conversation.avatarTextColor || root.dusk
      online: row.conversation.online || false
      snoozed: row.conversation.snoozed || false
    }

    Text {
      id: contactTitle
      anchors.left: contactAvatar.right
      anchors.leftMargin: 10
      anchors.right: parent.right
      anchors.rightMargin: 14
      y: 12
      text: row.conversation.title || ""
      color: root.dusk
      elide: Text.ElideRight
      font.family: Settings.data.ui.fontDefault
      font.pixelSize: 14
      font.weight: 700
    }

    Text {
      anchors.left: contactTitle.left
      anchors.right: contactTitle.right
      y: 32
      text: row.conversation.subtitle || ""
      color: root.muted
      elide: Text.ElideRight
      font.family: Settings.data.ui.fontDefault
      font.pixelSize: 12
      font.weight: 500
    }

    HoverHandler {
      id: hover
      cursorShape: Qt.PointingHandCursor
    }

    TapHandler {
      onTapped: row.clicked()
    }
  }

  component KinMessageRow: Item {
    id: row

    property var message

    implicitHeight: Math.max(52, body.y + body.implicitHeight + 8)

    Avatar {
      id: messageAvatar
      anchors.left: parent.left
      anchors.leftMargin: 0
      y: 4
      label: row.message.avatarText || root.initials(row.message.author)
      iconName: row.message.icon || ""
      baseColor: row.message.avatarColor || root.sleet
      textColor: row.message.avatarTextColor || root.dusk
      online: row.message.online || false
      snoozed: false
    }

    Text {
      id: author
      anchors.left: messageAvatar.right
      anchors.leftMargin: 10
      y: 0
      text: row.message.author || ""
      color: root.dusk
      font.family: Settings.data.ui.fontDefault
      font.pixelSize: 14
      font.weight: 700
    }

    Text {
      anchors.left: author.right
      anchors.leftMargin: 8
      anchors.baseline: author.baseline
      text: row.message.time || ""
      color: root.muted
      font.family: Settings.data.ui.fontDefault
      font.pixelSize: 10
      font.weight: 500
    }

    Text {
      id: body
      anchors.left: author.left
      anchors.right: parent.right
      anchors.rightMargin: 4
      y: 25
      text: row.message.text || ""
      color: root.ink
      wrapMode: Text.Wrap
      lineHeight: 20
      lineHeightMode: Text.FixedHeight
      font.family: Settings.data.ui.fontDefault
      font.pixelSize: 14
      font.weight: 400
    }
  }

  Rectangle {
    id: cardShadow
    width: card.width
    height: card.height
    anchors.centerIn: card
    radius: 18
    color: root.cardColor
    opacity: 0.01
    layer.enabled: true
    layer.effect: MultiEffect {
      shadowEnabled: true
      shadowColor: Qt.rgba(0, 0, 0, 0.18)
      shadowBlur: 0.85
      shadowVerticalOffset: 8
      shadowHorizontalOffset: 0
    }
  }

  Rectangle {
    id: card
    width: Math.min(parent.width - 20, 408)
    height: Math.min(parent.height - 20, 612)
    anchors.right: parent.right
    anchors.rightMargin: 10
    anchors.top: parent.top
    anchors.topMargin: 10
    radius: 16
    color: root.cardColor
    clip: true

    Item {
      id: membersPane
      anchors.fill: parent
      visible: !root.inChat
      opacity: visible ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 120 } }

      Rectangle {
        id: listTopBarShadow
        x: listTopBar.x
        y: listTopBar.y
        width: listTopBar.width
        height: listTopBar.height
        radius: listTopBar.radius
        color: root.navColor
        opacity: 0.01
        layer.enabled: true
        layer.effect: MultiEffect {
          shadowEnabled: true
          shadowColor: Qt.rgba(0, 0, 0, 0.12)
          shadowBlur: 0.7
          shadowVerticalOffset: 4
          shadowHorizontalOffset: 0
        }
      }

      Rectangle {
        id: listTopBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 8
        height: 40
        radius: 12
        color: root.navColor

        Text {
          id: chatsTab
          x: 16
          y: 0
          height: parent.height
          text: "Chats"
          color: root.listMode === "chats" ? root.ink : root.cloud
          elide: Text.ElideRight
          verticalAlignment: Text.AlignVCenter
          font.family: Settings.data.ui.fontDefault
          font.pixelSize: 14
          font.weight: 700

          HoverHandler {
            id: chatsHover
            cursorShape: Qt.PointingHandCursor
          }

          TapHandler {
            onTapped: root.listMode = "chats"
          }
        }

        Text {
          id: communitiesTab
          anchors.left: chatsTab.right
          anchors.leftMargin: 26
          y: 0
          height: parent.height
          text: "Communities"
          color: root.listMode === "communities" ? root.ink : root.cloud
          elide: Text.ElideRight
          verticalAlignment: Text.AlignVCenter
          font.family: Settings.data.ui.fontDefault
          font.pixelSize: 14
          font.weight: 700

          HoverHandler {
            id: communitiesHover
            cursorShape: Qt.PointingHandCursor
          }

          TapHandler {
            onTapped: root.listMode = "communities"
          }
        }

        Rectangle {
          width: 12
          height: 2
          radius: 1
          x: (root.listMode === "communities"
              ? communitiesTab.x + communitiesTab.implicitWidth / 2
              : chatsTab.x + chatsTab.implicitWidth / 2) - width / 2
          y: parent.height - 1
          color: root.ink
          Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.InOutQuad } }
        }

        NIconButton {
          id: plusButton
          anchors.right: parent.right
          anchors.rightMargin: 8
          anchors.verticalCenter: parent.verticalCenter
          icon: "plus"
          tooltipText: "New chat"
          baseSize: 24
          colorBg: root.ice
          colorBgHover: root.sleet
          colorFg: root.granite
          colorFgHover: root.dusk
          colorBorder: "transparent"
          onClicked: {
            const id = directory.addDemoConversation(root.listMode);
            root.openConversation(id);
          }
        }

        NIconButton {
          anchors.right: plusButton.left
          anchors.rightMargin: 8
          anchors.verticalCenter: parent.verticalCenter
          icon: "search"
          tooltipText: "Search"
          baseSize: 24
          colorBg: root.ice
          colorBgHover: root.sleet
          colorFg: root.granite
          colorFgHover: root.dusk
          colorBorder: "transparent"
        }
      }

      ListView {
        id: contacts
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: 62
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 62
        anchors.leftMargin: 14
        anchors.rightMargin: 14
        model: root.visibleConversations()
        interactive: contentHeight > height
        clip: true
        spacing: 0

        delegate: ContactRow {
          required property var modelData

          width: contacts.width
          conversation: modelData
          onClicked: root.openConversation(modelData.id)
        }
      }
    }

    Item {
      id: chatPane
      anchors.fill: parent
      visible: root.inChat
      opacity: visible ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 120 } }

      Rectangle {
        id: navShadow
        x: nav.x
        y: nav.y
        width: nav.width
        height: nav.height
        radius: 12
        color: root.navColor
        opacity: 0.01
        layer.enabled: true
        layer.effect: MultiEffect {
          shadowEnabled: true
          shadowColor: Qt.rgba(0, 0, 0, 0.12)
          shadowBlur: 0.7
          shadowVerticalOffset: 4
          shadowHorizontalOffset: 0
        }
      }

      Rectangle {
        id: nav
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 8
        height: 40
        radius: 12
        color: root.navColor

        NIconButton {
          id: backButton
          anchors.left: parent.left
          anchors.leftMargin: 8
          anchors.verticalCenter: parent.verticalCenter
          icon: "arrow-left"
          tooltipText: "Back"
          baseSize: 24
          colorBg: root.ice
          colorBgHover: root.sleet
          colorFg: root.granite
          colorFgHover: root.dusk
          colorBorder: "transparent"
          onClicked: root.closeConversation()
        }

        Text {
          anchors.centerIn: parent
          width: parent.width - 96
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          text: root.selectedConversation?.chatTitle || ""
          color: root.dusk
          elide: Text.ElideRight
          font.family: Settings.data.ui.fontDefault
          font.pixelSize: 16
          font.weight: 700
        }

        NIconButton {
          anchors.right: parent.right
          anchors.rightMargin: 8
          anchors.verticalCenter: parent.verticalCenter
          icon: "video"
          tooltipText: "Video"
          baseSize: 24
          colorBg: root.ice
          colorBgHover: root.sleet
          colorFg: root.granite
          colorFgHover: root.dusk
          colorBorder: "transparent"
        }
      }

      ListView {
        id: history
        objectName: "chatHistory"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: nav.bottom
        anchors.topMargin: 20
        anchors.bottom: composer.top
        anchors.bottomMargin: 16
        anchors.leftMargin: 24
        anchors.rightMargin: 18
        model: root.inChat ? root.visibleMessages() : []
        clip: true
        spacing: 8
        interactive: contentHeight > height
        onCountChanged: Qt.callLater(() => positionViewAtEnd())

        delegate: KinMessageRow {
          required property var modelData

          width: history.width
          message: modelData
        }
      }

      Item {
        id: composer
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 0
        height: 60

        NIconButton {
          id: addButton
          anchors.left: parent.left
          anchors.leftMargin: 16
          anchors.top: parent.top
          anchors.topMargin: 8
          icon: "plus"
          tooltipText: "Add"
          baseSize: 24
          colorBg: "transparent"
          colorBgHover: root.ice
          colorFg: root.muted
          colorFgHover: root.dusk
          colorBorder: "transparent"
        }

        Rectangle {
          id: inputBox
          anchors.left: parent.left
          anchors.leftMargin: 48
          anchors.right: parent.right
          anchors.rightMargin: 16
          anchors.top: parent.top
          anchors.topMargin: 0
          height: 40
          radius: 16
          color: "white"
          border.color: root.dust
          border.width: 1

          TextArea {
            id: inputArea
            objectName: "composeInput"
            anchors.left: parent.left
            anchors.right: sendButton.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.leftMargin: 16
            anchors.rightMargin: 0
            anchors.topMargin: 0
            anchors.bottomMargin: 0
            background: null
            placeholderText: "Message space"
            placeholderTextColor: root.cloud
            color: root.ink
            wrapMode: TextEdit.NoWrap
            selectByMouse: true
            verticalAlignment: TextEdit.AlignVCenter
            font.family: Settings.data.ui.fontDefault
            font.pixelSize: 14
            leftPadding: 0
            rightPadding: 0
            topPadding: 0
            bottomPadding: 0

            Keys.onPressed: event => {
              if (event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter) return;
              if ((event.modifiers & Qt.ShiftModifier) !== 0) {
                event.accepted = false;
                return;
              }
              event.accepted = true;
              root.submitMessage();
            }
          }

          NIconButton {
            id: sendButton
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            icon: inputArea.text.trim().length > 0 ? "send" : "mood-smile"
            tooltipText: inputArea.text.trim().length > 0 ? "Send" : ""
            baseSize: 24
            colorBg: "transparent"
            colorBgHover: root.ice
            colorFg: inputArea.text.trim().length > 0 ? root.dusk : root.muted
            colorFgHover: root.dusk
            colorBorder: "transparent"
            onClicked: root.submitMessage()
          }
        }

        Text {
          anchors.left: inputBox.left
          anchors.top: inputBox.bottom
          anchors.topMargin: 4
          text: (root.selectedConversation?.typingName || "Adrock") + " is typing"
          color: root.muted
          font.family: Settings.data.ui.fontDefault
          font.pixelSize: 10
          font.weight: 400
        }
      }
    }
  }

  Connections {
    target: root.Window.window
    ignoreUnknownSignals: true
    function onActiveChanged() {
      if (root.Window.window?.active && root.inChat) inputArea.forceActiveFocus();
    }
  }
}

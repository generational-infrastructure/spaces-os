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
  property var _historyCache: ({})

  readonly property bool inChat: selectedConversationId !== ""
  readonly property var selectedConversation: conversationById(selectedConversationId)
  readonly property var selectedSession: sessionObject(selectedConversationId)

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
    onTriggered: {
      root._now = Date.now();
      root.syncHistoryModel();
    }
  }

  onSelectedConversationIdChanged: {
    if (history) history.followTail = true;
    if (selectedConversationId !== "") Qt.callLater(() => root.syncHistoryModel(true));
  }

  function ago(ts) {
    if (!ts) return "";
    const s = Math.max(0, (root._now - ts) / 1000);
    if (s < 60) return "now";
    if (s < 3600) return Math.floor(s / 60) + "m";
    if (s < 86400) return Math.floor(s / 3600) + "h";
    return Qt.formatDateTime(new Date(ts), "ddd HH:mm");
  }

  function openConversation(conversationId) {
    if (!conversationId) return;
    root.backend?.selectSession?.(conversationId);
    selectedConversationId = conversationId;
    Qt.callLater(() => {
      root.syncHistoryModel(true);
      history.followTail = true;
      history.positionViewAtEnd();
      inputArea.forceActiveFocus();
    });
  }

  function closeConversation() {
    selectedConversationId = "";
  }

  function rawSessions() {
    return Array.prototype.slice.call(root.backend?.sessionsList || []);
  }

  function primarySession() {
    const sessions = rawSessions();
    if (sessions.length === 0) return null;
    for (const session of sessions) {
      if (String(session.name || "").toLowerCase() === "arlo") return session;
    }
    return sessions[0];
  }

  function sessionObject(id) {
    if (!id) return null;
    const map = root.backend?._sessionObjs || {};
    if (map[id]) return map[id];
    if (root.backend?.activeSessionId === id) return root.backend?.chat || null;
    return null;
  }

  function avatarColorFor(id) {
    const colors = ["#dff5e6", "#ffefcb", "#b8c9c3", "#ffdfb4", "#a7b1d4", "#ffefee", "#d7e7ff"];
    let h = 0;
    const s = String(id || "");
    for (let i = 0; i < s.length; i++) h = ((h * 31) + s.charCodeAt(i)) & 0x7fffffff;
    return colors[h % colors.length];
  }

  function latestPreview(messages) {
    for (let i = messages.length - 1; i >= 0; i--) {
      const m = messages[i];
      if (!m || (m.type || "") === "thinking") continue;
      const text = String(m.text || "").trim();
      if (text !== "") return text.replace(/\s+/g, " ");
    }
    return "Ready";
  }

  function conversationFromSession(session) {
    const obj = sessionObject(session.id);
    const messages = Array.prototype.slice.call(obj?.messages || []);
    const title = session.name || obj?.sessionName || "Chat";
    const busy = obj?.busy || false;
    return {
      id: session.id,
      section: session.section || "chats",
      title,
      subtitle: busy ? "Working" : latestPreview(messages),
      chatTitle: title,
      avatarText: initials(title),
      avatarColor: avatarColorFor(session.id),
      avatarTextColor: root.dusk,
      icon: "message-chatbot",
      online: obj?.streaming || false,
      snoozed: busy,
      unread: session.unread || 0,
    };
  }

  function visibleConversations() {
    if (root.listMode !== "chats") return [];
    const session = primarySession();
    return session ? [conversationFromSession(session)] : [];
  }

  function conversationById(id) {
    const sessions = rawSessions();
    for (const session of sessions) {
      if (session.id === id) return conversationFromSession(session);
    }
    return null;
  }

  function initials(name) {
    const parts = String(name || "?").split(/[ ,&]+/).filter(p => p.length > 0);
    if (parts.length === 0) return "?";
    if (parts.length === 1) return String(parts[0]).slice(0, 2).toUpperCase();
    return String(parts[0]).slice(0, 1).toUpperCase()
      + String(parts[1]).slice(0, 1).toUpperCase();
  }

  function visibleMessages() {
    const obj = sessionObject(selectedConversationId);
    const messages = Array.prototype.slice.call(obj?.messages || []);
    return messages.map(message => normalizeMessage(message));
  }

  function rememberHistoryRows(sessionId, rows) {
    if (!sessionId || rows.length === 0) return;
    const next = Object.assign({}, _historyCache);
    next[sessionId] = rows.slice();
    _historyCache = next;
  }

  function syncHistoryModel(forceReset) {
    if (!historyModel) return;
    const sessionId = selectedConversationId;
    let rows = root.inChat ? visibleMessages() : [];
    const cached = sessionId ? (_historyCache[sessionId] || []) : [];
    if (root.inChat && rows.length === 0 && cached.length > 0) {
      rows = cached.slice();
    } else if (root.inChat && rows.length > 0) {
      rememberHistoryRows(sessionId, rows);
    }
    let reset = forceReset || historyModel.count > rows.length;

    if (!reset) {
      for (let i = 0; i < Math.min(historyModel.count, rows.length); i++) {
        const current = historyModel.get(i).value || {};
        if (current.id !== rows[i].id) {
          reset = true;
          break;
        }
      }
    }

    if (reset) {
      historyModel.clear();
      for (const row of rows) historyModel.append({ value: row });
      return;
    }

    for (let i = 0; i < rows.length; i++) {
      if (i >= historyModel.count) {
        historyModel.append({ value: rows[i] });
        continue;
      }

      const current = historyModel.get(i).value || {};
      if (JSON.stringify(current) !== JSON.stringify(rows[i])) {
        historyModel.setProperty(i, "value", rows[i]);
      }
    }
  }

  function normalizeMessage(message) {
    const mine = message.from === "me";
    const notification = (message.type || "") === "notification";
    const thinking = (message.type || "") === "thinking";
    const author = mine ? "You" : (notification ? "System" : (root.selectedConversation?.chatTitle || "Pi"));
    return Object.assign({}, message, {
      author,
      time: ago(message.ts),
      avatarText: mine ? "Y" : (notification ? "S" : root.initials(author)),
      avatarColor: mine ? "#dff5e6" : (notification ? root.sleet : root.selectedConversation?.avatarColor || root.sleet),
      avatarTextColor: root.dusk,
      icon: (!mine && !notification && !thinking) ? "message-chatbot" : "",
      online: !mine && (root.selectedSession?.streaming || false),
      mine,
    });
  }

  function submitMessage() {
    const text = inputArea.text.trim();
    if (text.length === 0) return;

    root.selectedSession?.send?.(text);
    inputArea.clear();
    history.scheduleTailScroll(true);
  }

  function attachFiles(paths) {
    const session = root.selectedSession;
    if (!session || !paths) return;

    const selectedPaths = Array.isArray(paths) ? paths : [paths];
    for (const path of selectedPaths) {
      const filePath = String(path || "");
      if (filePath.length > 0) session.sendFile?.(filePath, true);
    }
    history.scheduleTailScroll(true);
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

  component AttachmentMenuAction: Item {
    id: action

    property string icon: ""
    property string label: ""
    signal triggered

    implicitHeight: 36
    implicitWidth: 150
    height: implicitHeight

    Rectangle {
      anchors.fill: parent
      radius: 10
      color: actionMouse.containsMouse ? root.ice : "transparent"
      Behavior on color { ColorAnimation { duration: 80 } }
    }

    NIcon {
      id: actionIcon
      anchors.left: parent.left
      anchors.leftMargin: 10
      anchors.verticalCenter: parent.verticalCenter
      icon: action.icon
      pointSize: 13
      color: root.granite
    }

    Text {
      anchors.left: actionIcon.right
      anchors.leftMargin: 8
      anchors.right: parent.right
      anchors.rightMargin: 10
      anchors.verticalCenter: parent.verticalCenter
      text: action.label
      color: root.dusk
      elide: Text.ElideRight
      font.family: Settings.data.ui.fontDefault
      font.pixelSize: 13
      font.weight: 600
    }

    MouseArea {
      id: actionMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: action.triggered()
    }
  }

  component KinMessageRow: Item {
    id: row

    property var message
    readonly property bool isConfirm: (row.message.type || "") === "confirm"
    readonly property bool isPrompt: (row.message.type || "") === "prompt"
    readonly property bool isNotice: (row.message.type || "") === "notification"
    readonly property bool isThinking: (row.message.type || "") === "thinking"
    signal confirmRequested(bool confirmed)
    signal promptSubmit(string value)
    signal promptCancel

    implicitHeight: row.isConfirm
      ? confirmCard.implicitHeight
      : row.isPrompt
        ? promptCard.implicitHeight
        : Math.max(52, body.y + body.implicitHeight + 8)

    Avatar {
      id: messageAvatar
      visible: !row.isConfirm && !row.isPrompt
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
      visible: !row.isConfirm && !row.isPrompt
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
      visible: !row.isConfirm && !row.isPrompt
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
      visible: !row.isConfirm && !row.isPrompt
      anchors.left: author.left
      anchors.right: parent.right
      anchors.rightMargin: 4
      y: 25
      text: row.isThinking && !(row.message.text || "") ? "thinking..." : (row.message.text || "")
      color: row.isNotice || row.isThinking ? root.muted : root.ink
      wrapMode: Text.Wrap
      lineHeight: 20
      lineHeightMode: Text.FixedHeight
      font.family: Settings.data.ui.fontDefault
      font.pixelSize: 14
      font.weight: 400
      font.italic: row.isThinking
      horizontalAlignment: row.isNotice ? Text.AlignHCenter : Text.AlignLeft
    }

    Rectangle {
      id: confirmCard
      visible: row.isConfirm
      anchors.left: parent.left
      anchors.right: parent.right
      radius: 12
      color: Qt.rgba(1, 1, 1, 0.9)
      border.color: root.dust
      border.width: 1
      implicitHeight: confirmCol.implicitHeight + 20

      Column {
        id: confirmCol
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 10
        spacing: 8

        Text {
          width: parent.width
          text: row.message.confirmTitle || "Confirm action"
          color: root.dusk
          wrapMode: Text.Wrap
          font.family: Settings.data.ui.fontDefault
          font.pixelSize: 13
          font.weight: 700
        }

        Text {
          width: parent.width
          text: row.message.text || ""
          color: root.ink
          wrapMode: Text.Wrap
          font.family: Settings.data.ui.fontFixed || Settings.data.ui.fontDefault
          font.pixelSize: 12
        }

        Row {
          anchors.right: parent.right
          spacing: 8
          visible: (row.message.confirmState || "pending") === "pending"

          NButton {
            text: "Deny"
            bgColor: root.sleet
            fgColor: root.dusk
            onClicked: row.confirmRequested(false)
          }

          NButton {
            text: "Allow"
            onClicked: row.confirmRequested(true)
          }
        }

        Text {
          anchors.right: parent.right
          visible: row.message.confirmState === "allowed" || row.message.confirmState === "denied"
          text: row.message.confirmState === "allowed" ? "Allowed" : "Denied"
          color: row.message.confirmState === "allowed" ? root.matcha : root.warning
          font.family: Settings.data.ui.fontDefault
          font.pixelSize: 12
          font.weight: 700
        }
      }
    }

    Rectangle {
      id: promptCard
      visible: row.isPrompt
      anchors.left: parent.left
      anchors.right: parent.right
      radius: 12
      color: Qt.rgba(1, 1, 1, 0.9)
      border.color: root.dust
      border.width: 1
      implicitHeight: promptCol.implicitHeight + 20

      Column {
        id: promptCol
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 10
        spacing: 8

        Text {
          width: parent.width
          text: row.message.promptSkill
            ? row.message.promptSkill + " · " + (row.message.promptField || "input")
            : "Input required"
          color: root.dusk
          wrapMode: Text.Wrap
          font.family: Settings.data.ui.fontDefault
          font.pixelSize: 13
          font.weight: 700
        }

        Text {
          width: parent.width
          text: row.message.text || ""
          color: root.ink
          wrapMode: Text.Wrap
          font.family: Settings.data.ui.fontDefault
          font.pixelSize: 12
        }

        TextField {
          id: promptInput
          visible: (row.message.promptState || "pending") === "pending"
          width: parent.width
          echoMode: row.message.promptSecret ? TextInput.Password : TextInput.Normal
          placeholderText: row.message.promptSecret ? "Enter secret value" : "Enter value"
          font.family: Settings.data.ui.fontDefault
          font.pixelSize: 12
          onAccepted: if (text.length > 0) row.promptSubmit(text)
        }

        Row {
          anchors.right: parent.right
          spacing: 8
          visible: (row.message.promptState || "pending") === "pending"

          NButton {
            text: "Cancel"
            bgColor: root.sleet
            fgColor: root.dusk
            onClicked: row.promptCancel()
          }

          NButton {
            text: "Submit"
            enabled: promptInput.text.length > 0
            onClicked: row.promptSubmit(promptInput.text)
          }
        }

        Text {
          anchors.right: parent.right
          visible: (row.message.promptState || "pending") !== "pending"
          text: row.message.promptState || ""
          color: root.muted
          font.family: Settings.data.ui.fontDefault
          font.pixelSize: 12
          font.weight: 700
        }
      }
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
            const primary = root.primarySession();
            const id = primary ? primary.id : root.backend?.newSession?.("arlo");
            if (id) root.openConversation(id);
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
          anchors.left: backButton.right
          anchors.right: searchButton.left
          anchors.leftMargin: 8
          anchors.rightMargin: 8
          anchors.verticalCenter: parent.verticalCenter
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
          id: infoButton
          anchors.right: parent.right
          anchors.rightMargin: 8
          anchors.verticalCenter: parent.verticalCenter
          icon: "info-circle"
          tooltipText: "Info"
          baseSize: 24
          colorBg: root.ice
          colorBgHover: root.sleet
          colorFg: root.granite
          colorFgHover: root.dusk
          colorBorder: "transparent"
        }

        NIconButton {
          id: searchButton
          anchors.right: infoButton.left
          anchors.rightMargin: 6
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

      ListModel {
        id: historyModel
        dynamicRoles: true
      }

      ListView {
        id: history
        objectName: "chatHistory"
        property bool followTail: true
        property bool userInteracting: false
        property real _lastContentHeight: 0
        readonly property real tailSlack: 32

        function isAtTail(contentHeightToCheck) {
          const h = contentHeightToCheck === undefined ? contentHeight : contentHeightToCheck;
          return h <= height || contentY >= Math.max(0, h - height - tailSlack);
        }

        function scheduleTailScroll(force) {
          if (force) followTail = true;
          if (!root.inChat || !followTail || userInteracting) return;
          tailScrollTimer.remainingPasses = 3;
          tailScrollTimer.restart();
        }

        function beginUserScroll() {
          userInteracting = true;
          tailScrollTimer.stop();
        }

        function finishUserScroll() {
          if (moving || flicking) return;
          userInteracting = false;
          followTail = isAtTail();
          scheduleTailScroll();
        }

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: nav.bottom
        anchors.topMargin: 20
        anchors.bottom: composer.top
        anchors.bottomMargin: 16
        anchors.leftMargin: 24
        anchors.rightMargin: 18
        model: historyModel
        clip: true
        spacing: 8
        interactive: contentHeight > height
        Component.onCompleted: {
          root.syncHistoryModel(true);
          _lastContentHeight = contentHeight;
          scheduleTailScroll(true);
        }

        onMovementStarted: beginUserScroll()
        onMovementEnded: finishUserScroll()
        onFlickStarted: beginUserScroll()
        onFlickEnded: finishUserScroll()
        onContentHeightChanged: {
          const wasAtTail = followTail || isAtTail(_lastContentHeight);
          _lastContentHeight = contentHeight;
          if (wasAtTail) scheduleTailScroll(true);
        }
        onHeightChanged: scheduleTailScroll()
        onCountChanged: scheduleTailScroll()

        Timer {
          id: tailScrollTimer
          property int remainingPasses: 0

          interval: 16
          repeat: false
          onTriggered: {
            if (!root.inChat || !history.followTail || history.userInteracting) return;

            history.positionViewAtEnd();
            if (remainingPasses > 0) {
              remainingPasses--;
              restart();
            }
          }
        }

        Connections {
          target: root.selectedSession
          ignoreUnknownSignals: true

          function onMessagesChanged() {
            const wasAtTail = history.followTail || history.isAtTail(history._lastContentHeight);
            root.syncHistoryModel();
            if (wasAtTail) history.scheduleTailScroll(true);
          }
        }

        delegate: KinMessageRow {
          required property var value

          width: history.width
          message: value
          onConfirmRequested: confirmed => root.selectedSession?.confirmRespond?.(value.id, confirmed)
          onPromptSubmit: response => root.selectedSession?.promptRespond?.(value.id, response)
          onPromptCancel: root.selectedSession?.promptCancel?.(value.id)
        }
      }

      Item {
        id: composer
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 0
        height: 60
        property bool attachmentMenuOpen: false

        NFilePicker {
          id: attachmentPicker
          title: "Attach files"
          selectionMode: "files"
          allowMultiSelection: true
          nameFilters: ["*"]
          onAccepted: paths => root.attachFiles(paths)
          onCancelled: composer.attachmentMenuOpen = false
        }

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
          onClicked: composer.attachmentMenuOpen = !composer.attachmentMenuOpen
        }

        Rectangle {
          id: attachmentMenuShadow
          visible: composer.attachmentMenuOpen
          x: attachmentMenu.x
          y: attachmentMenu.y
          width: attachmentMenu.width
          height: attachmentMenu.height
          radius: attachmentMenu.radius
          color: root.navColor
          opacity: 0.01
          z: 19
          layer.enabled: visible
          layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Qt.rgba(0, 0, 0, 0.14)
            shadowBlur: 0.8
            shadowVerticalOffset: 4
            shadowHorizontalOffset: 0
          }
        }

        Rectangle {
          id: attachmentMenu
          visible: composer.attachmentMenuOpen
          anchors.left: addButton.left
          anchors.bottom: addButton.top
          anchors.bottomMargin: 8
          width: 156
          height: attachmentMenuColumn.implicitHeight + 12
          radius: 14
          color: root.navColor
          border.color: root.dust
          border.width: 1
          z: 20

          Column {
            id: attachmentMenuColumn
            anchors.fill: parent
            anchors.margins: 6
            spacing: 2

            AttachmentMenuAction {
              width: parent.width
              icon: "paperclip"
              label: "Files"
              onTriggered: {
                composer.attachmentMenuOpen = false;
                attachmentPicker.openFilePicker();
              }
            }
          }
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
            icon: inputArea.text.trim().length > 0 ? "send" : "microphone"
            tooltipText: inputArea.text.trim().length > 0 ? "Send" : "Voice"
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
          visible: root.selectedSession?.typing || false
          text: (root.selectedConversation?.chatTitle || "Pi") + " is typing"
          color: root.muted
          font.family: Settings.data.ui.fontDefault
          font.pixelSize: 10
          font.weight: 400
        }
      }
    }

    Rectangle {
      id: signalConfirmBanner
      objectName: "signalConfirmBanner"
      readonly property var items: (root.backend?.signalPendingSends) || []

      visible: items.length > 0
      z: 40
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: 12
      height: visible ? Math.min(signalConfirmCol.implicitHeight + 20, parent.height - 24) : 0
      radius: 14
      color: Qt.rgba(1, 1, 1, 0.96)
      border.color: root.dust
      border.width: 1

      Column {
        id: signalConfirmCol
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 10
        spacing: 10

        Repeater {
          model: signalConfirmBanner.items

          delegate: Column {
            id: signalDelegate
            required property var modelData

            width: signalConfirmCol.width
            spacing: 8

            readonly property string recipientLabel: {
              const dn = signalDelegate.modelData.display_name || "";
              const rc = signalDelegate.modelData.recipient || "?";
              return (dn === "" || dn === rc) ? rc : (dn + " <" + rc + ">");
            }

            Text {
              width: parent.width
              text: "Pending Signal send to " + signalDelegate.recipientLabel + ":"
              color: root.dusk
              wrapMode: Text.Wrap
              font.family: Settings.data.ui.fontDefault
              font.pixelSize: 13
              font.weight: 700
            }

            Text {
              width: parent.width
              text: signalDelegate.modelData.body || ""
              color: root.ink
              wrapMode: Text.Wrap
              maximumLineCount: 8
              elide: Text.ElideRight
              font.family: Settings.data.ui.fontDefault
              font.pixelSize: 12
            }

            Row {
              anchors.right: parent.right
              spacing: 8

              NButton {
                text: "Cancel"
                bgColor: root.sleet
                fgColor: root.dusk
                onClicked: root.backend?.signalDeny?.(signalDelegate.modelData.token)
              }

              NButton {
                text: "Send"
                onClicked: root.backend?.signalApprove?.(signalDelegate.modelData.token)
              }
            }
          }
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

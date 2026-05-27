import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Widgets
import "MsgText.js" as Txt
import "MsgFilter.js" as MsgFilter

Item {
  id: root

  // Set by shell.qml. The Panel never reaches around `backend` for
  // anything noctalia used to mediate via `pluginApi.mainInstance`.
  property var backend: null
  property var chat: backend?.chat || null

  // Daemon pushes this in the status event — single source of truth is
  // the hm-module's displayName option, not a separate plugin setting.
  readonly property string peerName: chat?.peerName || tr("panel.default-peer-name")

  // UI-only "hide thinking bubbles" toggle. Persisted in our own
  // settings.json (Commons.Settings) so it survives across launches.
  // Flipping it never mutates session.messages; restoring it brings
  // every previously hidden bubble back in place.
  readonly property bool showThinking: Settings.data.showThinking

  function tr(key, args) {
    return I18n.tr(key, args);
  }

  // Look up a message by id to render the quoted snippet above a
  // threaded reply. Linear scan is fine — maxHistory caps it at ~200.
  function findMsg(id) {
    const arr = chat?.messages || [];
    for (let i = arr.length - 1; i >= 0; i--)
      if (arr[i].id === id) return arr[i];
    return null;
  }


  // SmartPanel.qml sizes by contentPreferred{Width,Height} — without
  // these it falls back to its 900px default, ignoring implicitHeight.
  property real contentPreferredWidth: 1000
  property real contentPreferredHeight: 800
  implicitWidth: contentPreferredWidth
  implicitHeight: contentPreferredHeight

  // Relative-time formatter for the tiny timestamp under each bubble.
  // Absolute times would be noise for a chat that's mostly "just now".
  // `_now` ticks every 30s so `ago()` bindings re-evaluate — otherwise
  // "now" freezes at send time and never becomes "1m".
  property real _now: Date.now()
  // Voice input via voxtype. Toggle-style: click starts recording,
  // click again stops + transcribes into the focused input. We track
  // state locally — same command the Mod+Space keybind invokes — so
  // the button color reflects what we asked for. Out-of-band toggles
  // from the keyboard will drift, but that's a rare edge case.
  property bool voiceRecording: false
  Timer { interval: 30000; running: root.visible; repeat: true; onTriggered: root._now = Date.now() }

  function ago(ts) {
    const s = Math.max(0, (_now - ts) / 1000);
    if (s < 60)   return tr("panel.time-now");
    if (s < 3600) return Math.floor(s/60) + "m";
    if (s < 86400) return Math.floor(s/3600) + "h";
    return Qt.formatDateTime(new Date(ts), "ddd HH:mm");
  }

  ColumnLayout {
    anchors.fill: parent
    anchors.margins: Style.marginL
    spacing: Style.marginM

    // ── Session tabs ───────────────────────────────────────────────
    // Session tabs are populated by PiChatBackend; if the list
    // is empty the row collapses to zero height.
    Item {
      id: sessionTabsHost
      Layout.fillWidth: true
      visible: sessionTabsRow.count > 0
      implicitHeight: visible ? Style.baseWidgetSize : 0

      readonly property var sessions: root.backend?.sessionsList || []
      readonly property string active: root.backend?.activeSessionId || ""

      RowLayout {
        anchors.fill: parent
        spacing: Style.marginXS

        NIconButton {
          icon: "plus"
          tooltipText: root.tr("panel.new-session-tooltip")
          baseSize: Style.baseWidgetSize * 0.85
          onClicked: root.backend?.newSession?.()
        }

        ListView {
          id: sessionTabsRow
          Layout.fillWidth: true
          Layout.fillHeight: true
          orientation: ListView.Horizontal
          spacing: Style.marginXS
          clip: true
          interactive: contentWidth > width
          model: sessionTabsHost.sessions

          delegate: Rectangle {
            readonly property bool isActive: modelData.id === sessionTabsHost.active
            readonly property int unread: modelData.unread || 0
            height: ListView.view.height
            width: tabLabel.implicitWidth + Style.marginM * 2
            radius: Style.radiusS
            color: isActive ? Color.mPrimary : Color.mSurfaceVariant
            border.width: isActive ? 0 : 1
            border.color: Color.mOutline
            TapHandler {
              onTapped: root.backend?.selectSession?.(modelData.id)
              onLongPressed: root.backend?.removeSession?.(modelData.id)
            }
            HoverHandler { cursorShape: Qt.PointingHandCursor }
            NText {
              id: tabLabel
              anchors.centerIn: parent
              text: (modelData.name || "chat") + (unread > 0 ? "  •" : "")
              color: parent.isActive ? Color.mOnPrimary : Color.mOnSurface
              pointSize: Style.fontSizeS
              font.bold: parent.isActive
            }
          }
        }
      }
    }

    // ── Header ────────────────────────────────────────────────────────
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.marginS

      NIcon {
        icon: "message-chatbot"
        pointSize: Style.fontSizeXL * 1.4
        color: Color.mPrimary
      }
      ColumnLayout {
        spacing: 0
        Layout.fillWidth: true
        NText {
          text: root.peerName
          pointSize: Style.fontSizeL
          font.bold: true
        }
        NText {
          text: (chat !== null && chat.typing)
            ? "thinking…"
            : chat?.streaming
              ? "ready"
              : root.tr("panel.status-offline")
          pointSize: Style.fontSizeXS
          color: Color.mOnSurfaceVariant
        }
      }
      // Model selector. PiChatBackend exposes the llama-swap-discovered list.
      NComboBox {
        id: modelCombo
        Layout.alignment: Qt.AlignVCenter
        minimumWidth: 420
        popupHeight: 420
        baseSize: 0.85
        tooltip: root.tr("panel.models-tooltip")
        // NComboBox expects [{key, name}]. We use "<provider>/<id>" as the
        // stable key and name for now — pi doesn't expose a separate display
        // name for models, just provider+id.
        model: (chat?.models ?? []).map(m => ({
          key: m.provider + "/" + m.id,
          name: m.id + (m.reasoning ? "  ⚡" : ""),
          provider: m.provider,
          modelId: m.id,
        }))
        currentKey: chat?.activeModel ?? ""
        onSelected: key => {
          const item = (chat?.models ?? []).find(m => (m.provider + "/" + m.id) === key);
          if (item) chat.setModel(item.provider, item.id);
        }
      }
      NIconButton {
        icon: "search"
        tooltipText: root.tr("panel.search-tooltip")
        baseSize: Style.baseWidgetSize * 0.9
        onClicked: { searchBar.visible = !searchBar.visible; if (searchBar.visible) searchField.forceActiveFocus(); }
      }
      NIconButton {
        icon: root.showThinking ? "eye" : "eye-off"
        tooltipText: root.showThinking
          ? root.tr("panel.thinking-hide-tooltip")
          : root.tr("panel.thinking-show-tooltip")
        baseSize: Style.baseWidgetSize * 0.9
        // Flip the persisted setting in-place. root.showThinking
        // re-binds against Settings.data and the ListView's
        // MsgFilter binding recomputes immediately.
        onClicked: { Settings.data.showThinking = !Settings.data.showThinking; Settings.persist(); }
      }
      // Per-session long-term-memory toggle. The active session owns
      // the bool; the backend persists, writes the marker file the
      // pi extension reads, and reflects back through chat.memoryEnabled.
      NIconButton {
        icon: (chat?.memoryEnabled ?? true) ? "brain" : "database-off"
        tooltipText: (chat?.memoryEnabled ?? true)
          ? root.tr("panel.memory-on-tooltip")
          : root.tr("panel.memory-off-tooltip")
        baseSize: Style.baseWidgetSize * 0.9
        onClicked: {
          const id = root.backend?.activeSessionId;
          if (!id) return;
          root.backend.setSessionMemoryEnabled(id, !(chat?.memoryEnabled ?? true));
        }
      }
      // Wipe every stored memory item across all sessions. Destructive
      // and irreversible, so the click only opens the confirm row
      // below the header — the actual rm runs from the "Wipe" button
      // there.
      NIconButton {
        icon: "eraser"
        tooltipText: root.tr("panel.memory-wipe-tooltip")
        baseSize: Style.baseWidgetSize * 0.9
        onClicked: wipeConfirmBar.visible = true
      }
      NIconButton {
        icon: "rotate"
        tooltipText: root.tr("panel.reset-tooltip")
        baseSize: Style.baseWidgetSize * 0.9
        // chat.restart() clears the local bubble list and issues
        // { type: "new_session" } to pi, which swaps in a fresh
        // session in-place — same RPC process, empty history. The
        // local clear keeps the panel from flashing stale bubbles
        // while pi sets up the new session.
        onClicked: {
          if (!chat) return;
          chat.restart();
        }
      }
      Rectangle {
        id: relayDot
        implicitWidth: 8; implicitHeight: 8; radius: 4
        color: chat?.streaming ? Color.mTertiary : Color.mError
      }
    }

    // Inline confirm strip for "Wipe all memory". Renders only when
    // the user clicked the eraser button; closes itself on either
    // confirm or cancel. We do not stop running pi sessions before
    // the rm — the next sediment call will recreate an empty DB layout.
    RowLayout {
      id: wipeConfirmBar
      visible: false
      Layout.fillWidth: true
      spacing: Style.marginS
      NText {
        Layout.fillWidth: true
        text: root.tr("panel.memory-wipe-confirm")
        pointSize: Style.fontSizeS
        color: Color.mError
        wrapMode: Text.Wrap
      }
      NIconButton {
        icon: "check"
        tooltipText: root.tr("panel.memory-wipe-yes")
        baseSize: Style.baseWidgetSize * 0.85
        onClicked: {
          root.backend?.wipeMemory?.();
          wipeConfirmBar.visible = false;
        }
      }
      NIconButton {
        icon: "x"
        tooltipText: root.tr("panel.memory-wipe-no")
        baseSize: Style.baseWidgetSize * 0.85
        onClicked: wipeConfirmBar.visible = false
      }
    }

    // ── Search ────────────────────────────────────────────────────────────
    // Case-insensitive substring match over the in-memory mirror.
    // hits[] indexes history.model (already newest-first), cursor walks
    // them. Closing clears the query so bubbles drop the outline.
    RowLayout {
      id: searchBar
      visible: false
      Layout.fillWidth: true
      spacing: Style.marginS

      // Store message IDs, not model indices — the reversed model
      // shifts by one every time a message arrives, which would point
      // every cached index at the wrong bubble.
      property var hits: []      // [id, id, …] newest-first
      property string current: ""
      readonly property string query: searchField.text.toLowerCase()
      onVisibleChanged: if (!visible) { searchField.text = ""; history.contentY = 0; }

      function refresh() {
        if (!query) { hits = []; current = ""; return; }
        const out = [];
        for (const m of history.model)
          if ((m.text || "").toLowerCase().includes(query)) out.push(m.id);
        hits = out;
        current = out[0] || "";
        jump();
      }
      function step(d) {
        if (!hits.length) return;
        const i = Math.max(0, hits.indexOf(current));
        current = hits[(i + d + hits.length) % hits.length];
        jump();
      }
      function jump() {
        if (!current) return;
        const i = history.model.findIndex(m => m.id === current);
        if (i >= 0) history.positionViewAtIndex(i, ListView.Center);
      }
      // Re-scan when messages arrive mid-search so the counter stays
      // honest. current is an ID so the cursor survives the refresh.
      readonly property int _watch: history.count
      on_WatchChanged: if (visible && query) {
        const keep = current;
        refresh();
        if (hits.includes(keep)) { current = keep; jump(); }
      }

      NTextInput {
        id: searchField
        Layout.fillWidth: true
        placeholderText: root.tr("panel.search-placeholder")
        inputItem.onTextChanged: searchBar.refresh()
        inputItem.Keys.onReturnPressed: e => searchBar.step(e.modifiers & Qt.ShiftModifier ? -1 : 1)
        inputItem.Keys.onEscapePressed: searchBar.visible = false
        function forceActiveFocus() { inputItem.forceActiveFocus(); }
      }
      NText {
        text: searchBar.hits.length
          ? (searchBar.hits.indexOf(searchBar.current) + 1) + "/" + searchBar.hits.length
          : (searchField.text ? "0" : "")
        color: Color.mOnSurfaceVariant
        pointSize: Style.fontSizeS
      }
      NIconButton { icon: "chevron-up";   baseSize: Style.baseWidgetSize * 0.8; onClicked: searchBar.step(1) }
      NIconButton { icon: "chevron-down"; baseSize: Style.baseWidgetSize * 0.8; onClicked: searchBar.step(-1) }
      NIconButton { icon: "x";            baseSize: Style.baseWidgetSize * 0.8; onClicked: searchBar.visible = false }
    }

    NDivider { Layout.fillWidth: true }

    // Asymmetry hint: when the panel comes up empty but the daemon is
    // already running, the underlying pi process likely has prior turns
    // in its context window — typing here continues that conversation
    // rather than starting a new one. Plugin can't reliably distinguish
    // a truly fresh daemon from a long-running one without a daemon-side
    // signal, so this also surfaces on first-ever startup; the cost of
    // that false positive (one extra line until the user sends anything)
    // is lower than the cost of silently appending to a hidden history.
    NText {
      visible: chat?.streaming && (chat?.messages?.length ?? 0) === 0
      Layout.fillWidth: true
      text: root.tr("panel.context-hint")
      color: Color.mOnSurfaceVariant
      pointSize: Style.fontSizeXS
      wrapMode: Text.Wrap
      font.italic: true
    }

    // ── Pending Signal-send approvals (out-of-band channel) ──────────
    // The bridge runs outside the pi-chat sandbox; the agent can
    // enqueue but only the human (here) can mint approvals. Cards
    // sit ABOVE the history pane so the user can never miss one
    // while looking at the chat.
    Rectangle {
      id: signalConfirmBanner
      readonly property var items: (root.chat?.signalPendingSends) || []
      Layout.fillWidth: true
      visible: items.length > 0
      implicitHeight: visible ? signalConfirmCol.implicitHeight + Style.marginS * 2 : 0
      color: Color.mSurfaceVariant
      radius: Style.radiusS
      border.color: Color.mPrimary
      border.width: 1

      ColumnLayout {
        id: signalConfirmCol
        anchors.fill: parent
        anchors.margins: Style.marginS
        spacing: Style.marginS
        Repeater {
          model: signalConfirmBanner.items
          delegate: RowLayout {
            Layout.fillWidth: true
            spacing: Style.marginS
            ColumnLayout {
              Layout.fillWidth: true
              spacing: 0
              NText {
                Layout.fillWidth: true
                text: root.tr("panel.signal-pending-prefix", { to: (modelData.display_name || modelData.recipient || "?") })
                pointSize: Style.fontSizeS
                font.bold: true
                wrapMode: Text.Wrap
              }
              NText {
                Layout.fillWidth: true
                text: modelData.body || ""
                pointSize: Style.fontSizeXS
                wrapMode: Text.Wrap
                maximumLineCount: 4
                elide: Text.ElideRight
              }
            }
            NButton {
              text: root.tr("panel.signal-approve")
              onClicked: root.chat?.signalApprove(modelData.token)
            }
            NButton {
              text: root.tr("panel.signal-deny")
              onClicked: root.chat?.signalDeny(modelData.token)
            }
          }
        }
      }
    }

    // ── History ───────────────────────────────────────────────────────
    // Wrapped so the "new messages" pill can float over the list
    // without joining the ColumnLayout flow.
    Item {
      Layout.fillWidth: true
      Layout.fillHeight: true
    NListView {
      id: history
      anchors.fill: parent
      // BottomToTop + reversed model: index 0 = newest = visual bottom.
      // This makes "stay at bottom" equivalent to contentY≈0, which
      // ListView preserves across our array-reassignment updates
      // without any positionViewAtEnd() gymnastics. Scrolling up
      // increases contentY into history as usual.
      verticalLayoutDirection: ListView.BottomToTop
      model: MsgFilter.visible(chat?.messages ?? [], root.showThinking).slice().reverse()
      clip: true
      // "Near bottom" = within two bubble-heights of contentY 0.
      readonly property bool atBottom: contentY < Style.baseWidgetSize * 2
      property int unseen: 0
      onAtBottomChanged: if (atBottom) unseen = 0
      spacing: Style.marginM
      // NListView's custom WheelHandler clamps contentY assuming
      // originY==0, which breaks once our reassigned-array model shifts
      // originY. 1.0 disables it and falls back to Qt's own scrolling.
      wheelScrollMultiplier: 1.0
      // The gradient fade looks wrong over chat bubbles — it's meant for
      // flat lists. Bubbles already provide their own visual boundary.
      showGradientMasks: false

      // ListView injects modelData into the delegate root; Bubble
      // declares that as required and aliases it to msg internally.
      delegate: Bubble {
        width: history.availableWidth
        searchQuery: searchBar.visible ? searchBar.query : ""
        searchCurrent: searchBar.current === modelData.id
        quotedText: root.findMsg(modelData.replyTo)?.text ?? ""
        ago: root.ago
        tr: root.tr

        onReplyRequested: {
          chat.replyTarget = { id: modelData.id, text: modelData.text };
          input.forceActiveFocus();
        }
        onJumpToQuote: {
          const i = history.model.findIndex(m => m.id === modelData.replyTo);
          if (i >= 0) history.positionViewAtIndex(i, ListView.Center);
        }
        onRetryRequested:  chat.retry(modelData.id)
        onCancelRequested: chat.cancel(modelData.id)
        onConfirmRequested: confirmed => chat.confirmRespond(modelData.id, confirmed)
        onPromptSubmit: value => chat.promptRespond(modelData.id, value)
        onPromptCancel: chat.promptCancel(modelData.id)
      }

      // BottomToTop keeps contentY stable on append, so the only
      // bookkeeping left is the unread pill. Our own sends always
      // snap — not seeing your message appear is worse than losing
      // scrollback. The first non-empty population after open is
      // also a snap: history replay arrives after Component.onCompleted,
      // and landing mid-scroll on a fresh open is jarring.
      property int _lastCount: 0
      property bool _initialized: false
      onModelChanged: {
        if (count === 0) return;
        if (!_initialized) {
          _initialized = true;
          _lastCount = count;
          contentY = 0;
          positionViewAtBeginning();
          return;
        }
        if (count <= _lastCount) { _lastCount = count; return; }
        _lastCount = count;
        if (model[0]?.from === "me") contentY = 0;
        else if (!atBottom) unseen++;
      }
    }

    // Floating "N new ↓" pill. Appears only when scrolled up and
    // messages arrived; tapping it jumps to the end and clears itself
    // via the atBottom watcher.
    Rectangle {
      visible: history.unseen > 0
      anchors.bottom: parent.bottom
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottomMargin: Style.marginM
      radius: height / 2
      color: Color.mPrimary
      implicitWidth: pillRow.implicitWidth + Style.marginL * 2
      implicitHeight: pillRow.implicitHeight + Style.marginS * 2
      RowLayout {
        id: pillRow
        anchors.centerIn: parent
        spacing: Style.marginXS
        NText {
          text: root.tr("panel.new-messages", { count: history.unseen })
          color: Color.mOnPrimary
          pointSize: Style.fontSizeS
          font.bold: true
        }
        NIcon { icon: "chevron-down"; color: Color.mOnPrimary }
      }
      TapHandler { onTapped: history.contentY = 0 }
      HoverHandler { cursorShape: Qt.PointingHandCursor }
    }
    } // history wrapper

    // ── Compose ───────────────────────────────────────────────────────
    // Reply context bar — shown when a bubble was tapped. Cleared on
    // send (Main.qml) or by the × here.
    Rectangle {
      visible: (chat?.replyTarget ?? null) !== null
      Layout.fillWidth: true
      implicitHeight: replyRow.implicitHeight + Style.marginS * 2
      radius: Style.radiusS
      color: Color.mSurfaceVariant
      RowLayout {
        id: replyRow
        anchors.fill: parent
        anchors.margins: Style.marginS
        spacing: Style.marginS
        NIcon { icon: "corner-down-right"; color: Color.mPrimary }
        NText {
          Layout.fillWidth: true
          text: Txt.snippet(chat?.replyTarget?.text ?? "", 80)
          elide: Text.ElideRight
          pointSize: Style.fontSizeS
          color: Color.mOnSurfaceVariant
        }
        NIconButton {
          icon: "x"
          baseSize: Style.baseWidgetSize * 0.7
          onClicked: chat.replyTarget = null
        }
      }
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.marginS

      // Custom multiline compose box — NTextInput wraps a single-line
      // TextField, but AI chat messages routinely carry code snippets and
      // pasted logs. TextArea gives us newlines; we intercept Return
      // so plain Enter still sends (chat-app convention) while
      // Shift+Enter inserts a break.
      Control {
        id: input
        Layout.fillWidth: true
        // Grow with content up to ~5 lines, then scroll. Min matches
        // the icon buttons so the row stays aligned when empty.
        // TextArea.implicitHeight already includes its own padding.
        Layout.preferredHeight: Math.min(
          Math.max(inputArea.implicitHeight,
                   Style.baseWidgetSize * 1.1 * Style.uiScaleRatio),
          Style.baseWidgetSize * 4 * Style.uiScaleRatio)

        property alias text: inputArea.text
        signal accepted

        function forceActiveFocus() { inputArea.forceActiveFocus(); }

        onAccepted: {
          if (!chat) return;
          // Send regardless of streaming state — the daemon's outbox
          // queues it and retries when relays come back.
          chat.send(inputArea.text);
          inputArea.clear();
        }

        background: Rectangle {
          radius: Style.iRadiusM
          color: Color.mSurface
          border.color: inputArea.activeFocus ? Color.mSecondary : Color.mOutline
          border.width: Style.borderS
          Behavior on border.color { ColorAnimation { duration: Style.animationFast } }
        }

        contentItem: ScrollView {
          clip: true
          ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
          TextArea {
            id: inputArea
            placeholderText: chat?.streaming ? root.tr("panel.compose-placeholder", { name: root.peerName }) : root.tr("panel.compose-waiting")
            placeholderTextColor: Qt.alpha(Color.mOnSurfaceVariant, 0.6)
            color: Color.mOnSurface
            wrapMode: TextEdit.Wrap
            selectByMouse: true
            background: null
            topPadding: Style.marginS
            bottomPadding: Style.marginS
            leftPadding: Style.marginM
            rightPadding: Style.marginM
            font.family: Settings.data.ui.fontDefault
            font.pointSize: Style.fontSizeS * Style.uiScaleRatio

            // Esc clears the reply target without reaching for the ×.
            Keys.onEscapePressed: if (chat?.replyTarget) chat.replyTarget = null

            // Ctrl+V: if the clipboard holds an image, dump it to
            // $XDG_RUNTIME_DIR and hand the path to the daemon with
            // unlink=true (same path as the screenshot keybind). Text
            // falls through to TextArea's own paste. canPaste reflects
            // text/plain availability, so it doubles as the "is this
            // an image?" probe without a wl-paste roundtrip.
            Keys.onPressed: e => {
              if (e.matches(StandardKey.Paste) && !canPaste) {
                e.accepted = true;
                pasteImage.running = true;
                return;
              }
              handleReturn(e);
            }

            // Enter sends, Shift+Enter newlines. Split out so the
            // paste interceptor above can share Keys.onPressed.
            function handleReturn(event) {
              if (event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter) return;
              if ((event.modifiers & Qt.ShiftModifier)
                  && !(event.modifiers & Qt.ControlModifier)) {
                event.accepted = false;  // Shift+Enter → newline
              } else {
                event.accepted = true;
                if (text.trim().length > 0) input.accepted();
              }
            }
          }
        }
      }
      // Voice-to-text. Mirrors the Mod+Space shortcut. Refocus the
      // input area before spawning so voxtype's typed output lands in
      // the compose box rather than whatever stole focus on click.
      NIconButton {
        id: voiceButton
        icon: root.voiceRecording ? "microphone-mute" : "microphone"
        tooltipText: root.voiceRecording
          ? root.tr("panel.voice-stop-tooltip")
          : root.tr("panel.voice-tooltip")
        baseSize: Style.baseWidgetSize * 1.1 * Style.uiScaleRatio
        Layout.alignment: Qt.AlignBottom
        colorBg: root.voiceRecording ? Color.mError : Color.smartAlpha(Color.mSurfaceVariant)
        colorFg: root.voiceRecording ? Color.mOnError : Color.mPrimary
        colorBgHover: root.voiceRecording ? Color.mError : Color.mHover
        colorFgHover: root.voiceRecording ? Color.mOnError : Color.mOnHover
        onClicked: {
          inputArea.forceActiveFocus();
          voxtypeProcess.running = true;
          root.voiceRecording = !root.voiceRecording;
        }
      }
      NIconButton {
        icon: "paperclip"
        tooltipText: root.tr("panel.attach-image-tooltip")
        // Fixed size + bottom-align — the input now grows with
        // multiline content and we don't want 4×-tall buttons.
        baseSize: Style.baseWidgetSize * 1.1 * Style.uiScaleRatio
        Layout.alignment: Qt.AlignBottom
        onClicked: filePicker.openFilePicker()
      }
      NIconButton {
        icon: "send"
        baseSize: Style.baseWidgetSize * 1.1 * Style.uiScaleRatio
        Layout.alignment: Qt.AlignBottom
        enabled: input.text.trim().length > 0
        onClicked: input.accepted()
      }
    }

    Process {
      id: voxtypeProcess
      command: ["voxtype", "record", "toggle"]
    }

    // Noctalia's in-panel Popup file picker — QtQuick.Dialogs.FileDialog
    // spawns a regular toplevel that layer-shell either occludes or
    // orphans. This one renders inside the panel overlay.
    NFilePicker {
      id: filePicker
      title: root.tr("panel.attach-image-title")
      selectionMode: "files"
      nameFilters: ["*.png", "*.jpg", "*.jpeg", "*.gif", "*.webp"]
      initialPath: Quickshell.env("HOME") + "/Pictures"
      onAccepted: paths => { if (paths.length > 0) chat?.sendFile(paths[0]); }
    }

    Process {
      id: pasteImage
      property string tmp: ""
      command: ["sh", "-c",
        `f="$XDG_RUNTIME_DIR/pi-chat-paste-$$"; ` +
        `wl-paste --type image > "$f" && printf %s "$f"`]
      stdout: StdioCollector { onStreamFinished: pasteImage.tmp = text }
      onExited: (code) => { if (code === 0 && tmp) chat?.sendFile(tmp, true); tmp = ""; }
    }

    // Drag-and-drop from file managers. Most offer text/uri-list; take
    // the first local file and let the daemon reject non-images.
    DropArea {
      parent: root  // cover the whole panel, not just this layout slot
      anchors.fill: parent
      onDropped: d => {
        if (!d.hasUrls) return;
        const u = d.urls[0].toString();
        if (u.startsWith("file://")) chat?.sendFile(decodeURIComponent(u.slice(7)));
      }
    }

    NText {
      visible: (chat?.lastError ?? "") !== ""
      text: chat?.lastError ?? ""
      color: Color.mError
      pointSize: Style.fontSizeS
      Layout.fillWidth: true
      wrapMode: Text.Wrap
    }
  }

  // Focus the compose box when the panel surface gains keyboard focus.
  // On niri the layer-shell `active` flag flips true the instant the
  // compositor routes keyboard input to us; that's the moment Qt can
  // actually take focus. Doing it earlier races with the click that
  // opened the panel.
  Connections {
    target: root.Window.window
    ignoreUnknownSignals: true
    function onActiveChanged() {
      if (root.Window.window?.active) inputArea.forceActiveFocus();
    }
  }

  // Refresh the model list on every open so the dropdown reflects the
  // current backend state, and snap the history to the newest bubble.
  // The plugin Item is reinstantiated per open (SmartPanel's content
  // Loader has `active: isPanelOpen`), so Component.onCompleted is the
  // open hook.
  Component.onCompleted: {
    chat?.listModels();
    if (history) { history.contentY = 0; history.returnToBounds(); }
  }

  // Ctrl+F from anywhere in the panel. Shortcut rather than Keys so it
  // fires regardless of which TextArea currently has focus.
  Shortcut {
    sequences: [StandardKey.Find]
    enabled: root.visible
    onActivated: { searchBar.visible = true; searchField.forceActiveFocus(); }
  }
}

pragma ComponentBehavior: Bound
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
  readonly property string peerName: root.chat?.peerName || tr("panel.default-peer-name")

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
    const arr = root.chat?.messages || [];
    for (let i = arr.length - 1; i >= 0; i--)
      if (arr[i].id === id) return arr[i];
    return null;
  }


  // No implicitWidth/implicitHeight on purpose. shell.qml's
  // PanelWindow requests the wayland-surface size via its own
  // `implicitWidth: 480`, and QQuickWindow uses its contentItem's
  // implicit size as the window's implicit. Anything we advertise
  // here would propagate up and replace the shell's value, sizing
  // the surface to whatever we put (the noctalia SmartPanel host
  // used to read a 1000 px `contentPreferredWidth` from us — that
  // value reaching the standalone window made the panel render
  // wider than the screen, clipping the header and bubbles off the
  // right edge). The shell sets the width; we fill it via
  // anchors.fill at our call site.

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
          id: newSessionButton
          icon: "plus"
          tooltipText: root.tr("panel.new-session-tooltip")
          baseSize: Style.baseWidgetSize * 0.85
          // One executor (or none): create directly on the default. Multiple
          // (multi-homing): open the picker so the session can be pinned.
          onClicked: {
            if ((root.backend?.executors?.length || 0) > 1)
              executorPickerPopup.visible ? executorPickerPopup.close() : executorPickerPopup.open();
            else
              root.backend?.newSession?.();
          }
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
            id: tabDelegate
            required property var modelData
            readonly property bool isActive: tabDelegate.modelData.id === sessionTabsHost.active
            readonly property int unread: tabDelegate.modelData.unread || 0
            height: ListView.view.height
            width: tabLabel.implicitWidth + Style.marginM * 2
            radius: Style.radiusS
            color: tabDelegate.isActive ? Color.mPrimary : Color.mSurfaceVariant
            border.width: tabDelegate.isActive ? 0 : 1
            border.color: Color.mOutline
            TapHandler {
              onTapped: root.backend?.selectSession?.(tabDelegate.modelData.id)
              onLongPressed: root.backend?.removeSession?.(tabDelegate.modelData.id)
            }
            HoverHandler { cursorShape: Qt.PointingHandCursor }
            NText {
              id: tabLabel
              anchors.centerIn: parent
              text: (tabDelegate.modelData.name || "chat")
                + ((tabDelegate.modelData.executor && (root.backend?.executors?.length || 0) > 1)
                   ? " · " + tabDelegate.modelData.executor : "")
                + (tabDelegate.unread > 0 ? "  •" : "")
              color: tabDelegate.isActive ? Color.mOnPrimary : Color.mOnSurface
              pointSize: Style.fontSizeS
              font.bold: tabDelegate.isActive
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
        NText {
          text: root.peerName
          pointSize: Style.fontSizeL
          font.bold: true
        }
        NText {
          text: (root.chat !== null && root.chat.typing)
            ? "thinking…"
            : root.chat?.streaming
              ? "ready"
              : root.tr("panel.status-offline")
          pointSize: Style.fontSizeXS
          color: Color.mOnSurfaceVariant
        }
      }
      // Model selector. PiChatBackend exposes the llama-swap-discovered list.
      NComboBox {
        id: modelCombo
        // fillWidth so the combo claims the whole header width after the
        // icon and name/status block — every other action moved into the
        // "more" menu, so the dropdown gets nearly the full panel width.
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
        Layout.minimumWidth: 0
        popupHeight: 420
        baseSize: 0.85
        tooltip: root.tr("panel.models-tooltip")
        // NComboBox expects [{key, name}]. Key is the stable "<provider>/<id>";
        // name prefixes the model with its source — the executor id for that
        // executor's local provider ("[kiwi] …"), else the provider name
        // ("[openrouter] …"). Frecency sort orders most-recently/often-used first.
        model: ModelFrecency.sortModels(root.chat?.models ?? [], m => m.provider + "/" + m.id).map(m => ({
          key: m.provider + "/" + m.id,
          name: "[" + (m.provider === "local" ? (root.chat?.executor?.executorId || "local") : m.provider) + "] " + m.id + (m.reasoning ? "  ⚡" : ""),
          provider: m.provider,
          modelId: m.id,
        }))
        currentKey: root.chat?.activeModel ?? ""
        onSelected: key => {
          const item = (root.chat?.models ?? []).find(m => (m.provider + "/" + m.id) === key);
          if (item) root.chat.setModel(item.provider, item.id);
        }
      }
      // Overflow "more" menu: search, memory toggle, wipe and reset all
      // live in optionsPopup now, keeping the header to just the model
      // selector plus this button (and the relay status dot).
      NIconButton {
        id: optionsButton
        icon: "dots-vertical"
        tooltipText: root.tr("panel.options-tooltip")
        baseSize: Style.baseWidgetSize * 0.9
        onClicked: optionsPopup.visible ? optionsPopup.close() : optionsPopup.open()
      }
      Rectangle {
        id: relayDot
        implicitWidth: 8; implicitHeight: 8; radius: 4
        color: root.chat?.streaming ? Color.mTertiary : Color.mError
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
      onVisibleChanged: if (!visible) { searchField.text = ""; history.positionViewAtBeginning(); history._follow = true; }

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
        if (i >= 0) { history.positionViewAtIndex(i, ListView.Center); history._captureFollow(); }
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
      visible: root.chat?.streaming && (root.chat?.messages?.length ?? 0) === 0
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
      objectName: "signalConfirmBanner"
      readonly property var items: (root.backend?.signalPendingSends) || []
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
            id: signalDelegate
            required property var modelData
            // Always surface the raw recipient beside the (attacker-
            // controllable) display name so the human can catch a
            // spoofed name aimed at an unrelated number/UUID before
            // tapping Send. Mirrors the `signal` CLI's pending card.
            readonly property string recipientLabel: {
              const dn = signalDelegate.modelData.display_name || "";
              const rc = signalDelegate.modelData.recipient || "?";
              return (dn === "" || dn === rc) ? rc : (dn + " <" + rc + ">");
            }
            readonly property real maxBodyHeight: Style.baseWidgetSize * 5
            Layout.fillWidth: true
            spacing: Style.marginS
            ColumnLayout {
              Layout.fillWidth: true
              spacing: 0
              NText {
                Layout.fillWidth: true
                text: root.tr("panel.signal-pending-prefix", { to: signalDelegate.recipientLabel })
                pointSize: Style.fontSizeS
                font.bold: true
                wrapMode: Text.Wrap
              }
              ScrollView {
                id: signalBodyScroll
                Layout.fillWidth: true
                // Untruncated: show the whole body, but cap the card and
                // scroll past the cap so a long message can't blow up the
                // panel. The human can scroll to read all of what they
                // are about to approve.
                Layout.preferredHeight: Math.min(signalBody.implicitHeight, signalDelegate.maxBodyHeight)
                clip: true
                contentWidth: availableWidth
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                ScrollBar.vertical.policy: ScrollBar.AsNeeded
                NText {
                  id: signalBody
                  width: signalBodyScroll.availableWidth
                  text: signalDelegate.modelData.body || ""
                  pointSize: Style.fontSizeXS
                  wrapMode: Text.Wrap
                }
              }
            }
            NButton {
              text: root.tr("panel.signal-approve")
              onClicked: root.backend?.signalApprove(signalDelegate.modelData.token)
            }
            NButton {
              text: root.tr("panel.signal-deny")
              onClicked: root.backend?.signalDeny(signalDelegate.modelData.token)
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
      objectName: "chatHistory"
      anchors.fill: parent
      // BottomToTop + reversed model: index 0 = newest = the visual
      // bottom, which Qt anchors to the bottom edge. In this layout
      // originY is large-negative and contentY is never ≈0; "at the
      // bottom" is Qt's atYEnd, and scrolling up drives contentY toward
      // originY.
      verticalLayoutDirection: ListView.BottomToTop
      model: MsgFilter.visible(root.chat?.messages ?? [], root.showThinking).slice().reverse()
      clip: true
      // atYEnd is the only honest "pinned to the newest message" signal
      // here — a `contentY < N` test reads true everywhere. Drives the
      // unread pill below.
      readonly property bool atBottom: atYEnd
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

      // ── keep scrollback while the agent streams (issue #28) ──
      // Each streaming token reassigns `messages`, regrowing the newest
      // bubble; the model-driven relayout then re-anchors to index 0 and
      // snaps the view to the bottom — yanking a reader who scrolled up,
      // on every token. Hold their position by pinning the gap from the
      // top of content (contentY − originY) across every height change,
      // and only let Qt's snap stand when they were already at the bottom.
      // `_follow` records that intent on user-driven movement, captured
      // before the snap flips atYEnd back to true.
      property bool _follow: true
      property real _topGap: 0
      function _captureFollow() {
        _follow = atYEnd;
        if (!_follow) _topGap = contentY - originY;
      }
      onMovementEnded: _captureFollow()
      onContentYChanged: if (moving) _captureFollow()
      // The relayout that snaps to the bottom runs after this notifier,
      // so re-pin once it has settled (Qt.callLater coalesces the burst
      // of per-token height changes into a single correction). Never
      // fight an active gesture — let _captureFollow track it instead.
      onContentHeightChanged: if (!_follow && !moving) Qt.callLater(_restoreScroll)
      function _restoreScroll() {
        if (_follow || moving) return;
        const y = originY + _topGap;
        if (Math.abs(contentY - y) > 0.5) contentY = y;
      }

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
          root.chat.replyTarget = { id: modelData.id, text: modelData.text };
          input.forceActiveFocus();
        }
        onJumpToQuote: {
          const i = history.model.findIndex(m => m.id === modelData.replyTo);
          if (i >= 0) { history.positionViewAtIndex(i, ListView.Center); history._captureFollow(); }
        }
        onRetryRequested:  root.chat.retry(modelData.id)
        onCancelRequested: root.chat.cancel(modelData.id)
        onConfirmRequested: confirmed => root.chat.confirmRespond(modelData.id, confirmed)
        onPromptSubmit: value => root.chat.promptRespond(modelData.id, value)
        onPromptCancel: root.chat.promptCancel(modelData.id)
      }

      // A streaming token reassigns the model every frame but never
      // changes the count, so the per-append work below is skipped for it.
      // Switching sessions (chat identity changes) or first populating one
      // snaps to the newest message and re-engages follow. Within a chat,
      // own sends snap to the new bubble — not seeing your own message is
      // worse than losing scrollback — while a peer message sticks to the
      // bottom only if the reader was already there, otherwise it feeds the
      // unread pill with their place held by _captureFollow /
      // onContentHeightChanged.
      property int _lastCount: 0
      property var _lastChat: undefined
      onModelChanged: {
        if (root.chat !== _lastChat) {
          _lastChat = root.chat;
          _lastCount = count;
          _follow = true;
          if (count > 0) positionViewAtBeginning();
          return;
        }
        if (count === 0) return;
        if (count <= _lastCount) { _lastCount = count; return; }
        _lastCount = count;
        if (model[0]?.from === "me") { _follow = true; positionViewAtBeginning(); }
        else if (!_follow) unseen++;
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
      TapHandler { onTapped: { history.positionViewAtBeginning(); history._follow = true; } }
      HoverHandler { cursorShape: Qt.PointingHandCursor }
    }
    } // history wrapper

    // ── Compose ───────────────────────────────────────────────────────
    // Reply context bar — shown when a bubble was tapped. Cleared on
    // send (Main.qml) or by the × here.
    Rectangle {
      visible: (root.chat?.replyTarget ?? null) !== null
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
          text: Txt.snippet(root.chat?.replyTarget?.text ?? "", 80)
          elide: Text.ElideRight
          pointSize: Style.fontSizeS
          color: Color.mOnSurfaceVariant
        }
        NIconButton {
          icon: "x"
          baseSize: Style.baseWidgetSize * 0.7
          onClicked: root.chat.replyTarget = null
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
          if (!root.chat) return;
          // Send regardless of streaming state — the daemon's outbox
          // queues it and retries when relays come back.
          root.chat.send(inputArea.text);
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
            placeholderText: root.chat?.streaming ? root.tr("panel.compose-placeholder", { name: root.peerName }) : root.tr("panel.compose-waiting")
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
            Keys.onEscapePressed: if (root.chat?.replyTarget) root.chat.replyTarget = null

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
      onAccepted: paths => { if (paths.length > 0) root.chat?.sendFile(paths[0]); }
    }

    Process {
      id: pasteImage
      property string tmp: ""
      command: ["sh", "-c",
        `f="$XDG_RUNTIME_DIR/pi-chat-paste-$$"; ` +
        `wl-paste --type image > "$f" && printf %s "$f"`]
      stdout: StdioCollector { onStreamFinished: pasteImage.tmp = text }
      onExited: code => { if (code === 0 && tmp) root.chat?.sendFile(tmp, true); tmp = ""; }
    }

    NText {
      visible: (root.chat?.lastError ?? "") !== ""
      text: root.chat?.lastError ?? ""
      color: Color.mError
      pointSize: Style.fontSizeS
      Layout.fillWidth: true
      wrapMode: Text.Wrap
    }
  }

  // Drag-and-drop from file managers. Most offer text/uri-list; take
  // the first local file and let the daemon reject non-images. Lives
  // at the root scope so it covers the whole panel rather than only
  // the ColumnLayout's footprint.
  DropArea {
    anchors.fill: parent
    onDropped: d => {
      if (!d.hasUrls) return;
      const u = d.urls[0].toString();
      if (u.startsWith("file://")) root.chat?.sendFile(decodeURIComponent(u.slice(7)));
    }
  }

  // Focus the compose box when the panel surface gains keyboard focus.
  // The shell requests Exclusive keyboard focus while visible, so the
  // layer-shell `active` flag flips true as soon as the panel opens —
  // no click needed. `active` is the moment Qt can actually take focus;
  // doing it earlier (e.g. on Component.onCompleted) races the grab.
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
    root.chat?.listModels();
    if (history) { history.positionViewAtBeginning(); history._follow = true; }
  }

  // Ctrl+F from anywhere in the panel. Shortcut rather than Keys so it
  // fires regardless of which TextArea currently has focus.
  Shortcut {
    sequences: [StandardKey.Find]
    enabled: root.visible
    onActivated: { searchBar.visible = true; searchField.forceActiveFocus(); }
  }

  // ── Options popup ("more" menu) ────────────────────────────────────
  // The header's overflow menu: per-session actions (search, long-term
  // memory toggle, wipe, restart) on top, then the persisted display
  // toggles. Popup keeps close-on-outside-click for free.

  // One clickable menu strip: leading icon, label, optional trailing
  // check. `active` tints the icon (e.g. an enabled toggle); `showCheck`
  // renders the ✓ when active. Emits activated() on tap — callers wire
  // the behaviour, so this stays a dumb presentational row.
  component OptionRow: Item {
    id: optRow
    property string iconName: ""
    property string label: ""
    property bool active: false
    property bool showCheck: false
    signal activated()

    Layout.fillWidth: true
    implicitHeight: Style.baseWidgetSize

    Rectangle {
      anchors.fill: parent
      color: optRowHover.hovered ? Color.mHover : "transparent"
      radius: Style.radiusS
      Behavior on color {
        ColorAnimation { duration: Style.animationFast; easing.type: Easing.InOutQuad }
      }
    }

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.marginS
      anchors.rightMargin: Style.marginS
      spacing: Style.marginS

      NIcon {
        icon: optRow.iconName
        pointSize: Style.fontSizeL
        color: optRowHover.hovered
          ? Color.mOnHover
          : (optRow.active ? Color.mPrimary : Color.mOnSurfaceVariant)
      }
      NText {
        Layout.fillWidth: true
        text: optRow.label
        pointSize: Style.fontSizeS
        color: optRowHover.hovered ? Color.mOnHover : Color.mOnSurface
        elide: Text.ElideRight
      }
      NText {
        text: (optRow.showCheck && optRow.active) ? "✓" : ""
        pointSize: Style.fontSizeS
        color: optRowHover.hovered ? Color.mOnHover : Color.mPrimary
      }
    }

    HoverHandler { id: optRowHover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: optRow.activated() }
  }

  Popup {
    id: optionsPopup
    objectName: "optionsPopup"
    // Parent to the button so x/y live in its own coordinate space and
    // track it directly — mapping into root's space misplaced the popup.
    // Right edges align; the menu opens just below the button.
    parent: optionsButton
    x: optionsButton.width - implicitWidth
    y: optionsButton.height + Style.marginXS
    padding: Style.marginXS
    implicitWidth: 320
    closePolicy: Popup.CloseOnPressOutside | Popup.CloseOnEscape

    background: Rectangle {
      color: Color.mSurfaceVariant
      radius: Style.iRadiusM
      border.color: Color.mOutline
      border.width: Style.borderS
    }

    contentItem: ColumnLayout {
      spacing: 0

      // Search: toggle the inline search bar and focus its field.
      OptionRow {
        iconName: "search"
        label: root.tr("panel.search-tooltip")
        onActivated: {
          optionsPopup.close();
          searchBar.visible = !searchBar.visible;
          if (searchBar.visible) searchField.forceActiveFocus();
        }
      }
      // Long-term-memory toggle. Backed by chat.memoryEnabled (the backend
      // persists + writes the marker file pi reads), so it stays open to
      // show the ✓ flip rather than closing like the action rows.
      OptionRow {
        readonly property bool memOn: root.chat?.memoryEnabled ?? true
        iconName: memOn ? "brain" : "database-off"
        label: root.tr("panel.options-memory")
        active: memOn
        showCheck: true
        onActivated: {
          const id = root.backend?.activeSessionId;
          if (!id) return;
          root.backend.setSessionMemoryEnabled(id, !memOn);
        }
      }
      // Wipe all memory: destructive, so just reveal the confirm strip.
      OptionRow {
        iconName: "eraser"
        label: root.tr("panel.memory-wipe-tooltip")
        onActivated: {
          optionsPopup.close();
          wipeConfirmBar.visible = true;
        }
      }
      // Restart: clear local bubbles and ask pi for a fresh session.
      OptionRow {
        iconName: "rotate"
        label: root.tr("panel.reset-tooltip")
        onActivated: {
          optionsPopup.close();
          if (root.chat) root.chat.restart();
        }
      }

      NDivider {
        Layout.fillWidth: true
        Layout.topMargin: Style.marginXS
        Layout.bottomMargin: Style.marginXS
      }

      // Persisted display toggles (UI-only Settings flags).
      Repeater {
        model: [
          {
            key: "showThinking",
            iconOn: "eye",
            iconOff: "eye-off",
            labelOn: "panel.options-thinking-hide",
            labelOff: "panel.options-thinking-show",
          },
          {
            key: "showInferenceSpeed",
            iconOn: "gauge",
            iconOff: "gauge",
            labelOn: "panel.options-tps-hide",
            labelOff: "panel.options-tps-show",
          },
        ]
        delegate: OptionRow {
          id: toggleRow
          required property var modelData
          readonly property bool on: Settings.data[toggleRow.modelData.key] === true
          iconName: on ? toggleRow.modelData.iconOn : toggleRow.modelData.iconOff
          label: root.tr(on ? toggleRow.modelData.labelOn : toggleRow.modelData.labelOff)
          active: on
          showCheck: true
          onActivated: {
            Settings.data[toggleRow.modelData.key] = !on;
            Settings.persist();
          }
        }
      }
    }
  }

  // ── New-session executor picker ────────────────────────────────────
  // Multi-homing: when more than one executor is configured the + button
  // opens this to pin a new session to a chosen executor (one executor =>
  // create directly, see newSessionButton). Rows show the executor id, so
  // no new translatable string is introduced (mirrors the tab's · label).
  Popup {
    id: executorPickerPopup
    objectName: "executorPickerPopup"
    x: newSessionButton ? newSessionButton.mapToItem(root, 0, 0).x : 0
    y: newSessionButton ? newSessionButton.mapToItem(root, 0, 0).y + newSessionButton.height + Style.marginXS : 0
    padding: Style.marginXS
    implicitWidth: 200
    closePolicy: Popup.CloseOnPressOutside | Popup.CloseOnEscape

    background: Rectangle {
      color: Color.mSurfaceVariant
      radius: Style.iRadiusM
      border.color: Color.mOutline
      border.width: Style.borderS
    }

    contentItem: ColumnLayout {
      spacing: 0

      Repeater {
        model: root.backend?.executors || []
        delegate: Item {
          id: execRow
          required property var modelData
          Layout.fillWidth: true
          implicitHeight: Style.baseWidgetSize

          Rectangle {
            anchors.fill: parent
            color: execTap.hovered ? Color.mHover : "transparent"
            radius: Style.radiusS
            Behavior on color {
              ColorAnimation { duration: Style.animationFast; easing.type: Easing.InOutQuad }
            }
          }

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.marginS
            anchors.rightMargin: Style.marginS
            spacing: Style.marginS

            NIcon {
              icon: "plus"
              pointSize: Style.fontSizeL
              color: execTap.hovered ? Color.mOnHover : Color.mOnSurfaceVariant
            }
            NText {
              Layout.fillWidth: true
              text: execRow.modelData.id
              pointSize: Style.fontSizeS
              color: execTap.hovered ? Color.mOnHover : Color.mOnSurface
              elide: Text.ElideRight
            }
          }

          HoverHandler { id: execTap; cursorShape: Qt.PointingHandCursor }
          TapHandler {
            onTapped: {
              root.backend?.newSession?.("", execRow.modelData.id);
              executorPickerPopup.close();
            }
          }
        }
      }
    }
  }
}

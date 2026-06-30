pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Widgets
import "MsgText.js" as Txt

// One chat row: hover-reveal reply button + the bubble itself.
// Panel owns all state; this takes data in and emits intent out so the
// delegate stays dumb and testable.
Item {
  id: row

  // ── in ───────────────────────────────────────────────────────────
  // modelData because that's what ListView injects into delegate
  // roots; aliased to msg for readability.
  required property var modelData // {id, from, text, ts, ack, image, replyTo, state, tries}
  readonly property var msg: modelData
  property string pendingState: "pending"
  property string searchQuery: ""
  property bool   searchCurrent: false
  // Panel resolves replyTo → text (needs access to the full list).
  property string quotedText: ""
  // ago() depends on Panel's ticking clock, so it's injected.
  property var ago: ts => ""
  // Injected by Panel so the delegate doesn't need pluginApi
  property var tr: k => k

  // ── out ──────────────────────────────────────────────────────────
  signal replyRequested
  signal jumpToQuote
  signal retryRequested
  signal cancelRequested
  // Emitted when the user clicks Allow/Deny on a confirm bubble.
  // Panel forwards to chat.confirmRespond.
  signal confirmRequested(bool confirmed)
  // Emitted when the user submits or cancels a prompt bubble.
  // Panel forwards to chat.promptRespond / chat.promptCancel.
  signal promptSubmit(string value)
  signal promptCancel
  // Emitted when the user picks once/session/deny on an approval bubble.
  // Panel forwards to chat.approvalRespond.
  signal approvalRequested(string decision)

  readonly property bool mine: row.msg.from === "me"
  readonly property bool isNotification: (row.msg.type ?? "") === "notification"
  readonly property bool isConfirm: (row.msg.type ?? "") === "confirm"
  readonly property bool isPrompt: (row.msg.type ?? "") === "prompt"
  readonly property bool isThinking: (row.msg.type ?? "") === "thinking"
  readonly property bool isApproval: (row.msg.type ?? "") === "approval"
  // Match locally — O(1) and can't drift from Panel's hit list since
  // it's the same predicate.
  readonly property bool searchHit:
    searchQuery !== "" && (row.msg.text || "").toLowerCase().includes(searchQuery)

  implicitHeight: row.isConfirm ? confirmCard.implicitHeight
                                : row.isApproval ? approvalCard.implicitHeight
                                : row.isPrompt ? promptCard.implicitHeight
                                : row.isNotification ? notifText.implicitHeight
                                : row.isThinking ? thinkingText.implicitHeight
                                                 : bubble.implicitHeight

  // Hover-reveal reply button in the 15% gutter beside the bubble.
  // Lives on the row so it never covers text and doesn't fight
  // selectByMouse.
  NIconButton {
    icon: "corner-down-right"
    tooltipText: row.tr("bubble.reply-tooltip")
    baseSize: Style.baseWidgetSize * 0.7
    anchors.verticalCenter: bubble.verticalCenter
    anchors.left:  row.mine ? undefined : bubble.right
    anchors.right: row.mine ? bubble.left : undefined
    anchors.margins: Style.marginXS
    opacity: (hov.hovered || hovering) ? 1 : 0
    visible: !row.isConfirm && !row.isPrompt && !row.isNotification && !row.isThinking && opacity > 0
    Behavior on opacity { NumberAnimation { duration: 100 } }
    onClicked: row.replyRequested()
  }

  // Bubble floats left (peer) or right (me) at ~85% width so the
  // alignment itself reads as "who said this" without an avatar.
  Rectangle {
    id: bubble
    // Anchor selection: one of "notification" (centered) / "mine"
    // (right) / "peer" (left). Kept as States so the three anchor
    // properties never appear together in the base scope — qmllint's
    // Quick.anchor-combinations check requires that.
    states: [
      State {
        name: "notification"
        when: row.isNotification
        AnchorChanges { target: bubble; anchors.horizontalCenter: parent.horizontalCenter }
      },
      State {
        name: "mine"
        when: !row.isNotification && row.mine
        AnchorChanges { target: bubble; anchors.right: parent.right }
      },
      State {
        name: "peer"
        when: !row.isNotification && !row.mine
        AnchorChanges { target: bubble; anchors.left: parent.left }
      }
    ]
    visible: !row.isNotification && !row.isConfirm && !row.isPrompt && !row.isThinking
    // Image/quote/streaming bubbles snap to the cap; plain text shrinks
    // to fit so short replies don't stretch edge-to-edge.
    width: ((row.msg.image ?? "") !== "" || (row.msg.replyTo ?? "") !== "" || (row.msg.state ?? "") === "streaming")
      ? row.width * 0.85
      : Math.min(msgText.implicitWidth + Style.marginM * 2, row.width * 0.85)
    implicitHeight: col.implicitHeight + Style.marginM * 2
    radius: Style.radiusS
    color: row.mine ? Color.mPrimary : Color.mSurfaceVariant
    border.width: row.searchHit ? 2 : (row.mine ? 0 : 1)
    border.color: row.searchHit
      ? (row.searchCurrent ? Color.mTertiary : Color.mSecondary)
      : Color.mOutline
    // Dim only while the outbox still owns it. Once a relay has the
    // wrap it's out of our hands — ✓ covers the rest.
    opacity: (row.mine && row.msg.state === row.pendingState) ? 0.7 : 1.0
    Behavior on opacity { NumberAnimation { duration: 150 } }

    HoverHandler { id: hov }

    ColumnLayout {
      id: col
      anchors.fill: parent
      anchors.margins: Style.marginM
      spacing: Style.marginXXS

      // Quoted snippet for threaded replies. Panel resolves the text;
      // we just render.
      Rectangle {
        visible: (row.msg.replyTo ?? "") !== ""
        Layout.fillWidth: true
        implicitHeight: quote.implicitHeight + Style.marginXS * 2
        radius: Style.radiusXS
        color: row.mine
          ? Qt.alpha(Color.mOnPrimary, 0.15)
          : Qt.alpha(Color.mOnSurface, 0.08)
        TapHandler { onTapped: row.jumpToQuote() }
        NText {
          id: quote
          anchors.fill: parent
          anchors.margins: Style.marginXS
          text: row.quotedText
            ? "↳ " + Txt.snippet(row.quotedText, 60)
            : row.tr("bubble.quote-missing")
          pointSize: Style.fontSizeXS
          elide: Text.ElideRight
          color: row.mine
            ? Qt.alpha(Color.mOnPrimary, 0.7)
            : Color.mOnSurfaceVariant
        }
      }

      // kind-15 attachments: daemon downloads + decrypts, then pushes
      // the local path. QML Image won't load a bare path — needs the
      // file:// scheme.
      Image {
        visible: (row.msg.image ?? "") !== ""
        Layout.fillWidth: true
        Layout.preferredHeight: visible
          ? Math.min(implicitHeight * (width / Math.max(implicitWidth, 1)), 240)
          : 0
        source: row.msg.image ? "file://" + row.msg.image : ""
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        cache: true
        // Open full-size — 240px is fine for a glance but useless for
        // reading a screenshot.
        TapHandler {
          grabPermissions: PointerHandler.TakeOverForbidden
          onTapped: Quickshell.execDetached(["xdg-open", row.msg.image])
        }
        HoverHandler { cursorShape: Qt.PointingHandCursor }
      }

      TextEdit {
        id: msgText
        Layout.fillWidth: true
        readonly property color linkColor:
          row.mine ? Color.mOnPrimary : Color.mSecondary
        text: Txt.colorizeLinks(
          row.searchHit
            ? Txt.highlight(row.msg.text, row.searchQuery,
                            Color.mTertiary, Color.mOnTertiary)
            : row.msg.text,
          linkColor)
        wrapMode: Text.Wrap
        textFormat: Text.MarkdownText
        readOnly: true
        selectByMouse: true
        // Own bubbles sit on mPrimary, so invert the selection palette
        // or the highlight vanishes.
        selectionColor: row.mine ? Color.mOnPrimary : Color.mPrimary
        selectedTextColor: row.mine ? Color.mPrimary : Color.mOnPrimary
        color: row.mine ? Color.mOnPrimary : Color.mOnSurface
        font.family: Settings.data.ui.fontDefault
        font.pointSize: Style.fontSizeM * Settings.data.ui.fontDefaultScale
        font.weight: Style.fontWeightMedium
        onLinkActivated: url => Quickshell.execDetached(["xdg-open", url])
        HoverHandler {
          cursorShape: msgText.hoveredLink !== ""
            ? Qt.PointingHandCursor : Qt.IBeamCursor
        }
      }

      RowLayout {
        Layout.alignment: row.mine ? Qt.AlignRight : Qt.AlignLeft
        spacing: Style.marginXS
        NText {
          text: row.ago(row.msg.ts)
          pointSize: Style.fontSizeM
          color: row.mine
            ? Qt.alpha(Color.mOnPrimary, 0.6)
            : Color.mOnSurfaceVariant
        }
        // Inference-speed footer for assistant text bubbles when the
        // user opted in via the Panel's options menu. Pi feeds tps
        // onto the message via PiSession on message_end with usage.
        NText {
          visible: !row.mine
            && Settings.data.showInferenceSpeed
            && (row.msg.tps ?? 0) > 0
          text: (row.msg.tps ?? 0).toFixed(1) + " t/s"
          pointSize: Style.fontSizeM
          color: Color.mOnSurfaceVariant
        }
        // Delivery ladder: 🕓 pending → ✓ sent → ✓✓/emoji read.
        // ⚠ when retries pile up — tap to force, long-press to cancel.
        NText {
          visible: row.mine
          text: {
            if ((row.msg.tries ?? 0) > 0) return "⚠";
            if (row.msg.state === row.pendingState) return "🕓";
            const a = row.msg.ack ?? "";
            if (a === "") return "✓";
            return (a === "+" || a === "✓") ? "✓✓" : a;
          }
          pointSize: Style.fontSizeL
          color: (row.msg.tries ?? 0) > 0
            ? Color.mError
            : Qt.alpha(Color.mOnPrimary, 0.8)
          TapHandler {
            enabled: (row.msg.tries ?? 0) > 0
            onTapped: row.retryRequested()
            onLongPressed: row.cancelRequested()
          }
        }
      }
    }
  }

  // Notification messages: no bubble, just centered faded text.
  NText {
    id: notifText
    visible: row.isNotification
    anchors.horizontalCenter: parent.horizontalCenter
    width: parent.width * 0.85
    text: row.msg.text
    horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.Wrap
    pointSize: Style.fontSizeM
    color: Qt.alpha(Color.mOnSurface, 0.45)
  }

  // Thinking: small grey text, no bubble, left-aligned. Streams in
  // real-time as the model reasons, then stays as a faded record.
  NText {
    id: thinkingText
    visible: row.isThinking
    anchors.left: parent.left
    width: parent.width * 0.85
    text: (row.msg.text || "") !== "" ? row.msg.text : "thinking…"
    wrapMode: Text.Wrap
    pointSize: Style.fontSizeS
    font.italic: true
    color: Qt.alpha(Color.mOnSurface, 0.45)
  }

  // Confirmation card: title + monospace command body + Allow/Deny.
  // After the user clicks, the buttons disappear and an outcome label
  // shows in their place so the row remains a permanent audit entry.
  Rectangle {
    id: confirmCard
    visible: row.isConfirm
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.margins: 0
    implicitHeight: confirmCol.implicitHeight + Style.marginM * 2
    radius: Style.radiusS
    color: Color.mSurfaceVariant
    border.width: 1
    border.color: {
      const s = row.msg.confirmState ?? "pending";
      if (s === "allowed") return Color.mTertiary;
      if (s === "denied")  return Color.mError;
      return Color.mPrimary;
    }
    ColumnLayout {
      id: confirmCol
      anchors.fill: parent
      anchors.margins: Style.marginM
      spacing: Style.marginXS
      NText {
        text: row.msg.confirmTitle ?? row.tr("bubble.confirm-default-title")
        pointSize: Style.fontSizeM
        font.bold: true
        color: Color.mOnSurface
      }
      // Body in monospace so a shell command reads as a shell command,
      // not a paragraph. Selectable so the user can copy before deciding.
      TextEdit {
        Layout.fillWidth: true
        text: row.msg.text
        readOnly: true
        selectByMouse: true
        wrapMode: Text.Wrap
        font.family: Settings.data.ui.fontFixed ?? Settings.data.ui.fontDefault
        font.pointSize: Style.fontSizeS * Settings.data.ui.fontDefaultScale
        color: Color.mOnSurface
      }
      RowLayout {
        Layout.alignment: Qt.AlignRight
        spacing: Style.marginS
        visible: (row.msg.confirmState ?? "pending") === "pending"
        Button {
          text: row.tr("bubble.confirm-deny")
          onClicked: row.confirmRequested(false)
        }
        Button {
          text: row.tr("bubble.confirm-allow")
          highlighted: true
          onClicked: row.confirmRequested(true)
        }
      }
      NText {
        Layout.alignment: Qt.AlignRight
        // "resolved" (answered by another mirrored client) collapses to just
        // the title — no buttons, and no allow/deny outcome to mislabel it.
        visible: row.msg.confirmState === "allowed" || row.msg.confirmState === "denied"
        text: (row.msg.confirmState === "allowed")
          ? row.tr("bubble.confirm-allowed")
          : row.tr("bubble.confirm-denied")
        color: (row.msg.confirmState === "allowed") ? Color.mTertiary : Color.mError
        pointSize: Style.fontSizeS
        font.bold: true
      }
    }
  }

  // Integration tool-call approval (gateway → panel). A non-allowlisted
  // tool wants to run; the args below are exactly what it will execute
  // with. Three outcomes — once, session (tool-name grant), deny.
  Rectangle {
    id: approvalCard
    visible: row.isApproval
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.margins: 0
    implicitHeight: approvalCol.implicitHeight + Style.marginM * 2
    radius: Style.radiusS
    color: Color.mSurfaceVariant
    border.width: 1
    border.color: {
      const s = row.msg.approvalState ?? "pending";
      if (s === "once" || s === "session") return Color.mTertiary;
      if (s === "deny") return Color.mError;
      return Color.mPrimary;
    }
    ColumnLayout {
      id: approvalCol
      anchors.fill: parent
      anchors.margins: Style.marginM
      spacing: Style.marginXS
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.marginS
        NIcon {
          icon: "key"
          pointSize: Style.fontSizeL
          color: Color.mPrimary
        }
        ColumnLayout {
          Layout.fillWidth: true
          spacing: 0
          NText {
            text: row.tr("bubble.approval-title")
            pointSize: Style.fontSizeM
            font.bold: true
            color: Color.mOnSurface
          }
          NText {
            text: (row.msg.approvalIntegration || "") + " · " + (row.msg.approvalTool || "")
            pointSize: Style.fontSizeS
            color: Color.mOnSurfaceVariant
          }
        }
      }
      // The exact args the tool will run with — the security-relevant payload.
      NText {
        Layout.fillWidth: true
        visible: (row.msg.approvalArgs || "") !== "" && (row.msg.approvalArgs || "") !== "{}"
        text: row.msg.approvalArgs
        wrapMode: Text.Wrap
        color: Color.mOnSurfaceVariant
        pointSize: Style.fontSizeXS
      }
      RowLayout {
        Layout.alignment: Qt.AlignRight
        spacing: Style.marginS
        visible: (row.msg.approvalState ?? "pending") === "pending"
        Button {
          text: row.tr("bubble.approval-deny")
          onClicked: row.approvalRequested("deny")
        }
        Button {
          text: row.tr("bubble.approval-once")
          onClicked: row.approvalRequested("once")
        }
        Button {
          text: row.tr("bubble.approval-session")
          highlighted: true
          onClicked: row.approvalRequested("session")
        }
      }
      NText {
        Layout.alignment: Qt.AlignRight
        visible: (row.msg.approvalState ?? "pending") !== "pending"
        text: {
          const s = row.msg.approvalState ?? "";
          if (s === "once") return row.tr("bubble.approval-allowed-once");
          if (s === "session") return row.tr("bubble.approval-allowed-session");
          if (s === "deny") return row.tr("bubble.approval-denied");
          return "";
        }
        color: {
          const s = row.msg.approvalState ?? "";
          return s === "deny" ? Color.mError : Color.mTertiary;
        }
        pointSize: Style.fontSizeS
        font.bold: true
      }
    }
  }

  // Prompt card: skill-config credential request rendered inline.
  // Header (instance/skill/profile/field) + description (markdown so
  // SKILL.md can use bold and lists) + text input + Submit/Cancel.
  // Secret fields mask the input. Once submitted/cancelled/retracted
  // the controls disappear and an outcome label stays as audit trail.
  Rectangle {
    id: promptCard
    visible: row.isPrompt
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.margins: 0
    implicitHeight: promptCol.implicitHeight + Style.marginM * 2
    radius: Style.radiusS
    color: Color.mSurfaceVariant
    border.width: 1
    border.color: {
      const s = row.msg.promptState ?? "pending";
      if (s === "submitted") return Color.mTertiary;
      if (s === "cancelled") return Color.mError;
      if (s === "retracted") return Color.mOutline;
      return Color.mPrimary;
    }
    readonly property bool pending: (row.msg.promptState ?? "pending") === "pending"
    ColumnLayout {
      id: promptCol
      anchors.fill: parent
      anchors.margins: Style.marginM
      spacing: Style.marginXS
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.marginS
        NIcon {
          icon: row.msg.promptSecret ? "key" : "edit"
          pointSize: Style.fontSizeL
          color: Color.mPrimary
        }
        ColumnLayout {
          Layout.fillWidth: true
          spacing: 0
          NText {
            text: row.msg.promptInstance ? ("session-" + row.msg.promptInstance) : ""
            pointSize: Style.fontSizeXS
            color: Color.mOnSurfaceVariant
          }
          NText {
            text: (row.msg.promptSkill || "") + " · "
              + (row.msg.promptProfile || "") + " · "
              + (row.msg.promptField || "")
            pointSize: Style.fontSizeM
            font.bold: true
            color: Color.mOnSurface
          }
        }
      }
      // Description: markdown so SKILL.md formatting survives.
      NText {
        Layout.fillWidth: true
        visible: (row.msg.text || "") !== ""
        text: row.msg.text
        wrapMode: Text.Wrap
        markdownTextEnabled: true
        color: Color.mOnSurfaceVariant
        pointSize: Style.fontSizeS
      }
      // Live input — only while pending. After submit we drop the value
      // from the bubble (especially for secrets) so an audit-trail scroll
      // doesn't leak it.
      TextField {
        id: promptInput
        Layout.fillWidth: true
        visible: promptCard.pending
        echoMode: row.msg.promptSecret ? TextInput.Password : TextInput.Normal
        placeholderText: row.msg.promptSecret
          ? row.tr("bubble.prompt-placeholder-secret")
          : row.tr("bubble.prompt-placeholder")
        Keys.onReturnPressed: e => {
          if (text.length > 0) { row.promptSubmit(text); text = ""; }
        }
        Keys.onEscapePressed: e => { text = ""; row.promptCancel(); }
      }
      RowLayout {
        Layout.alignment: Qt.AlignRight
        spacing: Style.marginS
        visible: promptCard.pending
        Button {
          text: row.tr("bubble.prompt-cancel")
          onClicked: { promptInput.text = ""; row.promptCancel(); }
        }
        Button {
          text: row.tr("bubble.prompt-submit")
          highlighted: true
          enabled: promptInput.text.length > 0
          onClicked: {
            const v = promptInput.text;
            promptInput.text = "";
            row.promptSubmit(v);
          }
        }
      }
      NText {
        Layout.alignment: Qt.AlignRight
        visible: !promptCard.pending
        text: {
          const s = row.msg.promptState ?? "";
          if (s === "submitted") return row.tr("bubble.prompt-submitted");
          if (s === "cancelled") return row.tr("bubble.prompt-cancelled");
          if (s === "retracted") return row.tr("bubble.prompt-retracted");
          return "";
        }
        color: {
          const s = row.msg.promptState ?? "";
          if (s === "submitted") return Color.mTertiary;
          if (s === "cancelled") return Color.mError;
          return Color.mOnSurfaceVariant;
        }
        pointSize: Style.fontSizeS
        font.bold: true
      }
    }
  }
}

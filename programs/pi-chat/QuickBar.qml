// Quick-launch agent bar — the Mod+/ "Spotlight" surface.
//
// A second layer-shell surface in the same pi-chat process, anchored
// bottom-center and sharing the single PiChatBackend. Type a prompt and
// press Enter to fire an agent in the BACKGROUND
// (backend.launchBackground): the chat panel stays closed, the bar
// hides, and a desktop notification fires on completion. The launched
// session is a normal index entry — Mod+A later shows it in the tab
// strip to continue.
//
// Leading slash-directives configure the launch (e.g. /model:gemma4:e4b);
// the completion list lives in QuickBarCompletion, an in-window overlay
// that grows the bar upward — no second layer-shell, no clipping Popup.
// Parsing is delegated to BarParse via the completion controller; this
// surface only renders and forwards keys.
//
// Unlike the chat panel (OnDemand focus, so summoning never steals the
// keyboard), this bar is a modal input: it grabs Exclusive keyboard
// focus while shown and releases it when hidden. niri compositor binds
// still fire under Exclusive.
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Widgets

PanelWindow {
  id: bar

  property var backend: null

  // Gap between the bar and the screen edge. The window itself reaches
  // the edge (transparent); the rounded surface floats `gap` above it
  // via anchors.bottomMargin — PanelWindow's own `margins` group isn't
  // resolvable under qmllint, so we inset the surface instead.
  readonly property int gap: Style.marginL * 4

  // Guards the completion→field write-back: applying a rewritten text
  // moves the caret, and that cursor change must not be mistaken for a
  // user edit and fed back in.
  property bool _applying: false

  anchors.bottom: true

  // ~640px, clamped so it neither overflows a small laptop nor sprawls
  // on an ultrawide — mirrors the chat panel's clamp idiom.
  implicitWidth: Math.round(Math.max(360, Math.min(640, screen.width - Style.marginL * 4)))
  // The completion overlay reports 0 height when inactive and animates as
  // it opens/closes, so adding it directly grows the bottom-anchored
  // surface UPWARD in step with the list. No binding loop: the overlay's
  // implicitHeight derives from its candidate count and active flag, never
  // from this window's size.
  implicitHeight: row.implicitHeight + Style.marginM * 2 + bar.gap + completion.implicitHeight

  exclusiveZone: 0
  WlrLayershell.layer: WlrLayer.Top
  WlrLayershell.keyboardFocus: bar.visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

  // The PanelWindow itself is transparent; the rounded surface paints.
  color: "transparent"
  visible: false

  // Enter with the list closed: launch the parsed prompt. The controller
  // strips directives and refuses an empty/invalid/unknown input, so the
  // bar only hides when a launch actually fired.
  function launch() {
    if (completion.enter() === "launch")
      bar.visible = false;
  }

  // Apply a completion's rewrite back into the field without the cursor
  // move looping through onCursorPositionChanged as a fake user edit.
  function _applyCompletion() {
    bar._applying = true;
    if (input.text !== completion.text)
      input.text = completion.text;
    input.cursorPosition = completion.cursor;
    bar._applying = false;
  }

  // Grab focus on show; warm the model cache so the first /model: Tab has
  // candidates; clear the field on hide so the next summon starts empty.
  onVisibleChanged: {
    if (bar.visible) {
      if (bar.backend)
        bar.backend.refreshModels();
      input.forceActiveFocus();
      input.selectAll();
      completion.setInput(input.text, input.cursorPosition);
    } else {
      input.text = "";
      completion.setInput("", 0);
    }
  }

  Connections {
    target: completion
    function onApplied() { bar._applyCompletion(); }
  }

  Rectangle {
    anchors.fill: parent
    anchors.bottomMargin: bar.gap
    radius: Style.radiusS
    color: Color.mSurface
    border.color: Color.mOutline
    border.width: Style.borderS

    ColumnLayout {
      anchors.fill: parent
      anchors.margins: Style.marginM
      // No inter-row spacing: the overlay carries its own padding and must
      // collapse to exactly 0 when inactive so the closed bar is unchanged.
      spacing: 0

      // Grows the bar upward when active; collapses to 0 otherwise.
      QuickBarCompletion {
        id: completion
        Layout.fillWidth: true
        Layout.preferredHeight: completion.implicitHeight
        backend: bar.backend
      }

      RowLayout {
        id: row
        Layout.fillWidth: true
        spacing: Style.marginS

        NIcon {
          icon: "sparkles"
          pointSize: Style.fontSizeXL
          color: Color.mPrimary
        }

        NTextInput {
          id: input
          Layout.fillWidth: true
          placeholderText: I18n.tr("quickbar.placeholder")

          // The completer owns the canonical text; push user edits in and
          // let it (via onApplied) push rewritten completions back out.
          onTextEdited: completion.setInput(input.text, input.cursorPosition)
          onCursorPositionChanged: {
            if (!bar._applying)
              completion.setInput(input.text, input.cursorPosition);
          }

          // The §4.2 keyboard contract. Tab/arrows are gated nowhere — they
          // only ever act on the completer — but Enter falls through to
          // onAccepted→launch whenever the list is closed, so the original
          // launch flow is untouched when no completion is in progress.
          Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Tab) {
              completion.advance();
              event.accepted = true;
            } else if (event.key === Qt.Key_Backtab) {
              completion.move(-1);
              event.accepted = true;
            } else if (event.key === Qt.Key_Down) {
              completion.move(1);
              event.accepted = true;
            } else if (event.key === Qt.Key_Up) {
              completion.move(-1);
              event.accepted = true;
            } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_J) {
              // Ctrl+J / Ctrl+K mirror Down / Up so the list scrolls without
              // leaving the home row — move() is a no-op when no list is open.
              completion.move(1);
              event.accepted = true;
            } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_K) {
              completion.move(-1);
              event.accepted = true;
            } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && completion.active) {
              completion.accept();
              event.accepted = true;
            }
          }
          onAccepted: bar.launch()
          // Esc closes the list first; once closed, a second Esc hides the
          // bar. dismiss() is the exact call the keyboard contract is tested
          // against, so the live path and the check stay in lockstep.
          Keys.onEscapePressed: (event) => {
            if (completion.dismiss() === "hide")
              bar.visible = false;
            event.accepted = true;
          }
        }

        // The "/ for options" affordance already lives in the placeholder;
        // beside Enter we only spell out the launch key.
        NText {
          text: I18n.tr("quickbar.launch-hint")
          color: Color.mOnSurfaceVariant
          pointSize: Style.fontSizeS
        }
      }
    }
  }
}

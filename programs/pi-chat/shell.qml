// pi-chat standalone shell entry point.
//
// One normal toplevel window (FloatingWindow), hidden by default.
// Toggled via `quickshell ipc call -c pi-chat pi-chat toggle` — wire
// to a compositor keybind for summon-on-demand UX. As a regular
// xdg-toplevel it appears in the window list / alt-tab and is
// tiled or floated by the compositor like any other application
// (this replaces the original layer-shell overlay design).
//
// The IpcHandler block exposes the verbs the test harnesses + the
// `pi-chat-toggle` CLI drive: `send`, `sendFile`, `newSession`,
// `selectSession`, `removeSession`, `sendTo`, `listSessions`,
// `sessionMessages`, `lastAssistantText`, `sessionModel`, plus the
// triad `show`/`hide`/`toggle`. They route into PiChatBackend
// (sessions index, skill-config socket, signal-bridge socket) or
// straight to `backend.chat` (the active PiSession).
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

FloatingWindow {
  id: shell

  title: "pi-chat"

  // Initial size request only — once mapped, the compositor sizes the
  // window like any other toplevel (niri tiles it into a column).
  implicitWidth: 560
  implicitHeight: 800
  minimumSize: Qt.size(440, 480)

  color: Color.mSurface
  visible: false

  // Tell the backend when we're showing so it can spawn pi on first
  // visibility and reap idle sessions when we close.
  PiChatBackend {
    id: backend
    panelVisible: shell.visible
  }

  Panel {
    anchors.fill: parent
    backend: backend
    onSettingsRequested: shell.openSettings()
  }

  // The only layer-shell surface in this process: the bottom-center
  // quick-launch bar (Mod+/). Shares the one backend so a session it
  // fires lands in the same index the chat panel reads.
  QuickBar {
    id: quickBar
    backend: backend
  }

  // Persistent settings window — its own toplevel (FloatingWindow)
  // so it gets independent focus and dismissal, like any app dialog.
  property var _settingsWindow: null
  function openSettings() {
    if (!_settingsWindow) {
      _settingsWindow = settingsComponent.createObject(shell);
    }
    _settingsWindow.show();
    _settingsWindow.raise();
  }
  Component {
    id: settingsComponent
    SettingsWindow {}
  }

  // Tap-debounce for the IpcHandler's `tap()` verb. A single tap is
  // wired to a no-op so global keybinds can bind two tap actions
  // (peek / dismiss) on one chord without flicker; a double-tap
  // toggles visibility.
  property real _lastTap: 0

  IpcHandler {
    target: "pi-chat"

    function tap() {
      const now = Date.now();
      if (now - shell._lastTap < 400) toggle();
      shell._lastTap = now;
    }
    function toggle() { shell.visible = !shell.visible; }
    function show() { shell.visible = true; }
    function hide() { shell.visible = false; }
    function settings() { shell.openSettings(); }
    // Toggle the quick-launch bar (Mod+/ via `pi-chat-toggle quickLaunch`).
    function quickLaunch() { quickBar.visible = !quickBar.visible; }

    function send(text: string) { backend.chat?.send(text); }
    function sendFile(path: string) { backend.chat?.sendFile(path, true); }

    // Multi-session verbs. Driven by the test harness and the
    // settings window; same shape across all callers.
    function newSession(name: string): string {
      return backend.newSession?.(name) ?? "";
    }
    // Multi-homing: create a session pinned to a specific executor id.
    function newSessionOn(name: string, executorId: string): string {
      return backend.newSession?.(name, executorId) ?? "";
    }
    function selectSession(id: string) {
      backend.selectSession?.(id);
    }
    function removeSession(id: string) {
      backend.removeSession?.(id);
    }
    function sendTo(id: string, text: string) {
      backend.sendTo?.(id, text);
    }
    function listSessions(): string {
      return backend.listSessions?.() ?? "[]";
    }

    // Test probes. JSON-returning getters so the harness can parse
    // without scraping pi's session.jsonl. Pure routing — the lookup
    // and predicates live on PiChatBackend's per-session read surface.
    function sessionMessages(id: string): string {
      return JSON.stringify(backend.sessionMessages(id));
    }
    function lastAssistantText(id: string): string {
      return backend.lastAssistantText(id);
    }
    function sessionModel(id: string): string {
      return JSON.stringify(backend.sessionModel(id));
    }
  }
}

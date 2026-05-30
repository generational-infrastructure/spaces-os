// pi-chat standalone shell entry point.
//
// One PanelWindow anchored to the right edge of the focused screen,
// hidden by default. Toggled via `quickshell ipc call -c pi-chat
// pi-chat toggle` — wire to a compositor keybind for summon-on-demand
// UX. Layer-shell surface, so the panel never appears in alt-tab or
// the task switcher (that's the design point — see PI_CHAT_STANDALONE_PLAN
// for the "not visible to alt-tab" requirement that drove the choice).
//
// The IpcHandler block exposes the verbs the test harnesses + the
// `pi-chat-toggle` CLI drive: `send`, `sendFile`, `newSession`,
// `selectSession`, `removeSession`, `sendTo`, `listSessions`,
// `sessionMessages`, `lastAssistantText`, plus the visibility
// triad `show`/`hide`/`toggle`. They route into PiChatBackend
// (sessions index, skill-config socket, signal-bridge socket) or
// straight to `backend.chat` (the active PiSession).
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons


PanelWindow {
  id: shell

  // Anchored right edge, full height. exclusiveZone:0 means the
  // panel overlays whatever is below it instead of pushing content
  // aside — chat is transient, not a permanent bar.
  anchors {
    top: true
    right: true
    bottom: true
  }
  // Width follows the screen: the golden-ratio minor portion (1/phi^2 =
  // 0.382), so the app left visible behind the panel gets the major 61.8%.
  // screen.width is logical (post-HiDPI) pixels, so the proportion already
  // adapts across resolutions; the clamp keeps it usable on small laptops
  // and from sprawling on ultrawides.
  implicitWidth: Math.round(Math.min(900, Math.max(440, screen.width * 0.382)))
  exclusiveZone: 0
  // Layer-shell layer choice: Top is enough for "above normal
  // windows, below screen-edge OSDs/lockscreens". Overlay would
  // hover over the bar too aggressively.
  WlrLayershell.layer: WlrLayer.Top
  // Don't yank focus from whatever the user was doing when they
  // summon the chat. The compose box explicitly requests focus when
  // tapped — until then the underlying app keeps the keyboard.
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

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
  }

  // Persistent settings window. Lives outside the layer-shell
  // surface (FloatingWindow) so it has a normal title bar, focus,
  // and dismissal — what users expect of a settings dialog.
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

    function send(text: string) { backend.chat?.send(text); }
    function sendFile(path: string) { backend.chat?.sendFile(path, true); }

    // Multi-session verbs. Driven by the test harness and the
    // settings window; same shape across all callers.
    function newSession(name: string): string {
      return backend.newSession?.(name) ?? "";
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
    // without scraping pi's session.jsonl. Same shape as the plugin.
    function sessionMessages(id: string): string {
      const map = backend._sessionObjs;
      const obj = (id && map && map[id]) ? map[id] : backend.chat;
      if (!obj) return "[]";
      return JSON.stringify(obj.messages || []);
    }
    function lastAssistantText(id: string): string {
      const map = backend._sessionObjs;
      const obj = (id && map && map[id]) ? map[id] : backend.chat;
      if (!obj || !Array.isArray(obj.messages)) return "";
      for (let i = obj.messages.length - 1; i >= 0; i--) {
        const m = obj.messages[i];
        if (m && m.from === "peer" && (m.type || "") === "" && m.text) return m.text;
      }
      return "";
    }
  }
}

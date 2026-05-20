// Test shell for the chat panel's "hide thinking" toggle.
//
// Covers two surfaces:
//
//   1. MsgFilter — pure filter that decides which session messages
//      the ListView renders. Driven through a local `showThinking`
//      property that mimics Panel.qml's binding.
//
//   2. PluginSettings — the helper that flips the persisted toggle
//      against the noctalia plugin API. Driven through `stubApi`,
//      which mirrors the real surface noctalia exposes
//      (`pluginSettings` + `manifest` + `saveSettings()`) and
//      deliberately omits anything noctalia does NOT expose. If the
//      helper reaches for a non-existent method, the stub stays
//      untouched and the driver's assertions trip.
//
// No noctalia, no compositor, no pi process.
import QtQuick
import Quickshell
import Quickshell.Io
import "MsgFilter.js" as Filter
import "PluginSettings.js" as PluginSettings

Item {
  id: root

  // Mirrors what Panel.qml binds to pluginApi.pluginSettings.showThinking.
  // Defaults to "thinking is visible" so users see model reasoning by
  // default.
  property bool showThinking: true

  // Faithful noctalia plugin-API stub. Only the surface real plugins
  // can rely on lives here — adding `setPluginSetting` would mask the
  // exact wiring bug this test exists to catch.
  QtObject {
    id: stubApi
    property var pluginSettings: ({})
    property var manifest: ({
      metadata: { defaultSettings: { showThinking: true } }
    })
    property int saveCalls: 0
    function saveSettings() {
      saveCalls += 1;
      // Mirror noctalia: replace the reference so QML bindings re-evaluate.
      pluginSettings = Object.assign({}, pluginSettings);
    }
  }

  // Mirrors Panel.qml's `showThinking` binding — fed by the same
  // `pluginSettings` → `manifest.defaultSettings` → hard fallback
  // chain. Used by the driver to confirm the displayed state, not
  // just the stored one.
  readonly property bool resolvedShowThinking:
    stubApi.pluginSettings.showThinking
      ?? stubApi.manifest?.metadata?.defaultSettings?.showThinking
      ?? true

  PiSession {
    id: session
    sessionId: "test"
    piBin: "/bin/false"
    stateDir: Quickshell.env("TEST_STATE_DIR")
    piAgentDir: Quickshell.env("TEST_AGENT_DIR")
    workspacePath: Quickshell.env("TEST_WORKSPACE")
    llmUrl: "http://127.0.0.1:1"
  }

  IpcHandler {
    target: "test:thinking-toggle"

    // ── MsgFilter surface ───────────────────────────────────────

    function injectEvent(jsonStr: string) {
      const ev = JSON.parse(jsonStr);
      session._handleEvent(ev);
    }
    function rawMessages(): string {
      return JSON.stringify(session.messages || []);
    }
    function visibleMessages(): string {
      return JSON.stringify(Filter.visible(session.messages || [], root.showThinking));
    }
    function setShowThinking(value: bool) { root.showThinking = value; }
    function getShowThinking(): bool { return root.showThinking; }

    // ── PluginSettings surface ──────────────────────────────────

    // Invokes the exact same helper the panel's toggle button calls.
    // Driver asserts the bool flipped + saveSettings was called.
    function clickToggle() {
      PluginSettings.toggleBool(stubApi, "showThinking");
    }
    function resolvedShowThinking(): bool { return root.resolvedShowThinking; }
    function storedShowThinking(): string {
      // JSON so the driver can distinguish "undefined" (relying on
      // manifest default) from a stored boolean.
      return JSON.stringify(stubApi.pluginSettings.showThinking ?? null);
    }
    function saveCalls(): int { return stubApi.saveCalls; }
  }
}

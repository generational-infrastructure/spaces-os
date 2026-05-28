// User settings singleton.
//
// Replaces the noctalia plugin's split between `pluginApi.pluginSettings`
// (user prefs: maxHistory, showThinking, …) and noctalia's global
// `Settings.data.ui.font*` (font preferences). Standalone owns the
// whole surface via a single JSON file at:
//
//   ~/.config/pi-chat/settings.json
//
// Plain `FileView` + `JsonAdapter` — same machinery PiChatBackend
// already uses for `/etc/distro/pi-chat.json`. The file is created
// on first write; missing keys fall back to defaults declared on
// the adapter.
//
// Bubble/Panel access fonts via `Settings.data.ui.fontDefault` etc.,
// mirroring the noctalia data path so the port is a verbatim import
// swap. We expose a stable `data` reference pointing at the adapter
// so the dotted lookups resolve transparently.
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
  id: root

  // The adapter itself doubles as the `data` namespace: Bubble/Panel
  // already write `Settings.data.ui.fontDefault`, and that resolves
  // straight to the JsonObject below. New top-level prefs land at
  // `Settings.data.maxHistory` etc. — same dotted form throughout.
  readonly property alias data: _adapter

  // Mutation surface used by the settings window. After flipping a
  // property, callers must `Settings.persist()` so the change lands
  // on disk and survives a restart.
  function persist() { _file.writeAdapter(); }

  readonly property string configDir:
    (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config"))
    + "/pi-chat"

  component UiPrefs : JsonObject {
    property string fontDefault: "Inter"
    property string fontFixed: "JetBrains Mono"
    property real fontDefaultScale: 1.0
  }


  property FileView _file: FileView {
    path: root.configDir + "/settings.json"
    printErrors: false
    JsonAdapter {
      id: _adapter
      // User prefs (previously in noctalia's pluginSettings)
      property int maxHistory: 200
      property string defaultWorkspaceRoot: ""
      property int idleTimeoutMinutes: 10
      property string memoryHigh: "4G"
      property bool showThinking: true

      // UI preferences (previously in noctalia's Settings.data.ui).
      property UiPrefs ui: UiPrefs {}
    }
    onLoadFailed: () => {
      // First launch: file doesn't exist; write defaults so the
      // settings window has something to bind against.
      writeAdapter();
    }
  }
}

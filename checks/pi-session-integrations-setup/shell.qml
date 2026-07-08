// Test host for the panel's integration device-setup flow.
//
// Mounts the real SettingsWindow pointed at a fake broker socket and
// exposes visual-tree introspection over IPC so the driver can assert:
//   - the setup button appears ONLY for enabled + setup-capable
//     integrations,
//   - the QR Image element becomes visible (with the streamed png) after
//     the broker's qr event,
//   - a `done` event flips the pane to its success state and auto-closes
//     the flow (setupFor clears),
//   - an `error` event surfaces the error text and keeps the pane open.
//
// The bridge auto-lists on startup, so the driver waits on the delegates
// materialising (setupBtn-<name> existing) rather than any test-only
// accessor on SettingsWindow.
import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
  id: shell

  property var win: SettingsWindow {
    id: settingsWin
    visible: true
    integrationsSockPath: Quickshell.env("TEST_INTEGRATIONS_SOCK")
  }

  // Depth-first search of the window's visual tree by objectName.
  function _find(obj, name) {
    if (!obj)
      return null;
    if (obj.objectName === name)
      return obj;
    const kids = obj.children || [];
    for (let i = 0; i < kids.length; i++) {
      const r = shell._find(kids[i], name);
      if (r)
        return r;
    }
    return null;
  }
  function _node(name) { return shell._find(settingsWin.contentItem, name); }

  property var ipc: IpcHandler {
    target: "test:setup"

    // Element introspection.
    function exists(name: string): bool { return shell._node(name) !== null; }
    function visibleOf(name: string): string {
      const n = shell._node(name);
      return n ? String(n.visible) : "missing";
    }
    // Emit the found button's clicked() — exercises the delegate's real
    // onClicked wiring, not a shortcut into the bridge.
    function click(name: string): string {
      const n = shell._node(name);
      if (!n)
        return "missing";
      n.clicked();
      return "ok";
    }
    function qrSource(): string {
      const n = shell._node("setupQr");
      return n ? String(n.source) : "missing";
    }
    function statusText(): string {
      const n = shell._node("setupStatus");
      return n ? String(n.text) : "missing";
    }

    // Prompt-input helpers: type a reply, then read the echo mode so the
    // driver can assert secret-field masking.
    function setText(name: string, value: string): string {
      const n = shell._node(name);
      if (!n)
        return "missing";
      n.text = value;
      return "ok";
    }
    function echoModeOf(name: string): string {
      const n = shell._node(name);
      if (!n)
        return "missing";
      return n.echoMode === TextInput.Password ? "password" : "normal";
    }

    // Window-level setup-flow state.
    function setupFor(): string { return settingsWin.setupFor; }
    function setupPhase(): string { return settingsWin.setupPhase; }
  }
}

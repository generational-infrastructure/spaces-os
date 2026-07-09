// Test host for the panel's Nix-managed integration-profiles rendering.
//
// Mounts the real SettingsWindow pointed at a fake broker whose `list` reply
// carries managed/shadowed profiles and enabledByNix verdicts, and exposes
// visual-tree introspection over IPC so the driver can assert the read-only
// managed-profile GUI contract (design doc §10.7):
//   - a managed profile renders a lock badge + STATIC config value rows, and
//     its edit/remove affordances are NOT in the tree (a distinct read-only
//     delegate, not disabled inputs),
//   - an enabledByNix integration renders a static enable label instead of
//     the enable/disable toggle,
//   - the add-account input stays available on multiProfile integrations,
//   - an add-profile draft naming a managed profile is blocked (draftError).
//
// The bridge auto-lists on startup, so the driver waits on the managed
// delegates materialising (a known objectName existing) rather than any
// test-only accessor on SettingsWindow.
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
    target: "test:managed"

    // Element introspection: presence proves a delegate branch was taken
    // (managed vs editable), so the driver asserts exists()==false for the
    // affordances the read-only path must NOT instantiate.
    function exists(name: string): bool { return shell._node(name) !== null; }
    function visibleOf(name: string): string {
      const n = shell._node(name);
      return n ? String(n.visible) : "missing";
    }
    // Read a rendered text node's content (static config rows, badges) so the
    // driver can assert the managed value is displayed, not just the row.
    function textOf(name: string): string {
      const n = shell._node(name);
      return n ? String(n.text) : "missing";
    }
    // Drive the add-account input: typing a managed profile's name must flip
    // the draft into its blocked state (draftError visible, draft suppressed).
    function setText(name: string, value: string): string {
      const n = shell._node(name);
      if (!n)
        return "missing";
      n.text = value;
      return "ok";
    }
  }
}

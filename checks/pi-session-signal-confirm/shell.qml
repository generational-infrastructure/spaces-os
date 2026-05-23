// Test shell for SignalConfirm.
//
// Mounts the component pointed at a unix socket address provided via
// env. The driver spawns a Python fake bridge bound to that path and
// observes/manipulates SignalConfirm's state via IPC.
import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  SignalConfirm {
    id: sc
    sockPath: Quickshell.env("TEST_SIGNAL_PANEL_SOCK")
    active: true
  }

  IpcHandler {
    target: "test:signal-confirm"

    function pending(): string { return JSON.stringify(sc.pending || []); }
    function connected(): bool { return sc.connected; }
    function approve(token: string) { sc.approve(token); }
    function deny(token: string) { sc.deny(token); }
  }
}

// Test shell for IntegrationsBridge.
//
// Mounts the broker client pointed at a unix socket address provided via env.
// The driver spawns a Python fake broker bound to that path and drives the
// list / set-secret / enable / disable round-trips through IPC, observing the
// bridge's state.
import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  IntegrationsBridge {
    id: bridge
    sockPath: Quickshell.env("TEST_INTEGRATIONS_SOCK")
  }

  IpcHandler {
    target: "test:integrations"

    function refresh() { bridge.refresh(); }
    function setSecret(integration: string, name: string, value: string) {
      bridge.setSecret(integration, name, value);
    }
    function enable(integration: string) { bridge.enable(integration); }
    function disable(integration: string) { bridge.disable(integration); }

    function loaded(): bool { return bridge.loaded; }
    function lastError(): string { return bridge.lastError; }
    function integrationsJson(): string { return JSON.stringify(bridge.integrations || []); }
  }
}

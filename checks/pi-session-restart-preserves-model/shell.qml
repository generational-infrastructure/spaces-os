// Test shell for PiSession.restart() model preservation.
//
// Mounts a PiSession pointed at a fake pi binary (records stdin frames
// to a witness file) and a stub systemd-run wrapper that strips all
// sandbox flags. IpcHandler exposes the bits the driver needs to drive
// setModel/spawn/restart and inspect state.
import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  PiSession {
    id: session
    sessionId: "test"
    piBin: Quickshell.env("TEST_PI_BIN")
    stateDir: Quickshell.env("TEST_STATE_DIR")
    piAgentDir: Quickshell.env("TEST_AGENT_DIR")
    workspacePath: Quickshell.env("TEST_WORKSPACE")
    llmUrl: "http://127.0.0.1:1"
    memoryEnabled: false
    trusted: true
  }

  IpcHandler {
    target: "test:restart-model"

    function spawnSession() { session.spawn(); }
    function setModel(provider: string, modelId: string) {
      session.setModel(provider, modelId);
    }
    function restart() { session.restart(); }
    function modelPref(): string { return session.modelPref; }
  }
}

// Test shell for the sandboxBinds extension point.
//
// Mounts PiSession with a fixture sandboxBinds list, then exposes
// the sandbox command PiSession would hand to systemd-run as plain
// JSON via IPC. The driver compares the produced --property=BindPaths
// / --property=BindReadOnlyPaths flags against expected entries.
//
// No pi process, no LLM, no compositor. We never let the session run;
// we only call _buildCommand() and read it back.
import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  PiSession {
    id: session
    sessionId: "test"
    piBin: "/bin/false"
    stateDir: Quickshell.env("TEST_STATE_DIR")
    piAgentDir: Quickshell.env("TEST_AGENT_DIR")
    workspacePath: Quickshell.env("TEST_WORKSPACE")
    llmUrl: "http://127.0.0.1:1"
    // Driver feeds this in via JSON env var so a single shell.qml
    // can cover many fixtures (rw/ro/optional/%h/%t/explicit target).
    sandboxBinds: {
      const raw = Quickshell.env("TEST_SANDBOX_BINDS");
      try { return raw ? JSON.parse(raw) : []; }
      catch (e) { return []; }
    }
  }

  IpcHandler {
    target: "test:sandbox-binds"

    function buildCommand(): string {
      return JSON.stringify(session._buildCommand());
    }
  }
}

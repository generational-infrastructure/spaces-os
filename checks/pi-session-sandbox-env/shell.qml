// Test shell for the sandbox env-forwarding contract.
//
// Mounts PiSession, then exposes the sandbox command PiSession would
// hand to systemd-run as plain JSON via IPC. The driver asserts the
// argv contains `--setenv=PATH=<expected>` so transient services see
// the chat shell's PATH rather than the minimal user@.service PATH.
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
  }

  IpcHandler {
    target: "test:sandbox-env"

    function buildCommand(): string {
      return JSON.stringify(session._buildCommand());
    }
  }
}

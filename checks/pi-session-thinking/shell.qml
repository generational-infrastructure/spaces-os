// Test shell that hosts PiSession, injects RPC events via IPC, and
// exposes the resulting messages list. Tests thinking event handling
// without needing a real pi process or LLM.
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
    target: "test:thinking"

    // Inject a raw RPC event into PiSession's handler — same shape
    // as what arrives on pi's stdout.
    function injectEvent(jsonStr: string) {
      const ev = JSON.parse(jsonStr);
      session._handleEvent(ev);
    }

    function messages(): string {
      return JSON.stringify(session.messages || []);
    }

    function streaming(): bool { return session.streaming; }
    function typing(): bool { return session.typing; }
  }
}

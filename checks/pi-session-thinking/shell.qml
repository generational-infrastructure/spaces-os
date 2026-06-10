// Test shell that hosts PiSession, injects RPC events via IPC, and
// exposes the resulting messages list. Tests thinking event handling
// without needing a pi-sessiond executor or LLM.
import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  PiSession {
    id: session
    sessionId: "test"
    // No executor configured — spawn() is a no-op; events arrive only
    // via the injectEvent IPC below, mimicking daemon `event` payloads.
    workspacePath: Quickshell.env("TEST_WORKSPACE")
  }

  IpcHandler {
    target: "test:thinking"

    // Inject a raw RPC event into PiSession's handler — same payload
    // a daemon `event` envelope carries.
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

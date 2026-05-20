// Minimal test shell that hosts a single PiSession and exposes the
// bits of its surface the chat panel actually relies on through
// `qs ipc call test:pi-session …`.
//
// Why no PiChatBackend / noctalia at all: the bug we're chasing is in
// PiSession.qml's `_readImage` → `_appendMessage` path. Loading the
// full backend (which requires noctalia singletons, a configured
// /etc/distro/pi-chat.json, and a live systemd user manager for
// per-session sandboxing) just to drive `sendFile()` would multiply
// the failure surface a hundredfold. Mounting PiSession directly with
// stubbed env keeps the test honed on the actual contract.
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
    llmUrl: Quickshell.env("TEST_LLM_URL")
  }

  IpcHandler {
    target: "test:pi-session"

    function sendFile(path: string) {
      session.sendFile(path, false);
    }
    function send(text: string) {
      session.send(text);
    }
    function messages(): string {
      return JSON.stringify(session.messages || []);
    }
    function streaming(): bool { return session.streaming; }
    function typing(): bool { return session.typing; }
    function lastError(): string { return session.lastError || ""; }
  }
}

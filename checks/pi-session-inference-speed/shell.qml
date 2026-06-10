// Test shell that hosts PiSession and injects raw RPC events via IPC,
// exposing the resulting messages list so the driver can assert that
// tps is computed from `message_end.message.usage.output` over the
// wall clock since the first text_start of the assistant message.
//
// Tests pin elapsed time by writing PiSession's internal
// `_assistantStartedAt` to (now - elapsedMs) right before the
// message_end injection, so the deterministic part is the elapsed
// delta — not Date.now() itself.
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
    target: "test:tps"

    // Inject a raw RPC event — same payload a daemon `event` envelope carries.
    function injectEvent(jsonStr: string) {
      const ev = JSON.parse(jsonStr);
      session._handleEvent(ev);
    }

    // Pin elapsed time for the active assistant message by backdating
    // _assistantStartedAt. Negative or zero elapsedMs leaves the field
    // alone.
    function setElapsedMs(elapsedMs: int) {
      if (elapsedMs > 0) {
        session._assistantStartedAt = Date.now() - elapsedMs;
      }
    }

    // Read the current value so the driver can confirm reset after agent_end.
    function startedAt(): int {
      return session._assistantStartedAt;
    }

    function messages(): string {
      return JSON.stringify(session.messages || []);
    }
  }
}

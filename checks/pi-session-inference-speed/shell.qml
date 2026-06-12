// Test shell that hosts PiSession and injects raw RPC events via IPC,
// exposing the resulting messages list so the driver can assert that
// tps is computed from `message_end.message.usage.output` over the
// wall clock since the first text_start of the assistant message.
//
// Tests pin elapsed time atomically: injectEventWithElapsed backdates
// PiSession's internal `_assistantStartedAt` to (now - elapsedMs) and
// injects the event in the same synchronous call, so no IPC round-trip
// latency can leak into the measured window.
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
    // _assistantStartedAt, then inject the event in the same call.
    // Backdate and injection share one synchronous JS frame, so the
    // elapsed delta the event sees is exact (±1 ms clock tick).
    function injectEventWithElapsed(elapsedMs: int, jsonStr: string) {
      const ev = JSON.parse(jsonStr);
      if (elapsedMs > 0) {
        session._assistantStartedAt = Date.now() - elapsedMs;
      }
      session._handleEvent(ev);
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

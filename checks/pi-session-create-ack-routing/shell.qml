// Headless host for the create-ack routing contract.
//
// Mounts the real PiChatBackend against a scripted fake daemon. The
// fake daemon interleaves a plain attach ack with a pending
// create_session ack; the probes expose each entry's daemonSessionId
// so the driver can assert the create resolver was not consumed by
// the attach ack (which would stamp the wrong daemon id).
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

Item {
  id: root

  PiChatBackend {
    id: backend
    panelVisible: true
  }

  IpcHandler {
    target: "test:ack-routing"

    function ping(): bool { return true; }
    function openPanel() { backend.chat?.listModels(); }
    function newSession(name: string): string {
      return backend.newSession?.(name) ?? "";
    }
    function rawSessions(): string {
      return JSON.stringify(backend.sessionsList.map(s => ({
        id: s.id,
        name: s.name,
        executor: s.executor,
        daemonSessionId: s.daemonSessionId || "",
      })));
    }

    // Diagnostic: transport-state internals of the active session, for
    // pinpointing where a create stalls when the contract fails.
    function sessionDebug(): string {
      const c = backend.chat;
      if (!c) return "{}";
      return JSON.stringify({
        shouldRun: c._shouldRun ?? null,
        creating: c._wsCreating ?? null,
        attached: c._wsAttached ?? null,
        daemonId: c._daemonSessionId ?? null,
        pending: (c._wsPending ?? []).length,
        streaming: c.streaming ?? null,
        hasExecutor: !!c.executor,
        execConnected: c.executor ? c.executor.connected : null,
        execWelcomed: c.executor ? c.executor._welcomed : null,
      });
    }
  }
}

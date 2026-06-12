// Headless host for the stale daemon-session recovery contract.
//
// Mounts the real PiChatBackend against a real pi-sessiond. The staged
// sessions.json carries a daemonSessionId the daemon does not know —
// the shape a deployment is left with after the daemon's state was
// wiped, the session was deleted by another client, or a turnless
// session never committed its jsonl. The probes expose the session's
// data layer so the driver can assert the entry recovers (fresh daemon
// session, models populated) instead of wedging attached-but-dead.
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
    target: "test:stale-recovery"

    function ping(): bool { return true; }

    // What Panel.onCompleted does when the panel opens: ask the active
    // session for its model list (spawning/attaching it on demand).
    function openPanel() { backend.chat?.listModels(); }

    function modelsCount(): int { return (backend.chat?.models ?? []).length; }
    function activeModel(): string { return backend.chat?.activeModel ?? ""; }

    function rawSessions(): string {
      return JSON.stringify(backend.sessionsList.map(s => ({
        id: s.id,
        executor: s.executor,
        daemonSessionId: s.daemonSessionId || "",
      })));
    }
    // Diagnostic: the raw adapter view next to the backend's list —
    // tells load-vs-clobber stories apart when the index goes missing.
    function debugState(): string {
      return JSON.stringify({
        adapterSessions: backend._sessions.sessions,
        adapterActive: backend._sessions.activeSessionId,
        adapterImportTime: backend._sessions.lastImportTime,
        active: backend.activeSessionId,
      });
    }
  }
}

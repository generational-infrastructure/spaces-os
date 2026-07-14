// Headless host for the model-pick persistence contract test.
//
// Mounts the real PiChatBackend with a single REMOTE executor configured
// (injected via $SPACES_PI_CHAT_EXECUTORS) and the panel reported hidden,
// then exposes IPC so the driver can mint sessions, spawn them, run the
// Panel's fire-and-forget setModel path, and read back both the raw index
// entry (the durable carrier) and the LIVE object's modelPref (to catch
// the reconciler clobbering a pick that never reached the entry).
//
// The whole pi-chat plugin tree is staged alongside this file by the
// driver, so PiExecutor / PiSession / qs.Commons resolve exactly as in
// production.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

Item {
  id: root

  PiChatBackend {
    id: backend
    panelVisible: false
  }

  IpcHandler {
    target: "test:modelpick"

    function newSession(name: string, executor: string): string {
      return backend.newSession(name, executor);
    }

    function spawnSession(id: string) {
      const o = backend._sessionObjs[id];
      if (o) o.spawn();
    }

    // The Panel's model-picker path (Panel.qml header combobox):
    // fire-and-forget PiSession.setModel on the live object.
    function setModel(id: string, provider: string, modelId: string) {
      const o = backend._sessionObjs[id];
      if (o) o.setModel(provider, modelId);
    }

    // The LIVE object's modelPref — what the next create_session/restart
    // would actually carry for this session.
    function modelPrefOf(id: string): string {
      const o = backend._sessionObjs[id];
      return o ? (o.modelPref || "") : "__missing__";
    }

    // Raw index including the entry's model field, which listSessions()
    // omits but the durable-carrier assertion needs.
    function rawSessions(): string {
      return JSON.stringify(backend.sessionsList.map(s => ({
        id: s.id,
        name: s.name,
        model: s.model || "",
        daemonSessionId: s.daemonSessionId || "",
      })));
    }

    function executorConnected(id: string): bool {
      const e = backend._executorById[id];
      return e ? !!e.connected : false;
    }
  }
}

// Headless host for the restart-preserves-model contract test.
//
// Mounts the real PiChatBackend with a single REMOTE executor configured
// (injected via $SPACES_PI_CHAT_EXECUTORS) and the panel reported hidden,
// then exposes IPC so the driver can mint a session whose entry carries a
// model pref, spawn it, round-trip a set_model command, restart() it, and
// read back the raw index (incl. daemonSessionId) to assert the
// delete+create restart re-bound the entry to a fresh daemon session.
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

  // Resolution payload of the last setModelAndWait round-trip. Non-empty
  // only after the mock daemon echoed the request id on its set_model
  // response — proves the command-with-id seam works against the mock.
  property string lastSetModelResult: ""

  PiChatBackend {
    id: backend
    panelVisible: false
  }

  IpcHandler {
    target: "test:restart"

    // Seed the model pref on the session ENTRY (entry.model), not just the
    // live object: the reconciler re-asserts obj.modelPref from entry.model
    // on every sessionsList reassignment, and restart() reassigns the list
    // when it clears daemonSessionId — so the entry is the durable carrier
    // the fresh create_session reads its model from.
    function newSessionWithModel(name: string, executor: string, model: string): string {
      return backend.newSession(name, executor, { model: model });
    }

    function spawnSession(id: string) {
      const o = backend._sessionObjs[id];
      if (o) o.spawn();
    }

    // The awaited set_model path: sends a `command` envelope whose payload
    // carries a request id; resolves only when the daemon echoes that id on
    // the matching {type:"response", command:"set_model", ...} event.
    function setModelWait(id: string, provider: string, modelId: string) {
      const o = backend._sessionObjs[id];
      if (!o) return;
      o.setModelAndWait(provider, modelId)
        .then(d => root.lastSetModelResult = JSON.stringify(d))
        .catch(e => root.lastSetModelResult = "ERROR: " + e);
    }

    function setModelResult(): string {
      return root.lastSetModelResult;
    }

    // The contract under test: detach + delete_session for the old daemon
    // id, clear the entry's daemonSessionId, then a fresh create_session
    // carrying model=modelPref.
    function restartSession(id: string) {
      const o = backend._sessionObjs[id];
      if (o) o.restart();
    }

    // Raw index including executor + daemonSessionId, which listSessions()
    // omits but the rebind assertion needs.
    function rawSessions(): string {
      return JSON.stringify(backend.sessionsList.map(s => ({
        id: s.id,
        name: s.name,
        executor: s.executor,
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

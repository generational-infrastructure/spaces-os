// Headless host for the attach-image WS contract check.
//
// Mounts the real PiChatBackend with one executor injected via
// $SPACES_PI_CHAT_EXECUTORS (the panel's test seam — /etc/spaces/pi-chat.json
// is root-owned and unwritable in the build sandbox), pointed at a REAL
// pi-sessiond. PiSession has no local pi-spawn path anymore; sendFile's
// prompt rides the executor's WebSocket, so the harness exercises the exact
// production wiring: backend -> PiExecutor -> daemon -> embedded pi SDK.
//
// The whole pi-chat plugin tree is staged alongside this file by the driver,
// so PiExecutor / PiSession / qs.Commons resolve exactly as in production.
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
    target: "test:pi-session"

    function executorConnected(id: string): bool {
      const e = backend._executorById[id];
      return e ? !!e.connected : false;
    }

    // Create a panel session pinned to the given executor; returns its id.
    function newSessionOn(name: string, executor: string): string {
      return backend.newSession(name, executor);
    }

    // The paperclip / drag-and-drop entry point under test.
    function sendFile(id: string, path: string) {
      const o = backend._sessionObjs[id];
      if (o) o.sendFile(path, false);
    }

    function messages(id: string): string {
      const o = backend._sessionObjs[id];
      return JSON.stringify((o && o.messages) || []);
    }

    function lastError(id: string): string {
      const o = backend._sessionObjs[id];
      return (o && o.lastError) || "";
    }
  }
}

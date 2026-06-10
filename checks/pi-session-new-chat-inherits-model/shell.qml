// Headless host for the new-chat model-inheritance contract.
//
// The whole pi-chat tree is mirrored beside this file (real Commons,
// real ModelFrecency) so backend.newSession() exercises the same
// inheritance path the panel's "+" button hits. A single executor is
// injected via $SPACES_PI_CHAT_EXECUTORS; the panel is reported hidden,
// so nothing spawns until the driver sends a prompt.
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
    target: "test:new-chat-model"

    // Touching the singleton constructs it and arms its async FileView
    // load. The driver waits for >=1 before creating sessions, so
    // mostRecent() reads a settled store.
    function frecencyLoadGen(): string {
      return String(ModelFrecency.loadGeneration);
    }

    function newSession(name: string): string {
      return backend.newSession(name);
    }

    function sendTo(id: string, text: string) {
      backend.sendTo(id, text);
    }

    // Unit seam for the remote-import path. _importRemoteSessions
    // mints entries via _freshSessionEntry and must keep model "".
    // An imported session's model lives on the daemon side, not on
    // the panel entry.
    function freshEntryModel(): string {
      const e = backend._freshSessionEntry("probe", "probe", "remote-exec");
      return e.model === "" ? "<empty>" : String(e.model);
    }

    function executorConnected(id: string): bool {
      const e = backend._executorById[id];
      return e ? !!e.connected : false;
    }
  }
}

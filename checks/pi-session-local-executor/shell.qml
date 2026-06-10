// Headless host for the loopback-executor wiring check.
//
// Mounts the real PiChatBackend pointed (via $SPACES_PI_CHAT_CONFIG) at a
// fixture pi-chat.json and exposes IPC so the driver can read the
// materialized executors list and the live connection state of the
// loopback executor. The whole pi-chat plugin tree is staged alongside
// this file by the driver, so PiExecutor / PiSession / qs.Commons resolve
// exactly as in production.
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
    target: "test:localexec"

    // Sentinel proving the fixture config actually loaded — the regression
    // run asserts an EMPTY executors list, which must not pass trivially
    // before the FileView fires.
    function cfgModel(): string {
      return backend._cfg.defaultModel;
    }

    function executorsJson(): string {
      return JSON.stringify(backend.executors);
    }

    function executorConnected(id: string): bool {
      const e = backend._executorById[id];
      return e ? !!e.connected : false;
    }
  }
}

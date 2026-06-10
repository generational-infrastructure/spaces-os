// Headless host for the quick-launch background-agent contract.
//
// Mounts the real PiChatBackend with the panel reported hidden
// (panelVisible: false) and a single "host" executor — a real
// pi-sessiond on loopback — injected via $SPACES_PI_CHAT_EXECUTORS.
// The driver fires backend.launchBackground(prompt) over IPC and reads
// back the index and per-session state to assert the background session
// lands on the executor, streams its reply over the WebSocket, and
// notifies exactly once. The whole pi-chat plugin tree is staged
// alongside this file by the driver, so `import qs.Commons` and the
// PiExecutor / PiSession children resolve exactly as they do under the
// production shell.qml.
//
// No window: the feature under test is the backend's hidden-panel
// launch + completion-notification behaviour, which is independent of
// the QuickBar layer-shell surface (that surface is covered by qmllint
// + the manual VM pass).
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
    target: "test:quick-launch"

    function launchBackground(prompt: string): string {
      return backend.launchBackground(prompt);
    }
    function panelVisible(): bool { return backend.panelVisible; }

    function activeSessionId(): string { return backend.activeSessionId; }
    function selectSession(id: string) { backend.selectSession(id); }

    // Raw index including executor + daemonSessionId, which listSessions()
    // omits but the pinned-to-"host" and create-acked assertions need.
    function rawSessions(): string {
      return JSON.stringify(backend.sessionsList.map(s => ({
        id: s.id,
        name: s.name,
        executor: s.executor,
        daemonSessionId: s.daemonSessionId || "",
      })));
    }

    function executorConnected(id: string): bool {
      const e = backend._executorById[id];
      return e ? !!e.connected : false;
    }

    // True once spawn() marked the session running on its executor —
    // the hidden-panel launch must flip this without the panel ever
    // opening.
    function sessionStreaming(id: string): bool {
      const o = backend._sessionObjs[id];
      return o ? !!o.streaming : false;
    }
    function lastAssistantText(id: string): string {
      const o = backend._sessionObjs[id];
      if (!o || !Array.isArray(o.messages)) return "";
      for (let i = o.messages.length - 1; i >= 0; i--) {
        const m = o.messages[i];
        if (m && m.from === "peer" && (m.type || "") === "" && m.text) return m.text;
      }
      return "";
    }
  }
}

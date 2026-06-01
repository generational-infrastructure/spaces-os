// Headless host for the quick-launch background-agent contract.
//
// Mounts the real PiChatBackend with the panel reported hidden
// (panelVisible: false) and drives backend.launchBackground(prompt)
// over IPC. The whole pi-chat plugin tree is staged alongside this
// file by the driver, so `import qs.Commons` and the PiSession /
// SignalConfirm / OpenUrlListener children resolve exactly as they do
// under the production shell.qml.
//
// No window: the feature under test is the backend's headless spawn +
// completion-notification + idle-reap behaviour, which is independent
// of the QuickBar layer-shell surface (that surface is covered by
// qmllint + the manual VM pass).
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
    function setPanelVisible(v: bool) { backend.panelVisible = v; }
    function panelVisible(): bool { return backend.panelVisible; }
    function reapIdle() { backend._reapIdle(); }

    function activeSessionId(): string { return backend.activeSessionId; }
    function selectSession(id: string) { backend.selectSession(id); }
    function listSessions(): string { return backend.listSessions(); }

    function sessionStreaming(id: string): bool {
      const o = backend._sessionObjs[id];
      return o ? !!o.streaming : false;
    }
    function sessionBusy(id: string): bool {
      const o = backend._sessionObjs[id];
      return o ? !!o.busy : false;
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

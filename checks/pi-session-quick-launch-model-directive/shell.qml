// Headless host for the model-directive launch contract.
//
// Same staging as pi-session-quick-launch (the whole pi-chat tree is
// mirrored beside this file, panel reported hidden), but the launch
// verb forwards a model so the driver can prove launchBackground applies
// it to the worker before the prompt turn runs.
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

    function launchBackground(prompt: string, model: string): string {
      return backend.launchBackground(prompt, { model: model });
    }
    function panelVisible(): bool { return backend.panelVisible; }

    function activeSessionId(): string { return backend.activeSessionId; }
    function selectSession(id: string) { backend.selectSession(id); }
    function listSessions(): string { return backend.listSessions(); }

    // A pending background session is exempt from the idle reaper; the
    // driver asserts a failed-model launch clears this mark so its idle
    // worker stays reapable rather than leaking.
    function isPending(id: string): bool {
      return backend._pendingBg.hasOwnProperty(id);
    }

    // Exercise the backend model cache's dedup directly (the live
    // /v1/models GET can't reach the random-port mock in this headless
    // host). A bare-id entry must take the default provider, and the
    // duplicate must collapse. Returns the resulting cache as JSON.
    function mergeModelsProbe(): string {
      backend.modelsList = [];
      backend._mergeModels([
        { provider: "local", id: "gemma4:e4b" },
        { id: "gpt-oss" },
        { provider: "local", id: "gemma4:e4b" },
      ]);
      return JSON.stringify(backend.modelsList);
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

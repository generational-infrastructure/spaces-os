// Headless host for the launch-bar completion UI contract.
//
// QuickBar itself is a layer-shell PanelWindow, which the offscreen Qt
// platform can't realise (same reason pi-chat-panel-width hosts Panel in
// a FloatingWindow). So we host the real `completer` controller — the
// brain QuickBar's Keys.onPressed drives — alongside a real
// PiChatBackend, and exercise the EXACT functions the key handlers call
// (setInput/advance/move/accept/enter/escape) over IPC. The whole
// pi-chat tree is staged beside this file so `import qs.*` and the
// PiChatBackend children resolve as they do under the production shell.
import QtQuick
import Quickshell
import Quickshell.Io

FloatingWindow {
  id: win
  implicitWidth: 640
  implicitHeight: 400
  visible: true

  PiChatBackend {
    id: backend
    panelVisible: false
  }

  QuickBarCompletion {
    id: completion
    anchors.fill: parent
    backend: backend
  }

  IpcHandler {
    target: "test:quick-launch-completion"

    // Deterministic model cache: the live /v1/models GET can't reach a
    // server in the build sandbox, so the cache is seeded in-QML (passing
    // a JSON array through `ipc call` has no precedent and mangles). Kept
    // in sync with the driver's MODELS list.
    function setModels() {
      backend.modelsList = [
        { provider: "local", id: "gemma4:e4b" },
        { provider: "local", id: "gpt-oss" },
        { provider: "local", id: "gpt-oss-120b" },
        { provider: "local", id: "llama-3.2" },
        { provider: "local", id: "mistral" },
      ];
    }

    function setInput(text: string, cursor: int) { completion.setInput(text, cursor); }
    function pressTab() { completion.advance(); }
    function pressShiftTab() { completion.move(-1); }
    function pressUp() { completion.move(-1); }
    function pressDown() { completion.move(1); }
    function pressEscape(): string { return completion.dismiss(); }
    function pressEnter(): string { return completion.enter(); }

    function candidateTexts(): string {
      return JSON.stringify((completion.candidates || []).map(c => c.label));
    }
    function selectedCandidate(): string {
      const i = completion.selectedIndex;
      const c = completion.candidates || [];
      return (i >= 0 && i < c.length) ? String(c[i].label) : "";
    }
    function inputText(): string { return completion.text; }
    function active(): bool { return completion.active; }
    function note(): string { return completion.note; }
    function loading(): bool { return completion.loading; }

    function sessionCount(): int { return backend.sessionsList.length; }
    function newestModel(): string {
      const a = backend.sessionsList;
      return a.length ? String(a[a.length - 1].model || "") : "";
    }
    function lastLaunchPrompt(): string { return completion.lastLaunchPrompt; }
    function lastLaunchModel(): string { return completion.lastLaunchModel; }
  }
}

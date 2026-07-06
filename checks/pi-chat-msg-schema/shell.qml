// Headless host for the pure message-entry module.
//
// Msg.js is staged next to this file by the driver, so the bare
// `import "Msg.js"` resolves exactly as it does beside the production
// QML. No PiChatBackend, no pi worker, no LLM — the module is pure
// logic, so this check just calls it over IPC and the driver asserts
// on the JSON it returns.
import QtQuick
import Quickshell
import Quickshell.Io
import "Msg.js" as Msg

Item {
  id: root

  // Explicit map (not Msg[fn]) — a QML JS-namespace import is not a
  // plain object, so dynamic property access on it is unreliable.
  readonly property var fns: ({
    user: Msg.user,
    userImage: Msg.userImage,
    assistant: Msg.assistant,
    assistantStream: Msg.assistantStream,
    thinking: Msg.thinking,
    notification: Msg.notification,
    confirm: Msg.confirm,
    approval: Msg.approval,
    prompt: Msg.prompt,
    isMine: Msg.isMine,
    isNotification: Msg.isNotification,
    isConfirm: Msg.isConfirm,
    isPrompt: Msg.isPrompt,
    isThinking: Msg.isThinking,
    isApproval: Msg.isApproval,
    isPlain: Msg.isPlain,
    isPlainAssistant: Msg.isPlainAssistant,
    isPendingPrompt: Msg.isPendingPrompt,
    visible: Msg.visible,
    patch: Msg.patch,
    appendDelta: Msg.appendDelta,
    finalizeStream: Msg.finalizeStream,
    remove: Msg.remove,
  })

  IpcHandler {
    target: "test:msg"

    // Generic dispatcher: Msg.<fn>(...args) → JSON. Keeps the harness
    // a single verb while the driver owns the whole assertion matrix.
    // The args ride inside an object ({"args": […]}) because the
    // quickshell IPC CLI explodes a leading-'[' argument into separate
    // positional parameters.
    function call(fn: string, argsJson: string): string {
      try {
        const f = root.fns[fn];
        if (typeof f !== "function") return JSON.stringify({ _error: "no such fn: " + fn });
        return JSON.stringify(f.apply(null, JSON.parse(argsJson).args));
      } catch (e) {
        return JSON.stringify({ _error: String(e) });
      }
    }
  }
}

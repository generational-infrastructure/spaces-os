// Headless host for the pure launch-bar parser.
//
// BarParse.js is staged next to this file by the driver, so the bare
// `import "BarParse.js"` resolves exactly as it does beside the
// production QML. No PiChatBackend, no pi worker, no LLM — the parser
// is pure logic, so this check just feeds it grammar inputs over IPC
// and the driver asserts on the JSON it returns.
import QtQuick
import Quickshell
import Quickshell.Io
import "BarParse.js" as BarParse

Item {
  id: root

  IpcHandler {
    target: "test:bar-parse"

    function parse(text: string, cursor: int): string {
      return JSON.stringify(BarParse.parse(text, cursor));
    }
  }
}

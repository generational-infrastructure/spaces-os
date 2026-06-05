// Headless host for the WebSocket-transport check.
//
// Instantiates the real PiExecutor + PiSession in WS mode (executor set,
// no local pi) pointed at a fake pi-sessiond, and exposes IPC so the driver
// can connect, send a prompt, and read back the streamed reply. No
// compositor, no pi, no LLM.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

FloatingWindow {
  id: win
  implicitWidth: 320
  implicitHeight: 240
  visible: true

  property string wsUrl: String(Quickshell.env("PI_WS_URL"))
  property string wsToken: String(Quickshell.env("PI_WS_TOKEN"))
  property string wsTokenPath: String(Quickshell.env("PI_WS_TOKEN_PATH"))

  PiExecutor {
    id: exec
    url: win.wsUrl
    token: win.wsToken
    tokenPath: win.wsTokenPath
    active: win.wsUrl !== ""
  }

  PiSession {
    id: sess
    sessionId: "test"
    sessionName: "Test"
    executor: exec
  }

  IpcHandler {
    target: "test:ws"

    function connected(): bool { return exec.connected; }
    function streaming(): bool { return sess.streaming; }
    function send(text: string) { sess.send(text); }
    function msgCount(): string { return String(sess.messages.length); }

    // Concatenated text of every non-user (assistant) bubble.
    function reply(): string {
      var out = "";
      for (var i = 0; i < sess.messages.length; i++) {
        var m = sess.messages[i];
        if (m && m.from !== "me") out += (m.text || "");
      }
      return out;
    }

    // State of the confirm bubble with id `reqId` ("pending"/"resolved"/…); "" if absent.
    function confirmState(reqId: string): string {
      for (var i = 0; i < sess.messages.length; i++) {
        var m = sess.messages[i];
        if (m && (m.type || "") === "confirm" && m.id === reqId) return m.confirmState || "";
      }
      return "";
    }
  }
}

// Headless host for the create_session retry-across-reconnect check.
//
// A single real PiExecutor + PiSession in WS mode, pointed at a fake
// pi-sessiond that DROPS the connection during the first create_session
// (no ack) and only accepts the create on reconnect. The session is
// driven with one send() — its prompt must survive the flap and stream a
// reply once the retried create finally attaches.
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

  PiExecutor {
    id: exec
    url: win.wsUrl
    token: win.wsToken
    active: win.wsUrl !== ""
  }

  PiSession {
    id: sess
    sessionId: "test"
    sessionName: "Test"
    executor: exec
  }

  IpcHandler {
    target: "test:retry"

    function connected(): bool { return exec.connected; }
    function send(text: string) { sess.send(text); }

    // Concatenated text of every non-user (assistant) bubble.
    function reply(): string {
      var out = "";
      for (var i = 0; i < sess.messages.length; i++) {
        var m = sess.messages[i];
        if (m && m.from !== "me") out += (m.text || "");
      }
      return out;
    }
  }
}

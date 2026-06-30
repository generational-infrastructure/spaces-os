// Headless host for the integration-approval check.
//
// Instantiates the real PiExecutor + PiSession in WS mode pointed at a fake
// gateway, and exposes IPC so the driver can: trigger an approval_request
// (via a "approve:<id>" prompt the fake gateway turns into the event),
// inspect the rendered approval bubble, and reply {once|session|deny}. No
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

  function _find(id) {
    for (var i = 0; i < sess.messages.length; i++) {
      var m = sess.messages[i];
      if (m && (m.type || "") === "approval" && m.id === id) return m;
    }
    return null;
  }

  IpcHandler {
    target: "test:approval"

    function connected(): bool { return exec.connected; }
    function send(text: string) { sess.send(text); }
    function respond(id: string, decision: string) { sess.approvalRespond(id, decision); }

    // "" when no approval bubble with that id exists yet.
    function approvalState(id: string): string {
      var m = win._find(id);
      return m ? (m.approvalState || "") : "";
    }
    // The tool + args the bubble captured — proves the panel surfaced exactly
    // what the gateway sent, not merely that some bubble appeared.
    function approvalTool(id: string): string {
      var m = win._find(id);
      return m ? (m.approvalTool || "") : "";
    }
    function approvalArgs(id: string): string {
      var m = win._find(id);
      return m ? (m.approvalArgs || "") : "";
    }
  }
}

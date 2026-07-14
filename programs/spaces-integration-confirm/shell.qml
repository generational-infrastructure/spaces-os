// spaces-integration-confirm — the standalone confirmation popup
// (docs/agent-integrations-generic-mcp-design.md §3). The DEFAULT confirm
// command the aggregating gateway spawns for a per-call approval. Deliberately
// self-contained: it depends on NO harness QML (no pi-chat panel, no qs.Commons)
// so it renders the same regardless of which harness triggered the tool call.
//
// Contract (design §2): read the request from SPACES_CONFIRM_REQUEST (JSON) and
// write one verdict token — once | session | deny — to SPACES_CONFIRM_VERDICT_FILE,
// then quit. No verdict written ⇒ the gateway's runner fails closed to deny.
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

FloatingWindow {
  id: root

  // ── palette (self-contained; a neutral dark Material-ish scheme) ──
  readonly property color cSurface: "#1e1e2e"
  readonly property color cSurfaceVariant: "#313244"
  readonly property color cOnSurface: "#cdd6f4"
  readonly property color cOnSurfaceVariant: "#a6adc8"
  readonly property color cPrimary: "#89b4fa"
  readonly property color cOnPrimary: "#11111b"
  readonly property color cError: "#f38ba8"
  readonly property color cOnError: "#11111b"

  // ── request (from the env the gateway sets) ──
  readonly property string verdictFile: String(Quickshell.env("SPACES_CONFIRM_VERDICT_FILE") || "")
  readonly property var request: {
    try {
      return JSON.parse(String(Quickshell.env("SPACES_CONFIRM_REQUEST") || "{}"));
    } catch (e) {
      return {};
    }
  }
  readonly property string integration: String(root.request.integration || "")
  readonly property string tool: String(root.request.tool || "")
  readonly property string toolName: String(root.request.toolName || (root.integration + "_" + root.tool))
  readonly property string argsText: root.request.args ? JSON.stringify(root.request.args, null, 2) : ""
  readonly property string context: typeof root.request.context === "string" ? root.request.context : ""

  title: "Confirm integration tool call"
  implicitWidth: 480
  implicitHeight: 360
  minimumSize: Qt.size(380, 260)
  color: root.cSurface
  visible: true

  // Write the verdict (a fixed token, never user input — passed as an argv
  // element so no untrusted shell interpolation) and quit. onExited quits even
  // on a write failure, so the gateway runner falls back to deny.
  function decide(verdict) {
    if (root.verdictFile === "") {
      Qt.quit();
      return;
    }
    writer.command = ["sh", "-c", 'printf %s "$1" > "$2"', "spaces-confirm", verdict, root.verdictFile];
    writer.running = true;
  }
  Process {
    id: writer
    onExited: Qt.quit()
  }

  // IPC seam for the headless contract check (checks/spaces-integration-confirm):
  // the driver invokes decide() exactly as a button click would and reads back
  // what the popup parsed from the request env.
  IpcHandler {
    target: "confirm"
    function decide(verdict: string): void {
      root.decide(verdict);
    }
    function toolName(): string {
      return root.toolName;
    }
    function argsText(): string {
      return root.argsText;
    }
    function context(): string {
      return root.context;
    }
  }

  ColumnLayout {
    anchors.fill: parent
    anchors.margins: 16
    spacing: 10

    Text {
      text: "Allow integration tool call?"
      color: root.cOnSurface
      font.pixelSize: 18
      font.bold: true
    }
    Text {
      text: root.integration + " · " + root.tool
      color: root.cOnSurfaceVariant
      font.pixelSize: 13
    }

    // Untrusted preview text (a confirmPreview tool's output), rendered as
    // plain quoted text — never interpreted.
    Rectangle {
      Layout.fillWidth: true
      visible: root.context !== ""
      color: root.cSurfaceVariant
      radius: 6
      implicitHeight: ctxCol.implicitHeight + 12
      ColumnLayout {
        id: ctxCol
        anchors.fill: parent
        anchors.margins: 6
        spacing: 2
        Text {
          text: "Preview:"
          color: root.cOnSurfaceVariant
          font.pixelSize: 11
          font.bold: true
        }
        Text {
          Layout.fillWidth: true
          text: root.context
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          color: root.cOnSurfaceVariant
          font.pixelSize: 12
        }
      }
    }

    // The concrete arguments the gateway will forward on approval — the
    // security-relevant payload the user is consenting to.
    Rectangle {
      Layout.fillWidth: true
      Layout.fillHeight: true
      color: root.cSurfaceVariant
      radius: 6
      visible: root.argsText !== "" && root.argsText !== "{}"
      Flickable {
        anchors.fill: parent
        anchors.margins: 8
        contentHeight: argsView.implicitHeight
        clip: true
        Text {
          id: argsView
          width: parent.width
          text: root.argsText
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          color: root.cOnSurface
          font.family: "monospace"
          font.pixelSize: 12
        }
      }
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: 8

      // Deny (destructive-tinted, left).
      Rectangle {
        Layout.preferredHeight: 36
        Layout.preferredWidth: 96
        radius: 6
        color: denyArea.containsMouse ? root.cError : root.cSurfaceVariant
        Text {
          anchors.centerIn: parent
          text: "Deny"
          color: denyArea.containsMouse ? root.cOnError : root.cOnSurface
          font.pixelSize: 13
        }
        MouseArea {
          id: denyArea
          anchors.fill: parent
          hoverEnabled: true
          onClicked: root.decide("deny")
        }
      }

      Item {
        Layout.fillWidth: true
      }

      // Allow once.
      Rectangle {
        Layout.preferredHeight: 36
        Layout.preferredWidth: 110
        radius: 6
        color: onceArea.containsMouse ? root.cSurfaceVariant : "transparent"
        border.width: 1
        border.color: root.cPrimary
        Text {
          anchors.centerIn: parent
          text: "Allow once"
          color: root.cPrimary
          font.pixelSize: 13
        }
        MouseArea {
          id: onceArea
          anchors.fill: parent
          hoverEnabled: true
          onClicked: root.decide("once")
        }
      }

      // Allow for this session (primary).
      Rectangle {
        Layout.preferredHeight: 36
        Layout.preferredWidth: 150
        radius: 6
        color: root.cPrimary
        opacity: sessionArea.containsMouse ? 0.9 : 1.0
        Text {
          anchors.centerIn: parent
          text: "Allow for session"
          color: root.cOnPrimary
          font.pixelSize: 13
          font.bold: true
        }
        MouseArea {
          id: sessionArea
          anchors.fill: parent
          hoverEnabled: true
          onClicked: root.decide("session")
        }
      }
    }
  }
}

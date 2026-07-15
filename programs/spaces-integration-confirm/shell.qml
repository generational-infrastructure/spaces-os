// spaces-integration-confirm — the standalone confirmation popup
// (docs/agent-integrations-generic-mcp-design.md §3, restyle per
// docs/confirm-popup-settings-session-design.md §1). The DEFAULT confirm
// command the aggregating gateway spawns for a per-call approval. Deliberately
// self-contained: it depends on NO harness QML (no pi-chat panel, no qs.Commons)
// so it renders the same regardless of which harness triggered the tool call —
// the voxtype-tuner dark tokens below are COPIED, not shared, for that reason.
//
// The root is a Quickshell PanelWindow on the wlr layer-shell Overlay layer with
// no anchors, so a layer-shell compositor (niri) centers it as a floating
// overlay above everything and never tiles it. Under QT_QPA_PLATFORM=offscreen
// (the contract check) it boots headless exactly like pi-chat's QuickBar.
//
// Contract (design §2): read the request from SPACES_CONFIRM_REQUEST (JSON) and
// write one verdict token — once | session | deny — to SPACES_CONFIRM_VERDICT_FILE,
// then quit. No verdict written ⇒ the gateway's runner fails closed to deny.
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

PanelWindow {
  id: root

  // ── voxtype-tuner dark tokens (copied; the popup imports no harness QML) ──
  readonly property color cWindow: "#151b1e"
  readonly property color cCard: "#222c30"
  readonly property color cControl: "#2f3c42"
  readonly property color cText: "#ffffff"
  readonly property color cTextDim: "#afc6ca"
  readonly property color cBorderSoft: "#465a62"
  readonly property color cBorderStrong: "#617e89"
  readonly property color cDanger: "#c43e81"
  readonly property color cOnAccent: "#151b1e"

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
  // argsText stays the JSON serialization: the contract check and the gateway
  // semantics ("the human sees exactly what runs") depend on it verbatim.
  readonly property string argsText: root.request.args ? JSON.stringify(root.request.args, null, 2) : ""
  readonly property string context: typeof root.request.context === "string" ? root.request.context : ""

  // Per-field surface: one row per top-level arg key. Scalars render as flat
  // mono text; nested objects/arrays as pretty-printed JSON inside their own
  // well, so a scalar never drowns in a blob's punctuation. Labels are the
  // uppercased keys. Everything downstream renders Text.PlainText (untrusted).
  readonly property var fields: {
    var out = [];
    var a = root.request.args;
    if (a && typeof a === "object") {
      for (var k in a) {
        var v = a[k];
        var scalar = (v === null || typeof v !== "object");
        out.push({
          label: String(k).toUpperCase(),
          value: scalar ? String(v) : JSON.stringify(v, null, 2)
        });
      }
    }
    return out;
  }

  // Layer-shell overlay: no anchors ⇒ compositor-centered; OnDemand focus so
  // summoning never steals the keyboard until the user clicks in.
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
  WlrLayershell.namespace: "spaces-integration-confirm"

  implicitWidth: 460
  // Content-driven, capped so a huge args payload scrolls instead of sprawling.
  implicitHeight: Math.min(600, 40 + header.implicitHeight + subtitle.implicitHeight
    + fieldsCol.implicitHeight + buttons.implicitHeight + outer.spacing * 3)

  // The window is transparent; the rounded card paints. Rounded corners need
  // the window bg to show through as fully transparent, not the window color.
  color: "transparent"
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
  // what the popup parsed from the request env, including the per-field surface.
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
    function argFields(): string {
      return JSON.stringify(root.fields);
    }
  }

  Rectangle {
    anchors.fill: parent
    color: root.cCard
    radius: 16
    border.width: 1
    border.color: root.cBorderSoft

    ColumnLayout {
      id: outer
      anchors.fill: parent
      anchors.margins: 20
      spacing: 14

      Text {
        id: header
        Layout.fillWidth: true
        text: "Allow integration tool call?"
        textFormat: Text.PlainText
        color: root.cText
        font.pixelSize: 18
        font.weight: Font.DemiBold
      }
      Text {
        id: subtitle
        Layout.fillWidth: true
        text: root.integration + " · " + root.tool
        textFormat: Text.PlainText
        color: root.cTextDim
        font.pixelSize: 14
      }

      // The security-relevant surface: the untrusted preview plus one well per
      // concrete arg the gateway will forward on approval. Scrolls when the
      // window is capped; fits exactly otherwise.
      Flickable {
        id: flick
        Layout.fillWidth: true
        Layout.fillHeight: true
        contentHeight: fieldsCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
          id: fieldsCol
          width: flick.width
          spacing: 12

          // Untrusted preview text (a confirmPreview tool's output), quoted as
          // plain text — never interpreted.
          ColumnLayout {
            Layout.fillWidth: true
            visible: root.context !== ""
            spacing: 4
            Text {
              text: "PREVIEW"
              textFormat: Text.PlainText
              color: root.cTextDim
              font.family: "monospace"
              font.pixelSize: 12
            }
            Rectangle {
              Layout.fillWidth: true
              color: root.cControl
              radius: 10
              implicitHeight: previewText.implicitHeight + 20
              Text {
                id: previewText
                anchors.fill: parent
                anchors.margins: 10
                text: root.context
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.cText
                font.family: "monospace"
                font.pixelSize: 13
              }
            }
          }

          // One caption-over-well row per top-level arg.
          Repeater {
            model: root.fields
            delegate: ColumnLayout {
              id: fieldRow
              required property var modelData
              Layout.fillWidth: true
              spacing: 4
              Text {
                text: fieldRow.modelData.label
                textFormat: Text.PlainText
                color: root.cTextDim
                font.family: "monospace"
                font.pixelSize: 12
              }
              Rectangle {
                Layout.fillWidth: true
                color: root.cControl
                radius: 10
                implicitHeight: fieldValue.implicitHeight + 20
                Text {
                  id: fieldValue
                  anchors.fill: parent
                  anchors.margins: 10
                  text: fieldRow.modelData.value
                  textFormat: Text.PlainText
                  wrapMode: Text.Wrap
                  color: root.cText
                  font.family: "monospace"
                  font.pixelSize: 13
                }
              }
            }
          }
        }
      }

      // Pills: Deny (danger, left), Allow once (secondary), Allow for session
      // (primary, right). 180ms hover fills.
      RowLayout {
        id: buttons
        Layout.fillWidth: true
        spacing: 8

        // Deny — danger pill.
        Rectangle {
          Layout.preferredHeight: 40
          Layout.preferredWidth: 96
          radius: 20
          color: denyArea.containsMouse ? Qt.darker(root.cDanger, 1.2) : root.cDanger
          Behavior on color {
            ColorAnimation { duration: 180 }
          }
          Text {
            anchors.centerIn: parent
            text: "Deny"
            textFormat: Text.PlainText
            color: root.cText
            font.pixelSize: 14
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

        // Allow once — secondary pill (control fill + strong hairline).
        Rectangle {
          Layout.preferredHeight: 40
          Layout.preferredWidth: 116
          radius: 20
          color: onceArea.containsMouse ? Qt.lighter(root.cControl, 1.2) : root.cControl
          border.width: 1
          border.color: root.cBorderStrong
          Behavior on color {
            ColorAnimation { duration: 180 }
          }
          Text {
            anchors.centerIn: parent
            text: "Allow once"
            textFormat: Text.PlainText
            color: root.cText
            font.pixelSize: 14
          }
          MouseArea {
            id: onceArea
            anchors.fill: parent
            hoverEnabled: true
            onClicked: root.decide("once")
          }
        }

        // Allow for session — primary pill (accent fill, dark ink).
        Rectangle {
          Layout.preferredHeight: 40
          Layout.preferredWidth: 156
          radius: 20
          color: sessionArea.containsMouse ? Qt.darker(root.cText, 1.08) : root.cText
          Behavior on color {
            ColorAnimation { duration: 180 }
          }
          Text {
            anchors.centerIn: parent
            text: "Allow for session"
            textFormat: Text.PlainText
            color: root.cOnAccent
            font.pixelSize: 14
            font.weight: Font.DemiBold
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
}

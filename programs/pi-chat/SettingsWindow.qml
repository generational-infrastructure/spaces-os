// Standalone settings window.
//
// Replaces noctalia's plugin-settings dialog (`pluginApi`-mediated).
// Opened on demand from the panel header; persists into our own
// Commons.Settings adapter.
//
// FloatingWindow (not PanelWindow) because a settings dialog is a
// modal, transient window — it should appear in the window list
// when open, get focus, and behave like any other app dialog.
//
// The Integrations section talks straight to the per-user broker over
// $XDG_RUNTIME_DIR/spaces-integrations.sock (IntegrationsBridge). This
// panel→broker path provisions secrets and flips the enable flag; it is
// disjoint from the agent runtime, which never sees this socket. The
// form is rendered entirely from the broker's `list` reply — secret
// *names* and descriptions, never values.
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Widgets

FloatingWindow {
  id: root

  title: "pi-chat settings"
  implicitWidth: 480
  implicitHeight: 420
  minimumSize: Qt.size(400, 280)

  color: Color.mSurface

  // Broker socket address; overridable so headless checks can point the
  // bridge at a fake. Production resolves the per-user runtime socket.
  property string integrationsSockPath: String(Quickshell.env("XDG_RUNTIME_DIR") || "") + "/spaces-integrations.sock"

  // Inline device-setup flow state (one integration at a time).
  // setupFor names the integration whose setup pane is open; the rest
  // mirror the broker's streamed NDJSON events (see IntegrationsBridge).
  property string setupFor: ""
  property string setupPhase: ""   // "connecting" | "qr" | "done" | "error"
  property string setupPng: ""
  property string setupText: ""
  property string setupErrorText: ""

  // Setup-pane lifecycle phases (setupPhase). "connecting" is entered on
  // launch, then the broker's stream drives qr → done | error.
  readonly property string phaseConnecting: "connecting"
  readonly property string phaseQr: "qr"
  readonly property string phaseDone: "done"
  readonly property string phaseError: "error"

  // Success pane lingers on its done state this long before auto-closing,
  // so the user registers the "linked" confirmation.
  readonly property int setupDoneCloseMs: 1200

  // Linking QR render size (square), matched to the inline pane width.
  readonly property int setupQrSize: 180

  // Reset the inline setup pane to one consistent state: every view-state
  // var assigned, so no teardown site leaves a stale subset behind.
  function resetSetup(phase, forName) {
    root.setupFor = forName || "";
    root.setupPhase = phase || "";
    root.setupPng = "";
    root.setupText = "";
    root.setupErrorText = "";
  }

  IntegrationsBridge {
    id: integrations
    sockPath: root.integrationsSockPath
    Component.onCompleted: refresh()
  }

  // Relay the bridge's streamed setup events into the inline pane state.
  Connections {
    target: integrations
    function onSetupEvent(ev) {
      if (!ev || !ev.event) return;
      if (ev.event === integrations.evQr) {
        root.setupPng = ev.png || "";
        root.setupPhase = root.phaseQr;
      } else if (ev.event === integrations.evMessage) {
        root.setupText = ev.text || "";
      } else if (ev.event === integrations.evDone) {
        root.setupText = "";
        root.setupPhase = root.phaseDone;
        setupAutoClose.restart();
      } else if (ev.event === integrations.evError) {
        root.setupErrorText = ev.error || "";
        root.setupPhase = root.phaseError;
      }
    }
  }

  // On success the pane shows its done state briefly, then closes.
  Timer {
    id: setupAutoClose
    interval: root.setupDoneCloseMs
    onTriggered: root.resetSetup()
  }

  // One profile's provisioning form: config fields (plain) + secret fields
  // (masked), each saved through the broker via setField. Reused for every
  // profile of a multi-account integration, for the "add account" draft, and
  // for the implicit "default" profile of a single-account integration.
  component ProfileEditor: ColumnLayout {
    id: pe
    property string intName: ""
    property string profileName: ""
    property var configSchema: []
    property var secretSchema: []
    property var configValues: ({})
    property var secretStatus: ({})
    property bool removable: false
    property bool showName: true
    Layout.fillWidth: true
    spacing: Style.marginXS

    RowLayout {
      visible: pe.showName
      Layout.fillWidth: true
      spacing: Style.marginS
      NText {
        text: pe.profileName
        font.bold: true
        color: Color.mOnSurface
        pointSize: Style.fontSizeS
      }
      Item { Layout.fillWidth: true }
      NButton {
        visible: pe.removable
        text: I18n.tr("settings.integrations-profile-remove")
        onClicked: integrations.removeProfile(pe.intName, pe.profileName)
      }
    }

    Repeater {
      model: pe.configSchema
      delegate: RowLayout {
        id: cfgRow
        required property var modelData
        Layout.fillWidth: true
        spacing: Style.marginS
        NText {
          text: cfgRow.modelData.name + (cfgRow.modelData.required ? " *" : "")
          color: Color.mOnSurfaceVariant
          pointSize: Style.fontSizeS
        }
        NTextInput {
          id: cfgInput
          Layout.fillWidth: true
          text: (pe.configValues && pe.configValues[cfgRow.modelData.name]) || ""
          placeholderText: cfgRow.modelData.description || cfgRow.modelData.name
        }
        NButton {
          text: I18n.tr("settings.integrations-secret-save")
          enabled: cfgInput.text.length > 0
          onClicked: integrations.setField(pe.intName, pe.profileName, cfgRow.modelData.name, cfgInput.text)
        }
      }
    }

    Repeater {
      model: pe.secretSchema
      delegate: RowLayout {
        id: secRow
        required property var modelData
        Layout.fillWidth: true
        spacing: Style.marginS
        NText {
          text: secRow.modelData.name + " · " + ((pe.secretStatus && pe.secretStatus[secRow.modelData.name])
            ? I18n.tr("settings.integrations-secret-set")
            : I18n.tr("settings.integrations-secret-unset"))
          color: (pe.secretStatus && pe.secretStatus[secRow.modelData.name]) ? Color.mTertiary : Color.mOnSurfaceVariant
          pointSize: Style.fontSizeS
        }
        NTextInput {
          id: secInput
          Layout.fillWidth: true
          echoMode: TextInput.Password
          placeholderText: secRow.modelData.description || secRow.modelData.name
        }
        NButton {
          text: I18n.tr("settings.integrations-secret-save")
          enabled: secInput.text.length > 0
          onClicked: {
            integrations.setField(pe.intName, pe.profileName, secRow.modelData.name, secInput.text);
            secInput.text = "";
          }
        }
      }
    }
  }

  ScrollView {
    id: scroller
    anchors.fill: parent
    anchors.margins: Style.marginL
    contentWidth: availableWidth

    ColumnLayout {
      width: scroller.availableWidth
      spacing: Style.marginM

      NText {
        Layout.fillWidth: true
        text: I18n.tr("settings.nixos-hint")
        wrapMode: Text.Wrap
        color: Color.mOnSurfaceVariant
      }

      NSpinBox {
        Layout.fillWidth: true
        label: I18n.tr("settings.history-limit-label")
        description: I18n.tr("settings.history-limit-description")
        from: 20
        to: 1000
        stepSize: 20
        value: Settings.data.maxHistory
        onValueModified: v => {
          Settings.data.maxHistory = v;
          Settings.persist();
        }
      }

      NDivider { Layout.fillWidth: true }

      NText {
        Layout.fillWidth: true
        text: I18n.tr("settings.integrations-title")
        pointSize: Style.fontSizeL
        font.bold: true
        color: Color.mOnSurface
      }

      NText {
        Layout.fillWidth: true
        visible: integrations.lastError !== ""
        text: I18n.tr("settings.integrations-error", { error: integrations.lastError })
        wrapMode: Text.Wrap
        color: Color.mError
        pointSize: Style.fontSizeS
      }

      NText {
        Layout.fillWidth: true
        visible: !integrations.loaded
        text: I18n.tr("settings.integrations-offline")
        wrapMode: Text.Wrap
        color: Color.mOnSurfaceVariant
        pointSize: Style.fontSizeS
      }

      NText {
        Layout.fillWidth: true
        visible: integrations.loaded && integrations.integrations.length === 0
        text: I18n.tr("settings.integrations-empty")
        wrapMode: Text.Wrap
        color: Color.mOnSurfaceVariant
        pointSize: Style.fontSizeS
      }

      Repeater {
        model: integrations.integrations
        delegate: ColumnLayout {
          id: intRow
          required property var modelData
          Layout.fillWidth: true
          spacing: Style.marginXS

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.marginS
            NText {
              text: intRow.modelData.name || ""
              font.bold: true
              color: Color.mOnSurface
              pointSize: Style.fontSizeM
            }
            NText {
              visible: intRow.modelData.enabled === true
              text: I18n.tr("settings.integrations-enabled-badge")
              color: Color.mTertiary
              pointSize: Style.fontSizeXS
            }
            Item { Layout.fillWidth: true }
            NButton {
              objectName: "setupBtn-" + (intRow.modelData.name || "")
              visible: intRow.modelData.enabled === true && intRow.modelData.setup === true
              text: I18n.tr("settings.integrations-setup")
              onClicked: {
                root.resetSetup(root.phaseConnecting, intRow.modelData.name);
                integrations.startSetup(intRow.modelData.name);
              }
            }
            NButton {
              text: intRow.modelData.enabled
                ? I18n.tr("settings.integrations-disable")
                : I18n.tr("settings.integrations-enable")
              onClicked: {
                if (intRow.modelData.enabled) integrations.disable(intRow.modelData.name);
                else integrations.enable(intRow.modelData.name);
              }
            }
          }

          NText {
            Layout.fillWidth: true
            visible: (intRow.modelData.description || "") !== ""
            text: intRow.modelData.description || ""
            wrapMode: Text.Wrap
            color: Color.mOnSurfaceVariant
            pointSize: Style.fontSizeS
          }

          // Inline device-setup flow, rendered only for the integration
          // whose setup was launched (one at a time). qr paints the
          // linking QR, message events show progress, done shows success
          // then auto-closes, error surfaces the failure.
          Loader {
            Layout.fillWidth: true
            active: root.setupFor === intRow.modelData.name
            visible: active
            sourceComponent: ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.marginXS

              NText {
                text: I18n.tr("settings.integrations-setup-title")
                font.bold: true
                color: Color.mOnSurface
                pointSize: Style.fontSizeS
              }

              Image {
                objectName: "setupQr"
                visible: root.setupPhase === root.phaseQr && root.setupPng !== ""
                Layout.alignment: Qt.AlignHCenter
                sourceSize.width: root.setupQrSize
                sourceSize.height: root.setupQrSize
                fillMode: Image.PreserveAspectFit
                source: root.setupPng !== "" ? ("data:image/png;base64," + root.setupPng) : ""
              }

              NText {
                visible: root.setupPhase === root.phaseQr
                Layout.fillWidth: true
                text: I18n.tr("settings.integrations-setup-scan")
                wrapMode: Text.Wrap
                horizontalAlignment: Text.AlignHCenter
                color: Color.mOnSurfaceVariant
                pointSize: Style.fontSizeS
              }

              NText {
                objectName: "setupStatus"
                Layout.fillWidth: true
                visible: text !== ""
                wrapMode: Text.Wrap
                pointSize: Style.fontSizeS
                text: {
                  if (root.setupPhase === root.phaseDone) return I18n.tr("settings.integrations-setup-done");
                  if (root.setupPhase === root.phaseError) return I18n.tr("settings.integrations-setup-error", { error: root.setupErrorText });
                  return root.setupText;
                }
                color: root.setupPhase === root.phaseError ? Color.mError : Color.mOnSurfaceVariant
              }

              NButton {
                visible: root.setupPhase !== root.phaseDone
                text: I18n.tr("settings.integrations-setup-cancel")
                bgColor: Color.mSurfaceVariant
                fgColor: Color.mOnSurfaceVariant
                onClicked: {
                  integrations.cancelSetup();
                  root.resetSetup();
                }
              }
            }
          }

          // Multi-account: each provisioned profile, plus an "add account" draft.
          ColumnLayout {
            visible: intRow.modelData.multiProfile === true
            Layout.fillWidth: true
            spacing: Style.marginS

            Repeater {
              model: intRow.modelData.profiles || []
              delegate: ProfileEditor {
                id: profRow
                required property var modelData
                Layout.fillWidth: true
                intName: intRow.modelData.name
                profileName: profRow.modelData.name
                configSchema: intRow.modelData.config || []
                secretSchema: intRow.modelData.secrets || []
                configValues: profRow.modelData.config || ({})
                secretStatus: profRow.modelData.secrets || ({})
                removable: true
                showName: true
              }
            }

            NTextInput {
              id: newProfile
              Layout.fillWidth: true
              placeholderText: I18n.tr("settings.integrations-profile-add")
            }
            // Draft editor for the typed-in account name; saving any field
            // creates the profile (the broker materialises it on first set-field).
            ProfileEditor {
              visible: newProfile.text.length > 0
              Layout.fillWidth: true
              intName: intRow.modelData.name
              profileName: newProfile.text
              configSchema: intRow.modelData.config || []
              secretSchema: intRow.modelData.secrets || []
              removable: false
              showName: false
            }
          }

          // Single-account: the implicit "default" profile, no profile chrome.
          ProfileEditor {
            visible: intRow.modelData.multiProfile !== true
            Layout.fillWidth: true
            intName: intRow.modelData.name
            profileName: "default"
            configSchema: intRow.modelData.config || []
            secretSchema: intRow.modelData.secrets || []
            configValues: (intRow.modelData.profiles && intRow.modelData.profiles.length > 0) ? intRow.modelData.profiles[0].config : ({})
            secretStatus: (intRow.modelData.profiles && intRow.modelData.profiles.length > 0) ? intRow.modelData.profiles[0].secrets : ({})
            removable: false
            showName: false
          }
        }
      }
    }
  }
}

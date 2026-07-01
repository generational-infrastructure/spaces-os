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

  IntegrationsBridge {
    id: integrations
    sockPath: String(Quickshell.env("XDG_RUNTIME_DIR") || "") + "/spaces-integrations.sock"
    Component.onCompleted: refresh()
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

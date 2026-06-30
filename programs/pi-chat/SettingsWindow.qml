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

          Repeater {
            model: intRow.modelData.secrets || []
            delegate: RowLayout {
              id: secretRow
              required property var modelData
              Layout.fillWidth: true
              spacing: Style.marginS

              NText {
                text: secretRow.modelData.name + " · " + (secretRow.modelData.set
                  ? I18n.tr("settings.integrations-secret-set")
                  : I18n.tr("settings.integrations-secret-unset"))
                color: secretRow.modelData.set ? Color.mTertiary : Color.mOnSurfaceVariant
                pointSize: Style.fontSizeS
              }
              NTextInput {
                id: secretField
                Layout.fillWidth: true
                echoMode: TextInput.Password
                placeholderText: secretRow.modelData.description || secretRow.modelData.name
              }
              NButton {
                text: I18n.tr("settings.integrations-secret-save")
                enabled: secretField.text.length > 0
                onClicked: {
                  integrations.setSecret(intRow.modelData.name, secretRow.modelData.name, secretField.text);
                  secretField.text = "";
                }
              }
            }
          }
        }
      }
    }
  }
}

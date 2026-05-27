// Standalone settings window.
//
// Replaces noctalia's plugin-settings dialog (`pluginApi`-mediated).
// Opened on demand from the panel header; persists into our own
// Commons.Settings adapter. Surface mirrors the original
// `Settings.qml` plugin component — same controls, same widgets.
//
// FloatingWindow (not PanelWindow) because a settings dialog is a
// modal, transient window — it should appear in the window list
// when open, get focus, and behave like any other app dialog.
import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Widgets

FloatingWindow {
  id: root

  title: "pi-chat settings"
  implicitWidth: 480
  implicitHeight: 280
  minimumSize: Qt.size(400, 240)

  color: Color.mSurface

  ColumnLayout {
    anchors.fill: parent
    anchors.margins: Style.marginL
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

    // Push everything to the top.
    Item { Layout.fillHeight: true }
  }
}

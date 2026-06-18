// Headless host for the NComboBox dropdown popup-geometry test.
//
// The model selector in the panel is an NComboBox. Its popup takes
// its height from the content ListView; if that ListView reports
// implicitHeight 0 the Popup collapses to zero height and the
// dropdown is invisible — clicking it "does nothing". This shell
// drives the popup over IPC so the driver can assert it gains a
// real height when opened.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Widgets

FloatingWindow {
  id: win
  implicitWidth: 320
  implicitHeight: 240
  visible: true

  property var testModel: [
    { key: "prov/one", name: "one" },
    { key: "prov/two", name: "two" },
    { key: "prov/three", name: "three" },
  ]

  NComboBox {
    id: combo
    width: 240
    sourceModel: win.testModel
    currentKey: "prov/two"
  }

  IpcHandler {
    target: "test:combo"

    function count(): string { return String(combo.count); }
    function currentKey(): string { return combo.currentKey; }
    function openPopup() { combo.popup.open(); }
    function popupVisible(): bool { return combo.popup.visible; }
    function popupHeight(): string { return String(combo.popup.height); }
    function popupImplicitHeight(): string { return String(combo.popup.implicitHeight); }
    function contentHeight(): string {
      return String(combo.popup.contentItem ? combo.popup.contentItem.contentHeight : -1);
    }
  }
}

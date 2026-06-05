// Dropdown selector. Used by the panel header to switch between
// available models reported by the chat backend.
//
// API matches noctalia's NComboBox for the surface the plugin uses:
//   - `model: [{key, name, ...}]` — array of entries; `key` is the
//     stable identifier emitted by `selected()`, `name` is the label
//   - `currentKey: <string>` — preselect by key
//   - `signal selected(key)` — fires when the user picks an option
//   - `tooltip`, `baseSize`, `placeholder` — optional cosmetics
//
// Implementation wraps QtQuick Controls ComboBox and maintains the
// key↔index mapping ourselves so callers stay in key space.
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import qs.Commons

ComboBox {
  id: root

  property string currentKey: ""
  property string tooltip: ""
  property real baseSize: 1.0
  property string placeholder: ""
  // noctalia exposes these as layout hints; the chat panel binds
  // them at the call site. Honour them so the dropdown sizes
  // sensibly without forcing a rewrite of the binding.
  property real minimumWidth: 0
  property real popupHeight: 300

  signal selected(string key)

  // `textRole` lets ComboBox render `name` from each model entry.
  textRole: "name"
  // Default valueRole is the field used to derive `currentValue`. We
  // surface `key` as the canonical identifier.
  valueRole: "key"

  implicitHeight: Math.round(Style.baseWidgetSize * baseSize)
  implicitWidth: Math.max(root.minimumWidth, 160)
  font.family: Settings.data.ui.fontDefault
  font.pointSize: Style.fontSizeS

  // Sync the visible selection when callers update currentKey, and
  // emit `selected()` only on user-initiated changes (not when we
  // align programmatically).
  property bool _syncingKey: false
  function _syncFromKey() {
    if (!model) return;
    _syncingKey = true;
    let idx = -1;
    const arr = (typeof model === "object" && "length" in model) ? model : [];
    for (let i = 0; i < arr.length; i++) {
      const k = arr[i] && arr[i].key !== undefined ? arr[i].key : "";
      if (k === currentKey) { idx = i; break; }
    }
    if (idx >= 0 && currentIndex !== idx) currentIndex = idx;
    _syncingKey = false;
  }

  onCurrentKeyChanged: _syncFromKey()
  onModelChanged: _syncFromKey()
  Component.onCompleted: _syncFromKey()
  onActivated: {
    if (_syncingKey) return;
    const item = model && currentIndex >= 0 ? model[currentIndex] : null;
    const k = item && item.key !== undefined ? item.key : "";
    if (k !== currentKey) currentKey = k;
    selected(k);
  }

  delegate: ItemDelegate {
    id: delegateItem
    required property var modelData
    required property int index
    width: root.width
    // Full label for this row, with the same key fallback the closed
    // display uses. Shared by the contentItem and the truncation tooltip.
    readonly property string fullName: delegateItem.modelData && delegateItem.modelData.name
      ? delegateItem.modelData.name
      : (delegateItem.modelData && delegateItem.modelData.key
        ? delegateItem.modelData.key
        : String(delegateItem.modelData))
    contentItem: NText {
      id: delegateLabel
      text: delegateItem.fullName
      pointSize: Style.fontSizeS
      color: root.highlightedIndex === delegateItem.index ? Color.mOnPrimary : Color.mOnSurface
    }
    background: Rectangle {
      color: root.highlightedIndex === delegateItem.index ? Color.mPrimary : "transparent"
    }
    // A long model name elides to a trailing "…"; surface the full
    // string on hover so the dropdown never permanently hides it.
    ToolTip.visible: delegateLabel.truncated && delegateItem.hovered
    ToolTip.text: delegateItem.fullName
    ToolTip.delay: 300
  }

  contentItem: NText {
    leftPadding: Style.marginS
    rightPadding: Style.marginS
    text: root.displayText !== "" ? root.displayText : root.placeholder
    pointSize: Style.fontSizeS
    color: root.displayText !== "" ? Color.mOnSurface : Color.mOnSurfaceVariant
    verticalAlignment: Text.AlignVCenter
  }

  background: Rectangle {
    color: Color.mSurfaceVariant
    radius: Style.iRadiusM
    border.color: Color.mOutline
    border.width: Style.borderS
  }

  popup: Popup {
    y: root.height
    width: root.width
    implicitHeight: Math.min(contentItem.implicitHeight, root.popupHeight)
    contentItem: ListView {
      clip: true
      // Qt's own ComboBox popup sets this; without it a bare ListView
      // reports implicitHeight 0, collapsing the Popup to zero height
      // (the dropdown opens but is invisible). contentHeight is the
      // laid-out total, capped by popupHeight in the Popup above.
      implicitHeight: contentHeight
      model: root.popup.visible ? root.delegateModel : null
      currentIndex: root.highlightedIndex
    }
    background: Rectangle {
      color: Color.mSurfaceVariant
      radius: Style.iRadiusM
      border.color: Color.mOutline
      border.width: Style.borderS
    }
  }

  ToolTip.visible: root.tooltip !== "" && hovered
  ToolTip.text: root.tooltip
  ToolTip.delay: 300
}

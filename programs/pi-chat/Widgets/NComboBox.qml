// Dropdown selector. Used by the panel header to switch between
// available models reported by the chat backend.
//
// API matches noctalia's NComboBox for the surface the plugin uses:
//   - `sourceModel: [{key, name, ...}]` — the full list of entries;
//     `key` is the stable identifier emitted by `selected()`, `name`
//     is the label
//   - `currentKey: <string>` — preselect by key
//   - `signal selected(key)` — fires when the user picks an option
//   - `searchable: <bool>` — grow a fuzzy search field at the top of
//     the dropdown that filters `sourceModel` as the user types
//   - `tooltip`, `baseSize`, `placeholder`, `searchPlaceholder` —
//     optional cosmetics
//
// The visible `model` is derived from `sourceModel` filtered by the
// fuzzy query, so callers bind `sourceModel`, never `model`. The query
// is empty whenever the popup is closed, so the closed display and the
// key↔index sync always see the complete list.
// Implementation wraps QtQuick Controls ComboBox and maintains the
// key↔index mapping ourselves so callers stay in key space.
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
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

  // The full, unfiltered entry list. `model` (the popup rows) is derived
  // from this, filtered by the fuzzy query, so callers bind this and
  // never `model` directly.
  property var sourceModel: []
  // When set, the dropdown grows a fuzzy search field that filters
  // `sourceModel` live as the user types.
  property bool searchable: false
  // Live fuzzy query, driven by the popup's search field.
  property string filterQuery: ""
  // Placeholder shown in the search field (caller-localised).
  property string searchPlaceholder: ""

  // Visible rows: the full list, or its fuzzy-ranked subset while a
  // query is active. An empty query short-circuits to the source so an
  // un-searched combo is exactly the source array.
  model: (root.searchable && root.filterQuery !== "")
    ? Fuzzy.filter(root.sourceModel, root.filterQuery, root._textOf)
    : root.sourceModel

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

  // Label used to match an entry during fuzzy filtering — same
  // name→key fallback the delegate renders.
  function _textOf(e) {
    return (e && e.name !== undefined) ? String(e.name)
      : (e && e.key !== undefined ? String(e.key) : String(e));
  }

  // Pick the filtered entry at `idx` (the search field's "accept"):
  // restore the full list, select the key, notify, and close.
  function _chooseFiltered(idx) {
    // `model` reads back array-like (QVariantList) but not necessarily a
    // real JS Array, so duck-type the length the way _syncFromKey does.
    const arr = root.model;
    const n = (arr && typeof arr === "object" && "length" in arr) ? arr.length : 0;
    if (idx < 0 || idx >= n) return;
    const entry = arr[idx];
    const k = (entry && entry.key !== undefined) ? entry.key : "";
    if (k === "") return;
    root.filterQuery = "";
    if (k !== root.currentKey) root.currentKey = k;
    root.selected(k);
    root.popup.close();
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
    id: comboPopup
    y: root.height
    width: root.width
    // Cap the list area at popupHeight; when searchable, the field adds
    // its own intrinsic height on top (referencing implicitHeight, not
    // the layout-assigned height, keeps this loop-free).
    implicitHeight: Math.min(popupColumn.implicitHeight,
      root.popupHeight + (searchField.visible ? searchField.implicitHeight + popupColumn.spacing : 0))
    // Take keyboard focus when opened so the search field receives input.
    focus: root.searchable
    onOpened: {
      if (!root.searchable) return;
      searchField.clear();
      searchField.forceActiveFocus();
    }
    // Clearing the query restores the full list so the closed display and
    // currentKey↔index sync realign to the real selection on dismissal.
    onClosed: root.filterQuery = ""

    contentItem: ColumnLayout {
      id: popupColumn
      spacing: Style.marginXS

      NTextInput {
        id: searchField
        visible: root.searchable
        Layout.fillWidth: true
        Layout.preferredHeight: visible ? implicitHeight : 0
        font.pointSize: Style.fontSizeS
        placeholderText: root.searchPlaceholder
        onTextChanged: root.filterQuery = text
        // Enter takes the top-ranked match; a bare Enter with nothing
        // typed just dismisses without changing the selection. Esc
        // always dismisses.
        onAccepted: root.filterQuery !== "" ? root._chooseFiltered(0) : comboPopup.close()
        Keys.onEscapePressed: comboPopup.close()
      }

      ListView {
        Layout.fillWidth: true
        Layout.preferredHeight: Math.min(contentHeight, root.popupHeight)
        clip: true
        // Qt's own ComboBox popup sets this; without it a bare ListView
        // reports implicitHeight 0, collapsing the Popup to zero height
        // (the dropdown opens but is invisible). contentHeight is the
        // laid-out total, capped by popupHeight above.
        implicitHeight: contentHeight
        model: comboPopup.visible ? root.delegateModel : null
        currentIndex: root.highlightedIndex
      }
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

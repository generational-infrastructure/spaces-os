// Headless host for the NComboBox fuzzy model-search filter.
//
// The panel's model selector is `searchable`: typing into the dropdown
// narrows it to a fuzzy-ranked subset of the source list, and accepting
// (Enter) picks the top match. This shell stages the REAL NComboBox
// (searchable) over a known model list plus the real Fuzzy helper, and
// exposes both the widget's filtered view (combo.model) and the raw
// Fuzzy.filter ranking over IPC so the driver can assert filtering,
// exclusion and selection without a compositor.
//
// FloatingWindow over PanelWindow because the offscreen Qt platform
// ships no layer-shell; the combo sizing is identical either way.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Widgets

FloatingWindow {
  id: win
  implicitWidth: 360
  implicitHeight: 280
  visible: true

  // Names carry an executor/provider prefix exactly like the panel's
  // entries, so "kiwi" must match a model purely by its source tag.
  property var testModel: [
    { key: "openrouter/gpt-4o", name: "[openrouter] gpt-4o" },
    { key: "openrouter/gpt-4o-mini", name: "[openrouter] gpt-4o-mini" },
    { key: "openrouter/claude-3.5-sonnet", name: "[openrouter] claude-3.5-sonnet" },
    { key: "local/llama-3.1-8b", name: "[kiwi] llama-3.1-8b" },
  ]
  property string lastSelected: ""

  NComboBox {
    id: combo
    width: 320
    searchable: true
    searchPlaceholder: "Search models…"
    sourceModel: win.testModel
    currentKey: "local/llama-3.1-8b"
    onSelected: key => win.lastSelected = key
  }

  IpcHandler {
    target: "test:fuzzy"

    // The widget's visible row set: count and the keys in popup order.
    function count(): string { return String(combo.count); }
    function keys(): string {
      const arr = combo.model || [];
      return JSON.stringify(arr.map(e => e.key));
    }

    // Drive the live query the search field would set, then read it back.
    function setQuery(q: string) { combo.filterQuery = q; }
    function clearQuery() { combo.filterQuery = ""; }
    function query(): string { return combo.filterQuery; }

    // Accept the row at `i` (what Enter does at i=0): selects it,
    // restores the full list and notifies via onSelected.
    function choose(i: string) { combo._chooseFiltered(Number(i)); }
    function selected(): string { return win.lastSelected; }
    function currentKey(): string { return combo.currentKey; }

    // Popup lifecycle, so the driver can open the searchable dropdown and
    // assert it gains a real height (the search field + list ColumnLayout
    // geometry) instead of collapsing to zero.
    function openPopup() { combo.popup.open(); }
    function closePopup() { combo.popup.close(); }
    function popupVisible(): bool { return combo.popup.visible; }
    function popupHeight(): string { return String(combo.popup.height); }

    // Direct ranking probe over the pure helper: comma-delimited
    // candidates (quickshell's ipc CLI mangles brackets/braces, so a JSON
    // array can't be an argument; the model ids carry no commas).
    function fuzzy(q: string, csv: string): string {
      const items = String(csv).length ? String(csv).split(",") : [];
      return JSON.stringify(Fuzzy.filter(items, q, x => x));
    }
  }
}

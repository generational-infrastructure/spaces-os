pragma Singleton

// Stand-in for noctalia's Services.UI/TooltipService singleton. The mapping
// test only needs show/hide to exist; it asserts tooltipKey, not the popup.
import QtQuick

QtObject {
  function show(item, text, position) {}
  function hide(item) {}
}

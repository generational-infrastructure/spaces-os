// Vertically-scrolling list. Used by the panel's session tab strip
// and the chat history pane.
//
// Inherits everything from QtQuick ListView so call sites pass model,
// delegate, spacing, etc., directly. The wrapper only attaches a
// hidden vertical ScrollBar — wheel and drag still scroll, the bar
// just never paints; the chat panel is narrow enough that even a 4 px
// indicator stole real estate next to each bubble.
import QtQuick
import QtQuick.Controls

ListView {
  id: root

  // noctalia API parity — call sites set these; we accept them as
  // inert properties because our simpler NListView relies on Qt's
  // native wheel handling (no custom multiplier) and never draws
  // edge-fade masks. `availableWidth` mirrors the drawable width so
  // bubble-width bindings keep working.
  property real wheelScrollMultiplier: 1.0
  property bool showGradientMasks: false
  readonly property real availableWidth: root.width

  clip: true
  boundsBehavior: Flickable.StopAtBounds

  // Hidden: the chat panel is narrow (~480 px) and even a 4 px bar
  // eats real estate next to each bubble. Wheel and drag still work
  // because Flickable doesn't need a visible scrollbar to scroll.
  ScrollBar.vertical: ScrollBar {
    parent: root
    anchors.top: root.top
    anchors.bottom: root.bottom
    anchors.right: root.right
    policy: ScrollBar.AlwaysOff
  }
}

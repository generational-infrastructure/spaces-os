// Vertically-scrolling list with a styled scrollbar. Used by the
// panel's session tab strip.
//
// Inherits everything from QtQuick ListView so call sites pass model,
// delegate, spacing, etc., directly. The wrapper only attaches a
// ScrollBar so the look matches the rest of the chat surface.
import QtQuick
import QtQuick.Controls
import qs.Commons

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

  ScrollBar.vertical: ScrollBar {
    parent: root
    anchors.top: root.top
    anchors.bottom: root.bottom
    anchors.right: root.right
    policy: ScrollBar.AsNeeded

    contentItem: Rectangle {
      implicitWidth: 4
      radius: 2
      color: Color.mOnSurfaceVariant
      opacity: 0.5
    }
  }
}

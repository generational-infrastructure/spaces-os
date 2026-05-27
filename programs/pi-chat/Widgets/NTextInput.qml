// Single-line text input. The compose box uses a multi-line variant
// directly (TextArea inside Flickable); this NTextInput covers the
// noctalia-API single-line surface for any future inline inputs.
//
// API the plugin uses: `text`, `placeholderText`, `onAccepted`,
// `onTextChanged`, `forceActiveFocus()`, `selectAll()`. Standard
// QtQuick TextField gives us all of these; the wrapper only styles.
import QtQuick
import QtQuick.Controls
import qs.Commons

TextField {
  id: root

  // noctalia's NTextInput exposes an `inputItem` property pointing
  // at the inner TextInput control. Callers bind signals/keys
  // against it: `inputItem.onTextChanged: ...`,
  // `inputItem.Keys.onReturnPressed: ...`. Our wrapper IS a plain
  // TextField, so the alias is self-referential — but the surface
  // preserves noctalia's binding syntax in port sites.
  property alias inputItem: root

  color: Color.mOnSurface
  placeholderTextColor: Color.mOnSurfaceVariant
  selectionColor: Color.mPrimary
  selectedTextColor: Color.mOnPrimary
  font.family: Settings.data.ui.fontDefault
  font.pointSize: Style.fontSizeM
  padding: Style.marginS

  background: Rectangle {
    color: Color.mSurfaceVariant
    radius: Style.iRadiusM
    border.color: root.activeFocus ? Color.mPrimary : Color.mOutline
    border.width: Style.borderS
  }
}

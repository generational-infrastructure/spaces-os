// Numeric spin box used by the settings panel for `maxHistory`.
//
// Plugin uses: `label`, `description`, `from`, `to`, `stepSize`,
// `value`, `onValueModified`. Wraps QtQuick Controls SpinBox with
// label/description text above.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons

ColumnLayout {
  id: root

  property string label: ""
  property string description: ""
  property int from: 0
  property int to: 1000
  property int stepSize: 1
  property int value: 0

  // Same signal name noctalia uses so call sites port unchanged.
  signal valueModified(int v)

  spacing: Style.marginXXS

  NText {
    text: root.label
    pointSize: Style.fontSizeM
    color: Color.mOnSurface
    Layout.fillWidth: true
  }

  NText {
    visible: root.description !== ""
    text: root.description
    pointSize: Style.fontSizeS
    color: Color.mOnSurfaceVariant
    wrapMode: Text.WordWrap
    Layout.fillWidth: true
  }

  SpinBox {
    id: spin
    from: root.from
    to: root.to
    stepSize: root.stepSize
    value: root.value
    editable: true
    onValueModified: root.valueModified(value)
    Layout.fillWidth: true

    contentItem: NText {
      text: spin.textFromValue(spin.value, spin.locale)
      color: Color.mOnSurface
      horizontalAlignment: Text.AlignHCenter
    }
    background: Rectangle {
      color: Color.mSurfaceVariant
      radius: Style.iRadiusM
      border.color: Color.mOutline
      border.width: Style.borderS
    }
  }
}

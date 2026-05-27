// Styled Text. Minimal subset of noctalia's qs.Widgets.NText covering
// the properties the plugin actually binds against: text, pointSize,
// font.weight, font.family, font.features, color, wrapMode, elide,
// horizontalAlignment, Layout.* (inherited from Text), plus the
// richTextEnabled / markdownTextEnabled toggles used by Bubble.
//
// Defaults pulled from Style/Color so most call sites can pass just
// `text:`.
import QtQuick
import QtQuick.Layouts
import qs.Commons

Text {
  id: root

  property bool richTextEnabled: false
  property bool markdownTextEnabled: false
  property string family: Settings.data.ui.fontDefault
  property real pointSize: Style.fontSizeM

  opacity: enabled ? 1.0 : 0.6
  font.family: root.family
  font.weight: Style.fontWeightMedium
  font.pointSize: Math.max(1, root.pointSize * Settings.data.ui.fontDefaultScale)
  color: Color.mOnSurface
  elide: Text.ElideRight
  wrapMode: Text.NoWrap
  verticalAlignment: Text.AlignVCenter

  textFormat: {
    if (root.richTextEnabled) return Text.RichText;
    if (root.markdownTextEnabled) return Text.MarkdownText;
    return Text.PlainText;
  }
}

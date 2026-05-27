// Layout/spacing/font/animation tokens.
//
// Trimmed copy of noctalia's qs.Commons.Style retaining only the
// properties actually referenced by the chat plugin (audited via
// `grep -rhoE 'Style\.[a-zA-Z]+' programs/pi-chat-plugin/`). All
// dynamic dependencies on Settings.data.* (radiusRatio, scaleRatio,
// animationDisabled) are folded into constants — the standalone
// app does not expose per-user scaling knobs in v1.
pragma Singleton

import QtQuick

QtObject {
  // Font sizes
  readonly property real fontSizeXS: 9
  readonly property real fontSizeS: 10
  readonly property real fontSizeM: 11
  readonly property real fontSizeL: 13
  readonly property real fontSizeXL: 16

  // Font weight (only Medium is used)
  readonly property int fontWeightMedium: 500

  // Container radii (constants; noctalia multiplies by Settings.data.general.radiusRatio)
  readonly property int radiusXS: 8
  readonly property int radiusS: 12

  // Input radius (used by NIconButton/NButton — slightly different scale in noctalia)
  readonly property int iRadiusM: 16

  // Border width (1 px at scale 1.0)
  readonly property int borderS: 1

  // Margins (constants; noctalia multiplies by uiScaleRatio)
  readonly property int marginXXS: 2
  readonly property int marginXS: 4
  readonly property int marginS: 6
  readonly property int marginM: 9
  readonly property int marginL: 13

  // Base widget size (NIconButton/NButton default)
  readonly property real baseWidgetSize: 33

  // UI scale ratio (constant 1.0 in v1; future scaling knob)
  readonly property real uiScaleRatio: 1.0

  // Animation duration in ms (only Fast is used)
  readonly property int animationFast: 150
}

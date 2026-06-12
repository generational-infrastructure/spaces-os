// Layout/spacing/font/animation tokens.
//
// Trimmed copy of noctalia's qs.Commons.Style retaining only the
// properties actually referenced by the chat plugin (audited via
// `grep -rhoE 'Style\.[a-zA-Z]+' programs/pi-chat-plugin/`).
//
// Radii, borders and margins are derived live from noctalia's
// settings.json the same way noctalia itself derives them:
//
//   radius*  = round(base * general.radiusRatio)
//   iRadius* = round(base * general.iRadiusRatio)   // input controls
//   border*/margin* = round(base * general.scaleRatio)
//
// We read the same file noctalia writes (honouring $NOCTALIA_CONFIG_DIR
// exactly as noctalia does) and watch it, so the panel's corner radius
// tracks the bar — a sharper-cornered scheme makes the chat window
// sharper too. When settings.json is absent — noctalia not installed,
// or not yet configured — the JsonAdapter defaults below (all ratios
// 1.0) reproduce the sharpened base constants (2/4/6, border 1, the
// unscaled margins). The base radii were tightened from noctalia's
// 8/12/16 to **2/4/6** to match the Spaces OS design system's crisper,
// more terminal-adjacent look (see `docs/design-system/source/readme.md` →
// "Visual foundations / Spacing, radii, borders"). A noctalia scheme
// that bumps `radiusRatio` above 1.0 can still bring softer corners
// back in.
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
  id: root

  // Font sizes
  readonly property real fontSizeXS: 9
  readonly property real fontSizeS: 10
  readonly property real fontSizeM: 11
  readonly property real fontSizeL: 13
  readonly property real fontSizeXL: 16

  // Font weight (only Medium is used)
  readonly property int fontWeightMedium: 500

  // Container radii (noctalia: round(base * general.radiusRatio)).
  // Bases tightened from 8/12 to 2/4 per the design system.
  readonly property int radiusXS: Math.round(2 * general.radiusRatio)
  readonly property int radiusS: Math.round(4 * general.radiusRatio)

  // Input radius (NIconButton/NButton — noctalia scales these by iRadiusRatio).
  // Base tightened from 16 to 6 per the design system.
  readonly property int iRadiusM: Math.round(6 * general.iRadiusRatio)

  // Border width (noctalia: max(1, round(1 * scaleRatio)))
  readonly property int borderS: Math.max(1, Math.round(1 * uiScaleRatio))

  // Margins (noctalia: round(base * scaleRatio))
  readonly property int marginXXS: Math.round(2 * uiScaleRatio)
  readonly property int marginXS: Math.round(4 * uiScaleRatio)
  readonly property int marginS: Math.round(6 * uiScaleRatio)
  readonly property int marginM: Math.round(9 * uiScaleRatio)
  readonly property int marginL: Math.round(13 * uiScaleRatio)

  // Base widget size (NIconButton/NButton default)
  readonly property real baseWidgetSize: 33

  // UI scale ratio (noctalia: general.scaleRatio; defaults to 1.0)
  readonly property real uiScaleRatio: general.scaleRatio

  // Animation duration in ms (only Fast is used)
  readonly property int animationFast: 150

  // Same config-dir resolution noctalia (and Color.qml) uses.
  readonly property string noctaliaConfigDir: (Quickshell.env("NOCTALIA_CONFIG_DIR") || ((Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/noctalia"))

  // The `general` block of noctalia's settings.json. Only the ratio knobs
  // the chat panel needs are mapped; everything else in the file is ignored.
  //
  // Aliased to the inline `generalAdapter` so the linter can resolve the ratio
  // members: a property typed as the bare `JsonObject` is opaque to qmllint, so
  // reads like `general.radiusRatio` would trip --max-warnings 0.
  readonly property alias general: generalAdapter

  property FileView _settingsFile: FileView {
    path: root.noctaliaConfigDir + "/settings.json"
    printErrors: false
    watchChanges: true
    // FileView 0.3.0 does not read on construction (setPath only arms the
    // watcher); prime it once so the ratios load immediately, then let the
    // watcher pick up later edits. Mirrors Color.qml's colors.json handling.
    onFileChanged: reload()
    Component.onCompleted: reload()

    JsonAdapter {
      id: settings
      // Defaults (all ratios 1.0) match noctalia's own defaults and the
      // plugin's original hardcoded constants. A missing file or absent key
      // falls back here, so a setup without noctalia is unchanged.
      property JsonObject general: JsonObject {
        id: generalAdapter
        property real radiusRatio: 1.0
        property real iRadiusRatio: 1.0
        property real scaleRatio: 1.0
      }
    }
  }
}

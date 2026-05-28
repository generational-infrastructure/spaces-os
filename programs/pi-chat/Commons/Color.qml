// Material-3-flavoured palette, mirrored live from noctalia.
//
// noctalia writes its resolved scheme to colors.json under its config
// dir; a colour edit, a wallpaper-derived recolour, or a light/dark
// switch all rewrite that file. We read the same file (honouring
// $NOCTALIA_CONFIG_DIR exactly as noctalia does) and watch it, so the
// chat panel always matches the bar. When the file is absent — noctalia
// not running, or no scheme generated yet — the adapter defaults below
// (Noctalia-default dark) keep the panel looking sane.
//
// `smartAlpha` is a no-op pass-through: we don't expose noctalia's
// translucency toggles, so the identity function preserves intent.
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
  id: root

  // Accent
  readonly property color mPrimary: palette.mPrimary
  readonly property color mOnPrimary: palette.mOnPrimary
  readonly property color mSecondary: palette.mSecondary
  readonly property color mTertiary: palette.mTertiary
  readonly property color mOnTertiary: palette.mOnTertiary

  // Utility
  readonly property color mError: palette.mError
  readonly property color mOnError: palette.mOnError

  // Surface
  readonly property color mSurface: palette.mSurface
  readonly property color mOnSurface: palette.mOnSurface
  readonly property color mSurfaceVariant: palette.mSurfaceVariant
  readonly property color mOnSurfaceVariant: palette.mOnSurfaceVariant

  // Outline / hover
  readonly property color mOutline: palette.mOutline
  readonly property color mHover: palette.mHover
  readonly property color mOnHover: palette.mOnHover

  function smartAlpha(baseColor, minAlpha) {
    return baseColor;
  }

  // Same resolution noctalia uses for its config dir.
  readonly property string noctaliaConfigDir: (Quickshell.env("NOCTALIA_CONFIG_DIR") || ((Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/noctalia"))

  property FileView _colorsFile: FileView {
    path: root.noctaliaConfigDir + "/colors.json"
    printErrors: false
    watchChanges: true
    onFileChanged: reload()

    // Defaults match Noctalia-default dark; a missing file or absent key
    // falls back here. Keys mirror noctalia's colors.json schema.
    JsonAdapter {
      id: palette
      property color mPrimary: "#fff59b"
      property color mOnPrimary: "#0e0e43"
      property color mSecondary: "#a9aefe"
      property color mOnSecondary: "#0e0e43"
      property color mTertiary: "#9BFECE"
      property color mOnTertiary: "#0e0e43"
      property color mError: "#FD4663"
      property color mOnError: "#0e0e43"
      property color mSurface: "#070722"
      property color mOnSurface: "#f3edf7"
      property color mSurfaceVariant: "#11112d"
      property color mOnSurfaceVariant: "#7c80b4"
      property color mOutline: "#21215F"
      property color mShadow: "#070722"
      property color mHover: "#9BFECE"
      property color mOnHover: "#0e0e43"
    }
  }

  // noctalia replaces colors.json atomically (rename), which the file
  // watcher alone can miss; watch the dir too, exactly as noctalia does.
  property FileView _colorsDir: FileView {
    path: root.noctaliaConfigDir
    printErrors: false
    watchChanges: true
    onFileChanged: root._colorsFile.reload()
  }
}

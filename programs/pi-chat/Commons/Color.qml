// Material-3-flavoured palette.
//
// Default palette matches noctalia's Noctalia-default dark scheme so
// users coming from the plugin see the same colours. The standalone
// app does not load colors.json or react to noctalia theme changes —
// that's deferred. `smartAlpha` is a no-op pass-through (the plugin
// only uses it for one Rectangle backdrop and the indirection is not
// load-bearing without noctalia's translucency settings).
pragma Singleton

import QtQuick

QtObject {
  // Accent
  readonly property color mPrimary: "#fff59b"
  readonly property color mOnPrimary: "#0e0e43"
  readonly property color mSecondary: "#a9aefe"
  readonly property color mTertiary: "#9BFECE"
  readonly property color mOnTertiary: "#0e0e43"

  // Utility
  readonly property color mError: "#FD4663"
  readonly property color mOnError: "#0e0e43"

  // Surface
  readonly property color mSurface: "#070722"
  readonly property color mOnSurface: "#f3edf7"
  readonly property color mSurfaceVariant: "#11112d"
  readonly property color mOnSurfaceVariant: "#7c80b4"

  // Outline / hover
  readonly property color mOutline: "#21215F"
  readonly property color mHover: "#9BFECE"
  readonly property color mOnHover: "#0e0e43"

  // Pass-through. noctalia uses this to derive a translucent variant
  // of a colour based on user settings; we don't expose translucency
  // toggles in v1 so the identity function preserves intent.
  function smartAlpha(baseColor, minAlpha) { return baseColor; }
}

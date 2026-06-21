pragma Singleton

// Minimal stand-in for noctalia's Commons/Color singleton, carrying only the
// palette entries BarWidget.qml reads, pinned to noctalia's default dark
// scheme so the colour assertions match what the real bar would render.
import QtQuick

QtObject {
  readonly property color mPrimary: "#fff59b"          // transcribing (amber)
  readonly property color mError: "#FD4663"            // recording (red)
  readonly property color mTertiary: "#9BFECE"         // no-speech warning (caution)
  readonly property color mOnSurfaceVariant: "#7c80b4" // idle (dim)
  readonly property color mHover: "#9BFECE"
  readonly property color mOnHover: "#0e0e43"
}

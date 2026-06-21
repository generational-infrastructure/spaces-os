pragma Singleton

// Stand-in for noctalia's Commons/Style singleton — just the sizing helpers
// BarWidget.qml reads. Values are arbitrary; only the colour / tooltip /
// glyph / visibility mapping is under test here.
import QtQuick

QtObject {
  readonly property real fontSizeM: 12

  function getCapsuleHeightForScreen(name) {
    return 24;
  }
  function toOdd(v) {
    return 25;
  }
}

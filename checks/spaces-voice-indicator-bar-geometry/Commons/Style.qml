// Test stub for noctalia's qs.Commons.Style — only getBarHeightForScreen
// (the bar thickness for the active screen/orientation), copied verbatim
// from upstream Commons/Style.qml so the glow's thickness matches the bar.
pragma Singleton
import QtQuick
import qs.Commons

QtObject {
  function toOdd(n) {
    return Math.floor(n / 2) * 2 + 1;
  }

  function getBarHeightForDensity(density, isVertical) {
    let h;
    switch (density) {
    case "mini":
      h = isVertical ? 23 : 21;
      break;
    case "compact":
      h = isVertical ? 27 : 25;
      break;
    case "comfortable":
      h = isVertical ? 39 : 37;
      break;
    case "spacious":
      h = isVertical ? 49 : 47;
      break;
    default:
    case "default":
      h = isVertical ? 33 : 31;
    }
    return toOdd(h);
  }

  function getBarHeightForScreen(screenName) {
    var density = Settings.getBarDensityForScreen(screenName);
    var position = Settings.getBarPositionForScreen(screenName);
    var isVertical = position === "left" || position === "right";
    return getBarHeightForDensity(density, isVertical);
  }
}

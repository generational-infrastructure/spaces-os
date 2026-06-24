// Test stub for noctalia's qs.Commons.Settings — only the bar-geometry
// surface BarPulseGeometry touches, with the SAME per-screen override
// resolution as upstream (Commons/Settings.qml) so the glow inherits
// position/density exactly as the real bar does. `data` is reassigned
// wholesale by the driver so dependent bindings re-evaluate.
pragma Singleton
import QtQuick

QtObject {
  id: settings

  property var data: ({
      "bar": {
        "barType": "simple",
        "position": "top",
        "monitors": [],
        "density": "default",
        "marginVertical": 4,
        "marginHorizontal": 4,
        "frameThickness": 8,
        "screenOverrides": []
      }
    })

  function _findScreenOverride(screenName) {
    var overrides = data.bar.screenOverrides;
    if (!screenName || !overrides || overrides.length === undefined) {
      return null;
    }
    for (var i = 0; i < overrides.length; i++) {
      if (overrides[i] && overrides[i].name === screenName) {
        return overrides[i];
      }
    }
    return null;
  }

  function getBarPositionForScreen(screenName) {
    var override = _findScreenOverride(screenName);
    if (override && override.enabled !== false && override.position !== undefined) {
      return override.position;
    }
    return data.bar.position || "top";
  }

  function getBarDensityForScreen(screenName) {
    var override = _findScreenOverride(screenName);
    if (override && override.enabled !== false && override.density !== undefined) {
      return override.density;
    }
    return data.bar.density || "default";
  }
}

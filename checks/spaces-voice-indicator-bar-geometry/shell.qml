// Headless host for the voice-indicator bar-pulse GEOMETRY test.
//
// Instantiates the plugin's BarPulseGeometry.qml (staged next to this
// file) against stubbed qs.Commons Settings/Style singletons, and exposes
// its computed glow geometry over IPC. The driver reassigns the whole bar
// config and the screen size, then reads the resulting bloom rectangle —
// no Wayland, no layer-shell, no compositor.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

Item {
  id: root

  BarPulseGeometry {
    id: geo
    screenName: "DP-1"
    screenWidth: 1920
    screenHeight: 1080
  }

  IpcHandler {
    target: "test:bargeom"

    // Replace the entire bar settings blob; reassigning Settings.data
    // re-evaluates every dependent binding in BarPulseGeometry.
    function configure(json: string): string {
      Settings.data = JSON.parse(json);
      return "ok";
    }

    function setScreen(name: string, w: int, h: int): string {
      geo.screenName = name;
      geo.screenWidth = w;
      geo.screenHeight = h;
      return "ok";
    }

    // All computed geometry as one JSON blob the driver parses.
    function geom(): string {
      return JSON.stringify({
                              "barShown": geo.barShown,
                              "position": geo.barPosition,
                              "vertical": geo.barIsVertical,
                              "gradientVertical": geo.gradientVertical,
                              "innerAtStart": geo.innerAtStart,
                              "thickness": geo.barThickness,
                              "glowDepth": geo.glowDepth,
                              "bloomX": geo.bloomX,
                              "bloomY": geo.bloomY,
                              "bloomW": geo.bloomW,
                              "bloomH": geo.bloomH
                            });
    }
  }
}

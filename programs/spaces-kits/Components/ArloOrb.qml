// ArloOrb — the Spaces OS AI agent mark (port of ArloOrb.jsx).
// A soft iridescent disc (pink→indigo) with a glowing inner eye. `pulse`
// adds the slow listening ring. (The bespoke robot render isn't vendored
// here; this is the design system's own gradient fallback.)
import QtQuick
import qs.Commons

Item {
  id: root

  property int dim: 40
  property bool pulse: false

  implicitWidth: root.dim
  implicitHeight: root.dim

  Rectangle {
    id: ring
    anchors.centerIn: disc
    width: disc.width
    height: disc.height
    radius: width / 2
    color: "transparent"
    border.width: 2
    border.color: Theme.arloTo
    visible: root.pulse
    opacity: 0

    SequentialAnimation on scale {
      running: root.pulse
      loops: Animation.Infinite
      NumberAnimation {
        from: 1.0
        to: 1.45
        duration: 1800
        easing.type: Easing.OutCubic
      }
    }
    SequentialAnimation on opacity {
      running: root.pulse
      loops: Animation.Infinite
      NumberAnimation {
        from: 0.45
        to: 0.0
        duration: 1800
        easing.type: Easing.OutCubic
      }
    }
  }

  Rectangle {
    id: disc
    anchors.fill: parent
    radius: width / 2
    gradient: Gradient {
      GradientStop {
        position: 0.0
        color: Theme.arloFrom
      }
      GradientStop {
        position: 1.0
        color: Theme.arloTo
      }
    }

    Rectangle {
      // Inner glowing eye (radial highlight approximated with a light disc).
      anchors.centerIn: parent
      width: root.dim * 0.34
      height: width
      radius: width / 2
      gradient: Gradient {
        GradientStop {
          position: 0.0
          color: Theme.white
        }
        GradientStop {
          position: 1.0
          color: Theme.kinSky
        }
      }
    }
  }
}

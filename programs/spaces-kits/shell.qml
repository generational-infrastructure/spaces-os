// spaces-kits standalone shell entry point.
//
// Two normal desktop windows showing the ported UI kits — the Files browser
// and the Arlo "Space" home. Run with `quickshell -p programs/spaces-kits`.
// (The screens are plain Items, so they also render in a bare QtQuick Window
// for offscreen preview/screenshots.)
import Quickshell

ShellRoot {
  FloatingWindow {
    implicitWidth: 1100
    implicitHeight: 720

    FilesApp {
      anchors.fill: parent
    }
  }

  FloatingWindow {
    implicitWidth: 1000
    implicitHeight: 720

    ArloHome {
      anchors.fill: parent
    }
  }
}

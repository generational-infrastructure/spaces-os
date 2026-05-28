// Headless host for the noctalia colour-tracking test.
//
// The chat panel's Color singleton must mirror noctalia's generated
// colors.json (honouring $NOCTALIA_CONFIG_DIR) and live-update when the
// file is rewritten — a colour edit or a light/dark switch both rewrite
// it. This shell surfaces Color over IPC so the driver can assert the
// palette both loads from disk and reacts to a replacement.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

FloatingWindow {
  id: win
  implicitWidth: 80
  implicitHeight: 80
  visible: true

  IpcHandler {
    target: "test:color"

    function surface(): string {
      return String(Color.mSurface);
    }
    function variant(): string {
      return String(Color.mSurfaceVariant);
    }
    function primary(): string {
      return String(Color.mPrimary);
    }

    // Robust colour comparison — avoids #rrggbb vs #aarrggbb ambiguity.
    function eq(key: string, hex: string): bool {
      var c = key === "surface" ? Color.mSurface : key === "variant" ? Color.mSurfaceVariant : key === "primary" ? Color.mPrimary : key === "onSurface" ? Color.mOnSurface : Color.mOutline;
      return Qt.colorEqual(c, hex);
    }
  }
}

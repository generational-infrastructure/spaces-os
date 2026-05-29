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
import qs.Widgets

FloatingWindow {
  id: win
  implicitWidth: 80
  implicitHeight: 80
  visible: true

  // Off-window icon whose recoloured SVG the driver inspects. The icon
  // must bake `color` into the markup (Tabler icons stroke with
  // `currentColor`); a MultiEffect tint is luminance-weighted and
  // collapses a black stroke to black for every colour.
  NIcon {
    id: probe
    icon: "search"
    color: Color.mPrimary
  }

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

  IpcHandler {
    target: "test:icon"

    // True once the SVG has been read off disk and recoloured.
    function ready(): bool {
      return probe.imageSource !== "";
    }

    function setColor(hex: string): void {
      probe.color = hex;
    }

    // The decoded SVG markup the icon paints, so the driver can assert
    // the requested colour is baked in and no `currentColor` remains.
    function markup(): string {
      var uri = probe.imageSource;
      var comma = uri.indexOf(",");
      return comma < 0 ? "" : decodeURIComponent(uri.slice(comma + 1));
    }
  }
}

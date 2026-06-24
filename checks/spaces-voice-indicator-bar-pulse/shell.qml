// Headless host for the voice-indicator bar-pulse activation test.
//
// Hosts two copies of the plugin's Main.qml service (staged next to this
// file so `Main {}` resolves locally) and exposes their pulse-driving
// state over IPC:
//
//   svcDefault  — no pluginApi, so the barPulse setting takes its default
//                 (ON). Proves the ambient cue activates out of the box.
//   svcDisabled — a stub pluginApi whose pluginSettings.barPulse is false.
//                 Proves the opt-out is honoured.
//
// Both watch the SAME $XDG_RUNTIME_DIR/voxtype/state file, so the driver
// writes one word and asserts pulseActive on both. Neither instance's
// overlay LazyLoader arms here (svcDefault has no pluginApi; svcDisabled
// has the feature off), so Main.qml stays standalone — no noctalia
// qs.Commons / layer-shell needed. No compositor.
import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  // Default host: pluginApi null → barPulse defaults ON.
  Main {
    id: svcDefault
  }

  // A minimal stand-in for the plugin host that turns the feature off.
  QtObject {
    id: disabledApi
    property var pluginSettings: ({
        "barPulse": false
      })
  }

  // Opt-out host: barPulse explicitly false.
  Main {
    id: svcDisabled
    pluginApi: disabledApi
  }

  IpcHandler {
    target: "test:voicepulse"

    // The raw lifecycle word, to confirm both services track the file.
    function stateDefault(): string {
      return svcDefault.voiceState;
    }

    // Whether the bar pulse is currently active (recording/streaming and
    // enabled). Returned as a word so the driver parses it deterministically.
    function pulseDefault(): string {
      return svcDefault.pulseActive ? "true" : "false";
    }
    function pulseDisabled(): string {
      return svcDisabled.pulseActive ? "true" : "false";
    }

    // The resolved enable flag (default vs opted-out).
    function enabledDefault(): string {
      return svcDefault.barPulseEnabled ? "true" : "false";
    }
    function enabledDisabled(): string {
      return svcDisabled.barPulseEnabled ? "true" : "false";
    }
  }
}

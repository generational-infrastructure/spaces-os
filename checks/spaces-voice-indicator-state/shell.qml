// Headless host for the voice-indicator reactivity test.
//
// Hosts the plugin's Main.qml service (staged next to this file, so the
// `Main {}` component resolves from the same directory) and exposes its
// voiceState + qualityWarning over IPC. The driver writes voxtype's state
// file and reads the values back to assert the FileView wiring and the
// VAD-rejection inference. No noctalia modules, no compositor.
import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  Main {
    id: svc
    // Stub the injected plugin host so Main reads a short warning timeout
    // (the real default is ~4s; 600ms keeps the auto-clear assertion fast
    // and deterministic). Only pluginSettings is consumed by Main.qml.
    pluginApi: QtObject {
      property var pluginSettings: ({
          "noSpeechWarningMs": 600
        })
    }
  }

  IpcHandler {
    target: "test:voice"

    // The current voxtype lifecycle word, or "down" when the file is
    // absent (daemon not running / removed).
    function state(): string {
      return svc.voiceState;
    }

    // The transient "recording quality impeded" marker: "no_speech" while
    // a VAD-rejected take is being surfaced, "" otherwise.
    function quality(): string {
      return svc.qualityWarning || "";
    }
  }
}

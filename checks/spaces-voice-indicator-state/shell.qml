// Headless host for the voice-indicator reactivity test.
//
// Hosts the plugin's Main.qml service (staged next to this file, so the
// `Main {}` component resolves from the same directory) and exposes its
// voiceState over IPC. The driver writes voxtype's state file and reads
// the value back to assert the FileView wiring. No noctalia modules, no
// compositor.
import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  Main {
    id: svc
  }

  IpcHandler {
    target: "test:voice"

    // The current voxtype lifecycle word, or "down" when the file is
    // absent (daemon not running / removed).
    function state(): string {
      return svc.voiceState;
    }
  }
}

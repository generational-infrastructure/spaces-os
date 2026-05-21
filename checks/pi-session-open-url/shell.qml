// Open-URL listener round-trip test.
//
// Instantiates the real OpenUrlListener.qml from the pi-chat plugin,
// overrides `openUrlSink` so we never actually invoke Qt.openUrlExternally
// (the test machine has no graphical session anyway), and records every
// dispatched URL to a witness file the driver reads.
//
// We deliberately use the production component file. Tests that copy
// the dispatch logic into their own QML mask wiring bugs (see the
// pre-existing skill-config check, which did exactly that and let the
// promptRespond → daemon write regression slip through).
import QtQuick
import Quickshell
import Quickshell.Io
import qs

Item {
  id: root

  readonly property string sockPath: Quickshell.env("TEST_OPEN_URL_SOCK")
  readonly property string witnessPath: Quickshell.env("TEST_WITNESS_FILE")

  OpenUrlListener {
    id: listener
    sockPath: root.sockPath
    openUrlSink: (url) => {
      witnessProc.command = ["sh", "-c", "printf '%s\\n' \"$1\" >> \"$2\"", "sh", url, root.witnessPath];
      witnessProc.running = true;
    }
  }

  Process {
    id: witnessProc
  }
}

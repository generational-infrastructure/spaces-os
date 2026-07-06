// Headless host for the activity.json contract test.
//
// Hosts the sessions-bar plugin's Main.qml service (staged next to this
// file, so the `Main {}` component resolves from the same directory) and
// exposes its parsed model over IPC. The driver writes fixture
// activity.json files replicating PiChatBackend._writeActivity's output
// and reads the values back to assert the FileView wiring and the
// consumer's parse rules. No noctalia modules, no pi-chat, no compositor.
import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  Main {
    id: svc
    // The real plugin host injects pluginApi; Main.qml never dereferences
    // it, so the null default is fine for this headless harness.
  }

  IpcHandler {
    target: "test:activity"

    // The id of the chat the bar should highlight, "" when none.
    function active(): string {
      return svc.activeSessionId;
    }

    // The session model flattened one row per chat as "id|name|state",
    // rows joined with ";". Empty string = empty model. Deliberately
    // projects only the three contract fields, so fixture rows with
    // extra keys still compare equal when the consumer tolerates them.
    function sessions(): string {
      const rows = (svc.sessions || []).map(function (s) {
        return [s.id, s.name, s.state].join("|");
      });
      return rows.join(";");
    }
  }
}

// Headless host for the host-directive launch contract.
//
// PiChatBackend's executor inventory normally comes from
// /etc/spaces/pi-chat.json (a FileView), which the build sandbox can't
// write. Instead we seed the JsonAdapter's `executors` property in-memory
// — the `executors` binding re-evaluates and the Instantiator builds the
// PiExecutor pool just as a real deployment would. url:"" keeps each
// executor inactive, so a pinned launch never spawns a local pi.
//
// The whole pi-chat tree is staged beside this file so `import qs.*` and
// the PiChatBackend children resolve as under the production shell.
import QtQuick
import Quickshell
import Quickshell.Io

FloatingWindow {
  id: win
  implicitWidth: 320
  implicitHeight: 200
  visible: true

  PiChatBackend {
    id: backend
    panelVisible: false
  }

  IpcHandler {
    target: "test:quick-launch-host"

    // Seed two executors the way services.pi-chat's managed JSON would.
    // Returns the resolved id list so the driver can confirm the seed took.
    function seedExecutors(): string {
      backend._cfg.executors = [
        { id: "kiwi", url: "" },
        { id: "traube", url: "" },
      ];
      return JSON.stringify((backend.executors || []).map(e => e.id));
    }

    function launchHost(prompt: string, executor: string): string {
      return backend.launchBackground(prompt, { executor: executor });
    }
    function launchPlain(prompt: string): string {
      return backend.launchBackground(prompt, {});
    }

    function sessionCount(): int { return backend.sessionsList.length; }
    function defaultExecutorId(): string { return backend.defaultExecutorId; }

    // Raw entries incl. the `executor` field that listSessions() omits.
    function dumpSessions(): string {
      return JSON.stringify(
        backend.sessionsList.map(s => ({ id: s.id, executor: s.executor })));
    }
  }
}

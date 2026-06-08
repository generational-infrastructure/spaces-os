// Headless host for the quick-launch duplicate-session regression.
//
// Mounts the real PiChatBackend with a single REMOTE executor configured
// (injected via $SPACES_PI_CHAT_EXECUTORS) and the panel reported hidden, then
// exposes IPC so the driver can:
//
//   * create a session pinned to that remote executor and drive it, then
//     read back the raw index to assert the create→broadcast→re-import path
//     yields exactly ONE entry (no dead duplicate); and
//   * fire backend.launchBackground() (the Mod+/ quick-bar path) and assert
//     the resulting session follows defaultExecutor (the lone remote) and
//     stays a single index entry.
//
// The whole pi-chat plugin tree is staged alongside this file by the driver,
// so PiExecutor / PiSession / qs.Commons resolve exactly as in production.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

Item {
  id: root

  PiChatBackend {
    id: backend
    panelVisible: false
  }

  IpcHandler {
    target: "test:dup"

    function newSessionOn(name: string, executor: string): string {
      return backend.newSession(name, executor);
    }
    function launchBackground(prompt: string): string {
      return backend.launchBackground(prompt);
    }

    // Reproduce launchBackground's exact spawn()-then-send() double-spawn on
    // an arbitrary (here: remote-pinned) session, to prove _wsSpawn is
    // idempotent across the in-flight create window — i.e. the second spawn
    // does NOT mint a second daemon session that orphans into a duplicate.
    function spawnSend(id: string, text: string) {
      const o = backend._sessionObjs[id];
      if (!o) return;
      o.spawn();
      o.send(text);
    }

    // Raw index including executor + daemonSessionId, which listSessions()
    // omits but the dedup assertions need.
    function rawSessions(): string {
      return JSON.stringify(backend.sessionsList.map(s => ({
        id: s.id,
        name: s.name,
        executor: s.executor,
        daemonSessionId: s.daemonSessionId || "",
      })));
    }

    function executorConnected(id: string): bool {
      const e = backend._executorById[id];
      return e ? !!e.connected : false;
    }

    function lastAssistantText(id: string): string {
      const o = backend._sessionObjs[id];
      if (!o || !Array.isArray(o.messages)) return "";
      for (let i = o.messages.length - 1; i >= 0; i--) {
        const m = o.messages[i];
        if (m && m.from === "peer" && (m.type || "") === "" && m.text) return m.text;
      }
      return "";
    }
  }
}

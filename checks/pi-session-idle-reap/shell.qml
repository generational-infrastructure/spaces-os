// Headless host for the WS-era idle-reap contract test.
//
// Mounts the real PiChatBackend with a single REMOTE executor configured
// (injected via $SPACES_PI_CHAT_EXECUTORS) and the panel reported hidden,
// then exposes IPC so the driver can:
//
//   * fire backend.launchBackground() twice — one prompt the mock daemon
//     holds mid-turn (busy stays true), one it completes (agent_end);
//   * read back busy/streaming flags and each entry's daemonSessionId; and
//   * invoke backend._reapIdle() directly (deterministic — no waiting on
//     the real idleTimeoutMinutes timer).
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
    target: "test:reap"

    function launchBackground(prompt: string): string {
      return backend.launchBackground(prompt);
    }

    // The reaper under test: stops idle streaming sessions via
    // PiSession.stop() (detach frame + subscriber removal), skipping busy
    // sessions and pending background launches.
    function reapIdle() {
      backend._reapIdle();
    }

    // Raw index including daemonSessionId — the id the driver matches
    // against the mock daemon's detach frames.
    function rawSessions(): string {
      return JSON.stringify(backend.sessionsList.map(s => ({
        id: s.id,
        name: s.name,
        executor: s.executor,
        daemonSessionId: s.daemonSessionId || "",
      })));
    }

    function sessionBusy(id: string): bool {
      const o = backend._sessionObjs[id];
      return o ? !!o.busy : false;
    }

    function sessionStreaming(id: string): bool {
      const o = backend._sessionObjs[id];
      return o ? !!o.streaming : false;
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

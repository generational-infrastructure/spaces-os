// Plugin entry point. Loads PiChatBackend, which talks pi --mode rpc
// directly over stdio — one pi process per session, lazy-spawned under
// a systemd-run --user transient service sandbox.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.UI

Item {
  id: root

  property var pluginApi: null
  property alias chat: chatAlias.chat
  // Session entries surfaced by the backend; Panel.qml reads it for
  // the sidebar.
  readonly property var sessionsList: backend.sessionsList || []
  readonly property string activeSessionId: backend.activeSessionId || ""

  function cfg(key) {
    const s = pluginApi?.pluginSettings || {};
    const d = pluginApi?.manifest?.metadata?.defaultSettings || {};
    return s[key] ?? d[key];
  }

  // Indirection keeps Panel.qml's `pluginApi.mainInstance.chat`
  // binding live as the backend instantiates sessions.
  QtObject {
    id: chatAlias
    property var chat: backend.chat || null
  }

  PiChatBackend {
    id: backend
    pluginApi: root.pluginApi
  }

  // ── IpcHandler ──

  property real _lastTap: 0
  IpcHandler {
    target: "plugin:pi-chat"

    function tap() {
      const now = Date.now();
      if (now - root._lastTap < 400) toggle();
      root._lastTap = now;
    }
    function toggle() {
      backend.markRead?.();
      pluginApi?.withCurrentScreen(s => pluginApi.togglePanel(s));
    }
    function hide() {
      pluginApi?.withCurrentScreen(s => pluginApi.closePanel(s));
    }
    function send(text: string) { root.chat?.send(text); }
    function sendFile(path: string) { root.chat?.sendFile(path, true); }

    // Multi-session verbs.
    function newSession(name: string): string {
      return backend.newSession?.(name) ?? "";
    }
    function selectSession(id: string) {
      backend.selectSession?.(id);
    }
    function removeSession(id: string) {
      backend.removeSession?.(id);
    }
    function sendTo(id: string, text: string) {
      backend.sendTo?.(id, text);
    }
    function listSessions(): string {
      return backend.listSessions?.() ?? "[]";
    }

    // Test probes. Return JSON so callers can parse without scraping
    // pi's session.jsonl. Documented as the e2e entry point.
    function sessionMessages(id: string): string {
      const map = backend._sessionObjs;
      const obj = (id && map && map[id]) ? map[id] : root.chat;
      if (!obj) return "[]";
      return JSON.stringify(obj.messages || []);
    }
    function lastAssistantText(id: string): string {
      const map = backend._sessionObjs;
      const obj = (id && map && map[id]) ? map[id] : root.chat;
      if (!obj || !Array.isArray(obj.messages)) return "";
      for (let i = obj.messages.length - 1; i >= 0; i--) {
        const m = obj.messages[i];
        if (m && m.from === "peer" && (m.type || "") === "" && m.text) return m.text;
      }
      return "";
    }
  }

  // Open the panel idempotently.
  function showPanel() {
    if (pluginApi?.panelOpenScreen) {
      backend.markRead?.();
      return;
    }
    pluginApi?.withCurrentScreen(s => pluginApi.openPanel(s));
    backend.markRead?.();
  }
}

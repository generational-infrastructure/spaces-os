// Bridge between the distro-signal-bridge panel socket and the chat
// panel UI.
//
// Owns the long-lived subscriber connection to
// $XDG_RUNTIME_DIR/distro-signal/panel.sock. Each `op:"snapshot"`
// rebuilds `pending`; `op:"added"` appends one row; `op:"removed"`
// drops a row by token. The panel binds `pending` directly to render
// the approval cards.
//
// `approve(token)` / `deny(token)` write one NDJSON line each on the
// same socket; the bridge's broadcast then drops the row from
// `pending` on every subscriber (this component included).
//
// This file deliberately lives at the same layer as PiChatBackend so
// the security boundary is obvious — the panel socket is *only*
// reachable from outside the sandbox, so only the panel can
// instantiate this. The CLI inside the sandbox uses the disjoint
// enqueue socket and has no way to mint approvals.
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Io

QtObject {
  id: root

  // Set by the parent before `active = true`. Lets tests point at a
  // throwaway socket in a temp dir without monkey-patching env.
  property string sockPath: ""

  // Auto-reconnect: bridge service may restart (e.g. signal-cli
  // daemon flapped). We retry with linear backoff so subscribers
  // pick the socket back up without operator intervention.
  property bool active: false

  // Public, read-only-from-the-outside. Newest-first; each entry
  // mirrors the bridge's pending_sends row shape:
  //   { token, recipient, display_name, body, created_at, account_uuid, ... }
  property var pending: []

  readonly property bool connected: _socket.item?.connected ?? false

  function approve(token) {
    _send({ op: "approve", token: token });
  }

  function deny(token) {
    _send({ op: "deny", token: token });
  }

  function _send(payload) {
    if (!_socket.item || !_socket.item.connected) return false;
    try {
      _socket.item.write(JSON.stringify(payload) + "\n");
      _socket.item.flush();
      return true;
    } catch (e) {
      return false;
    }
  }

  function _onLine(raw) {
    let ev;
    try { ev = JSON.parse(raw); } catch (_e) { return; }
    if (!ev || !ev.op) return;
    if (ev.op === "snapshot") {
      const arr = Array.isArray(ev.pending) ? ev.pending.slice() : [];
      // Newest-first order matches what the panel wants to show on
      // top — the bridge returns oldest-first by created_at.
      arr.sort((a, b) => (b.created_at || 0) - (a.created_at || 0));
      pending = arr;
    } else if (ev.op === "added" && ev.request) {
      const arr = pending.slice();
      // Don't double-add — defensive against any future broadcast
      // duplicate (e.g. a snapshot racing an added event).
      if (!arr.some(p => p.token === ev.request.token)) {
        arr.unshift(ev.request);
        pending = arr;
      }
    } else if (ev.op === "removed" && ev.token) {
      const arr = pending.filter(p => p.token !== ev.token);
      if (arr.length !== pending.length) {
        pending = arr;
      }
    }
    // op === "decision" / "error" are responses to our own approve/
    // deny calls; nothing to render — the matching `removed` event
    // tells us the row is gone.
  }

  property var _socket: Loader {
    active: root.active && root.sockPath !== ""
    sourceComponent: Component {
      Socket {
        path: root.sockPath
        connected: true
        parser: SplitParser { onRead: line => root._onLine(line) }
        onConnectionStateChanged: {
          if (connected) {
            root._reconnectTimer.stop();
            root._reconnectTimer.interval = 500;
            write(JSON.stringify({ op: "subscribe" }) + "\n");
            flush();
          } else {
            // Connection dropped — drop any cached state so the
            // panel doesn't render stale approval cards against a
            // bridge that may have restarted with fresh tokens.
            root.pending = [];
            root._reconnectTimer.start();
          }
        }
        onError: _e => root._reconnectTimer.start() // qmllint disable signal-handler-parameters
      }
    }
  }

  property var _reconnectTimer: Timer {
    interval: 500
    onTriggered: {
      root._socket.active = false;
      root._socket.active = true;
      // Cap backoff at 4s — bridge restarts via systemd within ~3s.
      interval = Math.min(interval * 2, 4000);
    }
  }
}

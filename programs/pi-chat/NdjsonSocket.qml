// The ONE newline-delimited-JSON unix-socket adapter for the panel.
//
// Every pi-chat socket peer speaks NDJSON over AF_UNIX, but with three
// wire conventions. Instead of each consumer hand-rolling its own
// Socket + reconnect Timer + SplitParser + JSON.parse (three bespoke
// copies used to live in PiChatBackend's skill-config sidecar,
// IntegrationsBridge and OpenUrlListener), this component
// owns all connection-lifecycle edge cases — reconnect backoff, the
// bounce-to-reconnect idiom, backoff reset on success, one-shot
// done-guards, reply timeouts, stale-socket unlink — in one place.
// Consumers declare path + mode + handlers and stay pure protocol.
//
// Modes:
//   "subscribe" — persistent client. Connects while `active` and
//       `path` is set, writes the optional `hello` payload on every
//       (re)connect, emits `message(msg)` per parsed line and
//       `badLine(raw)` per unparseable one, and reconnects with
//       exponential backoff (500ms → 4s cap, reset on success) when
//       the peer drops. `send(payload)` writes one line back on the
//       live connection; `dropped()` fires on disconnect so consumers
//       can invalidate state cached from the dead peer.
//   "request" — no persistent connection; `request()` only (below).
//   "listen"  — server. Unlinks any stale socket file left by a
//       previous process, then accepts clients and emits
//       `message`/`badLine` for every inbound line.
//
// `request(payload, onReply)` works in any mode (subscribe consumers
// pair a long-lived feed with one-shot writes on the same path): a
// fresh connection per call — connect → write payload → first reply
// line wins → close. The reply callback is invoked exactly once, as
// `onReply(msg, raw)`: parsed reply + raw line on success, (null, raw)
// on an unparseable reply, (null, "") on close/error/timeout without
// a reply.
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Io

QtObject {
  id: root

  // Unix socket path. Empty ⇒ inert (subscribe/listen stay down,
  // request() refuses).
  property string path: ""

  // "subscribe" | "request" | "listen" — see header.
  property string mode: "subscribe"

  // Gate for the persistent modes. request() ignores it.
  property bool active: true

  // subscribe: JSON payload written as the first line after every
  // (re)connect, e.g. ({ op: "subscribe" }). undefined ⇒ nothing sent.
  property var hello: undefined

  // request: how long a one-shot waits for its reply line before
  // giving up with (null, "").
  property int requestTimeoutMs: 3000

  // subscribe: live connection state.
  readonly property bool connected: _subLoader.item?.connected ?? false

  // One parsed JSON line (subscribe/listen).
  signal message(var msg)
  // One line JSON.parse rejected (subscribe/listen).
  signal badLine(string raw)
  // subscribe: connection lost — cached peer state is now stale.
  signal dropped()
  // subscribe: socket error (reconnect is already scheduled).
  signal errored(var error)

  // subscribe: write one NDJSON line on the live connection.
  function send(payload) {
    const sock = _subLoader.item;
    if (!sock || !sock.connected)
      return false;
    try {
      sock.write(JSON.stringify(payload) + "\n");
      sock.flush();
      return true;
    } catch (_e) {
      return false;
    }
  }

  // One-shot request on a fresh connection; see header for the
  // onReply contract. Returns false when no attempt could be made.
  function request(payload, onReply) {
    if (path === "")
      return false;
    const sock = _oneShot.createObject(root, { path: path, payload: payload, replyCb: onReply ?? null });
    return sock !== null;
  }

  function _deliver(raw) {
    let msg;
    try {
      msg = JSON.parse(raw);
    } catch (_e) {
      badLine(raw);
      return;
    }
    message(msg);
  }

  // ── subscribe internals ──────────────────────────────────────────
  //
  // The Socket is recreated per connection attempt (Loader bounce)
  // instead of bouncing `connected` on a static Socket: quickshell's
  // Socket keeps its dead QLocalSocket around after a FAILED connect
  // attempt (no `disconnected` ever fires), so `connected = false;
  // connected = true` on that carcass is a no-op and the retry loop
  // dies the first time the peer's socket file is missing.

  readonly property bool _subActive: active && mode === "subscribe" && path !== ""
  on_SubActiveChanged: {
    _retry.stop();
    _retry.interval = 500;
    _subLoader.active = _subActive;
  }
  Component.onCompleted: {
    _subLoader.active = _subActive;
    if (_listenActive)
      _unlinkStale.running = true;
  }

  property var _subLoader: Loader {
    active: false
    sourceComponent: Component {
      Socket {
        path: root.path
        connected: true
        parser: SplitParser {
          onRead: line => root._deliver(line)
        }
        onConnectionStateChanged: {
          if (connected) {
            root._retry.stop();
            root._retry.interval = 500;
            if (root.hello !== undefined) {
              write(JSON.stringify(root.hello) + "\n");
              flush();
            }
          } else {
            root.dropped();
            if (root._subActive)
              root._retry.start();
          }
        }
        onError: e => {
          root.errored(e);
          if (root._subActive)
            root._retry.start();
        }
      }
    }
  }

  property Timer _retry: Timer {
    interval: 500
    onTriggered: {
      if (!root._subActive)
        return;
      // Fresh Socket per attempt — see the note above.
      root._subLoader.active = false;
      root._subLoader.active = true;
      interval = Math.min(interval * 2, 4000);
    }
  }

  // ── request internals ────────────────────────────────────────────

  property Component _oneShot: Component {
    Socket {
      id: shot

      property var payload: null
      property var replyCb: null
      // First terminal event wins: reply line, close, error, or the
      // deadline. Everything after is a no-op.
      property bool done: false
      readonly property Timer deadline: Timer {
        interval: root.requestTimeoutMs
        running: true
        onTriggered: shot._finish(null, "")
      }

      function _finish(msg, raw) {
        if (done)
          return;
        done = true;
        if (replyCb)
          replyCb(msg, raw);
        shot.destroy(1000);
      }

      connected: path !== ""
      parser: SplitParser {
        onRead: line => {
          let msg = null;
          try {
            msg = JSON.parse(line);
          } catch (_e) {}
          shot._finish(msg, line);
        }
      }
      onConnectionStateChanged: {
        if (connected) {
          write(JSON.stringify(shot.payload) + "\n");
          flush();
        } else {
          shot._finish(null, "");
        }
      }
      onError: _e => shot._finish(null, "")
    }
  }

  // ── listen internals ─────────────────────────────────────────────

  readonly property bool _listenActive: active && mode === "listen" && path !== ""
  on_ListenActiveChanged: {
    if (_listenActive)
      _unlinkStale.running = true;
  }

  // Unlink any socket file left by a previous process before the
  // server binds — otherwise quickshell logs a "Deleting existing
  // socket" warning every reload.
  property bool _staleGone: false
  property Process _unlinkStale: Process {
    command: ["rm", "-f", "--", root.path]
    onExited: root._staleGone = true
  }

  property SocketServer _server: SocketServer {
    active: root._listenActive && root._staleGone
    path: root.path
    handler: Socket {
      parser: SplitParser {
        onRead: line => root._deliver(line)
      }
    }
  }
}

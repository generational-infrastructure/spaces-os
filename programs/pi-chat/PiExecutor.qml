// One WebSocket connection to a pi-sessiond executor
// (docs/remote-pi-design.md §12). It owns the transport; PiSession
// instances route through it, multiplexed by the daemon-assigned
// sessionId.
//
//   send  { v:1, kind:"hello", token, client }
//         { v:1, kind:"create_session", name?, model?, workspace? }
//         { v:1, kind:"attach"|"detach", sessionId }
//         { v:1, kind:"command", sessionId, payload }   // payload = pi command
//
//   recv  { v:1, kind:"welcome", connectionId, caps }
//         { v:1, kind:"attached", sessionId, seq }
//         { v:1, kind:"event", sessionId, seq, payload }  // payload = pi event
//         { v:1, kind:"error", error }
//
// create_session's `attached` carries no correlation id, so pending
// creates resolve FIFO — the panel creates sessions one at a time.
import QtQuick
import QtWebSockets
import qs.Commons

QtObject {
  id: executor

  required property string url
  property string token: ""
  property bool active: false

  readonly property bool connected: _sock.status === WebSocket.Open && _welcomed

  // daemonSessionId -> PiSession (the subscriber fed incoming events)
  property var _subscribers: ({})
  property bool _welcomed: false
  property var _pendingCreates: []   // FIFO of { resolve, reject }
  property var _connectWaiters: []   // callbacks fired once welcomed

  property WebSocket _sock: WebSocket {
    url: executor.url
    active: executor.active
    onStatusChanged: status => {
      if (status === WebSocket.Open) {
        sendTextMessage(JSON.stringify({
          v: 1,
          kind: "hello",
          token: executor.token,
          client: { name: "pi-chat" },
        }));
      } else if (status === WebSocket.Closed || status === WebSocket.Error) {
        executor._onClosed(errorString);
      }
    }
    onTextMessageReceived: message => executor._onMessage(message)
  }

  function _onMessage(text) {
    let msg;
    try {
      msg = JSON.parse(text);
    } catch (e) {
      Logger.w("PiExecutor", "bad envelope", text);
      return;
    }
    switch (msg.kind) {
    case "welcome": {
      _welcomed = true;
      const waiters = _connectWaiters;
      _connectWaiters = [];
      for (const cb of waiters) cb();
      break;
    }
    case "attached": {
      // create_session ack (FIFO). attach acks for existing sessions
      // have no pending create and are simply ignored — the caller
      // already knows the id it attached.
      const p = _pendingCreates.shift();
      if (p) p.resolve(msg.sessionId);
      break;
    }
    case "event": {
      const obj = _subscribers[msg.sessionId];
      if (obj) obj._onEnvelopeEvent(msg.payload);
      break;
    }
    case "error":
      Logger.w("PiExecutor", "server error", JSON.stringify(msg));
      break;
    default:
      break;
    }
  }

  function _onClosed(reason) {
    _welcomed = false;
    const creates = _pendingCreates;
    _pendingCreates = [];
    for (const p of creates) p.reject("executor disconnected");
    const subs = _subscribers;
    _subscribers = ({});
    for (const sid in subs) subs[sid]?._onExecutorClosed?.();
    if (reason) Logger.w("PiExecutor", "closed", reason);
  }

  // Run cb once the connection is welcomed (immediately if already).
  function whenConnected(cb) {
    if (connected) { cb(); return; }
    _connectWaiters.push(cb);
  }

  function createSession(opts) {
    return new Promise((resolve, reject) => {
      if (!connected) { reject("executor not connected"); return; }
      _pendingCreates.push({ resolve: resolve, reject: reject });
      _sock.sendTextMessage(JSON.stringify(Object.assign(
        { v: 1, kind: "create_session" }, opts || {})));
    });
  }

  function attach(sid) {
    if (_sock.status === WebSocket.Open)
      _sock.sendTextMessage(JSON.stringify({ v: 1, kind: "attach", sessionId: sid }));
  }

  function detach(sid) {
    if (_sock.status === WebSocket.Open)
      _sock.sendTextMessage(JSON.stringify({ v: 1, kind: "detach", sessionId: sid }));
  }

  function command(sid, payload) {
    if (_sock.status === WebSocket.Open)
      _sock.sendTextMessage(JSON.stringify({ v: 1, kind: "command", sessionId: sid, payload: payload }));
  }

  function subscribe(sid, obj) { _subscribers[sid] = obj; }
  function unsubscribe(sid) { delete _subscribers[sid]; }
}

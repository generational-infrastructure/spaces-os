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
  property var _lastSeq: ({})        // daemonSessionId -> highest seq seen
  property bool _welcomed: false
  property var _pendingCreates: []   // FIFO of { resolve, reject }
  property var _connectWaiters: []   // callbacks fired once welcomed
  property bool _live: false         // drives the socket; toggled to reconnect
  onActiveChanged: _live = active
  Component.onCompleted: _live = active

  property WebSocket _sock: WebSocket {
    url: executor.url
    active: executor._live
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
        if (executor.active) {
          executor._live = false;  // toggle so the next connect is a real change
          executor._retry.restart();
        }
      }
    }
    onTextMessageReceived: message => executor._onMessage(message)
  }

  // The WebSocket does not auto-retry; reconnect with a short backoff while
  // a connection is wanted (server not up yet, dropped, or daemon restarted).
  property Timer _retry: Timer {
    interval: 1000
    repeat: false
    onTriggered: if (executor.active) executor._live = true
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
      // Re-attach sessions kept across a reconnect, replaying events missed
      // while the socket was down (the daemon replays seq > lastSeq).
      for (const sid in _subscribers) {
        _sock.sendTextMessage(JSON.stringify({
          v: 1, kind: "attach", sessionId: sid, lastSeq: _lastSeq[sid] ?? 0,
        }));
        _subscribers[sid]?._onExecutorReattached?.();
      }
      break;
    }
    case "attached": {
      const sid = msg.sessionId;
      // Re-attach ack for a kept session: if the daemon's seq is below our high
      // water mark the session was resurrected (seq reset) — drop the stale
      // mark so replayed/new events aren't suppressed.
      if ((sid in _subscribers) && (msg.seq < (_lastSeq[sid] ?? 0))) _lastSeq[sid] = msg.seq;
      // create_session ack (FIFO). attach acks for existing sessions have no
      // pending create and are simply ignored — the caller knows its id.
      const p = _pendingCreates.shift();
      if (p) p.resolve(sid);
      break;
    }
    case "event": {
      _lastSeq[msg.sessionId] = msg.seq;
      const obj = _subscribers[msg.sessionId];
      if (obj) obj._onEnvelopeEvent(msg.payload);
      break;
    }
    case "sidechannel_resolved": {
      // Another client answered a shared side-channel request; collapse ours.
      _subscribers[msg.sessionId]?._onSidechannelResolved?.(msg.id, msg.by);
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
    // Keep _subscribers so they re-attach (with lastSeq) on the next welcome.
    for (const sid in _subscribers) _subscribers[sid]?._onExecutorClosed?.();
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
      _sock.sendTextMessage(JSON.stringify({
        v: 1, kind: "attach", sessionId: sid, lastSeq: _lastSeq[sid] ?? 0,
      }));
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

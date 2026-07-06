// One WebSocket connection to a pi-sessiond executor
// (docs/remote-pi-design.md §12). It owns the transport; PiSession
// instances route through it, multiplexed by the daemon-assigned
// sessionId.
//
//   send  { v:1, kind:"hello", token, client }
//         { v:1, kind:"create_session", requestId, name?, model?, workspace? }
//         { v:1, kind:"attach"|"detach", sessionId }
//         { v:1, kind:"command", sessionId, payload }   // payload = pi command
//
//   recv  { v:1, kind:"welcome", connectionId, caps }
//         { v:1, kind:"attached", sessionId, seq, created?, requestId? }
//         { v:1, kind:"event", sessionId, seq, payload }  // payload = pi event
//         { v:1, kind:"error", error, sessionId?, requestId? }
//
// Each create_session carries a client-minted requestId; the daemon echoes
// it verbatim on the created ack (or on the error ack when the create
// fails), so several in-flight creates correlate directly — no FIFO
// guessing (packages/pi-sessiond/protocol.ts is normative).
import QtQuick
import QtWebSockets
import Quickshell.Io
import qs.Commons

QtObject {
  id: executor

  required property string url
  property string token: ""
  // When set, the `hello` token is read from this file at connect time instead
  // of from the inline `token` (see _helloToken).
  property string tokenPath: ""
  property bool active: false
  // The daemon's own executor id (welcome.caps.executor), surfaced so the UI
  // can label this executor's local models, e.g. "[kiwi] <model>".
  property string executorId: ""

  readonly property bool connected: _sock.status === WebSocket.Open && _welcomed
  // daemonSessionId -> PiSession (the subscriber fed incoming events)
  property var _subscribers: ({})
  property var _lastSeq: ({})        // daemonSessionId -> highest seq seen
  property bool _welcomed: false
  // In-flight create_sessions: requestId -> { onAttached, onError }. The
  // callbacks run SYNCHRONOUSLY inside the ack's message dispatch, so the
  // caller stamps its bookkeeping BEFORE the daemon's follow-up `sessions`
  // broadcast (sent right after the ack, a later message) is processed —
  // the importer never sees a created-but-unclaimed id.
  property var _inflightCreates: ({})
  property int _createSerial: 0
  property var _connectWaiters: []   // callbacks fired once welcomed
  property bool _live: false         // drives the socket; toggled to reconnect

  // Sessions known to the daemon. Populated by `list_sessions` on welcome,
  // refreshed by every unsolicited `kind:"sessions"` push (the daemon fans
  // one out on create_session / gcSession / cold→live attach). PiChatBackend
  // merges this per-executor view into its tab strip so a session created
  // on this executor by another client (the PWA, another panel) shows up
  // here, and vice versa.
  //
  // Each entry is `{ id, name, executorId, state, updated }`; `state` is
  // one of "cold" / "live-idle" / "live-busy" / "parked"; `updated` is the
  // daemon's last-activity ms-since-epoch.
  property var remoteSessions: []
  // Connection generation: bumped on every welcome. The session
  // registry keys its per-connection observation sets on it, so
  // "deleted upstream" judgments never leak across a reconnect.
  property int connectionEpoch: 0

  onActiveChanged: _live = active
  Component.onCompleted: _live = active

  // Authenticate with a token read from `tokenPath` — a file staged outside the
  // world-readable panel config (e.g. /run/spaces-secrets, root:users 0640) —
  // when set, else the inline `token`. blockLoading makes text() return the
  // content synchronously, so the value is ready when `hello` is sent on open.
  property FileView _tokenFile: FileView {
    path: executor.tokenPath
    blockLoading: true
    printErrors: false
  }
  function _helloToken() {
    return executor.tokenPath !== "" ? (_tokenFile.text() || "").trim() : executor.token;
  }

  property WebSocket _sock: WebSocket {
    url: executor.url
    active: executor._live
    onStatusChanged: status => {
      if (status === WebSocket.Open) {
        sendTextMessage(JSON.stringify({
          v: 1,
          kind: "hello",
          token: executor._helloToken(),
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
      executorId = (msg.caps && msg.caps.executor) || "";
      // New connection epoch: the registry's observation sets restart so
      // judgments about "deleted upstream" are only ever made against ids
      // this very connection observed.
      connectionEpoch += 1;
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
      // Bootstrap the per-executor session-list view. The daemon answers
      // once with a `kind:"sessions"` envelope; the same envelope is then
      // fanned out unsolicited on every list-shaping change (create / gc /
      // cold→live), so this single request seeds + subscribes in one step.
      _sock.sendTextMessage(JSON.stringify({ v: 1, kind: "list_sessions" }));
      break;
    }
    case "attached": {
      const sid = msg.sessionId;
      // Re-attach ack for a kept session: if the daemon's seq is below our high
      // water mark the session was resurrected (seq reset) — drop the stale
      // mark so replayed/new events aren't suppressed.
      if ((sid in _subscribers) && (msg.seq < (_lastSeq[sid] ?? 0))) _lastSeq[sid] = msg.seq;
      // create_session ack: `created` acks carry the requestId echo of the
      // create they answer. Plain attach acks carry neither, so a re-attach
      // ack racing an in-flight create can never be mistaken for it.
      if (msg.created && msg.requestId && _inflightCreates[msg.requestId]) {
        const p = _inflightCreates[msg.requestId];
        delete _inflightCreates[msg.requestId];
        p.onAttached(sid);
      }
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
    case "sessions": {
      // Both the response to `list_sessions` and the unsolicited pushes
      // arrive as the same shape; the merge is idempotent.
      const list = msg.sessions || [];
      const next = new Array(list.length);
      for (let i = 0; i < list.length; i += 1) {
        const s = list[i];
        next[i] = {
          id: s.id,
          name: s.name || "",
          // Daemons stamp every entry with their own executorId; fall back to
          // ours so the panel can still route attaches when an older daemon
          // omits the field.
          executorId: s.executor || executor.executorId,
          state: s.state || "cold",
          updated: s.updated || 0,
        };
      }
      remoteSessions = next;
      break;
    }
    case "error":
      Logger.w("PiExecutor", "server error", JSON.stringify(msg));
      // A requestId echo names the create_session it failed.
      if (msg.requestId && _inflightCreates[msg.requestId]) {
        const p = _inflightCreates[msg.requestId];
        delete _inflightCreates[msg.requestId];
        p.onError(msg.error || "create_session failed");
        break;
      }
      // Session-scoped failures (the daemon echoes the offending
      // sessionId) are routed to the owning session so it can recover —
      // e.g. drop a stale persisted daemon id and mint a fresh session.
      if (msg.sessionId) _subscribers[msg.sessionId]?._onSessionError?.(msg.error);
      break;
    default:
      break;
    }
  }

  function _onClosed(reason) {
    _welcomed = false;
    const creates = _inflightCreates;
    _inflightCreates = ({});
    for (const rid in creates) creates[rid].onError("executor disconnected");
    // Keep _subscribers so they re-attach (with lastSeq) on the next welcome.
    for (const sid in _subscribers) _subscribers[sid]?._onExecutorClosed?.();
    // Stale remote-list view goes away when the link drops; a fresh
    // list_sessions on next welcome reseeds it.
    remoteSessions = [];
    if (reason) Logger.w("PiExecutor", "closed", reason);
  }

  // Run cb once the connection is welcomed (immediately if already).
  function whenConnected(cb) {
    if (connected) { cb(); return; }
    _connectWaiters.push(cb);
  }

  // Create a session, correlated by a client-minted requestId echoed on the
  // ack. onAttached(sessionId) / onError(reason) are plain callbacks — NOT
  // promise continuations — invoked synchronously from the ack dispatch, so
  // the caller's claim on the fresh id lands before the daemon's follow-up
  // `sessions` broadcast is processed. Returns the requestId.
  function createSession(opts, onAttached, onError) {
    _createSerial += 1;
    const requestId = "qs-create-" + _createSerial;
    if (!connected) { onError("executor not connected"); return requestId; }
    _inflightCreates[requestId] = { onAttached: onAttached, onError: onError };
    _sock.sendTextMessage(JSON.stringify(Object.assign(
      { v: 1, kind: "create_session", requestId: requestId }, opts || {})));
    return requestId;
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

  // End a session for good on this executor. The daemon disposes the
  // live AgentSession, removes the on-disk session.jsonl + meta sidecar
  // + workspace, then broadcasts the updated `sessions` list so siblings
  // drop their tab. We don't wait for the `deleted` ack here — the
  // broadcast pass through _onMessage's `sessions` case handles the
  // local refresh symmetrically.
  function deleteSession(sid) {
    if (_sock.status === WebSocket.Open)
      _sock.sendTextMessage(JSON.stringify({
        v: 1, kind: "delete_session", sessionId: sid,
      }));
  }

  function command(sid, payload) {
    if (_sock.status === WebSocket.Open)
      _sock.sendTextMessage(JSON.stringify({ v: 1, kind: "command", sessionId: sid, payload: payload }));
  }

  function subscribe(sid, obj) { _subscribers[sid] = obj; }
  function unsubscribe(sid) { delete _subscribers[sid]; }
}

// Test shell for NdjsonSocket.
//
// Mounts one subscribe-mode and one request-mode instance pointed at
// unix socket addresses provided via env, and exposes everything the
// driver needs over IPC: delivered messages, rejected lines, drop
// count, live connection state, send() and request() triggers.
import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property var received: []
  property var badLines: []
  property int drops: 0
  property var replies: []

  NdjsonSocket {
    id: sub
    path: Quickshell.env("TEST_SUB_SOCK")
    mode: "subscribe"
    hello: ({ op: "subscribe" })
    onMessage: msg => root.received = root.received.concat([msg])
    onBadLine: raw => root.badLines = root.badLines.concat([raw])
    onDropped: root.drops += 1
  }

  NdjsonSocket {
    id: req
    path: Quickshell.env("TEST_REQ_SOCK")
    mode: "request"
    requestTimeoutMs: 1500
  }

  IpcHandler {
    target: "test:ndjson"

    function received(): string { return JSON.stringify(root.received); }
    function badLines(): string { return JSON.stringify(root.badLines); }
    function drops(): string { return JSON.stringify(root.drops); }
    function connected(): string { return JSON.stringify(sub.connected); }
    function sendSub(payload: string) { sub.send(JSON.parse(payload)); }
    function request(payload: string) {
      req.request(JSON.parse(payload), (msg, raw) => {
        root.replies = root.replies.concat([{ msg: msg, raw: raw }]);
      });
    }
    function replies(): string { return JSON.stringify(root.replies); }
  }
}

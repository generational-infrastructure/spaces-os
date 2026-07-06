// Listens on a unix socket for `{"url":"…"}` JSON lines and forwards
// the URL to the real user session.
//
// pi-chat runs each agent inside a systemd-run sandbox (ProtectHome=
// tmpfs + private namespaces), so anything the agent spawns can't
// reach the user's Firefox profile / DBus session. Skills that need
// to open a browser tab (google-cli auth, OAuth flows, …) connect to
// the socket this component owns and write a single JSON line;
// NdjsonSocket handles the server + line framing, we validate the URL
// and call `openUrlSink(url)` here, in the user session where Qt has
// a working desktop portal.
//
// The unit-test harness overrides `openUrlSink` to capture URLs
// without launching a real browser. Production wiring leaves the
// default `Qt.openUrlExternally`.
pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons

Item {
  id: root

  // Full socket path the listener binds. Caller picks the location
  // (typically `$XDG_RUNTIME_DIR/spaces-pi-open-url.sock`).
  required property string sockPath

  // Receives every validated http(s) URL. Override in tests.
  property var openUrlSink: Qt.openUrlExternally

  NdjsonSocket {
    path: root.sockPath
    mode: "listen"
    onMessage: payload => root._dispatch(payload)
    onBadLine: raw => Logger.w("OpenUrlListener", "bad json:", raw)
  }

  function _dispatch(payload) {
    const url = String(payload?.url ?? "");
    // Refuse anything other than http(s) so a compromised skill can't
    // talk us into launching file:// or arbitrary URI handlers in the
    // user's session.
    if (!/^https?:\/\//i.test(url)) {
      Logger.w("OpenUrlListener", "rejecting non-http scheme:", url);
      return;
    }
    Logger.i("OpenUrlListener", "open-url:", url);
    root.openUrlSink(url);
  }
}

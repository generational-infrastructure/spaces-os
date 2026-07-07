// Panel-side client for the per-user integrations broker
// (spaces-integrationd) on $XDG_RUNTIME_DIR/spaces-integrations.sock.
//
// The broker speaks one JSON request per connection, one JSON reply, then
// closes (see packages/spaces-integrationd/protocol.go). So unlike a
// long-lived subscriber connection, every op here is an NdjsonSocket
// one-shot request: fresh connection, one request line, single reply,
// teardown. `list` refreshes `integrations`; `set-secret`/`enable`/`disable`
// mutate then trigger a re-list so the form reflects the new state.
//
// This lives at the panel layer on purpose: the broker authenticates the
// caller by SO_PEERCRED (same-uid only) and its socket dir is 0700, so only
// the user's own session — never the sandboxed agent — can reach it.
pragma ComponentBehavior: Bound
import QtQuick

QtObject {
  id: root

  // Set by the parent (the broker socket address). Empty ⇒ inert.
  property string sockPath: ""

  // Mirror of the broker's `list` reply. Each entry:
  //   { name, description, enabled, setup, multiProfile, config, secrets, profiles }
  // `setup` (bool) is surfaced verbatim: the panel gates the Link/Setup
  // button on it.
  property var integrations: []

  // True once a `list` has succeeded — lets the UI tell "still connecting"
  // apart from "genuinely no integrations configured".
  property bool loaded: false

  // Last human-readable failure, or "" when the last op succeeded.
  property string lastError: ""

  // Emitted after `integrations` is refreshed from a successful `list`.
  signal listed
  // Emitted after a set-secret/enable/disable terminal reply.
  signal acked(string op, string integration, bool ok, string error)

  // ── setup flow ────────────────────────────────────────────────────
  // op:"setup" opens a DEDICATED long-lived broker connection that
  // streams NDJSON events (qr | message | done | error) until the
  // broker closes it. Only one flow runs at a time.

  // One parsed setup event line relayed from the broker.
  signal setupEvent(var ev)
  // The setup connection closed (done, error, cancel, or peer EOF).
  signal setupClosed()

  // True while a setup flow is live — enforces the one-at-a-time rule
  // and lets the UI show/hide its inline setup area.
  property bool setupActive: false
  property var _setupSock: null

  function refresh() { _request({ op: "list" }); }
  function setField(integration, profile, field, value) {
    _request({ op: "set-field", integration: integration, profile: profile, field: field, value: value });
  }
  function removeProfile(integration, profile) {
    _request({ op: "remove-profile", integration: integration, profile: profile });
  }
  function enable(integration) { _request({ op: "enable", integration: integration }); }
  function disable(integration) { _request({ op: "disable", integration: integration }); }

  // Open the sandboxed setup channel for `integration`. The broker
  // validates it is enabled + setup-capable, starts the twin setup
  // unit, and relays its NDJSON events until done/error. Returns false
  // when inert, already running, or the socket could not be opened.
  function startSetup(integration) {
    if (root.sockPath === "") { root.lastError = "no integrations socket"; return false; }
    if (root.setupActive) return false;
    const s = _sock.stream({ op: "setup", integration: integration },
                           (ev, raw) => root._onSetupLine(ev, raw),
                           () => root._onSetupClosed());
    if (!s) { root.lastError = "could not open integrations socket"; return false; }
    root._setupSock = s;
    root.setupActive = true;
    return true;
  }

  // Abort the live setup flow; closing our end makes the broker kill
  // the setup helper. _onSetupClosed() clears the state on teardown.
  function cancelSetup() {
    if (root._setupSock) root._setupSock.closeStream();
  }

  property NdjsonSocket _sock: NdjsonSocket {
    path: root.sockPath
    mode: "request"
  }

  function _request(req) {
    if (root.sockPath === "") { root.lastError = "no integrations socket"; return; }
    if (!_sock.request(req, (ev, raw) => root._onReply(req, ev, raw))) {
      root.lastError = "could not open integrations socket";
    }
  }

  function _onReply(req, ev, raw) {
    if (raw === "") {
      root.lastError = (req.op || "request") + ": no reply from broker";
      if (req.op !== "list") root.acked(req.op, req.integration || "", false, root.lastError);
      return;
    }
    if (!ev) { root.lastError = "malformed broker reply"; return; }
    if (req.op === "list") {
      if (ev.op === "ok" && Array.isArray(ev.integrations)) {
        root.integrations = ev.integrations;
        root.loaded = true;
        root.lastError = "";
        root.listed();
      } else {
        root.lastError = ev.error || "list failed";
      }
      return;
    }
    const ok = ev.op === "ok";
    root.lastError = ok ? "" : (ev.error || (req.op + " failed"));
    root.acked(req.op, req.integration || "", ok, root.lastError);
    // A successful mutation changed broker state — re-list so the form,
    // enable badges, and secret "set" markers reflect it.
    if (ok) root.refresh();
  }

  function _onSetupLine(ev, _raw) {
    if (!ev || !ev.event) return;
    root.setupEvent(ev);
    // A completed link changed broker/service state — re-list so the
    // form (enable badges, setup gating) reflects the freshly linked
    // integration.
    if (ev.event === "done") root.refresh();
  }

  function _onSetupClosed() {
    root._setupSock = null;
    root.setupActive = false;
    root.setupClosed();
  }
}

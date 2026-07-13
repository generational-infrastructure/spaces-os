"""Signal device-linking setup helper (spaces integration setup channel).

Spawned by systemd socket activation on the twin setup socket
(spaces-integration-signal-setup.socket), in the SAME sandbox as the MCP
server (only ExecStart differs). The broker connects to that socket; this
helper accepts the connection and streams newline-delimited JSON events back
over it, which the broker relays verbatim to the panel.

Event vocabulary is the minimal subset of docs/agent-integrations-design.md
§5.5 — qr / message / done / error. (The typed text-prompt, secret-field,
open-url, confirm and progress requests from that section are to be completed
later.)

Flow: accept the activated socket connection; connect to the signal-cli daemon
JSON-RPC socket at $SPACES_SIGNAL_DAEMON_SOCKET (retrying while the daemon
warms up in parallel via the socket unit's Wants=); JSON-RPC `startLink` ->
`{deviceLinkUri}`; render + emit a `qr` event (PNG via the qrcode library's
PIL backend); JSON-RPC `finishLink {deviceLinkUri, deviceName: "spaces-<host>"}`
(blocks until the phone scans, with a generous timeout); then exactly one
terminal `done` / `error` line.

Every outcome path ends with exactly one terminal done/error line and the
process exits 0 — a link failure is a protocol event, not a crash.
"""

import base64
import io
import json
import os
import socket
import sys
import time

import qrcode

# The daemon socket env name and connect timeout are owned by the server module;
# import them so setup and server can't drift.
from integration_signal import _DAEMON_CONNECT_TIMEOUT, DAEMON_SOCKET_ENV

# The MCP server's socket-activation accept mechanism is reused verbatim so the
# setup helper binds/inherits its listening socket exactly like the server.
from spaces_integration_mcp import _listen
from spaces_signal.jsonrpc import JsonRpcClient, JsonRpcError

SERVER_NAME = "integration-signal-setup"


# The daemon is brought up in parallel (socket Wants=) and may still be warming
# up when we connect, so retry with a short backoff up to the deadline.
_DAEMON_CONNECT_DEADLINE = 15.0
_DAEMON_RETRY_INTERVAL = 0.5

# startLink is a local daemon round-trip; finishLink blocks on the human
# scanning the QR with their phone, so it gets a much more generous window.
_START_LINK_TIMEOUT = 30.0
_FINISH_LINK_TIMEOUT = 180.0


def _emit(conn, event):
    """Write one NDJSON event line to the broker connection."""
    conn.sendall(json.dumps(event).encode("utf-8") + b"\n")


def _device_name():
    return "spaces-" + socket.gethostname()


def _render_qr_png(uri):
    """PNG bytes of a QR encoding `uri` (qrcode's default PIL backend)."""
    img = qrcode.make(uri)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def _connect_daemon(path):
    """Connect to the signal-cli daemon JSON-RPC socket, retrying while it warms
    up. Raises the last OSError once the connect deadline elapses.
    """
    deadline = time.monotonic() + _DAEMON_CONNECT_DEADLINE
    while True:
        try:
            return JsonRpcClient(path, connect_timeout=_DAEMON_CONNECT_TIMEOUT)
        except OSError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(_DAEMON_RETRY_INTERVAL)


def link(conn):
    """Run the device-link flow, streaming NDJSON events to `conn`. Returns after
    emitting exactly one terminal done/error event.
    """
    path = os.environ.get(DAEMON_SOCKET_ENV)
    if not path:
        _emit(
            conn,
            {
                "event": "error",
                "error": f"signal daemon socket not configured (${DAEMON_SOCKET_ENV})",
            },
        )
        return

    _emit(conn, {"event": "message", "text": "connecting to the signal daemon"})
    try:
        client = _connect_daemon(path)
    except OSError as exc:
        _emit(
            conn,
            {
                "event": "error",
                "error": f"signal daemon is not reachable: {exc}",
            },
        )
        return

    try:
        try:
            result = client.call("startLink", timeout=_START_LINK_TIMEOUT)
        except (JsonRpcError, TimeoutError, OSError) as exc:
            _emit(
                conn,
                {"event": "error", "error": f"could not start device link: {exc}"},
            )
            return

        uri = result.get("deviceLinkUri") if isinstance(result, dict) else None
        if not uri:
            _emit(
                conn,
                {
                    "event": "error",
                    "error": "signal daemon returned no device-link URI",
                },
            )
            return

        try:
            png = _render_qr_png(uri)
        except Exception as exc:  # noqa: BLE001 — surface as a protocol error
            _emit(
                conn,
                {"event": "error", "error": f"could not render the QR code: {exc}"},
            )
            return

        _emit(
            conn,
            {
                "event": "qr",
                "uri": uri,
                "png": base64.b64encode(png).decode("ascii"),
            },
        )
        _emit(
            conn,
            {
                "event": "message",
                "text": "scan the QR with Signal on your phone "
                "(Settings -> Linked devices -> Link new device), "
                "then keep this open",
            },
        )

        try:
            client.call(
                "finishLink",
                {"deviceLinkUri": uri, "deviceName": _device_name()},
                timeout=_FINISH_LINK_TIMEOUT,
            )
        except TimeoutError:
            _emit(
                conn,
                {
                    "event": "error",
                    "error": "timed out waiting for the phone to scan the QR "
                    "code; open the setup again to retry",
                },
            )
            return
        except (JsonRpcError, OSError) as exc:
            _emit(
                conn,
                {"event": "error", "error": f"device link did not complete: {exc}"},
            )
            return

        _emit(conn, {"event": "done"})
    finally:
        client.close()


def main():
    sock = _listen(SERVER_NAME)
    if sock is None:
        return 2
    try:
        conn, _ = sock.accept()
    except OSError as exc:
        print(f"{SERVER_NAME}: accept failed: {exc}", file=sys.stderr)
        return 2
    with conn:
        try:
            link(conn)
        except OSError:
            # Broker hung up mid-stream; nothing left to say to it.
            pass
        except Exception as exc:  # noqa: BLE001 — never crash on an unlinked flow
            try:
                _emit(
                    conn,
                    {
                        "event": "error",
                        "error": f"unexpected setup failure: "
                        f"{exc.__class__.__name__}: {exc}",
                    },
                )
            except OSError:
                pass
    return 0


if __name__ == "__main__":
    sys.exit(main())

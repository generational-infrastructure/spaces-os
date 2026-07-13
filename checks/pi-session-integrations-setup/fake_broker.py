#!/usr/bin/env python3
"""Fake spaces-integrationd for the setup-channel panel check.

Extends the request/reply broker fake (checks/pi-session-integrations-bridge)
with the streaming `setup` op. UNLIKE every other op, a `setup` request keeps
the connection OPEN and streams NDJSON event lines (qr | message | done |
error) until the broker closes it — mirroring packages/spaces-integrationd's
setup relay of the sandboxed helper's events.

The `list` reply carries the definition's `setup: bool` so the panel can gate
its Link/Setup button on it. A tiny stats sidecar (<sock>.stats) records how
many `list` requests have arrived, so the driver can prove the re-list the
bridge fires after a `done` event.

Scripted integrations:
  - github : enabled, NOT setup-capable  -> button hidden
  - signal : enabled + setup-capable     -> button shown; streams qr/message/done
  - mail   : setup-capable but DISABLED   -> button hidden
  - caldav : enabled + setup-capable     -> button shown; streams error
  - matrix : enabled + setup-capable     -> streams a text-field prompt, then
             DROPS the connection (no done/error) — the dead-stream case

Usage: fake_broker.py <sock_path>
"""

from __future__ import annotations

import json
import os
import socket
import sys
import threading
import time

# A valid 1x1 PNG (base64). The panel renders it via a data: URL; the driver
# only asserts this payload flows through into the QR Image's source.
KNOWN_PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4//8/AAX+Av4N70a4AAAAAElFTkSuQmCC"

STATE = {
    "github": {"description": "GitHub", "enabled": True, "setup": False},
    "signal": {"description": "Signal", "enabled": True, "setup": True},
    "mail": {"description": "Email (IMAP/SMTP)", "enabled": False, "setup": True},
    "caldav": {"description": "Calendar (CalDAV)", "enabled": True, "setup": True},
    "matrix": {"description": "Matrix", "enabled": True, "setup": True},
    "proton": {
        "description": "Proton Mail",
        "enabled": True,
        "setup": True,
        # Field-bearing: the panel renders manual field rows from these, and
        # must HIDE them while the proton setup pane is open (setup owns
        # provisioning; the rows return when the pane closes).
        "config": [{"name": "email", "description": "Proton account email address"}],
        "secrets": [
            {
                "name": "bridge_password",
                "description": "Proton Bridge per-account password",
            }
        ],
    },
}
LOCK = threading.Lock()
STATS_PATH = None
STATS = {"list": 0, "setup": 0, "replies": []}


def _flush_stats() -> None:
    """Atomically write the stats sidecar (call under LOCK)."""
    if STATS_PATH:
        tmp = STATS_PATH + ".tmp"
        with open(tmp, "w") as f:
            json.dump(STATS, f)
        os.replace(tmp, STATS_PATH)


def _bump(op: str) -> None:
    """Record an op in the stats sidecar (call under LOCK)."""
    STATS[op] = STATS.get(op, 0) + 1
    _flush_stats()


def _record_reply(line: str) -> None:
    """Record a panel reply line's value in the stats sidecar (call under LOCK)."""
    try:
        val = json.loads(line).get("value")
    except (ValueError, AttributeError):
        val = None
    STATS["replies"].append(val)
    _flush_stats()


def list_reply() -> dict:
    integrations = []
    for name, info in STATE.items():
        integrations.append(
            {
                "name": name,
                "description": info["description"],
                "enabled": info["enabled"],
                # Definition JSON gains `setup: bool`; the panel gates its
                # Link/Setup button on it.
                "setup": info["setup"],
                "multiProfile": False,
                "config": info.get("config", []),
                "secrets": info.get("secrets", []),
                "profiles": [],
            }
        )
    return {"op": "ok", "integrations": integrations}


def send_line(conn: socket.socket, obj: dict) -> None:
    conn.sendall((json.dumps(obj) + "\n").encode())


def recv_line(conn: socket.socket) -> str:
    """Read one NDJSON line (the panel's reply) off the connection; '' on EOF."""
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = conn.recv(4096)
        if not chunk:
            return buf.decode()
        buf += chunk
    return buf.decode().strip()


def stream_setup(conn: socket.socket, name: str) -> None:
    """Stream the scripted NDJSON event sequence for `name`, then return
    (the caller closes the connection — the panel treats EOF as flow end).
    """
    info = STATE.get(name)
    # Setup-capability is the only gate — setup on a DISABLED integration is
    # the provisioning path (mirrors the real broker's prepareSetup).
    if info is None or not info.get("setup"):
        send_line(conn, {"event": "error", "error": f"{name!r} is not setup-capable"})
        return
    # Pause between events so the panel (and the driver) can observe each
    # intermediate state — a real link waits on a phone scan between the
    # QR and the done/error outcome.
    if name == "signal":
        send_line(
            conn,
            {
                "event": "qr",
                "uri": "sgnl://linkdevice?uuid=test-device",
                "png": KNOWN_PNG,
            },
        )
        time.sleep(0.6)
        send_line(conn, {"event": "message", "text": "Waiting for the phone to scan…"})
        time.sleep(0.6)
        send_line(conn, {"event": "done"})
    elif name == "proton":
        # Prompt flow: text-field email -> reply -> secret-field password ->
        # reply -> done. Each reply is recorded so the driver can assert it
        # reached the broker verbatim (and secret-field masking on the panel).
        # The pre-prompt pause keeps the "connecting" phase observable: the
        # driver asserts the pane shows feedback text before any event lands
        # (a real helper takes seconds to spawn its transient Bridge).
        time.sleep(0.8)
        send_line(
            conn,
            {"event": "text-field", "field": "email", "label": "Proton account email"},
        )
        with LOCK:
            _record_reply(recv_line(conn))
        time.sleep(0.2)
        send_line(
            conn,
            {
                "event": "secret-field",
                "field": "password",
                "label": "Proton account password",
            },
        )
        with LOCK:
            _record_reply(recv_line(conn))
        time.sleep(0.2)
        send_line(conn, {"event": "done"})
    elif name == "matrix":
        # Prompt then DROP: stream a text-field and return WITHOUT a terminal
        # event — serve() closes the connection (helper crash / broker
        # restart mid-prompt). The panel must notice the dead stream and
        # refuse the next submit (keep the typed reply, no phase flip).
        time.sleep(0.2)
        send_line(
            conn,
            {"event": "text-field", "field": "token", "label": "Matrix access token"},
        )
        # Let the prompt line land before the drop so the panel renders the
        # prompt phase from a still-live stream.
        time.sleep(0.3)
    else:
        send_line(conn, {"event": "message", "text": "Starting link…"})
        time.sleep(0.4)
        send_line(conn, {"event": "error", "error": "device link failed"})


def handle(req: dict) -> dict:
    op = req.get("op")
    if op == "list":
        return list_reply()
    name = req.get("integration")
    info = STATE.get(name)
    if info is None:
        return {"op": "error", "error": f"unknown integration {name!r}"}
    if op == "enable":
        info["enabled"] = True
        return {"op": "ok"}
    if op == "disable":
        info["enabled"] = False
        return {"op": "ok"}
    return {"op": "error", "error": f"unknown op {op!r}"}


def serve(conn: socket.socket) -> None:
    try:
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(4096)
            if not chunk:
                return
            buf += chunk
        req = json.loads(buf.decode())
        if req.get("op") == "setup":
            with LOCK:
                _bump("setup")
            # Stream WITHOUT holding the lock: setup is long-running and must
            # not block list/enable (mirrors the real broker's mutex rule).
            stream_setup(conn, req.get("integration"))
            return
        with LOCK:
            if req.get("op") == "list":
                _bump("list")
            reply = handle(req)
        send_line(conn, reply)
    except Exception as e:
        try:
            send_line(conn, {"op": "error", "error": str(e)})
        except OSError:
            pass
    finally:
        conn.close()


def main() -> None:
    global STATS_PATH
    if len(sys.argv) != 2:
        sys.exit("usage: fake_broker.py <sock_path>")
    sock_path = sys.argv[1]
    STATS_PATH = sock_path + ".stats"
    try:
        os.unlink(sock_path)
    except FileNotFoundError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock_path)
    os.chmod(sock_path, 0o600)
    srv.listen(8)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=serve, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()

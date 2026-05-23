#!/usr/bin/env python3
"""Minimal fake of distro-signal-bridge's panel-socket protocol.

The real bridge is exercised by packages/signal-cli/test_bridge.py.
This fake only needs to drive SignalConfirm.qml's subscribe/approve
state machine — speaking the same NDJSON shape, but skipping
SQLite / signal-cli entirely.

Driven over stdin by the test driver:

    push_snapshot <json>
    push_added <token-json>
    push_removed <token>
    expect_approve <token>           # wait until subscriber sent approve
    expect_deny <token>
"""

from __future__ import annotations

import json
import os
import socket
import sys
import threading
import time


def main() -> None:
    if len(sys.argv) != 2:
        sys.stderr.write("usage: fake_bridge.py <sock_path>\n")
        sys.exit(2)
    sock_path = sys.argv[1]
    try:
        os.unlink(sock_path)
    except FileNotFoundError:
        pass

    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock_path)
    srv.listen(8)
    srv.settimeout(0.5)

    state_lock = threading.Lock()
    subscribers: list[socket.socket] = []
    seen_ops: list[dict] = []  # every NDJSON op the subscriber sent

    def broadcast(payload: dict) -> None:
        line = (json.dumps(payload) + "\n").encode("utf-8")
        with state_lock:
            stale = []
            for conn in subscribers:
                try:
                    conn.sendall(line)
                except OSError:
                    stale.append(conn)
            for c in stale:
                subscribers.remove(c)

    def handle_conn(conn: socket.socket) -> None:
        try:
            f = conn.makefile("r", encoding="utf-8", newline="\n")
            while True:
                line = f.readline()
                if not line:
                    return
                try:
                    req = json.loads(line)
                except json.JSONDecodeError:
                    continue
                with state_lock:
                    seen_ops.append(req)
                op = req.get("op")
                if op == "subscribe":
                    with state_lock:
                        if conn not in subscribers:
                            subscribers.append(conn)
                    snapshot = (
                        json.dumps({"op": "snapshot", "ok": True, "pending": []}) + "\n"
                    )
                    conn.sendall(snapshot.encode("utf-8"))
                elif op in ("approve", "deny"):
                    state = "sent" if op == "approve" else "denied"
                    resp = (
                        json.dumps({"op": "decision", "ok": True, "state": state})
                        + "\n"
                    )
                    conn.sendall(resp.encode("utf-8"))
                    # Mirror the real bridge: every decision drops the
                    # row on every subscriber.
                    broadcast(
                        {"op": "removed", "token": req.get("token"), "state": state}
                    )
        finally:
            with state_lock:
                if conn in subscribers:
                    subscribers.remove(conn)
            conn.close()

    def accept_loop() -> None:
        while True:
            try:
                conn, _ = srv.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            threading.Thread(target=handle_conn, args=(conn,), daemon=True).start()

    threading.Thread(target=accept_loop, daemon=True).start()

    # Hand off to a stdin command loop. The driver pushes events and
    # waits on assertions through this protocol.
    sys.stdout.write("READY\n")
    sys.stdout.flush()
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        cmd, _, rest = line.partition(" ")
        if cmd == "push_snapshot":
            broadcast({"op": "snapshot", "ok": True, "pending": json.loads(rest)})
            sys.stdout.write("OK\n")
            sys.stdout.flush()
        elif cmd == "push_added":
            broadcast({"op": "added", "request": json.loads(rest)})
            sys.stdout.write("OK\n")
            sys.stdout.flush()
        elif cmd == "push_removed":
            broadcast({"op": "removed", "token": rest})
            sys.stdout.write("OK\n")
            sys.stdout.flush()
        elif cmd == "expect_op":
            token, *_ = rest.split(" ", 1)
            deadline = time.monotonic() + 5.0
            found = False
            while time.monotonic() < deadline:
                with state_lock:
                    found = any(o.get("token") == token for o in seen_ops)
                if found:
                    break
                time.sleep(0.02)
            sys.stdout.write("OK\n" if found else "MISS\n")
            sys.stdout.flush()
        elif cmd == "expect_approve":
            deadline = time.monotonic() + 5.0
            found = False
            while time.monotonic() < deadline:
                with state_lock:
                    found = any(
                        o.get("op") == "approve" and o.get("token") == rest
                        for o in seen_ops
                    )
                if found:
                    break
                time.sleep(0.02)
            sys.stdout.write("OK\n" if found else "MISS\n")
            sys.stdout.flush()
        elif cmd == "expect_deny":
            deadline = time.monotonic() + 5.0
            found = False
            while time.monotonic() < deadline:
                with state_lock:
                    found = any(
                        o.get("op") == "deny" and o.get("token") == rest
                        for o in seen_ops
                    )
                if found:
                    break
                time.sleep(0.02)
            sys.stdout.write("OK\n" if found else "MISS\n")
            sys.stdout.flush()
        elif cmd == "quit":
            return
        else:
            sys.stdout.write(f"UNKNOWN {cmd}\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()

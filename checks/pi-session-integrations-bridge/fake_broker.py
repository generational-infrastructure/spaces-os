#!/usr/bin/env python3
"""Minimal fake of spaces-integrationd's socket protocol.

Request/reply-per-connection over a unix socket, mirroring
packages/spaces-integrationd/protocol.go: one JSON request line in, one JSON
reply line out, then close. In-memory state (enabled flag + which secrets have
ciphertext) so set-secret/enable/disable are observable in the next `list`.
`enable` refuses until every declared secret is set — the broker's real guard,
which the panel must surface.

Usage: fake_broker.py <sock_path>
"""

from __future__ import annotations

import json
import os
import socket
import sys
import threading

STATE = {
    "github": {
        "description": "GitHub MCP integration",
        "enabled": False,
        "secrets": {
            "token": {"description": "GitHub personal access token", "set": False}
        },
    },
}
LOCK = threading.Lock()


def list_reply() -> dict:
    integrations = []
    for name, info in STATE.items():
        integrations.append(
            {
                "name": name,
                "description": info["description"],
                "enabled": info["enabled"],
                "secrets": [
                    {"name": sn, "description": sv["description"], "set": sv["set"]}
                    for sn, sv in info["secrets"].items()
                ],
            }
        )
    return {"op": "ok", "integrations": integrations}


def handle(req: dict) -> dict:
    op = req.get("op")
    if op == "list":
        return list_reply()
    name = req.get("integration")
    info = STATE.get(name)
    if info is None:
        return {"op": "error", "error": f"unknown integration {name!r}"}
    if op == "set-secret":
        sn = req.get("name")
        if sn not in info["secrets"]:
            return {"op": "error", "error": f"unknown secret {sn!r}"}
        if not (req.get("value") or ""):
            return {"op": "error", "error": "empty secret value"}
        info["secrets"][sn]["set"] = True
        return {"op": "ok"}
    if op == "enable":
        missing = [sn for sn, sv in info["secrets"].items() if not sv["set"]]
        if missing:
            return {"op": "error", "error": "missing secrets: " + ",".join(missing)}
        info["enabled"] = True
        return {"op": "ok"}
    if op == "disable":
        info["enabled"] = False
        return {"op": "ok"}
    return {"op": "error", "error": f"unknown op {op!r}"}


def serve(conn: socket.socket) -> None:
    try:
        buf = b""
        while b"\n" not in buf:
            chunk = conn.recv(4096)
            if not chunk:
                return
            buf += chunk
        line = buf.split(b"\n", 1)[0]
        try:
            req = json.loads(line)
        except ValueError:
            reply = {"op": "error", "error": "malformed request"}
        else:
            with LOCK:
                reply = handle(req)
        conn.sendall((json.dumps(reply) + "\n").encode("utf-8"))
    finally:
        conn.close()


def main() -> None:
    if len(sys.argv) != 2:
        sys.stderr.write("usage: fake_broker.py <sock_path>\n")
        sys.exit(2)
    sock_path = sys.argv[1]
    try:
        os.unlink(sock_path)
    except FileNotFoundError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock_path)
    srv.listen(8)
    sys.stdout.write("READY\n")
    sys.stdout.flush()
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=serve, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()

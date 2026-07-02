#!/usr/bin/env python3
"""Minimal fake of spaces-integrationd's socket protocol (unified profile store).

Request/reply-per-connection over a unix socket, mirroring
packages/spaces-integrationd/protocol.go: one JSON request line in, one JSON
reply line out, then close. In-memory, profile-keyed state so
set-field/remove-profile/enable/disable are observable in the next `list`.
`enable` refuses until at least one profile has every required field — the
broker's real guard, which the panel must surface.

Usage: fake_broker.py <sock_path>
"""

from __future__ import annotations

import json
import os
import socket
import sys
import threading

# One multi-account integration exercising both config and secret fields.
STATE = {
    "mail": {
        "description": "Email (IMAP/SMTP)",
        "multiProfile": True,
        "enabled": False,
        "config": {"imap_host": {"description": "IMAP host", "required": True}},
        "secrets": {"password": {"description": "Password", "required": True}},
        # profile -> {"config": {field: value}, "secrets": {field: bool}}
        "profiles": {},
    },
}
LOCK = threading.Lock()


def _profile_complete(info: dict, prof: str) -> bool:
    p = info["profiles"].get(prof, {})
    for f, s in info["config"].items():
        if s["required"] and not p.get("config", {}).get(f):
            return False
    for f, s in info["secrets"].items():
        if s["required"] and not p.get("secrets", {}).get(f):
            return False
    return True


def list_reply() -> dict:
    integrations = []
    for name, info in STATE.items():
        profiles = []
        for pn, pv in sorted(info["profiles"].items()):
            profiles.append(
                {
                    "name": pn,
                    "config": pv.get("config", {}),
                    "secrets": {f: bool(v) for f, v in pv.get("secrets", {}).items()},
                    "complete": _profile_complete(info, pn),
                }
            )
        integrations.append(
            {
                "name": name,
                "description": info["description"],
                "multiProfile": info["multiProfile"],
                "enabled": info["enabled"],
                "config": [
                    {
                        "name": f,
                        "description": s["description"],
                        "required": s["required"],
                    }
                    for f, s in info["config"].items()
                ],
                "secrets": [
                    {
                        "name": f,
                        "description": s["description"],
                        "required": s["required"],
                    }
                    for f, s in info["secrets"].items()
                ],
                "profiles": profiles,
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
    if op == "set-field":
        prof = req.get("profile") or ""
        field = req.get("field")
        value = req.get("value") or ""
        if not prof:
            return {"op": "error", "error": "missing profile"}
        p = info["profiles"].setdefault(prof, {})
        if field in info["config"]:
            p.setdefault("config", {})[field] = value
        elif field in info["secrets"]:
            # never store the value — only the set marker (mirrors the broker)
            p.setdefault("secrets", {})[field] = True
        else:
            return {"op": "error", "error": f"unknown field {field!r}"}
        return {"op": "ok"}
    if op == "remove-profile":
        info["profiles"].pop(req.get("profile") or "", None)
        return {"op": "ok"}
    if op == "enable":
        if not any(_profile_complete(info, p) for p in info["profiles"]):
            return {"op": "error", "error": "no complete profile"}
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
        with LOCK:
            reply = handle(json.loads(buf.decode()))
        conn.sendall((json.dumps(reply) + "\n").encode())
    except Exception as e:  # noqa: BLE001
        try:
            conn.sendall((json.dumps({"op": "error", "error": str(e)}) + "\n").encode())
        except OSError:
            pass
    finally:
        conn.close()


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: fake_broker.py <sock_path>")
    sock_path = sys.argv[1]
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

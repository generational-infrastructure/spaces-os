#!/usr/bin/env python3
"""Fake spaces-integrationd for the Nix-managed integration-profiles check.

Serves the `list` reply the panel renders when some integration accounts are
provisioned declaratively by NixOS (design doc §10). Unlike the plain bridge
fake, the reply carries the managed-profile contract fields (§10.5):

  - ProfileInfo.managed  (bool) — the profile is Nix-managed, read-only in the
    GUI;
  - ProfileInfo.shadowed (bool) — this managed profile shadows a same-named
    user profile (a GUI subtitle hint);
  - IntegrationInfo.enabledByNix (true | false | field ABSENT) — the Nix enable
    verdict; an ABSENT key means "no Nix opinion" (user autonomy).

Scripted integrations:
  - mail   : multiProfile, NO Nix enable verdict. Profiles:
      work     — managed, NOT shadowed (config values + a set secret),
      personal — managed AND shadowed (replaces a same-named user profile),
      side     — a plain user profile (contrast: editable + removable).
  - signal : enabledByNix = true  (enable is Nix-managed).
  - caldav : enabledByNix = false (disable is Nix-managed).

The broker's managed-write rejections (§10.5) are also implemented with the
exact, stable contract messages, so the UI rejection path can be exercised:
  - set-field / remove-profile naming a managed profile →
      "profile '<p>' is managed by system configuration"
  - enable / disable on an integration carrying a Nix enable verdict →
      "integration '<i>' enable state is managed by system configuration"

Like the real broker, this speaks one JSON request per connection, one JSON
reply, then closes (mirrors packages/spaces-integrationd/protocol.go).

Usage: fake_broker.py <sock_path>
"""

from __future__ import annotations

import json
import os
import socket
import sys
import threading

# Stable rejection messages (design doc §10.5). The GUI shows these verbatim
# and the driver asserts on them, so they must not drift.
MSG_PROFILE_MANAGED = "profile '{profile}' is managed by system configuration"
MSG_ENABLE_MANAGED = (
    "integration '{integration}' enable state is managed by system configuration"
)

# Scripted broker state. An `enabledByNix` key present means a Nix enable
# verdict exists (its value, true|false, is the verdict); the key ABSENT means
# no Nix opinion. Each profile's `managed`/`shadowed` mirror ProfileInfo; a
# managed profile's `config` values and `secrets` set-status render read-only.
STATE = {
    "mail": {
        "description": "Email (IMAP/SMTP)",
        "enabled": True,
        "setup": False,
        "multiProfile": True,
        "config": [
            {"name": "address", "required": True, "description": "Email address"},
            {"name": "imap_host", "required": True, "description": "IMAP server host"},
        ],
        "secrets": [
            {"name": "password", "description": "Account password"},
        ],
        "profiles": [
            {
                "name": "work",
                "config": {
                    "address": "bob@corp.example",
                    "imap_host": "imap.corp.example",
                },
                "secrets": {"password": True},
                "managed": True,
                "shadowed": False,
            },
            {
                "name": "personal",
                "config": {
                    "address": "bob@home.example",
                    "imap_host": "imap.home.example",
                },
                "secrets": {"password": True},
                "managed": True,
                "shadowed": True,
            },
            {
                "name": "side",
                "config": {
                    "address": "bob@side.example",
                    "imap_host": "imap.side.example",
                },
                "secrets": {"password": False},
                "managed": False,
                "shadowed": False,
            },
        ],
    },
    "signal": {
        "description": "Signal",
        "enabled": True,
        "setup": True,
        "multiProfile": False,
        "enabledByNix": True,
        "config": [],
        "secrets": [],
        "profiles": [],
    },
    "caldav": {
        "description": "Calendar (CalDAV)",
        "enabled": False,
        "setup": False,
        "multiProfile": False,
        "enabledByNix": False,
        "config": [],
        "secrets": [],
        "profiles": [],
    },
}
LOCK = threading.Lock()


def _managed_profiles(name: str) -> set:
    """Names of the Nix-managed profiles of integration `name`."""
    info = STATE.get(name) or {}
    return {p["name"] for p in info.get("profiles", []) if p.get("managed")}


def list_reply() -> dict:
    integrations = []
    for name, info in STATE.items():
        entry = {
            "name": name,
            "description": info["description"],
            "enabled": info["enabled"],
            "setup": info["setup"],
            "multiProfile": info["multiProfile"],
            "config": info["config"],
            "secrets": info["secrets"],
            "profiles": info["profiles"],
        }
        # enabledByNix is emitted ONLY when a Nix verdict exists (true|false).
        # An absent key is "no Nix opinion" — the panel then shows the toggle.
        if "enabledByNix" in info:
            entry["enabledByNix"] = info["enabledByNix"]
        integrations.append(entry)
    return {"op": "ok", "integrations": integrations}


def send_line(conn: socket.socket, obj: dict) -> None:
    conn.sendall((json.dumps(obj) + "\n").encode())


def handle(req: dict) -> dict:
    op = req.get("op")
    if op == "list":
        return list_reply()
    name = req.get("integration")
    info = STATE.get(name)
    if info is None:
        return {"op": "error", "error": f"unknown integration {name!r}"}
    if op in ("enable", "disable"):
        # A Nix enable verdict makes enable/disable read-only (§10.5).
        if "enabledByNix" in info:
            return {"op": "error", "error": MSG_ENABLE_MANAGED.format(integration=name)}
        info["enabled"] = op == "enable"
        return {"op": "ok"}
    if op in ("set-field", "remove-profile"):
        profile = req.get("profile")
        # A managed profile is read-only (§10.5): reject any write naming it.
        if profile in _managed_profiles(name):
            return {"op": "error", "error": MSG_PROFILE_MANAGED.format(profile=profile)}
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
        with LOCK:
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

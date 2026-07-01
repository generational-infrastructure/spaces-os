"""Shared MCP server scaffold for spaces integrations.

NDJSON JSON-RPC 2.0 over a unix socket. The listening socket arrives either as
fd 3 (systemd socket activation, LISTEN_FDS) or is bound at
SPACES_INTEGRATION_SOCKET (tests). Connections are served sequentially.

An integration supplies its server identity, a static tool list (advertised via
tools/list), and a `call_tool(name, arguments) -> (text, is_error)` dispatcher;
this module owns the JSON-RPC protocol, NDJSON framing, and socket lifecycle so
every integration server speaks exactly one wire dialect.
"""

import json
import os
import socket
import sys
import tomllib

PROTOCOL_VERSION = "2025-03-26"


def read_credential(name):
    """Read $CREDENTIALS_DIRECTORY/<name>, stripped, or None when absent.

    The decrypted secret/config blobs land there (ro) via the unit's
    LoadCredential[Encrypted]; the agent's Landlock domain never grants this
    mount, so a value read here never crosses the wall.
    """
    creds_dir = os.environ.get("CREDENTIALS_DIRECTORY")
    if not creds_dir:
        return None
    try:
        with open(os.path.join(creds_dir, name), encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return None


def shared_dir():
    """The per-pair file-exchange dir, or None when none was provisioned."""
    return os.environ.get("SPACES_INTEGRATION_SHARED_DIR")


def store_profile(profile, kinds=("config", "secrets")):
    """Merged field values for one profile, read from the store's credential
    blobs ($CREDENTIALS_DIRECTORY/config and .../secrets). The blobs are
    skill-config TOML: a single [<skill>.<profile>] table tree per integration.
    Returns {} when a blob is absent or unparseable — a missing field surfaces
    as a tool error at the call site, never a crash."""
    out = {}
    for kind in kinds:
        text = read_credential(kind)
        if not text:
            continue
        try:
            doc = tomllib.loads(text)
        except tomllib.TOMLDecodeError:
            continue
        for _skill, profiles in doc.items():
            if isinstance(profiles, dict) and isinstance(profiles.get(profile), dict):
                out.update(profiles[profile])
    return out


def _handle_request(req, ctx):
    """Return a JSON-RPC response dict, or None when no reply is owed."""
    server_name, server_version, tools, call_tool = ctx
    method = req.get("method")
    req_id = req.get("id")
    is_notification = "id" not in req

    if method == "initialize":
        result = {
            "protocolVersion": PROTOCOL_VERSION,
            "serverInfo": {"name": server_name, "version": server_version},
            "capabilities": {"tools": {}},
        }
    elif method == "notifications/initialized":
        return None
    elif method == "tools/list":
        result = {"tools": tools}
    elif method == "tools/call":
        params = req.get("params") or {}
        text, is_error = call_tool(params.get("name"), params.get("arguments") or {})
        result = {"content": [{"type": "text", "text": text}], "isError": is_error}
    else:
        if is_notification:
            return None
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {"code": -32601, "message": f"method not found: {method}"},
        }

    if is_notification:
        return None
    return {"jsonrpc": "2.0", "id": req_id, "result": result}


def _handle_line(line, ctx):
    try:
        req = json.loads(line)
        if not isinstance(req, dict):
            raise ValueError("request is not an object")
    except ValueError as e:
        return {
            "jsonrpc": "2.0",
            "id": None,
            "error": {"code": -32700, "message": f"parse error: {e}"},
        }
    return _handle_request(req, ctx)


def _serve_connection(conn, ctx):
    with conn, conn.makefile("rb") as reader:
        for line in reader:
            line = line.strip()
            if not line:
                continue
            resp = _handle_line(line, ctx)
            if resp is not None:
                conn.sendall(json.dumps(resp).encode("utf-8") + b"\n")


def _serve(sock, ctx):
    while True:
        try:
            conn, _ = sock.accept()
        except OSError:
            return
        try:
            _serve_connection(conn, ctx)
        except Exception as e:  # noqa: BLE001 — never crash the accept loop
            print(f"connection error: {e.__class__.__name__}: {e}", file=sys.stderr)


def _listen(server_name):
    if os.environ.get("LISTEN_FDS"):
        return socket.socket(fileno=3)
    path = os.environ.get("SPACES_INTEGRATION_SOCKET")
    if path:
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.bind(path)
        sock.listen(8)
        return sock
    print(
        f"{server_name}: no listening socket "
        "(set LISTEN_FDS via socket activation or SPACES_INTEGRATION_SOCKET)",
        file=sys.stderr,
    )
    return None


def run(server_name, server_version, tools, call_tool):
    """Bind (socket activation or SPACES_INTEGRATION_SOCKET) and serve until the
    socket closes. `call_tool(name, arguments)` returns `(text, is_error)`.
    Returns a process exit code."""
    sock = _listen(server_name)
    if sock is None:
        return 2
    _serve(sock, (server_name, server_version, tools, call_tool))
    return 0

"""Shared MCP server scaffold for spaces integrations.

NDJSON JSON-RPC 2.0 over a unix socket. The listening socket arrives either as
fd 3 (systemd socket activation, LISTEN_FDS) or is bound at
SPACES_INTEGRATION_SOCKET (tests). Connections are served sequentially.

An integration declares its tools as records ({name, description, schema,
needs_fields, impl}) and assembles a server via `make_server`; this module owns
the per-call pipeline (dispatch, profile resolution, required-field gating,
error wrapping, the shared secret_fingerprint tool) plus the JSON-RPC protocol,
NDJSON framing, and socket lifecycle so every integration server speaks exactly
one wire dialect.
"""

import hashlib
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
    as a tool error at the call site, never a crash.
    """
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


def store_profiles(kinds=("config", "secrets")):
    """Sorted names of every provisioned profile (union across the config and
    secrets blobs).
    """
    names = set()
    for kind in kinds:
        text = read_credential(kind)
        if not text:
            continue
        try:
            doc = tomllib.loads(text)
        except tomllib.TOMLDecodeError:
            continue
        for _skill, profiles in doc.items():
            if isinstance(profiles, dict):
                names.update(k for k, v in profiles.items() if isinstance(v, dict))
    return sorted(names)


def resolve_profile(arguments):
    """Pick the profile a tool call targets: (name, error_text). Uses
    arguments["profile"] when given; else the sole provisioned profile; errors
    when the name is unknown, when several exist and none was named, or when none
    is provisioned. Mirrors himalaya's default-account behaviour.
    """
    profs = store_profiles()
    want = arguments.get("profile")
    if want:
        if want not in profs:
            return None, f"profile '{want}' is not provisioned"
        return want, None
    if len(profs) == 1:
        return profs[0], None
    if not profs:
        return None, "no profile provisioned; add one in the panel first"
    return None, f"multiple profiles ({', '.join(profs)}); pass a profile argument"


_PROFILE_PROP = {
    "profile": {
        "type": "string",
        "description": "account profile (default: the only one)",
    }
}

FINGERPRINT_TOOL = "secret_fingerprint"
# Truncated fingerprint width: leading hex chars of the sha256 digest (see the
# make_server docstring's "first 16 hex chars").
_FINGERPRINT_HEX = 16


def _advertised(records, multi_profile):
    """The tools/list payload for the records: name/description/inputSchema,
    with the profile property injected when the server is multi-profile.
    """
    tools = []
    for rec in records:
        props = dict(rec["schema"].get("properties", {}))
        if multi_profile:
            props.update(_PROFILE_PROP)
        tools.append(
            {
                "name": rec["name"],
                "description": rec["description"],
                "inputSchema": {
                    "type": "object",
                    "properties": props,
                    "required": rec["schema"].get("required", []),
                },
            }
        )
    return tools


def make_server(
    server_name,
    server_version,
    records,
    *,
    secret_field=None,
    multi_profile=True,
    error_label="tool",
    require_profile=True,
):
    """Assemble an integration server from declarative tool records.

    A record is {"name", "description", "schema", "needs_fields", "impl"}:
    `schema` is the tool's inputSchema body ({"properties", "required"}) WITHOUT
    the profile property (injected here when `multi_profile`); `needs_fields`
    names the store fields that must be non-empty for the resolved profile
    before the impl runs; `impl(arguments, profile, vals) -> (text, is_error)`
    does the work with the profile's merged store values.

    The scaffold owns the shared per-call pipeline: dispatch (unknown tool ->
    error), profile resolution, required-field gating, OSError wrapping
    ("<error_label> failed: ..."), and the hidden secret_fingerprint tool
    (sha256 of `secret_field`, first 16 hex chars) that is callable but never
    advertised. Every failure is a tool error, never a crash.

    A field-less integration (config={} + secrets={}, e.g. one driven entirely
    by environment) passes `secret_field=None` (no fingerprint tool is
    registered) and `require_profile=False`; then no profile is resolved and the
    impl runs with `profile=None, vals={}`. This is the runtime half of the
    broker's field-less enable (no credential staging => zero provisioned
    profiles).

    Returns (tools, call_tool, main): the advertised tools/list payload, the
    dispatcher, and a ready process entry point.
    """
    by_name = {rec["name"]: rec for rec in records}
    if secret_field is not None:
        by_name[FINGERPRINT_TOOL] = {
            "name": FINGERPRINT_TOOL,
            "needs_fields": (secret_field,),
            "impl": lambda args, profile, vals: (
                hashlib.sha256(vals[secret_field].encode("utf-8")).hexdigest()[
                    :_FINGERPRINT_HEX
                ],
                False,
            ),
        }
    tools = _advertised(records, multi_profile)

    def call_tool(name, arguments):
        rec = by_name.get(name)
        if rec is None:
            return f"unknown tool: {name}", True
        if require_profile:
            profile, err = resolve_profile(arguments)
            if err:
                return err, True
            vals = store_profile(profile)
        else:
            profile, vals = None, {}
        for field in rec["needs_fields"]:
            if not vals.get(field):
                return f"field '{field}' not set for profile '{profile}'", True
        try:
            return rec["impl"](arguments, profile, vals)
        except OSError as e:
            return f"{error_label} failed: {e.__class__.__name__}: {e}", True

    def main():
        return run(server_name, server_version, tools, call_tool)

    return tools, call_tool, main


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
    Returns a process exit code.
    """
    sock = _listen(server_name)
    if sock is None:
        return 2
    _serve(sock, (server_name, server_version, tools, call_tool))
    return 0

import hashlib
import json
import os
import socket
import tempfile
import threading
import time
from pathlib import Path

import spaces_integration_mcp as mcp

TOOLS = [
    {
        "name": "echo",
        "description": "echo back its text argument",
        "inputSchema": {
            "type": "object",
            "properties": {"text": {"type": "string"}},
            "required": ["text"],
        },
    },
]


def call_tool(name, arguments):
    if name == "echo":
        return arguments.get("text", ""), False
    if name == "boom":
        return "tool failed", True
    return f"unknown tool: {name}", True


class Client:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(5)
        self.sock.connect(path)
        self.reader = self.sock.makefile("rb")

    def send(self, obj):
        self.sock.sendall(json.dumps(obj).encode() + b"\n")

    def send_raw(self, data):
        self.sock.sendall(data)

    def recv(self):
        line = self.reader.readline()
        assert line, "connection closed unexpectedly"
        return json.loads(line)

    def rpc(self, method, params=None, msg_id=1):
        msg = {"jsonrpc": "2.0", "id": msg_id, "method": method}
        if params is not None:
            msg["params"] = params
        self.send(msg)
        return self.recv()

    def close(self):
        self.reader.close()
        self.sock.close()


# unique per test run, os.getpid() keeps parallel test workers apart
sock_path = str(Path(tempfile.mkdtemp()) / f"spaces-mcp-test-{os.getpid()}.sock")


def _serve():
    os.environ["SPACES_INTEGRATION_SOCKET"] = sock_path
    os.environ.pop("LISTEN_FDS", None)
    mcp.run("test-integration", "9.9.9", TOOLS, call_tool)


def setup_module():
    threading.Thread(target=_serve, daemon=True).start()
    deadline = time.monotonic() + 5
    while not Path(sock_path).exists():
        assert time.monotonic() < deadline, "server socket never appeared"
        time.sleep(0.01)


def _client():
    return Client(sock_path)


def test_initialize_reports_identity():
    c = _client()
    try:
        resp = c.rpc("initialize", {"protocolVersion": mcp.PROTOCOL_VERSION})
        result = resp["result"]
        assert result["protocolVersion"] == mcp.PROTOCOL_VERSION
        assert result["serverInfo"] == {"name": "test-integration", "version": "9.9.9"}
        assert result["capabilities"] == {"tools": {}}
    finally:
        c.close()


def test_initialized_notification_gets_no_reply():
    c = _client()
    try:
        c.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        # No reply owed; the same connection stays usable.
        resp = c.rpc("tools/list", msg_id=5)
        assert resp["id"] == 5
    finally:
        c.close()


def test_tools_list_returns_the_supplied_tools():
    c = _client()
    try:
        resp = c.rpc("tools/list")
        assert [t["name"] for t in resp["result"]["tools"]] == ["echo"]
    finally:
        c.close()


def test_tools_call_ok_and_error_map_to_content():
    c = _client()
    try:
        ok = c.rpc(
            "tools/call", {"name": "echo", "arguments": {"text": "hi"}}, msg_id=2
        )
        assert ok["result"]["isError"] is False
        assert ok["result"]["content"] == [{"type": "text", "text": "hi"}]

        bad = c.rpc("tools/call", {"name": "boom", "arguments": {}}, msg_id=3)
        assert bad["result"]["isError"] is True
        assert bad["result"]["content"][0]["text"] == "tool failed"
    finally:
        c.close()


def test_unknown_method_is_jsonrpc_error():
    c = _client()
    try:
        resp = c.rpc("frobnicate", msg_id=9)
        assert resp["id"] == 9
        assert resp["error"]["code"] == -32601
    finally:
        c.close()


def test_malformed_line_then_connection_survives():
    c = _client()
    try:
        c.send_raw(b"not json at all\n")
        resp = c.recv()
        assert resp["id"] is None
        assert resp["error"]["code"] == -32700
        resp = c.rpc("tools/list", msg_id=7)
        assert resp["id"] == 7
    finally:
        c.close()


def test_unknown_method_notification_is_silent():
    # A notification (no id) for an unknown method owes no reply; the next
    # request on the same connection must still get its answer.
    c = _client()
    try:
        c.send({"jsonrpc": "2.0", "method": "frobnicate"})
        resp = c.rpc("tools/list", msg_id=8)
        assert resp["id"] == 8
    finally:
        c.close()


def test_read_credential_and_shared_dir(tmp_path, monkeypatch):
    creds = tmp_path / "creds"
    creds.mkdir()
    (creds / "token").write_text("s3cret\n")
    monkeypatch.setenv("CREDENTIALS_DIRECTORY", str(creds))
    assert mcp.read_credential("token") == "s3cret"
    assert mcp.read_credential("absent") is None

    monkeypatch.delenv("CREDENTIALS_DIRECTORY", raising=False)
    assert mcp.read_credential("token") is None

    monkeypatch.setenv("SPACES_INTEGRATION_SHARED_DIR", "/run/share/x")
    assert mcp.shared_dir() == "/run/share/x"
    monkeypatch.delenv("SPACES_INTEGRATION_SHARED_DIR", raising=False)
    assert mcp.shared_dir() is None


def test_store_profile_merges_config_and_secrets(tmp_path, monkeypatch):
    creds = tmp_path / "creds"
    creds.mkdir()
    (creds / "config").write_text(
        '[mail.work]\nimap_host = "imap.corp.com"\nimap_port = "993"\n'
    )
    (creds / "secrets").write_text('[mail.work]\npassword = "hunter2"\n')
    monkeypatch.setenv("CREDENTIALS_DIRECTORY", str(creds))

    vals = mcp.store_profile("work")
    assert vals["imap_host"] == "imap.corp.com"
    assert vals["imap_port"] == "993"
    assert vals["password"] == "hunter2"
    # A profile that isn't provisioned yields no fields.
    assert mcp.store_profile("home") == {}


def test_store_profile_absent_blobs(tmp_path, monkeypatch):
    monkeypatch.setenv("CREDENTIALS_DIRECTORY", str(tmp_path / "empty"))
    assert mcp.store_profile("work") == {}
    monkeypatch.delenv("CREDENTIALS_DIRECTORY", raising=False)
    assert mcp.store_profile("work") == {}


def test_store_profiles_and_resolve(tmp_path, monkeypatch):
    creds = tmp_path / "creds"
    creds.mkdir()
    (creds / "config").write_text(
        '[mail.work]\nimap_host = "a"\n[mail.home]\nimap_host = "b"\n'
    )
    (creds / "secrets").write_text('[mail.work]\npassword = "p"\n')
    monkeypatch.setenv("CREDENTIALS_DIRECTORY", str(creds))

    assert mcp.store_profiles() == ["home", "work"]
    # explicit, valid
    assert mcp.resolve_profile({"profile": "home"}) == ("home", None)
    # explicit, unknown
    name, err = mcp.resolve_profile({"profile": "nope"})
    assert name is None
    assert "not provisioned" in err
    # ambiguous (several, none named)
    name, err = mcp.resolve_profile({})
    assert name is None
    assert "multiple profiles" in err


def test_resolve_profile_single_and_none(tmp_path, monkeypatch):
    creds = tmp_path / "creds"
    creds.mkdir()
    monkeypatch.setenv("CREDENTIALS_DIRECTORY", str(creds))
    # none provisioned
    name, err = mcp.resolve_profile({})
    assert name is None
    assert "no profile" in err
    # exactly one → used implicitly
    (creds / "secrets").write_text('[mail.only]\npassword = "p"\n')
    assert mcp.resolve_profile({}) == ("only", None)


# --- managed credentials (Nix-managed profiles, design §10.3/§10.6) ----------


def test_store_profile_managed_shadows_user(tmp_path, monkeypatch):
    # A managed profile name wins WHOLESALE over a same-named user profile:
    # user-only fields under that name are dropped, not per-field merged.
    creds = tmp_path / "creds"
    creds.mkdir()
    (creds / "config").write_text(
        '[mail.work]\nimap_host = "user.imap"\nsmtp_host = "user.smtp"\n'
    )
    (creds / "secrets").write_text('[mail.work]\npassword = "user-pw"\n')
    (creds / "managed_managed-config.toml").write_text(
        '[mail.work]\nimap_host = "managed.imap"\n'
    )
    (creds / "managed_secret-work-password").write_text("managed-pw\n")
    monkeypatch.setenv("CREDENTIALS_DIRECTORY", str(creds))

    assert mcp.store_profile("work") == {
        "imap_host": "managed.imap",
        "password": "managed-pw",
    }


def test_store_profile_managed_only(tmp_path, monkeypatch):
    creds = tmp_path / "creds"
    creds.mkdir()
    (creds / "config").write_text('[mail.home]\nimap_host = "home.imap"\n')
    (creds / "managed_managed-config.toml").write_text(
        '[mail.corp]\nimap_host = "corp.imap"\nsmtp_host = "corp.smtp"\n'
    )
    (creds / "managed_secret-corp-password").write_text("corp-pw")
    monkeypatch.setenv("CREDENTIALS_DIRECTORY", str(creds))

    assert mcp.store_profile("corp") == {
        "imap_host": "corp.imap",
        "smtp_host": "corp.smtp",
        "password": "corp-pw",
    }


def test_store_profile_user_only_untouched_with_managed_present(tmp_path, monkeypatch):
    # Managed creds for another profile must not disturb a user-only profile.
    creds = tmp_path / "creds"
    creds.mkdir()
    (creds / "config").write_text('[mail.home]\nimap_host = "home.imap"\n')
    (creds / "secrets").write_text('[mail.home]\npassword = "home-pw"\n')
    (creds / "managed_managed-config.toml").write_text('[mail.corp]\nimap_host = "c"\n')
    monkeypatch.setenv("CREDENTIALS_DIRECTORY", str(creds))

    assert mcp.store_profile("home") == {
        "imap_host": "home.imap",
        "password": "home-pw",
    }


def test_managed_secret_filename_resolution_config_known(tmp_path, monkeypatch):
    # A config-known profile prefix resolves a dashed field name correctly.
    creds = tmp_path / "creds"
    creds.mkdir()
    (creds / "managed_managed-config.toml").write_text('[mail.work]\nimap_host = "w"\n')
    (creds / "managed_secret-work-imap-password").write_text("secret-value\n")
    monkeypatch.setenv("CREDENTIALS_DIRECTORY", str(creds))

    assert mcp.store_profile("work") == {
        "imap_host": "w",
        "imap-password": "secret-value",
    }


def test_managed_secret_filename_fallback_split(tmp_path, monkeypatch):
    # No config table for the profile → split on the first '-'.
    creds = tmp_path / "creds"
    creds.mkdir()
    (creds / "managed_secret-solo-password").write_text("solo-pw")
    monkeypatch.setenv("CREDENTIALS_DIRECTORY", str(creds))

    assert mcp.store_profile("solo") == {"password": "solo-pw"}


def test_store_profiles_union_of_user_and_managed(tmp_path, monkeypatch):
    creds = tmp_path / "creds"
    creds.mkdir()
    (creds / "config").write_text('[mail.home]\nimap_host = "h"\n')
    (creds / "secrets").write_text('[mail.home]\npassword = "p"\n')
    (creds / "managed_managed-config.toml").write_text('[mail.corp]\nimap_host = "c"\n')
    (creds / "managed_secret-vault-token").write_text("t")
    monkeypatch.setenv("CREDENTIALS_DIRECTORY", str(creds))

    assert mcp.store_profiles() == ["corp", "home", "vault"]


# --- make_server: declarative tool records ----------------------------------


def _demo_records():
    def hello_impl(args, profile, vals):
        return f"hello {profile}:{vals['user']}:{args.get('text', '')}", False

    def crash_impl(_args, _profile, _vals):
        msg = "disk gone"
        raise OSError(msg)

    return [
        {
            "name": "hello",
            "description": "say hello",
            "schema": {
                "properties": {"text": {"type": "string"}},
                "required": ["text"],
            },
            "needs_fields": ("user", "password"),
            "impl": hello_impl,
        },
        {
            "name": "crash",
            "description": "raise from the impl",
            "schema": {"properties": {}, "required": []},
            "needs_fields": (),
            "impl": crash_impl,
        },
    ]


def _demo_server(**kwargs):
    kwargs.setdefault("secret_field", "password")
    return mcp.make_server("demo", "0.0.1", _demo_records(), **kwargs)


def _provision(tmp_path, monkeypatch, secrets='[demo.work]\npassword = "pw-1"\n'):
    creds = tmp_path / "creds"
    creds.mkdir()
    (creds / "config").write_text('[demo.work]\nuser = "alice"\n')
    (creds / "secrets").write_text(secrets)
    monkeypatch.setenv("CREDENTIALS_DIRECTORY", str(creds))


def test_make_server_injects_profile_prop_when_multi_profile():
    tools, _, _ = _demo_server(multi_profile=True)
    assert [t["name"] for t in tools] == ["hello", "crash"]
    for t in tools:
        props = t["inputSchema"]["properties"]
        assert props["profile"]["type"] == "string"
        assert "profile" not in t["inputSchema"]["required"]
    # the tool's own schema is intact
    hello = tools[0]
    assert hello["description"] == "say hello"
    assert hello["inputSchema"]["type"] == "object"
    assert hello["inputSchema"]["properties"]["text"] == {"type": "string"}
    assert hello["inputSchema"]["required"] == ["text"]


def test_make_server_single_profile_omits_profile_prop():
    tools, _, _ = _demo_server(multi_profile=False)
    for t in tools:
        assert "profile" not in t["inputSchema"]["properties"]


def test_make_server_never_advertises_secret_fingerprint():
    tools, _, _ = _demo_server()
    assert "secret_fingerprint" not in [t["name"] for t in tools]


def test_make_server_unknown_tool_is_error(tmp_path, monkeypatch):
    _provision(tmp_path, monkeypatch)
    _, call_tool, _ = _demo_server()
    assert call_tool("nope", {}) == ("unknown tool: nope", True)


def test_make_server_dispatches_with_profile_and_vals(tmp_path, monkeypatch):
    _provision(tmp_path, monkeypatch)
    _, call_tool, _ = _demo_server()
    assert call_tool("hello", {"text": "hi"}) == ("hello work:alice:hi", False)


def test_make_server_gates_missing_required_field(tmp_path, monkeypatch):
    _provision(tmp_path, monkeypatch, secrets='[demo.work]\nother = "x"\n')
    _, call_tool, _ = _demo_server()
    assert call_tool("hello", {}) == (
        "field 'password' not set for profile 'work'",
        True,
    )


def test_make_server_profile_resolution_error_passthrough(tmp_path, monkeypatch):
    monkeypatch.setenv("CREDENTIALS_DIRECTORY", str(tmp_path / "empty"))
    _, call_tool, _ = _demo_server()
    text, is_error = call_tool("hello", {})
    assert is_error
    assert "no profile" in text


def test_make_server_secret_fingerprint_is_callable_and_stable(tmp_path, monkeypatch):
    _provision(tmp_path, monkeypatch)
    _, call_tool, _ = _demo_server()
    expected = hashlib.sha256(b"pw-1").hexdigest()[:16]
    assert call_tool("secret_fingerprint", {}) == (expected, False)
    # stable across calls
    assert call_tool("secret_fingerprint", {}) == (expected, False)


def test_make_server_fingerprint_gates_on_secret_field(tmp_path, monkeypatch):
    _provision(tmp_path, monkeypatch, secrets='[demo.work]\nother = "x"\n')
    _, call_tool, _ = _demo_server()
    assert call_tool("secret_fingerprint", {}) == (
        "field 'password' not set for profile 'work'",
        True,
    )


def test_make_server_wraps_oserror(tmp_path, monkeypatch):
    _provision(tmp_path, monkeypatch)
    _, call_tool, _ = _demo_server(error_label="demo operation")
    assert call_tool("crash", {}) == (
        "demo operation failed: OSError: disk gone",
        True,
    )


def test_make_server_field_less_dispatches_without_profile(tmp_path, monkeypatch):
    # config={} + secrets={} => the broker stages no credentials, so no profile
    # is ever provisioned. require_profile=False lets the impl run anyway with
    # profile=None, vals={} (the runtime half of the broker's field-less enable).
    monkeypatch.setenv("CREDENTIALS_DIRECTORY", str(tmp_path / "empty"))
    records = [
        {
            "name": "ping",
            "description": "pong",
            "schema": {"properties": {}, "required": []},
            "needs_fields": (),
            "impl": lambda args, profile, vals: (f"{profile}:{vals}", False),
        }
    ]
    tools, call_tool, _ = mcp.make_server(
        "fl", "0", records, multi_profile=False, require_profile=False
    )
    assert call_tool("ping", {}) == ("None:{}", False)
    # No secret_field => no hidden fingerprint tool registered or callable.
    assert "secret_fingerprint" not in [t["name"] for t in tools]
    assert call_tool("secret_fingerprint", {}) == (
        "unknown tool: secret_fingerprint",
        True,
    )

import json
import os
import socket
import threading
import time

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

    def rpc(self, method, params=None, id=1):
        msg = {"jsonrpc": "2.0", "id": id, "method": method}
        if params is not None:
            msg["params"] = params
        self.send(msg)
        return self.recv()

    def close(self):
        self.reader.close()
        self.sock.close()


def _serve(sock_path):
    os.environ["SPACES_INTEGRATION_SOCKET"] = sock_path
    os.environ.pop("LISTEN_FDS", None)
    mcp.run("test-integration", "9.9.9", TOOLS, call_tool)


def setup_module(module):
    module.sock_path = f"/tmp/spaces-mcp-test-{os.getpid()}.sock"
    threading.Thread(target=_serve, args=(module.sock_path,), daemon=True).start()
    deadline = time.monotonic() + 5
    while not os.path.exists(module.sock_path):
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
        resp = c.rpc("tools/list", id=5)
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
        ok = c.rpc("tools/call", {"name": "echo", "arguments": {"text": "hi"}}, id=2)
        assert ok["result"]["isError"] is False
        assert ok["result"]["content"] == [{"type": "text", "text": "hi"}]

        bad = c.rpc("tools/call", {"name": "boom", "arguments": {}}, id=3)
        assert bad["result"]["isError"] is True
        assert bad["result"]["content"][0]["text"] == "tool failed"
    finally:
        c.close()


def test_unknown_method_is_jsonrpc_error():
    c = _client()
    try:
        resp = c.rpc("frobnicate", id=9)
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
        resp = c.rpc("tools/list", id=7)
        assert resp["id"] == 7
    finally:
        c.close()


def test_unknown_method_notification_is_silent():
    # A notification (no id) for an unknown method owes no reply; the next
    # request on the same connection must still get its answer.
    c = _client()
    try:
        c.send({"jsonrpc": "2.0", "method": "frobnicate"})
        resp = c.rpc("tools/list", id=8)
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
    (creds / "config").write_text('[mail.work]\nimap_host = "a"\n[mail.home]\nimap_host = "b"\n')
    (creds / "secrets").write_text('[mail.work]\npassword = "p"\n')
    monkeypatch.setenv("CREDENTIALS_DIRECTORY", str(creds))

    assert mcp.store_profiles() == ["home", "work"]
    # explicit, valid
    assert mcp.resolve_profile({"profile": "home"}) == ("home", None)
    # explicit, unknown
    name, err = mcp.resolve_profile({"profile": "nope"})
    assert name is None and "not provisioned" in err
    # ambiguous (several, none named)
    name, err = mcp.resolve_profile({})
    assert name is None and "multiple profiles" in err


def test_resolve_profile_single_and_none(tmp_path, monkeypatch):
    creds = tmp_path / "creds"
    creds.mkdir()
    monkeypatch.setenv("CREDENTIALS_DIRECTORY", str(creds))
    # none provisioned
    name, err = mcp.resolve_profile({})
    assert name is None and "no profile" in err
    # exactly one → used implicitly
    (creds / "secrets").write_text('[mail.only]\npassword = "p"\n')
    assert mcp.resolve_profile({}) == ("only", None)

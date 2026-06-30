import hashlib
import json
import os
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import integration_github
import pytest

TOKEN = "sekrit-token-12345"


class StubGitHub(BaseHTTPRequestHandler):
    """Records requests, serves canned JSON."""

    requests = []  # (method, path, headers-dict, body-bytes)

    def _record(self, body=b""):
        StubGitHub.requests.append((self.command, self.path, dict(self.headers), body))

    def _reply(self, code, payload):
        data = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._record()
        if self.path == "/repos/octocat/hello":
            self._reply(
                200,
                {
                    "full_name": "octocat/hello",
                    "description": "A test repo",
                    "stargazers_count": 42,
                    "default_branch": "main",
                },
            )
        else:
            self._reply(404, {"message": "Not Found"})

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self._record(body)
        if self.path == "/repos/octocat/hello/issues":
            self._reply(
                201,
                {
                    "number": 7,
                    "html_url": "https://github.test/octocat/hello/issues/7",
                },
            )
        else:
            self._reply(404, {"message": "Not Found"})

    def log_message(self, *args):
        pass


@pytest.fixture(scope="module")
def env(tmp_path_factory):
    tmp = tmp_path_factory.mktemp("itg")

    stub = ThreadingHTTPServer(("127.0.0.1", 0), StubGitHub)
    threading.Thread(target=stub.serve_forever, daemon=True).start()

    creds = tmp / "creds"
    creds.mkdir()
    (creds / "token").write_text(TOKEN + "\n")

    sock_path = str(tmp / "github.sock")
    os.environ["SPACES_INTEGRATION_SOCKET"] = sock_path
    os.environ["SPACES_GITHUB_API_URL"] = f"http://127.0.0.1:{stub.server_address[1]}"
    os.environ["CREDENTIALS_DIRECTORY"] = str(creds)
    os.environ.pop("LISTEN_FDS", None)

    threading.Thread(target=integration_github.main, daemon=True).start()
    deadline = time.monotonic() + 5
    while not os.path.exists(sock_path):
        assert time.monotonic() < deadline, "server socket never appeared"
        time.sleep(0.01)

    yield {"sock": sock_path, "creds": str(creds), "tmp": tmp}
    stub.shutdown()


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


@pytest.fixture
def client(env):
    c = Client(env["sock"])
    yield c
    c.close()


def call_tool(client, name, arguments):
    return client.rpc("tools/call", {"name": name, "arguments": arguments}, id=2)


def test_initialize_handshake(client):
    resp = client.rpc(
        "initialize",
        {
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": {"name": "pi-sessiond", "version": "0"},
        },
    )
    assert resp["id"] == 1
    result = resp["result"]
    assert result["protocolVersion"] == "2025-03-26"
    assert result["serverInfo"]["name"] == "integration-github"
    assert result["capabilities"] == {"tools": {}}
    # notification: no reply, connection stays usable
    client.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    resp = client.rpc("tools/list", id=2)
    assert resp["id"] == 2


def test_tools_list_shape(client):
    resp = client.rpc("tools/list")
    tools = {t["name"]: t for t in resp["result"]["tools"]}
    assert set(tools) == {"get_repo", "create_issue"}
    assert tools["get_repo"]["inputSchema"]["required"] == ["repo"]
    assert tools["create_issue"]["inputSchema"]["required"] == ["repo", "title"]
    assert (
        tools["create_issue"]["inputSchema"]["properties"]["body"]["type"] == "string"
    )


def test_get_repo_happy_path(client):
    resp = call_tool(client, "get_repo", {"repo": "octocat/hello"})
    result = resp["result"]
    assert result["isError"] is False
    assert result["content"] == [
        {
            "type": "text",
            "text": "octocat/hello: A test repo (stars 42, default branch main)",
        }
    ]


def test_create_issue_sends_auth_and_returns_url(client):
    StubGitHub.requests.clear()
    resp = call_tool(
        client,
        "create_issue",
        {
            "repo": "octocat/hello",
            "title": "Bug",
            "body": "It broke",
        },
    )
    result = resp["result"]
    assert result["isError"] is False
    assert (
        result["content"][0]["text"]
        == "created issue #7: https://github.test/octocat/hello/issues/7"
    )

    method, path, headers, body = StubGitHub.requests[-1]
    assert (method, path) == ("POST", "/repos/octocat/hello/issues")
    assert headers["Authorization"] == f"Bearer {TOKEN}"
    assert headers["Accept"] == "application/vnd.github+json"
    assert json.loads(body) == {"title": "Bug", "body": "It broke"}


def test_missing_token_is_error_and_leaks_nothing(client, env, tmp_path):
    empty = tmp_path / "empty-creds"
    empty.mkdir()
    os.environ["CREDENTIALS_DIRECTORY"] = str(empty)
    try:
        resp = call_tool(
            client, "create_issue", {"repo": "octocat/hello", "title": "x"}
        )
    finally:
        os.environ["CREDENTIALS_DIRECTORY"] = env["creds"]
    result = resp["result"]
    assert result["isError"] is True
    assert TOKEN not in json.dumps(resp)


def test_bad_repo_name_is_error(client):
    StubGitHub.requests.clear()
    for bad in ("no-slash", "../../etc/passwd", "a/b/c", "o/r?x=1"):
        resp = call_tool(client, "get_repo", {"repo": bad})
        assert resp["result"]["isError"] is True, bad
    assert StubGitHub.requests == []  # never hit the API


def test_secret_fingerprint(client):
    resp = call_tool(client, "secret_fingerprint", {})
    expected = hashlib.sha256(TOKEN.encode()).hexdigest()[:16]
    assert resp["result"]["content"] == [{"type": "text", "text": expected}]
    assert resp["result"]["isError"] is False


def test_secret_fingerprint_not_listed(client):
    resp = client.rpc("tools/list")
    assert "secret_fingerprint" not in [t["name"] for t in resp["result"]["tools"]]


def test_unknown_method_is_jsonrpc_error(client):
    resp = client.rpc("frobnicate", id=9)
    assert resp["id"] == 9
    assert resp["error"]["code"] == -32601


def test_malformed_line_then_connection_survives(client):
    client.send_raw(b"this is not json\n")
    resp = client.recv()
    assert resp["id"] is None
    assert resp["error"]["code"] == -32700
    # same connection still works
    resp = client.rpc("tools/list", id=3)
    assert resp["id"] == 3
    assert "tools" in resp["result"]


def test_http_error_is_tool_error(client):
    resp = call_tool(client, "get_repo", {"repo": "octocat/missing"})
    result = resp["result"]
    assert result["isError"] is True
    assert "404" in result["content"][0]["text"]

import hashlib
import io
import json
import os
import socket
import tarfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import integration_github
import pytest

TOKEN = "sekrit-token-12345"


def _make_tarball(prefix="octocat-hello-deadbee", files=None):
    """A GitHub-style tar.gz: every entry under a single "<owner>-<repo>-<sha>/"
    wrapper dir, exactly what the tarball endpoint returns."""
    files = files or {"README.md": b"# hello\n", "src/app.py": b"print('hi')\n"}
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for rel, data in files.items():
            info = tarfile.TarInfo(f"{prefix}/{rel}")
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    return buf.getvalue()


TARBALL = _make_tarball()


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

    def _reply_bytes(self, code, data, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
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
        elif self.path.startswith("/repos/octocat/hello/tarball/"):
            self._reply_bytes(200, TARBALL, "application/gzip")
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
        elif self.path == "/repos/octocat/hello/pulls":
            self._reply(
                201,
                {
                    "number": 99,
                    "html_url": "https://github.test/octocat/hello/pull/99",
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
    (creds / "secrets").write_text(f'[github.default]\ntoken = "{TOKEN}"\n')
    share = tmp / "share"
    share.mkdir()

    sock_path = str(tmp / "github.sock")
    os.environ["SPACES_INTEGRATION_SOCKET"] = sock_path
    os.environ["SPACES_GITHUB_API_URL"] = f"http://127.0.0.1:{stub.server_address[1]}"
    os.environ["CREDENTIALS_DIRECTORY"] = str(creds)
    os.environ["SPACES_INTEGRATION_SHARED_DIR"] = str(share)
    os.environ.pop("LISTEN_FDS", None)

    threading.Thread(target=integration_github.main, daemon=True).start()
    deadline = time.monotonic() + 5
    while not os.path.exists(sock_path):
        assert time.monotonic() < deadline, "server socket never appeared"
        time.sleep(0.01)

    yield {"sock": sock_path, "creds": str(creds), "tmp": tmp, "share": str(share)}
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
    assert set(tools) == {
        "get_repo",
        "create_issue",
        "clone_to_workspace",
        "open_pull_request",
    }
    assert tools["get_repo"]["inputSchema"]["required"] == ["repo"]
    assert tools["create_issue"]["inputSchema"]["required"] == ["repo", "title"]
    assert (
        tools["create_issue"]["inputSchema"]["properties"]["body"]["type"] == "string"
    )
    assert tools["clone_to_workspace"]["inputSchema"]["required"] == ["repo"]
    assert tools["open_pull_request"]["inputSchema"]["required"] == ["repo", "title"]


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


def test_clone_to_workspace_extracts_tree(client, env):
    StubGitHub.requests.clear()
    resp = call_tool(client, "clone_to_workspace", {"repo": "octocat/hello"})
    result = resp["result"]
    assert result["isError"] is False
    dest = os.path.join(env["share"], "hello")
    # the wrapper dir is stripped; the tree lands directly under the workspace
    assert os.path.isfile(os.path.join(dest, "README.md"))
    assert os.path.isfile(os.path.join(dest, "src", "app.py"))
    assert "2 files" in result["content"][0]["text"]
    # the fetch carried the credential
    gets = [r for r in StubGitHub.requests if r[0] == "GET" and "/tarball/" in r[1]]
    assert gets and gets[0][2].get("Authorization") == f"Bearer {TOKEN}"


def test_clone_to_workspace_without_shared_dir_is_error(client, monkeypatch):
    monkeypatch.delenv("SPACES_INTEGRATION_SHARED_DIR", raising=False)
    resp = call_tool(client, "clone_to_workspace", {"repo": "octocat/hello"})
    result = resp["result"]
    assert result["isError"] is True
    assert "no shared workspace" in result["content"][0]["text"]


def test_open_pull_request_pushes_workspace_edits(client, env):
    StubGitHub.requests.clear()
    # clone, then the "agent" edits the tree with its own file tools
    call_tool(client, "clone_to_workspace", {"repo": "octocat/hello"})
    dest = os.path.join(env["share"], "hello")
    with open(os.path.join(dest, "AGENT.md"), "w") as fh:
        fh.write("agent was here\n")
    resp = call_tool(
        client,
        "open_pull_request",
        {"repo": "octocat/hello", "title": "My change", "body": "please review"},
    )
    result = resp["result"]
    assert result["isError"] is False
    assert "PR #99" in result["content"][0]["text"]
    # the effect reached the server with auth and the agent's edit reflected in it
    posts = [
        r for r in StubGitHub.requests if r[0] == "POST" and r[1].endswith("/pulls")
    ]
    assert len(posts) == 1
    _, _, headers, body = posts[0]
    assert headers.get("Authorization") == f"Bearer {TOKEN}"
    sent = json.loads(body)
    assert sent["title"] == "My change"
    assert sent["base"] == "main"
    assert "AGENT.md" in sent["body"]


def test_open_pull_request_without_clone_is_error(client, monkeypatch, tmp_path):
    monkeypatch.setenv("SPACES_INTEGRATION_SHARED_DIR", str(tmp_path / "empty"))
    resp = call_tool(
        client, "open_pull_request", {"repo": "octocat/hello", "title": "x"}
    )
    result = resp["result"]
    assert result["isError"] is True
    assert "clone_to_workspace first" in result["content"][0]["text"]

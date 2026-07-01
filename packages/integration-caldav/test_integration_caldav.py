import base64
import hashlib
import json
import os
import re
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import integration_caldav
import pytest

# profile -> (user, password); two profiles prove multi-profile isolation.
PROFILES = {
    "work": ("alice", "work-pass-123"),
    "home": ("bob", "home-pass-456"),
}

_UID_RE = re.compile(r"<c:text-match[^>]*>([^<]*)</c:text-match>")


def _multistatus(hrefs):
    body = "".join(
        f"  <d:response>\n"
        f"    <d:href>{h}</d:href>\n"
        f"    <d:propstat><d:prop><d:getetag>\"etag-{i}\"</d:getetag></d:prop>"
        f"<d:status>HTTP/1.1 200 OK</d:status></d:propstat>\n"
        f"  </d:response>\n"
        for i, h in enumerate(hrefs)
    )
    return f'<?xml version="1.0"?>\n<d:multistatus xmlns:d="DAV:">\n{body}</d:multistatus>\n'


class StubCalDAV(BaseHTTPRequestHandler):
    """Records requests, serves canned CalDAV responses."""

    requests = []  # (method, path, headers-dict, body-bytes)

    def _record(self, body=b""):
        StubCalDAV.requests.append((self.command, self.path, dict(self.headers), body))

    def _read_body(self):
        return self.rfile.read(int(self.headers.get("Content-Length", 0)))

    def _reply(self, code, data, ctype, headers=None):
        raw = data.encode() if isinstance(data, str) else data
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(raw)

    def do_REPORT(self):
        body = self._read_body()
        self._record(body)
        text = body.decode("utf-8", "replace")
        base = self.path.rstrip("/")
        if "time-range" in text:
            href = f"{base}/listed-event.ics"
            data = (
                "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:listed-event\r\n"
                "SUMMARY:Standup\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
            )
            xml = (
                '<?xml version="1.0"?>\n<d:multistatus xmlns:d="DAV:" '
                'xmlns:c="urn:ietf:params:xml:ns:caldav">\n'
                f"  <d:response>\n    <d:href>{href}</d:href>\n"
                "    <d:propstat><d:prop><d:getetag>\"etag-0\"</d:getetag>"
                f"<c:calendar-data>{data}</c:calendar-data></d:prop>"
                "<d:status>HTTP/1.1 200 OK</d:status></d:propstat>\n"
                "  </d:response>\n</d:multistatus>\n"
            )
            self._reply(207, xml, "application/xml; charset=utf-8")
            return
        m = _UID_RE.search(text)
        uid = m.group(1) if m else ""
        if uid == "ghost-uid":
            hrefs = []
        elif uid == "dup-uid":
            hrefs = [f"{base}/dup-a.ics", f"{base}/dup-b.ics"]
        else:
            hrefs = [f"{base}/{uid}-resource.ics"]
        self._reply(207, _multistatus(hrefs), "application/xml; charset=utf-8")

    def do_GET(self):
        self._record()
        if "missing" in self.path:
            self._reply(404, "{}", "application/json")
            return
        ics = f"BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:from {self.path}\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        self._reply(200, ics, "text/calendar; charset=utf-8")

    def do_HEAD(self):
        self._record()
        self._reply(200, b"", "text/calendar; charset=utf-8", headers={"ETag": '"etag-head"'})

    def do_PUT(self):
        self._record(self._read_body())
        self._reply(201, b"", "text/plain", headers={"ETag": '"etag-new"'})

    def do_DELETE(self):
        self._record()
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


def _config_toml(port):
    return "".join(
        f'[caldav.{p}]\nurl = "http://127.0.0.1:{port}/dav/{p}/"\nuser = "{u}"\n\n'
        for p, (u, _pw) in PROFILES.items()
    )


def _secrets_toml():
    return "".join(f'[caldav.{p}]\npassword = "{pw}"\n\n' for p, (_u, pw) in PROFILES.items())


@pytest.fixture(scope="module")
def env(tmp_path_factory):
    tmp = tmp_path_factory.mktemp("itc")

    stub = ThreadingHTTPServer(("127.0.0.1", 0), StubCalDAV)
    port = stub.server_address[1]
    threading.Thread(target=stub.serve_forever, daemon=True).start()

    creds = tmp / "creds"
    creds.mkdir()
    (creds / "config").write_text(_config_toml(port))
    (creds / "secrets").write_text(_secrets_toml())

    sock_path = str(tmp / "caldav.sock")
    os.environ["SPACES_INTEGRATION_SOCKET"] = sock_path
    os.environ["CREDENTIALS_DIRECTORY"] = str(creds)
    os.environ.pop("LISTEN_FDS", None)

    threading.Thread(target=integration_caldav.main, daemon=True).start()
    deadline = time.monotonic() + 5
    while not os.path.exists(sock_path):
        assert time.monotonic() < deadline, "server socket never appeared"
        time.sleep(0.01)

    yield {"sock": sock_path, "creds": str(creds), "tmp": tmp, "port": port}
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


def _text(resp):
    return resp["result"]["content"][0]["text"]


def _decoded_auth(headers):
    raw = headers["Authorization"].split(" ", 1)[1]
    return base64.b64decode(raw).decode("utf-8")


def test_initialize_handshake(client):
    resp = client.rpc(
        "initialize",
        {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}},
    )
    assert resp["id"] == 1
    result = resp["result"]
    assert result["protocolVersion"] == "2025-03-26"
    assert result["serverInfo"]["name"] == "integration-caldav"
    assert result["capabilities"] == {"tools": {}}
    client.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    resp = client.rpc("tools/list", id=2)
    assert resp["id"] == 2


def test_tools_list_shape(client):
    resp = client.rpc("tools/list")
    tools = {t["name"]: t for t in resp["result"]["tools"]}
    assert set(tools) == {"list", "get", "etag", "put", "delete"}
    for name, t in tools.items():
        props = t["inputSchema"]["properties"]
        assert props["profile"]["type"] == "string", name
        assert "profile" not in t["inputSchema"]["required"], name
    assert tools["list"]["inputSchema"]["required"] == ["start", "end"]
    assert tools["get"]["inputSchema"]["required"] == ["id"]
    assert tools["etag"]["inputSchema"]["required"] == ["id"]
    assert tools["put"]["inputSchema"]["required"] == ["id", "ics"]
    assert tools["delete"]["inputSchema"]["required"] == ["id"]


def test_secret_fingerprint_not_listed(client):
    resp = client.rpc("tools/list")
    assert "secret_fingerprint" not in [t["name"] for t in resp["result"]["tools"]]


def test_list_time_range_and_auth(client):
    StubCalDAV.requests.clear()
    resp = call_tool(
        client, "list", {"profile": "work", "start": "20260101T000000Z", "end": "20260201T000000Z"}
    )
    assert resp["result"]["isError"] is False
    assert "calendar-data" in _text(resp) and "Standup" in _text(resp)
    method, path, headers, body = StubCalDAV.requests[-1]
    assert (method, path) == ("REPORT", "/dav/work")
    assert _decoded_auth(headers) == "alice:work-pass-123"
    assert headers["Depth"] == "1"
    text = body.decode()
    assert 'time-range start="20260101T000000Z" end="20260201T000000Z"' in text


def test_get_resolves_uid_to_resource(client):
    StubCalDAV.requests.clear()
    resp = call_tool(client, "get", {"profile": "work", "id": "meeting-42"})
    assert resp["result"]["isError"] is False
    assert "BEGIN:VCALENDAR" in _text(resp)
    kinds = [(m, p) for (m, p, _h, _b) in StubCalDAV.requests]
    # resolve REPORT to the collection, then GET the resolved resource href
    assert kinds[0] == ("REPORT", "/dav/work")
    assert kinds[-1] == ("GET", "/dav/work/meeting-42-resource.ics")
    assert _decoded_auth(StubCalDAV.requests[-1][2]) == "alice:work-pass-123"


def test_get_uid_no_match_falls_back_to_ics(client):
    StubCalDAV.requests.clear()
    resp = call_tool(client, "get", {"profile": "work", "id": "ghost-uid"})
    assert resp["result"]["isError"] is False
    assert StubCalDAV.requests[-1][:2] == ("GET", "/dav/work/ghost-uid.ics")


def test_get_uid_multiple_matches_is_error(client):
    StubCalDAV.requests.clear()
    resp = call_tool(client, "get", {"profile": "work", "id": "dup-uid"})
    assert resp["result"]["isError"] is True
    assert "matched 2 resources" in _text(resp)
    assert not any(m == "GET" for (m, _p, _h, _b) in StubCalDAV.requests)


def test_etag_returns_header_value(client):
    StubCalDAV.requests.clear()
    resp = call_tool(client, "etag", {"profile": "work", "id": "meeting-42"})
    assert resp["result"]["isError"] is False
    assert _text(resp) == '"etag-head"'
    assert StubCalDAV.requests[-1][:2] == ("HEAD", "/dav/work/meeting-42-resource.ics")


def test_put_without_etag_creates_resource(client):
    StubCalDAV.requests.clear()
    ics = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:new-evt\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    resp = call_tool(client, "put", {"profile": "work", "id": "new-evt", "ics": ics})
    assert resp["result"]["isError"] is False
    # no resolve REPORT: PUT straight to <base>/<id>.ics
    assert [(m, p) for (m, p, _h, _b) in StubCalDAV.requests] == [
        ("PUT", "/dav/work/new-evt.ics")
    ]
    method, path, headers, body = StubCalDAV.requests[-1]
    assert body.decode() == ics
    assert headers["Content-Type"] == "text/calendar; charset=utf-8"
    assert "If-Match" not in headers


def test_put_with_etag_resolves_and_sends_if_match(client):
    StubCalDAV.requests.clear()
    ics = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:edit-me\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    resp = call_tool(
        client, "put", {"profile": "work", "id": "edit-me", "ics": ics, "etag": '"etag-head"'}
    )
    assert resp["result"]["isError"] is False
    kinds = [(m, p) for (m, p, _h, _b) in StubCalDAV.requests]
    assert kinds[0] == ("REPORT", "/dav/work")
    assert kinds[-1] == ("PUT", "/dav/work/edit-me-resource.ics")
    put_headers = StubCalDAV.requests[-1][2]
    assert put_headers["If-Match"] == '"etag-head"'


def test_delete_resolves_and_deletes(client):
    StubCalDAV.requests.clear()
    resp = call_tool(client, "delete", {"profile": "work", "id": "meeting-42"})
    assert resp["result"]["isError"] is False
    kinds = [(m, p) for (m, p, _h, _b) in StubCalDAV.requests]
    assert kinds[0] == ("REPORT", "/dav/work")
    assert kinds[-1] == ("DELETE", "/dav/work/meeting-42-resource.ics")


def test_multi_profile_isolation(client):
    StubCalDAV.requests.clear()
    call_tool(client, "list", {"profile": "work", "start": "20260101T000000Z", "end": "20260201T000000Z"})
    call_tool(client, "list", {"profile": "home", "start": "20260101T000000Z", "end": "20260201T000000Z"})
    reqs = StubCalDAV.requests
    work = next(r for r in reqs if r[1] == "/dav/work")
    home = next(r for r in reqs if r[1] == "/dav/home")
    assert _decoded_auth(work[2]) == "alice:work-pass-123"
    assert _decoded_auth(home[2]) == "bob:home-pass-456"


def test_unknown_profile_is_error(client):
    resp = call_tool(client, "get", {"profile": "nope", "id": "x"})
    assert resp["result"]["isError"] is True
    assert "not provisioned" in _text(resp)


def test_missing_password_is_error(client, env, tmp_path):
    creds = tmp_path / "solo-creds"
    creds.mkdir()
    (creds / "config").write_text(f'[caldav.solo]\nurl = "http://127.0.0.1:{env["port"]}/dav/solo/"\nuser = "carol"\n')
    os.environ["CREDENTIALS_DIRECTORY"] = str(creds)
    try:
        resp = call_tool(client, "get", {"id": "whatever"})
    finally:
        os.environ["CREDENTIALS_DIRECTORY"] = env["creds"]
    result = resp["result"]
    assert result["isError"] is True
    assert "password" in _text(resp)


def test_secret_fingerprint(client):
    resp = call_tool(client, "secret_fingerprint", {"profile": "work"})
    expected = hashlib.sha256("work-pass-123".encode()).hexdigest()[:16]
    assert resp["result"]["content"] == [{"type": "text", "text": expected}]
    assert resp["result"]["isError"] is False


def test_secret_fingerprint_per_profile(client):
    work = _text(call_tool(client, "secret_fingerprint", {"profile": "work"}))
    home = _text(call_tool(client, "secret_fingerprint", {"profile": "home"}))
    assert work == hashlib.sha256("work-pass-123".encode()).hexdigest()[:16]
    assert home == hashlib.sha256("home-pass-456".encode()).hexdigest()[:16]
    assert work != home


def test_http_error_is_tool_error(client):
    # resolve falls back to <base>/missing-uid.ics, whose GET the stub 404s
    StubCalDAV.requests.clear()
    resp = call_tool(client, "get", {"profile": "work", "id": "missing-uid"})
    result = resp["result"]
    assert result["isError"] is True
    assert "404" in result["content"][0]["text"]


def test_unknown_method_is_jsonrpc_error(client):
    resp = client.rpc("frobnicate", id=9)
    assert resp["id"] == 9
    assert resp["error"]["code"] == -32601

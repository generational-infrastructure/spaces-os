import base64
import json
import os
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import integration_contacts
import pytest

WORK_PASS = "work-pass-123"
HOME_PASS = "home-pass-456"


class StubDAV(BaseHTTPRequestHandler):
    """Records requests and serves canned CardDAV responses."""

    requests = []  # (method, path, headers-dict, body-bytes)

    def _record(self, body=b""):
        StubDAV.requests.append((self.command, self.path, dict(self.headers), body))

    def _body(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        return self.rfile.read(n) if n else b""

    def _send(self, code, data=b"", ctype="application/xml; charset=utf-8", headers=None):
        self.send_response(code)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        if data:
            self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if data:
            self.wfile.write(data)

    def do_PROPFIND(self):
        self._record(self._body())
        base = self.path.rstrip("/")
        ms = (
            '<?xml version="1.0" encoding="utf-8"?>'
            '<d:multistatus xmlns:d="DAV:">'
            f"<d:response><d:href>{self.path}</d:href><d:propstat><d:prop>"
            "<d:resourcetype><d:collection/></d:resourcetype></d:prop>"
            "<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
            f'<d:response><d:href>{base}/alice.vcf</d:href><d:propstat><d:prop>'
            "<d:getcontenttype>text/vcard</d:getcontenttype><d:getetag>&quot;e1&quot;</d:getetag>"
            "</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
            f'<d:response><d:href>{base}/bob.vcf</d:href><d:propstat><d:prop>'
            "<d:getcontenttype>text/vcard</d:getcontenttype><d:getetag>&quot;e2&quot;</d:getetag>"
            "</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
            "</d:multistatus>"
        ).encode()
        self._send(207, ms)

    def do_REPORT(self):
        self._record(self._body())
        ms = (
            '<?xml version="1.0" encoding="utf-8"?>'
            '<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:carddav">'
            f'<d:response><d:href>{self.path.rstrip("/")}/alice.vcf</d:href>'
            "<d:propstat><d:prop><d:getetag>&quot;e1&quot;</d:getetag>"
            "<c:address-data>BEGIN:VCARD&#10;VERSION:3.0&#10;FN:Alice&#10;END:VCARD</c:address-data>"
            "</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
            "</d:multistatus>"
        ).encode()
        self._send(207, ms)

    def do_GET(self):
        self._record()
        vcf = b"BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Alice\r\nEND:VCARD\r\n"
        self._send(200, vcf, ctype="text/vcard; charset=utf-8")

    def do_PUT(self):
        self._record(self._body())
        self._send(201, headers={"ETag": '"new-etag"'})

    def do_DELETE(self):
        self._record()
        self._send(204)

    def log_message(self, *args):
        pass


@pytest.fixture(scope="module")
def env(tmp_path_factory):
    tmp = tmp_path_factory.mktemp("itc")

    stub = ThreadingHTTPServer(("127.0.0.1", 0), StubDAV)
    threading.Thread(target=stub.serve_forever, daemon=True).start()
    port = stub.server_address[1]

    creds = tmp / "creds"
    creds.mkdir()
    (creds / "config").write_text(
        f'[contacts.work]\nserver = "http://127.0.0.1:{port}/work/"\nuser = "workuser"\n\n'
        f'[contacts.home]\nserver = "http://127.0.0.1:{port}/home/"\nuser = "homeuser"\n'
    )
    (creds / "secrets").write_text(
        f'[contacts.work]\npassword = "{WORK_PASS}"\n\n'
        f'[contacts.home]\npassword = "{HOME_PASS}"\n'
    )

    sock_path = str(tmp / "contacts.sock")
    os.environ["SPACES_INTEGRATION_SOCKET"] = sock_path
    os.environ["CREDENTIALS_DIRECTORY"] = str(creds)
    os.environ.pop("LISTEN_FDS", None)

    threading.Thread(target=integration_contacts.main, daemon=True).start()
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


def _result(resp):
    return resp["result"]


def _text(resp):
    return resp["result"]["content"][0]["text"]


def _basic(headers):
    auth = headers.get("Authorization", "")
    assert auth.startswith("Basic "), auth
    return base64.b64decode(auth[6:]).decode()


def _last(method):
    for req in reversed(StubDAV.requests):
        if req[0] == method:
            return req
    raise AssertionError(f"no {method} request recorded")


# --- protocol / schema ---


def test_initialize_handshake(client):
    resp = client.rpc(
        "initialize",
        {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "t"}},
        id=1,
    )
    assert resp["id"] == 1
    assert resp["result"]["serverInfo"]["name"] == "integration-contacts"


def test_tools_list_shape(client):
    resp = client.rpc("tools/list")
    tools = {t["name"]: t for t in resp["result"]["tools"]}
    assert set(tools) == {"discover", "search", "get", "new", "edit", "delete"}
    for spec in tools.values():
        assert "profile" in spec["inputSchema"]["properties"]
        assert "profile" not in spec["inputSchema"]["required"]
    assert tools["get"]["inputSchema"]["required"] == ["path"]
    assert tools["new"]["inputSchema"]["required"] == ["vcard"]
    assert tools["edit"]["inputSchema"]["required"] == ["path", "vcard"]
    assert tools["delete"]["inputSchema"]["required"] == ["path"]
    assert tools["discover"]["inputSchema"]["required"] == []
    assert tools["search"]["inputSchema"]["required"] == []


def test_secret_fingerprint_not_listed(client):
    resp = client.rpc("tools/list")
    assert "secret_fingerprint" not in [t["name"] for t in resp["result"]["tools"]]


# --- tools ---


def test_discover_lists_hrefs_and_sends_basic_auth(client):
    StubDAV.requests.clear()
    resp = call_tool(client, "discover", {"profile": "work"})
    assert _result(resp)["isError"] is False
    hrefs = json.loads(_text(resp))
    assert hrefs == ["/work/alice.vcf", "/work/bob.vcf"]
    method, path, headers, body = _last("PROPFIND")
    assert path == "/work/"
    assert headers.get("Depth") == "1"
    assert _basic(headers) == f"workuser:{WORK_PASS}"
    assert b"propfind" in body.lower()


def test_search_builds_report_with_fn_and_email(client):
    StubDAV.requests.clear()
    resp = call_tool(client, "search", {"profile": "work", "query": "alice"})
    assert _result(resp)["isError"] is False
    assert "address-data" in _text(resp)
    _m, path, headers, body = _last("REPORT")
    text = body.decode()
    assert path == "/work/"
    assert headers.get("Depth") == "1"
    assert "addressbook-query" in text
    assert 'name="FN"' in text and 'name="EMAIL"' in text
    assert "alice" in text
    assert 'match-type="contains"' in text


def test_search_empty_query_has_no_filter(client):
    StubDAV.requests.clear()
    resp = call_tool(client, "search", {"profile": "work", "query": ""})
    assert _result(resp)["isError"] is False
    _m, _p, _h, body = _last("REPORT")
    text = body.decode()
    assert "addressbook-query" in text
    assert "prop-filter" not in text


def test_get_fetches_vcard(client):
    StubDAV.requests.clear()
    resp = call_tool(client, "get", {"profile": "work", "path": "alice.vcf"})
    assert _result(resp)["isError"] is False
    assert "BEGIN:VCARD" in _text(resp)
    _m, path, headers, _b = _last("GET")
    assert path == "/work/alice.vcf"  # bare name joined to the collection
    assert _basic(headers) == f"workuser:{WORK_PASS}"


def test_get_absolute_path_joins_origin(client):
    StubDAV.requests.clear()
    resp = call_tool(client, "get", {"profile": "work", "path": "/other/x.vcf"})
    assert _result(resp)["isError"] is False
    _m, path, _h, _b = _last("GET")
    assert path == "/other/x.vcf"


def test_new_puts_derived_name(client):
    StubDAV.requests.clear()
    vcard = "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:john-doe\r\nFN:John Doe\r\nEND:VCARD\r\n"
    resp = call_tool(client, "new", {"profile": "work", "vcard": vcard})
    assert _result(resp)["isError"] is False
    assert _text(resp).endswith("/work/john-doe.vcf")
    _m, path, headers, body = _last("PUT")
    assert path == "/work/john-doe.vcf"
    assert headers.get("If-None-Match") == "*"
    assert headers.get("Content-Type", "").startswith("text/vcard")
    assert body.decode() == vcard


def test_new_without_uid_falls_back_to_uuid(client):
    StubDAV.requests.clear()
    vcard = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:No UID\r\nEND:VCARD\r\n"
    resp = call_tool(client, "new", {"profile": "work", "vcard": vcard})
    assert _result(resp)["isError"] is False
    _m, path, _h, _b = _last("PUT")
    assert path.startswith("/work/") and path.endswith(".vcf")
    assert path != "/work/.vcf"


def test_edit_sends_if_match(client):
    StubDAV.requests.clear()
    vcard = "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:john-doe\r\nFN:Edited\r\nEND:VCARD\r\n"
    resp = call_tool(
        client, "edit", {"profile": "work", "path": "john-doe.vcf", "vcard": vcard, "etag": '"e1"'}
    )
    assert _result(resp)["isError"] is False
    _m, path, headers, body = _last("PUT")
    assert path == "/work/john-doe.vcf"
    assert headers.get("If-Match") == '"e1"'
    assert "If-None-Match" not in headers
    assert body.decode() == vcard


def test_edit_without_etag_has_no_if_match(client):
    StubDAV.requests.clear()
    vcard = "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:x\r\nFN:X\r\nEND:VCARD\r\n"
    resp = call_tool(client, "edit", {"profile": "work", "path": "x.vcf", "vcard": vcard})
    assert _result(resp)["isError"] is False
    _m, _p, headers, _b = _last("PUT")
    assert "If-Match" not in headers


def test_delete_removes(client):
    StubDAV.requests.clear()
    resp = call_tool(client, "delete", {"profile": "work", "path": "alice.vcf"})
    assert _result(resp)["isError"] is False
    _m, path, headers, _b = _last("DELETE")
    assert path == "/work/alice.vcf"
    assert _basic(headers) == f"workuser:{WORK_PASS}"


def test_multi_profile_isolation(client):
    StubDAV.requests.clear()
    call_tool(client, "discover", {"profile": "work"})
    call_tool(client, "discover", {"profile": "home"})
    propfinds = [r for r in StubDAV.requests if r[0] == "PROPFIND"]
    assert len(propfinds) == 2
    by_path = {r[1]: r for r in propfinds}
    assert _basic(by_path["/work/"][2]) == f"workuser:{WORK_PASS}"
    assert _basic(by_path["/home/"][2]) == f"homeuser:{HOME_PASS}"


def test_unknown_profile_is_error(client):
    resp = call_tool(client, "discover", {"profile": "nope"})
    assert _result(resp)["isError"] is True
    assert "nope" in _text(resp)


def test_no_profile_when_many_is_error(client):
    resp = call_tool(client, "discover", {})
    assert _result(resp)["isError"] is True
    assert "profile" in _text(resp).lower()


def test_missing_password_is_error_and_leaks_nothing(client, env, tmp_path):
    solo = tmp_path / "solo-creds"
    solo.mkdir()
    (solo / "config").write_text(
        f'[contacts.solo]\nserver = "http://127.0.0.1:{env["port"]}/solo/"\nuser = "solouser"\n'
    )
    os.environ["CREDENTIALS_DIRECTORY"] = str(solo)
    try:
        resp = call_tool(client, "get", {"path": "x.vcf"})
    finally:
        os.environ["CREDENTIALS_DIRECTORY"] = env["creds"]
    result = _result(resp)
    assert result["isError"] is True
    assert "password" in result["content"][0]["text"]


def test_secret_fingerprint(client):
    resp = call_tool(client, "secret_fingerprint", {"profile": "work"})
    assert _result(resp)["isError"] is False
    import hashlib

    expected = hashlib.sha256(WORK_PASS.encode()).hexdigest()[:16]
    assert _text(resp) == expected


def test_secret_fingerprint_differs_per_profile(client):
    a = _text(call_tool(client, "secret_fingerprint", {"profile": "work"}))
    b = _text(call_tool(client, "secret_fingerprint", {"profile": "home"}))
    assert a != b


def test_http_error_is_tool_error(client):
    StubDAV.requests.clear()
    # DELETE on a path the stub answers 204 for is fine; force an error by pointing
    # at a closed port via an absolute href the resolver passes through untouched.
    resp = call_tool(
        client, "get", {"profile": "work", "path": "http://127.0.0.1:1/nope.vcf"}
    )
    assert _result(resp)["isError"] is True


def test_unknown_method_is_jsonrpc_error(client):
    resp = client.rpc("frobnicate", id=9)
    assert resp["id"] == 9
    assert resp["error"]["code"] == -32601

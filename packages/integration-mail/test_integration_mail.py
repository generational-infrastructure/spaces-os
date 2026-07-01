import hashlib
import json
import os
import socket
import stat
import sys
import threading
import time
import tomllib

import integration_mail
import pytest

# Stub himalaya binary: records argv/stdin, copies its -c config aside, and
# prints canned output per subcommand. Shebang is pinned to this interpreter so
# it resolves regardless of PATH ordering.
_STUB_HIMALAYA = r'''#!__PY__
import os, sys, shutil
d = os.environ["MAIL_STUB_DIR"]
argv = sys.argv[1:]
with open(os.path.join(d, "last_argv"), "w") as f:
    f.write("\n".join(argv))
with open(os.path.join(d, "calls.log"), "a") as f:
    f.write("\x00".join(argv) + "\n")
if "-c" in argv:
    cfg = argv[argv.index("-c") + 1]
    if os.path.isfile(cfg):
        shutil.copy(cfg, os.path.join(d, "last_config"))
if "send" in argv:
    with open(os.path.join(d, "last_stdin"), "wb") as f:
        f.write(sys.stdin.buffer.read())
if "list" in argv:
    sys.stdout.write('[{"id": "1", "subject": "hello", "from": "a@b.test"}]')
elif "read" in argv:
    sys.stdout.write("From: a@b.test\nSubject: hi\n\nHello body")
elif "send" in argv:
    sys.stdout.write("Message sent!")
'''

# A resolvable auth command: prints the sealed-store password for argv[1] and
# nothing else. himalaya would call this via backend.auth.cmd (stubbed here).
_STUB_AUTHCMD = r'''#!__PY__
import os, sys, tomllib
with open(os.path.join(os.environ["CREDENTIALS_DIRECTORY"], "secrets"), "rb") as f:
    doc = tomllib.load(f)
for _skill, profs in doc.items():
    if isinstance(profs, dict) and sys.argv[1] in profs:
        print(profs[sys.argv[1]]["password"])
        break
'''

CONFIG_BLOB = """\
[mail.personal]
email = "me@personal.test"
imap_host = "imap.personal.test"
smtp_host = "smtp.personal.test"
display_name = "Personal Me"

[mail.work]
email = "me@work.test"
imap_host = "imap.work.test"
smtp_host = "smtp.work.test"
imap_port = "143"
smtp_port = "465"
imap_login = "work-login"
smtp_login = "work-sender"

[mail.custom]
email = "me@custom.test"
imap_host = "imap.custom.test"
smtp_host = "smtp.custom.test"
imap_port = "25"
imap_encryption = "tls"
smtp_port = "25"

[mail.nopass]
email = "me@nopass.test"
imap_host = "imap.nopass.test"
smtp_host = "smtp.nopass.test"
"""

SECRETS_BLOB = """\
[mail.personal]
password = "pw-personal-123"

[mail.work]
password = "pw-work-456"

[mail.custom]
password = "pw-custom-789"
"""


def _write_exec(path, text):
    path.write_text(text.replace("__PY__", sys.executable))
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


@pytest.fixture(scope="module")
def env(tmp_path_factory):
    tmp = tmp_path_factory.mktemp("itm")

    stub_dir = tmp / "stub"
    stub_dir.mkdir()
    bin_dir = tmp / "bin"
    bin_dir.mkdir()
    _write_exec(bin_dir / "himalaya", _STUB_HIMALAYA)
    authcmd = bin_dir / "mail-authcmd"
    _write_exec(authcmd, _STUB_AUTHCMD)

    creds = tmp / "creds"
    creds.mkdir()
    (creds / "config").write_text(CONFIG_BLOB)
    (creds / "secrets").write_text(SECRETS_BLOB)

    sock_path = str(tmp / "mail.sock")
    os.environ["SPACES_INTEGRATION_SOCKET"] = sock_path
    os.environ["CREDENTIALS_DIRECTORY"] = str(creds)
    os.environ["MAIL_STUB_DIR"] = str(stub_dir)
    os.environ["SPACES_MAIL_AUTHCMD"] = str(authcmd)
    os.environ["PATH"] = str(bin_dir) + os.pathsep + os.environ["PATH"]
    os.environ.pop("LISTEN_FDS", None)

    threading.Thread(target=integration_mail.main, daemon=True).start()
    deadline = time.monotonic() + 5
    while not os.path.exists(sock_path):
        assert time.monotonic() < deadline, "server socket never appeared"
        time.sleep(0.01)

    yield {
        "sock": sock_path,
        "creds": str(creds),
        "stub": str(stub_dir),
        "authcmd": str(authcmd),
    }


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


def _text(resp):
    return resp["result"]["content"][0]["text"]


def _argv(env):
    return (open(os.path.join(env["stub"], "last_argv")).read()).split("\n")


def _last_config(env):
    with open(os.path.join(env["stub"], "last_config"), "rb") as f:
        return tomllib.load(f)


# --- protocol / shape -------------------------------------------------------


def test_initialize_handshake(client):
    resp = client.rpc(
        "initialize",
        {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {}},
    )
    assert resp["result"]["serverInfo"]["name"] == "integration-mail"


def test_tools_list_shape(client):
    resp = client.rpc("tools/list")
    tools = {t["name"]: t for t in resp["result"]["tools"]}
    assert set(tools) == {"envelope_list", "message_read", "message_send"}
    for t in tools.values():
        assert "profile" in t["inputSchema"]["properties"]
        assert "profile" not in t["inputSchema"]["required"]
    assert tools["message_read"]["inputSchema"]["required"] == ["id"]
    assert tools["message_send"]["inputSchema"]["required"] == ["message"]
    assert "secret_fingerprint" not in tools


def test_unknown_method_is_jsonrpc_error(client):
    resp = client.rpc("frobnicate", id=9)
    assert resp["error"]["code"] == -32601


# --- envelope_list ----------------------------------------------------------


def test_envelope_list_passes_json_and_returns_output(client, env):
    resp = call_tool(client, "envelope_list", {"profile": "personal"})
    assert resp["result"]["isError"] is False
    assert json.loads(_text(resp))[0]["subject"] == "hello"
    argv = _argv(env)
    assert argv[argv.index("-o") + 1] == "json"
    assert "envelope" in argv and "list" in argv
    assert argv[argv.index("-a") + 1] == "personal"


def test_envelope_list_folder_flag(client, env):
    call_tool(client, "envelope_list", {"profile": "personal", "folder": "Archive"})
    argv = _argv(env)
    assert argv[argv.index("-f") + 1] == "Archive"


# --- config generation (mail.sh parity) -------------------------------------


def test_config_generation_defaults_and_authcmd(client, env):
    call_tool(client, "envelope_list", {"profile": "personal"})
    acc = _last_config(env)["accounts"]["personal"]
    assert acc["default"] is True
    assert acc["email"] == "me@personal.test"
    assert acc["display-name"] == "Personal Me"
    assert acc["backend"]["type"] == "imap"
    assert acc["backend"]["host"] == "imap.personal.test"
    assert acc["backend"]["port"] == 993
    assert acc["backend"]["encryption"]["type"] == "tls"
    assert acc["backend"]["login"] == "me@personal.test"
    assert acc["backend"]["auth"]["type"] == "password"
    assert acc["backend"]["auth"]["cmd"] == f"{env['authcmd']} personal"
    send = acc["message"]["send"]["backend"]
    assert send["type"] == "smtp"
    assert send["host"] == "smtp.personal.test"
    assert send["port"] == 587
    assert send["encryption"]["type"] == "start-tls"
    assert send["login"] == "me@personal.test"
    assert send["auth"]["cmd"] == f"{env['authcmd']} personal"


def test_config_generation_custom_ports_logins(client, env):
    call_tool(client, "envelope_list", {"profile": "work"})
    acc = _last_config(env)["accounts"]["work"]
    assert acc["backend"]["port"] == 143
    assert acc["backend"]["encryption"]["type"] == "start-tls"
    assert acc["backend"]["login"] == "work-login"
    send = acc["message"]["send"]["backend"]
    assert send["port"] == 465
    assert send["encryption"]["type"] == "tls"
    assert send["login"] == "work-sender"
    assert "display-name" not in acc


def test_explicit_encryption_overrides_port_mapping(client, env):
    call_tool(client, "envelope_list", {"profile": "custom"})
    acc = _last_config(env)["accounts"]["custom"]
    # port 25 maps to none, but imap_encryption is pinned to tls
    assert acc["backend"]["encryption"]["type"] == "tls"
    # smtp port 25 with no pin -> none
    assert acc["message"]["send"]["backend"]["encryption"]["type"] == "none"


def test_multi_profile_writes_distinct_accounts(client, env):
    call_tool(client, "envelope_list", {"profile": "personal"})
    p = _last_config(env)["accounts"]
    assert list(p) == ["personal"]
    assert p["personal"]["backend"]["host"] == "imap.personal.test"
    call_tool(client, "envelope_list", {"profile": "work"})
    w = _last_config(env)["accounts"]
    assert list(w) == ["work"]
    assert w["work"]["backend"]["host"] == "imap.work.test"


# --- message_read / message_send --------------------------------------------


def test_message_read_passes_id(client, env):
    resp = call_tool(client, "message_read", {"profile": "personal", "id": "42"})
    assert resp["result"]["isError"] is False
    assert "Hello body" in _text(resp)
    argv = _argv(env)
    assert argv[argv.index("read") + 1] == "-a"
    assert "42" in argv


def test_message_read_missing_id_is_error(client):
    resp = call_tool(client, "message_read", {"profile": "personal"})
    assert resp["result"]["isError"] is True


def test_message_send_passes_body_on_stdin(client, env):
    raw = "From: me@personal.test\r\nTo: you@x.test\r\nSubject: Hi\r\n\r\nBody here"
    resp = call_tool(client, "message_send", {"profile": "personal", "message": raw})
    assert resp["result"]["isError"] is False
    assert _text(resp) == "Message sent!"
    argv = _argv(env)
    assert "message" in argv and "send" in argv
    assert open(os.path.join(env["stub"], "last_stdin"), "rb").read() == raw.encode()


def test_message_send_missing_message_is_error(client):
    resp = call_tool(client, "message_send", {"profile": "personal"})
    assert resp["result"]["isError"] is True


# --- error paths ------------------------------------------------------------


def test_missing_password_is_error(client):
    resp = call_tool(client, "envelope_list", {"profile": "nopass"})
    assert resp["result"]["isError"] is True
    assert "password" in _text(resp)


def test_absent_profile_is_error(client):
    resp = call_tool(client, "envelope_list", {"profile": "ghost"})
    assert resp["result"]["isError"] is True


def test_unknown_tool_is_error(client):
    resp = call_tool(client, "nope", {"profile": "personal"})
    assert resp["result"]["isError"] is True


# --- secret_fingerprint (registered in impls only) --------------------------


def test_secret_fingerprint(client):
    resp = call_tool(client, "secret_fingerprint", {"profile": "personal"})
    assert resp["result"]["isError"] is False
    assert _text(resp) == hashlib.sha256(b"pw-personal-123").hexdigest()[:16]


# --- unit: pure helpers + authcmd -------------------------------------------


def test_enc_for_port_mapping():
    assert integration_mail._enc_for_port(993) == "tls"
    assert integration_mail._enc_for_port("465") == "tls"
    assert integration_mail._enc_for_port(587) == "start-tls"
    assert integration_mail._enc_for_port("143") == "start-tls"
    assert integration_mail._enc_for_port(25) == "none"
    assert integration_mail._enc_for_port(12345) == "tls"


def test_toml_escape():
    assert integration_mail._toml_escape('a"b\\c') == 'a\\"b\\\\c'


def test_authcmd_prints_stored_password(env, capsys, monkeypatch):
    monkeypatch.setattr(sys, "argv", ["integration-mail-authcmd", "work"])
    integration_mail.authcmd()
    assert capsys.readouterr().out.strip() == "pw-work-456"

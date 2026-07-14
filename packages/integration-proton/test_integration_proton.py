import hashlib
import json
import os
import socket
import sys
import threading
import time
import tomllib

import integration_proton
import pytest
from conftest import _write_exec

# The autouse _probe_ok fixture replaces integration_proton.bridge_probe for the
# server-driven tests; the probe unit tests below exercise the real function
# captured here at import time (before any fixture runs).
_REAL_PROBE = integration_proton.bridge_probe

# Stub himalaya: records argv/stdin, copies the -c config aside, and (proton
# specific) resolves the msmtprc the config's sendmail cmd points at, copies it
# aside, and records its mode while it still exists. Canned output per subcommand.
_STUB_HIMALAYA = r"""#!__PY__
import os, sys, shutil, tomllib
d = os.environ["PROTON_STUB_DIR"]
argv = sys.argv[1:]
with open(os.path.join(d, "last_argv"), "w") as f:
    f.write("\n".join(argv))
with open(os.path.join(d, "calls.log"), "a") as f:
    f.write("\x00".join(argv) + "\n")
if "-c" in argv:
    cfg = argv[argv.index("-c") + 1]
    if os.path.isfile(cfg):
        shutil.copy(cfg, os.path.join(d, "last_config"))
        with open(cfg, "rb") as f:
            doc = tomllib.load(f)
        for acc in doc.get("accounts", {}).values():
            cmd = acc.get("message", {}).get("send", {}).get("backend", {}).get("cmd", "")
            parts = cmd.split()
            if "-C" in parts:
                rc = parts[parts.index("-C") + 1]
                with open(os.path.join(d, "last_msmtprc_path"), "w") as f:
                    f.write(rc)
                if os.path.isfile(rc):
                    with open(os.path.join(d, "last_msmtprc_mode"), "w") as f:
                        f.write(oct(os.stat(rc).st_mode & 0o777))
                    shutil.copy(rc, os.path.join(d, "last_msmtprc"))
if "send" in argv:
    with open(os.path.join(d, "last_stdin"), "wb") as f:
        f.write(sys.stdin.buffer.read())
if "list" in argv:
    sys.stdout.write('[{"id": "1", "subject": "hello", "from": "a@b.test"}]')
elif "read" in argv:
    sys.stdout.write("From: a@b.test\nSubject: hi\n\nHello body")
elif "send" in argv:
    sys.stdout.write("Message sent!")
"""

# Resolvable auth command: prints the sealed-store bridge_password for argv[1].
_STUB_AUTHCMD = r"""#!__PY__
import os, sys, tomllib
with open(os.path.join(os.environ["CREDENTIALS_DIRECTORY"], "secrets"), "rb") as f:
    doc = tomllib.load(f)
for _skill, profs in doc.items():
    if isinstance(profs, dict) and sys.argv[1] in profs:
        print(profs[sys.argv[1]]["bridge_password"])
        break
"""

CONFIG_BLOB = """\
[proton.personal]
email = "me@personal.test"

[proton.work]
email = "me@work.test"

[proton.nopass]
email = "me@nopass.test"
"""

SECRETS_BLOB = """\
[proton.personal]
bridge_password = "bp-personal-123"

[proton.work]
bridge_password = "bp-work-456"
"""


@pytest.fixture(scope="module")
def env(tmp_path_factory):
    tmp = tmp_path_factory.mktemp("itp")

    stub_dir = tmp / "stub"
    stub_dir.mkdir()
    bin_dir = tmp / "bin"
    bin_dir.mkdir()
    _write_exec(bin_dir / "himalaya", _STUB_HIMALAYA)
    authcmd = bin_dir / "proton-authcmd"
    _write_exec(authcmd, _STUB_AUTHCMD)

    creds = tmp / "creds"
    creds.mkdir()
    (creds / "config").write_text(CONFIG_BLOB)
    (creds / "secrets").write_text(SECRETS_BLOB)

    # Bridge state root with the serving cert in place (the probe is monkeypatched
    # per test; the cert path is asserted against generated configs).
    state = tmp / "state"
    cert = state / "config/protonmail/bridge-v3/cert.pem"
    cert.parent.mkdir(parents=True)
    cert.write_text("-----BEGIN CERTIFICATE-----\nstub\n-----END CERTIFICATE-----\n")

    sock_path = str(tmp / "proton.sock")
    os.environ["SPACES_INTEGRATION_SOCKET"] = sock_path
    os.environ["CREDENTIALS_DIRECTORY"] = str(creds)
    os.environ["PROTON_STUB_DIR"] = str(stub_dir)
    os.environ["SPACES_PROTON_AUTHCMD"] = str(authcmd)
    os.environ["SPACES_PROTON_BRIDGE_STATE"] = str(state)
    os.environ["PATH"] = str(bin_dir) + os.pathsep + os.environ["PATH"]
    os.environ.pop("LISTEN_FDS", None)

    threading.Thread(target=integration_proton.main, daemon=True).start()
    deadline = time.monotonic() + 5
    while not os.path.exists(sock_path):
        assert time.monotonic() < deadline, "server socket never appeared"
        time.sleep(0.01)

    return {
        "sock": sock_path,
        "creds": str(creds),
        "stub": str(stub_dir),
        "authcmd": str(authcmd),
        "cert": str(cert),
    }


@pytest.fixture(autouse=True)
def _probe_ok(monkeypatch):
    # Default: Bridge is healthy so tools reach himalaya. Probe-specific tests
    # override this after the autouse ran.
    monkeypatch.setattr(integration_proton, "bridge_probe", lambda profile, vals: None)


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

    def rpc(self, method, params=None, req_id=1):
        msg = {"jsonrpc": "2.0", "id": req_id, "method": method}
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
    return client.rpc("tools/call", {"name": name, "arguments": arguments}, req_id=2)


def _text(resp):
    return resp["result"]["content"][0]["text"]


def _argv(env):
    return open(os.path.join(env["stub"], "last_argv")).read().split("\n")


def _last_config(env):
    with open(os.path.join(env["stub"], "last_config"), "rb") as f:
        return tomllib.load(f)


def _calls(env):
    p = os.path.join(env["stub"], "calls.log")
    return open(p).read().splitlines() if os.path.exists(p) else []


# --- constants / protocol shape ---------------------------------------------


def test_transport_constants_pinned():
    assert integration_proton.BRIDGE_HOST == "127.0.0.1"
    assert integration_proton.IMAP_PORT == 1143
    assert integration_proton.SMTP_PORT == 1025
    assert integration_proton.ENCRYPTION == "start-tls"


def test_initialize_handshake(client):
    resp = client.rpc(
        "initialize", {"protocolVersion": "2025-03-26", "capabilities": {}}, req_id=1
    )
    assert resp["result"]["serverInfo"]["name"] == "integration-proton"


def test_tools_list_shape(client):
    resp = client.rpc("tools/list")
    names = {t["name"] for t in resp["result"]["tools"]}
    assert names == {"envelope_list", "message_read", "message_send"}
    assert "secret_fingerprint" not in names


# --- config generation pins -------------------------------------------------


def test_config_pins_bridge_transport(client, env):
    call_tool(client, "envelope_list", {"profile": "personal"})
    acc = _last_config(env)["accounts"]["personal"]
    assert acc["email"] == "me@personal.test"
    assert acc["backend"]["type"] == "imap"
    assert acc["backend"]["host"] == "127.0.0.1"
    assert acc["backend"]["port"] == 1143
    assert acc["backend"]["encryption"]["type"] == "start-tls"
    assert acc["backend"]["encryption"]["cert"] == env["cert"]
    assert acc["backend"]["login"] == "me@personal.test"
    assert acc["backend"]["auth"]["cmd"] == f"{env['authcmd']} personal"


def test_config_send_backend_is_msmtp_sendmail(client, env):
    call_tool(client, "envelope_list", {"profile": "personal"})
    send = _last_config(env)["accounts"]["personal"]["message"]["send"]["backend"]
    assert send["type"] == "sendmail"
    assert send["cmd"].startswith("msmtp -C ")
    assert send["cmd"].endswith(" -a personal -t")


def test_msmtprc_pins_and_trust_file(client, env):
    call_tool(client, "envelope_list", {"profile": "personal"})
    with open(os.path.join(env["stub"], "last_msmtprc")) as f:
        rc = f.read().splitlines()
    assert "account personal" in rc
    assert "host 127.0.0.1" in rc
    assert "port 1025" in rc
    assert "auth on" in rc
    assert "tls on" in rc
    assert "tls_starttls on" in rc
    assert f"tls_trust_file {env['cert']}" in rc
    assert "user me@personal.test" in rc
    assert f'passwordeval "{env["authcmd"]} personal"' in rc


def test_msmtprc_is_0600(client, env):
    call_tool(client, "envelope_list", {"profile": "personal"})
    with open(os.path.join(env["stub"], "last_msmtprc_mode")) as f:
        mode = f.read().strip()
    assert mode == "0o600"


def test_msmtprc_dir_cleaned_up_after_call(client, env):
    call_tool(client, "envelope_list", {"profile": "personal"})
    with open(os.path.join(env["stub"], "last_msmtprc_path")) as f:
        path = f.read().strip()
    assert path
    assert not os.path.exists(path), "per-call msmtprc tempdir must be removed"
    assert not os.path.exists(os.path.dirname(path))


# --- probe gating -----------------------------------------------------------


def test_probe_failure_yields_onboarding_hint_and_skips_himalaya(
    client, env, monkeypatch
):
    monkeypatch.setattr(
        integration_proton,
        "bridge_probe",
        lambda p, v: integration_proton._ONBOARDING_HINT,
    )
    before = len(_calls(env))
    resp = call_tool(client, "envelope_list", {"profile": "personal"})
    assert resp["result"]["isError"] is True
    assert "Set up" in _text(resp)
    assert len(_calls(env)) == before, (
        "himalaya must not be spawned when the probe fails"
    )


def test_probe_success_passes_through_to_himalaya(client, env, monkeypatch):
    monkeypatch.setattr(integration_proton, "bridge_probe", lambda p, v: None)
    resp = call_tool(client, "envelope_list", {"profile": "personal"})
    assert resp["result"]["isError"] is False
    argv = _argv(env)
    assert "list" in argv
    assert argv[argv.index("-a") + 1] == "personal"


# --- tool bodies ------------------------------------------------------------


def test_envelope_list_folder_flag(client, env):
    call_tool(client, "envelope_list", {"profile": "personal", "folder": "Archive"})
    argv = _argv(env)
    assert argv[argv.index("-f") + 1] == "Archive"


def test_message_read_passes_id(client, env):
    resp = call_tool(client, "message_read", {"profile": "personal", "id": "42"})
    assert resp["result"]["isError"] is False
    assert "42" in _argv(env)


def test_message_read_missing_id_is_error(client):
    resp = call_tool(client, "message_read", {"profile": "personal"})
    assert resp["result"]["isError"] is True


def test_message_send_passes_body_on_stdin(client, env):
    raw = "From: me@personal.test\r\nTo: you@x.test\r\nSubject: Hi\r\n\r\nBody"
    resp = call_tool(client, "message_send", {"profile": "personal", "message": raw})
    assert resp["result"]["isError"] is False
    with open(os.path.join(env["stub"], "last_stdin"), "rb") as f:
        assert f.read() == raw.encode()


def test_message_send_missing_message_is_error(client):
    resp = call_tool(client, "message_send", {"profile": "personal"})
    assert resp["result"]["isError"] is True


# --- error paths ------------------------------------------------------------


def test_missing_bridge_password_is_error(client):
    resp = call_tool(client, "envelope_list", {"profile": "nopass"})
    assert resp["result"]["isError"] is True
    assert "bridge_password" in _text(resp)


def test_unknown_tool_is_error(client):
    resp = call_tool(client, "nope", {"profile": "personal"})
    assert resp["result"]["isError"] is True


def test_secret_fingerprint_hidden_but_callable(client):
    resp = call_tool(client, "secret_fingerprint", {"profile": "personal"})
    assert resp["result"]["isError"] is False
    assert _text(resp) == hashlib.sha256(b"bp-personal-123").hexdigest()[:16]


# --- unit: probe + authcmd --------------------------------------------------


def test_bridge_probe_missing_cert_returns_hint(monkeypatch, tmp_path):
    monkeypatch.setenv("SPACES_PROTON_BRIDGE_STATE", str(tmp_path))  # no cert.pem
    assert _REAL_PROBE("p", {}) == integration_proton._ONBOARDING_HINT


def test_bridge_probe_cert_and_port_open_returns_none(monkeypatch, tmp_path):
    cert = tmp_path / "config/protonmail/bridge-v3/cert.pem"
    cert.parent.mkdir(parents=True)
    cert.write_text("x")
    monkeypatch.setenv("SPACES_PROTON_BRIDGE_STATE", str(tmp_path))
    lsock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    lsock.bind(("127.0.0.1", 0))
    lsock.listen(1)
    monkeypatch.setattr(integration_proton, "IMAP_PORT", lsock.getsockname()[1])
    try:
        assert _REAL_PROBE("p", {}) is None
    finally:
        lsock.close()


def test_bridge_probe_cert_but_port_closed_returns_hint(monkeypatch, tmp_path):
    cert = tmp_path / "config/protonmail/bridge-v3/cert.pem"
    cert.parent.mkdir(parents=True)
    cert.write_text("x")
    monkeypatch.setenv("SPACES_PROTON_BRIDGE_STATE", str(tmp_path))
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    closed_port = s.getsockname()[1]
    s.close()  # nothing listens here now
    monkeypatch.setattr(integration_proton, "IMAP_PORT", closed_port)
    monkeypatch.setattr(integration_proton, "_PROBE_TIMEOUT", 0.3)
    assert _REAL_PROBE("p", {}) == integration_proton._ONBOARDING_HINT


def test_authcmd_prints_bridge_password(env, capsys, monkeypatch):
    monkeypatch.setattr(sys, "argv", ["integration-proton-authcmd", "work"])
    integration_proton.authcmd()
    assert capsys.readouterr().out.strip() == "bp-work-456"

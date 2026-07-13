"""Contract tests for the integration-proton setup helper.

No network, no real Bridge: a fake `protonmail-bridge` executable on PATH starts
an in-process grpcio server that implements only the RPCs the helper uses, over
a unix socket with self-signed TLS and server-token validation, and writes a
real grpcServerConfig.json into the pinned XDG tree. The broker side is played
by a driver that sends the action line, answers prompts, and records events.
"""

import base64
import contextlib
import json
import os
import socket
import subprocess
import threading
import time

from conftest import _write_exec
import grpc
import integration_proton_setup as setup
import pytest

# Throwaway self-signed localhost cert (CN + SAN = 127.0.0.1, matching Bridge's
# internal/certs/tls.go). Private key is a test artifact, never a real secret.
CERT_PEM = """\
-----BEGIN CERTIFICATE-----
MIIDijCCAnKgAwIBAgIUJxPdlSl3aX6BkwXIvY/IphGlpHYwDQYJKoZIhvcNAQEL
BQAwSzELMAkGA1UEBhMCQ0gxEjAQBgNVBAoMCVByb3RvbiBBRzEUMBIGA1UECwwL
UHJvdG9uIE1haWwxEjAQBgNVBAMMCTEyNy4wLjAuMTAgFw0yNjA3MDgxMDU3NTBa
GA8yMTI2MDYxNDEwNTc1MFowSzELMAkGA1UEBhMCQ0gxEjAQBgNVBAoMCVByb3Rv
biBBRzEUMBIGA1UECwwLUHJvdG9uIE1haWwxEjAQBgNVBAMMCTEyNy4wLjAuMTCC
ASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALs9fiZQdu1xMaFso6vUn9A2
OfM0RD4gpol/3Kjsk9olGX41m9fXUdxRbx6Vh6u8jiN5Ey6O9L3dvGx1ZRM1ZuZZ
9UTmYSFxQWDCBTiuy/4IZBtgpXF/o/a62RppnZH0gQifSDOFBujAVxrJkkIrQbLm
EaDIBn6rUHwtZndEBMQkdYJgNsdMgFZLUa1s0eRpqvtNNoKKKoYPs5lzQlufCLVm
HtJtKZ/jYMM/gC7yIz6SPHRlV/mAtGAXqBHIeuoTsPPaurtLfdAk2o68yeaLdDw8
vVSxmnUnELDgRJJ8vXwwWy6em74hR+wMhWHfbfqf0GquYw5/B8xbhlaYsi0hm+0C
AwEAAaNkMGIwHQYDVR0OBBYEFFfTBaT1d/naeNQt42hRn9EDdY2sMB8GA1UdIwQY
MBaAFFfTBaT1d/naeNQt42hRn9EDdY2sMA8GA1UdEwEB/wQFMAMBAf8wDwYDVR0R
BAgwBocEfwAAATANBgkqhkiG9w0BAQsFAAOCAQEAKsr8E72/42GyD6VoaLThvvBi
RtwQapOG5BBqhgeAB/plhRq2YtLKwpWiEtxXORDb/aPhlJnp8UalUaAJkJqSYh+K
/9HsZ6y9qRsdG4RLiCZFs40EaEBlUoBUaqiUEZG6f8U/24185yX/sqhysHNhIrWH
+nMh4KIS4D2eNdkDzX5GBt57QqpX7TrM2CdjU4nbd+SiQd8SRFq87NsYOGfnUD2e
s0ExWCUkDO1NytSMVT9+MKwv5Y+0QI5n4Dyv7TfvYl0WwJ3cjka2zPS3vQL+CLRZ
7OKtyE+2DZUmgPkviVJ1sqKdkbDw15ncQrwLENoiWV1GCTFX+bQMTsevdAdvFg==
-----END CERTIFICATE-----
"""

KEY_PEM = """\
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQC7PX4mUHbtcTGh
bKOr1J/QNjnzNEQ+IKaJf9yo7JPaJRl+NZvX11HcUW8elYervI4jeRMujvS93bxs
dWUTNWbmWfVE5mEhcUFgwgU4rsv+CGQbYKVxf6P2utkaaZ2R9IEIn0gzhQbowFca
yZJCK0Gy5hGgyAZ+q1B8LWZ3RATEJHWCYDbHTIBWS1GtbNHkaar7TTaCiiqGD7OZ
c0Jbnwi1Zh7SbSmf42DDP4Au8iM+kjx0ZVf5gLRgF6gRyHrqE7Dz2rq7S33QJNqO
vMnmi3Q8PL1UsZp1JxCw4ESSfL18MFsunpu+IUfsDIVh3236n9BqrmMOfwfMW4ZW
mLItIZvtAgMBAAECggEAM3tjaZ57LKsQZd2MnQzPyjx2r4+h6eEpWSoOXmX5+yNz
QHf1+yFJcUX0wxiDHq2v+UHri8Qjt+a1Ta7zlRX8Tn7SiNi9QSg2PSfrrpulHBpr
h/mJU80wJIFYe0Ip4H01U00UWZIMhceIy6U7sTTakhlfJHGLE53/+byz7TwHAXS5
iEcV7Pg4mIbZiVuZAIjAvVjDaSlcl5CyEstOj240slvdtsw0o6FobteHOyIeDMva
9xAqm43uRqc6vNhDWGziTJC0CrCz4CmS3Cj404ECvQ6rIGBn5rpRRGGHXrsafFSF
vzJTivBFUBiVio37gp+XDRFFvb/uOMJSsOQkwKF6UwKBgQD3sGPPRUq6RTQxhirJ
K+jclRdIO28OQSz/oJKFE0mYtZMZoWXmmNz8l38MKWkK2NWOw1is183nNRifpcF3
Vh5FW156MT/1zML6+G7V+0G+GGdm6EPv1LtHLp4bZ4fVzyqeLV60ZXIa6MTh/Il5
csaGqvymgKf+wlacfM5pTdvJ1wKBgQDBhdtif8gOuV0qFLr28GHRN8hfApF6Z5MW
Aa5Du43xgDJDCBI6+0oZo2jLyDMevCFPEXK05Uwsd1f57+NaJQV4iByo8I0MBJVh
Q4YQGUN4ozwDzZakZSIBCI0phsEle89RZGJEQV3NeUiCkakmRGv2yvodr5QqBlMk
5Cutc9932wKBgEmdXSy/NWSDKO4HKDQ+HqlgjljjgTBFYrBe8u0mPFtsq9mURIry
p8tS42mj7RpSM7aIjJRiV0n+V+ErDIMBT2HhtASxGoddYh3hNF/Ym0N6UVEeewKO
wVJ4onkWniKHvezhIyKOfAlPYSShP+KeoC5qJ0j9N/DZpZBA78AQaeBlAoGBAJq1
D/VmgeCDf18sw2q2MPy4w45w1ywrsQJexZmQTqFKAuRjh29vhIWKhTSkD3n6nAZB
xJmo1YSWw9YjWHWwMvdwmLjV1WxOHb1r5bjo+W9vz4Ka0FsMHmsFExSnjbERkWNY
BNbcCslAtB7to3PcLxNUoS8qNiCCfeV4IxK/F18RAoGBAPQ/UqjbYZ1i093gVEu5
7k0/YIqlHpMstgs/g+Z1NkQVpcLoQHOmi1KWxvieOm5tz1QMY+8ED3rFn2ZRlEuz
gSEZ3aGq/Gul3/Daga5/iX4O9Z6hB2EjMCnGqk+4qVKTl225fflvZ6LsFTWqnDMJ
pfPgsS2VvhGBWoVA9TnUP7Tf
-----END PRIVATE KEY-----
"""

TOKEN = "test-server-token-0001"

# Fake `protonmail-bridge`: on --grpc it serves the RPCs the helper uses over a
# unix socket with TLS + token validation, writes a real grpcServerConfig.json
# (temp+rename) into the pinned XDG tree, and records observable calls to
# PROTON_FAKE_RECORD so tests can assert the flow.
_FAKE_BRIDGE = r"""#!__PY__
import json, os, queue, sys, tempfile, threading, time
from concurrent import futures

sys.path.insert(0, os.environ["PROTON_FAKE_PKGDIR"])
import grpc
import bridge_pb2 as pb
import bridge_pb2_grpc as pbg
from google.protobuf.empty_pb2 import Empty

SCEN = json.load(open(os.environ["PROTON_FAKE_SCENARIO"]))
RECORD = os.environ["PROTON_FAKE_RECORD"]
TOKEN = os.environ["PROTON_FAKE_TOKEN"]
CERT = open(os.environ["PROTON_FAKE_CERT"], "rb").read()
KEY = open(os.environ["PROTON_FAKE_KEY"], "rb").read()

_rec = {"calls": [], "login_calls": [], "settings": None, "removed": [], "wire_passwords": [], "export_dirs": []}
_lock = threading.RLock()


def record():
    with _lock:
        tmp = RECORD + ".tmp"
        with open(tmp, "w") as f:
            json.dump(_rec, f)
        os.replace(tmp, RECORD)


def mk_user(d):
    return pb.User(
        id=d["id"],
        username=d.get("username", ""),
        addresses=d.get("addresses", []),
        state=d.get("state", 0),
        password=d.get("password", "").encode("utf-8"),
    )


def mk_event(d):
    t = d["type"]
    L = pb.LoginEvent
    if t == "finished":
        return pb.StreamEvent(login=L(finished=pb.LoginFinishedEvent(userID=d.get("userID", ""))))
    if t == "alreadyLoggedIn":
        return pb.StreamEvent(login=L(alreadyLoggedIn=pb.LoginFinishedEvent(userID=d.get("userID", ""))))
    if t == "tfaRequested":
        return pb.StreamEvent(login=L(tfaRequested=pb.LoginTfaRequestedEvent(username=d.get("username", ""))))
    if t == "tfaOrFidoRequested":
        return pb.StreamEvent(login=L(tfaOrFidoRequested=pb.LoginTfaOrFidoRequestedEvent(username=d.get("username", ""))))
    if t == "twoPasswordRequested":
        return pb.StreamEvent(login=L(twoPasswordRequested=pb.LoginTwoPasswordsRequestedEvent(username=d.get("username", ""))))
    if t == "fidoRequested":
        return pb.StreamEvent(login=L(fidoRequested=pb.LoginFidoRequestedEvent(username=d.get("username", ""))))
    if t == "error":
        return pb.StreamEvent(login=L(error=pb.LoginErrorEvent(type=d.get("errType", 0), message=d.get("message", ""))))
    raise SystemExit("unknown scripted event: " + t)


class Servicer(pbg.BridgeServicer):
    def __init__(self):
        self.q = queue.Queue()
        self.steps = list(SCEN.get("login_steps", []))
        self.i = 0
        self.stop = threading.Event()
        # Users load ASYNC after the gRPC server is up (bridge.goLoad); the
        # real Bridge queues allUsersLoaded until the first RunEventStream
        # subscriber. GetUserList before the load finishes returns [] — a
        # helper that does not await the event races to an empty list.
        self.users_loaded = threading.Event()
        delay = SCEN.get("users_load_delay_ms", 0) / 1000.0
        def load():
            if delay:
                time.sleep(delay)
            self.users_loaded.set()
            self.q.put(pb.StreamEvent(app=pb.AppEvent(allUsersLoaded=pb.AllUsersLoadedEvent())))
        threading.Thread(target=load, daemon=True).start()

    def _tok(self, context):
        md = dict(context.invocation_metadata())
        if md.get("server-token") != TOKEN:
            context.abort(grpc.StatusCode.UNAUTHENTICATED, "invalid server token")

    def _advance(self, call, request=None):
        with _lock:
            _rec["login_calls"].append(call)
            # Record the wire password so tests can assert the base64
            # contract: Bridge's Login/Login2FA/Login2Passwords all run
            # base64Decode() on it (service_methods.go) and fail login on
            # raw bytes.
            if request is not None:
                _rec["wire_passwords"].append(request.password.decode("utf-8"))
            record()
        if self.i < len(self.steps):
            step = self.steps[self.i]
            self.i += 1
            for e in step.get("emit", []):
                self.q.put(mk_event(e))

    def RunEventStream(self, request, context):
        self._tok(context)
        while True:
            item = self.q.get()
            if item is None:
                return
            yield item

    def GetUserList(self, request, context):
        self._tok(context)
        with _lock:
            _rec["calls"].append("GetUserList")
            record()
        users = SCEN.get("connected_users", []) if self.users_loaded.is_set() else []
        return pb.UserListResponse(users=[mk_user(u) for u in users])

    def GetUser(self, request, context):
        self._tok(context)
        with _lock:
            _rec["calls"].append("GetUser")
            record()
        return mk_user(SCEN["users_by_id"][request.value])

    def Login(self, request, context):
        self._tok(context)
        self._advance("Login", request)
        return Empty()

    def Login2FA(self, request, context):
        self._tok(context)
        self._advance("Login2FA", request)
        return Empty()

    def Login2Passwords(self, request, context):
        self._tok(context)
        self._advance("Login2Passwords", request)
        return Empty()

    def SetMailServerSettings(self, request, context):
        self._tok(context)
        with _lock:
            _rec["settings"] = {
                "imapPort": request.imapPort,
                "smtpPort": request.smtpPort,
                "useSSLForImap": request.useSSLForImap,
                "useSSLForSmtp": request.useSSLForSmtp,
            }
            _rec["calls"].append("SetMailServerSettings")
            record()
        self.q.put(pb.StreamEvent(mailServerSettings=pb.MailServerSettingsEvent(
            changeMailServerSettingsFinished=pb.ChangeMailServerSettingsFinishedEvent())))
        return Empty()

    def RemoveUser(self, request, context):
        self._tok(context)
        with _lock:
            _rec["removed"].append(request.value)
            _rec["calls"].append("RemoveUser")
            record()
        return Empty()

    def ExportTLSCertificates(self, request, context):
        self._tok(context)
        folder = request.value
        with _lock:
            _rec["calls"].append("ExportTLSCertificates")
            _rec["export_dirs"].append(folder)
            record()
        # The real Bridge exports in a fire-and-forget goroutine with no
        # success event (grpc/service_cert.go); delay the write so a helper
        # that fails to wait for cert.pem goes red.
        def write():
            time.sleep(0.3)
            os.makedirs(folder, exist_ok=True)
            with open(os.path.join(folder, "cert.pem"), "wb") as f:
                f.write(CERT)
            with open(os.path.join(folder, "key.pem"), "wb") as f:
                f.write(KEY)
        threading.Thread(target=write, daemon=True).start()
        return Empty()

    def Quit(self, request, context):
        self._tok(context)
        with _lock:
            _rec["calls"].append("Quit")
            record()
        self.q.put(None)
        self.stop.set()
        return Empty()


def main():
    if "--grpc" not in sys.argv[1:]:
        return 0
    svc = Servicer()
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=8))
    pbg.add_BridgeServicer_to_server(svc, server)
    creds = grpc.ssl_server_credentials([(KEY, CERT)])
    sockdir = tempfile.mkdtemp(prefix="pb")
    sockpath = os.path.join(sockdir, "b.sock")
    server.add_secure_port("unix:" + sockpath, creds)
    server.start()
    record()
    cfgdir = os.path.join(os.environ["XDG_CONFIG_HOME"], "protonmail", "bridge-v3")
    os.makedirs(cfgdir, exist_ok=True)
    cfg = {"port": 0, "cert": CERT.decode("utf-8"), "token": TOKEN, "fileSocketPath": sockpath}
    tmp = os.path.join(cfgdir, "grpcServerConfig.json.tmp")
    with open(tmp, "w") as f:
        json.dump(cfg, f)
    os.replace(tmp, os.path.join(cfgdir, "grpcServerConfig.json"))
    svc.stop.wait()
    server.stop(1).wait()
    return 0


sys.exit(main())
"""


@pytest.fixture(scope="module")
def bench(tmp_path_factory):
    tmp = tmp_path_factory.mktemp("itps")
    certdir = tmp / "tls"
    certdir.mkdir()
    (certdir / "cert.pem").write_text(CERT_PEM)
    (certdir / "key.pem").write_text(KEY_PEM)

    bin_dir = tmp / "bin"
    bin_dir.mkdir()
    _write_exec(bin_dir / "protonmail-bridge", _FAKE_BRIDGE)

    pkgdir = os.path.dirname(os.path.abspath(__file__))
    os.environ["PATH"] = str(bin_dir) + os.pathsep + os.environ["PATH"]
    os.environ["PROTON_FAKE_PKGDIR"] = pkgdir
    os.environ["PROTON_FAKE_CERT"] = str(certdir / "cert.pem")
    os.environ["PROTON_FAKE_KEY"] = str(certdir / "key.pem")
    os.environ["PROTON_FAKE_TOKEN"] = TOKEN
    # The fake subprocess reuses this interpreter; make grpc + bridge_pb2
    # importable regardless of how pytest arranged its own sys.path.
    os.environ["PYTHONPATH"] = pkgdir + os.pathsep + os.environ.get("PYTHONPATH", "")
    os.environ.pop("LISTEN_FDS", None)
    return {"bin": str(bin_dir), "pkgdir": pkgdir}


def _wait_path(path, timeout=10.0):
    deadline = time.monotonic() + timeout
    while not os.path.exists(path):
        assert time.monotonic() < deadline, f"path never appeared: {path}"
        time.sleep(0.01)


def _drive(activation, action, replies):
    """Play the broker: send the action line, answer prompts, collect events."""
    broker = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    broker.settimeout(20)
    broker.connect(activation)
    broker.sendall(json.dumps(action).encode("utf-8") + b"\n")
    events = []
    with broker, broker.makefile("rb") as reader:
        for line in reader:
            line = line.strip()
            if not line:
                continue
            ev = json.loads(line)
            events.append(ev)
            et = ev.get("event")
            if et in ("text-field", "secret-field"):
                broker.sendall(
                    json.dumps({"value": replies[ev["field"]]}).encode("utf-8") + b"\n"
                )
            elif et in ("done", "error"):
                break
    return events


def _run_helper(tmp_path, scenario, action, replies):
    run = tmp_path
    state = run / "state"
    (state / "config").mkdir(parents=True)
    scen_path = run / "scenario.json"
    scen_path.write_text(json.dumps(scenario))
    record = run / "record.json"

    os.environ["SPACES_PROTON_BRIDGE_STATE"] = str(state)
    os.environ["PROTON_FAKE_SCENARIO"] = str(scen_path)
    os.environ["PROTON_FAKE_RECORD"] = str(record)
    activation = str(run / "setup.sock")
    os.environ["SPACES_INTEGRATION_SOCKET"] = activation
    os.environ.pop("CREDENTIALS_DIRECTORY", None)

    rc = {}
    thread = threading.Thread(
        target=lambda: rc.__setitem__("code", setup.main()), daemon=True
    )
    thread.start()
    _wait_path(activation)

    events = _drive(activation, action, replies)

    thread.join(timeout=30.0)
    assert not thread.is_alive(), "helper did not exit"
    assert rc.get("code") == 0, "a flow failure must still exit 0"

    rec = json.loads(record.read_text()) if record.exists() else {}
    return events, rec


def _terminals(events):
    return [e for e in events if e.get("event") in ("done", "error")]


def _set_fields(events):
    return [e for e in events if e.get("event") == "set-field"]


_USER = {
    "id": "u1",
    "username": "me@proton.me",
    "addresses": ["me@proton.me"],
    "state": 2,  # CONNECTED
    "password": "BRIDGE-PW-1",
}

_REPLIES = {
    "email": "me@proton.me",
    "password": "hunter2",
    "totp": "123456",
    "mailbox_password": "second-pass",
}


# ── happy path (with a 2FA round-trip) ──────────────────────────────


def test_happy_path_2fa_links_and_sets_fields(bench, tmp_path):
    scenario = {
        "connected_users": [],
        "login_steps": [
            {"emit": [{"type": "tfaRequested", "username": "me@proton.me"}]},
            {"emit": [{"type": "finished", "userID": "u1"}]},
        ],
        "users_by_id": {"u1": _USER},
    }
    events, rec = _run_helper(tmp_path, scenario, {"action": "link"}, _REPLIES)

    kinds = [e.get("event") for e in events]
    assert "text-field" in kinds and "secret-field" in kinds
    # two secret prompts: password + totp
    assert kinds.count("secret-field") == 2
    assert rec["login_calls"] == ["Login", "Login2FA"]
    # Wire contract: Bridge base64Decode()s every LoginRequest.password
    # (service_methods.go) — raw bytes fail login with "Cannot decode
    # password". The helper must send std-base64 of the human's reply.
    assert rec["wire_passwords"] == [
        base64.b64encode(_REPLIES["password"].encode()).decode(),
        base64.b64encode(_REPLIES["totp"].encode()).decode(),
    ]

    sf = {e["field"]: e["value"] for e in _set_fields(events)}
    assert sf == {"email": "me@proton.me", "bridge_password": "BRIDGE-PW-1"}

    terms = _terminals(events)
    assert len(terms) == 1 and terms[0]["event"] == "done"
    assert "Quit" in rec["calls"]


def test_happy_path_pins_mail_server_ports(bench, tmp_path):
    scenario = {
        "connected_users": [],
        "login_steps": [{"emit": [{"type": "finished", "userID": "u1"}]}],
        "users_by_id": {"u1": _USER},
    }
    _events, rec = _run_helper(tmp_path, scenario, {"action": "link"}, _REPLIES)
    assert rec["settings"] == {
        "imapPort": 1143,
        "smtpPort": 1025,
        "useSSLForImap": False,
        "useSSLForSmtp": False,
    }


# ── TLS cert export: Bridge v3 keeps the cert in its vault ───────────


def test_link_exports_bridge_tls_cert(bench, tmp_path):
    """Bridge v3 never writes cert.pem on its own (the cert lives in
    vault.enc); the server module's bridge_probe requires it on disk. The
    helper must call ExportTLSCertificates into the bridge-v3 config dir and
    wait for cert.pem (the export is a fire-and-forget goroutine server-side)
    before declaring done."""
    scenario = {
        "connected_users": [],
        "login_steps": [{"emit": [{"type": "finished", "userID": "u1"}]}],
        "users_by_id": {"u1": _USER},
    }
    events, rec = _run_helper(tmp_path, scenario, {"action": "link"}, _REPLIES)

    certdir = tmp_path / "state" / "config" / "protonmail" / "bridge-v3"
    assert rec["export_dirs"] == [str(certdir)]
    # done implies the helper waited out the fake's delayed write
    assert (certdir / "cert.pem").read_text() == CERT_PEM
    terms = _terminals(events)
    assert len(terms) == 1 and terms[0]["event"] == "done"
    assert rec["calls"].index("ExportTLSCertificates") < rec["calls"].index("Quit")


def test_already_logged_in_refresh_exports_cert(bench, tmp_path):
    """The refresh path must export too: it is the recovery route for a state
    dir onboarded before the export existed (vault present, cert.pem absent)."""
    scenario = {
        "connected_users": [_USER],
        "login_steps": [],
        "users_by_id": {"u1": _USER},
    }
    _events, rec = _run_helper(tmp_path, scenario, {"action": "link"}, _REPLIES)
    certdir = tmp_path / "state" / "config" / "protonmail" / "bridge-v3"
    assert rec["export_dirs"] == [str(certdir)]
    assert (certdir / "cert.pem").exists()


# ── protocol-order pin: no set-field before login finished ───────────


def test_no_set_field_before_login_finished(bench, tmp_path):
    scenario = {
        "connected_users": [],
        "login_steps": [
            {"emit": [{"type": "tfaRequested", "username": "me@proton.me"}]},
            {"emit": [{"type": "finished", "userID": "u1"}]},
        ],
        "users_by_id": {"u1": _USER},
    }
    events, _rec = _run_helper(tmp_path, scenario, {"action": "link"}, _REPLIES)

    kinds = [e.get("event") for e in events]
    first_set = next(i for i, k in enumerate(kinds) if k == "set-field")
    last_prompt = max(
        i for i, k in enumerate(kinds) if k in ("text-field", "secret-field")
    )
    assert first_set > last_prompt, "set-field must follow every login prompt"


# ── typed errors ────────────────────────────────────────────────────


def test_free_user_gives_paid_plan_hint_and_no_set_field(bench, tmp_path):
    scenario = {
        "connected_users": [],
        "login_steps": [{"emit": [{"type": "error", "errType": 1, "message": "free"}]}],
        "users_by_id": {},
    }
    events, _rec = _run_helper(tmp_path, scenario, {"action": "link"}, _REPLIES)
    terms = _terminals(events)
    assert len(terms) == 1 and terms[0]["event"] == "error"
    assert "paid Proton plan" in terms[0]["error"]
    assert _set_fields(events) == []


def test_fido_only_account_is_use_totp_error(bench, tmp_path):
    scenario = {
        "connected_users": [],
        "login_steps": [
            {"emit": [{"type": "fidoRequested", "username": "me@proton.me"}]}
        ],
        "users_by_id": {},
    }
    events, _rec = _run_helper(tmp_path, scenario, {"action": "link"}, _REPLIES)
    terms = _terminals(events)
    assert len(terms) == 1 and terms[0]["event"] == "error"
    assert "TOTP" in terms[0]["error"]
    assert _set_fields(events) == []


# ── already-logged-in refresh ───────────────────────────────────────


def test_already_logged_in_refresh_skips_login(bench, tmp_path):
    scenario = {
        "connected_users": [_USER],
        "login_steps": [],
        "users_by_id": {"u1": _USER},
    }
    events, rec = _run_helper(tmp_path, scenario, {"action": "link"}, _REPLIES)

    kinds = [e.get("event") for e in events]
    assert "text-field" not in kinds and "secret-field" not in kinds
    assert rec["login_calls"] == []  # Login never called

    sf = {e["field"]: e["value"] for e in _set_fields(events)}
    assert sf == {"email": "me@proton.me", "bridge_password": "BRIDGE-PW-1"}
    terms = _terminals(events)
    assert len(terms) == 1 and terms[0]["event"] == "done"


def test_refresh_awaits_users_loaded(bench, tmp_path):
    """Users load ASYNC after Bridge's gRPC server is up (bridge.goLoad
    publishes allUsersLoaded when done; the event is queued server-side until
    the first RunEventStream subscriber). A GetUserList racing the load sees
    [] and would re-prompt full credentials on an already-linked vault. The
    helper must await allUsersLoaded before listing users."""
    scenario = {
        "connected_users": [_USER],
        "login_steps": [],
        "users_by_id": {"u1": _USER},
        "users_load_delay_ms": 500,
    }
    events, rec = _run_helper(tmp_path, scenario, {"action": "link"}, _REPLIES)
    kinds = [e.get("event") for e in events]
    assert "text-field" not in kinds and "secret-field" not in kinds
    assert rec["login_calls"] == []
    terms = _terminals(events)
    assert len(terms) == 1 and terms[0]["event"] == "done"


# ── remove verb ─────────────────────────────────────────────────────


def test_remove_calls_remove_user_then_done(bench, tmp_path):
    scenario = {
        "connected_users": [_USER],
        "login_steps": [],
        "users_by_id": {"u1": _USER},
    }
    events, rec = _run_helper(
        tmp_path, scenario, {"action": "remove", "profile": "default"}, _REPLIES
    )
    assert rec["removed"] == ["u1"]
    assert "RemoveUser" in rec["calls"] and "Quit" in rec["calls"]
    terms = _terminals(events)
    assert len(terms) == 1 and terms[0]["event"] == "done"
    assert _set_fields(events) == []


def test_remove_no_users_is_idempotent_done(bench, tmp_path):
    scenario = {"connected_users": [], "login_steps": [], "users_by_id": {}}
    events, rec = _run_helper(
        tmp_path, scenario, {"action": "remove", "profile": "default"}, _REPLIES
    )
    assert rec["removed"] == []
    assert "RemoveUser" not in rec["calls"]
    terms = _terminals(events)
    assert len(terms) == 1 and terms[0]["event"] == "done"


def test_remove_awaits_users_loaded(bench, tmp_path):
    """Same async-load race as the refresh: a remove racing the user load
    sees [] and would return the idempotent done WITHOUT removing anyone."""
    scenario = {
        "connected_users": [_USER],
        "login_steps": [],
        "users_by_id": {"u1": _USER},
        "users_load_delay_ms": 500,
    }
    _events, rec = _run_helper(
        tmp_path, scenario, {"action": "remove", "profile": "default"}, _REPLIES
    )
    assert rec["removed"] == ["u1"]


# ── fake harness self-check: TLS + token validation ─────────────────


def test_fake_bridge_rejects_bad_token(bench, tmp_path):
    """Prove the fake enforces the server-token (so the happy path's success
    means the helper really sent the right token over the TLS channel)."""
    run = tmp_path
    state = run / "state"
    (state / "config").mkdir(parents=True)
    (run / "scenario.json").write_text(json.dumps({"connected_users": []}))
    os.environ["SPACES_PROTON_BRIDGE_STATE"] = str(state)
    os.environ["PROTON_FAKE_SCENARIO"] = str(run / "scenario.json")
    os.environ["PROTON_FAKE_RECORD"] = str(run / "record.json")

    env = setup._bridge_env()
    cfg_path = setup._config_path(env)
    with contextlib.suppress(FileNotFoundError):
        os.unlink(cfg_path)

    proc = subprocess.Popen(["protonmail-bridge", "--grpc"], env=env)
    try:
        cfg = setup._poll_config(cfg_path)
        creds = grpc.ssl_channel_credentials(root_certificates=cfg["cert"].encode())
        channel = grpc.secure_channel(
            "unix:" + cfg["fileSocketPath"],
            creds,
            options=[("grpc.ssl_target_name_override", "127.0.0.1")],
        )
        stub = setup.pb_grpc.BridgeStub(channel)
        from google.protobuf.empty_pb2 import Empty

        # Right token: accepted.
        stub.GetUserList(Empty(), metadata=(("server-token", TOKEN),))
        # Wrong token: UNAUTHENTICATED.
        with pytest.raises(grpc.RpcError) as ei:
            stub.GetUserList(Empty(), metadata=(("server-token", "nope"),))
        assert ei.value.code() == grpc.StatusCode.UNAUTHENTICATED
        channel.close()
    finally:
        setup._terminate(proc)


# ── constants ───────────────────────────────────────────────────────


def test_pinned_ports_and_binary():
    assert setup.IMAP_PORT == 1143
    assert setup.SMTP_PORT == 1025
    assert setup.BRIDGE_BINARY == "protonmail-bridge"

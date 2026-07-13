"""Contract tests for the integration-signal setup helper (device linking).

The helper is spawned by systemd socket activation on the twin setup socket;
the broker connects to that socket and the helper streams NDJSON events
(qr/message/done/error) back over it. These tests stand in for both ends: a
fake signal-cli daemon serving scripted `startLink`/`finishLink` JSON-RPC, and
a fake broker that connects to the activation socket and captures every NDJSON
line the helper emits.
"""

import base64
import json
import os
import socket
import threading
import time

import integration_signal_setup as setup

DEVICE_LINK_URI = "sgnl://linkdevice?uuid=abcd-1234&pub_key=deadbeef"
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


# ── fake signal-cli daemon ──────────────────────────────────────────


class FakeLinkDaemon:
    """Unix-socket JSON-RPC daemon scripted for startLink / finishLink."""

    def __init__(
        self,
        sock_path,
        *,
        start_result=None,
        start_error=None,
        finish_error=None,
        finish_delay=0.0,
    ):
        self.sock_path = sock_path
        self.start_result = start_result
        self.start_error = start_error
        self.finish_error = finish_error
        self.finish_delay = finish_delay
        self.requests = []
        self._stop = False
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            os.unlink(sock_path)
        except FileNotFoundError:
            pass
        self._sock.bind(sock_path)
        self._sock.listen(8)
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def _serve(self):
        while not self._stop:
            try:
                conn, _ = self._sock.accept()
            except OSError:
                return
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn):
        with conn, conn.makefile("rb") as reader:
            for line in reader:
                line = line.strip()
                if not line:
                    continue
                req = json.loads(line)
                self.requests.append(req)
                resp = self._dispatch(req)
                if resp is not None:
                    conn.sendall(json.dumps(resp).encode("utf-8") + b"\n")

    def _dispatch(self, req):
        method = req.get("method")
        rid = req.get("id")
        if method == "startLink":
            if self.start_error is not None:
                return self._err(rid, self.start_error)
            return self._ok(rid, self.start_result)
        if method == "finishLink":
            if self.finish_delay:
                time.sleep(self.finish_delay)
            if self.finish_error is not None:
                return self._err(rid, self.finish_error)
            return self._ok(rid, {"number": "+15550001111"})
        return self._err(rid, f"no method: {method}")

    @staticmethod
    def _ok(rid, result):
        return {"jsonrpc": "2.0", "id": rid, "result": result}

    @staticmethod
    def _err(rid, message):
        return {
            "jsonrpc": "2.0",
            "id": rid,
            "error": {"code": -1, "message": message},
        }

    def calls(self, method):
        return [r for r in self.requests if r.get("method") == method]

    def close(self):
        self._stop = True
        try:
            self._sock.close()
        except OSError:
            pass


def _wait_path(path, timeout=5.0):
    deadline = time.monotonic() + timeout
    while not os.path.exists(path):
        assert time.monotonic() < deadline, f"path never appeared: {path}"
        time.sleep(0.01)


def _run_helper(tmp_path, monkeypatch, *, daemon=None, daemon_socket=None):
    """Run `setup.main()` as the socket-activated helper, connect to its
    activation socket as the broker, and return the list of NDJSON events it
    streams before closing the connection.
    """
    monkeypatch.delenv("LISTEN_FDS", raising=False)
    # Keep the daemon-connect backoff snappy for the unreachable case.
    monkeypatch.setattr(setup, "_DAEMON_CONNECT_DEADLINE", 1.0)
    monkeypatch.setattr(setup, "_DAEMON_RETRY_INTERVAL", 0.05)

    activation = str(tmp_path / "setup.sock")
    monkeypatch.setenv("SPACES_INTEGRATION_SOCKET", activation)

    if daemon_socket is None and daemon is not None:
        daemon_socket = daemon.sock_path
    if daemon_socket is not None:
        monkeypatch.setenv("SPACES_SIGNAL_DAEMON_SOCKET", daemon_socket)
    else:
        monkeypatch.delenv("SPACES_SIGNAL_DAEMON_SOCKET", raising=False)

    rc = {}
    thread = threading.Thread(
        target=lambda: rc.__setitem__("code", setup.main()), daemon=True
    )
    thread.start()
    _wait_path(activation)

    broker = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    broker.connect(activation)
    events = []
    with broker, broker.makefile("rb") as reader:
        for line in reader:
            line = line.strip()
            if line:
                events.append(json.loads(line))

    thread.join(timeout=10.0)
    assert not thread.is_alive(), "helper did not exit"
    # A link failure is a protocol event, never a crash: exit 0 either way.
    assert rc.get("code") == 0
    return events


def _terminals(events):
    return [e for e in events if e.get("event") in ("done", "error")]


# ── happy path ──────────────────────────────────────────────────────


def test_happy_path_emits_qr_then_done(tmp_path, monkeypatch):
    daemon = FakeLinkDaemon(
        str(tmp_path / "daemon.sock"),
        start_result={"deviceLinkUri": DEVICE_LINK_URI},
    )
    try:
        events = _run_helper(tmp_path, monkeypatch, daemon=daemon)
    finally:
        daemon.close()

    kinds = [e["event"] for e in events]
    assert "qr" in kinds
    assert kinds[-1] == "done"
    assert _terminals(events) == [{"event": "done"}]

    qr = next(e for e in events if e["event"] == "qr")
    assert qr["uri"] == DEVICE_LINK_URI
    png = base64.b64decode(qr["png"])
    assert png.startswith(PNG_MAGIC)

    assert daemon.calls("startLink")
    finish = daemon.calls("finishLink")
    assert finish
    params = finish[0]["params"]
    assert params["deviceLinkUri"] == DEVICE_LINK_URI
    assert params["deviceName"].startswith("spaces-")


# ── daemon unreachable ──────────────────────────────────────────────


def test_daemon_unreachable_emits_error(tmp_path, monkeypatch):
    events = _run_helper(
        tmp_path,
        monkeypatch,
        daemon_socket=str(tmp_path / "missing.sock"),
    )
    assert [e["event"] for e in events if e["event"] == "qr"] == []
    terminals = _terminals(events)
    assert len(terminals) == 1
    err = terminals[0]
    assert err["event"] == "error"
    assert "daemon" in err["error"].lower()


# ── startLink JSON-RPC error ────────────────────────────────────────


def test_start_link_error_emits_error(tmp_path, monkeypatch):
    daemon = FakeLinkDaemon(
        str(tmp_path / "daemon.sock"),
        start_error="cannot start a link right now",
    )
    try:
        events = _run_helper(tmp_path, monkeypatch, daemon=daemon)
    finally:
        daemon.close()

    assert [e for e in events if e["event"] == "qr"] == []
    terminals = _terminals(events)
    assert len(terminals) == 1
    assert terminals[0]["event"] == "error"
    assert daemon.calls("startLink")
    assert daemon.calls("finishLink") == []  # never reached the finish step


# ── finishLink error / timeout after the QR ─────────────────────────


def test_finish_link_error_emits_error_after_qr(tmp_path, monkeypatch):
    daemon = FakeLinkDaemon(
        str(tmp_path / "daemon.sock"),
        start_result={"deviceLinkUri": DEVICE_LINK_URI},
        finish_error="linking failed on the device",
    )
    try:
        events = _run_helper(tmp_path, monkeypatch, daemon=daemon)
    finally:
        daemon.close()

    kinds = [e["event"] for e in events]
    assert kinds.index("qr") < len(kinds) - 1  # qr precedes the terminal line
    terminals = _terminals(events)
    assert len(terminals) == 1
    assert terminals[0]["event"] == "error"


def test_finish_link_timeout_emits_error_after_qr(tmp_path, monkeypatch):
    monkeypatch.setattr(setup, "_FINISH_LINK_TIMEOUT", 0.3)
    daemon = FakeLinkDaemon(
        str(tmp_path / "daemon.sock"),
        start_result={"deviceLinkUri": DEVICE_LINK_URI},
        finish_delay=5.0,
    )
    try:
        events = _run_helper(tmp_path, monkeypatch, daemon=daemon)
    finally:
        daemon.close()

    assert any(e["event"] == "qr" for e in events)
    terminals = _terminals(events)
    assert len(terminals) == 1
    assert terminals[0]["event"] == "error"


# ── missing deviceLinkUri in a well-formed result ───────────────────


def test_missing_device_link_uri_emits_error(tmp_path, monkeypatch):
    daemon = FakeLinkDaemon(
        str(tmp_path / "daemon.sock"),
        start_result={"unexpected": "shape"},
    )
    try:
        events = _run_helper(tmp_path, monkeypatch, daemon=daemon)
    finally:
        daemon.close()

    assert [e for e in events if e["event"] == "qr"] == []
    terminals = _terminals(events)
    assert len(terminals) == 1
    assert terminals[0]["event"] == "error"

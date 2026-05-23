"""End-to-end tests for distro_signal.bridge.

Spawns a tiny in-process FakeSignalDaemon over a unix socket, points
the bridge at it, and drives both the sandbox-facing enqueue socket
and the panel-facing approval socket through real socket I/O. No
signal-cli binary, no actual JVM.
"""

from __future__ import annotations

import json
import os
import socket
import tempfile
import threading
import time
import unittest
from pathlib import Path
from typing import Callable

from distro_signal import bridge as bridge_mod
from distro_signal import db as dbmod

# ── Fake signal-cli daemon ──────────────────────────────────────────


class FakeSignalDaemon:
    """Minimal JSON-RPC server over a unix socket that speaks just
    enough signal-cli to drive the bridge. Each test mutates
    `accounts`, `groups`, `contacts` to shape what the daemon
    advertises; `push_receive()` writes a `receive` notification to
    any currently-subscribed connection.
    """

    def __init__(self, sock_path: str) -> None:
        self.sock_path = sock_path
        self.accounts: list[dict] = []
        self.groups: list[dict] = []
        self.contacts: list[dict] = []

        self.subscribed_conns: list[socket.socket] = []
        self.send_calls: list[dict] = []
        self._lock = threading.Lock()

        self._srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._srv.bind(sock_path)
        self._srv.listen(8)
        self._srv.settimeout(0.5)

        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        try:
            self._srv.close()
        except OSError:
            pass
        with self._lock:
            for c in list(self.subscribed_conns):
                try:
                    c.close()
                except OSError:
                    pass
            self.subscribed_conns.clear()
        self._thread.join(timeout=2.0)

    def push_receive(self, params: dict) -> None:
        """Emit a `receive` JSON-RPC notification to every subscribed conn."""
        line = (
            json.dumps({"jsonrpc": "2.0", "method": "receive", "params": params}) + "\n"
        ).encode("utf-8")
        with self._lock:
            stale = []
            for c in self.subscribed_conns:
                try:
                    c.sendall(line)
                except OSError:
                    stale.append(c)
            for c in stale:
                self.subscribed_conns.remove(c)

    def _serve(self) -> None:
        while not self._stop.is_set():
            try:
                conn, _ = self._srv.accept()
            except (socket.timeout, OSError):
                continue
            t = threading.Thread(target=self._handle_conn, args=(conn,), daemon=True)
            t.start()

    def _handle_conn(self, conn: socket.socket) -> None:
        f = conn.makefile("r", encoding="utf-8", newline="\n")
        try:
            while True:
                line = f.readline()
                if not line:
                    return
                try:
                    req = json.loads(line)
                except json.JSONDecodeError:
                    continue
                resp = self._dispatch(conn, req)
                if resp is None:
                    continue
                conn.sendall((json.dumps(resp) + "\n").encode("utf-8"))
        finally:
            with self._lock:
                if conn in self.subscribed_conns:
                    self.subscribed_conns.remove(conn)
            try:
                conn.close()
            except OSError:
                pass

    def _dispatch(self, conn: socket.socket, req: dict) -> dict | None:
        method = req.get("method")
        params = req.get("params") or {}
        rid = req.get("id")
        result: object = None
        error: dict | None = None
        if method == "listAccounts":
            result = self.accounts
        elif method == "listGroups":
            result = self.groups
        elif method == "listContacts":
            result = self.contacts
        elif method == "subscribeReceive":
            with self._lock:
                if conn not in self.subscribed_conns:
                    self.subscribed_conns.append(conn)
            result = {}
        elif method == "send":
            self.send_calls.append(params)
            result = {"timestamp": int(time.time() * 1000)}
        else:
            error = {"code": -32601, "message": f"unknown method {method}"}
        if rid is None:
            return None
        payload: dict = {"jsonrpc": "2.0", "id": rid}
        if error is not None:
            payload["error"] = error
        else:
            payload["result"] = result
        return payload


# ── helpers ─────────────────────────────────────────────────────────


def _wait_until(predicate: Callable[[], bool], *, timeout: float = 5.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.02)
    return False


def _socket_reachable(sock_path: str) -> bool:
    """True iff a unix-socket listener on `sock_path` accepts a
    connection. Used in place of `os.path.exists`, which is true the
    moment bind() returns and can race the subsequent listen()."""
    if not os.path.exists(sock_path):
        return False
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(0.2)
    try:
        s.connect(sock_path)
    except OSError:
        return False
    finally:
        s.close()
    return True


def _send_request(sock_path: str, payload: dict, *, timeout: float = 5.0) -> dict:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(sock_path)
    try:
        s.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        f = s.makefile("r", encoding="utf-8", newline="\n")
        line = f.readline()
        if not line:
            raise RuntimeError("socket closed before response")
        return json.loads(line)
    finally:
        s.close()


# ── fixture base ────────────────────────────────────────────────────


class BridgeHarness(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name)

        self.daemon_sock = str(base / "signal.sock")
        self.enqueue_sock = str(base / "enqueue.sock")
        self.panel_sock = str(base / "panel.sock")
        self.db_path = base / "messages.db"

        self.daemon = FakeSignalDaemon(self.daemon_sock)
        self.daemon.accounts = [{"uuid": "acct-uuid", "number": "+15550000001"}]
        self.addCleanup(self.daemon.stop)

        self.bridge = bridge_mod.Bridge(
            bridge_mod.BridgeConfig(
                db_path=self.db_path,
                daemon_socket=self.daemon_sock,
                enqueue_socket=self.enqueue_sock,
                panel_socket=self.panel_sock,
            ),
            accounts_refresh_seconds=60.0,
        )
        self.bridge.start()
        self.addCleanup(self.bridge.stop)

        # Wait until both listener sockets are reachable (file exists
        # AND listen() has finished — file-exists alone races against
        # bind/listen on slower runners) and the bridge has pulled
        # the account snapshot.
        for sock_path in (self.enqueue_sock, self.panel_sock):
            if not _wait_until(lambda p=sock_path: _socket_reachable(p)):
                self.fail(f"socket {sock_path} never became reachable")
        if not _wait_until(lambda: bool(self.bridge._accounts_snapshot())):
            self.fail("accounts never populated from listAccounts")
        # Subscriber needs a beat to call subscribeReceive.
        if not _wait_until(lambda: len(self.daemon.subscribed_conns) >= 1):
            self.fail("bridge never subscribed")


# ── tests ───────────────────────────────────────────────────────────


class TestReceiver(BridgeHarness):
    def test_incoming_dm_envelope_lands_in_db(self) -> None:
        self.daemon.push_receive(
            {
                "account": "+15550000001",
                "envelope": {
                    "sourceUuid": "uuid-alice",
                    "sourceName": "Alice",
                    "timestamp": 1700000000000,
                    "dataMessage": {"message": "hi from alice"},
                },
            }
        )
        self.assertTrue(
            _wait_until(
                lambda: dbmod.query_messages(
                    dbmod.connect(self.db_path), thread_id="uuid-alice"
                ),
                timeout=3,
            )
        )
        rows = dbmod.query_messages(dbmod.connect(self.db_path), thread_id="uuid-alice")
        self.assertEqual(rows[0]["body"], "hi from alice")
        self.assertEqual(rows[0]["thread_kind"], "dm")
        self.assertEqual(rows[0]["account_uuid"], "acct-uuid")

    def test_group_envelope_routed_by_group_id(self) -> None:
        self.daemon.push_receive(
            {
                "account": "+15550000001",
                "envelope": {
                    "sourceUuid": "uuid-bob",
                    "sourceName": "Bob",
                    "timestamp": 1700000001000,
                    "dataMessage": {
                        "message": "hi crew",
                        "groupInfo": {"groupId": "GROUP=1"},
                    },
                },
            }
        )
        self.assertTrue(
            _wait_until(
                lambda: dbmod.query_messages(
                    dbmod.connect(self.db_path), thread_id="GROUP=1"
                ),
                timeout=3,
            )
        )
        rows = dbmod.query_messages(dbmod.connect(self.db_path), thread_id="GROUP=1")
        self.assertEqual(rows[0]["thread_kind"], "group")

    def test_replayed_envelope_deduped(self) -> None:
        env = {
            "account": "+15550000001",
            "envelope": {
                "sourceUuid": "uuid-alice",
                "sourceName": "Alice",
                "timestamp": 1700000099000,
                "dataMessage": {"message": "x"},
            },
        }
        for _ in range(3):
            self.daemon.push_receive(env)
        # Wait for at least one row, then verify count caps at 1.
        self.assertTrue(
            _wait_until(
                lambda: (
                    len(
                        dbmod.query_messages(
                            dbmod.connect(self.db_path), thread_id="uuid-alice"
                        )
                    )
                    >= 1
                ),
                timeout=3,
            )
        )
        time.sleep(0.2)  # let any pending duplicates flush
        rows = dbmod.query_messages(dbmod.connect(self.db_path), thread_id="uuid-alice")
        self.assertEqual(len(rows), 1)

    def test_typing_only_envelope_ignored(self) -> None:
        before = len(dbmod.query_messages(dbmod.connect(self.db_path)))
        self.daemon.push_receive(
            {
                "account": "+15550000001",
                "envelope": {
                    "sourceUuid": "uuid-alice",
                    "timestamp": 1700000050000,
                    "typingMessage": {"action": "STARTED"},
                },
            }
        )
        # Give the bridge a moment; it may or may not call store
        time.sleep(0.2)
        after = len(dbmod.query_messages(dbmod.connect(self.db_path)))
        self.assertEqual(before, after)


class TestEnqueueSelfSend(BridgeHarness):
    def test_self_send_dispatches_without_pending(self) -> None:
        resp = _send_request(
            self.enqueue_sock,
            {"op": "send", "to": "+15550000001", "body": "note to self"},
        )
        self.assertTrue(resp["ok"])
        self.assertTrue(resp.get("to_self"))
        # signal-cli `send` should have been called with our message.
        self.assertTrue(_wait_until(lambda: bool(self.daemon.send_calls), timeout=3))
        self.assertEqual(self.daemon.send_calls[0]["message"], "note to self")
        # No pending row.
        pending = dbmod.list_pending(dbmod.connect(self.db_path))
        self.assertEqual(pending, [])

    def test_self_send_by_uuid_also_bypasses(self) -> None:
        resp = _send_request(
            self.enqueue_sock,
            {"op": "send", "to": "acct-uuid", "body": "x"},
        )
        self.assertTrue(resp["ok"])
        self.assertTrue(resp.get("to_self"))


class TestEnqueueOtherRecipient(BridgeHarness):
    def test_non_self_returns_pending_token(self) -> None:
        self.daemon.contacts = [
            {"uuid": "uuid-bob", "number": "+15559998888", "name": "Bob"}
        ]
        resp = _send_request(
            self.enqueue_sock,
            {"op": "send", "to": "+15559998888", "body": "hi bob"},
        )
        self.assertTrue(resp["ok"])
        self.assertTrue(resp.get("pending"))
        self.assertIn("token", resp)
        # display_name resolved from contacts.
        self.assertEqual(resp["display_name"], "Bob")
        # signal-cli `send` was NOT called.
        self.assertEqual(self.daemon.send_calls, [])
        # Pending row exists.
        pending = dbmod.list_pending(dbmod.connect(self.db_path))
        self.assertEqual(len(pending), 1)
        self.assertEqual(pending[0]["recipient"], "+15559998888")
        self.assertEqual(pending[0]["body"], "hi bob")

    def test_missing_to_or_body_returns_error(self) -> None:
        resp = _send_request(self.enqueue_sock, {"op": "send", "to": "+1"})
        self.assertFalse(resp["ok"])
        self.assertIn("error", resp)

    def test_unknown_op_rejected(self) -> None:
        resp = _send_request(self.enqueue_sock, {"op": "frobnicate"})
        self.assertFalse(resp["ok"])


class TestPanelDecision(BridgeHarness):
    def _enqueue(self, to: str = "+15559998888", body: str = "x") -> str:
        resp = _send_request(self.enqueue_sock, {"op": "send", "to": to, "body": body})
        self.assertTrue(resp["ok"])
        self.assertTrue(resp.get("pending"))
        return resp["token"]

    def test_list_returns_pending(self) -> None:
        self._enqueue(body="m1")
        self._enqueue(body="m2")
        resp = _send_request(self.panel_sock, {"op": "list"})
        self.assertTrue(resp["ok"])
        self.assertEqual(len(resp["pending"]), 2)
        bodies = {p["body"] for p in resp["pending"]}
        self.assertEqual(bodies, {"m1", "m2"})

    def test_approve_dispatches_and_marks_sent(self) -> None:
        token = self._enqueue(body="approved-msg")
        resp = _send_request(self.panel_sock, {"op": "approve", "token": token})
        self.assertTrue(resp["ok"])
        self.assertEqual(resp["state"], "sent")
        # daemon was called.
        self.assertTrue(
            _wait_until(
                lambda: any(
                    c.get("message") == "approved-msg" for c in self.daemon.send_calls
                ),
                timeout=3,
            )
        )
        # DB updated.
        row = dbmod.get_pending(dbmod.connect(self.db_path), token)
        self.assertEqual(row["state"], "sent")

    def test_deny_marks_denied_and_skips_dispatch(self) -> None:
        token = self._enqueue(body="denied-msg")
        resp = _send_request(self.panel_sock, {"op": "deny", "token": token})
        self.assertTrue(resp["ok"])
        self.assertEqual(resp["state"], "denied")
        # daemon NOT called for this message.
        time.sleep(0.2)
        self.assertFalse(
            any(c.get("message") == "denied-msg" for c in self.daemon.send_calls)
        )
        row = dbmod.get_pending(dbmod.connect(self.db_path), token)
        self.assertEqual(row["state"], "denied")

    def test_approve_unknown_token_errors(self) -> None:
        resp = _send_request(self.panel_sock, {"op": "approve", "token": "bogus"})
        self.assertFalse(resp["ok"])
        self.assertIn("unknown", resp["error"])

    def test_double_decide_rejected(self) -> None:
        token = self._enqueue()
        first = _send_request(self.panel_sock, {"op": "approve", "token": token})
        self.assertTrue(first["ok"])
        second = _send_request(self.panel_sock, {"op": "deny", "token": token})
        self.assertFalse(second["ok"])
        # Should mention current state for the panel to render usefully.
        self.assertIn("already", second["error"])


# ── pure helpers (no harness) ───────────────────────────────────────


class TestClassifyAndSelf(unittest.TestCase):
    def test_classify_recipient(self) -> None:
        cases = [
            ("+15551234", "number"),
            ("abcdef01-2345-6789-abcd-ef0123456789", "uuid"),
            ("alice.42", "username"),
            ("AfL/co87TsyfTv4FqgJfcF6rNWoRkO2CYLybn83tfTU=", "group"),
        ]
        for value, want in cases:
            with self.subTest(value=value):
                self.assertEqual(bridge_mod.classify_recipient(value), want)

    def test_is_self_recipient_matches_uuid_and_number(self) -> None:
        accounts = [
            {"uuid": "acct-uuid", "number": "+15550000001"},
            {"uuid": "second-uuid", "number": "+15550000002"},
        ]
        self.assertTrue(bridge_mod.is_self_recipient("acct-uuid", accounts))
        self.assertTrue(bridge_mod.is_self_recipient("+15550000002", accounts))
        self.assertFalse(bridge_mod.is_self_recipient("+15559998888", accounts))
        self.assertFalse(bridge_mod.is_self_recipient("other-uuid", accounts))

    def test_envelope_to_message_basic_dm(self) -> None:
        out = bridge_mod.envelope_to_message(
            {
                "envelope": {
                    "sourceUuid": "uuid-alice",
                    "sourceName": "Alice",
                    "timestamp": 1700000000000,
                    "dataMessage": {"message": "hi"},
                }
            },
            account={"uuid": "acct-uuid", "number": "+1"},
        )
        self.assertEqual(out["thread_id"], "uuid-alice")
        self.assertEqual(out["thread_kind"], "dm")
        self.assertEqual(out["body"], "hi")
        self.assertEqual(out["sender_name"], "Alice")
        self.assertEqual(out["uid"], "1700000000000_uuid-alice")

    def test_envelope_to_message_disappearing(self) -> None:
        out = bridge_mod.envelope_to_message(
            {
                "envelope": {
                    "sourceUuid": "uuid-alice",
                    "timestamp": 1700000000000,
                    "dataMessage": {
                        "message": "secret",
                        "expiresInSeconds": 60,
                    },
                }
            }
        )
        self.assertEqual(out["expires_at_ms"], 1700000000000 + 60_000)

    def test_envelope_to_message_typing_only_returns_none(self) -> None:
        self.assertIsNone(
            bridge_mod.envelope_to_message(
                {
                    "envelope": {
                        "sourceUuid": "uuid-alice",
                        "timestamp": 1700000000000,
                        "typingMessage": {"action": "STARTED"},
                    }
                }
            )
        )


if __name__ == "__main__":
    unittest.main()

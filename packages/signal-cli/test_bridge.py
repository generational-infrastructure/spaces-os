"""End-to-end tests for distro_signal.bridge.

Spawns a tiny in-process FakeSignalDaemon over a unix socket, points
the bridge at it, and drives both the sandbox-facing enqueue socket
and the panel-facing approval socket through real socket I/O. No
signal-cli binary, no actual JVM.
"""

from __future__ import annotations

import json
import os
import select
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
        self.sync_requests: list[dict] = []
        self._lock = threading.Lock()

        self._srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._srv.bind(sock_path)
        self._srv.listen(8)

        self._stop = threading.Event()
        self._wake = bridge_mod._SelectWake()
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        # Interrupt the select() so the accept loop exits before we
        # close its listening socket — same shutdown trick the
        # production bridge uses, so tests don't pay an accept-timeout
        # per teardown.
        self._wake.wake()
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
        self._wake.close()

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
        wake_fd = self._wake.read_end
        while not self._stop.is_set():
            try:
                rlist, _, _ = select.select([self._srv, wake_fd], [], [])
            except (OSError, ValueError):
                return
            if wake_fd in rlist:
                self._wake.drain()
                continue
            try:
                conn, _ = self._srv.accept()
            except OSError:
                return
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
        elif method == "sendSyncRequest":
            with self._lock:
                self.sync_requests.append(params)
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


class TestEnqueueDisplayName(BridgeHarness):
    """Display-name handling is panel-visible: an attacker who
    controls their Signal display name (BIDI override, zero-width
    chars, terminal control codes) could otherwise spoof the
    visible recipient on the approval card. The bridge must:
      1. strip Unicode control / format chars before storing or
         echoing the name back, and
      2. always return the raw `recipient` alongside the friendly
         name so the CLI can show both."""

    def test_response_carries_recipient_verbatim(self) -> None:
        self.daemon.contacts = [
            {"uuid": "u-bob", "number": "+15559998888", "name": "Bob"}
        ]
        resp = _send_request(
            self.enqueue_sock,
            {"op": "send", "to": "+15559998888", "body": "hi"},
        )
        self.assertEqual(resp["recipient"], "+15559998888")

    def test_display_name_strips_bidi_override(self) -> None:
        # U+202E RIGHT-TO-LEFT OVERRIDE inserted mid-name.
        self.daemon.contacts = [
            {"uuid": "u-evil", "number": "+1666", "name": "Al\u202eice"}
        ]
        resp = _send_request(
            self.enqueue_sock,
            {"op": "send", "to": "+1666", "body": "x"},
        )
        self.assertEqual(resp["display_name"], "Alice")

    def test_display_name_strips_zero_width(self) -> None:
        # U+200B ZERO WIDTH SPACE and U+200D ZERO WIDTH JOINER.
        self.daemon.contacts = [
            {"uuid": "u-eve", "number": "+1777", "name": "Ev\u200be\u200d"}
        ]
        resp = _send_request(
            self.enqueue_sock,
            {"op": "send", "to": "+1777", "body": "x"},
        )
        self.assertEqual(resp["display_name"], "Eve")

    def test_display_name_falls_back_when_all_chars_stripped(self) -> None:
        # Pathological name made entirely of control chars: fall back
        # to the recipient so the panel doesn't render an empty card.
        self.daemon.contacts = [
            {"uuid": "u-x", "number": "+1888", "name": "\u200b\u200d\u202e"}
        ]
        resp = _send_request(
            self.enqueue_sock,
            {"op": "send", "to": "+1888", "body": "x"},
        )
        self.assertEqual(resp["display_name"], "+1888")


class TestEnqueueDaemonProxy(BridgeHarness):
    """Bridge proxies listContacts/listGroups so the sandbox never
    touches the daemon socket directly."""

    def test_contacts_op_returns_aggregated_list(self) -> None:
        self.daemon.contacts = [
            {"uuid": "u-bob", "number": "+1888", "name": "Bob"},
            {"uuid": "u-carol", "number": "+1777", "name": "Carol"},
        ]
        resp = _send_request(self.enqueue_sock, {"op": "contacts"})
        self.assertTrue(resp["ok"])
        names = sorted(c.get("name") for c in resp["contacts"])
        self.assertEqual(names, ["Bob", "Carol"])

    def test_groups_op_returns_aggregated_list(self) -> None:
        self.daemon.groups = [
            {"id": "GROUP=1", "name": "Crew", "members": [1, 2]},
        ]
        resp = _send_request(self.enqueue_sock, {"op": "groups"})
        self.assertTrue(resp["ok"])
        self.assertEqual(len(resp["groups"]), 1)
        self.assertEqual(resp["groups"][0]["name"], "Crew")

    def test_contacts_op_empty_when_daemon_empty(self) -> None:
        self.daemon.contacts = []
        resp = _send_request(self.enqueue_sock, {"op": "contacts"})
        self.assertTrue(resp["ok"])
        self.assertEqual(resp["contacts"], [])

    def test_contacts_op_errors_when_no_account(self) -> None:
        self.daemon.accounts = []
        self.bridge._refresh_accounts()
        resp = _send_request(self.enqueue_sock, {"op": "contacts"})
        self.assertFalse(resp["ok"])
        self.assertIn("no linked Signal account", resp["error"])


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


class TestPanelDecisionRace(BridgeHarness):
    """Two concurrent approvals on the same token must dispatch the
    underlying `send` exactly once. The pre-fix flow read the row,
    checked state, dispatched, then wrote — a classic TOCTOU. Two
    parallel approvers could both pass the state check and both
    dispatch, double-sending the message."""

    def test_concurrent_approve_dispatches_once(self) -> None:
        # Queue one pending send.
        resp = _send_request(
            self.enqueue_sock,
            {"op": "send", "to": "+15559998888", "body": "race-msg"},
        )
        token = resp["token"]

        # Fire N parallel approvals.
        N = 8
        results: list[dict] = []
        results_lock = threading.Lock()

        def approve() -> None:
            r = _send_request(
                self.panel_sock, {"op": "approve", "token": token}, timeout=10.0
            )
            with results_lock:
                results.append(r)

        threads = [threading.Thread(target=approve) for _ in range(N)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        winners = [r for r in results if r.get("ok")]
        losers = [r for r in results if not r.get("ok")]
        self.assertEqual(
            len(winners), 1, f"expected exactly one approver to win, got {results!r}"
        )
        self.assertEqual(len(losers), N - 1)

        # signal-cli `send` invoked exactly once.
        sends = [c for c in self.daemon.send_calls if c.get("message") == "race-msg"]
        self.assertEqual(len(sends), 1, f"send must be dispatched once, got {sends!r}")

        # Row ends up in `sent` state.
        check_db = dbmod.connect(self.db_path)
        try:
            row = dbmod.get_pending(check_db, token)
        finally:
            check_db.close()
        self.assertEqual(row["state"], "sent")


class TestEnqueueResourceLimits(BridgeHarness):
    """Cheap DoS guards: a malicious sandbox or bug-pinned client
    must not be able to OOM the bridge by streaming a single
    unbounded line, nor stash a giant body that signal-cli would
    reject downstream after we've already paid the storage cost."""

    def test_oversize_line_drops_connection_bridge_stays_up(self) -> None:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(5.0)
        s.connect(self.enqueue_sock)
        big = b"x" * (2 * 1024 * 1024)  # 2 MiB, no newline
        try:
            s.sendall(big)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass  # bridge closed us, that's the desired outcome
        finally:
            s.close()
        # Bridge stayed alive — fresh conn works.
        resp = _send_request(
            self.enqueue_sock,
            {"op": "send", "to": "+15550000001", "body": "still alive"},
        )
        self.assertTrue(resp["ok"])

    def test_oversize_body_rejected_before_enqueue(self) -> None:
        body = "x" * (65 * 1024)  # 65 KiB
        resp = _send_request(
            self.enqueue_sock,
            {"op": "send", "to": "+15559998888", "body": body},
        )
        self.assertFalse(resp["ok"])
        self.assertIn("body too large", resp["error"])
        # No pending row created.
        with self.bridge._db_lock:
            pending = dbmod.list_pending(self.bridge.db)
        self.assertEqual(pending, [])


class _PanelSubscriber:
    """Persistent panel-side conn that captures every event the bridge
    pushes via `op:"added"` / `op:"removed"`. Used by subscribe tests
    to verify the bridge actually broadcasts state mutations.
    """

    def __init__(self, sock_path: str) -> None:
        self.events: list[dict] = []
        self._stop = threading.Event()
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._sock.settimeout(5.0)
        self._sock.connect(sock_path)
        self._sock.sendall((json.dumps({"op": "subscribe"}) + "\n").encode("utf-8"))
        self._reader = threading.Thread(target=self._run, daemon=True)
        self._reader.start()

    def send(self, payload: dict) -> None:
        self._sock.sendall((json.dumps(payload) + "\n").encode("utf-8"))

    def close(self) -> None:
        self._stop.set()
        try:
            self._sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self._sock.close()
        except OSError:
            pass
        self._reader.join(timeout=2.0)

    def _run(self) -> None:
        f = self._sock.makefile("r", encoding="utf-8", newline="\n")
        while not self._stop.is_set():
            try:
                line = f.readline()
            except OSError:
                return
            if not line:
                return
            try:
                self.events.append(json.loads(line))
            except json.JSONDecodeError:
                continue


class TestPanelSubscribe(BridgeHarness):
    def _subscribe(self) -> "_PanelSubscriber":
        sub = _PanelSubscriber(self.panel_sock)
        self.addCleanup(sub.close)
        # Wait for the initial snapshot.
        self.assertTrue(
            _wait_until(
                lambda: any(e.get("op") == "snapshot" for e in sub.events),
                timeout=3,
            )
        )
        return sub

    def test_subscribe_initial_snapshot_carries_existing_pending(self) -> None:
        _send_request(
            self.enqueue_sock,
            {"op": "send", "to": "+15559998888", "body": "preexisting"},
        )
        sub = self._subscribe()
        snapshot = [e for e in sub.events if e.get("op") == "snapshot"][0]
        self.assertEqual(len(snapshot["pending"]), 1)
        self.assertEqual(snapshot["pending"][0]["body"], "preexisting")

    def test_subscribe_receives_added_when_new_enqueue_arrives(self) -> None:
        sub = self._subscribe()
        before = len(sub.events)
        _send_request(
            self.enqueue_sock,
            {"op": "send", "to": "+15559998888", "body": "live-add"},
        )
        self.assertTrue(
            _wait_until(
                lambda: any(
                    e.get("op") == "added"
                    and e.get("request", {}).get("body") == "live-add"
                    for e in sub.events[before:]
                ),
                timeout=3,
            )
        )

    def test_subscribe_receives_removed_on_approve(self) -> None:
        sub = self._subscribe()
        resp = _send_request(
            self.enqueue_sock,
            {"op": "send", "to": "+15559998888", "body": "to-approve"},
        )
        token = resp["token"]
        before = len(sub.events)
        # Approve on a separate conn — the subscribe conn must still
        # receive the broadcast.
        _send_request(self.panel_sock, {"op": "approve", "token": token})
        self.assertTrue(
            _wait_until(
                lambda: any(
                    e.get("op") == "removed"
                    and e.get("token") == token
                    and e.get("state") == "sent"
                    for e in sub.events[before:]
                ),
                timeout=3,
            )
        )

    def test_subscribe_receives_removed_on_deny(self) -> None:
        sub = self._subscribe()
        resp = _send_request(
            self.enqueue_sock,
            {"op": "send", "to": "+15559998888", "body": "to-deny"},
        )
        token = resp["token"]
        before = len(sub.events)
        _send_request(self.panel_sock, {"op": "deny", "token": token})
        self.assertTrue(
            _wait_until(
                lambda: any(
                    e.get("op") == "removed"
                    and e.get("token") == token
                    and e.get("state") == "denied"
                    for e in sub.events[before:]
                ),
                timeout=3,
            )
        )

    def test_subscribed_conn_can_also_approve(self) -> None:
        sub = self._subscribe()
        resp = _send_request(
            self.enqueue_sock,
            {"op": "send", "to": "+15559998888", "body": "via-sub-approve"},
        )
        token = resp["token"]
        before = len(sub.events)
        # Send approve on the SAME socket the subscriber owns.
        sub.send({"op": "approve", "token": token})
        self.assertTrue(
            _wait_until(
                lambda: any(
                    e.get("op") == "removed" and e.get("token") == token
                    for e in sub.events[before:]
                ),
                timeout=3,
            )
        )
        # Decision response also arrives back on the same conn.
        self.assertTrue(
            any(e.get("op") == "decision" and e.get("ok") for e in sub.events[before:])
        )

    def test_unsubscribe_stops_receiving_broadcasts(self) -> None:
        sub = self._subscribe()
        sub.close()
        # Give the bridge a beat to notice the closed conn.
        time.sleep(0.2)
        # A subsequent enqueue must still complete (it just won't
        # broadcast to anyone).
        resp = _send_request(
            self.enqueue_sock,
            {"op": "send", "to": "+15559998888", "body": "after-unsub"},
        )
        self.assertTrue(resp["ok"])


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


class TestStartupSync(BridgeHarness):
    def test_sendSyncRequest_issued_for_each_account_at_startup(self) -> None:
        if not _wait_until(lambda: len(self.daemon.sync_requests) >= 1):
            self.fail("bridge never issued sendSyncRequest at startup")
        accounts_requested = {p.get("account") for p in self.daemon.sync_requests}
        self.assertEqual(accounts_requested, {"+15550000001"})

    def test_sendSyncRequest_not_repeated_on_account_refresh(self) -> None:
        if not _wait_until(lambda: len(self.daemon.sync_requests) >= 1):
            self.fail("bridge never issued sendSyncRequest at startup")
        baseline = len(self.daemon.sync_requests)
        # Force a refresh — should NOT trigger another sync request,
        # otherwise repeated refreshes hammer the primary device.
        self.bridge._refresh_accounts()
        time.sleep(0.1)
        self.assertEqual(len(self.daemon.sync_requests), baseline)


class TestStartupSyncMultiAccount(unittest.TestCase):
    def test_one_request_per_account(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        base = Path(tmp.name)
        daemon_sock = str(base / "signal.sock")
        enqueue_sock = str(base / "enqueue.sock")
        panel_sock = str(base / "panel.sock")
        db_path = base / "messages.db"

        daemon = FakeSignalDaemon(daemon_sock)
        daemon.accounts = [
            {"uuid": "u1", "number": "+1111"},
            {"uuid": "u2", "number": "+2222"},
        ]
        self.addCleanup(daemon.stop)

        bridge = bridge_mod.Bridge(
            bridge_mod.BridgeConfig(
                db_path=db_path,
                daemon_socket=daemon_sock,
                enqueue_socket=enqueue_sock,
                panel_socket=panel_sock,
            ),
            accounts_refresh_seconds=60.0,
        )
        bridge.start()
        self.addCleanup(bridge.stop)

        if not _wait_until(lambda: len(daemon.sync_requests) >= 2):
            self.fail(f"expected 2 sync requests, got {len(daemon.sync_requests)}")
        time.sleep(0.1)
        accounts_requested = sorted(p.get("account") for p in daemon.sync_requests)
        self.assertEqual(accounts_requested, ["+1111", "+2222"])


if __name__ == "__main__":
    unittest.main()

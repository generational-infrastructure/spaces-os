"""Tests for spaces_signal.bridge (forwarder-only).

Spawns a tiny in-process FakeSignalDaemon over a unix socket, points the
bridge at it, and verifies incoming envelopes are persisted into
messages.db and disappearing messages are swept. Sending/approval moved to
the integration-signal MCP server, so the bridge owns no sockets and speaks
no send protocol — these tests exercise only the daemon → messages.db path.
No signal-cli binary, no actual JVM.
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
from collections.abc import Callable
from datetime import datetime
from pathlib import Path

from spaces_signal import bridge as bridge_mod
from spaces_signal import db as dbmod

# ── Fake signal-cli daemon ──────────────────────────────────────────


class _Wake:
    """socketpair wake so the fake daemon's accept select() exits
    instantly on teardown instead of paying an accept-timeout.
    """

    def __init__(self) -> None:
        r, w = socket.socketpair()
        r.setblocking(False)
        self.read_end = r
        self._write_end = w

    def wake(self) -> None:
        try:
            self._write_end.send(b"\x01")
        except OSError:
            pass

    def drain(self) -> None:
        try:
            while self.read_end.recv(64):
                pass
        except (BlockingIOError, OSError):
            pass

    def close(self) -> None:
        for s in (self._write_end, self.read_end):
            try:
                s.close()
            except OSError:
                pass


class FakeSignalDaemon:
    """Minimal JSON-RPC server over a unix socket that speaks just
    enough signal-cli to drive the forwarder. Each test mutates
    `accounts` to shape what the daemon advertises; `push_receive()`
    writes a `receive` notification to any currently-subscribed
    connection.
    """

    def __init__(self, sock_path: str) -> None:
        self.sock_path = sock_path
        self.accounts: list[dict] = []

        self.subscribed_conns: list[socket.socket] = []
        self.sync_requests: list[dict] = []
        self._lock = threading.Lock()

        self._srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._srv.bind(sock_path)
        self._srv.listen(8)

        self._stop = threading.Event()
        self._wake = _Wake()
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
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
        elif method == "subscribeReceive":
            with self._lock:
                if conn not in self.subscribed_conns:
                    self.subscribed_conns.append(conn)
            result = {}
        elif method == "sendSyncRequest":
            with self._lock:
                self.sync_requests.append(params)
            result = {}
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


# ── fixture base ────────────────────────────────────────────────────


class BridgeHarness(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name)

        self.daemon_sock = str(base / "signal.sock")
        self.db_path = base / "messages.db"

        self.daemon = FakeSignalDaemon(self.daemon_sock)
        self.daemon.accounts = [{"uuid": "acct-uuid", "number": "+15550000001"}]
        self.addCleanup(self.daemon.stop)

        self.bridge = bridge_mod.Bridge(
            bridge_mod.BridgeConfig(
                db_path=self.db_path,
                daemon_socket=self.daemon_sock,
            ),
            accounts_refresh_seconds=60.0,
        )
        self.bridge.start()
        self.addCleanup(self.bridge.stop)

        # Wait until the bridge has pulled the account snapshot and the
        # receiver has subscribed before pushing envelopes.
        if not _wait_until(lambda: bool(self.bridge._accounts_snapshot())):
            self.fail("accounts never populated from listAccounts")
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


class TestMessageExpiry(BridgeHarness):
    """Disappearing messages must actually leave messages.db. The read
    paths filter expired rows, but without the bridge's periodic sweep
    the plaintext would persist on disk forever.
    """

    def test_expire_once_deletes_expired_keeps_live(self) -> None:
        past = dbmod.now_ms() - 10_000
        with self.bridge._db_lock:
            dbmod.store_message(
                self.bridge.db,
                {
                    "uid": "exp",
                    "ts_ms": past,
                    "thread_id": "t",
                    "thread_kind": "dm",
                    "body": "secret",
                    "expires_at_ms": past,
                },
            )
            dbmod.store_message(
                self.bridge.db,
                {
                    "uid": "keep",
                    "ts_ms": dbmod.now_ms(),
                    "thread_id": "t",
                    "thread_kind": "dm",
                    "body": "stay",
                },
            )
        self.bridge._expire_once()
        with self.bridge._db_lock:
            uids = {
                r["uid"] for r in self.bridge.db.execute("SELECT uid FROM messages")
            }
        self.assertNotIn("exp", uids)
        self.assertIn("keep", uids)

    def test_expiry_thread_is_running(self) -> None:
        self.assertIn("bridge-expiry", {t.name for t in self.bridge._threads})


class TestMessageExpiryScheduled(unittest.TestCase):
    """The running bridge sweeps on startup (and on its interval), not
    only when _expire_once is called by hand.
    """

    def test_startup_sweep_removes_preexisting_expired(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        base = Path(tmp.name)
        daemon = FakeSignalDaemon(str(base / "signal.sock"))
        daemon.accounts = [{"uuid": "acct-uuid", "number": "+15550000001"}]
        self.addCleanup(daemon.stop)

        db_path = base / "messages.db"
        seed = dbmod.connect(db_path)
        past = dbmod.now_ms() - 10_000
        dbmod.store_message(
            seed,
            {
                "uid": "exp",
                "ts_ms": past,
                "thread_id": "t",
                "thread_kind": "dm",
                "body": "secret",
                "expires_at_ms": past,
            },
        )
        dbmod.store_message(
            seed,
            {
                "uid": "keep",
                "ts_ms": dbmod.now_ms(),
                "thread_id": "t",
                "thread_kind": "dm",
                "body": "stay",
            },
        )
        seed.close()

        br = bridge_mod.Bridge(
            bridge_mod.BridgeConfig(
                db_path=db_path,
                daemon_socket=str(base / "signal.sock"),
            ),
            accounts_refresh_seconds=60.0,
            expire_interval_seconds=0.05,
        )
        br.start()
        self.addCleanup(br.stop)

        def expired_gone() -> bool:
            with br._db_lock:
                uids = {r["uid"] for r in br.db.execute("SELECT uid FROM messages")}
            return "exp" not in uids and "keep" in uids

        self.assertTrue(_wait_until(expired_gone, timeout=3))


# ── pure helpers (no harness) ───────────────────────────────────────


class TestEnvelopeToMessage(unittest.TestCase):
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

    def test_envelope_to_message_sync_note_to_self(self) -> None:
        # A Note-to-Self typed on the primary phone reaches this linked
        # device as syncMessage.sentMessage (NOT dataMessage), with the
        # destination pointing back at our own account.
        out = bridge_mod.envelope_to_message(
            {
                "envelope": {
                    "sourceUuid": "acct-uuid",
                    "sourceName": "Me",
                    "timestamp": 1700000000000,
                    "syncMessage": {
                        "sentMessage": {
                            "destination": "+1",
                            "destinationUuid": "acct-uuid",
                            "timestamp": 1700000000000,
                            "message": "remember the milk",
                        }
                    },
                }
            },
            account={"uuid": "acct-uuid", "number": "+1"},
        )
        self.assertIsNotNone(out)
        self.assertEqual(out["thread_kind"], "self")
        self.assertEqual(out["thread_id"], "acct-uuid")
        self.assertEqual(out["body"], "remember the milk")

    def test_envelope_to_message_sync_sent_to_contact(self) -> None:
        # A message sent from another linked device to a real contact
        # also arrives as syncMessage.sentMessage; it must route to that
        # contact's DM thread, not note-to-self.
        out = bridge_mod.envelope_to_message(
            {
                "envelope": {
                    "sourceUuid": "acct-uuid",
                    "timestamp": 1700000000000,
                    "syncMessage": {
                        "sentMessage": {
                            "destinationUuid": "uuid-bob",
                            "timestamp": 1700000000000,
                            "message": "hi bob",
                        }
                    },
                }
            },
            account={"uuid": "acct-uuid", "number": "+1"},
        )
        self.assertIsNotNone(out)
        self.assertEqual(out["thread_kind"], "dm")
        self.assertEqual(out["thread_id"], "uuid-bob")
        self.assertEqual(out["body"], "hi bob")

    def test_envelope_to_message_sync_to_group(self) -> None:
        # Group sends from another linked device carry groupInfo inside
        # the sentMessage; route by group id.
        out = bridge_mod.envelope_to_message(
            {
                "envelope": {
                    "sourceUuid": "acct-uuid",
                    "timestamp": 1700000000000,
                    "syncMessage": {
                        "sentMessage": {
                            "timestamp": 1700000000000,
                            "message": "hi crew",
                            "groupInfo": {"groupId": "GROUP=1"},
                        }
                    },
                }
            },
            account={"uuid": "acct-uuid", "number": "+1"},
        )
        self.assertIsNotNone(out)
        self.assertEqual(out["thread_kind"], "group")
        self.assertEqual(out["thread_id"], "GROUP=1")


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


class TestAccountsHealthFile(unittest.TestCase):
    """After each successful listAccounts poll the bridge atomically
    exports accounts-health.json next to messages.db: `store` (entries in
    signal-cli's on-disk data/accounts.json; 0 if absent/unparseable) vs
    `loaded` (the daemon's listAccounts count) plus an iso8601 `updated`
    stamp. The signal MCP tool gate reads it to tell "never linked" from
    "linked but the daemon dropped the account at its startup network
    check" — the false 'not linked' hint this file exists to kill.
    """

    def _start_bridge(self, daemon_accounts: list[dict], store_content: str | None):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        base = Path(tmp.name)
        store_path = base / "signal-cli-data" / "accounts.json"
        if store_content is not None:
            store_path.parent.mkdir(parents=True)
            store_path.write_text(store_content)

        daemon = FakeSignalDaemon(str(base / "signal.sock"))
        daemon.accounts = daemon_accounts
        self.addCleanup(daemon.stop)

        bridge = bridge_mod.Bridge(
            bridge_mod.BridgeConfig(
                db_path=base / "messages.db",
                daemon_socket=daemon.sock_path,
                accounts_store_path=store_path,
            ),
            accounts_refresh_seconds=60.0,
        )
        bridge.start()
        self.addCleanup(bridge.stop)
        # Quiesce: wait for the receiver's subscribe so teardown can't race
        # the daemon's in-flight subscribeReceive response (broken pipe).
        if not _wait_until(lambda: len(daemon.subscribed_conns) >= 1):
            self.fail("bridge never subscribed")
        return base / "accounts-health.json"

    def _read_health(self, path: Path) -> dict:
        if not _wait_until(path.exists):
            self.fail("accounts-health.json never written")
        return json.loads(path.read_text())

    def test_store_vs_loaded_counts(self) -> None:
        # Two accounts on disk, only one loaded by the daemon — the torn
        # state the gate must be able to see.
        store = json.dumps({"accounts": [{"number": "+1111"}, {"number": "+2222"}]})
        health_path = self._start_bridge([{"uuid": "u1", "number": "+1111"}], store)
        health = self._read_health(health_path)
        self.assertEqual(health["store"], 2)
        self.assertEqual(health["loaded"], 1)
        # `updated` is a parseable iso8601 stamp.
        datetime.fromisoformat(health["updated"])

    def test_absent_store_counts_zero(self) -> None:
        health_path = self._start_bridge([{"uuid": "u1", "number": "+1111"}], None)
        health = self._read_health(health_path)
        self.assertEqual(health["store"], 0)
        self.assertEqual(health["loaded"], 1)

    def test_unparseable_store_counts_zero(self) -> None:
        health_path = self._start_bridge(
            [{"uuid": "u1", "number": "+1111"}], "{not json"
        )
        health = self._read_health(health_path)
        self.assertEqual(health["store"], 0)


class TestDaemonSocketDefault(unittest.TestCase):
    """The daemon socket default couples this module to signal-cli.nix,
    whose RuntimeDirectory=signal-cli exposes the JSON-RPC socket at
    `$XDG_RUNTIME_DIR/signal-cli/socket`.
    """

    def setUp(self) -> None:
        self._saved = {
            k: os.environ.get(k)
            for k in ("XDG_RUNTIME_DIR", "SPACES_SIGNAL_DAEMON_SOCKET")
        }
        os.environ["XDG_RUNTIME_DIR"] = "/run/user/1234"
        os.environ.pop("SPACES_SIGNAL_DAEMON_SOCKET", None)

    def tearDown(self) -> None:
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def test_daemon_default_matches_signal_cli_socket(self) -> None:
        self.assertEqual(
            bridge_mod._default_daemon_socket(),
            "/run/user/1234/signal-cli/socket",
        )

    def test_env_override_wins_for_daemon(self) -> None:
        os.environ["SPACES_SIGNAL_DAEMON_SOCKET"] = "/custom/daemon.sock"
        self.assertEqual(bridge_mod._default_daemon_socket(), "/custom/daemon.sock")


if __name__ == "__main__":
    unittest.main()

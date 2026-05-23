"""Tests for the `signal` CLI.

Exercises each subcommand in-process: DB-backed commands run against
a temp SQLite, daemon-backed commands against the FakeSignalDaemon
defined in test_bridge, and `send` against an in-process enqueue
listener that records the request and replies with canned shapes.
"""

from __future__ import annotations

import io
import json
import os
import select
import socket
import tempfile
import threading
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

from distro_signal import bridge as bridge_mod
from distro_signal import cli as cli_mod
from distro_signal import db as dbmod
from test_bridge import FakeSignalDaemon, _wait_until

# ── helpers ─────────────────────────────────────────────────────────


def _run(argv: list[str]) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        rc = cli_mod.main(argv)
    return rc, out.getvalue(), err.getvalue()


def _seed_messages(db_path: Path) -> None:
    db = dbmod.connect(db_path)
    ts = 1_700_000_000_000
    fixtures = [
        # DM with Alice — two messages.
        {
            "uid": "1",
            "ts_ms": ts,
            "thread_id": "uuid-alice",
            "thread_kind": "dm",
            "body": "hi from alice",
            "sender_uuid": "uuid-alice",
            "sender_name": "Alice",
        },
        {
            "uid": "2",
            "ts_ms": ts + 30_000,
            "thread_id": "uuid-alice",
            "thread_kind": "dm",
            "body": "are you free tomorrow?",
            "sender_uuid": "uuid-alice",
            "sender_name": "Alice",
        },
        # Group message.
        {
            "uid": "3",
            "ts_ms": ts + 60_000,
            "thread_id": "GROUP=1",
            "thread_kind": "group",
            "body": "team standup at 10",
            "sender_uuid": "uuid-bob",
            "sender_name": "Bob",
        },
        # Unrelated DM for search filtering.
        {
            "uid": "4",
            "ts_ms": ts + 90_000,
            "thread_id": "uuid-carol",
            "thread_kind": "dm",
            "body": "remember the cake",
            "sender_uuid": "uuid-carol",
            "sender_name": "Carol",
        },
    ]
    for msg in fixtures:
        dbmod.store_message(db, msg)
    db.close()


class _EnqueueStub:
    """Tiny unix-socket listener that captures the request lines it
    receives and replies with `response_for(req)`.
    """

    def __init__(self, sock_path: str, response_for):
        self.sock_path = sock_path
        self.requests: list[dict] = []
        self._response_for = response_for
        self._stop = threading.Event()
        self._wake = bridge_mod._SelectWake()
        try:
            os.unlink(sock_path)
        except FileNotFoundError:
            pass
        self._srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._srv.bind(sock_path)
        self._srv.listen(8)
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        # Same shutdown idiom as the production bridge: poke the
        # select() so the accept loop exits instantly instead of
        # waiting out the next timeout.
        self._wake.wake()
        try:
            self._srv.close()
        except OSError:
            pass
        self._thread.join(timeout=2.0)
        self._wake.close()

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
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn: socket.socket) -> None:
        try:
            f = conn.makefile("r", encoding="utf-8", newline="\n")
            line = f.readline()
            if not line:
                return
            req = json.loads(line)
            self.requests.append(req)
            resp = self._response_for(req)
            conn.sendall((json.dumps(resp) + "\n").encode("utf-8"))
        finally:
            conn.close()


class CliBase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name)
        self.db_path = base / "messages.db"
        self.runtime = base / "runtime"
        self.runtime.mkdir(mode=0o700)
        self._old_env = {
            k: os.environ.get(k)
            for k in (
                "DISTRO_SIGNAL_DB",
                "DISTRO_SIGNAL_ENQUEUE_SOCKET",
                "DISTRO_SIGNAL_DAEMON_SOCKET",
                "XDG_RUNTIME_DIR",
            )
        }
        os.environ["DISTRO_SIGNAL_DB"] = str(self.db_path)
        os.environ["XDG_RUNTIME_DIR"] = str(self.runtime)

    def tearDown(self) -> None:
        for k, v in self._old_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


# ── DB-backed reads ─────────────────────────────────────────────────


class TestThreads(CliBase):
    def setUp(self) -> None:
        super().setUp()
        _seed_messages(self.db_path)

    def test_threads_text_lists_all(self) -> None:
        rc, out, _ = _run(["threads"])
        self.assertEqual(rc, 0)
        # One row per thread, newest first → uuid-carol then GROUP=1 then uuid-alice.
        # Verify each thread id appears at least once and ordering is correct.
        idx_carol = out.find("uuid-carol")
        idx_group = out.find("GROUP=1")
        idx_alice = out.find("uuid-alice")
        self.assertTrue(idx_carol >= 0)
        self.assertTrue(idx_group >= 0)
        self.assertTrue(idx_alice >= 0)
        self.assertLess(idx_carol, idx_group)
        self.assertLess(idx_group, idx_alice)

    def test_threads_json_round_trip(self) -> None:
        rc, out, _ = _run(["threads", "--json"])
        self.assertEqual(rc, 0)
        parsed = json.loads(out)
        thread_ids = [r["thread_id"] for r in parsed]
        self.assertEqual(thread_ids, ["uuid-carol", "GROUP=1", "uuid-alice"])

    def test_threads_empty_when_db_empty(self) -> None:
        # Wipe seed.
        Path(self.db_path).unlink()
        rc, out, _ = _run(["threads"])
        self.assertEqual(rc, 0)
        self.assertIn("no threads", out)


class TestRead(CliBase):
    def setUp(self) -> None:
        super().setUp()
        _seed_messages(self.db_path)

    def test_read_returns_oldest_first(self) -> None:
        rc, out, _ = _run(["read", "uuid-alice"])
        self.assertEqual(rc, 0)
        idx_first = out.find("hi from alice")
        idx_second = out.find("are you free tomorrow")
        self.assertGreater(idx_first, 0)
        self.assertGreater(idx_second, 0)
        self.assertLess(idx_first, idx_second)

    def test_read_unknown_thread_says_no_messages(self) -> None:
        rc, out, _ = _run(["read", "nope"])
        self.assertEqual(rc, 0)
        self.assertIn("no messages", out)

    def test_read_json(self) -> None:
        rc, out, _ = _run(["read", "uuid-alice", "--json"])
        self.assertEqual(rc, 0)
        parsed = json.loads(out)
        self.assertEqual([r["uid"] for r in parsed], ["1", "2"])

    def test_read_since_filters(self) -> None:
        rc, out, _ = _run(["read", "uuid-alice", "--since", "1700000020000"])
        self.assertEqual(rc, 0)
        self.assertNotIn("hi from alice", out)
        self.assertIn("are you free tomorrow", out)


class TestSearch(CliBase):
    def setUp(self) -> None:
        super().setUp()
        _seed_messages(self.db_path)

    def test_search_matches_substring(self) -> None:
        rc, out, _ = _run(["search", "cake"])
        self.assertEqual(rc, 0)
        self.assertIn("Carol", out)
        self.assertNotIn("Alice", out)

    def test_search_no_match(self) -> None:
        rc, out, _ = _run(["search", "octopus"])
        self.assertEqual(rc, 0)
        self.assertIn("no matches", out)

    def test_search_json(self) -> None:
        rc, out, _ = _run(["search", "alice", "--json"])
        self.assertEqual(rc, 0)
        parsed = json.loads(out)
        self.assertTrue(parsed)
        self.assertTrue(all("alice" in (r.get("body") or "").lower() for r in parsed))


# ── daemon-backed reads ─────────────────────────────────────────────


class TestContactsGroups(CliBase):
    def setUp(self) -> None:
        super().setUp()
        sock_path = str(Path(self.tmp.name) / "signal.sock")
        self.daemon = FakeSignalDaemon(sock_path)
        self.addCleanup(self.daemon.stop)
        self.daemon.accounts = [{"uuid": "acct-uuid", "number": "+15550000001"}]
        self.daemon.contacts = [
            {
                "uuid": "uuid-bob",
                "number": "+15559998888",
                "name": "Bob the Builder",
            },
            {"uuid": "uuid-carol", "number": "+15557776666", "name": "Carol"},
        ]
        self.daemon.groups = [
            {"id": "GROUP=1", "name": "Team Crew", "members": [1, 2, 3]},
        ]
        os.environ["DISTRO_SIGNAL_DAEMON_SOCKET"] = sock_path

    def test_contacts_text(self) -> None:
        rc, out, _ = _run(["contacts"])
        self.assertEqual(rc, 0)
        self.assertIn("Bob the Builder", out)
        self.assertIn("+15559998888", out)

    def test_contacts_json(self) -> None:
        rc, out, _ = _run(["contacts", "--json"])
        self.assertEqual(rc, 0)
        parsed = json.loads(out)
        self.assertEqual(len(parsed), 2)

    def test_groups_text(self) -> None:
        rc, out, _ = _run(["groups"])
        self.assertEqual(rc, 0)
        self.assertIn("Team Crew", out)
        self.assertIn("members=  3", out)
        self.assertIn("GROUP=1", out)

    def test_no_accounts_returns_error(self) -> None:
        self.daemon.accounts = []
        rc, out, err = _run(["contacts"])
        self.assertNotEqual(rc, 0)
        self.assertIn("no linked Signal account", err)

    def test_daemon_unreachable_returns_error(self) -> None:
        os.environ["DISTRO_SIGNAL_DAEMON_SOCKET"] = "/nonexistent.sock"
        rc, _, err = _run(["contacts"])
        self.assertNotEqual(rc, 0)
        # When the socket *file* is missing (vs. ECONNREFUSED on a
        # half-up daemon), the CLI prints an onboarding hint pointing
        # at `signal-cli link` instead of a bare connect-failure trace.
        self.assertIn("signal-cli link", err)


# ── send / enqueue ──────────────────────────────────────────────────


class TestSend(CliBase):
    def _start_stub(self, response_for):
        sock_path = str(Path(self.tmp.name) / "enqueue.sock")
        os.environ["DISTRO_SIGNAL_ENQUEUE_SOCKET"] = sock_path
        stub = _EnqueueStub(sock_path, response_for)
        self.addCleanup(stub.stop)
        if not _wait_until(lambda: os.path.exists(sock_path)):
            self.fail("enqueue stub never bound")
        return stub

    def test_pending_send_prints_token(self) -> None:
        stub = self._start_stub(
            lambda req: {
                "ok": True,
                "pending": True,
                "token": "abc-token",
                "display_name": "Alice",
            }
        )
        rc, out, _ = _run(["send", "+15559998888", "hi alice"])
        self.assertEqual(rc, 0)
        self.assertIn("pending", out)
        self.assertIn("abc-token", out)
        self.assertIn("Alice", out)
        # Bridge actually saw the right request.
        self.assertEqual(len(stub.requests), 1)
        self.assertEqual(stub.requests[0]["op"], "send")
        self.assertEqual(stub.requests[0]["to"], "+15559998888")
        self.assertEqual(stub.requests[0]["body"], "hi alice")

    def test_self_send_prints_sent(self) -> None:
        self._start_stub(lambda req: {"ok": True, "to_self": True})
        rc, out, _ = _run(["send", "+15550000001", "note"])
        self.assertEqual(rc, 0)
        self.assertIn("sent to self", out)

    def test_bridge_error_propagates_to_stderr(self) -> None:
        self._start_stub(lambda req: {"ok": False, "error": "no linked Signal account"})
        rc, _, err = _run(["send", "+1", "x"])
        self.assertNotEqual(rc, 0)
        self.assertIn("no linked Signal account", err)

    def test_send_json_round_trips(self) -> None:
        self._start_stub(
            lambda req: {
                "ok": True,
                "pending": True,
                "token": "xyz",
                "display_name": "Bob",
            }
        )
        rc, out, _ = _run(["send", "+15559998888", "hi", "--json"])
        self.assertEqual(rc, 0)
        parsed = json.loads(out)
        self.assertTrue(parsed["pending"])
        self.assertEqual(parsed["token"], "xyz")

    def test_bridge_unreachable_returns_error(self) -> None:
        os.environ["DISTRO_SIGNAL_ENQUEUE_SOCKET"] = "/nonexistent.sock"
        rc, _, err = _run(["send", "+15559998888", "hi"])
        self.assertNotEqual(rc, 0)
        # Same onboarding hint as contacts/groups; the send path is
        # the most common first-touch point so the hint matters most
        # here.
        self.assertIn("signal-cli link", err)


# ── argparse plumbing ───────────────────────────────────────────────


class TestParser(unittest.TestCase):
    def test_no_subcommand_exits_nonzero(self) -> None:
        with self.assertRaises(SystemExit) as cm:
            with redirect_stderr(io.StringIO()):
                cli_mod.main([])
        self.assertNotEqual(cm.exception.code, 0)

    def test_unknown_subcommand_exits_nonzero(self) -> None:
        with self.assertRaises(SystemExit) as cm:
            with redirect_stderr(io.StringIO()):
                cli_mod.main(["frobnicate"])
        self.assertNotEqual(cm.exception.code, 0)


if __name__ == "__main__":
    unittest.main()

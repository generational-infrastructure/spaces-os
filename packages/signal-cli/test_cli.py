"""Tests for the `signal` CLI.

Exercises each subcommand in-process: DB-backed commands run against
a temp SQLite, bridge-proxied commands (`contacts` / `groups` / `send`)
against an in-process enqueue listener that records the request and
replies with canned shapes.
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

from spaces_signal import bridge as bridge_mod
from spaces_signal import cli as cli_mod
from spaces_signal import db as dbmod
from test_bridge import _wait_until

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
                "SPACES_SIGNAL_DB",
                "SPACES_SIGNAL_ENQUEUE_SOCKET",
                "XDG_RUNTIME_DIR",
            )
        }
        os.environ["SPACES_SIGNAL_DB"] = str(self.db_path)
        os.environ["XDG_RUNTIME_DIR"] = str(self.runtime)
        # Default-shape: a configured-and-running system has the bridge
        # enqueue socket present (bind-mounted from outside the
        # sandbox). Touch an empty file so the CLI's "is the signal
        # stack up?" check passes — tests that need to simulate an
        # unconfigured host remove it explicitly.
        self.enqueue_sock_default = (
            self.runtime / "spaces-signal" / "sandbox" / "enqueue.sock"
        )
        self.enqueue_sock_default.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.enqueue_sock_default.touch()

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
        # Drop the seeded rows but keep the file — production has the
        # bridge always present to create/maintain messages.db, so the
        # sandbox-side CLI is never asked to open a non-existent file.
        writer = dbmod.connect(self.db_path)
        writer.execute("DELETE FROM messages")
        writer.close()
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


# ── bridge-proxied daemon reads ─────────────────────────────────────


class TestContactsGroups(CliBase):
    """`signal contacts` / `signal groups` now talk to the bridge's
    enqueue socket — the daemon socket is no longer in the sandbox."""

    def setUp(self) -> None:
        super().setUp()
        # Replace the empty placeholder with a real listener.
        self.enqueue_sock_default.unlink()
        self._responses: dict[str, dict] = {
            "contacts": {
                "ok": True,
                "contacts": [
                    {
                        "uuid": "uuid-bob",
                        "number": "+15559998888",
                        "name": "Bob the Builder",
                    },
                    {
                        "uuid": "uuid-carol",
                        "number": "+15557776666",
                        "name": "Carol",
                    },
                ],
            },
            "groups": {
                "ok": True,
                "groups": [
                    {"id": "GROUP=1", "name": "Team Crew", "members": [1, 2, 3]},
                ],
            },
        }
        self.stub = _EnqueueStub(
            str(self.enqueue_sock_default),
            lambda req: self._responses.get(
                req.get("op", ""),
                {"ok": False, "error": f"unknown op: {req.get('op')!r}"},
            ),
        )
        self.addCleanup(self.stub.stop)

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

    def test_no_accounts_propagates_bridge_error(self) -> None:
        self._responses["contacts"] = {
            "ok": False,
            "error": "no linked Signal account",
        }
        rc, _, err = _run(["contacts"])
        self.assertNotEqual(rc, 0)
        self.assertIn("no linked Signal account", err)

    def test_bridge_socket_missing_returns_friendly_error(self) -> None:
        # Tear the stub down so the socket disappears entirely.
        self.stub.stop()
        os.unlink(self.stub.sock_path)
        rc, _, err = _run(["contacts"])
        self.assertNotEqual(rc, 0)
        self.assertIn("signal-cli link", err)

    def test_bridge_socket_present_but_not_listening(self) -> None:
        # Stub down but file remains → connect() returns ECONNREFUSED.
        self.stub.stop()
        rc, _, err = _run(["contacts"])
        self.assertNotEqual(rc, 0)
        self.assertIn("bridge unreachable", err)


# ── send / enqueue ──────────────────────────────────────────────────


class TestSend(CliBase):
    def _start_stub(self, response_for):
        sock_path = str(Path(self.tmp.name) / "enqueue.sock")
        os.environ["SPACES_SIGNAL_ENQUEUE_SOCKET"] = sock_path
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

    def test_pending_card_surfaces_raw_recipient(self) -> None:
        # Bridge returns a display_name AND the verbatim recipient.
        # The CLI's pending card must include both so the user can
        # verify the actual destination — display_name alone is
        # spoofable by anyone who controls a Signal profile.
        self._start_stub(
            lambda req: {
                "ok": True,
                "pending": True,
                "token": "tk",
                "display_name": "Alice",
                "recipient": "+15559998888",
            }
        )
        rc, out, _ = _run(["send", "+15559998888", "hi"])
        self.assertEqual(rc, 0)
        self.assertIn("Alice", out)
        self.assertIn("+15559998888", out)

    def test_pending_card_omits_redundant_label_when_no_display_name(self) -> None:
        # Bridge didn't resolve a friendly name; print the recipient
        # alone without the awkward "+1555…  <+1555…>" doubling.
        self._start_stub(
            lambda req: {
                "ok": True,
                "pending": True,
                "token": "tk",
                "display_name": "+15559998888",
                "recipient": "+15559998888",
            }
        )
        rc, out, _ = _run(["send", "+15559998888", "hi"])
        self.assertEqual(rc, 0)
        # "to:" line should appear exactly once for the recipient,
        # not as "+15559998888  <+15559998888>".
        self.assertNotIn("+15559998888  <+15559998888>", out)

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
        os.environ["SPACES_SIGNAL_ENQUEUE_SOCKET"] = "/nonexistent.sock"
        rc, _, err = _run(["send", "+15559998888", "hi"])
        self.assertNotEqual(rc, 0)
        # Same onboarding hint as contacts/groups; the send path is
        # the most common first-touch point so the hint matters most
        # here.
        self.assertIn("signal-cli link", err)


# ── unconfigured-host hint ──────────────────────────────────────────


class TestUnconfigured(CliBase):
    """Regression: a fresh host where the user has never run
    `signal-cli link` shipped the systemd units in skipped state, so
    neither the daemon nor bridge socket exists. Pre-fix, the DB-
    backed reads opened (and silently created) an empty messages.db,
    then printed "(no threads)" / "(no messages…)" to stdout with
    rc=0. The agent took that as "configured but empty" and
    confidently told the user setup was complete — until the first
    command that actually hit the daemon (`signal contacts`) blew up
    with "daemon socket missing".

    Post-fix every command surfaces the onboarding hint on stderr
    and exits non-zero before the DB is touched, so the agent sees
    the real state on its very first call.
    """

    def setUp(self) -> None:
        super().setUp()
        # Strip the dummy enqueue socket CliBase touches by default —
        # this class simulates the unlinked-host case from the bug
        # report (bridge has never started, so its socket file does
        # not exist).
        self.enqueue_sock_default.unlink()

    def _assert_unconfigured(self, rc: int, out: str, err: str) -> None:
        # 1. Non-zero exit so bash callers (and the agent) trip on it.
        self.assertNotEqual(rc, 0, f"expected non-zero rc, stdout={out!r}")
        # 2. stdout MUST be silent. The original failure was the
        #    misleading "(no threads)" landing on stdout where the
        #    agent took it as a legitimate empty-state answer.
        self.assertEqual(out, "", f"stdout leaked unconfigured-state content: {out!r}")
        # 3. The hint must point at the actual fix.
        self.assertIn("signal-cli link", err)

    def test_threads_does_not_pretend_db_is_truth(self) -> None:
        rc, out, err = _run(["threads"])
        self._assert_unconfigured(rc, out, err)
        # Belt-and-braces: the exact lie from the bug report
        # ("(no threads)") must NOT appear anywhere.
        self.assertNotIn("no threads", out + err)

    def test_read_does_not_pretend_db_is_truth(self) -> None:
        rc, out, err = _run(["read", "uuid-alice"])
        self._assert_unconfigured(rc, out, err)
        self.assertNotIn("no messages", out + err)

    def test_search_does_not_pretend_db_is_truth(self) -> None:
        rc, out, err = _run(["search", "hello"])
        self._assert_unconfigured(rc, out, err)
        self.assertNotIn("no matches", out + err)

    def test_signal_running_is_only_enqueue_socket(self) -> None:
        # Belt-and-braces for the bridge-only architecture: even if
        # a stray signal-cli/socket file were present under runtime
        # (left over from before the daemon-bind was removed, say),
        # the CLI must still report unconfigured when the bridge
        # enqueue socket is missing. The daemon socket is no longer
        # reachable from the sandbox so it must not influence the
        # readiness check.
        stray = self.runtime / "signal-cli" / "socket"
        stray.parent.mkdir(parents=True, exist_ok=True)
        stray.touch()
        rc, out, err = _run(["threads"])
        self._assert_unconfigured(rc, out, err)


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


class TestEnqueueSocketPathDefault(unittest.TestCase):
    """Couples the CLI's enqueue-socket default to signal-cli.nix.

    The sandbox bind-mounts `$XDG_RUNTIME_DIR/spaces-signal/sandbox`
    (see modules/nixos/signal-cli.nix). The CLI's idea of where the
    enqueue socket lives MUST resolve inside that bind-mounted dir,
    otherwise the agent inside the sandbox would look for the socket
    in a path that the bind-mount doesn't cover and `signal threads`
    would report "infrastructure not running" forever, even after
    `signal-cli link`.
    """

    def setUp(self) -> None:
        self._saved = {
            k: os.environ.get(k)
            for k in ("XDG_RUNTIME_DIR", "SPACES_SIGNAL_ENQUEUE_SOCKET")
        }
        os.environ["XDG_RUNTIME_DIR"] = "/run/user/4242"
        os.environ.pop("SPACES_SIGNAL_ENQUEUE_SOCKET", None)

    def tearDown(self) -> None:
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def test_default_lives_inside_sandbox_subdir(self) -> None:
        self.assertEqual(
            cli_mod._enqueue_socket_path(),
            "/run/user/4242/spaces-signal/sandbox/enqueue.sock",
        )

    def test_env_override_wins(self) -> None:
        os.environ["SPACES_SIGNAL_ENQUEUE_SOCKET"] = "/elsewhere/sock"
        self.assertEqual(cli_mod._enqueue_socket_path(), "/elsewhere/sock")


if __name__ == "__main__":
    unittest.main()

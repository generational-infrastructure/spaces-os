"""Tests for spaces_signal.db — schema, idempotency, thread/queue queries."""

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from spaces_signal import db as dbmod


def _msg(uid: str, **kwargs) -> dict:
    base = {
        "uid": uid,
        "ts_ms": 1_700_000_000_000,
        "thread_id": "thread-A",
        "thread_kind": "dm",
        "body": f"hello {uid}",
        "sender_uuid": "uuid-alice",
        "sender_name": "Alice",
    }
    base.update(kwargs)
    return base


class DbBase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "messages.db"
        self.db = dbmod.connect(self.path)
        self.addCleanup(self.db.close)


class TestSchema(DbBase):
    def test_schema_creates_messages_and_pending_tables(self) -> None:
        names = {
            r[0]
            for r in self.db.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            )
        }
        self.assertIn("messages", names)
        self.assertIn("pending_sends", names)

    def test_default_db_path_honours_env(self) -> None:
        with mock.patch.dict(os.environ, {"SPACES_SIGNAL_DB": "/x/y.db"}):
            self.assertEqual(dbmod.default_db_path(), Path("/x/y.db"))


class TestStoreMessage(DbBase):
    def test_store_and_query_round_trip(self) -> None:
        self.assertTrue(dbmod.store_message(self.db, _msg("a")))
        rows = dbmod.query_messages(self.db, thread_id="thread-A")
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["body"], "hello a")
        self.assertEqual(rows[0]["sender_name"], "Alice")

    def test_dedup_on_uid(self) -> None:
        self.assertTrue(dbmod.store_message(self.db, _msg("a")))
        # Re-insert with the same uid but different body — must NOT update;
        # idempotent insert means the bridge can replay the same envelope
        # (signal-cli ack retries) without double-counting.
        self.assertFalse(dbmod.store_message(self.db, _msg("a", body="ignored-replay")))
        rows = dbmod.query_messages(self.db, thread_id="thread-A")
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["body"], "hello a")

    def test_attachments_and_metadata_serialised_as_json(self) -> None:
        dbmod.store_message(
            self.db,
            _msg(
                "a",
                attachments_json=[{"id": "1", "ct": "image/png"}],
                metadata_json={"raw": {"envelope": "..."}},
            ),
        )
        row = self.db.execute(
            "SELECT attachments_json, metadata_json FROM messages WHERE uid='a'"
        ).fetchone()
        self.assertIn('"id": "1"', row["attachments_json"])
        self.assertIn('"envelope"', row["metadata_json"])

    def test_missing_required_field_raises(self) -> None:
        with self.assertRaises(ValueError):
            dbmod.store_message(self.db, {"uid": "x"})

    def test_received_at_defaults_to_now(self) -> None:
        before = dbmod.now_ms()
        dbmod.store_message(self.db, _msg("a"))
        after = dbmod.now_ms()
        ts = self.db.execute(
            "SELECT received_at_ms FROM messages WHERE uid='a'"
        ).fetchone()["received_at_ms"]
        self.assertGreaterEqual(ts, before)
        self.assertLessEqual(ts, after)

    def test_expired_messages_are_filtered_from_queries(self) -> None:
        past = dbmod.now_ms() - 10_000
        dbmod.store_message(self.db, _msg("expired", expires_at_ms=past))
        dbmod.store_message(self.db, _msg("alive"))
        rows = dbmod.query_messages(self.db, thread_id="thread-A")
        uids = {r["uid"] for r in rows}
        self.assertEqual(uids, {"alive"})

    def test_expire_messages_vacuum_removes_rows(self) -> None:
        past = dbmod.now_ms() - 10_000
        future = dbmod.now_ms() + 60_000
        dbmod.store_message(self.db, _msg("e1", expires_at_ms=past))
        dbmod.store_message(self.db, _msg("e2", expires_at_ms=past))
        dbmod.store_message(self.db, _msg("k1", expires_at_ms=future))
        dbmod.store_message(self.db, _msg("k2"))  # no expiry
        deleted = dbmod.expire_messages(self.db)
        self.assertEqual(deleted, 2)
        remaining = {r["uid"] for r in self.db.execute("SELECT uid FROM messages")}
        self.assertEqual(remaining, {"k1", "k2"})


class TestQueryMessages(DbBase):
    def setUp(self) -> None:
        super().setUp()
        ts = 1_700_000_000_000
        for i in range(5):
            dbmod.store_message(
                self.db,
                _msg(
                    f"m{i}",
                    thread_id="dm-alice" if i % 2 == 0 else "group-X",
                    thread_kind="dm" if i % 2 == 0 else "group",
                    ts_ms=ts + i * 60_000,
                    body=f"msg {i} {'evens' if i % 2 == 0 else 'odds'}",
                ),
            )

    def test_thread_filter_returns_only_matching(self) -> None:
        rows = dbmod.query_messages(self.db, thread_id="group-X")
        self.assertEqual({r["uid"] for r in rows}, {"m1", "m3"})

    def test_results_are_newest_first(self) -> None:
        rows = dbmod.query_messages(self.db)
        self.assertEqual([r["uid"] for r in rows], ["m4", "m3", "m2", "m1", "m0"])

    def test_since_until_window(self) -> None:
        rows = dbmod.query_messages(
            self.db,
            since_ms=1_700_000_060_000,
            until_ms=1_700_000_180_000,
        )
        self.assertEqual({r["uid"] for r in rows}, {"m1", "m2", "m3"})

    def test_limit(self) -> None:
        rows = dbmod.query_messages(self.db, limit=2)
        self.assertEqual(len(rows), 2)
        self.assertEqual([r["uid"] for r in rows], ["m4", "m3"])

    def test_body_query_substring(self) -> None:
        rows = dbmod.query_messages(self.db, body_query="evens")
        self.assertEqual({r["uid"] for r in rows}, {"m0", "m2", "m4"})


class TestListThreads(DbBase):
    def setUp(self) -> None:
        super().setUp()
        ts = 1_700_000_000_000
        dbmod.store_message(
            self.db,
            _msg("a1", thread_id="dm-alice", ts_ms=ts, body="hi"),
        )
        dbmod.store_message(
            self.db,
            _msg("a2", thread_id="dm-alice", ts_ms=ts + 1000, body="newer"),
        )
        dbmod.store_message(
            self.db,
            _msg(
                "g1",
                thread_id="group-X",
                thread_kind="group",
                ts_ms=ts - 1000,
                body="oldest",
            ),
        )

    def test_one_row_per_thread_ordered_by_latest(self) -> None:
        rows = dbmod.list_threads(self.db)
        self.assertEqual([r["thread_id"] for r in rows], ["dm-alice", "group-X"])

    def test_preview_is_last_body_and_count_matches(self) -> None:
        rows = dbmod.list_threads(self.db)
        previews = {r["thread_id"]: r for r in rows}
        self.assertEqual(previews["dm-alice"]["last_body"], "newer")
        self.assertEqual(previews["dm-alice"]["message_count"], 2)
        self.assertEqual(previews["group-X"]["message_count"], 1)


class TestPendingSends(DbBase):
    def test_insert_and_list(self) -> None:
        dbmod.insert_pending(
            self.db,
            token="tok1",
            recipient="+15551234",
            body="hi",
            display_name="Bob",
        )
        rows = dbmod.list_pending(self.db)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["state"], "pending")
        self.assertEqual(rows[0]["display_name"], "Bob")

    def test_get_pending_by_token(self) -> None:
        dbmod.insert_pending(self.db, token="tok2", recipient="+15551234", body="x")
        row = dbmod.get_pending(self.db, "tok2")
        self.assertIsNotNone(row)
        self.assertEqual(row["recipient"], "+15551234")

    def test_get_pending_missing_returns_none(self) -> None:
        self.assertIsNone(dbmod.get_pending(self.db, "nope"))

    def test_mark_pending_changes_state(self) -> None:
        dbmod.insert_pending(self.db, token="t", recipient="+1", body="x")
        self.assertTrue(dbmod.mark_pending(self.db, "t", state="approved"))
        row = dbmod.get_pending(self.db, "t")
        self.assertEqual(row["state"], "approved")
        self.assertIsNotNone(row["decision_at"])

    def test_mark_pending_returns_false_when_unchanged(self) -> None:
        dbmod.insert_pending(self.db, token="t", recipient="+1", body="x")
        self.assertTrue(dbmod.mark_pending(self.db, "t", state="approved"))
        # Setting the same state again is a no-op.
        self.assertFalse(dbmod.mark_pending(self.db, "t", state="approved"))

    def test_mark_pending_records_error_on_failure(self) -> None:
        dbmod.insert_pending(self.db, token="t", recipient="+1", body="x")
        dbmod.mark_pending(self.db, "t", state="failed", error="signal-cli refused")
        row = dbmod.get_pending(self.db, "t")
        self.assertEqual(row["state"], "failed")
        self.assertEqual(row["error"], "signal-cli refused")

    def test_invalid_state_rejected(self) -> None:
        dbmod.insert_pending(self.db, token="t", recipient="+1", body="x")
        with self.assertRaises(ValueError):
            dbmod.mark_pending(self.db, "t", state="not-a-state")

    def test_claim_pending_wins_from_pending(self) -> None:
        dbmod.insert_pending(self.db, token="t", recipient="+1", body="x")
        self.assertTrue(dbmod.claim_pending(self.db, "t", state="approved"))
        self.assertEqual(dbmod.get_pending(self.db, "t")["state"], "approved")

    def test_claim_pending_second_claim_loses(self) -> None:
        # Once a row leaves 'pending', no further claim can win — this
        # is what stops a deny from "cancelling" an already-approved
        # send while signal-cli dispatches it anyway.
        dbmod.insert_pending(self.db, token="t", recipient="+1", body="x")
        self.assertTrue(dbmod.claim_pending(self.db, "t", state="approved"))
        self.assertFalse(dbmod.claim_pending(self.db, "t", state="denied"))
        self.assertEqual(dbmod.get_pending(self.db, "t")["state"], "approved")

    def test_claim_pending_cannot_flip_sent_to_denied(self) -> None:
        dbmod.insert_pending(self.db, token="t", recipient="+1", body="x")
        dbmod.claim_pending(self.db, "t", state="approved")
        dbmod.mark_pending(self.db, "t", state="sent")
        self.assertFalse(dbmod.claim_pending(self.db, "t", state="denied"))
        self.assertEqual(dbmod.get_pending(self.db, "t")["state"], "sent")

    def test_claim_pending_rejects_terminal_state(self) -> None:
        dbmod.insert_pending(self.db, token="t", recipient="+1", body="x")
        with self.assertRaises(ValueError):
            dbmod.claim_pending(self.db, "t", state="sent")

    def test_claim_pending_unknown_token_returns_false(self) -> None:
        self.assertFalse(dbmod.claim_pending(self.db, "nope", state="approved"))

    def test_list_pending_filters_by_state(self) -> None:
        dbmod.insert_pending(self.db, token="a", recipient="+1", body="x")
        dbmod.insert_pending(self.db, token="b", recipient="+2", body="y")
        dbmod.mark_pending(self.db, "b", state="approved")
        pending = {r["token"] for r in dbmod.list_pending(self.db)}
        approved = {
            r["token"] for r in dbmod.list_pending(self.db, states=["approved"])
        }
        self.assertEqual(pending, {"a"})
        self.assertEqual(approved, {"b"})


class TestConnectReadonly(unittest.TestCase):
    """The sandbox-side `signal` CLI MUST open the DB read-only.
    Any write attempt — INSERT, UPDATE, DELETE, CREATE — must be
    rejected at the SQLite layer, so a prompt-injected agent
    cannot forge inbound messages or flip pending_sends to 'sent'
    without panel approval.
    """

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "messages.db"
        # Bridge-side connect to materialise the schema and one row.
        writer = dbmod.connect(self.path)
        dbmod.store_message(
            writer,
            {
                "uid": "u1",
                "ts_ms": 1_700_000_000_000,
                "thread_id": "t1",
                "thread_kind": "dm",
                "body": "hi",
            },
        )
        writer.close()

    def test_reads_work(self) -> None:
        ro = dbmod.connect_readonly(self.path)
        self.addCleanup(ro.close)
        rows = dbmod.query_messages(ro)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["body"], "hi")

    def test_insert_rejected(self) -> None:
        ro = dbmod.connect_readonly(self.path)
        self.addCleanup(ro.close)
        import sqlite3

        with self.assertRaises(sqlite3.OperationalError):
            ro.execute(
                "INSERT INTO messages (uid, ts_ms, received_at_ms, thread_id, thread_kind)"
                " VALUES ('forged', 0, 0, 't', 'dm')"
            )

    def test_update_rejected(self) -> None:
        ro = dbmod.connect_readonly(self.path)
        self.addCleanup(ro.close)
        import sqlite3

        with self.assertRaises(sqlite3.OperationalError):
            ro.execute("UPDATE messages SET body = 'tampered' WHERE uid = 'u1'")

    def test_create_table_rejected(self) -> None:
        ro = dbmod.connect_readonly(self.path)
        self.addCleanup(ro.close)
        import sqlite3

        with self.assertRaises(sqlite3.OperationalError):
            ro.execute("CREATE TABLE evil (x INTEGER)")

    def test_missing_file_raises(self) -> None:
        missing = Path(self.tmp.name) / "nope.db"
        import sqlite3

        with self.assertRaises(sqlite3.OperationalError):
            dbmod.connect_readonly(missing)


if __name__ == "__main__":
    unittest.main()

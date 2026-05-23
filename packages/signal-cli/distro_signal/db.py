"""SQLite schema + helpers shared by the signal CLI and bridge.

The store lives at $DISTRO_SIGNAL_DB (default
~/.local/state/distro/signal/messages.db). Two tables:

* `messages` — append-only inbox. Idempotent on `(uid)`; the bridge
  may legitimately replay the same envelope (signal-cli ack semantics)
  and the dedup prevents double-counting in thread reads.

* `pending_sends` — outbound sends queued by the agent that require
  the human to approve through the chat panel. The bridge owns state
  transitions; the agent-facing CLI only ever INSERTs into 'pending'.

Both tables store timestamps as integer ms-since-epoch (matching the
Signal protocol envelope timestamps) so the agent never has to
think about timezones — UTC ISO conversion happens at the print layer.
"""

from __future__ import annotations

import json
import os
import sqlite3
import time
from pathlib import Path
from typing import Iterable

SCHEMA = """
CREATE TABLE IF NOT EXISTS messages (
  id               INTEGER PRIMARY KEY,
  uid              TEXT    NOT NULL UNIQUE,
  account_uuid     TEXT,
  ts_ms            INTEGER NOT NULL,
  received_at_ms   INTEGER NOT NULL,
  sender_uuid      TEXT,
  sender_name      TEXT,
  sender_number    TEXT,
  thread_id        TEXT    NOT NULL,
  thread_kind      TEXT    NOT NULL,
  body             TEXT,
  attachments_json TEXT,
  expires_at_ms    INTEGER,
  metadata_json    TEXT
);
CREATE INDEX IF NOT EXISTS idx_messages_thread_ts
  ON messages(thread_id, ts_ms DESC);
CREATE INDEX IF NOT EXISTS idx_messages_ts
  ON messages(ts_ms DESC);

CREATE TABLE IF NOT EXISTS pending_sends (
  token        TEXT PRIMARY KEY,
  created_at   INTEGER NOT NULL,
  account_uuid TEXT,
  recipient    TEXT NOT NULL,
  display_name TEXT,
  body         TEXT NOT NULL,
  state        TEXT NOT NULL,
  decision_at  INTEGER,
  error        TEXT
);
CREATE INDEX IF NOT EXISTS idx_pending_state
  ON pending_sends(state, created_at);
"""

VALID_STATES = frozenset({"pending", "approved", "sent", "denied", "failed"})


def default_db_path() -> Path:
    env = os.environ.get("DISTRO_SIGNAL_DB")
    if env:
        return Path(env)
    state = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return Path(state) / "distro" / "signal" / "messages.db"


def connect(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    # check_same_thread=False: the bridge serialises writes via its
    # own db_lock and the CLI workers each only ever hold one thread.
    # The GIL keeps individual sqlite3 calls atomic; WAL handles
    # reader/writer concurrency across processes.
    db = sqlite3.connect(str(path), isolation_level=None, check_same_thread=False)
    db.row_factory = sqlite3.Row
    # WAL keeps the read CLI (sandbox) from blocking the bridge writer
    # and vice versa — both processes touch the same file concurrently.
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=NORMAL")
    db.execute("PRAGMA foreign_keys=ON")
    init_schema(db)
    return db


def init_schema(db: sqlite3.Connection) -> None:
    db.executescript(SCHEMA)


def now_ms() -> int:
    return int(time.time() * 1000)


def store_message(db: sqlite3.Connection, msg: dict) -> bool:
    """INSERT OR IGNORE a normalised message dict.

    Required keys: uid, ts_ms, thread_id, thread_kind.
    Returns True iff a new row was inserted (False on dedup).
    """
    for required in ("uid", "ts_ms", "thread_id", "thread_kind"):
        if required not in msg:
            raise ValueError(f"store_message: missing required field {required!r}")

    attachments = msg.get("attachments_json")
    if isinstance(attachments, (list, dict)):
        attachments = json.dumps(attachments)
    metadata = msg.get("metadata_json")
    if isinstance(metadata, (list, dict)):
        metadata = json.dumps(metadata)

    cur = db.execute(
        """INSERT OR IGNORE INTO messages
           (uid, account_uuid, ts_ms, received_at_ms,
            sender_uuid, sender_name, sender_number,
            thread_id, thread_kind, body,
            attachments_json, expires_at_ms, metadata_json)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            msg["uid"],
            msg.get("account_uuid"),
            int(msg["ts_ms"]),
            int(msg.get("received_at_ms") or now_ms()),
            msg.get("sender_uuid"),
            msg.get("sender_name"),
            msg.get("sender_number"),
            msg["thread_id"],
            msg["thread_kind"],
            msg.get("body"),
            attachments,
            msg.get("expires_at_ms"),
            metadata,
        ),
    )
    return cur.rowcount == 1


def query_messages(
    db: sqlite3.Connection,
    *,
    thread_id: str | None = None,
    since_ms: int | None = None,
    until_ms: int | None = None,
    body_query: str | None = None,
    limit: int = 100,
) -> list[dict]:
    """Filtered message read. Newest first by default."""
    clauses: list[str] = []
    params: list = []

    # Disappearing-message hygiene: never surface anything past its
    # configured expiry. The bridge runs a periodic vacuum that actually
    # deletes these rows; this filter is the belt to that vacuum's braces.
    clauses.append("(expires_at_ms IS NULL OR expires_at_ms > ?)")
    params.append(now_ms())

    if thread_id is not None:
        clauses.append("thread_id = ?")
        params.append(thread_id)
    if since_ms is not None:
        clauses.append("ts_ms >= ?")
        params.append(int(since_ms))
    if until_ms is not None:
        clauses.append("ts_ms <= ?")
        params.append(int(until_ms))
    if body_query:
        clauses.append("body LIKE ?")
        params.append(f"%{body_query}%")

    sql = (
        "SELECT * FROM messages WHERE "
        + " AND ".join(clauses)
        + " ORDER BY ts_ms DESC LIMIT ?"
    )
    params.append(int(limit))
    rows = db.execute(sql, params).fetchall()
    return [dict(r) for r in rows]


def list_threads(db: sqlite3.Connection, *, limit: int = 50) -> list[dict]:
    """One row per `thread_id`, ordered by latest activity.

    Returned shape:
        {thread_id, thread_kind, last_ts_ms, last_sender_name,
         last_body, message_count}
    """
    sql = """
        SELECT
            m.thread_id,
            m.thread_kind,
            m.ts_ms          AS last_ts_ms,
            m.sender_name    AS last_sender_name,
            m.sender_uuid    AS last_sender_uuid,
            m.sender_number  AS last_sender_number,
            m.body           AS last_body,
            counts.cnt       AS message_count
        FROM messages m
        JOIN (
            SELECT thread_id, MAX(ts_ms) AS max_ts, COUNT(*) AS cnt
            FROM messages
            WHERE (expires_at_ms IS NULL OR expires_at_ms > ?)
            GROUP BY thread_id
        ) counts
          ON counts.thread_id = m.thread_id AND counts.max_ts = m.ts_ms
        WHERE (m.expires_at_ms IS NULL OR m.expires_at_ms > ?)
        ORDER BY m.ts_ms DESC
        LIMIT ?
    """
    rows = db.execute(sql, (now_ms(), now_ms(), int(limit))).fetchall()
    return [dict(r) for r in rows]


def insert_pending(
    db: sqlite3.Connection,
    *,
    token: str,
    recipient: str,
    body: str,
    display_name: str | None = None,
    account_uuid: str | None = None,
) -> None:
    db.execute(
        """INSERT INTO pending_sends
           (token, created_at, account_uuid, recipient, display_name, body, state)
           VALUES (?, ?, ?, ?, ?, ?, 'pending')""",
        (token, now_ms(), account_uuid, recipient, display_name, body),
    )


def list_pending(
    db: sqlite3.Connection, *, states: Iterable[str] = ("pending",)
) -> list[dict]:
    state_list = list(states)
    if not state_list:
        return []
    placeholders = ",".join("?" * len(state_list))
    rows = db.execute(
        f"SELECT * FROM pending_sends WHERE state IN ({placeholders})"
        f" ORDER BY created_at ASC",
        state_list,
    ).fetchall()
    return [dict(r) for r in rows]


def get_pending(db: sqlite3.Connection, token: str) -> dict | None:
    row = db.execute("SELECT * FROM pending_sends WHERE token = ?", (token,)).fetchone()
    return dict(row) if row else None


def mark_pending(
    db: sqlite3.Connection,
    token: str,
    *,
    state: str,
    error: str | None = None,
) -> bool:
    """Set the terminal state on a pending row. Returns True iff the row
    existed and the state actually changed.
    """
    if state not in VALID_STATES:
        raise ValueError(f"mark_pending: invalid state {state!r}")
    cur = db.execute(
        """UPDATE pending_sends
           SET state = ?, decision_at = ?, error = ?
           WHERE token = ? AND state != ?""",
        (state, now_ms(), error, token, state),
    )
    return cur.rowcount == 1


def expire_messages(db: sqlite3.Connection) -> int:
    """Physically delete messages past their disappear-after window.
    Returns the row count deleted."""
    cur = db.execute(
        "DELETE FROM messages WHERE expires_at_ms IS NOT NULL AND expires_at_ms <= ?",
        (now_ms(),),
    )
    return cur.rowcount

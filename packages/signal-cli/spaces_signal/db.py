"""SQLite schema + helpers shared by the signal CLI and bridge.

The store lives at $SPACES_SIGNAL_DB (default
~/.local/state/spaces/signal/messages.db). Two tables:

* `messages` — append-only inbox. Idempotent on `(uid)`; the bridge
  may legitimately replay the same envelope (signal-cli ack semantics)
  and the dedup prevents double-counting in thread reads.

* `pending_sends` — outbound sends the agent queued via the bridge's
  enqueue socket that require the human to approve through the chat
  panel. The bridge owns this table outright: it INSERTs the row and
  owns every state transition. The sandbox-side CLI never writes here
  — it opens the store read-only — so a prompt-injected agent cannot
  forge an 'approved'/'sent' row to fake an approval.

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

VALID_STATES = frozenset({"pending", "approved", "sent", "denied", "failed", "expired"})


def default_db_path() -> Path:
    env = os.environ.get("SPACES_SIGNAL_DB")
    if env:
        return Path(env)
    state = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return Path(state) / "spaces" / "signal" / "messages.db"


def default_legacy_db_path() -> Path:
    """messages.db location used before the 2026-05 'distro' → 'spaces'
    rename. Returned even if it doesn't exist — callers branch on
    existence themselves so the path is testable in isolation.
    """
    state = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return Path(state) / "distro" / "signal" / "messages.db"


def _count_messages(path: Path) -> int:
    """Row count from a possibly-corrupt or schema-only DB. Any sqlite
    error (missing file, locked, wrong schema) is treated as zero so
    the migration falls back safely instead of aborting bridge startup.
    """
    try:
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True, isolation_level=None)
    except sqlite3.Error:
        return 0
    try:
        row = db.execute("SELECT COUNT(*) FROM messages").fetchone()
        return int(row[0]) if row else 0
    except sqlite3.Error:
        return 0
    finally:
        db.close()


def _checkpoint(path: Path) -> None:
    """Fold any pending WAL into the main DB file. The legacy bridge
    may have crashed before checkpointing, leaving rows only in
    messages.db-wal; without this the os.replace below would migrate
    a strictly older snapshot.
    """
    db = sqlite3.connect(str(path), isolation_level=None)
    try:
        db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    finally:
        db.close()


def migrate_legacy_state(new_db_path: Path, legacy_db_path: Path) -> bool:
    """Move the pre-rename messages DB into the new location on first
    bridge startup after the 2026-05 'distro' → 'spaces' rename.

    Guard: only migrates when the legacy DB has more rows than the new
    one. That covers the two real-world shapes — new DB absent (fresh
    post-rename install on an old home dir) and new DB freshly created
    but empty (bridge already ran once before this code shipped) — while
    refusing to clobber a new DB the user has accumulated real history
    into.

    The legacy WAL is checkpointed first so uncommitted rows survive
    the move; legacy sidecars (-wal, -shm) are unlinked afterwards
    because they're dead pointers post-rename.
    """
    if not legacy_db_path.is_file():
        return False
    legacy_count = _count_messages(legacy_db_path)
    if legacy_count <= 0:
        return False
    new_count = _count_messages(new_db_path) if new_db_path.is_file() else 0
    if new_count >= legacy_count:
        return False
    _checkpoint(legacy_db_path)
    new_db_path.parent.mkdir(parents=True, exist_ok=True)
    # Drop the new DB's sidecars before replacing: a stale WAL/SHM
    # referencing the about-to-be-overwritten inode would confuse the
    # next sqlite open. The bridge will recreate them on connect().
    for suffix in ("-wal", "-shm"):
        sidecar = new_db_path.with_name(new_db_path.name + suffix)
        try:
            sidecar.unlink()
        except FileNotFoundError:
            pass
    os.replace(legacy_db_path, new_db_path)
    for suffix in ("-wal", "-shm"):
        sidecar = legacy_db_path.with_name(legacy_db_path.name + suffix)
        try:
            sidecar.unlink()
        except FileNotFoundError:
            pass
    # Tidy: if the legacy dir is now empty, remove it so a re-run is
    # obviously a no-op and the empty shell doesn't linger in $HOME.
    try:
        legacy_db_path.parent.rmdir()
    except OSError:
        pass
    return True


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
    # secure_delete overwrites freed content instead of leaving it in
    # the page. Disappearing messages are deleted by the bridge's
    # expiry sweep; this makes that deletion actually scrub the
    # plaintext off disk rather than leaving it readable in free pages.
    db.execute("PRAGMA secure_delete=ON")
    init_schema(db)
    return db


def connect_readonly(path: Path) -> sqlite3.Connection:
    """Open the message DB read-only via SQLite's URI `mode=ro`.

    Used by the sandbox-side `signal` CLI: the bind-mount that
    surfaces messages.db into the sandbox is also `mode = "ro"` in
    NixOS, so the kernel enforces this at the filesystem layer
    too. The URI mode is belt-and-braces, but it also produces
    clean OperationalError on attempted writes rather than IOError
    from the filesystem.

    Does not run schema migrations and does not flip journal mode
    — either would itself be a write. Caller is responsible for
    the file already existing; on a fresh, unlinked host the
    bridge has not produced one yet and the CLI's
    `_signal_running()` check should already have short-circuited
    before we get here.
    """
    uri = f"file:{path}?mode=ro"
    db = sqlite3.connect(uri, uri=True, isolation_level=None, check_same_thread=False)
    db.row_factory = sqlite3.Row
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
    thread_kind: str | None = None,
    since_ms: int | None = None,
    until_ms: int | None = None,
    body_query: str | None = None,
    limit: int = 100,
) -> list[dict]:
    """Filtered message read. Newest first by default."""
    clauses: list[str] = []
    params: list = []

    # Disappearing-message hygiene: never surface anything past its
    # configured expiry. The bridge runs a periodic expiry sweep
    # (Bridge._run_expiry -> expire_messages) that physically deletes
    # these rows; this filter is the belt to that sweep's braces.
    clauses.append("(expires_at_ms IS NULL OR expires_at_ms > ?)")
    params.append(now_ms())

    if thread_id is not None:
        clauses.append("thread_id = ?")
        params.append(thread_id)
    if thread_kind is not None:
        clauses.append("thread_kind = ?")
        params.append(thread_kind)
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


def count_pending(db: sqlite3.Connection) -> int:
    """Number of sends still awaiting a human decision."""
    row = db.execute(
        "SELECT COUNT(*) AS n FROM pending_sends WHERE state = 'pending'"
    ).fetchone()
    return int(row["n"])


def expire_pending(db: sqlite3.Connection, *, older_than_ms: int) -> list[str]:
    """Mark still-'pending' rows created before `older_than_ms` as
    'expired' (never decided in time). Returns the tokens expired so the
    caller can drop their cards from the panel.

    Callers MUST hold the bridge db_lock so the SELECT and UPDATE are
    atomic against a concurrent approve/deny — otherwise a row decided
    between the two could be wrongly reported expired.
    """
    rows = db.execute(
        "SELECT token FROM pending_sends WHERE state = 'pending' AND created_at < ?",
        (older_than_ms,),
    ).fetchall()
    tokens = [r["token"] for r in rows]
    if tokens:
        db.execute(
            "UPDATE pending_sends SET state = 'expired', decision_at = ?"
            " WHERE state = 'pending' AND created_at < ?",
            (now_ms(), older_than_ms),
        )
    return tokens


def get_pending(db: sqlite3.Connection, token: str) -> dict | None:
    row = db.execute("SELECT * FROM pending_sends WHERE token = ?", (token,)).fetchone()
    return dict(row) if row else None


def claim_pending(db: sqlite3.Connection, token: str, *, state: str) -> bool:
    """Atomically claim a still-`pending` row, moving it to a decided
    state ('approved' or 'denied'). Returns True iff *this* caller won
    the claim — the row existed and was still 'pending'. Concurrent
    deciders (a second approve, or an approve racing a deny) get False
    and MUST NOT act on the row.

    This is the approval gate's serialization point. The older
    `mark_pending(state != target)` guard only blocked re-applying the
    *same* state; it still let an already-approved (or even 'sent')
    row be flipped to 'denied' and vice versa, so a deny racing an
    approve could report success while signal-cli actually dispatched
    the message. Claiming strictly from 'pending' closes that race:
    exactly one of {approve, deny} can win.
    """
    if state not in ("approved", "denied"):
        raise ValueError(f"claim_pending: state must be approved/denied, got {state!r}")
    cur = db.execute(
        """UPDATE pending_sends
           SET state = ?, decision_at = ?
           WHERE token = ? AND state = 'pending'""",
        (state, now_ms(), token),
    )
    return cur.rowcount == 1


def mark_pending(
    db: sqlite3.Connection,
    token: str,
    *,
    state: str,
    error: str | None = None,
) -> bool:
    """Set a terminal state (sent/failed) on a row already claimed via
    `claim_pending`. Idempotent: returns True iff the row existed and
    the state actually changed. NOT a claim — callers that need to win
    an exclusive pending→decided transition MUST use `claim_pending`.
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

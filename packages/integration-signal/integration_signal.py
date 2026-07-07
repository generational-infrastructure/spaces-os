"""Signal MCP integration server (spaces integration).

Wraps the existing, tested signal backends:
  * reads (threads / read_thread / search) query the local messages.db that the
    `spaces-signal-bridge` service fills, reusing `spaces_signal.db` read
    helpers over a read-only (`mode=ro`) SQLite connection;
  * everything that talks to Signal live (contacts / groups / send /
    note_to_self) speaks signal-cli's JSON-RPC over its daemon unix socket with
    the shared `spaces_signal.jsonrpc` client.

Security posture baked into the tool surface (see the migration plan's locked
decisions):
  * EVERY tool first probes the daemon socket; unreachable/unlinked yields a
    uniform onboarding hint rather than masquerading as "no messages"
    (decision 11);
  * `send` requires the caller to name the recipient and verifies that name
    against the daemon's contacts/groups (decision 2); recipients must be known
    (decision 3); groups verify against the title (decision 4); self-sends are
    routed to `note_to_self` (decision 10);
  * `send_preview` produces a trusted to:-line plus confusable/near-miss
    warnings and NEVER dispatches a message (decision 6);
  * `fetch_attachment` stages a stored attachment into the shared dir with
    basename-only path neutralization (decision 7).

Config is entirely environment-driven, so this is a field-less integration
(schema.json config/secrets are both empty): the scaffold runs with
`require_profile=False`.
"""

import json
import os
import sys
import unicodedata
from pathlib import Path

from spaces_integration_mcp import make_server, shared_dir
from spaces_signal import db as dbmod
from spaces_signal.jsonrpc import JsonRpcClient, JsonRpcError

SERVER_NAME = "integration-signal"
SERVER_VERSION = "0.1.0"

# Env the host grants this domain (see the signal manifest / extraPaths):
DAEMON_SOCKET_ENV = "SPACES_SIGNAL_DAEMON_SOCKET"  # signal-cli JSON-RPC socket
ATTACHMENTS_DIR_ENV = "SPACES_SIGNAL_ATTACHMENTS_DIR"  # signal-cli attachment store
# messages.db path comes from SPACES_SIGNAL_DB via dbmod.default_db_path().

_ONBOARDING_HINT = (
    "if signal-cli has never been linked on this host, run on your host "
    'shell:\n  signal-cli link -n "spaces-$(hostname)"\n'
    "and scan the printed tsdevice: URL with your phone's Signal app."
)
_UNLINKED_MSG = (
    "signal is not reachable (daemon down or no linked account).\n"
    + _ONBOARDING_HINT
)

_SHORT_MAXLEN = 4  # names this short use a normalized distance, not lev<=2


class SignalError(Exception):
    """A tool-level error; the message is returned as the tool's error text."""


# ── recipient helpers ───────────────────────────────────────────────
# Faithful copies of the classifier / sanitizer / self-check from
# spaces_signal.bridge. Copied rather than imported because the bridge's send
# path (and these helpers with it) is slated to be gutted to a forwarder-only
# service in a later migration step; the integration owns this logic now.


def classify_recipient(value):
    """One of 'number', 'uuid', 'username', 'group' — the distinct argument
    shapes signal-cli's `send` RPC accepts."""
    value = value.strip()
    if value.startswith("+"):
        return "number"
    if len(value) == 36 and value.count("-") == 4:
        return "uuid"
    if "." in value and len(value) < 40:
        return "username"
    return "group"


def sanitize_display(name, fallback):
    """Strip Unicode control/format characters (category C*, keeping spaces)
    from an attacker-controlled display name; fall back when nothing readable
    survives. Blocks RTL-override / zero-width spoofing of the approval card."""
    if not name:
        return fallback
    cleaned = "".join(
        c for c in name if unicodedata.category(c)[0] != "C" or c == " "
    ).strip()
    return cleaned or fallback


def is_self_recipient(recipient, accounts):
    """True iff `recipient` matches a linked account by uuid or number."""
    recipient = (recipient or "").strip()
    for acct in accounts:
        if recipient and recipient in (acct.get("uuid"), acct.get("number")):
            return True
    return False


# ── daemon probe / client ───────────────────────────────────────────


def _connect_daemon():
    path = os.environ.get(DAEMON_SOCKET_ENV)
    if not path:
        raise SignalError(_UNLINKED_MSG)
    try:
        return JsonRpcClient(path, connect_timeout=5.0)
    except OSError as exc:
        raise SignalError(_UNLINKED_MSG) from exc


def _list_accounts(client):
    """Linked accounts (normalized {uuid, number}); raises when none — an empty
    account set is 'unlinked', not 'up and idle'."""
    try:
        result = client.call("listAccounts")
    except (JsonRpcError, OSError, TimeoutError) as exc:
        raise SignalError(_UNLINKED_MSG) from exc
    accounts = []
    if isinstance(result, list):
        for item in result:
            if isinstance(item, dict):
                accounts.append(
                    {
                        "uuid": item.get("uuid") or item.get("accountUuid"),
                        "number": item.get("number") or item.get("account"),
                    }
                )
    if not accounts:
        raise SignalError(_UNLINKED_MSG)
    return accounts


def _run_with_daemon(fn, args):
    """The per-tool pipeline: probe the daemon (decision 11), fetch accounts,
    run `fn(args, client, accounts)`, always closing the client. DB-backed
    tools ignore `client`/`accounts` past the probe but still probe first."""
    try:
        client = _connect_daemon()
    except SignalError as exc:
        return str(exc), True
    try:
        accounts = _list_accounts(client)
        return fn(args, client, accounts)
    except SignalError as exc:
        return str(exc), True
    except (JsonRpcError, TimeoutError, OSError) as exc:
        return f"signal daemon error: {exc.__class__.__name__}: {exc}", True
    finally:
        client.close()


def _tool(fn):
    """Adapt a `(args, client, accounts)` impl to the scaffold record signature
    (profile/vals are always None/{} — this is a field-less integration)."""
    return lambda args, profile, vals: _run_with_daemon(fn, args)


# ── read-only messages.db access (decision 8) ───────────────────────


def _open_db(path=None):
    # messages.db is written by the bridge with PRAGMA journal_mode=WAL
    # (spaces_signal/db.py `connect()`), so the store dir is granted rw purely
    # for the -wal/-shm side-files (decision 8 / extraPaths). This connection
    # opens the file with SQLite's `mode=ro` URI (connect_readonly) and never
    # flips journal mode, so it reads a WAL database without ever writing —
    # any INSERT/UPDATE/DDL through it raises sqlite3.OperationalError.
    p = Path(path) if path is not None else dbmod.default_db_path()
    return dbmod.connect_readonly(p)


def _int(value, default):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _parse_attachments(raw):
    if not raw:
        return []
    if isinstance(raw, list):
        return raw
    try:
        parsed = json.loads(raw)
    except (ValueError, TypeError):
        return []
    return parsed if isinstance(parsed, list) else []


def _attachment_views(raw):
    out = []
    for i, att in enumerate(_parse_attachments(raw)):
        if not isinstance(att, dict):
            out.append({"index": i})
            continue
        out.append(
            {
                "index": i,
                "id": att.get("id"),
                "filename": att.get("filename"),
                "contentType": att.get("contentType"),
                "size": att.get("size"),
            }
        )
    return out


def _safe_name(name):
    return sanitize_display(name, "") if name else name


def _message_view(row):
    return {
        "uid": row.get("uid"),
        "ts_ms": row.get("ts_ms"),
        "thread_id": row.get("thread_id"),
        "thread_kind": row.get("thread_kind"),
        "sender_name": _safe_name(row.get("sender_name")),
        "sender_number": row.get("sender_number"),
        "sender_uuid": row.get("sender_uuid"),
        "body": row.get("body"),
        "attachments": _attachment_views(row.get("attachments_json")),
    }


def _tool_threads(args, client, accounts):
    db = _open_db()
    try:
        rows = dbmod.list_threads(db, limit=_int(args.get("limit"), 50))
    finally:
        db.close()
    out = [
        {
            "thread_id": r.get("thread_id"),
            "thread_kind": r.get("thread_kind"),
            "last_ts_ms": r.get("last_ts_ms"),
            "last_sender": _safe_name(r.get("last_sender_name")),
            "last_body": r.get("last_body"),
            "message_count": r.get("message_count"),
        }
        for r in rows
    ]
    return json.dumps(out, default=str), False


def _tool_read_thread(args, client, accounts):
    thread_id = (args.get("thread_id") or "").strip()
    if not thread_id:
        return "thread_id is required", True
    limit = _int(args.get("limit"), 100)
    db = _open_db()
    try:
        # `self` is an alias for the note-to-self thread, so the agent never
        # needs to discover its own UUID.
        if thread_id.lower() == "self":
            rows = dbmod.query_messages(db, thread_kind="self", limit=limit)
        else:
            rows = dbmod.query_messages(db, thread_id=thread_id, limit=limit)
    finally:
        db.close()
    rows = list(reversed(rows))  # oldest-first for reading
    return json.dumps([_message_view(r) for r in rows], default=str), False


def _tool_search(args, client, accounts):
    query = args.get("query") or ""
    db = _open_db()
    try:
        rows = dbmod.query_messages(
            db, body_query=query, limit=_int(args.get("limit"), 100)
        )
    finally:
        db.close()
    return json.dumps([_message_view(r) for r in rows], default=str), False


# ── daemon-backed live namespace (contacts + groups) ────────────────


def _safe_list(client, method, account_id):
    try:
        result = client.call(method, {"account": account_id})
    except (JsonRpcError, OSError, TimeoutError):
        return []
    return result if isinstance(result, list) else []


def _contact_stored_name(contact):
    name = contact.get("name")
    if not name:
        profile = contact.get("profile") or {}
        name = (
            str(profile.get("givenName") or "")
            + " "
            + str(profile.get("familyName") or "")
        ).strip()
    return name or contact.get("number") or ""


def _namespace(client, accounts):
    """Pooled contacts + groups across every linked account. Each entry carries
    its sanitized display name, raw id, and owning account (for dispatch)."""
    entries = []
    for acct in accounts:
        account_id = acct.get("number") or acct.get("uuid")
        for contact in _safe_list(client, "listContacts", account_id):
            if not isinstance(contact, dict):
                continue
            raw = contact.get("number") or contact.get("uuid") or contact.get(
                "username"
            )
            entries.append(
                {
                    "kind": "contact",
                    "account": acct,
                    "raw": raw,
                    "number": contact.get("number"),
                    "uuid": contact.get("uuid"),
                    "username": contact.get("username"),
                    "display": sanitize_display(
                        _contact_stored_name(contact), raw or ""
                    ),
                }
            )
        for group in _safe_list(client, "listGroups", account_id):
            if not isinstance(group, dict):
                continue
            gid = group.get("id")
            entries.append(
                {
                    "kind": "group",
                    "account": acct,
                    "raw": gid,
                    "members": group.get("members") or [],
                    "display": sanitize_display(group.get("name"), gid or ""),
                }
            )
    return entries


def _find_by_id(entries, recipient):
    kind = classify_recipient(recipient)
    for entry in entries:
        if kind == "group":
            if entry["kind"] == "group" and entry["raw"] == recipient:
                return entry
        elif entry["kind"] == "contact" and recipient in (
            entry.get("number"),
            entry.get("uuid"),
            entry.get("username"),
        ):
            return entry
    return None


def _to_line(entry):
    """Trusted, kind-labelled recipient line for the preview / send receipt."""
    if entry["kind"] == "group":
        n = len(entry.get("members") or [])
        return f'GROUP "{entry["display"]}" ({n} member{"" if n == 1 else "s"})'
    ident = (
        entry.get("number")
        or entry.get("uuid")
        or entry.get("username")
        or entry.get("raw")
    )
    return f'{entry["display"]} <{ident}>'


def _tool_contacts(args, client, accounts):
    out = [
        {
            "name": e["display"],
            "number": e.get("number"),
            "uuid": e.get("uuid"),
            "username": e.get("username"),
        }
        for e in _namespace(client, accounts)
        if e["kind"] == "contact"
    ]
    return json.dumps(out, default=str), False


def _tool_groups(args, client, accounts):
    out = [
        {
            "id": e["raw"],
            "name": e["display"],
            "members": len(e.get("members") or []),
        }
        for e in _namespace(client, accounts)
        if e["kind"] == "group"
    ]
    return json.dumps(out, default=str), False


# ── similarity / confusable scan (decision 6) ───────────────────────
# UTS#39-lite: a small hand-rolled Latin/Cyrillic/Greek homoglyph table folds a
# name to a "skeleton". Two names with equal skeletons but different casefolds
# look identical across scripts => a mixed-script confusable. stdlib only.

_CONFUSABLES = {
    # Cyrillic (lowercase; casefold runs first) -> Latin lookalike
    "\u0430": "a",  # а
    "\u0435": "e",  # е
    "\u043e": "o",  # о
    "\u0440": "p",  # р
    "\u0441": "c",  # с
    "\u0445": "x",  # х
    "\u0443": "y",  # у
    "\u043a": "k",  # к
    "\u043c": "m",  # м
    "\u0442": "t",  # т
    "\u0432": "b",  # в
    "\u043d": "h",  # н
    "\u0456": "i",  # і
    "\u0458": "j",  # ј
    "\u0455": "s",  # ѕ
    "\u0501": "d",  # ԁ
    # Greek (lowercase) -> Latin lookalike
    "\u03b1": "a",  # α
    "\u03b2": "b",  # β
    "\u03b5": "e",  # ε
    "\u03b9": "i",  # ι
    "\u03ba": "k",  # κ
    "\u03bd": "v",  # ν
    "\u03bf": "o",  # ο
    "\u03c1": "p",  # ρ
    "\u03c4": "t",  # τ
    "\u03c5": "u",  # υ
    "\u03c7": "x",  # χ
    "\u03b3": "y",  # γ
    "\u03b7": "n",  # η
    "\u03bc": "u",  # μ
    "\u03c2": "c",  # ς (final sigma)
}


def _norm(text):
    """NFKC + casefold of the sanitized name."""
    return unicodedata.normalize("NFKC", sanitize_display(text, text)).casefold()


def _skeleton(text):
    return "".join(_CONFUSABLES.get(c, c) for c in _norm(text))


def _levenshtein(a, b):
    if a == b:
        return 0
    if not a:
        return len(b)
    if not b:
        return len(a)
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(
                min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb))
            )
        prev = cur
    return prev[-1]


def _similarity_scan(claimed, candidates):
    """Warn (never block) about namespace names close to the claimed name.
    `candidates` is a list of (display, raw_id). Skeleton-equal-but-not-identical
    names are flagged as mixed-script confusables; the rest use Levenshtein
    (<=2, or a normalized 0.25 threshold for short names). Raw id beside each."""
    if not claimed:
        return []
    t_norm = _norm(claimed)
    t_skel = _skeleton(claimed)
    out = []
    for display, raw in candidates:
        c_norm = _norm(display)
        if c_norm == t_norm:
            continue  # the exact (case/width/script-identical) intended match
        if _skeleton(display) == t_skel:
            out.append(f'\u26a0 confusable (mixed-script): "{display}" [{raw}]')
            continue
        dist = _levenshtein(t_norm, c_norm)
        maxlen = max(len(t_norm), len(c_norm))
        if maxlen == 0:
            continue
        near = (dist / maxlen <= 0.25) if maxlen <= _SHORT_MAXLEN else (dist <= 2)
        if near:
            out.append(f'similar: "{display}" [{raw}]')
    return out


def _similar(claimed, entries):
    return _similarity_scan(claimed, [(e["display"], e["raw"]) for e in entries])


# ── send / note_to_self / send_preview ──────────────────────────────


def _dispatch_send(client, entry, body):
    account = entry["account"]
    params = {
        "account": account.get("number") or account.get("uuid"),
        "message": body,
    }
    if entry["kind"] == "group":
        params["groupId"] = entry["raw"]
    elif classify_recipient(entry["raw"]) == "username":
        params["username"] = [entry["raw"]]
    else:
        params["recipient"] = [entry["raw"]]
    client.call("send", params)


def _tool_send(args, client, accounts):
    recipient = (args.get("recipient") or "").strip()
    name = args.get("name")
    body = args.get("body") or ""
    if not recipient:
        return "recipient is required", True
    if not name:
        return (
            "name is required: the recipient's display name, verified against "
            "your contacts before anything is sent",
            True,
        )
    if not body:
        return "body is required", True
    if recipient.lower() == "self" or is_self_recipient(recipient, accounts):
        return (
            "refusing to send to your own account — use the note_to_self tool "
            "to message yourself",
            True,
        )
    entries = _namespace(client, accounts)
    match = _find_by_id(entries, recipient)
    if match is None:
        if classify_recipient(recipient) == "group":
            return f"{recipient!r} is not a group you've joined", True
        return (
            f"{recipient!r} is not in your contacts — add them on your phone",
            True,
        )
    true_name = match["display"]
    if true_name != name:
        msg = (
            f"name mismatch: {recipient!r} is {true_name!r} in your contacts, "
            f"not {name!r}; refusing to send"
        )
        near = _similar(name, entries)
        if near:
            msg += ". near matches: " + "; ".join(near)
        return msg, True
    _dispatch_send(client, match, body)
    return f"sent to {_to_line(match)}", False


def _tool_note_to_self(args, client, accounts):
    body = args.get("body") or ""
    if not body:
        return "body is required", True
    account = accounts[0]
    account_id = account.get("number") or account.get("uuid")
    own = account.get("number") or account.get("uuid")
    if not own:
        return "linked account has no number or uuid", True
    # signal-cli treats a send to your own number as a note-to-self.
    client.call("send", {"account": account_id, "message": body, "recipient": [own]})
    return "sent to your note-to-self thread", False


def _tool_send_preview(args, client, accounts):
    recipient = (args.get("recipient") or "").strip()
    name = args.get("name") or ""
    if not recipient:
        return "recipient is required", True
    entries = _namespace(client, accounts)
    lines = []
    if recipient.lower() == "self" or is_self_recipient(recipient, accounts):
        lines.append("to: your own account (use note_to_self instead)")
    else:
        match = _find_by_id(entries, recipient)
        if match is None:
            if classify_recipient(recipient) == "group":
                lines.append(
                    f"to: UNKNOWN GROUP {recipient} — not a group you've joined"
                )
            else:
                lines.append(f"to: UNKNOWN {recipient} — not in your contacts")
        else:
            lines.append("to: " + _to_line(match))
            if name and match["display"] != name:
                lines.append(
                    f'\u26a0 name mismatch: you said "{name}" but this is '
                    f'"{match["display"]}"'
                )
    lines.extend(_similar(name, entries) if name else [])
    # NOTE: no `send` RPC is ever issued here — preview must be side-effect free.
    return "\n".join(lines), False


# ── attachment staging (decision 7) ─────────────────────────────────


def _tool_fetch_attachment(args, client, accounts):
    uid = (args.get("message_uid") or "").strip()
    if not uid:
        return "message_uid is required", True
    index = _int(args.get("index"), None)
    if index is None:
        return "index is required", True
    db = _open_db()
    try:
        row = db.execute(
            "SELECT attachments_json FROM messages WHERE uid = ?", (uid,)
        ).fetchone()
    finally:
        db.close()
    if row is None:
        return f"no message with uid {uid!r}", True
    items = _parse_attachments(row["attachments_json"])
    if index < 0 or index >= len(items):
        return f"message {uid!r} has no attachment at index {index}", True
    att = items[index] if isinstance(items[index], dict) else {}
    att_id = str(att.get("id") or "")
    if not att_id:
        return f"attachment {index} of {uid!r} has no stored id", True

    att_dir = os.environ.get(ATTACHMENTS_DIR_ENV)
    if not att_dir:
        return f"{ATTACHMENTS_DIR_ENV} is not set", True
    shared = shared_dir()
    if not shared:
        return "no shared directory provisioned for file exchange", True

    # basename-only: stored ids and filenames are attacker-influenced, so they
    # must never escape the attachments dir (source) or the shared dir (dest).
    src = os.path.join(att_dir, os.path.basename(att_id))
    dest_name = os.path.basename(str(att.get("filename") or "")) or os.path.basename(
        att_id
    )
    dest = os.path.join(shared, dest_name)
    try:
        with open(src, "rb") as f:
            data = f.read()
    except OSError as exc:
        return (
            f"attachment file not readable: {exc.__class__.__name__}: {exc}",
            True,
        )
    with open(dest, "wb") as f:
        f.write(data)
    return dest, False


# ── server assembly ─────────────────────────────────────────────────


def _rec(name, description, properties, required, fn):
    return {
        "name": name,
        "description": description,
        "schema": {"properties": properties, "required": required},
        "needs_fields": (),
        "impl": _tool(fn),
    }


_STR = {"type": "string"}
_LIMIT = {"type": "integer", "description": "max rows (optional)"}

TOOLS, call_tool, main = make_server(
    SERVER_NAME,
    SERVER_VERSION,
    [
        _rec(
            "threads",
            "List Signal conversations (one row per thread, newest first) from "
            "the local message store",
            {"limit": _LIMIT},
            [],
            _tool_threads,
        ),
        _rec(
            "read_thread",
            "Read a thread's messages oldest-first (use 'self' for "
            "note-to-self); includes attachment ids/filenames",
            {
                "thread_id": {
                    "type": "string",
                    "description": "thread id, or 'self'",
                },
                "limit": _LIMIT,
            },
            ["thread_id"],
            _tool_read_thread,
        ),
        _rec(
            "search",
            "Full-text-ish search of message bodies across all threads",
            {"query": {"type": "string", "description": "text to match"},
             "limit": _LIMIT},
            ["query"],
            _tool_search,
        ),
        _rec(
            "contacts",
            "List known Signal contacts (live from the daemon): display name + "
            "number/uuid",
            {},
            [],
            _tool_contacts,
        ),
        _rec(
            "groups",
            "List joined Signal groups (live from the daemon): title, id, "
            "member count",
            {},
            [],
            _tool_groups,
        ),
        _rec(
            "note_to_self",
            "Send a message to your own Signal note-to-self thread",
            {"body": {"type": "string", "description": "message text"}},
            ["body"],
            _tool_note_to_self,
        ),
        _rec(
            "send",
            "Send a Signal message. `name` (the recipient's display name/group "
            "title) is REQUIRED and verified against your contacts/groups before "
            "dispatch; unknown recipients and name mismatches are refused",
            {
                "recipient": {
                    "type": "string",
                    "description": "phone number, uuid, username, or group id",
                },
                "name": {
                    "type": "string",
                    "description": "the recipient's display name / group title",
                },
                "body": {"type": "string", "description": "message text"},
            },
            ["recipient", "name", "body"],
            _tool_send,
        ),
        _rec(
            "fetch_attachment",
            "Copy a stored attachment into the shared exchange dir and return "
            "its path",
            {
                "message_uid": {
                    "type": "string",
                    "description": "the message's uid (from read_thread)",
                },
                "index": {
                    "type": "integer",
                    "description": "attachment index within the message",
                },
            },
            ["message_uid", "index"],
            _tool_fetch_attachment,
        ),
        _rec(
            "send_preview",
            "Preview a send: the resolved recipient line plus confusable / "
            "near-miss warnings. Never dispatches a message",
            {
                "recipient": {"type": "string"},
                "name": {"type": "string"},
                "body": {"type": "string"},
            },
            ["recipient"],
            _tool_send_preview,
        ),
    ],
    multi_profile=False,
    require_profile=False,
    error_label="signal",
)


if __name__ == "__main__":
    sys.exit(main())

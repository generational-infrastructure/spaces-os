"""Agent-facing `signal` command.

The CLI is the only `spaces_signal` entry point visible from inside
the pi-chat sandbox. It speaks three protocols:

* **SQLite (RO)** for read commands: `threads`, `read`, `search`.
  Backed by the same `messages.db` the bridge writes.

* **JSON-RPC over the signal-cli daemon socket** for live identity
  reads: `contacts`, `groups`. Bound into the sandbox by the
  signal-cli NixOS module; called directly because both endpoints
  are short-lived and the data is not sensitive.

* **NDJSON over the bridge enqueue socket** for `send`. Self-sends
  return immediately ("sent"); everything else returns a pending
  token the agent must surface to the user — approval happens out
  of band through the chat panel, not from inside the sandbox.

Default output is plain text designed for the agent's eyes; `--json`
emits the underlying records verbatim for programmatic use.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import socket
import sys
from pathlib import Path
from typing import Sequence

from . import db as dbmod

DEFAULT_ENQUEUE_SOCKET_ENV = "SPACES_SIGNAL_ENQUEUE_SOCKET"


# ── socket-path helpers ─────────────────────────────────────────────


def _runtime_dir() -> str:
    return os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"


def _enqueue_socket_path() -> str:
    env = os.environ.get(DEFAULT_ENQUEUE_SOCKET_ENV)
    return env or f"{_runtime_dir()}/spaces-signal/sandbox/enqueue.sock"


_ONBOARDING_HINT = (
    "if signal-cli has never been linked on this host, run on your "
    'host shell:\n  signal-cli link -n "$(hostname)-pi"\n'
    "and scan the printed tsdevice: URL with your phone's Signal app."
)

# ── formatting ──────────────────────────────────────────────────────


def _iso(ts_ms: int | None) -> str:
    if not ts_ms:
        return "                    "
    dt = _dt.datetime.fromtimestamp(int(ts_ms) / 1000, tz=_dt.timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def _sender_label(row: dict) -> str:
    name = row.get("sender_name")
    if name:
        return str(name)
    number = row.get("sender_number")
    if number:
        return str(number)
    uuid = row.get("sender_uuid")
    if uuid:
        return str(uuid)[:8]
    return "?"


def _truncate(text: str | None, n: int = 80) -> str:
    if not text:
        return ""
    text = " ".join(text.split())
    return text if len(text) <= n else text[: n - 1] + "…"


def _signal_running() -> bool:
    """True iff the bridge enqueue socket is present.

    The sandbox can only reach the bridge — the daemon JSON-RPC
    socket is deliberately NOT bind-mounted, so the agent cannot
    sidestep the human approval gate by speaking `send` to the
    daemon directly. The enqueue socket file shows up the first
    time the bridge runs, which only happens after the user has
    completed `signal-cli link`.
    """
    return Path(_enqueue_socket_path()).exists()


def _emit_unconfigured_hint() -> None:
    print(
        "error: signal infrastructure not running "
        "(neither daemon nor bridge socket present).\n" + _ONBOARDING_HINT,
        file=sys.stderr,
    )


# ── commands ────────────────────────────────────────────────────────


def cmd_threads(args: argparse.Namespace) -> int:
    if not _signal_running():
        _emit_unconfigured_hint()
        return 1
    db = dbmod.connect_readonly(dbmod.default_db_path())
    rows = dbmod.list_threads(db, limit=args.limit)
    if args.json:
        json.dump(rows, sys.stdout, indent=2, default=str)
        sys.stdout.write("\n")
        return 0
    if not rows:
        print("(no threads)")
        return 0
    for r in rows:
        kind = r.get("thread_kind") or "?"
        thread_id = r.get("thread_id") or "?"
        label = _sender_label(r)
        ts = _iso(r.get("last_ts_ms"))
        preview = _truncate(r.get("last_body"))
        print(
            f"{ts}  {kind:5}  {label:24}  {preview}\n"
            f"          id={thread_id}  msgs={r.get('message_count')}"
        )
    return 0


def cmd_read(args: argparse.Namespace) -> int:
    if not _signal_running():
        _emit_unconfigured_hint()
        return 1
    db = dbmod.connect_readonly(dbmod.default_db_path())
    rows = dbmod.query_messages(
        db,
        thread_id=args.thread_id,
        since_ms=args.since,
        until_ms=args.until,
        limit=args.limit,
    )
    # Reverse to oldest-first for readability.
    rows = list(reversed(rows))
    if args.json:
        json.dump(rows, sys.stdout, indent=2, default=str)
        sys.stdout.write("\n")
        return 0
    if not rows:
        print(f"(no messages in thread {args.thread_id})")
        return 0
    print(f"=== thread {args.thread_id} ({rows[-1].get('thread_kind') or '?'}) ===")
    for r in rows:
        ts = _iso(r.get("ts_ms"))
        sender = _sender_label(r)
        body = r.get("body") or ""
        print(f"{ts}  {sender:24}  {body}")
    return 0


def cmd_search(args: argparse.Namespace) -> int:
    if not _signal_running():
        _emit_unconfigured_hint()
        return 1
    db = dbmod.connect_readonly(dbmod.default_db_path())
    rows = dbmod.query_messages(db, body_query=args.query, limit=args.limit)
    if args.json:
        json.dump(rows, sys.stdout, indent=2, default=str)
        sys.stdout.write("\n")
        return 0
    if not rows:
        print(f"(no matches for {args.query!r})")
        return 0
    for r in rows:
        ts = _iso(r.get("ts_ms"))
        sender = _sender_label(r)
        thread = r.get("thread_id") or "?"
        body = r.get("body") or ""
        print(f"{ts}  {sender:20}  [{thread}]  {body}")
    return 0


def cmd_contacts(args: argparse.Namespace) -> int:
    return _bridge_daemon_list(args, "contacts", _format_contacts)


def cmd_groups(args: argparse.Namespace) -> int:
    return _bridge_daemon_list(args, "groups", _format_groups)


def _bridge_daemon_list(args, op: str, formatter) -> int:
    """Read contacts/groups through the bridge enqueue socket.

    The bridge owns the daemon connection; the sandbox never touches
    the daemon JSON-RPC socket directly. That isolation is what keeps
    a prompt-injected agent from calling `send` on the daemon and
    sidestepping the human approval gate.
    """
    try:
        resp = _enqueue_call({"op": op})
    except FileNotFoundError:
        sock = _enqueue_socket_path()
        print(
            f"error: signal bridge socket missing ({sock}).\n{_ONBOARDING_HINT}",
            file=sys.stderr,
        )
        return 1
    except (OSError, ValueError) as exc:
        print(f"error: bridge unreachable: {exc}", file=sys.stderr)
        return 1
    if not resp.get("ok"):
        print(f"error: {resp.get('error', 'unknown error')}", file=sys.stderr)
        return 1
    items = resp.get(op) or []
    for warning in resp.get("warnings") or []:
        print(f"warning: {warning}", file=sys.stderr)
    if args.json:
        json.dump(items, sys.stdout, indent=2, default=str)
        sys.stdout.write("\n")
        return 0
    formatter(items)
    return 0


def _format_contacts(contacts: list[dict]) -> None:
    if not contacts:
        print("(no contacts)")
        return
    for c in contacts:
        name = c.get("name") or ""
        if not name:
            profile = c.get("profile") or {}
            given = profile.get("givenName") or ""
            family = profile.get("familyName") or ""
            name = (given + " " + family).strip()
        number = c.get("number") or ""
        uuid = c.get("uuid") or ""
        print(f"{name or '(unnamed)':28}  {number:18}  {uuid}")


def _format_groups(groups: list[dict]) -> None:
    if not groups:
        print("(no groups)")
        return
    for g in groups:
        name = g.get("name") or "(unnamed)"
        gid = g.get("id") or ""
        members = g.get("members") or []
        print(f"{name:28}  members={len(members):3}  id={gid}")


def cmd_send(args: argparse.Namespace) -> int:
    payload = {"op": "send", "to": args.recipient, "body": args.body}
    try:
        resp = _enqueue_call(payload)
    except FileNotFoundError:
        sock = _enqueue_socket_path()
        print(
            f"error: signal bridge socket missing ({sock}).\n{_ONBOARDING_HINT}",
            file=sys.stderr,
        )
        return 1
    except (OSError, ValueError) as exc:
        print(f"error: bridge unreachable: {exc}", file=sys.stderr)
        return 1
    if args.json:
        json.dump(resp, sys.stdout, indent=2, default=str)
        sys.stdout.write("\n")
        return 0 if resp.get("ok") else 1
    if not resp.get("ok"):
        print(f"error: {resp.get('error', 'unknown error')}", file=sys.stderr)
        return 1
    if resp.get("to_self"):
        print("sent to self.")
        return 0
    if resp.get("pending"):
        print(
            "pending — show this card to the user and ask them to approve "
            "in the chat panel:"
        )
        # Always show BOTH the friendly display name AND the raw
        # recipient. The display name comes from the contact's
        # attacker-controlled Signal profile — even after we strip
        # Unicode controls, a malicious contact could pick a
        # display name like "Mom" while their actual UUID is
        # someone unrelated. Surfacing the recipient gives the user
        # (and the agent reporting to them) the unambiguous target.
        recipient = resp.get("recipient") or args.recipient
        display = resp.get("display_name") or recipient
        if display == recipient:
            print(f"  to:    {recipient}")
        else:
            print(f"  to:    {display}  <{recipient}>")
        print(f"  body:  {args.body}")
        print(f"  token: {resp.get('token')}")
        return 0
    print(json.dumps(resp))
    return 0


def _enqueue_call(payload: dict, *, timeout: float = 5.0) -> dict:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(_enqueue_socket_path())
    try:
        s.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        f = s.makefile("r", encoding="utf-8", newline="\n")
        line = f.readline()
        if not line:
            raise ValueError("bridge closed connection before responding")
        return json.loads(line)
    finally:
        s.close()


# ── argparse wiring ─────────────────────────────────────────────────


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="signal",
        description="Agent-facing CLI for the spaces Signal skill.",
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    pt = sub.add_parser("threads", help="list active threads, newest first")
    pt.add_argument("--limit", type=int, default=50)
    pt.add_argument("--json", action="store_true")
    pt.set_defaults(func=cmd_threads)

    pr = sub.add_parser("read", help="show messages in one thread")
    pr.add_argument("thread_id")
    pr.add_argument(
        "--since", type=int, default=None, help="lower bound, ms since epoch"
    )
    pr.add_argument(
        "--until", type=int, default=None, help="upper bound, ms since epoch"
    )
    pr.add_argument("--limit", type=int, default=200)
    pr.add_argument("--json", action="store_true")
    pr.set_defaults(func=cmd_read)

    ps = sub.add_parser("search", help="substring search across message bodies")
    ps.add_argument("query")
    ps.add_argument("--limit", type=int, default=50)
    ps.add_argument("--json", action="store_true")
    ps.set_defaults(func=cmd_search)

    pc = sub.add_parser("contacts", help="list known contacts (live from daemon)")
    pc.add_argument("--json", action="store_true")
    pc.set_defaults(func=cmd_contacts)

    pg = sub.add_parser("groups", help="list known groups (live from daemon)")
    pg.add_argument("--json", action="store_true")
    pg.set_defaults(func=cmd_groups)

    psd = sub.add_parser(
        "send",
        help="enqueue a Signal message (sends self-directed messages "
        "immediately; everything else requires human approval in the "
        "chat panel)",
    )
    psd.add_argument(
        "recipient", help="phone number (+...), UUID, username (a.b), or group ID"
    )
    psd.add_argument("body", help="message text")
    psd.add_argument("--json", action="store_true")
    psd.set_defaults(func=cmd_send)

    return p


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.func(args) or 0)


if __name__ == "__main__":
    sys.exit(main())

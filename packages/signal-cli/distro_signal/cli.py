"""Agent-facing `signal` command.

The CLI is the only `distro_signal` entry point visible from inside
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
from typing import Sequence

from . import db as dbmod
from .jsonrpc import JsonRpcClient, JsonRpcError

DEFAULT_ENQUEUE_SOCKET_ENV = "DISTRO_SIGNAL_ENQUEUE_SOCKET"
DEFAULT_DAEMON_SOCKET_ENV = "DISTRO_SIGNAL_DAEMON_SOCKET"


# ── socket-path helpers ─────────────────────────────────────────────


def _runtime_dir() -> str:
    return os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"


def _enqueue_socket_path() -> str:
    env = os.environ.get(DEFAULT_ENQUEUE_SOCKET_ENV)
    return env or f"{_runtime_dir()}/distro-signal-enqueue.sock"


def _daemon_socket_path() -> str:
    env = os.environ.get(DEFAULT_DAEMON_SOCKET_ENV)
    return env or f"{_runtime_dir()}/signal-cli/socket"


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


# ── commands ────────────────────────────────────────────────────────


def cmd_threads(args: argparse.Namespace) -> int:
    db = dbmod.connect(dbmod.default_db_path())
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
    db = dbmod.connect(dbmod.default_db_path())
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
    db = dbmod.connect(dbmod.default_db_path())
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
    return _daemon_list(args, "listContacts", _format_contacts)


def cmd_groups(args: argparse.Namespace) -> int:
    return _daemon_list(args, "listGroups", _format_groups)


def _daemon_list(args, method: str, formatter) -> int:
    try:
        client = JsonRpcClient(_daemon_socket_path())
    except OSError as exc:
        print(f"error: signal-cli daemon unreachable: {exc}", file=sys.stderr)
        return 1
    try:
        accounts = client.call("listAccounts")
    except (JsonRpcError, OSError, TimeoutError) as exc:
        client.close()
        print(f"error: listAccounts failed: {exc}", file=sys.stderr)
        return 1
    if not accounts:
        client.close()
        print(
            "error: no linked Signal account — run `signal-cli link` first",
            file=sys.stderr,
        )
        return 1
    # Multi-account: aggregate across all linked identities.
    combined: list[dict] = []
    try:
        for acct in accounts:
            account_id = acct.get("number") or acct.get("uuid")
            try:
                result = client.call(method, {"account": account_id})
            except JsonRpcError as exc:
                print(
                    f"warning: {method} for {account_id} failed: {exc}",
                    file=sys.stderr,
                )
                continue
            if isinstance(result, list):
                combined.extend(result)
    finally:
        client.close()
    if args.json:
        json.dump(combined, sys.stdout, indent=2, default=str)
        sys.stdout.write("\n")
        return 0
    formatter(combined)
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
        print(f"  to:    {resp.get('display_name') or args.recipient}")
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
        description="Agent-facing CLI for the distro Signal skill.",
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

"""Read-only CLI over a desktop notification-history file.

Pi-chat skills shell out to this via the `notifications` entry point.
The CLI is deliberately tiny: an external writer owns the data, the
file is already structured, and the LLM doesn't need a programmable
API beyond "give me the recent entries, maybe filtered".

The schema this CLI reads is the one noctalia ships
(`~/.cache/noctalia/notifications.json`); when noctalia is running
the CLI auto-picks up its file, otherwise the user wires their own
writer and points `DISTRO_NOTIFICATIONS_FILE` at the output path.
Pi's sandboxed scope sets `DISTRO_NOTIFICATIONS_FILE` to a
bind-mounted copy regardless, so the agent always sees the same data
the user does.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

URGENCY_LABEL = {0: "low", 1: "normal", 2: "critical"}
URGENCY_VALUE = {label: value for value, label in URGENCY_LABEL.items()}


def _default_history_path() -> Path:
    # Order of precedence — first hit wins:
    #   1. DISTRO_NOTIFICATIONS_FILE — pi-chat sandbox export, pinned to
    #      the bind-mounted path inside the scope. Also the right knob for
    #      a user pointing at a non-noctalia writer.
    #   2. NOCTALIA_NOTIF_HISTORY_FILE — honored when noctalia is the
    #      writer and its history was redirected elsewhere.
    #   3. ~/.cache/noctalia/notifications.json — noctalia's hardcoded
    #      default; works out of the box when noctalia is running.
    for var in ("DISTRO_NOTIFICATIONS_FILE", "NOCTALIA_NOTIF_HISTORY_FILE"):
        value = os.environ.get(var)
        if value:
            return Path(value)
    cache_root = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    return Path(cache_root) / "noctalia" / "notifications.json"


@dataclass(frozen=True)
class Notification:
    """Minimal projection of the noctalia-compatible history schema.

    We keep the raw dict alongside the typed view so `--json` output round-trips
    every field the writer persisted, even ones we don't render in text.
    """

    raw: dict
    id: str
    app: str
    summary: str
    body: str
    urgency: int
    timestamp_ms: int

    @classmethod
    def from_dict(cls, entry: dict) -> "Notification":
        urgency = entry.get("urgency", 1)
        if not isinstance(urgency, int) or urgency < 0 or urgency > 2:
            urgency = 1
        return cls(
            raw=entry,
            id=str(entry.get("id", "")),
            app=str(entry.get("appName", "") or "Unknown"),
            summary=str(entry.get("summary", "")),
            body=str(entry.get("body", "")),
            urgency=urgency,
            timestamp_ms=int(entry.get("timestamp", 0) or 0),
        )

    @property
    def urgency_label(self) -> str:
        return URGENCY_LABEL.get(self.urgency, "normal")

    @property
    def iso_timestamp(self) -> str:
        dt = _dt.datetime.fromtimestamp(self.timestamp_ms / 1000, tz=_dt.timezone.utc)
        return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def _load(path: Path) -> list[Notification]:
    """Return the notifications from `path`, newest first.

    Missing file → empty list (pi must be able to call this on a fresh
    install). Malformed JSON → raise `ValueError`; callers translate that
    into a one-line stderr message.
    """

    if not path.exists():
        return []
    try:
        payload = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise ValueError(f"{path}: {exc.msg} at line {exc.lineno}") from exc
    if not isinstance(payload, dict):
        raise ValueError(f"{path}: expected object at top level")
    entries = payload.get("notifications") or []
    return [Notification.from_dict(e) for e in entries if isinstance(e, dict)]


def _apply_filters(
    notifications: list[Notification],
    *,
    app: str | None,
    since: int | None,
    urgency: int | None,
    limit: int | None,
) -> list[Notification]:
    out = notifications
    if app is not None:
        needle = app.casefold()
        out = [n for n in out if n.app.casefold() == needle]
    if since is not None:
        out = [n for n in out if n.timestamp_ms >= since]
    if urgency is not None:
        out = [n for n in out if n.urgency == urgency]
    if limit is not None and limit >= 0:
        out = out[:limit]
    return out


def _format_text(notifications: list[Notification]) -> str:
    if not notifications:
        return "(no notifications)\n"
    lines: list[str] = []
    for n in notifications:
        # Short-id prefix keeps the line readable; the LLM can `get <prefix>`
        # to recover the rest. Eight hex characters is plenty for a 100-entry ring.
        short_id = n.id[:8] if n.id else "-"
        lines.append(f"{n.iso_timestamp}  {n.app}  {n.urgency_label}  id={short_id}")
        if n.summary:
            lines.append(f"  {n.summary}")
        if n.body:
            lines.append(f"  {n.body}")
        lines.append("")  # blank separator
    return "\n".join(lines).rstrip() + "\n"


def _format_json(notifications: list[Notification]) -> str:
    return json.dumps([n.raw for n in notifications], ensure_ascii=False) + "\n"


def _resolve_urgency(value: str | None) -> int | None:
    if value is None:
        return None
    label = value.strip().casefold()
    if label in URGENCY_VALUE:
        return URGENCY_VALUE[label]
    # Tolerate numeric input too — the schema stores 0/1/2 raw.
    try:
        n = int(label)
    except ValueError:
        raise argparse.ArgumentTypeError(
            f"--urgency expects one of low/normal/critical or 0/1/2, got {value!r}"
        )
    if n not in URGENCY_LABEL:
        raise argparse.ArgumentTypeError(
            f"--urgency numeric value must be 0/1/2, got {n}"
        )
    return n


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="notifications",
        description=(
            "Read-only access to a desktop notification history file in "
            "the schema noctalia ships. The default path can be overridden "
            "with DISTRO_NOTIFICATIONS_FILE."
        ),
    )
    parser.add_argument(
        "--file",
        type=Path,
        default=None,
        help="Override the history file path (default: $DISTRO_NOTIFICATIONS_FILE or ~/.cache/noctalia/notifications.json)",
    )
    sub = parser.add_subparsers(dest="command")
    sub.required = True

    p_list = sub.add_parser("list", help="List recent notifications, newest first")
    p_list.add_argument("--limit", type=int, default=None)
    p_list.add_argument("--app", type=str, default=None)
    p_list.add_argument(
        "--since",
        type=int,
        default=None,
        help="Drop entries older than this Unix-ms timestamp",
    )
    p_list.add_argument("--urgency", type=str, default=None)
    p_list.add_argument(
        "--json",
        dest="as_json",
        action="store_true",
        help="Emit raw JSON instead of human-readable text",
    )

    p_get = sub.add_parser("get", help="Show one notification by id (prefix match)")
    p_get.add_argument("id")
    p_get.add_argument(
        "--json",
        dest="as_json",
        action="store_true",
    )

    return parser


def _resolve_path(args: argparse.Namespace) -> Path:
    return args.file if args.file is not None else _default_history_path()


def _cmd_list(args: argparse.Namespace) -> int:
    path = _resolve_path(args)
    try:
        notifications = _load(path)
    except ValueError as exc:
        print(f"notifications: {exc}", file=sys.stderr)
        return 1
    urgency = _resolve_urgency(args.urgency)
    filtered = _apply_filters(
        notifications,
        app=args.app,
        since=args.since,
        urgency=urgency,
        limit=args.limit,
    )
    if args.as_json:
        sys.stdout.write(_format_json(filtered))
    else:
        sys.stdout.write(_format_text(filtered))
    return 0


def _cmd_get(args: argparse.Namespace) -> int:
    path = _resolve_path(args)
    try:
        notifications = _load(path)
    except ValueError as exc:
        print(f"notifications: {exc}", file=sys.stderr)
        return 1
    needle = args.id
    matches = [n for n in notifications if n.id.startswith(needle)]
    if not matches:
        print(f"notifications: id {needle!r} not found", file=sys.stderr)
        return 2
    if len(matches) > 1:
        ids = ", ".join(n.id[:8] for n in matches)
        print(
            f"notifications: id {needle!r} is ambiguous (matches: {ids})",
            file=sys.stderr,
        )
        return 2
    if args.as_json:
        sys.stdout.write(json.dumps(matches[0].raw, ensure_ascii=False) + "\n")
    else:
        sys.stdout.write(_format_text(matches))
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    if args.command == "list":
        return _cmd_list(args)
    if args.command == "get":
        return _cmd_get(args)
    parser.error(f"unknown command: {args.command}")
    return 2  # unreachable; parser.error() raises SystemExit


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())

#!/usr/bin/env python3
"""google-cli: Gmail + Google Calendar over a Google "Desktop application"
OAuth client, plumbed into pi-chat through the `skill-config` store.

Why one binary for two services
-------------------------------
Mail and calendar share the same OAuth surface (one Cloud project, one
client_id/secret, one consent screen the user goes through once). Splitting
into two CLIs would mean two refresh tokens and two consent walk-throughs
for every profile, which is hostile UX for no engineering payoff.

Credential layout (per profile, in skill-config)
------------------------------------------------
    config (config.toml):
      google.<profile>.client_id      Google Cloud OAuth client_id.
    secrets (secrets.toml):
      google.<profile>.client_secret  OAuth client_secret.
      google.<profile>.refresh_token  Populated by `google-cli auth`.

`auth` runs the standard loopback flow (RFC 8252):
  * Bind 127.0.0.1:<random>.
  * Print the consent URL — the user opens it in their browser.
  * Google redirects back to http://127.0.0.1:<port>/?code=…
  * We exchange the code for a refresh_token and persist it via
    `skill-config set`.

The pi sandbox shares the host network namespace (PrivateNetwork is not
set on the per-session transient unit), so a loopback listener inside the
sandbox is reachable from the host browser.

Tokens after auth
-----------------
We only persist the refresh_token. The short-lived access_token is
re-minted on every CLI invocation from (client_id, client_secret,
refresh_token). That keeps secrets.toml stable and avoids stamping a
token-expiry timestamp through skill-config's flat string schema.
"""

from __future__ import annotations

import argparse
import base64
import http.server
import json
import os
import secrets
import socket
import subprocess
import sys
import threading
import urllib.parse
import webbrowser
from dataclasses import dataclass
from email.message import EmailMessage
from typing import Any, Iterable

# Lazy-imported in the functions that need them so `google-cli --help`
# and any pure-formatting unit test can run without google-auth installed.

GMAIL_SCOPE = "https://www.googleapis.com/auth/gmail.modify"
CALENDAR_SCOPE = "https://www.googleapis.com/auth/calendar"
DEFAULT_SCOPES = (GMAIL_SCOPE, CALENDAR_SCOPE)

AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URL = "https://oauth2.googleapis.com/token"

SKILL = "google"


# ── skill-config plumbing ────────────────────────────────────────────


def _skill_config_bin() -> str:
    """Resolve the skill-config binary.

    Overridable via $SKILL_CONFIG_BIN so unit tests can drop in a stub
    without touching PATH.
    """
    return os.environ.get("SKILL_CONFIG_BIN") or "skill-config"


def sc_get(key: str) -> str | None:
    """Read a single skill-config key, returning None when unset.

    `skill-config get` exits non-zero on missing keys and writes the
    explanation to stderr. We swallow that here so callers can branch on
    "is the field set?" without their own subprocess scaffolding.
    """
    res = subprocess.run(
        [_skill_config_bin(), "get", key],
        capture_output=True,
        text=True,
    )
    if res.returncode != 0:
        return None
    val = res.stdout.rstrip("\n")
    return val or None


def sc_set(key: str, value: str) -> None:
    """Write a single skill-config key. Raises on failure."""
    res = subprocess.run(
        [_skill_config_bin(), "set", key, value],
        capture_output=True,
        text=True,
    )
    if res.returncode != 0:
        raise RuntimeError(f"skill-config set {key} failed: {res.stderr.strip()}")


@dataclass
class ProfileCreds:
    client_id: str
    client_secret: str
    refresh_token: str | None


def load_profile(profile: str, *, require_refresh: bool) -> ProfileCreds:
    """Pull credentials for `profile` from skill-config.

    Raises SystemExit with a remediation hint when a required field is
    missing — the LLM is the immediate audience and benefits from being
    told which `skill-config request-input` to run next.
    """
    cid = sc_get(f"{SKILL}.{profile}.client_id")
    csec = sc_get(f"{SKILL}.{profile}.client_secret")
    rt = sc_get(f"{SKILL}.{profile}.refresh_token")
    missing: list[str] = []
    if not cid:
        missing.append("client_id")
    if not csec:
        missing.append("client_secret")
    if require_refresh and not rt:
        missing.append("refresh_token")
    if missing:
        names = ", ".join(missing)
        hint = f"run `skill-config request-input {SKILL}.{profile}.<field>` for each"
        if require_refresh and "refresh_token" in missing and cid and csec:
            hint = f"run `google-cli auth {profile}` to mint a refresh_token"
        sys.exit(f"error: google.{profile} missing: {names}. {hint}.")
    assert cid and csec
    return ProfileCreds(client_id=cid, client_secret=csec, refresh_token=rt)


# ── OAuth flow ───────────────────────────────────────────────────────


def _free_loopback_port() -> int:
    """Ask the kernel for a free port we can hand to the OAuth client.

    Closing the socket leaves a TIME_WAIT-immune binding window long
    enough for the next bind() to succeed in practice; both Google's
    quickstart and InstalledAppFlow.run_local_server use this pattern.
    """
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def build_auth_url(
    client_id: str,
    redirect_uri: str,
    scopes: Iterable[str],
    state: str,
) -> str:
    """Compose the consent URL.

    `access_type=offline` + `prompt=consent` is what forces Google to
    hand back a refresh_token. Without `prompt=consent`, a user who has
    already consented in a previous session gets only an access_token
    and the auth flow silently produces a half-broken profile.
    """
    params = {
        "response_type": "code",
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "scope": " ".join(scopes),
        "access_type": "offline",
        "prompt": "consent",
        "state": state,
    }
    return AUTH_URL + "?" + urllib.parse.urlencode(params)


class _CallbackHandler(http.server.BaseHTTPRequestHandler):
    # Set by the parent server in cmd_auth.
    expected_state: str = ""
    result: dict[str, str] = {}

    def do_GET(self) -> None:  # noqa: N802 — http.server name
        parsed = urllib.parse.urlsplit(self.path)
        qs = dict(urllib.parse.parse_qsl(parsed.query, keep_blank_values=True))
        if qs.get("state") != self.expected_state:
            self._respond(
                400,
                "State mismatch. Close this tab and retry `google-cli auth`.",
            )
            return
        if "error" in qs:
            self.result["error"] = qs["error"]
            self._respond(
                400,
                f"Authorization denied: {qs['error']}. You can close this tab.",
            )
            return
        code = qs.get("code")
        if not code:
            self._respond(
                400,
                "Missing authorization code. Close this tab and retry.",
            )
            return
        self.result["code"] = code
        self._respond(
            200,
            "Google authorization complete. You can close this tab and "
            "return to pi-chat.",
        )

    def log_message(self, *_args: Any) -> None:  # noqa: D401
        # Silence default request logging — the user is looking at the
        # CLI, not at stderr noise.
        pass

    def _respond(self, status: int, body: str) -> None:
        payload = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def _exchange_code(
    client_id: str,
    client_secret: str,
    code: str,
    redirect_uri: str,
) -> dict[str, Any]:
    """Hit Google's token endpoint to swap the authorization code for a
    refresh_token. Uses urllib so we don't pull in `requests` for one POST.
    """
    import urllib.request as _ur

    body = urllib.parse.urlencode(
        {
            "client_id": client_id,
            "client_secret": client_secret,
            "code": code,
            "grant_type": "authorization_code",
            "redirect_uri": redirect_uri,
        }
    ).encode()
    req = _ur.Request(
        TOKEN_URL,
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    try:
        with _ur.urlopen(req, timeout=30) as resp:  # noqa: S310 — known host
            return json.loads(resp.read().decode())
    except _ur.HTTPError as e:  # pragma: no cover — network branch
        detail = e.read().decode(errors="replace")
        raise SystemExit(f"token exchange failed: HTTP {e.code} {detail.strip()}")


def _open_url(url: str) -> None:
    """Open `url` in the user's browser.

    pi-chat runs each agent under a systemd-run sandbox (ProtectHome=
    tmpfs + private namespaces), so a direct `webbrowser.open` spawns
    Firefox/Chromium inside the sandbox where it cannot see the real
    user profile (Firefox: "Profile Missing"). The noctalia pi-chat
    plugin runs in the user's session and listens on a unix socket
    bind-mounted into the sandbox at $DISTRO_OPEN_URL_SOCKET; writing a
    single JSON line there delegates the open to the real session via
    `Qt.openUrlExternally`.

    When the env var is unset or the socket cannot be reached (headless
    invocations, the unit test harness, the daemon being down) we fall
    back to `webbrowser.open` so the helper stays useful outside the
    pi-chat sandbox.
    """
    sock_path = os.environ.get("DISTRO_OPEN_URL_SOCKET")
    if sock_path:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                s.settimeout(2.0)
                s.connect(sock_path)
                s.sendall((json.dumps({"url": url}) + "\n").encode())
            return
        except OSError:
            # Daemon not running / stale bind / refused — fall through to
            # the local webbrowser so the user at least gets *some* way to
            # reach the URL.
            pass
    try:
        webbrowser.open(url, new=2)
    except webbrowser.Error:
        pass


def cmd_auth(args: argparse.Namespace) -> None:
    creds = load_profile(args.profile, require_refresh=False)
    scopes = list(DEFAULT_SCOPES)
    port = _free_loopback_port()
    redirect_uri = f"http://127.0.0.1:{port}/"
    state = secrets.token_urlsafe(24)

    url = build_auth_url(creds.client_id, redirect_uri, scopes, state)

    _CallbackHandler.expected_state = state
    _CallbackHandler.result = {}

    server = http.server.HTTPServer(("127.0.0.1", port), _CallbackHandler)
    server.timeout = args.timeout

    print(
        "\n──────────────────────────────────────────────────────────"
        "\n  Open this URL in your browser to authorize pi-chat:"
        "\n──────────────────────────────────────────────────────────\n",
        flush=True,
    )
    print(url, flush=True)
    print(
        f"\nWaiting for the callback on {redirect_uri} (timeout: {args.timeout}s).\n",
        flush=True,
    )
    _open_url(url)

    # handle_request returns either when one request is served or when
    # the timeout fires. Loop so a stray GET (favicon, refresh) doesn't
    # exit before the real /?code= lands.
    deadline_thread = threading.Thread(
        target=server.handle_request,
        daemon=True,
    )
    deadline_thread.start()
    deadline_thread.join(timeout=args.timeout + 5)
    server.server_close()

    if _CallbackHandler.result.get("error"):
        sys.exit(f"authorization denied by Google: {_CallbackHandler.result['error']}")
    code = _CallbackHandler.result.get("code")
    if not code:
        sys.exit("timed out waiting for the OAuth callback")

    token = _exchange_code(creds.client_id, creds.client_secret, code, redirect_uri)
    refresh_token = token.get("refresh_token")
    if not refresh_token:
        sys.exit(
            "Google returned no refresh_token (the consent prompt did not "
            "include offline access). Revoke pi-chat access at "
            "https://myaccount.google.com/permissions and retry."
        )
    sc_set(f"{SKILL}.{args.profile}.refresh_token", refresh_token)
    print(f"saved google.{args.profile}.refresh_token")


# ── google-api clients ───────────────────────────────────────────────


def _build_credentials(creds: ProfileCreds, scopes: Iterable[str]) -> Any:
    """Materialize a `google.oauth2.credentials.Credentials` object that
    will auto-refresh against the stored refresh_token.
    """
    from google.oauth2.credentials import Credentials  # noqa: PLC0415

    return Credentials(
        token=None,
        refresh_token=creds.refresh_token,
        token_uri=TOKEN_URL,
        client_id=creds.client_id,
        client_secret=creds.client_secret,
        scopes=list(scopes),
    )


def _gmail_service(profile: str) -> Any:
    from googleapiclient.discovery import build  # noqa: PLC0415

    creds = load_profile(profile, require_refresh=True)
    return build(
        "gmail",
        "v1",
        credentials=_build_credentials(creds, [GMAIL_SCOPE]),
        cache_discovery=False,
    )


def _calendar_service(profile: str) -> Any:
    from googleapiclient.discovery import build  # noqa: PLC0415

    creds = load_profile(profile, require_refresh=True)
    return build(
        "calendar",
        "v3",
        credentials=_build_credentials(creds, [CALENDAR_SCOPE]),
        cache_discovery=False,
    )


# ── Gmail ────────────────────────────────────────────────────────────


def _header(payload: dict[str, Any], name: str) -> str:
    for h in payload.get("headers") or []:
        if h.get("name", "").lower() == name.lower():
            return h.get("value", "")
    return ""


def _decode_body(part: dict[str, Any]) -> str:
    data = part.get("body", {}).get("data")
    if not data:
        return ""
    pad = "=" * (-len(data) % 4)
    raw = base64.urlsafe_b64decode(data + pad)
    return raw.decode(errors="replace")


def _extract_plain_body(payload: dict[str, Any]) -> str:
    """Walk a Gmail message payload and return the best plain-text body.

    Prefers `text/plain`; falls back to a stripped-down `text/html`. The
    fallback isn't a full HTML parser — Gmail returns enough structured
    parts that we almost always have a `text/plain` alternative.
    """
    stack = [payload]
    html_body = ""
    while stack:
        part = stack.pop()
        mime = part.get("mimeType", "")
        if mime == "text/plain":
            body = _decode_body(part)
            if body:
                return body
        elif mime == "text/html" and not html_body:
            html_body = _decode_body(part)
        stack.extend(part.get("parts") or [])
    return html_body


def _format_message(msg: dict[str, Any]) -> str:
    payload = msg.get("payload") or {}
    return (
        f"id: {msg.get('id', '')}\n"
        f"from: {_header(payload, 'From')}\n"
        f"to: {_header(payload, 'To')}\n"
        f"date: {_header(payload, 'Date')}\n"
        f"subject: {_header(payload, 'Subject')}\n"
        f"snippet: {msg.get('snippet', '')}\n"
    )


def cmd_mail_list(args: argparse.Namespace) -> None:
    svc = _gmail_service(args.profile)
    req = (
        svc.users()
        .messages()
        .list(
            userId="me",
            q=args.query or "",
            maxResults=args.limit,
        )
    )
    resp = req.execute()
    ids = [m["id"] for m in resp.get("messages") or []]
    out: list[dict[str, Any]] = []
    for mid in ids:
        m = (
            svc.users()
            .messages()
            .get(
                userId="me",
                id=mid,
                format="metadata",
                metadataHeaders=["From", "To", "Date", "Subject"],
            )
            .execute()
        )
        out.append(m)
    if args.json:
        json.dump(out, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return
    if not out:
        print("(no messages)")
        return
    print("\n".join(_format_message(m) for m in out))


def cmd_mail_get(args: argparse.Namespace) -> None:
    svc = _gmail_service(args.profile)
    msg = svc.users().messages().get(userId="me", id=args.id, format="full").execute()
    if args.json:
        json.dump(msg, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return
    payload = msg.get("payload") or {}
    body = _extract_plain_body(payload)
    print(_format_message(msg))
    print(body)


def build_send_payload(
    *,
    to: str,
    subject: str,
    body: str,
    cc: str | None = None,
    bcc: str | None = None,
) -> dict[str, str]:
    """Pure helper — produce the JSON the Gmail API wants. Public so the
    unit tests can exercise it without hitting Google.
    """
    msg = EmailMessage()
    msg["To"] = to
    if cc:
        msg["Cc"] = cc
    if bcc:
        msg["Bcc"] = bcc
    msg["Subject"] = subject
    msg.set_content(body)
    raw = base64.urlsafe_b64encode(bytes(msg)).decode()
    return {"raw": raw}


def cmd_mail_send(args: argparse.Namespace) -> None:
    body = args.body
    if body is None:
        if args.body_file == "-":
            body = sys.stdin.read()
        elif args.body_file:
            with open(args.body_file, encoding="utf-8") as f:
                body = f.read()
        else:
            sys.exit("error: --body or --body-file is required")
    payload = build_send_payload(
        to=args.to,
        subject=args.subject,
        body=body,
        cc=args.cc,
        bcc=args.bcc,
    )
    svc = _gmail_service(args.profile)
    sent = svc.users().messages().send(userId="me", body=payload).execute()
    print(f"sent id={sent.get('id', '?')} threadId={sent.get('threadId', '?')}")


# ── Calendar ─────────────────────────────────────────────────────────


def cmd_calendar_calendars(args: argparse.Namespace) -> None:
    svc = _calendar_service(args.profile)
    resp = svc.calendarList().list().execute()
    items = resp.get("items") or []
    if args.json:
        json.dump(items, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return
    if not items:
        print("(no calendars)")
        return
    for c in items:
        primary = " [primary]" if c.get("primary") else ""
        print(f"{c.get('id', '')}  {c.get('summary', '')}{primary}")


def _format_event(ev: dict[str, Any]) -> str:
    start = ev.get("start", {})
    end = ev.get("end", {})
    s = start.get("dateTime") or start.get("date") or ""
    e = end.get("dateTime") or end.get("date") or ""
    return (
        f"id: {ev.get('id', '')}\n"
        f"summary: {ev.get('summary', '')}\n"
        f"start: {s}\n"
        f"end: {e}\n"
        f"location: {ev.get('location', '')}\n"
        f"description: {ev.get('description', '')}\n"
    )


def cmd_calendar_list(args: argparse.Namespace) -> None:
    svc = _calendar_service(args.profile)
    kwargs: dict[str, Any] = {
        "calendarId": args.calendar,
        "maxResults": args.limit,
        "singleEvents": True,
        "orderBy": "startTime",
    }
    if args.time_min:
        kwargs["timeMin"] = args.time_min
    if args.time_max:
        kwargs["timeMax"] = args.time_max
    if args.query:
        kwargs["q"] = args.query
    resp = svc.events().list(**kwargs).execute()
    items = resp.get("items") or []
    if args.json:
        json.dump(items, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return
    if not items:
        print("(no events)")
        return
    print("\n".join(_format_event(ev) for ev in items))


def cmd_calendar_get(args: argparse.Namespace) -> None:
    svc = _calendar_service(args.profile)
    ev = svc.events().get(calendarId=args.calendar, eventId=args.id).execute()
    if args.json:
        json.dump(ev, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return
    print(_format_event(ev))


def _event_time(value: str, all_day: bool) -> dict[str, str]:
    """Turn a CLI time string into the {date|dateTime, timeZone?} shape
    Google Calendar expects.

    `all_day` flips between date-only ("YYYY-MM-DD") and RFC 3339
    timestamps. Callers pre-validate the date-shape; we don't here so
    invalid input bounces off the API with its own diagnostics.
    """
    if all_day:
        return {"date": value}
    return {"dateTime": value}


def cmd_calendar_add(args: argparse.Namespace) -> None:
    body: dict[str, Any] = {
        "summary": args.summary,
        "start": _event_time(args.start, args.all_day),
        "end": _event_time(args.end, args.all_day),
    }
    if args.location:
        body["location"] = args.location
    if args.description:
        body["description"] = args.description
    if args.attendee:
        body["attendees"] = [{"email": a} for a in args.attendee]
    svc = _calendar_service(args.profile)
    ev = svc.events().insert(calendarId=args.calendar, body=body).execute()
    print(f"created id={ev.get('id', '?')} htmlLink={ev.get('htmlLink', '')}")


def cmd_calendar_delete(args: argparse.Namespace) -> None:
    svc = _calendar_service(args.profile)
    svc.events().delete(calendarId=args.calendar, eventId=args.id).execute()
    print(f"deleted {args.id}")


# ── argparse ─────────────────────────────────────────────────────────


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="google-cli")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_auth = sub.add_parser(
        "auth",
        help="Run the Google OAuth flow and store a refresh_token.",
    )
    p_auth.add_argument("profile")
    p_auth.add_argument(
        "--timeout",
        type=int,
        default=300,
        help="Seconds to wait for the OAuth callback (default 300).",
    )
    p_auth.set_defaults(func=cmd_auth)

    # mail …
    p_mail = sub.add_parser("mail", help="Gmail operations.")
    mail_sub = p_mail.add_subparsers(dest="mail_cmd", required=True)

    pm_list = mail_sub.add_parser("list", help="List messages.")
    pm_list.add_argument("profile")
    pm_list.add_argument(
        "-q",
        "--query",
        default="",
        help="Gmail search query (e.g. 'is:unread newer_than:1d').",
    )
    pm_list.add_argument("-n", "--limit", type=int, default=20)
    pm_list.add_argument("--json", action="store_true")
    pm_list.set_defaults(func=cmd_mail_list)

    pm_search = mail_sub.add_parser(
        "search",
        help="Alias for `list -q QUERY`.",
    )
    pm_search.add_argument("profile")
    pm_search.add_argument("-q", "--query", required=True)
    pm_search.add_argument("-n", "--limit", type=int, default=20)
    pm_search.add_argument("--json", action="store_true")
    pm_search.set_defaults(func=cmd_mail_list)

    pm_get = mail_sub.add_parser("get", help="Get one message.")
    pm_get.add_argument("profile")
    pm_get.add_argument("id")
    pm_get.add_argument("--json", action="store_true")
    pm_get.set_defaults(func=cmd_mail_get)

    pm_send = mail_sub.add_parser("send", help="Send a message.")
    pm_send.add_argument("profile")
    pm_send.add_argument("--to", required=True)
    pm_send.add_argument("--cc")
    pm_send.add_argument("--bcc")
    pm_send.add_argument("--subject", required=True)
    pm_send.add_argument("--body")
    pm_send.add_argument(
        "--body-file",
        help="Read body from this path (use '-' for stdin).",
    )
    pm_send.set_defaults(func=cmd_mail_send)

    # calendar …
    p_cal = sub.add_parser("calendar", help="Google Calendar operations.")
    cal_sub = p_cal.add_subparsers(dest="cal_cmd", required=True)

    pc_calendars = cal_sub.add_parser(
        "calendars",
        help="List calendars on the account.",
    )
    pc_calendars.add_argument("profile")
    pc_calendars.add_argument("--json", action="store_true")
    pc_calendars.set_defaults(func=cmd_calendar_calendars)

    pc_list = cal_sub.add_parser("list", help="List events.")
    pc_list.add_argument("profile")
    pc_list.add_argument(
        "--calendar",
        default="primary",
        help="Calendar ID (default: primary).",
    )
    pc_list.add_argument(
        "--from",
        dest="time_min",
        help="RFC 3339 lower bound (e.g. 2026-05-21T00:00:00Z).",
    )
    pc_list.add_argument(
        "--to",
        dest="time_max",
        help="RFC 3339 upper bound.",
    )
    pc_list.add_argument("-q", "--query", help="Free-text filter.")
    pc_list.add_argument("-n", "--limit", type=int, default=50)
    pc_list.add_argument("--json", action="store_true")
    pc_list.set_defaults(func=cmd_calendar_list)

    pc_get = cal_sub.add_parser("get", help="Get one event.")
    pc_get.add_argument("profile")
    pc_get.add_argument("id")
    pc_get.add_argument("--calendar", default="primary")
    pc_get.add_argument("--json", action="store_true")
    pc_get.set_defaults(func=cmd_calendar_get)

    pc_add = cal_sub.add_parser("add", help="Create an event.")
    pc_add.add_argument("profile")
    pc_add.add_argument("--calendar", default="primary")
    pc_add.add_argument("--summary", required=True)
    pc_add.add_argument(
        "--start",
        required=True,
        help="RFC 3339 timestamp, or YYYY-MM-DD with --all-day.",
    )
    pc_add.add_argument("--end", required=True)
    pc_add.add_argument("--all-day", action="store_true")
    pc_add.add_argument("--location")
    pc_add.add_argument("--description")
    pc_add.add_argument(
        "--attendee",
        action="append",
        default=[],
        help="Email of an attendee (repeatable).",
    )
    pc_add.set_defaults(func=cmd_calendar_add)

    pc_del = cal_sub.add_parser("delete", help="Delete an event.")
    pc_del.add_argument("profile")
    pc_del.add_argument("id")
    pc_del.add_argument("--calendar", default="primary")
    pc_del.set_defaults(func=cmd_calendar_delete)

    return ap


def main(argv: list[str] | None = None) -> None:
    ap = build_parser()
    args = ap.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()

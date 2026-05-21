"""Unit tests for google-cli.

We exercise the pieces that have non-trivial logic and avoid contacting
Google's APIs entirely:

  * skill-config plumbing (sc_get / sc_set, including the missing-field
    error message that tells the LLM what to ask for next).
  * The OAuth URL builder — Google's consent screen is strict about
    `access_type=offline` and `prompt=consent`, and a regression here
    silently breaks the "I need a refresh_token" workflow.
  * Gmail's RFC 2822 → base64url envelope, including CC.
  * Argument parsing routing (so each subcommand wires through to the
    expected function).

Network code (the loopback callback server + token exchange + Google
API calls) is intentionally not under test — those paths are thin
glue and a unit test mocking them only proves the mock is well-typed.
"""

from __future__ import annotations

import base64
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
import urllib.parse
from pathlib import Path
from unittest import mock

import google_cli


class StubSkillConfig:
    """Drop-in replacement for the `skill-config` binary.

    Writes a tiny shell script to a tempfile and points
    $SKILL_CONFIG_BIN at it. The script reads/writes a JSON-backed
    key/value store on disk so successive invocations share state, the
    way a real skill-config does via its TOML files.
    """

    def __init__(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Path(self.tmp.name) / "store.json"
        self.store.write_text("{}")
        self.bin = Path(self.tmp.name) / "skill-config"
        self.bin.write_text(
            textwrap.dedent(
                f"""\
                #!{sys.executable}
                import json, sys
                store_path = {str(self.store)!r}
                with open(store_path) as f:
                    store = json.load(f)
                op = sys.argv[1]
                if op == "get":
                    val = store.get(sys.argv[2])
                    if val is None:
                        sys.stderr.write(f"error: {{sys.argv[2]}} not set\\n")
                        sys.exit(1)
                    print(val)
                elif op == "set":
                    store[sys.argv[2]] = sys.argv[3]
                    with open(store_path, "w") as f:
                        json.dump(store, f)
                else:
                    sys.stderr.write(f"unknown op {{op}}\\n")
                    sys.exit(2)
                """
            )
        )
        self.bin.chmod(0o755)

    def env(self) -> dict[str, str]:
        return {"SKILL_CONFIG_BIN": str(self.bin)}

    def set(self, key: str, value: str) -> None:
        subprocess.run(
            [str(self.bin), "set", key, value],
            check=True,
        )

    def get(self, key: str) -> str | None:
        res = subprocess.run(
            [str(self.bin), "get", key],
            capture_output=True,
            text=True,
        )
        if res.returncode != 0:
            return None
        return res.stdout.rstrip("\n")

    def cleanup(self) -> None:
        self.tmp.cleanup()


class SkillConfigPlumbingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.sc = StubSkillConfig()
        self._env_patch = mock.patch.dict(os.environ, self.sc.env())
        self._env_patch.start()

    def tearDown(self) -> None:
        self._env_patch.stop()
        self.sc.cleanup()

    def test_sc_get_returns_none_for_missing_key(self) -> None:
        # Missing keys are an expected branch (we ask "is the profile
        # configured yet?"), not an exception. sc_get must swallow the
        # non-zero exit cleanly.
        self.assertIsNone(google_cli.sc_get("google.work.client_id"))

    def test_sc_set_then_get_roundtrip(self) -> None:
        google_cli.sc_set("google.work.client_id", "abc-123")
        self.assertEqual(
            google_cli.sc_get("google.work.client_id"),
            "abc-123",
        )

    def test_load_profile_lists_every_missing_field(self) -> None:
        with self.assertRaises(SystemExit) as cm:
            google_cli.load_profile("work", require_refresh=True)
        # The diagnostic must enumerate every gap so the LLM can call
        # request-input for each one without a second probe.
        msg = str(cm.exception)
        self.assertIn("client_id", msg)
        self.assertIn("client_secret", msg)
        self.assertIn("refresh_token", msg)

    def test_load_profile_with_client_but_no_refresh_recommends_auth(
        self,
    ) -> None:
        # Once OAuth client creds exist, the next step is mint-a-token —
        # the error message must point at `google-cli auth`, not a
        # `skill-config request-input` for a token the user can't paste.
        google_cli.sc_set("google.work.client_id", "cid")
        google_cli.sc_set("google.work.client_secret", "csec")
        with self.assertRaises(SystemExit) as cm:
            google_cli.load_profile("work", require_refresh=True)
        self.assertIn("google-cli auth work", str(cm.exception))

    def test_load_profile_without_refresh_succeeds_when_only_client_set(
        self,
    ) -> None:
        # `auth` itself doesn't need a refresh_token yet — that's what
        # it goes off to fetch. The require_refresh=False branch must
        # not falsely flag missing fields.
        google_cli.sc_set("google.work.client_id", "cid")
        google_cli.sc_set("google.work.client_secret", "csec")
        creds = google_cli.load_profile("work", require_refresh=False)
        self.assertEqual(creds.client_id, "cid")
        self.assertEqual(creds.client_secret, "csec")
        self.assertIsNone(creds.refresh_token)


class OAuthURLTests(unittest.TestCase):
    def test_build_auth_url_includes_offline_and_consent(self) -> None:
        # If Google's auth screen is hit without these two parameters,
        # a previously-consented user receives no refresh_token and the
        # `auth` flow silently produces a half-broken profile. Lock the
        # params down at the unit-test boundary.
        url = google_cli.build_auth_url(
            client_id="abc.apps.googleusercontent.com",
            redirect_uri="http://127.0.0.1:5555/",
            scopes=(google_cli.GMAIL_SCOPE, google_cli.CALENDAR_SCOPE),
            state="STATE",
        )
        parsed = urllib.parse.urlsplit(url)
        qs = dict(urllib.parse.parse_qsl(parsed.query))
        self.assertEqual(qs["access_type"], "offline")
        self.assertEqual(qs["prompt"], "consent")
        self.assertEqual(qs["state"], "STATE")
        self.assertEqual(qs["response_type"], "code")
        self.assertEqual(qs["client_id"], "abc.apps.googleusercontent.com")
        self.assertEqual(qs["redirect_uri"], "http://127.0.0.1:5555/")
        # Scopes are space-separated in the query value, not repeated.
        self.assertEqual(
            qs["scope"],
            f"{google_cli.GMAIL_SCOPE} {google_cli.CALENDAR_SCOPE}",
        )


class GmailEnvelopeTests(unittest.TestCase):
    def test_build_send_payload_is_base64url_rfc2822(self) -> None:
        payload = google_cli.build_send_payload(
            to="alice@example.com",
            subject="Hi",
            body="Hello there",
            cc="bob@example.com",
        )
        # Gmail's send endpoint wants a single `raw` key with a base64url
        # (no padding required, but tolerated) RFC 2822 message.
        self.assertEqual(list(payload.keys()), ["raw"])
        # Round-trip and check the headers landed where we said.
        pad = "=" * (-len(payload["raw"]) % 4)
        raw = base64.urlsafe_b64decode(payload["raw"] + pad).decode()
        self.assertIn("To: alice@example.com", raw)
        self.assertIn("Cc: bob@example.com", raw)
        self.assertIn("Subject: Hi", raw)
        self.assertIn("Hello there", raw)


class FormatHelperTests(unittest.TestCase):
    def test_format_message_pulls_headers_case_insensitively(self) -> None:
        # The Gmail REST surface returns headers with idiosyncratic
        # casing (`From`, `from`, `FROM` have all shown up depending on
        # the source server). Lock the header lookup to be
        # case-insensitive so list/get output stays readable.
        msg = {
            "id": "deadbeef",
            "snippet": "hello",
            "payload": {
                "headers": [
                    {"name": "from", "value": "alice@example.com"},
                    {"name": "SUBJECT", "value": "Hi"},
                    {"name": "To", "value": "me@example.com"},
                ]
            },
        }
        out = google_cli._format_message(msg)
        self.assertIn("from: alice@example.com", out)
        self.assertIn("subject: Hi", out)
        self.assertIn("to: me@example.com", out)

    def test_extract_plain_body_prefers_text_plain(self) -> None:
        # A multipart message where text/html came first must still
        # surface the text/plain alternative.
        def b64(s: str) -> str:
            return base64.urlsafe_b64encode(s.encode()).decode().rstrip("=")

        payload = {
            "mimeType": "multipart/alternative",
            "parts": [
                {
                    "mimeType": "text/html",
                    "body": {"data": b64("<p>hi</p>")},
                },
                {
                    "mimeType": "text/plain",
                    "body": {"data": b64("hi plain")},
                },
            ],
        }
        self.assertEqual(google_cli._extract_plain_body(payload), "hi plain")

    def test_event_time_all_day_vs_timed(self) -> None:
        self.assertEqual(
            google_cli._event_time("2026-05-21", all_day=True),
            {"date": "2026-05-21"},
        )
        self.assertEqual(
            google_cli._event_time(
                "2026-05-21T09:00:00Z",
                all_day=False,
            ),
            {"dateTime": "2026-05-21T09:00:00Z"},
        )


class ArgparseRoutingTests(unittest.TestCase):
    """Each subcommand must point at the right handler.

    Mis-routing here would make the CLI silently call the wrong API
    (e.g. `mail send` invoking the list handler), so we verify the
    .func attribute argparse stamps onto the namespace.
    """

    def setUp(self) -> None:
        self.parser = google_cli.build_parser()

    def _parse(self, *argv: str) -> object:
        return self.parser.parse_args(list(argv))

    def test_auth_routes_to_cmd_auth(self) -> None:
        ns = self._parse("auth", "work")
        self.assertIs(ns.func, google_cli.cmd_auth)
        self.assertEqual(ns.profile, "work")

    def test_mail_list_routes(self) -> None:
        ns = self._parse("mail", "list", "personal", "-q", "is:unread")
        self.assertIs(ns.func, google_cli.cmd_mail_list)
        self.assertEqual(ns.query, "is:unread")
        # default limit defends the LLM against pulling a 1000-message
        # inbox into context.
        self.assertEqual(ns.limit, 20)

    def test_mail_search_aliases_list(self) -> None:
        ns = self._parse("mail", "search", "personal", "-q", "from:bob")
        self.assertIs(ns.func, google_cli.cmd_mail_list)
        self.assertEqual(ns.query, "from:bob")

    def test_mail_send_requires_to_and_subject(self) -> None:
        with self.assertRaises(SystemExit):
            self._parse("mail", "send", "personal", "--subject", "Hi")
        ns = self._parse(
            "mail",
            "send",
            "personal",
            "--to",
            "a@b",
            "--subject",
            "Hi",
            "--body",
            "Hey",
        )
        self.assertIs(ns.func, google_cli.cmd_mail_send)

    def test_calendar_add_requires_summary_start_end(self) -> None:
        with self.assertRaises(SystemExit):
            self._parse(
                "calendar",
                "add",
                "personal",
                "--summary",
                "x",
                "--start",
                "2026-05-21T09:00:00Z",
            )
        ns = self._parse(
            "calendar",
            "add",
            "personal",
            "--summary",
            "Lunch",
            "--start",
            "2026-05-21T12:00:00Z",
            "--end",
            "2026-05-21T13:00:00Z",
        )
        self.assertIs(ns.func, google_cli.cmd_calendar_add)
        # Default calendar is the user's primary — that's what almost
        # every `add` request actually wants.
        self.assertEqual(ns.calendar, "primary")

    def test_calendar_list_defaults(self) -> None:
        ns = self._parse("calendar", "list", "personal")
        self.assertIs(ns.func, google_cli.cmd_calendar_list)
        self.assertEqual(ns.calendar, "primary")
        self.assertEqual(ns.limit, 50)


if __name__ == "__main__":
    unittest.main()

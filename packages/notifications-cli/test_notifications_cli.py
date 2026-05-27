"""Unit tests for the `notifications` CLI.

Run as a stand-alone unittest module (no pytest dep in the closure):
    python -m unittest test_notifications_cli -v

Behaviour under test:
  * `list` defaults to human-readable text, newest first, with ISO-8601 UTC
    timestamps (the underlying file stores ms-since-epoch).
  * `--limit`, `--app`, `--since`, `--urgency` filter the same way they read.
  * `--json` emits raw entries unchanged (apart from the filters above).
  * `get <id>` echoes one full entry.
  * Missing file is **not** an error — pi must be able to call this on a
    fresh session before any notification has been delivered.
  * Malformed JSON exits non-zero with a single-line message on stderr.
  * `DISTRO_NOTIFICATIONS_FILE` overrides the default path.
"""

from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

import notifications_cli

# 2026-05-20T17:42:30Z = 1779298950000 ms.
T0 = 1779298950000
T1 = T0 - 60_000  # one minute earlier
T2 = T0 - 3_600_000  # one hour earlier


def sample_payload() -> dict:
    return {
        "notifications": [
            {
                "id": "abc12345" + "0" * 56,
                "appName": "Ferdium",
                "summary": "flokli (Pradille Geek Week 2026)",
                "body": "@hsngrmpf:matrix.org: meet at the station",
                "urgency": 1,
                "timestamp": T0,
                "actionsJson": "[]",
                "originalId": 1,
            },
            {
                "id": "def67890" + "0" * 56,
                "appName": "Slack",
                "summary": "alice: ping",
                "body": "are you around?",
                "urgency": 0,
                "timestamp": T1,
                "actionsJson": "[]",
                "originalId": 2,
            },
            {
                "id": "ffffcafe" + "0" * 56,
                "appName": "kernel",
                "summary": "low battery",
                "body": "10% remaining",
                "urgency": 2,
                "timestamp": T2,
                "actionsJson": "[]",
                "originalId": 3,
            },
        ]
    }


class CliHarness(unittest.TestCase):
    """Drive notifications_cli.main() in-process with a tmpfile + env override."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "notifications.json"
        self._old_env = os.environ.get("DISTRO_NOTIFICATIONS_FILE")
        os.environ["DISTRO_NOTIFICATIONS_FILE"] = str(self.path)

    def tearDown(self) -> None:
        if self._old_env is None:
            os.environ.pop("DISTRO_NOTIFICATIONS_FILE", None)
        else:
            os.environ["DISTRO_NOTIFICATIONS_FILE"] = self._old_env

    def write(self, payload: dict | str) -> None:
        if isinstance(payload, dict):
            self.path.write_text(json.dumps(payload))
        else:
            self.path.write_text(payload)

    def run_cli(self, *args: str) -> tuple[int, str, str]:
        stdout = io.StringIO()
        stderr = io.StringIO()
        argv = ["notifications", *args]
        old_argv = sys.argv
        sys.argv = argv
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                code = notifications_cli.main()
        except SystemExit as exc:  # argparse exits via SystemExit
            code = int(exc.code or 0)
        finally:
            sys.argv = old_argv
        return code, stdout.getvalue(), stderr.getvalue()


class ListTextFormat(CliHarness):
    def test_emits_one_block_per_notification_newest_first(self) -> None:
        self.write(sample_payload())
        code, out, err = self.run_cli("list")
        self.assertEqual(code, 0, msg=err)
        # Newest first → Ferdium block precedes Slack which precedes kernel.
        ferd = out.index("Ferdium")
        slack = out.index("Slack")
        kern = out.index("kernel")
        self.assertLess(ferd, slack)
        self.assertLess(slack, kern)

    def test_renders_iso_utc_timestamp(self) -> None:
        self.write(sample_payload())
        _, out, _ = self.run_cli("list")
        self.assertIn("2026-05-20T17:42:30Z", out)

    def test_renders_urgency_label(self) -> None:
        self.write(sample_payload())
        _, out, _ = self.run_cli("list")
        # urgency 0/1/2 → low/normal/critical labels.
        self.assertIn("low", out)
        self.assertIn("normal", out)
        self.assertIn("critical", out)

    def test_includes_body_text(self) -> None:
        self.write(sample_payload())
        _, out, _ = self.run_cli("list")
        self.assertIn("meet at the station", out)
        self.assertIn("are you around?", out)


class ListFilters(CliHarness):
    def test_limit_truncates_to_newest_n(self) -> None:
        self.write(sample_payload())
        _, out, _ = self.run_cli("list", "--limit", "1")
        self.assertIn("Ferdium", out)
        self.assertNotIn("Slack", out)
        self.assertNotIn("kernel", out)

    def test_app_filter_is_case_insensitive(self) -> None:
        self.write(sample_payload())
        _, out, _ = self.run_cli("list", "--app", "SLACK")
        self.assertIn("Slack", out)
        self.assertNotIn("Ferdium", out)
        self.assertNotIn("kernel", out)

    def test_since_drops_older_entries(self) -> None:
        self.write(sample_payload())
        # 30 minutes ago in ms → keeps Ferdium (T0) and Slack (T1) but drops kernel (T2 = -1h).
        cutoff = T0 - 30 * 60 * 1000
        _, out, _ = self.run_cli("list", "--since", str(cutoff))
        self.assertIn("Ferdium", out)
        self.assertIn("Slack", out)
        self.assertNotIn("kernel", out)

    def test_urgency_filter_by_label(self) -> None:
        self.write(sample_payload())
        _, out, _ = self.run_cli("list", "--urgency", "critical")
        self.assertIn("kernel", out)
        self.assertNotIn("Ferdium", out)
        self.assertNotIn("Slack", out)


class JsonOutput(CliHarness):
    def test_list_json_is_valid_array_after_filters(self) -> None:
        self.write(sample_payload())
        _, out, _ = self.run_cli("list", "--json", "--app", "Slack")
        parsed = json.loads(out)
        self.assertIsInstance(parsed, list)
        self.assertEqual(len(parsed), 1)
        self.assertEqual(parsed[0]["appName"], "Slack")

    def test_list_json_preserves_timestamp_in_ms(self) -> None:
        self.write(sample_payload())
        _, out, _ = self.run_cli("list", "--json", "--limit", "1")
        parsed = json.loads(out)
        self.assertEqual(parsed[0]["timestamp"], T0)


class Get(CliHarness):
    def test_get_by_full_id(self) -> None:
        self.write(sample_payload())
        full_id = "def67890" + "0" * 56
        code, out, err = self.run_cli("get", full_id)
        self.assertEqual(code, 0, msg=err)
        self.assertIn("Slack", out)
        self.assertIn("are you around?", out)

    def test_get_by_prefix(self) -> None:
        self.write(sample_payload())
        # First 8 chars are enough to disambiguate the fixture.
        code, out, _ = self.run_cli("get", "abc12345")
        self.assertEqual(code, 0)
        self.assertIn("Ferdium", out)

    def test_get_unknown_id_exits_non_zero(self) -> None:
        self.write(sample_payload())
        code, _, err = self.run_cli("get", "0" * 64)
        self.assertNotEqual(code, 0)
        self.assertIn("not found", err.lower())


class Robustness(CliHarness):
    def test_missing_file_is_not_an_error(self) -> None:
        # path intentionally not created
        code, out, err = self.run_cli("list")
        self.assertEqual(code, 0, msg=err)
        self.assertNotIn("Traceback", err)
        # Friendly message rather than a noisy empty block.
        self.assertIn("no notifications", out.lower())

    def test_missing_file_with_json_returns_empty_array(self) -> None:
        code, out, _ = self.run_cli("list", "--json")
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out), [])

    def test_malformed_json_exits_non_zero_with_message(self) -> None:
        self.write("{not json")
        code, _, err = self.run_cli("list")
        self.assertNotEqual(code, 0)
        self.assertIn("notifications.json", err)
        self.assertNotIn("Traceback", err)

    def test_env_var_overrides_default_path(self) -> None:
        # Already exercised implicitly by CliHarness — pin it explicitly.
        self.write(sample_payload())
        self.assertEqual(os.environ["DISTRO_NOTIFICATIONS_FILE"], str(self.path))
        code, out, _ = self.run_cli("list")
        self.assertEqual(code, 0)
        self.assertIn("Ferdium", out)


class HelpAndUsage(unittest.TestCase):
    def test_no_args_prints_usage(self) -> None:
        stderr = io.StringIO()
        sys.argv = ["notifications"]
        with redirect_stderr(stderr):
            try:
                notifications_cli.main()
            except SystemExit as exc:
                code = int(exc.code or 0)
            else:
                code = 0
        self.assertNotEqual(code, 0)
        self.assertIn("usage", stderr.getvalue().lower())


class FallbackPathResolution(unittest.TestCase):
    """The CLI looks at DISTRO_NOTIFICATIONS_FILE first, then NOCTALIA_NOTIF_HISTORY_FILE."""

    def setUp(self) -> None:
        self._snapshot = {
            k: os.environ.pop(k, None)
            for k in ("DISTRO_NOTIFICATIONS_FILE", "NOCTALIA_NOTIF_HISTORY_FILE")
        }

    def tearDown(self) -> None:
        for key, value in self._snapshot.items():
            if value is not None:
                os.environ[key] = value
            else:
                os.environ.pop(key, None)

    def _drive(self, *args: str) -> tuple[int, str]:
        stdout = io.StringIO()
        old_argv = sys.argv
        sys.argv = ["notifications", *args]
        try:
            with redirect_stdout(stdout):
                code = notifications_cli.main()
        except SystemExit as exc:
            code = int(exc.code or 0)
        finally:
            sys.argv = old_argv
        return code, stdout.getvalue()

    def test_noctalia_env_used_when_distro_var_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "from-noctalia.json"
            path.write_text(json.dumps(sample_payload()))
            os.environ["NOCTALIA_NOTIF_HISTORY_FILE"] = str(path)
            code, out = self._drive("list", "--limit", "1")
            self.assertEqual(code, 0)
            self.assertIn("Ferdium", out)

    def test_distro_var_takes_precedence_over_noctalia(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            primary = Path(tmp) / "distro.json"
            secondary = Path(tmp) / "noctalia.json"
            primary.write_text(json.dumps(sample_payload()))
            secondary.write_text(json.dumps({"notifications": []}))
            os.environ["DISTRO_NOTIFICATIONS_FILE"] = str(primary)
            os.environ["NOCTALIA_NOTIF_HISTORY_FILE"] = str(secondary)
            code, out = self._drive("list", "--limit", "1")
            self.assertEqual(code, 0)
            # primary fixture is non-empty; secondary would produce "(no notifications)"
            self.assertIn("Ferdium", out)


if __name__ == "__main__":
    unittest.main()

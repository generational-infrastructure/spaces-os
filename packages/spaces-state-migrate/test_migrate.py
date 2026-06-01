"""Tests for spaces_state_migrate.migrate.

Each test sets up a small fake ``$HOME`` with the relevant legacy and
new layouts, runs a single migration helper, and asserts the
post-migration shape. The helpers are pure with respect to the two
paths they're given so we never touch the real $HOME.
"""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from spaces_state_migrate import migrate


def _session(sid: str, last_active_at: int = 0) -> dict:
    return {
        "id": sid,
        "name": f"Chat {sid}",
        "lastActiveAt": last_active_at,
        "createdAt": last_active_at,
        "memoryEnabled": True,
        "model": "",
        "trusted": False,
        "unread": 0,
        "workspacePath": f"/wsp/{sid}",
    }


class TempHomeBase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)


# ── sessions.json JSON-merge ────────────────────────────────────────


class TestMergeSessionsIndex(TempHomeBase):
    def _write(self, path: Path, data: dict) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data))

    def test_returns_false_when_legacy_missing(self) -> None:
        new = self.root / "new.json"
        self.assertFalse(migrate.merge_sessions_index(self.root / "legacy.json", new))
        self.assertFalse(new.exists())

    def test_moves_legacy_when_new_missing(self) -> None:
        legacy = self.root / "legacy.json"
        new = self.root / "new.json"
        self._write(
            legacy,
            {"version": 1, "sessions": [_session("a", 100)], "activeSessionId": "a"},
        )
        self.assertTrue(migrate.merge_sessions_index(legacy, new))
        out = json.loads(new.read_text())
        self.assertEqual([s["id"] for s in out["sessions"]], ["a"])
        self.assertEqual(out["activeSessionId"], "a")
        self.assertFalse(legacy.exists())

    def test_union_by_id_new_wins_collision(self) -> None:
        legacy = self.root / "legacy.json"
        new = self.root / "new.json"
        self._write(
            legacy,
            {
                "version": 1,
                "sessions": [_session("old1", 50), _session("dup", 10)],
                "activeSessionId": "old1",
            },
        )
        new_dup = _session("dup", 500)
        new_dup["name"] = "renamed-by-user"
        self._write(
            new,
            {
                "version": 1,
                "sessions": [new_dup, _session("new1", 200)],
                "activeSessionId": "new1",
            },
        )
        self.assertTrue(migrate.merge_sessions_index(legacy, new))
        out = json.loads(new.read_text())
        ids = [s["id"] for s in out["sessions"]]
        self.assertCountEqual(ids, ["old1", "dup", "new1"])
        # Newest-first ordering. dup wins (lastActiveAt=500) over
        # new1 (200) over old1 (50).
        self.assertEqual(ids, ["dup", "new1", "old1"])
        # New wins on collision — name must be the post-rename one.
        dup = next(s for s in out["sessions"] if s["id"] == "dup")
        self.assertEqual(dup["name"], "renamed-by-user")
        # activeSessionId comes from the new file (user choice "today wins").
        self.assertEqual(out["activeSessionId"], "new1")

    def test_workspace_path_rewritten_to_spaces_prefix(self) -> None:
        legacy = self.root / "legacy.json"
        new = self.root / "new.json"
        legacy_session = _session("hist", 50)
        legacy_session["workspacePath"] = "/home/u/.local/share/distro/workspaces/hist"
        # And one entry with a user-set workspacePath that has nothing
        # to do with the rename — MUST pass through untouched.
        custom = _session("custom", 60)
        custom["workspacePath"] = "/srv/projects/some-repo"
        self._write(
            legacy,
            {
                "version": 1,
                "sessions": [legacy_session, custom],
                "activeSessionId": "hist",
            },
        )
        self.assertTrue(migrate.merge_sessions_index(legacy, new))
        out = json.loads(new.read_text())
        by_id = {s["id"]: s for s in out["sessions"]}
        self.assertEqual(
            by_id["hist"]["workspacePath"],
            "/home/u/.local/share/spaces/workspaces/hist",
        )
        self.assertEqual(by_id["custom"]["workspacePath"], "/srv/projects/some-repo")

    def test_state_path_in_workspace_field_also_rewritten(self) -> None:
        # The rename touched both share/ and state/ — and at least one
        # historical pi-chat build wrote workspacePath under state/.
        # The migration MUST cover both prefixes.
        legacy = self.root / "legacy.json"
        new = self.root / "new.json"
        s = _session("s", 50)
        s["workspacePath"] = "/home/u/.local/state/distro/pi/workspaces/s"
        self._write(legacy, {"version": 1, "sessions": [s], "activeSessionId": "s"})
        self.assertTrue(migrate.merge_sessions_index(legacy, new))
        out = json.loads(new.read_text())
        self.assertEqual(
            out["sessions"][0]["workspacePath"],
            "/home/u/.local/state/spaces/pi/workspaces/s",
        )

    def test_active_falls_back_to_legacy_when_new_lacks_one(self) -> None:
        legacy = self.root / "legacy.json"
        new = self.root / "new.json"
        self._write(
            legacy,
            {"version": 1, "sessions": [_session("a")], "activeSessionId": "a"},
        )
        self._write(new, {"version": 1, "sessions": [], "activeSessionId": None})
        self.assertTrue(migrate.merge_sessions_index(legacy, new))
        out = json.loads(new.read_text())
        self.assertEqual(out["activeSessionId"], "a")

    def test_malformed_legacy_is_a_noop_not_a_crash(self) -> None:
        legacy = self.root / "legacy.json"
        new = self.root / "new.json"
        legacy.write_text("not json {")
        self._write(
            new, {"version": 1, "sessions": [_session("n")], "activeSessionId": "n"}
        )
        self.assertFalse(migrate.merge_sessions_index(legacy, new))
        # New must be untouched — a corrupt legacy can't blow away the
        # working index.
        out = json.loads(new.read_text())
        self.assertEqual([s["id"] for s in out["sessions"]], ["n"])
        self.assertTrue(legacy.exists())


# ── self-healing workspacePath repair ───────────────────────────────


class TestRewriteWorkspacePaths(TempHomeBase):
    """Self-healing repair pass for sessions.json — runs on the new
    index whether or not a legacy index was merged this run, so users
    on a half-migrated host (e.g. signal recovered but pi never) get
    their workspacePaths fixed up too.
    """

    def _write_index(self, path: Path, sessions: list[dict]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(
                {"version": 1, "activeSessionId": None, "sessions": sessions},
                indent=4,
            )
        )

    def test_returns_false_when_no_changes_needed(self) -> None:
        idx = self.root / "sessions.json"
        s = _session("a")
        s["workspacePath"] = "/home/u/.local/share/spaces/workspaces/a"
        self._write_index(idx, [s])
        self.assertFalse(migrate.rewrite_workspace_paths(idx))

    def test_rewrites_distro_paths(self) -> None:
        idx = self.root / "sessions.json"
        s_broken = _session("a")
        s_broken["workspacePath"] = "/home/u/.local/share/distro/workspaces/a"
        s_ok = _session("b")
        s_ok["workspacePath"] = "/home/u/.local/share/spaces/workspaces/b"
        self._write_index(idx, [s_broken, s_ok])
        self.assertTrue(migrate.rewrite_workspace_paths(idx))
        out = json.loads(idx.read_text())
        by_id = {s["id"]: s for s in out["sessions"]}
        self.assertEqual(
            by_id["a"]["workspacePath"],
            "/home/u/.local/share/spaces/workspaces/a",
        )
        self.assertEqual(
            by_id["b"]["workspacePath"],
            "/home/u/.local/share/spaces/workspaces/b",
        )

    def test_missing_index_is_a_noop(self) -> None:
        self.assertFalse(migrate.rewrite_workspace_paths(self.root / "missing.json"))


# ── per-directory UNION merge ───────────────────────────────────────


class TestUnionSubdirs(TempHomeBase):
    def test_returns_zero_when_legacy_missing(self) -> None:
        self.assertEqual(
            migrate.union_subdirs(self.root / "legacy", self.root / "new"), 0
        )

    def test_moves_only_non_colliding_entries(self) -> None:
        legacy = self.root / "legacy"
        new = self.root / "new"
        for sid in ("a", "b", "dup"):
            (legacy / sid).mkdir(parents=True)
            (legacy / sid / "marker").write_text(f"legacy-{sid}")
        (new / "dup").mkdir(parents=True)
        (new / "dup" / "marker").write_text("new-dup")
        (new / "c").mkdir()
        moved = migrate.union_subdirs(legacy, new)
        self.assertEqual(moved, 2)
        self.assertEqual((new / "a" / "marker").read_text(), "legacy-a")
        self.assertEqual((new / "b" / "marker").read_text(), "legacy-b")
        # Collision: new wins.
        self.assertEqual((new / "dup" / "marker").read_text(), "new-dup")
        self.assertTrue((new / "c").is_dir())
        self.assertFalse((legacy / "a").exists())
        self.assertFalse((legacy / "b").exists())
        # Stale collision discarded so the legacy root collapses.
        self.assertFalse((legacy / "dup").exists())

    def test_creates_new_root_when_absent(self) -> None:
        legacy = self.root / "legacy"
        new = self.root / "new"
        (legacy / "x").mkdir(parents=True)
        moved = migrate.union_subdirs(legacy, new)
        self.assertEqual(moved, 1)
        self.assertTrue((new / "x").is_dir())


# ── take-over-if-empty (skill-config / notifications / cache) ───────


class TestTakeOverIfEmpty(TempHomeBase):
    def test_moves_legacy_when_new_missing(self) -> None:
        legacy = self.root / "legacy"
        new = self.root / "new"
        legacy.mkdir()
        (legacy / "config.toml").write_text("x = 1")
        self.assertTrue(migrate.take_over_if_empty(legacy, new))
        self.assertEqual((new / "config.toml").read_text(), "x = 1")
        self.assertFalse(legacy.exists())

    def test_moves_legacy_when_new_is_an_empty_dir(self) -> None:
        legacy = self.root / "legacy"
        new = self.root / "new"
        new.mkdir()
        legacy.mkdir()
        (legacy / "history.json").write_text("[]")
        self.assertTrue(migrate.take_over_if_empty(legacy, new))
        self.assertEqual((new / "history.json").read_text(), "[]")

    def test_refuses_when_new_has_content(self) -> None:
        legacy = self.root / "legacy"
        new = self.root / "new"
        new.mkdir()
        (new / "existing").write_text("keep me")
        legacy.mkdir()
        (legacy / "history.json").write_text("[]")
        self.assertFalse(migrate.take_over_if_empty(legacy, new))
        self.assertEqual((new / "existing").read_text(), "keep me")
        self.assertTrue(legacy.exists())

    def test_returns_false_when_legacy_missing(self) -> None:
        new = self.root / "new"
        self.assertFalse(migrate.take_over_if_empty(self.root / "legacy", new))
        self.assertFalse(new.exists())


# ── sediment: swap-with-backup ──────────────────────────────────────


class TestSwapWithBackup(TempHomeBase):
    def test_moves_legacy_in_and_renames_new_to_backup(self) -> None:
        legacy = self.root / "sediment"
        new = self.root / "new" / "sediment"
        new.mkdir(parents=True)
        (new / "access.db").write_text("today")
        (new / "data").mkdir()
        (new / "data" / "today.lance").write_text("today-lance")
        legacy.mkdir()
        (legacy / "data").mkdir()
        (legacy / "data" / "history.lance").write_text("old-lance")
        self.assertTrue(migrate.swap_with_backup(legacy, new))
        # Legacy data now under new.
        self.assertEqual((new / "data" / "history.lance").read_text(), "old-lance")
        # Today's writes preserved alongside as a sibling backup.
        backup = new.parent / "sediment.post-rename"
        self.assertTrue(backup.is_dir())
        self.assertEqual((backup / "access.db").read_text(), "today")
        self.assertEqual((backup / "data" / "today.lance").read_text(), "today-lance")
        self.assertFalse(legacy.exists())

    def test_moves_legacy_in_when_new_missing(self) -> None:
        legacy = self.root / "sediment"
        new = self.root / "new" / "sediment"
        legacy.mkdir()
        (legacy / "data.lance").write_text("history")
        self.assertTrue(migrate.swap_with_backup(legacy, new))
        self.assertEqual((new / "data.lance").read_text(), "history")
        self.assertFalse((new.parent / "sediment.post-rename").exists())

    def test_returns_false_when_legacy_missing(self) -> None:
        new = self.root / "new" / "sediment"
        self.assertFalse(migrate.swap_with_backup(self.root / "sediment", new))

    def test_does_not_double_backup_on_rerun(self) -> None:
        legacy = self.root / "sediment"
        new = self.root / "new" / "sediment"
        new.mkdir(parents=True)
        (new / "x").write_text("v1")
        legacy.mkdir()
        (legacy / "y").write_text("y")
        self.assertTrue(migrate.swap_with_backup(legacy, new))
        # Second invocation: legacy gone — clean no-op, no second backup.
        self.assertFalse(migrate.swap_with_backup(legacy, new))
        backup = new.parent / "sediment.post-rename"
        self.assertTrue(backup.is_dir())
        self.assertEqual((backup / "x").read_text(), "v1")
        self.assertFalse((new.parent / "sediment.post-rename.post-rename").exists())


# ── top-level driver: full $HOME shape ──────────────────────────────


class TestRunMigration(TempHomeBase):
    """End-to-end test of `migrate.run(home)` against a $HOME laid out
    like the user's actual machine when the rename hit: signal + pi +
    workspaces populated under ``distro/``, fresh tmpfiles skeleton
    under ``spaces/`` with one active chat already in
    ``sessions.json`` and sediment scribbled in.
    """

    def _touch(self, path: Path, content: str = "") -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def test_full_migration_recovers_history_keeps_active(self) -> None:
        home = self.root
        legacy_state = home / ".local" / "state" / "distro"
        legacy_share = home / ".local" / "share" / "distro"

        # Legacy: real user data the rename orphaned.
        self._touch(
            legacy_state / "pi" / "sessions.json",
            json.dumps(
                {
                    "version": 1,
                    "activeSessionId": "old-active",
                    "sessions": [
                        _session("old-active", 100),
                        _session("hist1", 80),
                        _session("collide", 50),
                    ],
                }
            ),
        )
        for sid in ("old-active", "hist1", "collide"):
            self._touch(
                legacy_state / "pi" / "sessions" / sid / "log.jsonl",
                f"legacy-{sid}",
            )
            self._touch(
                legacy_share / "workspaces" / sid / "marker",
                f"legacy-ws-{sid}",
            )
        self._touch(legacy_state / "pi" / "skill-config" / "secrets.toml", "secret")
        self._touch(legacy_state / "pi" / "notifications" / "history.json", "[]")
        self._touch(
            legacy_state / "pi" / "sediment" / "data" / "history.lance", "memory"
        )
        self._touch(legacy_state / "pi" / "sediment-cache" / "blob", "cache")
        self._touch(legacy_state / "signal" / "messages.db", "sqlite-bytes-here")

        # New: what tmpfiles + today's pi-chat run already created.
        new_state = home / ".local" / "state" / "spaces"
        new_share = home / ".local" / "share" / "spaces"
        self._touch(
            new_state / "pi" / "sessions.json",
            json.dumps(
                {
                    "version": 1,
                    "activeSessionId": "today",
                    "sessions": [
                        _session("today", 1000),
                        _session("collide", 999),
                    ],
                }
            ),
        )
        self._touch(new_state / "pi" / "sessions" / "today" / "log.jsonl", "today-log")
        self._touch(
            new_state / "pi" / "sessions" / "collide" / "log.jsonl",
            "today-collide",
        )
        self._touch(new_share / "workspaces" / "today" / "marker", "today-ws")
        # Today's tiny sediment writes — must be preserved as a backup.
        self._touch(new_state / "pi" / "sediment" / "access.db", "today-access")
        (new_state / "pi" / "skill-config").mkdir(parents=True)
        (new_state / "pi" / "notifications").mkdir(parents=True)

        migrate.run(home)

        # sessions.json: 4 unique ids, today's activeSessionId preserved.
        idx = json.loads((new_state / "pi" / "sessions.json").read_text())
        self.assertCountEqual(
            [s["id"] for s in idx["sessions"]],
            ["today", "old-active", "hist1", "collide"],
        )
        self.assertEqual(idx["activeSessionId"], "today")

        # sessions/: union — collide stays the today version.
        sess_dir = new_state / "pi" / "sessions"
        self.assertEqual((sess_dir / "today" / "log.jsonl").read_text(), "today-log")
        self.assertEqual(
            (sess_dir / "collide" / "log.jsonl").read_text(), "today-collide"
        )
        self.assertEqual(
            (sess_dir / "old-active" / "log.jsonl").read_text(),
            "legacy-old-active",
        )
        self.assertEqual((sess_dir / "hist1" / "log.jsonl").read_text(), "legacy-hist1")

        # workspaces/: legacy 'collide' had no collision in new (we
        # only created today's workspace), so it lands as legacy data.
        wsp = new_share / "workspaces"
        self.assertEqual((wsp / "today" / "marker").read_text(), "today-ws")
        self.assertEqual((wsp / "hist1" / "marker").read_text(), "legacy-ws-hist1")
        self.assertEqual((wsp / "collide" / "marker").read_text(), "legacy-ws-collide")
        self.assertEqual(
            (wsp / "old-active" / "marker").read_text(),
            "legacy-ws-old-active",
        )

        # skill-config + notifications: take_over_if_empty fired.
        self.assertEqual(
            (new_state / "pi" / "skill-config" / "secrets.toml").read_text(),
            "secret",
        )
        self.assertEqual(
            (new_state / "pi" / "notifications" / "history.json").read_text(),
            "[]",
        )

        # sediment: legacy wins, today's data preserved as backup sibling.
        self.assertEqual(
            (new_state / "pi" / "sediment" / "data" / "history.lance").read_text(),
            "memory",
        )
        self.assertEqual(
            (new_state / "pi" / "sediment.post-rename" / "access.db").read_text(),
            "today-access",
        )

        # sediment-cache: take_over_if_empty (new absent).
        self.assertEqual(
            (new_state / "pi" / "sediment-cache" / "blob").read_text(), "cache"
        )

        # signal: take_over_if_empty (new absent in this test).
        self.assertEqual(
            (new_state / "signal" / "messages.db").read_text(),
            "sqlite-bytes-here",
        )

        # Tidy: empty legacy roots are gone.
        self.assertFalse(legacy_state.exists())
        self.assertFalse(legacy_share.exists())

    def test_pre_rename_access_db_at_pi_parent_is_carried_into_sediment(self) -> None:
        # An older sediment layout placed access.db at the pi/
        # parent rather than inside sediment/. The migration must
        # carry that file into the new sediment dir so the legacy
        # rows retain their access tracking — otherwise we'd orphan
        # a 36 KiB sqlite that nothing else can clean up.
        home = self.root
        legacy_state = home / ".local" / "state" / "distro"
        new_state = home / ".local" / "state" / "spaces"
        (legacy_state / "pi").mkdir(parents=True)
        (legacy_state / "pi" / "access.db").write_text("legacy-access")
        # No sediment dir in legacy or new — exercises the
        # parent.mkdir(parents=True) branch.

        migrate.run(home)

        self.assertEqual(
            (new_state / "pi" / "sediment" / "access.db").read_text(),
            "legacy-access",
        )
        self.assertFalse((legacy_state / "pi" / "access.db").exists())
        self.assertFalse(legacy_state.exists())

    def test_pre_rename_access_db_dropped_when_new_already_has_one(self) -> None:
        # If today's sediment has already written its own access.db,
        # the legacy one is stale and must be discarded so the dir
        # collapses cleanly.
        home = self.root
        legacy_state = home / ".local" / "state" / "distro"
        new_state = home / ".local" / "state" / "spaces"
        (legacy_state / "pi").mkdir(parents=True)
        (legacy_state / "pi" / "access.db").write_text("legacy-access")
        (new_state / "pi" / "sediment").mkdir(parents=True)
        (new_state / "pi" / "sediment" / "access.db").write_text("today-access")

        migrate.run(home)

        self.assertEqual(
            (new_state / "pi" / "sediment" / "access.db").read_text(),
            "today-access",
        )
        self.assertFalse(legacy_state.exists())

    def test_rerun_is_a_noop(self) -> None:
        home = self.root
        new_state = home / ".local" / "state" / "spaces"
        (new_state / "pi").mkdir(parents=True)
        self._touch(
            new_state / "pi" / "sessions.json",
            json.dumps({"version": 1, "activeSessionId": None, "sessions": []}),
        )
        migrate.run(home)
        idx = json.loads((new_state / "pi" / "sessions.json").read_text())
        self.assertEqual(idx["sessions"], [])


if __name__ == "__main__":
    unittest.main()

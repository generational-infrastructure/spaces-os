"""Leaf-aware migration helpers for the 'distro' → 'spaces' rename.

Each helper is a pure function over (legacy_path, new_path) so the
behaviour can be unit-tested in a tempdir without touching the real
$HOME. ``run()`` composes them against the actual layout the pi-chat
+ signal-cli modules write to.

Migration strategy by leaf:

* ``sessions.json`` — JSON merge keyed on session id. New file wins
  on field collisions (it has more recent ``lastActiveAt`` / name
  edits made after the rename); ``activeSessionId`` is taken from the
  new file so the user stays in the chat they're currently in. Output
  is sorted newest-first.

* ``sessions/`` and ``workspaces/`` — UNION at the immediate-child
  level. Each session is a directory with a globally-unique id; if
  ``new/sessions/<id>`` exists, leave it alone (today's data wins);
  otherwise move ``legacy/sessions/<id>`` across.

* ``skill-config/``, ``notifications/``, ``sediment-cache/``, the
  per-subsystem signal store — "take over if empty". tmpfiles creates
  these as empty dirs, so any case where the user actually wrote
  something post-rename is rare and the conservative rule is "don't
  touch a non-empty new dir".

* ``sediment/`` — neither side can be merged cleanly (LanceDB
  manifests strict-chain) and the user's long-term memory is more
  valuable than a freshly-rebuilt access.db. Swap legacy in, rename
  the today version to ``sediment.post-rename`` so any recent writes
  remain recoverable by hand.

* ``pi-agent/`` and ``skills-defs/`` — pure /nix/store symlink
  payloads, idempotently re-created by tmpfiles every login. No data
  to migrate.
"""

from __future__ import annotations

import json
import logging
import os
import shutil
from pathlib import Path

log = logging.getLogger("spaces_state_migrate")

# Leaves that the pi-chat module manages with /nix/store symlinks
# only. No user data lives there so we skip them entirely.
_NIX_MANAGED_LEAVES = ("pi/pi-agent", "pi/skills-defs")


# ── sessions.json ───────────────────────────────────────────────────


def merge_sessions_index(legacy: Path, new: Path) -> bool:
    """JSON-merge the two pi-chat session indices. Returns True iff a
    write occurred.

    Identity is the session ``id`` (ULID-shaped, unique). On collision
    the new entry wins — by the time the migration runs the user has
    already opened pi-chat post-rename and any field they updated
    (name, model, lastActiveAt) is the newest truth for that session.
    ``activeSessionId`` follows the same rule, falling back to legacy
    only when the new file has no active session.

    Every entry's ``workspacePath`` is rewritten from the pre-rename
    distro/ location to the spaces/ equivalent so pi-chat doesn't try
    to cd into a dangling path when the user opens an old chat. Paths
    that don't match the rename prefix pass through untouched.
    """
    if not legacy.is_file():
        return False
    try:
        legacy_data = json.loads(legacy.read_text())
    except (json.JSONDecodeError, OSError) as exc:
        log.warning("legacy sessions index unreadable (%s); skipping", exc)
        return False
    if not isinstance(legacy_data.get("sessions"), list):
        log.warning("legacy sessions index malformed; skipping")
        return False

    new_data: dict = {}
    if new.is_file():
        try:
            parsed = json.loads(new.read_text())
            if isinstance(parsed, dict):
                new_data = parsed
        except (json.JSONDecodeError, OSError):
            new_data = {}
    if not isinstance(new_data.get("sessions"), list):
        new_data["sessions"] = []

    by_id: dict[str, dict] = {
        s["id"]: s
        for s in legacy_data["sessions"]
        if isinstance(s, dict) and isinstance(s.get("id"), str)
    }
    for s in new_data["sessions"]:
        if isinstance(s, dict) and isinstance(s.get("id"), str):
            by_id[s["id"]] = s
    for entry in by_id.values():
        _rewrite_workspace_path(entry)

    merged = sorted(
        by_id.values(),
        key=lambda s: int(s.get("lastActiveAt") or 0),
        reverse=True,
    )

    new_active = new_data.get("activeSessionId")
    legacy_active = legacy_data.get("activeSessionId")
    active = new_active if new_active else legacy_active

    output = {
        "version": new_data.get("version") or legacy_data.get("version") or 1,
        "activeSessionId": active,
        "sessions": merged,
    }
    new.parent.mkdir(parents=True, exist_ok=True)
    # Atomic write: serialise to a sibling tmp then os.replace so an
    # interrupted run never leaves a half-written index.
    tmp = new.with_name(new.name + ".migrate-tmp")
    tmp.write_text(json.dumps(output, indent=4) + "\n")
    os.replace(tmp, new)
    legacy.unlink()
    return True


# ── union-by-name directory merge ───────────────────────────────────


def union_subdirs(legacy_root: Path, new_root: Path) -> int:
    """For each immediate child of ``legacy_root`` whose name is not
    already present under ``new_root``, move it across. Returns the
    number of entries actually moved.

    Per-name union (not deep merge): each session/workspace is a
    self-contained subtree and the in-place version is always correct
    on its own, so we never recurse into a collision.

    On collision the legacy entry is the stale pre-rename copy and the
    new entry is current truth — we delete the legacy entry rather
    than leave it dangling in $HOME. The two leaves we drive this
    against (sessions/, workspaces/) both use globally-unique ids, so
    a collision genuinely means "same session, two histories" with the
    new one being the active one.
    """
    if not legacy_root.is_dir():
        return 0
    new_root.mkdir(parents=True, exist_ok=True)
    moved = 0
    for entry in list(legacy_root.iterdir()):
        target = new_root / entry.name
        if target.exists():
            # Stale collision — discard so the legacy root can be
            # collapsed at the end and a re-run is obviously a no-op.
            _remove_path(entry)
            continue
        # shutil.move handles files, dirs, and symlinks uniformly and
        # falls back to copy+remove across filesystems.
        shutil.move(str(entry), str(target))
        moved += 1
    _rmdir_if_empty(legacy_root)
    return moved


# ── take-over-if-empty (skill-config / notifications / cache) ───────


def take_over_if_empty(legacy: Path, new: Path) -> bool:
    """Move ``legacy`` over ``new`` iff ``new`` is missing or an empty
    directory. Returns True on action.

    Used for leaves where tmpfiles only ever creates an empty
    placeholder dir and the bridge / chat plugin doesn't write into
    it until first-use. A non-empty new dir means the user did write
    something post-rename — refuse rather than risk clobbering.
    """
    if not legacy.exists():
        return False
    if new.exists():
        try:
            has_children = any(True for _ in new.iterdir())
        except (NotADirectoryError, OSError):
            return False
        if has_children:
            return False
        new.rmdir()
    new.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(legacy), str(new))
    return True


# ── sediment: swap-with-backup ──────────────────────────────────────


def swap_with_backup(legacy: Path, new: Path, *, suffix: str = ".post-rename") -> bool:
    """Move ``legacy`` into ``new``'s spot, renaming any existing
    ``new`` to ``<new>{suffix}`` so post-rename writes remain
    recoverable. Returns True iff a move occurred.

    For sediment: LanceDB manifests strict-chain so we cannot merge
    two independent stores. Legacy wins because the user's long-term
    memory dwarfs anything they could have written today, and the
    backup sibling keeps today's writes around for manual recovery.
    """
    if not legacy.exists():
        return False
    backup = new.with_name(new.name + suffix)
    if new.exists():
        # If a previous run already created the backup, refuse to
        # overwrite it — the user may have inspected/extracted it. The
        # legacy dir is the indicator that the migration hasn't run
        # yet, so we only ever reach this branch on a first attempt.
        if backup.exists():
            log.warning("backup path %s already exists; aborting swap", backup)
            return False
        os.replace(new, backup)
    new.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(legacy), str(new))
    return True


# ── helpers ─────────────────────────────────────────────────────────


# Rename boundary: any absolute path containing one of these segments
# was written by a pre-rename pi-chat and needs to point at the new
# spaces/ layout for the existing data to be reachable post-migration.
_PATH_REWRITES = (
    ("/.local/state/distro/", "/.local/state/spaces/"),
    ("/.local/share/distro/", "/.local/share/spaces/"),
)


def _rewrite_workspace_path(session: dict) -> None:
    """Patch ``session['workspacePath']`` in place when it points at
    the pre-rename location. Non-string / non-matching values are left
    alone so a session with an exotic cwd (a custom workspacePath the
    user set themselves) doesn't get mangled.
    """
    wsp = session.get("workspacePath")
    if not isinstance(wsp, str):
        return
    for old, new in _PATH_REWRITES:
        if old in wsp:
            session["workspacePath"] = wsp.replace(old, new, 1)
            return


def rewrite_workspace_paths(index_path: Path) -> bool:
    """Self-healing pass: rewrite any ``workspacePath`` in
    ``index_path`` that still references the pre-rename distro/
    location. Returns True iff at least one entry changed.

    Runs unconditionally — covers both the "legacy was merged in by
    this run" path and the "user already had a half-migrated index
    from a prior bridge-only fix" path. Idempotent: an index with no
    matching paths is a no-op no-write.
    """
    if not index_path.is_file():
        return False
    try:
        data = json.loads(index_path.read_text())
    except (json.JSONDecodeError, OSError):
        return False
    sessions = data.get("sessions")
    if not isinstance(sessions, list):
        return False
    changed = False
    for entry in sessions:
        if not isinstance(entry, dict):
            continue
        before = entry.get("workspacePath")
        _rewrite_workspace_path(entry)
        if entry.get("workspacePath") != before:
            changed = True
    if not changed:
        return False
    tmp = index_path.with_name(index_path.name + ".migrate-tmp")
    tmp.write_text(json.dumps(data, indent=4) + "\n")
    os.replace(tmp, index_path)
    return True


def _rmdir_if_empty(p: Path) -> None:
    try:
        p.rmdir()
    except OSError:
        pass


def _remove_path(p: Path) -> None:
    """Delete a file, symlink, or directory tree. Errors are swallowed
    — the migration treats removal failures as non-fatal so a
    leftover that can't be cleaned still leaves the new state intact.
    """
    try:
        if p.is_symlink() or p.is_file():
            p.unlink()
        elif p.is_dir():
            shutil.rmtree(p)
    except OSError as exc:
        log.warning("could not remove stale path %s: %s", p, exc)


# ── top-level driver ────────────────────────────────────────────────


def run(home: Path) -> None:
    """Run every leaf migration against the standard layout.

    Idempotent: on a host with no legacy state the function makes no
    filesystem changes. Each helper guards its own no-op on missing
    inputs so the driver only has to wire them up.
    """
    legacy_state = home / ".local" / "state" / "distro"
    new_state = home / ".local" / "state" / "spaces"
    legacy_share = home / ".local" / "share" / "distro"
    new_share = home / ".local" / "share" / "spaces"

    # 1. JSON-merge the session index before touching the per-session
    # dirs — the index references session IDs that the union step
    # below moves into place, and a half-applied run is least
    # surprising when the index is consistent with the dirs.
    merge_sessions_index(
        legacy_state / "pi" / "sessions.json",
        new_state / "pi" / "sessions.json",
    )
    # Self-healing repair pass: an earlier run (e.g. a manual signal-
    # only fix that left pi alone) may already have a sessions.json
    # carrying broken workspacePaths; rewrite them whether or not the
    # merge above fired.
    rewrite_workspace_paths(new_state / "pi" / "sessions.json")

    # 2. UNION per-session dirs + per-session workspace dirs.
    union_subdirs(legacy_state / "pi" / "sessions", new_state / "pi" / "sessions")
    union_subdirs(legacy_share / "workspaces", new_share / "workspaces")

    # 3. Take-over-if-empty for the leaves that tmpfiles materialises
    # as empty dirs and that the user only writes to on first-use.
    for rel in (
        "pi/skill-config",
        "pi/notifications",
        "pi/sediment-cache",
        "signal",
    ):
        take_over_if_empty(legacy_state / rel, new_state / rel)

    # 4. Sediment gets the swap-with-backup treatment so neither
    # snapshot is lost.
    swap_with_backup(legacy_state / "pi" / "sediment", new_state / "pi" / "sediment")

    # 5. /nix/store-symlink-only leaves — explicitly skip.
    for rel in _NIX_MANAGED_LEAVES:
        legacy_leaf = legacy_state / rel
        if legacy_leaf.exists():
            # Unlink each symlink first so rmdir below can collect the
            # empty parent. Plain files/dirs are left as-is; we don't
            # know what's in them.
            for entry in list(legacy_leaf.iterdir()):
                if entry.is_symlink():
                    entry.unlink()
            _rmdir_if_empty(legacy_leaf)

    # 6. Tidy: collapse empty legacy roots so a re-run is obviously a
    # no-op and the empty shell doesn't linger forever in $HOME.
    # Pre-rename quirk: an older sediment layout placed access.db at
    # the ``pi/`` parent (alongside ``pi/sediment/``) rather than
    # inside it. The current sediment expects access.db as a sibling
    # of the ``data/`` subdir; carry the legacy file across so the
    # legacy memory rows still track access correctly. Skip when the
    # new sediment already has its own access.db — sediment regenerates
    # tracking on first write, so a conflict means today's wins.
    legacy_access = legacy_state / "pi" / "access.db"
    new_access = new_state / "pi" / "sediment" / "access.db"
    if legacy_access.is_file():
        if new_access.exists():
            legacy_access.unlink()
        else:
            new_access.parent.mkdir(parents=True, exist_ok=True)
            os.replace(legacy_access, new_access)

    _rmdir_if_empty(legacy_state / "pi")
    _rmdir_if_empty(legacy_state)
    _rmdir_if_empty(legacy_share)


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )
    home = Path(os.environ.get("HOME") or os.path.expanduser("~"))
    log.info("migrating user state under %s", home)
    run(home)
    log.info("migration complete")


if __name__ == "__main__":
    main()

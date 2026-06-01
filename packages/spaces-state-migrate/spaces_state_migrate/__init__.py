"""One-shot migration for the 2026-05 'distro' → 'spaces' rename.

The rename moved every persistent on-disk path from
``~/.local/state/distro/`` / ``~/.local/share/distro/`` to the
``spaces`` equivalents but did **not** carry existing data across. A
user who linked Signal, ran chats, or accumulated memory before the
rename ended up looking at empty new directories with their actual
state orphaned under ``distro/``.

This package owns the recovery: a small Python entry point invoked by
a user systemd oneshot (``spaces-state-migrate.service``) at login,
ordered before any subsystem that opens a state file. The migration
is leaf-aware (different per-directory rules — UNION merges for
session/workspace dirs, JSON-merge for ``sessions.json``,
take-over-if-empty for skill-config/notifications/etc., and a
swap-with-backup for sediment so existing post-rename writes aren't
lost) and idempotent, so re-running it on a clean host is a no-op.
"""

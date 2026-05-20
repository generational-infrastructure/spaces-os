---
name: Desktop notifications
description: Read recent desktop notifications captured by the noctalia shell.
---

The user's notification history is exposed by the `notifications` CLI. The
underlying data is noctalia's persistent history file — every notification
the desktop has received is in there, capped at the 100 most recent entries
and ordered newest-first.

Use this skill whenever the user asks anything about *what they missed*,
*what just popped up*, *who messaged them*, or any other question that maps
onto recent desktop activity.

### List recent notifications

```bash
notifications list
```

Default text format, newest first. One block per entry, three lines:

```
2026-05-20T17:42:30Z  Ferdium  normal  id=bb35b94f
  flokli (Pradille Geek Week 2026)
  @hsngrmpf:matrix.org: meet at the station
```

Fields: ISO-8601 UTC timestamp · originating app · urgency
(`low` / `normal` / `critical`) · short id. Use the id with `notifications get`
when you need the full body or other fields.

### Filter

```bash
notifications list --limit 5
notifications list --app Slack          # case-insensitive exact match
notifications list --since 1779200000000   # unix ms; drops anything older
notifications list --urgency critical   # low | normal | critical (or 0/1/2)
```

Combine flags as needed; filters compose left-to-right.

### Machine-readable output

```bash
notifications list --json --limit 10
```

Emits the raw entries as a JSON array. Each entry includes every field
noctalia persisted (`actionsJson`, `cachedImage`, `originalId`, etc.), so
parse this when you need anything beyond app / summary / body / urgency.

### Look up one entry

```bash
notifications get <id>
```

`<id>` may be a prefix — eight hex characters is plenty since the ring is
capped at 100 entries. Add `--json` for the full raw record. Exit code is
non-zero (and stderr explains why) when no entry matches or the prefix is
ambiguous.

### Tips

- The data is captured passively by the desktop shell — the user did not have
  to opt in per notification. Treat the contents as private; never quote them
  unprompted in unrelated answers.
- Timestamps are stored in milliseconds since the Unix epoch. Combine with
  the datetime skill (`date -u +%s%3N` etc.) for "since this morning",
  "in the last hour", and similar windows.
- Urgency `2` (critical) is what apps reserve for things you really should
  read — battery, security alerts, missed calls. Surface those first when
  summarising.
- The file may not exist yet on a fresh install. `notifications list` returns
  `(no notifications)` rather than failing, so it is safe to call without a
  preflight check.

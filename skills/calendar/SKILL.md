---
name: Calendar
description: View, add, edit and delete events on CalDAV calendars (Nextcloud, Radicale, Fastmail, iCloud, etc.) via the caldav wrapper.
config:
  url: |
    **Full CalDAV collection URL** — the address of one specific
    calendar, *not* the server root.

    - **Nextcloud** — `https://cloud.example.com/remote.php/dav/calendars/USER/CALENDAR/`
    - **iCloud** — supply the per-calendar URL shown by your client.
  user: CalDAV username
secrets:
  password: |
    CalDAV password.

    Use an **app-specific password** for iCloud or any account with
    two-factor authentication enabled.
---

Manage CalDAV calendar events using the `caldav` wrapper, which handles
auth, URL composition, headers, and ETag concurrency for you.

## Picking a profile

The user may have one calendar profile or many. Profile names are chosen
by the user during onboarding and usually reflect what each calendar is
for. Don't assume any particular naming scheme.

At the start of any operation, list what's configured:

```bash
skill-config list calendar
```

Then:

- **One profile configured** → use it.
- **Multiple profiles, single-event operation** (add / edit / delete /
  fetch one) → infer the most likely profile from the user's request
  and the profile names. If ambiguous, ask which one.
- **Multiple profiles, schedule overview or conflict check** → query
  **every** profile and merge the results. Prefix each event with its
  profile name in brackets so the user can tell them apart, e.g.
  `[<profile>] 14:00 Dentist`.
- **No profiles configured** (or the user references one that isn't set
  up) → hand off to the `skill-config` skill to onboard it before
  proceeding.

## Always check for conflicts before adding or moving events

Before creating or rescheduling any event, query the relevant date range
across **all** configured profiles. Surface anything that overlaps the
proposed window so the user can confirm.

---

### List events in a date range

Dates are in `YYYYMMDDTHHMMSSZ` (UTC).

```bash
caldav list <profile> 20260509T000000Z 20260516T235959Z
```

Repeat per profile when listing across all calendars. The response is
the raw multi-status XML from the CalDAV server. Each event is one
`<d:response>` block containing:

- a `<d:href>` element — the event's **CalDAV resource path**, and
- a `<c:calendar-data>` element — the iCalendar body (parse this for
  titles, times, descriptions, locations, and the `UID:` property).

---

### Resource names vs. UIDs (important)

`get`, `etag`, `delete`, and edits (`put` with an ETag) address an
event by its **CalDAV resource**, not by the iCalendar `UID:` property.
These are *not* the same string:

- The **resource name** is the last path segment of `<d:href>`, e.g.
  `BE11B01C-2D5F-4A1C-9E0A-1234567890AB.ics`.
- The **UID** is the `UID:` line inside `<c:calendar-data>`, e.g.
  `7db7874e-...`.

CalDAV decouples the two on purpose. Servers like Nextcloud/SabreDAV
assign a *random* resource name, so for any event created via the
Nextcloud web UI, a phone, or another client the resource name has
nothing to do with the UID. (Events this skill creates happen to use
the UID as the resource name — see "Add an event" — but never rely on
that for events you didn't create.)

`get`/`etag`/`delete`/edit accept **either** form:

- Pass the **UID** and the wrapper resolves it to the right resource
  with a `calendar-query` REPORT before issuing the request.
- Or pass the **resource name** directly (slightly faster, and the only
  option if a UID matches zero or multiple resources).

**Extracting the resource name from `list` output.** Find the
`<d:href>` for the event and take the segment after the last `/`:

```
<d:response>
  <d:href>/remote.php/dav/calendars/alice/personal/BE11B01C-2D5F-4A1C-9E0A-1234567890AB.ics</d:href>
  ...
  <c:calendar-data>BEGIN:VCALENDAR...UID:7db7874e-...END:VCALENDAR</c:calendar-data>
</d:response>
```

→ resource name = `BE11B01C-2D5F-4A1C-9E0A-1234567890AB.ics`
(here the UID is the unrelated `7db7874e-...`).

If a UID resolves to more than one resource the wrapper refuses to
guess and prints the candidates — pass the exact resource name in that
case.

---

### Get a single event

```bash
# By UID (auto-resolved):
caldav get <profile> 7db7874e-...
# Or by resource name from <d:href>:
caldav get <profile> BE11B01C-2D5F-4A1C-9E0A-1234567890AB.ics
```

Returns the raw `.ics` body for that event.

---

### Add an event

Generate a fresh UUID for the event, pipe the iCalendar body via heredoc:

```bash
EVENT_UID="$(cat /proc/sys/kernel/random/uuid)"
caldav put <profile> "$EVENT_UID" <<EOF
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Crow//Calendar Skill//EN
BEGIN:VEVENT
UID:${EVENT_UID}
DTSTART:20260217T090000Z
DTEND:20260217T100000Z
SUMMARY:Team Meeting
DESCRIPTION:Weekly sync
LOCATION:Office
CLASS:PRIVATE
STATUS:CONFIRMED
END:VEVENT
END:VCALENDAR
EOF
```

**Date formats:**
- All-day event: `DTSTART;VALUE=DATE:20260217` and `DTEND;VALUE=DATE:20260218`
- Timed (UTC): `DTSTART:20260217T090000Z` / `DTEND:20260217T100000Z`
- With timezone: `DTSTART;TZID=Europe/Berlin:20260217T100000` / `DTEND;TZID=Europe/Berlin:20260217T110000`

---

### Edit an event

Two-step: fetch the current ETag, then `put` with that ETag to prevent
overwriting concurrent changes. Address the event by the same
identifier for both calls — a UID (auto-resolved) or the resource name
from `<d:href>` (see "Resource names vs. UIDs"). Keep the event's own
`UID:` property unchanged in the body.

```bash
EVENT="<uid-or-resource>"   # e.g. a UID, or BE11B01C-....ics
ETAG="$(caldav etag <profile> "$EVENT")"
caldav put <profile> "$EVENT" "$ETAG" <<EOF
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Crow//Calendar Skill//EN
BEGIN:VEVENT
UID:<unchanged-event-uid>
DTSTART:20260217T140000Z
DTEND:20260217T150000Z
SUMMARY:Updated Meeting Title
DESCRIPTION:Changed description
LOCATION:Room 2
CLASS:PRIVATE
STATUS:CONFIRMED
END:VEVENT
END:VCALENDAR
EOF
```

If `caldav put` returns HTTP 412, the event was modified between the
`etag` fetch and the `put` — re-fetch and try again.

---

### Delete an event

```bash
# By UID (auto-resolved) or by resource name from <d:href>:
caldav delete <profile> <uid-or-resource>
```

Returns 204 No Content on success.

---

### Defaults

- **Always set `CLASS:PRIVATE`** on new events. No downside on personal
  calendars; only restricts visibility on shared ones, which is the safe
  default.

### Tips

- Always `list` first before editing or deleting — the response gives
  you both each event's `<d:href>` (resource name) and its `UID:`. You
  can pass either to `get`/`etag`/`put`/`delete`, but prefer the
  resource name when a UID might be ambiguous (see "Resource names vs.
  UIDs").
- For schedule overviews and conflict checks, query **every** configured
  profile and merge the results.
- Generate a fresh UUID for the UID on every new event. Don't reuse.
- Use `TZID=Europe/Berlin` (or the user's timezone) for local times,
  rather than UTC, when the user specifies times without a timezone.
- When presenting events from multiple profiles, prefix each with its
  profile name in brackets so the user can see at a glance which
  calendar an event belongs to.

---

### Escape hatch — raw CalDAV via curl

For unusual queries that `caldav` doesn't expose (e.g. filtering by
attendee, free/busy lookups, calendar-collection metadata), fall back to
raw `curl`. Pull credentials with `skill-config get`:

```bash
URL=$(skill-config get calendar.<profile>.url)
USER=$(skill-config get calendar.<profile>.user)

curl -s -u "$USER:$(skill-config get calendar.<profile>.password)" \
  -X REPORT \
  -H "Content-Type: application/xml; charset=utf-8" \
  -H "Depth: 1" \
  --data-binary @- "$URL" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  ... custom filter here ...
</c:calendar-query>
XML
```

---
name: Calendar
description: View, add, edit and delete events on CalDAV calendars (Nextcloud, Radicale, Fastmail, iCloud, etc.) via the caldav wrapper.
config:
  url: Full CalDAV collection URL — the address of one specific calendar, not the server root. Example for Nextcloud — https://cloud.example.com/remote.php/dav/calendars/USER/CALENDAR/. iCloud users — supply the per-calendar URL shown by your client.
  user: CalDAV username
secrets:
  password: CalDAV password (use an app-specific password for iCloud / two-factor accounts)
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
the raw multi-status XML from the CalDAV server with each event's
iCalendar data inside `<c:calendar-data>` elements — parse those to
extract titles, times, descriptions, locations, UIDs.

---

### Get a single event

```bash
caldav get <profile> <event-uid>
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
overwriting concurrent changes. Keep the same UID.

```bash
ETAG="$(caldav etag <profile> <event-uid>)"
caldav put <profile> <event-uid> "$ETAG" <<EOF
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Crow//Calendar Skill//EN
BEGIN:VEVENT
UID:<event-uid>
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
caldav delete <profile> <event-uid>
```

Returns 204 No Content on success.

---

### Defaults

- **Always set `CLASS:PRIVATE`** on new events. No downside on personal
  calendars; only restricts visibility on shared ones, which is the safe
  default.

### Tips

- Always `list` first to find UIDs before editing or deleting — the
  response includes the UID for every event.
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

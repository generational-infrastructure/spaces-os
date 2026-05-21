---
name: Google
description: Read, search, and send Gmail messages and view, add, edit, or delete Google Calendar events via the `google-cli` wrapper.
config:
  client_id: |
    Google OAuth **client ID** for the user's Cloud project (looks like
    `123-abc.apps.googleusercontent.com`). Created once per user in the
    Google Cloud Console — see "First-time setup" below for the exact
    steps to walk them through.
secrets:
  client_secret: |
    OAuth **client secret** paired with `client_id`. Shown alongside
    the client ID in the Google Cloud Console.
  refresh_token: |
    OAuth refresh token. **Do not ask the user to paste this** — it is
    written automatically by `google-cli auth <profile>`, which runs
    the standard Google consent flow.
---

Manage Gmail and Google Calendar through the `google-cli` wrapper, which
handles OAuth client credential loading, refresh-token rotation, and
output formatting.

The same skill covers both products on purpose: Gmail and Calendar share
one OAuth consent surface, so a profile maps to one Google account and
gives access to both inboxes and calendars in that account.

## Picking a profile

The user may have one Google account or many (personal, work, …). Profile
names are chosen during onboarding and usually reflect what each account
is for. Don't assume any particular naming scheme.

At the start of any operation, list what's configured:

```bash
skill-config list google
```

Then:

- **One profile configured** → use it.
- **Multiple profiles, single operation** (one search, one send,
  one event) → infer the most likely profile from the user's request
  and the profile names. If ambiguous, ask which one.
- **Multiple profiles, "what's in my inbox / on my schedule"** → query
  **every** profile and merge the results. Prefix each line with its
  profile name in brackets so the user can tell them apart, e.g.
  `[work] 14:00 1:1 with Manager`.
- **No profile configured** → run the first-time setup flow below.

---

## First-time setup

Google does not let third-party software ship a pre-baked OAuth client
that can read mail or calendar data for arbitrary users — every user
needs their own Cloud project. The flow is one-time and takes a few
minutes. Walk the user through it explicitly, in this order:

### 1 — Have the user create an OAuth client

Tell them, in chat:

> 1. Open <https://console.cloud.google.com/projectcreate> and create
>    a new project (any name).
> 2. Enable the **Gmail API** and **Google Calendar API** at
>    <https://console.cloud.google.com/apis/library> — search for each
>    and click "Enable".
> 3. Open <https://console.cloud.google.com/apis/credentials/consent>
>    and configure the consent screen as **External**, user type
>    **Testing**. Add their own Google address as a test user.
> 4. Open <https://console.cloud.google.com/apis/credentials>, click
>    **Create credentials → OAuth client ID**, choose **Desktop app**,
>    and copy the **Client ID** and **Client secret** they're shown.

Wait for the user to confirm they have the two values. **Do not ask
them to paste the values into chat** — the next step collects them via
popups so they never touch the LLM.

### 2 — Collect client_id and client_secret via skill-config

Pick a profile name (`default` is fine for a single account; otherwise
`personal`, `work`, …). For each of the two fields, in order:

```bash
skill-config request-input google.<profile>.client_id
skill-config request-input google.<profile>.client_secret
```

The first popup is for a non-secret value; the second masks the input.
Handle the exit codes the same way the skill-config skill documents
(0 = submitted, 1 = dismissed, 2 = timeout, 3 = daemon unreachable).

### 3 — Run the OAuth consent flow

Once both credentials are stored, run:

```bash
google-cli auth <profile>
```

This:

1. Picks a free loopback port and starts a local HTTP server on it.
2. **Prints a Google consent URL to stdout.** Show the URL to the user
   verbatim — tell them to open it in their browser, sign in with the
   matching Google account, and approve the requested scopes.
3. Waits up to 5 minutes for Google's redirect to hit the loopback
   listener, exchanges the authorization code for a refresh token, and
   stores it as `google.<profile>.refresh_token` automatically.

On success the CLI prints `saved google.<profile>.refresh_token`.

Failure modes:

- `authorization denied by Google: <reason>` — the user clicked "Cancel"
  in the consent screen. Offer to retry.
- `timed out waiting for the OAuth callback` — the user did not finish
  the consent flow within the timeout. Offer to retry.
- `Google returned no refresh_token …` — happens when a previous
  consent for the same Cloud project is still active and Google skips
  the offline-access prompt. Have the user revoke pi-chat at
  <https://myaccount.google.com/permissions> and retry.

### 4 — Confirm

```bash
skill-config list google.<profile>
```

The three fields should appear; secrets render as `[set]`. The profile
is ready for use.

---

## Gmail

All commands take the profile as the first positional. `--json` switches
output from human-readable text blocks to the raw Gmail API JSON; reach
for it when you need fields beyond `from / to / date / subject /
snippet` (labels, threadId, raw headers, …).

### List recent messages

```bash
google-cli mail list <profile> [-q "QUERY"] [-n LIMIT] [--json]
```

`-q` accepts any Gmail search expression: `is:unread`,
`from:alice@example.com`, `newer_than:1d`, `label:INBOX`, etc. Combine
them with spaces.

### Read a single message

```bash
google-cli mail get <profile> <message-id> [--json]
```

The text view prints headers + snippet + the best plain-text body
(falling back to HTML if no plain-text part exists).

### Send a message

```bash
google-cli mail send <profile> \
  --to alice@example.com \
  [--cc bob@example.com] [--bcc dave@example.com] \
  --subject "Subject" \
  --body "Body text"
```

For longer or templated bodies, use `--body-file PATH` (or `--body-file -`
to read from stdin via a here-doc). The CLI builds an RFC 2822 envelope
and base64url-encodes it for Gmail's send endpoint.

---

## Calendar

### List calendars on the account

```bash
google-cli calendar calendars <profile> [--json]
```

Use this when the user mentions a calendar by name and you need its ID
for `--calendar`. The user's main calendar always has the ID `primary`.

### List events

```bash
google-cli calendar list <profile> \
  [--calendar CALENDAR_ID] \
  [--from RFC3339] [--to RFC3339] \
  [-q "FREE TEXT"] [-n LIMIT] [--json]
```

Default calendar is `primary`. `--from` / `--to` are RFC 3339 timestamps
(`2026-05-21T00:00:00Z`); without them the API returns events from now
forward.

For schedule overviews across multiple Google profiles **and** any
configured CalDAV calendars, query each one separately and merge the
results, labelling each event with its profile name in brackets.

### Read a single event

```bash
google-cli calendar get <profile> <event-id> [--calendar CALENDAR_ID] [--json]
```

### Add an event

```bash
google-cli calendar add <profile> \
  [--calendar CALENDAR_ID] \
  --summary "Title" \
  --start RFC3339 --end RFC3339 \
  [--all-day] \
  [--location "Office"] \
  [--description "Notes"] \
  [--attendee a@b.com [--attendee c@d.com]]
```

For all-day events pass `--all-day` and use `YYYY-MM-DD` for `--start`
and `--end` (the end date is **exclusive**, the same convention as the
Calendar API). Repeat `--attendee` for multiple invitees.

Before creating any event, **check for conflicts** by listing events in
the proposed window across every configured profile (Google + CalDAV) —
the user expects pi to flag overlaps automatically.

### Delete an event

```bash
google-cli calendar delete <profile> <event-id> [--calendar CALENDAR_ID]
```

---

## Notes

- The refresh token is the only thing persisted between runs; access
  tokens are minted on every CLI invocation. If the user revokes access
  in <https://myaccount.google.com/permissions>, every subsequent
  command will fail with a token-refresh error — re-run
  `google-cli auth <profile>` to mint a new one.
- The OAuth scopes granted are `gmail.modify` (read + send + label) and
  `calendar` (read + write events and calendars). Both are the minimum
  Google offers that still cover the operations exposed here.
- If a profile is missing fields, the CLI exits with a message naming
  the missing key(s) and the exact command to fix them — prefer running
  that command over guessing.

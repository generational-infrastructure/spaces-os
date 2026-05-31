---
name: Contacts
description: Look up, create, edit and delete contacts on CardDAV address books (Nextcloud, Radicale, Baïkal, Fastmail, SOGo, etc.) via the contacts wrapper.
config:
  server: |
    **CardDAV server** — either a **bare domain** (e.g. `example.com`,
    which triggers RFC 6764 auto-discovery) or a **full endpoint URL**.

    - **Nextcloud** — `cloud.example.com`, or the full
      `https://cloud.example.com/remote.php/dav/`
    - **Radicale / Baïkal / SOGo** — the DAV endpoint URL your client uses.
  user: CardDAV username
secrets:
  password: |
    CardDAV password.

    Use an **app-specific password** for any account with two-factor
    authentication enabled. (Google Contacts is **not** supported — it
    needs OAuth2, not HTTP Basic auth.)
---

Manage CardDAV contacts using the `contacts` wrapper, which handles auth,
server discovery, and ETag concurrency for you. Every command talks to
the server directly (no local mirror) and prints JSON to stdout.

## Picking a profile

The user may have one contacts profile or many. Profile names are chosen
by the user during onboarding and usually reflect what each address book
is for (e.g. `personal`, `work`). Don't assume any particular scheme.

At the start of any operation, list what's configured:

```bash
skill-config list contacts
```

Then:

- **One profile configured** → use it.
- **Multiple profiles, single-contact operation** (look up / add / edit /
  delete one) → infer the most likely profile from the user's request
  and the profile names. If ambiguous, ask which one.
- **Multiple profiles, "search everywhere" lookup** → query **every**
  profile and merge the results. Prefix each hit with its profile name in
  brackets so the user can tell them apart, e.g. `[work] Ada Lovelace`.
- **No profiles configured** (or the user references one that isn't set
  up) → hand off to the `skill-config` skill to onboard it before
  proceeding.

All commands take the profile as the **first** argument:
`contacts <profile> <command> ...`.

---

### List address books

```bash
contacts <profile> discover
```

Returns the address books on the server (`path`, `name`, `description`).
Useful when the user wants to target a specific book — see *Targeting a
specific address book* below.

---

### Search for contacts

Server-side search. An empty query lists everyone.

```bash
contacts <profile> search ada                      # FN contains "ada"
contacts <profile> search --field EMAIL ada@       # match a different property
contacts <profile> search --match equals "Ada Lovelace"
contacts <profile> search --limit 20 ""            # list (up to 20)
```

Flags: `--field` (default `FN`), `--match`
(`contains`|`equals`|`starts-with`|`ends-with`), `--limit`, `--photos`.

> **Flag ordering:** put flags *before* the query
> (`search --match equals ada`, not `search ada --match equals`).

Each result is a JSON object:

```json
{
  "path":  "/remote.php/dav/addressbooks/users/alice/contacts/UID.vcf",
  "etag":  "\"1a2b3c\"",
  "uid":   "urn:uuid:…",
  "fn":    "Ada Lovelace",
  "vcard": "BEGIN:VCARD\r\nVERSION:4.0\r\n…END:VCARD\r\n"
}
```

The `path` is the handle you pass to `get`, `edit`, and `delete`. Parse
the `vcard` field for individual properties (`EMAIL`, `TEL`, `ADR`, …).

Inline photo blobs (base64 `PHOTO`/`LOGO`/`SOUND`, `data:` URIs) are
**stripped by default** so they don't flood your context. Pass `--photos`
only when the user actually wants the image data.

---

### Get a single contact

```bash
contacts <profile> get <path>
```

Returns the one contact (same JSON shape as `search`). `<path>` is the
`path` from a prior `search`.

---

### Add a contact

Pipe a vCard on stdin. `UID` and `VERSION` are filled in automatically if
missing, and the write uses `If-None-Match: *` so it never clobbers an
existing contact.

```bash
contacts <profile> new <<'EOF'
BEGIN:VCARD
VERSION:4.0
FN:Ada Lovelace
N:Lovelace;Ada;;;
EMAIL;TYPE=home:ada@example.com
TEL;TYPE=cell:+1-555-0100
END:VCARD
EOF
```

Returns the created contact's JSON (including its new `path` and `etag`).

---

### Edit a contact

`edit` **replaces** the whole vCard, so start from the current one. The
safe pattern is fetch → modify → write; the current ETag is fetched
automatically and sent as `If-Match`, so a concurrent change elsewhere
makes the write fail instead of silently overwriting.

```bash
# Fetch, change the email, write it back:
contacts <profile> get "$P" | jq -r .vcard \
  | sed 's/ada@example.com/ada.l@example.com/' \
  | contacts <profile> edit "$P"
```

For non-trivial edits, fetch the vCard, edit the text yourself (keep the
same `UID` and `VERSION`), and pipe the full card back into `edit`.

If the write fails on the ETag guard, the contact changed in the
meantime — re-`get` and retry. Use `--force` to overwrite unconditionally
only when the user explicitly wants that.

---

### Delete a contact

Same `If-Match` guard as `edit` (`--force` to skip it).

```bash
contacts <profile> delete <path>
```

Returns `{"path": …, "status": "deleted"}`.

---

### Back up an address book

Exports every contact as one `.vcf` per file into a directory (a vdir,
the layout khard/vdirsyncer use), re-encoded to canonical form so it
diffs cleanly under git.

```bash
contacts <profile> backup --out ./contacts-backup
```

---

### Targeting a specific address book

If a profile's server has several address books, the wrapper uses the
first one discovered unless a book is pinned. To pin one, find its path
with `discover`, then store it (one-time):

```bash
contacts <profile> discover            # copy the desired book's "path"
skill-config set contacts.<profile>.book "<path>"
```

After that, every `contacts <profile> …` call operates on that book.

### Tips

- Always `search`/`get` first to obtain a contact's `path` before editing
  or deleting — there's no lookup-by-name for writes.
- Pair the JSON output with `jq` to pull out fields
  (`… | jq -r '.[].fn'`).
- Keep `UID` and `VERSION` intact when editing, or the write will create
  a divergent card.
- When presenting hits from multiple profiles, prefix each with its
  profile name in brackets so the user can see which book it came from.

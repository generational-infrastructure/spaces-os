# contacts-cli

A small, **server-agnostic** CardDAV command-line client. It talks to any
standards-compliant CardDAV server (Nextcloud, Radicale, Baïkal, Fastmail,
SOGo, …) **directly over HTTP** — no local mirror, no sync step — and emits
JSON, so it is easy to drive from scripts and agents.

- RFC 6764 discovery (well-known URI / DNS SRV) when given a bare domain.
- Server-side search via the CardDAV `addressbook-query` `REPORT`.
- Safe writes using conditional requests (`If-Match` / `If-None-Match`).
- HTTP Basic / app-password auth, with the password fetched from a command
  (e.g. [`passage`](https://github.com/FiloSottile/passage)) so it never has to
  be stored in plaintext.

Built on [`emersion/go-webdav`](https://github.com/emersion/go-webdav) and
[`emersion/go-vcard`](https://github.com/emersion/go-vcard).

## Build

```sh
go build -o contacts .
```

## Configuration

Settings are merged from three sources, **flags > environment > config file**:

| Setting       | Flag             | Env                     | Config key    |
|---------------|------------------|-------------------------|---------------|
| Server        | `--server`       | `CONTACTS_SERVER`       | `server`      |
| Username      | `--username`     | `CONTACTS_USERNAME`     | `username`    |
| Password      | `--password`     | `CONTACTS_PASSWORD`     | `password`    |
| Password cmd  | `--password-cmd` | `CONTACTS_PASSWORD_CMD` | `passwordCmd` |
| Address book  | `--book`         | `CONTACTS_ADDRESSBOOK`  | `addressbook` |
| Include photos| `--photos`       | `CONTACTS_INCLUDE_PHOTOS` | `includePhotos` |

`server` may be a **bare domain** (`example.com`, triggers RFC 6764 discovery)
or a **full endpoint URL** (`https://dav.example.com/remote.php/dav/`).

`passwordCmd` is run through `sh -c`; its trimmed stdout is used as the
password. It is only consulted when no literal password is set.

Config file location: `$XDG_CONFIG_HOME/contacts-cli/config.json` (falls back to
`~/.config/contacts-cli/config.json`); override with `CONTACTS_CONFIG`. See
[`config.example.json`](config.example.json).

```json
{
  "server": "dav.example.com",
  "username": "alice",
  "passwordCmd": "passage show carddav/example"
}
```

If `addressbook` is left empty, the first address book found via discovery is
used. Set it to a concrete path to skip the discovery round-trips on every call.

## Commands

All commands print JSON to stdout. Contacts are represented as:

```json
{
  "path":  "/remote.php/dav/addressbooks/users/alice/contacts/UID.vcf",
  "etag":  "\"1a2b3c\"",
  "uid":   "urn:uuid:…",
  "fn":    "Ada Lovelace",
  "vcard": "BEGIN:VCARD\r\nVERSION:4.0\r\n…END:VCARD\r\n"
}
```

> **Flag ordering:** put flags *before* positional arguments
> (`search --match equals ada`, not `search ada --match equals`). This is
> Go's standard `flag` behaviour — parsing stops at the first positional.

### discover — list address books

```sh
contacts discover
```

### search — server-side search (empty query lists all)

```sh
contacts search ada                       # FN contains "ada"
contacts search --field EMAIL ada@        # match a different property
contacts search --match equals "Ada Lovelace"
contacts search --limit 20 ""             # list (up to 20)
```

Flags: `--field` (default `FN`), `--match` (`contains`|`equals`|`starts-with`|`ends-with`), `--limit`, `--photos`.

By default, inline-encoded media (base64 `PHOTO`/`LOGO`/`SOUND`, or `data:`
URIs) is **stripped** from `search` and `get` output, so a contact's photo blob
doesn't flood an agent's context window. Small URL/URI photo references are
kept. Pass `--photos` (or set `includePhotos: true` / `CONTACTS_INCLUDE_PHOTOS=1`)
to include them; `--photos=false` forces stripping for a single call. The
`backup` command always keeps photos for full fidelity, regardless of this
setting.

### get — fetch one contact

```sh
contacts get /remote.php/dav/addressbooks/users/alice/contacts/UID.vcf
```

### new — create from a vCard on stdin

A `UID` and `VERSION` are added automatically if missing; the new resource path
is derived from the UID. Uses `If-None-Match: *` so it never clobbers an
existing contact.

```sh
cat <<'EOF' | contacts new
BEGIN:VCARD
VERSION:4.0
FN:Ada Lovelace
EMAIL:ada@example.com
END:VCARD
EOF
```

### edit — replace a contact from stdin

By default the current `ETag` is fetched and sent as `If-Match`, so a
concurrent change elsewhere makes the write fail instead of silently clobbering.
Pass `--etag` to supply one yourself, or `--force` to overwrite unconditionally.

```sh
contacts get "$PATH" | jq -r .vcard | sed 's/ada@/ada.l@/' | contacts edit "$PATH"
```

### delete — remove a contact

Same `If-Match` guard as `edit` (`--etag` / `--force`).

```sh
contacts delete "$PATH"
```

### backup — export every contact as a vdir

Writes one `.vcf` file per contact into `--out DIR`, named after the contact's
resource (`<UID>.vcf`) — the same layout khard/vdirsyncer use. Contacts are
downloaded with a single CardDAV `REPORT` (via the go-webdav client) and
re-encoded to **canonical, deterministically-ordered** vCards, so the directory
diffs cleanly when tracked in git: an unchanged contact serialises identically
across runs, and a real edit produces a minimal diff.

```sh
contacts backup --out ./contacts-backup
cd ./contacts-backup && git add -A && git commit -m "contacts snapshot"
```

Output is a JSON summary (`{format, book, dir, count, files}`). Re-encoding
preserves all vCard data (including `X-*` properties, groups, and params) and
only normalises ordering/line-folding; the exact serialisation is tied to the
go-vcard encoder version. Backs up the resolved address book — set `--book` (or
run once per book) to cover others.

## Notes

- Pairs well with `jq` for extracting fields from the JSON output.
- For Google Contacts you would need OAuth2; this client only does HTTP Basic /
  app-password auth, which covers self-hosted servers and most providers.

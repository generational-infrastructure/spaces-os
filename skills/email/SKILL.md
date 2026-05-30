---
name: Email
description: Read, search, send and manage email over IMAP/SMTP via the mail wrapper around himalaya.
config:
  email: |
    **Email address** for this account, e.g. `you@example.com`. Used as
    the From address and, unless overridden, as the IMAP and SMTP login.
  imap_host: |
    **IMAP server hostname** for receiving mail, e.g.
    `imap.example.com` (Gmail: `imap.gmail.com`, Fastmail:
    `imap.fastmail.com`).
  smtp_host: |
    **SMTP server hostname** for sending mail, e.g.
    `smtp.example.com` (Gmail: `smtp.gmail.com`, Fastmail:
    `smtp.fastmail.com`).
  imap_port: |
    IMAP port. Optional — defaults to `993` (implicit TLS).
  smtp_port: |
    SMTP port. Optional — defaults to `587` (STARTTLS). Use `465` for
    implicit TLS.
  imap_login: |
    IMAP username, if it differs from the email address. Optional —
    defaults to `email`.
  smtp_login: |
    SMTP username, if it differs from the email address. Optional —
    defaults to `email`.
  display_name: |
    Display name shown on outgoing mail, e.g. `Jane Doe`. Optional.
  imap_encryption: |
    IMAP encryption: `tls`, `start-tls`, or `none`. Optional —
    inferred from the port (993/465 → tls, 587/143 → start-tls).
  smtp_encryption: |
    SMTP encryption: `tls`, `start-tls`, or `none`. Optional —
    inferred from the port.
secrets:
  password: |
    Account password, used for both IMAP and SMTP.

    Use an **app-specific password** for Gmail, iCloud, or any account
    with two-factor authentication enabled.
---

Manage email over IMAP/SMTP using the `mail` wrapper, which builds a
fresh himalaya config from your stored account settings on every call
and passes your arguments straight through to `himalaya`. Passwords are
fetched at send/fetch time and never written to disk.

## Picking a profile

The user may have one email profile or many (e.g. `personal`, `work`).
Profile names are chosen by the user during onboarding. Don't assume any
particular naming scheme.

At the start of any operation, list what's configured:

```bash
skill-config list email
```

Then:

- **One profile configured** → use it. It is himalaya's default
  account, so `-a` is optional.
- **Multiple profiles, single operation** (read / send / search one
  account) → infer the most likely profile from the user's request and
  the profile names, and pass it with `-a <profile>`. If ambiguous, ask
  which one.
- **Multiple profiles, "check all my mail"** → run the command once per
  profile and merge the results. Prefix each message with its profile
  name in brackets so the user can tell them apart, e.g.
  `[work] 14:00 Re: Budget`.
- **No profiles configured** (or the user references one that isn't set
  up) → hand off to the `skill-config` skill to onboard it before
  proceeding.

Every command below accepts `-a <profile>` to choose the account.

---

### List / search envelopes

```bash
mail envelope list -a <profile>
```

Filter and sort with a query (see `mail envelope list --help`):

```bash
mail envelope list -a <profile> "from alice and after 2026-05-01 order by date desc"
mail envelope list -a <profile> "subject invoice"
mail envelope list -a <profile> "flag unseen"
```

The first column is the **envelope id** used by `message read`, `flag`,
and `attachment download`. For machine parsing, add `-o json`:

```bash
mail -o json envelope list -a <profile>
```

---

### Read a message

```bash
mail message read <id> -a <profile>
```

Reading marks the message **seen**. To peek without changing the flag:

```bash
mail message read <id> -a <profile> --preview
```

`-f <folder>` reads from a folder other than `INBOX`.

---

### Send a message

`message send` takes a raw RFC822 message (headers + body) on stdin:

```bash
mail message send -a <profile> <<'EOF'
From: you@example.com
To: alice@example.com
Subject: Lunch?

Are you free Thursday at noon?
EOF
```

Set `From:` to the profile's own address. Add `Cc:`/`Bcc:` headers as
needed. A copy is saved to the Sent folder automatically.

To reply, fetch the original's `Message-ID` first and include
`In-Reply-To:` and `References:` headers so the reply threads correctly.

---

### Flags

```bash
mail flag add <id> seen -a <profile>
mail flag remove <id> seen -a <profile>
mail flag set <id> flagged -a <profile>
```

Common flags: `seen`, `flagged`, `answered`, `deleted`, `draft`.

---

### Folders and attachments

```bash
mail folder list -a <profile>
mail envelope list -f Archive -a <profile>
mail attachment download <id> -a <profile>
```

---

### Tips

- Always `envelope list` first to find ids before reading, flagging, or
  downloading — ids are folder-relative.
- Use `-o json` whenever you need to parse output reliably rather than
  scrape the table.
- For "do I have new mail" / overview requests across all accounts,
  query **every** configured profile and merge, prefixing each line with
  `[<profile>]`.
- The wrapper is a pass-through: anything `himalaya` supports works.
  Run `mail <subcommand> --help` to discover options.

---

### Escape hatch — raw himalaya

`mail` simply runs `himalaya` with a generated config, so any himalaya
subcommand is available even if it isn't documented above (templates,
message move/copy/delete, folder purge, account doctor, etc.):

```bash
mail message move <id> Archive -a <profile>
mail message delete <id> -a <profile>
mail account doctor -a <profile>     # diagnose connection/auth
```

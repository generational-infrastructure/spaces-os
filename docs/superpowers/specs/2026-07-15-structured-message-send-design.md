# Structured `message_send` for mail integrations

Date: 2026-07-15
Status: approved

## Problem

`message_send` in both `integration-mail` and `integration-proton` takes a
single `message` string: a raw RFC822 message the agent must compose itself
(headers, folding, RFC 2047 encoding for non-ASCII subjects, MIME headers).
That pushes RFC knowledge onto the agent and invites malformed mail (typo'd
From addresses, missing MIME headers, unencoded UTF-8 subjects).

## Decision

Replace the raw `message` argument with structured fields. The server
composes the RFC822 message with Python's stdlib `email.message.EmailMessage`
(`policy.SMTP`). Clean cutover: the raw `message` argument is removed, no
dual path.

## Schema

Both integrations expose the same `message_send` input schema:

- `to` — array of strings, required, at least one entry
- `cc` — array of strings, optional
- `bcc` — array of strings, optional
- `subject` — string, required
- `body` — string, required; plain text UTF-8 (HTML/attachments out of scope)
- `profile` — unchanged (injected by the scaffold)

`From` is NOT a field: it is derived from the profile's sealed-store `email`
value, so the agent can never mistype the sender.

## Composition

In `spaces_himalaya_core.make_tool_impls.message_send`:

1. Validate: `to` non-empty array of strings, `cc`/`bcc` arrays of strings
   when present, `subject`/`body` non-empty strings. Failures return
   `(error_text, True)` before the precheck probe, matching the existing
   arg-validation style.
2. Build `EmailMessage` with `policy.SMTP`: `From` = `vals["email"]`,
   `To`/`Cc`/`Bcc` joined from arrays, `Subject`, `set_content(body)`.
   EmailMessage owns folding, RFC 2047, MIME + CTE headers.
3. Serialize and pipe to `himalaya message send` stdin exactly as before.
   The himalaya/msmtp transport is untouched.

## Blast radius

- `packages/spaces-himalaya-core/spaces_himalaya_core.py` — new impl body.
- `packages/integration-mail/integration_mail.py`,
  `packages/integration-proton/integration_proton.py` — tool schema decls.
- Both packages' test files — send tests reworked to assert composed
  headers/body on the stub's captured stdin.
- Approval flow keys on the tool name (`message_send`), unaffected.

## Testing

Per package (stub himalaya captures stdin):

- happy path: stdin parses as an email with correct From (profile email),
  To/Cc, Subject, and body;
- non-ASCII subject/body round-trips (RFC 2047 / CTE handled);
- Bcc reaches the composed message (himalaya's SMTP send strips it at
  transmission; the header must exist for recipient extraction);
- missing/empty `to`, `subject`, `body` → isError, no himalaya exec.

---
name: Skill Config
description: Onboard or reconfigure other pi-chat skills (URLs, usernames, credentials) by triggering a popup that the user fills in directly — values never travel through chat.
---

When the user wants to set up a skill, change a credential, add a second
profile, or has hit a "is not set" error, drive the flow yourself
instead of asking them to run shell commands.

## Why this skill never asks for credentials in chat

Anything the user types into chat reaches pi's LLM — and from
there, the LLM provider's logs and prompt cache. Passwords, API keys,
and tokens must never go that route. Instead, this skill collects each
field via `skill-config request-input`, which opens a popup on the
user's host. The user types the value into the popup and it goes
**directly** from the host to the on-disk store, bypassing the LLM
entirely.

This applies to non-secret fields too (URLs, usernames). It's not
strictly required for those, but using the popup uniformly keeps the
chat clean and the flow consistent.

## Steps

1. **Find the target.** Run `skill-config list` to see installed skills
   and which already have profiles configured. **Use the skill name
   exactly as it appears in this list** — they are lowercase short
   identifiers like `calendar`, not display names like `Calendar` or
   `AI Chat`. (Lookups are case-insensitive as a fallback, but matching
   verbatim avoids any guesswork.) If the user named a skill, jump to
   step 2. Otherwise, list the candidates and ask which one.

2. **Read its schema.** Run `skill-config schema <skill>`. The output
   is YAML with two optional top-level keys, `config:` and `secrets:`.
   Each is a flat map of `field_name: human description`. If the schema
   is empty (`{}`), the skill needs no setup — tell the user and stop.

3. **Pick a profile.** Run `skill-config list <skill>` to see existing
   profiles. Suggest the profile name `default` for skills that
   typically have a single instance. For skills that may have multiple
   (calendar, mail), ask for a label like `personal` or `work`. If a
   profile already exists, ask whether to edit it or create a new one.

4. **Collect each field, one popup at a time.** For every field in the
   schema (`config:` first, then `secrets:`), run:

   ```bash
   skill-config request-input <skill>.<profile>.<field_name>
   ```

   This blocks until the user submits, dismisses, or the prompt times
   out. Tell the user what the next popup is for in chat (e.g. "I'll
   open a popup for your CalDAV URL — fill it in and submit") so they
   know to look at it.

5. **Handle each exit code:**
   - `0` — submitted (stdout: `saved <skill>.<profile>.<field>`).
     **Immediately call `request-input` for the next field** without
     waiting for the user to say anything. The user already knows the
     popup flow is in motion; pausing for confirmation between fields
     wastes their time.
   - `1` — user dismissed. Stop, acknowledge, ask if they want to try
     again later.
   - `2` — timeout. Ask the user if they want to retry that field.
   - `3` — daemon unreachable. Tell the user the popup service isn't
     running and stop.

6. **Confirm.** When all fields are written, run
   `skill-config list <skill>.<profile>` and show the summary. Secrets
   appear as `[set]` rather than their values, so this is safe to
   include in chat.

## Examples of when to invoke this flow

- "Set up the calendar skill for my Nextcloud account"
- "Add my work email to pi-chat"
- "Change the password on my personal CalDAV" → step 3, edit existing profile
- A skill returned `error: <key> is not set` → propose running this flow
  for the missing field

## Notes

- All `skill-config` commands run inside the user's session against
  the per-user `distro-skill-config-daemon` socket. No `sudo`, no
  `--instance` flag — the environment is already correct.
- Field names in `request-input`, `set`, and `get` are exactly as they
  appear in the schema output.
- If the user wants to start over on a profile,
  `skill-config remove <skill> <profile>` wipes both the config and
  secret entries for that profile.
- The `set` verb still exists for non-secret values you already have in
  hand from chat (e.g. the user said "set the timezone to Europe/Berlin"
  — no popup needed). Use it sparingly; for any field marked as a
  secret in the schema, always use `request-input` instead.

# shellcheck shell=bash
set -euo pipefail

# mail: thin wrapper around `himalaya` that materializes its TOML config
# from skill-config on every invocation, then execs himalaya with the
# remaining arguments. Each `email.<profile>.*` entry in skill-config
# becomes a himalaya `[accounts.<profile>]` block, so the agent drives
# himalaya natively and selects a profile with `-a <profile>`.
#
# Passwords are NEVER written to the config file: himalaya pulls them at
# runtime via `backend.auth.cmd = "skill-config get email.<profile>.password"`.

usage() {
  cat >&2 <<'EOF'
Usage:
  mail <himalaya-args...>            # e.g. mail envelope list -a personal
  mail -a <profile> <himalaya-args>  # select a profile (account)

This is a wrapper around `himalaya`; all arguments are passed straight
through. Run `mail --help` (or `mail <subcommand> --help`) for the full
himalaya CLI. Useful entry points:

  mail envelope list -a <profile>            # list inbox
  mail message read <id> -a <profile>        # read a message
  mail message send -a <profile> < raw.eml   # send a raw RFC822 message
  mail -o json envelope list -a <profile>    # JSON output for parsing

Accounts are read from skill-config keys email.<profile>.*
EOF
  exit 2
}

case "${1:-}" in
-h | --help-wrapper) usage ;;
esac

# Map a port to himalaya's encryption type when the profile doesn't pin
# one explicitly. 993/465 are implicit TLS, 587/143 negotiate STARTTLS,
# 25 is plaintext; anything else defaults to TLS.
enc_for_port() {
  case "$1" in
  993 | 465) echo tls ;;
  587 | 143) echo start-tls ;;
  25) echo none ;;
  *) echo tls ;;
  esac
}

# Required field: let skill-config's own "is not set" error (with its
# onboarding hint) propagate and abort the script.
req() { skill-config get "email.${1}.${2}"; }
# Optional field: empty string when unset, never fails.
opt() { skill-config get "email.${1}.${2}" 2>/dev/null || true; }

# TOML basic-string escaping for the few free-text values (display name).
toml_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# Enumerate configured profiles from `skill-config list email`, which
# prints one "[email.<profile>]" header line per configured profile.
mapfile -t profiles < <(skill-config list email | sed -n 's/^\[email\.\([^]]*\)\]$/\1/p')

if [ "${#profiles[@]}" -eq 0 ]; then
  cat >&2 <<'EOF'
error: no email profiles configured.

Hand off to the skill-config skill to onboard an account, e.g.
  skill-config request-input email.personal.email
EOF
  exit 1
fi

cfg="$(mktemp --tmpdir mail-himalaya-XXXXXX.toml)"
trap 'rm -f "$cfg"' EXIT
chmod 600 "$cfg"

default_set=0
for p in "${profiles[@]}"; do
  email="$(req "$p" email)"
  imap_host="$(req "$p" imap_host)"
  smtp_host="$(req "$p" smtp_host)"

  imap_port="$(opt "$p" imap_port)"
  imap_port="${imap_port:-993}"
  smtp_port="$(opt "$p" smtp_port)"
  smtp_port="${smtp_port:-587}"

  imap_login="$(opt "$p" imap_login)"
  imap_login="${imap_login:-$email}"
  smtp_login="$(opt "$p" smtp_login)"
  smtp_login="${smtp_login:-$email}"

  imap_enc="$(opt "$p" imap_encryption)"
  imap_enc="${imap_enc:-$(enc_for_port "$imap_port")}"
  smtp_enc="$(opt "$p" smtp_encryption)"
  smtp_enc="${smtp_enc:-$(enc_for_port "$smtp_port")}"

  display_name="$(opt "$p" display_name)"

  # First profile becomes himalaya's default account so commands without
  # -a still work for the common single-account case.
  if [ "$default_set" -eq 0 ]; then
    is_default="true"
    default_set=1
  else
    is_default="false"
  fi

  {
    printf '[accounts.%s]\n' "$p"
    printf 'email = "%s"\n' "$email"
    if [ -n "$display_name" ]; then
      printf 'display-name = "%s"\n' "$(toml_escape "$display_name")"
    fi
    printf 'default = %s\n' "$is_default"

    printf 'backend.type = "imap"\n'
    printf 'backend.host = "%s"\n' "$imap_host"
    printf 'backend.port = %s\n' "$imap_port"
    printf 'backend.encryption.type = "%s"\n' "$imap_enc"
    printf 'backend.login = "%s"\n' "$imap_login"
    printf 'backend.auth.type = "password"\n'
    printf 'backend.auth.cmd = "skill-config get email.%s.password"\n' "$p"

    printf 'message.send.backend.type = "smtp"\n'
    printf 'message.send.backend.host = "%s"\n' "$smtp_host"
    printf 'message.send.backend.port = %s\n' "$smtp_port"
    printf 'message.send.backend.encryption.type = "%s"\n' "$smtp_enc"
    printf 'message.send.backend.login = "%s"\n' "$smtp_login"
    printf 'message.send.backend.auth.type = "password"\n'
    printf 'message.send.backend.auth.cmd = "skill-config get email.%s.password"\n' "$p"
    printf '\n'
  } >>"$cfg"
done

exec himalaya -c "$cfg" "$@"

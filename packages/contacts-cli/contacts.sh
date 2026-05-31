# shellcheck shell=bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  contacts <profile> discover                  # list address books
  contacts <profile> search [flags] <query>    # server-side search; empty query lists all
  contacts <profile> get <path>                # fetch one contact by its href/path
  contacts <profile> new                       # create a contact from a vCard on stdin
  contacts <profile> edit [flags] <path>       # replace a contact from a vCard on stdin
  contacts <profile> delete [flags] <path>     # delete a contact
  contacts <profile> backup --out DIR          # export every contact as a vdir

Credentials are read from skill-config:
  contacts.<profile>.server, contacts.<profile>.user,
  contacts.<profile>.password, contacts.<profile>.book (optional)
EOF
  exit 2
}

if [ "$#" -lt 2 ]; then
  usage
fi

profile="$1"
shift

CONTACTS_SERVER="$(skill-config get "contacts.${profile}.server")"
CONTACTS_USERNAME="$(skill-config get "contacts.${profile}.user")"
CONTACTS_PASSWORD="$(skill-config get "contacts.${profile}.password")"
# The address book is optional — when unset, contacts-cli discovers the
# first book on the server.
CONTACTS_ADDRESSBOOK="$(skill-config get "contacts.${profile}.book" 2>/dev/null || true)"
export CONTACTS_SERVER CONTACTS_USERNAME CONTACTS_PASSWORD CONTACTS_ADDRESSBOOK

exec contacts-cli "$@"

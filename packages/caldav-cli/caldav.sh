# shellcheck shell=bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  caldav list <profile> <start> <end>     # dates as YYYYMMDDTHHMMSSZ
  caldav get <profile> <uid>              # fetch one event as ICS
  caldav etag <profile> <uid>             # fetch the current ETag value
  caldav put <profile> <uid> [<etag>]     # ICS body on stdin; etag triggers If-Match
  caldav delete <profile> <uid>           # remove event by UID

Credentials are read from skill-config:
  calendar.<profile>.url, calendar.<profile>.user, calendar.<profile>.password
EOF
  exit 2
}

if [ "$#" -lt 2 ]; then
  usage
fi

cmd="$1"
profile="$2"
shift 2

base="$(skill-config get "calendar.${profile}.url")"
user="$(skill-config get "calendar.${profile}.user")"
pass="$(skill-config get "calendar.${profile}.password")"
base="${base%/}"
auth="${user}:${pass}"

case "$cmd" in
list)
  if [ "$#" -ne 2 ]; then usage; fi
  start="$1"
  end="$2"
  curl -fsS -u "$auth" -X REPORT \
    -H "Content-Type: application/xml; charset=utf-8" \
    -H "Depth: 1" \
    --data-binary @- "$base" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop><d:getetag/><c:calendar-data/></d:prop>
  <c:filter>
    <c:comp-filter name="VCALENDAR">
      <c:comp-filter name="VEVENT">
        <c:time-range start="${start}" end="${end}"/>
      </c:comp-filter>
    </c:comp-filter>
  </c:filter>
</c:calendar-query>
XML
  ;;
get)
  if [ "$#" -ne 1 ]; then usage; fi
  uid="$1"
  curl -fsS -u "$auth" "${base}/${uid}.ics"
  ;;
etag)
  if [ "$#" -ne 1 ]; then usage; fi
  uid="$1"
  curl -fsSI -u "$auth" "${base}/${uid}.ics" |
    sed -n 's/^[Ee][Tt][Aa][Gg]:[[:space:]]*//p' |
    tr -d '\r'
  ;;
put)
  if [ "$#" -lt 1 ]; then usage; fi
  uid="$1"
  etag="${2:-}"
  headers=(-H "Content-Type: text/calendar; charset=utf-8")
  if [ -n "$etag" ]; then
    headers+=(-H "If-Match: ${etag}")
  fi
  curl -fsS -u "$auth" -X PUT "${headers[@]}" \
    --data-binary @- "${base}/${uid}.ics"
  ;;
delete)
  if [ "$#" -ne 1 ]; then usage; fi
  uid="$1"
  curl -fsS -u "$auth" -X DELETE "${base}/${uid}.ics"
  ;;
*)
  usage
  ;;
esac

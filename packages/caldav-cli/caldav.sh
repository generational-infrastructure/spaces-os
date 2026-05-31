# shellcheck shell=bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  caldav list   <profile> <start> <end>          # dates as YYYYMMDDTHHMMSSZ
  caldav get    <profile> <uid|resource>         # fetch one event as ICS
  caldav etag   <profile> <uid|resource>         # fetch the current ETag value
  caldav put    <profile> <uid|resource> [<etag>] # ICS body on stdin; etag triggers If-Match
  caldav delete <profile> <uid|resource>         # remove one event

get / etag / delete and put-with-etag (i.e. edits) accept EITHER:
  - an iCalendar UID — resolved to its CalDAV resource via a
    calendar-query REPORT before the request, or
  - a raw resource name — the ".ics" segment of a <d:href> returned
    by `caldav list`.

A CalDAV resource name is NOT the same as the UID: servers such as
Nextcloud/SabreDAV assign random resource names, so the URL and the
UID property differ for any event not created by this skill.

put WITHOUT an etag creates a NEW event at "<resource>.ics"; pass a
fresh UUID so the resource name matches the event's UID.

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

# Scheme://host[:port] of the collection, for resolving absolute-path hrefs.
origin="$(printf '%s' "$base" | sed -E 's#^(https?://[^/]+).*#\1#')"

# Turn an href (absolute URL, absolute path, or bare resource) into a full URL.
href_to_url() {
  local href="$1"
  case "$href" in
    http://* | https://*) printf '%s' "$href" ;;
    /*) printf '%s%s' "$origin" "$href" ;;
    *) printf '%s/%s' "$base" "$href" ;;
  esac
}

# Resolve a value that may be a UID into the resource URL to operate on.
#
# Ask the server for the resource whose VEVENT UID matches:
#   - exactly one match  -> use its <d:href>
#   - no match           -> treat the value as a resource name and fall
#                           back to "${base}/${value}.ics". This keeps
#                           events created by this skill working, where
#                           the resource name equals the UID, and also
#                           lets callers pass a resource name directly.
#   - more than one match -> bail out rather than guess.
resolve_url() {
  local value="$1"
  local resp hrefs count
  resp="$(curl -fsS -u "$auth" -X REPORT \
    -H "Content-Type: application/xml; charset=utf-8" \
    -H "Depth: 1" \
    --data-binary @- "$base" <<XML 2>/dev/null || true
<?xml version="1.0" encoding="UTF-8"?>
<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop><d:getetag/></d:prop>
  <c:filter>
    <c:comp-filter name="VCALENDAR">
      <c:comp-filter name="VEVENT">
        <c:prop-filter name="UID">
          <c:text-match collation="i;octet">${value}</c:text-match>
        </c:prop-filter>
      </c:comp-filter>
    </c:comp-filter>
  </c:filter>
</c:calendar-query>
XML
  )"
  hrefs="$(printf '%s' "$resp" |
    grep -oiE '<[A-Za-z0-9]*:?href[^>]*>[^<]+</[A-Za-z0-9]*:?href>' |
    sed -E 's#<[^>]+>##g' |
    grep -i '\.ics' || true)"
  count="$(printf '%s\n' "$hrefs" | grep -c . || true)"
  if [ "$count" -eq 1 ]; then
    href_to_url "$hrefs"
  elif [ "$count" -eq 0 ]; then
    printf '%s/%s.ics' "$base" "$value"
  else
    {
      echo "caldav: UID '${value}' matched ${count} resources:"
      printf '  %s\n' "$hrefs"
      echo "Pass the exact resource name (the .ics segment of the <d:href> from \`caldav list\`) instead."
    } >&2
    exit 1
  fi
}

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
  url="$(resolve_url "$1")"
  curl -fsS -u "$auth" "$url"
  ;;
etag)
  if [ "$#" -ne 1 ]; then usage; fi
  url="$(resolve_url "$1")"
  curl -fsSI -u "$auth" "$url" |
    sed -n 's/^[Ee][Tt][Aa][Gg]:[[:space:]]*//p' |
    tr -d '\r'
  ;;
put)
  if [ "$#" -lt 1 ]; then usage; fi
  value="$1"
  etag="${2:-}"
  headers=(-H "Content-Type: text/calendar; charset=utf-8")
  if [ -n "$etag" ]; then
    # Editing an existing event: resolve UID -> resource and guard with If-Match.
    headers+=(-H "If-Match: ${etag}")
    url="$(resolve_url "$value")"
  else
    # Creating a new event: the value becomes the resource name (== UID).
    url="${base}/${value}.ics"
  fi
  curl -fsS -u "$auth" -X PUT "${headers[@]}" \
    --data-binary @- "$url"
  ;;
delete)
  if [ "$#" -ne 1 ]; then usage; fi
  url="$(resolve_url "$1")"
  curl -fsS -u "$auth" -X DELETE "$url"
  ;;
*)
  usage
  ;;
esac

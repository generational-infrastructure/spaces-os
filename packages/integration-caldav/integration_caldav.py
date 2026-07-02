"""CalDAV MCP integration server (spaces integration POC).

Speaks NDJSON JSON-RPC 2.0 over a unix socket via the shared
spaces_integration_mcp scaffold. Re-implements the legacy caldav.sh skill in
Python (urllib + HTTP Basic auth): calendar-query REPORTs, UID->resource
resolution, and GET/PUT/DELETE against a CalDAV collection. Multi-profile: every
tool takes an optional "profile"; credentials come from the store's per-profile
config (url, user) and secrets (password) blobs.
"""

import base64
import hashlib
import re
import sys
import urllib.error
import urllib.request

from spaces_integration_mcp import resolve_profile, run, store_profile

SERVER_NAME = "integration-caldav"
SERVER_VERSION = "0.1.0"

_PROFILE_PROP = {
    "profile": {
        "type": "string",
        "description": "account profile (default: the only one)",
    }
}

TOOLS = [
    {
        "name": "list",
        "description": (
            "List events in a time range via a calendar-query REPORT; returns the "
            "raw multistatus body (with calendar-data)"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                **_PROFILE_PROP,
                "start": {
                    "type": "string",
                    "description": "range start (YYYYMMDDTHHMMSSZ)",
                },
                "end": {
                    "type": "string",
                    "description": "range end (YYYYMMDDTHHMMSSZ)",
                },
            },
            "required": ["start", "end"],
        },
    },
    {
        "name": "get",
        "description": "Fetch one event as ICS by iCalendar UID or CalDAV resource name",
        "inputSchema": {
            "type": "object",
            "properties": {
                **_PROFILE_PROP,
                "id": {
                    "type": "string",
                    "description": "iCalendar UID or resource name",
                },
            },
            "required": ["id"],
        },
    },
    {
        "name": "etag",
        "description": "Fetch the current ETag value for one event (UID or resource name)",
        "inputSchema": {
            "type": "object",
            "properties": {
                **_PROFILE_PROP,
                "id": {
                    "type": "string",
                    "description": "iCalendar UID or resource name",
                },
            },
            "required": ["id"],
        },
    },
    {
        "name": "put",
        "description": (
            "Create or update an event. Without an etag, PUTs a new resource at "
            "<base>/<id>.ics; with an etag, resolves the UID and guards with If-Match"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                **_PROFILE_PROP,
                "id": {
                    "type": "string",
                    "description": "UID (new event) or UID/resource (edit)",
                },
                "ics": {"type": "string", "description": "the iCalendar body to store"},
                "etag": {
                    "type": "string",
                    "description": "If-Match guard for an edit (optional)",
                },
            },
            "required": ["id", "ics"],
        },
    },
    {
        "name": "delete",
        "description": "Delete one event by iCalendar UID or CalDAV resource name",
        "inputSchema": {
            "type": "object",
            "properties": {
                **_PROFILE_PROP,
                "id": {
                    "type": "string",
                    "description": "iCalendar UID or resource name",
                },
            },
            "required": ["id"],
        },
    },
]

# <d:href>...</d:href> text, tolerant of any namespace prefix (mirrors caldav.sh).
_HREF_RE = re.compile(
    r"<[A-Za-z0-9]*:?href[^>]*>([^<]+)</[A-Za-z0-9]*:?href>", re.IGNORECASE
)


def _resolve_xml(value):
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">\n'
        "  <d:prop><d:getetag/></d:prop>\n"
        "  <c:filter>\n"
        '    <c:comp-filter name="VCALENDAR">\n'
        '      <c:comp-filter name="VEVENT">\n'
        '        <c:prop-filter name="UID">\n'
        f'          <c:text-match collation="i;octet">{value}</c:text-match>\n'
        "        </c:prop-filter>\n"
        "      </c:comp-filter>\n"
        "    </c:comp-filter>\n"
        "  </c:filter>\n"
        "</c:calendar-query>\n"
    )


def _list_xml(start, end):
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">\n'
        "  <d:prop><d:getetag/><c:calendar-data/></d:prop>\n"
        "  <c:filter>\n"
        '    <c:comp-filter name="VCALENDAR">\n'
        '      <c:comp-filter name="VEVENT">\n'
        f'        <c:time-range start="{start}" end="{end}"/>\n'
        "      </c:comp-filter>\n"
        "    </c:comp-filter>\n"
        "  </c:filter>\n"
        "</c:calendar-query>\n"
    )


def _profile_ctx(profile):
    """Resolve one profile's required fields into a request context.

    Returns (ctx, None) or (None, error-text). A missing required field is a
    tool error, never a crash."""
    vals = store_profile(profile)
    for field in ("url", "user", "password"):
        if not vals.get(field):
            return None, f"field '{field}' not set for profile '{profile}'"
    base = vals["url"].rstrip("/")
    m = re.match(r"^(https?://[^/]+)", base)
    origin = m.group(1) if m else base
    userpass = f"{vals['user']}:{vals['password']}"
    auth = "Basic " + base64.b64encode(userpass.encode("utf-8")).decode("ascii")
    return {
        "base": base,
        "origin": origin,
        "auth": auth,
        "password": vals["password"],
    }, None


def _http(ctx, url, method, body=None, headers=None):
    """Run one urllib request; return (result-dict, None) or (None, error-text)."""
    hdrs = {"Authorization": ctx["auth"]}
    if headers:
        hdrs.update(headers)
    data = body.encode("utf-8") if isinstance(body, str) else body
    req = urllib.request.Request(url, data=data, method=method, headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return {
                "status": resp.status,
                "body": resp.read(),
                "headers": resp.headers,
            }, None
    except urllib.error.HTTPError as e:
        return None, f"CalDAV error: HTTP {e.code} for {method} {url}"
    except (urllib.error.URLError, OSError, ValueError) as e:
        return None, f"CalDAV request failed: {e.__class__.__name__}: {e}"


def _href_to_url(ctx, href):
    """Turn an href (absolute URL, absolute path, or bare resource) into a full URL."""
    if href.startswith("http://") or href.startswith("https://"):
        return href
    if href.startswith("/"):
        return ctx["origin"] + href
    return f"{ctx['base']}/{href}"


def _extract_ics_hrefs(text):
    return [m.group(1) for m in _HREF_RE.finditer(text) if ".ics" in m.group(1).lower()]


def _resolve_url(ctx, value):
    """Resolve a value that may be a UID into the resource URL to operate on.

    Ports caldav.sh resolve_url: exactly one UID match uses its href; no match
    falls back to <base>/<value>.ics; multiple matches is an error. A failing
    REPORT is swallowed (like the shell's `|| true`) and falls back."""
    resp, err = _http(
        ctx,
        ctx["base"],
        "REPORT",
        body=_resolve_xml(value),
        headers={"Content-Type": "application/xml; charset=utf-8", "Depth": "1"},
    )
    hrefs = [] if err else _extract_ics_hrefs(resp["body"].decode("utf-8", "replace"))
    if len(hrefs) == 1:
        return _href_to_url(ctx, hrefs[0]), None
    if len(hrefs) == 0:
        return f"{ctx['base']}/{value}.ics", None
    return None, (
        f"UID '{value}' matched {len(hrefs)} resources: {', '.join(hrefs)}. "
        "Pass the exact resource name (the .ics segment of a <d:href> from 'list') instead."
    )


def _tool_list(args, ctx):
    resp, err = _http(
        ctx,
        ctx["base"],
        "REPORT",
        body=_list_xml(args.get("start", ""), args.get("end", "")),
        headers={"Content-Type": "application/xml; charset=utf-8", "Depth": "1"},
    )
    if err:
        return err, True
    return resp["body"].decode("utf-8", "replace"), False


def _tool_get(args, ctx):
    url, err = _resolve_url(ctx, args.get("id", ""))
    if err:
        return err, True
    resp, err = _http(ctx, url, "GET")
    if err:
        return err, True
    return resp["body"].decode("utf-8", "replace"), False


def _tool_etag(args, ctx):
    url, err = _resolve_url(ctx, args.get("id", ""))
    if err:
        return err, True
    resp, err = _http(ctx, url, "HEAD")
    if err:
        return err, True
    return (resp["headers"].get("ETag", "") or "").strip(), False


def _tool_put(args, ctx):
    value = args.get("id", "")
    etag = args.get("etag")
    headers = {"Content-Type": "text/calendar; charset=utf-8"}
    if etag:
        headers["If-Match"] = etag
        url, err = _resolve_url(ctx, value)
        if err:
            return err, True
    else:
        url = f"{ctx['base']}/{value}.ics"
    resp, err = _http(ctx, url, "PUT", body=args.get("ics", ""), headers=headers)
    if err:
        return err, True
    return f"stored event at {url}", False


def _tool_delete(args, ctx):
    url, err = _resolve_url(ctx, args.get("id", ""))
    if err:
        return err, True
    resp, err = _http(ctx, url, "DELETE")
    if err:
        return err, True
    return f"deleted event at {url}", False


def _tool_secret_fingerprint(args, ctx):
    return hashlib.sha256(ctx["password"].encode("utf-8")).hexdigest()[:16], False


_TOOL_IMPLS = {
    "list": _tool_list,
    "get": _tool_get,
    "etag": _tool_etag,
    "put": _tool_put,
    "delete": _tool_delete,
    "secret_fingerprint": _tool_secret_fingerprint,
}


def call_tool(name, arguments):
    """Dispatch a tools/call: pick the target profile, load its credentials, run
    the impl, return (text, is_error). Never raises."""
    impl = _TOOL_IMPLS.get(name)
    if impl is None:
        return f"unknown tool: {name}", True
    profile, err = resolve_profile(arguments)
    if err:
        return err, True
    ctx, err = _profile_ctx(profile)
    if err:
        return err, True
    return impl(arguments, ctx)


def main():
    return run(SERVER_NAME, SERVER_VERSION, TOOLS, call_tool)


if __name__ == "__main__":
    sys.exit(main())

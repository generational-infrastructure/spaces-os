"""Contacts (CardDAV) MCP integration server (spaces integration POC).

Speaks NDJSON JSON-RPC 2.0 over a unix socket via the shared
spaces_integration_mcp scaffold. Re-implements the core CardDAV surface of the
legacy contacts-cli (packages/contacts-cli) directly over urllib with HTTP Basic
auth. The `server` config value is the addressbook collection URL itself, so no
principal / home-set discovery is needed. Every tool is multi-profile: the
target account is resolved from arguments["profile"] (or the sole profile).
"""

import base64
import hashlib
import json
import os
import re
import sys
import uuid
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from urllib.parse import quote, urljoin, urlsplit
from xml.sax.saxutils import escape as _xml_escape

from spaces_integration_mcp import resolve_profile, run, store_profile

SERVER_NAME = "integration-contacts"
SERVER_VERSION = "0.1.0"

_PROFILE_PROP = {
    "profile": {
        "type": "string",
        "description": "account profile (default: the only one)",
    },
}


def _schema(properties, required):
    props = dict(properties)
    props.update(_PROFILE_PROP)
    return {"type": "object", "properties": props, "required": required}


TOOLS = [
    {
        "name": "discover",
        "description": "List the vCard hrefs in the addressbook collection (PROPFIND Depth:1)",
        "inputSchema": _schema({}, []),
    },
    {
        "name": "search",
        "description": (
            "Server-side addressbook-query REPORT matching FN/EMAIL; "
            "an empty query returns every contact"
        ),
        "inputSchema": _schema(
            {"query": {"type": "string", "description": "text to match (empty = all)"}},
            [],
        ),
    },
    {
        "name": "get",
        "description": "Fetch one contact's vCard by its href/path",
        "inputSchema": _schema(
            {"path": {"type": "string", "description": "contact href, path, or resource name"}},
            ["path"],
        ),
    },
    {
        "name": "new",
        "description": "Create a contact from a vCard (PUT); the resource name is derived from its UID",
        "inputSchema": _schema(
            {"vcard": {"type": "string", "description": "the vCard body to store"}},
            ["vcard"],
        ),
    },
    {
        "name": "edit",
        "description": "Replace an existing contact's vCard (PUT), optionally guarded by an If-Match ETag",
        "inputSchema": _schema(
            {
                "path": {"type": "string", "description": "contact href, path, or resource name"},
                "vcard": {"type": "string", "description": "the replacement vCard body"},
                "etag": {"type": "string", "description": "ETag guard sent as If-Match (optional)"},
            },
            ["path", "vcard"],
        ),
    },
    {
        "name": "delete",
        "description": "Delete a contact by its href/path",
        "inputSchema": _schema(
            {"path": {"type": "string", "description": "contact href, path, or resource name"}},
            ["path"],
        ),
    },
]


def _collection(vals):
    """The addressbook collection URL: `server` directly, or `server` with the
    optional `book` path resolved against it when configured."""
    server = (vals.get("server") or "").strip()
    book = (vals.get("book") or "").strip()
    if book:
        base = server if server.endswith("/") else server + "/"
        return urljoin(base, book)
    return server


def _resolve_path(path, collection):
    """Turn an argument path into an absolute URL: an absolute href is used as
    is, an absolute path joins to the collection's scheme://host, and a bare
    resource name joins to the collection."""
    if re.match(r"^https?://", path, re.IGNORECASE):
        return path
    parts = urlsplit(collection)
    origin = f"{parts.scheme}://{parts.netloc}"
    if path.startswith("/"):
        return origin + path
    return collection.rstrip("/") + "/" + path


def _http(method, url, user, password, body=None, extra_headers=None):
    """Run an authenticated urllib request. Returns
    (status, headers-dict, raw-bytes, None) or (None-ish, {}, b"", error-text).
    2xx (including 207 Multi-Status) is success; anything else is an error."""
    token = base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")
    headers = {"Authorization": f"Basic {token}"}
    if extra_headers:
        headers.update(extra_headers)
    data = body.encode("utf-8") if isinstance(body, str) else body
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.getcode(), dict(resp.headers), resp.read(), None
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers or {}), e.read() or b"", (
            f"CardDAV error: HTTP {e.code} for {method} {url}"
        )
    except (urllib.error.URLError, OSError) as e:
        return None, {}, b"", f"CardDAV request failed: {e.__class__.__name__}: {e}"


_XML_HEADERS = {"Depth": "1", "Content-Type": "application/xml; charset=utf-8"}

_PROPFIND_BODY = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<d:propfind xmlns:d="DAV:">\n'
    "  <d:prop><d:getcontenttype/><d:getetag/><d:resourcetype/></d:prop>\n"
    "</d:propfind>"
)


def _vcard_hrefs(raw):
    """The hrefs from a PROPFIND multistatus that name vCard resources (by
    content type text/vcard or a .vcf suffix)."""
    root = ET.fromstring(raw)
    out = []
    for resp in root.iter("{DAV:}response"):
        href_el = resp.find("{DAV:}href")
        if href_el is None or not href_el.text:
            continue
        href = href_el.text.strip()
        ctype = ""
        for ct in resp.iter("{DAV:}getcontenttype"):
            if ct.text:
                ctype = ct.text
        if "vcard" in ctype.lower() or href.lower().endswith(".vcf"):
            out.append(href)
    return out


def _search_body(query):
    lines = [
        '<?xml version="1.0" encoding="utf-8" ?>',
        '<c:addressbook-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:carddav">',
        "  <d:prop><d:getetag/><c:address-data/></d:prop>",
    ]
    if query:
        esc = _xml_escape(query)
        lines.append('  <c:filter test="anyof">')
        for field in ("FN", "EMAIL"):
            lines.append(f'    <c:prop-filter name="{field}">')
            lines.append(
                '      <c:text-match collation="i;unicode-casemap" '
                f'match-type="contains">{esc}</c:text-match>'
            )
            lines.append("    </c:prop-filter>")
        lines.append("  </c:filter>")
    lines.append("</c:addressbook-query>")
    return "\n".join(lines)


def _vcard_uid(vcard):
    """The UID value from a vCard body, or "" when absent."""
    m = re.search(r"(?im)^UID(?:;[^:]*)?:(.*)$", vcard)
    return m.group(1).strip() if m else ""


def _tool_discover(args, vals):
    collection = _collection(vals)
    _, _, raw, err = _http(
        "PROPFIND", collection, vals["user"], vals["password"],
        body=_PROPFIND_BODY, extra_headers=_XML_HEADERS,
    )
    if err:
        return err, True
    try:
        hrefs = _vcard_hrefs(raw)
    except ET.ParseError as e:
        return f"failed to parse PROPFIND response: {e}", True
    return json.dumps(hrefs), False


def _tool_search(args, vals):
    collection = _collection(vals)
    query = (args.get("query") or "").strip()
    _, _, raw, err = _http(
        "REPORT", collection, vals["user"], vals["password"],
        body=_search_body(query), extra_headers=_XML_HEADERS,
    )
    if err:
        return err, True
    return raw.decode("utf-8", "replace"), False


def _tool_get(args, vals):
    path = args.get("path")
    if not path:
        return "missing required argument: path", True
    url = _resolve_path(path, _collection(vals))
    _, _, raw, err = _http("GET", url, vals["user"], vals["password"])
    if err:
        return err, True
    return raw.decode("utf-8", "replace"), False


def _tool_new(args, vals):
    vcard = args.get("vcard")
    if not vcard:
        return "missing required argument: vcard", True
    collection = _collection(vals)
    name = (_vcard_uid(vcard) or str(uuid.uuid4())) + ".vcf"
    url = collection.rstrip("/") + "/" + quote(name, safe="")
    _, _, _, err = _http(
        "PUT", url, vals["user"], vals["password"], body=vcard,
        extra_headers={"Content-Type": "text/vcard; charset=utf-8", "If-None-Match": "*"},
    )
    if err:
        return err, True
    return url, False


def _tool_edit(args, vals):
    path = args.get("path")
    vcard = args.get("vcard")
    if not path:
        return "missing required argument: path", True
    if not vcard:
        return "missing required argument: vcard", True
    url = _resolve_path(path, _collection(vals))
    headers = {"Content-Type": "text/vcard; charset=utf-8"}
    etag = args.get("etag")
    if etag:
        headers["If-Match"] = etag
    _, resp_headers, _, err = _http(
        "PUT", url, vals["user"], vals["password"], body=vcard, extra_headers=headers,
    )
    if err:
        return err, True
    return json.dumps({"path": url, "etag": resp_headers.get("ETag", "")}), False


def _tool_delete(args, vals):
    path = args.get("path")
    if not path:
        return "missing required argument: path", True
    url = _resolve_path(path, _collection(vals))
    _, _, _, err = _http("DELETE", url, vals["user"], vals["password"])
    if err:
        return err, True
    return f"deleted {url}", False


def _tool_secret_fingerprint(args, vals):
    return hashlib.sha256(vals["password"].encode("utf-8")).hexdigest()[:16], False


_TOOL_IMPLS = {
    "discover": _tool_discover,
    "search": _tool_search,
    "get": _tool_get,
    "new": _tool_new,
    "edit": _tool_edit,
    "delete": _tool_delete,
    "secret_fingerprint": _tool_secret_fingerprint,
}

# Fields each tool needs from the resolved profile store.
_NEEDS = {
    "discover": ("server", "user", "password"),
    "search": ("server", "user", "password"),
    "get": ("server", "user", "password"),
    "new": ("server", "user", "password"),
    "edit": ("server", "user", "password"),
    "delete": ("server", "user", "password"),
    "secret_fingerprint": ("password",),
}


def call_tool(name, arguments):
    """Dispatch a tools/call: resolve the target profile, pull its CardDAV
    credentials from the store, run the impl, return (text, is_error). A missing
    required field is a tool error, never a crash."""
    impl = _TOOL_IMPLS.get(name)
    if impl is None:
        return f"unknown tool: {name}", True
    profile, err = resolve_profile(arguments)
    if err:
        return err, True
    vals = store_profile(profile)
    for field in _NEEDS.get(name, ()):
        if not vals.get(field):
            return f"field '{field}' not set for profile '{profile}'", True
    return impl(arguments, vals)


def main():
    return run(SERVER_NAME, SERVER_VERSION, TOOLS, call_tool)


if __name__ == "__main__":
    sys.exit(main())

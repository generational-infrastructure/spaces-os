"""Contacts (CardDAV) MCP integration server (spaces integration POC).

Speaks NDJSON JSON-RPC 2.0 over a unix socket via the shared
spaces_integration_mcp scaffold, which owns dispatch, profile resolution,
required-field gating, and the hidden secret_fingerprint tool. Re-implements
the core CardDAV surface of the legacy contacts-cli (packages/contacts-cli)
directly over urllib with HTTP Basic auth. The `server` config value is the
addressbook collection URL itself, so no principal / home-set discovery is
needed. Every tool is multi-profile: the target account is resolved from
arguments["profile"] (or the sole profile).
"""

from __future__ import annotations

import base64
import json
import re
import sys
import urllib.error
import urllib.request
import uuid
import xml.etree.ElementTree as ET
from typing import TYPE_CHECKING, Any
from urllib.parse import quote, urljoin, urlsplit
from xml.sax.saxutils import escape as _xml_escape

from spaces_integration_mcp import make_server

if TYPE_CHECKING:
    from collections.abc import Callable

SERVER_NAME = "integration-contacts"
SERVER_VERSION = "0.1.0"


def _collection(vals: dict[str, str]) -> str:
    """The addressbook collection URL: `server` directly, or `server` with the
    optional `book` path resolved against it when configured.
    """
    server = (vals.get("server") or "").strip()
    book = (vals.get("book") or "").strip()
    if book:
        base = server if server.endswith("/") else server + "/"
        return urljoin(base, book)
    return server


def _resolve_path(path: str, collection: str) -> str:
    """Turn an argument path into an absolute URL: an absolute href is used as
    is, an absolute path joins to the collection's scheme://host, and a bare
    resource name joins to the collection.
    """
    if re.match(r"^https?://", path, re.IGNORECASE):
        return path
    parts = urlsplit(collection)
    origin = f"{parts.scheme}://{parts.netloc}"
    if path.startswith("/"):
        return origin + path
    return collection.rstrip("/") + "/" + path


def _http(
    method: str,
    url: str,
    user: str,
    password: str,
    body: str | bytes | None = None,
    extra_headers: dict[str, str] | None = None,
) -> tuple[int | None, dict[str, str], bytes, str | None]:
    """Run an authenticated urllib request. Returns
    (status, headers-dict, raw-bytes, None) or (None-ish, {}, b"", error-text).
    2xx (including 207 Multi-Status) is success; anything else is an error.
    """
    token = base64.b64encode(f"{user}:{password}".encode()).decode("ascii")
    headers = {"Authorization": f"Basic {token}"}
    if extra_headers:
        headers.update(extra_headers)
    data = body.encode("utf-8") if isinstance(body, str) else body
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.getcode(), dict(resp.headers), resp.read(), None
    except urllib.error.HTTPError as e:
        return (
            e.code,
            dict(e.headers or {}),
            e.read() or b"",
            (f"CardDAV error: HTTP {e.code} for {method} {url}"),
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


def _vcard_hrefs(raw: bytes) -> list[str]:
    """The hrefs from a PROPFIND multistatus that name vCard resources (by
    content type text/vcard or a .vcf suffix).
    """
    # The XML is the user's own configured CardDAV server's response to an
    # authenticated request, and this stdlib-only package cannot grow a
    # defusedxml dependency, so plain ElementTree is deliberate.
    root = ET.fromstring(raw)  # noqa: S314
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


def _search_body(query: str) -> str:
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


def _vcard_uid(vcard: str) -> str:
    """The UID value from a vCard body, or "" when absent."""
    m = re.search(r"(?im)^UID(?:;[^:]*)?:(.*)$", vcard)
    return m.group(1).strip() if m else ""


def _tool_discover(_args: dict[str, Any], vals: dict[str, str]) -> tuple[str, bool]:
    collection = _collection(vals)
    _, _, raw, err = _http(
        "PROPFIND",
        collection,
        vals["user"],
        vals["password"],
        body=_PROPFIND_BODY,
        extra_headers=_XML_HEADERS,
    )
    if err:
        return err, True
    try:
        hrefs = _vcard_hrefs(raw)
    except ET.ParseError as e:
        return f"failed to parse PROPFIND response: {e}", True
    return json.dumps(hrefs), False


def _tool_search(args: dict[str, Any], vals: dict[str, str]) -> tuple[str, bool]:
    collection = _collection(vals)
    query = (args.get("query") or "").strip()
    _, _, raw, err = _http(
        "REPORT",
        collection,
        vals["user"],
        vals["password"],
        body=_search_body(query),
        extra_headers=_XML_HEADERS,
    )
    if err:
        return err, True
    return raw.decode("utf-8", "replace"), False


def _tool_get(args: dict[str, Any], vals: dict[str, str]) -> tuple[str, bool]:
    path = args.get("path")
    if not path:
        return "missing required argument: path", True
    url = _resolve_path(path, _collection(vals))
    _, _, raw, err = _http("GET", url, vals["user"], vals["password"])
    if err:
        return err, True
    return raw.decode("utf-8", "replace"), False


def _tool_new(args: dict[str, Any], vals: dict[str, str]) -> tuple[str, bool]:
    vcard = args.get("vcard")
    if not vcard:
        return "missing required argument: vcard", True
    collection = _collection(vals)
    name = (_vcard_uid(vcard) or str(uuid.uuid4())) + ".vcf"
    url = collection.rstrip("/") + "/" + quote(name, safe="")
    _, _, _, err = _http(
        "PUT",
        url,
        vals["user"],
        vals["password"],
        body=vcard,
        extra_headers={
            "Content-Type": "text/vcard; charset=utf-8",
            "If-None-Match": "*",
        },
    )
    if err:
        return err, True
    return url, False


def _tool_edit(args: dict[str, Any], vals: dict[str, str]) -> tuple[str, bool]:
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
        "PUT",
        url,
        vals["user"],
        vals["password"],
        body=vcard,
        extra_headers=headers,
    )
    if err:
        return err, True
    return json.dumps({"path": url, "etag": resp_headers.get("ETag", "")}), False


def _tool_delete(args: dict[str, Any], vals: dict[str, str]) -> tuple[str, bool]:
    path = args.get("path")
    if not path:
        return "missing required argument: path", True
    url = _resolve_path(path, _collection(vals))
    _, _, _, err = _http("DELETE", url, vals["user"], vals["password"])
    if err:
        return err, True
    return f"deleted {url}", False


def _vals(
    impl: Callable[[dict[str, Any], dict[str, str]], tuple[str, bool]],
) -> Callable[[dict[str, Any], str, dict[str, str]], tuple[str, bool]]:
    """Adapt an (args, vals)-style impl to the scaffold's record signature."""
    return lambda args, _profile, vals: impl(args, vals)


_NEEDS = ("server", "user", "password")

TOOLS, call_tool, main = make_server(
    SERVER_NAME,
    SERVER_VERSION,
    [
        {
            "name": "discover",
            "description": "List the vCard hrefs in the addressbook collection (PROPFIND Depth:1)",
            "schema": {"properties": {}, "required": []},
            "needs_fields": _NEEDS,
            "impl": _vals(_tool_discover),
        },
        {
            "name": "search",
            "description": (
                "Server-side addressbook-query REPORT matching FN/EMAIL; "
                "an empty query returns every contact"
            ),
            "schema": {
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "text to match (empty = all)",
                    }
                },
                "required": [],
            },
            "needs_fields": _NEEDS,
            "impl": _vals(_tool_search),
        },
        {
            "name": "get",
            "description": "Fetch one contact's vCard by its href/path",
            "schema": {
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "contact href, path, or resource name",
                    }
                },
                "required": ["path"],
            },
            "needs_fields": _NEEDS,
            "impl": _vals(_tool_get),
        },
        {
            "name": "new",
            "description": "Create a contact from a vCard (PUT); the resource name is derived from its UID",
            "schema": {
                "properties": {
                    "vcard": {
                        "type": "string",
                        "description": "the vCard body to store",
                    }
                },
                "required": ["vcard"],
            },
            "needs_fields": _NEEDS,
            "impl": _vals(_tool_new),
        },
        {
            "name": "edit",
            "description": "Replace an existing contact's vCard (PUT), optionally guarded by an If-Match ETag",
            "schema": {
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "contact href, path, or resource name",
                    },
                    "vcard": {
                        "type": "string",
                        "description": "the replacement vCard body",
                    },
                    "etag": {
                        "type": "string",
                        "description": "ETag guard sent as If-Match (optional)",
                    },
                },
                "required": ["path", "vcard"],
            },
            "needs_fields": _NEEDS,
            "impl": _vals(_tool_edit),
        },
        {
            "name": "delete",
            "description": "Delete a contact by its href/path",
            "schema": {
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "contact href, path, or resource name",
                    }
                },
                "required": ["path"],
            },
            "needs_fields": _NEEDS,
            "impl": _vals(_tool_delete),
        },
    ],
    secret_field="password",  # noqa: S106 — names the store field, not a credential
)


if __name__ == "__main__":
    sys.exit(main())

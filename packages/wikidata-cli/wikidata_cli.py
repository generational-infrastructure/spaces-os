#!/usr/bin/env python3
"""Wikidata CLI - search entities, fetch entity data, and run SPARQL.

All three Wikidata endpoints are public and need no auth. WDQS asks
clients to send a descriptive User-Agent and not to hammer the service,
so every request carries one and repeated requests are throttled to one
per second (the same courtesy osm-cli extends to Nominatim).
"""

import argparse
import functools
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

WIKIDATA_API = "https://www.wikidata.org/w/api.php"
ENTITY_DATA = "https://www.wikidata.org/wiki/Special:EntityData"
WDQS = "https://query.wikidata.org/sparql"
USER_AGENT = "distro-pi-chat-wikidata/0.1"


@functools.cache
def _throttle_state() -> list[float]:
    """Single-element mutable cache holding the monotonic time of the last
    request. `functools.cache` hands back the same list on every call, which
    gives `_request` a persistent slot to update without a module `global`.
    """
    return [0.0]


def search_url(query: str, limit: int) -> str:
    """Build the wbsearchentities request URL for a label search."""
    params = urllib.parse.urlencode(
        {
            "action": "wbsearchentities",
            "search": query,
            "language": "en",
            "format": "json",
            "type": "item",
            "limit": str(limit),
        }
    )
    return f"{WIKIDATA_API}?{params}"


def entity_url(qid: str) -> str:
    """Build the Special:EntityData JSON URL for an entity."""
    return f"{ENTITY_DATA}/{qid}.json"


def sparql_url(query: str) -> str:
    """Build the WDQS request URL for a SPARQL query."""
    params = urllib.parse.urlencode({"query": query, "format": "json"})
    return f"{WDQS}?{params}"


def parse_search(data: dict[str, Any]) -> list[dict[str, Any]]:
    """Extract id/label/description per hit from a wbsearchentities body."""
    return [
        {
            "id": hit.get("id"),
            "label": hit.get("label"),
            "description": hit.get("description"),
        }
        for hit in data.get("search", [])
    ]


def _render_snak(snak: dict[str, Any]) -> Any:
    """Render a claim's mainsnak as a compact, readable value string."""
    if snak.get("snaktype") != "value":
        # "somevalue" (unknown) / "novalue" (explicit absence) carry no datavalue.
        return snak.get("snaktype")
    datavalue = snak.get("datavalue", {})
    vtype = datavalue.get("type")
    value = datavalue.get("value")
    if vtype == "wikibase-entityid":
        return value.get("id")
    if vtype == "string":
        return value
    if vtype == "time":
        return value.get("time")
    if vtype == "quantity":
        return value.get("amount")
    if vtype == "monolingualtext":
        return value.get("text")
    if vtype == "globecoordinate":
        return f"{value.get('latitude')}, {value.get('longitude')}"
    return json.dumps(value, ensure_ascii=False)


def summarize_entity(data: dict[str, Any], qid: str) -> dict[str, Any]:
    """Reduce a Special:EntityData body to id, en label/description, claims.

    Claims collapse to property → list of rendered values; referenced
    entities stay as QIDs so the summary is one request, not hundreds.
    """
    entity = data.get("entities", {}).get(qid, {})
    label = entity.get("labels", {}).get("en", {}).get("value")
    description = entity.get("descriptions", {}).get("en", {}).get("value")
    claims = {}
    for prop, statements in entity.get("claims", {}).items():
        values = [_render_snak(st.get("mainsnak", {})) for st in statements]
        values = [v for v in values if v is not None]
        if values:
            claims[prop] = values
    return {
        "id": entity.get("id", qid),
        "label": label,
        "description": description,
        "claims": claims,
    }


def parse_sparql(data: dict[str, Any]) -> list[dict[str, Any]]:
    """Return the results.bindings rows from a SPARQL JSON result set."""
    return data.get("results", {}).get("bindings", [])


def select_query(
    positional: str | None, file_text: str | None, stdin_text: str | None
) -> str | None:
    """Resolve the SPARQL query text: positional, then --file, then stdin."""
    if positional:
        return positional
    if file_text is not None:
        return file_text
    if stdin_text:
        return stdin_text
    return None


def _request(
    url: str, accept: str = "application/json", timeout: int = 30
) -> dict[str, Any]:
    """HTTP GET with a polite User-Agent and 1 req/s throttle. Returns JSON."""
    state = _throttle_state()
    elapsed = time.monotonic() - state[0]
    if elapsed < 1.0:
        time.sleep(1.0 - elapsed)
    state[0] = time.monotonic()

    headers = {"User-Agent": USER_AGENT, "Accept": accept}
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        print(f"Error: HTTP {e.code} from {url}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"Error: {e.reason}", file=sys.stderr)
        sys.exit(1)
    except TimeoutError:
        print(f"Error: request timed out ({timeout}s)", file=sys.stderr)
        sys.exit(1)


def _print_json(obj: Any) -> None:
    print(json.dumps(obj, indent=2, ensure_ascii=False))


def cmd_search(args: argparse.Namespace) -> None:
    """Resolve a label to candidate QIDs with labels and descriptions."""
    data = _request(search_url(args.query, args.limit))
    _print_json(parse_search(data))


def cmd_get(args: argparse.Namespace) -> None:
    """Fetch one entity; summarize by default, dump raw JSON with --raw."""
    data = _request(entity_url(args.qid))
    if args.raw:
        _print_json(data)
    else:
        _print_json(summarize_entity(data, args.qid))


def cmd_sparql(args: argparse.Namespace) -> None:
    """Run a SPARQL query against WDQS and print results.bindings."""
    file_text = None
    if args.file:
        file_text = Path(args.file).read_text()
    stdin_text = None
    if not sys.stdin.isatty():
        stdin_text = sys.stdin.read()
    query = select_query(args.query, file_text, stdin_text)
    if not query or not query.strip():
        print(
            "Error: no query given. Pass it as an argument, via --file, or on stdin.",
            file=sys.stderr,
        )
        sys.exit(1)
    data = _request(sparql_url(query), accept="application/sparql-results+json")
    _print_json(parse_sparql(data))


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="wikidata-cli",
        description="Search entities, fetch entity data, and run SPARQL on Wikidata",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_search = sub.add_parser("search", help="Resolve a label to candidate QIDs")
    p_search.add_argument("query", help="Label or text to search for")
    p_search.add_argument(
        "--limit", type=int, default=7, help="Max results (default: 7)"
    )

    p_get = sub.add_parser("get", help="Fetch entity data by QID")
    p_get.add_argument("qid", help="Entity id, e.g. Q42")
    p_get.add_argument("--raw", action="store_true", help="Dump the full upstream JSON")

    p_sparql = sub.add_parser("sparql", help="Run a SPARQL query against WDQS")
    p_sparql.add_argument(
        "query", nargs="?", help="SPARQL query (or use --file / stdin)"
    )
    p_sparql.add_argument("--file", help="Read the query from a file")

    args = parser.parse_args()
    if args.command == "search":
        cmd_search(args)
    elif args.command == "get":
        cmd_get(args)
    elif args.command == "sparql":
        cmd_sparql(args)


if __name__ == "__main__":
    main()

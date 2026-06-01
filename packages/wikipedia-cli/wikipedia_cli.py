#!/usr/bin/env python3
"""Wikipedia CLI - search, summary, and full article text via the MediaWiki API.

Public, no-auth service: the Action API (`/w/api.php`) and the REST v1
summary endpoint (`/api/rest_v1/page/summary/`). All verbs take --lang to
pick the language subdomain (default English). MediaWiki etiquette asks for
a descriptive User-Agent and a gentle request rate; both are honoured here.
"""

import argparse
import html
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

USER_AGENT = "distro-pi-chat-wikipedia/0.1"

_TAG_RE = re.compile(r"<[^>]+>")
_last_request = 0.0


def _api_base(lang):
    return f"https://{lang}.wikipedia.org/w/api.php"


def build_search_url(query, limit, lang):
    """Action API full-text search URL for a language edition."""
    params = urllib.parse.urlencode(
        {
            "action": "query",
            "list": "search",
            "srsearch": query,
            "srlimit": str(limit),
            "format": "json",
        }
    )
    return f"{_api_base(lang)}?{params}"


def build_summary_url(title, lang):
    """REST v1 page-summary URL. Title is path-encoded so reserved
    characters can't break the slash-delimited REST path."""
    slug = urllib.parse.quote(title.replace(" ", "_"), safe="")
    return f"https://{lang}.wikipedia.org/api/rest_v1/page/summary/{slug}"


def build_content_url(title, intro, lang):
    """Action API plaintext-extract URL; --intro limits it to the lead."""
    params = {
        "action": "query",
        "prop": "extracts",
        "explaintext": "1",
        "titles": title,
        "format": "json",
    }
    if intro:
        params["exintro"] = "1"
    return f"{_api_base(lang)}?{urllib.parse.urlencode(params)}"


def strip_html(text):
    """Strip MediaWiki's snippet markup down to plain text."""
    return html.unescape(_TAG_RE.sub("", text))


def parse_search(data):
    """Pull (title, pageid, plain snippet) out of a list=search response."""
    hits = []
    for hit in data.get("query", {}).get("search", []):
        hits.append(
            {
                "title": hit.get("title", ""),
                "pageid": hit.get("pageid"),
                "snippet": strip_html(hit.get("snippet", "")),
            }
        )
    return hits


def parse_summary(data):
    """Pull title/description/extract and the canonical page URL out of a
    REST summary response."""
    return {
        "title": data.get("title", ""),
        "description": data.get("description", ""),
        "extract": data.get("extract", ""),
        "url": data.get("content_urls", {}).get("desktop", {}).get("page", ""),
    }


def parse_extract(data):
    """Return the plaintext extract from a prop=extracts response. The
    pages map is keyed by pageid; a missing page carries no extract."""
    for page in data.get("query", {}).get("pages", {}).values():
        return page.get("extract", "")
    return ""


def _request(url, timeout=15):
    """HTTP GET with a descriptive User-Agent. Returns parsed JSON.

    Repeated calls are throttled to one per second to stay within
    MediaWiki's etiquette, the way osm-cli throttles Nominatim."""
    global _last_request
    elapsed = time.monotonic() - _last_request
    if elapsed < 1.0:
        time.sleep(1.0 - elapsed)
    _last_request = time.monotonic()

    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
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


def cmd_search(args):
    """Resolve a query to encyclopedic article candidates."""
    data = _request(build_search_url(args.query, args.limit, args.lang))
    hits = parse_search(data)
    if not hits:
        print(f"No results for '{args.query}'")
        return
    for i, hit in enumerate(hits):
        if i > 0:
            print()
        print(f"Title: {hit['title']}")
        print(f"Page ID: {hit['pageid']}")
        if hit["snippet"]:
            print(f"Snippet: {hit['snippet']}")


def cmd_summary(args):
    """One-shot factual summary of an article."""
    data = _request(build_summary_url(args.title, args.lang))
    out = parse_summary(data)
    print(f"Title: {out['title']}")
    if out["description"]:
        print(f"Description: {out['description']}")
    if out["extract"]:
        print(f"Extract: {out['extract']}")
    if out["url"]:
        print(f"URL: {out['url']}")


def cmd_content(args):
    """Full plaintext article, or just the lead with --intro."""
    data = _request(build_content_url(args.title, args.intro, args.lang))
    text = parse_extract(data)
    if not text:
        print(f"No article found for '{args.title}'")
        return
    print(text)


def build_parser():
    parser = argparse.ArgumentParser(
        prog="wikipedia-cli",
        description="Search Wikipedia and read article summaries or full text",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    def add_lang(p):
        p.add_argument(
            "--lang",
            default="en",
            help="Wikipedia language edition (default: en)",
        )

    p_search = sub.add_parser("search", help="Search articles by query")
    p_search.add_argument("query", help="Search query")
    p_search.add_argument(
        "--limit", type=int, default=5, help="Number of results (default: 5)"
    )
    add_lang(p_search)
    p_search.set_defaults(func=cmd_search)

    p_summary = sub.add_parser("summary", help="Short factual summary of an article")
    p_summary.add_argument("title", help="Exact article title")
    add_lang(p_summary)
    p_summary.set_defaults(func=cmd_summary)

    p_content = sub.add_parser("content", help="Full plaintext article")
    p_content.add_argument("title", help="Exact article title")
    p_content.add_argument("--intro", action="store_true", help="Only the lead section")
    add_lang(p_content)
    p_content.set_defaults(func=cmd_content)

    return parser


def main():
    args = build_parser().parse_args()
    args.func(args)


if __name__ == "__main__":
    main()

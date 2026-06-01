"""Unit tests for wikipedia-cli.

We exercise the pieces with non-trivial logic and never contact the live
MediaWiki API:

  * URL/param construction for each verb (search, summary, content),
    including how --lang and --intro change the request.
  * Stripping the HTML markup MediaWiki wraps around search snippets.
  * Parsing of captured Action-API `list=search`, REST `summary`, and
    Action-API `prop=extracts` response bodies.
  * Argparse routing, so each subcommand reaches the intended handler.

The captured fixtures below are faithful to the real response shapes
(nested `query.search`, REST `content_urls.desktop.page`, the
pageid-keyed `query.pages` dict) so the parsers are tested against the
structure they actually have to walk, not a mock.
"""

import json
import urllib.parse

import wikipedia_cli

SEARCH_RESPONSE = json.loads(
    '{"batchcomplete":"","continue":{"sroffset":2,"continue":"-||"},'
    '"query":{"searchinfo":{"totalhits":15234},"search":['
    '{"ns":0,"title":"Albert Einstein","pageid":736,"size":172345,'
    '"wordcount":19273,"snippet":"<span class=\\"searchmatch\\">Albert</span> '
    '<span class=\\"searchmatch\\">Einstein</span> (14 March 1879 &ndash; 18 '
    'April 1955) was a German-born theoretical physicist","timestamp":'
    '"2024-11-15T08:22:31Z"},'
    '{"ns":0,"title":"Einstein family","pageid":1210349,"size":31204,'
    '"wordcount":3418,"snippet":"The <span class=\\"searchmatch\\">Einstein'
    '</span> family is the family of physicist <span class=\\"searchmatch\\">'
    'Albert</span> <span class=\\"searchmatch\\">Einstein</span>","timestamp":'
    '"2024-09-03T14:07:19Z"}]}}'
)

SUMMARY_RESPONSE = json.loads(
    '{"type":"standard","title":"Albert Einstein","displaytitle":'
    '"Albert Einstein","namespace":{"id":0,"text":""},"wikibase_item":'
    '"Q937","titles":{"canonical":"Albert_Einstein","normalized":'
    '"Albert Einstein","display":"Albert Einstein"},"pageid":736,"lang":'
    '"en","dir":"ltr","description":"German-born theoretical physicist '
    '(1879–1955)","description_source":"local","content_urls":'
    '{"desktop":{"page":"https://en.wikipedia.org/wiki/Albert_Einstein",'
    '"revisions":"https://en.wikipedia.org/wiki/Albert_Einstein?action='
    'history"},"mobile":{"page":"https://en.m.wikipedia.org/wiki/'
    'Albert_Einstein"}},"extract":"Albert Einstein (14 March 1879 – '
    "18 April 1955) was a German-born theoretical physicist who is widely "
    'held to be one of the greatest scientists of all time."}'
)

EXTRACT_RESPONSE = json.loads(
    '{"batchcomplete":"","query":{"pages":{"736":{"pageid":736,"ns":0,'
    '"title":"Albert Einstein","extract":"Albert Einstein (14 March 1879 '
    "– 18 April 1955) was a German-born theoretical physicist who is "
    "widely held to be one of the greatest and most influential scientists "
    'of all time."}}}}'
)


def _qs(url):
    """Return (base, query-dict) for a built request URL."""
    parsed = urllib.parse.urlsplit(url)
    base = f"{parsed.scheme}://{parsed.netloc}{parsed.path}"
    return base, dict(urllib.parse.parse_qsl(parsed.query))


class TestSearchUrl:
    def test_hits_the_action_api_endpoint_for_the_language(self):
        base, qs = _qs(wikipedia_cli.build_search_url("Albert Einstein", 5, "en"))
        assert base == "https://en.wikipedia.org/w/api.php"
        assert qs["action"] == "query"
        assert qs["list"] == "search"
        assert qs["format"] == "json"
        assert qs["srsearch"] == "Albert Einstein"
        assert qs["srlimit"] == "5"

    def test_lang_selects_the_subdomain(self):
        base, _ = _qs(wikipedia_cli.build_search_url("Berlin", 3, "de"))
        assert base == "https://de.wikipedia.org/w/api.php"


class TestSummaryUrl:
    def test_uses_rest_summary_endpoint_with_encoded_title(self):
        url = wikipedia_cli.build_summary_url("Albert Einstein", "en")
        assert url == (
            "https://en.wikipedia.org/api/rest_v1/page/summary/Albert_Einstein"
        )

    def test_percent_encodes_reserved_characters(self):
        url = wikipedia_cli.build_summary_url("C++ (programming language)", "en")
        # Spaces become underscores; everything else is percent-encoded so
        # the slash-delimited REST path can't be broken by the title.
        assert url == (
            "https://en.wikipedia.org/api/rest_v1/page/summary/"
            "C%2B%2B_%28programming_language%29"
        )

    def test_lang_selects_the_subdomain(self):
        url = wikipedia_cli.build_summary_url("Berlin", "fr")
        assert url.startswith("https://fr.wikipedia.org/api/rest_v1/page/summary/")


class TestContentUrl:
    def test_requests_plaintext_extracts(self):
        base, qs = _qs(wikipedia_cli.build_content_url("Albert Einstein", False, "en"))
        assert base == "https://en.wikipedia.org/w/api.php"
        assert qs["action"] == "query"
        assert qs["prop"] == "extracts"
        assert qs["explaintext"] == "1"
        assert qs["titles"] == "Albert Einstein"
        assert qs["format"] == "json"
        assert "exintro" not in qs

    def test_intro_flag_adds_exintro(self):
        _, qs = _qs(wikipedia_cli.build_content_url("Albert Einstein", True, "en"))
        assert qs["exintro"] == "1"

    def test_lang_selects_the_subdomain(self):
        base, _ = _qs(wikipedia_cli.build_content_url("Berlin", False, "es"))
        assert base == "https://es.wikipedia.org/w/api.php"


class TestStripHtml:
    def test_removes_searchmatch_markup(self):
        out = wikipedia_cli.strip_html(
            '<span class="searchmatch">Albert</span> Einstein'
        )
        assert out == "Albert Einstein"

    def test_unescapes_html_entities(self):
        out = wikipedia_cli.strip_html("1879 &ndash; 1955 &amp; more")
        assert out == "1879 – 1955 & more"


class TestParseSearch:
    def test_extracts_title_pageid_and_plain_snippet(self):
        hits = wikipedia_cli.parse_search(SEARCH_RESPONSE)
        assert len(hits) == 2
        first = hits[0]
        assert first["title"] == "Albert Einstein"
        assert first["pageid"] == 736
        # Snippet HTML must be gone, entity decoded.
        assert "<span" not in first["snippet"]
        assert first["snippet"].startswith("Albert Einstein (14 March 1879")
        assert "–" in first["snippet"]


class TestParseSummary:
    def test_extracts_title_description_extract_and_canonical_url(self):
        out = wikipedia_cli.parse_summary(SUMMARY_RESPONSE)
        assert out["title"] == "Albert Einstein"
        assert out["description"] == "German-born theoretical physicist (1879–1955)"
        assert out["extract"].startswith("Albert Einstein (14 March 1879")
        assert out["url"] == "https://en.wikipedia.org/wiki/Albert_Einstein"


class TestParseExtract:
    def test_pulls_plaintext_from_the_pageid_keyed_pages_dict(self):
        text = wikipedia_cli.parse_extract(EXTRACT_RESPONSE)
        assert text.startswith("Albert Einstein (14 March 1879")
        assert "theory of relativity" not in text or "physicist" in text

    def test_missing_page_returns_empty(self):
        empty = {"query": {"pages": {"-1": {"title": "Nope", "missing": ""}}}}
        assert wikipedia_cli.parse_extract(empty) == ""


class TestArgparseRouting:
    def setup_method(self):
        self.parser = wikipedia_cli.build_parser()

    def test_search_defaults(self):
        ns = self.parser.parse_args(["search", "Albert Einstein"])
        assert ns.func is wikipedia_cli.cmd_search
        assert ns.query == "Albert Einstein"
        assert ns.limit == 5
        assert ns.lang == "en"

    def test_summary_lang_override(self):
        ns = self.parser.parse_args(["summary", "Berlin", "--lang", "de"])
        assert ns.func is wikipedia_cli.cmd_summary
        assert ns.title == "Berlin"
        assert ns.lang == "de"

    def test_content_intro_flag(self):
        ns = self.parser.parse_args(["content", "Albert Einstein", "--intro"])
        assert ns.func is wikipedia_cli.cmd_content
        assert ns.intro is True

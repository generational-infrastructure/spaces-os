"""Tests for wikidata_cli: URL construction and response parsing.

These never touch the network. Each parsing test runs against a captured
slice of a real upstream response embedded below.
"""

import urllib.parse

import wikidata_cli

# Captured slice of a real wbsearchentities response for "Douglas Adams"
# (action=wbsearchentities&search=Douglas Adams&language=en&format=json
#  &type=item&limit=3). The flat label/description keys are canonical.
SEARCH_FIXTURE = {
    "searchinfo": {"search": "Douglas Adams"},
    "search": [
        {
            "id": "Q42",
            "title": "Q42",
            "pageid": 138,
            "concepturi": "http://www.wikidata.org/entity/Q42",
            "label": "Douglas Adams",
            "description": "British science fiction writer and humorist (1952–2001)",
            "match": {"type": "label", "language": "en", "text": "Douglas Adams"},
        },
        {
            "id": "Q28421831",
            "title": "Q28421831",
            "pageid": 30117550,
            "concepturi": "http://www.wikidata.org/entity/Q28421831",
            "label": "Douglas Adams",
            "description": "American environmental engineer",
            "match": {"type": "label", "language": "en", "text": "Douglas Adams"},
        },
    ],
    "search-continue": 2,
    "success": 1,
}

# Captured slice of Special:EntityData/Q42.json covering every claim
# datavalue shape we render: wikibase-entityid, time, quantity,
# external-id (string), and monolingualtext.
ENTITY_FIXTURE = {
    "entities": {
        "Q42": {
            "type": "item",
            "id": "Q42",
            "labels": {
                "en": {"language": "en", "value": "Douglas Adams"},
                "de": {"language": "de", "value": "Douglas Adams"},
            },
            "descriptions": {
                "en": {
                    "language": "en",
                    "value": "British science fiction writer and humorist (1952–2001)",
                }
            },
            "claims": {
                "P31": [
                    {
                        "mainsnak": {
                            "snaktype": "value",
                            "property": "P31",
                            "datavalue": {
                                "value": {
                                    "entity-type": "item",
                                    "numeric-id": 5,
                                    "id": "Q5",
                                },
                                "type": "wikibase-entityid",
                            },
                            "datatype": "wikibase-item",
                        },
                        "type": "statement",
                        "rank": "normal",
                    }
                ],
                "P569": [
                    {
                        "mainsnak": {
                            "snaktype": "value",
                            "property": "P569",
                            "datavalue": {
                                "value": {
                                    "time": "+1952-03-11T00:00:00Z",
                                    "timezone": 0,
                                    "precision": 11,
                                    "calendarmodel": "http://www.wikidata.org/entity/Q1985727",
                                },
                                "type": "time",
                            },
                            "datatype": "time",
                        },
                        "type": "statement",
                        "rank": "normal",
                    }
                ],
                "P2048": [
                    {
                        "mainsnak": {
                            "snaktype": "value",
                            "property": "P2048",
                            "datavalue": {
                                "value": {
                                    "amount": "+1.96",
                                    "unit": "http://www.wikidata.org/entity/Q11573",
                                },
                                "type": "quantity",
                            },
                            "datatype": "quantity",
                        },
                        "type": "statement",
                        "rank": "normal",
                    }
                ],
                "P1015": [
                    {
                        "mainsnak": {
                            "snaktype": "value",
                            "property": "P1015",
                            "datavalue": {"value": "90196888", "type": "string"},
                            "datatype": "external-id",
                        },
                        "type": "statement",
                        "rank": "normal",
                    }
                ],
                "P1813": [
                    {
                        "mainsnak": {
                            "snaktype": "value",
                            "property": "P1813",
                            "datavalue": {
                                "value": {"text": "Douglas Adams", "language": "en"},
                                "type": "monolingualtext",
                            },
                            "datatype": "monolingualtext",
                        },
                        "type": "statement",
                        "rank": "normal",
                    }
                ],
            },
        }
    }
}

# Captured slice of a WDQS SPARQL 1.1 JSON result set.
SPARQL_FIXTURE = {
    "head": {"vars": ["author", "authorLabel", "born"]},
    "results": {
        "bindings": [
            {
                "author": {
                    "type": "uri",
                    "value": "http://www.wikidata.org/entity/Q151819",
                },
                "authorLabel": {
                    "type": "literal",
                    "xml:lang": "en",
                    "value": "Qa'a",
                },
                "born": {
                    "type": "literal",
                    "datatype": "http://www.w3.org/2001/XMLSchema#dateTime",
                    "value": "-2889-01-01T00:00:00Z",
                },
            },
            {
                "author": {
                    "type": "uri",
                    "value": "http://www.wikidata.org/entity/Q131171",
                },
                "authorLabel": {
                    "type": "literal",
                    "xml:lang": "en",
                    "value": "Imhotep",
                },
            },
        ]
    },
}


def _query_params(url):
    return urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)


def test_search_url_uses_wbsearchentities_with_query_and_limit():
    url = wikidata_cli.search_url("Douglas Adams", 3)
    split = urllib.parse.urlsplit(url)
    assert split.netloc == "www.wikidata.org"
    assert split.path == "/w/api.php"
    params = _query_params(url)
    assert params["action"] == ["wbsearchentities"]
    assert params["search"] == ["Douglas Adams"]
    assert params["language"] == ["en"]
    assert params["format"] == ["json"]
    assert params["type"] == ["item"]
    assert params["limit"] == ["3"]


def test_entity_url_targets_special_entitydata_json():
    url = wikidata_cli.entity_url("Q42")
    assert url == "https://www.wikidata.org/wiki/Special:EntityData/Q42.json"


def test_sparql_url_targets_wdqs_with_query_and_json_format():
    url = wikidata_cli.sparql_url("SELECT ?x WHERE { ?x ?y ?z } LIMIT 1")
    split = urllib.parse.urlsplit(url)
    assert split.netloc == "query.wikidata.org"
    assert split.path == "/sparql"
    params = _query_params(url)
    assert params["query"] == ["SELECT ?x WHERE { ?x ?y ?z } LIMIT 1"]
    assert params["format"] == ["json"]


def test_parse_search_extracts_id_label_description():
    hits = wikidata_cli.parse_search(SEARCH_FIXTURE)
    assert hits == [
        {
            "id": "Q42",
            "label": "Douglas Adams",
            "description": "British science fiction writer and humorist (1952–2001)",
        },
        {
            "id": "Q28421831",
            "label": "Douglas Adams",
            "description": "American environmental engineer",
        },
    ]


def test_summarize_entity_extracts_label_description_and_rendered_claims():
    summary = wikidata_cli.summarize_entity(ENTITY_FIXTURE, "Q42")
    assert summary["id"] == "Q42"
    assert summary["label"] == "Douglas Adams"
    assert summary["description"].startswith("British science fiction writer")
    claims = summary["claims"]
    assert claims["P31"] == ["Q5"]
    assert claims["P569"] == ["+1952-03-11T00:00:00Z"]
    assert claims["P2048"] == ["+1.96"]
    assert claims["P1015"] == ["90196888"]
    assert claims["P1813"] == ["Douglas Adams"]


def test_parse_sparql_returns_results_bindings():
    bindings = wikidata_cli.parse_sparql(SPARQL_FIXTURE)
    assert bindings == SPARQL_FIXTURE["results"]["bindings"]
    # Unbound variables are simply absent from a binding row.
    assert "born" not in bindings[1]


def test_select_query_prefers_positional_then_file_then_stdin():
    assert wikidata_cli.select_query("POSITIONAL", "FILE", "STDIN") == "POSITIONAL"
    assert wikidata_cli.select_query(None, "FILE", "STDIN") == "FILE"
    assert wikidata_cli.select_query(None, None, "STDIN") == "STDIN"
    assert wikidata_cli.select_query(None, None, None) is None

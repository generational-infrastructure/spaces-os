---
name: wikidata
description: Resolve entities, fetch structured facts, and run SPARQL queries against Wikidata
---

Use `wikidata-cli` to look up entities on Wikidata, fetch their structured
facts, and run SPARQL queries. Wikidata is a free, public knowledge base —
no account or key is needed.

### Resolve a label to a QID

```bash
wikidata-cli search "Douglas Adams"
wikidata-cli search "Berlin" --limit 3
```

Returns candidate hits as JSON, each with `id` (the QID), `label`, and
`description`. Pick the QID that matches the entity you mean.

### Fetch an entity's facts

```bash
wikidata-cli get Q42
wikidata-cli get Q42 --raw
```

Summarizes the entity as JSON: `id`, `label`, `description`, and a compact
`claims` view (property id → value list). Referenced entities appear as QIDs
(e.g. `P31: ["Q5"]`); resolve them with another `get` or `search` if you need
their labels. `--raw` dumps the full upstream JSON (large — avoid unless you
need a field the summary drops).

### Run a SPARQL query

```bash
wikidata-cli sparql 'SELECT ?item ?itemLabel WHERE { ?item wdt:P31 wd:Q5. SERVICE wikibase:label { bd:serviceParam wikibase:language "en". } } LIMIT 5'
wikidata-cli sparql --file query.rq
echo 'SELECT ?x WHERE { ?x wdt:P31 wd:Q5 } LIMIT 1' | wikidata-cli sparql
```

Runs the query against the Wikidata Query Service and prints
`results.bindings` as JSON. Each binding maps a variable to a `{type, value}`
object. Unbound variables are simply absent from a row.

### Tips

- Two-step workflow: use `search` to turn a name into a QID, then `get` that
  QID for its facts or reference it in a `sparql` query (`wd:Q42`).
- Reach for `sparql` when you need structured, aggregate, or cross-entity
  answers ("all novels by author X", "count of cities over 1M") — `get` only
  returns one entity at a time.
- Add `SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }` and
  select `?xLabel` variables to get human-readable labels back from SPARQL.

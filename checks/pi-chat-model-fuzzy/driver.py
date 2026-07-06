#!/usr/bin/env python3
"""Component test for the NComboBox fuzzy model search.

The panel's model selector is `searchable`: a search field at the top of
the dropdown filters the list with the Fuzzy helper as the user types,
and Enter accepts the top-ranked match. This driver stages the REAL
NComboBox (searchable) next to a known model list and asserts three
layers without a compositor:

  1. The pure Fuzzy.filter ranking — substring beats scattered
     subsequence, non-matches are excluded, an empty query is identity.
  2. The widget's filtered view (combo.model) tracks the live query,
     matching against the *displayed* name (so the "[kiwi] …" source tag
     is searchable), and restores the full list when cleared.
  3. Accepting a filtered row selects its key, fires onSelected, and
     restores the full list.

Headless quickshell, offscreen platform. No pi, no LLM, no compositor.
~3s.
"""

import json
import os
import sys

from qs_harness import Quickshell, qs_env, stage_shell
from qs_harness import wait_until as _wait_until


def wait_until(predicate, *, timeout_s: float, interval_s: float = 0.2) -> bool:
    """Exception-swallowing poll: predicates here go through `qs ipc`, which
    raises on a transient failure — treat a raise as 'not yet'."""

    def safe():
        try:
            return predicate()
        except Exception:
            return False

    return _wait_until(safe, timeout_s=timeout_s, interval_s=interval_s)


def main() -> None:
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    env = qs_env(work_dir)

    qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target="test:fuzzy")
    qs.start()

    ipc = qs.ipc
    die = qs.die

    try:
        qs.wait_ipc_ready(timeout_s=20)

        # ── 1. Pure Fuzzy.filter ranking ──────────────────────────────
        candidates = "gpt-4o,gpt-4o-mini,claude-3.5-sonnet,llama-3.1-8b"

        def fuzzy(q):
            return json.loads(ipc("fuzzy", q, candidates))

        # A substring hit keeps both gpt models; input (frecency) order is
        # preserved among equal-score matches.
        if fuzzy("gpt") != ["gpt-4o", "gpt-4o-mini"]:
            die(f"fuzzy('gpt') wrong: {fuzzy('gpt')!r}")
        # Scattered subsequence: "38b" -> the only id with 3…8…b in order.
        if fuzzy("38b") != ["llama-3.1-8b"]:
            die(f"fuzzy('38b') wrong: {fuzzy('38b')!r}")
        # A query char with no in-order home anywhere excludes the row.
        if fuzzy("zzz") != []:
            die(f"fuzzy('zzz') should match nothing: {fuzzy('zzz')!r}")
        # Empty query is identity (full list, original order).
        if fuzzy("") != candidates.split(","):
            die(f"fuzzy('') should be identity: {fuzzy('')!r}")

        # ── 2. The widget's filtered view tracks the live query ───────
        if ipc("count") != "4":
            die(f"combo did not load the 4-item source (count={ipc('count')})")

        def keys():
            return json.loads(ipc("keys"))

        # The searchable dropdown must actually expand: opening it builds a
        # search field + list ColumnLayout, and the popup height derives
        # from that. A binding loop or a zero-height layout would collapse
        # it (the dropdown "opens" but is invisible). Open, assert real
        # height, then close so onClosed clears any query first.
        ipc("openPopup")
        if not wait_until(lambda: ipc("popupVisible") == "true", timeout_s=5):
            die("searchable popup never became visible after open()")
        if not wait_until(
            lambda: float(ipc("popupHeight")) > 0,
            timeout_s=5,
        ):
            die(f"opened searchable popup has zero height: {ipc('popupHeight')!r}")
        ipc("closePopup")
        if not wait_until(lambda: ipc("popupVisible") == "false", timeout_s=5):
            die("searchable popup never closed")

        ipc("setQuery", "gpt")
        if not wait_until(
            lambda: keys() == ["openrouter/gpt-4o", "openrouter/gpt-4o-mini"],
            timeout_s=5,
        ):
            die(f"'gpt' did not narrow to the gpt models: keys={keys()!r}")

        # The displayed name carries the source tag, so "kiwi" must match
        # the llama row purely by its "[kiwi]" prefix.
        ipc("setQuery", "kiwi")
        if not wait_until(lambda: keys() == ["local/llama-3.1-8b"], timeout_s=5):
            die(f"'kiwi' did not match by source tag: keys={keys()!r}")

        ipc("setQuery", "zzz")
        if not wait_until(lambda: ipc("count") == "0", timeout_s=5):
            die(f"'zzz' should empty the list: count={ipc('count')}")

        # Clearing the query restores the full source list.
        ipc("clearQuery")
        if not wait_until(lambda: ipc("count") == "4", timeout_s=5):
            die(
                f"clearing the query did not restore the full list: count={ipc('count')}"
            )

        # ── 3. Accepting a filtered row selects it and restores the list ─
        ipc("setQuery", "claude")
        if not wait_until(
            lambda: keys() == ["openrouter/claude-3.5-sonnet"], timeout_s=5
        ):
            die(f"'claude' did not narrow to the claude model: keys={keys()!r}")
        ipc("choose", "0")
        if not wait_until(
            lambda: ipc("selected") == "openrouter/claude-3.5-sonnet", timeout_s=5
        ):
            die(f"accepting the top match did not emit selected: {ipc('selected')!r}")
        if ipc("currentKey") != "openrouter/claude-3.5-sonnet":
            die(f"currentKey did not move to the accepted model: {ipc('currentKey')!r}")
        if not wait_until(lambda: ipc("count") == "4", timeout_s=5):
            die(f"accepting did not restore the full list: count={ipc('count')}")

        sys.stderr.write(
            "PASS: NComboBox fuzzy model search filters, matches by source tag, and accepts the top match\n"
        )
    finally:
        qs.stop()


if __name__ == "__main__":
    main()

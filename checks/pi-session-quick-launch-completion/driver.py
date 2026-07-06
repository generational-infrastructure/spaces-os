#!/usr/bin/env python3
"""Launch-bar completion UI contract test.

Drives the real `completer` controller (QuickBarCompletion.qml) — the
brain QuickBar's Keys.onPressed calls into — through headless quickshell
and asserts the §4.2 keyboard-contract table and the §4a behavioural
edges from the launch-bar completion plan, plus the async "candidates not
ready yet" path.

The completer is hosted in a FloatingWindow (the real QuickBar is a
layer-shell PanelWindow the offscreen platform can't realise), with a
real PiChatBackend whose model cache the driver seeds deterministically.
Completion is driven via test-only IPC verbs that invoke the SAME
functions the key handlers do (setInput/pressTab/pressEnter/…), so the
test exercises the production logic, not a re-creation of it.

Usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir>
"""

from __future__ import annotations

import json
import os
import sys

from qs_harness import Quickshell, fail, qs_env, stage_shell, wait_until

MODELS = [
    {"provider": "local", "id": "gemma4:e4b"},
    {"provider": "local", "id": "gpt-oss"},
    {"provider": "local", "id": "gpt-oss-120b"},
    {"provider": "local", "id": "llama-3.2"},
    {"provider": "local", "id": "mistral"},
]

TARGET = "test:quick-launch-completion"


def main() -> None:
    if len(sys.argv) != 5:
        fail("usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir>")
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    env = qs_env(
        work_dir,
        extra={
            "QSG_RHI_BACKEND": "null",
            "LC_ALL": "C.UTF-8",
            "LANG": "C.UTF-8",
            "PYTHONUTF8": "1",
        },
    )

    qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target=TARGET)
    qs.start()

    def die(msg):
        qs.die(msg)

    def call(*args: str) -> str:
        return qs.ipc(*args, timeout=20)

    def cand(text: str, cursor: int | None = None) -> list[str]:
        call("setInput", text, str(len(text) if cursor is None else cursor))
        return json.loads(call("candidateTexts"))

    def set_at(text: str, cursor: int | None = None) -> None:
        call("setInput", text, str(len(text) if cursor is None else cursor))

    failures: list[str] = []

    def check(label: str, got, want):
        if got != want:
            failures.append(f"{label}: got {got!r}, want {want!r}")

    try:
        if not wait_until(qs.ipc_ready, timeout_s=30):
            die("quickshell never bound the completion IPC target")

        # ── async: candidates not ready yet (plan §3.1 / §6) ──
        # Before the cache is seeded, opening the value list shows a
        # loading/empty state, then repopulates when the list arrives.
        check("loading candidates empty", cand("/model:"), [])
        check("loading flag", call("loading"), "true")
        check("loading active", call("active"), "true")
        if call("note") == "":
            failures.append("loading note: expected non-empty loading note")

        call("setModels")
        # The seed fires onModelsSnapshotChanged → re-tokenize; the open
        # list repopulates without another keystroke.
        if not wait_until(
            lambda: json.loads(call("candidateTexts")) == [m["id"] for m in MODELS],
            timeout_s=5,
        ):
            die(
                "value list did not repopulate after the model cache arrived: "
                f"{call('candidateTexts')!r}"
            )

        # ── §4.2 row: bare "/" → directive-key menu (both keys), no mutation ──
        check("slash menu", cand("/"), ["/model:", "/host:"])
        check("slash selected", call("selectedCandidate"), "/model:")
        call("pressTab")
        check("slash tab no mutation", call("inputText"), "/")

        # ── §4.2 row: "/m" unique key prefix + Tab → "/model:" + value list ──
        set_at("/m")
        call("pressTab")
        check("key complete", call("inputText"), "/model:")
        check(
            "value list opened",
            json.loads(call("candidateTexts")),
            [m["id"] for m in MODELS],
        )

        # ── §4.2 row: "/model:" + Tab → reveal value list, no mutation ──
        set_at("/model:")
        check(
            "value list shown",
            json.loads(call("candidateTexts")),
            [m["id"] for m in MODELS],
        )
        call("pressTab")
        check("empty value tab no mutation", call("inputText"), "/model:")

        # ── §4.2 row + §6 split: a unique value prefix completes and keeps
        # the value's own colon ("ge" is unique; "g" alone is ambiguous
        # against gpt-oss*) ──
        set_at("/model:ge")
        call("pressTab")
        check("value complete keeps colon", call("inputText"), "/model:gemma4:e4b")

        # ── an ambiguous prefix with no shared extension stays put, list open ──
        set_at("/model:g")
        call("pressTab")
        check("ambiguous no-extend stays", call("inputText"), "/model:g")
        check(
            "ambiguous g list",
            json.loads(call("candidateTexts")),
            ["gemma4:e4b", "gpt-oss", "gpt-oss-120b"],
        )

        # ── §4.2 row: ambiguous value → longest common prefix, list stays ──
        set_at("/model:gpt")
        call("pressTab")
        check("ambiguous lcp", call("inputText"), "/model:gpt-oss")
        check(
            "ambiguous list stays",
            json.loads(call("candidateTexts")),
            ["gpt-oss", "gpt-oss-120b"],
        )
        check("ambiguous active", call("active"), "true")

        # ── selection wraps deterministically ──
        set_at("/model:")  # 5 candidates, index 0
        check("sel start", call("selectedCandidate"), "gemma4:e4b")
        call("pressUp")
        check("wrap up to last", call("selectedCandidate"), "mistral")
        call("pressDown")
        check("wrap down to first", call("selectedCandidate"), "gemma4:e4b")
        call("pressShiftTab")
        check("shift-tab back to last", call("selectedCandidate"), "mistral")

        # ── §4a: directive-only input + Enter → no-op (stripped prompt empty) ──
        before = call("sessionCount")
        set_at("/model:gemma4:e4b ")  # trailing space → caret in empty prompt
        check("dir-only list closed", call("active"), "false")
        check("dir-only enter", call("pressEnter"), "noop")
        check("dir-only no launch", call("sessionCount"), before)

        # ── §4a: invalid model value + Enter → bar stays, no launch ──
        before = call("sessionCount")
        set_at("/model:bogus summarize")
        check("invalid enter", call("pressEnter"), "invalid")
        check("invalid no launch", call("sessionCount"), before)
        check("invalid stays open", call("active"), "true")

        # ── §4a: unknown leading directive key + Enter → not sent as prose ──
        before = call("sessionCount")
        set_at("/modle:foo bar")
        check("unknown enter", call("pressEnter"), "unknown")
        check("unknown no launch", call("sessionCount"), before)

        # ── §4.2: Esc closes the list first, a second Esc hides the bar ──
        set_at("/model:")
        check("esc pre active", call("active"), "true")
        check("esc closes", call("pressEscape"), "close")
        check("esc closed list", call("active"), "false")
        check("esc hides bar", call("pressEscape"), "hide")

        # ── full launch: directive applied, prompt stripped ──
        before = int(call("sessionCount"))
        set_at("/model:gemma4:e4b do X")
        check("launch list closed", call("active"), "false")
        check("launch enter", call("pressEnter"), "launch")
        check("launch prompt stripped", call("lastLaunchPrompt"), "do X")
        check("launch model resolved", call("lastLaunchModel"), "local/gemma4:e4b")
        if not wait_until(lambda: int(call("sessionCount")) == before + 1, timeout_s=5):
            failures.append(
                f"launch session: count stayed {call('sessionCount')}, want {before + 1}"
            )
        else:
            check("launch newest model", call("newestModel"), "local/gemma4:e4b")

        # ── plain prose Enter still launches verbatim (flow untouched) ──
        before = int(call("sessionCount"))
        set_at("just summarize the repo")
        check("prose list closed", call("active"), "false")
        check("prose enter", call("pressEnter"), "launch")
        check("prose prompt", call("lastLaunchPrompt"), "just summarize the repo")
        check("prose no model", call("lastLaunchModel"), "")

        # ── /host: — executor directive (mirrors /model:) ──
        # Before any executor is configured, /host: offers nothing.
        check("host empty no execs", cand("/host:"), [])
        check("host empty note", call("note"), "no matching host")

        # One executor: still gated (mirrors Panel's >1 +-picker rule).
        call("setExecutorsOne")
        check("host one exec gated", cand("/host:"), [])

        # Two executors: ids are offered, prefix-narrowed, Tab-completed.
        call("setExecutorsTwo")
        check("host candidates", cand("/host:"), ["kiwi", "traube"])
        set_at("/host:k")
        call("pressTab")
        check("host unique tab", call("inputText"), "/host:kiwi")
        set_at("/host:t")
        call("pressTab")
        check("host other tab", call("inputText"), "/host:traube")
        # No match → dead-end note, no candidates.
        check("host no match", cand("/host:zzz"), [])
        check("host no match note", call("note"), "no matching host")

        # Unknown id + Enter → refused, bar stays open, no launch.
        before = call("sessionCount")
        set_at("/host:zzz do thing")
        check("host invalid enter", call("pressEnter"), "invalid")
        check("host invalid no launch", call("sessionCount"), before)
        check("host invalid stays open", call("active"), "true")

        # Valid id (full) + Enter → launch pinned to that executor.
        before = int(call("sessionCount"))
        set_at("/host:kiwi summarize")
        check("host launch enter", call("pressEnter"), "launch")
        check("host launch prompt", call("lastLaunchPrompt"), "summarize")
        check("host launch executor", call("lastLaunchExecutor"), "kiwi")
        if not wait_until(lambda: int(call("sessionCount")) == before + 1, timeout_s=5):
            failures.append("host launch created no session")
        else:
            check("host newest executor", call("newestExecutor"), "kiwi")

        # Prefix-unique id (no Tab) + Enter → resolves and launches.
        before = int(call("sessionCount"))
        set_at("/host:tra cleanup")
        check("host prefix enter", call("pressEnter"), "launch")
        check("host prefix executor", call("lastLaunchExecutor"), "traube")
        if not wait_until(lambda: int(call("sessionCount")) == before + 1, timeout_s=5):
            failures.append("host prefix launch created no session")
        else:
            check("host prefix newest executor", call("newestExecutor"), "traube")

        # An empty host value must be refused, never resolved to the sole
        # executor — "".indexOf is 0 for every id, so a single-executor
        # deployment is the at-risk case. "/host:  x" (two spaces) parses
        # to an empty host directive with prompt "x".
        call("setExecutorsOne")
        before = call("sessionCount")
        set_at("/host:  do thing")
        check("host empty value enter", call("pressEnter"), "invalid")
        check("host empty value no launch", call("sessionCount"), before)
        call("setExecutorsTwo")
        before = call("sessionCount")
        set_at("/host:  do thing")
        check("host empty value enter 2x", call("pressEnter"), "invalid")
        check("host empty value no launch 2x", call("sessionCount"), before)

        # Single executor: gating hides the candidate menu, but /host: is
        # NOT disabled — a full valid id still resolves and launches pinned
        # to it, and an unknown id is still refused.
        call("setExecutorsOne")
        check("host one gated", cand("/host:"), [])
        before = int(call("sessionCount"))
        set_at("/host:kiwi single-home task")
        check("host one enter", call("pressEnter"), "launch")
        check("host one executor", call("lastLaunchExecutor"), "kiwi")
        if not wait_until(lambda: int(call("sessionCount")) == before + 1, timeout_s=5):
            failures.append("host one-executor launch created no session")
        else:
            check("host one newest executor", call("newestExecutor"), "kiwi")
        before = call("sessionCount")
        set_at("/host:ghost x")
        check("host one unknown", call("pressEnter"), "invalid")
        check("host one unknown no launch", call("sessionCount"), before)
        call("setExecutorsTwo")

        # Combined /model: + /host: → both applied (last-wins per key).
        before = int(call("sessionCount"))
        set_at("/model:gemma4:e4b /host:kiwi do both")
        check("combined enter", call("pressEnter"), "launch")
        check("combined prompt", call("lastLaunchPrompt"), "do both")
        check("combined model", call("lastLaunchModel"), "local/gemma4:e4b")
        check("combined executor", call("lastLaunchExecutor"), "kiwi")
        if not wait_until(lambda: int(call("sessionCount")) == before + 1, timeout_s=5):
            failures.append("combined launch created no session")
        else:
            check("combined newest model", call("newestModel"), "local/gemma4:e4b")
            check("combined newest executor", call("newestExecutor"), "kiwi")

        if failures:
            die("completion contract mismatches:\n  " + "\n  ".join(failures))

        print("PASS")
    finally:
        qs.stop()


if __name__ == "__main__":
    main()

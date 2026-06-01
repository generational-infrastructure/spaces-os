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
import shutil
import subprocess
import sys
import time

MODELS = [
    {"provider": "local", "id": "gemma4:e4b"},
    {"provider": "local", "id": "gpt-oss"},
    {"provider": "local", "id": "gpt-oss-120b"},
    {"provider": "local", "id": "llama-3.2"},
    {"provider": "local", "id": "mistral"},
]

TARGET = "test:quick-launch-completion"


def fail(msg: str) -> None:
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


def wait_until(predicate, *, timeout_s: float, interval_s: float = 0.2) -> bool:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            if predicate():
                return True
        except Exception:
            pass
        time.sleep(interval_s)
    return False


def stage_shell(test_dir: str, plugin_dir: str, work_dir: str) -> str:
    """Mirror the whole pi-chat tree, then drop in our test shell.qml.

    QuickBarCompletion + PiChatBackend pull in qs.Commons / qs.Widgets and
    the PiSession family, so the entire plugin is staged the way the
    panel-width and quick-launch checks do."""
    shell_root = os.path.join(work_dir, "shell")
    shutil.copytree(plugin_dir, shell_root, dirs_exist_ok=True)
    for root, _dirs, files in os.walk(shell_root):
        os.chmod(root, 0o755)
        for f in files:
            try:
                os.chmod(os.path.join(root, f), 0o644)
            except OSError:
                pass
    shell_dst = os.path.join(shell_root, "shell.qml")
    if os.path.exists(shell_dst):
        os.remove(shell_dst)
    shutil.copy2(os.path.join(test_dir, "shell.qml"), shell_dst)
    now = time.time()
    for root, _dirs, files in os.walk(shell_root):
        for f in files:
            try:
                os.utime(os.path.join(root, f), (now, now))
            except OSError:
                pass
    return shell_root


def main() -> None:
    if len(sys.argv) != 5:
        fail("usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir>")
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]
    os.makedirs(work_dir, exist_ok=True)

    home = os.path.join(work_dir, "home")
    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    for d in (home, xdg_runtime):
        os.makedirs(d, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    env = os.environ.copy()
    env.update(
        {
            "HOME": home,
            "XDG_RUNTIME_DIR": xdg_runtime,
            "QT_QPA_PLATFORM": "offscreen",
            "QSG_RHI_BACKEND": "null",
            "LC_ALL": "C.UTF-8",
            "LANG": "C.UTF-8",
            "PYTHONUTF8": "1",
        }
    )

    qs_log = open(os.path.join(work_dir, "qs.log"), "w")
    qs_proc = subprocess.Popen(
        [qs_bin, "-p", shell_qml], env=env, stdout=qs_log, stderr=qs_log
    )

    def die(msg):
        p = os.path.join(work_dir, "qs.log")
        if os.path.isfile(p):
            sys.stderr.write("\n== qs.log ==\n")
            sys.stderr.write(open(p, errors="replace").read()[-6000:])
        fail(msg)

    def call(*args: str, check: bool = True) -> str:
        cmd = [qs_bin, "ipc", "-p", shell_qml, "call", TARGET, *args]
        out = subprocess.run(
            cmd, env=env, capture_output=True, text=True, encoding="utf-8", timeout=20
        )
        if check and out.returncode != 0:
            raise RuntimeError(
                f"ipc {args} failed (exit={out.returncode}):\n"
                f"stdout: {out.stdout!r}\nstderr: {out.stderr!r}"
            )
        return out.stdout.strip()

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

        def ipc_ready():
            r = subprocess.run(
                [qs_bin, "ipc", "-p", shell_qml, "show"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
            return r.returncode == 0 and TARGET in r.stdout

        if not wait_until(ipc_ready, timeout_s=30):
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

        # ── §4.2 row: bare "/" → directive-key menu, no mutation ──
        check("slash menu", cand("/"), ["/model:"])
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

        if failures:
            die("completion contract mismatches:\n  " + "\n  ".join(failures))

        print("PASS")
    finally:
        qs_proc.terminate()
        try:
            qs_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            qs_proc.kill()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Launch-bar grammar contract test.

Stages the real programs/pi-chat/BarParse.js next to a tiny shell.qml,
runs quickshell offscreen, and drives the pure `parse(text, cursor)`
helper over IPC (`test:bar-parse parse`). Each row of the grammar /
behaviour matrix from the launch-bar completion plan is asserted against
the JSON the parser returns. No pi worker, no LLM — the parser is pure.

Usage: driver.py <qs_bin> <bar_parse_js> <test_dir> <work_dir>
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time


def fail(msg: str) -> None:
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


def utf16_len(s: str) -> int:
    # QML's TextField.cursorPosition (and thus BarParse) counts UTF-16
    # code units, so the cursor argument must too — a Python code-point
    # len() would be off by one per astral character (e.g. an emoji).
    return len(s.encode("utf-16-le")) // 2


def wait_until(predicate, *, timeout_s: float, interval_s: float = 0.2):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            if predicate():
                return True
        except Exception:
            pass
        time.sleep(interval_s)
    return False


def stage_shell(test_dir: str, bar_parse_js: str, work_dir: str) -> str:
    """Drop BarParse.js next to the test shell.qml so the bare
    `import "BarParse.js"` resolves the same way it does in production."""
    shell_root = os.path.join(work_dir, "shell")
    os.makedirs(shell_root, exist_ok=True)
    shutil.copy2(bar_parse_js, os.path.join(shell_root, "BarParse.js"))
    shutil.copy2(
        os.path.join(test_dir, "shell.qml"), os.path.join(shell_root, "shell.qml")
    )
    return shell_root


def main() -> None:
    if len(sys.argv) != 5:
        fail("usage: driver.py <qs_bin> <bar_parse_js> <test_dir> <work_dir>")
    qs_bin, bar_parse_js, test_dir, work_dir = sys.argv[1:5]
    os.makedirs(work_dir, exist_ok=True)

    home = os.path.join(work_dir, "home")
    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    for d in (home, xdg_runtime):
        os.makedirs(d, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)

    shell_root = stage_shell(test_dir, bar_parse_js, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    env = os.environ.copy()
    env.update(
        {
            "HOME": home,
            "XDG_RUNTIME_DIR": xdg_runtime,
            "QT_QPA_PLATFORM": "offscreen",
            "QSG_RHI_BACKEND": "null",
            # UTF-8 argv decoding so the unicode-prompt row round-trips.
            "LC_ALL": "C.UTF-8",
            "LANG": "C.UTF-8",
            "PYTHONUTF8": "1",
        }
    )

    def parse(text: str, cursor: int):
        cmd = [
            qs_bin,
            "ipc",
            "-p",
            shell_qml,
            "call",
            "test:bar-parse",
            "parse",
            text,
            str(cursor),
        ]
        out = subprocess.run(
            cmd, env=env, capture_output=True, text=True, encoding="utf-8", timeout=20
        )
        if out.returncode != 0:
            raise RuntimeError(
                f"parse({text!r},{cursor}) ipc failed (exit={out.returncode}):\n"
                f"stdout: {out.stdout!r}\nstderr: {out.stderr!r}"
            )
        return json.loads(out.stdout.strip())

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
            return r.returncode == 0 and "test:bar-parse" in r.stdout

        if not wait_until(ipc_ready, timeout_s=30):
            die("quickshell never bound the test:bar-parse IPC target")

        # `/` + Tab opens the directive-key menu.
        r = parse("/", 1)
        check("slash kind", r["cursorToken"]["kind"], "slash")

        # `/m` is a key prefix being typed.
        r = parse("/m", 2)
        check("key kind", r["cursorToken"]["kind"], "key")
        check("key partial", r["cursorToken"]["partial"], "m")

        # `/model:` opens the value list — empty value, key known. The
        # caret resting on the colon itself (cursor==6) is already value-mode
        # with an empty partial, same as just after it (cursor==7).
        r = parse("/model:", 6)
        check("on-colon kind", r["cursorToken"]["kind"], "value")
        check("on-colon key", r["cursorToken"]["key"], "model")
        check("on-colon partial", r["cursorToken"]["partial"], "")
        r = parse("/model:", 7)
        check("empty-value kind", r["cursorToken"]["kind"], "value")
        check("empty-value key", r["cursorToken"]["key"], "model")
        check("empty-value partial", r["cursorToken"]["partial"], "")
        check("empty-value directive", r["directives"], {"model": ""})

        # `/model:g` — typing into the value.
        r = parse("/model:g", 8)
        check("value kind", r["cursorToken"]["kind"], "value")
        check("value key", r["cursorToken"]["key"], "model")
        check("value partial", r["cursorToken"]["partial"], "g")

        # The load-bearing split: the value keeps its own colon. The cursor
        # at the value's end stays value-mode (not prompt) so Tab still
        # completes it.
        r = parse("/model:gemma4:e4b", len("/model:gemma4:e4b"))
        check("split directive", r["directives"], {"model": "gemma4:e4b"})
        check("split prompt empty", r["prompt"], "")
        check("split end kind", r["cursorToken"]["kind"], "value")
        check("split end partial", r["cursorToken"]["partial"], "gemma4:e4b")

        # Directive followed by a free-form prompt; the cursor in the prompt
        # is prompt-mode even though a directive was parsed.
        t = "/model:gemma4:e4b summarize repo"
        r = parse(t, len(t))
        check("dir+prompt directive", r["directives"], {"model": "gemma4:e4b"})
        check("dir+prompt prompt", r["prompt"], "summarize repo")
        check("dir+prompt cursor", r["cursorToken"]["kind"], "prompt")

        # A trailing space pushes the cursor past the directive into the
        # (empty) prompt region, but the directive is still parsed.
        t = "/model:gemma "
        r = parse(t, len(t))
        check("trail-space directive", r["directives"], {"model": "gemma"})
        check("trail-space prompt", r["prompt"], "")
        check("trail-space cursor", r["cursorToken"]["kind"], "prompt")

        # Trailing-space form: one optional space after `:` is tolerated.
        t = "/model: gemma4:e4b x"
        r = parse(t, len(t))
        check("space-form directive", r["directives"], {"model": "gemma4:e4b"})
        check("space-form prompt", r["prompt"], "x")

        # Two leading directives: both resolve, prompt is the remainder, and
        # a cursor in the 2nd directive classifies against the 2nd key.
        t = "/a:1 /b:2 do it"
        r = parse(t, len(t))
        check("two-dir directives", r["directives"], {"a": "1", "b": "2"})
        check("two-dir prompt", r["prompt"], "do it")
        r2 = parse(t, 9)
        check("two-dir cursor kind", r2["cursorToken"]["kind"], "value")
        check("two-dir cursor key", r2["cursorToken"]["key"], "b")
        check("two-dir cursor partial", r2["cursorToken"]["partial"], "2")

        # Unknown key is still parsed structurally; validity is the UI's job.
        t = "/modle:foo bar"
        r = parse(t, len(t))
        check("unknown directive", r["directives"], {"modle": "foo"})
        check("unknown prompt", r["prompt"], "bar")

        # Duplicate directive: last wins.
        r = parse("/model:a /model:b", len("/model:a /model:b"))
        check("dup last-wins", r["directives"], {"model": "b"})

        # Bare `/verb` is a command, not a directive: never a prompt, never
        # a /key:value pair. Its kind while typing reflects a key.
        r = parse("/help", 5)
        check("command kind", r["cursorToken"]["kind"], "key")
        check("command partial", r["cursorToken"]["partial"], "help")
        check("command no prompt", r["prompt"], "")
        check("command no directives", r["directives"], {})

        # A non-leading `/` is plain prose — the whole input is the prompt.
        t = "fix the /path bug"
        r = parse(t, len(t))
        check("prose directives", r["directives"], {})
        check("prose prompt", r["prompt"], "fix the /path bug")

        # Empty input: empty prompt, no directives.
        r = parse("", 0)
        check("empty prompt", r["prompt"], "")
        check("empty directives", r["directives"], {})

        # Unicode prompt survives directive stripping verbatim, including a
        # non-BMP emoji (surrogate pair) — which also pins the UTF-16 cursor
        # convention: an off-by-one here would misclassify the token.
        t = "/model:gemma summarize café ☕ 😀"
        r = parse(t, utf16_len(t))
        check("unicode directive", r["directives"], {"model": "gemma"})
        check("unicode prompt", r["prompt"], "summarize café ☕ 😀")

        # Whitespace tolerance rules (load-bearing): a tab separates the
        # directive from the prompt just like a space; only ONE space after
        # `:` is absorbed, a second leaves an empty value + prose remainder.
        r = parse("/model:x\tsummarize", utf16_len("/model:x\tsummarize"))
        check("tab-sep directive", r["directives"], {"model": "x"})
        check("tab-sep prompt", r["prompt"], "summarize")
        r = parse("/model:  gemma", len("/model:  gemma"))
        check("two-space value", r["directives"], {"model": ""})
        check("two-space prompt", r["prompt"], "gemma")

        # Cursor mid-value reports the partial only up to the cursor, and
        # stays value-mode throughout; before the colon it is key-mode.
        v8 = parse("/model:gemma", 8)["cursorToken"]
        check("mid value@8 partial", v8["partial"], "g")
        check("mid value@8 kind", v8["kind"], "value")
        v10 = parse("/model:gemma", 10)["cursorToken"]
        check("mid value@10 partial", v10["partial"], "gem")
        check("mid value@10 kind", v10["kind"], "value")
        k3 = parse("/model:gemma", 3)["cursorToken"]
        check("mid key@3 partial", k3["partial"], "mo")
        check("mid key@3 kind", k3["kind"], "key")

        if failures:
            die("grammar matrix mismatches:\n  " + "\n  ".join(failures))

        print("PASS")
    finally:
        qs_proc.terminate()
        try:
            qs_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            qs_proc.kill()


if __name__ == "__main__":
    main()

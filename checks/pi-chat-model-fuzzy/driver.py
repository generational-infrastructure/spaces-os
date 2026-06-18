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
import shutil
import subprocess
import sys
import time


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
    shell_root = os.path.join(work_dir, "shell")
    os.makedirs(shell_root, exist_ok=True)
    shutil.copy2(
        os.path.join(test_dir, "shell.qml"), os.path.join(shell_root, "shell.qml")
    )
    # Stage the real Commons (Fuzzy/Style/Color/Settings singletons) and
    # Widgets (NComboBox/NTextInput/NText) so the test exercises the exact
    # components the panel ships, not a stand-in.
    for sub in ("Commons", "Widgets"):
        shutil.copytree(
            os.path.join(plugin_dir, sub),
            os.path.join(shell_root, sub),
            dirs_exist_ok=True,
        )
    now = time.time()
    for root, _dirs, files in os.walk(shell_root):
        for f in files:
            try:
                os.utime(os.path.join(root, f), (now, now))
            except OSError:
                pass
    return shell_root


def main() -> None:
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]

    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    os.makedirs(xdg_runtime, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    env = {
        "HOME": work_dir,
        "PATH": os.environ.get("PATH", "/bin:/usr/bin"),
        "XDG_RUNTIME_DIR": xdg_runtime,
        "QT_QPA_PLATFORM": "offscreen",
        "QT_PLUGIN_PATH": os.environ.get("QT_PLUGIN_PATH", ""),
        "QML2_IMPORT_PATH": os.environ.get("QML2_IMPORT_PATH", ""),
    }

    qs_stdout = open(os.path.join(work_dir, "qs.stdout.log"), "w")
    qs_stderr = open(os.path.join(work_dir, "qs.stderr.log"), "w")
    qs_proc = subprocess.Popen(
        [qs_bin, "-p", shell_qml],
        env=env,
        stdout=qs_stdout,
        stderr=qs_stderr,
    )

    def dump_logs():
        for label, name in [("qs.stdout", "qs.stdout.log"), ("qs.stderr", "qs.stderr.log")]:
            path = os.path.join(work_dir, name)
            if os.path.isfile(path):
                sys.stderr.write(f"\n== {label} ==\n")
                sys.stderr.write(open(path).read())

    def die(msg):
        dump_logs()
        fail(msg)

    def ipc(*args: str) -> str:
        cmd = [qs_bin, "ipc", "-p", shell_qml, "call", "test:fuzzy", *args]
        out = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=15)
        if out.returncode != 0:
            raise RuntimeError(
                f"qs ipc call {args} failed (exit={out.returncode}):\n"
                f"stdout: {out.stdout!r}\nstderr: {out.stderr!r}"
            )
        return out.stdout.strip()

    try:

        def ipc_ready():
            r = subprocess.run(
                [qs_bin, "ipc", "-p", shell_qml, "show"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
            return r.returncode == 0 and "test:fuzzy" in r.stdout

        if not wait_until(ipc_ready, timeout_s=20):
            die("quickshell never bound the test:fuzzy IPC target")

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
            die(f"clearing the query did not restore the full list: count={ipc('count')}")

        # ── 3. Accepting a filtered row selects it and restores the list ─
        ipc("setQuery", "claude")
        if not wait_until(lambda: keys() == ["openrouter/claude-3.5-sonnet"], timeout_s=5):
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

        sys.stderr.write("PASS: NComboBox fuzzy model search filters, matches by source tag, and accepts the top match\n")
    finally:
        qs_proc.terminate()
        try:
            qs_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            qs_proc.kill()


if __name__ == "__main__":
    main()

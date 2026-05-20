#!/usr/bin/env python3
"""Component test for the chat panel's thinking-visibility toggle.

Drives PiSession through a realistic thinking + text turn, then asks
the shared MsgFilter what the ListView would render under each toggle
state. Asserts that:

  - default (showThinking=true) renders every bubble
  - setShowThinking(false) drops thinking bubbles only
  - the underlying session.messages array is never mutated (the toggle
    is UI-only — flipping it back must restore the same bubbles, not
    replay them)
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


def wait_until(predicate, *, timeout_s: float, interval_s: float = 0.2):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval_s)
    return False


def stage_shell(test_dir: str, plugin_dir: str, work_dir: str) -> str:
    shell_root = os.path.join(work_dir, "shell")
    os.makedirs(shell_root, exist_ok=True)
    shutil.copy2(
        os.path.join(test_dir, "shell.qml"), os.path.join(shell_root, "shell.qml")
    )
    shutil.copytree(
        os.path.join(test_dir, "Commons"),
        os.path.join(shell_root, "Commons"),
        dirs_exist_ok=True,
    )
    for fname in ("PiSession.qml", "MsgFilter.js", "PluginSettings.js"):
        shutil.copy2(
            os.path.join(plugin_dir, fname),
            os.path.join(shell_root, fname),
        )
    now = time.time()
    for root, _dirs, files in os.walk(shell_root):
        for f in files:
            try:
                os.utime(os.path.join(root, f), (now, now))
            except OSError:
                pass
    return shell_root


def qs_ipc_call(qs_bin: str, shell_qml: str, env: dict, *args: str) -> str:
    cmd = [qs_bin, "ipc", "-p", shell_qml, "call", "test:thinking-toggle", *args]
    out = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=15)
    if out.returncode != 0:
        raise RuntimeError(
            f"qs ipc call {args} failed (exit={out.returncode}):\n"
            f"stdout: {out.stdout!r}\nstderr: {out.stderr!r}"
        )
    return out.stdout


def inject(qs_bin, shell_qml, env, event):
    qs_ipc_call(qs_bin, shell_qml, env, "injectEvent", json.dumps(event))


def messages(qs_bin, shell_qml, env, which: str):
    raw = qs_ipc_call(qs_bin, shell_qml, env, which)
    return json.loads(raw)


def set_show_thinking(qs_bin, shell_qml, env, value: bool):
    qs_ipc_call(qs_bin, shell_qml, env, "setShowThinking", "true" if value else "false")


def play_turn(qs_bin, shell_qml, env):
    """Inject a thinking + text turn — the production event sequence."""
    inject(qs_bin, shell_qml, env, {"type": "agent_start"})
    inject(
        qs_bin,
        shell_qml,
        env,
        {
            "type": "message_update",
            "assistantMessageEvent": {
                "type": "thinking_start",
                "contentIndex": 0,
            },
        },
    )
    inject(
        qs_bin,
        shell_qml,
        env,
        {
            "type": "message_update",
            "assistantMessageEvent": {
                "type": "thinking_delta",
                "contentIndex": 0,
                "delta": "Let me think about this.",
            },
        },
    )
    inject(
        qs_bin,
        shell_qml,
        env,
        {
            "type": "message_update",
            "assistantMessageEvent": {
                "type": "thinking_end",
                "contentIndex": 0,
                "content": "Let me think about this.",
            },
        },
    )
    inject(
        qs_bin,
        shell_qml,
        env,
        {
            "type": "message_update",
            "assistantMessageEvent": {"type": "text_start"},
        },
    )
    inject(
        qs_bin,
        shell_qml,
        env,
        {
            "type": "message_update",
            "assistantMessageEvent": {
                "type": "text_delta",
                "delta": "Here is the answer.",
            },
        },
    )
    inject(
        qs_bin,
        shell_qml,
        env,
        {
            "type": "message_update",
            "assistantMessageEvent": {
                "type": "text_end",
                "content": "Here is the answer.",
            },
        },
    )
    inject(qs_bin, shell_qml, env, {"type": "agent_end", "messages": []})


def main():
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]

    state_dir = os.path.join(work_dir, "state")
    agent_dir = os.path.join(state_dir, "pi-agent")
    workspace = os.path.join(work_dir, "workspace")
    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    for d in [state_dir, agent_dir, workspace, xdg_runtime]:
        os.makedirs(d, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)

    with open(os.path.join(agent_dir, "settings.json"), "w") as f:
        json.dump({"extensions": [], "skills": []}, f)

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    env = {
        "HOME": work_dir,
        "PATH": os.environ.get("PATH", "/bin:/usr/bin"),
        "XDG_RUNTIME_DIR": xdg_runtime,
        "QT_QPA_PLATFORM": "offscreen",
        "QT_PLUGIN_PATH": os.environ.get("QT_PLUGIN_PATH", ""),
        "QML2_IMPORT_PATH": os.environ.get("QML2_IMPORT_PATH", ""),
        "TEST_STATE_DIR": state_dir,
        "TEST_AGENT_DIR": agent_dir,
        "TEST_WORKSPACE": workspace,
    }

    qs_stdout = open(os.path.join(work_dir, "qs.stdout.log"), "w")
    qs_stderr = open(os.path.join(work_dir, "qs.stderr.log"), "w")
    qs_proc = subprocess.Popen(
        [qs_bin, "-p", shell_qml],
        env=env,
        stdout=qs_stdout,
        stderr=qs_stderr,
    )

    def cleanup():
        qs_proc.terminate()
        try:
            qs_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            qs_proc.kill()
            qs_proc.wait(timeout=5)
        for label, name in [
            ("qs.stdout", "qs.stdout.log"),
            ("qs.stderr", "qs.stderr.log"),
        ]:
            path = os.path.join(work_dir, name)
            if os.path.isfile(path):
                sys.stderr.write(f"\n== {label} ==\n")
                sys.stderr.write(open(path).read())

    try:

        def ipc_ready():
            r = subprocess.run(
                [qs_bin, "ipc", "-p", shell_qml, "show"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
            return r.returncode == 0 and "test:thinking-toggle" in r.stdout

        if not wait_until(ipc_ready, timeout_s=20):
            cleanup()
            fail("quickshell never bound the test:thinking-toggle IPC target")

        # Play one full turn so the session ends up with exactly the
        # bubble shape the panel renders in production.
        play_turn(qs_bin, shell_qml, env)

        raw = messages(qs_bin, shell_qml, env, "rawMessages")
        thinking = [m for m in raw if m.get("type") == "thinking"]
        text = [m for m in raw if m.get("type", "") == "" and m.get("from") == "peer"]
        if len(thinking) != 1:
            cleanup()
            fail(f"expected exactly 1 thinking bubble in raw, got {raw}")
        if len(text) != 1:
            cleanup()
            fail(f"expected exactly 1 text bubble in raw, got {raw}")

        # Default: showThinking=true → visible matches raw exactly.
        if not qs_ipc_call(qs_bin, shell_qml, env, "getShowThinking").startswith(
            "true"
        ):
            cleanup()
            fail("showThinking did not default to true")
        visible = messages(qs_bin, shell_qml, env, "visibleMessages")
        if visible != raw:
            cleanup()
            fail(f"default visible should mirror raw; visible={visible} raw={raw}")

        # Toggle off — thinking drops out, text stays.
        set_show_thinking(qs_bin, shell_qml, env, False)
        visible_off = messages(qs_bin, shell_qml, env, "visibleMessages")
        if any(m.get("type") == "thinking" for m in visible_off):
            cleanup()
            fail(f"thinking bubble still visible after toggle off: {visible_off}")
        if len(visible_off) != len(raw) - 1:
            cleanup()
            fail(
                f"toggle off removed wrong number of bubbles: "
                f"visible_off={visible_off} raw={raw}"
            )
        if not any(m.get("text") == "Here is the answer." for m in visible_off):
            cleanup()
            fail(f"text bubble missing after toggle off: {visible_off}")

        # Raw must be untouched — the toggle is purely a render filter.
        raw_after = messages(qs_bin, shell_qml, env, "rawMessages")
        if raw_after != raw:
            cleanup()
            fail(f"toggle mutated session.messages: before={raw} after={raw_after}")

        # Toggle back on — the same thinking bubble reappears in place.
        set_show_thinking(qs_bin, shell_qml, env, True)
        visible_on = messages(qs_bin, shell_qml, env, "visibleMessages")
        if visible_on != raw:
            cleanup()
            fail(
                f"toggle on did not restore raw history: "
                f"visible_on={visible_on} raw={raw}"
            )

        # ── PluginSettings wiring ────────────────────────────────────
        #
        # The MsgFilter section above proved the model filters
        # correctly for any given `showThinking`. This section proves
        # the toggle button can actually move that boolean against the
        # real noctalia plugin-API contract. The stub in shell.qml
        # mirrors the noctalia surface exactly — `pluginSettings`,
        # `manifest`, `saveSettings()` — and crucially does NOT expose
        # `setPluginSetting`, the method an earlier draft of the panel
        # reached for. Any helper that uses the wrong API will leave
        # the stub untouched and trip the assertions below.

        def stored():
            return json.loads(qs_ipc_call(qs_bin, shell_qml, env, "storedShowThinking"))

        def resolved():
            return qs_ipc_call(
                qs_bin, shell_qml, env, "resolvedShowThinking"
            ).startswith("true")

        def saves():
            return int(qs_ipc_call(qs_bin, shell_qml, env, "saveCalls").strip())

        # Pre-conditions: nothing stored yet, manifest default wins.
        if stored() is not None:
            cleanup()
            fail(f"expected no stored showThinking before any click, got {stored()!r}")
        if not resolved():
            cleanup()
            fail("manifest default should resolve showThinking=true before any click")
        if saves() != 0:
            cleanup()
            fail(f"expected 0 saveSettings calls before any click, got {saves()}")

        qs_ipc_call(qs_bin, shell_qml, env, "clickToggle")
        first_stored = stored()
        first_resolved = resolved()
        first_saves = saves()
        if first_stored is not False:
            cleanup()
            fail(
                f"clickToggle did not flip the stored showThinking; stored={first_stored!r}"
            )
        if first_resolved:
            cleanup()
            fail("resolved showThinking should be false after one click")
        if first_saves != 1:
            cleanup()
            fail(f"clickToggle did not call saveSettings; saveCalls={first_saves}")

        qs_ipc_call(qs_bin, shell_qml, env, "clickToggle")
        second_stored = stored()
        second_resolved = resolved()
        second_saves = saves()
        if second_stored is not True:
            cleanup()
            fail(
                f"second clickToggle did not flip back to true; "
                f"stored={second_stored!r}"
            )
        if not second_resolved:
            cleanup()
            fail("resolved showThinking should be true after two clicks")
        if second_saves != 2:
            cleanup()
            fail(
                f"second clickToggle did not call saveSettings; saveCalls={second_saves}"
            )

        print("OK")
    finally:
        cleanup()


if __name__ == "__main__":
    main()

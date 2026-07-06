#!/usr/bin/env python3
"""Event-fold contract test for programs/pi-chat/Reducer.js.

Replays the shared pi-event fixture corpus (fixtures/*.json — the same
streams checks/pi-web-reducer replays through packages/pi-web/reducer.ts)
through Reducer.apply inside headless quickshell and asserts:

  * the chat-side outcome each fixture pins under expect.chat — message
    records (partial match per listed key), flags, accumulated effects,
    pending confirm/approval registries,
  * the renderer-agnostic projection (expect.transcript / expect.confirms)
    both reducers must agree on — a divergence between the panel fold and
    the pi-web fold turns one of the two checks red,
  * every folded record still carries the full Msg.js base schema,
  * replay is pure (same stream twice -> byte-identical JSON),
  * importHistory prepends daemon history without touching live bubbles.

No pi worker, no LLM — the fold is pure.

Usage: driver.py <qs_bin> <reducer_js> <msg_js> <test_dir> <work_dir>
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time

BASE_FIELDS = {"id", "from", "text", "ts", "state", "image", "replyTo", "type"}


def fail(msg: str) -> None:
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


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


def stage_shell(test_dir: str, reducer_js: str, msg_js: str, work_dir: str) -> str:
    """Drop Reducer.js + Msg.js next to the test shell.qml so the module
    imports resolve the same way they do beside the production QML."""
    shell_root = os.path.join(work_dir, "shell")
    os.makedirs(shell_root, exist_ok=True)
    shutil.copy2(reducer_js, os.path.join(shell_root, "Reducer.js"))
    shutil.copy2(msg_js, os.path.join(shell_root, "Msg.js"))
    shutil.copy2(
        os.path.join(test_dir, "shell.qml"), os.path.join(shell_root, "shell.qml")
    )
    return shell_root


def project(messages: list[dict]) -> tuple[list[dict], list[dict]]:
    """The renderer-agnostic projection shared with checks/pi-web-reducer:
    plain chat text as (role, text, streaming) in order, plus confirm
    cards as (id, state)."""
    transcript = []
    confirms = []
    for m in messages:
        kind = m.get("type") or ""
        if kind == "":
            transcript.append(
                {
                    "role": "user" if m.get("from") == "me" else "assistant",
                    "text": m.get("text", ""),
                    "streaming": m.get("state") == "streaming",
                }
            )
        elif kind == "confirm":
            confirms.append({"id": m.get("id"), "state": m.get("confirmState")})
    return transcript, confirms


def main() -> None:
    if len(sys.argv) != 6:
        fail("usage: driver.py <qs_bin> <reducer_js> <msg_js> <test_dir> <work_dir>")
    qs_bin, reducer_js, msg_js, test_dir, work_dir = sys.argv[1:6]
    os.makedirs(work_dir, exist_ok=True)

    home = os.path.join(work_dir, "home")
    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    for d in (home, xdg_runtime):
        os.makedirs(d, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)

    shell_root = stage_shell(test_dir, reducer_js, msg_js, work_dir)
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

    def call(verb: str, payload) -> object:
        cmd = [
            qs_bin,
            "ipc",
            "-p",
            shell_qml,
            "call",
            "test:reducer",
            verb,
            json.dumps(payload),
        ]
        out = subprocess.run(
            cmd, env=env, capture_output=True, text=True, encoding="utf-8", timeout=20
        )
        if out.returncode != 0:
            raise RuntimeError(
                f"{verb} ipc failed (exit={out.returncode}):\n"
                f"stdout: {out.stdout!r}\nstderr: {out.stderr!r}"
            )
        got = json.loads(out.stdout.strip())
        if isinstance(got, dict) and "_error" in got:
            raise RuntimeError(f"{verb}: {got['_error']}")
        return got

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

    def check_partial(label: str, got: dict, want: dict):
        for k, v in want.items():
            if got.get(k) != v:
                failures.append(f"{label}.{k}: got {got.get(k)!r}, want {v!r}")

    def check_partial_list(label: str, got: list, want: list):
        if len(got) != len(want):
            failures.append(f"{label}: got {len(got)} entries, want {len(want)}: {got!r}")
            return
        for i, (g, w) in enumerate(zip(got, want)):
            check_partial(f"{label}[{i}]", g, w)

    try:

        def ipc_ready():
            r = subprocess.run(
                [qs_bin, "ipc", "-p", shell_qml, "show"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
            return r.returncode == 0 and "test:reducer" in r.stdout

        if not wait_until(ipc_ready, timeout_s=30):
            die("quickshell never bound the test:reducer IPC target")

        fixture_dir = os.path.join(test_dir, "fixtures")
        names = sorted(f for f in os.listdir(fixture_dir) if f.endswith(".json"))
        if not names:
            die("no fixtures found")

        for name in names:
            with open(os.path.join(fixture_dir, name)) as f:
                fx = json.load(f)
            label = name[: -len(".json")]
            got = call("replay", {"events": fx["events"]})
            state, effects = got["state"], got["effects"]
            msgs = state["messages"]

            # Msg.js base schema survives the fold on every record.
            for i, m in enumerate(msgs):
                missing = BASE_FIELDS - set(m)
                if missing:
                    failures.append(
                        f"{label}: messages[{i}] missing base fields {sorted(missing)}"
                    )

            # Shared projection — must match what pi-web-reducer asserts
            # for the same fixture.
            transcript, confirms = project(msgs)
            check(f"{label}.transcript", transcript, fx["expect"]["transcript"])
            check(f"{label}.confirms", confirms, fx["expect"].get("confirms", []))

            # Chat-side expectations.
            chat = fx["expect"].get("chat", {})
            for key in ("typing", "busy", "lastError"):
                if key in chat:
                    check(f"{label}.{key}", state.get(key), chat[key])
            if "messages" in chat:
                check_partial_list(f"{label}.messages", msgs, chat["messages"])
            if "effects" in chat:
                check_partial_list(f"{label}.effects", effects, chat["effects"])
            if "pendingExtensionUI" in chat:
                check(
                    f"{label}.pendingExtensionUI",
                    sorted(state.get("pendingExtensionUI", {})),
                    chat["pendingExtensionUI"],
                )
            if "pendingApprovals" in chat:
                check(
                    f"{label}.pendingApprovals",
                    sorted(state.get("pendingApprovals", {})),
                    chat["pendingApprovals"],
                )

            # Purity: the fold is stateless — an identical replay yields
            # an identical result. The only tolerated wobble is the
            # Math.random suffix in remote-mirror bubble ids (production
            # parity), so normalize those before comparing.
            def norm(obj):
                if isinstance(obj, dict):
                    return {
                        k: ("user-*" if k == "id" and str(v).startswith("user-") else norm(v))
                        for k, v in obj.items()
                    }
                if isinstance(obj, list):
                    return [norm(v) for v in obj]
                return obj

            again = call("replay", {"events": fx["events"]})
            check(f"{label}.pure-replay", norm(again), norm(got))

        # ── importHistory: daemon get_messages replay prepends history ──

        live = call("replay", {"events": [
            {"type": "message_start",
             "message": {"role": "user",
                         "content": [{"type": "text", "text": "live prompt"}]}},
        ]})["state"]
        hist = call("importHistory", {
            "state": live,
            "piMessages": [
                {"role": "user",
                 "content": [{"type": "text", "text": "old question"}],
                 "timestamp": 111},
                {"role": "assistant",
                 "content": [{"type": "text", "text": "old answer"}]},
                # tool-call-only content and malformed entries are skipped
                {"role": "assistant", "content": [{"type": "toolCall"}]},
                {"role": "user", "content": "not-a-list"},
            ],
        })
        texts = [(m["from"], m["text"]) for m in hist["messages"]]
        check("importHistory order", texts, [
            ("me", "old question"), ("peer", "old answer"), ("me", "live prompt"),
        ])
        check("importHistory ts", hist["messages"][0]["ts"], 111)
        # Empty import is an identity on messages.
        noop = call("importHistory", {"state": live, "piMessages": []})
        check("importHistory empty identity", noop["messages"], live["messages"])

        if failures:
            die("reducer mismatches:\n  " + "\n  ".join(failures))

        print(f"PASS ({len(names)} fixtures)")
    finally:
        qs_proc.terminate()
        try:
            qs_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            qs_proc.kill()


if __name__ == "__main__":
    main()

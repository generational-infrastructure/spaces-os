#!/usr/bin/env python3
"""Message-entry schema contract test.

Stages the pi-chat plugin tree (Msg.js at its root) next to a tiny
shell.qml, runs quickshell offscreen, and drives the pure module over
IPC (`test:msg call <fn> <argsJson>`). Asserts:

  * every constructor yields the full 8-field record
    ({id, from, text, ts, state, image, replyTo, type}),
  * the predicates discriminate the stringly type tags — including the
    empty-type plain-assistant case and legacy records with no `type`
    key at all,
  * the streaming patch helpers are pure (array in, new array out;
    identity when the target id is absent).

No pi worker, no LLM — the module is pure.

Usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir>
"""

from __future__ import annotations

import json
import os
import sys

from qs_harness import Quickshell, fail, qs_env, stage_shell

FIELDS = {"id", "from", "text", "ts", "state", "image", "replyTo", "type"}


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

    qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target="test:msg")

    def call(fn: str, *args):
        out = qs.ipc("call", fn, json.dumps({"args": list(args)}), timeout=20)
        got = json.loads(out)
        if isinstance(got, dict) and "_error" in got:
            raise RuntimeError(f"call({fn}): {got['_error']}")
        return got

    qs.start()

    def die(msg):
        qs.die(msg)

    failures: list[str] = []

    def check(label: str, got, want):
        if got != want:
            failures.append(f"{label}: got {got!r}, want {want!r}")

    def check_record(label: str, m: dict, want: dict):
        missing = FIELDS - set(m)
        if missing:
            failures.append(f"{label}: missing base fields {sorted(missing)} in {m!r}")
        for k, v in want.items():
            if m.get(k) != v:
                failures.append(f"{label}.{k}: got {m.get(k)!r}, want {v!r}")

    try:
        qs.wait_ipc_ready(timeout_s=30)

        # ── constructors: full 8-field record, kind-correct values ──

        user = call("user", "u1", "hi there", 123, "r9")
        check_record("user", user, {
            "id": "u1", "from": "me", "text": "hi there", "ts": 123,
            "state": "sent", "image": "", "replyTo": "r9", "type": "",
        })

        img = call("userImage", "u2", "/tmp/shot.png", 124, "")
        check_record("userImage", img, {
            "id": "u2", "from": "me", "text": "", "ts": 124,
            "state": "sent", "image": "/tmp/shot.png", "replyTo": "", "type": "",
        })

        asst = call("assistant", "a1", "answer", 125)
        check_record("assistant", asst, {
            "id": "a1", "from": "peer", "text": "answer", "ts": 125,
            "state": "sent", "replyTo": "", "type": "",
        })

        stream = call("assistantStream", "s1", 126)
        check_record("assistantStream", stream, {
            "id": "s1", "from": "peer", "text": "", "ts": 126,
            "state": "streaming", "type": "",
        })

        think = call("thinking", "t1", 127)
        check_record("thinking", think, {
            "id": "t1", "from": "peer", "text": "", "ts": 127,
            "state": "streaming", "type": "thinking",
        })

        notif = call("notification", "n1", "retrying (1): boom", 128)
        check_record("notification", notif, {
            "id": "n1", "from": "peer", "text": "retrying (1): boom",
            "ts": 128, "state": "sent", "type": "notification",
        })

        conf = call("confirm", "c1", "rm -rf /tmp/x", 129, "Run shell command?")
        check_record("confirm", conf, {
            "id": "c1", "from": "peer", "text": "rm -rf /tmp/x", "ts": 129,
            "state": "sent", "type": "confirm",
            "confirmTitle": "Run shell command?", "confirmState": "pending",
        })

        appr = call("approval", "ap1", 130, {
            "integration": "github", "tool": "github_create_issue",
            "args": "{\n  \"repo\": \"octo/repo\"\n}",
        })
        check_record("approval", appr, {
            "id": "ap1", "from": "peer", "text": "", "ts": 130,
            "state": "sent", "type": "approval",
            "approvalIntegration": "github",
            "approvalTool": "github_create_issue",
            "approvalState": "pending",
        })
        check("approval.args", "octo/repo" in appr.get("approvalArgs", ""), True)

        prompt = call("prompt", "p1", "Paste the API key", 131, {
            "instance": "sess-9", "skill": "google-cli", "profile": "default",
            "field": "api_key", "secret": True,
        })
        check_record("prompt", prompt, {
            "id": "p1", "from": "peer", "text": "Paste the API key", "ts": 131,
            "state": "sent", "type": "prompt",
            "promptInstance": "sess-9", "promptSkill": "google-cli",
            "promptProfile": "default", "promptField": "api_key",
            "promptSecret": True, "promptState": "pending",
        })
        # Missing meta fields default to the empty/false shape the UI binds.
        bare_prompt = call("prompt", "p2", "", 132, {})
        check_record("prompt bare", bare_prompt, {
            "promptInstance": "", "promptSkill": "", "promptProfile": "",
            "promptField": "", "promptSecret": False, "promptState": "pending",
        })

        # text omitted → the constructor owns the "" default (call sites
        # pass raw event values). ts has no default: every production
        # caller stamps its own clock.
        blank = call("notification", "n2", None, 132)
        check("null text defaults empty", blank.get("text"), "")

        # ── predicates ──

        kinds = {
            "plain user": user,
            "plain assistant": asst,
            "stream": stream,
            "thinking": think,
            "notification": notif,
            "confirm": conf,
            "approval": appr,
            "prompt": prompt,
        }
        table = {
            "isNotification": {"notification"},
            "isConfirm": {"confirm"},
            "isPrompt": {"prompt"},
            "isThinking": {"thinking"},
            "isApproval": {"approval"},
            "isPlain": {"plain user", "plain assistant", "stream"},
        }
        for pred, truthy in table.items():
            for label, m in kinds.items():
                check(f"{pred}({label})", call(pred, m), label in truthy)

        # Plain-assistant probe: peer + empty type. A user message and every
        # typed bubble must NOT match; a legacy record with no `type` key at
        # all (pre-schema messages, stub-backend fixtures) MUST match.
        check("isPlainAssistant(assistant)", call("isPlainAssistant", asst), True)
        check("isPlainAssistant(stream)", call("isPlainAssistant", stream), True)
        check("isPlainAssistant(user)", call("isPlainAssistant", user), False)
        for label in ("thinking", "notification", "confirm", "approval", "prompt"):
            check(f"isPlainAssistant({label})", call("isPlainAssistant", kinds[label]), False)
        legacy = {"id": "L", "from": "peer", "text": "old"}
        check("isPlainAssistant(legacy no-type)", call("isPlainAssistant", legacy), True)
        check("isPlain(legacy no-type)", call("isPlain", legacy), True)

        check("isMine(user)", call("isMine", user), True)
        check("isMine(assistant)", call("isMine", asst), False)

        # Pending-prompt gate (backend retract loops).
        check("isPendingPrompt(fresh)", call("isPendingPrompt", prompt), True)
        submitted = dict(prompt, promptState="submitted")
        check("isPendingPrompt(submitted)", call("isPendingPrompt", submitted), False)
        nostate = {k: v for k, v in prompt.items() if k != "promptState"}
        check("isPendingPrompt(state absent → pending)", call("isPendingPrompt", nostate), True)
        check("isPendingPrompt(non-prompt)", call("isPendingPrompt", notif), False)

        # ── visibility filter (the old MsgFilter.visible) ──

        msgs = [asst, think, user, legacy]
        check("visible hides thinking", call("visible", msgs, False), [asst, user, legacy])
        check("visible shows all", call("visible", msgs, True), msgs)
        check("visible empty", call("visible", [], False), [])

        # ── patch helpers: pure, identity on missing id ──

        arr = [stream, user]
        patched = call("patch", arr, "s1", {"state": "sent", "tps": 42})
        check("patch state", patched[0]["state"], "sent")
        check("patch extra", patched[0]["tps"], 42)
        check("patch untouched sibling", patched[1], user)
        check("patch missing id identity", call("patch", arr, "nope", {"state": "x"}), arr)

        grown = call("appendDelta", arr, "s1", "hel")
        grown = call("appendDelta", grown, "s1", "lo")
        check("appendDelta concatenates", grown[0]["text"], "hello")
        check("appendDelta missing id identity", call("appendDelta", arr, "nope", "x"), arr)

        fin = call("finalizeStream", grown, "s1", "hello world")
        check("finalize content wins", fin[0]["text"], "hello world")
        check("finalize state", fin[0]["state"], "sent")
        fin2 = call("finalizeStream", grown, "s1", "")
        check("finalize keeps streamed text", fin2[0]["text"], "hello")
        check("finalize keeps state sent", fin2[0]["state"], "sent")

        dropped = call("remove", arr, "s1")
        check("remove drops", dropped, [user])
        check("remove missing id identity", call("remove", arr, "nope"), arr)

        if failures:
            die("msg schema mismatches:\n  " + "\n  ".join(failures))

        print("PASS")
    finally:
        qs.stop()


if __name__ == "__main__":
    main()

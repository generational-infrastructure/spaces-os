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

Usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir>
"""

from __future__ import annotations

import json
import os
import sys

from qs_harness import Quickshell, fail, qs_env, stage_shell

BASE_FIELDS = {"id", "from", "text", "ts", "state", "image", "replyTo", "type"}


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

    qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target="test:reducer")

    def call(verb: str, payload) -> object:
        out = qs.ipc(verb, json.dumps(payload), timeout=20)
        got = json.loads(out)
        if isinstance(got, dict) and "_error" in got:
            raise RuntimeError(f"{verb}: {got['_error']}")
        return got

    qs.start()

    def die(msg):
        qs.die(msg)

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
            failures.append(
                f"{label}: got {len(got)} entries, want {len(want)}: {got!r}"
            )
            return
        for i, (g, w) in enumerate(zip(got, want)):
            check_partial(f"{label}[{i}]", g, w)

    try:
        qs.wait_ipc_ready(timeout_s=30)

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
                        k: (
                            "user-*"
                            if k == "id" and str(v).startswith("user-")
                            else norm(v)
                        )
                        for k, v in obj.items()
                    }
                if isinstance(obj, list):
                    return [norm(v) for v in obj]
                return obj

            again = call("replay", {"events": fx["events"]})
            check(f"{label}.pure-replay", norm(again), norm(got))

        # ── importHistory: daemon get_messages replay prepends history ──

        live = call(
            "replay",
            {
                "events": [
                    {
                        "type": "message_start",
                        "message": {
                            "role": "user",
                            "content": [{"type": "text", "text": "live prompt"}],
                        },
                    },
                ]
            },
        )["state"]
        hist = call(
            "importHistory",
            {
                "state": live,
                "piMessages": [
                    {
                        "role": "user",
                        "content": [{"type": "text", "text": "old question"}],
                        "timestamp": 111,
                    },
                    {
                        "role": "assistant",
                        "content": [{"type": "text", "text": "old answer"}],
                    },
                    # tool-call-only content and malformed entries are skipped
                    {"role": "assistant", "content": [{"type": "toolCall"}]},
                    {"role": "user", "content": "not-a-list"},
                ],
            },
        )
        texts = [(m["from"], m["text"]) for m in hist["messages"]]
        check(
            "importHistory order",
            texts,
            [
                ("me", "old question"),
                ("peer", "old answer"),
                ("me", "live prompt"),
            ],
        )
        check("importHistory ts", hist["messages"][0]["ts"], 111)
        # Empty import is an identity on messages.
        noop = call("importHistory", {"state": live, "piMessages": []})
        check("importHistory empty identity", noop["messages"], live["messages"])
        # ── importHistory: re-import over retained bubbles is identity ──
        # A panel that kept its bubbles across an idle stop (window
        # closed → session reaped → reopened) re-attaches and replays
        # get_messages; the history is already on screen and must not
        # be prepended a second time.

        turn = [
            {
                "type": "message_start",
                "message": {
                    "role": "user",
                    "content": [{"type": "text", "text": "old question"}],
                },
            },
            {"type": "agent_start"},
            {"type": "message_update", "assistantMessageEvent": {"type": "text_start"}},
            {
                "type": "message_update",
                "assistantMessageEvent": {"type": "text_delta", "delta": "old answer"},
            },
            {
                "type": "message_update",
                "assistantMessageEvent": {"type": "text_end", "content": "old answer"},
            },
            {"type": "agent_end"},
        ]
        turn_hist = [
            {
                "role": "user",
                "content": [{"type": "text", "text": "old question"}],
                "timestamp": 111,
            },
            {"role": "assistant", "content": [{"type": "text", "text": "old answer"}]},
        ]
        retained = call("replay", {"events": turn})["state"]
        reimport = call("importHistory", {"state": retained, "piMessages": turn_hist})
        check(
            "importHistory reattach identity",
            reimport["messages"],
            retained["messages"],
        )

        # Same, with the assistant message split across two text blocks:
        # the live fold renders one bubble per block while the history
        # payload joins the blocks into one entry. The projections must
        # still be recognized as the same conversation.
        split = call(
            "replay",
            {
                "events": [
                    turn[0],
                    {"type": "agent_start"},
                    {
                        "type": "message_update",
                        "assistantMessageEvent": {"type": "text_start"},
                    },
                    {
                        "type": "message_update",
                        "assistantMessageEvent": {
                            "type": "text_end",
                            "content": "part one",
                        },
                    },
                    {
                        "type": "message_update",
                        "assistantMessageEvent": {"type": "text_start"},
                    },
                    {
                        "type": "message_update",
                        "assistantMessageEvent": {
                            "type": "text_end",
                            "content": "part two",
                        },
                    },
                    {"type": "agent_end"},
                ]
            },
        )["state"]
        split_hist = [
            turn_hist[0],
            {
                "role": "assistant",
                "content": [
                    {"type": "text", "text": "part one"},
                    {"type": "text", "text": "part two"},
                ],
            },
        ]
        split_re = call("importHistory", {"state": split, "piMessages": split_hist})
        check(
            "importHistory split-bubble identity",
            split_re["messages"],
            split["messages"],
        )

        # Retained conversation plus a fresh optimistic prompt sent
        # before the get_messages response landed: history is a prefix
        # of what's shown — still nothing to prepend.
        retained_plus = call(
            "replay",
            {
                "events": turn
                + [
                    {
                        "type": "message_start",
                        "message": {
                            "role": "user",
                            "content": [{"type": "text", "text": "follow-up"}],
                        },
                    },
                ]
            },
        )["state"]
        plus_re = call(
            "importHistory", {"state": retained_plus, "piMessages": turn_hist}
        )
        check(
            "importHistory prefix identity",
            plus_re["messages"],
            retained_plus["messages"],
        )

        if failures:
            die("reducer mismatches:\n  " + "\n  ".join(failures))

        print(f"PASS ({len(names)} fixtures)")
    finally:
        qs.stop()


if __name__ == "__main__":
    main()

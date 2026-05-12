#!/usr/bin/env python3
"""
Drive a two-turn conversation through opencrow's chat socket and verify
the full noctalia plugin → opencrow (socket) → pi → reply round trip.

Turn 1: greet, expect any non-empty reply.
Turn 2: ask "What color is the sky?", expect a reply containing "blue".

Usage: test-opencrow-chat.py <socket_path> [mode]

`mode` is "local" (default) or "openrouter". In openrouter mode the
llama-swap-specific model assertions are skipped — the active model is
the one configured via `services.opencrow-local.defaultModel`, and the
visible model list is whatever OpenRouter reports.
"""

import json
import socket
import sys
import time

sock_path = sys.argv[1]
mode = sys.argv[2] if len(sys.argv) > 2 else "local"

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
for _ in range(50):
    try:
        s.connect(sock_path)
        break
    except OSError:
        time.sleep(0.2)
else:
    sys.exit("could not connect to chat socket")

# Drain status/history events with a fresh replay.
s.sendall(json.dumps({"cmd": "replay", "n": 50}).encode() + b"\n")
s.settimeout(120)


def send_and_wait(text, predicate, timeout=120):
    """Send `text`, then wait for the next inbound reply matching `predicate`.

    opencrow batches concurrent messages, so each turn must complete before
    the next is sent.
    """
    s.sendall(json.dumps({"cmd": "send", "text": text}).encode() + b"\n")
    buf = bytearray()
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            chunk = s.recv(4096)
        except socket.timeout:
            break
        if not chunk:
            break
        buf.extend(chunk)
        while b"\n" in buf:
            nl = buf.index(b"\n")
            line = bytes(buf[:nl])
            del buf[: nl + 1]
            ev = json.loads(line)
            print(f"EVENT: {ev}", file=sys.stderr)
            msg = ev.get("msg") or {}
            if ev.get("kind") != "msg" or msg.get("dir") != "in":
                continue
            content = msg.get("content", "")
            print(f"BOT REPLY: {content}", file=sys.stderr)
            if predicate(content):
                return content
            sys.exit(f"reply failed predicate: {content!r}")
    sys.exit(f"timed out waiting for reply to {text!r}")


reply1 = send_and_wait("Hello bot", lambda c: bool(c.strip()))
print(f"TURN 1 OK: {reply1}")

reply2 = send_and_wait(
    "What color is the sky? Answer in one word.",
    lambda c: "blue" in c.lower(),
)
print(f"TURN 2 OK: {reply2}")


def request_models(timeout=30):
    """Send list-models, wait for the 'models' event, and return the list."""
    s.sendall(json.dumps({"cmd": "list-models"}).encode() + b"\n")
    buf = bytearray()
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            chunk = s.recv(4096)
        except socket.timeout:
            break
        if not chunk:
            break
        buf.extend(chunk)
        while b"\n" in buf:
            nl = buf.index(b"\n")
            line = bytes(buf[:nl])
            del buf[: nl + 1]
            ev = json.loads(line)
            if ev.get("kind") == "models":
                return ev.get("models") or []
            if ev.get("kind") == "error":
                sys.exit(f"models request failed: {ev.get('text')}")
    sys.exit("timed out waiting for models event")


models = request_models()
print(f"MODELS: {models}", file=sys.stderr)
assert isinstance(models, list), f"models must be a list, got {type(models)}"
ids = [m["id"] for m in models]
if mode == "openrouter":
    assert ids, "model list is empty in openrouter mode"
    active = [m for m in models if m.get("active")]
    assert len(active) == 1, f"exactly one model must be active, got {active}"
    print(
        f"MODEL LIST OK (openrouter): {len(models)} model(s), active={active[0]['id']}"
    )
else:
    assert "qwen2.5:0.5b" in ids, f"qwen2.5:0.5b not in {ids}"
    assert "smollm" in ids, f"smollm not in {ids}"
    active = [m for m in models if m.get("active")]
    assert len(active) == 1, f"exactly one model must be active, got {active}"
    assert active[0]["id"] == "qwen2.5:0.5b", (
        f"default model expected to be active, got {active[0]}"
    )
    print(f"MODEL LIST OK: {len(models)} model(s), active={active[0]['id']}")

s.close()
print("SUCCESS")

#!/usr/bin/env python3
"""Round-trip test for the OpenUrlListener component.

Spins up an offscreen quickshell with shell.qml (which mounts the real
OpenUrlListener pointing at a temp socket), then exercises the socket
the way `google-cli` would inside the pi sandbox: write one JSON line
per URL.

Cases covered:
  * Valid https URL  → listener calls openUrlSink → witness file updated.
  * file://… scheme → listener rejects → witness file untouched.
  * bad JSON line   → listener logs + skips → witness file untouched.
"""

from __future__ import annotations

import json
import os
import socket
import sys
import time
from pathlib import Path

from qs_harness import Quickshell, qs_env, stage_shell, wait_until

QUICKSHELL = sys.argv[1]
TEST_DIR = sys.argv[2]  # checks/pi-session-open-url/
PLUGIN_DIR = sys.argv[3]  # programs/pi-chat/
WORK = Path(sys.argv[4])

shell_root = stage_shell(TEST_DIR, PLUGIN_DIR, str(WORK))
shell_qml = os.path.join(shell_root, "shell.qml")

sock = WORK / "open-url.sock"
witness = WORK / "witness.log"
witness.write_text("")

env = qs_env(
    str(WORK),
    extra={
        "TEST_OPEN_URL_SOCK": str(sock),
        "TEST_WITNESS_FILE": str(witness),
    },
)

qs = Quickshell(QUICKSHELL, shell_qml, env, str(WORK))
qs.start()


def fail(msg: str) -> None:
    qs.stop()
    qs.die(msg)


def wait_for_socket(timeout: float = 10.0) -> None:
    def ready() -> bool:
        if sock.exists():
            return True
        if qs.proc.poll() is not None:
            fail(f"quickshell exited early with code {qs.proc.returncode}")
        return False

    if not wait_until(ready, timeout_s=timeout, interval_s=0.05):
        fail(f"socket {sock} never appeared")


def send_line(payload: str) -> None:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(2.0)
        s.connect(str(sock))
        s.sendall((payload + "\n").encode())


wait_for_socket()

# Valid URL.
send_line(json.dumps({"url": "https://example.com/auth?x=1"}))
if not wait_until(
    lambda: "https://example.com/auth?x=1" in witness.read_text(),
    timeout_s=5.0,
    interval_s=0.05,
):
    fail(f"witness missing https URL; contents={witness.read_text()!r}")

# Bad scheme should be rejected.
send_line(json.dumps({"url": "file:///etc/passwd"}))
# Bad JSON should be skipped.
send_line("not-json {{{")

# Give the listener a beat to (not) process the rejected lines, then
# send another legitimate URL — if rejected ones leaked through, they
# would land in the witness file BEFORE the next legit URL.
time.sleep(0.3)
send_line(json.dumps({"url": "https://example.com/second"}))
if not wait_until(
    lambda: "https://example.com/second" in witness.read_text(),
    timeout_s=5.0,
    interval_s=0.05,
):
    fail(f"witness missing second URL; contents={witness.read_text()!r}")

content = witness.read_text()
if "file:///etc/passwd" in content:
    fail("rejected file:// URL leaked through to the sink")
if "not-json" in content:
    fail("malformed JSON leaked through to the sink")

qs.stop()
print("PASS")

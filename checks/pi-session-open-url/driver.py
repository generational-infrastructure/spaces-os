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
import subprocess
import sys
import tempfile
import time
from pathlib import Path

QUICKSHELL = sys.argv[1]
TEST_DIR = sys.argv[2]   # checks/pi-session-open-url/
PLUGIN_DIR = sys.argv[3]  # programs/pi-chat-plugin/
WORK = Path(sys.argv[4])

shell_qml = WORK / "shell" / "shell.qml"
shell_qml.parent.mkdir(parents=True, exist_ok=True)
# quickshell's `import qs` resolves to the *parent* of shell.qml, so we
# stage shell.qml inside a dir that also contains the OpenUrlListener.
# Copy plugin files alongside so the relative import works.
shell_qml.write_text(Path(TEST_DIR, "shell.qml").read_text())
for name in ("OpenUrlListener.qml",):
    (shell_qml.parent / name).write_text(Path(PLUGIN_DIR, name).read_text())
# Stub the qs.Commons.Logger import used by OpenUrlListener.
commons_dir = shell_qml.parent / "Commons"
commons_dir.mkdir(exist_ok=True)
(commons_dir / "qmldir").write_text("module qs.Commons\nsingleton Logger 1.0 Logger.qml\n")
(commons_dir / "Logger.qml").write_text(
    'import QtQuick\n'
    'pragma Singleton\n'
    'QtObject {\n'
    '  function i() {}\n'
    '  function w() {}\n'
    '}\n'
)

sock = WORK / "open-url.sock"
witness = WORK / "witness.log"
witness.write_text("")

env = dict(os.environ)
env["TEST_OPEN_URL_SOCK"] = str(sock)
env["TEST_WITNESS_FILE"] = str(witness)
env["QT_QPA_PLATFORM"] = "offscreen"
env["XDG_RUNTIME_DIR"] = str(WORK / "xdg")
Path(env["XDG_RUNTIME_DIR"]).mkdir(parents=True, exist_ok=True)
os.chmod(env["XDG_RUNTIME_DIR"], 0o700)

proc = subprocess.Popen(
    [QUICKSHELL, "-p", str(shell_qml)],
    env=env,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
)


def stop_shell() -> None:
    try:
        proc.terminate()
        proc.wait(timeout=5)
    except Exception:
        proc.kill()


def fail(msg: str) -> None:
    stop_shell()
    out = proc.stdout.read().decode(errors="replace") if proc.stdout else ""
    print(out)
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def wait_for_socket(timeout: float = 10.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if sock.exists():
            return
        if proc.poll() is not None:
            fail(f"quickshell exited early with code {proc.returncode}")
        time.sleep(0.05)
    fail(f"socket {sock} never appeared")


def send_line(payload: str) -> None:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(2.0)
        s.connect(str(sock))
        s.sendall((payload + "\n").encode())


def wait_until(predicate, timeout: float = 5.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return False


wait_for_socket()

# Valid URL.
send_line(json.dumps({"url": "https://example.com/auth?x=1"}))
if not wait_until(lambda: "https://example.com/auth?x=1" in witness.read_text()):
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
if not wait_until(lambda: "https://example.com/second" in witness.read_text()):
    fail(f"witness missing second URL; contents={witness.read_text()!r}")

content = witness.read_text()
if "file:///etc/passwd" in content:
    fail("rejected file:// URL leaked through to the sink")
if "not-json" in content:
    fail("malformed JSON leaked through to the sink")

stop_shell()
print("PASS")

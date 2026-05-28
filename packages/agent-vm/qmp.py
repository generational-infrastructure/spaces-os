"""Tiny QMP client for the agent-vm wrapper.

Subcommands:
  key <chord>           — `send-key`; chord is dash-separated, e.g.
                          alt-a, ctrl-alt-t, shift-space
  screenshot <path>     — `screendump` PNG to <path>

The QMP socket path comes from $AGENT_VM_QMP (default
/tmp/agent-vm-qmp.sock — matches the path baked into vm-debug.nix's
headless qemu options).
"""

import json
import os
import pathlib
import socket
import sys

QMP_PATH = os.environ.get("AGENT_VM_QMP", "/tmp/agent-vm-qmp.sock")

# Human-friendly key tokens that don't match the QEMU QKeyCode name
# verbatim. Anything not in here passes through unchanged (a, b, …, z,
# 0-9, f1-f12, tab, esc, …).
ALIASES = {
    "altgr": "alt_r",
    "super": "meta_l",
    "win": "meta_l",
    "meta": "meta_l",
    "enter": "ret",
    "return": "ret",
    "space": "spc",
    "del": "delete",
    "ins": "insert",
    "pgup": "pgup",
    "pgdn": "pgdn",
}


def qcode(token: str) -> str:
    t = token.lower()
    return ALIASES.get(t, t)


def qmp_exchange(commands):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(QMP_PATH)
    f = s.makefile("rw", buffering=1, encoding="utf-8", newline="\n")

    def recv():
        while True:
            line = f.readline()
            if not line:
                raise RuntimeError("qmp socket closed")
            msg = json.loads(line)
            if "return" in msg or "error" in msg:
                return msg
            # ignore async events (POWERDOWN, RESET, …)

    # banner + capability negotiation
    f.readline()
    f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n")
    f.flush()
    recv()

    out = []
    for cmd in commands:
        f.write(json.dumps(cmd) + "\n")
        f.flush()
        out.append(recv())
    return out


def cmd_key(args):
    if not args:
        sys.exit("agent-vm key: missing chord (e.g. alt-a)")
    keys = [{"type": "qcode", "data": qcode(tok)} for tok in args[0].split("-")]
    [resp] = qmp_exchange(
        [
            {
                "execute": "send-key",
                "arguments": {"keys": keys, "hold-time": 200},
            }
        ]
    )
    if "error" in resp:
        sys.exit("agent-vm key: " + resp["error"]["desc"])


def cmd_screenshot(args):
    if not args:
        sys.exit("agent-vm screenshot: missing output path")
    out = pathlib.Path(args[0]).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    [resp] = qmp_exchange(
        [
            {
                "execute": "screendump",
                "arguments": {"filename": str(out), "format": "png"},
            }
        ]
    )
    if "error" in resp:
        sys.exit("agent-vm screenshot: " + resp["error"]["desc"])
    print(out)


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: qmp.py key|screenshot ...")
    cmd, *args = sys.argv[1:]
    if cmd == "key":
        cmd_key(args)
    elif cmd == "screenshot":
        cmd_screenshot(args)
    else:
        sys.exit(f"unknown qmp subcommand: {cmd}")


if __name__ == "__main__":
    main()

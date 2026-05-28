"""Tiny QMP client for the agent-vm wrapper.

Subcommands:
  key <chord>           — `send-key`; chord is dash-separated, e.g.
                          alt-a, ctrl-alt-t, shift-space
  screenshot <path>     — `screendump` PNG to <path>
  move <x> <y>          — warp the absolute pointer to pixel (x, y)
  click <x> <y> [btn]   — move, then press+release a button at (x, y)
                          (btn: left (default), right, middle)

Pixel coordinates address the framebuffer the guest is currently
driving; they are scaled into QEMU's 0..0x7fff abs-axis range using
the live resolution read from a throwaway `screendump`. Clicking
needs an absolute pointing device on the guest — the headless
test-machine wires `-device usb-tablet`, so libinput/niri see a
normal absolute pointer.

The QMP socket path comes from $AGENT_VM_QMP (default
/tmp/agent-vm-qmp.sock — matches the path baked into vm-debug.nix's
headless qemu options).
"""

import json
import os
import pathlib
import socket
import struct
import sys
import time

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
    _run(
        [{"execute": "send-key", "arguments": {"keys": keys, "hold-time": 200}}],
        "key",
    )


PNG_SIG = b"\x89PNG\r\n\x1a\n"
PNG_END = b"IEND\xaeB`\x82"
ABS_MAX = 0x7FFF
BUTTONS = ("left", "right", "middle")


def _screendump(path, ctx="screenshot"):
    """Dump the primary head to `path` and block until it is a full PNG.

    QEMU's `screendump` runs in a coroutine and the QMP reply can land
    before the file is fully flushed, so a naive immediate read sees a
    truncated (or empty) file. Poll until the bytes start with the PNG
    signature and end with the IEND chunk.
    """
    _run(
        [
            {
                "execute": "screendump",
                "arguments": {"filename": str(path), "format": "png"},
            }
        ],
        ctx,
    )
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        try:
            data = pathlib.Path(path).read_bytes()
        except FileNotFoundError:
            data = b""
        if len(data) >= 24 and data[:8] == PNG_SIG and data[-8:] == PNG_END:
            return data
        time.sleep(0.05)
    sys.exit(f"agent-vm {ctx}: {path} never completed as a PNG")


def cmd_screenshot(args):
    if not args:
        sys.exit("agent-vm screenshot: missing output path")
    out = pathlib.Path(args[0]).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    _screendump(out)
    print(out)


def _framebuffer_size():
    """(width, height) of the primary head, via a throwaway screendump.

    QEMU has no portable "query resolution" command, so we dump a PNG
    and read its IHDR. Pixel→abs scaling needs the live mode, which
    niri picks for the virtual display and can change between boots.

    The scratch file lives beside the QMP socket, NOT in /tmp: QEMU may
    run under a private-tmp sandbox (e.g. launched from a systemd/pueue
    service), so its /tmp differs from ours — but the socket directory
    is a path both ends already share.
    """
    scratch = pathlib.Path(QMP_PATH).parent / f".fbsize-{os.getpid()}.png"
    try:
        data = _screendump(scratch, "pointer")
    finally:
        scratch.unlink(missing_ok=True)
    width, height = struct.unpack(">II", data[16:24])
    return width, height


def _abs_events(px, py):
    width, height = _framebuffer_size()
    if not (0 <= px < width and 0 <= py < height):
        sys.exit(f"agent-vm pointer: ({px},{py}) outside {width}x{height}")
    # usb-tablet axes span 0..0x7fff; map the last pixel to the max.
    ax = round(px * ABS_MAX / (width - 1))
    ay = round(py * ABS_MAX / (height - 1))
    return [
        {"type": "abs", "data": {"axis": "x", "value": ax}},
        {"type": "abs", "data": {"axis": "y", "value": ay}},
    ]


def _input_cmd(events):
    return {"execute": "input-send-event", "arguments": {"events": events}}


def _btn(button, down):
    return _input_cmd([{"type": "btn", "data": {"down": down, "button": button}}])


def _run(commands, ctx="pointer"):
    """Send QMP commands in order; exit on the first error.

    Returns each command's `return` payload, so callers that need the
    result (query-mice, …) and callers that only care about success
    share one error path. `ctx` tags the failure message, e.g.
    "agent-vm key: …".
    """
    payloads = []
    for resp in qmp_exchange(commands):
        if "error" in resp:
            sys.exit(f"agent-vm {ctx}: {resp['error']['desc']}")
        payloads.append(resp.get("return"))
    return payloads


def _select_tablet():
    """Make the absolute USB tablet the current QEMU mouse.

    input-send-event is routed to whichever pointer QEMU considers
    "current". On the test-machine that defaults to the paravirtual
    vmmouse, which niri/libinput never bind under Wayland, so abs/btn
    events sent there vanish silently. The `-device usb-tablet`
    (reported as "QEMU HID Tablet", absolute) is the pointer the guest
    actually drives, so steer events to it via the `mouse_set` monitor
    command. Idempotent and cheap; run it before every pointer op so a
    fresh wrapper invocation never assumes prior state.
    """
    [mice] = _run([{"execute": "query-mice"}])
    tablet = next(
        (m for m in mice if m.get("absolute") and "Tablet" in m["name"]),
        None,
    )
    if tablet is None:
        sys.exit("agent-vm pointer: no absolute tablet found in query-mice")
    _run(
        [
            {
                "execute": "human-monitor-command",
                "arguments": {"command-line": f"mouse_set {tablet['index']}"},
            }
        ]
    )


def _xy(args, verb):
    if len(args) < 2:
        sys.exit(f"agent-vm {verb}: need <x> <y> in pixels")
    try:
        return int(args[0]), int(args[1])
    except ValueError:
        sys.exit(f"agent-vm {verb}: x and y must be integers")


def cmd_move(args):
    px, py = _xy(args, "move")
    _select_tablet()
    _run([_input_cmd(_abs_events(px, py))])


def cmd_click(args):
    px, py = _xy(args, "click")
    button = args[2] if len(args) > 2 else "left"
    if button not in BUTTONS:
        sys.exit("agent-vm click: button must be one of " + ", ".join(BUTTONS))
    motion = _abs_events(px, py)
    _select_tablet()
    _run(
        [
            _input_cmd(motion),
            _btn(button, True),
            _btn(button, False),
        ]
    )


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: qmp.py key|screenshot|move|click ...")
    cmd, *args = sys.argv[1:]
    handlers = {
        "key": cmd_key,
        "screenshot": cmd_screenshot,
        "move": cmd_move,
        "click": cmd_click,
    }
    handler = handlers.get(cmd)
    if handler is None:
        sys.exit(f"unknown qmp subcommand: {cmd}")
    handler(args)


if __name__ == "__main__":
    main()

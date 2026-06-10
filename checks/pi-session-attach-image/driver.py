#!/usr/bin/env python3
"""Attach-image contract test — end-to-end over WS against the REAL pi-sessiond.

PiSession has no local pi-spawn path anymore; it only talks to pi-sessiond
executors over WebSocket. So this check runs the real PiChatBackend in a
headless quickshell with one executor injected via $SPACES_PI_CHAT_EXECUTORS,
pointed at a real pi-sessiond (bun, embedded pi SDK) whose llama-swap is a
recording mock LLM, and drives `sendFile(<image_path>)` — the entry point the
paperclip button and drag-and-drop both call.

What this test guarantees:

  - handing PiSession an image path **immediately** produces a local
    "from: me" bubble carrying the image path. The user has to see the
    thing they just attached, before any daemon roundtrip. (The original
    regression: `_readImage` only sent the prompt — no local bubble, so
    pressing "attach" showed nothing.)

  - the attachment actually reaches the model: the panel base64-encodes
    the file (`file -b --mime-type` + `base64 -w0` in a one-shot Process —
    both binaries must be on PATH), ships it inside the WS `prompt`
    command as `images: [{type:"image", data, mimeType}]`, pi-sessiond
    forwards that verbatim to the SDK's prompt options, and pi posts a
    multimodal /v1/chat/completions request. Asserted on the stable part:
    the tiny PNG's exact base64 payload appears in the recorded request
    body (however pi shapes the content block around it).

Token plumbing mirrors production: the daemon reads its token from
$CREDENTIALS_DIRECTORY/token (LoadCredential), the panel-side executor entry
carries a `tokenPath` to the same file.

Usage: driver.py <qs_bin> <daemon_bin> <systemd_run_stub> <test_dir>
       <plugin_dir> <work_dir>
"""

import base64
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import time
import zlib

TOKEN = "attach-image-secret"


# 1×1 transparent PNG, constructed inline so the test stays hermetic.
def _tiny_png_bytes() -> bytes:
    sig = b"\x89PNG\r\n\x1a\n"

    def chunk(tag: bytes, payload: bytes) -> bytes:
        crc = zlib.crc32(tag + payload)
        return struct.pack(">I", len(payload)) + tag + payload + struct.pack(">I", crc)

    ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)  # 1×1, 8-bit RGBA
    idat = zlib.compress(b"\x00\x00\x00\x00\x00")  # one scanline of zeroes
    return sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")


def fail(msg: str) -> None:
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def wait_until(predicate, *, timeout_s: float, interval_s: float = 0.2):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            v = predicate()
            if v:
                return v
        except Exception:
            pass
        time.sleep(interval_s)
    return None


def wait_for_port(port: int, *, timeout_s: float) -> bool:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                return True
        except OSError:
            time.sleep(0.1)
    return False


def stage_shell(test_dir: str, plugin_dir: str, work_dir: str) -> str:
    """Stage the whole plugin tree (PiChatBackend pulls in PiExecutor /
    PiSession / qs.Commons / qs.Widgets) with our shell.qml on top, fresh
    mtimes so qmlcache can't pin stale bytecode keyed off /nix/store."""
    shell_root = os.path.join(work_dir, "shell")
    shutil.copytree(plugin_dir, shell_root, dirs_exist_ok=True)
    for root, _dirs, files in os.walk(shell_root):
        os.chmod(root, 0o755)
        for f in files:
            try:
                os.chmod(os.path.join(root, f), 0o644)
            except OSError:
                pass
    shell_dst = os.path.join(shell_root, "shell.qml")
    if os.path.exists(shell_dst):
        os.remove(shell_dst)
    shutil.copy2(os.path.join(test_dir, "shell.qml"), shell_dst)
    now = time.time()
    for root, _dirs, files in os.walk(shell_root):
        for f in files:
            try:
                os.utime(os.path.join(root, f), (now, now))
            except OSError:
                pass
    return os.path.join(shell_root, "shell.qml")


def main() -> None:
    if len(sys.argv) != 7:
        fail(
            "usage: driver.py <qs_bin> <daemon_bin> <systemd_run_stub> "
            "<test_dir> <plugin_dir> <work_dir>"
        )
    qs_bin, daemon_bin, stub, test_dir, plugin_dir, work_dir = sys.argv[1:7]
    os.makedirs(work_dir, exist_ok=True)

    home = os.path.join(work_dir, "home")
    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    state_dir = os.path.join(work_dir, "sessiond-state")
    cred_dir = os.path.join(work_dir, "creds")
    for d in (home, xdg_runtime, state_dir, cred_dir):
        os.makedirs(d, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)

    # Token file shared by both ends: the daemon loads it via
    # $CREDENTIALS_DIRECTORY/token, the executor entry points its tokenPath
    # here. Trailing newline checks the panel trims the read.
    token_path = os.path.join(cred_dir, "token")
    with open(token_path, "w") as fh:
        fh.write(TOKEN + "\n")
    os.chmod(token_path, 0o600)

    # The test image + the exact base64 the panel-side `base64 -w0` must
    # produce; the LLM-request assertion greps for this payload.
    png = _tiny_png_bytes()
    image_path = os.path.join(work_dir, "test.png")
    with open(image_path, "wb") as fh:
        fh.write(png)
    expected_b64 = base64.b64encode(png).decode()

    shell_qml = stage_shell(test_dir, plugin_dir, work_dir)

    # ── mock LLM (records every completion request body) ──────────────────
    llm_port = free_port()
    capture_path = os.path.join(work_dir, "llm-requests.jsonl")
    llm_log = open(os.path.join(work_dir, "mock-llm.log"), "w")
    llm_proc = subprocess.Popen(
        [
            sys.executable,
            os.path.join(test_dir, "mock-llm.py"),
            str(llm_port),
            capture_path,
        ],
        stdout=llm_log,
        stderr=subprocess.STDOUT,
    )

    # ── real pi-sessiond ───────────────────────────────────────────────────
    ws_port = free_port()
    daemon_env = os.environ.copy()
    daemon_env.update(
        {
            "HOME": state_dir,
            "SPACES_SESSIOND_HOST": "127.0.0.1",
            "SPACES_SESSIOND_PORT": str(ws_port),
            "CREDENTIALS_DIRECTORY": cred_dir,
            "SPACES_SESSIOND_STATE_DIR": state_dir,
            "SPACES_SESSIOND_DEFAULT_MODEL": "mock-model",
            "SPACES_SESSIOND_SYSTEMD_RUN": stub,
            "SPACES_SESSIOND_IDLE_TIMEOUT_MS": "0",  # no idle-GC mid-test
            "LLAMA_SWAP_BASE_URL": f"http://127.0.0.1:{llm_port}",
        }
    )
    daemon_log = open(os.path.join(work_dir, "daemon.log"), "w")
    daemon = subprocess.Popen(
        [daemon_bin], env=daemon_env, stdout=daemon_log, stderr=subprocess.STDOUT
    )

    # ── headless quickshell hosting the real backend ───────────────────────
    env = os.environ.copy()
    env.update(
        {
            "HOME": home,
            "XDG_RUNTIME_DIR": xdg_runtime,
            "QT_QPA_PLATFORM": "offscreen",
            "QSG_RHI_BACKEND": "null",
            # The executor topology, as the panel's test seam takes it. The
            # tokenPath (not an inline token) proves the file-read plumbing.
            "SPACES_PI_CHAT_EXECUTORS": json.dumps(
                [
                    {
                        "id": "local",
                        "url": f"ws://127.0.0.1:{ws_port}",
                        "tokenPath": token_path,
                    }
                ]
            ),
        }
    )

    qs_proc = None

    def dump_logs():
        for name in ("qs.log", "daemon.log", "mock-llm.log"):
            p = os.path.join(work_dir, name)
            if os.path.isfile(p):
                sys.stderr.write(f"\n== {name} ==\n")
                sys.stderr.write(open(p, errors="replace").read()[-8000:])
        if os.path.isfile(capture_path):
            sys.stderr.write("\n== llm-requests.jsonl (truncated) ==\n")
            sys.stderr.write(open(capture_path, errors="replace").read()[:4000])

    def die(msg):
        dump_logs()
        fail(msg)

    def ipc(*args):
        r = subprocess.run(
            [qs_bin, "ipc", "-p", shell_qml, "call", "test:pi-session", *args],
            env=env,
            capture_output=True,
            text=True,
            timeout=20,
        )
        if r.returncode != 0:
            raise RuntimeError(f"ipc {args} failed (exit={r.returncode}): {r.stderr!r}")
        return r.stdout.strip()

    def ipc_ready():
        r = subprocess.run(
            [qs_bin, "ipc", "-p", shell_qml, "show"],
            env=env,
            capture_output=True,
            text=True,
            timeout=5,
        )
        return r.returncode == 0 and "test:pi-session" in r.stdout

    try:
        # Mock LLM first: the daemon discovers models from /v1/models at boot.
        if not wait_for_port(llm_port, timeout_s=15):
            die(f"mock LLM never listened on {llm_port} (exit={llm_proc.poll()})")
        # bun + SDK import make the daemon the slowest riser here.
        if not wait_for_port(ws_port, timeout_s=60):
            die(f"pi-sessiond never listened on {ws_port} (exit={daemon.poll()})")

        qs_log = open(os.path.join(work_dir, "qs.log"), "w")
        qs_proc = subprocess.Popen(
            [qs_bin, "-p", shell_qml], env=env, stdout=qs_log, stderr=qs_log
        )

        if not wait_until(ipc_ready, timeout_s=30):
            die("quickshell never bound the test:pi-session IPC target")

        # hello/welcome with the token-file content — tokenPath end-to-end.
        if not wait_until(
            lambda: ipc("executorConnected", "local") == "true", timeout_s=30
        ):
            die("panel never connected/authenticated against pi-sessiond")

        sid = ipc("newSessionOn", "AttachImage", "local")
        if not sid:
            die("newSessionOn returned no id")

        # ── the contract under test ────────────────────────────────────────
        ipc("sendFile", sid, image_path)

        # (1) The picker just closed; the user must see their attachment
        # immediately — the local bubble precedes the (async) base64 encode
        # and the whole daemon roundtrip.
        def user_image_bubbles():
            msgs = json.loads(ipc("messages", sid))
            return [
                m
                for m in msgs
                if isinstance(m, dict)
                and m.get("from") == "me"
                and m.get("image") == image_path
            ] or None

        bubbles = wait_until(user_image_bubbles, timeout_s=10)
        if not bubbles:
            die(
                f"expected a local user bubble with image={image_path!r} after "
                f"sendFile, got messages={ipc('messages', sid)!r}"
            )
        # A state-machine bug that leaves our message "queued" forever would
        # still satisfy the bubble check but break the panel's send affordance.
        bubble = bubbles[0]
        if bubble.get("state") not in ("sent", "delivered", "streaming"):
            die(f"user image bubble has unexpected state: {bubble!r}")

        # (2) The multimodal payload reaches the LLM: panel encodes ->
        # WS prompt {images:[{type:"image", data, mimeType}]} -> daemon
        # forwards verbatim to the SDK -> pi posts /v1/chat/completions.
        # Assert on the stable part — the exact base64 of the PNG — rather
        # than the content-block shape pi wraps around it.
        def capture_has_image():
            if not os.path.isfile(capture_path):
                return False
            return expected_b64 in open(capture_path, errors="replace").read()

        if not wait_until(capture_has_image, timeout_s=120, interval_s=0.5):
            die(
                "mock LLM never received a completion request carrying the "
                "attached PNG's base64 payload"
            )

        # The reply streamed by the mock should also round-trip back into the
        # chat — proves the session stayed attached through the image turn.
        def got_reply():
            msgs = json.loads(ipc("messages", sid))
            return any(
                isinstance(m, dict)
                and m.get("from") != "me"
                and "I can see the image." in (m.get("text") or "")
                for m in msgs
            )

        if not wait_until(got_reply, timeout_s=60):
            die("assistant reply never streamed back into the session")

        print("PASS: local bubble + base64 PNG in the recorded LLM request")
    finally:
        if qs_proc:
            qs_proc.terminate()
            try:
                qs_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                qs_proc.kill()
        for p in (daemon, llm_proc):
            p.terminate()
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()


if __name__ == "__main__":
    main()

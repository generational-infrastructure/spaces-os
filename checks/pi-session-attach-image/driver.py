#!/usr/bin/env python3
"""Attach-image contract test — end-to-end over WS against the REAL pi-sessiond.

PiSession has no local pi-spawn path anymore; it only talks to pi-sessiond
executors over WebSocket. So this check runs the real PiChatBackend in a
headless quickshell with one executor injected via $SPACES_PI_CHAT_EXECUTORS,
pointed at a real pi-sessiond (bun supervisor) whose recording mock LLM stands
in for llama-swap, and drives `sendFile(<image_path>)` — the entry point the
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
    command as `images: [{type:"image", data, mimeType}]`, the supervisor
    forwards that array verbatim over the rpc pipe to the per-session
    `pi --mode rpc` child, and pi posts a multimodal /v1/chat/completions
    request. Asserted on the stable part: the tiny PNG's exact base64 payload
    appears in the recorded request body (however pi shapes the content block
    around it). The assertion is on the LLM-facing bytes, so this drives the
    REAL pi child (SPACES_SESSIOND_PI_BIN = the daemon package's `pi`
    passthru), never a stub.

Token plumbing mirrors production: the daemon reads its token from
$CREDENTIALS_DIRECTORY/token (LoadCredential), the panel-side executor entry
carries a `tokenPath` to the same file.

Usage: driver.py <qs_bin> <daemon_bin> <pi_bin> <discover_ext> <test_dir>
       <plugin_dir> <work_dir>
"""

import base64
import json
import os
import struct
import sys
import zlib

from qs_harness import (
    Quickshell,
    fail,
    free_port,
    qs_env,
    reap,
    spawn,
    stage_shell,
    wait_for_port,
    wait_until,
)

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


def main() -> None:
    if len(sys.argv) != 9:
        fail(
            "usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir> "
            "<daemon_bin> <pi_bin> <discover_ext> <systemd_run>"
        )
    (
        qs_bin,
        test_dir,
        plugin_dir,
        work_dir,
        daemon_bin,
        pi_bin,
        discover_ext,
        systemd_run,
    ) = sys.argv[1:9]
    os.makedirs(work_dir, exist_ok=True)

    state_dir = os.path.join(work_dir, "sessiond-state")
    cred_dir = os.path.join(work_dir, "creds")
    for d in (state_dir, cred_dir):
        os.makedirs(d, exist_ok=True)

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

    shell_qml = os.path.join(stage_shell(test_dir, plugin_dir, work_dir), "shell.qml")

    # pi child settings (staged into the daemon's agent dir via
    # SPACES_SESSIOND_PI_SETTINGS): the supervisor no longer embeds pi or does
    # its own discovery for the child, so the child must register the `local`
    # provider itself. llama-swap-discover hits ${LLAMA_SWAP_BASE_URL}/v1/models
    # (the recording mock) and registers `mock-model` under provider `local`,
    # which the child resolves from the create_session default.
    settings_path = os.path.join(work_dir, "pi-settings.json")
    with open(settings_path, "w") as fh:
        json.dump(
            {
                "extensions": [discover_ext],
                "defaultProvider": "local",
                "defaultModel": "mock-model",
                "quietStartup": True,
                "enableInstallTelemetry": False,
            },
            fh,
        )

    # ── mock LLM (records every completion request body) ──────────────────
    llm_port = free_port()
    capture_path = os.path.join(work_dir, "llm-requests.jsonl")
    llm_proc = spawn(
        [
            sys.executable,
            os.path.join(test_dir, "mock-llm.py"),
            str(llm_port),
            capture_path,
        ],
        work_dir,
        "mock-llm.log",
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
            # The supervisor spawns this REAL pi build per session in rpc-mode;
            # the child reads settings.json (→ llama-swap-discover) from the
            # agent dir staged from this template.
            "SPACES_SESSIOND_PI_BIN": pi_bin,
            "SPACES_SESSIOND_PI_SETTINGS": settings_path,
            # No systemd in the build sandbox: point the daemon's per-session
            # confinement wrapper at the passthrough stub (strips the unit
            # flags, re-applies --setenv, execs the real pi child).
            "SPACES_SESSIOND_SYSTEMD_RUN": systemd_run,
            "SPACES_SESSIOND_IDLE_TIMEOUT_MS": "0",  # no idle-GC mid-test
            # Inherited by the child: point its discover extension at the mock
            # and keep pi off the network for telemetry/update probes.
            "LLAMA_SWAP_BASE_URL": f"http://127.0.0.1:{llm_port}",
            "PI_OFFLINE": "1",
            "PI_TELEMETRY": "0",
        }
    )
    daemon = spawn([daemon_bin], work_dir, "daemon.log", env=daemon_env)

    # ── headless quickshell hosting the real backend ───────────────────────
    env = qs_env(
        work_dir,
        extra={
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
        },
    )

    qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target="test:pi-session")

    def dump_logs():
        qs.dump_logs(extra=("daemon.log", "mock-llm.log"))
        if os.path.isfile(capture_path):
            sys.stderr.write("\n== llm-requests.jsonl (truncated) ==\n")
            sys.stderr.write(open(capture_path, errors="replace").read()[:4000])

    def die(msg):
        dump_logs()
        fail(msg)

    def ipc(*args):
        return qs.ipc(*args, timeout=20)

    try:
        # Mock LLM first: the daemon discovers models from /v1/models at boot.
        if not wait_for_port(llm_port, timeout_s=15):
            die(f"mock LLM never listened on {llm_port} (exit={llm_proc.poll()})")
        # bun + SDK import make the daemon the slowest riser here.
        if not wait_for_port(ws_port, timeout_s=60):
            die(f"pi-sessiond never listened on {ws_port} (exit={daemon.poll()})")

        qs.start()

        if not wait_until(qs.ipc_ready, timeout_s=30):
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

        if not wait_until(user_image_bubbles, timeout_s=10):
            die(
                f"expected a local user bubble with image={image_path!r} after "
                f"sendFile, got messages={ipc('messages', sid)!r}"
            )
        bubbles = user_image_bubbles()
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
        qs.stop()
        reap(daemon, llm_proc)


if __name__ == "__main__":
    main()

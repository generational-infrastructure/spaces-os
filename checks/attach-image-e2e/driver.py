#!/usr/bin/env python3
"""End-to-end attach-image contract for the chat plugin.

We mount PiSession.qml directly inside a small test shell, bypass the
noctalia plugin host and the pi-chat NixOS module, and exercise the
`sendFile(image_path)` IPC entry that the paperclip button and drag-
and-drop both end up calling.

What this test guarantees:

  - clicking the picker (or any IPC caller) and handing PiSession an
    image path **immediately** produces a local "from: me" message
    bubble that carries the image path. The user has to see the thing
    they just attached, without waiting for a roundtrip to pi.

  - the same path lands at pi over the RPC channel as a `{type:
    "prompt", images: [{type: "image", data, mimeType}]}` payload and
    pi processes it (we wait for `agent_end` via the streaming mock).

The first guarantee is the regression we're catching: until today,
`_readImage` only called `_send(...)` and `typing = true` — no local
bubble was appended, so the user pressed "attach" and saw nothing.
"""

import json
import os
import shutil
import struct
import subprocess
import sys
import time
import zlib


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


def start_mock_llm(mock_script: str, work_dir: str):
    log = open(os.path.join(work_dir, "mock-llm.log"), "w")
    proc = subprocess.Popen(
        [sys.executable, mock_script],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=log,
    )
    line = proc.stdout.readline()
    if not line:
        fail("mock LLM did not print its URL")
    return proc, line.decode().strip()


def stage_shell(test_dir: str, plugin_dir: str, work_dir: str) -> str:
    """Lay out a fresh shell.qml + Commons stub + PiSession copy under
    work_dir/shell. We copy rather than symlink so Qt's qmlcache can't
    pin stale bytecode keyed off /nix/store mtimes."""
    shell_root = os.path.join(work_dir, "shell")
    os.makedirs(shell_root, exist_ok=True)
    shutil.copy2(
        os.path.join(test_dir, "shell.qml"), os.path.join(shell_root, "shell.qml")
    )
    shutil.copytree(
        os.path.join(test_dir, "Commons"),
        os.path.join(shell_root, "Commons"),
        dirs_exist_ok=True,
    )
    shutil.copy2(
        os.path.join(plugin_dir, "PiSession.qml"),
        os.path.join(shell_root, "PiSession.qml"),
    )
    now = time.time()
    for root, _dirs, files in os.walk(shell_root):
        for f in files:
            try:
                os.utime(os.path.join(root, f), (now, now))
            except PermissionError:
                pass
    return shell_root


def stage_systemd_run_stub(test_dir: str, work_dir: str) -> str:
    bin_dir = os.path.join(work_dir, "bin")
    os.makedirs(bin_dir, exist_ok=True)
    dst = os.path.join(bin_dir, "systemd-run")
    shutil.copy2(os.path.join(test_dir, "systemd-run-stub"), dst)
    os.chmod(dst, 0o755)
    return bin_dir


def qs_ipc_call(qs_bin: str, shell_qml: str, env: dict, *args: str) -> str:
    cmd = [
        qs_bin,
        "ipc",
        "-p",
        shell_qml,
        "call",
        "test:pi-session",
        *args,
    ]
    out = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=15)
    if out.returncode != 0:
        raise RuntimeError(
            f"qs ipc call {args} failed (exit={out.returncode}):\n"
            f"stdout: {out.stdout!r}\nstderr: {out.stderr!r}"
        )
    return out.stdout


def wait_until(predicate, *, timeout_s: float, interval_s: float = 0.2):
    deadline = time.monotonic() + timeout_s
    last_err = None
    while time.monotonic() < deadline:
        try:
            value = predicate()
            if value:
                return value
        except Exception as e:  # noqa: BLE001
            last_err = e
        time.sleep(interval_s)
    if last_err:
        raise last_err
    return None


def main() -> None:
    if len(sys.argv) != 8:
        fail(
            "usage: driver.py <pi_bin> <qs_bin> <mock_llm_script> <ext_dir> "
            "<test_dir> <plugin_dir> <work_dir>"
        )
    (
        pi_bin,
        qs_bin,
        mock_script,
        ext_dir,
        test_dir,
        plugin_dir,
        work_dir,
    ) = sys.argv[1:8]
    os.makedirs(work_dir, exist_ok=True)

    # Filesystem layout under work_dir.
    home = os.path.join(work_dir, "home")
    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    agent_dir = os.path.join(work_dir, "agent")
    state_dir = os.path.join(work_dir, "state")
    session_dir = os.path.join(state_dir, "sessions", "test")
    workspace = os.path.join(work_dir, "workspace")
    for d in (home, xdg_runtime, agent_dir, state_dir, session_dir, workspace):
        os.makedirs(d, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")
    bin_dir = stage_systemd_run_stub(test_dir, work_dir)

    # Pi agent config: same shape as the NixOS module writes, minus the
    # extensions we don't exercise here (we only care that pi accepts a
    # multimodal prompt and replies).
    with open(os.path.join(agent_dir, "settings.json"), "w") as fh:
        json.dump(
            {
                "extensions": [os.path.join(ext_dir, "llama-swap-discover.ts")],
                "defaultProvider": "local",
                "defaultModel": "mock-model",
                "quietStartup": True,
                "enableInstallTelemetry": False,
            },
            fh,
        )

    # Write the test image.
    image_path = os.path.join(work_dir, "test.png")
    with open(image_path, "wb") as fh:
        fh.write(_tiny_png_bytes())

    # Boot the mock LLM first so the QML side can spawn pi against a
    # live OpenAI endpoint.
    mock_proc, mock_url = start_mock_llm(mock_script, work_dir)

    # Environment for quickshell + child pi.
    env = os.environ.copy()
    env.update(
        {
            "HOME": home,
            "XDG_RUNTIME_DIR": xdg_runtime,
            "PATH": bin_dir + os.pathsep + env.get("PATH", ""),
            "QT_QPA_PLATFORM": "offscreen",
            "QSG_RHI_BACKEND": "null",  # don't try to allocate a GPU surface
            "TEST_PI_BIN": pi_bin,
            "TEST_STATE_DIR": state_dir,
            "TEST_AGENT_DIR": agent_dir,
            "TEST_WORKSPACE": workspace,
            "TEST_LLM_URL": mock_url,
            "PI_CODING_AGENT_DIR": agent_dir,
            "LLAMA_SWAP_BASE_URL": mock_url,
            "PI_OFFLINE": "1",
            "PI_TELEMETRY": "0",
        }
    )

    qs_stdout = open(os.path.join(work_dir, "qs.stdout.log"), "w")
    qs_stderr = open(os.path.join(work_dir, "qs.stderr.log"), "w")
    # Run qs with merged stdout/stderr so we capture QML load errors.
    qs_proc = subprocess.Popen(
        [qs_bin, "-p", shell_qml],
        env=env,
        stdout=qs_stdout,
        stderr=qs_stderr,
    )

    def cleanup_logs():
        try:
            qs_stdout.flush()
            qs_stderr.flush()
            sys.stderr.write("\n== qs.stdout.log ==\n")
            with open(os.path.join(work_dir, "qs.stdout.log")) as fh:
                sys.stderr.write(fh.read())
            sys.stderr.write("\n== qs.stderr.log ==\n")
            with open(os.path.join(work_dir, "qs.stderr.log")) as fh:
                sys.stderr.write(fh.read())
            # Dump quickshell's own binary log (qslog) — this contains
            # QML compilation errors that don't surface on stdout/stderr.
            qs_log_root = os.path.join(xdg_runtime, "quickshell")
            for dirpath, _, filenames in os.walk(qs_log_root):
                for fn in filenames:
                    fp = os.path.join(dirpath, fn)
                    sys.stderr.write(f"\n== {fp} ==\n")
                    try:
                        with open(fp, errors="replace") as lf:
                            sys.stderr.write(lf.read()[-4000:])
                    except Exception:
                        sys.stderr.write("<unreadable>\n")
            sys.stderr.write("\n== mock-llm.log ==\n")
            with open(os.path.join(work_dir, "mock-llm.log")) as fh:
                sys.stderr.write(fh.read())
            rc = qs_proc.poll()
            if rc is not None:
                sys.stderr.write(f"\n== quickshell exited with code {rc} ==\n")
        except Exception as e:
            sys.stderr.write(f"(cleanup_logs error: {e})\n")

    try:
        # Wait for the IPC handler to register. `qs ipc show` returns a
        # non-zero exit until quickshell finishes loading the shell.
        def ipc_ready():
            r = subprocess.run(
                [qs_bin, "ipc", "-p", shell_qml, "show"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
            if r.returncode != 0:
                sys.stderr.write(
                    f"[ipc_ready] exit={r.returncode} stderr={r.stderr!r}\n"
                )
                return False
            return "test:pi-session" in r.stdout

        if not wait_until(ipc_ready, timeout_s=20):
            cleanup_logs()
            fail("quickshell never bound the test:pi-session IPC target")

        # Drive the actual contract under test.
        qs_ipc_call(qs_bin, shell_qml, env, "sendFile", image_path)

        # The picker just closed; the user must see their attachment.
        # Poll briefly for the local bubble.
        def has_user_image_bubble():
            raw = qs_ipc_call(qs_bin, shell_qml, env, "messages")
            try:
                msgs = json.loads(raw)
            except Exception:
                return False
            for m in msgs:
                if (
                    isinstance(m, dict)
                    and m.get("from") == "me"
                    and m.get("image") == image_path
                ):
                    return True
            return False

        try:
            wait_until(has_user_image_bubble, timeout_s=10)
        except Exception:
            pass

        # Final read so we get a stable snapshot for the assertion message.
        raw = qs_ipc_call(qs_bin, shell_qml, env, "messages")
        msgs = json.loads(raw)
        user_bubbles = [
            m
            for m in msgs
            if isinstance(m, dict)
            and m.get("from") == "me"
            and m.get("image") == image_path
        ]
        if not user_bubbles:
            cleanup_logs()
            fail(
                "expected a local user bubble with image="
                f"{image_path!r} after sendFile, got messages={msgs!r}"
            )

        # Sanity-check the rest of the bubble: a state-machine bug that
        # marks our message as "queued" forever would still satisfy the
        # bubble check above but break the panel's send affordance.
        bubble = user_bubbles[0]
        if bubble.get("state") not in ("sent", "delivered", "streaming"):
            cleanup_logs()
            fail(f"user image bubble has unexpected state: {bubble!r}")

        print("OK")
    finally:
        qs_proc.terminate()
        try:
            qs_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            qs_proc.kill()
        mock_proc.terminate()
        try:
            mock_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            mock_proc.kill()


if __name__ == "__main__":
    main()

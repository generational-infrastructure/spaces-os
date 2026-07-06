#!/usr/bin/env python3
"""NdjsonSocket contract test.

Drives the shared unix-socket adapter through both client modes against
in-process python socket fixtures:

  subscribe — hello line written on connect, line-buffered JSON
              delivery, bad-line rejection, send(), reconnect with
              backoff after the listener vanishes, and backoff reset
              after a successful reconnect;
  request   — one-shot connect -> send -> single JSON reply -> close,
              malformed reply, reply timeout, close-without-reply.

No pi process, no LLM, no compositor. ~5-10s.
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
import time


def fail(msg: str) -> None:
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


def wait_until(predicate, *, timeout_s: float, interval_s: float = 0.05):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            if predicate():
                return True
        except Exception:
            pass
        time.sleep(interval_s)
    return False


def read_line(conn: socket.socket, timeout_s: float = 10.0) -> str:
    """Read one \\n-terminated line off a unix socket."""
    conn.settimeout(timeout_s)
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = conn.recv(4096)
        if not chunk:
            raise RuntimeError(f"peer closed mid-line, buffer={buf!r}")
        buf += chunk
    return buf.decode().rstrip("\n")


def stage_shell(test_dir: str, plugin_dir: str, work_dir: str) -> str:
    shell_root = os.path.join(work_dir, "shell")
    os.makedirs(shell_root, exist_ok=True)
    shutil.copy2(
        os.path.join(test_dir, "shell.qml"),
        os.path.join(shell_root, "shell.qml"),
    )
    shutil.copy2(
        os.path.join(plugin_dir, "NdjsonSocket.qml"),
        os.path.join(shell_root, "NdjsonSocket.qml"),
    )
    now = time.time()
    for root, _dirs, files in os.walk(shell_root):
        for f in files:
            try:
                os.utime(os.path.join(root, f), (now, now))
            except OSError:
                pass
    return shell_root


def listen_unix(path: str) -> socket.socket:
    lst = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    lst.bind(path)
    lst.listen(4)
    lst.settimeout(15.0)
    return lst


def main() -> None:
    if len(sys.argv) != 5:
        fail("usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir>")
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]
    os.makedirs(work_dir, exist_ok=True)

    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    os.makedirs(xdg_runtime, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)

    sub_path = os.path.join(work_dir, "sub.sock")
    req_path = os.path.join(work_dir, "req.sock")
    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    # Both listeners exist before quickshell starts so the subscribe
    # socket's very first connect attempt succeeds.
    sub_lst = listen_unix(sub_path)
    req_lst = listen_unix(req_path)

    env = os.environ.copy()
    env.update(
        {
            "XDG_RUNTIME_DIR": xdg_runtime,
            "QT_QPA_PLATFORM": "offscreen",
            "QSG_RHI_BACKEND": "null",
            "TEST_SUB_SOCK": sub_path,
            "TEST_REQ_SOCK": req_path,
        }
    )

    def ipc(*args: str) -> str:
        cmd = [qs_bin, "ipc", "-p", shell_qml, "call", "test:ndjson", *args]
        out = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=15)
        if out.returncode != 0:
            raise RuntimeError(
                f"qs ipc call {args} failed (exit={out.returncode}):\n"
                f"stdout: {out.stdout!r}\nstderr: {out.stderr!r}"
            )
        return out.stdout

    qs_log = open(os.path.join(work_dir, "qs.log"), "w")
    qs_proc = subprocess.Popen(
        [qs_bin, "-p", shell_qml], env=env, stdout=qs_log, stderr=qs_log
    )

    def cleanup_logs():
        try:
            qs_log.flush()
            with open(os.path.join(work_dir, "qs.log")) as fh:
                sys.stderr.write("\n== qs.log ==\n")
                sys.stderr.write(fh.read())
        except Exception:
            pass

    try:
        def ipc_ready():
            r = subprocess.run(
                [qs_bin, "ipc", "-p", shell_qml, "show"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
            return r.returncode == 0 and "test:ndjson" in r.stdout

        if not wait_until(ipc_ready, timeout_s=20):
            cleanup_logs()
            fail("IPC never registered")

        # ── subscribe: hello + delivery + bad line + send() ──────────
        conn1, _ = sub_lst.accept()
        if json.loads(read_line(conn1)) != {"op": "subscribe"}:
            cleanup_logs()
            fail("subscribe socket did not send the hello payload")

        conn1.sendall(b'{"op":"a","n":1}\n{"op":"b","n":2}\nnot-json {{{\n')
        if not wait_until(
            lambda: json.loads(ipc("received"))
            == [{"op": "a", "n": 1}, {"op": "b", "n": 2}],
            timeout_s=5,
        ):
            cleanup_logs()
            fail(f"subscribe lines not delivered: received={ipc('received')!r}")
        if not wait_until(
            lambda: json.loads(ipc("badLines")) == ["not-json {{{"],
            timeout_s=3,
        ):
            cleanup_logs()
            fail(f"malformed line not rejected: badLines={ipc('badLines')!r}")
        if json.loads(ipc("connected")) is not True:
            cleanup_logs()
            fail("connected should read true while the fixture holds the socket")

        ipc("sendSub", json.dumps({"op": "echo", "n": 3}))
        if json.loads(read_line(conn1)) != {"op": "echo", "n": 3}:
            cleanup_logs()
            fail("send() line never reached the fixture")

        # ── subscribe: listener vanishes -> backoff escalates ────────
        conn1.close()
        sub_lst.close()
        os.unlink(sub_path)
        if not wait_until(lambda: json.loads(ipc("drops")) >= 1, timeout_s=5):
            cleanup_logs()
            fail("connection drop never surfaced")
        if not wait_until(
            lambda: json.loads(ipc("connected")) is False, timeout_s=3
        ):
            cleanup_logs()
            fail("connected should read false after the listener vanished")
        # Let a few reconnect attempts fail so the interval doubles past
        # its base — the reset assertion below is meaningless otherwise.
        time.sleep(2.5)

        # ── subscribe: listener returns -> reconnect + fresh hello ───
        sub_lst = listen_unix(sub_path)
        conn2, _ = sub_lst.accept()  # backoff caps at 4s; 15s accept timeout
        if json.loads(read_line(conn2)) != {"op": "subscribe"}:
            cleanup_logs()
            fail("no hello after reconnect")
        conn2.sendall(b'{"op":"c","n":4}\n')
        if not wait_until(
            lambda: json.loads(ipc("received"))[-1] == {"op": "c", "n": 4},
            timeout_s=5,
        ):
            cleanup_logs()
            fail("post-reconnect line not delivered")

        # ── subscribe: backoff resets after a successful connect ─────
        # The escalation above pushed the retry interval towards the 4s
        # cap; a successful connect must reset it to base (500ms), so
        # this bounce reconnects fast.
        t0 = time.monotonic()
        conn2.close()
        conn3, _ = sub_lst.accept()
        dt = time.monotonic() - t0
        if dt > 2.5:
            cleanup_logs()
            fail(f"backoff not reset on success: reconnect took {dt:.2f}s")
        if json.loads(read_line(conn3)) != {"op": "subscribe"}:
            cleanup_logs()
            fail("no hello after second reconnect")

        # ── request: happy path ──────────────────────────────────────
        ipc("request", json.dumps({"op": "ping"}))
        rconn, _ = req_lst.accept()
        if json.loads(read_line(rconn)) != {"op": "ping"}:
            cleanup_logs()
            fail("request payload never reached the fixture")
        rconn.sendall(b'{"op":"ok","n":1}\n')
        rconn.close()
        if not wait_until(
            lambda: json.loads(ipc("replies"))
            == [{"msg": {"op": "ok", "n": 1}, "raw": '{"op":"ok","n":1}'}],
            timeout_s=5,
        ):
            cleanup_logs()
            fail(f"request reply not delivered: replies={ipc('replies')!r}")

        # ── request: malformed reply -> msg null, raw preserved ──────
        ipc("request", json.dumps({"op": "junk"}))
        rconn, _ = req_lst.accept()
        read_line(rconn)
        rconn.sendall(b"not-json\n")
        rconn.close()
        if not wait_until(
            lambda: json.loads(ipc("replies"))[-1] == {"msg": None, "raw": "not-json"},
            timeout_s=5,
        ):
            cleanup_logs()
            fail(f"malformed reply not surfaced: replies={ipc('replies')!r}")

        # ── request: silent peer -> timeout fires exactly once ───────
        ipc("request", json.dumps({"op": "hang"}))
        rconn, _ = req_lst.accept()
        read_line(rconn)  # swallow the request, never reply, keep open
        if not wait_until(
            lambda: len(json.loads(ipc("replies"))) == 3
            and json.loads(ipc("replies"))[-1] == {"msg": None, "raw": ""},
            timeout_s=5,  # requestTimeoutMs is 1500 in shell.qml
        ):
            cleanup_logs()
            fail(f"reply timeout never fired: replies={ipc('replies')!r}")
        rconn.close()

        # ── request: peer closes without replying ────────────────────
        ipc("request", json.dumps({"op": "slam"}))
        rconn, _ = req_lst.accept()
        rconn.close()
        if not wait_until(
            lambda: len(json.loads(ipc("replies"))) == 4
            and json.loads(ipc("replies"))[-1] == {"msg": None, "raw": ""},
            timeout_s=5,
        ):
            cleanup_logs()
            fail(f"close-without-reply not surfaced: replies={ipc('replies')!r}")

        # The done-guard: no late duplicate callbacks from the timed-out
        # or slammed one-shots.
        time.sleep(1.0)
        if len(json.loads(ipc("replies"))) != 4:
            cleanup_logs()
            fail(f"duplicate reply callbacks: replies={ipc('replies')!r}")

        print("OK")
    finally:
        qs_proc.terminate()
        try:
            qs_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            qs_proc.kill()


if __name__ == "__main__":
    main()

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
import socket
import sys
import time

from qs_harness import Quickshell, fail, qs_env, stage_shell
from qs_harness import wait_until as _wait_until


def wait_until(predicate, *, timeout_s: float, interval_s: float = 0.05):
    return _wait_until(predicate, timeout_s=timeout_s, interval_s=interval_s)


def read_line(conn: socket.socket, timeout_s: float = 10.0) -> str:
    r"""Read one \n-terminated line off a unix socket."""
    conn.settimeout(timeout_s)
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = conn.recv(4096)
        if not chunk:
            msg = f"peer closed mid-line, buffer={buf!r}"
            raise RuntimeError(msg)
        buf += chunk
    return buf.decode().rstrip("\n")


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

    sub_path = os.path.join(work_dir, "sub.sock")
    req_path = os.path.join(work_dir, "req.sock")
    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    # Both listeners exist before quickshell starts so the subscribe
    # socket's very first connect attempt succeeds.
    sub_lst = listen_unix(sub_path)
    req_lst = listen_unix(req_path)

    env = qs_env(
        work_dir,
        extra={
            "QSG_RHI_BACKEND": "null",
            "TEST_SUB_SOCK": sub_path,
            "TEST_REQ_SOCK": req_path,
        },
    )

    qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target="test:ndjson")

    def ipc(*args: str) -> str:
        return qs.ipc(*args)

    qs.start()

    def cleanup_logs():
        qs.dump_logs()

    try:
        if not wait_until(qs.ipc_ready, timeout_s=20):
            cleanup_logs()
            fail("IPC never registered")

        # ── subscribe: hello + delivery + bad line + send() ──────────
        conn1, _ = sub_lst.accept()
        if json.loads(read_line(conn1)) != {"op": "subscribe"}:
            cleanup_logs()
            fail("subscribe socket did not send the hello payload")

        conn1.sendall(b'{"op":"a","n":1}\n{"op":"b","n":2}\nnot-json {{{\n')
        if not wait_until(
            lambda: (
                json.loads(ipc("received"))
                == [{"op": "a", "n": 1}, {"op": "b", "n": 2}]
            ),
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
        if not wait_until(lambda: json.loads(ipc("connected")) is False, timeout_s=3):
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
            lambda: (
                json.loads(ipc("replies"))
                == [{"msg": {"op": "ok", "n": 1}, "raw": '{"op":"ok","n":1}'}]
            ),
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
            lambda: (
                len(json.loads(ipc("replies"))) == 3
                and json.loads(ipc("replies"))[-1] == {"msg": None, "raw": ""}
            ),
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
            lambda: (
                len(json.loads(ipc("replies"))) == 4
                and json.loads(ipc("replies"))[-1] == {"msg": None, "raw": ""}
            ),
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
        qs.stop()


if __name__ == "__main__":
    main()

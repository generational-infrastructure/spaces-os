#!/usr/bin/env python3
"""Signal approval-split driver check (migration plan step 7) against the REAL
pi-sessiond gateway AND the REAL integration-signal MCP server.

Where checks/pi-sessiond-integration-gateway proves the confirmPreview mechanism
generically with a stub MCP + a synthetic `github` fixture, this check proves
the SIGNAL-specific autoRun/confirm split end to end: signal's real definition
(autoRun = threads/read_thread/search/contacts/groups/note_to_self/
fetch_attachment; confirm = send; confirmPreview.send = send_preview) driven
through the real gateway against the real integration-signal server, which is
itself wired to a fake signal-cli JSON-RPC daemon + a fixture messages.db (the
same fake-daemon shape packages/integration-signal/test_integration_signal.py
uses for the unit contract tests).

Asserts:
  1. The child-facing tool spec lists signal's autoRun + confirm tools but NEVER
     the gateway-only send_preview.
  2. `send` (a known contact) raises an approval_request whose untrusted
     `context` is the real send_preview `to:` line; approving it dispatches the
     message (preview-then-send order: the preview never touches the daemon,
     the real send does).
  3. autoRun tools `threads` and `note_to_self` run with NO approval prompt
     (threads reads the fixture DB; note_to_self dispatches a self-send).
  4. A send whose preview returns an error FAILS CLOSED through the real signal
     server: the tool errors with the preview text, no approval is raised, and
     the real send never reaches the daemon. (The generic fail-closed mechanism
     is covered by the Wave A gateway check; this pins that the REAL signal
     preview producing isError actually trips it.)

Cheap (~seconds, no VM, no model): the real daemon runs on loopback in the
build sandbox, the real integration-signal server runs behind its unix socket,
and a fake signal daemon + fixture DB stand in for signal-cli. Real Landlock
enforcement is checks/pi-sessiond-landlock.

usage: driver.py <daemon> <stub_pi> <integration_signal_bin> <systemd_run> <landlock_exec>
"""

import asyncio
import json
import os
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

import websockets

# spaces_signal.db (from the spaces-signal-cli package) is on PYTHONPATH via the
# check's default.nix; it owns the messages.db schema the integration reads.
from spaces_signal import db as dbmod

TOKEN = "signal-split-secret"

# The wire contract (integration-wire.json via the check's env export): the
# per-session spec filename the daemon stages, single-sourced with the gateway.
with open(os.environ["SPACES_INTEGRATION_WIRE"], encoding="utf-8") as _wire:
    TOOL_SPEC_FILE = json.load(_wire)["toolSpecFile"]

# ── fake signal-cli daemon + fixtures ───────────────────────────────
# Adapted from packages/integration-signal/test_integration_signal.py: a
# unix-socket line-delimited JSON-RPC server (spaces_signal.jsonrpc framing)
# that records every request so the driver can assert dispatch (and preview
# purity: no `send` during a preview).

OWN_NUMBER = "+15550000000"
ACCOUNTS = [{"number": OWN_NUMBER, "uuid": "uuid-self"}]
CONTACTS = [
    {"number": "+15551230001", "uuid": "uuid-bob", "name": "Bob"},
    {
        "number": "+15551230002",
        "uuid": "uuid-alice",
        "name": "",
        "profile": {"givenName": "Alice", "familyName": ""},
    },
]
GROUPS = [
    {
        "id": "TEAMGROUPID=",
        "name": "Team",
        "members": ["+15551230001", "+15551230002"],
    },
]


class FakeDaemon:
    """Unix-socket JSON-RPC server; records every request it receives."""

    def __init__(self, sock_path):
        self.sock_path = sock_path
        self.requests = []
        self._stop = False
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            os.unlink(sock_path)
        except FileNotFoundError:
            pass
        self._sock.bind(sock_path)
        self._sock.listen(8)
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def _serve(self):
        while not self._stop:
            try:
                conn, _ = self._sock.accept()
            except OSError:
                return
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn):
        with conn, conn.makefile("rb") as reader:
            for line in reader:
                line = line.strip()
                if not line:
                    continue
                req = json.loads(line)
                self.requests.append(req)
                resp = self._dispatch(req)
                conn.sendall(json.dumps(resp).encode("utf-8") + b"\n")

    def _dispatch(self, req):
        method = req.get("method")
        rid = req.get("id")
        if method == "listAccounts":
            result = ACCOUNTS
        elif method == "listContacts":
            result = CONTACTS
        elif method == "listGroups":
            result = GROUPS
        elif method == "send":
            result = {"timestamp": 1234567890}
        else:
            return {
                "jsonrpc": "2.0",
                "id": rid,
                "error": {"code": -32601, "message": f"no method: {method}"},
            }
        return {"jsonrpc": "2.0", "id": rid, "result": result}

    def sends(self):
        return [r for r in self.requests if r.get("method") == "send"]

    def close(self):
        self._stop = True
        try:
            self._sock.close()
        except OSError:
            pass


def build_db(path):
    db = dbmod.connect(Path(path))
    for msg in (
        {
            "uid": "m-bob-1",
            "ts_ms": 1_700_000_001_000,
            "thread_id": "uuid-bob",
            "thread_kind": "dm",
            "sender_uuid": "uuid-bob",
            "sender_name": "Bob",
            "body": "hello from bob",
        },
        {
            "uid": "m-team-1",
            "ts_ms": 1_700_000_002_000,
            "thread_id": "TEAMGROUPID=",
            "thread_kind": "group",
            "sender_uuid": "uuid-carol",
            "sender_name": "Carol",
            "body": "standup at ten",
        },
    ):
        dbmod.store_message(db, msg)
    db.close()


# ── daemon WS helpers (shape shared with the gateway check driver) ───


def fail(msg):
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


async def recv_kind(ws, want, timeout=30):
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            fail(f"timed out awaiting {want!r}")
        msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=remaining))
        if msg.get("kind") == want:
            return msg
        if msg.get("kind") == "error":
            fail(f"server error while awaiting {want!r}: {msg}")


async def hello(ws):
    await ws.send(
        json.dumps({"v": 1, "kind": "hello", "token": TOKEN, "client": {"name": "drv"}})
    )
    await recv_kind(ws, "welcome")


def cmd(sid, payload):
    return json.dumps({"v": 1, "kind": "command", "sessionId": sid, "payload": payload})


async def create_session(ws):
    await ws.send(json.dumps({"v": 1, "kind": "create_session", "name": "sig"}))
    return (await recv_kind(ws, "attached"))["sessionId"]


async def do_call(ws, sid, integration, tool, args, decision=None, timeout=30):
    """Drive one INTCALL. Returns (saw_approval, args, result, context)."""
    payload = json.dumps({"integration": integration, "tool": tool, "args": args})
    await ws.send(cmd(sid, {"type": "prompt", "message": "INTCALL " + payload}))
    saw_approval = False
    approval_args = None
    approval_context = None
    result = None
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            fail(f"timed out mid-call ({integration}_{tool})")
        msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=remaining))
        if msg.get("kind") != "event":
            continue
        p = msg.get("payload") or {}
        if p.get("type") == "approval_request":
            saw_approval = True
            approval_args = p.get("args")
            approval_context = p.get("context")
            if decision is None:
                fail(f"unexpected approval_request for {integration}_{tool}")
            await ws.send(
                cmd(
                    sid,
                    {"type": "approval_response", "id": p["id"], "decision": decision},
                )
            )
        elif p.get("type") == "assistant_message" and str(p.get("text", "")).startswith(
            "RESULT "
        ):
            result = json.loads(p["text"][len("RESULT ") :])
        elif p.get("type") == "agent_end":
            break
    return saw_approval, approval_args, result, approval_context


# ── scenarios ────────────────────────────────────────────────────────


async def scenarios(state, daemon):
    async with websockets.connect("ws://127.0.0.1:8785") as ws:
        await hello(ws)
        sid = await create_session(ws)

        # 1. The staged child spec lists signal's autoRun + confirm tools, and
        #    NEVER the gateway-only preview tool (decision 1/5).
        spec_path = os.path.join(state, "sessions", sid, "agent", TOOL_SPEC_FILE)
        with open(spec_path) as fh:
            spec = json.load(fh)
        names = sorted(e["name"] for e in spec)
        expected = sorted(
            "signal_" + t
            for t in [
                "threads",
                "read_thread",
                "search",
                "contacts",
                "groups",
                "note_to_self",
                "fetch_attachment",
                "send",
            ]
        )
        if names != expected:
            fail(f"child spec should list signal's child-facing tools, got {names}")
        if any(e["name"] == "signal_send_preview" for e in spec):
            fail("send_preview must never be child-facing")
        if any("autoRun" in e for e in spec):
            fail("the child spec must not carry the allowlist")

        # 2. autoRun read tool: no prompt, reads the fixture DB.
        saw, _, res, _ = await do_call(ws, sid, "signal", "threads", {})
        if saw:
            fail("autoRun threads must not prompt")
        if not res or res.get("isError"):
            fail(f"threads should succeed, got {res}")
        if "uuid-bob" not in res["text"]:
            fail(f"threads should list the fixture threads, got {res['text']!r}")
        if daemon.sends():
            fail("threads must never dispatch a send")

        # 3. autoRun note_to_self: no prompt, dispatches a self-send.
        saw, _, res, _ = await do_call(
            ws, sid, "signal", "note_to_self", {"body": "remember milk"}
        )
        if saw:
            fail("autoRun note_to_self must not prompt")
        if not res or res.get("isError") or "note-to-self" not in res["text"]:
            fail(f"note_to_self should succeed, got {res}")
        note_sends = daemon.sends()
        if len(note_sends) != 1:
            fail(f"note_to_self should dispatch exactly one send, got {len(note_sends)}")
        if note_sends[0]["params"].get("message") != "remember milk":
            fail(f"note_to_self send carried wrong body: {note_sends[0]}")

        # 4. send (confirm + confirmPreview): the gateway calls the REAL
        #    send_preview first — no daemon send during the preview — rides its
        #    `to:` line on the approval as untrusted context, then on "once"
        #    dispatches the real send.
        sends_before = len(daemon.sends())
        saw, ap_args, res, ctx = await do_call(
            ws,
            sid,
            "signal",
            "send",
            {"recipient": "+15551230001", "name": "Bob", "body": "hi bob"},
            decision="once",
        )
        if not saw:
            fail("send must raise an approval prompt")
        if ap_args != {"recipient": "+15551230001", "name": "Bob", "body": "hi bob"}:
            fail(f"approval must carry the call args, got {ap_args}")
        if ctx != "to: Bob <+15551230001>":
            fail(f"approval context must be the real send_preview to-line, got {ctx!r}")
        if not res or res.get("isError") or not res["text"].startswith("sent to"):
            fail(f"approved send should dispatch, got {res}")
        after = daemon.sends()
        if len(after) != sends_before + 1:
            fail(f"approved send should dispatch exactly one send, got {after}")
        if after[-1]["params"].get("recipient") != ["+15551230001"]:
            fail(f"the real send targeted the wrong recipient: {after[-1]}")
        if after[-1]["params"].get("message") != "hi bob":
            fail(f"the real send carried the wrong body: {after[-1]}")

        # 5. Preview error FAILS CLOSED (decision 5) through the REAL signal
        #    server: an empty recipient makes send_preview return isError, so the
        #    gateway errors the tool, raises NO approval, and the real send never
        #    reaches the daemon.
        sends_before = len(daemon.sends())
        saw, _, res, _ = await do_call(
            ws, sid, "signal", "send", {"recipient": "", "name": "Bob", "body": "x"}
        )
        if saw:
            fail("a failed preview must not raise an approval prompt")
        if not res or not res.get("isError") or "recipient is required" not in res["text"]:
            fail(f"a failed preview must surface the signal preview error, got {res}")
        if len(daemon.sends()) != sends_before:
            fail("a fail-closed send must never reach the daemon")


def wait_path(path, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(path):
            return
        time.sleep(0.05)
    fail(f"path never appeared: {path}")


def wait_port(port, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                return
        except OSError:
            time.sleep(0.1)
    fail(f"daemon never opened port {port}")


def main():
    if len(sys.argv) < 6:
        fail(
            "usage: driver.py <daemon> <stub_pi> <integration_signal> "
            "<systemd_run> <landlock_exec>"
        )
    daemon_bin, stub_pi, signal_bin, systemd_run, landlock_exec = sys.argv[1:6]

    import tempfile

    root = tempfile.mkdtemp(prefix="sig-split-")
    sock_dir = os.path.join(root, "sockets")
    os.makedirs(sock_dir, exist_ok=True)
    shared_base = os.path.join(root, "share")
    defs_dir = os.path.join(root, "defs")
    os.makedirs(defs_dir, exist_ok=True)
    # Signal's real autoRun/confirm split (migration decision 1).
    with open(os.path.join(defs_dir, "signal.json"), "w") as fh:
        json.dump(
            {
                "autoRun": [
                    "threads",
                    "read_thread",
                    "search",
                    "contacts",
                    "groups",
                    "note_to_self",
                    "fetch_attachment",
                ],
                "confirmPreview": {"send": "send_preview"},
            },
            fh,
        )
    enabled_path = os.path.join(root, "enabled.json")
    with open(enabled_path, "w") as fh:
        json.dump({"integrations": {"signal": {"enabled": True}}}, fh)

    # Fixture DB + attachments + fake signal daemon.
    db_path = os.path.join(root, "messages.db")
    build_db(db_path)
    att_dir = os.path.join(root, "attachments")
    os.makedirs(att_dir, exist_ok=True)
    shared_int = os.path.join(root, "int-shared")
    os.makedirs(shared_int, exist_ok=True)
    daemon_sock = os.path.join(sock_dir, "signal-cli.sock")
    fake = FakeDaemon(daemon_sock)

    # The REAL integration-signal server, bound to the socket the gateway
    # derives for this integration (spaces-integration-<name>.sock).
    int_sock = os.path.join(sock_dir, "spaces-integration-signal.sock")
    int_env = dict(os.environ)
    # The integration-signal app is a self-contained closure; do not leak the
    # driver's PYTHONPATH (which only carries spaces_signal for the fixture DB).
    int_env.pop("PYTHONPATH", None)
    int_env.update(
        {
            "SPACES_INTEGRATION_SOCKET": int_sock,
            "SPACES_SIGNAL_DAEMON_SOCKET": daemon_sock,
            "SPACES_SIGNAL_DB": db_path,
            "SPACES_SIGNAL_ATTACHMENTS_DIR": att_dir,
            "SPACES_INTEGRATION_SHARED_DIR": shared_int,
        }
    )
    int_log = open(os.path.join(root, "integration.log"), "wb")
    integ = subprocess.Popen(
        [signal_bin], env=int_env, stdout=int_log, stderr=subprocess.STDOUT
    )
    procs = [integ]
    try:
        wait_path(int_sock)

        state = os.path.join(root, "state")
        os.makedirs(state, exist_ok=True)
        env = dict(os.environ)
        env.update(
            {
                "SPACES_SESSIOND_HOST": "127.0.0.1",
                "SPACES_SESSIOND_PORT": "8785",
                "SPACES_SESSIOND_TOKEN": TOKEN,
                "SPACES_SESSIOND_PI_BIN": stub_pi,
                "SPACES_SESSIOND_STATE_DIR": state,
                "SPACES_SESSIOND_IDLE_TIMEOUT_MS": "0",
                "SPACES_SESSIOND_SYSTEMD_RUN": systemd_run,
                "SPACES_SESSIOND_LANDLOCK_EXEC": landlock_exec,
                "HOME": state,
                "SPACES_SESSIOND_INTEGRATIONS_ENABLED": enabled_path,
                "SPACES_SESSIOND_INTEGRATIONS_DEFS": defs_dir,
                "SPACES_SESSIOND_INTEGRATIONS_SOCKETS": sock_dir,
                "SPACES_SESSIOND_INTEGRATIONS_SHARED": shared_base,
            }
        )
        log = open(os.path.join(root, "daemon.log"), "wb")
        d = subprocess.Popen(
            [daemon_bin], env=env, stdout=log, stderr=subprocess.STDOUT
        )
        procs.append(d)
        wait_port(8785)
        asyncio.run(scenarios(state, fake))
        print("OK")
    except BaseException:
        for name in ("daemon.log", "integration.log"):
            p = os.path.join(root, name)
            if os.path.exists(p):
                with open(p) as fh:
                    sys.stderr.write(f"=== {name} ===\n" + fh.read())
        raise
    finally:
        fake.close()
        for p in procs:
            p.terminate()
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()


if __name__ == "__main__":
    main()

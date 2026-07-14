#!/usr/bin/env python3
"""End-to-end check for the standalone aggregating MCP gateway
(packages/spaces-integration-gateway, docs/agent-integrations-generic-mcp-design.md).

Drives the REAL gateway binary over its unix socket — the transport, socket
binding, lazy discovery against a real integration socket, the autoRun allowlist,
and the confirm-COMMAND spawn (confirm.ts) — end to end. Only the integration
server and the confirm command are stubs; the gateway is production code.

Asserts:
  - tools/list aggregates the enabled integration's tools, namespaced;
  - an autoRun tool forwards with NO confirm command spawned;
  - a non-autoRun tool spawns the confirm command; a "deny" verdict returns
    "Denied by user." and the integration is never called;
  - an "once" verdict forwards the call;
  - a "session" verdict suppresses the confirm on the next call to that tool
    (the grant persists for the connection).
"""

import json
import os
import socket
import stat
import subprocess
import sys
import threading
import time
from pathlib import Path


def fail(msg):
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


# ── stub integration MCP server (NDJSON JSON-RPC over a unix socket) ──
class StubIntegration:
    def __init__(self, path):
        self.path = path
        self.calls = []  # tools/call names it actually received
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.srv.bind(path)
        self.srv.listen(8)
        self._stop = False
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self):
        while not self._stop:
            try:
                conn, _ = self.srv.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(conn,), daemon=True).start()

    def _serve(self, conn):
        with conn, conn.makefile("rb") as r:
            for line in r:
                line = line.strip()
                if not line:
                    continue
                msg = json.loads(line)
                m = msg.get("method")
                if m == "initialize":
                    self._reply(conn, msg, {"capabilities": {"tools": {}}})
                elif m == "tools/list":
                    self._reply(
                        conn,
                        msg,
                        {
                            "tools": [
                                {
                                    "name": "get_repo",
                                    "description": "read repo",
                                    "inputSchema": {"type": "object"},
                                },
                                {
                                    "name": "create_issue",
                                    "description": "make issue",
                                    "inputSchema": {"type": "object"},
                                },
                            ]
                        },
                    )
                elif m == "tools/call":
                    name = msg["params"]["name"]
                    self.calls.append(name)
                    self._reply(
                        conn,
                        msg,
                        {
                            "content": [{"type": "text", "text": f"{name} ran"}],
                            "isError": False,
                        },
                    )
                # notifications/initialized: no reply

    def _reply(self, conn, msg, result):
        conn.sendall(
            (
                json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": result}) + "\n"
            ).encode()
        )


# ── MCP client over the gateway socket ──
class GatewayClient:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.f = self.sock.makefile("rwb")
        self._id = 0
        self._send(
            {"jsonrpc": "2.0", "id": self._next(), "method": "initialize", "params": {}}
        )
        self._recv()
        self.f.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        self.f.flush()

    def _next(self):
        self._id += 1
        return self._id

    def _send(self, obj):
        self.f.write((json.dumps(obj) + "\n").encode())
        self.f.flush()

    def _recv(self):
        return json.loads(self.f.readline().decode())

    def list_tools(self):
        self._send({"jsonrpc": "2.0", "id": self._next(), "method": "tools/list"})
        return self._recv()["result"]["tools"]

    def call(self, name, args=None):
        self._send(
            {
                "jsonrpc": "2.0",
                "id": self._next(),
                "method": "tools/call",
                "params": {"name": name, "arguments": args or {}},
            }
        )
        return self._recv()["result"]


def wait_path(p, timeout=15):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if Path(p).exists():
            return True
        time.sleep(0.1)
    return False


def main():
    gateway_bin = sys.argv[1]
    work = os.environ["TMPDIR"]

    defs = Path(work) / "defs"
    defs.mkdir(exist_ok=True)
    (defs / "github.json").write_text(json.dumps({"autoRun": ["get_repo"]}))
    enabled = Path(work) / "enabled.json"
    enabled.write_text(json.dumps({"integrations": {"github": {"enabled": True}}}))

    sockdir = Path(work) / "run"
    sockdir.mkdir(exist_ok=True)
    stub = StubIntegration(str(sockdir / "spaces-integration-github.sock"))

    gw_sock = str(sockdir / "gw.sock")
    control = Path(work) / "verdict.control"
    confirm_log = Path(work) / "confirm.log"
    confirm_log.write_text("")

    confirm = Path(work) / "confirm-stub.sh"
    confirm.write_text(
        "#!/bin/sh\n"
        'echo called >> "$CONFIRM_LOG"\n'
        'printf %s "$(cat "$CONFIRM_CONTROL")" > "$SPACES_CONFIRM_VERDICT_FILE"\n'
    )
    confirm.chmod(confirm.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

    env = dict(os.environ)
    env.update(
        SPACES_INTEGRATION_GATEWAY_ENABLED=str(enabled),
        SPACES_INTEGRATION_GATEWAY_DEFS=str(defs),
        SPACES_INTEGRATION_GATEWAY_SOCKETS=str(sockdir),
        SPACES_INTEGRATION_GATEWAY_SOCKET=gw_sock,
        SPACES_INTEGRATION_CONFIRM_CMD=json.dumps([str(confirm)]),
        CONFIRM_CONTROL=str(control),
        CONFIRM_LOG=str(confirm_log),
    )
    gw = subprocess.Popen(
        [gateway_bin], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
    )
    try:
        if not wait_path(gw_sock):
            out = gw.stdout.read().decode() if gw.stdout else ""
            fail(f"gateway never bound {gw_sock}\n{out}")

        cl = GatewayClient(gw_sock)

        names = sorted(t["name"] for t in cl.list_tools())
        if names != ["github_create_issue", "github_get_repo"]:
            fail(f"tools/list did not aggregate the integration's tools: {names}")

        # autoRun: forwards, no confirm.
        res = cl.call("github_get_repo")
        if res.get("isError") or "get_repo ran" not in res["content"][0]["text"]:
            fail(f"autoRun tool did not forward: {res}")
        if confirm_log.read_text().strip():
            fail("autoRun tool must not spawn the confirm command")

        # non-autoRun + deny: confirm spawned, integration never called.
        control.write_text("deny")
        before = list(stub.calls)
        res = cl.call("github_create_issue", {"title": "x"})
        if not res.get("isError") or res["content"][0]["text"] != "Denied by user.":
            fail(f"deny must return the canned refusal: {res}")
        if stub.calls != before:
            fail("a denied tool must never reach the integration")
        if len(confirm_log.read_text().split()) != 1:
            fail("non-autoRun tool must spawn the confirm command exactly once")

        # once: forwards.
        control.write_text("once")
        res = cl.call("github_create_issue", {"title": "y"})
        if res.get("isError") or "create_issue ran" not in res["content"][0]["text"]:
            fail(f"once verdict must forward: {res}")

        # session: forwards AND grants; a follow-up call is NOT re-confirmed even
        # though the control now says deny (the grant, not the verdict, decides).
        control.write_text("session")
        cl.call("github_create_issue", {"title": "z1"})
        confirms_after_session = len(confirm_log.read_text().split())
        control.write_text("deny")
        res = cl.call("github_create_issue", {"title": "z2"})
        if res.get("isError"):
            fail(f"session grant must suppress the next confirm: {res}")
        if len(confirm_log.read_text().split()) != confirms_after_session:
            fail("session grant must not re-spawn the confirm command")

        print("PASS: gateway aggregates, gates autoRun, and enforces confirm verdicts")
    finally:
        gw.terminate()
        try:
            gw.wait(timeout=5)
        except subprocess.TimeoutExpired:
            gw.kill()
        stub._stop = True
        stub.srv.close()


main()

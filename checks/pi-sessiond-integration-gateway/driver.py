#!/usr/bin/env python3
"""Integration-gateway check (design §9.3) against the REAL pi-sessiond.

The supervisor's gateway is driven end to end without a model or the real pi:
a stub `pi --mode rpc` child forwards a tool call exactly as the
spaces-integrations extension does (extension_ui input with the integration-call
sentinel), and a stub MCP server stands in for the integration. Asserts the
step-4 acceptance:

  - discovery: the daemon stages the discovered tools as the per-session spec
    the extension would register (github_get_repo, github_create_issue);
  - an allowlisted tool (autoRun) runs with no approval prompt;
  - a non-allowlisted tool opens an approval_request carrying the call args;
  - Deny returns "Denied by user." and the MCP server is never called;
  - "Allow for this session" runs it and suppresses the prompt next time;
  - a daemon with no integrations env exposes no tools (empty spec).

Cheap: bun runs the daemon on loopback in the build sandbox; no VM, no model.

usage: driver.py <daemon_bin> <stub_pi> <stub_mcp> <systemd_run> <landlock_exec>
"""

import asyncio
import json
import os
import subprocess
import sys
import time

import websockets

TOKEN = "gateway-secret"


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
    await ws.send(json.dumps({"v": 1, "kind": "create_session", "name": "gw"}))
    return (await recv_kind(ws, "attached"))["sessionId"]


async def do_call(ws, sid, integration, tool, args, decision=None, timeout=30):
    """Drive one INTCALL through the gateway. Returns (saw_approval, args, result)."""
    payload = json.dumps({"integration": integration, "tool": tool, "args": args})
    await ws.send(cmd(sid, {"type": "prompt", "message": "INTCALL " + payload}))
    saw_approval = False
    approval_args = None
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
    return saw_approval, approval_args, result


def read_calls(calls_out):
    if not os.path.exists(calls_out):
        return []
    with open(calls_out) as fh:
        return [json.loads(line) for line in fh if line.strip()]


async def scenarios(state, calls_out):
    async with websockets.connect("ws://127.0.0.1:8783") as ws:
        await hello(ws)
        sid = await create_session(ws)

        # The daemon stages the discovered tools for the extension to register.
        spec_path = os.path.join(
            state, "sessions", sid, "agent", "integration-tools.json"
        )
        with open(spec_path) as fh:
            spec = json.load(fh)
        names = sorted(e["name"] for e in spec)
        if names != ["github_create_issue", "github_get_repo"]:
            fail(f"spec should list both discovered tools, got {names}")
        get_entry = next(e for e in spec if e["name"] == "github_get_repo")
        if (
            get_entry["parameters"].get("properties", {}).get("repo", {}).get("type")
            != "string"
        ):
            fail(f"spec must carry the discovered inputSchema, got {get_entry}")
        if "autoRun" in get_entry:
            fail("the child spec must not carry the allowlist")

        # 1. Allowlisted (autoRun) tool: no prompt, server called, text returned.
        saw, _, res = await do_call(ws, sid, "github", "get_repo", {"repo": "o/r"})
        if saw:
            fail("allowlisted get_repo must not prompt")
        if not res or res.get("isError") or not res["text"].startswith("ok:get_repo:"):
            fail(f"get_repo result wrong: {res}")
        if [c["name"] for c in read_calls(calls_out)] != ["get_repo"]:
            fail("get_repo should have reached the server exactly once")

        # 2. Non-allowlisted tool, Deny: prompt with args, server NOT called.
        saw, ap_args, res = await do_call(
            ws,
            sid,
            "github",
            "create_issue",
            {"repo": "o/r", "title": "bug"},
            decision="deny",
        )
        if not saw:
            fail("create_issue must raise an approval prompt")
        if ap_args != {"repo": "o/r", "title": "bug"}:
            fail(f"approval must carry the call args, got {ap_args}")
        if res != {"text": "Denied by user.", "isError": True}:
            fail(f"deny must return the canned refusal, got {res}")
        if any(c["name"] == "create_issue" for c in read_calls(calls_out)):
            fail("a denied call must never reach the server")

        # 3. "Allow for this session": runs, and the next call is not prompted.
        saw, _, res = await do_call(
            ws,
            sid,
            "github",
            "create_issue",
            {"repo": "o/r", "title": "x"},
            decision="session",
        )
        if not saw or not res or res.get("isError"):
            fail(f"session-grant call should run, got saw={saw} res={res}")
        saw2, _, res2 = await do_call(
            ws, sid, "github", "create_issue", {"repo": "o/r", "title": "y"}
        )
        if saw2:
            fail("a session-granted tool must not prompt again")
        if (
            not res2
            or res2.get("isError")
            or not res2["text"].startswith("ok:create_issue:")
        ):
            fail(f"second create_issue should run, got {res2}")
        issues = [c for c in read_calls(calls_out) if c["name"] == "create_issue"]
        if len(issues) != 2:
            fail(
                f"create_issue should have reached the server twice, got {len(issues)}"
            )


async def scenario_no_integrations(state):
    async with websockets.connect("ws://127.0.0.1:8784") as ws:
        await hello(ws)
        sid = await create_session(ws)
        spec_path = os.path.join(
            state, "sessions", sid, "agent", "integration-tools.json"
        )
        with open(spec_path) as fh:
            spec = json.load(fh)
        if spec != []:
            fail(f"a daemon with no integrations env must expose no tools, got {spec}")


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
            with __import__("socket").create_connection(("127.0.0.1", port), timeout=1):
                return
        except OSError:
            time.sleep(0.1)
    fail(f"daemon never opened port {port}")


def base_env(state, stub_pi, systemd_run, landlock_exec, port):
    env = dict(os.environ)
    env.update(
        {
            "SPACES_SESSIOND_HOST": "127.0.0.1",
            "SPACES_SESSIOND_PORT": str(port),
            "SPACES_SESSIOND_TOKEN": TOKEN,
            "SPACES_SESSIOND_PI_BIN": stub_pi,
            "SPACES_SESSIOND_STATE_DIR": state,
            "SPACES_SESSIOND_IDLE_TIMEOUT_MS": "0",
            "SPACES_SESSIOND_SYSTEMD_RUN": systemd_run,
            "SPACES_SESSIOND_LANDLOCK_EXEC": landlock_exec,
            "HOME": state,
        }
    )
    return env


def main():
    if len(sys.argv) < 6:
        fail(
            "usage: driver.py <daemon> <stub_pi> <stub_mcp> <systemd_run> <landlock_exec>"
        )
    daemon, stub_pi, stub_mcp, systemd_run, landlock_exec = sys.argv[1:6]

    import tempfile

    root = tempfile.mkdtemp(prefix="gw-")
    sock_dir = os.path.join(root, "sockets")
    os.makedirs(sock_dir, exist_ok=True)
    defs_dir = os.path.join(root, "defs")
    os.makedirs(defs_dir, exist_ok=True)
    with open(os.path.join(defs_dir, "github.json"), "w") as fh:
        json.dump({"autoRun": ["get_repo"]}, fh)
    enabled_path = os.path.join(root, "enabled.json")
    with open(enabled_path, "w") as fh:
        json.dump({"integrations": {"github": {"enabled": True}}}, fh)
    calls_out = os.path.join(root, "calls.jsonl")
    gh_sock = os.path.join(sock_dir, "github.sock")

    # Stub MCP server must be listening before the daemon's startup discovery.
    mcp = subprocess.Popen([sys.executable, stub_mcp, gh_sock, calls_out])
    procs = [mcp]
    try:
        wait_path(gh_sock)

        # Phase 1: a daemon WITH integrations enabled.
        state1 = os.path.join(root, "state1")
        os.makedirs(state1, exist_ok=True)
        env1 = base_env(state1, stub_pi, systemd_run, landlock_exec, 8783)
        env1.update(
            {
                "SPACES_SESSIOND_INTEGRATIONS_ENABLED": enabled_path,
                "SPACES_SESSIOND_INTEGRATIONS_DEFS": defs_dir,
                "SPACES_SESSIOND_INTEGRATIONS_SOCKETS": sock_dir,
            }
        )
        log1 = open(os.path.join(root, "daemon1.log"), "wb")
        d1 = subprocess.Popen([daemon], env=env1, stdout=log1, stderr=subprocess.STDOUT)
        procs.append(d1)
        wait_port(8783)
        asyncio.run(scenarios(state1, calls_out))
        d1.terminate()
        d1.wait(timeout=5)

        # Phase 2: a daemon WITHOUT integrations env → no tools.
        state2 = os.path.join(root, "state2")
        os.makedirs(state2, exist_ok=True)
        env2 = base_env(state2, stub_pi, systemd_run, landlock_exec, 8784)
        log2 = open(os.path.join(root, "daemon2.log"), "wb")
        d2 = subprocess.Popen([daemon], env=env2, stdout=log2, stderr=subprocess.STDOUT)
        procs.append(d2)
        wait_port(8784)
        asyncio.run(scenario_no_integrations(state2))

        print("OK")
    except BaseException:
        for name in ("daemon1.log", "daemon2.log"):
            p = os.path.join(root, name)
            if os.path.exists(p):
                with open(p) as fh:
                    sys.stderr.write(f"=== {name} ===\n" + fh.read())
        raise
    finally:
        for p in procs:
            p.terminate()
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()


if __name__ == "__main__":
    main()

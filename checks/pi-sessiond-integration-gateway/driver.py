#!/usr/bin/env python3
"""Integration-gateway check (design §9.3) against the REAL pi-sessiond.

The supervisor's gateway is driven end to end without a model or the real pi:
a stub `pi --mode rpc` child forwards a tool call exactly as the
spaces-integrations extension does (extension_ui input with the integration-call
sentinel), and a stub MCP server stands in for the integration. Asserts the
step-4 acceptance plus the step-6 file-exchange wiring:

  - discovery: the daemon stages the discovered tools as the per-session spec
    the extension would register (github_get_repo, github_create_issue);
  - an allowlisted tool (autoRun) runs with no approval prompt;
  - a non-allowlisted tool opens an approval_request carrying the call args;
  - Deny returns "Denied by user." and the MCP server is never called;
  - "Allow for this session" runs it and suppresses the prompt next time;
  - a daemon with no integrations env exposes no tools (empty spec).
  - file exchange (step 6): an enabled integration's shared dir joins the
    session's Landlock rw set (the supervisor creates it); none ⇒ absent.

Cheap: bun runs the daemon on loopback in the build sandbox; no VM, no model.

usage: driver.py <daemon_bin> <stub_pi> <stub_mcp> <systemd_run> <landlock_exec>
"""

import asyncio
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import websockets

TOKEN = "gateway-secret"

# The wire contract (integration-wire.json via the check's env export) — the
# per-session spec filename the daemon stages, single-sourced with the gateway.
with open(os.environ["SPACES_INTEGRATION_WIRE"], encoding="utf-8") as _wire:
    TOOL_SPEC_FILE = json.load(_wire)["toolSpecFile"]


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


def read_calls(calls_out):
    if not os.path.exists(calls_out):
        return []
    with open(calls_out) as fh:
        return [json.loads(line) for line in fh if line.strip()]


def read_policy(state, sid):
    with open(os.path.join(state, "sessions", sid, "landlock.json")) as fh:
        return json.load(fh)


def rw_parents(policy):
    """The directories granted abi.read_write in a session's landlock policy."""
    out = []
    for rule in policy.get("pathBeneath", []):
        if "abi.read_write" in rule.get("allowedAccess", []):
            out.extend(rule.get("parent", []))
    return out


async def scenarios(state, calls_out, shared_base):
    async with websockets.connect("ws://127.0.0.1:8783") as ws:
        await hello(ws)
        sid = await create_session(ws)

        # File exchange (step 6): the session policy grants the enabled
        # integration's shared dir rw (the same dir the integration unit grants
        # itself), and the supervisor created it before the launcher ran.
        shared = os.path.join(shared_base, "github")
        if shared not in rw_parents(read_policy(state, sid)):
            fail(f"session policy must grant the integration shared dir rw: {shared}")
        if not await asyncio.to_thread(Path(shared).is_dir):
            fail(f"supervisor must create the shared dir: {shared}")

        # The daemon stages the discovered tools for the extension to register.
        spec_path = os.path.join(state, "sessions", sid, "agent", TOOL_SPEC_FILE)
        with open(spec_path) as fh:
            spec = json.load(fh)
        names = sorted(e["name"] for e in spec)
        if names != ["github_create_issue", "github_get_repo", "github_send"]:
            fail(f"spec should list the child-facing tools, got {names}")
        # send_preview is a gateway-only preview tool (decision 1/5): the server
        # exposes it, but the gateway must never surface it to the child.
        if any(e["name"] == "github_send_preview" for e in spec):
            fail("send_preview must never be child-facing")
        get_entry = next(e for e in spec if e["name"] == "github_get_repo")
        if (
            get_entry["parameters"].get("properties", {}).get("repo", {}).get("type")
            != "string"
        ):
            fail(f"spec must carry the discovered inputSchema, got {get_entry}")
        if "autoRun" in get_entry:
            fail("the child spec must not carry the allowlist")

        # 1. Allowlisted (autoRun) tool: no prompt, server called, text returned.
        saw, _, res, _ = await do_call(ws, sid, "github", "get_repo", {"repo": "o/r"})
        if saw:
            fail("allowlisted get_repo must not prompt")
        if not res or res.get("isError") or not res["text"].startswith("ok:get_repo:"):
            fail(f"get_repo result wrong: {res}")
        if [c["name"] for c in read_calls(calls_out)] != ["get_repo"]:
            fail("get_repo should have reached the server exactly once")

        # 2. Non-allowlisted tool, Deny: prompt with args, server NOT called.
        saw, ap_args, res, _ = await do_call(
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
        saw, _, res, _ = await do_call(
            ws,
            sid,
            "github",
            "create_issue",
            {"repo": "o/r", "title": "x"},
            decision="session",
        )
        if not saw or not res or res.get("isError"):
            fail(f"session-grant call should run, got saw={saw} res={res}")
        saw2, _, res2, _ = await do_call(
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

        # 4. confirmPreview (decision 5): a non-allowlisted tool WITH a preview
        # tool. The gateway calls the preview (same socket, same args) BEFORE
        # the prompt and rides its output on the approval as `context`. "once"
        # runs the tool without a session grant, so scenario 5 still exercises
        # the pre-approval preview path.
        saw, _, res, ctx = await do_call(
            ws,
            sid,
            "github",
            "send",
            {"recipient": "+1555", "name": "Alice", "body": "hi"},
            decision="once",
        )
        if not saw:
            fail("send must raise an approval prompt")
        if ctx != "to: Alice <+1555>":
            fail(f"approval must carry the preview output as context, got {ctx!r}")
        if not res or res.get("isError") or not res["text"].startswith("ok:send:"):
            fail(f"approved send should run, got {res}")
        seq = [
            c["name"]
            for c in read_calls(calls_out)
            if c["name"] in ("send", "send_preview")
        ]
        if seq != ["send_preview", "send"]:
            fail(f"expected preview-then-send call order, got {seq}")

        # 5. Preview failure FAILS CLOSED (decision 5): the tool errors, NO
        # approval is raised (do_call fails on an unexpected prompt), and the
        # real send never reaches the server.
        sends_before = len([c for c in read_calls(calls_out) if c["name"] == "send"])
        saw, _, res, _ = await do_call(
            ws,
            sid,
            "github",
            "send",
            {"recipient": "+1555", "name": "Alice", "body": "boom"},
        )
        if saw:
            fail("a failed preview must not raise an approval prompt")
        if not res or not res.get("isError") or "preview failed" not in res["text"]:
            fail(f"a failed preview must surface the preview tool error, got {res}")
        sends_after = len([c for c in read_calls(calls_out) if c["name"] == "send"])
        if sends_after != sends_before:
            fail("a fail-closed send must never reach the server")


async def scenario_no_integrations(state, shared_base):
    async with websockets.connect("ws://127.0.0.1:8784") as ws:
        await hello(ws)
        sid = await create_session(ws)
        spec_path = os.path.join(state, "sessions", sid, "agent", TOOL_SPEC_FILE)
        with open(spec_path) as fh:
            spec = json.load(fh)
        if spec != []:
            fail(f"a daemon with no integrations env must expose no tools, got {spec}")
        # No integrations enabled ⇒ no shared-dir grant, even though the base is
        # configured (the grant is per enabled integration, not the bare base).
        shared = os.path.join(shared_base, "github")
        if shared in rw_parents(read_policy(state, sid)):
            fail("a daemon with no integrations must not grant any shared dir")


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

    root = tempfile.mkdtemp(prefix="gw-")
    # The file-exchange base; the daemon creates <base>/<name> per enabled
    # integration (asserted below) — left absent here so creation is observable.
    shared_base = os.path.join(root, "share")
    sock_dir = os.path.join(root, "sockets")
    os.makedirs(sock_dir, exist_ok=True)
    defs_dir = os.path.join(root, "defs")
    os.makedirs(defs_dir, exist_ok=True)
    with open(os.path.join(defs_dir, "github.json"), "w") as fh:
        json.dump(
            {"autoRun": ["get_repo"], "confirmPreview": {"send": "send_preview"}}, fh
        )
    enabled_path = os.path.join(root, "enabled.json")
    with open(enabled_path, "w") as fh:
        json.dump({"integrations": {"github": {"enabled": True}}}, fh)
    calls_out = os.path.join(root, "calls.jsonl")
    gh_sock = os.path.join(sock_dir, "spaces-integration-github.sock")

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
                "SPACES_SESSIOND_INTEGRATIONS_SHARED": shared_base,
            }
        )
        log1 = open(os.path.join(root, "daemon1.log"), "wb")
        d1 = subprocess.Popen([daemon], env=env1, stdout=log1, stderr=subprocess.STDOUT)
        procs.append(d1)
        wait_port(8783)
        asyncio.run(scenarios(state1, calls_out, shared_base))
        d1.terminate()
        d1.wait(timeout=5)

        # Phase 2: a daemon WITHOUT integrations env → no tools.
        state2 = os.path.join(root, "state2")
        os.makedirs(state2, exist_ok=True)
        env2 = base_env(state2, stub_pi, systemd_run, landlock_exec, 8784)
        env2["SPACES_SESSIOND_INTEGRATIONS_SHARED"] = shared_base
        log2 = open(os.path.join(root, "daemon2.log"), "wb")
        d2 = subprocess.Popen([daemon], env=env2, stdout=log2, stderr=subprocess.STDOUT)
        procs.append(d2)
        wait_port(8784)
        asyncio.run(scenario_no_integrations(state2, shared_base))

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

"""WS probe for the loopback-executor subtests of test-machine (runs in
the VM as the desktop user).

Usage: ws-probe <port> <token-file> <scenario>

Scenarios:
  auth     hello with the real token -> welcome; hello with a wrong
           token -> no welcome (error or close).
  sandbox  create a session, prompt the mock LLM's home-probe trigger;
           bash-confirm asks, we approve; the probe command must yield
           HOME-DENIED (ProtectHome=tmpfs hid /home/test inside the
           per-command unit) and the marker content must never appear
           in the event stream. Prints the stream for the test log.
"""

import asyncio
import json
import sys
import time

import websockets

PORT = int(sys.argv[1])
TOKEN = open(sys.argv[2]).read().strip()
SCENARIO = sys.argv[3]
PROBE_PROMPT = "run the home probe"
MARKER_SECRET = "home-marker-secret"


def uri():
    return f"ws://127.0.0.1:{PORT}"


async def recv_kind(ws, want, timeout=60):
    while True:
        msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=timeout))
        if msg.get("kind") == want:
            return msg
        if msg.get("kind") == "error":
            sys.exit(f"server error while awaiting {want!r}: {msg}")


async def hello(ws, token):
    await ws.send(
        json.dumps(
            {"v": 1, "kind": "hello", "token": token, "client": {"name": "probe"}}
        )
    )
    return await recv_kind(ws, "welcome")


def cmd(sid, payload):
    return json.dumps({"v": 1, "kind": "command", "sessionId": sid, "payload": payload})


async def scenario_auth():
    async with websockets.connect(uri()) as ws:
        await hello(ws, TOKEN)
    try:
        async with websockets.connect(uri()) as ws:
            await ws.send(
                json.dumps(
                    {
                        "v": 1,
                        "kind": "hello",
                        "token": "wrong-token",
                        "client": {"name": "probe"},
                    }
                )
            )
            msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=10))
            if msg.get("kind") == "welcome":
                sys.exit("daemon accepted a wrong token")
    except (websockets.ConnectionClosed, asyncio.TimeoutError):
        pass  # rejection by close/silence is fine


async def scenario_sandbox():
    async with websockets.connect(uri()) as ws:
        await hello(ws, TOKEN)
        await ws.send(json.dumps({"v": 1, "kind": "create_session", "name": "probe"}))
        sid = (await recv_kind(ws, "attached"))["sessionId"]
        await ws.send(cmd(sid, {"type": "prompt", "message": PROBE_PROMPT}))

        transcript = []
        deadline = time.monotonic() + 120
        confirmed = False
        while time.monotonic() < deadline:
            try:
                msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=10))
            except asyncio.TimeoutError:
                continue
            transcript.append(msg)
            payload = msg.get("payload") or {}
            if (
                msg.get("kind") == "event"
                and payload.get("type") == "extension_ui_request"
                and not confirmed
            ):
                await ws.send(
                    cmd(
                        sid,
                        {
                            "type": "extension_ui_response",
                            "id": payload["id"],
                            "confirmed": True,
                        },
                    )
                )
                confirmed = True
            if msg.get("kind") == "event" and payload.get("type") == "agent_end":
                break
        else:
            sys.exit("turn never reached agent_end")

        dump = json.dumps(transcript)
        print(dump)
        if not confirmed:
            sys.exit("bash-confirm side channel never opened")
        if "HOME-DENIED" not in dump:
            sys.exit("probe command did not run or HOME was readable")
        if MARKER_SECRET in dump:
            sys.exit("marker content leaked into the event stream — HOME visible")


asyncio.run(scenario_auth() if SCENARIO == "auth" else scenario_sandbox())

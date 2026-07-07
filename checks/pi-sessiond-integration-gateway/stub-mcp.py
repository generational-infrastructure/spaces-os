#!/usr/bin/env python3
"""Stub integration MCP server for the gateway check.

NDJSON JSON-RPC 2.0 over a unix socket, like packages/integration-github but
trivial and dependency-free: initialize -> {}, tools/list -> two tools, and
tools/call -> a canned text result. Every tools/call is appended to CALLS_OUT so
the driver can assert that a denied call never reaches the server.

usage: stub-mcp.py <socket-path> <calls-out-path>
"""

import asyncio
import json
import os
import sys

SOCK = sys.argv[1]
CALLS_OUT = sys.argv[2]

TOOLS = [
    {
        "name": "get_repo",
        "description": "Fetch repository metadata",
        "inputSchema": {
            "type": "object",
            "properties": {"repo": {"type": "string"}},
            "required": ["repo"],
        },
    },
    {
        "name": "create_issue",
        "description": "Open an issue",
        "inputSchema": {
            "type": "object",
            "properties": {"repo": {"type": "string"}, "title": {"type": "string"}},
            "required": ["repo", "title"],
        },
    },
    {
        "name": "send",
        "description": "Send a message (confirm)",
        "inputSchema": {
            "type": "object",
            "properties": {
                "recipient": {"type": "string"},
                "name": {"type": "string"},
                "body": {"type": "string"},
            },
            "required": ["recipient", "name", "body"],
        },
    },
    {
        "name": "send_preview",
        "description": "Preview a send (gateway-only, never child-facing)",
        "inputSchema": {
            "type": "object",
            "properties": {
                "recipient": {"type": "string"},
                "name": {"type": "string"},
                "body": {"type": "string"},
            },
            "required": ["recipient", "name", "body"],
        },
    },
]


async def handle(reader, writer):
    while True:
        line = await reader.readline()
        if not line:
            break
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        method = msg.get("method")
        mid = msg.get("id")

        def send(result):
            writer.write(
                (
                    json.dumps({"jsonrpc": "2.0", "id": mid, "result": result}) + "\n"
                ).encode()
            )

        if method == "initialize":
            send({})
        elif method == "tools/list":
            send({"tools": TOOLS})
        elif method == "tools/call":
            params = msg.get("params") or {}
            name = params.get("name")
            args = params.get("arguments") or {}
            with open(CALLS_OUT, "a") as fh:
                fh.write(json.dumps({"name": name, "args": args}) + "\n")
            if name == "send_preview":
                # The gateway calls the preview tool before raising approval. A
                # "boom" body simulates a preview error → the gateway FAILS
                # CLOSED (tool errors, no approval, the real send never runs).
                if args.get("body") == "boom":
                    send(
                        {
                            "content": [
                                {
                                    "type": "text",
                                    "text": "preview failed: unknown recipient",
                                }
                            ],
                            "isError": True,
                        }
                    )
                else:
                    send(
                        {
                            "content": [
                                {
                                    "type": "text",
                                    "text": f"to: {args.get('name', '')} <{args.get('recipient', '')}>",
                                }
                            ],
                            "isError": False,
                        }
                    )
            else:
                send(
                    {
                        "content": [
                            {
                                "type": "text",
                                "text": f"ok:{name}:{json.dumps(args, sort_keys=True)}",
                            }
                        ],
                        "isError": False,
                    }
                )
        # notifications/initialized and anything else: no reply.
        await writer.drain()


async def main():
    if os.path.exists(SOCK):
        os.remove(SOCK)
    server = await asyncio.start_unix_server(handle, path=SOCK)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())

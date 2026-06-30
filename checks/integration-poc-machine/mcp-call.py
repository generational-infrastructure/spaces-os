#!/usr/bin/env python3
"""Minimal MCP client for the VM check: connect to an integration's activation
socket (triggering socket activation), do the initialize handshake, call one
tool, print its text result. Exits 3 if the tool reports isError.

usage: mcp-call.py <socket> <tool> <json-args>
"""

import json
import socket
import sys


def main():
    sockpath, tool, args = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sockpath)
    f = s.makefile("r")

    def send(obj):
        s.sendall((json.dumps(obj) + "\n").encode())

    send(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-03-26",
                "capabilities": {},
                "clientInfo": {"name": "probe", "version": "0"},
            },
        }
    )
    f.readline()  # initialize result
    send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    send(
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {"name": tool, "arguments": args},
        }
    )
    resp = json.loads(f.readline())
    result = resp.get("result", {})
    texts = [
        c.get("text", "") for c in result.get("content", []) if c.get("type") == "text"
    ]
    sys.stdout.write("\n".join(texts))
    if result.get("isError"):
        sys.exit(3)


if __name__ == "__main__":
    main()

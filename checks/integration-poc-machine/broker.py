#!/usr/bin/env python3
"""Minimal spaces-integrationd client for the VM check: one JSON request per
connection, print the JSON reply (the panel's IntegrationsBridge speaks the same
wire). The broker authorises via SO_PEERCRED (uid == self), so this must run as
the owning user.

usage: broker.py <socket> <op> [integration] [name] [value]
"""

import json
import socket
import sys


def main():
    sockpath, op = sys.argv[1], sys.argv[2]
    req = {"op": op}
    for key, idx in (("integration", 3), ("name", 4), ("value", 5)):
        if len(sys.argv) > idx:
            req[key] = sys.argv[idx]
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sockpath)
    s.sendall((json.dumps(req) + "\n").encode())
    s.shutdown(socket.SHUT_WR)
    buf = b""
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
    sys.stdout.write(buf.decode())


if __name__ == "__main__":
    main()

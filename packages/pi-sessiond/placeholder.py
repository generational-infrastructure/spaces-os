#!/usr/bin/env python3
"""Red-phase placeholder daemon: open the port, accept, drop.

Replaced by the real TypeScript pi-sessiond (WebSocket transport + sandboxed
`pi --mode rpc` session registry) in the green phase. Its only job is to make
the configured listener port reachable so checks/pi-remote-session/ fails at
the WebSocket/session protocol rather than at an unstarted service.

Honours the same env the real daemon reads for its bind address so the
NixOS module wiring is exercised unchanged when green lands.
"""

import os
import socket


def main():
    host = os.environ.get("SPACES_SESSIOND_HOST", "127.0.0.1")
    port = int(os.environ.get("SPACES_SESSIOND_PORT", "8770"))

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((host, port))
    sock.listen(16)

    while True:
        conn, _ = sock.accept()
        # No WebSocket handshake: the client's upgrade fails here, which is
        # the intended red. Green replaces this whole program.
        conn.close()


if __name__ == "__main__":
    main()

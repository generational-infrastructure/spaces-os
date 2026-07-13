# Minimal plaintext IMAP stub: greets, answers CAPABILITY, and rejects LOGIN.
# Just enough for himalaya to reach credential resolution (auth.cmd runs only
# once the connection is up) and attempt LOGIN. Prints the bound port on
# stdout; logs "LOGIN-ATTEMPTED" so the check can assert the auth.cmd secret
# actually made it to the wire.
import socket
import sys
import threading

srv = socket.socket()
srv.bind(("127.0.0.1", 0))
srv.listen(5)
print(srv.getsockname()[1], flush=True)


def handle(c):
    f = c.makefile("rwb")
    f.write(b"* OK IMAP4rev1 ready\r\n")
    f.flush()
    for line in f:
        parts = line.split()
        if not parts:
            continue
        tag = parts[0].decode("ascii", "replace")
        u = line.upper()
        if b"CAPABILITY" in u:
            f.write(b"* CAPABILITY IMAP4rev1 AUTH=PLAIN\r\n")
            f.write(f"{tag} OK done\r\n".encode())
        elif b"LOGIN" in u or b"AUTHENTICATE" in u:
            print("LOGIN-ATTEMPTED", file=sys.stderr, flush=True)
            f.write(f"{tag} NO login disabled\r\n".encode())
        elif b"LOGOUT" in u:
            f.write(f"{tag} OK bye\r\n".encode())
            f.flush()
            break
        else:
            f.write(f"{tag} NO nope\r\n".encode())
        f.flush()
    c.close()


while True:
    conn, _ = srv.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()

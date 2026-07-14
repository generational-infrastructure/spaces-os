# Minimal STARTTLS IMAP/SMTP stub that presents a caller-supplied
# certificate, used to prove that integration-proton's generated transports
# (himalaya IMAP config, msmtp send detour) trust a Bridge-style
# certificate (see ./default.nix). It is intentionally dumb: it only needs
# to get far enough for the client to validate the server certificate.
#
#   argv: <IMAP|SMTP> <certfile> <keyfile> <port>
#
# On a completed TLS handshake it prints "<KIND>_TLS_OK". The client's
# own output is what proves *client-side* trust (the server handshake can
# complete just before a client rejects post-handshake), so callers must
# also inspect the client's verdict for negative controls.
import socket
import ssl
import sys

kind, certfile, keyfile, port = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])


def readline(c, buf):
    while b"\r\n" not in buf:
        d = c.recv(4096)
        if not d:
            return None, buf
        buf += d
    line, _, rest = buf.partition(b"\r\n")
    return line, rest


def upgrade(conn):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(certfile, keyfile)
    return ctx.wrap_socket(conn, server_side=True)


def serve_imap(conn):
    conn.sendall(b"* OK [CAPABILITY IMAP4rev1 STARTTLS] stub ready\r\n")
    buf = b""
    while True:
        line, buf = readline(conn, buf)
        if line is None:
            return
        tag = line.split(b" ", 1)[0].decode(errors="replace")
        up = line.upper()
        if b"STARTTLS" in up:
            conn.sendall(f"{tag} OK begin TLS\r\n".encode())
            try:
                upgrade(conn)
            except Exception as e:
                print(f"IMAP_TLS_FAIL {e}", flush=True)
                return
            print("IMAP_TLS_OK", flush=True)
            return
        if b"CAPABILITY" in up:
            conn.sendall(b"* CAPABILITY IMAP4rev1 STARTTLS\r\n")
            conn.sendall(f"{tag} OK\r\n".encode())
        elif b"LOGOUT" in up:
            conn.sendall(f"{tag} OK\r\n".encode())
            return
        else:
            conn.sendall(f"{tag} OK\r\n".encode())


def serve_smtp(conn):
    conn.sendall(b"220 stub ESMTP\r\n")
    buf = b""
    while True:
        line, buf = readline(conn, buf)
        if line is None:
            return
        up = line.upper()
        if up.startswith((b"EHLO", b"HELO")):
            conn.sendall(b"250-stub\r\n250 STARTTLS\r\n")
        elif up.startswith(b"STARTTLS"):
            conn.sendall(b"220 ready\r\n")
            try:
                tconn = upgrade(conn)
            except Exception as e:
                print(f"SMTP_TLS_FAIL {e}", flush=True)
                return
            print("SMTP_TLS_OK", flush=True)
            try:
                tbuf = b""
                while True:
                    l2, tbuf = readline(tconn, tbuf)
                    if l2 is None:
                        return
                    if l2.upper().startswith(b"QUIT"):
                        tconn.sendall(b"221 bye\r\n")
                        return
                    tconn.sendall(b"250 ok\r\n")
            except Exception:
                return
        elif up.startswith(b"QUIT"):
            conn.sendall(b"221 bye\r\n")
            return
        else:
            conn.sendall(b"250 ok\r\n")


srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(1)
srv.settimeout(20)
print(f"{kind}_LISTEN {port}", flush=True)
try:
    conn, _ = srv.accept()
except TimeoutError:
    print(f"{kind}_TIMEOUT", flush=True)
    sys.exit(2)
conn.settimeout(20)
try:
    (serve_imap if kind == "IMAP" else serve_smtp)(conn)
finally:
    try:
        conn.close()
    except Exception:
        pass

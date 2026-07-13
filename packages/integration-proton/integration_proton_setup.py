"""Proton Mail setup helper (spaces integration setup channel v2).

Speaks the broker's setup-channel v2 protocol over the socket-activated
connection (reusing spaces_integration_mcp._listen exactly like the server) and
drives a *transient* `protonmail-bridge --grpc` instance to sign the user in (or
sign them out, in remove mode). The steady-state daemon is parked by the broker
(setupPark) for the duration, because Bridge is single-instance-locked.

link flow:
  1. read the broker's action line
  2. spawn `protonmail-bridge --grpc` with the pinned XDG env, poll for
     grpcServerConfig.json, open a TLS + server-token gRPC channel
  3. subscribe RunEventStream FIRST (login events race the Login call) and
     await allUsersLoaded (users load async; listing earlier races to [])
  4. if a user is already connected, skip login (idempotent credential refresh)
  5. prompt email + password -> Login
  6. drive the login event stream (2FA / mailbox-password round-trips; typed
     human errors; FIDO-only accounts rejected with a use-TOTP hint)
  7. GetUser -> bridge password
  8. SetMailServerSettings (pin 1143/1025 STARTTLS), await the finished event
  9. ExportTLSCertificates -> poll for cert.pem on disk (Bridge v3 keeps the
     cert in its vault; the server's bridge_probe and configs need the file)
 10. Quit the transient Bridge (SIGTERM fallback on the way out)
 11. set-field email (config) + bridge_password (secret) -> done

remove flow: transient Bridge -> await allUsersLoaded -> GetUserList ->
RemoveUser (match the profile's email, else the sole user; none -> idempotent
done) -> Quit -> done.

Every outcome emits exactly one terminal done/error line and exits 0 (a flow
failure is a protocol event, not a crash). No set-field is emitted before the
vendor login reports finished, so a failed flow never touches the store.
"""

import base64
import contextlib
import json
import os
import shutil
import subprocess
import sys
import time

import bridge_pb2 as pb
import bridge_pb2_grpc as pb_grpc
import grpc
from google.protobuf.empty_pb2 import Empty
from google.protobuf.wrappers_pb2 import StringValue

# The MCP server's socket-activation accept mechanism is reused verbatim, and
# the store reader is used to resolve a profile's email in remove mode.
from spaces_integration_mcp import _listen, store_profile

SERVER_NAME = "integration-proton-setup"

# Resolved via PATH so tests can shadow it with a fake executable.
BRIDGE_BINARY = "protonmail-bridge"

CLIENT_PLATFORM = "spaces"

# Pinned mail-server ports (STARTTLS both ways) the Bridge must expose; the
# server module pins the same values for himalaya/msmtp.
IMAP_PORT = 1143
SMTP_PORT = 1025


def _wire_pw(secret: str) -> bytes:
    """LoginRequest.password on the wire: Bridge base64Decode()s every
    Login/Login2FA/Login2Passwords password (grpc/service_methods.go) and
    fails login on raw bytes ("Cannot decode password")."""
    return base64.b64encode(secret.encode("utf-8"))


# Bridge's serving cert CN/SAN (internal/certs/tls.go) — the TLS name the client
# must verify against, even over a unix socket.
_TLS_NAME = "127.0.0.1"

_STATE_ENV = "SPACES_PROTON_BRIDGE_STATE"
_DEFAULT_STATE = "~/.local/state/protonmail-bridge"

# The transient Bridge writes grpcServerConfig.json (temp+rename) shortly after
# start; poll for it. Login blocks on the human, so it gets a generous window.
_CONFIG_POLL_DEADLINE = 30.0
_CONFIG_POLL_INTERVAL = 0.2
_CHANNEL_READY_TIMEOUT = 15.0
_LOGIN_TIMEOUT = 300.0
_SETTINGS_TIMEOUT = 60.0
_QUIT_TIMEOUT = 10.0
# ExportTLSCertificates is a fire-and-forget goroutine server-side (no success
# event, only error events); poll for cert.pem landing on disk. A local file
# write either happens promptly or the export failed.
_CERT_EXPORT_DEADLINE = 30.0

_FIDO_ONLY_MSG = (
    "this account only offers a security key (FIDO2) for two-factor "
    "authentication; add a TOTP authenticator app in your Proton account "
    "settings and retry"
)


class _Fail(Exception):
    """A terminal, human-facing setup failure (mapped to one `error` event)."""


# ── broker channel I/O ──────────────────────────────────────────────


def _emit(conn, event):
    conn.sendall(json.dumps(event).encode("utf-8") + b"\n")


def _safe_emit(conn, event):
    with contextlib.suppress(OSError):
        _emit(conn, event)


def _read_line(reader):
    line = reader.readline()
    if not line:
        raise _Fail("the setup connection closed before a reply arrived")
    return line


def _prompt(conn, reader, event, field, label):
    """Emit a prompt and read exactly one reply line before anything else."""
    _emit(conn, {"event": event, "field": field, "label": label})
    try:
        reply = json.loads(_read_line(reader))
    except ValueError as exc:
        raise _Fail(f"malformed reply for {field}: {exc}")
    value = reply.get("value")
    if not value:
        raise _Fail(f"no value provided for {field}")
    return value


def _set_field(conn, profile, field, value):
    # Broker-intercepted: never relayed to the panel; routes config vs secret.
    _emit(
        conn, {"event": "set-field", "profile": profile, "field": field, "value": value}
    )


# ── transient Bridge lifecycle ──────────────────────────────────────


def _state_root():
    return os.path.expanduser(os.environ.get(_STATE_ENV) or _DEFAULT_STATE)


def _bridge_env():
    """os.environ plus the XDG pins the resurrected daemon and the setup helper
    share (proton-bridge-facts). DBUS unset makes Bridge fall back to the `pass`
    keychain deterministically."""
    state = _state_root()
    env = os.environ.copy()
    env["XDG_CONFIG_HOME"] = os.path.join(state, "config")
    env["XDG_DATA_HOME"] = os.path.join(state, "data")
    env["XDG_CACHE_HOME"] = os.path.join(state, "cache")
    env["GNUPGHOME"] = os.path.join(state, "gnupg")
    env["PASSWORD_STORE_DIR"] = os.path.join(state, "password-store")
    env.pop("DBUS_SESSION_BUS_ADDRESS", None)
    return env


def _config_path(env):
    return os.path.join(
        env["XDG_CONFIG_HOME"], "protonmail", "bridge-v3", "grpcServerConfig.json"
    )


def _poll_config(path):
    """Poll for a fully-written grpcServerConfig.json. temp+rename means a
    partial read/parse just means "not ready yet" -> retry."""
    deadline = time.monotonic() + _CONFIG_POLL_DEADLINE
    while True:
        try:
            with open(path, "rb") as f:
                cfg = json.load(f)
            if (
                cfg.get("token")
                and cfg.get("cert")
                and (cfg.get("fileSocketPath") or cfg.get("port"))
            ):
                return cfg
        except (OSError, ValueError):
            pass
        if time.monotonic() >= deadline:
            raise _Fail("Proton Bridge did not become ready (no gRPC config file)")
        time.sleep(_CONFIG_POLL_INTERVAL)


def _make_channel(cfg):
    creds = grpc.ssl_channel_credentials(root_certificates=cfg["cert"].encode("utf-8"))
    if cfg.get("fileSocketPath"):
        target = "unix:" + cfg["fileSocketPath"]
    else:
        target = f"{_TLS_NAME}:{cfg['port']}"
    channel = grpc.secure_channel(
        target, creds, options=[("grpc.ssl_target_name_override", _TLS_NAME)]
    )
    try:
        grpc.channel_ready_future(channel).result(timeout=_CHANNEL_READY_TIMEOUT)
    except grpc.FutureTimeoutError:
        channel.close()
        raise _Fail("could not open a gRPC channel to Proton Bridge")
    return channel


def _terminate(proc):
    """SIGTERM fallback after the graceful rpc Quit; escalate to kill if needed."""
    if proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=_QUIT_TIMEOUT)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()


@contextlib.contextmanager
def _bridge():
    """Spawn a transient `protonmail-bridge --grpc`, yield (stub, metadata), and
    guarantee the instance and channel are torn down on exit."""
    env = _bridge_env()
    cfg_path = _config_path(env)
    os.makedirs(os.path.dirname(cfg_path), exist_ok=True)
    # Drop a stale config so we poll for THIS instance's freshly written file.
    with contextlib.suppress(FileNotFoundError):
        os.unlink(cfg_path)

    binary = shutil.which(BRIDGE_BINARY) or BRIDGE_BINARY
    proc = subprocess.Popen([binary, "--grpc"], env=env)
    channel = None
    try:
        cfg = _poll_config(cfg_path)
        channel = _make_channel(cfg)
        stub = pb_grpc.BridgeStub(channel)
        md = (("server-token", cfg["token"]),)
        yield stub, md
    finally:
        if channel is not None:
            channel.close()
        _terminate(proc)


# ── login stream driving ────────────────────────────────────────────


def _rpc_text(exc):
    try:
        return exc.details() or exc.code().name
    except Exception:  # noqa: BLE001
        return str(exc)


def _login_error_text(err):
    t = err.type
    if t == pb.FREE_USER:
        return (
            "Proton Mail Bridge requires a paid Proton plan; upgrade your Proton "
            "account and retry"
        )
    if t == pb.USERNAME_PASSWORD_ERROR:
        return "Proton rejected the email or password; double-check them and retry"
    if t == pb.CONNECTION_ERROR:
        return "could not reach Proton to sign in; check your connection and retry"
    return f"Proton sign-in failed: {err.message or 'unknown error'}"


def _drive_login(conn, reader, stub, md, events, email):
    """Consume login events until finished/alreadyLoggedIn (returns the userID),
    answering 2FA / mailbox-password prompts and mapping typed errors."""
    try:
        for ev in events:
            if ev.WhichOneof("event") != "login":
                continue
            le = ev.login
            kind = le.WhichOneof("event")
            if kind == "finished":
                return le.finished.userID
            if kind == "alreadyLoggedIn":
                return le.alreadyLoggedIn.userID
            if kind == "error":
                raise _Fail(_login_error_text(le.error))
            if kind in ("tfaRequested", "tfaOrFidoRequested"):
                code = _prompt(
                    conn,
                    reader,
                    "secret-field",
                    "totp",
                    "Proton two-factor authentication code",
                )
                stub.Login2FA(
                    pb.LoginRequest(username=email, password=_wire_pw(code)),
                    metadata=md,
                )
                continue
            if kind == "twoPasswordRequested":
                mbox = _prompt(
                    conn,
                    reader,
                    "secret-field",
                    "mailbox_password",
                    "Proton mailbox (second) password",
                )
                stub.Login2Passwords(
                    pb.LoginRequest(username=email, password=_wire_pw(mbox)),
                    metadata=md,
                )
                continue
            if kind in (
                "fidoRequested",
                "loginFidoTouchRequested",
                "loginFidoTouchCompleted",
                "loginFidoPinRequired",
            ):
                raise _Fail(_FIDO_ONLY_MSG)
            if kind == "hvRequested":
                raise _Fail(
                    "Proton requested human verification (CAPTCHA), which this "
                    "setup can't complete; sign in once via the Proton Bridge app, "
                    "then retry"
                )
            # Any other login event: ignore and keep waiting.
    except grpc.RpcError as exc:
        raise _Fail(f"lost contact with Proton Bridge during login: {_rpc_text(exc)}")
    raise _Fail("Proton Bridge closed the login stream before finishing")


def _await_settings(events):
    try:
        for ev in events:
            if ev.WhichOneof("event") != "mailServerSettings":
                continue
            kind = ev.mailServerSettings.WhichOneof("event")
            if kind == "changeMailServerSettingsFinished":
                return
            if kind == "error":
                raise _Fail(
                    "Proton Bridge could not apply the pinned mail-server ports"
                )
    except grpc.RpcError as exc:
        raise _Fail(
            f"lost contact with Proton Bridge applying settings: {_rpc_text(exc)}"
        )
    raise _Fail("Proton Bridge closed the stream before confirming the port settings")


# ── users ───────────────────────────────────────────────────────────


def _await_users_loaded(events):
    """Block until Bridge reports allUsersLoaded. Users load ASYNC after the
    gRPC server is up (bridge.goLoad publishes the event when done), and the
    event is queued server-side until the first RunEventStream subscriber —
    so a subscriber can never miss it. A GetUserList racing the load sees an
    empty list: link() would re-prompt full credentials on an already-linked
    vault, remove() would silently no-op."""
    try:
        for ev in events:
            if (
                ev.WhichOneof("event") == "app"
                and ev.app.WhichOneof("event") == "allUsersLoaded"
            ):
                return
    except grpc.RpcError as exc:
        raise _Fail(
            f"lost contact with Proton Bridge loading users: {_rpc_text(exc)}"
        )
    raise _Fail("Proton Bridge closed the stream before loading users")


def _user_email(user):
    return user.addresses[0] if user.addresses else user.username


def _connected_user(stub, md):
    for u in stub.GetUserList(Empty(), metadata=md).users:
        if u.state == pb.CONNECTED:
            return u
    return None


def _profile_email(profile):
    try:
        return store_profile(profile).get("email")
    except Exception:  # noqa: BLE001 — store access is best-effort here
        return None


def _match_user(users, profile):
    email = _profile_email(profile)
    if email:
        for u in users:
            if email == u.username or email in u.addresses:
                return u
    if len(users) == 1:
        return users[0]
    return None


# ── TLS cert export ─────────────────────────────────────────────────


def _export_cert(stub, md):
    """Put Bridge's serving cert on disk where the server module's
    bridge_probe and the generated himalaya/msmtp configs expect it
    (<state>/config/protonmail/bridge-v3/cert.pem). Bridge v3 keeps the cert
    in its vault and never writes cert.pem on its own; without this export
    every mail tool fails the precheck forever."""
    folder = os.path.join(
        _bridge_env()["XDG_CONFIG_HOME"], "protonmail", "bridge-v3"
    )
    stub.ExportTLSCertificates(StringValue(value=folder), metadata=md)
    cert = os.path.join(folder, "cert.pem")
    deadline = time.monotonic() + _CERT_EXPORT_DEADLINE
    # The server-side goroutine writes cert.pem then key.pem with no rename;
    # key.pem appearing means cert.pem is complete.
    key = os.path.join(folder, "key.pem")
    while not (os.path.exists(cert) and os.path.exists(key)):
        if time.monotonic() >= deadline:
            raise _Fail("Proton Bridge did not export its TLS certificate")
        time.sleep(_CONFIG_POLL_INTERVAL)


# ── flows ───────────────────────────────────────────────────────────


def link(conn, reader, profile):
    with _bridge() as (stub, md):
        # RunEventStream FIRST: login events race the Login call.
        events = stub.RunEventStream(
            pb.EventStreamRequest(ClientPlatform=CLIENT_PLATFORM),
            metadata=md,
            timeout=_LOGIN_TIMEOUT,
        )

        _await_users_loaded(events)
        connected = _connected_user(stub, md)
        if connected is not None:
            user_id = connected.id
            email = _user_email(connected)
        else:
            email = _prompt(conn, reader, "text-field", "email", "Proton account email")
            password = _prompt(
                conn, reader, "secret-field", "password", "Proton account password"
            )
            stub.Login(
                pb.LoginRequest(username=email, password=_wire_pw(password)),
                metadata=md,
            )
            user_id = _drive_login(conn, reader, stub, md, events, email)

        user = stub.GetUser(StringValue(value=user_id), metadata=md)
        bridge_password = bytes(user.password).decode("utf-8")
        email = email or _user_email(user)

        stub.SetMailServerSettings(
            pb.ImapSmtpSettings(
                imapPort=IMAP_PORT,
                smtpPort=SMTP_PORT,
                useSSLForImap=False,
                useSSLForSmtp=False,
            ),
            metadata=md,
        )
        _await_settings(events)
        _export_cert(stub, md)

        with contextlib.suppress(grpc.RpcError):
            stub.Quit(Empty(), metadata=md)

        # Only now — vendor login finished — do we touch the store.
        _set_field(conn, profile, "email", email)
        _set_field(conn, profile, "bridge_password", bridge_password)
        _emit(conn, {"event": "done"})


def remove(conn, reader, profile):
    with _bridge() as (stub, md):
        events = stub.RunEventStream(
            pb.EventStreamRequest(ClientPlatform=CLIENT_PLATFORM),
            metadata=md,
            timeout=_LOGIN_TIMEOUT,
        )
        _await_users_loaded(events)
        users = list(stub.GetUserList(Empty(), metadata=md).users)
        if not users:
            _emit(conn, {"event": "done"})  # nothing to remove — idempotent
            return
        target = _match_user(users, profile)
        if target is None:
            raise _Fail("could not identify which Proton account to remove")
        stub.RemoveUser(StringValue(value=target.id), metadata=md)
        with contextlib.suppress(grpc.RpcError):
            stub.Quit(Empty(), metadata=md)
        _emit(conn, {"event": "done"})


def _read_action(reader):
    line = reader.readline()
    if not line:
        return {}
    try:
        return json.loads(line)
    except ValueError:
        return {}


def main():
    sock = _listen(SERVER_NAME)
    if sock is None:
        return 2
    try:
        conn, _ = sock.accept()
    except OSError as exc:
        print(f"{SERVER_NAME}: accept failed: {exc}", file=sys.stderr)
        return 2
    with conn:
        reader = conn.makefile("rb")
        try:
            action = _read_action(reader)
            profile = action.get("profile") or "default"
            if action.get("action") == "remove":
                remove(conn, reader, profile)
            else:
                link(conn, reader, profile)
        except _Fail as exc:
            _safe_emit(conn, {"event": "error", "error": str(exc)})
        except OSError:
            pass  # broker hung up mid-stream
        except Exception as exc:  # noqa: BLE001 — never crash on a failed flow
            _safe_emit(
                conn,
                {
                    "event": "error",
                    "error": f"unexpected setup failure: {exc.__class__.__name__}: {exc}",
                },
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())

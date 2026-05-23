"""Always-up bridge between signal-cli's daemon and the distro agent.

Three concurrent jobs in one process:

1. **Receiver** — subscribes to every linked account on the
   signal-cli daemon socket and writes each incoming envelope into
   `messages.db`. Subscription stays alive for the daemon's lifetime;
   if the socket drops, the supervisor reconnects on a short backoff.

2. **Enqueue listener** — bound to `$XDG_RUNTIME_DIR/distro-signal-enqueue.sock`
   and bind-mounted RW into the pi-chat sandbox. Sandbox-side CLIs
   (the `signal send` command) talk to this socket. Self-sends are
   dispatched immediately; everything else lands in `pending_sends`
   and returns a token the agent must hand back to the human.

3. **Panel listener** — bound to `$XDG_RUNTIME_DIR/distro-signal-panel.sock`
   and **NOT** bound into the sandbox. The noctalia chat panel reads
   `{op:"list"}` to render pending approval cards and posts
   `{op:"approve"/"deny"}` to dispatch or cancel them. The split-socket
   shape is the security boundary: prompt injection through an
   incoming Signal message cannot mint an approval, because the
   approval channel is unreachable from inside the sandbox.

Self-detection is based on the daemon's `listAccounts` snapshot
(taken on connect, refreshed every few minutes). A recipient that
matches any of our accounts by phone number or UUID bypasses the
confirmation queue — the same shape vbuterin/messaging-daemon ships,
adapted to multi-account mode.
"""

from __future__ import annotations

import json
import logging
import os
import secrets
import socket
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable

from . import db as dbmod
from .jsonrpc import JsonRpcClient, JsonRpcError

log = logging.getLogger("distro_signal.bridge")

DEFAULT_DAEMON_SOCKET_ENV = "DISTRO_SIGNAL_DAEMON_SOCKET"
DEFAULT_ENQUEUE_SOCKET_ENV = "DISTRO_SIGNAL_ENQUEUE_SOCKET"
DEFAULT_PANEL_SOCKET_ENV = "DISTRO_SIGNAL_PANEL_SOCKET"


def _default_daemon_socket() -> str:
    env = os.environ.get(DEFAULT_DAEMON_SOCKET_ENV)
    if env:
        return env
    runtime = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    return f"{runtime}/signal-cli/socket"


def _default_enqueue_socket() -> str:
    env = os.environ.get(DEFAULT_ENQUEUE_SOCKET_ENV)
    if env:
        return env
    runtime = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    return f"{runtime}/distro-signal-enqueue.sock"


def _default_panel_socket() -> str:
    env = os.environ.get(DEFAULT_PANEL_SOCKET_ENV)
    if env:
        return env
    runtime = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    return f"{runtime}/distro-signal-panel.sock"


# ── helpers ─────────────────────────────────────────────────────────


def envelope_to_message(envelope: dict, account: dict | None = None) -> dict | None:
    """Normalise a signal-cli `receive` notification into the shape
    `db.store_message` expects. Returns None for envelopes that carry
    no user-visible content (typing indicators, receipts, …).
    """
    env = envelope.get("envelope") or envelope
    data = env.get("dataMessage") or {}
    body = data.get("message")
    if body is None and not data.get("attachments"):
        # Typing/receipt-only envelopes: nothing the agent can read.
        return None

    ts = env.get("timestamp") or data.get("timestamp") or dbmod.now_ms()
    source_uuid = env.get("sourceUuid") or env.get("source")
    source_number = env.get("sourceNumber")
    source_name = env.get("sourceName")

    group_info = data.get("groupInfo") or {}
    group_id = group_info.get("groupId")
    if group_id:
        thread_id = group_id
        thread_kind = "group"
    else:
        # DM: thread_id is the other side. For sync messages (sent from
        # another linked device of *this* account), `destination` carries
        # the conversation partner.
        destination = data.get("destination") or env.get("destinationUuid")
        if account and source_uuid == account.get("uuid"):
            thread_id = destination or source_uuid or "self"
            thread_kind = "self" if thread_id == source_uuid else "dm"
        else:
            thread_id = source_uuid or env.get("source") or "unknown"
            thread_kind = "dm"

    expires_at_ms = None
    expires_in_seconds = data.get("expiresInSeconds") or 0
    if expires_in_seconds:
        expires_at_ms = int(ts) + int(expires_in_seconds) * 1000

    return {
        "uid": f"{ts}_{source_uuid or source_number or 'unknown'}",
        "account_uuid": account.get("uuid") if account else None,
        "ts_ms": int(ts),
        "sender_uuid": source_uuid,
        "sender_name": source_name,
        "sender_number": source_number,
        "thread_id": str(thread_id),
        "thread_kind": thread_kind,
        "body": body,
        "attachments_json": data.get("attachments"),
        "expires_at_ms": expires_at_ms,
        "metadata_json": envelope,
    }


def classify_recipient(value: str) -> str:
    """Return one of 'number', 'uuid', 'username', 'group'.

    Mirrors vbuterin/messaging-daemon's classifier; the daemon's
    `send` RPC accepts these as distinct argument shapes.
    """
    value = value.strip()
    if value.startswith("+"):
        return "number"
    if len(value) == 36 and value.count("-") == 4:
        return "uuid"
    if "." in value and len(value) < 40:
        return "username"
    return "group"


def is_self_recipient(recipient: str, accounts: Iterable[dict]) -> bool:
    """True iff recipient matches any of our linked-account
    identities by UUID or phone number."""
    recipient = recipient.strip()
    for acct in accounts:
        if recipient == acct.get("uuid"):
            return True
        if recipient == acct.get("number"):
            return True
    return False


# ── core ────────────────────────────────────────────────────────────


@dataclass
class BridgeConfig:
    db_path: Path
    daemon_socket: str
    enqueue_socket: str
    panel_socket: str


class DaemonClientFactory:
    """Default factory: returns a real JsonRpcClient against the
    daemon socket. Tests inject a stub that yields a fake client
    talking to an in-process FakeSignalDaemon.
    """

    def __init__(self, sock_path: str) -> None:
        self.sock_path = sock_path

    def __call__(
        self,
        *,
        on_notification=None,
        on_close=None,
    ) -> JsonRpcClient:
        return JsonRpcClient(
            self.sock_path,
            on_notification=on_notification,
            on_close=on_close,
        )


class Bridge:
    def __init__(
        self,
        config: BridgeConfig,
        *,
        daemon_client_factory: Callable[[], JsonRpcClient] | None = None,
        accounts_refresh_seconds: float = 300.0,
    ) -> None:
        self.config = config
        self._db_lock = threading.Lock()
        self.db = dbmod.connect(config.db_path)
        self._client_factory = daemon_client_factory or DaemonClientFactory(
            config.daemon_socket
        )
        self._accounts_refresh_seconds = accounts_refresh_seconds

        self._accounts: list[dict] = []
        self._accounts_lock = threading.Lock()

        self._stop = threading.Event()
        self._threads: list[threading.Thread] = []
        self._sockets: list[socket.socket] = []

        # Panel subscribers: long-lived conns that received an
        # {op:"subscribe"} request and are now waiting for live
        # `added`/`removed` events as pending sends mutate. The write
        # lock serialises broadcasts so we don't interleave bytes
        # from concurrent updates.
        self._panel_subscribers: list[socket.socket] = []
        self._panel_subs_lock = threading.Lock()
        self._panel_write_lock = threading.Lock()

        # Two daemon clients: one long-lived for the receive
        # subscription (reads notifications via its own reader thread)
        # and one for short-lived RPC calls (send, listAccounts,
        # listContacts) issued from the listener threads. They're
        # split mostly to isolate failure domains — a `send` error
        # path that closes the RPC client must not also tear down the
        # subscription, and vice versa.
        self._rpc_client: JsonRpcClient | None = None
        self._sub_client: JsonRpcClient | None = None

    # ── lifecycle ───────────────────────────────────────────────────

    def start(self) -> None:
        # Open the short-lived RPC client + populate accounts before
        # any listener accepts a connection so self-detection works on
        # the very first send.
        self._rpc_client = self._client_factory()
        self._refresh_accounts()

        self._spawn(self._run_receiver, name="receiver")
        self._spawn(self._run_enqueue_listener, name="enqueue")
        self._spawn(self._run_panel_listener, name="panel")
        self._spawn(self._run_accounts_refresher, name="accounts-refresh")

    def stop(self) -> None:
        self._stop.set()
        for s in self._sockets:
            try:
                s.close()
            except OSError:
                pass
        if self._sub_client is not None:
            self._sub_client.close()
        if self._rpc_client is not None:
            self._rpc_client.close()
        for t in self._threads:
            t.join(timeout=5.0)
        with self._db_lock:
            self.db.close()

    def join(self) -> None:
        for t in self._threads:
            t.join()

    def _spawn(self, fn: Callable[[], None], *, name: str) -> None:
        t = threading.Thread(target=fn, name=f"bridge-{name}", daemon=True)
        t.start()
        self._threads.append(t)

    # ── accounts cache ──────────────────────────────────────────────

    def _refresh_accounts(self) -> None:
        try:
            result = self._rpc_client.call("listAccounts")
        except (JsonRpcError, OSError, TimeoutError) as exc:
            log.warning("listAccounts failed: %s", exc)
            return
        accounts: list[dict] = []
        if isinstance(result, list):
            for item in result:
                if isinstance(item, dict):
                    accounts.append(
                        {
                            "uuid": item.get("uuid") or item.get("accountUuid"),
                            "number": item.get("number") or item.get("account"),
                        }
                    )
        with self._accounts_lock:
            self._accounts = accounts
        log.info("refreshed accounts: %r", accounts)

    def _accounts_snapshot(self) -> list[dict]:
        with self._accounts_lock:
            return list(self._accounts)

    def _run_accounts_refresher(self) -> None:
        while not self._stop.wait(self._accounts_refresh_seconds):
            self._refresh_accounts()

    # ── receiver ────────────────────────────────────────────────────

    def _run_receiver(self) -> None:
        backoff = 1.0
        while not self._stop.is_set():
            ready = threading.Event()
            try:
                # The client owns a background reader thread that
                # dispatches both responses (back to call() waiters)
                # and `receive` notifications (to our handler). We
                # subscribe inline, then block on the client's close
                # event — the read loop wakes us up when the daemon
                # disconnects or we're asked to stop.
                def on_note(method: str, params: object) -> None:
                    if method != "receive":
                        return
                    if not isinstance(params, dict):
                        return
                    self._handle_receive(params)

                def on_close() -> None:
                    ready.set()

                self._sub_client = self._client_factory(
                    on_notification=on_note, on_close=on_close
                )
                accounts = self._accounts_snapshot()
                if not accounts:
                    # Linked-but-unverified: signal-cli may still be
                    # syncing. Try again after a beat — listAccounts
                    # will eventually populate.
                    self._sub_client.close()
                    self._sub_client = None
                    self._stop.wait(5.0)
                    continue
                for acct in accounts:
                    params = {"account": acct.get("number") or acct.get("uuid")}
                    try:
                        self._sub_client.call("subscribeReceive", params)
                    except JsonRpcError as exc:
                        log.warning("subscribeReceive(%s) failed: %s", params, exc)
                # Wait until the daemon socket closes (peer hangup or
                # explicit stop()). The reader thread fires on_close.
                while not self._stop.is_set() and not ready.is_set():
                    ready.wait(0.5)
                backoff = 1.0
            except (OSError, TimeoutError) as exc:
                log.warning("receiver lost daemon connection: %s", exc)
            finally:
                if self._sub_client is not None:
                    self._sub_client.close()
                    self._sub_client = None
            if self._stop.is_set():
                break
            # Cap exponential backoff at 30s — daemon restarts on
            # systemd Restart=always with 5s, so 30s is plenty.
            self._stop.wait(backoff)
            backoff = min(backoff * 2, 30.0)

    def _handle_receive(self, params: dict) -> None:
        # signal-cli wraps the envelope as either
        #   {envelope: {...}, account: "+..."}  or
        #   {envelope: {...}}
        account_id = params.get("account")
        accounts = self._accounts_snapshot()
        acct = None
        if account_id:
            for a in accounts:
                if a.get("uuid") == account_id or a.get("number") == account_id:
                    acct = a
                    break
        msg = envelope_to_message(params, acct)
        if msg is None:
            return
        with self._db_lock:
            inserted = dbmod.store_message(self.db, msg)
        if inserted:
            log.debug("stored message uid=%s thread=%s", msg["uid"], msg["thread_id"])

    # ── enqueue listener ────────────────────────────────────────────

    def _run_enqueue_listener(self) -> None:
        self._serve_socket(self.config.enqueue_socket, self._handle_enqueue_conn)

    def _handle_enqueue_conn(self, conn: socket.socket) -> None:
        try:
            for req in _ndjson_requests(conn):
                resp = self._handle_enqueue_request(req)
                conn.sendall((json.dumps(resp) + "\n").encode("utf-8"))
        except Exception as exc:  # noqa: BLE001
            log.warning("enqueue conn errored: %s", exc)
        finally:
            conn.close()

    def _handle_enqueue_request(self, req: dict) -> dict:
        op = req.get("op")
        if op != "send":
            return {"ok": False, "error": f"unknown op: {op!r}"}
        recipient = (req.get("to") or "").strip()
        body = req.get("body") or ""
        if not recipient or not body:
            return {"ok": False, "error": "missing 'to' or 'body'"}

        accounts = self._accounts_snapshot()
        if not accounts:
            return {"ok": False, "error": "no linked Signal account"}
        # Multi-account: prefer explicit; fall back to first.
        account = req.get("from")
        if account:
            acct = next(
                (
                    a
                    for a in accounts
                    if a.get("uuid") == account or a.get("number") == account
                ),
                None,
            )
            if acct is None:
                return {"ok": False, "error": f"unknown account: {account!r}"}
        else:
            acct = accounts[0]

        # Self-send: dispatch immediately, no confirmation gate.
        if is_self_recipient(recipient, [acct]):
            try:
                self._dispatch_send(acct, recipient, body)
            except (JsonRpcError, OSError, TimeoutError) as exc:
                return {"ok": False, "error": f"send failed: {exc}"}
            return {"ok": True, "to_self": True}

        # Non-self: queue for human approval.
        token = secrets.token_urlsafe(24)
        display_name = self._resolve_display_name(acct, recipient)
        with self._db_lock:
            dbmod.insert_pending(
                self.db,
                token=token,
                recipient=recipient,
                body=body,
                display_name=display_name,
                account_uuid=acct.get("uuid"),
            )
        with self._db_lock:
            row = dbmod.get_pending(self.db, token)
        if row is not None:
            self._broadcast_panel({"op": "added", "request": row})
        return {
            "ok": True,
            "pending": True,
            "token": token,
            "display_name": display_name,
        }

    def _dispatch_send(self, account: dict, recipient: str, body: str) -> None:
        kind = classify_recipient(recipient)
        params: dict = {
            "account": account.get("number") or account.get("uuid"),
            "message": body,
        }
        if kind == "group":
            params["groupId"] = recipient
        elif kind == "number":
            params["recipient"] = [recipient]
        elif kind == "uuid":
            params["recipient"] = [recipient]
        else:  # username
            params["username"] = [recipient]
        assert self._rpc_client is not None
        self._rpc_client.call("send", params)

    def _resolve_display_name(self, account: dict, recipient: str) -> str:
        kind = classify_recipient(recipient)
        if not self._rpc_client:
            return recipient
        try:
            if kind == "group":
                groups = self._rpc_client.call(
                    "listGroups",
                    {"account": account.get("number") or account.get("uuid")},
                )
                if isinstance(groups, list):
                    for g in groups:
                        if isinstance(g, dict) and g.get("id") == recipient:
                            return str(g.get("name") or recipient)
            elif kind in ("number", "uuid"):
                contacts = self._rpc_client.call(
                    "listContacts",
                    {"account": account.get("number") or account.get("uuid")},
                )
                if isinstance(contacts, list):
                    for c in contacts:
                        if not isinstance(c, dict):
                            continue
                        if c.get("uuid") == recipient or c.get("number") == recipient:
                            name = c.get("name")
                            if not name:
                                profile = c.get("profile") or {}
                                given = profile.get("givenName") or ""
                                family = profile.get("familyName") or ""
                                name = (given + " " + family).strip()
                            return str(name or c.get("number") or recipient)
        except (JsonRpcError, OSError, TimeoutError) as exc:
            log.debug("display-name lookup failed: %s", exc)
        return recipient

    # ── panel listener ──────────────────────────────────────────────

    def _run_panel_listener(self) -> None:
        self._serve_socket(self.config.panel_socket, self._handle_panel_conn)

    def _handle_panel_conn(self, conn: socket.socket) -> None:
        try:
            for req in _ndjson_requests(conn):
                resp = self._handle_panel_request(req, conn)
                if resp is None:
                    continue
                self._panel_write(conn, resp)
        except Exception as exc:  # noqa: BLE001
            log.warning("panel conn errored: %s", exc)
        finally:
            self._unsubscribe_panel(conn)
            try:
                conn.close()
            except OSError:
                pass

    def _handle_panel_request(self, req: dict, conn: socket.socket) -> dict | None:
        op = req.get("op")
        if op == "list":
            with self._db_lock:
                pending = dbmod.list_pending(self.db, states=["pending"])
            return {"op": "snapshot", "ok": True, "pending": pending}
        if op == "subscribe":
            # Register first, snapshot under the same lock so the
            # subscriber can't miss an event that lands between the
            # snapshot read and the registration. The initial snapshot
            # is itself a response — return it to be written.
            with self._db_lock:
                pending = dbmod.list_pending(self.db, states=["pending"])
            with self._panel_subs_lock:
                if conn not in self._panel_subscribers:
                    self._panel_subscribers.append(conn)
            return {"op": "snapshot", "ok": True, "pending": pending}
        if op == "approve":
            return self._panel_decide(req.get("token"), approve=True)
        if op == "deny":
            return self._panel_decide(req.get("token"), approve=False)
        return {"op": "error", "ok": False, "error": f"unknown op: {op!r}"}

    def _panel_decide(self, token: str | None, *, approve: bool) -> dict:
        if not token:
            return {"op": "decision", "ok": False, "error": "missing 'token'"}
        with self._db_lock:
            row = dbmod.get_pending(self.db, token)
        if row is None:
            return {"op": "decision", "ok": False, "error": "unknown token"}
        if row["state"] != "pending":
            return {
                "op": "decision",
                "ok": False,
                "error": f"already {row['state']}",
                "state": row["state"],
            }
        if not approve:
            with self._db_lock:
                dbmod.mark_pending(self.db, token, state="denied")
            self._broadcast_panel({"op": "removed", "token": token, "state": "denied"})
            return {"op": "decision", "ok": True, "state": "denied"}

        # Approved: dispatch through signal-cli, record outcome.
        accounts = self._accounts_snapshot()
        acct = next(
            (a for a in accounts if a.get("uuid") == row.get("account_uuid")),
            None,
        ) or (accounts[0] if accounts else None)
        if acct is None:
            with self._db_lock:
                dbmod.mark_pending(
                    self.db, token, state="failed", error="no account available"
                )
            self._broadcast_panel(
                {
                    "op": "removed",
                    "token": token,
                    "state": "failed",
                    "error": "no account available",
                }
            )
            return {"op": "decision", "ok": False, "error": "no account available"}
        try:
            self._dispatch_send(acct, row["recipient"], row["body"])
        except (JsonRpcError, OSError, TimeoutError) as exc:
            with self._db_lock:
                dbmod.mark_pending(self.db, token, state="failed", error=str(exc))
            self._broadcast_panel(
                {
                    "op": "removed",
                    "token": token,
                    "state": "failed",
                    "error": str(exc),
                }
            )
            return {"op": "decision", "ok": False, "error": f"send failed: {exc}"}
        with self._db_lock:
            dbmod.mark_pending(self.db, token, state="sent")
        self._broadcast_panel({"op": "removed", "token": token, "state": "sent"})
        return {"op": "decision", "ok": True, "state": "sent"}

    # ── panel subscriber broadcast ──────────────────────────────────

    def _panel_write(self, conn: socket.socket, payload: dict) -> bool:
        line = (json.dumps(payload) + "\n").encode("utf-8")
        with self._panel_write_lock:
            try:
                conn.sendall(line)
                return True
            except OSError:
                return False

    def _broadcast_panel(self, payload: dict) -> None:
        with self._panel_subs_lock:
            subs = list(self._panel_subscribers)
        stale: list[socket.socket] = []
        for conn in subs:
            if not self._panel_write(conn, payload):
                stale.append(conn)
        if stale:
            with self._panel_subs_lock:
                for c in stale:
                    if c in self._panel_subscribers:
                        self._panel_subscribers.remove(c)

    def _unsubscribe_panel(self, conn: socket.socket) -> None:
        with self._panel_subs_lock:
            if conn in self._panel_subscribers:
                self._panel_subscribers.remove(conn)

    # ── socket plumbing ─────────────────────────────────────────────

    def _serve_socket(
        self,
        path: str,
        handler: Callable[[socket.socket], None],
    ) -> None:
        # Stale socket from a previous crashed run: unlink then bind.
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            srv.bind(path)
            os.chmod(path, 0o600)
            srv.listen(8)
            srv.settimeout(1.0)
        except OSError as exc:
            log.error("failed to bind %s: %s", path, exc)
            srv.close()
            return
        self._sockets.append(srv)
        while not self._stop.is_set():
            try:
                conn, _ = srv.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            self._spawn(lambda c=conn: handler(c), name=f"conn-{path}")


def _ndjson_requests(conn: socket.socket):
    """Yield one parsed JSON dict per newline-delimited line read from conn."""
    buf = b""
    while True:
        try:
            chunk = conn.recv(4096)
        except OSError:
            return
        if not chunk:
            return
        buf += chunk
        while b"\n" in buf:
            line, _, buf = buf.partition(b"\n")
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line.decode("utf-8"))
            except (json.JSONDecodeError, UnicodeDecodeError):
                continue


# ── entry point ─────────────────────────────────────────────────────


def build_config_from_env() -> BridgeConfig:
    return BridgeConfig(
        db_path=dbmod.default_db_path(),
        daemon_socket=_default_daemon_socket(),
        enqueue_socket=_default_enqueue_socket(),
        panel_socket=_default_panel_socket(),
    )


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )
    bridge = Bridge(build_config_from_env())
    bridge.start()
    try:
        bridge.join()
    except KeyboardInterrupt:
        pass
    finally:
        bridge.stop()


if __name__ == "__main__":
    main()

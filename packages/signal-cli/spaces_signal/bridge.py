"""Always-up bridge between signal-cli's daemon and the spaces agent.

Three concurrent jobs in one process:

1. **Receiver** — subscribes to every linked account on the
   signal-cli daemon socket and writes each incoming envelope into
   `messages.db`. Subscription stays alive for the daemon's lifetime;
   if the socket drops, the supervisor reconnects on a short backoff.

2. **Enqueue listener** — bound to `$XDG_RUNTIME_DIR/spaces-signal/sandbox/enqueue.sock`
   and bind-mounted RW into the pi-chat sandbox. Sandbox-side CLIs
   (the `signal send` command) talk to this socket. Self-sends are
   dispatched immediately; everything else lands in `pending_sends`
   and returns a token the agent must hand back to the human.

3. **Panel listener** — bound to `$XDG_RUNTIME_DIR/spaces-signal/panel.sock`
   and **NOT** bound into the sandbox. The pi-chat Quickshell panel reads
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
import select
import socket
import sqlite3
import threading
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable

from . import db as dbmod
from .jsonrpc import JsonRpcClient, JsonRpcError

log = logging.getLogger("spaces_signal.bridge")

DEFAULT_DAEMON_SOCKET_ENV = "SPACES_SIGNAL_DAEMON_SOCKET"
DEFAULT_ENQUEUE_SOCKET_ENV = "SPACES_SIGNAL_ENQUEUE_SOCKET"
DEFAULT_PANEL_SOCKET_ENV = "SPACES_SIGNAL_PANEL_SOCKET"

# Resource caps on the sandbox-facing enqueue socket. The sandbox is
# the lower-trust side of the bridge — these prevent a buggy or
# prompt-injected agent from OOMing the bridge (line cap) or stashing
# a huge body the daemon will reject anyway (body cap).
MAX_ENQUEUE_LINE_BYTES = 1 << 20  # 1 MiB
MAX_SEND_BODY_BYTES = 64 * 1024  # 64 KiB

# Cap on un-decided sends an agent can stack up at once. A prompt-
# injected agent could otherwise flood the approval panel (local DoS)
# or bury a malicious card among many to fish for an approve-by-fatigue.
MAX_PENDING_SENDS = 32

# Stale pending sends are auto-expired after this long un-decided, so a
# forgotten card can't be approved hours later with surprising effect
# and pending_sends can't grow without bound.
PENDING_TTL_SECONDS = 60 * 60


class _SelectWake:
    """Wake-up primitive that interrupts a blocking select() instantly.

    Two socketpair endpoints: select on `read_end`, call `wake()` from
    any other thread to make that select return immediately. Cheaper
    than poll-the-accept-timeout — zero CPU while idle, microsecond
    wake latency on stop. Spurious wake-ups are harmless: the caller
    drains the read end and loops back to check its real stop flag.
    """

    def __init__(self) -> None:
        r, w = socket.socketpair()
        r.setblocking(False)
        self.read_end = r
        self._write_end = w

    def wake(self) -> None:
        try:
            self._write_end.send(b"\x01")
        except OSError:
            pass

    def drain(self) -> None:
        try:
            while self.read_end.recv(64):
                pass
        except (BlockingIOError, OSError):
            pass

    def close(self) -> None:
        for s in (self._write_end, self.read_end):
            try:
                s.close()
            except OSError:
                pass


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
    return f"{runtime}/spaces-signal/sandbox/enqueue.sock"


def _default_panel_socket() -> str:
    env = os.environ.get(DEFAULT_PANEL_SOCKET_ENV)
    if env:
        return env
    runtime = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    return f"{runtime}/spaces-signal/panel.sock"


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


def sanitize_display(name: str | None, fallback: str) -> str:
    """Strip Unicode control / format characters from a contact's
    display name before showing it to the human.

    Signal display names are attacker-controlled (anyone can pick
    their own profile name). Left raw, a U+202E RIGHT-TO-LEFT
    OVERRIDE would let an attacker make the approval card render
    "alice" while the message actually goes to "bob"; zero-width
    joiners and BIDI marks are similar. We drop every character in
    Unicode category C* (control, format, surrogate, private-use,
    unassigned), then fall back to `fallback` if nothing readable
    survives.
    """
    if not name:
        return fallback
    cleaned = "".join(
        c for c in name if unicodedata.category(c)[0] != "C" or c == " "
    ).strip()
    return cleaned or fallback


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
        expire_interval_seconds: float = 60.0,
    ) -> None:
        self.config = config
        self._db_lock = threading.Lock()
        self.db = dbmod.connect(config.db_path)
        self._client_factory = daemon_client_factory or DaemonClientFactory(
            config.daemon_socket
        )
        self._accounts_refresh_seconds = accounts_refresh_seconds
        self._expire_interval_seconds = expire_interval_seconds

        self._accounts: list[dict] = []
        self._accounts_lock = threading.Lock()

        self._stop = threading.Event()
        self._wake = _SelectWake()
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
        self._request_initial_sync()

        self._spawn(self._run_receiver, name="receiver")
        self._spawn(self._run_enqueue_listener, name="enqueue")
        self._spawn(self._run_panel_listener, name="panel")
        self._spawn(self._run_accounts_refresher, name="accounts-refresh")
        self._spawn(self._run_expiry, name="expiry")

    def stop(self) -> None:
        self._stop.set()
        # Wake every select() loop so listeners exit before we yank
        # their sockets out from under them. Without this they'd sit
        # in select() for the next timeout (or forever if it's
        # blocking) and the join() below would stall.
        self._wake.wake()
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
        self._wake.close()
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

    def _request_initial_sync(self) -> None:
        """Ask the primary device to push a fresh metadata sync.

        signal-cli's `sendSyncRequest` covers contacts, groups,
        blocked list, configuration, and keys — **NOT** message
        history. The Signal protocol has no "give me old messages"
        primitive that signal-cli speaks (the January-2025
        linked-device history archive is a separate provisioning-time
        channel that signal-cli has not implemented; see
        AsamK/signal-cli#1708).

        We fire this once per process startup so a user who has
        added/removed contacts or groups on their phone since the
        last bridge run sees an up-to-date `listContacts` /
        `listGroups` without having to unlink-and-relink. Failures
        are non-fatal — the primary device may be offline.
        """
        if self._rpc_client is None:
            return
        for acct in self._accounts_snapshot():
            account = acct.get("number") or acct.get("uuid")
            if not account:
                continue
            try:
                self._rpc_client.call("sendSyncRequest", {"account": account})
                log.info("requested primary-device metadata sync for %s", account)
            except (JsonRpcError, OSError, TimeoutError) as exc:
                log.warning("sendSyncRequest(%s) failed: %s", account, exc)

    # ── disappearing-message expiry ─────────────────────────────────

    def _run_expiry(self) -> None:
        """Physically delete disappearing messages whose window has
        passed. The read paths already filter expired rows out, but
        without this sweep the plaintext lingers in messages.db
        forever — defeating the point of disappearing messages.

        Runs once promptly on startup (a restart should clear any
        backlog accrued while the bridge was down), then on the
        interval.
        """
        while True:
            self._expire_once()
            if self._stop.wait(self._expire_interval_seconds):
                return

    def _expire_once(self) -> None:
        try:
            with self._db_lock:
                deleted = dbmod.expire_messages(self.db)
                expired_tokens = dbmod.expire_pending(
                    self.db,
                    older_than_ms=dbmod.now_ms() - PENDING_TTL_SECONDS * 1000,
                )
                if deleted or expired_tokens:
                    # Flush secure-deleted pages out of the WAL so expired
                    # plaintext actually leaves the file rather than
                    # lingering in -wal until a checkpoint.
                    self.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        except sqlite3.Error as exc:
            log.warning("expiry sweep failed: %s", exc)
            return
        if deleted:
            log.info("expired %d disappearing message(s)", deleted)
        for token in expired_tokens:
            log.info("expired stale pending send %s", token)
            self._broadcast_panel({"op": "removed", "token": token, "state": "expired"})

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
        if op == "send":
            return self._handle_send_request(req)
        if op == "contacts":
            return self._handle_daemon_list_request("listContacts", "contacts")
        if op == "groups":
            return self._handle_daemon_list_request("listGroups", "groups")
        return {"ok": False, "error": f"unknown op: {op!r}"}

    def _handle_send_request(self, req: dict) -> dict:
        recipient = (req.get("to") or "").strip()
        body = req.get("body") or ""
        if not recipient or not body:
            return {"ok": False, "error": "missing 'to' or 'body'"}
        body_bytes = body.encode("utf-8", errors="replace")
        if len(body_bytes) > MAX_SEND_BODY_BYTES:
            return {
                "ok": False,
                "error": (
                    f"body too large ({len(body_bytes)} bytes); "
                    f"maximum is {MAX_SEND_BODY_BYTES}"
                ),
            }

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

        # Cap the outstanding approval backlog. A prompt-injected agent
        # could otherwise mint unbounded pending cards — flooding the
        # panel (local DoS) or burying a malicious request among many to
        # fish for an approve-by-fatigue. Refuse new sends until the
        # human clears the backlog.
        with self._db_lock:
            outstanding = dbmod.count_pending(self.db)
        if outstanding >= MAX_PENDING_SENDS:
            return {
                "ok": False,
                "error": (
                    f"too many pending sends ({outstanding}); approve or "
                    f"deny existing ones in the chat panel first"
                ),
            }

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
            "recipient": recipient,
        }

    def _handle_daemon_list_request(self, method: str, key: str) -> dict:
        """Aggregate `listContacts` or `listGroups` across every linked
        account and return a flat list. The CLI used to hit the daemon
        socket directly for this; proxying through the bridge keeps the
        daemon socket OFF the sandbox's bind-mount set, so a
        prompt-injected agent cannot bypass the approval gate by
        speaking JSON-RPC `send` to the daemon itself.
        """
        if self._rpc_client is None:
            return {"ok": False, "error": "daemon connection not available"}
        accounts = self._accounts_snapshot()
        if not accounts:
            return {"ok": False, "error": "no linked Signal account"}
        combined: list = []
        errors: list[str] = []
        for acct in accounts:
            account_id = acct.get("number") or acct.get("uuid")
            try:
                result = self._rpc_client.call(method, {"account": account_id})
            except (JsonRpcError, OSError, TimeoutError) as exc:
                errors.append(f"{method}({account_id}): {exc}")
                continue
            if isinstance(result, list):
                combined.extend(result)
        resp: dict = {"ok": True, key: combined}
        if errors:
            resp["warnings"] = errors
        return resp

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
                            return sanitize_display(g.get("name"), recipient)
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
                            return sanitize_display(name or c.get("number"), recipient)
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
            # Atomically claim the still-`pending` row, moving it to
            # 'denied'. If an approve already won the claim (or the row
            # was otherwise decided), claim_pending returns False and we
            # surface "already <state>" rather than reporting a cancel
            # that didn't actually stop the send.
            with self._db_lock:
                claimed = dbmod.claim_pending(self.db, token, state="denied")
                if not claimed:
                    current = dbmod.get_pending(self.db, token)
            if not claimed:
                state = current["state"] if current else "unknown"
                return {
                    "op": "decision",
                    "ok": False,
                    "error": f"already {state}",
                    "state": state,
                }
            self._broadcast_panel({"op": "removed", "token": token, "state": "denied"})
            return {"op": "decision", "ok": True, "state": "denied"}

        # Approve: claim the still-`pending` row, moving it to
        # 'approved'. Only the thread whose UPDATE actually changes a
        # row may dispatch — every other concurrent decider (a second
        # approve, or a racing deny) gets `claimed = False` and bails.
        # This closes both the double-send TOCTOU and the deny-races-
        # approve hole (a cancel that returned ok while the message
        # still went out).
        with self._db_lock:
            claimed = dbmod.claim_pending(self.db, token, state="approved")
            if not claimed:
                current = dbmod.get_pending(self.db, token)
        if not claimed:
            state = current["state"] if current else "unknown"
            return {
                "op": "decision",
                "ok": False,
                "error": f"already {state}",
                "state": state,
            }

        # We own the dispatch. From here on we MUST move the row off
        # the 'approved' intermediate state (to 'sent' or 'failed')
        # before returning, otherwise the panel sees a stuck row.
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
        except OSError as exc:
            log.error("failed to bind %s: %s", path, exc)
            srv.close()
            return
        self._sockets.append(srv)
        # Blocking accept() interleaved with the shared wake fd:
        # select() returns instantly when either a client connects or
        # stop() pings the wake. No accept-timeout polling means zero
        # idle CPU and microsecond shutdown.
        wake_fd = self._wake.read_end
        while not self._stop.is_set():
            try:
                rlist, _, _ = select.select([srv, wake_fd], [], [])
            except (OSError, ValueError):
                break
            if wake_fd in rlist:
                self._wake.drain()
                continue
            try:
                conn, _ = srv.accept()
            except OSError:
                break
            self._spawn(lambda c=conn: handler(c), name=f"conn-{path}")


def _ndjson_requests(conn: socket.socket, max_line_bytes: int = MAX_ENQUEUE_LINE_BYTES):
    """Yield one parsed JSON dict per newline-delimited line read from conn.

    Caps the unfinished-line buffer at `max_line_bytes`. A client that
    streams data without a newline (accidentally or maliciously) gets
    its connection closed instead of OOM-ing the bridge.
    """
    buf = b""
    while True:
        try:
            chunk = conn.recv(4096)
        except OSError:
            return
        if not chunk:
            return
        buf += chunk
        if b"\n" not in buf and len(buf) > max_line_bytes:
            log.warning(
                "enqueue conn flooded %d bytes without newline; dropping", len(buf)
            )
            return
        while b"\n" in buf:
            line, _, buf = buf.partition(b"\n")
            if len(line) > max_line_bytes:
                log.warning(
                    "enqueue conn line %d bytes exceeds %d; skipping",
                    len(line),
                    max_line_bytes,
                )
                continue
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

"""Always-up bridge between signal-cli's daemon and the spaces agent.

The bridge is a **forwarder**: it subscribes to every linked account on
the signal-cli daemon socket and writes each incoming envelope into
`messages.db`. The subscription stays alive for the daemon's lifetime; if
the socket drops, the supervisor reconnects on a short backoff. A periodic
sweep physically deletes disappearing messages once their window passes.

Self-detection is based on the daemon's `listAccounts` snapshot (taken on
connect, refreshed every few minutes): an envelope that matches one of our
own linked identities — a sent transcript synced from another linked
device, including note-to-self — is routed to the right thread rather than
mistaken for an inbound DM.

Sending, recipient verification, and the human approval gate that guards a
send now live entirely in the `integration-signal` MCP server behind the
gateway. The bridge no longer speaks any send/approval protocol and owns no
sockets of its own — it is purely daemon → messages.db.
"""

from __future__ import annotations

import logging
import os
import sqlite3
import threading
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from . import db as dbmod
from .jsonrpc import JsonRpcClient, JsonRpcError

log = logging.getLogger("spaces_signal.bridge")

DEFAULT_DAEMON_SOCKET_ENV = "SPACES_SIGNAL_DAEMON_SOCKET"


def _default_daemon_socket() -> str:
    env = os.environ.get(DEFAULT_DAEMON_SOCKET_ENV)
    if env:
        return env
    runtime = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    return f"{runtime}/signal-cli/socket"


# ── helpers ─────────────────────────────────────────────────────────


def envelope_to_message(envelope: dict, account: dict | None = None) -> dict | None:
    """Normalise a signal-cli `receive` notification into the shape
    `db.store_message` expects. Returns None for envelopes that carry
    no user-visible content (typing indicators, receipts, …).
    """
    env = envelope.get("envelope") or envelope
    data = env.get("dataMessage") or {}
    if not data.get("message") and not data.get("attachments"):
        # No inbound dataMessage: this may be a sent transcript synced
        # from another linked device of *this* account (incl. note-to-
        # self typed on the primary phone). signal-cli surfaces those as
        # syncMessage.sentMessage, never dataMessage — treat the sent
        # message as the content source.
        data = (env.get("syncMessage") or {}).get("sentMessage") or {}
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
    elif account and source_uuid == account.get("uuid"):
        # Outbound transcript from one of our own linked devices. The
        # sentMessage's destination is the conversation partner; a
        # missing or own-identity destination means note-to-self.
        destination = (
            data.get("destinationUuid")
            or data.get("destination")
            or env.get("destinationUuid")
        )
        own = {account.get("uuid"), account.get("number")} - {None}
        if not destination or destination in own:
            thread_id = account.get("uuid") or destination or "self"
            thread_kind = "self"
        else:
            thread_id = destination
            thread_kind = "dm"
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


# ── core ────────────────────────────────────────────────────────────


@dataclass
class BridgeConfig:
    db_path: Path
    daemon_socket: str


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
        self._threads: list[threading.Thread] = []

        # Two daemon clients: one long-lived for the receive subscription
        # (reads notifications via its own reader thread) and one for the
        # short-lived RPC calls (listAccounts, sendSyncRequest) issued at
        # startup and on the refresh interval. They're split to isolate
        # failure domains — a dropped subscription must not tear down the
        # account-refresh client, and vice versa.
        self._rpc_client: JsonRpcClient | None = None
        self._sub_client: JsonRpcClient | None = None

    # ── lifecycle ───────────────────────────────────────────────────

    def start(self) -> None:
        # Open the short-lived RPC client + populate accounts before the
        # receiver subscribes so self-detection works on the first
        # envelope.
        self._rpc_client = self._client_factory()
        self._refresh_accounts()
        self._request_initial_sync()

        self._spawn(self._run_receiver, name="receiver")
        self._spawn(self._run_accounts_refresher, name="accounts-refresh")
        self._spawn(self._run_expiry, name="expiry")

    def stop(self) -> None:
        self._stop.set()
        # Closing the daemon clients wakes the receiver's on_close and
        # unblocks any in-flight call(); the loops also poll `_stop`, so
        # every thread exits promptly.
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
        `listGroups` (read live by the integration) without having to
        unlink-and-relink. Failures are non-fatal — the primary device
        may be offline.
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
                if deleted:
                    # Flush secure-deleted pages out of the WAL so expired
                    # plaintext actually leaves the file rather than
                    # lingering in -wal until a checkpoint.
                    self.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        except sqlite3.Error as exc:
            log.warning("expiry sweep failed: %s", exc)
            return
        if deleted:
            log.info("expired %d disappearing message(s)", deleted)

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


# ── entry point ─────────────────────────────────────────────────────


def build_config_from_env() -> BridgeConfig:
    return BridgeConfig(
        db_path=dbmod.default_db_path(),
        daemon_socket=_default_daemon_socket(),
    )


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )
    config = build_config_from_env()
    legacy_db = dbmod.default_legacy_db_path()
    # One-shot migration for the 'distro' → 'spaces' rename. Wrapped in
    # a broad except so a corrupt legacy DB can never block bridge
    # startup — losing the migration is recoverable, losing the bridge
    # is not.
    try:
        if dbmod.migrate_legacy_state(config.db_path, legacy_db):
            log.info("migrated legacy signal store %s -> %s", legacy_db, config.db_path)
    except Exception as exc:  # noqa: BLE001
        log.warning("legacy-state migration failed: %s; continuing with new store", exc)
    bridge = Bridge(config)
    bridge.start()
    try:
        bridge.join()
    except KeyboardInterrupt:
        pass
    finally:
        bridge.stop()


if __name__ == "__main__":
    main()

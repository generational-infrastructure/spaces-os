"""Nostr transport: the record rides in a kind-30078 replaceable event.

The outer event is schnorr-signed by the secp256k1 key; the inner ed25519
signature on the record is what the resolver trusts. Publishing needs the
secp256k1 secret; resolving needs only the pubkey (the `pk` arg is the ed25519
rendezvous key and is ignored — Nostr addresses by its own key).
"""

from __future__ import annotations

import hashlib
import json
import logging
from typing import TYPE_CHECKING

from websocket import create_connection

from . import secp
from .record import Record

if TYPE_CHECKING:
    from .transport import PublishResult

logger = logging.getLogger(__name__)

KIND = 30078  # NIP-78 application-specific data (parameterized replaceable)
DEFAULT_D = "spaces-restore"
_TIMEOUT = 15
_MICROS_PER_SEC = 1_000_000
_MAX_RESP_MSGS = 5  # relay chatter (NOTICE, etc.) to read past before giving up on OK
_OK_DETAIL_INDEX = 3  # ["OK", id, accepted, detail]


def _event_id(
    pubkey_hex: str, created_at: int, kind: int, tags: list, content: str
) -> str:
    serialized = json.dumps(
        [0, pubkey_hex, created_at, kind, tags, content],
        separators=(",", ":"),
        ensure_ascii=False,
    )
    return hashlib.sha256(serialized.encode()).hexdigest()


def build_event(
    secret: bytes, record: Record, created_at: int, d_id: str = DEFAULT_D
) -> dict:
    pubkey_hex = secp.xonly_pubkey(secret).hex()
    tags = [["d", d_id]]
    content = json.dumps(record.to_dict(), separators=(",", ":"))
    event_id = _event_id(pubkey_hex, created_at, KIND, tags, content)
    sig = secp.schnorr_sign(secret, bytes.fromhex(event_id)).hex()
    return {
        "id": event_id,
        "pubkey": pubkey_hex,
        "created_at": created_at,
        "kind": KIND,
        "tags": tags,
        "content": content,
        "sig": sig,
    }


def verify_event(event: dict) -> bool:
    recomputed = _event_id(
        event["pubkey"],
        event["created_at"],
        event["kind"],
        event["tags"],
        event["content"],
    )
    if recomputed != event["id"]:
        return False
    return secp.schnorr_verify(
        bytes.fromhex(event["pubkey"]),
        bytes.fromhex(recomputed),
        bytes.fromhex(event["sig"]),
    )


def record_from_event(event: dict) -> Record:
    return Record.from_dict(json.loads(event["content"]))


class NostrTransport:
    def __init__(
        self,
        relays: list[str],
        secret: bytes | None = None,
        pubkey_hex: str | None = None,
        d_id: str = DEFAULT_D,
        timeout: int = _TIMEOUT,
    ) -> None:
        self._relays = relays
        self._secret = secret
        self._pubkey = pubkey_hex or (
            secp.xonly_pubkey(secret).hex() if secret else None
        )
        self._d = d_id
        self._timeout = timeout

    def publish(self, record: Record) -> list[PublishResult]:
        if self._secret is None:
            msg = "publishing to Nostr needs the mnemonic (secp256k1 key)"
            raise ValueError(msg)
        created_at = record.seq // _MICROS_PER_SEC  # our seq is µs; Nostr wants seconds
        event = build_event(self._secret, record, created_at, self._d)
        results: list[PublishResult] = []
        for relay in self._relays:
            try:
                self._send_event(relay, event)
                results.append((relay, True, None))
            except Exception as exc:  # noqa: BLE001 -- one dead relay must not block the rest
                logger.warning("nostr publish failed on %s: %s", relay, exc)
                results.append((relay, False, str(exc)))
        return results

    def resolve(self, pk: bytes) -> Record | None:  # noqa: ARG002 -- keyed by secp pubkey, not pk
        best: Record | None = None
        for relay in self._relays:
            try:
                event = self._fetch_latest(relay)
            except Exception as exc:  # noqa: BLE001 -- skip a dead relay, keep going
                logger.warning("nostr resolve failed on %s: %s", relay, exc)
                continue
            if event is None or not verify_event(event):
                continue
            record = record_from_event(event)
            if record.verify() and (best is None or record.seq > best.seq):
                best = record
        return best

    def _send_event(self, relay: str, event: dict) -> None:
        ws = create_connection(relay, timeout=self._timeout)
        try:
            ws.send(json.dumps(["EVENT", event]))
            for _ in range(_MAX_RESP_MSGS):
                msg = json.loads(ws.recv())
                if msg[0] == "OK" and msg[1] == event["id"]:
                    if not msg[2]:
                        detail = msg[3] if len(msg) > _OK_DETAIL_INDEX else ""
                        error = f"relay rejected event: {detail}"
                        raise RuntimeError(error)
                    return
        finally:
            ws.close()

    def _fetch_latest(self, relay: str) -> dict | None:
        ws = create_connection(relay, timeout=self._timeout)
        try:
            sub = "s"
            req = {
                "authors": [self._pubkey],
                "kinds": [KIND],
                "#d": [self._d],
                "limit": 1,
            }
            ws.send(json.dumps(["REQ", sub, req]))
            latest = None
            while True:
                msg = json.loads(ws.recv())
                if msg[0] == "EVENT" and msg[1] == sub:
                    latest = msg[2]
                elif msg[0] == "EOSE":
                    break
            ws.send(json.dumps(["CLOSE", sub]))
            return latest
        finally:
            ws.close()

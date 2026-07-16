"""Author, publish, and resolve the config-pointer record.

The seed is needed only to author and to decrypt on resolve; publish needs no
secret. Publish is best-effort; resolve takes the freshest valid record.
"""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING

from . import crypto
from .manifest import Manifest
from .record import Record

if TYPE_CHECKING:
    from .transport import PublishResult, Transport

logger = logging.getLogger(__name__)


def author(
    seed: bytes, manifest: Manifest, seq: int, nonce: bytes | None = None
) -> Record:
    """Build a fresh signed+encrypted record. The only step that needs the seed."""
    value = crypto.seal(crypto.manifest_key(seed), manifest.to_json(), nonce=nonce)
    rv = crypto.rendezvous_key(seed)
    sig = crypto.sign_record(rv, seq, value)
    return Record(pk=rv.verify_key.encode(), seq=seq, v=value, sig=sig)


def open_record(seed: bytes, record: Record) -> Manifest:
    """Decrypt the manifest from a verified record."""
    return Manifest.from_json(crypto.open_value(crypto.manifest_key(seed), record.v))


def publish(record: Record, transports: list[Transport]) -> list[PublishResult]:
    """Push to every transport, best-effort. Returns a per-endpoint report; raises
    only if every endpoint failed.
    """
    report: list[PublishResult] = []
    for transport in transports:
        try:
            report.extend(transport.publish(record))
        except Exception as exc:  # noqa: BLE001 -- a transport-level failure must not abort the rest
            logger.warning("publish failed on %s: %s", type(transport).__name__, exc)
            report.append((type(transport).__name__, False, str(exc)))
    if report and not any(ok for _endpoint, ok, _err in report):
        msg = "publish failed on all endpoints"
        raise RuntimeError(msg)
    return report


def resolve_record(pk: bytes, transports: list[Transport]) -> Record | None:
    """The highest-seq signature-valid record across all transports; skips dead ones."""
    best: Record | None = None
    for transport in transports:
        try:
            record = transport.resolve(pk)
        except Exception as exc:  # noqa: BLE001 -- skip a dead transport, keep going
            logger.warning("resolve failed on %s: %s", type(transport).__name__, exc)
            continue
        if record is None or not record.verify():
            continue
        if best is None or record.seq > best.seq:
            best = record
    return best


def resolve(seed: bytes, transports: list[Transport]) -> Manifest:
    """Locate, verify, and decrypt the config pointer. Needs the seed."""
    pk = crypto.rendezvous_key(seed).verify_key.encode()
    record = resolve_record(pk, transports)
    if record is None:
        msg = "no valid rendezvous record found on any transport"
        raise LookupError(msg)
    return open_record(seed, record)

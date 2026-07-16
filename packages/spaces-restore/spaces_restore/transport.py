"""Transports move a Record to/from a rendezvous location.

Every backend (in-memory fake, local file, Nostr relay) is interchangeable. A
transport must reject records whose signature does not verify and never replace
a stored record with a lower-seq one.
"""

from __future__ import annotations

import base64
import json
from pathlib import Path
from typing import Protocol, runtime_checkable

from .record import Record

# (endpoint, ok, error) per place a publish landed.
PublishResult = tuple[str, bool, "str | None"]


@runtime_checkable
class Transport(Protocol):
    def publish(self, record: Record) -> list[PublishResult]: ...

    def resolve(self, pk: bytes) -> Record | None: ...


def _accept(current: Record | None, incoming: Record) -> bool:
    """Admission: valid signature, and not a rollback."""
    if not incoming.verify():
        msg = "refusing record: signature does not verify"
        raise ValueError(msg)
    return current is None or incoming.seq >= current.seq


class FakeTransport:
    """In-memory transport for tests and local use."""

    def __init__(self) -> None:
        self._store: dict[bytes, Record] = {}

    def publish(self, record: Record) -> list[PublishResult]:
        if _accept(self._store.get(record.pk), record):
            self._store[record.pk] = record
        return [("fake://memory", True, None)]

    def resolve(self, pk: bytes) -> Record | None:
        return self._store.get(pk)


class FileTransport:
    """A transport persisted to a JSON file — an offline local copy."""

    def __init__(self, path: str | Path) -> None:
        self._path = Path(path)

    def _load(self) -> dict[str, dict]:
        if not self._path.exists():
            return {}
        return json.loads(self._path.read_text())

    def publish(self, record: Record) -> list[PublishResult]:
        raw = self._load()
        key = record.to_dict()["pk"]
        existing = Record.from_dict(raw[key]) if key in raw else None
        if _accept(existing, record):
            raw[key] = record.to_dict()
            self._path.write_text(json.dumps(raw, indent=2, sort_keys=True))
        return [(f"file:{self._path}", True, None)]

    def resolve(self, pk: bytes) -> Record | None:
        entry = self._load().get(base64.b64encode(pk).decode())
        return Record.from_dict(entry) if entry else None

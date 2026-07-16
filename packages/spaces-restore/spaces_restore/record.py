"""The record {pk, seq, v, sig}: an ed25519-signed, encrypted config pointer.

Carries no secret. Serialized as JSON inside a Nostr event's content.
"""

from __future__ import annotations

import base64
from dataclasses import dataclass

from . import crypto


@dataclass(frozen=True)
class Record:
    pk: bytes  # ed25519 rendezvous public key
    seq: int  # monotonic; a microsecond timestamp
    v: bytes  # sealed manifest blob
    sig: bytes  # signature over bencode(seq, v)

    def verify(self) -> bool:
        return crypto.verify_record(self.pk, self.seq, self.v, self.sig)

    def to_dict(self) -> dict:
        return {
            "pk": base64.b64encode(self.pk).decode(),
            "seq": self.seq,
            "v": base64.b64encode(self.v).decode(),
            "sig": base64.b64encode(self.sig).decode(),
        }

    @classmethod
    def from_dict(cls, d: dict) -> Record:
        return cls(
            pk=base64.b64decode(d["pk"]),
            seq=int(d["seq"]),
            v=base64.b64decode(d["v"]),
            sig=base64.b64decode(d["sig"]),
        )

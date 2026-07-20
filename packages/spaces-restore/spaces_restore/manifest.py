"""The record payload: a pointer to the config git repo.

The flake holds the rest (machine list, borg repos, disko), so the record only
names where the flake is. `config` is a git URL or Radicle RID; `rev` optionally
pins a commit.
"""

from __future__ import annotations

import json
from dataclasses import dataclass


@dataclass
class Manifest:
    config: str
    rev: str = ""
    version: int = 1

    def to_json(self) -> bytes:
        return json.dumps(
            {"version": self.version, "config": self.config, "rev": self.rev},
            separators=(",", ":"),
            sort_keys=True,
        ).encode()

    @classmethod
    def from_json(cls, raw: bytes) -> Manifest:
        d = json.loads(raw)
        return cls(
            config=d["config"], rev=d.get("rev", ""), version=int(d.get("version", 1))
        )

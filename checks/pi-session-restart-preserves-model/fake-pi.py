#!/usr/bin/env python3
"""Fake pi --mode rpc for the QML-level restart test.

Records every NDJSON frame received on stdin to the witness file
pointed at by `FAKE_PI_WITNESS`. When the frame is `new_session`,
emits a synthetic `response` event — unless the suppress file pointed
at by `FAKE_PI_SUPPRESS_FILE` exists at that moment, in which case the
response is withheld. That gates the QML test on PiSession actually
waiting for pi's ack before sending the follow-up set_model.

Echoes back the request's `id` so PiSession's request/response
correlator can fulfill the matching promise.
"""

from __future__ import annotations

import json
import os
import sys


def main() -> int:
    witness = os.environ.get("FAKE_PI_WITNESS")
    if not witness:
        sys.stderr.write("FAKE_PI_WITNESS unset\n")
        return 2
    suppress = os.environ.get("FAKE_PI_SUPPRESS_FILE", "")
    with open(witness, "a", buffering=1) as fh:
        fh.write("STARTED\n")
        for line in sys.stdin:
            fh.write(line)
            try:
                frame = json.loads(line)
            except json.JSONDecodeError:
                continue
            if frame.get("type") != "new_session":
                continue
            if suppress and os.path.exists(suppress):
                continue
            response = {
                "type": "response",
                "command": "new_session",
                "success": True,
                "data": {"cancelled": False},
            }
            if "id" in frame:
                response["id"] = frame["id"]
            sys.stdout.write(json.dumps(response) + "\n")
            sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())

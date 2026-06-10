#!/usr/bin/env python3
"""Fake pi --mode rpc for the new-chat-inherits-model check.

Logs every stdin frame to FAKE_PI_WITNESS as one JSON object per line:
  {"sid": "<session id>", "dir": "in",  "frame": {...}}
and every emitted response as
  {"sid": "<session id>", "dir": "out", "frame": {...}}.

The session id is recovered from the --session-dir argv basename. The
stub systemd-run strips --setenv without applying it, so the usual
SPACES_SESSION_ID env is not available here. Multiple sessions (one
fake pi each) append to the same witness. The per-line sid keeps
their frames separable.

set_model handling. The flag files are checked per frame so the
driver can flip behaviour mid-run:
  - FAKE_PI_SUPPRESS_FILE exists -> no response. PiSession must
    withhold the first prompt until pi acks the set_model.
  - FAKE_PI_REJECT_FILE exists   -> success:false. The prompt must
    still follow on pi's default model.
  - otherwise                    -> success:true with {provider, id}.

Every other frame (prompt, get_messages, ...) is logged but
unanswered. The check never awaits those responses.
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
    reject = os.environ.get("FAKE_PI_REJECT_FILE", "")
    sid = ""
    argv = sys.argv[1:]
    for i, arg in enumerate(argv):
        if arg == "--session-dir" and i + 1 < len(argv):
            sid = os.path.basename(argv[i + 1])
    with open(witness, "a", buffering=1) as fh:

        def log(direction: str, frame: dict) -> None:
            fh.write(json.dumps({"sid": sid, "dir": direction, "frame": frame}) + "\n")

        log("in", {"type": "__started__"})
        for line in sys.stdin:
            try:
                frame = json.loads(line)
            except json.JSONDecodeError:
                continue
            log("in", frame)
            if frame.get("type") != "set_model":
                continue
            if suppress and os.path.exists(suppress):
                continue
            ok = not (reject and os.path.exists(reject))
            response: dict = {"type": "response", "command": "set_model", "success": ok}
            if ok:
                response["data"] = {
                    "provider": frame.get("provider"),
                    "id": frame.get("modelId"),
                }
            else:
                response["error"] = "unknown model"
            if "id" in frame:
                response["id"] = frame["id"]
            log("out", response)
            sys.stdout.write(json.dumps(response) + "\n")
            sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())

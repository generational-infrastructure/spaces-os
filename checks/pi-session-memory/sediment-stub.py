#!/usr/bin/env python3
"""Stub for the sediment CLI used by the memory pi extension test.

The real sediment binary downloads an embedding model and runs LanceDB;
neither fits inside a build sandbox. This stub mimics the JSON shapes
the extension consumes and records every invocation to
$SEDIMENT_STUB_LOG so the driver can assert call sequencing.

Behaviour matrix:
  sediment recall <q> --limit N --json
      Query starts with '['  → return {"results":[]} (supersession lookup).
      Anything else          → return a single canned fact result. This
                               models a populated DB without persisting
                               state across calls.
  sediment store <content>...        → exit 0 (success), nothing on stdout.
  sediment compact --force           → exit 0.
  anything else                      → exit 0; logged for diagnosis.
"""

import json
import os
import sys
import time

CANNED = {
    "results": [
        {
            "id": "stub-fact-1",
            "content": "[fact] favourite colour: blue",
            # Above MIN_SIMILARITY=0.40 so the extension keeps it; below
            # SUPERSEDE_SIMILARITY=0.70 so it doesn't trigger --replace
            # on subsequent storeFact paths.
            "similarity": "0.65",
        }
    ]
}


def log(record):
    path = os.environ.get("SEDIMENT_STUB_LOG")
    if not path:
        return
    record["ts"] = time.time()
    with open(path, "a") as fh:
        fh.write(json.dumps(record) + "\n")


def main():
    args = sys.argv[1:]
    log({"argv": args})
    if not args:
        return 0

    cmd = args[0]
    if cmd == "recall":
        # `sediment recall <query> --limit N --json [--scope ...]`
        query = args[1] if len(args) > 1 else ""
        if query.startswith("["):
            payload = {"results": []}
        else:
            payload = CANNED
        sys.stdout.write(json.dumps(payload))
        sys.stdout.flush()
        return 0

    # store / compact / unrecognised — nothing to emit, exit success so
    # the extension's best-effort paths stay best-effort.
    return 0


if __name__ == "__main__":
    sys.exit(main())

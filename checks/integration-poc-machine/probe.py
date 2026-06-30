#!/usr/bin/env python3
"""Same-uid Landlock-wall probe for the integration POC VM check (design §9.5).

Run under a live session's real landlock.json (via pi-landlock-exec) it stands
in for the agent's domain; run bare (as the same user) it stands in for the
unconfined supervisor. It attempts to READ each target and prints
`<label> OK|DENIED <errno>`, so the test can assert the agent's domain is denied
the integration's private runtime state (a deny-by-default Landlock FS rule)
while the unconfined supervisor — same uid — can read it, AND that the grant is
selective (the shared workspace, which the session policy DOES grant, stays
reachable).

NB: Landlock mediates filesystem access (open/read), not AF_UNIX `connect()`, so
the wall under test is FS isolation of the integration's private state — see the
"deviations & decisions" note in docs/agent-integrations-poc-plan.md.

usage: probe.py <integration_private_file> <shared_file>
"""

import errno
import sys


def _errname(e):
    return errno.errorcode.get(e.errno, str(e.errno))


def try_read(path):
    try:
        with open(path, "rb") as fh:
            fh.read(1)
        return "OK"
    except OSError as e:
        return f"DENIED {_errname(e)}"


def main():
    private_file, shared_file = sys.argv[1], sys.argv[2]
    print(f"private {try_read(private_file)}")
    print(f"shared {try_read(shared_file)}")


if __name__ == "__main__":
    main()

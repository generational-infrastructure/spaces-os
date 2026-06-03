#!/usr/bin/env python3
"""Notifier stub for the side-channel park test.

pi-sessiond runs this (SPACES_SESSIOND_NOTIFY_CMD) when a side-channel request
parks with zero clients attached. It appends the parked request's identity —
from the SPACES_NOTIFY_* env the daemon sets — to the file named by NOTIFY_OUT,
so the driver can assert the notifier fired (and with the right session/method).
"""

import os

with open(os.environ["NOTIFY_OUT"], "a") as fh:
    fh.write(
        "{} {} {}\n".format(
            os.environ.get("SPACES_NOTIFY_SESSION_ID", ""),
            os.environ.get("SPACES_NOTIFY_METHOD", ""),
            os.environ.get("SPACES_NOTIFY_EXECUTOR", ""),
        )
    )

import os
import time

import nacl.utils
import pytest
from spaces_restore import discovery, secp
from spaces_restore.manifest import Manifest
from spaces_restore.nostr import NostrTransport

RELAY = os.environ.get("SPACES_NOSTR_RELAY")


@pytest.mark.skipif(
    not RELAY, reason="set SPACES_NOSTR_RELAY to run against a live nostr relay"
)
def test_publish_resolve_against_live_nostr():
    seed = nacl.utils.random(32)  # unique key so runs never collide on a shared relay
    transport = NostrTransport([RELAY], secret=secp.nostr_secret(seed))
    manifest = Manifest(config="borg:cfg")
    discovery.publish(
        discovery.author(seed, manifest, time.time_ns() // 1000), [transport]
    )
    assert discovery.resolve(seed, [transport]) == manifest

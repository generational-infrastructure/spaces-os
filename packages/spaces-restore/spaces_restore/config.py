"""Default Nostr relays used when no --nostr is given.

Best-effort public relays: publish to all, resolve from all, take the freshest
valid record. The record is only a convenience pointer to the config repo, so
best-effort retention is fine.
"""

# Open strfry relays that accept kind-30078 from arbitrary authors.
DEFAULT_NOSTR_RELAYS = [
    "wss://relay.damus.io",
    "wss://nos.lol",
    "wss://relay.primal.net",
    "wss://offchain.pub",
    "wss://nostr.mom",
]

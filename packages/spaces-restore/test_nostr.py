from spaces_restore import discovery, nostr, secp
from spaces_restore.manifest import Manifest

CREATED_AT = 1_700_000_000


def _rec(seed):
    return discovery.author(seed, Manifest(config="borg:c"), 1)


def test_build_event_verifies(seed):
    event = nostr.build_event(secp.nostr_secret(seed), _rec(seed), CREATED_AT)
    assert nostr.verify_event(event) is True


def test_event_kind_and_d_tag(seed):
    event = nostr.build_event(secp.nostr_secret(seed), _rec(seed), CREATED_AT)
    assert event["kind"] == 30078
    assert ["d", "spaces-restore"] in event["tags"]


def test_tampered_content_fails_verify(seed):
    event = nostr.build_event(secp.nostr_secret(seed), _rec(seed), CREATED_AT)
    event["content"] += "x"  # id no longer matches the content
    assert nostr.verify_event(event) is False


def test_record_survives_event_roundtrip(seed):
    record = _rec(seed)
    event = nostr.build_event(secp.nostr_secret(seed), record, CREATED_AT)
    assert nostr.record_from_event(event) == record


def test_publish_tolerates_one_bad_relay(seed, monkeypatch):
    transport = nostr.NostrTransport(
        ["wss://good", "wss://bad"], secret=secp.nostr_secret(seed)
    )
    sent = []

    def fake_send(relay, _event):
        sent.append(relay)
        if "bad" in relay:
            msg = "relay down"
            raise RuntimeError(msg)

    monkeypatch.setattr(transport, "_send_event", fake_send)
    results = transport.publish(_rec(seed))  # must NOT raise
    assert sent == ["wss://good", "wss://bad"]
    assert [(r, ok) for r, ok, _e in results] == [
        ("wss://good", True),
        ("wss://bad", False),
    ]


def test_publish_reports_all_relays_failed(seed, monkeypatch):
    transport = nostr.NostrTransport(
        ["wss://a", "wss://b"], secret=secp.nostr_secret(seed)
    )

    def always_fail(_relay, _event):
        msg = "down"
        raise RuntimeError(msg)

    monkeypatch.setattr(transport, "_send_event", always_fail)
    results = transport.publish(_rec(seed))
    assert len(results) == 2
    assert all(not ok for _r, ok, _e in results)

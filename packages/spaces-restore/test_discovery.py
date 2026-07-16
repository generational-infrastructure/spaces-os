import pytest
from mnemonic import Mnemonic
from spaces_restore import crypto, discovery
from spaces_restore.manifest import Manifest
from spaces_restore.record import Record
from spaces_restore.transport import FakeTransport

M = Manifest(config="borg:cfg")


def test_author_publish_resolve_roundtrip(seed):
    transport = FakeTransport()
    discovery.publish(discovery.author(seed, M, 1), [transport])
    assert discovery.resolve(seed, [transport]) == M


def test_resolve_missing_raises(seed):
    with pytest.raises(LookupError, match="no valid"):
        discovery.resolve(seed, [FakeTransport()])


def test_resolve_picks_highest_seq_across_transports(seed):
    old, new = FakeTransport(), FakeTransport()
    discovery.publish(discovery.author(seed, Manifest(config="old"), 1), [old])
    discovery.publish(discovery.author(seed, Manifest(config="new"), 9), [new])
    assert discovery.resolve(seed, [old, new]).config == "new"


def test_republish_needs_no_seed(seed):
    # Authored once on a seed-holding box, then handed to a republisher as a blob.
    blob = discovery.author(seed, M, 4).to_dict()
    # The republisher reconstructs from the blob alone — no seed in scope here.
    record = Record.from_dict(blob)
    transport = FakeTransport()
    discovery.publish(record, [transport])
    # Still resolves + decrypts back on a seed-holding box.
    assert discovery.resolve(seed, [transport]) == M


class _FailingTransport:
    def publish(self, _record):
        msg = "transport down"
        raise RuntimeError(msg)

    def resolve(self, _pk):
        msg = "transport down"
        raise RuntimeError(msg)


def test_publish_tolerates_a_failing_transport(seed):
    good = FakeTransport()
    report = discovery.publish(
        discovery.author(seed, M, 1), [_FailingTransport(), good]
    )
    assert sum(1 for _e, ok, _err in report if ok) == 1
    assert discovery.resolve(seed, [good]) == M


def test_publish_raises_only_when_all_transports_fail(seed):
    with pytest.raises(RuntimeError, match="all"):
        discovery.publish(
            discovery.author(seed, M, 1), [_FailingTransport(), _FailingTransport()]
        )


def test_resolve_skips_a_failing_transport(seed):
    good = FakeTransport()
    discovery.publish(discovery.author(seed, M, 1), [good])
    assert discovery.resolve(seed, [_FailingTransport(), good]) == M


def test_resolve_isolated_from_other_mnemonic(seed):
    transport = FakeTransport()
    discovery.publish(discovery.author(seed, M, 1), [transport])
    other_seed = crypto.master_seed(Mnemonic("english").to_mnemonic(b"\x01" * 32))
    # A different mnemonic derives a different lookup key -> record is unfindable.
    with pytest.raises(LookupError):
        discovery.resolve(other_seed, [transport])

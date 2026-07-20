import pytest
from spaces_restore import crypto, discovery
from spaces_restore.manifest import Manifest
from spaces_restore.record import Record
from spaces_restore.transport import FakeTransport, FileTransport


def _record(seed, seq=1):
    return discovery.author(seed, Manifest(config="c"), seq)


def _pk(seed):
    return crypto.rendezvous_key(seed).verify_key.encode()


def test_fake_publish_resolve_roundtrip(seed):
    transport = FakeTransport()
    record = _record(seed)
    transport.publish(record)
    assert transport.resolve(record.pk) == record


def test_fake_resolve_missing_returns_none(seed):
    assert FakeTransport().resolve(_pk(seed)) is None


def test_fake_rejects_invalid_signature(seed):
    record = _record(seed)
    tampered = Record(pk=record.pk, seq=record.seq, v=record.v + b"x", sig=record.sig)
    with pytest.raises(ValueError, match="signature"):
        FakeTransport().publish(tampered)


def test_fake_rejects_rollback(seed):
    transport = FakeTransport()
    transport.publish(_record(seed, seq=5))
    transport.publish(_record(seed, seq=3))  # lower seq must be ignored
    assert transport.resolve(_pk(seed)).seq == 5


def test_file_transport_persists_across_instances(tmp_path, seed):
    path = tmp_path / "store.json"
    record = _record(seed, seq=2)
    FileTransport(path).publish(record)
    assert FileTransport(path).resolve(record.pk) == record

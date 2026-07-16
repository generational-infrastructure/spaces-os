from spaces_restore import discovery
from spaces_restore.manifest import Manifest
from spaces_restore.record import Record


def _rec(seed):
    return discovery.author(seed, Manifest(config="github:example/flake"), 7)


def test_record_dict_roundtrip(seed):
    record = _rec(seed)
    assert Record.from_dict(record.to_dict()) == record

from spaces_restore.manifest import Manifest


def test_manifest_roundtrips_through_json():
    m = Manifest(config="github:example/flake", rev="abc123")
    assert Manifest.from_json(m.to_json()) == m


def test_manifest_serialization_is_deterministic():
    m = Manifest(config="c")
    assert m.to_json() == m.to_json()


def test_manifest_defaults_rev_empty_version_one():
    m = Manifest.from_json(b'{"config":"github:example/flake"}')
    assert m.rev == ""
    assert m.version == 1

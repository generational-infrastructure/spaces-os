from types import SimpleNamespace

from spaces_restore import config
from spaces_restore.cli import _transports
from spaces_restore.nostr import NostrTransport
from spaces_restore.transport import FileTransport


def test_default_relays_are_nonempty_wss():
    assert config.DEFAULT_NOSTR_RELAYS
    assert all(url.startswith("wss://") for url in config.DEFAULT_NOSTR_RELAYS)


def test_transports_defaults_to_nostr(seed):
    transports = _transports(SimpleNamespace(nostr=None, store=None), seed)
    assert any(isinstance(t, NostrTransport) for t in transports)


def test_transports_adds_optional_file_store(tmp_path, seed):
    args = SimpleNamespace(nostr=None, store=str(tmp_path / "s.json"))
    transports = _transports(args, seed)
    assert any(isinstance(t, FileTransport) for t in transports)

import email
import email.policy
import email.utils
import os
import stat
import sys

import pytest
import spaces_himalaya_core as core

# Stub himalaya on a prepended PATH, exactly like test_integration_mail.py: it
# records every spawn (proving whether himalaya ran) and fails loudly on the
# "boom" subcommand so run_himalaya's error mapping has something to map.
_STUB_HIMALAYA = r"""#!__PY__
import os, sys
d = os.environ["HIMALAYA_STUB_DIR"]
argv = sys.argv[1:]
with open(os.path.join(d, "spawned"), "a") as f:
    f.write(" ".join(argv) + "\n")
if "boom" in argv:
    sys.stderr.write("kaboom\n")
    sys.exit(3)
sys.stdout.write("hello-out")
"""


def _write_exec(path, text):
    path.write_text(text.replace("__PY__", sys.executable))
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


@pytest.fixture
def himalaya_stub(tmp_path, monkeypatch):
    stub_dir = tmp_path / "stub"
    stub_dir.mkdir()
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    _write_exec(bin_dir / "himalaya", _STUB_HIMALAYA)
    monkeypatch.setenv("HIMALAYA_STUB_DIR", str(stub_dir))
    monkeypatch.setenv("PATH", str(bin_dir) + os.pathsep + os.environ["PATH"])
    return stub_dir


def _spawned(stub_dir):
    return (stub_dir / "spawned").exists()


# --- pure helpers -----------------------------------------------------------


def test_enc_for_port_table():
    assert core.enc_for_port(993) == "tls"
    assert core.enc_for_port("465") == "tls"
    assert core.enc_for_port(587) == "start-tls"
    assert core.enc_for_port("143") == "start-tls"
    assert core.enc_for_port(25) == "none"
    assert core.enc_for_port(12345) == "tls"


def test_toml_escape():
    assert core.toml_escape('a"b\\c') == 'a\\"b\\\\c'


# --- config_file ------------------------------------------------------------


def test_config_file_is_0600_and_cleaned_up():
    with core.config_file("hello = 1\n") as path:
        assert os.path.isfile(path)
        assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
        with open(path, encoding="utf-8") as f:
            assert f.read() == "hello = 1\n"
        tmpdir = os.path.dirname(path)
        assert os.path.basename(tmpdir).startswith("himalaya-")
    assert not os.path.exists(tmpdir)


def test_config_file_prefix_override():
    with core.config_file("x = 1\n", prefix="proton-") as path:
        assert os.path.basename(os.path.dirname(path)).startswith("proton-")


# --- run_himalaya error mapping ---------------------------------------------


def test_run_himalaya_success(himalaya_stub, tmp_path):
    cfg = tmp_path / "c.toml"
    cfg.write_text("x = 1\n")
    out, is_error = core.run_himalaya(str(cfg), ["envelope", "list"])
    assert is_error is False
    assert out == "hello-out"
    assert _spawned(himalaya_stub)


def test_run_himalaya_nonzero_maps_to_stderr(himalaya_stub, tmp_path):
    cfg = tmp_path / "c.toml"
    cfg.write_text("x = 1\n")
    out, is_error = core.run_himalaya(str(cfg), ["boom"])
    assert is_error is True
    assert out == "kaboom"


def test_run_himalaya_spawn_failure(monkeypatch, tmp_path):
    cfg = tmp_path / "c.toml"
    cfg.write_text("x = 1\n")
    monkeypatch.setattr(core, "HIMALAYA", "himalaya-does-not-exist-zzz")
    out, is_error = core.run_himalaya(str(cfg), ["envelope", "list"])
    assert is_error is True
    assert "failed to run himalaya-does-not-exist-zzz" in out


# --- compose_message --------------------------------------------------------


def _composed(args=None):
    msg = core.compose_message(
        "me@x.test",
        args
        or {
            "to": ["alice@y.test"],
            "subject": "Hi",
            "body": "Body",
        },
    )
    return email.message_from_bytes(msg, policy=email.policy.default)


def test_compose_message_stamps_date():
    # RFC 5322 requires Date; Proton Bridge's IMAP append validates and
    # rejects a message without it ("Required header field 'Date' not found").
    msg = _composed()
    assert msg["Date"] is not None
    parsed = email.utils.parsedate_to_datetime(str(msg["Date"]))
    assert parsed.tzinfo is not None  # zone-aware, not a bare local time


def test_compose_message_stamps_message_id():
    # Message-ID is a SHOULD that strict providers flag; stamp it server-side
    # so the agent never has to.
    msg = _composed()
    mid = str(msg["Message-ID"] or "")
    assert mid.startswith("<")
    assert mid.endswith(">")
    assert "@" in mid


def test_compose_message_ids_are_unique():
    a = str(_composed()["Message-ID"])
    b = str(_composed()["Message-ID"])
    assert a != b


# --- make_tool_impls --------------------------------------------------------


def _ok_config(profile, vals):
    return "x = 1\n", None


def test_make_tool_impls_precheck_short_circuits(himalaya_stub):
    impls = core.make_tool_impls(_ok_config, precheck=lambda p, v: "bridge unavailable")
    text, is_error = impls["envelope_list"]({}, "personal", {})
    assert is_error is True
    assert text == "bridge unavailable"
    # precheck failed before any exec: himalaya must never have been spawned.
    assert not _spawned(himalaya_stub)


def test_make_tool_impls_precheck_pass_runs_himalaya(himalaya_stub):
    impls = core.make_tool_impls(_ok_config, precheck=lambda p, v: None)
    text, is_error = impls["envelope_list"]({}, "personal", {})
    assert is_error is False
    assert text == "hello-out"
    assert _spawned(himalaya_stub)


def test_make_tool_impls_default_precheck_is_no_probe(himalaya_stub):
    impls = core.make_tool_impls(_ok_config)
    _text, is_error = impls["message_read"]({"id": "5"}, "personal", {})
    assert is_error is False
    assert _spawned(himalaya_stub)
    assert "5" in (himalaya_stub / "spawned").read_text()


def test_make_tool_impls_arg_validation_precedes_probe(himalaya_stub):
    probed = []
    impls = core.make_tool_impls(_ok_config, precheck=lambda p, v: probed.append(1))
    text, is_error = impls["message_read"]({}, "personal", {})
    assert is_error is True
    assert text == "missing required argument: id"
    # a clearly-invalid argument is reported without probing or spawning.
    assert not probed
    assert not _spawned(himalaya_stub)


def test_make_tool_impls_build_config_error(himalaya_stub):
    impls = core.make_tool_impls(lambda p, v: (None, "invalid port for profile 'x'"))
    text, is_error = impls["envelope_list"]({}, "x", {})
    assert is_error is True
    assert text == "invalid port for profile 'x'"
    assert not _spawned(himalaya_stub)

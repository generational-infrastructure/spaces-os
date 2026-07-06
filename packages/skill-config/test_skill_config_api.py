"""`skill-config api`: the versioned JSON seam spaces-integrationd drives.

One request object on stdin, one response envelope on stdout, exit 0
whenever an envelope was produced (errors travel INSIDE the envelope, so
the broker never scrapes stderr or parses human-oriented output).

    request:  {"v": 1, "op": "...", ...}
    response: {"v": 1, "ok": true,  "result": {...}}
            | {"v": 1, "ok": false, "error": "message"}

Ops: set {skill,profile,field,value} -> {}
     remove-profile {skill,profile}  -> {"removed": bool}
     profiles {skill}                -> {"skill", "profiles": {name:
                                         {"config": {field: value},
                                          "secrets": {field: is_set}}}}
"""

import json
import os
import subprocess
import sys

import skill_config

SC = skill_config.__file__


def api(request, env, tmp):
    e = dict(os.environ)
    e["SPACES_PI_CHAT_STATE_DIR"] = str(tmp / "state")
    e.update(env)
    return subprocess.run(
        [sys.executable, SC, "api"],
        input=json.dumps(request),
        env=e,
        capture_output=True,
        text=True,
        check=False,
    )


def envelope(request, env, tmp):
    r = api(request, env, tmp)
    assert r.returncode == 0, (r.stdout, r.stderr)
    doc = json.loads(r.stdout)
    assert doc["v"] == 1
    return doc


def _env_schema(tmp):
    schema = tmp / "schema.json"
    schema.write_text(
        json.dumps(
            {
                "config": {"imap_host": "IMAP host"},
                "secrets": {"password": "IMAP password"},
            }
        )
    )
    cfg = tmp / "config.toml"
    sec = tmp / "secrets.toml"
    return (
        cfg,
        sec,
        {
            "SKILL_CONFIG_SCHEMA": str(schema),
            "SKILL_CONFIG_CONFIG_FILE": str(cfg),
            "SKILL_CONFIG_SECRETS_FILE": str(sec),
        },
    )


def set_req(skill, profile, field, value):
    return {
        "v": 1,
        "op": "set",
        "skill": skill,
        "profile": profile,
        "field": field,
        "value": value,
    }


def test_set_routes_to_schema_designated_files(tmp_path):
    cfg, sec, env = _env_schema(tmp_path)
    doc = envelope(set_req("mail", "work", "imap_host", "imap.corp.com"), env, tmp_path)
    assert doc["ok"] is True
    doc = envelope(set_req("mail", "work", "password", "hunter2"), env, tmp_path)
    assert doc["ok"] is True

    assert "imap.corp.com" in cfg.read_text()
    assert "hunter2" not in cfg.read_text()
    assert "hunter2" in sec.read_text()
    assert "imap.corp.com" not in sec.read_text()


def test_profiles_snapshot(tmp_path):
    _cfg, _sec, env = _env_schema(tmp_path)
    envelope(set_req("mail", "work", "imap_host", "imap.corp.com"), env, tmp_path)
    envelope(set_req("mail", "work", "password", "hunter2"), env, tmp_path)
    envelope(set_req("mail", "home", "imap_host", "imap.home.net"), env, tmp_path)

    doc = envelope({"v": 1, "op": "profiles", "skill": "mail"}, env, tmp_path)
    assert doc["ok"] is True
    result = doc["result"]
    assert result["skill"] == "mail"
    assert set(result["profiles"]) == {"work", "home"}
    assert result["profiles"]["work"]["config"]["imap_host"] == "imap.corp.com"
    # secrets are set-status only; the value never crosses the seam.
    assert result["profiles"]["work"]["secrets"]["password"] is True
    assert result["profiles"]["home"]["secrets"]["password"] is False
    assert "hunter2" not in json.dumps(doc)


def test_profiles_empty_store(tmp_path):
    _cfg, _sec, env = _env_schema(tmp_path)
    doc = envelope({"v": 1, "op": "profiles", "skill": "mail"}, env, tmp_path)
    assert doc["ok"] is True
    assert doc["result"]["profiles"] == {}


def test_remove_profile(tmp_path):
    _cfg, _sec, env = _env_schema(tmp_path)
    envelope(set_req("mail", "work", "password", "w"), env, tmp_path)
    envelope(set_req("mail", "home", "password", "h"), env, tmp_path)

    doc = envelope(
        {"v": 1, "op": "remove-profile", "skill": "mail", "profile": "work"},
        env,
        tmp_path,
    )
    assert doc["ok"] is True
    assert doc["result"]["removed"] is True

    snap = envelope({"v": 1, "op": "profiles", "skill": "mail"}, env, tmp_path)
    assert set(snap["result"]["profiles"]) == {"home"}

    doc = envelope(
        {"v": 1, "op": "remove-profile", "skill": "mail", "profile": "work"},
        env,
        tmp_path,
    )
    assert doc["ok"] is True
    assert doc["result"]["removed"] is False


def test_errors_travel_in_envelope_not_exit_code(tmp_path):
    _cfg, _sec, env = _env_schema(tmp_path)
    doc = envelope(set_req("mail", "work", "bogus", "x"), env, tmp_path)
    assert doc["ok"] is False
    assert "unknown field 'bogus'" in doc["error"]


def test_malformed_schema_reported_in_envelope(tmp_path):
    cfg, sec, _env = _env_schema(tmp_path)
    bad = tmp_path / "bad.json"
    bad.write_text('{"config": "not-a-table"}')
    env = {
        "SKILL_CONFIG_SCHEMA": str(bad),
        "SKILL_CONFIG_CONFIG_FILE": str(cfg),
        "SKILL_CONFIG_SECRETS_FILE": str(sec),
    }
    doc = envelope({"v": 1, "op": "profiles", "skill": "mail"}, env, tmp_path)
    assert doc["ok"] is False
    assert "malformed" in doc["error"]


def test_unsupported_version_rejected(tmp_path):
    _cfg, _sec, env = _env_schema(tmp_path)
    doc = envelope({"v": 2, "op": "profiles", "skill": "mail"}, env, tmp_path)
    assert doc["ok"] is False
    assert "version" in doc["error"]


def test_unknown_op_rejected(tmp_path):
    _cfg, _sec, env = _env_schema(tmp_path)
    doc = envelope({"v": 1, "op": "frobnicate"}, env, tmp_path)
    assert doc["ok"] is False
    assert "unknown op" in doc["error"]


def test_garbage_stdin_rejected_in_envelope(tmp_path):
    _cfg, _sec, env = _env_schema(tmp_path)
    e = dict(os.environ)
    e["SPACES_PI_CHAT_STATE_DIR"] = str(tmp_path / "state")
    e.update(env)
    proc = subprocess.run(
        [sys.executable, SC, "api"],
        input="{not json",
        env=e,
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0
    doc = json.loads(proc.stdout)
    assert doc["ok"] is False
    assert "malformed" in doc["error"]


def test_store_io_failure_travels_in_envelope(tmp_path):
    cfg, _sec, env = _env_schema(tmp_path)
    envelope(set_req("mail", "work", "imap_host", "imap.corp.com"), env, tmp_path)
    cfg.chmod(0o000)
    try:
        doc = envelope({"v": 1, "op": "profiles", "skill": "mail"}, env, tmp_path)
    finally:
        cfg.chmod(0o644)
    assert doc["ok"] is False
    assert "config.toml" in doc["error"]

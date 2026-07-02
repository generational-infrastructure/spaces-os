"""skill-config: the SKILL.md path (unchanged, used by the agent-facing
skills) plus the $SKILL_CONFIG_SCHEMA / $SKILL_CONFIG_*_FILE overrides the
relocated integration store drives."""

import json
import os
import subprocess
import sys

import skill_config

SC = skill_config.__file__


def run(argv, env, tmp):
    e = dict(os.environ)
    # Pin instance resolution so a real /var/lib on the dev host can't leak in.
    e["SPACES_PI_CHAT_STATE_DIR"] = str(tmp / "state")
    e.update(env)
    return subprocess.run(
        [sys.executable, SC, *argv], env=e, capture_output=True, text=True
    )


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
        schema,
        cfg,
        sec,
        {
            "SKILL_CONFIG_SCHEMA": str(schema),
            "SKILL_CONFIG_CONFIG_FILE": str(cfg),
            "SKILL_CONFIG_SECRETS_FILE": str(sec),
        },
    )


def test_env_schema_routes_config_and_secret_to_the_named_files(tmp_path):
    _schema, cfg, sec, env = _env_schema(tmp_path)

    assert (
        run(["set", "mail.work.imap_host", "imap.corp.com"], env, tmp_path).returncode
        == 0
    )
    assert run(["set", "mail.work.password", "hunter2"], env, tmp_path).returncode == 0

    # Each value lands in its schema-designated blob, and only there.
    assert "imap.corp.com" in cfg.read_text()
    assert "hunter2" not in cfg.read_text()
    assert "hunter2" in sec.read_text()
    assert "imap.corp.com" not in sec.read_text()

    g = run(["get", "mail.work.password"], env, tmp_path)
    assert g.returncode == 0 and g.stdout.strip() == "hunter2"
    g = run(["get", "mail.work.imap_host"], env, tmp_path)
    assert g.stdout.strip() == "imap.corp.com"


def test_env_schema_needs_no_skill_md_on_disk(tmp_path):
    # No skills-defs dir exists; env schema alone must satisfy get/set.
    _schema, _cfg, _sec, env = _env_schema(tmp_path)
    assert run(["set", "mail.solo.imap_host", "x"], env, tmp_path).returncode == 0
    assert run(["get", "mail.solo.imap_host"], env, tmp_path).stdout.strip() == "x"


def test_env_schema_multiprofile_isolated(tmp_path):
    _schema, _cfg, _sec, env = _env_schema(tmp_path)
    run(["set", "mail.a.password", "aaa"], env, tmp_path)
    run(["set", "mail.b.password", "bbb"], env, tmp_path)
    assert run(["get", "mail.a.password"], env, tmp_path).stdout.strip() == "aaa"
    assert run(["get", "mail.b.password"], env, tmp_path).stdout.strip() == "bbb"


def test_env_schema_unknown_field_errors(tmp_path):
    _schema, _cfg, _sec, env = _env_schema(tmp_path)
    r = run(["get", "mail.work.bogus"], env, tmp_path)
    assert r.returncode != 0
    assert "unknown field" in r.stderr


def test_env_schema_malformed_schema_file_errors(tmp_path):
    _schema, cfg, sec, _env = _env_schema(tmp_path)
    bad = tmp_path / "bad.json"
    bad.write_text('{"config": "not-a-table"}')
    env = {
        "SKILL_CONFIG_SCHEMA": str(bad),
        "SKILL_CONFIG_CONFIG_FILE": str(cfg),
        "SKILL_CONFIG_SECRETS_FILE": str(sec),
    }
    r = run(["get", "mail.work.password"], env, tmp_path)
    assert r.returncode != 0
    assert "malformed" in r.stderr


def test_skill_md_mode_unchanged(tmp_path):
    # The agent-facing path (google/signal) must keep working: schema from
    # SKILL.md, store under the state dir's skill-config/.
    skilldir = tmp_path / "state" / "skills-defs" / "calendar"
    skilldir.mkdir(parents=True)
    (skilldir / "SKILL.md").write_text(
        "---\n"
        "name: Calendar\n"
        "config:\n  url: CalDAV URL\n"
        "secrets:\n  password: CalDAV password\n"
        "---\nbody\n"
    )
    assert (
        run(
            ["set", "calendar.home.url", "https://dav.example"], {}, tmp_path
        ).returncode
        == 0
    )
    assert run(["set", "calendar.home.password", "pw"], {}, tmp_path).returncode == 0
    store = tmp_path / "state" / "skill-config"
    assert "https://dav.example" in (store / "config.toml").read_text()
    assert "pw" in (store / "secrets.toml").read_text()
    assert (
        run(["get", "calendar.home.url"], {}, tmp_path).stdout.strip()
        == "https://dav.example"
    )


def test_env_schema_list_json_reports_values_and_set_status(tmp_path):
    import json as _json

    _schema, _cfg, _sec, env = _env_schema(tmp_path)
    run(["set", "mail.work.imap_host", "imap.corp.com"], env, tmp_path)
    run(["set", "mail.work.password", "hunter2"], env, tmp_path)
    run(["set", "mail.home.imap_host", "imap.home.net"], env, tmp_path)

    r = run(["list", "mail", "--json"], env, tmp_path)
    assert r.returncode == 0, r.stderr
    doc = _json.loads(r.stdout)
    assert doc["skill"] == "mail"
    assert set(doc["profiles"]) == {"work", "home"}
    # config carries values; secrets carry set-status only, never the value.
    assert doc["profiles"]["work"]["config"]["imap_host"] == "imap.corp.com"
    assert doc["profiles"]["work"]["secrets"]["password"] is True
    assert doc["profiles"]["home"]["secrets"]["password"] is False
    assert "hunter2" not in r.stdout

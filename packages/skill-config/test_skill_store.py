"""skill_store: the pure store library. Everything here is in-process —
no subprocess, no sys.exit. Failures are typed exceptions.
"""

import json

import pytest
import skill_store


def make_paths(tmp_path, monkeypatch, *, env_schema=None):
    """Paths pinned to tmp dirs; optionally with the env-schema overrides
    the relocated integration store uses.
    """
    monkeypatch.setenv("SPACES_PI_CHAT_STATE_DIR", str(tmp_path / "state"))
    if env_schema is not None:
        schema = tmp_path / "schema.json"
        schema.write_text(json.dumps(env_schema))
        monkeypatch.setenv("SKILL_CONFIG_SCHEMA", str(schema))
        monkeypatch.setenv("SKILL_CONFIG_CONFIG_FILE", str(tmp_path / "config.toml"))
        monkeypatch.setenv("SKILL_CONFIG_SECRETS_FILE", str(tmp_path / "secrets.toml"))
    else:
        monkeypatch.delenv("SKILL_CONFIG_SCHEMA", raising=False)
        monkeypatch.delenv("SKILL_CONFIG_CONFIG_FILE", raising=False)
        monkeypatch.delenv("SKILL_CONFIG_SECRETS_FILE", raising=False)
    return skill_store.Paths("local")


MAIL_SCHEMA = {
    "config": {"imap_host": "IMAP host"},
    "secrets": {"password": "IMAP password"},
}


def test_round_trip_and_file_routing(tmp_path, monkeypatch):
    paths = make_paths(tmp_path, monkeypatch, env_schema=MAIL_SCHEMA)
    store = skill_store.SkillStore(paths)

    store.set("mail", "work", "imap_host", "imap.corp.com")
    store.set("mail", "work", "password", "hunter2")

    assert store.get("mail", "work", "imap_host") == "imap.corp.com"
    assert store.get("mail", "work", "password") == "hunter2"

    cfg = (tmp_path / "config.toml").read_text()
    sec = (tmp_path / "secrets.toml").read_text()
    assert "imap.corp.com" in cfg
    assert "hunter2" not in cfg
    assert "hunter2" in sec
    assert "imap.corp.com" not in sec


def test_get_unset_returns_none(tmp_path, monkeypatch):
    paths = make_paths(tmp_path, monkeypatch, env_schema=MAIL_SCHEMA)
    store = skill_store.SkillStore(paths)
    assert store.get("mail", "work", "imap_host") is None


def test_unknown_field_raises_not_exits(tmp_path, monkeypatch):
    paths = make_paths(tmp_path, monkeypatch, env_schema=MAIL_SCHEMA)
    store = skill_store.SkillStore(paths)
    with pytest.raises(skill_store.UnknownFieldError) as ei:
        store.get("mail", "work", "bogus")
    assert "unknown field 'bogus'" in str(ei.value)
    with pytest.raises(skill_store.UnknownFieldError):
        store.set("mail", "work", "bogus", "x")


def test_malformed_env_schema_raises(tmp_path, monkeypatch):
    paths = make_paths(tmp_path, monkeypatch, env_schema="not-used")
    bad = tmp_path / "bad.json"
    bad.write_text('{"config": "not-a-table"}')
    monkeypatch.setenv("SKILL_CONFIG_SCHEMA", str(bad))
    store = skill_store.SkillStore(paths)
    with pytest.raises(skill_store.SchemaError) as ei:
        store.load_schema("mail")
    assert "malformed" in str(ei.value)


def test_unreadable_env_schema_raises(tmp_path, monkeypatch):
    paths = make_paths(tmp_path, monkeypatch, env_schema=MAIL_SCHEMA)
    monkeypatch.setenv("SKILL_CONFIG_SCHEMA", str(tmp_path / "missing.json"))
    store = skill_store.SkillStore(paths)
    with pytest.raises(skill_store.SchemaError):
        store.load_schema("mail")


def test_skill_md_schema_routing(tmp_path, monkeypatch):
    paths = make_paths(tmp_path, monkeypatch)
    skilldir = tmp_path / "state" / "skills-defs" / "calendar"
    skilldir.mkdir(parents=True)
    (skilldir / "SKILL.md").write_text(
        "---\n"
        "name: Calendar\n"
        "config:\n  url: CalDAV URL\n"
        "secrets:\n  password: CalDAV password\n"
        "---\nbody\n"
    )
    store = skill_store.SkillStore(paths)
    cfg, sec = store.load_schema("calendar")
    assert cfg == {"url": "CalDAV URL"}
    assert sec == {"password": "CalDAV password"}

    store.set("calendar", "home", "url", "https://dav.example")
    store.set("calendar", "home", "password", "pw")
    state = tmp_path / "state" / "skill-config"
    assert "https://dav.example" in (state / "config.toml").read_text()
    assert "pw" in (state / "secrets.toml").read_text()


def test_missing_skill_raises(tmp_path, monkeypatch):
    paths = make_paths(tmp_path, monkeypatch)
    store = skill_store.SkillStore(paths)
    with pytest.raises(skill_store.SkillNotFoundError):
        store.load_schema("nope")


def test_resolve_skill_case_insensitive(tmp_path, monkeypatch):
    paths = make_paths(tmp_path, monkeypatch)
    skilldir = tmp_path / "state" / "skills-defs" / "calendar"
    skilldir.mkdir(parents=True)
    (skilldir / "SKILL.md").write_text("---\nname: Calendar\n---\n")
    store = skill_store.SkillStore(paths)
    assert store.resolve_skill("Calendar") == "calendar"
    assert store.resolve_skill("calendar") == "calendar"
    # Unknown names fall through unchanged; the caller raises its usual error.
    assert store.resolve_skill("Nope") == "Nope"


def test_remove_profile_round_trip(tmp_path, monkeypatch):
    paths = make_paths(tmp_path, monkeypatch, env_schema=MAIL_SCHEMA)
    store = skill_store.SkillStore(paths)
    store.set("mail", "work", "imap_host", "h1")
    store.set("mail", "work", "password", "p1")
    store.set("mail", "home", "password", "p2")

    assert store.remove_profile("mail", "work") is True
    assert store.get("mail", "work", "imap_host") is None
    assert store.get("mail", "work", "password") is None
    # Sibling profile survives.
    assert store.get("mail", "home", "password") == "p2"
    # Removing again is a no-op, reported as such.
    assert store.remove_profile("mail", "work") is False


def test_profiles_snapshot_values_and_secret_status(tmp_path, monkeypatch):
    paths = make_paths(tmp_path, monkeypatch, env_schema=MAIL_SCHEMA)
    store = skill_store.SkillStore(paths)
    store.set("mail", "work", "imap_host", "imap.corp.com")
    store.set("mail", "work", "password", "hunter2")
    store.set("mail", "home", "imap_host", "imap.home.net")

    snap = store.profiles_snapshot("mail")
    assert snap["skill"] == "mail"
    assert set(snap["profiles"]) == {"work", "home"}
    assert snap["profiles"]["work"]["config"]["imap_host"] == "imap.corp.com"
    # Secrets are set-status booleans; the value never appears.
    assert snap["profiles"]["work"]["secrets"]["password"] is True
    assert snap["profiles"]["home"]["secrets"]["password"] is False
    assert "hunter2" not in json.dumps(snap)


def test_resolve_instance_ambiguous_raises(tmp_path, monkeypatch):
    monkeypatch.delenv("SPACES_PI_CHAT_STATE_DIR", raising=False)
    monkeypatch.delenv("SPACES_PI_CHAT_INSTANCE", raising=False)
    var_lib = tmp_path / "var-lib"
    for inst in ["a", "b"]:
        (var_lib / f"spaces-pi-chat-{inst}").mkdir(parents=True)
    with pytest.raises(skill_store.AmbiguousInstanceError) as ei:
        skill_store.resolve_instance(None, var_lib=var_lib)
    assert "a, b" in str(ei.value)
    # A flag or a single candidate resolves fine.
    assert skill_store.resolve_instance("x", var_lib=var_lib) == "x"


def test_unreadable_store_file_raises_store_io_error(tmp_path, monkeypatch):
    paths = make_paths(tmp_path, monkeypatch, env_schema=MAIL_SCHEMA)
    store = skill_store.SkillStore(paths)
    store.set("mail", "work", "imap_host", "imap.corp.com")
    (tmp_path / "config.toml").chmod(0o000)
    try:
        with pytest.raises(skill_store.StoreIOError) as ei:
            store.get("mail", "work", "imap_host")
        # StoreIOError is a SkillStoreError, so every front end already
        # maps it to its error channel instead of a traceback.
        assert isinstance(ei.value, skill_store.SkillStoreError)
        assert "config.toml" in str(ei.value)
    finally:
        (tmp_path / "config.toml").chmod(0o644)

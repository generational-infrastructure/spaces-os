"""skill_store: the pure per-skill config/secrets store engine.

This is the library under both front ends:

  * `skill_config` — the agent-facing CLI (get/set/list/schema/remove/
    request-input), which maps the exceptions below to `error: …` + exit
    codes.
  * `skill-config api` — the versioned JSON seam spaces-integrationd
    drives.

Layout (paths identical on host and inside the container, because the state
directory is bind-mounted at the same path):

    /var/lib/spaces-pi-chat-<instance>/skills-defs/<skill>/SKILL.md   # schema source
    /var/lib/spaces-pi-chat-<instance>/skill-config/config.toml       # mode 0644
    /var/lib/spaces-pi-chat-<instance>/skill-config/secrets.toml      # mode 0600

Schema routing: a field belongs to exactly one of `config:` or `secrets:`;
that decides which TOML file holds the value. Field name = TOML key. The
schema comes from $SKILL_CONFIG_SCHEMA (a JSON {"config": {...},
"secrets": {...}} file, used by the relocated integration store with no
SKILL.md on disk) when set, else from the YAML frontmatter of the skill's
SKILL.md:

    ---
    name: Calendar
    config:
      url: Full CalDAV collection URL ...
    secrets:
      password: CalDAV password ...
    ---

Nothing in this module exits or prints; failures raise SkillStoreError
subclasses whose messages are the exact human strings the CLI shows after
an `error: ` prefix.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import NamedTuple

import tomlkit
import yaml

DEFAULT_INSTANCE = "local"
CONFIG_MODE = 0o644
SECRETS_MODE = 0o600
DIR_MODE = 0o750


class SkillStoreError(Exception):
    """Base for all store failures. str(e) is the human message."""


class AmbiguousInstanceError(SkillStoreError):
    pass


class SkillNotFoundError(SkillStoreError):
    pass


class SchemaError(SkillStoreError):
    pass


class UnknownFieldError(SkillStoreError):
    def __init__(self, field: str, skill: str):
        super().__init__(f"unknown field '{field}' for skill '{skill}'")
        self.field = field
        self.skill = skill


class Paths:
    def __init__(self, instance: str):
        self.instance = instance
        env_state = os.environ.get("SPACES_PI_CHAT_STATE_DIR")
        self.state_dir = (
            Path(env_state)
            if env_state
            else Path(f"/var/lib/spaces-pi-chat-{instance}")
        )
        self.skills_dir = self.state_dir / "skills-defs"
        self.cfg_dir = self.state_dir / "skill-config"
        env_config = os.environ.get("SKILL_CONFIG_CONFIG_FILE")
        env_secrets = os.environ.get("SKILL_CONFIG_SECRETS_FILE")
        self.config_toml = (
            Path(env_config) if env_config else self.cfg_dir / "config.toml"
        )
        self.secrets_toml = (
            Path(env_secrets) if env_secrets else self.cfg_dir / "secrets.toml"
        )


def resolve_instance(flag: str | None, var_lib: Path = Path("/var/lib")) -> str:
    if flag:
        return flag
    env = os.environ.get("SPACES_PI_CHAT_INSTANCE")
    if env:
        return env
    # If state dir is overridden, instance name doesn't matter for path resolution.
    if os.environ.get("SPACES_PI_CHAT_STATE_DIR"):
        return DEFAULT_INSTANCE
    candidates = sorted(
        p.name[len("spaces-pi-chat-") :]
        for p in var_lib.glob("spaces-pi-chat-*")
        if p.is_dir()
    )
    if len(candidates) == 1:
        return candidates[0]
    if not candidates:
        return DEFAULT_INSTANCE
    raise AmbiguousInstanceError(
        f"multiple spaces-pi-chat instances found ({', '.join(candidates)}); "
        "pass --instance or set SPACES_PI_CHAT_INSTANCE"
    )


def load_frontmatter(skill_dir: Path) -> dict:
    md = skill_dir / "SKILL.md"
    if not md.exists():
        raise SkillNotFoundError(f"{md} not found")
    text = md.read_text()
    if not text.startswith("---\n"):
        return {}
    end = text.find("\n---", 4)
    if end == -1:
        return {}
    return yaml.safe_load(text[4 : end + 1]) or {}


def skill_md_schema(skill_dir: Path) -> tuple[dict, dict]:
    """(config_fields, secret_fields) from a skill dir's SKILL.md frontmatter."""
    fm = load_frontmatter(skill_dir)
    cfg = fm.get("config") or {}
    sec = fm.get("secrets") or {}
    if not isinstance(cfg, dict) or not isinstance(sec, dict):
        raise SchemaError(f"malformed config:/secrets: in {skill_dir}/SKILL.md")
    return cfg, sec


def load_toml(path: Path) -> tomlkit.TOMLDocument:
    if not path.exists():
        return tomlkit.document()
    return tomlkit.parse(path.read_text())


def save_toml(path: Path, doc: tomlkit.TOMLDocument, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=DIR_MODE)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(tomlkit.dumps(doc))
    tmp.chmod(mode)
    tmp.rename(path)


def section_get(doc: tomlkit.TOMLDocument, skill: str, profile: str) -> dict:
    return dict(doc.get(skill, {}).get(profile, {}) or {})


def section_set(
    doc: tomlkit.TOMLDocument, skill: str, profile: str, values: dict
) -> None:
    if skill not in doc:
        doc[skill] = tomlkit.table(is_super_table=True)
    doc[skill][profile] = values


def section_delete(doc: tomlkit.TOMLDocument, skill: str, profile: str) -> bool:
    skill_t = doc.get(skill)
    if not skill_t or profile not in skill_t:
        return False
    del skill_t[profile]
    if len(skill_t) == 0:
        del doc[skill]
    return True


def list_profiles(doc: tomlkit.TOMLDocument, skill: str) -> list[str]:
    skill_t = doc.get(skill)
    if not skill_t:
        return []
    return sorted(skill_t.keys())


class Route(NamedTuple):
    """Where one field lives: which TOML file, its mode, and its schema row."""

    path: Path
    mode: int
    description: str
    secret: bool


class SkillStore:
    """Store operations for one instance's Paths.

    Every method takes on-disk skill names; run user input through
    resolve_skill() first.
    """

    def __init__(self, paths: Paths):
        self.paths = paths

    # ── schema ──────────────────────────────────────────────────────

    def load_schema(self, skill: str) -> tuple[dict, dict]:
        """(config_fields, secret_fields) for a skill.

        Prefers $SKILL_CONFIG_SCHEMA — a JSON {"config": {...}, "secrets": {...}}
        map used by the relocated integration store (no SKILL.md on disk) — over
        the skill's SKILL.md frontmatter.
        """
        env_schema = os.environ.get("SKILL_CONFIG_SCHEMA")
        if env_schema:
            try:
                doc = json.loads(Path(env_schema).read_text())
            except (OSError, ValueError) as e:
                raise SchemaError(
                    f"cannot read SKILL_CONFIG_SCHEMA {env_schema}: {e}"
                ) from e
            cfg = doc.get("config") or {}
            sec = doc.get("secrets") or {}
            if not isinstance(cfg, dict) or not isinstance(sec, dict):
                raise SchemaError(f"malformed config:/secrets: in {env_schema}")
            return cfg, sec
        skill_dir = self.paths.skills_dir / skill
        if not skill_dir.exists():
            raise SkillNotFoundError(f"skill '{skill}' not found at {skill_dir}")
        return skill_md_schema(skill_dir)

    def route(self, skill: str, field: str) -> Route:
        cfg_fields, sec_fields = self.load_schema(skill)
        if field in cfg_fields:
            return Route(
                self.paths.config_toml, CONFIG_MODE, str(cfg_fields[field]), False
            )
        if field in sec_fields:
            return Route(
                self.paths.secrets_toml, SECRETS_MODE, str(sec_fields[field]), True
            )
        raise UnknownFieldError(field, skill)

    # ── skill name handling ─────────────────────────────────────────

    def list_skills(self) -> list[str]:
        skills_dir = self.paths.skills_dir
        if not skills_dir.exists():
            return []
        return sorted(
            p.name for p in skills_dir.iterdir() if (p / "SKILL.md").exists()
        )

    def resolve_skill(self, name: str) -> str:
        """Map a user/agent-supplied skill name to its on-disk directory name.

        Skills live at <skills_dir>/<dirname>/SKILL.md. Directory names are
        lowercase but the SKILL.md `name:` field is a Title Case display
        string, and small LLMs often pass that back as the lookup key.
        Match case-insensitively so `schema Calendar` resolves to `calendar`.
        """
        candidates = self.list_skills()
        for c in candidates:
            if c == name:
                return c
        lowered = name.lower()
        for c in candidates:
            if c.lower() == lowered:
                return c
        return name  # fall through; the next schema lookup raises not-found

    # ── values ──────────────────────────────────────────────────────

    def get(self, skill: str, profile: str, field: str):
        """The stored value, or None when unset. Raises UnknownFieldError
        for fields outside the schema."""
        route = self.route(skill, field)
        doc = load_toml(route.path)
        return doc.get(skill, {}).get(profile, {}).get(field)

    def set(self, skill: str, profile: str, field: str, value: str) -> None:
        route = self.route(skill, field)
        doc = load_toml(route.path)
        section = section_get(doc, skill, profile)
        section[field] = value
        section_set(doc, skill, profile, section)
        save_toml(route.path, doc, route.mode)

    def remove_profile(self, skill: str, profile: str) -> bool:
        """Delete a profile from both stores. True if anything was removed."""
        removed = False
        for path, mode in (
            (self.paths.config_toml, CONFIG_MODE),
            (self.paths.secrets_toml, SECRETS_MODE),
        ):
            doc = load_toml(path)
            if section_delete(doc, skill, profile):
                save_toml(path, doc, mode)
                removed = True
        return removed

    # ── snapshots ───────────────────────────────────────────────────

    def profile_names(self, skill: str) -> list[str]:
        """All profiles for a skill, across both stores."""
        return sorted(
            set(list_profiles(load_toml(self.paths.config_toml), skill))
            | set(list_profiles(load_toml(self.paths.secrets_toml), skill))
        )

    def profiles_snapshot(self, skill: str) -> dict:
        """Machine-readable state for one skill: per profile, config VALUES
        and secret SET-STATUS. A secret value never leaves the store here."""
        cfg_fields, sec_fields = self.load_schema(skill)
        config_doc = load_toml(self.paths.config_toml)
        secrets_doc = load_toml(self.paths.secrets_toml)
        all_profiles = sorted(
            set(list_profiles(config_doc, skill))
            | set(list_profiles(secrets_doc, skill))
        )
        out = {"skill": skill, "profiles": {}}
        for profile in all_profiles:
            cfg_section = section_get(config_doc, skill, profile)
            sec_section = section_get(secrets_doc, skill, profile)
            out["profiles"][profile] = {
                "config": {
                    name: cfg_section[name]
                    for name in cfg_fields
                    if name in cfg_section
                },
                "secrets": {
                    name: sec_section.get(name) is not None for name in sec_fields
                },
            }
        return out

#!/usr/bin/env python3
"""skill-config: per-skill config and secrets store for opencrow.

Layout (paths identical on host and inside the container, because the state
directory is bind-mounted at the same path):

    /var/lib/opencrow-<instance>/skills-defs/<skill>/SKILL.md   # schema source
    /var/lib/opencrow-<instance>/skill-config/config.toml       # mode 0644
    /var/lib/opencrow-<instance>/skill-config/secrets.toml      # mode 0600

Schema lives in YAML frontmatter of SKILL.md:

    ---
    name: Calendar
    config:
      url: Full CalDAV collection URL ...
      user: CalDAV username
    secrets:
      password: CalDAV password ...
    ---

Each field belongs to exactly one of `config:` or `secrets:`; that decides
which TOML file holds the value. Field name = TOML key.
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import socket
import sys
import time
from pathlib import Path

import tomlkit
import yaml

DEFAULT_INSTANCE = "local"
CONFIG_MODE = 0o644
SECRETS_MODE = 0o600
DIR_MODE = 0o750
DEFAULT_DAEMON_SOCKET = "/run/opencrow-sock/skill-config.sock"
DAEMON_CONNECT_TIMEOUT = 3.0  # seconds, retried while daemon is starting


class Paths:
    def __init__(self, instance: str):
        self.instance = instance
        env_state = os.environ.get("OPENCROW_STATE_DIR")
        self.state_dir = (
            Path(env_state) if env_state else Path(f"/var/lib/opencrow-{instance}")
        )
        self.skills_dir = self.state_dir / "skills-defs"
        self.cfg_dir = self.state_dir / "skill-config"
        self.config_toml = self.cfg_dir / "config.toml"
        self.secrets_toml = self.cfg_dir / "secrets.toml"


def resolve_instance(flag: str | None) -> str:
    if flag:
        return flag
    env = os.environ.get("OPENCROW_INSTANCE")
    if env:
        return env
    # If state dir is overridden, instance name doesn't matter for path resolution.
    if os.environ.get("OPENCROW_STATE_DIR"):
        return DEFAULT_INSTANCE
    candidates = sorted(
        p.name[len("opencrow-") :]
        for p in Path("/var/lib").glob("opencrow-*")
        if p.is_dir()
    )
    if len(candidates) == 1:
        return candidates[0]
    if not candidates:
        return DEFAULT_INSTANCE
    sys.exit(
        f"error: multiple opencrow instances found ({', '.join(candidates)}); "
        "pass --instance or set OPENCROW_INSTANCE"
    )


def load_frontmatter(skill_dir: Path) -> dict:
    md = skill_dir / "SKILL.md"
    if not md.exists():
        sys.exit(f"error: {md} not found")
    text = md.read_text()
    if not text.startswith("---\n"):
        return {}
    end = text.find("\n---", 4)
    if end == -1:
        return {}
    return yaml.safe_load(text[4 : end + 1]) or {}


def schema(skill_dir: Path) -> tuple[dict, dict]:
    fm = load_frontmatter(skill_dir)
    cfg = fm.get("config") or {}
    sec = fm.get("secrets") or {}
    if not isinstance(cfg, dict) or not isinstance(sec, dict):
        sys.exit(f"error: malformed config:/secrets: in {skill_dir}/SKILL.md")
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


def list_skills(skills_dir: Path) -> list[str]:
    if not skills_dir.exists():
        return []
    return sorted(p.name for p in skills_dir.iterdir() if (p / "SKILL.md").exists())


def list_profiles(doc: tomlkit.TOMLDocument, skill: str) -> list[str]:
    skill_t = doc.get(skill)
    if not skill_t:
        return []
    return sorted(skill_t.keys())


def cmd_init(args, paths: Paths) -> None:
    skill_dir = paths.skills_dir / args.skill
    if not skill_dir.exists():
        sys.exit(f"error: skill '{args.skill}' not found at {skill_dir}")
    cfg_fields, sec_fields = schema(skill_dir)
    if not cfg_fields and not sec_fields:
        sys.exit(f"error: skill '{args.skill}' has no config:/secrets: in its SKILL.md")

    profile = args.profile
    if profile is None:
        profile = input("Profile name [default] > ").strip() or "default"

    config_doc = load_toml(paths.config_toml)
    secrets_doc = load_toml(paths.secrets_toml)
    existing_cfg = section_get(config_doc, args.skill, profile)
    existing_sec = section_get(secrets_doc, args.skill, profile)

    print()
    new_cfg = {}
    for name, desc in cfg_fields.items():
        current = existing_cfg.get(name)
        suffix = f"\n  [{current}] > " if current is not None else "\n  > "
        val = input(f"{desc}{suffix}").strip()
        if not val and current is not None:
            val = current
        if val:
            new_cfg[name] = val
        print()

    new_sec = {}
    for name, desc in sec_fields.items():
        has_existing = existing_sec.get(name) is not None
        suffix = "\n  [hidden — enter to keep] > " if has_existing else "\n  > "
        val = getpass.getpass(f"{desc}{suffix}")
        if not val and has_existing:
            val = existing_sec[name]
        if val:
            new_sec[name] = val
        print()

    if new_cfg:
        section_set(config_doc, args.skill, profile, new_cfg)
        save_toml(paths.config_toml, config_doc, CONFIG_MODE)
    if new_sec:
        section_set(secrets_doc, args.skill, profile, new_sec)
        save_toml(paths.secrets_toml, secrets_doc, SECRETS_MODE)

    print(f"✓ Saved profile '{profile}' for skill '{args.skill}'.")


def cmd_get(args, paths: Paths) -> None:
    parts = args.key.split(".")
    if len(parts) != 3:
        sys.exit("error: key must be <skill>.<profile>.<field>")
    skill, profile, field = parts

    skill_dir = paths.skills_dir / skill
    if not skill_dir.exists():
        sys.exit(f"error: skill '{skill}' not found at {skill_dir}")
    cfg_fields, sec_fields = schema(skill_dir)

    if field in cfg_fields:
        doc = load_toml(paths.config_toml)
    elif field in sec_fields:
        doc = load_toml(paths.secrets_toml)
    else:
        sys.exit(f"error: unknown field '{field}' for skill '{skill}'")

    val = doc.get(skill, {}).get(profile, {}).get(field)
    if val is None:
        sys.exit(
            f"error: {args.key} is not set. "
            f"Use the skill-config skill to onboard this field "
            f"(`skill-config request-input {args.key}` opens a popup "
            f"for the user)."
        )
    print(val)


def cmd_list(args, paths: Paths) -> None:
    config_doc = load_toml(paths.config_toml)
    secrets_doc = load_toml(paths.secrets_toml)

    if args.target:
        parts = args.target.split(".")
        skill = parts[0]
        skill_dir = paths.skills_dir / skill
        if not skill_dir.exists():
            sys.exit(f"error: skill '{skill}' not found")
        cfg_fields, sec_fields = schema(skill_dir)

        if len(parts) == 2:
            profiles = [parts[1]]
        else:
            all_profiles = set(list_profiles(config_doc, skill)) | set(
                list_profiles(secrets_doc, skill)
            )
            profiles = sorted(all_profiles)
            if not profiles:
                print(f"{skill}: no profiles configured")
                return

        for profile in profiles:
            print(f"[{skill}.{profile}]")
            cfg_section = section_get(config_doc, skill, profile)
            sec_section = section_get(secrets_doc, skill, profile)
            for name in cfg_fields:
                val = cfg_section.get(name)
                rendered = repr(val) if val is not None else "[unset]"
                print(f"  {name} = {rendered}")
            for name in sec_fields:
                tag = "[set]" if sec_section.get(name) is not None else "[unset]"
                print(f"  {name} = {tag}")
            print()
        return

    skills = list_skills(paths.skills_dir)
    if not skills:
        print(f"(no skills found in {paths.skills_dir})")
        return
    for skill in skills:
        cfg_fields, sec_fields = schema(paths.skills_dir / skill)
        if not cfg_fields and not sec_fields:
            print(f"{skill}  (no schema)")
            continue
        all_profiles = set(list_profiles(config_doc, skill)) | set(
            list_profiles(secrets_doc, skill)
        )
        profiles = sorted(all_profiles)
        if not profiles:
            print(f"{skill}  (not configured)")
        else:
            print(f"{skill}")
            for p in profiles:
                print(f"  - {p}")


def cmd_set(args, paths: Paths) -> None:
    parts = args.key.split(".")
    if len(parts) != 3:
        sys.exit("error: key must be <skill>.<profile>.<field>")
    skill, profile, field = parts

    skill_dir = paths.skills_dir / skill
    if not skill_dir.exists():
        sys.exit(f"error: skill '{skill}' not found at {skill_dir}")
    cfg_fields, sec_fields = schema(skill_dir)

    if field in cfg_fields:
        path, mode = paths.config_toml, CONFIG_MODE
    elif field in sec_fields:
        path, mode = paths.secrets_toml, SECRETS_MODE
    else:
        sys.exit(f"error: unknown field '{field}' for skill '{skill}'")

    doc = load_toml(path)
    section = section_get(doc, skill, profile)
    section[field] = args.value
    section_set(doc, skill, profile, section)
    save_toml(path, doc, mode)


def cmd_schema(args, paths: Paths) -> None:
    skill_dir = paths.skills_dir / args.skill
    if not skill_dir.exists():
        sys.exit(f"error: skill '{args.skill}' not found at {skill_dir}")
    cfg_fields, sec_fields = schema(skill_dir)
    out = {}
    if cfg_fields:
        out["config"] = dict(cfg_fields)
    if sec_fields:
        out["secrets"] = dict(sec_fields)
    sys.stdout.write(yaml.safe_dump(out, sort_keys=False, default_flow_style=False))


def daemon_socket_path() -> str:
    return os.environ.get("SKILL_CONFIG_SOCKET") or DEFAULT_DAEMON_SOCKET


def daemon_connect() -> socket.socket:
    """Connect to the daemon, retrying briefly in case it's still starting."""
    path = daemon_socket_path()
    deadline = time.monotonic() + DAEMON_CONNECT_TIMEOUT
    last_err: Exception | None = None
    while time.monotonic() < deadline:
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(path)
            return s
        except (FileNotFoundError, ConnectionRefusedError) as e:
            last_err = e
            time.sleep(0.2)
    sys.stderr.write(f"error: cannot reach skill-config-daemon at {path}: {last_err}\n")
    sys.exit(3)


def cmd_request_input(args, paths: Paths) -> None:
    parts = args.key.split(".")
    if len(parts) != 3:
        sys.exit("error: key must be <skill>.<profile>.<field>")
    skill, profile, field = parts

    skill_dir = paths.skills_dir / skill
    if not skill_dir.exists():
        sys.exit(f"error: skill '{skill}' not found at {skill_dir}")
    cfg_fields, sec_fields = schema(skill_dir)
    if field in cfg_fields:
        description = cfg_fields[field]
        is_secret = False
    elif field in sec_fields:
        description = sec_fields[field]
        is_secret = True
    else:
        sys.exit(f"error: unknown field '{field}' for skill '{skill}'")

    sock = daemon_connect()
    sock_file = sock.makefile("rwb")

    request = {
        "op": "request",
        "skill": skill,
        "profile": profile,
        "field": field,
        "description": str(description),
        "secret": is_secret,
        "timeout_secs": args.timeout,
    }
    sock_file.write((json.dumps(request) + "\n").encode())
    sock_file.flush()

    registered = json.loads(sock_file.readline())
    if registered.get("op") != "registered":
        sys.exit(f"error: unexpected daemon response: {registered}")
    request_id = registered["request_id"]
    if args.verbose:
        sys.stderr.write(f"request {request_id} registered, waiting for input…\n")

    try:
        terminal = json.loads(sock_file.readline())
    except (ValueError, ConnectionResetError) as e:
        sys.exit(f"error: daemon connection lost: {e}")
    finally:
        sock.close()

    op = terminal.get("op")
    if op == "submitted":
        value = terminal.get("value", "")
        if not isinstance(value, str):
            sys.exit("error: daemon returned non-string value")
        # Route to the right TOML based on schema.
        if is_secret:
            path, mode = paths.secrets_toml, SECRETS_MODE
        else:
            path, mode = paths.config_toml, CONFIG_MODE
        doc = load_toml(path)
        section = section_get(doc, skill, profile)
        section[field] = value
        section_set(doc, skill, profile, section)
        save_toml(path, doc, mode)
        return
    if op == "cancelled":
        sys.stderr.write("cancelled by user\n")
        sys.exit(1)
    if op == "timeout":
        sys.stderr.write("timeout waiting for input\n")
        sys.exit(2)
    sys.exit(f"error: unexpected terminal op: {op}")


def cmd_remove(args, paths: Paths) -> None:
    config_doc = load_toml(paths.config_toml)
    secrets_doc = load_toml(paths.secrets_toml)

    removed = False
    if section_delete(config_doc, args.skill, args.profile):
        save_toml(paths.config_toml, config_doc, CONFIG_MODE)
        removed = True
    if section_delete(secrets_doc, args.skill, args.profile):
        save_toml(paths.secrets_toml, secrets_doc, SECRETS_MODE)
        removed = True

    if removed:
        print(f"✓ Removed profile '{args.profile}' for skill '{args.skill}'.")
    else:
        print(f"(nothing to remove for {args.skill}.{args.profile})")


def main() -> None:
    ap = argparse.ArgumentParser(prog="skill-config")
    ap.add_argument(
        "--instance",
        help="opencrow instance name (default: $OPENCROW_INSTANCE, or auto-detect)",
    )
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_init = sub.add_parser("init", help="set up a profile interactively")
    p_init.add_argument("skill")
    p_init.add_argument("profile", nargs="?")

    p_get = sub.add_parser("get", help="read one value (used by skills)")
    p_get.add_argument("key", help="<skill>.<profile>.<field>")

    p_set = sub.add_parser(
        "set", help="write one value (used by the skill-config skill)"
    )
    p_set.add_argument("key", help="<skill>.<profile>.<field>")
    p_set.add_argument("value")

    p_req = sub.add_parser(
        "request-input",
        help="open a popup via skill-config-daemon to receive one value",
    )
    p_req.add_argument("key", help="<skill>.<profile>.<field>")
    p_req.add_argument(
        "--timeout",
        type=int,
        default=120,
        help="seconds to wait for input (default 120)",
    )
    p_req.add_argument("-v", "--verbose", action="store_true")

    p_schema = sub.add_parser(
        "schema", help="dump a skill's config:/secrets: schema as YAML"
    )
    p_schema.add_argument("skill")

    p_list = sub.add_parser("list", help="show skills, profiles, and field state")
    p_list.add_argument("target", nargs="?", help="<skill> or <skill>.<profile>")

    p_remove = sub.add_parser("remove", help="delete a profile from both stores")
    p_remove.add_argument("skill")
    p_remove.add_argument("profile")

    args = ap.parse_args()
    instance = resolve_instance(args.instance)
    paths = Paths(instance)

    {
        "init": cmd_init,
        "get": cmd_get,
        "set": cmd_set,
        "request-input": cmd_request_input,
        "schema": cmd_schema,
        "list": cmd_list,
        "remove": cmd_remove,
    }[args.cmd](args, paths)


if __name__ == "__main__":
    main()

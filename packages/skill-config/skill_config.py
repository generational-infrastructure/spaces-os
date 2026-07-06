#!/usr/bin/env python3
"""skill-config: CLI front end over the skill_store engine.

Two audiences, one binary:

  * Agent-facing verbs (get/set/list/schema/remove/request-input): human-
    oriented output, `error: …` on stderr, non-zero exit on failure. The
    store layout and schema syntax are documented in skill_store.
  * `api`: the versioned JSON request/response seam machine callers
    (spaces-integrationd) drive; see cmd_api.

This module only parses argv, talks to the popup daemon, and maps
skill_store exceptions to exit codes + messages. All store logic —
TOML round-trips, schema routing (SKILL.md frontmatter vs
$SKILL_CONFIG_SCHEMA), file modes — lives in skill_store.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import time

import skill_store
import yaml
from skill_store import (
    Paths,
    SkillStore,
    SkillStoreError,
    skill_md_schema,
)

DEFAULT_DAEMON_SOCKET = "/run/spaces-skill-config-default.sock"
DAEMON_CONNECT_TIMEOUT = 3.0  # seconds, retried while daemon is starting

API_VERSION = 1


def cmd_get(args, store: SkillStore) -> None:
    parts = args.key.split(".")
    if len(parts) != 3:
        sys.exit("error: key must be <skill>.<profile>.<field>")
    skill, profile, field = parts
    skill = store.resolve_skill(skill)

    val = store.get(skill, profile, field)
    if val is None:
        sys.exit(
            f"error: {args.key} is not set. "
            f"Use the skill-config skill to onboard this field "
            f"(`skill-config request-input {args.key}` opens a popup "
            f"for the user)."
        )
    print(val)


def cmd_list(args, store: SkillStore) -> None:
    paths = store.paths

    if getattr(args, "json", False):
        if not args.target:
            sys.exit("error: --json requires a <skill> target")
        skill = store.resolve_skill(args.target.split(".")[0])
        print(json.dumps(store.profiles_snapshot(skill)))
        return

    if args.target:
        parts = args.target.split(".")
        skill = store.resolve_skill(parts[0])
        # The snapshot carries per-profile config values and secret
        # set-status; the schema supplies the names of unset fields.
        cfg_fields, sec_fields = store.load_schema(skill)
        snapshot = store.profiles_snapshot(skill)["profiles"]

        if len(parts) == 2:
            profiles = [parts[1]]
        else:
            profiles = sorted(snapshot)
            if not profiles:
                print(f"{skill}: no profiles configured")
                return

        for profile in profiles:
            state = snapshot.get(profile, {"config": {}, "secrets": {}})
            print(f"[{skill}.{profile}]")
            for name in cfg_fields:
                val = state["config"].get(name)
                rendered = repr(val) if val is not None else "[unset]"
                print(f"  {name} = {rendered}")
            for name in sec_fields:
                tag = "[set]" if state["secrets"].get(name) else "[unset]"
                print(f"  {name} = {tag}")
            print()
        return

    skills = store.list_skills()
    if not skills:
        print(f"(no skills found in {paths.skills_dir})")
        return
    for skill in skills:
        cfg_fields, sec_fields = skill_md_schema(paths.skills_dir / skill)
        if not cfg_fields and not sec_fields:
            print(f"{skill}  (no schema)")
            continue
        profiles = store.profile_names(skill)
        if not profiles:
            print(f"{skill}  (not configured)")
        else:
            print(f"{skill}")
            for p in profiles:
                print(f"  - {p}")


def cmd_set(args, store: SkillStore) -> None:
    parts = args.key.split(".")
    if len(parts) != 3:
        sys.exit("error: key must be <skill>.<profile>.<field>")
    skill, profile, field = parts
    skill = store.resolve_skill(skill)
    store.set(skill, profile, field, args.value)


def cmd_schema(args, store: SkillStore) -> None:
    skill = store.resolve_skill(args.skill)
    cfg_fields, sec_fields = store.load_schema(skill)
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


def cmd_request_input(args, store: SkillStore) -> None:
    parts = args.key.split(".")
    if len(parts) != 3:
        sys.exit("error: key must be <skill>.<profile>.<field>")
    skill, profile, field = parts
    skill = store.resolve_skill(skill)
    args.key = f"{skill}.{profile}.{field}"

    route = store.route(skill, field)

    sock = daemon_connect()
    sock_file = sock.makefile("rwb")

    request = {
        "op": "request",
        "skill": skill,
        "profile": profile,
        "field": field,
        "description": route.description,
        "secret": route.secret,
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
        store.set(skill, profile, field, value)
        # Print a confirmation so the agent has a visible signal that
        # the user submitted (small LLMs treat empty stdout as "nothing
        # happened" even when the exit code is 0).
        print(f"saved {args.key}")
        return
    if op == "cancelled":
        sys.stderr.write("cancelled by user\n")
        sys.exit(1)
    if op == "timeout":
        sys.stderr.write("timeout waiting for input\n")
        sys.exit(2)
    sys.exit(f"error: unexpected terminal op: {op}")


def cmd_remove(args, store: SkillStore) -> None:
    skill = store.resolve_skill(args.skill)
    if store.remove_profile(skill, args.profile):
        print(f"✓ Removed profile '{args.profile}' for skill '{skill}'.")
    else:
        print(f"(nothing to remove for {skill}.{args.profile})")


# ── the versioned machine seam ─────────────────────────────────────


def api_dispatch(req: dict, store: SkillStore) -> dict:
    """One api request -> its `result` payload. Raises SkillStoreError
    (or ValueError for envelope-level problems) on failure."""
    if req.get("v") != API_VERSION:
        raise ValueError(
            f"unsupported api version {req.get('v')!r} (want {API_VERSION})"
        )
    op = req.get("op")
    if op == "set":
        store.set(req["skill"], req["profile"], req["field"], req["value"])
        return {}
    if op == "remove-profile":
        return {"removed": store.remove_profile(req["skill"], req["profile"])}
    if op == "profiles":
        return store.profiles_snapshot(req["skill"])
    raise ValueError(f"unknown op {op!r}")


def cmd_api(args, store: SkillStore) -> None:
    """The versioned JSON seam for machine callers (spaces-integrationd).

    Reads ONE JSON request object from stdin and writes ONE response
    envelope to stdout; the exit code is 0 whenever an envelope was
    produced. Errors travel inside the envelope so callers never parse
    human-oriented stderr:

        request:  {"v": 1, "op": "...", ...}
        response: {"v": 1, "ok": true,  "result": {...}}
                | {"v": 1, "ok": false, "error": "message"}

    Ops (store files/schema selected by the usual SKILL_CONFIG_SCHEMA /
    SKILL_CONFIG_CONFIG_FILE / SKILL_CONFIG_SECRETS_FILE env overrides):

        set            {skill, profile, field, value} -> {}
        remove-profile {skill, profile}  -> {"removed": bool}
        profiles       {skill}           -> {"skill", "profiles": {name:
                          {"config": {field: value},
                           "secrets": {field: is_set}}}}
    """
    try:
        req = json.loads(sys.stdin.read())
        if not isinstance(req, dict):
            raise ValueError("request must be a JSON object")
    except ValueError as e:
        req, err = None, f"malformed request: {e}"
    else:
        err = None

    if req is not None:
        try:
            result = api_dispatch(req, store)
            print(json.dumps({"v": API_VERSION, "ok": True, "result": result}))
            return
        except (SkillStoreError, ValueError, KeyError) as e:
            err = f"missing key {e}" if isinstance(e, KeyError) else str(e)
    print(json.dumps({"v": API_VERSION, "ok": False, "error": err}))


def main() -> None:
    ap = argparse.ArgumentParser(prog="skill-config")
    ap.add_argument(
        "--instance",
        help="pi-chat instance name (default: $SPACES_PI_CHAT_INSTANCE, or auto-detect)",
    )
    sub = ap.add_subparsers(dest="cmd", required=True)

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
    p_list.add_argument(
        "-j",
        "--json",
        action="store_true",
        help="machine-readable output for <skill>: profiles with config values "
        "and secret set-status (never secret values)",
    )

    p_remove = sub.add_parser("remove", help="delete a profile from both stores")
    p_remove.add_argument("skill")
    p_remove.add_argument("profile")

    sub.add_parser(
        "api",
        help="versioned JSON request/response seam for machine callers "
        "(one request on stdin, one envelope on stdout)",
    )

    args = ap.parse_args()
    try:
        instance = skill_store.resolve_instance(args.instance)
    except SkillStoreError as e:
        sys.exit(f"error: {e}")
    store = SkillStore(Paths(instance))

    handler = {
        "get": cmd_get,
        "set": cmd_set,
        "request-input": cmd_request_input,
        "schema": cmd_schema,
        "list": cmd_list,
        "remove": cmd_remove,
        "api": cmd_api,
    }[args.cmd]
    try:
        handler(args, store)
    except SkillStoreError as e:
        sys.exit(f"error: {e}")


if __name__ == "__main__":
    main()

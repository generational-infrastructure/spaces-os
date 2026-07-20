"""CLI: derive keys, publish the config-repo pointer, resolve it back.

`publish` reads the config repo's git origin so you never retype the URL;
`resolve` gives it back from just the mnemonic. The mnemonic also derives the
ssh + age keys that clone the repo and decrypt its secrets.

The mnemonic comes from $SPACES_MNEMONIC or an interactive prompt — never argv.
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import subprocess
import sys
import time

from . import config, crypto, discovery, secp
from .manifest import Manifest
from .nostr import NostrTransport
from .transport import FileTransport, Transport


def _mnemonic() -> str:
    words = os.environ.get("SPACES_MNEMONIC")
    if not words:
        words = getpass.getpass("mnemonic (24 words): ")
    return words


def _seq(args: argparse.Namespace) -> int:
    return args.seq if args.seq is not None else time.time_ns() // 1000


def _git(repo: str, *cmd: str) -> str:
    result = subprocess.run(
        ["git", "-C", repo, *cmd],
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout.strip()


def _transports(args: argparse.Namespace, seed: bytes) -> list[Transport]:
    relays = getattr(args, "nostr", None) or config.DEFAULT_NOSTR_RELAYS
    transports: list[Transport] = [
        NostrTransport(relays, secret=secp.nostr_secret(seed))
    ]
    if getattr(args, "store", None):
        transports.append(FileTransport(args.store))
    return transports


def cmd_gen_mnemonic(_args: argparse.Namespace) -> int:
    print("# keep this secret — it is your entire recovery key", file=sys.stderr)
    print(crypto.generate_mnemonic())
    return 0


def cmd_derive(_args: argparse.Namespace) -> int:
    seed = crypto.master_seed(_mnemonic())
    identity = crypto.identity_key(seed).verify_key.encode()
    print(
        json.dumps(
            {
                # authorized_keys line for the backup host
                "identity_ssh": crypto.ssh_authorized_key(identity, "spaces-restore"),
                # clan secrets users add recovery <this>
                "age_recipient": crypto.age_recipient(seed),
                "nostr_pub": secp.xonly_pubkey(secp.nostr_secret(seed)).hex(),
            },
            indent=2,
        )
    )
    return 0


def cmd_age_identity(_args: argparse.Namespace) -> int:
    seed = crypto.master_seed(_mnemonic())
    print(
        "# secret age key — `export SOPS_AGE_KEY=…`; treat like the mnemonic",
        file=sys.stderr,
    )
    print(crypto.age_identity(seed))
    return 0


def cmd_publish(args: argparse.Namespace) -> int:
    seed = crypto.master_seed(_mnemonic())
    repo = args.repo or "."
    config_url = args.config or _git(repo, "remote", "get-url", "origin")
    rev = args.rev if args.rev is not None else _git(repo, "rev-parse", "HEAD")
    record = discovery.author(seed, Manifest(config=config_url, rev=rev), _seq(args))
    report = discovery.publish(record, _transports(args, seed))
    shortrev = rev[:12] if rev else "(no rev)"
    ok = sum(1 for _endpoint, good, _err in report if good)
    print(
        f"published {config_url}@{shortrev} to {ok}/{len(report)} endpoint(s):",
        file=sys.stderr,
    )
    for endpoint, good, err in report:
        mark = "ok " if good else "FAIL"
        suffix = f"  ({err})" if err else ""
        print(f"  [{mark}] {endpoint}{suffix}", file=sys.stderr)
    return 0


def cmd_resolve(args: argparse.Namespace) -> int:
    seed = crypto.master_seed(_mnemonic())
    print(discovery.resolve(seed, _transports(args, seed)).to_json().decode())
    return 0


def _add_nostr_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--nostr",
        action="append",
        help="Nostr relay wss:// URL (repeatable; default: baked list)",
    )
    parser.add_argument("--store", help="also use a local file store (offline copy)")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="spaces-restore",
        description="Mnemonic restore — keys + config-pointer discovery.",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("gen-mnemonic", help="generate a fresh random 24-word mnemonic")
    sub.add_parser("derive", help="print ssh + age recipient + nostr keys")
    sub.add_parser(
        "age-identity", help="print the secret age key (AGE-SECRET-KEY-…) for restore"
    )

    pub = sub.add_parser(
        "publish", help="publish the config repo pointer (from git origin)"
    )
    pub.add_argument("--repo", help="path to the config repo (default: .)")
    pub.add_argument("--config", help="config URL/RID (default: the repo's git origin)")
    pub.add_argument(
        "--rev", help="commit to pin (default: current HEAD; pass '' for none)"
    )
    pub.add_argument("--seq", type=int, default=None)
    _add_nostr_args(pub)

    res = sub.add_parser(
        "resolve", help="fetch the config pointer with just the mnemonic"
    )
    _add_nostr_args(res)

    args = parser.parse_args(argv)
    handlers = {
        "gen-mnemonic": cmd_gen_mnemonic,
        "derive": cmd_derive,
        "age-identity": cmd_age_identity,
        "publish": cmd_publish,
        "resolve": cmd_resolve,
    }
    return handlers[args.cmd](args)

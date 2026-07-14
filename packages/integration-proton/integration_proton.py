"""Proton Mail MCP integration server (Proton Bridge backed).

Speaks NDJSON JSON-RPC 2.0 over a unix socket via the shared
spaces_integration_mcp scaffold and reuses the shared spaces_himalaya_core tool
bodies (envelope_list/message_read/message_send). Only the transport differs
from integration-mail: everything is pinned to the local Proton Bridge instead
of an arbitrary IMAP/SMTP host.

- IMAP read goes straight through himalaya to Bridge on 127.0.0.1:1143
  (STARTTLS), trusting Bridge's self-signed CA:TRUE leaf via
  `backend.encryption.cert`.
- Sending is routed through himalaya's `sendmail` backend to msmtp, because
  himalaya 1.2.0's rustls SMTP stack rejects Bridge's CA:TRUE certificate
  (pimalaya/himalaya#633). msmtp (GnuTLS) accepts it via `tls_trust_file`. This
  is a workaround: drop the msmtp detour once nixpkgs ships himalaya > 1.2.0 and
  send straight over 127.0.0.1:1025 STARTTLS with `backend.encryption.cert`.

The bridge password is never written to any config file: himalaya's
`backend.auth.cmd` and msmtp's `passwordeval` both shell out to the second
console script `integration-proton-authcmd`, which prints the sealed-store
`bridge_password` for the named profile.

Before any himalaya exec a `precheck` probes the Bridge (cert present + IMAP port
reachable); a down/unonboarded Bridge yields a single onboarding-hint error
instead of an opaque himalaya failure.
"""

import os
import shutil
import socket
import sys
import tempfile

from spaces_himalaya_core import make_tool_impls, toml_escape
from spaces_integration_mcp import make_server, store_profile

SERVER_NAME = "integration-proton"
SERVER_VERSION = "0.1.0"

# Pinned Bridge transport. No host/port/cert fields ever live in the store: the
# local Bridge always listens here, so the values are constants, not config.
BRIDGE_HOST = "127.0.0.1"
IMAP_PORT = 1143
SMTP_PORT = 1025
ENCRYPTION = "start-tls"

# Second console script himalaya + msmtp call to fetch the bridge password from
# the sealed store. Overridable via the SPACES_PROTON_AUTHCMD env var (consulted
# in _authcmd()) so tests point at a resolvable command without the wheel's
# entry point being installed.
AUTHCMD = "integration-proton-authcmd"

# Store fields every tool needs before himalaya can run. The full field schema
# (descriptions, required flags) lives in schema.json, single-sourced by the
# host manifest; the scaffold gates these per call. bridge_password first so a
# missing secret is reported ahead of missing config.
_NEEDS = ("bridge_password", "email")

# Bridge's serving cert for mail clients, under the state root the manifest pins
# via SPACES_PROTON_BRIDGE_STATE (XDG_CONFIG_HOME = <state>/config).
_STATE_ENV = "SPACES_PROTON_BRIDGE_STATE"
_DEFAULT_STATE = "~/.local/state/protonmail-bridge"
_CERT_RELPATH = "config/protonmail/bridge-v3/cert.pem"

# Bridge-probe timeout: a local TCP connect either wins immediately or the
# Bridge is down; keep it short so a probe failure surfaces fast.
_PROBE_TIMEOUT = 2.0

_ONBOARDING_HINT = (
    "Proton Bridge is not running or not set up yet. Open "
    "Settings -> Integrations -> Proton Mail -> Set up to sign in and start "
    "the bridge, then try again."
)

# Private key under which the per-call msmtprc tempdir is threaded from the impl
# wrapper (which owns its lifetime) down to _build_config (which fills it). Kept
# out of the field namespace so it never collides with a store field.
_SCRATCH = "_proton_scratch"


def _state_root():
    return os.path.expanduser(os.environ.get(_STATE_ENV) or _DEFAULT_STATE)


def _cert_path():
    return os.path.join(_state_root(), _CERT_RELPATH)


def _authcmd():
    # himalaya/msmtp (spawned by this server, under the integration unit) do not
    # have the package's own bin dir on PATH, so a bare name would not resolve.
    # Prefer the env override (tests), then the sibling script next to our own
    # executable ($out/bin/integration-proton-authcmd), then a PATH lookup.
    override = os.environ.get("SPACES_PROTON_AUTHCMD")
    if override:
        return override
    here = os.path.dirname(os.path.realpath(sys.argv[0]))
    sibling = os.path.join(here, AUTHCMD)
    if os.path.exists(sibling):
        return sibling
    return shutil.which(AUTHCMD) or AUTHCMD


def _msmtprc_text(profile, email, cert):
    auth = f"{_authcmd()} {profile}"
    return "\n".join(
        [
            # msmtp detour: himalaya 1.2.0's rustls SMTP rejects Bridge's
            # CA:TRUE cert (pimalaya/himalaya#633). msmtp (GnuTLS) trusts it via
            # tls_trust_file. Drop this file when nixpkgs ships himalaya > 1.2.0.
            "# msmtp detour for Proton Bridge (pimalaya/himalaya#633);"
            " drop when nixpkgs ships himalaya > 1.2.0",
            f"account {profile}",
            f"host {BRIDGE_HOST}",
            f"port {SMTP_PORT}",
            "auth on",
            "tls on",
            "tls_starttls on",
            f"tls_trust_file {cert}",
            f"user {email}",
            f'passwordeval "{auth}"',
            "",
        ]
    )


def _himalaya_config(profile, email, cert, msmtprc):
    auth = toml_escape(f"{_authcmd()} {profile}")
    e = toml_escape(email)
    return "\n".join(
        [
            f"[accounts.{profile}]",
            f'email = "{e}"',
            "default = true",
            'backend.type = "imap"',
            f'backend.host = "{BRIDGE_HOST}"',
            f"backend.port = {IMAP_PORT}",
            f'backend.encryption.type = "{ENCRYPTION}"',
            f'backend.encryption.cert = "{toml_escape(cert)}"',
            f'backend.login = "{e}"',
            'backend.auth.type = "password"',
            f'backend.auth.cmd = "{auth}"',
            # Send via himalaya's sendmail backend -> msmtp (see _msmtprc_text).
            'message.send.backend.type = "sendmail"',
            f'message.send.backend.cmd = "msmtp -C {toml_escape(msmtprc)} -a {profile} -t"',
            "",
        ]
    )


def _build_config(profile, vals):
    """Render the himalaya TOML for the profile and materialize the sibling
    msmtprc it references (host/ports pinned to Bridge, both trusting Bridge's
    cert). Returns (config_toml, None); Proton has no numeric-port parse to
    fail on, so the error slot is always None.

    The msmtprc is written 0600 into a per-call private tempdir; its dir path is
    registered in the caller-supplied scratch dict so the impl wrapper can
    remove it once himalaya (and any msmtp it spawns) has finished. When called
    without a scratch (direct unit test) the caller owns cleanup of the dir the
    returned cmd points at.
    """
    email = vals["email"]
    cert = _cert_path()

    d = tempfile.mkdtemp(prefix="integration-proton-")
    scratch = vals.get(_SCRATCH)
    if scratch is not None:
        scratch["dir"] = d

    msmtprc = os.path.join(d, "msmtprc")
    with open(msmtprc, "w", encoding="utf-8") as f:
        f.write(_msmtprc_text(profile, email, cert))
    os.chmod(msmtprc, 0o600)

    return _himalaya_config(profile, email, cert, msmtprc), None


def bridge_probe(profile, vals):
    """Pre-flight Bridge health: return None to proceed, else the onboarding
    hint. Bridge is usable only when its serving cert exists (onboarded) AND its
    IMAP port answers (daemon up). Overridable in tests by monkeypatching this
    name (the precheck resolves it dynamically).
    """
    if not os.path.exists(_cert_path()):
        return _ONBOARDING_HINT
    try:
        with socket.create_connection((BRIDGE_HOST, IMAP_PORT), timeout=_PROBE_TIMEOUT):
            return None
    except OSError:
        return _ONBOARDING_HINT


def _precheck(profile, vals):
    # Indirection so tests can monkeypatch integration_proton.bridge_probe.
    return bridge_probe(profile, vals)


def _wrap(base):
    """Give a shared tool impl a per-call msmtprc scratch dir and guarantee its
    removal, whatever the impl returns or raises (the himalaya exec, and any
    msmtp it spawns, complete synchronously inside the base impl).
    """

    def impl(args, profile, vals):
        scratch = {}
        try:
            return base(args, profile, {**vals, _SCRATCH: scratch})
        finally:
            d = scratch.get("dir")
            if d:
                shutil.rmtree(d, ignore_errors=True)

    return impl


def authcmd():
    """Second console script (integration-proton-authcmd): the credential
    fetcher himalaya's backend.auth.cmd and msmtp's passwordeval both call.
    Prints the sealed-store bridge_password for argv[1] so the secret is never
    written to any config file.
    """
    print(store_profile(sys.argv[1])["bridge_password"])


_base_impls = make_tool_impls(_build_config, precheck=_precheck)
_impls = {name: _wrap(impl) for name, impl in _base_impls.items()}

TOOLS, call_tool, main = make_server(
    SERVER_NAME,
    SERVER_VERSION,
    [
        {
            "name": "envelope_list",
            "description": "List envelopes (message headers) in a folder, as JSON",
            "schema": {
                "properties": {
                    "folder": {
                        "type": "string",
                        "description": "mailbox folder (default: INBOX)",
                    },
                },
                "required": [],
            },
            "needs_fields": _NEEDS,
            "impl": _impls["envelope_list"],
        },
        {
            "name": "message_read",
            "description": "Read a message by its envelope id",
            "schema": {
                "properties": {
                    "id": {"type": "string", "description": "envelope id"},
                },
                "required": ["id"],
            },
            "needs_fields": _NEEDS,
            "impl": _impls["message_read"],
        },
        {
            "name": "message_send",
            "description": "Send a raw RFC822 message (headers and body)",
            "schema": {
                "properties": {
                    "message": {
                        "type": "string",
                        "description": "raw RFC822 message, including headers and body",
                    },
                },
                "required": ["message"],
            },
            "needs_fields": _NEEDS,
            "impl": _impls["message_send"],
        },
    ],
    secret_field="bridge_password",  # noqa: S106 (names the store field, not a credential)
    error_label="proton mail operation",
)


if __name__ == "__main__":
    sys.exit(main())

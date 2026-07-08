"""Mail (IMAP/SMTP) MCP integration server (spaces integration POC).

Speaks NDJSON JSON-RPC 2.0 over a unix socket via the shared
spaces_integration_mcp scaffold, which owns dispatch, profile resolution,
required-field gating, and the hidden secret_fingerprint tool. Wraps the
`himalaya` CLI via the shared spaces_himalaya_core: on every call it
materializes a himalaya TOML config for the resolved profile in a throwaway
tempdir, then execs `himalaya -c <cfg> <subcommand...>`.

The mailbox password is NEVER written to the config file. himalaya fetches it
at runtime via `backend.auth.cmd`, which points at the second console script
`integration-mail-authcmd`; that script prints the sealed-store password to
stdout for the named profile and nothing else.

Only the generic IMAP/SMTP config generation is mail-specific; the tool bodies,
config-file handling, and himalaya exec live in spaces_himalaya_core and are
shared with the Proton integration.
"""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

from spaces_himalaya_core import enc_for_port, make_tool_impls, toml_escape
from spaces_integration_mcp import make_server, store_profile

SERVER_NAME = "integration-mail"
SERVER_VERSION = "0.1.0"

# Second console script that himalaya calls as backend.auth.cmd to fetch the
# password from the sealed store. Overridable via env so tests can point at a
# resolvable command without the wheel's entry point being installed.
AUTHCMD = "integration-mail-authcmd"

# Store fields every mail tool needs before himalaya can run. The full
# config/secrets field schema (descriptions, required flags) lives in the
# package's schema.json, which the host manifest single-sources; the scaffold
# gates these fields per call. password first so a missing password is
# reported ahead of missing config.
_NEEDS = ("password", "email", "imap_host", "smtp_host")


def _authcmd() -> str:
    # himalaya (spawned by this server, under the integration unit) does not
    # have the package's own bin dir on PATH, so a bare name would not resolve.
    # Prefer the env override (tests), then the sibling script next to our own
    # executable ($out/bin/integration-mail-authcmd), then a PATH lookup.
    override = os.environ.get("SPACES_MAIL_AUTHCMD")
    if override:
        return override
    sibling = Path(os.path.realpath(sys.argv[0])).parent / AUTHCMD
    if sibling.exists():
        return str(sibling)
    return shutil.which(AUTHCMD) or AUTHCMD


def _build_config(
    profile: str, vals: dict[str, str]
) -> tuple[str, None] | tuple[None, str]:
    """Return (config_toml, None) for the profile, or (None, error_text) when a
    port is not numeric. The required fields are gated by the scaffold before
    any impl runs. The password is never emitted — himalaya fetches it via
    backend.auth.cmd.
    """
    email = vals["email"]
    imap_host = vals["imap_host"]
    smtp_host = vals["smtp_host"]

    imap_port = vals.get("imap_port") or "993"
    smtp_port = vals.get("smtp_port") or "587"
    try:
        imap_port_n = int(imap_port)
        smtp_port_n = int(smtp_port)
    except (TypeError, ValueError):
        return None, f"invalid port for profile '{profile}'"

    imap_login = vals.get("imap_login") or email
    smtp_login = vals.get("smtp_login") or email
    imap_enc = vals.get("imap_encryption") or enc_for_port(imap_port)
    smtp_enc = vals.get("smtp_encryption") or enc_for_port(smtp_port)
    display_name = vals.get("display_name")

    auth = toml_escape(f"{_authcmd()} {profile}")

    lines = [f"[accounts.{profile}]", f'email = "{toml_escape(email)}"']
    if display_name:
        lines.append(f'display-name = "{toml_escape(display_name)}"')
    lines += [
        "default = true",
        'backend.type = "imap"',
        f'backend.host = "{toml_escape(imap_host)}"',
        f"backend.port = {imap_port_n}",
        f'backend.encryption.type = "{imap_enc}"',
        f'backend.login = "{toml_escape(imap_login)}"',
        'backend.auth.type = "password"',
        f'backend.auth.cmd = "{auth}"',
        'message.send.backend.type = "smtp"',
        f'message.send.backend.host = "{toml_escape(smtp_host)}"',
        f"message.send.backend.port = {smtp_port_n}",
        f'message.send.backend.encryption.type = "{smtp_enc}"',
        f'message.send.backend.login = "{toml_escape(smtp_login)}"',
        'message.send.backend.auth.type = "password"',
        f'message.send.backend.auth.cmd = "{auth}"',
        "",
    ]
    return "\n".join(lines), None


def authcmd() -> None:
    """Second console script (integration-mail-authcmd): himalaya's
    backend.auth.cmd. Prints the sealed-store password for the profile named in
    argv[1] to stdout so the password is never written to any file.
    """
    print(store_profile(sys.argv[1])["password"])


# Mail needs no pre-flight probe: himalaya talks straight to the mailbox, so the
# tool bodies run with the default precheck=None.
_impls = make_tool_impls(_build_config)

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
    secret_field="password",  # noqa: S106 (names the store field, not a credential)
    error_label="mail operation",
)


if __name__ == "__main__":
    sys.exit(main())

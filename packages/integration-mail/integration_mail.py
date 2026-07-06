"""Mail (IMAP/SMTP) MCP integration server (spaces integration POC).

Speaks NDJSON JSON-RPC 2.0 over a unix socket via the shared
spaces_integration_mcp scaffold, which owns dispatch, profile resolution,
required-field gating, and the hidden secret_fingerprint tool. Wraps the
`himalaya` CLI: on every call it materializes a himalaya TOML config for the
resolved profile in a throwaway tempdir, then execs
`himalaya -c <cfg> <subcommand...>`.

The mailbox password is NEVER written to the config file. himalaya fetches it
at runtime via `backend.auth.cmd`, which points at the second console script
`integration-mail-authcmd`; that script prints the sealed-store password to
stdout for the named profile and nothing else.
"""

import contextlib
import os
import shutil
import subprocess
import sys
import tempfile

from spaces_integration_mcp import make_server, store_profile

SERVER_NAME = "integration-mail"
SERVER_VERSION = "0.1.0"

# himalaya is resolved via PATH: production wraps PATH to nixpkgs' himalaya,
# tests shadow it with a stub binary on a prepended PATH entry.
HIMALAYA = "himalaya"

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


def _authcmd():
    # himalaya (spawned by this server, under the integration unit) does not
    # have the package's own bin dir on PATH, so a bare name would not resolve.
    # Prefer the env override (tests), then the sibling script next to our own
    # executable ($out/bin/integration-mail-authcmd), then a PATH lookup.
    override = os.environ.get("SPACES_MAIL_AUTHCMD")
    if override:
        return override
    here = os.path.dirname(os.path.realpath(sys.argv[0]))
    sibling = os.path.join(here, AUTHCMD)
    if os.path.exists(sibling):
        return sibling
    return shutil.which(AUTHCMD) or AUTHCMD


def _enc_for_port(port):
    """himalaya encryption type inferred from a port when none is pinned:
    993/465 are implicit TLS, 587/143 negotiate STARTTLS, 25 is plaintext,
    anything else defaults to TLS (mirrors mail.sh's enc_for_port)."""
    return {
        "993": "tls",
        "465": "tls",
        "587": "start-tls",
        "143": "start-tls",
        "25": "none",
    }.get(str(port), "tls")


def _toml_escape(s):
    """TOML basic-string escaping for the few free-text values."""
    return str(s).replace("\\", "\\\\").replace('"', '\\"')


def _build_config(profile, vals):
    """Return (config_toml, None) for the profile, or (None, error_text) when a
    port is not numeric. The required fields are gated by the scaffold before
    any impl runs. The password is never emitted — himalaya fetches it via
    backend.auth.cmd."""

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
    imap_enc = vals.get("imap_encryption") or _enc_for_port(imap_port)
    smtp_enc = vals.get("smtp_encryption") or _enc_for_port(smtp_port)
    display_name = vals.get("display_name")

    auth = _toml_escape(f"{_authcmd()} {profile}")

    lines = [f"[accounts.{profile}]", f'email = "{_toml_escape(email)}"']
    if display_name:
        lines.append(f'display-name = "{_toml_escape(display_name)}"')
    lines += [
        "default = true",
        'backend.type = "imap"',
        f'backend.host = "{_toml_escape(imap_host)}"',
        f"backend.port = {imap_port_n}",
        f'backend.encryption.type = "{imap_enc}"',
        f'backend.login = "{_toml_escape(imap_login)}"',
        'backend.auth.type = "password"',
        f'backend.auth.cmd = "{auth}"',
        'message.send.backend.type = "smtp"',
        f'message.send.backend.host = "{_toml_escape(smtp_host)}"',
        f"message.send.backend.port = {smtp_port_n}",
        f'message.send.backend.encryption.type = "{smtp_enc}"',
        f'message.send.backend.login = "{_toml_escape(smtp_login)}"',
        'message.send.backend.auth.type = "password"',
        f'message.send.backend.auth.cmd = "{auth}"',
        "",
    ]
    return "\n".join(lines), None


@contextlib.contextmanager
def _config_file(text):
    """Write the himalaya config to a 0600 file inside a private tempdir, yield
    its path, and remove the tempdir on exit."""
    d = tempfile.mkdtemp(prefix="integration-mail-")
    try:
        path = os.path.join(d, "himalaya.toml")
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(path, 0o600)
        yield path
    finally:
        shutil.rmtree(d, ignore_errors=True)


def _run_himalaya(cfg, sub_args, stdin=None):
    """Exec himalaya against the generated config; return (stdout, False) or,
    on a non-zero exit / spawn failure, (stderr-or-stdout, True). stdin is sent
    verbatim as bytes so a raw RFC822 message keeps its CRLF line endings."""
    argv = [HIMALAYA, "-c", cfg] + sub_args
    data = stdin.encode("utf-8") if isinstance(stdin, str) else stdin
    try:
        proc = subprocess.run(argv, input=data, capture_output=True)
    except OSError as e:
        return f"failed to run {HIMALAYA}: {e.__class__.__name__}: {e}", True
    out = proc.stdout.decode("utf-8", "replace")
    err = proc.stderr.decode("utf-8", "replace")
    if proc.returncode != 0:
        msg = (
            err.strip()
            or out.strip()
            or f"{HIMALAYA} exited with status {proc.returncode}"
        )
        return msg, True
    return out, False


def _tool_envelope_list(args, profile, vals):
    cfg_text, err = _build_config(profile, vals)
    if err:
        return err, True
    sub = ["-o", "json", "envelope", "list", "-a", profile]
    folder = args.get("folder")
    if folder:
        sub += ["-f", str(folder)]
    with _config_file(cfg_text) as cfg:
        return _run_himalaya(cfg, sub)


def _tool_message_read(args, profile, vals):
    mid = args.get("id")
    if not mid:
        return "missing required argument: id", True
    cfg_text, err = _build_config(profile, vals)
    if err:
        return err, True
    with _config_file(cfg_text) as cfg:
        return _run_himalaya(cfg, ["message", "read", "-a", profile, str(mid)])


def _tool_message_send(args, profile, vals):
    message = args.get("message")
    if not isinstance(message, str) or not message:
        return "missing required argument: message", True
    cfg_text, err = _build_config(profile, vals)
    if err:
        return err, True
    with _config_file(cfg_text) as cfg:
        return _run_himalaya(cfg, ["message", "send", "-a", profile], stdin=message)


def authcmd():
    """Second console script (integration-mail-authcmd): himalaya's
    backend.auth.cmd. Prints the sealed-store password for the profile named in
    argv[1] to stdout so the password is never written to any file."""
    print(store_profile(sys.argv[1])["password"])


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
            "impl": _tool_envelope_list,
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
            "impl": _tool_message_read,
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
            "impl": _tool_message_send,
        },
    ],
    secret_field="password",
    error_label="mail operation",
)


if __name__ == "__main__":
    sys.exit(main())

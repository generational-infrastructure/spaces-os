"""Shared himalaya CLI core for spaces mail-family integrations.

The himalaya config generation, 0600 tempfile handling, subprocess exec/error
mapping, and the envelope_list/message_read/message_send tool bodies are
identical across every mailbox backend, so they live here once and each
integration server injects only what differs.

`integration-mail` builds a generic IMAP/SMTP config and needs no pre-flight
probe. `integration-proton` reuses the SAME tool bodies but pins the transport
to the local Proton Bridge and passes a `precheck` that probes the Bridge
before any himalaya exec; see integration_proton.py's module docs for the
Bridge transport and msmtp-workaround details.
"""

import contextlib
import os
import shutil
import subprocess
import tempfile

# himalaya is resolved via PATH: production wraps PATH to nixpkgs' himalaya,
# tests shadow it with a stub binary on a prepended PATH entry.
HIMALAYA = "himalaya"


def enc_for_port(port):
    """Himalaya encryption type inferred from a port when none is pinned:
    993/465 are implicit TLS, 587/143 negotiate STARTTLS, 25 is plaintext,
    anything else defaults to TLS (mirrors mail.sh's enc_for_port).
    """
    return {
        "993": "tls",
        "465": "tls",
        "587": "start-tls",
        "143": "start-tls",
        "25": "none",
    }.get(str(port), "tls")


def toml_escape(s):
    """TOML basic-string escaping for the few free-text values."""
    return str(s).replace("\\", "\\\\").replace('"', '\\"')


@contextlib.contextmanager
def config_file(text, prefix="himalaya-"):
    """Write the himalaya config to a 0600 file inside a private tempdir, yield
    its path, and remove the tempdir on exit.
    """
    d = tempfile.mkdtemp(prefix=prefix)
    try:
        path = os.path.join(d, "himalaya.toml")
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(path, 0o600)
        yield path
    finally:
        shutil.rmtree(d, ignore_errors=True)


def run_himalaya(cfg, sub_args, stdin=None):
    """Exec himalaya against the generated config; return (stdout, False) or,
    on a non-zero exit / spawn failure, (stderr-or-stdout, True). stdin is sent
    verbatim as bytes so a raw RFC822 message keeps its CRLF line endings.
    """
    argv = [HIMALAYA, "-c", cfg, *sub_args]
    data = stdin.encode("utf-8") if isinstance(stdin, str) else stdin
    try:
        proc = subprocess.run(argv, input=data, capture_output=True, check=False)
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


def make_tool_impls(build_config, precheck=None):
    """Build the {envelope_list, message_read, message_send} scaffold impls,
    each `(arguments, profile, vals) -> (text, is_error)`, parameterized by the
    two things that differ between backends:

    - `build_config(profile, vals) -> (config_toml | None, error_text | None)`
      renders the himalaya config for the profile.
    - `precheck(profile, vals) -> error_text | None` is an optional pre-flight
      probe. It runs after per-call argument validation but before any himalaya
      exec; a non-None result short-circuits to `(error_text, True)`, so
      himalaya is never spawned. Default None means no probe (mail); proton
      passes a Bridge probe here.

    The tool bodies (arg validation messages, himalaya subcommands, JSON output
    flag, stdin handling) are shared verbatim across backends.
    """

    def _probe(profile, vals):
        # None => proceed; (err, True) => caller returns it and skips himalaya.
        if precheck is None:
            return None
        err = precheck(profile, vals)
        return (err, True) if err else None

    def envelope_list(args, profile, vals):
        blocked = _probe(profile, vals)
        if blocked:
            return blocked
        cfg_text, err = build_config(profile, vals)
        if err:
            return err, True
        sub = ["-o", "json", "envelope", "list", "-a", profile]
        folder = args.get("folder")
        if folder:
            sub += ["-f", str(folder)]
        with config_file(cfg_text) as cfg:
            return run_himalaya(cfg, sub)

    def message_read(args, profile, vals):
        mid = args.get("id")
        if not mid:
            return "missing required argument: id", True
        blocked = _probe(profile, vals)
        if blocked:
            return blocked
        cfg_text, err = build_config(profile, vals)
        if err:
            return err, True
        with config_file(cfg_text) as cfg:
            return run_himalaya(cfg, ["message", "read", "-a", profile, str(mid)])

    def message_send(args, profile, vals):
        message = args.get("message")
        if not isinstance(message, str) or not message:
            return "missing required argument: message", True
        blocked = _probe(profile, vals)
        if blocked:
            return blocked
        cfg_text, err = build_config(profile, vals)
        if err:
            return err, True
        with config_file(cfg_text) as cfg:
            return run_himalaya(cfg, ["message", "send", "-a", profile], stdin=message)

    return {
        "envelope_list": envelope_list,
        "message_read": message_read,
        "message_send": message_send,
    }

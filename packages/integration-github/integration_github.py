"""GitHub MCP integration server (spaces integration POC).

NDJSON JSON-RPC 2.0 over a unix socket. Listening socket arrives either as
fd 3 (systemd socket activation, LISTEN_FDS) or is bound at
SPACES_INTEGRATION_SOCKET (tests). Serves connections sequentially.
"""

import hashlib
import json
import os
import re
import socket
import sys
import urllib.error
import urllib.request

PROTOCOL_VERSION = "2025-03-26"
SERVER_NAME = "integration-github"
SERVER_VERSION = "0.1.0"

REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")

TOOLS = [
    {
        "name": "get_repo",
        "description": "Fetch repository metadata (stars, description, default branch)",
        "inputSchema": {
            "type": "object",
            "properties": {
                "repo": {"type": "string", "description": "owner/name"},
            },
            "required": ["repo"],
        },
    },
    {
        "name": "create_issue",
        "description": "Create an issue in a repository",
        "inputSchema": {
            "type": "object",
            "properties": {
                "repo": {"type": "string", "description": "owner/name"},
                "title": {"type": "string"},
                "body": {"type": "string"},
            },
            "required": ["repo", "title"],
        },
    },
]


def _api_base():
    return os.environ.get("SPACES_GITHUB_API_URL", "https://api.github.com").rstrip("/")


def _read_token():
    creds_dir = os.environ.get("CREDENTIALS_DIRECTORY")
    if not creds_dir:
        return None
    try:
        with open(os.path.join(creds_dir, "token"), encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return None


def _http(req):
    """Run an urllib request, return (parsed-json, None) or (None, error-text)."""
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp), None
    except urllib.error.HTTPError as e:
        return (
            None,
            f"GitHub API error: HTTP {e.code} for {req.get_method()} {req.full_url}",
        )
    except (urllib.error.URLError, OSError, ValueError) as e:
        return None, f"GitHub API request failed: {e.__class__.__name__}: {e}"


def _tool_get_repo(args, token):
    repo = args.get("repo", "")
    if not REPO_RE.fullmatch(repo):
        return f"invalid repo name: {repo!r}", True
    req = urllib.request.Request(
        f"{_api_base()}/repos/{repo}",
        headers={"Accept": "application/vnd.github+json"},
    )
    data, err = _http(req)
    if err:
        return err, True
    text = (
        f"{data.get('full_name')}: {data.get('description')} "
        f"(stars {data.get('stargazers_count')}, default branch {data.get('default_branch')})"
    )
    return text, False


def _tool_create_issue(args, token):
    repo = args.get("repo", "")
    if not REPO_RE.fullmatch(repo):
        return f"invalid repo name: {repo!r}", True
    title = args.get("title")
    if not isinstance(title, str) or not title:
        return "missing required argument: title", True
    body = {"title": title, "body": args.get("body", "")}
    req = urllib.request.Request(
        f"{_api_base()}/repos/{repo}/issues",
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    data, err = _http(req)
    if err:
        return err, True
    return f"created issue #{data.get('number')}: {data.get('html_url')}", False


def _tool_secret_fingerprint(args, token):
    return hashlib.sha256(token.encode("utf-8")).hexdigest()[:16], False


_TOOL_IMPLS = {
    "get_repo": _tool_get_repo,
    "create_issue": _tool_create_issue,
    "secret_fingerprint": _tool_secret_fingerprint,
}


def _tools_call(params):
    name = params.get("name")
    impl = _TOOL_IMPLS.get(name)
    if impl is None:
        return {
            "content": [{"type": "text", "text": f"unknown tool: {name}"}],
            "isError": True,
        }
    token = _read_token()
    if not token:
        return {
            "content": [
                {"type": "text", "text": "credential 'token' is not available"}
            ],
            "isError": True,
        }
    args = params.get("arguments") or {}
    text, is_error = impl(args, token)
    return {"content": [{"type": "text", "text": text}], "isError": is_error}


def _handle_request(req):
    """Return a JSON-RPC response dict, or None for notifications."""
    method = req.get("method")
    req_id = req.get("id")
    is_notification = "id" not in req

    if method == "initialize":
        result = {
            "protocolVersion": PROTOCOL_VERSION,
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            "capabilities": {"tools": {}},
        }
    elif method == "notifications/initialized":
        return None
    elif method == "tools/list":
        result = {"tools": TOOLS}
    elif method == "tools/call":
        result = _tools_call(req.get("params") or {})
    else:
        if is_notification:
            return None
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {"code": -32601, "message": f"method not found: {method}"},
        }

    if is_notification:
        return None
    return {"jsonrpc": "2.0", "id": req_id, "result": result}


def _handle_line(line):
    """Return a response dict, or None when no reply is owed."""
    try:
        req = json.loads(line)
        if not isinstance(req, dict):
            raise ValueError("request is not an object")
    except ValueError as e:
        return {
            "jsonrpc": "2.0",
            "id": None,
            "error": {"code": -32700, "message": f"parse error: {e}"},
        }
    return _handle_request(req)


def _serve_connection(conn):
    with conn, conn.makefile("rb") as reader:
        for line in reader:
            line = line.strip()
            if not line:
                continue
            resp = _handle_line(line)
            if resp is not None:
                conn.sendall(json.dumps(resp).encode("utf-8") + b"\n")


def serve(sock):
    while True:
        try:
            conn, _ = sock.accept()
        except OSError:
            return
        try:
            _serve_connection(conn)
        except Exception as e:  # noqa: BLE001 — never crash the accept loop
            print(f"connection error: {e.__class__.__name__}: {e}", file=sys.stderr)


def main():
    if os.environ.get("LISTEN_FDS"):
        sock = socket.socket(fileno=3)
    elif os.environ.get("SPACES_INTEGRATION_SOCKET"):
        path = os.environ["SPACES_INTEGRATION_SOCKET"]
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.bind(path)
        sock.listen(8)
    else:
        print(
            "integration-github: no listening socket "
            "(set LISTEN_FDS via socket activation or SPACES_INTEGRATION_SOCKET)",
            file=sys.stderr,
        )
        return 2
    serve(sock)
    return 0


if __name__ == "__main__":
    sys.exit(main())

"""GitHub MCP integration server (spaces integration POC).

NDJSON JSON-RPC 2.0 over a unix socket. Listening socket arrives either as
fd 3 (systemd socket activation, LISTEN_FDS) or is bound at
SPACES_INTEGRATION_SOCKET (tests). Serves connections sequentially.
"""

import hashlib
import io
import json
import os
import re
import socket
import sys
import tarfile
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
    {
        "name": "clone_to_workspace",
        "description": (
            "Download a repository's tree into the shared workspace so the agent "
            "can edit it with its native file tools"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "repo": {"type": "string", "description": "owner/name"},
                "ref": {
                    "type": "string",
                    "description": "branch/tag/sha (default HEAD)",
                },
            },
            "required": ["repo"],
        },
    },
    {
        "name": "open_pull_request",
        "description": (
            "Push the edited workspace and open a pull request "
            "(the confirm-gated effect)"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "repo": {"type": "string", "description": "owner/name"},
                "title": {"type": "string"},
                "body": {"type": "string"},
                "head": {
                    "type": "string",
                    "description": "source branch (default agent-changes)",
                },
                "base": {
                    "type": "string",
                    "description": "target branch (default main)",
                },
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


def _shared_dir():
    return os.environ.get("SPACES_INTEGRATION_SHARED_DIR")


def _workspace_for(repo):
    """The clone destination for a repo under the shared dir, or None when no
    shared workspace is provisioned (the agent's session never granted one)."""
    shared = _shared_dir()
    if not shared:
        return None
    return os.path.join(shared, repo.split("/")[1])


def _http_bytes(req):
    """Run an urllib request, return (raw-bytes, None) or (None, error-text)."""
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.read(), None
    except urllib.error.HTTPError as e:
        return (
            None,
            f"GitHub API error: HTTP {e.code} for {req.get_method()} {req.full_url}",
        )
    except (urllib.error.URLError, OSError, ValueError) as e:
        return None, f"GitHub API request failed: {e.__class__.__name__}: {e}"


def _extract_tree(raw, dest):
    """Extract a GitHub tarball into dest, dropping the single "<owner>-<repo>-
    <sha>/" wrapper dir GitHub wraps the tree in and refusing path traversal.
    Returns the count of regular files written."""
    count = 0
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as tar:
        for member in tar.getmembers():
            rel = "/".join(member.name.split("/")[1:])  # drop the wrapper
            if not rel or os.path.isabs(rel) or ".." in rel.split("/"):
                continue  # never escape dest
            target = os.path.join(dest, rel)
            if member.isdir():
                os.makedirs(target, exist_ok=True)
            elif member.isfile():
                os.makedirs(os.path.dirname(target) or dest, exist_ok=True)
                src = tar.extractfile(member)
                if src is None:
                    continue
                with open(target, "wb") as f:
                    f.write(src.read())
                count += 1
    return count


def _workspace_files(root):
    """Relative paths of every regular file under root (sorted, '/'-joined)."""
    out = []
    for dirpath, _dirs, names in os.walk(root):
        for nm in names:
            out.append(
                os.path.relpath(os.path.join(dirpath, nm), root).replace(os.sep, "/")
            )
    return sorted(out)


def _tool_clone_to_workspace(args, token):
    repo = args.get("repo", "")
    if not REPO_RE.fullmatch(repo):
        return f"invalid repo name: {repo!r}", True
    dest = _workspace_for(repo)
    if dest is None:
        return "file exchange unavailable: no shared workspace", True
    ref = args.get("ref") or "HEAD"
    req = urllib.request.Request(
        f"{_api_base()}/repos/{repo}/tarball/{ref}",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
        },
    )
    raw, err = _http_bytes(req)
    if err:
        return err, True
    os.makedirs(dest, exist_ok=True)
    try:
        n = _extract_tree(raw, dest)
    except tarfile.TarError as e:
        return f"failed to extract tarball: {e}", True
    return f"cloned {repo} into {dest} ({n} file{'' if n == 1 else 's'})", False


def _tool_open_pull_request(args, token):
    repo = args.get("repo", "")
    if not REPO_RE.fullmatch(repo):
        return f"invalid repo name: {repo!r}", True
    title = args.get("title")
    if not isinstance(title, str) or not title:
        return "missing required argument: title", True
    dest = _workspace_for(repo)
    if dest is None or not os.path.isdir(dest):
        return f"no workspace for {repo}; clone_to_workspace first", True
    # The "push": reflect the agent's edited tree into the PR so the effect
    # observably carries its work — the shared dir round-trips end to end.
    files = _workspace_files(dest)
    manifest = "\n".join(f"- {p}" for p in files) or "- (empty)"
    payload = {
        "title": title,
        "head": args.get("head") or "agent-changes",
        "base": args.get("base") or "main",
        "body": (args.get("body", "") + f"\n\nWorkspace files:\n{manifest}").strip(),
    }
    req = urllib.request.Request(
        f"{_api_base()}/repos/{repo}/pulls",
        data=json.dumps(payload).encode("utf-8"),
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
    return (
        f"opened PR #{data.get('number')} from {len(files)} file(s): "
        f"{data.get('html_url')}",
        False,
    )


_TOOL_IMPLS = {
    "get_repo": _tool_get_repo,
    "create_issue": _tool_create_issue,
    "secret_fingerprint": _tool_secret_fingerprint,
    "clone_to_workspace": _tool_clone_to_workspace,
    "open_pull_request": _tool_open_pull_request,
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

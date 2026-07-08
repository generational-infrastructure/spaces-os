"""GitHub MCP integration server (spaces integration POC).

Speaks NDJSON JSON-RPC 2.0 over a unix socket via the shared
spaces_integration_mcp scaffold, which owns dispatch, profile resolution,
field gating, and the hidden secret_fingerprint tool. GitHub is single-account
(multiProfile off), so every call targets the store's sole profile and its
`token` secret (the PAT). File exchange uses the per-pair shared workspace
($SPACES_INTEGRATION_SHARED_DIR).
"""

from __future__ import annotations

import io
import json
import os
import re
import sys
import tarfile
import urllib.error
import urllib.request
from pathlib import Path
from typing import TYPE_CHECKING, Any

from spaces_integration_mcp import make_server, shared_dir

if TYPE_CHECKING:
    from collections.abc import Callable

SERVER_NAME = "integration-github"
SERVER_VERSION = "0.1.0"

REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


def _api_base() -> str:
    return os.environ.get("SPACES_GITHUB_API_URL", "https://api.github.com").rstrip("/")


def _http(req: urllib.request.Request) -> tuple[Any, None] | tuple[None, str]:
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


def _tool_get_repo(args: dict[str, Any], _token: str) -> tuple[str, bool]:
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


def _tool_create_issue(args: dict[str, Any], token: str) -> tuple[str, bool]:
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


def _workspace_for(repo: str) -> Path | None:
    """The clone destination for a repo under the shared dir, or None when no
    shared workspace is provisioned (the agent's session never granted one).
    """
    shared = shared_dir()
    if not shared:
        return None
    return Path(shared) / repo.split("/")[1]


def _http_bytes(req: urllib.request.Request) -> tuple[bytes, None] | tuple[None, str]:
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


def _extract_tree(raw: bytes, dest: Path) -> int:
    """Extract a GitHub tarball into dest, dropping the single "<owner>-<repo>-
    <sha>/" wrapper dir GitHub wraps the tree in and refusing path traversal.
    Returns the count of regular files written.
    """
    count = 0
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as tar:
        for member in tar.getmembers():
            rel = "/".join(member.name.split("/")[1:])  # drop the wrapper
            if not rel or Path(rel).is_absolute() or ".." in rel.split("/"):
                continue  # never escape dest
            target = dest / rel
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                src = tar.extractfile(member)
                if src is None:
                    continue
                target.write_bytes(src.read())
                count += 1
    return count


def _workspace_files(root: Path) -> list[str]:
    """Relative paths of every regular file under root (sorted, '/'-joined)."""
    return sorted(
        os.path.relpath(Path(dirpath) / name, root).replace(os.sep, "/")
        for dirpath, _dirs, names in os.walk(root)
        for name in names
    )


def _tool_clone_to_workspace(args: dict[str, Any], token: str) -> tuple[str, bool]:
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
    dest.mkdir(parents=True, exist_ok=True)
    try:
        n = _extract_tree(raw, dest)
    except tarfile.TarError as e:
        return f"failed to extract tarball: {e}", True
    return f"cloned {repo} into {dest} ({n} file{'' if n == 1 else 's'})", False


def _tool_open_pull_request(args: dict[str, Any], token: str) -> tuple[str, bool]:
    repo = args.get("repo", "")
    if not REPO_RE.fullmatch(repo):
        return f"invalid repo name: {repo!r}", True
    title = args.get("title")
    if not isinstance(title, str) or not title:
        return "missing required argument: title", True
    dest = _workspace_for(repo)
    if dest is None or not dest.is_dir():
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


def _tok(
    impl: Callable[[dict[str, Any], str], tuple[str, bool]],
) -> Callable[[dict[str, Any], str, dict[str, str]], tuple[str, bool]]:
    """Adapt an (args, token)-style impl to the scaffold's record signature."""
    return lambda args, _profile, vals: impl(args, vals["token"])


_NEEDS = ("token",)

TOOLS, call_tool, main = make_server(
    SERVER_NAME,
    SERVER_VERSION,
    [
        {
            "name": "get_repo",
            "description": "Fetch repository metadata (stars, description, default branch)",
            "schema": {
                "properties": {
                    "repo": {"type": "string", "description": "owner/name"},
                },
                "required": ["repo"],
            },
            "needs_fields": _NEEDS,
            "impl": _tok(_tool_get_repo),
        },
        {
            "name": "create_issue",
            "description": "Create an issue in a repository",
            "schema": {
                "properties": {
                    "repo": {"type": "string", "description": "owner/name"},
                    "title": {"type": "string"},
                    "body": {"type": "string"},
                },
                "required": ["repo", "title"],
            },
            "needs_fields": _NEEDS,
            "impl": _tok(_tool_create_issue),
        },
        {
            "name": "clone_to_workspace",
            "description": (
                "Download a repository's tree into the shared workspace so the agent "
                "can edit it with its native file tools"
            ),
            "schema": {
                "properties": {
                    "repo": {"type": "string", "description": "owner/name"},
                    "ref": {
                        "type": "string",
                        "description": "branch/tag/sha (default HEAD)",
                    },
                },
                "required": ["repo"],
            },
            "needs_fields": _NEEDS,
            "impl": _tok(_tool_clone_to_workspace),
        },
        {
            "name": "open_pull_request",
            "description": (
                "Push the edited workspace and open a pull request "
                "(the confirm-gated effect)"
            ),
            "schema": {
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
            "needs_fields": _NEEDS,
            "impl": _tok(_tool_open_pull_request),
        },
    ],
    secret_field="token",  # noqa: S106 (names the store field, not a credential)
    multi_profile=False,
)


if __name__ == "__main__":
    sys.exit(main())

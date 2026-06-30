#!/usr/bin/env python3
"""Mock GitHub REST API for the integration-poc VM check (design §9.5).

Stands in for api.github.com so the test runs offline. The github integration
(packages/integration-github) is pointed here with SPACES_GITHUB_API_URL. Every
request — method, path, Authorization header, JSON body — is appended as one
JSON line to the record file, so the test can assert the integration delivered
its decrypted token (Authorization observed server-side) and that
open_pull_request carried the agent's edited workspace into the PR body.

Endpoints (only what the integration calls):
  GET  /repos/<owner>/<repo>            -> repo metadata
  GET  /repos/<owner>/<repo>/tarball/*  -> gzip tarball (one wrapper dir + files)
  POST /repos/<owner>/<repo>/issues     -> { number, html_url }
  POST /repos/<owner>/<repo>/pulls      -> { number, html_url }

usage: mock-github.py <port> <record-file>
"""

import io
import json
import sys
import tarfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# The seed tree the tarball endpoint serves, under GitHub's single
# "<owner>-<repo>-<sha>/" wrapper dir (which the integration strips).
REPO_FILES = {
    "README.md": b"# hello\n\nseed repo for the integration POC.\n",
    "src/app.py": b"print('hello from octocat/hello')\n",
}


def _tarball():
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for rel, data in REPO_FILES.items():
            info = tarfile.TarInfo(f"octocat-hello-deadbee/{rel}")
            info.size = len(data)
            info.mtime = 0
            tar.addfile(info, io.BytesIO(data))
    return buf.getvalue()


class Handler(BaseHTTPRequestHandler):
    record_path = None

    def log_message(self, *_a, **_k):
        pass

    def _record(self, body):
        rec = {
            "method": self.command,
            "path": self.path,
            "authorization": self.headers.get("Authorization"),
            "body": body,
        }
        with open(self.record_path, "a") as fh:
            fh.write(json.dumps(rec) + "\n")

    def _json(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._record(None)
        parts = self.path.strip("/").split("/")
        if len(parts) >= 4 and parts[0] == "repos" and parts[3] == "tarball":
            raw = _tarball()
            self.send_response(200)
            self.send_header("Content-Type", "application/gzip")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return
        if len(parts) == 3 and parts[0] == "repos":
            owner, repo = parts[1], parts[2]
            self._json(
                200,
                {
                    "full_name": f"{owner}/{repo}",
                    "description": "seed repo for the integration POC",
                    "stargazers_count": 7,
                    "default_branch": "main",
                },
            )
            return
        self._json(404, {"message": "Not Found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length).decode() if length else ""
        try:
            body = json.loads(raw) if raw else None
        except ValueError:
            body = raw
        self._record(body)
        parts = self.path.strip("/").split("/")
        if len(parts) == 4 and parts[0] == "repos" and parts[3] == "issues":
            self._json(201, {"number": 1, "html_url": "http://github.invalid/issues/1"})
            return
        if len(parts) == 4 and parts[0] == "repos" and parts[3] == "pulls":
            self._json(201, {"number": 42, "html_url": "http://github.invalid/pull/42"})
            return
        self._json(404, {"message": "Not Found"})


def main():
    port = int(sys.argv[1])
    Handler.record_path = sys.argv[2]
    open(Handler.record_path, "w").close()  # truncate at startup
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()

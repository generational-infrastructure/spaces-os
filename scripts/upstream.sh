#!/usr/bin/env bash
# Sync local work onto the latest trunk and publish.
#
# Fetches new revisions from the git remote, rebases everything off the
# current working copy onto trunk(), formats, runs the flake checks,
# moves `main` to the resulting tip, and pushes.
set -euo pipefail

# Refuse to publish if any flake input resolves to a local path — those
# only work on the author's machine and would break the lock for others.
local_inputs=$(jq -r '
  .nodes
  | to_entries[]
  | select(
      .value.locked.type == "path"
      or (.value.original.url // "" | startswith("file:"))
      or (.value.locked.url // "" | startswith("file:"))
    )
  | .key
' flake.lock)
if [ -n "$local_inputs" ]; then
  echo "error: flake inputs point to local paths:" >&2
  echo "$local_inputs" >&2
  exit 1
fi

jj git fetch
jj rebase -o "trunk()"
nix fmt
nix flake check
jj bookmark set main
jj git push

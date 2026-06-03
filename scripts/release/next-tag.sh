#!/usr/bin/env bash
# Compute a date-based `spaces-YYYY.MM.DD` release tag and emit it on
# stdout. When more than one release is cut on the same day, a numeric
# suffix is appended (`spaces-YYYY.MM.DD.2`, `.3`, ...) so each tag is
# unique.
#
# When run inside GitHub Actions (i.e. $GITHUB_OUTPUT is set), also
# writes `tag=<value>` to the step output file so downstream steps can
# consume it.
set -euo pipefail

git fetch --tags --force >/dev/null

base="spaces-$(date -u +%Y.%m.%d)"

if ! git rev-parse -q --verify "refs/tags/${base}" >/dev/null; then
  tag="$base"
else
  n=2
  while git rev-parse -q --verify "refs/tags/${base}.${n}" >/dev/null; do
    n=$((n + 1))
  done
  tag="${base}.${n}"
fi

echo "$tag"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "tag=$tag" >>"$GITHUB_OUTPUT"
fi

#!/usr/bin/env bash
# Upload the just-built ISO and a sha256 sidecar to the
# geninf bucket on Hetzner Object Storage and emit the
# public download URLs.
#
# Usage: upload-artifacts.sh <tag>
#
# Reads the ISO from ./result/iso/*.iso (the symlink left by
# `nix build .#iso.<arch>.installer`). Uploaded keys are
# `<tag>-<arch>.iso` and `<tag>-<arch>.iso.sha256`.
#
# Architecture defaults to x86_64-linux; override with $ARCH to
# upload an aarch64 build (paired with build-iso.sh ARCH=…).
#
# Requires: AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY in env.
# `aws` is provided via `nix shell nixpkgs#awscli2`, so the only host
# dependency is a working nix.
#
# When run inside GitHub Actions, writes `iso_url=<url>` and
# `sha256_url=<url>` to $GITHUB_OUTPUT.
set -euo pipefail

tag=${1:?release tag required}

: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID required}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY required}"

endpoint=https://hel1.your-objectstorage.com
bucket=geninf
region=hel1

iso=$(find -L result/iso -maxdepth 1 -type f -name '*.iso' | head -n1)
if [ -z "$iso" ]; then
  echo "No ISO found under result/iso" >&2
  exit 1
fi

arch=${ARCH:-x86_64-linux}
iso_key="${tag}-${arch}.iso"
sha_key="${iso_key}.sha256"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
sha_file="${tmp}/${sha_key}"
(cd "$(dirname "$iso")" && sha256sum "$(basename "$iso")") |
  awk -v name="$iso_key" '{print $1 "  " name}' \
    >"$sha_file"

# shellcheck disable=SC2016 # $1..$7 are positional params for the inner sh -c
nix shell nixpkgs#awscli2 --command sh -euc '
  aws --endpoint-url "$1" --region "$2" s3 cp "$3" "s3://$4/$5" --no-progress
  aws --endpoint-url "$1" --region "$2" s3 cp "$6" "s3://$4/$7" --no-progress
' _ "$endpoint" "$region" "$iso" "$bucket" "$iso_key" "$sha_file" "$sha_key"

iso_url="${endpoint}/${bucket}/${iso_key}"
sha_url="${endpoint}/${bucket}/${sha_key}"

echo "$iso_url"
echo "$sha_url"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "iso_url=${iso_url}"
    echo "sha256_url=${sha_url}"
  } >>"$GITHUB_OUTPUT"
fi

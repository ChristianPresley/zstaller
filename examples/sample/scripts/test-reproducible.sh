#!/usr/bin/env bash
# Copyright 2026 The zstaller Authors
# SPDX-License-Identifier: Apache-2.0
#
# Reproducibility test: builds the sample's installers from two copies of
# the repository at different paths, each with its own local and global Zig
# cache, and checks that every installer is byte-identical. Then changes
# SOURCE_DATE_EPOCH and checks that the cached installers are rebuilt with
# the new timestamp rather than reused.
#
# Pass a file name to also write the installers' SHA256SUMS there, so builds
# on different hosts can be compared. Runs on Linux and in Git Bash on
# Windows.
set -euo pipefail

sums_out="${1:-}"
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export SOURCE_DATE_EPOCH=1700000000

build() { # <copy dir>
  mkdir -p "$1"
  (cd "$repo" && git ls-files -z --cached --others --exclude-standard | tar --null -cf - -T -) | tar -xf - -C "$1"
  (cd "$1/examples/sample" &&
    zig build installer --cache-dir "$1-cache" --global-cache-dir "$1-global-cache")
  # --binary: the same "<sum> *<name>" lines on Linux and Windows.
  (cd "$1/examples/sample/zig-out/installers" && sha256sum --binary -- *.msi *.exe *.deb) >"$1.sums"
}

echo "== build in two directories"
build "$work/a"
build "$work/a-second-copy-at-a-longer-path"
cat "$work/a.sums"
if ! diff "$work/a.sums" "$work/a-second-copy-at-a-longer-path.sums"; then
  echo "installers differ between build directories"
  exit 1
fi
if [ -n "$sums_out" ]; then cp "$work/a.sums" "$sums_out"; fi

echo "== rebuild with a different SOURCE_DATE_EPOCH"
export SOURCE_DATE_EPOCH=1700000100
build "$work/a"
# The EXE payload stores no timestamps, so only the MSI and .deb change.
while read -r sum name; do
  new="$(grep -F " $name" "$work/a.sums" | cut -d' ' -f1)"
  case "$name" in
    *.exe) [ "$new" = "$sum" ] || { echo "$name changed with SOURCE_DATE_EPOCH"; exit 1; } ;;
    *) [ "$new" != "$sum" ] || { echo "$name was not rebuilt for the new SOURCE_DATE_EPOCH"; exit 1; } ;;
  esac
done <"$work/a-second-copy-at-a-longer-path.sums"
echo "Reproducibility test passed"

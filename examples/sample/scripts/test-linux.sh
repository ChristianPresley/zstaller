#!/usr/bin/env bash
# Copyright 2026 The zstaller Authors
# SPDX-License-Identifier: Apache-2.0
#
# End-to-end test on Ubuntu: build every installer, verify checksums,
# inspect the .deb packages with dpkg-deb, then install, run and remove the
# package for the host architecture. Needs sudo for dpkg -i / -r.
#
# Pass a directory to test already-built installers (for example the ones a
# release is about to publish) instead of building them first.
set -euo pipefail

if [ $# -ge 1 ]; then
  cd "$1"
else
  cd "$(dirname "$0")/.."
  zig build installer --summary all
  cd zig-out/installers
fi
echo "== checksums"
sha256sum -c ./*.sha256

expected=(
  sample-1.0.0-windows-x86_64.msi
  sample-1.0.0-windows-x86_64-setup.exe
  sample-1.0.0-windows-aarch64.msi
  sample-1.0.0-windows-aarch64-setup.exe
  sample_1.0.0_amd64.deb
  sample_1.0.0_arm64.deb
)
for f in "${expected[@]}"; do
  test -s "$f" || { echo "missing $f"; exit 1; }
  test -s "$f.sha256" || { echo "missing $f.sha256"; exit 1; }
done

for deb in sample_1.0.0_*.deb; do
  echo "== dpkg-deb --info $deb"
  dpkg-deb --info "$deb"
  contents="$(dpkg-deb --contents "$deb")"
  grep -q './usr/bin/sample' <<<"$contents"
done
test "$(dpkg-deb --field sample_1.0.0_arm64.deb Architecture)" = arm64

arch="$(dpkg --print-architecture)"
deb="sample_1.0.0_${arch}.deb"
echo "== install $deb"
sudo dpkg -i "$deb"
out="$(sample)"
echo "$out"
grep -q "Hello from the zstaller sample on linux-$(uname -m)" <<<"$out"
grep -q "Installed at: /usr/bin/sample" <<<"$out"
test -f /usr/share/sample/README.md
test -f /usr/share/doc/sample/copyright
dpkg -s sample | grep -q '^Version: 1.0.0$'

echo "== remove"
sudo dpkg -r sample
if command -v sample >/dev/null; then echo "sample still installed"; exit 1; fi
echo "Linux end-to-end test passed"

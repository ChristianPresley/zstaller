#!/usr/bin/env bash
# Copyright 2026 The zstaller Authors
# SPDX-License-Identifier: Apache-2.0
#
# End-to-end test on Ubuntu: build every installer, verify checksums,
# inspect the .deb packages with dpkg-deb, then install, run, upgrade and
# purge the package for the host architecture. Needs sudo for dpkg.
#
# Pass a directory to test already-built installers (for example the ones a
# release is about to publish) instead of building them first.
set -euo pipefail

if [ $# -ge 1 ]; then
  cd "$1"
else
  cd "$(dirname "$0")/.."
  zig build installer --summary all
  # Another version, for the upgrade test.
  zig build installer -Dversion=1.0.1 -p zig-out/v1.0.1
  upgrade_dir="$PWD/zig-out/v1.0.1/installers"
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
  sample-1.0.0-windows-x86_64.mcpb
  sample-1.0.0-windows-aarch64.mcpb
  sample-1.0.0-ubuntu-x86_64.mcpb
  sample-1.0.0-ubuntu-aarch64.mcpb
)
for f in "${expected[@]}"; do
  test -s "$f" || { echo "missing $f"; exit 1; }
  test -s "$f.sha256" || { echo "missing $f.sha256"; exit 1; }
done

for deb in sample_1.0.0_*.deb; do
  echo "== dpkg-deb --info $deb"
  dpkg-deb --info "$deb"
  contents="$(dpkg-deb --contents "$deb")"
  grep -q './usr/bin/sample$' <<<"$contents"
  grep -q -- '-rwxr-xr-x .* ./usr/bin/sample-tool$' <<<"$contents"
done
test "$(dpkg-deb --field sample_1.0.0_arm64.deb Architecture)" = arm64
if command -v lintian >/dev/null; then
  echo "== lintian"
  lintian --fail-on error,warning sample_1.0.0_*.deb
fi

arch="$(dpkg --print-architecture)"
deb="sample_1.0.0_${arch}.deb"
echo "== install $deb"
sudo dpkg -i "$deb"
out="$(sample)"
echo "$out"
grep -q "Hello from the zstaller sample on linux-$(uname -m)" <<<"$out"
grep -q "Installed at: /usr/bin/sample" <<<"$out"
test "$(sample-tool | sed -n 1p)" = "sample-tool 1.0.0"
test "$(sample-tool /usr/share/sample/README.md | cut -d' ' -f1)" = "$(sha256sum /usr/share/sample/README.md | cut -d' ' -f1)"
test -f /usr/share/sample/README.md
# Listed rather than tested on disk: minimized images skip man pages.
dpkg -L sample | grep -x /usr/share/man/man1/sample-tool.1.gz >/dev/null
test -f /usr/share/icons/hicolor/256x256/apps/sample.png
grep -q '^Exec=/usr/bin/sample$' /usr/share/applications/sample.desktop
if command -v desktop-file-validate >/dev/null; then desktop-file-validate /usr/share/applications/sample.desktop; fi
dpkg-query -W -f='${Conffiles}\n' sample | grep -q '/etc/sample/sample.conf'
test -d /var/lib/sample # made by postinst
test -f /usr/share/doc/sample/copyright
dpkg -s sample | grep -q '^Version: 1.0.0$'

if [ -n "${upgrade_dir:-}" ]; then
  echo "== upgrade to 1.0.1 keeps a changed configuration file"
  echo 'greeting = Hi' | sudo tee /etc/sample/sample.conf >/dev/null
  sudo dpkg -i --force-confold "$upgrade_dir/sample_1.0.1_${arch}.deb"
  dpkg -s sample | grep -q '^Version: 1.0.1$'
  grep -q '^greeting = Hi$' /etc/sample/sample.conf
fi

echo "== MCP bundle: manifest and a JSON-RPC handshake with the server inside"
bundle_dir=$(mktemp -d)
unzip -q "sample-1.0.0-ubuntu-$(uname -m | sed 's/arm64/aarch64/').mcpb" -d "$bundle_dir"
grep -q '"entry_point": "server/sample-tool"' "$bundle_dir/manifest.json"
test -x "$bundle_dir/server/sample-tool"
reply=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | "$bundle_dir/server/sample-tool" mcp)
echo "$reply"
echo "$reply" | grep -q '"serverInfo":{"name":"sample"'
echo "$reply" | grep -q '"name":"sha256"'
rm -rf "$bundle_dir"

echo "== MCP: a user registers the server; removing the package unregisters it"
# A throwaway user, so no real profile is touched.
mcp_user=zstaller-mcp-test
sudo useradd --create-home "$mcp_user"
mcp_home="$(getent passwd "$mcp_user" | cut -d: -f6)"
sudo -u "$mcp_user" mkdir "$mcp_home/.claude"
printf '{\n  "numStartups": 1\n}\n' | sudo -u "$mcp_user" tee "$mcp_home/.claude.json" >/dev/null
sudo -u "$mcp_user" chmod 600 "$mcp_home/.claude.json"
sudo -u "$mcp_user" env HOME="$mcp_home" /usr/lib/sample/zstaller-mcp register
sudo grep -q '"zstaller-sample": {"type":"stdio","command":"/usr/bin/sample-tool","args":\["mcp"\]}' "$mcp_home/.claude.json"
sudo -u "$mcp_user" env HOME="$mcp_home" /usr/lib/sample/zstaller-mcp status | grep -q 'Claude Code: registered'

echo "== purge"
sudo dpkg --purge sample
if command -v sample >/dev/null || command -v sample-tool >/dev/null; then echo "sample still installed"; exit 1; fi
if [ -e /etc/sample ] || [ -e /var/lib/sample ]; then echo "purge left /etc/sample or /var/lib/sample"; exit 1; fi
if sudo grep -q zstaller-sample "$mcp_home/.claude.json"; then echo "removing the package left the MCP registration"; exit 1; fi
sudo grep -q '"numStartups": 1' "$mcp_home/.claude.json"
test "$(sudo stat -c '%U %a' "$mcp_home/.claude.json")" = "$mcp_user 600"
sudo userdel --remove "$mcp_user" 2>/dev/null || true
echo "Linux end-to-end test passed"

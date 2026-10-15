# Copyright 2026 The zstaller Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# SPDX-License-Identifier: Apache-2.0
#
# Builds the release installers on this machine. GitHub never builds the
# executables a release ships: this script does, and the release workflow
# only installs, runs and uninstalls the uploaded files before publishing.
#
#   pwsh scripts/release.ps1 [-OutputDir <dir>] [-Tag <tag>]
#
# The sample's installers are built from scratch for every target with
# SOURCE_DATE_EPOCH set to the commit time, so anyone can rebuild the same
# bytes (see "Reproducible builds" in README.md). Every .sha256 file is
# checked, then the installers and checksums are copied to -OutputDir
# (default zig-out/release/installers). Other files there are left alone.
#
# -Tag uploads the files to a new draft GitHub release for HEAD, which must
# be committed and pushed, and starts the release workflow to verify and
# publish it. Requires the GitHub CLI (gh), signed in.

param(
    [string]$OutputDir,
    [string]$Tag
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $repo

function Invoke-Native {
    & $args[0] @($args | Select-Object -Skip 1)
    if ($LASTEXITCODE -ne 0) { throw "$($args -join ' ') failed with exit code $LASTEXITCODE" }
}

function Test-Checksums([string]$dir) {
    $sums = @(Get-ChildItem -LiteralPath $dir -Filter *.sha256)
    if ($sums.Count -eq 0) { throw "no .sha256 files in $dir" }
    foreach ($sum in $sums) {
        $hash, $name = (Get-Content -LiteralPath $sum.FullName -Raw).Trim() -split '\s+', 2
        $name = $name.TrimStart('*')
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $dir $name)).Hash.ToLower()
        if ($actual -ne $hash) { throw "checksum mismatch for $name in $dir" }
        Write-Host "  $name OK"
    }
}

$commit = (git rev-parse HEAD).Trim()
$dirty = git status --porcelain
if ($Tag) {
    # A published release must match a commit anyone can check out.
    if ($dirty) { throw "-Tag needs a clean working tree; commit or stash your changes first" }
    Invoke-Native git fetch --quiet origin
    if (-not (git branch -r --contains $commit)) { throw "push $commit to GitHub before releasing it" }
} elseif ($dirty) {
    Write-Warning "the working tree has uncommitted changes, so these files may not match $commit"
}

$env:SOURCE_DATE_EPOCH = (git log -1 --format=%ct).Trim()
$zigVersion = (zig version).Trim()
Write-Host "== building $commit with Zig $zigVersion, SOURCE_DATE_EPOCH=$env:SOURCE_DATE_EPOCH"

# A fresh prefix, so no installer from an earlier version is picked up.
$prefix = Join-Path $repo 'zig-out/release'
if (Test-Path $prefix) { Remove-Item -Recurse -Force $prefix }
Push-Location examples/sample
try {
    Invoke-Native zig build installer --prefix $prefix --summary all
} finally {
    Pop-Location
}
$built = Join-Path $prefix 'installers'
$files = @(Get-ChildItem -LiteralPath $built -File |
        Where-Object { $_.Extension -in '.msi', '.exe', '.deb', '.sha256' })
Write-Host '== checksums'
Test-Checksums $built

if (-not $OutputDir) { $OutputDir = $built }
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }
$OutputDir = (Resolve-Path $OutputDir).Path
if ($OutputDir -ne (Resolve-Path $built).Path) {
    Write-Host "== copying to $OutputDir"
    foreach ($file in $files) { Copy-Item -LiteralPath $file.FullName -Destination $OutputDir -Force }
    Test-Checksums $OutputDir
}

Write-Host "== installers in $OutputDir"
$files | ForEach-Object { Get-Item -LiteralPath (Join-Path $OutputDir $_.Name) } |
    Format-Table Name, @{ Label = 'Size'; Expression = { $_.Length }; Align = 'Right' } -AutoSize |
    Out-Host

if ($Tag) {
    $slug = (gh repo view --json nameWithOwner --jq .nameWithOwner).Trim()
    $notes = Join-Path $prefix 'notes.md'
    $epoch = $env:SOURCE_DATE_EPOCH
    @(
        Get-Content -Raw .github/release-notes.md
        ''
        '## Reproducing these files'
        ''
        "They were built from commit $commit with Zig $zigVersion and"
        "``SOURCE_DATE_EPOCH=$epoch``. To rebuild them byte for byte:"
        ''
        '```'
        "git clone https://github.com/$slug && cd $($slug.Split('/')[1])"
        "git checkout $commit"
        'cd examples/sample'
        "SOURCE_DATE_EPOCH=$epoch zig build installer"
        'sha256sum zig-out/installers/*.msi zig-out/installers/*.exe zig-out/installers/*.deb'
        '```'
    ) | Set-Content -LiteralPath $notes -Encoding utf8NoBOM

    Write-Host "== uploading to draft release $Tag"
    Invoke-Native gh release create $Tag @($files | ForEach-Object { Join-Path $OutputDir $_.Name }) `
        --draft --target $commit --title "zstaller $($Tag.TrimStart('v'))" --notes-file $notes
    Invoke-Native gh workflow run release.yml -f "tag=$Tag"
    Write-Host "The release workflow now installs, runs and uninstalls these files on every"
    Write-Host "platform and publishes $Tag if they pass: gh run watch"
}

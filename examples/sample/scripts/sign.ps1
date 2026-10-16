# Copyright 2026 The zstaller Authors
# SPDX-License-Identifier: Apache-2.0
#
# Signs a copy of a file with signtool: sign.ps1 <thumbprint> <in> <out>.
# The certificate is looked up by its SHA-1 thumbprint in the current
# user's or the machine's "My" store. zstaller runs this through the
# sample's `sign` hook (build.zig) with `zig build installer -Dsign=...`.
#
# Add `/tr <timestamp URL> /td SHA256` for releases, so the signature
# stays valid after the certificate expires.

param(
    [Parameter(Mandatory)][string]$Thumbprint,
    [Parameter(Mandatory)][string]$In,
    [Parameter(Mandatory)][string]$Out
)

$ErrorActionPreference = 'Stop'
$signtool = (Get-Command signtool.exe -ErrorAction SilentlyContinue).Source
if (-not $signtool) {
    # The Windows SDK does not put signtool on PATH.
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    $signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\$arch\signtool.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName | Select-Object -Last 1 -ExpandProperty FullName
}
if (-not $signtool) { throw 'signtool.exe not found; install the Windows SDK' }

Copy-Item -LiteralPath $In -Destination $Out -Force
& $signtool sign /q /fd SHA256 /sha1 $Thumbprint $Out
if ($LASTEXITCODE -ne 0) { throw "signtool failed on $In" }

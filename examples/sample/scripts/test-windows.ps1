# Copyright 2026 The zstaller Authors
# SPDX-License-Identifier: Apache-2.0
#
# End-to-end test on Windows: build every installer, verify checksums, then
# exercise the MSI (silent install/uninstall with msiexec, with and without
# ADDTOPATH) and the EXE installer (silent install, then silent uninstall by
# running uninstall.exe directly, through the registered uninstall command
# and through the setup program).
# Must run elevated, as GitHub-hosted Windows runners do.
#
# -InstallerDir tests already-built installers (for example the ones a
# release is about to publish) instead of building them first.

param([string]$InstallerDir)

$ErrorActionPreference = 'Stop'
if ($InstallerDir) {
    Set-Location $InstallerDir
} else {
    Set-Location (Join-Path $PSScriptRoot '..')
    zig build installer --summary all
    if ($LASTEXITCODE -ne 0) { throw "zig build installer failed" }
    Set-Location zig-out/installers
}

Write-Host '== checksums'
foreach ($sum in Get-ChildItem *.sha256) {
    $hash, $name = (Get-Content $sum.FullName -Raw).Trim() -split '\s+', 2
    $actual = (Get-FileHash -Algorithm SHA256 $name).Hash.ToLower()
    if ($actual -ne $hash) { throw "checksum mismatch for $name" }
    Write-Host "$name OK"
}

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'aarch64' } else { 'x86_64' }
$msi = (Resolve-Path "sample-1.0.0-windows-$arch.msi").Path
$exe = (Resolve-Path "sample-1.0.0-windows-$arch-setup.exe").Path
$dir = Join-Path $env:ProgramFiles 'Zstaller Sample'
$app = Join-Path $dir 'sample.exe'
$shortcut = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Zstaller Sample.lnk'
$desktop = Join-Path $env:PUBLIC 'Desktop\Zstaller Sample.lnk'

function Invoke-Checked($file, $arguments) {
    $p = Start-Process -FilePath $file -ArgumentList $arguments -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "$file $arguments exited with $($p.ExitCode)" }
}

function Test-OnPath {
    $path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    return ($path -split ';' | ForEach-Object { $_.TrimEnd('\') }) -contains $dir
}

function Assert-Desktop($expected) {
    if ((Test-Path $desktop) -ne $expected) { throw "desktop shortcut present: $(Test-Path $desktop), expected $expected" }
    if ($expected) {
        $link = (New-Object -ComObject WScript.Shell).CreateShortcut($desktop)
        if ($link.TargetPath -ne $app) { throw "desktop shortcut points at '$($link.TargetPath)', expected '$app'" }
        Write-Host "Desktop shortcut OK: $desktop"
    }
}

function Assert-Installed($expectOnPath) {
    if (-not (Test-Path $app)) { throw "$app was not installed" }
    if (-not (Test-Path (Join-Path $dir 'README.md'))) { throw 'README.md was not installed' }
    $out = (& $app) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw ('{0} exited with 0x{1:X8}' -f $app, $LASTEXITCODE) }
    Write-Host $out
    if ($out -notmatch 'Hello from the zstaller sample on windows') { throw 'unexpected output' }
    if ((Test-OnPath) -ne $expectOnPath) { throw "PATH entry present: $(Test-OnPath), expected $expectOnPath" }
    Assert-Shortcut
}

function Assert-Shortcut {
    if (-not (Test-Path $shortcut)) { throw "Start Menu shortcut $shortcut was not created" }
    $link = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut)
    if ($link.TargetPath -ne $app) { throw "shortcut points at '$($link.TargetPath)', expected '$app'" }
    Write-Host "Start Menu shortcut OK: $shortcut -> $($link.TargetPath)"
}

function Assert-Removed {
    for ($i = 0; $i -lt 20 -and (Test-Path $dir); $i++) { Start-Sleep -Milliseconds 500 }
    if (Test-Path $dir) { throw "$dir still exists: $(Get-ChildItem $dir -Force | Out-String)" }
    if (Test-OnPath) { throw 'PATH entry was not removed' }
    if (Test-Path $shortcut) { throw 'Start Menu shortcut was not removed' }
    if (Test-Path $desktop) { throw 'desktop shortcut was not removed' }
}

Write-Host '== MSI: silent install with PATH and a desktop shortcut'
Invoke-Checked msiexec.exe "/i `"$msi`" /qn DESKTOPSHORTCUT=1 /l*v `"$PWD\msi-install.log`""
Assert-Installed $true
Assert-Desktop $true
$product = Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' |
    Where-Object { $_.DisplayName -eq 'Zstaller Sample' }
if (-not $product) { throw 'MSI product is not registered in Apps & Features' }
Write-Host '== MSI: silent uninstall'
Invoke-Checked msiexec.exe "/x `"$msi`" /qn /l*v `"$PWD\msi-uninstall.log`""
Assert-Removed

Write-Host '== MSI: silent install with ADDTOPATH=0, uninstall by product code'
Invoke-Checked msiexec.exe "/i `"$msi`" /qn ADDTOPATH=0"
Assert-Installed $false
Assert-Desktop $false
# Only the MSI registers under its {ProductCode}; an EXE install uses a
# named key, and passing that to msiexec opens its usage dialog.
$code = (Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' |
    Where-Object { $_.DisplayName -eq 'Zstaller Sample' -and $_.PSChildName -like '{*}' }).PSChildName
if (@($code).Count -ne 1) { throw "expected one MSI product code, found: $code" }
Invoke-Checked msiexec.exe "/x $code /qn"
Assert-Removed

$key = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\zstaller.sample'
$uninstaller = Join-Path $dir 'uninstall.exe'

function Assert-ExeRemoved {
    Assert-Removed
    if (Test-Path $key) { throw 'EXE uninstall entry was not removed' }
}

Write-Host '== EXE: silent install with /PATH and /DESKTOP'
Invoke-Checked $exe '/S /PATH /DESKTOP'
Assert-Installed $true
Assert-Desktop $true
$entry = Get-ItemProperty $key
if ($entry.DisplayVersion -ne '1.0.0') { throw 'EXE uninstall entry missing' }
if (-not (Test-Path $uninstaller)) { throw "$uninstaller was not installed" }
# Run the uninstaller directly with no action, as a double-click does: it
# must uninstall, not reinstall, and remove itself and the directory.
Write-Host '== EXE: uninstall.exe /S (no /uninstall)'
Invoke-Checked $uninstaller '/S'
Assert-ExeRemoved

Write-Host '== EXE: uninstall with the registered QuietUninstallString'
Invoke-Checked $exe '/S'
Assert-Installed $false
Assert-Desktop $false
$quiet = (Get-ItemProperty $key).QuietUninstallString
Invoke-Checked cmd.exe "/d /s /c `"$quiet`""
Assert-ExeRemoved

Write-Host '== EXE: setup.exe /uninstall /S finds the installation in the registry'
Invoke-Checked $exe '/S'
Assert-Installed $false
Invoke-Checked $exe '/uninstall /S'
Assert-ExeRemoved
$p = Start-Process -FilePath $exe -ArgumentList '/uninstall /S' -Wait -PassThru
if ($p.ExitCode -ne 1) { throw "uninstalling when not installed exited with $($p.ExitCode), expected 1" }

Write-Host '== EXE: silent install to another folder with /D='
$custom = Join-Path $env:SystemDrive 'zstaller test\Sample App'
Invoke-Checked $exe "/S `"/D=$custom`""
if (-not (Test-Path (Join-Path $custom 'sample.exe'))) { throw "sample.exe was not installed in $custom" }
if ((Get-ItemProperty $key).InstallLocation -ne $custom) { throw 'InstallLocation does not name the chosen folder' }
Invoke-Checked $exe '/uninstall /S'
for ($i = 0; $i -lt 20 -and (Test-Path $custom); $i++) { Start-Sleep -Milliseconds 500 }
if (Test-Path $custom) { throw "$custom still exists" }
if (Test-Path $key) { throw 'EXE uninstall entry was not removed' }

Write-Host 'Windows end-to-end test passed'

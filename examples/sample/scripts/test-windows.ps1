# Copyright 2026 The zstaller Authors
# SPDX-License-Identifier: Apache-2.0
#
# End-to-end test on Windows: build every installer, verify checksums, then
# exercise the MSI (silent install/uninstall with msiexec, with and without
# ADDTOPATH) and the EXE installer (silent install, then silent uninstall by
# running uninstall.exe directly, through the registered uninstall command
# and through the setup program), that neither installs over the other,
# install folders other users can change,
# then upgrades and downgrades of both, and per-user installs.
# Must run elevated, as GitHub-hosted Windows runners do.
#
# -InstallerDir tests already-built installers (for example the ones a
# release is about to publish) instead of building them first.

# -SignThumbprint builds them signed with that certificate (see
# scripts/sign.ps1) and checks the signatures of the installers and of the
# installed files.

param([string]$InstallerDir, [string]$SignThumbprint)

$ErrorActionPreference = 'Stop'
if ($InstallerDir) {
    Set-Location $InstallerDir
} else {
    Set-Location (Join-Path $PSScriptRoot '..')
    # Assigned, not taken from an if expression: PowerShell would unroll a
    # one-item array into a string, and @signArg would splat its characters.
    $signArg = @()
    if ($SignThumbprint) { $signArg = @("-Dsign=$SignThumbprint") }
    zig build installer --summary all @signArg
    if ($LASTEXITCODE -ne 0) { throw "zig build installer failed" }
    # Other versions of the sample, for the upgrade tests.
    foreach ($v in '1.0.1', '1.0.1-rc.1') {
        zig build installer "-Dversion=$v" -p "zig-out/v$v" @signArg
        if ($LASTEXITCODE -ne 0) { throw "zig build installer -Dversion=$v failed" }
        Copy-Item "zig-out/v$v/installers/*-windows-*" zig-out/installers/
    }
    # The per-user variant (windows.scope = .user), in its own folder as
    # its files have the same names.
    zig build installer -Dper-user -p zig-out/per-user @signArg
    if ($LASTEXITCODE -ne 0) { throw "zig build installer -Dper-user failed" }
    New-Item -ItemType Directory -Force zig-out/installers/per-user | Out-Null
    Copy-Item "zig-out/per-user/installers/*-windows-*" zig-out/installers/per-user/
    Set-Location zig-out/installers
}

Write-Host '== checksums'
foreach ($sum in Get-ChildItem *.sha256) {
    $hash, $name = (Get-Content $sum.FullName -Raw).Trim() -split '\s+', 2
    $actual = (Get-FileHash -Algorithm SHA256 $name).Hash.ToLower()
    if ($actual -ne $hash) { throw "checksum mismatch for $name" }
    Write-Host "$name OK"
}

# Signed by the certificate given with -SignThumbprint, which the caller
# made trusted on this machine.
function Assert-Signed($file) {
    if (-not $SignThumbprint) { return }
    $sig = Get-AuthenticodeSignature $file
    if ($sig.Status -ne 'Valid') { throw "$file signature: $($sig.Status) $($sig.StatusMessage)" }
    if ($sig.SignerCertificate.Thumbprint -ne $SignThumbprint) { throw "$file is signed by $($sig.SignerCertificate.Subject)" }
    Write-Host "Signed: $file"
}

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'aarch64' } else { 'x86_64' }
$msi = (Resolve-Path "sample-1.0.0-windows-$arch.msi").Path
$exe = (Resolve-Path "sample-1.0.0-windows-$arch-setup.exe").Path
Assert-Signed $msi
Assert-Signed $exe
$dir = Join-Path $env:ProgramFiles 'Zstaller Sample'
$app = Join-Path $dir 'sample.exe'
$shortcut = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Zstaller Sample.lnk'
$registered = Join-Path $env:ProgramData 'Zstaller Sample\registered.txt'
$desktop = Join-Path $env:PUBLIC 'Desktop\Zstaller Sample.lnk'

function Invoke-Checked($file, $arguments) {
    $p = Start-Process -FilePath $file -ArgumentList $arguments -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        Show-MsiLog $arguments
        throw "$file $arguments exited with $($p.ExitCode)"
    }
}

# Prints what led up to the first failed action in an msiexec /l*v log,
# so a failure can be read from the job output.
function Show-MsiLog($arguments) {
    if ($arguments -notmatch '/l\*v "([^"]+)"') { return }
    $log = $Matches[1]
    if (-not (Test-Path $log)) { return }
    $lines = Get-Content $log
    $fail = ($lines | Select-String -SimpleMatch 'Return value 3.' | Select-Object -First 1).LineNumber
    $errors = $lines | Select-String -Pattern 'Error \d{4}|error code|Note: 1: ' | Select-Object -First 20
    Write-Host "== $log"
    $errors | ForEach-Object { Write-Host $_.Line }
    if ($fail) { $lines[[Math]::Max(0, $fail - 40)..($fail - 1)] | ForEach-Object { Write-Host $_ } }
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

# Only SYSTEM and administrators may change the install folder and what
# is in it, and it does not inherit permissions from the folder above.
function Assert-LockedDown($folder) {
    foreach ($item in @($folder, (Join-Path $folder 'sample.exe'))) {
        $acl = Get-Acl $item
        if ($acl.Owner -notin 'BUILTIN\Administrators', 'NT AUTHORITY\SYSTEM') { throw "$item is owned by $($acl.Owner)" }
        $writable = $acl.Access | Where-Object {
            $_.AccessControlType -eq 'Allow' -and
            $_.IdentityReference -notmatch 'SYSTEM|Administrators' -and
            $_.FileSystemRights.ToString() -match 'Modify|Write|FullControl|Delete|ChangePermissions|TakeOwnership|CreateFiles|AppendData'
        }
        if ($writable) { throw "others can still change ${item}: $($writable | Out-String)" }
    }
    if (-not (Get-Acl $folder).AreAccessRulesProtected) { throw "$folder inherits permissions from the folder above" }
    Write-Host "Locked down: $folder"
}

function Assert-Installed($expectOnPath) {
    if (-not (Test-Path $app)) { throw "$app was not installed" }
    if (-not (Test-Path (Join-Path $dir 'README.md'))) { throw 'README.md was not installed' }
    $out = (& $app) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw ('{0} exited with 0x{1:X8}' -f $app, $LASTEXITCODE) }
    Write-Host $out
    if ($out -notmatch 'Hello from the zstaller sample on windows') { throw 'unexpected output' }
    $tool = Join-Path $dir 'sample-tool.exe'
    $toolOut = (& $tool) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $toolOut -notmatch '^sample-tool \d') { throw "sample-tool printed: $toolOut" }
    Assert-Signed $tool
    # after_install ran sample-tool --register.
    if (-not (Test-Path $registered)) { throw "the after_install hook did not create $registered" }
    if ((Test-OnPath) -ne $expectOnPath) { throw "PATH entry present: $(Test-OnPath), expected $expectOnPath" }
    Assert-LockedDown $dir
    Assert-Signed $app
    Assert-Shortcut
}

function Assert-Shortcut {
    if (-not (Test-Path $shortcut)) { throw "Start Menu shortcut $shortcut was not created" }
    $link = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut)
    if ($link.TargetPath -ne $app) { throw "shortcut points at '$($link.TargetPath)', expected '$app'" }
    Write-Host "Start Menu shortcut OK: $shortcut -> $($link.TargetPath)"
}

# The sample is an MCP server (.mcp in build.zig): installing registers it
# with the user's AI tools, here Claude Code, which counts as installed when
# ~/.claude exists.
$claudeJson = Join-Path $HOME '.claude.json'
New-Item -ItemType Directory -Force (Join-Path $HOME '.claude') | Out-Null
$claudeJsonExisted = Test-Path $claudeJson
$claudeBakExisted = Test-Path "$claudeJson.zstaller.bak"

function Test-McpRegistered {
    if (-not (Test-Path $claudeJson)) { return $false }
    return (Get-Content $claudeJson -Raw) -match '"zstaller-sample": \{"type":"stdio","command":"[^"]*sample-tool\.exe","args":\["mcp"\]\}'
}

function Assert-McpRegistered($expected) {
    # Setup registers through the desktop's Explorer, which can finish
    # after Setup does.
    for ($i = 0; $i -lt 40 -and (Test-McpRegistered) -ne $expected; $i++) { Start-Sleep -Milliseconds 500 }
    if ((Test-McpRegistered) -ne $expected) {
        throw "MCP server registered in ${claudeJson}: $(Test-McpRegistered), expected ${expected}: $(Get-Content $claudeJson -Raw -ErrorAction SilentlyContinue)"
    }
    # Unregistering leaves no trace: no backup, and no file it created.
    if (-not $expected -and -not $claudeBakExisted -and (Test-Path "$claudeJson.zstaller.bak")) { throw "unregistering left $claudeJson.zstaller.bak" }
    if (-not $expected -and -not $claudeJsonExisted -and (Test-Path $claudeJson)) { throw "unregistering left the $claudeJson it created: $(Get-Content $claudeJson -Raw)" }
    Write-Host "MCP registration OK: $expected"
}

function Assert-Removed {
    for ($i = 0; $i -lt 20 -and (Test-Path $dir); $i++) { Start-Sleep -Milliseconds 500 }
    if (Test-Path $dir) { throw "$dir still exists: $(Get-ChildItem $dir -Force | Out-String)" }
    if (Test-OnPath) { throw 'PATH entry was not removed' }
    if (Test-Path $registered) { throw "the before_uninstall hook did not remove $registered" }
    if (Test-Path $shortcut) { throw 'Start Menu shortcut was not removed' }
    if (Test-Path $desktop) { throw 'desktop shortcut was not removed' }
    Assert-McpRegistered $false
}

Write-Host '== MSI: silent install with PATH and a desktop shortcut'
Invoke-Checked msiexec.exe "/i `"$msi`" /qn DESKTOPSHORTCUT=1 /l*v `"$PWD\msi-install.log`""
Assert-Installed $true
Assert-Desktop $true
Assert-McpRegistered $true
$product = Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' |
    Where-Object { $_.DisplayName -eq 'Zstaller Sample' }
if (-not $product) { throw 'MSI product is not registered in Apps & Features' }
Write-Host '== MSI: silent uninstall'
Invoke-Checked msiexec.exe "/x `"$msi`" /qn /l*v `"$PWD\msi-uninstall.log`""
Assert-Removed

Write-Host '== MSI: silent install with ADDTOPATH=0 REGISTERMCP=0, uninstall by product code'
Invoke-Checked msiexec.exe "/i `"$msi`" /qn ADDTOPATH=0 REGISTERMCP=0"
Assert-Installed $false
Assert-McpRegistered $false
Assert-Desktop $false
# Only the MSI registers under its {ProductCode}; an EXE install uses a
# named key, and passing that to msiexec opens its usage dialog.
$code = (Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' |
    Where-Object { $_.DisplayName -eq 'Zstaller Sample' -and $_.PSChildName -like '{*}' }).PSChildName
if (@($code).Count -ne 1) { throw "expected one MSI product code, found: $code" }
Write-Host '== EXE: refused while the MSI is installed'
$p = Start-Process -FilePath $exe -ArgumentList '/S' -Wait -PassThru
if ($p.ExitCode -ne 1) { throw "setup.exe over the MSI exited with $($p.ExitCode), expected 1" }
if (Test-Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\zstaller.sample') { throw 'setup.exe registered over the MSI' }
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
Assert-McpRegistered $true
$entry = Get-ItemProperty $key
if ($entry.DisplayVersion -ne '1.0.0') { throw 'EXE uninstall entry missing' }
if (-not (Test-Path $uninstaller)) { throw "$uninstaller was not installed" }
Assert-Signed $uninstaller
# Run the uninstaller directly with no action, as a double-click does: it
# must uninstall, not reinstall, and remove itself and the directory.
Write-Host '== MSI: refused while the EXE is installed'
$p = Start-Process -FilePath msiexec.exe -ArgumentList "/i `"$msi`" /qn /l*v `"$PWD\msi-over-exe.log`"" -Wait -PassThru
if ($p.ExitCode -ne 1603) { throw "the MSI over the EXE exited with $($p.ExitCode), expected 1603" }
if (-not (Select-String -Path msi-over-exe.log -Pattern 'already installed with its setup program' -Quiet)) { throw 'the MSI did not say the EXE installation is in the way' }
Write-Host '== EXE: uninstall.exe /S (no /uninstall)'
Invoke-Checked $uninstaller '/S'
Assert-ExeRemoved

Write-Host '== EXE: uninstall with the registered QuietUninstallString'
# A silent install adds the folder to PATH unless told /NOPATH.
Invoke-Checked $exe '/S'
Assert-Installed $true
Assert-Desktop $false
$quiet = (Get-ItemProperty $key).QuietUninstallString
Invoke-Checked cmd.exe "/d /s /c `"$quiet`""
Assert-ExeRemoved

Write-Host '== EXE: setup.exe /uninstall /S finds the installation in the registry'
Invoke-Checked $exe '/S /NOPATH /NOMCP'
Assert-Installed $false
Assert-McpRegistered $false
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

Write-Host '== EXE: folders other users can change are refused or locked down'
$open = Join-Path $env:SystemDrive 'zstaller open'
New-Item -ItemType Directory -Force $open | Out-Null
# Let Users modify it, as a folder in C:\ lets Authenticated Users.
icacls $open /grant '*S-1-5-32-545:(OI)(CI)M' | Out-Null
$p = Start-Process -FilePath $exe -ArgumentList "/S `"/D=$open\Sample App`"" -Wait -PassThru
if ($p.ExitCode -ne 1) { throw "installing inside a folder Users can rename exited with $($p.ExitCode), expected 1" }
if (Test-Path "$open\Sample App") { throw 'the refused install created its folder' }
Set-Content (Join-Path $open 'other.dll') 'not ours'
$p = Start-Process -FilePath $exe -ArgumentList "/S `"/D=$open`"" -Wait -PassThru
if ($p.ExitCode -ne 1) { throw "installing into a folder with other files Users can change exited with $($p.ExitCode), expected 1" }
Remove-Item (Join-Path $open 'other.dll')
Invoke-Checked $exe "/S /NOPATH `"/D=$open`""
Assert-LockedDown $open
Invoke-Checked $exe '/uninstall /S'
for ($i = 0; $i -lt 20 -and (Test-Path $open); $i++) { Start-Sleep -Milliseconds 500 }
if (Test-Path $open) { throw "$open still exists" }

Write-Host '== EXE: a folder the user put on PATH stays there after uninstall'
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
[Environment]::SetEnvironmentVariable('Path', "$machinePath;$dir", 'Machine')
Invoke-Checked $exe '/S'
Invoke-Checked $exe '/uninstall /S'
for ($i = 0; $i -lt 20 -and (Test-Path $dir); $i++) { Start-Sleep -Milliseconds 500 }
if (-not (Test-OnPath)) { throw 'uninstall removed a PATH entry it did not add' }
[Environment]::SetEnvironmentVariable('Path', $machinePath, 'Machine')
Assert-ExeRemoved

# Per user: no administrator paths, keys or PATH entries are touched.
if (Test-Path per-user) {
    $puExe = (Resolve-Path "per-user/sample-1.0.0-windows-$arch-setup.exe").Path
    $puMsi = (Resolve-Path "per-user/sample-1.0.0-windows-$arch.msi").Path
    $puDir = Join-Path $env:LOCALAPPDATA 'Programs\Zstaller Sample'
    $puKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\zstaller.sample'
    $puShortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'Zstaller Sample.lnk'
    function Test-OnUserPath {
        $path = [Environment]::GetEnvironmentVariable('Path', 'User')
        return ($path -split ';' | ForEach-Object { $_.TrimEnd('\') }) -contains $puDir
    }
    function Assert-PerUserInstalled {
        $out = (& (Join-Path $puDir 'sample.exe')) -join "`n"
        if ($LASTEXITCODE -ne 0 -or $out -notmatch 'Hello from the zstaller sample') { throw "per-user sample.exe printed: $out" }
        if (-not (Test-Path $puShortcut)) { throw "per-user Start Menu shortcut $puShortcut was not created" }
        if (-not (Test-OnUserPath)) { throw 'per-user install did not add its folder to the user PATH' }
        if ((Test-OnPath) -or (Test-Path $dir) -or (Test-Path $shortcut)) { throw 'per-user install touched the per-machine locations' }
    }
    function Assert-PerUserRemoved {
        for ($i = 0; $i -lt 20 -and (Test-Path $puDir); $i++) { Start-Sleep -Milliseconds 500 }
        if (Test-Path $puDir) { throw "$puDir still exists: $(Get-ChildItem $puDir -Force | Out-String)" }
        if (Test-Path $puShortcut) { throw 'per-user Start Menu shortcut was not removed' }
        if (Test-OnUserPath) { throw 'per-user PATH entry was not removed' }
    }

    Write-Host '== Per-user EXE: silent install and uninstall'
    Invoke-Checked $puExe '/S'
    Assert-PerUserInstalled
    if (-not (Test-Path $puKey)) { throw 'per-user EXE is not registered under HKEY_CURRENT_USER' }
    Invoke-Checked (Join-Path $puDir 'uninstall.exe') '/S'
    Assert-PerUserRemoved
    if (Test-Path $puKey) { throw 'per-user uninstall entry was not removed' }

    Write-Host '== Per-user MSI: silent install and uninstall'
    Invoke-Checked msiexec.exe "/i `"$puMsi`" /qn /l*v `"$PWD\msi-per-user.log`""
    Assert-PerUserInstalled
    Invoke-Checked msiexec.exe "/x `"$puMsi`" /qn /l*v `"$PWD\msi-per-user-uninstall.log`""
    Assert-PerUserRemoved

    Write-Host '== Per-machine and per-user MSIs install side by side'
    # They are different products, so Windows Installer must not treat the
    # second as the first already installed.
    Invoke-Checked msiexec.exe "/i `"$msi`" /qn /l*v `"$PWD\msi-side-machine.log`""
    Invoke-Checked msiexec.exe "/i `"$puMsi`" /qn /l*v `"$PWD\msi-side-user.log`""
    if (-not (Test-Path $app)) { throw 'the per-machine MSI is not installed' }
    if (-not (Test-Path (Join-Path $puDir 'sample.exe'))) { throw 'the per-user MSI did not install next to the per-machine one' }
    Invoke-Checked msiexec.exe "/x `"$puMsi`" /qn"
    Assert-PerUserRemoved
    if (-not (Test-Path $app)) { throw 'removing the per-user MSI removed the per-machine one' }
    Invoke-Checked msiexec.exe "/x `"$msi`" /qn"
    Assert-Removed
}

function Get-Installer($version, $kind) {
    $suffix = if ($kind -eq 'msi') { '.msi' } else { '-setup.exe' }
    $file = "sample-$version-windows-$arch$suffix"
    if (Test-Path $file) { return (Resolve-Path $file).Path }
    return $null
}

$exe101 = Get-Installer '1.0.1' 'exe'
$msi101 = Get-Installer '1.0.1' 'msi'
$msiRc = Get-Installer '1.0.1-rc.1' 'msi'
if (-not ($exe101 -and $msi101 -and $msiRc)) {
    Write-Host 'Skipping upgrade tests: no 1.0.1 installers here'
    Write-Host 'Windows end-to-end test passed'
    exit 0
}

Write-Host '== EXE: upgrade 1.0.0 -> 1.0.1 in place, then refuse 1.0.0'
Invoke-Checked $exe '/S /NOPATH'
Invoke-Checked $exe101 '/S'
if ((Get-ItemProperty $key).DisplayVersion -ne '1.0.1') { throw 'upgrade did not record 1.0.1' }
Assert-Installed $true
$p = Start-Process -FilePath $exe -ArgumentList '/S' -Wait -PassThru
if ($p.ExitCode -eq 0) { throw 'installing 1.0.0 over 1.0.1 was not refused' }
if ((Get-ItemProperty $key).DisplayVersion -ne '1.0.1') { throw 'the refused downgrade changed the installation' }

Write-Host '== EXE: upgrade to another folder with /NOPATH removes the old folder and PATH entry'
$moved = Join-Path $env:SystemDrive 'zstaller test\Moved'
Invoke-Checked $exe101 "/S /NOPATH `"/D=$moved`""
for ($i = 0; $i -lt 20 -and (Test-Path $dir); $i++) { Start-Sleep -Milliseconds 500 }
if (Test-Path $dir) { throw "the old folder $dir is still there: $(Get-ChildItem $dir -Force | Out-String)" }
if (Test-OnPath) { throw 'the old PATH entry was not removed' }
if (-not (Test-Path (Join-Path $moved 'sample.exe'))) { throw "sample.exe was not installed in $moved" }
Invoke-Checked (Join-Path $moved 'uninstall.exe') '/S'
for ($i = 0; $i -lt 20 -and (Test-Path $moved); $i++) { Start-Sleep -Milliseconds 500 }
if (Test-Path $moved) { throw "$moved still exists" }
Assert-ExeRemoved

function Get-MsiProducts {
    @(Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' |
        Where-Object { $_.DisplayName -eq 'Zstaller Sample' -and $_.PSChildName -like '{*}' })
}

Write-Host '== MSI: 1.0.1 replaces 1.0.1-rc.1 (same numeric version)'
Invoke-Checked msiexec.exe "/i `"$msiRc`" /qn /l*v `"$PWD\msi-rc.log`""
Invoke-Checked msiexec.exe "/i `"$msi101`" /qn /l*v `"$PWD\msi-final.log`""
$products = Get-MsiProducts
if ($products.Count -ne 1) { throw "expected one MSI product after the upgrade, found $($products.Count)" }
Assert-Installed $true

Write-Host '== MSI: 1.0.0 is refused over 1.0.1'
$p = Start-Process -FilePath msiexec.exe -ArgumentList "/i `"$msi`" /qn /l*v `"$PWD\msi-downgrade.log`"" -Wait -PassThru
if ($p.ExitCode -eq 0) { throw 'installing the 1.0.0 MSI over 1.0.1 was not refused' }
Invoke-Checked msiexec.exe "/x `"$msi101`" /qn"
Assert-Removed

Write-Host '== MSI: an upgrade that moves the folder re-registers the MCP server there'
# The old package does not unregister during an upgrade, so the entry
# naming its folder must be recognised as left behind and replaced.
$msiOld = Join-Path $env:SystemDrive 'zstaller test\MSI Old'
Invoke-Checked msiexec.exe "/i `"$msi`" /qn INSTALLDIR=`"$msiOld`" /l*v `"$PWD\msi-move-old.log`""
Assert-McpRegistered $true
Invoke-Checked msiexec.exe "/i `"$msi101`" /qn /l*v `"$PWD\msi-move.log`""
if (Test-Path (Join-Path $msiOld 'sample.exe')) { throw "the upgrade left $msiOld behind" }
$expected = (Join-Path $dir 'sample-tool.exe') -replace '\\', '\\'
if (-not ((Get-Content $claudeJson -Raw) -match [regex]::Escape("`"command`":`"$expected`""))) {
    throw "after the move the MCP server is not registered at ${dir}: $(Get-Content $claudeJson -Raw)"
}
Invoke-Checked msiexec.exe "/x `"$msi101`" /qn"
Assert-Removed

Write-Host '== A failing after_install hook rolls the MSI back and fails the EXE'
# sample-tool --register cannot write registered.txt when a folder has
# that name, so it exits non-zero.
New-Item -ItemType Directory -Force (Join-Path $registered 'blocker') | Out-Null
$p = Start-Process -FilePath msiexec.exe -ArgumentList "/i `"$msi`" /qn /l*v `"$PWD\msi-hook-fail.log`"" -Wait -PassThru
if ($p.ExitCode -ne 1603) { throw "the MSI with a failing hook exited with $($p.ExitCode), expected 1603" }
if (Test-Path $app) { throw 'the MSI with a failing hook was not rolled back' }
if (Get-MsiProducts) { throw 'the MSI with a failing hook stayed registered' }
$p = Start-Process -FilePath $exe -ArgumentList '/S /NOPATH /NOMCP' -Wait -PassThru
if ($p.ExitCode -ne 1) { throw "setup.exe with a failing hook exited with $($p.ExitCode), expected 1" }
# The EXE keeps the files so that the user can retry or uninstall.
if (-not (Test-Path $uninstaller)) { throw 'setup.exe with a failing hook did not keep its uninstaller' }
Remove-Item -Recurse -Force (Split-Path $registered)
Invoke-Checked $uninstaller '/S'
for ($i = 0; $i -lt 20 -and (Test-Path $dir); $i++) { Start-Sleep -Milliseconds 500 }
if (Test-Path $dir) { throw "$dir still exists after uninstalling the failed install" }

Write-Host 'Windows end-to-end test passed'

#!/usr/bin/env bash
# Copyright 2026 The zstaller Authors
# SPDX-License-Identifier: Apache-2.0
#
# Recreates the documentation site's screenshots and terminal transcripts
# in docs/assets/shots/ and docs/_includes/term/. It builds docs/_tools/gallery with the options each
# scenario needs, runs the Windows installers under Wine on a virtual
# display and clicks through them, and installs the .deb on this machine.
#
# Needs Linux with zig 0.16.0, wine, Xvfb, xdotool, ImageMagick, msitools,
# dpkg and lintian; the Ubuntu scenarios need root (they install the .deb).
#
#   docs/_tools/capture.sh                 every scenario
#   docs/_tools/capture.sh wizard upgrade  only those
#
# Wine is not Windows: windows have Wine's classic frame, there is no real
# Restart Manager, UAC or service manager, and Apps & Features is Wine's
# own "Add/Remove Programs". The pages zstaller draws look as on Windows.

set -euo pipefail

TOOLS=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$TOOLS/../.." && pwd)
export SHOTS="${SHOTS:-$REPO/docs/assets/shots}"
export TERMS="${TERMS:-$REPO/docs/_includes/term}"
export WORK="${WORK:-${TMPDIR:-/tmp}/zstaller-capture}"
mkdir -p "$SHOTS" "$TERMS" "$WORK"
# shellcheck source=lib.sh
source "$TOOLS/lib.sh"

SETUP_TITLE='Zstaller Sample Setup'
UNINSTALL_TITLE='Zstaller Sample Uninstall'
PF='C:\Program Files\Zstaller Sample'

# Builds the gallery project with the given -D options into $WORK/build/$1.
build() {
    local name=$1
    shift
    echo "building $name: $*"
    (cd "$TOOLS/gallery" && zig build installer --prefix "$WORK/build/$name" "$@")
}

installer() { # installer <build> <exe|msi> [version]
    local dir="$WORK/build/$1/installers" v="${3:-1.0.0}"
    case $2 in
    exe) echo "$dir/sample-$v-windows-x86_64-setup.exe" ;;
    msi) echo "$dir/sample-$v-windows-x86_64.msi" ;;
    deb) echo "$dir/sample_${v}_amd64.deb" ;;
    esac
}

# Starts a setup program and waits for its wizard.
setup() {
    win_start "$@"
    wait_window "$SETUP_TITLE" 2
    focus "$SETUP_TITLE"
    # A click inside the page (the wizard is centered) makes it the active
    # window, with a highlighted title bar.
    xdotool mousemove 700 450 click 1 mousemove 1270 10
    sleep 0.5
}

# Clicks through a wizard from Welcome to Finished with default choices.
install_defaults() { # install_defaults <setup.exe> [license=yes]
    setup "$1"
    keys alt+n
    if [ "${2:-yes}" = yes ]; then keys alt+a alt+n; fi
    keys alt+n
    keys alt+i
    sleep 3
    keys alt+l alt+f
    wait_gone "$SETUP_TITLE"
}

uninstall_silently() {
    win_run "$PF\\uninstall.exe" /S || true
    sleep 2
}

# ---------------------------------------------------------------- scenarios

# Every page of the wizard, with the sample's own artwork.
scenario_wizard() {
    build custom
    fresh_prefix
    setup "$(installer custom exe)"
    shot wizard-welcome "$SETUP_TITLE"
    keys alt+n
    shot wizard-license "$SETUP_TITLE"
    keys alt+a
    shot wizard-license-accepted "$SETUP_TITLE"
    keys alt+n
    shot wizard-location "$SETUP_TITLE"
    keys alt+n
    shot wizard-options "$SETUP_TITLE"
    keys alt+i
    sleep 3
    shot wizard-finished "$SETUP_TITLE"
    keys alt+f
    sleep 4
    shot wizard-launched
    # Wine's console fills the screen; keep the part with the output.
    convert "$SHOTS/wizard-launched.png" -crop 640x250+0+0 +repage "$SHOTS/wizard-launched.png"
    xdotool key Return
    sleep 1

    # A large extra file slows the install down enough to see progress.
    head -c 300000000 /dev/urandom >"$WORK/large.bin"
    build large -Dlarge="$WORK/large.bin"
    fresh_prefix
    setup "$(installer large exe)"
    keys alt+n alt+a alt+n alt+n alt+i
    SHOT_DELAY=8 shot wizard-installing "$SETUP_TITLE"
    sleep 40
    keys alt+l alt+f
    wait_gone "$SETUP_TITLE"
}

# The built-in artwork, in the default and another accent color, and the
# pages that change with options.
scenario_builtin() {
    build builtin -Dart=builtin
    fresh_prefix
    setup "$(installer builtin exe)"
    shot builtin-welcome "$SETUP_TITLE"
    keys alt+n
    shot builtin-license "$SETUP_TITLE"
    keys Escape
    sleep 1
    shot wizard-cancel-confirm "$SETUP_TITLE"
    keys alt+y
    wait_gone "$SETUP_TITLE"

    build accent -Dart=builtin -Daccent=3046706
    fresh_prefix
    setup "$(installer accent exe)"
    shot accent-welcome "$SETUP_TITLE"
    keys alt+n
    shot accent-license "$SETUP_TITLE"
    keys alt+a alt+n alt+n alt+i
    sleep 3
    shot accent-finished "$SETUP_TITLE"
    keys alt+l alt+f
    wait_gone "$SETUP_TITLE"
}

# Options that remove or lock pages and checkboxes.
scenario_options() {
    build minimal -Dart=builtin -Dlicense=false -Dpath=never -Ddesktop=never -Dmcp=none -Dlaunch=false -Ddir-change=false -Dtexts=true
    fresh_prefix
    setup "$(installer minimal exe)"
    shot minimal-welcome "$SETUP_TITLE"
    keys alt+n
    shot minimal-location "$SETUP_TITLE"
    keys alt+i
    sleep 3
    shot minimal-finished "$SETUP_TITLE"
    keys alt+f
    wait_gone "$SETUP_TITLE"

    build always -Dart=builtin -Dlicense=false -Dpath=always -Ddesktop=always -Dmcp=always
    fresh_prefix
    setup "$(installer always exe)"
    keys alt+n
    shot always-location "$SETUP_TITLE"
    keys alt+i
    sleep 3
    keys alt+l alt+f
    wait_gone "$SETUP_TITLE"

    build pathonly -Dart=builtin -Dlicense=false -Dpath=optional -Ddesktop=never -Dmcp=none
    fresh_prefix
    setup "$(installer pathonly exe)"
    keys alt+n alt+n
    shot pathonly-options "$SETUP_TITLE"
    keys Escape alt+y
    wait_gone "$SETUP_TITLE"

    build programdata -Dart=builtin -Dlicense=false -Droot=program_data
    fresh_prefix
    setup "$(installer programdata exe)"
    keys alt+n
    shot root-program-data "$SETUP_TITLE"
    keys Escape alt+y
    wait_gone "$SETUP_TITLE"

    build systemdrive -Dart=builtin -Dlicense=false -Droot=system_drive
    fresh_prefix
    setup "$(installer systemdrive exe)"
    keys alt+n
    shot root-system-drive "$SETUP_TITLE"
    keys Escape alt+y
    wait_gone "$SETUP_TITLE"
}

# A per-user build: no administrator rights, a folder in the profile.
scenario_peruser() {
    build peruser -Dart=builtin -Dlicense=false -Dscope=user
    fresh_prefix
    setup "$(installer peruser exe)"
    shot peruser-welcome "$SETUP_TITLE"
    keys alt+n
    shot peruser-location "$SETUP_TITLE"
    keys alt+n
    shot peruser-options "$SETUP_TITLE"
    keys alt+i
    sleep 3
    keys alt+l alt+f
    wait_gone "$SETUP_TITLE"
    wtranscript peruser-registry 'reg query HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall /s' reg query 'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall' /s
    wtranscript peruser-path 'reg query HKCU\Environment /v Path' reg query 'HKCU\Environment' /v Path
}

# Installing over an earlier version, the same version and a newer one.
scenario_upgrade() {
    build custom
    build v110 -Dversion=1.1.0
    fresh_prefix
    win_run "$(installer custom exe)" /S
    setup "$(installer v110 exe 1.1.0)"
    shot upgrade-welcome "$SETUP_TITLE"
    keys alt+n alt+a alt+n
    shot upgrade-location "$SETUP_TITLE"
    keys alt+n alt+i
    sleep 3
    shot upgrade-finished "$SETUP_TITLE"
    keys alt+l alt+f
    wait_gone "$SETUP_TITLE"
    setup "$(installer v110 exe 1.1.0)"
    shot repair-welcome "$SETUP_TITLE"
    keys Escape alt+y
    wait_gone "$SETUP_TITLE"
    win_start "$(installer custom exe)"
    wait_window "$SETUP_TITLE" 2
    shot downgrade-refused "$SETUP_TITLE"
    keys Return
    wtranscript downgrade-silent 'sample-1.0.0-windows-x86_64-setup.exe /S' "$(installer custom exe)" /S
}

# The uninstaller, and the Programs in Use page when the app is running.
scenario_uninstall() {
    build custom
    fresh_prefix
    win_run "$(installer custom exe)" /S
    win_start "$PF\\uninstall.exe"
    wait_window "$SETUP_TITLE" 2
    focus "$SETUP_TITLE"
    shot uninstall-confirm "$SETUP_TITLE"
    keys alt+u
    sleep 3
    shot uninstall-finished "$SETUP_TITLE"
    keys alt+c
    wait_gone "$SETUP_TITLE"

    win_run "$(installer custom exe)" /S
    # sample-tool's MCP server runs until its input closes.
    mkfifo "$WORK/hold" 2>/dev/null || true
    (wine "$PF\\sample-tool.exe" mcp <"$WORK/hold" >/dev/null 2>&1 &)
    exec 7>"$WORK/hold"
    sleep 3
    win_start "$PF\\uninstall.exe"
    wait_window "$SETUP_TITLE" 2
    focus "$SETUP_TITLE"
    keys alt+u
    sleep 3
    shot in-use-uninstall "$SETUP_TITLE"
    keys alt+c
    sleep 1
    shot in-use-close-confirm "$SETUP_TITLE"
    keys alt+y
    sleep 4
    shot in-use-closed "$SETUP_TITLE"
    keys alt+c
    wait_gone "$SETUP_TITLE"
    exec 7>&-

    build noclose -Dclose=false
    fresh_prefix
    win_run "$(installer noclose exe)" /S
    (wine "$PF\\sample-tool.exe" mcp <"$WORK/hold" >/dev/null 2>&1 &)
    exec 7>"$WORK/hold"
    sleep 3
    setup "$(installer noclose exe)"
    keys alt+n alt+a alt+n alt+n alt+i
    sleep 3
    shot in-use-install-no-close "$SETUP_TITLE"
    keys Escape alt+y
    sleep 1
    wtranscript in-use-silent '"C:\Program Files\Zstaller Sample\uninstall.exe" /S' "$PF\\uninstall.exe" /S
    exec 7>&-
    sleep 2
}

# The MSI: Windows Installer's own progress window, silent installs, and
# what the EXE and MSI say about each other.
scenario_msi() {
    # Wine draws neither the MSI's basic progress window nor its launch
    # condition message boxes, so the MSI scenarios are command-line only.
    build custom
    build v110 -Dversion=1.1.0
    fresh_prefix
    wtranscript msi-install 'msiexec /i sample-1.0.0-windows-x86_64.msi /qn /l*v install.log' msiexec /i "$(installer custom msi)" /qn /l\*v "$WORK/install.log"
    NOHEAD=1 transcript msi-log-tail "printf 'C:\\\\> findstr /c:\"Action ended\" install.log\\n'; tr -d '\\r' <'$WORK/install.log' | grep -a -E '^Action ended [0-9:]+: (InstallFiles|WriteRegistryValues|WriteEnvironmentStrings|CreateShortcuts|ZstallerRegisterMcp|RegisterProduct|InstallFinalize|INSTALL)\\.'"
    wtranscript msi-path 'reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v Path' reg query 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' /v Path
    win_start "$(installer custom exe)"
    wait_window "$SETUP_TITLE" 2
    shot exe-refuses-msi "$SETUP_TITLE"
    keys Return
    wtranscript msi-upgrade 'msiexec /i sample-1.1.0-windows-x86_64.msi /qn' msiexec /i "$(installer v110 msi 1.1.0)" /qn
    wtranscript msi-downgrade 'msiexec /i sample-1.0.0-windows-x86_64.msi /qn' msiexec /i "$(installer custom msi)" /qn
    wtranscript msi-uninstall 'msiexec /x sample-1.1.0-windows-x86_64.msi /qn' msiexec /x "$(installer v110 msi 1.1.0)" /qn
    wtranscript msi-options 'msiexec /i sample-1.0.0-windows-x86_64.msi /qn ADDTOPATH=0 DESKTOPSHORTCUT=1 REGISTERMCP=0 INSTALLDIR="C:\Apps\Sample"' msiexec /i "$(installer custom msi)" /qn ADDTOPATH=0 DESKTOPSHORTCUT=1 REGISTERMCP=0 'INSTALLDIR=C:\Apps\Sample'
    wdir msi-options-files 'C:\Apps\Sample'
    ltranscript msi-tables "msiinfo tables sample-1.0.0-windows-x86_64.msi" "msiinfo tables '$(installer custom msi)' | sort | paste -sd' ' | fold -s -w 78"
    ltranscript msi-properties "msiinfo export sample-1.0.0-windows-x86_64.msi Property" "msiinfo export '$(installer custom msi)' Property | tail -n +4 | sort"
}

# Silent EXE installs, switches and exit codes.
scenario_silent() {
    build custom
    fresh_prefix
    wtranscript silent-install 'sample-1.0.0-windows-x86_64-setup.exe /S' "$(installer custom exe)" /S
    wdir silent-files "$PF"
    wtranscript silent-path 'reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v Path' reg query 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' /v Path
    wtranscript silent-run 'sample' cmd /c sample
    NOHEAD=1 transcript silent-registry "printf 'C:\\\\> reg query HKLM\\\\Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Uninstall /s\\n(only the Zstaller Sample key)\\n'; wine reg query 'HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall' /s | tr -d '\\r' | awk -v RS= -v ORS='\\n\\n' '/Zstaller Sample/'"
    wtranscript silent-uninstall '"C:\Program Files\Zstaller Sample\uninstall.exe" /S' "$PF\\uninstall.exe" /S
    sleep 3
    wtranscript silent-options 'sample-1.0.0-windows-x86_64-setup.exe /S "/D=C:\Tools\Sample" /NOPATH /DESKTOP /NOMCP' "$(installer custom exe)" /S '/D=C:\Tools\Sample' /NOPATH /DESKTOP /NOMCP
    wdir silent-options-files 'C:\Tools\Sample'
    wdir silent-options-desktop 'C:\users\Public\Desktop'
    wtranscript silent-uninstall-setup 'sample-1.0.0-windows-x86_64-setup.exe /uninstall /S' "$(installer custom exe)" /uninstall /S
    sleep 3
    wtranscript silent-not-installed 'sample-1.0.0-windows-x86_64-setup.exe /uninstall /S' "$(installer custom exe)" /uninstall /S
    # A switch Setup does not know is reported in a message box, /S or not.
    win_start "$(installer custom exe)" /S /FOO
    wait_window "$SETUP_TITLE" 2
    shot bad-switch "$SETUP_TITLE"
    keys Return
    win_start "$(installer custom exe)" /?
    wait_window "$SETUP_TITLE" 2
    shot help "$SETUP_TITLE"
    keys Return
}

# Install hooks, and what a failing one looks like.
scenario_hooks() {
    build hookok -Dhook=ok -Dart=builtin -Dlicense=false
    fresh_prefix
    wtranscript hook-install 'sample-1.0.0-windows-x86_64-setup.exe /S' "$(installer hookok exe)" /S
    wtype hook-state 'C:\ProgramData\Zstaller Sample\registered.txt'
    wtranscript hook-uninstall '"C:\Program Files\Zstaller Sample\uninstall.exe" /S' "$PF\\uninstall.exe" /S
    sleep 3
    wdir hook-state-after 'C:\ProgramData\Zstaller Sample'

    build hookfail -Dhook=fail -Dart=builtin -Dlicense=false
    fresh_prefix
    setup "$(installer hookfail exe)"
    keys alt+n alt+n alt+i
    sleep 4
    shot hook-failed "$SETUP_TITLE"
    keys alt+c
    wait_gone "$SETUP_TITLE"
    fresh_prefix
    wtranscript hook-failed-silent 'sample-1.0.0-windows-x86_64-setup.exe /S' "$(installer hookfail exe)" /S
    fresh_prefix
    wtranscript hook-failed-msi 'msiexec /i sample-1.0.0-windows-x86_64.msi /qn /l*v install.log' msiexec /i "$(installer hookfail msi)" /qn /l\*v "$WORK/hookfail.log"
    wdir hook-failed-msi-files 'C:\Program Files\Zstaller Sample'
}

# The wizard at 150% display scaling.
scenario_dpi() {
    build builtin -Dart=builtin
    build custom
    fresh_prefix
    wine reg add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d 144 /f >/dev/null 2>&1
    wineserver -k || true
    setup "$(installer builtin exe)"
    shot dpi150-builtin "$SETUP_TITLE"
    keys Escape alt+y
    wait_gone "$SETUP_TITLE"
    setup "$(installer custom exe)"
    keys alt+n
    shot dpi150-custom-license "$SETUP_TITLE"
    keys Escape alt+y
    wait_gone "$SETUP_TITLE"
}

# What an installed application looks like to Windows: the Start Menu and
# the list of installed programs (Wine's stand-ins for them).
scenario_windows_shell() {
    build custom
    fresh_prefix
    win_run "$(installer custom exe)" /S /DESKTOP
    win_start uninstaller
    wait_window 'Add/Remove Programs' 3
    shot apps-and-features 'Add/Remove Programs'
    wineserver -k || true
    sleep 1
    # The desktop needs a program running to stay open; keep it minimized.
    win_start cmd /c start /min notepad
    sleep 4
    import -window root "$WORK/full.png"
    convert "$WORK/full.png" -crop 100x70+0+0 +repage "$SHOTS/desktop-shortcut.png"
    echo "  captured desktop-shortcut.png"
    xdotool mousemove 20 889 click 1
    sleep 1.5
    xdotool mousemove 40 800
    sleep 1.5
    xdotool mousemove 160 800
    sleep 1
    import -window root "$WORK/full.png"
    convert "$WORK/full.png" -crop 240x98+0+780 +repage "$SHOTS/start-menu.png"
    echo "  captured start-menu.png"
    xdotool key Escape
    wdir shortcuts-start-menu 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs'
    wdir shortcuts-desktop 'C:\users\Public\Desktop'
}

# The configuration mistakes zstaller catches when it builds.
scenario_errors() {
    local m
    for m in name guid banner icon extra msi_version charset; do
        {
            echo '$ zig build installer'
            (cd "$TOOLS/gallery" && zig build installer -Dmistake=$m --prefix "$WORK/build/mistake" 2>&1 || true) |
                grep -E '^(error: zstaller|zstaller-pack:)' |
                sed -E -e "s#'[^']*/assets/#'assets/#g" -e 's#^zstaller-pack: #error: zstaller: #'
        } >"$TERMS/error-$m.txt"
        echo "  recorded error-$m.txt"
    done
}

# Building the sample, and what comes out.
scenario_build() {
    local out="$WORK/build/sample"
    (cd "$REPO/examples/sample" && zig build installer --prefix "$out")
    ltranscript build-outputs "find zig-out/installers -type f | sort" "cd '$out' && find installers -type f | sort | sed 's|^|zig-out/|'"
    ltranscript build-checksum "cd zig-out/installers && cat sample_1.0.0_amd64.deb.sha256 && sha256sum -c sample_1.0.0_amd64.deb.sha256" "cd '$out/installers' && cat sample_1.0.0_amd64.deb.sha256 && sha256sum -c sample_1.0.0_amd64.deb.sha256"
    ltranscript mcpb-contents "unzip -l sample-1.0.0-windows-x86_64.mcpb" "cd '$out/installers' && unzip -l sample-1.0.0-windows-x86_64.mcpb"
    ltranscript mcpb-manifest "unzip -p sample-1.0.0-windows-x86_64.mcpb manifest.json" "cd '$out/installers' && unzip -p sample-1.0.0-windows-x86_64.mcpb manifest.json"
}

# The Ubuntu package, installed on this machine (needs root).
scenario_ubuntu() {
    local deb="$WORK/build/sample/installers/sample_1.0.0_amd64.deb"
    [ -f "$deb" ] || scenario_build
    cp "$deb" "$WORK/"
    cd "$WORK"
    transcript deb-info "dpkg-deb --info sample_1.0.0_amd64.deb"
    transcript deb-contents "dpkg-deb --contents sample_1.0.0_amd64.deb | awk '{print \$1, \$6}' | column -t"
    transcript deb-lintian "lintian sample_1.0.0_amd64.deb && echo 'lintian: no errors or warnings'"
    transcript deb-install "apt-get install -y ./sample_1.0.0_amd64.deb 2>&1 | grep -E '^(Selecting|Preparing|Unpacking|Setting up)'"
    # lintian warns about running as root, which only matters here.
    sed -i '/running with root privileges/d' "$TERMS/deb-lintian.txt"
    sed -i 's#\.\.\./[^ ]*/sample_#.../sample_#' "$TERMS/deb-install.txt"
    transcript deb-run "sample"
    transcript deb-show "apt-cache show sample | grep -v -E '^(SHA|MD5|Filename|Size)'"
    transcript deb-files "dpkg -L sample"
    transcript deb-desktop "cat /usr/share/applications/sample.desktop"
    transcript deb-conffiles "dpkg-query --showformat='\${Conffiles}\n' --show sample"
    local home="$WORK/home"
    rm -rf "${home:?}"
    mkdir -p "$home/.config/Code/User"
    printf '{\n  "numStartups": 3\n}\n' >"$home/.claude.json"
    transcript mcp-usage "/usr/lib/sample/zstaller-mcp"
    ltranscript mcp-register "/usr/lib/sample/zstaller-mcp register" "HOME='$home' /usr/lib/sample/zstaller-mcp register"
    ltranscript mcp-status "/usr/lib/sample/zstaller-mcp status" "HOME='$home' /usr/lib/sample/zstaller-mcp status"
    ltranscript mcp-claude-json "cat ~/.claude.json" "cat '$home/.claude.json'"
    ltranscript mcp-vscode-json "cat ~/.config/Code/User/mcp.json" "cat '$home/.config/Code/User/mcp.json'"
    ltranscript mcp-unregister "/usr/lib/sample/zstaller-mcp unregister" "HOME='$home' /usr/lib/sample/zstaller-mcp unregister"
    sed -i "s|$home|/home/jane|g" "$TERMS"/mcp-*.txt
    transcript deb-remove "apt-get remove -y sample 2>&1 | grep -E '^(Removing)'"
    transcript deb-purge "apt-get purge -y sample 2>&1 | grep -E '^(Purging)'"
    cd - >/dev/null
}

# Windows: Setup registers the MCP server with the user's AI tools.
scenario_mcp_windows() {
    build custom
    fresh_prefix
    local user=${USER:-$(id -un)}
    local profile="$WINEPREFIX/drive_c/users/$user"
    printf '{\n  "numStartups": 3\n}\n' >"$profile/.claude.json"
    wtranscript mcp-windows-install 'sample-1.0.0-windows-x86_64-setup.exe /S' "$(installer custom exe)" /S
    sleep 3
    wtype mcp-windows-claude-json 'C:\users\'"$user"'\.claude.json'
    wtranscript mcp-windows-status '"C:\Program Files\Zstaller Sample\zstaller-mcp.exe" status' "$PF\\zstaller-mcp.exe" status
    wtranscript mcp-windows-uninstall '"C:\Program Files\Zstaller Sample\uninstall.exe" /S' "$PF\\uninstall.exe" /S
    sleep 3
    wtype mcp-windows-claude-json-after 'C:\users\'"$user"'\.claude.json'
    sed -i "s|$user|jane|g" "$TERMS"/mcp-windows-*.txt
}

# ---------------------------------------------------------------- main

start_display
if [ $# -eq 0 ]; then
    set -- $(declare -F | awk '$3 ~ /^scenario_/ { sub("scenario_", "", $3); print $3 }')
fi
for s in "$@"; do
    echo "== $s"
    "scenario_$s"
done
wineserver -k 2>/dev/null || true

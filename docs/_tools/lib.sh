#!/usr/bin/env bash
# Copyright 2026 The zstaller Authors
# SPDX-License-Identifier: Apache-2.0
#
# Helpers shared by the screenshot scripts: a virtual X display, a Wine
# desktop to run the Windows installers in, and functions to press keys and
# capture the window on screen. Sourced, not run.

set -euo pipefail

: "${SHOTS:?set SHOTS to the folder the screenshots go to}"
: "${WORK:?set WORK to a scratch folder}"
export DISPLAY="${DISPLAY:-:99}"
export WINEDEBUG=-all
export WINEPREFIX="${WINEPREFIX:-$WORK/wineprefix}"
DESKTOP_COLOR="#2a6f97"

start_display() {
    if ! xdpyinfo >/dev/null 2>&1; then
        Xvfb "$DISPLAY" -screen 0 1280x900x24 >/dev/null 2>&1 &
        sleep 1
    fi
}

# A fresh Wine prefix, so every scenario starts on a clean "PC".
fresh_prefix() {
    wineserver -k 2>/dev/null || true
    rm -rf "${WINEPREFIX:?}"
    wineboot -i >/dev/null 2>&1
    wine reg add 'HKCU\Control Panel\Colors' /v Background /d "42 111 151" /f >/dev/null 2>&1
    wineserver -w
}

# Runs a Windows program inside the Wine desktop, in the background.
win_start() {
    (wine explorer /desktop=zstaller,1280x900 "$@" >"$WORK/wine.log" 2>&1 &)
}

# Runs a Windows program and waits for it, printing its output and exit code.
win_run() {
    local code=0
    wine "$@" 2>&1 | tr -d '\r' || code=$?
    return $code
}

# Waits until a window whose title matches $1 exists.
wait_window() {
    local i
    for i in $(seq 1 120); do
        if xdotool search --name "$1" >/dev/null 2>&1; then
            sleep "${2:-1.5}"
            return 0
        fi
        sleep 0.5
    done
    echo "window '$1' never appeared" >&2
    return 1
}

# Waits until no window whose title matches $1 exists.
wait_gone() {
    local i
    for i in $(seq 1 240); do
        xdotool search --name "$1" >/dev/null 2>&1 || return 0
        sleep 0.5
    done
    echo "window '$1' never closed" >&2
    return 1
}

focus() {
    local w
    w=$(xdotool search --name "$1" | tail -1)
    xdotool windowactivate --sync "$w" 2>/dev/null || xdotool windowfocus "$w" 2>/dev/null || true
    sleep 0.3
}

keys() {
    xdotool key --delay 120 "$@"
    sleep 0.8
}

type_text() {
    xdotool type --delay 30 "$1"
    sleep 0.5
}

# Saves a screenshot as $SHOTS/$1.png: the window whose title matches $2,
# frame included, or without $2 the windows on the Wine desktop, cropped
# to them.
shot() {
    local name=$1 title=${2:-} w
    sleep "${SHOT_DELAY:-0.8}"
    if [ -n "$title" ]; then
        w=$(xdotool search --name "$title" | tail -1)
        import -window "$w" "$SHOTS/$name.png"
    else
        import -window root "$WORK/full.png"
        # Drop the taskbar, then trim the plain desktop around the windows.
        convert "$WORK/full.png" -crop 1280x878+0+0 +repage \
            -bordercolor "$DESKTOP_COLOR" -border 1 -fuzz 1% -trim +repage \
            "$SHOTS/$name.png"
    fi
    echo "  captured $name.png"
}

# Terminal transcripts: runs a command and saves "$ cmd" plus its output.
transcript() {
    local name=$1
    shift
    {
        if [ -z "${NOHEAD:-}" ]; then printf '$ %s\n' "$*"; fi
        bash -c "$*" 2>&1 || true
    } | tr -d '\r' >"${TERMS:-$SHOTS}/$name.txt"
    echo "  recorded $name.txt"
}

# Windows transcripts: runs a program under Wine and saves it as typed at a
# Windows prompt ($2), with its output and exit code. Setup programs and
# msiexec are Windows (not console) programs, which Command Prompt does not
# wait for, so they are shown run with `start /wait`, followed by the exit
# code and whatever they wrote to standard error.
wtranscript() {
    local name=$1 shown=$2 code=0 out
    shift 2
    out=$(wine "$@" 2>&1) || code=$?
    {
        case $shown in
        reg\ * | sample | sample\ * | cmd\ * | type\ * | dir\ * | *zstaller-mcp*)
            printf 'C:\\> %s\n' "$shown"
            if [ -n "$out" ]; then printf '%s\n' "$out"; fi
            ;;
        *)
            printf 'C:\\> start /wait %s\n' "$shown"
            printf 'C:\\> echo %%errorlevel%%\n%s\n' "$code"
            if [ -n "$out" ]; then printf '\nStandard error:\n%s\n' "$out"; fi
            ;;
        esac
    } | tr -d '\r' >"${TERMS:-$SHOTS}/$name.txt"
    echo "  recorded $name.txt"
}

# Lists a folder in the Wine prefix as `dir /b` would: wdir <name> <folder>.
wdir() {
    local name=$1 folder=$2 unix
    unix=$(winepath -u "$folder" 2>/dev/null)
    {
        printf 'C:\\> dir /b "%s"\n' "$folder"
        if [ -d "$unix" ]; then ls -1 "$unix"; else echo "File Not Found"; fi
    } >"${TERMS:-$SHOTS}/$name.txt"
    echo "  recorded $name.txt"
}

# Shows a text file in the Wine prefix as `type` would: wtype <name> <file>.
wtype() {
    local name=$1 file=$2
    {
        printf 'C:\\> type "%s"\n' "$file"
        tr -d '\r' <"$(winepath -u "$file" 2>/dev/null)"
        echo
    } >"${TERMS:-$SHOTS}/$name.txt"
    echo "  recorded $name.txt"
}

# Linux transcripts that show a tidier command ($2) than the one run ($3),
# for example without the scratch paths: ltranscript <name> <shown> <cmd>.
ltranscript() {
    local name=$1 shown=$2
    shift 2
    {
        printf '$ %s\n' "$shown"
        bash -c "$*" 2>&1 || true
    } | tr -d '\r' >"${TERMS:-$SHOTS}/$name.txt"
    echo "  recorded $name.txt"
}

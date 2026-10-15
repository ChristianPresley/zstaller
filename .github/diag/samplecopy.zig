// Copyright 2026 The zstaller Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0
//! A small command-line program used to demonstrate zstaller.
//!
//! It prints where it is installed and what it runs on. When started from
//! the Start Menu or Explorer, Windows opens a console window just for it,
//! so it waits for Enter before closing to leave the output readable.

const std = @import("std");
const builtin = @import("builtin");
const options = struct { const version = "diag"; };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const w = &stdout.interface;

    const exe_path = std.process.executablePathAlloc(io, init.arena.allocator()) catch "unknown";
    try w.print(
        \\
        \\  Zstaller Sample {s}
        \\  -------------------------------------------
        \\  Hello from the zstaller sample on {t}-{t}!
        \\
        \\  Installed at: {s}
        \\  Built with:   Zig {s}, packaged by zstaller
        \\
        \\
    , .{ options.version, builtin.os.tag, builtin.cpu.arch, exe_path, builtin.zig_version_string });
    if (builtin.os.tag == .windows) {
        try w.writeAll(
            \\  To uninstall, open Settings > Apps > Installed apps,
            \\  find "Zstaller Sample" and choose Uninstall.
            \\
            \\
        );
    } else {
        try w.writeAll(
            \\  To uninstall, run: sudo apt remove sample
            \\
            \\
        );
    }

    if (builtin.os.tag == .windows and ownsConsole()) {
        try w.writeAll("  Press Enter to close this window...");
        try w.flush();
        var in_buf: [64]u8 = undefined;
        var stdin = std.Io.File.stdin().reader(io, &in_buf);
        _ = stdin.interface.takeDelimiterExclusive('\n') catch {};
    }
    try w.flush();
}

/// True when this process is the only one attached to its console, which
/// means Windows created the console for it (a double-click or shortcut)
/// rather than it being run from an existing terminal.
fn ownsConsole() bool {
    var ids: [2]u32 = undefined;
    return GetConsoleProcessList(&ids, ids.len) == 1;
}

extern "kernel32" fn GetConsoleProcessList(list: [*]u32, count: u32) callconv(.winapi) u32;

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

//! Platform-independent logic of the Windows EXE installer stub: command
//! line parsing and PATH editing. Kept free of Win32 calls so it is unit
//! tested on every host.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const PathMode = enum { never, optional, always };

pub const Command = struct {
    action: Action = .install,
    silent: bool = false,
    /// Install directory override (`/D=<dir>`).
    install_dir: ?[]const u8 = null,
    /// Explicit PATH choice (`/PATH` or `/NOPATH`); null means "use the
    /// default for this installer".
    add_to_path: ?bool = null,

    pub const Action = enum { install, uninstall, help };
};

pub const ParseError = error{UnknownOption};

/// Parses installer arguments (excluding argv[0]). Options are
/// case-insensitive and may start with '/' or '-'.
///
///   /S           silent: no dialogs, result reported by exit code
///   /D=<dir>     install directory
///   /PATH        add the install directory to the system PATH
///   /NOPATH      do not add it
///   /uninstall   remove the installed application
///   /?           show help
pub fn parse(args: []const []const u8) ParseError!Command {
    var cmd: Command = .{};
    for (args) |raw| {
        if (raw.len < 2 or (raw[0] != '/' and raw[0] != '-')) return error.UnknownOption;
        const a = raw[1..];
        if (eqlIgnoreCase(a, "s") or eqlIgnoreCase(a, "silent") or eqlIgnoreCase(a, "quiet")) {
            cmd.silent = true;
        } else if (a.len > 2 and std.ascii.toLower(a[0]) == 'd' and a[1] == '=') {
            cmd.install_dir = a[2..];
        } else if (eqlIgnoreCase(a, "path")) {
            cmd.add_to_path = true;
        } else if (eqlIgnoreCase(a, "nopath")) {
            cmd.add_to_path = false;
        } else if (eqlIgnoreCase(a, "uninstall") or eqlIgnoreCase(a, "u")) {
            cmd.action = .uninstall;
        } else if (eqlIgnoreCase(a, "?") or eqlIgnoreCase(a, "h") or eqlIgnoreCase(a, "help")) {
            cmd.action = .help;
        } else {
            return error.UnknownOption;
        }
    }
    return cmd;
}

pub const help_text =
    \\Options:
    \\  /S          Silent install or uninstall (no dialogs)
    \\  /D=<dir>    Install directory
    \\  /PATH       Add the install directory to the system PATH
    \\  /NOPATH     Do not add the install directory to PATH
    \\  /uninstall  Remove the application
    \\
    \\Exit codes: 0 success, 1 error, 2 cancelled, 3 bad arguments
;

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Normalizes a directory for comparison: trims surrounding whitespace,
/// quotes and trailing backslashes.
fn normalizeDir(dir: []const u8) []const u8 {
    var d = std.mem.trim(u8, dir, " \t\"");
    while (d.len > 3 and (d[d.len - 1] == '\\' or d[d.len - 1] == '/')) d = d[0 .. d.len - 1];
    return d;
}

fn sameDir(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(normalizeDir(a), normalizeDir(b));
}

/// Returns true when `path_var` (a ';'-separated list) contains `dir`.
pub fn pathContains(path_var: []const u8, dir: []const u8) bool {
    var it = std.mem.splitScalar(u8, path_var, ';');
    while (it.next()) |entry| {
        if (sameDir(entry, dir)) return true;
    }
    return false;
}

/// Returns `path_var` with `dir` appended, or null if it is already
/// present.
pub fn pathAppend(gpa: Allocator, path_var: []const u8, dir: []const u8) Allocator.Error!?[]u8 {
    if (pathContains(path_var, dir)) return null;
    const trimmed = std.mem.trimEnd(u8, path_var, ";");
    if (trimmed.len == 0) return try gpa.dupe(u8, dir);
    return try std.mem.concat(gpa, u8, &.{ trimmed, ";", dir });
}

/// Returns `path_var` with every entry equal to `dir` removed, or null if
/// it was not present.
pub fn pathRemove(gpa: Allocator, path_var: []const u8, dir: []const u8) Allocator.Error!?[]u8 {
    if (!pathContains(path_var, dir)) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.splitScalar(u8, path_var, ';');
    var first = true;
    while (it.next()) |entry| {
        if (entry.len == 0 or sameDir(entry, dir)) continue;
        if (!first) try out.append(gpa, ';');
        try out.appendSlice(gpa, entry);
        first = false;
    }
    return try out.toOwnedSlice(gpa);
}

/// Parses the uninstall manifest written next to the installed files: one
/// relative path per line.
pub fn manifestPaths(gpa: Allocator, text: []const u8) Allocator.Error![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const l = std.mem.trimEnd(u8, line, "\r");
        if (l.len == 0) continue;
        if (!@import("../payload.zig").isSafePath(l)) continue;
        try list.append(gpa, l);
    }
    return list.toOwnedSlice(gpa);
}

const testing = std.testing;

test "parse options" {
    const c = try parse(&.{ "/S", "/D=C:\\Apps\\My App", "/NOPATH" });
    try testing.expect(c.silent);
    try testing.expectEqualStrings("C:\\Apps\\My App", c.install_dir.?);
    try testing.expectEqual(false, c.add_to_path.?);
    try testing.expectEqual(Command.Action.install, c.action);

    const u = try parse(&.{ "-uninstall", "/s" });
    try testing.expectEqual(Command.Action.uninstall, u.action);
    try testing.expect(u.silent);

    try testing.expectEqual(Command.Action.help, (try parse(&.{"/?"})).action);
    try testing.expectEqual(true, (try parse(&.{"/path"})).add_to_path.?);
    try testing.expectError(error.UnknownOption, parse(&.{"/bogus"}));
    try testing.expectError(error.UnknownOption, parse(&.{"stray"}));
}

test "path append and remove" {
    const gpa = testing.allocator;
    const base = "C:\\Windows\\system32;C:\\Windows";
    const added = (try pathAppend(gpa, base, "C:\\Program Files\\App")).?;
    defer gpa.free(added);
    try testing.expectEqualStrings("C:\\Windows\\system32;C:\\Windows;C:\\Program Files\\App", added);
    try testing.expect((try pathAppend(gpa, added, "c:\\program files\\app\\")) == null);

    const removed = (try pathRemove(gpa, added, "C:\\PROGRAM FILES\\APP")).?;
    defer gpa.free(removed);
    try testing.expectEqualStrings(base, removed);
    try testing.expect((try pathRemove(gpa, base, "C:\\Other")) == null);

    const from_empty = (try pathAppend(gpa, ";", "C:\\X")).?;
    defer gpa.free(from_empty);
    try testing.expectEqualStrings("C:\\X", from_empty);
}

test "manifest parsing skips unsafe lines" {
    const gpa = testing.allocator;
    const paths = try manifestPaths(gpa, "app.exe\r\ndocs/readme.txt\n\n../evil\n");
    defer gpa.free(paths);
    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expectEqualStrings("docs/readme.txt", paths[1]);
}

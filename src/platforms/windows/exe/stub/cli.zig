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

/// Whether the installer creates a desktop shortcut: never, when the user
/// ticks the box (unticked by default; `/DESKTOP` on the command line), or
/// always.
pub const DesktopShortcut = enum { never, optional, always };

/// The folder the default install directory is created in.
pub const InstallRoot = enum {
    /// `C:\Program Files` (the native one, also from an emulated process).
    program_files,
    /// `C:\ProgramData`.
    program_data,
    /// The root of the Windows drive, `C:\`.
    system_drive,
    /// `%LOCALAPPDATA%\Programs`, for per-user installs.
    user_programs,
};

/// File name of the uninstaller the installer copies into the install
/// directory.
pub const uninstaller_name = "uninstall.exe";

pub const Command = struct {
    /// Explicit action; null means "decide from the executable's name"
    /// (see `defaultAction`).
    action: ?Action = null,
    silent: bool = false,
    /// Install directory override (`/D=<dir>`).
    install_dir: ?[]const u8 = null,
    /// Explicit PATH choice (`/PATH` or `/NOPATH`); null means "use the
    /// default for this installer".
    add_to_path: ?bool = null,
    /// Explicit desktop shortcut choice (`/DESKTOP` or `/NODESKTOP`).
    desktop_shortcut: ?bool = null,
    /// Internal (`/_cleanup=<dir>`): run as the temporary helper that
    /// removes the uninstaller and the install directory once the
    /// uninstaller has exited.
    cleanup_dir: ?[]const u8 = null,
    /// Internal (`/_wait=<handle>`): inherited process handle of the
    /// uninstaller the cleanup helper waits for.
    wait_handle: ?usize = null,

    pub const Action = enum { install, uninstall, help, cleanup };
};

/// The action when none is given on the command line. The installer and
/// the uninstaller are the same program, so the uninstaller is recognized
/// by the name it is installed under: run directly (or double-clicked) it
/// must uninstall, not install again.
pub fn defaultAction(exe_path: []const u8) Command.Action {
    const base = basenameWindows(exe_path);
    return if (std.ascii.eqlIgnoreCase(base, uninstaller_name)) .uninstall else .install;
}

fn basenameWindows(path: []const u8) []const u8 {
    const start = if (std.mem.lastIndexOfAny(u8, path, "\\/")) |i| i + 1 else 0;
    return path[start..];
}

pub const ParseError = error{UnknownOption};

/// Parses installer arguments (excluding argv[0]). Options are
/// case-insensitive and may start with '/' or '-'.
///
///   /S           silent: no dialogs, result reported by exit code
///   /D=<dir>     install directory
///   /PATH        add the install directory to the system PATH
///   /NOPATH      do not add it
///   /DESKTOP     create a desktop shortcut
///   /NODESKTOP   do not create one
///   /uninstall   remove the installed application (the default when the
///                program is run as uninstall.exe)
///   /?           show help
///
/// `/_cleanup=<dir>` and `/_wait=<handle>` are internal: the uninstaller
/// passes them to the temporary helper that deletes it after it exits.
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
        } else if (eqlIgnoreCase(a, "desktop")) {
            cmd.desktop_shortcut = true;
        } else if (eqlIgnoreCase(a, "nodesktop")) {
            cmd.desktop_shortcut = false;
        } else if (eqlIgnoreCase(a, "uninstall") or eqlIgnoreCase(a, "u")) {
            cmd.action = .uninstall;
        } else if (eqlIgnoreCase(a, "?") or eqlIgnoreCase(a, "h") or eqlIgnoreCase(a, "help")) {
            cmd.action = .help;
        } else if (startsWithIgnoreCase(a, "_cleanup=") and a.len > "_cleanup=".len) {
            cmd.action = .cleanup;
            cmd.cleanup_dir = a["_cleanup=".len..];
        } else if (startsWithIgnoreCase(a, "_wait=")) {
            cmd.wait_handle = std.fmt.parseInt(usize, a["_wait=".len..], 10) catch return error.UnknownOption;
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
    \\  /DESKTOP    Create a desktop shortcut
    \\  /NODESKTOP  Do not create a desktop shortcut
    \\  /uninstall  Remove the application (the default for uninstall.exe)
    \\
    \\Exit codes: 0 success, 1 error, 2 cancelled, 3 bad arguments
;

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn startsWithIgnoreCase(a: []const u8, prefix: []const u8) bool {
    return a.len >= prefix.len and std.ascii.eqlIgnoreCase(a[0..prefix.len], prefix);
}

/// The default install directory: `dir_name` (which may contain
/// backslashes, such as `Acme\\Widget`) inside `root`, found from the
/// environment.
pub fn defaultInstallDir(gpa: Allocator, root: InstallRoot, env: *const std.process.Environ.Map, dir_name: []const u8) Allocator.Error![]u8 {
    const base = switch (root) {
        // ProgramW6432 is the native Program Files even from an emulated
        // process; ProgramFiles is the fallback.
        .program_files => env.get("ProgramW6432") orelse env.get("ProgramFiles") orelse "C:\\Program Files",
        .program_data => env.get("ProgramData") orelse env.get("ALLUSERSPROFILE") orelse "C:\\ProgramData",
        .system_drive => env.get("SystemDrive") orelse "C:",
        .user_programs => return std.mem.concat(gpa, u8, &.{
            std.mem.trimEnd(u8, env.get("LOCALAPPDATA") orelse "C:\\Users\\Default\\AppData\\Local", "\\/"),
            "\\Programs\\",
            dir_name,
        }),
    };
    return std.mem.concat(gpa, u8, &.{ std.mem.trimEnd(u8, base, "\\/"), "\\", dir_name });
}

/// The folder to install into after the user picks `picked` with Browse:
/// the application's own folder (`leaf`) inside it, unless the user
/// picked a folder of that name.
pub fn browsedInstallDir(gpa: Allocator, picked: []const u8, leaf: []const u8) Allocator.Error![]u8 {
    const trimmed = if (picked.len > 3) std.mem.trimEnd(u8, picked, "\\/") else picked;
    if (std.ascii.eqlIgnoreCase(basenameWindows(trimmed), leaf)) return gpa.dupe(u8, trimmed);
    const sep: []const u8 = if (trimmed.len > 0 and (trimmed[trimmed.len - 1] == '\\' or trimmed[trimmed.len - 1] == '/')) "" else "\\";
    return std.mem.concat(gpa, u8, &.{ trimmed, sep, leaf });
}

/// The last component of an `install_dir_name` such as `Acme\\Widget`.
pub fn installDirLeaf(dir_name: []const u8) []const u8 {
    return basenameWindows(std.mem.trimEnd(u8, dir_name, "\\/"));
}

/// Whether `dir` is a usable install directory: a fully qualified path on
/// a drive (`C:\\...`) or a network share (`\\\\server\\share\\...`),
/// without characters Windows forbids in names.
pub fn isValidInstallDir(dir: []const u8) bool {
    const d = std.mem.trim(u8, dir, " ");
    if (d.len != dir.len) return false;
    var rest: []const u8 = undefined;
    if (d.len >= 3 and std.ascii.isAlphabetic(d[0]) and d[1] == ':' and (d[2] == '\\' or d[2] == '/')) {
        rest = d[3..];
    } else if (std.mem.startsWith(u8, d, "\\\\") and d.len > 2) {
        rest = d[2..];
        // Server and share.
        var it = std.mem.tokenizeAny(u8, rest, "\\/");
        if (it.next() == null or it.next() == null) return false;
    } else return false;
    var it = std.mem.splitAny(u8, rest, "\\/");
    while (it.next()) |seg| {
        if (seg.len == 0) {
            if (it.peek() == null) break; // trailing separator
            return false;
        }
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
        if (seg[seg.len - 1] == '.' or seg[seg.len - 1] == ' ') return false;
        for (seg) |c| switch (c) {
            0...31, '<', '>', ':', '"', '|', '?', '*' => return false,
            else => {},
        };
    }
    return true;
}

/// The root of the volume `dir` is on, for free-space queries: `C:\\` or
/// `\\\\server\\share\\`. Null if `dir` is not a full path.
pub fn volumeRoot(dir: []const u8) ?[]const u8 {
    if (dir.len >= 3 and std.ascii.isAlphabetic(dir[0]) and dir[1] == ':' and (dir[2] == '\\' or dir[2] == '/')) return dir[0..3];
    if (!std.mem.startsWith(u8, dir, "\\\\")) return null;
    var seps: usize = 0;
    for (dir[2..], 2..) |c, i| {
        if (c == '\\' or c == '/') {
            seps += 1;
            if (seps == 2) return dir[0 .. i + 1];
        }
    }
    return null;
}

/// A byte count for people: `512 bytes`, `1.5 KB`, `24.0 MB`, `1.2 GB`.
pub fn formatSize(buf: []u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "KB", "MB", "GB", "TB" };
    if (bytes < 1024) return std.fmt.bufPrint(buf, "{d} bytes", .{bytes}) catch buf[0..0];
    var value: f64 = @floatFromInt(bytes);
    var unit: usize = 0;
    value /= 1024;
    while (value >= 1024 and unit + 1 < units.len) : (unit += 1) value /= 1024;
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[unit] }) catch buf[0..0];
}

/// `text` with every line ending as CRLF, as a Windows edit control needs.
pub fn crlf(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, text.len + text.len / 32);
    for (text, 0..) |c, i| {
        if (c == '\n' and (i == 0 or text[i - 1] != '\r')) try out.append(gpa, '\r');
        try out.append(gpa, c);
    }
    return out.toOwnedSlice(gpa);
}

/// Normalizes a directory for comparison: trims surrounding whitespace,
/// quotes and trailing backslashes.
fn normalizeDir(dir: []const u8) []const u8 {
    var d = std.mem.trim(u8, dir, " \t\"");
    while (d.len > 3 and (d[d.len - 1] == '\\' or d[d.len - 1] == '/')) d = d[0 .. d.len - 1];
    return d;
}

/// Returns true when `a` and `b` name the same folder, ignoring case and
/// trailing separators.
pub fn sameDir(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(normalizeDir(a), normalizeDir(b));
}

/// How many trailing folders of `dir` belong to the application: every
/// folder of `dir_name` (`Acme\\Widget` is two) when `dir` is the default
/// location `default_dir`, else only the install folder itself.
pub fn ownedComponents(dir: []const u8, default_dir: []const u8, dir_name: []const u8) usize {
    if (!sameDir(dir, default_dir)) return 1;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, dir_name, "\\/");
    while (it.next()) |_| n += 1;
    return @max(n, 1);
}

test "ownedComponents" {
    try std.testing.expectEqual(2, ownedComponents("C:\\Acme\\Widget", "c:\\acme\\widget\\", "Acme\\Widget"));
    try std.testing.expectEqual(1, ownedComponents("D:\\Tools\\Widget", "C:\\Acme\\Widget", "Acme\\Widget"));
    try std.testing.expectEqual(1, ownedComponents("C:\\Widget", "C:\\Widget", "Widget"));
}

/// `args` joined into a command line that CommandLineToArgvW and the C
/// runtime split back into the same arguments: each is quoted when it is
/// empty or has a space, tab or quote, with backslashes before a quote
/// doubled.
pub fn joinArgs(gpa: Allocator, args: []const []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (args, 0..) |arg, i| {
        if (i > 0) try out.append(gpa, ' ');
        if (arg.len > 0 and std.mem.indexOfAny(u8, arg, " \t\"") == null) {
            try out.appendSlice(gpa, arg);
            continue;
        }
        try out.append(gpa, '"');
        var backslashes: usize = 0;
        for (arg) |c| {
            if (c == '\\') {
                backslashes += 1;
                continue;
            }
            const n = if (c == '"') backslashes * 2 + 1 else backslashes;
            try out.appendNTimes(gpa, '\\', n);
            backslashes = 0;
            try out.append(gpa, c);
        }
        try out.appendNTimes(gpa, '\\', backslashes * 2);
        try out.append(gpa, '"');
    }
    return out.toOwnedSlice(gpa);
}

test "joinArgs" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { []const []const u8, []const u8 }{
        .{ &.{ "register", "--quiet" }, "register --quiet" },
        .{ &.{ "C:\\Program Files\\X", "" }, "\"C:\\Program Files\\X\" \"\"" },
        .{ &.{"say \"hi\""}, "\"say \\\"hi\\\"\"" },
        .{ &.{"dir\\ with space\\"}, "\"dir\\ with space\\\\\"" },
        .{ &.{"a\\\\b"}, "a\\\\b" },
    };
    for (cases) |c| {
        const got = try joinArgs(gpa, c[0]);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(c[1], got);
    }
}

/// The "packed" form of a `{GUID}` that Windows Installer uses for
/// registry key names, such as the product's upgrade code under
/// `HKLM\SOFTWARE\Classes\Installer\UpgradeCodes`: the first three
/// groups reversed, and the characters of each later byte swapped.
pub fn packedGuid(guid: []const u8) ?[32]u8 {
    if (guid.len != 38 or guid[0] != '{' or guid[37] != '}') return null;
    var hex: [32]u8 = undefined;
    var n: usize = 0;
    for (guid[1..37], 1..) |c, i| {
        if (i == 9 or i == 14 or i == 19 or i == 24) {
            if (c != '-') return null;
            continue;
        }
        if (!std.ascii.isHex(c)) return null;
        hex[n] = std.ascii.toUpper(c);
        n += 1;
    }
    var out: [32]u8 = undefined;
    for (0..8) |i| out[i] = hex[7 - i];
    for (0..4) |i| out[8 + i] = hex[11 - i];
    for (0..4) |i| out[12 + i] = hex[15 - i];
    var i: usize = 16;
    while (i < 32) : (i += 2) {
        out[i] = hex[i + 1];
        out[i + 1] = hex[i];
    }
    return out;
}

test packedGuid {
    try std.testing.expectEqualStrings(
        "A0E6B1C3D7F825E4B9A1D6C2F4E8A701",
        &packedGuid("{3C1B6E0A-8F7D-4E52-9B1A-6D2C4F8E7A10}").?,
    );
    try std.testing.expectEqual(null, packedGuid("3C1B6E0A-8F7D-4E52-9B1A-6D2C4F8E7A10"));
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
/// it was not present. Every other entry, empty ones included, is kept as
/// it was.
pub fn pathRemove(gpa: Allocator, path_var: []const u8, dir: []const u8) Allocator.Error!?[]u8 {
    if (!pathContains(path_var, dir)) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.splitScalar(u8, path_var, ';');
    var first = true;
    while (it.next()) |entry| {
        if (entry.len > 0 and sameDir(entry, dir)) continue;
        if (!first) try out.append(gpa, ';');
        try out.appendSlice(gpa, entry);
        first = false;
    }
    return try out.toOwnedSlice(gpa);
}

/// How an install changes the system PATH.
pub const PathChange = struct {
    /// An entry an earlier installation added that must go.
    remove: ?[]const u8 = null,
    /// Add the new install directory (if not already there).
    add: bool = false,
    /// The entry an earlier installation added stays, and is still ours.
    keep_ownership: bool = false,
};

/// Decides the PATH changes for installing to `dir`, given what an
/// earlier installation (in `previous_dir`, if any) recorded. Only entries
/// an installation added itself are ever removed, so a folder the user put
/// on PATH stays there.
pub fn planPathChange(previous_dir: ?[]const u8, previous_added: bool, dir: []const u8, want: bool) PathChange {
    var change: PathChange = .{ .add = want };
    if (previous_dir) |prev| if (previous_added) {
        if (want and sameDir(prev, dir)) {
            change.keep_ownership = true;
        } else {
            change.remove = prev;
        }
    };
    return change;
}

/// Returns true when `installed` is a newer semantic version than
/// `this`. Versions that do not parse are never newer, so a broken
/// registry value cannot block an install.
pub fn isNewerVersion(installed: []const u8, this: []const u8) bool {
    const a = std.SemanticVersion.parse(installed) catch return false;
    const b = std.SemanticVersion.parse(this) catch return false;
    return a.order(b) == .gt;
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

/// Returns true when `path` is `dir` itself or a file or directory below
/// it. Case-insensitive; accepts '\' and '/' separators.
pub fn isInsideDir(path: []const u8, dir: []const u8) bool {
    const d = normalizeDir(dir);
    if (d.len == 0 or path.len < d.len) return false;
    if (!std.ascii.eqlIgnoreCase(path[0..d.len], d)) return false;
    if (path.len == d.len) return true;
    return path[d.len] == '\\' or path[d.len] == '/' or d[d.len - 1] == '\\' or d[d.len - 1] == '/';
}

/// A program that keeps installed files in use: one running from the
/// install directory, or one Windows reports as having its files open.
pub const RunningProcess = struct {
    pid: u32,
    /// File name of the program, e.g. `app.exe`.
    name: []const u8,
    /// Full path of the program's executable, when it could be read.
    path: []const u8 = "",
    /// The account it runs as, e.g. `CONTOSO\alice` or
    /// `NT AUTHORITY\SYSTEM`, when it could be read.
    user: []const u8 = "",
    /// Short name of the Windows service it hosts, if it is one.
    service: ?[]const u8 = null,

    /// The program's name, with the service it runs: `app.exe` or
    /// `svchost.exe (service AppSvc)`.
    pub fn label(p: RunningProcess, buf: []u8) []const u8 {
        const service = p.service orelse return p.name;
        return std.fmt.bufPrint(buf, "{s} (service {s})", .{ p.name, service }) catch p.name;
    }

    /// Whether `p` and `q` are the same program; a process hosting
    /// several services appears once per service.
    pub fn same(p: RunningProcess, q: RunningProcess) bool {
        if (p.pid != q.pid) return false;
        const a = p.service orelse return q.service == null;
        const b = q.service orelse return false;
        return std.ascii.eqlIgnoreCase(a, b);
    }
};

/// Adds `p` to `list` unless it is already there. A service entry
/// replaces a plain entry for the same process, since it says more.
pub fn addProcess(gpa: Allocator, list: *std.ArrayList(RunningProcess), p: RunningProcess) Allocator.Error!void {
    for (list.items) |*q| {
        if (q.same(p)) return;
        if (q.pid == p.pid and q.service == null and p.service != null) {
            q.* = p;
            return;
        }
        if (q.pid == p.pid and p.service == null) return;
    }
    try list.append(gpa, p);
}

/// File name of `image_path`, a full Windows path.
pub fn processName(image_path: []const u8) []const u8 {
    return basenameWindows(image_path);
}

/// One or two lines per process:
///
///     app.exe (process ID 1234, user CONTOSO\alice)
///       C:\Program Files\App\app.exe
pub fn processList(gpa: Allocator, procs: []const RunningProcess) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (procs, 0..) |p, i| {
        if (i > 0) try out.append(gpa, '\n');
        var buf: [256]u8 = undefined;
        try out.print(gpa, "  {s} (process ID {d}", .{ p.label(&buf), p.pid });
        if (p.user.len > 0) try out.print(gpa, ", user {s}", .{p.user});
        try out.append(gpa, ')');
        if (p.path.len > 0) try out.print(gpa, "\n    {s}", .{p.path});
    }
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

test "isInsideDir" {
    try testing.expect(isInsideDir("C:\\Program Files\\App\\app.exe", "C:\\Program Files\\App"));
    try testing.expect(isInsideDir("c:\\program files\\app\\bin\\tool.exe", "C:\\Program Files\\App\\"));
    try testing.expect(isInsideDir("C:\\Program Files\\App", "C:\\Program Files\\App"));
    try testing.expect(!isInsideDir("C:\\Program Files\\AppTools\\app.exe", "C:\\Program Files\\App"));
    try testing.expect(!isInsideDir("C:\\Windows\\explorer.exe", "C:\\Program Files\\App"));
    try testing.expect(isInsideDir("C:\\x.exe", "C:\\"));
}

test "processList" {
    const gpa = testing.allocator;
    try testing.expectEqualStrings("app.exe", processName("C:\\Program Files\\App\\app.exe"));
    const text = try processList(gpa, &.{
        .{ .pid = 1234, .name = "app.exe", .path = "C:\\Program Files\\App\\app.exe", .user = "CONTOSO\\alice" },
        .{ .pid = 99, .name = "helper.exe" },
        .{ .pid = 7, .name = "svchost.exe", .user = "NT AUTHORITY\\SYSTEM", .service = "AppSvc" },
    });
    defer gpa.free(text);
    try testing.expectEqualStrings(
        "  app.exe (process ID 1234, user CONTOSO\\alice)\n    C:\\Program Files\\App\\app.exe\n" ++
            "  helper.exe (process ID 99)\n" ++
            "  svchost.exe (service AppSvc) (process ID 7, user NT AUTHORITY\\SYSTEM)",
        text,
    );
}

test "addProcess merges duplicates" {
    const gpa = testing.allocator;
    var list: std.ArrayList(RunningProcess) = .empty;
    defer list.deinit(gpa);
    try addProcess(gpa, &list, .{ .pid = 1, .name = "app.exe" });
    try addProcess(gpa, &list, .{ .pid = 1, .name = "app.exe" });
    try addProcess(gpa, &list, .{ .pid = 2, .name = "svchost.exe" });
    try addProcess(gpa, &list, .{ .pid = 2, .name = "svchost.exe", .service = "A" });
    try addProcess(gpa, &list, .{ .pid = 2, .name = "svchost.exe", .service = "b" });
    try addProcess(gpa, &list, .{ .pid = 2, .name = "svchost.exe", .service = "B" });
    try addProcess(gpa, &list, .{ .pid = 2, .name = "svchost.exe" });
    try testing.expectEqual(@as(usize, 3), list.items.len);
    try testing.expectEqualStrings("A", list.items[1].service.?);
    try testing.expectEqualStrings("b", list.items[2].service.?);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("svchost.exe (service A)", list.items[1].label(&buf));
    try testing.expectEqualStrings("app.exe", list.items[0].label(&buf));
}

test "parse options" {
    const c = try parse(&.{ "/S", "/D=C:\\Apps\\My App", "/NOPATH" });
    try testing.expect(c.silent);
    try testing.expectEqualStrings("C:\\Apps\\My App", c.install_dir.?);
    try testing.expectEqual(false, c.add_to_path.?);
    try testing.expectEqual(@as(?Command.Action, null), c.action);

    const u = try parse(&.{ "-uninstall", "/s" });
    try testing.expectEqual(Command.Action.uninstall, u.action);
    try testing.expect(u.silent);

    try testing.expectEqual(Command.Action.help, (try parse(&.{"/?"})).action);
    try testing.expectEqual(true, (try parse(&.{"/path"})).add_to_path.?);
    try testing.expectEqual(true, (try parse(&.{"/DESKTOP"})).desktop_shortcut.?);
    try testing.expectEqual(false, (try parse(&.{"-nodesktop"})).desktop_shortcut.?);
    try testing.expectError(error.UnknownOption, parse(&.{"/bogus"}));
    try testing.expectError(error.UnknownOption, parse(&.{"stray"}));

    const h = try parse(&.{ "/_cleanup=C:\\Program Files\\App", "/_wait=1234" });
    try testing.expectEqual(Command.Action.cleanup, h.action.?);
    try testing.expectEqualStrings("C:\\Program Files\\App", h.cleanup_dir.?);
    try testing.expectEqual(@as(usize, 1234), h.wait_handle.?);
    try testing.expectError(error.UnknownOption, parse(&.{"/_wait=x"}));
    try testing.expectError(error.UnknownOption, parse(&.{"/_cleanup="}));
}

test "install directories" {
    const gpa = testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("ProgramFiles", "C:\\Program Files (x86)");
    try env.put("ProgramW6432", "C:\\Program Files");
    try env.put("SystemDrive", "D:");

    const pf = try defaultInstallDir(gpa, .program_files, &env, "Acme\\Widget");
    defer gpa.free(pf);
    try testing.expectEqualStrings("C:\\Program Files\\Acme\\Widget", pf);
    const sd = try defaultInstallDir(gpa, .system_drive, &env, "Tools");
    defer gpa.free(sd);
    try testing.expectEqualStrings("D:\\Tools", sd);
    const pd = try defaultInstallDir(gpa, .program_data, &env, "App");
    defer gpa.free(pd);
    try testing.expectEqualStrings("C:\\ProgramData\\App", pd);

    try testing.expectEqualStrings("Widget", installDirLeaf("Acme\\Widget"));
    const b1 = try browsedInstallDir(gpa, "D:\\Apps", "Widget");
    defer gpa.free(b1);
    try testing.expectEqualStrings("D:\\Apps\\Widget", b1);
    const b2 = try browsedInstallDir(gpa, "D:\\Apps\\widget\\", "Widget");
    defer gpa.free(b2);
    try testing.expectEqualStrings("D:\\Apps\\widget", b2);
    const b3 = try browsedInstallDir(gpa, "E:\\", "Widget");
    defer gpa.free(b3);
    try testing.expectEqualStrings("E:\\Widget", b3);

    try testing.expect(isValidInstallDir("C:\\Program Files\\App"));
    try testing.expect(isValidInstallDir("d:/apps/app/"));
    try testing.expect(isValidInstallDir("\\\\server\\share\\App"));
    try testing.expect(!isValidInstallDir("App"));
    try testing.expect(!isValidInstallDir("C:App"));
    try testing.expect(!isValidInstallDir("C:\\a\\..\\b"));
    try testing.expect(!isValidInstallDir("C:\\a\\\\b"));
    try testing.expect(!isValidInstallDir("C:\\what?"));
    try testing.expect(!isValidInstallDir(" C:\\x"));
    try testing.expect(!isValidInstallDir("\\\\server"));
}

test "volumeRoot" {
    try testing.expectEqualStrings("C:\\", volumeRoot("C:\\Program Files\\App").?);
    try testing.expectEqualStrings("\\\\srv\\share\\", volumeRoot("\\\\srv\\share\\App").?);
    try testing.expect(volumeRoot("\\\\srv\\share") == null);
    try testing.expect(volumeRoot("App") == null);
}

test "formatSize and crlf" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("512 bytes", formatSize(&buf, 512));
    try testing.expectEqualStrings("1.5 KB", formatSize(&buf, 1536));
    try testing.expectEqualStrings("24.0 MB", formatSize(&buf, 24 * 1024 * 1024));
    const gpa = testing.allocator;
    const t = try crlf(gpa, "a\nb\r\nc\n");
    defer gpa.free(t);
    try testing.expectEqualStrings("a\r\nb\r\nc\r\n", t);
}

test "uninstall.exe uninstalls by default" {
    try testing.expectEqual(Command.Action.uninstall, defaultAction("C:\\Program Files\\App\\uninstall.exe"));
    try testing.expectEqual(Command.Action.uninstall, defaultAction("C:\\Program Files\\App\\UNINSTALL.EXE"));
    try testing.expectEqual(Command.Action.uninstall, defaultAction("uninstall.exe"));
    try testing.expectEqual(Command.Action.install, defaultAction("C:\\Users\\me\\Downloads\\app-1.0.0-windows-x86_64-setup.exe"));
    try testing.expectEqual(Command.Action.install, defaultAction("C:\\uninstall.exe\\setup.exe"));
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

    // Other entries, empty ones included, are left exactly as they were.
    const kept = (try pathRemove(gpa, "C:\\A;;C:\\App;C:\\B;", "C:\\App")).?;
    defer gpa.free(kept);
    try testing.expectEqualStrings("C:\\A;;C:\\B;", kept);
}

test "path changes on install and upgrade" {
    // Fresh install.
    try testing.expectEqual(PathChange{ .add = true }, planPathChange(null, false, "C:\\App", true));
    try testing.expectEqual(PathChange{}, planPathChange(null, false, "C:\\App", false));
    // Upgrade in place, still wanted: the entry stays ours.
    try testing.expectEqual(PathChange{ .add = true, .keep_ownership = true }, planPathChange("C:\\App", true, "c:\\app\\", true));
    // Upgrade in place, now unticked: our entry goes.
    const unticked = planPathChange("C:\\App", true, "C:\\App", false);
    try testing.expectEqualStrings("C:\\App", unticked.remove.?);
    try testing.expect(!unticked.add);
    // Upgrade to another folder: the old entry goes, the new one is added.
    const moved = planPathChange("C:\\Old", true, "C:\\New", true);
    try testing.expectEqualStrings("C:\\Old", moved.remove.?);
    try testing.expect(moved.add and !moved.keep_ownership);
    // The earlier installation did not add the entry (the user did): never
    // remove it.
    try testing.expectEqual(PathChange{}, planPathChange("C:\\App", false, "C:\\App", false));
}

test "newer installed versions" {
    try testing.expect(isNewerVersion("2.0.0", "1.9.9"));
    try testing.expect(isNewerVersion("1.0.0", "1.0.0-rc.1"));
    try testing.expect(!isNewerVersion("1.0.0", "1.0.0"));
    try testing.expect(!isNewerVersion("1.0.0-rc.1", "1.0.0"));
    try testing.expect(!isNewerVersion("garbage", "1.0.0"));
}

test "manifest parsing skips unsafe lines" {
    const gpa = testing.allocator;
    const paths = try manifestPaths(gpa, "app.exe\r\ndocs/readme.txt\n\n../evil\n");
    defer gpa.free(paths);
    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expectEqualStrings("docs/readme.txt", paths[1]);
}

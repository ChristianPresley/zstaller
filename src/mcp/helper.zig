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

//! `zstaller-mcp`: installed next to an application that is an MCP server
//! (`Options.mcp`), it registers the server with the AI tools of the user
//! who runs it, and removes it again. The installers run it: as the user
//! who installs (`register`), and when uninstalling (`unregister
//! --all-users`, as administrator or root, for every profile on the
//! machine). Users can run it themselves too.
//!
//! The server is described by the `config` module zstaller builds it with.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");
const registrar = @import("registrar.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Client = registrar.Client;

const os: registrar.Os = if (builtin.os.tag == .windows) .windows else .linux;

/// The clients to register with, from the build.
const clients: []const Client = blk: {
    var list: [config.client_names.len]Client = undefined;
    for (config.client_names, &list) |n, *c| c.* = @field(Client, n);
    const final = list;
    break :blk &final;
};

const usage =
    \\Usage: zstaller-mcp <command>
    \\
    \\Registers the {s} MCP server ({s}) with your AI tools:
    \\{s}.
    \\
    \\Commands:
    \\  register                 add it for the current user
    \\  unregister               remove it for the current user
    \\  unregister --all-users   remove it for every user (as administrator or root)
    \\  status                   show where it is registered
    \\
    \\Only entries that run this installation's program are changed or removed.
    \\
;

pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    const a = init.arena.allocator();
    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const args = init.minimal.args.toSlice(a) catch return 1;
    const command = if (args.len >= 2) args[1] else "";
    const all_users = args.len == 3 and std.mem.eql(u8, args[2], "--all-users");
    if (args.len > 3 or (args.len == 3 and !all_users)) return printUsage(out, a);

    const server: registrar.Server = .{
        .name = config.name,
        .command = programPath(io, a) catch |err| {
            out.print("zstaller-mcp: cannot find the installed program: {t}\n", .{err}) catch {};
            return 1;
        },
        .args = config.args,
        .env = blk: {
            const env = a.alloc([2][]const u8, config.env_names.len) catch return 1;
            for (env, config.env_names, config.env_values) |*e, n, v| e.* = .{ n, v };
            break :blk env;
        },
    };

    if (std.mem.eql(u8, command, "register") and !all_users) {
        const p = currentProfile(init, a) catch |err| return noProfile(out, err);
        return run(io, a, out, .register, server, p, null);
    } else if (std.mem.eql(u8, command, "unregister")) {
        if (!all_users) {
            const p = currentProfile(init, a) catch |err| return noProfile(out, err);
            return run(io, a, out, .unregister, server, p, null);
        }
        const profiles = allProfiles(io, a) catch |err| {
            out.print("zstaller-mcp: cannot list the users' profiles: {t}\n", .{err}) catch {};
            return 1;
        };
        var code: u8 = 0;
        for (profiles) |p| {
            out.print("{s}:\n", .{p.home}) catch {};
            code |= run(io, a, out, .unregister, server, p, keepOwner);
        }
        return code;
    } else if (std.mem.eql(u8, command, "status") and !all_users) {
        const p = currentProfile(init, a) catch |err| return noProfile(out, err);
        return status(io, a, out, server, p);
    }
    return printUsage(out, a);
}

fn printUsage(out: *Io.Writer, a: Allocator) u8 {
    var list: std.ArrayList(u8) = .empty;
    for (clients, 0..) |c, i| {
        if (i > 0) list.appendSlice(a, if (i + 1 == clients.len) " and " else ", ") catch {};
        list.appendSlice(a, c.label()) catch {};
    }
    out.print(usage, .{ config.display_name, config.name, list.items }) catch {};
    return 2;
}

fn noProfile(out: *Io.Writer, err: anyerror) u8 {
    out.print("zstaller-mcp: cannot find your profile folder: {t}\n", .{err}) catch {};
    return 1;
}

/// Registers or unregisters with each client; 0 when nothing failed.
fn run(io: Io, a: Allocator, out: *Io.Writer, op: registrar.Operation, server: registrar.Server, p: registrar.Profile, fixup: ?registrar.Fixup) u8 {
    var code: u8 = 0;
    for (clients) |client| {
        const outcome = registrar.apply(io, a, op, client, server, os, p, fixup) catch |err| {
            const loc = registrar.location(a, client, os, p) catch return 1;
            out.print("  {s}: failed to update {s}: {t}\n", .{ client.label(), loc.file, err }) catch {};
            code = 1;
            continue;
        };
        const loc = registrar.location(a, client, os, p) catch return 1;
        (switch (outcome) {
            .registered => out.print("  {s}: registered in {s}{s}\n", .{ client.label(), loc.file, restartNote(client) }),
            .unchanged => out.print("  {s}: already registered in {s}\n", .{ client.label(), loc.file }),
            .name_taken => out.print("  {s}: skipped, {s} already has a different server named '{s}'\n", .{ client.label(), loc.file, server.name }),
            .not_installed => out.print("  {s}: not installed\n", .{client.label()}),
            .removed => out.print("  {s}: removed from {s}\n", .{ client.label(), loc.file }),
            .absent => out.print("  {s}: not registered\n", .{client.label()}),
            .unreadable => out.print("  {s}: skipped, {s} is not valid JSON\n", .{ client.label(), loc.file }),
        }) catch {};
    }
    return code;
}

fn restartNote(client: Client) []const u8 {
    return switch (client) {
        .claude_desktop => " (restart Claude Desktop to use it)",
        else => "",
    };
}

fn status(io: Io, a: Allocator, out: *Io.Writer, server: registrar.Server, p: registrar.Profile) u8 {
    out.print("{s} ({s}) runs {s}\n", .{ config.display_name, server.name, server.command }) catch {};
    for (clients) |client| {
        const loc = registrar.location(a, client, os, p) catch return 1;
        const text = Io.Dir.cwd().readFileAlloc(io, loc.file, a, .limited(64 * 1024 * 1024)) catch |err| {
            const installed = if (Io.Dir.cwd().access(io, loc.marker, .{})) true else |_| false;
            out.print("  {s}: {s}\n", .{ client.label(), if (err == error.FileNotFound and !installed) "not installed" else "not registered" }) catch {};
            continue;
        };
        const value = registrar.jsonc.get(text, client.containerKey(), server.name) catch {
            out.print("  {s}: {s} is not valid JSON\n", .{ client.label(), loc.file }) catch {};
            continue;
        };
        const what = if (value) |v|
            if (registrar.isOurs(a, v, server.command, os))
                "registered"
            else if (registrar.leftBehind(io, a, text, client, server, os))
                "left behind by an earlier installation; run register to fix it"
            else
                "a different server has the name"
        else
            "not registered";
        out.print("  {s}: {s} ({s})\n", .{ client.label(), what, loc.file }) catch {};
    }
    return 0;
}

/// The installed program: next to this one on Windows, where the
/// installer put it on Linux.
fn programPath(io: Io, a: Allocator) ![]const u8 {
    if (!config.program_relative) return config.program;
    const dir = try std.process.executableDirPathAlloc(io, a);
    return std.fs.path.join(a, &.{ dir, config.program });
}

fn currentProfile(init: std.process.Init, a: Allocator) !registrar.Profile {
    if (builtin.os.tag == .windows) return .{
        .home = try knownFolder(a, &win.FOLDERID_Profile),
        .config = try knownFolder(a, &win.FOLDERID_RoamingAppData),
    };
    const home = init.environ_map.get("HOME") orelse return error.NoHome;
    // `sudo -u` can pass the caller's XDG_CONFIG_HOME through, which
    // would put this user's entries in someone else's files: use it only
    // when it is this user's own folder.
    const xdg = init.environ_map.get("XDG_CONFIG_HOME");
    return .{
        .home = home,
        .config = if (xdg != null and std.fs.path.isAbsolute(xdg.?) and ownedByCaller(xdg.?)) xdg.? else try std.fs.path.join(a, &.{ home, ".config" }),
    };
}

fn ownedByCaller(path: []const u8) bool {
    const linux = std.os.linux;
    var st: linux.Statx = undefined;
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= path_buf.len) return false;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    if (linux.errno(linux.statx(linux.AT.FDCWD, path_buf[0..path.len :0], 0, .{ .UID = true }, &st)) != .SUCCESS) return false;
    return st.uid == linux.getuid();
}

/// Every user profile on the machine.
fn allProfiles(io: Io, a: Allocator) ![]const registrar.Profile {
    var list: std.ArrayList(registrar.Profile) = .empty;
    if (builtin.os.tag == .windows) {
        for (try win.profileFolders(a)) |home| {
            Io.Dir.cwd().access(io, home, .{}) catch continue;
            try list.append(a, .{ .home = home, .config = try std.fs.path.join(a, &.{ home, "AppData", "Roaming" }) });
        }
        return list.items;
    }
    // Home folders from /etc/passwd. Programs installed in /usr/bin are
    // registered by path, so whichever user did it, the entry is ours.
    const passwd = try Io.Dir.cwd().readFileAlloc(io, "/etc/passwd", a, .limited(16 * 1024 * 1024));
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var lines = std.mem.splitScalar(u8, passwd, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        var i: usize = 0;
        var home: []const u8 = "";
        while (fields.next()) |f| : (i += 1) if (i == 5) {
            home = f;
        };
        if (home.len < 2 or home[0] != '/' or seen.contains(home)) continue;
        Io.Dir.cwd().access(io, home, .{}) catch continue;
        try seen.put(a, home, {});
        try list.append(a, .{ .home = home, .config = try std.fs.path.join(a, &.{ home, ".config" }) });
    }
    return list.items;
}

/// Gives a rewritten file the owner of the one it replaces: when root
/// edits a user's file, the user keeps it.
fn keepOwner(io: Io, file: Io.File, original_path: []const u8) void {
    if (builtin.os.tag != .linux) return;
    const linux = std.os.linux;
    var st: linux.Statx = undefined;
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (original_path.len >= path_buf.len) return;
    @memcpy(path_buf[0..original_path.len], original_path);
    path_buf[original_path.len] = 0;
    if (linux.errno(linux.statx(linux.AT.FDCWD, path_buf[0..original_path.len :0], 0, .{ .UID = true, .GID = true }, &st)) != .SUCCESS) return;
    file.setOwner(io, st.uid, st.gid) catch {};
}

fn knownFolder(a: Allocator, id: *const std.os.windows.GUID) ![]const u8 {
    var path: ?[*:0]u16 = null;
    if (win.SHGetKnownFolderPath(id, 0, null, &path) != 0) return error.NoProfileFolder;
    defer win.CoTaskMemFree(path);
    return std.unicode.wtf16LeToWtf8Alloc(a, std.mem.span(path.?));
}

const win = struct {
    const windows = std.os.windows;
    const HKEY = windows.HKEY;
    const DWORD = windows.DWORD;
    const KEY_READ: DWORD = 0x20019;
    const KEY_WOW64_64KEY: DWORD = 0x0100;

    const FOLDERID_Profile = windows.GUID.parse("{5E6C858F-0E22-4760-9AFE-EA3317B67173}");
    const FOLDERID_RoamingAppData = windows.GUID.parse("{3EB685DB-65F9-4CF6-A03A-E3EF65729F3D}");

    extern "shell32" fn SHGetKnownFolderPath(rfid: *const windows.GUID, flags: DWORD, token: ?windows.HANDLE, path: *?[*:0]u16) callconv(.winapi) i32;
    extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.winapi) void;
    extern "advapi32" fn RegOpenKeyExW(key: HKEY, sub_key: [*:0]const u16, options: DWORD, sam: DWORD, result: *HKEY) callconv(.winapi) windows.LSTATUS;
    extern "advapi32" fn RegEnumKeyExW(key: HKEY, index: DWORD, name: [*]u16, name_len: *DWORD, reserved: ?*DWORD, class: ?[*]u16, class_len: ?*DWORD, last_write: ?*windows.FILETIME) callconv(.winapi) windows.LSTATUS;
    extern "advapi32" fn RegQueryValueExW(key: HKEY, name: [*:0]const u16, reserved: ?*DWORD, kind: ?*DWORD, data: ?[*]u8, data_len: ?*DWORD) callconv(.winapi) windows.LSTATUS;
    extern "advapi32" fn RegCloseKey(key: HKEY) callconv(.winapi) windows.LSTATUS;
    extern "kernel32" fn ExpandEnvironmentStringsW(src: [*:0]const u16, dst: ?[*]u16, size: DWORD) callconv(.winapi) DWORD;

    /// The profile folders of the machine's users, from the registry.
    /// Built-in service accounts (S-1-5-18, -19, -20) are skipped.
    fn profileFolders(a: Allocator) ![]const []const u8 {
        const list_w = std.unicode.utf8ToUtf16LeStringLiteral("SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\ProfileList");
        var list: HKEY = undefined;
        if (RegOpenKeyExW(windows.HKEY_LOCAL_MACHINE, list_w, 0, KEY_READ | KEY_WOW64_64KEY, &list) != 0) return error.NoProfileList;
        defer _ = RegCloseKey(list);
        var out: std.ArrayList([]const u8) = .empty;
        var index: DWORD = 0;
        while (true) : (index += 1) {
            var name: [256:0]u16 = undefined;
            var name_len: DWORD = name.len;
            if (RegEnumKeyExW(list, index, &name, &name_len, null, null, null, null) != 0) break;
            name[name_len] = 0;
            const sid = name[0..name_len];
            if (!std.mem.startsWith(u16, sid, std.unicode.utf8ToUtf16LeStringLiteral("S-1-5-21-")) and
                !std.mem.startsWith(u16, sid, std.unicode.utf8ToUtf16LeStringLiteral("S-1-12-1-"))) continue;
            var key: HKEY = undefined;
            if (RegOpenKeyExW(list, name[0..name_len :0], 0, KEY_READ | KEY_WOW64_64KEY, &key) != 0) continue;
            defer _ = RegCloseKey(key);
            var raw: [1024]u16 = undefined;
            var raw_len: DWORD = (raw.len - 1) * 2;
            if (RegQueryValueExW(key, std.unicode.utf8ToUtf16LeStringLiteral("ProfileImagePath"), null, null, @ptrCast(&raw), &raw_len) != 0) continue;
            const chars = raw_len / 2;
            raw[chars] = 0;
            const raw_z: [*:0]const u16 = raw[0..chars :0];
            var expanded: [1024]u16 = undefined;
            const n = ExpandEnvironmentStringsW(raw_z, &expanded, expanded.len);
            if (n == 0 or n > expanded.len) continue;
            try out.append(a, try std.unicode.wtf16LeToWtf8Alloc(a, std.mem.sliceTo(&expanded, 0)));
        }
        return out.items;
    }
};

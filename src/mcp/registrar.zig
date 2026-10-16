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

//! Registers an installed MCP server with the AI tools of one user, and
//! removes it again: Claude Code, VS Code, Claude Desktop, Cursor and
//! Windsurf each keep their servers in a JSON file in the user's profile.
//!
//! An entry is ours when its `command` is the installed program. Only our
//! entries are replaced or removed, so a server the user set up under the
//! same name is left alone. Files are changed in place (see jsonc.zig),
//! written to a temporary file and renamed over the original, with the
//! previous version kept as `<file>.zstaller.bak`.

const std = @import("std");
pub const jsonc = @import("jsonc.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Client = enum {
    claude_code,
    vscode,
    vscode_insiders,
    claude_desktop,
    cursor,
    windsurf,

    pub fn label(c: Client) []const u8 {
        return switch (c) {
            .claude_code => "Claude Code",
            .vscode => "VS Code",
            .vscode_insiders => "VS Code Insiders",
            .claude_desktop => "Claude Desktop",
            .cursor => "Cursor",
            .windsurf => "Windsurf",
        };
    }

    /// The member of the file's top-level object that holds the servers.
    pub fn containerKey(c: Client) []const u8 {
        return switch (c) {
            .vscode, .vscode_insiders => "servers",
            else => "mcpServers",
        };
    }
};

pub const Os = enum { windows, linux };

/// Where a user's files are.
pub const Profile = struct {
    /// The home folder (`%USERPROFILE%`, `$HOME`).
    home: []const u8,
    /// Per-user settings: `%APPDATA%` on Windows, `$XDG_CONFIG_HOME` (by
    /// default `~/.config`) on Linux.
    config: []const u8,
};

pub const Location = struct {
    /// The client's MCP configuration file.
    file: []const u8,
    /// The client counts as installed when this exists. The file is only
    /// ever created inside an existing folder of the client's.
    marker: []const u8,
};

pub fn location(gpa: Allocator, client: Client, os: Os, p: Profile) Allocator.Error!Location {
    const sep: u8 = if (os == .windows) '\\' else '/';
    const join = struct {
        fn join(a: Allocator, s: u8, parts: []const []const u8) Allocator.Error![]const u8 {
            var out: std.ArrayList(u8) = .empty;
            for (parts, 0..) |part, i| {
                if (i > 0) try out.append(a, s);
                for (part) |c| try out.append(a, if (c == '/' or c == '\\') s else c);
            }
            return out.toOwnedSlice(a);
        }
    }.join;
    return switch (client) {
        // Claude Code keeps its settings in ~/.claude and its MCP servers
        // in ~/.claude.json.
        .claude_code => .{ .file = try join(gpa, sep, &.{ p.home, ".claude.json" }), .marker = try join(gpa, sep, &.{ p.home, ".claude" }) },
        .vscode, .vscode_insiders => blk: {
            const app = if (client == .vscode) "Code" else "Code - Insiders";
            break :blk .{ .file = try join(gpa, sep, &.{ p.config, app, "User/mcp.json" }), .marker = try join(gpa, sep, &.{ p.config, app, "User" }) };
        },
        .claude_desktop => .{ .file = try join(gpa, sep, &.{ p.config, "Claude/claude_desktop_config.json" }), .marker = try join(gpa, sep, &.{ p.config, "Claude" }) },
        .cursor => .{ .file = try join(gpa, sep, &.{ p.home, ".cursor/mcp.json" }), .marker = try join(gpa, sep, &.{ p.home, ".cursor" }) },
        .windsurf => .{ .file = try join(gpa, sep, &.{ p.home, ".codeium/windsurf/mcp_config.json" }), .marker = try join(gpa, sep, &.{ p.home, ".codeium/windsurf" }) },
    };
}

pub const Server = struct {
    name: []const u8,
    /// The installed program, as an absolute path.
    command: []const u8,
    args: []const []const u8,
    env: []const [2][]const u8,
};

/// The entry for `server` in `client`'s file, as JSON on one line.
pub fn entry(gpa: Allocator, client: Client, server: Server) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    write(&s, client, server) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn write(s: *std.json.Stringify, client: Client, server: Server) std.Io.Writer.Error!void {
    try s.beginObject();
    switch (client) {
        .claude_code, .vscode, .vscode_insiders => {
            try s.objectField("type");
            try s.write("stdio");
        },
        else => {},
    }
    try s.objectField("command");
    try s.write(server.command);
    try s.objectField("args");
    try s.write(server.args);
    if (server.env.len > 0) {
        try s.objectField("env");
        try s.beginObject();
        for (server.env) |e| {
            try s.objectField(e[0]);
            try s.write(e[1]);
        }
        try s.endObject();
    }
    try s.endObject();
}

/// Whether the entry `value` (JSON text) runs `command`. Paths compare
/// as Windows compares them on Windows.
pub fn isOurs(gpa: Allocator, value: []const u8, command: []const u8, os: Os) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, value, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const cmd = parsed.value.object.get("command") orelse return false;
    if (cmd != .string) return false;
    return samePath(cmd.string, command, os);
}

fn samePath(a: []const u8, b: []const u8, os: Os) bool {
    if (os == .linux) return std.mem.eql(u8, a, b);
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const nx = if (x == '/') '\\' else std.ascii.toLower(x);
        const ny = if (y == '/') '\\' else std.ascii.toLower(y);
        if (nx != ny) return false;
    }
    return true;
}

/// What to do with a file: write the new text, or keep it for a reason.
pub const Change = union(enum) { write: []u8, keep: Outcome };

pub const Outcome = enum {
    /// Added, or an older entry of ours was brought up to date.
    registered,
    /// Our entry was already there as it should be.
    unchanged,
    /// Another server already uses the name; left alone.
    name_taken,
    /// The client is not installed for this user.
    not_installed,
    /// Removed our entry.
    removed,
    /// There was no entry of ours to remove.
    absent,
    /// The file could not be read as JSON; left alone.
    unreadable,
};

/// The new text for registering, or null with the reason to leave the
/// file as it is.
pub fn registerText(gpa: Allocator, text: []const u8, client: Client, server: Server, os: Os) Allocator.Error!Change {
    const value = try entry(gpa, client, server);
    defer gpa.free(value);
    const key = client.containerKey();
    const existing = jsonc.get(text, key, server.name) catch return .{ .keep = .unreadable };
    if (existing) |old| {
        if (!isOurs(gpa, old, server.command, os)) return .{ .keep = .name_taken };
        if (std.mem.eql(u8, old, value)) return .{ .keep = .unchanged };
    }
    const new = jsonc.set(gpa, text, key, server.name, value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .keep = .unreadable },
    };
    return .{ .write = new };
}

/// The new text for unregistering, or null with the reason to leave the
/// file as it is.
pub fn unregisterText(gpa: Allocator, text: []const u8, client: Client, server: Server, os: Os) Allocator.Error!Change {
    const key = client.containerKey();
    const existing = (jsonc.get(text, key, server.name) catch return .{ .keep = .unreadable }) orelse return .{ .keep = .absent };
    if (!isOurs(gpa, existing, server.command, os)) return .{ .keep = .absent };
    const new = (jsonc.remove(gpa, text, key, server.name) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .keep = .unreadable },
    }) orelse return .{ .keep = .absent };
    return .{ .write = new };
}

pub const Operation = enum { register, unregister };

/// Called with the file's previous permissions before the new one takes
/// its place, so it can be given the same owner (see `apply`).
pub const Fixup = *const fn (io: Io, file: Io.File, original_path: []const u8) void;

/// Registers or unregisters `server` in `client`'s file for profile `p`.
pub fn apply(io: Io, gpa: Allocator, op: Operation, client: Client, server: Server, os: Os, p: Profile, fixup: ?Fixup) !Outcome {
    const loc = try location(gpa, client, os, p);
    defer gpa.free(loc.file);
    defer gpa.free(loc.marker);
    const cwd = Io.Dir.cwd();
    // A file kept elsewhere and linked here (as dotfile managers do) is
    // changed where it is, and the link stays.
    const real = cwd.realPathFileAlloc(io, loc.file, gpa) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| return e,
    };
    defer if (real) |r| gpa.free(r);
    const path: []const u8 = if (real) |r| r else loc.file;

    var stat: ?Io.File.Stat = null;
    const text: []u8 = if (real != null) blk: {
        const f = try cwd.openFile(io, path, .{});
        defer f.close(io);
        stat = try f.stat(io);
        var buf: [4096]u8 = undefined;
        var r = f.reader(io, &buf);
        break :blk try r.interface.allocRemaining(gpa, .limited(64 * 1024 * 1024));
    } else blk: {
        if (op == .unregister) return .absent;
        cwd.access(io, loc.marker, .{}) catch return .not_installed;
        break :blk try gpa.dupe(u8, "");
    };
    defer gpa.free(text);

    const result = switch (op) {
        .register => try registerText(gpa, text, client, server, os),
        .unregister => try unregisterText(gpa, text, client, server, os),
    };
    const new = switch (result) {
        .keep => |o| return o,
        .write => |t| t,
    };
    defer gpa.free(new);

    const dir_path = std.fs.path.dirname(path) orelse return error.FileNotFound;
    const base = std.fs.path.basename(path);
    var dir = try cwd.openDir(io, dir_path, .{});
    defer dir.close(io);
    if (stat != null) {
        const bak = try std.fmt.allocPrint(gpa, "{s}.zstaller.bak", .{base});
        defer gpa.free(bak);
        try writeReplacing(io, dir, bak, text, stat, path, fixup);
    }
    try writeReplacing(io, dir, base, new, stat, path, fixup);
    return switch (op) {
        .register => .registered,
        .unregister => .removed,
    };
}

/// Writes `data` to `name` in `dir` through a temporary file, with the
/// permissions of the file it replaces.
fn writeReplacing(io: Io, dir: Io.Dir, name: []const u8, data: []const u8, like: ?Io.File.Stat, original_path: []const u8, fixup: ?Fixup) !void {
    var af = try dir.createFileAtomic(io, name, .{
        .replace = true,
        .permissions = if (like) |s| s.permissions else .default_file,
    });
    defer af.deinit(io);
    try af.file.writePositionalAll(io, data, 0);
    if (like != null) if (fixup) |f| f(io, af.file, original_path);
    try af.replace(io);
}

const testing = std.testing;

const test_server: Server = .{
    .name = "app",
    .command = "C:\\Program Files\\App\\app.exe",
    .args = &.{"mcp"},
    .env = &.{.{ "APP_LOG", "warn" }},
};

test "entries per client" {
    const cc = try entry(testing.allocator, .claude_code, test_server);
    defer testing.allocator.free(cc);
    try testing.expectEqualStrings(
        \\{"type":"stdio","command":"C:\\Program Files\\App\\app.exe","args":["mcp"],"env":{"APP_LOG":"warn"}}
    , cc);
    const cd = try entry(testing.allocator, .claude_desktop, test_server);
    defer testing.allocator.free(cd);
    try testing.expectEqualStrings(
        \\{"command":"C:\\Program Files\\App\\app.exe","args":["mcp"],"env":{"APP_LOG":"warn"}}
    , cd);
}

test "register adds, updates ours and leaves others alone" {
    const a = testing.allocator;
    const added = (try registerText(a, "{}", .claude_code, test_server, .windows)).write;
    defer a.free(added);
    try testing.expect(std.mem.indexOf(u8, added, "\"app\": {\"type\":\"stdio\"") != null);
    try testing.expectEqual(Outcome.unchanged, (try registerText(a, added, .claude_code, test_server, .windows)).keep);

    // An older entry of ours (different args) is updated, matching the
    // path as Windows does.
    const old = "{\"mcpServers\":{\"app\":{\"command\":\"c:/program files/app/APP.exe\",\"args\":[]}}}";
    const updated = (try registerText(a, old, .claude_code, test_server, .windows)).write;
    defer a.free(updated);
    try testing.expect(std.mem.indexOf(u8, updated, "\"args\":[\"mcp\"]") != null);

    const theirs = "{\"mcpServers\":{\"app\":{\"command\":\"D:\\\\dev\\\\app.exe\"}}}";
    try testing.expectEqual(Outcome.name_taken, (try registerText(a, theirs, .claude_code, test_server, .windows)).keep);
    try testing.expectEqual(Outcome.unreadable, (try registerText(a, "{oops", .claude_code, test_server, .windows)).keep);
}

test "unregister removes only ours" {
    const a = testing.allocator;
    const ours = "{\"servers\":{\"app\":{\"type\":\"stdio\",\"command\":\"C:\\\\Program Files\\\\App\\\\app.exe\"},\"x\":{}}}";
    const removed = (try unregisterText(a, ours, .vscode, test_server, .windows)).write;
    defer a.free(removed);
    try testing.expectEqualStrings("{\"servers\":{\"x\":{}}}", removed);
    const theirs = "{\"servers\":{\"app\":{\"command\":\"D:\\\\app.exe\"}}}";
    try testing.expectEqual(Outcome.absent, (try unregisterText(a, theirs, .vscode, test_server, .windows)).keep);
    try testing.expectEqual(Outcome.absent, (try unregisterText(a, "{}", .vscode, test_server, .windows)).keep);
}

test "locations" {
    const a = testing.allocator;
    const l = try location(a, .vscode, .windows, .{ .home = "C:\\Users\\a", .config = "C:\\Users\\a\\AppData\\Roaming" });
    defer a.free(l.file);
    defer a.free(l.marker);
    try testing.expectEqualStrings("C:\\Users\\a\\AppData\\Roaming\\Code\\User\\mcp.json", l.file);
    const c = try location(a, .claude_code, .linux, .{ .home = "/home/a", .config = "/home/a/.config" });
    defer a.free(c.file);
    defer a.free(c.marker);
    try testing.expectEqualStrings("/home/a/.claude.json", c.file);
    try testing.expectEqualStrings("/home/a/.claude", c.marker);
}

test "apply registers and unregisters in files, keeping a backup" {
    const io = testing.io;
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    try tmp.dir.createDirPath(io, ".claude");
    try tmp.dir.writeFile(io, .{ .sub_path = ".claude.json", .data = "{\n  \"numStartups\": 3\n}\n" });
    const private = Io.File.Permissions.has_executable_bit;
    if (private) {
        const f = try tmp.dir.openFile(io, ".claude.json", .{});
        defer f.close(io);
        try f.setPermissions(io, .fromMode(0o600));
    }
    const server: Server = .{ .name = "app", .command = "/usr/bin/app", .args = &.{}, .env = &.{} };
    const p: Profile = .{ .home = root, .config = root };

    try testing.expectEqual(Outcome.registered, try apply(io, a, .register, .claude_code, server, .linux, p, null));
    try testing.expectEqual(Outcome.unchanged, try apply(io, a, .register, .claude_code, server, .linux, p, null));
    try testing.expectEqual(Outcome.not_installed, try apply(io, a, .register, .cursor, server, .linux, p, null));
    const text = try tmp.dir.readFileAlloc(io, ".claude.json", a, .unlimited);
    defer a.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\"app\": {\"type\":\"stdio\",\"command\":\"/usr/bin/app\",\"args\":[]}") != null);

    try testing.expectEqual(Outcome.removed, try apply(io, a, .unregister, .claude_code, server, .linux, p, null));
    try testing.expectEqual(Outcome.absent, try apply(io, a, .unregister, .claude_code, server, .linux, p, null));
    const back = try tmp.dir.readFileAlloc(io, ".claude.json", a, .unlimited);
    defer a.free(back);
    try testing.expectEqualStrings("{\n  \"mcpServers\": {\n  },\n  \"numStartups\": 3\n}\n", back);
    const bak = try tmp.dir.readFileAlloc(io, ".claude.json.zstaller.bak", a, .unlimited);
    defer a.free(bak);
    try testing.expect(std.mem.indexOf(u8, bak, "/usr/bin/app") != null);
    // A private file stays private, and so does its backup.
    if (private) for ([_][]const u8{ ".claude.json", ".claude.json.zstaller.bak" }) |name| {
        const st = try tmp.dir.statFile(io, name, .{});
        try testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
    };

    // A new file only goes into a folder the client already has.
    try tmp.dir.createDirPath(io, ".cursor");
    try testing.expectEqual(Outcome.registered, try apply(io, a, .register, .cursor, server, .linux, p, null));
    const cursor = try tmp.dir.readFileAlloc(io, ".cursor/mcp.json", a, .unlimited);
    defer a.free(cursor);
    try testing.expectEqualStrings("{\n  \"mcpServers\": {\n    \"app\": {\"command\":\"/usr/bin/app\",\"args\":[]}\n  }\n}\n", cursor);
}

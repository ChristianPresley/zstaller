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

//! zstaller-pack: the host tool that `zig build` runs to assemble
//! installers. It is an internal interface between zstaller's build API and
//! its package writers; its command line is not a stable public API.
//!
//! Commands:
//!   checksum <input> <output> <file-name>
//!   deb      --out <path> [package options] (--file <src> <dest> <mode>)...
//!   payload  --out <path> (--file <src> <dest>)...
//!   msi      --out <path> [package options] (--file <src> <dest>)...

const std = @import("std");
const zstaller = @import("zstaller");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) usage();
    const ctx: Ctx = .{ .gpa = init.gpa, .arena = arena, .io = init.io, .env = init.environ_map };
    const cmd = args[1];
    const rest = args[2..];
    if (std.mem.eql(u8, cmd, "checksum")) {
        try cmdChecksum(ctx, rest);
    } else if (std.mem.eql(u8, cmd, "deb")) {
        try cmdDeb(ctx, rest);
    } else if (std.mem.eql(u8, cmd, "payload")) {
        try cmdPayload(ctx, rest);
    } else if (std.mem.eql(u8, cmd, "msi")) {
        try cmdMsi(ctx, rest);
    } else {
        fail("unknown command '{s}'", .{cmd});
    }
}

const Ctx = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    env: *std.process.Environ.Map,

    fn readFile(ctx: Ctx, path: []const u8) []u8 {
        return Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(4 << 30)) catch |err|
            fail("cannot read '{s}': {t}", .{ path, err });
    }

    fn writeFile(ctx: Ctx, path: []const u8, data: []const u8) void {
        Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = data }) catch |err|
            fail("cannot write '{s}': {t}", .{ path, err });
    }

    /// Timestamp for archive entries: SOURCE_DATE_EPOCH when set, else a
    /// fixed date (1980-01-01), so builds are reproducible by default.
    fn mtime(ctx: Ctx) u64 {
        const s = ctx.env.get("SOURCE_DATE_EPOCH") orelse return default_mtime;
        return std.fmt.parseInt(u64, s, 10) catch fail("SOURCE_DATE_EPOCH is not an integer: '{s}'", .{s});
    }
};

const default_mtime = 315532800;

fn usage() noreturn {
    fail("usage: zstaller-pack <checksum|deb|payload|msi> [options]", .{});
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zstaller-pack: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

/// Simple `--key value` option parser. `--file` takes a fixed number of
/// values and may repeat.
const Options = struct {
    values: std.StringHashMapUnmanaged([]const u8) = .empty,
    files: std.ArrayList([]const []const u8) = .empty,

    fn parse(arena: Allocator, args: []const []const u8, file_arity: usize, allowed: []const []const u8) Options {
        var o: Options = .{};
        var i: usize = 0;
        while (i < args.len) {
            const a = args[i];
            if (std.mem.eql(u8, a, "--file")) {
                if (i + file_arity >= args.len) fail("--file needs {d} values", .{file_arity});
                o.files.append(arena, args[i + 1 ..][0..file_arity]) catch oom();
                i += 1 + file_arity;
                continue;
            }
            if (!std.mem.startsWith(u8, a, "--")) fail("unexpected argument '{s}'", .{a});
            const key = a[2..];
            for (allowed) |k| {
                if (std.mem.eql(u8, k, key)) break;
            } else fail("unknown option '{s}'", .{a});
            if (i + 1 >= args.len) fail("option '{s}' needs a value", .{a});
            o.values.put(arena, key, args[i + 1]) catch oom();
            i += 2;
        }
        return o;
    }

    fn get(o: Options, key: []const u8) ?[]const u8 {
        return o.values.get(key);
    }

    fn required(o: Options, key: []const u8) []const u8 {
        return o.values.get(key) orelse fail("missing required option --{s}", .{key});
    }
};

fn oom() noreturn {
    fail("out of memory", .{});
}

fn cmdChecksum(ctx: Ctx, args: []const []const u8) !void {
    if (args.len != 3) fail("usage: checksum <input> <output> <file-name>", .{});
    const d = zstaller.checksum.digestFile(ctx.io, Io.Dir.cwd(), args[0]) catch |err|
        fail("cannot hash '{s}': {t}", .{ args[0], err });
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    zstaller.checksum.writeLine(&w, d, args[2]) catch fail("file name too long", .{});
    ctx.writeFile(args[1], w.buffered());
}

fn cmdDeb(ctx: Ctx, args: []const []const u8) !void {
    const o = Options.parse(ctx.arena, args, 3, &.{
        "out", "name", "version", "arch", "maintainer", "description", "section", "priority", "homepage", "depends", "license", "copyright",
    });
    const name = o.required("name");
    if (!zstaller.naming.isValidDebPackageName(name))
        fail("'{s}' is not a valid Debian package name (lowercase letters, digits, '+', '-', '.'; at least two characters)", .{name});

    var files: std.ArrayList(zstaller.deb.File) = .empty;
    for (o.files.items) |f| {
        const mode = std.fmt.parseInt(u32, f[2], 8) catch fail("invalid mode '{s}'", .{f[2]});
        files.append(ctx.arena, .{ .path = f[1], .data = ctx.readFile(f[0]), .mode = mode }) catch oom();
    }
    if (o.get("license")) |license| {
        const path = std.fmt.allocPrint(ctx.arena, "/usr/share/doc/{s}/copyright", .{name}) catch oom();
        const text = zstaller.deb.copyrightFile(ctx.arena, name, license, o.get("copyright")) catch oom();
        files.append(ctx.arena, .{ .path = path, .data = text }) catch oom();
    }

    var out: Io.Writer.Allocating = .init(ctx.gpa);
    defer out.deinit();
    zstaller.deb.write(ctx.gpa, &out.writer, .{
        .name = name,
        .version = o.required("version"),
        .architecture = o.required("arch"),
        .maintainer = o.required("maintainer"),
        .description = o.required("description"),
        .section = o.get("section") orelse "utils",
        .priority = o.get("priority") orelse "optional",
        .homepage = o.get("homepage"),
        .depends = o.get("depends"),
        .files = files.items,
        .mtime = ctx.mtime(),
    }) catch |err| fail("cannot build .deb: {t}", .{err});
    ctx.writeFile(o.required("out"), out.written());
}

fn cmdPayload(ctx: Ctx, args: []const []const u8) !void {
    const o = Options.parse(ctx.arena, args, 2, &.{"out"});
    var entries: std.ArrayList(zstaller.exe_payload.Entry) = .empty;
    for (o.files.items) |f| {
        entries.append(ctx.arena, .{ .path = f[1], .data = ctx.readFile(f[0]) }) catch oom();
    }
    const bytes = zstaller.exe_payload.encode(ctx.gpa, entries.items) catch |err| switch (err) {
        error.InvalidPath => fail("payload contains an unsafe install path", .{}),
        else => |e| fail("cannot build payload: {t}", .{e}),
    };
    defer ctx.gpa.free(bytes);
    ctx.writeFile(o.required("out"), bytes);
}

fn cmdMsi(ctx: Ctx, args: []const []const u8) !void {
    const msi = zstaller.msi.package;
    const o = Options.parse(ctx.arena, args, 2, &.{
        "out",           "name",            "version", "manufacturer", "description", "upgrade-code", "platform", "install-dir", "add-to-path", "license", "icon",
        "shortcut-name", "shortcut-target",
    });
    var files: std.ArrayList(msi.File) = .empty;
    for (o.files.items) |f| {
        files.append(ctx.arena, .{ .path = f[1], .data = ctx.readFile(f[0]) }) catch oom();
    }
    const platform_arg = o.required("platform");
    const path_arg = o.get("add-to-path") orelse "never";
    var out: Io.Writer.Allocating = .init(ctx.gpa);
    defer out.deinit();
    msi.write(ctx.gpa, &out.writer, .{
        .name = o.required("name"),
        .version = o.required("version"),
        .manufacturer = o.required("manufacturer"),
        .description = o.required("description"),
        .upgrade_code = o.required("upgrade-code"),
        .platform = msi.Platform.parse(platform_arg) orelse fail("unknown platform '{s}'", .{platform_arg}),
        .install_dir = o.required("install-dir"),
        .add_to_path = std.meta.stringToEnum(msi.PathMode, path_arg) orelse fail("invalid --add-to-path '{s}'", .{path_arg}),
        .icon = if (o.get("icon")) |path| ctx.readFile(path) else null,
        .shortcut = if (o.get("shortcut-name")) |name| .{ .name = name, .target = o.required("shortcut-target") } else null,
        .files = files.items,
        .timestamp = ctx.mtime(),
    }) catch |err| switch (err) {
        error.NotRepresentable => fail("MSI strings must use characters from Windows-1252", .{}),
        error.InvalidShortcut => fail("the Start Menu shortcut name is invalid or its target is not an installed file", .{}),
        else => |e| fail("cannot build MSI: {t}", .{e}),
    };
    ctx.writeFile(o.required("out"), out.written());
}

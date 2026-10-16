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
//!   checksum     <input> <output> <file-name>
//!   deb          --out <path> --mtime <secs> [package options] (--file <src> <dest> <mode>)...
//!   payload      --out <path> (--file <src> <dest>)...
//!   wizard       --out <path> [--banner <img>] [--welcome <img>] [--license <txt>]
//!   msi          --out <path> --mtime <secs> [package options] (--file <src> <dest>)...
//!   pe-normalize <input> <output>
//!
//! Every input, including the timestamp, is a command-line argument, so the
//! build system's cache key covers it. The tool does not read the
//! environment.

const std = @import("std");
const zstaller = @import("zstaller");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) usage();
    const ctx: Ctx = .{ .gpa = init.gpa, .arena = arena, .io = init.io };
    const cmd = args[1];
    const rest = args[2..];
    if (std.mem.eql(u8, cmd, "checksum")) {
        try cmdChecksum(ctx, rest);
    } else if (std.mem.eql(u8, cmd, "deb")) {
        try cmdDeb(ctx, rest);
    } else if (std.mem.eql(u8, cmd, "payload")) {
        try cmdPayload(ctx, rest);
    } else if (std.mem.eql(u8, cmd, "wizard")) {
        try cmdWizard(ctx, rest);
    } else if (std.mem.eql(u8, cmd, "msi")) {
        try cmdMsi(ctx, rest);
    } else if (std.mem.eql(u8, cmd, "exe-assemble")) {
        cmdExeAssemble(ctx, rest);
    } else if (std.mem.eql(u8, cmd, "check-icon")) {
        cmdCheckIcon(ctx, rest);
    } else if (std.mem.eql(u8, cmd, "pe-normalize")) {
        try cmdPeNormalize(ctx, rest);
    } else {
        fail("unknown command '{s}'", .{cmd});
    }
}

const Ctx = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,

    fn readFile(ctx: Ctx, path: []const u8) []u8 {
        return Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(4 << 30)) catch |err|
            fail("cannot read '{s}': {t}", .{ path, err });
    }

    fn writeFile(ctx: Ctx, path: []const u8, data: []const u8) void {
        Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = data }) catch |err|
            fail("cannot write '{s}': {t}", .{ path, err });
    }
};

fn usage() noreturn {
    fail("usage: zstaller-pack <checksum|deb|payload|wizard|msi|exe-assemble|check-icon|pe-normalize> [options]", .{});
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

    /// `--mtime`: seconds since the Unix epoch for every timestamp written
    /// into the package.
    fn mtime(o: Options) u64 {
        const s = o.required("mtime");
        return std.fmt.parseInt(u64, s, 10) catch fail("--mtime is not an integer: '{s}'", .{s});
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
        "out", "mtime", "name", "version", "arch", "maintainer", "description", "section", "priority", "homepage", "depends", "license", "copyright",
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
        .mtime = o.mtime(),
    }) catch |err| fail("cannot build .deb: {t}", .{err});
    ctx.writeFile(o.required("out"), out.written());
}

/// `exe-assemble <stub> <payload> <out>`: appends the payload to the
/// linked setup program as an overlay.
fn cmdExeAssemble(ctx: Ctx, args: []const []const u8) void {
    if (args.len != 3) fail("usage: zstaller-pack exe-assemble <stub> <payload> <out>", .{});
    const out = zstaller.exe_overlay.append(ctx.arena, ctx.readFile(args[0]), ctx.readFile(args[1])) catch oom();
    ctx.writeFile(args[2], out);
}

/// `check-icon <in> <label> <out>`: copies a Windows .ico file, failing
/// with a message naming `label` when it is not one.
fn cmdCheckIcon(ctx: Ctx, args: []const []const u8) void {
    if (args.len != 3) fail("usage: zstaller-pack check-icon <in> <label> <out>", .{});
    const data = ctx.readFile(args[0]);
    if (zstaller.image.icoProblem(data)) |problem|
        fail("icon '{s}' is not a Windows .ico file: {s}. Convert it, for example with ImageMagick: magick app.png -define icon:auto-resize=256,48,32,16 app.ico", .{ args[1], problem });
    ctx.writeFile(args[2], data);
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

fn cmdWizard(ctx: Ctx, args: []const []const u8) !void {
    const assets = zstaller.wizard_assets;
    const o = Options.parse(ctx.arena, args, 0, &.{ "out", "banner", "welcome", "license", "banner-option", "welcome-option" });
    var entries: std.ArrayList(zstaller.exe_payload.Entry) = .empty;
    inline for (.{ assets.Kind.banner, assets.Kind.welcome }) |kind| {
        if (o.get(@tagName(kind))) |path| {
            const option = o.get(@tagName(kind) ++ "-option") orelse @tagName(kind);
            const size = kind.size();
            const data = assets.encodeImage(ctx.arena, kind, ctx.readFile(path)) catch |err| switch (err) {
                error.WrongSize => {
                    const img = zstaller.image.decode(ctx.arena, ctx.readFile(path)) catch unreachable;
                    fail("{s} must be {d}x{d} pixels, or {d}x{d} for high-DPI displays, but '{s}' is {d}x{d}", .{
                        option, size[0], size[1], size[0] * 2, size[1] * 2, path, img.width, img.height,
                    });
                },
                error.UnknownFormat => fail("{s}: '{s}' is not a PNG or BMP file", .{ option, path }),
                error.InterlacedPng => fail("{s}: '{s}' is an interlaced PNG; save it without interlacing", .{ option, path }),
                error.UnsupportedImage => fail("{s}: '{s}' uses an unsupported BMP or PNG variant; save it as a standard 24- or 32-bit PNG or BMP", .{ option, path }),
                error.TooLarge => fail("{s}: '{s}' is too large", .{ option, path }),
                error.InvalidImage => fail("{s}: '{s}' is not a valid image file", .{ option, path }),
                error.OutOfMemory => oom(),
            };
            entries.append(ctx.arena, .{ .path = kind.entryName(), .data = data }) catch oom();
        }
    }
    if (o.get("license")) |path| {
        const text = ctx.readFile(path);
        if (!std.unicode.utf8ValidateSlice(text)) fail("license_file: '{s}' is not UTF-8 text", .{path});
        // Drop a UTF-8 byte order mark.
        const body = if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text[3..] else text;
        entries.append(ctx.arena, .{ .path = assets.license_entry, .data = body }) catch oom();
    }
    const bytes = zstaller.exe_payload.encode(ctx.gpa, entries.items) catch |err| fail("cannot build wizard assets: {t}", .{err});
    defer ctx.gpa.free(bytes);
    ctx.writeFile(o.required("out"), bytes);
}

fn cmdMsi(ctx: Ctx, args: []const []const u8) !void {
    const msi = zstaller.msi.package;
    const o = Options.parse(ctx.arena, args, 2, &.{
        "out",           "mtime",           "name",         "version",    "manufacturer",     "description", "upgrade-code", "platform", "install-dir", "add-to-path", "license", "icon",
        "shortcut-name", "shortcut-target", "install-root", "start-menu", "desktop-shortcut", "release",
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
        .release = o.get("release") orelse "",
        .manufacturer = o.required("manufacturer"),
        .description = o.required("description"),
        .upgrade_code = o.required("upgrade-code"),
        .platform = msi.Platform.parse(platform_arg) orelse fail("unknown platform '{s}'", .{platform_arg}),
        .install_dir = o.required("install-dir"),
        .install_root = blk: {
            const r = o.get("install-root") orelse "program_files";
            break :blk std.meta.stringToEnum(msi.InstallRoot, r) orelse fail("invalid --install-root '{s}'", .{r});
        },
        .add_to_path = std.meta.stringToEnum(msi.PathMode, path_arg) orelse fail("invalid --add-to-path '{s}'", .{path_arg}),
        .icon = if (o.get("icon")) |path| ctx.readFile(path) else null,
        .shortcut = if (o.get("shortcut-name")) |name| .{
            .name = name,
            .target = o.required("shortcut-target"),
            .start_menu = !std.mem.eql(u8, o.get("start-menu") orelse "1", "0"),
            .desktop = blk: {
                const d = o.get("desktop-shortcut") orelse "never";
                break :blk std.meta.stringToEnum(msi.DesktopMode, d) orelse fail("invalid --desktop-shortcut '{s}'", .{d});
            },
        } else null,
        .files = files.items,
        .timestamp = o.mtime(),
    }) catch |err| switch (err) {
        error.NotRepresentable => fail("MSI strings must use characters from Windows-1252", .{}),
        error.InvalidShortcut => fail("the shortcut name is invalid or its target is not an installed file", .{}),
        error.InvalidPath => fail("an install path or install_dir_name contains characters Windows does not allow", .{}),
        else => |e| fail("cannot build MSI: {t}", .{e}),
    };
    ctx.writeFile(o.required("out"), out.written());
}

fn cmdPeNormalize(ctx: Ctx, args: []const []const u8) !void {
    if (args.len != 2) fail("usage: pe-normalize <input> <output>", .{});
    const image = ctx.readFile(args[0]);
    zstaller.pe.normalize(image) catch fail("'{s}' is not a valid PE image", .{args[0]});
    ctx.writeFile(args[1], image);
}

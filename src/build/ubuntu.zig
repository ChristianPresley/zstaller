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

//! Ubuntu packages: .deb.

const std = @import("std");
const api = @import("api.zig");
const naming = @import("../naming.zig");
const mcp = @import("mcp.zig");
const LazyPath = std.Build.LazyPath;

pub fn addPackage(ctx: *const api.Context, format: api.Format) ?LazyPath {
    return switch (format) {
        .deb => addDeb(ctx),
        else => unreachable,
    };
}

fn addDeb(ctx: *const api.Context) ?LazyPath {
    const b = ctx.b;
    const o = ctx.options;
    const description = ctx.meta.description orelse {
        ctx.fail("a description is required for .deb packages; add .description to build.zig.zon", .{});
        return null;
    };
    const maintainer = o.deb.maintainer orelse o.windows.publisher orelse {
        ctx.fail("set .deb.maintainer (e.g. \"Jane Doe <jane@example.com>\") to build .deb packages", .{});
        return null;
    };
    const pkg_name = naming.debPackageName(b.allocator, ctx.meta.name) catch @panic("OOM");
    if (!naming.isValidDebPackageName(pkg_name)) {
        ctx.fail("'{s}' cannot be used as a Debian package name", .{ctx.meta.name});
        return null;
    }

    const run = ctx.runPack("deb");
    run.addArg("--out");
    const out = run.addOutputFileArg("package.deb");
    ctx.addMtimeArg(run);
    run.addArgs(&.{ "--name", pkg_name });
    run.addArgs(&.{ "--version", naming.debVersion(b.allocator, ctx.meta.version) catch @panic("OOM") });
    run.addArgs(&.{ "--arch", ctx.target.debArch() });
    run.addArgs(&.{ "--maintainer", maintainer });
    run.addArgs(&.{ "--description", description });
    run.addArgs(&.{ "--section", o.deb.section });
    run.addArgs(&.{ "--priority", o.deb.priority });
    if (o.deb.homepage) |h| run.addArgs(&.{ "--homepage", h });
    if (o.deb.depends) |d| run.addArgs(&.{ "--depends", d });
    if (ctx.meta.license) |l| {
        run.addArgs(&.{ "--license", l });
        if (o.deb.copyright orelse o.windows.publisher) |holder| run.addArgs(&.{ "--copyright", holder });
    }

    run.addArg("--file");
    run.addFileArg(ctx.binary_file);
    run.addArgs(&.{ b.fmt("/usr/bin/{s}", .{ctx.binary.out_filename}), "755" });
    for (ctx.programs) |p| {
        run.addArg("--file");
        run.addFileArg(p.file);
        run.addArgs(&.{ b.fmt("/usr/bin/{s}", .{p.name}), "755" });
    }
    for (o.extra_files) |f| {
        run.addArg("--file");
        run.addFileArg(f.source);
        run.addArgs(&.{ b.fmt("/usr/share/{s}/{s}", .{ pkg_name, f.dest }), "644" });
    }
    if (ctx.mcp_helper) |helper| {
        const path = mcp.debHelperPath(b, pkg_name);
        run.addArg("--file");
        run.addFileArg(helper);
        run.addArgs(&.{ path, "755" });
        // Removing the package removes its registrations.
        run.addArgs(&.{ "--mcp-helper", path });
    }
    if (o.deb.long_description) |text| {
        const wf = b.addWriteFiles();
        run.addArg("--long-description");
        run.addFileArg(wf.add("long-description.txt", text));
    }
    if (!addLayout(ctx, run, pkg_name, description)) return null;
    return out;
}

/// Adds `deb.files`, the desktop entry and the maintainer scripts to the
/// `deb` pack step, after checking them. False when something is wrong.
fn addLayout(ctx: *const api.Context, run: *std.Build.Step.Run, pkg_name: []const u8, description: []const u8) bool {
    const b = ctx.b;
    const o = ctx.options;
    // Paths zstaller writes itself.
    var taken: std.StringHashMapUnmanaged([]const u8) = .empty;
    const put = struct {
        fn put(m: *std.StringHashMapUnmanaged([]const u8), a: std.mem.Allocator, path: []const u8, what: []const u8) void {
            m.put(a, path, what) catch @panic("OOM");
        }
    }.put;
    put(&taken, b.allocator, b.fmt("/usr/bin/{s}", .{ctx.binary.out_filename}), "the application");
    for (ctx.programs) |p| put(&taken, b.allocator, b.fmt("/usr/bin/{s}", .{p.name}), "a program");
    for (o.extra_files) |f| put(&taken, b.allocator, b.fmt("/usr/share/{s}/{s}", .{ pkg_name, f.dest }), "an extra file");
    if (ctx.meta.license != null) put(&taken, b.allocator, b.fmt("/usr/share/doc/{s}/copyright", .{pkg_name}), "the copyright file");
    put(&taken, b.allocator, b.fmt("/usr/share/doc/{s}/changelog.gz", .{pkg_name}), "the changelog");
    put(&taken, b.allocator, b.fmt("/usr/share/lintian/overrides/{s}", .{pkg_name}), "the lintian overrides");
    const desktop_path = b.fmt("/usr/share/applications/{s}.desktop", .{pkg_name});
    if (o.deb.desktop_entry != null) put(&taken, b.allocator, desktop_path, "the desktop entry");
    if (ctx.mcp_helper != null) put(&taken, b.allocator, mcp.debHelperPath(b, pkg_name), "zstaller-mcp");

    var ok = true;
    for (o.deb.files, 0..) |f, i| {
        if (debPathProblem(f.dest)) |problem| {
            ctx.fail("deb.files[{d}].dest '{s}' {s}", .{ i, f.dest, problem });
            ok = false;
        } else if (taken.get(f.dest)) |what| {
            ctx.fail("deb.files[{d}].dest '{s}' is where zstaller installs {s}", .{ i, f.dest, what });
            ok = false;
        } else if (f.mode > 0o7777) {
            ctx.fail("deb.files[{d}].mode {o} is not a permission mode", .{ i, f.mode });
            ok = false;
        } else {
            put(&taken, b.allocator, f.dest, b.fmt("deb.files[{d}]", .{i}));
        }
    }
    if (!ok) return false;
    for (o.deb.files) |f| {
        run.addArg("--file");
        run.addFileArg(f.source);
        run.addArgs(&.{ f.dest, b.fmt("{o}", .{f.mode}) });
    }

    if (o.deb.desktop_entry) |entry| {
        if (std.mem.indexOfAny(u8, entry.categories, "\r\n") != null or
            (entry.categories.len > 0 and entry.categories[entry.categories.len - 1] != ';'))
        {
            ctx.fail("deb.desktop_entry.categories '{s}' must be a list such as \"Utility;\" with each category followed by ';'", .{entry.categories});
            return false;
        }
        const text = b.fmt(
            \\[Desktop Entry]
            \\Type=Application
            \\Name={s}
            \\Comment={s}
            \\Exec=/usr/bin/{s}
            \\{s}Terminal={s}
            \\Categories={s}
            \\
        , .{
            desktopString(b, ctx.displayName()),
            desktopString(b, description),
            ctx.binary.out_filename,
            if (entry.icon != null) b.fmt("Icon={s}\n", .{pkg_name}) else "",
            if (entry.terminal) "true" else "false",
            entry.categories,
        });
        const wf = b.addWriteFiles();
        run.addArg("--file");
        run.addFileArg(wf.add(b.fmt("{s}.desktop", .{pkg_name}), text));
        run.addArgs(&.{ desktop_path, "644" });
        if (entry.icon) |icon| {
            run.addArg("--icon-png");
            run.addFileArg(icon);
        }
    }

    inline for (.{ "preinst", "postinst", "prerm", "postrm" }) |name| {
        if (@field(o.deb.scripts, name)) |script| {
            run.addArg("--" ++ name);
            run.addFileArg(script);
        }
    }
    return true;
}

/// Why `path` cannot be an install path in a .deb, or null.
fn debPathProblem(path: []const u8) ?[]const u8 {
    if (path.len < 2 or path[0] != '/') return "must be an absolute path such as /usr/share/man/man1/myapp.1";
    if (path[path.len - 1] == '/') return "names a directory; give the file's full path";
    var it = std.mem.splitScalar(u8, path[1..], '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return "must not contain empty, '.' or '..' parts";
    }
    if (std.mem.indexOfAny(u8, path, "\r\n") != null) return "must not contain line breaks";
    return null;
}

/// `value` escaped for a desktop entry string.
fn desktopString(b: *std.Build, value: []const u8) []const u8 {
    return std.mem.replaceOwned(u8, b.allocator, value, "\\", "\\\\") catch @panic("OOM");
}

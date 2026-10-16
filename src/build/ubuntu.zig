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
        if (o.windows.publisher) |p| run.addArgs(&.{ "--copyright", p });
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
    return out;
}

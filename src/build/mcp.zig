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

//! MCP server packaging (`Options.mcp`): the `.mcpb` bundle for Claude
//! Desktop and the MCP Registry. See
//! https://github.com/modelcontextprotocol/mcpb/blob/main/MANIFEST.md.

const std = @import("std");
const api = @import("api.zig");

const LazyPath = std.Build.LazyPath;

/// Whether `name` is usable as an MCP server name in every client:
/// letters, digits, '_' and '-', 1 to 64 characters.
pub fn isValidServerName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => {},
        else => return false,
    };
    return true;
}

test isValidServerName {
    try std.testing.expect(isValidServerName("my-app_2"));
    try std.testing.expect(!isValidServerName("my app"));
    try std.testing.expect(!isValidServerName(""));
    try std.testing.expect(!isValidServerName("a" ** 65));
}

/// The server program for this target.
pub const Server = struct {
    /// Its installed file name, e.g. `myapp.exe`.
    file_name: []const u8,
    file: LazyPath,
};

/// Finds `options.mcp.program` among the built programs, or reports why
/// it cannot.
pub fn server(ctx: *const api.Context) ?Server {
    const m = ctx.options.mcp.?;
    const name = m.name orelse ctx.meta.name;
    if (!isValidServerName(name)) {
        ctx.fail("mcp.name '{s}' is not a valid MCP server name: use letters, digits, '_' and '-', at most 64 characters", .{name});
        return null;
    }
    const wanted = m.program orelse return .{ .file_name = ctx.binary.out_filename, .file = ctx.binary_file };
    for (ctx.programs) |p| {
        if (std.mem.eql(u8, std.fs.path.stem(p.name), wanted)) return .{ .file_name = p.name, .file = p.file };
    }
    ctx.fail("mcp.program '{s}' is not one of the programs: give the file name of a program in .programs, without .exe", .{wanted});
    return null;
}

const Manifest = struct {
    manifest_version: []const u8 = "0.3",
    name: []const u8,
    display_name: []const u8,
    version: []const u8,
    description: []const u8,
    author: struct { name: []const u8 },
    homepage: ?[]const u8,
    license: ?[]const u8,
    icon: ?[]const u8,
    server: struct {
        type: []const u8 = "binary",
        entry_point: []const u8,
        mcp_config: struct {
            command: []const u8,
            args: []const []const u8,
            env: std.json.ArrayHashMap([]const u8),
        },
    },
    compatibility: struct { platforms: []const []const u8 },
};

/// The `.mcpb` for this target: `manifest.json`, the server program in
/// `server/` and the icon.
pub fn addBundle(ctx: *const api.Context) ?LazyPath {
    const b = ctx.b;
    const m = ctx.options.mcp.?;
    const srv = server(ctx) orelse return null;
    const description = ctx.meta.description orelse {
        ctx.fail("a description is required for MCP bundles; add .description to build.zig.zon", .{});
        return null;
    };
    const entry_point = b.fmt("server/{s}", .{srv.file_name});
    var env: std.json.ArrayHashMap([]const u8) = .{};
    for (m.env) |e| env.map.put(b.allocator, e.name, e.value) catch @panic("OOM");
    const manifest: Manifest = .{
        .name = m.name orelse ctx.meta.name,
        .display_name = ctx.displayName(),
        .version = ctx.meta.version,
        .description = description,
        .author = .{ .name = ctx.publisher() },
        .homepage = ctx.options.deb.homepage,
        .license = ctx.meta.license,
        .icon = if (m.icon != null) "icon.png" else null,
        .server = .{
            .entry_point = entry_point,
            .mcp_config = .{
                .command = b.fmt("${{__dirname}}/{s}", .{entry_point}),
                .args = m.args,
                .env = env,
            },
        },
        .compatibility = .{ .platforms = &.{switch (ctx.target.os()) {
            .windows => "win32",
            .ubuntu => "linux",
        }} },
    };
    const json = std.json.Stringify.valueAlloc(b.allocator, manifest, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    }) catch @panic("OOM");
    const wf = b.addWriteFiles();
    const manifest_file = wf.add("manifest.json", json);

    const run = ctx.runPack("mcpb");
    run.addArg("--out");
    const out = run.addOutputFileArg("bundle.mcpb");
    ctx.addMtimeArg(run);
    run.addArg("--manifest");
    run.addFileArg(manifest_file);
    if (m.icon) |icon| {
        run.addArg("--icon");
        run.addFileArg(icon);
    }
    run.addArg("--file");
    run.addFileArg(srv.file);
    run.addArgs(&.{ entry_point, "755" });
    return out;
}

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
const registrar = @import("../mcp/registrar.zig");

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

/// The registration program's file name on this target.
pub fn helperFileName(ctx: *const api.Context) []const u8 {
    return if (ctx.resolved_target.result.os.tag == .windows) "zstaller-mcp.exe" else "zstaller-mcp";
}

/// Where the .deb installs the registration program.
pub fn debHelperPath(b: *std.Build, pkg_name: []const u8) []const u8 {
    return b.fmt("/usr/lib/{s}/zstaller-mcp", .{pkg_name});
}

/// The clients `options.mcp.clients` turns on, by name.
pub fn clientNames(ctx: *const api.Context) []const []const u8 {
    const m = ctx.options.mcp.?;
    var list: std.ArrayList([]const u8) = .empty;
    inline for (@typeInfo(api.McpClients).@"struct".fields) |f| {
        if (@field(m.clients, f.name)) list.append(ctx.b.allocator, f.name) catch @panic("OOM");
    }
    return list.items;
}

/// "Claude Code and VS Code": the clients, for the Setup wizard.
pub fn clientLabels(ctx: *const api.Context) []const u8 {
    const names = clientNames(ctx);
    var out: std.ArrayList(u8) = .empty;
    const a = ctx.b.allocator;
    for (names, 0..) |n, i| {
        if (i > 0) out.appendSlice(a, if (i + 1 == names.len) " and " else ", ") catch @panic("OOM");
        const label = (std.meta.stringToEnum(registrar.Client, n) orelse unreachable).label();
        out.appendSlice(a, label) catch @panic("OOM");
    }
    return out.items;
}

/// `zstaller-mcp` (src/mcp/helper.zig) for this target, configured for
/// this server: it registers the server with the user's AI tools.
pub fn addHelper(ctx: *const api.Context) ?LazyPath {
    const b = ctx.b;
    const m = ctx.options.mcp.?;
    const srv = server(ctx) orelse return null;
    const names = clientNames(ctx);
    if (names.len == 0) {
        ctx.fail("mcp.clients turns every AI tool off; turn one on, or set mcp.register = .never", .{});
        return null;
    }
    const windows = ctx.resolved_target.result.os.tag == .windows;
    const config = b.addOptions();
    config.addOption([]const u8, "name", m.name orelse ctx.meta.name);
    config.addOption([]const u8, "display_name", ctx.displayName());
    // On Windows the program is next to zstaller-mcp, in whatever folder
    // the user chose; on Ubuntu it is in /usr/bin.
    config.addOption(bool, "program_relative", windows);
    config.addOption([]const u8, "program", if (windows) srv.file_name else b.fmt("/usr/bin/{s}", .{srv.file_name}));
    config.addOption([]const []const u8, "args", m.args);
    var env_names: std.ArrayList([]const u8) = .empty;
    var env_values: std.ArrayList([]const u8) = .empty;
    for (m.env) |e| {
        env_names.append(b.allocator, e.name) catch @panic("OOM");
        env_values.append(b.allocator, e.value) catch @panic("OOM");
    }
    config.addOption([]const []const u8, "env_names", env_names.items);
    config.addOption([]const []const u8, "env_values", env_values.items);
    config.addOption([]const []const u8, "client_names", names);

    const mod = b.createModule(.{
        .root_source_file = ctx.zb.path("src/mcp/helper.zig"),
        .target = ctx.resolved_target,
        .optimize = .ReleaseSmall,
        .imports = &.{.{ .name = "config", .module = config.createModule() }},
    });
    if (windows) {
        mod.linkSystemLibrary("shell32", .{});
        mod.linkSystemLibrary("ole32", .{});
        mod.linkSystemLibrary("advapi32", .{});
    }
    const exe = b.addExecutable(.{ .name = "zstaller-mcp", .root_module = mod });
    return api.packagedBinary(b, ctx.options, ctx.pack, ctx.target, ctx.resolved_target, exe);
}

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
//! Application metadata read from a consumer's `build.zig.zon`.
//!
//! zstaller reads `name` and `version`, which every package manifest has, plus
//! the optional `description` and `license` fields. Zig 0.16 accepts these
//! extra fields in a manifest, so consumers keep all metadata in one place.
//! Every other field is ignored.
//!
//! Package formats that need `description` or `license` (for example .deb
//! and MSI) check for them themselves; parsing only rejects values that are
//! present but malformed.

const Metadata = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Zoir = std.zig.Zoir;
const ZonGen = std.zig.ZonGen;

/// Package name, from `.name = .myapp`. Restricted to ASCII letters, digits,
/// `_`, `-` and `.` so it is safe to use in file names and package metadata.
name: []const u8,
/// The `.version` string exactly as written in the manifest.
version_string: []const u8,
/// Parsed form of `version_string`. Its `pre` and `build` slices point into
/// `version_string`.
version: std.SemanticVersion,
/// One-line summary, from `.description`.
description: ?[]const u8,
/// License identifier or SPDX expression, from `.license`.
license: ?[]const u8,

pub const ParseError = error{
    OutOfMemory,
    /// The source is not valid ZON. `Diagnostic.line`/`column` locate the
    /// first problem.
    InvalidSyntax,
    /// The top-level value is not a struct literal.
    NotAStruct,
    /// A required field is missing. `Diagnostic.field` names it.
    MissingField,
    /// A field has the wrong type or an invalid value. `Diagnostic.field`
    /// names it.
    InvalidField,
};

/// Extra information about the most recent parse failure.
pub const Diagnostic = struct {
    /// The manifest field the error refers to, if any.
    field: ?[]const u8 = null,
    /// Human-readable explanation. Points to static memory.
    message: []const u8 = "",
    /// 1-based position of a syntax error, when `InvalidSyntax` is returned.
    line: usize = 0,
    column: usize = 0,

    pub fn format(d: Diagnostic, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (d.line != 0) try w.print("{d}:{d}: ", .{ d.line, d.column });
        if (d.field) |f| try w.print("field '{s}': ", .{f});
        try w.writeAll(d.message);
    }
};

/// Parses manifest `source`. On success the returned strings are owned by the
/// caller; free them with `deinit` using the same allocator. When `diag` is
/// non-null it is filled in on error.
pub fn parse(gpa: Allocator, source: [:0]const u8, diag: ?*Diagnostic) ParseError!Metadata {
    var scratch: Diagnostic = .{};
    const d = diag orelse &scratch;
    d.* = .{};

    var ast = try Ast.parse(gpa, source, .zon);
    defer ast.deinit(gpa);
    if (ast.errors.len > 0) {
        const loc = ast.tokenLocation(0, ast.errors[0].token);
        d.* = .{ .message = "invalid ZON syntax", .line = loc.line + 1, .column = loc.column + 1 };
        return error.InvalidSyntax;
    }

    var zoir = try ZonGen.generate(gpa, ast, .{});
    defer zoir.deinit(gpa);
    if (zoir.hasCompileErrors()) {
        const err = zoir.compile_errors[0];
        d.* = .{ .message = "invalid ZON syntax" };
        if (err.token.unwrap()) |tok| {
            const loc = ast.tokenLocation(0, tok);
            d.line = loc.line + 1;
            d.column = loc.column + err.node_or_offset + 1;
        }
        return error.InvalidSyntax;
    }

    const root = switch (Zoir.Node.Index.root.get(zoir)) {
        .struct_literal => |s| s,
        .empty_literal => {
            d.* = .{ .field = "name", .message = "missing required field" };
            return error.MissingField;
        },
        else => {
            d.* = .{ .message = "top-level value must be a struct literal" };
            return error.NotAStruct;
        },
    };

    var name_node: ?Zoir.Node = null;
    var version_node: ?Zoir.Node = null;
    var description_node: ?Zoir.Node = null;
    var license_node: ?Zoir.Node = null;
    for (root.names, 0..) |field_name, i| {
        const key = field_name.get(zoir);
        const slot = if (std.mem.eql(u8, key, "name"))
            &name_node
        else if (std.mem.eql(u8, key, "version"))
            &version_node
        else if (std.mem.eql(u8, key, "description"))
            &description_node
        else if (std.mem.eql(u8, key, "license"))
            &license_node
        else
            continue;
        slot.* = root.vals.at(@intCast(i)).get(zoir);
    }

    const name_src: []const u8 = switch (name_node orelse {
        d.* = .{ .field = "name", .message = "missing required field" };
        return error.MissingField;
    }) {
        .enum_literal => |s| s.get(zoir),
        .string_literal => |s| s,
        else => {
            d.* = .{ .field = "name", .message = "expected an enum literal such as .myapp" };
            return error.InvalidField;
        },
    };
    if (!isValidName(name_src)) {
        d.* = .{ .field = "name", .message = "must be non-empty and contain only ASCII letters, digits, '_', '-' or '.'" };
        return error.InvalidField;
    }

    const version_src = switch (version_node orelse {
        d.* = .{ .field = "version", .message = "missing required field" };
        return error.MissingField;
    }) {
        .string_literal => |s| s,
        else => {
            d.* = .{ .field = "version", .message = "expected a string" };
            return error.InvalidField;
        },
    };
    _ = std.SemanticVersion.parse(version_src) catch {
        d.* = .{ .field = "version", .message = "not a valid semantic version (expected MAJOR.MINOR.PATCH)" };
        return error.InvalidField;
    };

    const description_src = try optionalText(description_node, "description", d);
    const license_src = try optionalText(license_node, "license", d);

    const name = try gpa.dupe(u8, name_src);
    errdefer gpa.free(name);
    const version_string = try gpa.dupe(u8, version_src);
    errdefer gpa.free(version_string);
    const description = if (description_src) |s| try gpa.dupe(u8, s) else null;
    errdefer if (description) |s| gpa.free(s);
    const license = if (license_src) |s| try gpa.dupe(u8, s) else null;

    return .{
        .name = name,
        .version_string = version_string,
        // Re-parse the owned copy so `pre` and `build` point into it.
        .version = std.SemanticVersion.parse(version_string) catch unreachable,
        .description = description,
        .license = license,
    };
}

/// Reads and parses the manifest at `sub_path` relative to `dir`.
pub fn load(
    gpa: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    diag: ?*Diagnostic,
) (ParseError || std.Io.Dir.ReadFileAllocError)!Metadata {
    const source = try dir.readFileAllocOptions(io, sub_path, gpa, .limited(max_manifest_bytes), .of(u8), 0);
    defer gpa.free(source);
    return parse(gpa, source, diag);
}

/// Upper bound on manifest size accepted by `load`.
pub const max_manifest_bytes = 1024 * 1024;

pub fn deinit(m: *Metadata, gpa: Allocator) void {
    gpa.free(m.name);
    gpa.free(m.version_string);
    if (m.description) |s| gpa.free(s);
    if (m.license) |s| gpa.free(s);
    m.* = undefined;
}

fn optionalText(node: ?Zoir.Node, comptime field: []const u8, d: *Diagnostic) ParseError!?[]const u8 {
    const n = node orelse return null;
    const s = switch (n) {
        .string_literal => |s| s,
        else => {
            d.* = .{ .field = field, .message = "expected a string" };
            return error.InvalidField;
        },
    };
    if (std.mem.trim(u8, s, " \t").len == 0) {
        d.* = .{ .field = field, .message = "must not be empty" };
        return error.InvalidField;
    }
    if (std.mem.indexOfAny(u8, s, "\r\n") != null) {
        d.* = .{ .field = field, .message = "must be a single line" };
        return error.InvalidField;
    }
    return s;
}

/// Returns true when `name` can name a package: letters, digits, '_',
/// '-' and '.'.
pub fn isValidName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
        else => return false,
    };
    return true;
}

const testing = std.testing;

fn expectParseError(expected: ParseError, field: ?[]const u8, source: [:0]const u8) !void {
    var diag: Diagnostic = .{};
    try testing.expectError(expected, parse(testing.allocator, source, &diag));
    if (field) |f| {
        try testing.expectEqualStrings(f, diag.field.?);
    } else {
        try testing.expect(diag.field == null);
    }
    try testing.expect(diag.message.len > 0);
}

test "parse full manifest" {
    var m = try parse(testing.allocator,
        \\.{
        \\    .name = .myapp,
        \\    .version = "1.2.3",
        \\    .description = "A tool that does things",
        \\    .license = "Apache-2.0",
        \\    .fingerprint = 0x276f7ca0b630ab83,
        \\    .minimum_zig_version = "0.16.0",
        \\    .dependencies = .{
        \\        .zstaller = .{ .path = "../zstaller" },
        \\    },
        \\    .paths = .{""},
        \\}
    , null);
    defer m.deinit(testing.allocator);
    try testing.expectEqualStrings("myapp", m.name);
    try testing.expectEqualStrings("1.2.3", m.version_string);
    try testing.expectEqual(std.SemanticVersion{ .major = 1, .minor = 2, .patch = 3 }, m.version);
    try testing.expectEqualStrings("A tool that does things", m.description.?);
    try testing.expectEqualStrings("Apache-2.0", m.license.?);
}

test "parse minimal manifest leaves optional fields null" {
    var m = try parse(testing.allocator, ".{ .name = .app, .version = \"0.0.1\" }", null);
    defer m.deinit(testing.allocator);
    try testing.expectEqualStrings("app", m.name);
    try testing.expect(m.description == null);
    try testing.expect(m.license == null);
}

test "parse keeps pre-release and build metadata" {
    var m = try parse(testing.allocator, ".{ .name = .app, .version = \"2.0.0-rc.1+abc\" }", null);
    defer m.deinit(testing.allocator);
    try testing.expectEqualStrings("rc.1", m.version.pre.?);
    try testing.expectEqualStrings("abc", m.version.build.?);
}

test "parse accepts quoted identifier and string names" {
    var a = try parse(testing.allocator, ".{ .name = .@\"my-app\", .version = \"1.0.0\" }", null);
    defer a.deinit(testing.allocator);
    try testing.expectEqualStrings("my-app", a.name);

    var b = try parse(testing.allocator, ".{ .name = \"legacy\", .version = \"1.0.0\" }", null);
    defer b.deinit(testing.allocator);
    try testing.expectEqualStrings("legacy", b.name);
}

test "parse decodes string escapes" {
    var m = try parse(testing.allocator,
        \\.{ .name = .app, .version = "1.0.0", .description = "Say \"hi\" \u{1F44B}" }
    , null);
    defer m.deinit(testing.allocator);
    try testing.expectEqualStrings("Say \"hi\" \u{1F44B}", m.description.?);
}

test "parse rejects missing required fields" {
    try expectParseError(error.MissingField, "name", ".{ .version = \"1.0.0\" }");
    try expectParseError(error.MissingField, "version", ".{ .name = .app }");
    try expectParseError(error.MissingField, "name", ".{}");
}

test "parse rejects wrong field types" {
    try expectParseError(error.InvalidField, "name", ".{ .name = 42, .version = \"1.0.0\" }");
    try expectParseError(error.InvalidField, "version", ".{ .name = .app, .version = .one }");
    try expectParseError(error.InvalidField, "description", ".{ .name = .app, .version = \"1.0.0\", .description = .{} }");
    try expectParseError(error.InvalidField, "license", ".{ .name = .app, .version = \"1.0.0\", .license = true }");
}

test "parse rejects invalid values" {
    try expectParseError(error.InvalidField, "version", ".{ .name = .app, .version = \"1.0\" }");
    try expectParseError(error.InvalidField, "name", ".{ .name = .@\"my app\", .version = \"1.0.0\" }");
    try expectParseError(error.InvalidField, "name", ".{ .name = \"\", .version = \"1.0.0\" }");
    try expectParseError(error.InvalidField, "description", ".{ .name = .app, .version = \"1.0.0\", .description = \"  \" }");
    try expectParseError(error.InvalidField, "description", ".{ .name = .app, .version = \"1.0.0\", .description = \"a\\nb\" }");
}

test "parse rejects non-struct and malformed source" {
    try expectParseError(error.NotAStruct, null, "\"just a string\"");
    try expectParseError(error.NotAStruct, null, ".{ 1, 2, 3 }");

    var diag: Diagnostic = .{};
    try testing.expectError(error.InvalidSyntax, parse(testing.allocator, ".{\n    .name = .app,\n    .version = ,\n}", &diag));
    try testing.expectEqual(@as(usize, 3), diag.line);

    try testing.expectError(error.InvalidSyntax, parse(testing.allocator, ".{ .name = .app, .name = .other }", &diag));
}

test "diagnostic formats field and position" {
    var buf: [128]u8 = undefined;
    const d: Diagnostic = .{ .field = "version", .message = "expected a string" };
    try testing.expectEqualStrings("field 'version': expected a string", try std.fmt.bufPrint(&buf, "{f}", .{d}));
    const s: Diagnostic = .{ .message = "invalid ZON syntax", .line = 3, .column = 16 };
    try testing.expectEqualStrings("3:16: invalid ZON syntax", try std.fmt.bufPrint(&buf, "{f}", .{s}));
}

test "parse does not leak on any allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            var m = parse(gpa, ".{ .name = .app, .version = \"1.0.0\", .description = \"d\", .license = \"MIT\" }", null) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => unreachable,
            };
            m.deinit(gpa);
        }
    }.run, .{});
}

test "load reads a manifest from disk" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "build.zig.zon",
        .data = ".{ .name = .disk, .version = \"3.1.4\", .license = \"MIT\" }\n",
    });
    var m = try load(testing.allocator, testing.io, tmp.dir, "build.zig.zon", null);
    defer m.deinit(testing.allocator);
    try testing.expectEqualStrings("disk", m.name);
    try testing.expectEqualStrings("MIT", m.license.?);
}

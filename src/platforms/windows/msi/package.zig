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

//! Builds a complete per-machine Windows Installer package for an
//! application: directory tree, one component per file, an embedded
//! MSZIP cabinet, major-upgrade handling, optional PATH entry and the
//! standard install/uninstall sequences, plus an optional Start Menu
//! shortcut. No UI tables are written, so
//! msiexec shows its basic progress UI, and `/qn` installs silently.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const db_mod = @import("database.zig");
const cab = @import("cab.zig");
const uuid = @import("../../../uuid.zig");
const payload = @import("../exe/payload.zig");

const Database = db_mod.Database;
const T = db_mod.ColumnType;
const Value = db_mod.Value;

pub const Platform = enum {
    x64,
    arm64,

    pub fn template(p: Platform) []const u8 {
        return switch (p) {
            .x64 => "x64;1033",
            .arm64 => "Arm64;1033",
        };
    }

    pub fn parse(s: []const u8) ?Platform {
        if (std.ascii.eqlIgnoreCase(s, "x64")) return .x64;
        if (std.ascii.eqlIgnoreCase(s, "arm64")) return .arm64;
        return null;
    }
};

pub const PathMode = enum { never, optional, always };

pub const File = struct {
    /// Relative install path using '/' separators.
    path: []const u8,
    data: []const u8,
};

pub const Shortcut = struct {
    /// Shortcut name in the Start Menu, without `.lnk`.
    name: []const u8,
    /// Install path of the file it opens; must be one of `files`.
    target: []const u8,
};

pub const Product = struct {
    name: []const u8,
    /// Numeric `major.minor.build` version.
    version: []const u8,
    manufacturer: []const u8,
    description: []const u8,
    /// `{GUID}`; stable across versions.
    upgrade_code: []const u8,
    platform: Platform,
    /// Directory created under Program Files.
    install_dir: []const u8,
    add_to_path: PathMode = .never,
    icon: ?[]const u8 = null,
    /// Start Menu shortcut for all users, removed on uninstall.
    shortcut: ?Shortcut = null,
    files: []const File,
    /// Seconds since the Unix epoch for the summary timestamps.
    timestamp: u64 = 0,
};

pub const Error = db_mod.Error || cab.Error || error{ InvalidUpgradeCode, InvalidPath, InvalidShortcut, InvalidVersion, NoFiles, TooManyFiles };

const cabinet_name = "product.cab";
const icon_key = "ProductIcon.ico";

pub fn write(gpa: Allocator, out: *Writer, p: Product) Error!void {
    if (p.files.len == 0) return error.NoFiles;
    if (p.files.len > 32000) return error.TooManyFiles;
    try validateVersion(p.version);
    const upgrade = uuid.parse(p.upgrade_code) catch return error.InvalidUpgradeCode;
    for (p.files) |f| if (!payload.isSafePath(f.path)) return error.InvalidPath;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const upgrade_str = uuid.format(upgrade);
    const platform = @tagName(p.platform);
    const product_code = uuid.format(uuid.v5Parts(upgrade, &.{ "product", p.version, platform }));
    const package_code = blk: {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        for ([_][]const u8{ p.name, p.version, p.manufacturer, p.description, p.install_dir, @tagName(p.add_to_path), platform }) |s| {
            h.update(s);
            h.update(&.{0});
        }
        for (p.files) |f| {
            h.update(f.path);
            h.update(&.{0});
            h.update(f.data);
        }
        if (p.icon) |i| h.update(i);
        if (p.shortcut) |sc| {
            h.update(sc.name);
            h.update(&.{0});
            h.update(sc.target);
        }
        var d: [32]u8 = undefined;
        h.final(&d);
        var hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{x}", .{&d}) catch unreachable;
        break :blk uuid.format(uuid.v5Parts(upgrade, &.{ "package", &hex }));
    };

    var db: Database = .init(gpa);
    defer db.deinit();

    // ---- Property
    const property = try db.addTable("Property", &.{
        .{ .name = "Property", .type = T.str(72) | T.key },
        .{ .name = "Value", .type = T.str(0) | T.localizable },
    });
    const props = [_][2][]const u8{
        .{ "ProductCode", &product_code },
        .{ "ProductName", p.name },
        .{ "ProductVersion", p.version },
        .{ "ProductLanguage", "1033" },
        .{ "Manufacturer", p.manufacturer },
        .{ "UpgradeCode", &upgrade_str },
        .{ "ALLUSERS", "1" },
        .{ "ARPNOMODIFY", "1" },
        .{ "ARPNOREPAIR", "1" },
        .{ "ARPCOMMENTS", p.description },
        .{ "SecureCustomProperties", "ADDTOPATH;NEWERVERSIONFOUND;OLDERVERSIONFOUND" },
    };
    for (props) |kv| try db.addRow(property, &.{ .{ .str = kv[0] }, .{ .str = kv[1] } });
    if (p.add_to_path == .optional) try db.addRow(property, &.{ .{ .str = "ADDTOPATH" }, .{ .str = "1" } });
    if (p.icon != null) try db.addRow(property, &.{ .{ .str = "ARPPRODUCTICON" }, .{ .str = icon_key } });

    // ---- Directory tree
    const directory = try db.addTable("Directory", &.{
        .{ .name = "Directory", .type = T.str(72) | T.key },
        .{ .name = "Directory_Parent", .type = T.str(72) | T.nullable },
        .{ .name = "DefaultDir", .type = T.str(255) | T.localizable },
    });
    try db.addRow(directory, &.{ .{ .str = "TARGETDIR" }, .null, .{ .str = "SourceDir" } });
    try db.addRow(directory, &.{ .{ .str = "ProgramFiles64Folder" }, .{ .str = "TARGETDIR" }, .{ .str = "." } });

    var short_names: ShortNames = .{};
    try db.addRow(directory, &.{
        .{ .str = "INSTALLDIR" },
        .{ .str = "ProgramFiles64Folder" },
        .{ .str = try short_names.longName(a, "ProgramFiles64Folder", p.install_dir) },
    });

    // Subdirectories, keyed by relative path ("" = INSTALLDIR).
    var dir_ids: std.StringHashMapUnmanaged([]const u8) = .empty;
    try dir_ids.put(a, "", "INSTALLDIR");
    const sorted_files = try a.dupe(File, p.files);
    std.mem.sort(File, sorted_files, {}, struct {
        fn lt(_: void, x: File, y: File) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.lt);
    for (sorted_files[1..], sorted_files[0 .. sorted_files.len - 1]) |y, x| {
        if (std.ascii.eqlIgnoreCase(x.path, y.path)) return error.InvalidPath;
    }
    for (sorted_files) |f| {
        var it = std.mem.splitScalar(u8, f.path, '/');
        var parent_rel: []const u8 = "";
        var consumed: usize = 0;
        while (it.next()) |seg| {
            if (it.peek() == null) break; // last segment is the file name
            consumed += seg.len + @intFromBool(consumed != 0);
            const rel = f.path[0..consumed];
            if (!dir_ids.contains(rel)) {
                const id = try std.fmt.allocPrint(a, "D{d}", .{dir_ids.count()});
                const parent_id = dir_ids.get(parent_rel).?;
                try db.addRow(directory, &.{ .{ .str = id }, .{ .str = parent_id }, .{ .str = try short_names.longName(a, parent_id, seg) } });
                try dir_ids.put(a, rel, id);
            }
            parent_rel = rel;
        }
    }

    // ---- Components, files and the cabinet
    const component = try db.addTable("Component", &.{
        .{ .name = "Component", .type = T.str(72) | T.key },
        .{ .name = "ComponentId", .type = T.str(38) | T.nullable },
        .{ .name = "Directory_", .type = T.str(72) },
        .{ .name = "Attributes", .type = T.int2 },
        .{ .name = "Condition", .type = T.str(255) | T.nullable },
        .{ .name = "KeyPath", .type = T.str(72) | T.nullable },
    });
    const file_table = try db.addTable("File", &.{
        .{ .name = "File", .type = T.str(72) | T.key },
        .{ .name = "Component_", .type = T.str(72) },
        .{ .name = "FileName", .type = T.str(255) | T.localizable },
        .{ .name = "FileSize", .type = T.int4 },
        .{ .name = "Version", .type = T.str(72) | T.nullable },
        .{ .name = "Language", .type = T.str(20) | T.nullable },
        .{ .name = "Attributes", .type = T.int2 | T.nullable },
        .{ .name = "Sequence", .type = T.int2 },
    });
    const feature_components = try db.addTable("FeatureComponents", &.{
        .{ .name = "Feature_", .type = T.str(38) | T.key },
        .{ .name = "Component_", .type = T.str(72) | T.key },
    });
    const component_64bit = 256;
    const component_registry_keypath = 4;
    const file_vital = 512;

    const cab_files = try a.alloc(cab.File, sorted_files.len);
    var shortcut_file: ?struct { file: []const u8, component: []const u8 } = null;
    for (sorted_files, 0..) |f, i| {
        const file_key = try std.fmt.allocPrint(a, "F{d}", .{i + 1});
        const comp_key = try std.fmt.allocPrint(a, "C{d}", .{i + 1});
        const dir_rel = std.fs.path.dirnamePosix(f.path) orelse "";
        const base = std.fs.path.basenamePosix(f.path);
        const dir_id = dir_ids.get(dir_rel).?;
        const comp_guid = uuid.format(uuid.v5Parts(upgrade, &.{ "component", platform, f.path }));
        try db.addRow(component, &.{ .{ .str = comp_key }, .{ .str = try a.dupe(u8, &comp_guid) }, .{ .str = dir_id }, .{ .int = component_64bit }, .null, .{ .str = file_key } });
        try db.addRow(file_table, &.{
            .{ .str = file_key },
            .{ .str = comp_key },
            .{ .str = try short_names.longName(a, dir_id, base) },
            .{ .int = @intCast(f.data.len) },
            .null,
            .null,
            .{ .int = file_vital },
            .{ .int = @intCast(i + 1) },
        });
        try db.addRow(feature_components, &.{ .{ .str = "Complete" }, .{ .str = comp_key } });
        cab_files[i] = .{ .name = file_key, .data = f.data };
        if (p.shortcut) |sc| if (std.mem.eql(u8, sc.target, f.path)) {
            shortcut_file = .{ .file = file_key, .component = comp_key };
        };
    }

    // ---- Start Menu shortcut, installed with the file it points at.
    if (p.shortcut) |sc| {
        const target = shortcut_file orelse return error.InvalidShortcut;
        if (sc.name.len == 0 or std.mem.indexOfAny(u8, sc.name, "\\/:*?\"<>|") != null) return error.InvalidShortcut;
        try db.addRow(directory, &.{ .{ .str = "ProgramMenuFolder" }, .{ .str = "TARGETDIR" }, .{ .str = "." } });
        const shortcut = try db.addTable("Shortcut", &.{
            .{ .name = "Shortcut", .type = T.str(72) | T.key },
            .{ .name = "Directory_", .type = T.str(72) },
            .{ .name = "Name", .type = T.str(128) | T.localizable },
            .{ .name = "Component_", .type = T.str(72) },
            .{ .name = "Target", .type = T.str(72) },
            .{ .name = "Arguments", .type = T.str(255) | T.nullable },
            .{ .name = "Description", .type = T.str(255) | T.localizable | T.nullable },
            .{ .name = "Hotkey", .type = T.int2 | T.nullable },
            .{ .name = "Icon_", .type = T.str(72) | T.nullable },
            .{ .name = "IconIndex", .type = T.int2 | T.nullable },
            .{ .name = "ShowCmd", .type = T.int2 | T.nullable },
            .{ .name = "WkDir", .type = T.str(72) | T.nullable },
        });
        try db.addRow(shortcut, &.{
            .{ .str = "SStartMenu" },
            .{ .str = "ProgramMenuFolder" },
            .{ .str = try short_names.longName(a, "ProgramMenuFolder", sc.name) },
            .{ .str = target.component },
            .{ .str = try std.fmt.allocPrint(a, "[#{s}]", .{target.file}) },
            .null,
            .{ .str = p.description },
            .null,
            if (p.icon != null) Value{ .str = icon_key } else .null,
            if (p.icon != null) Value{ .int = 0 } else .null,
            .null,
            .{ .str = "INSTALLDIR" },
        });
    }

    // ---- PATH
    if (p.add_to_path != .never) {
        const registry = try db.addTable("Registry", &.{
            .{ .name = "Registry", .type = T.str(72) | T.key },
            .{ .name = "Root", .type = T.int2 },
            .{ .name = "Key", .type = T.str(255) | T.localizable },
            .{ .name = "Name", .type = T.str(255) | T.localizable | T.nullable },
            .{ .name = "Value", .type = T.str(0) | T.localizable | T.nullable },
            .{ .name = "Component_", .type = T.str(72) },
        });
        const environment = try db.addTable("Environment", &.{
            .{ .name = "Environment", .type = T.str(72) | T.key },
            .{ .name = "Name", .type = T.str(255) | T.localizable },
            .{ .name = "Value", .type = T.str(255) | T.localizable | T.nullable },
            .{ .name = "Component_", .type = T.str(72) },
        });
        const path_guid = uuid.format(uuid.v5Parts(upgrade, &.{ "component", platform, "PATH" }));
        try db.addRow(component, &.{
            .{ .str = "CPath" },
            .{ .str = try a.dupe(u8, &path_guid) },
            .{ .str = "INSTALLDIR" },
            .{ .int = component_64bit | component_registry_keypath },
            if (p.add_to_path == .optional) Value{ .str = "ADDTOPATH=1" } else .null,
            .{ .str = "RPath" },
        });
        const reg_key = try std.fmt.allocPrint(a, "Software\\{s}\\{s}", .{ p.manufacturer, p.name });
        try db.addRow(registry, &.{ .{ .str = "RPath" }, .{ .int = 2 }, .{ .str = reg_key }, .{ .str = "AddedToPath" }, .{ .str = "1" }, .{ .str = "CPath" } });
        try db.addRow(environment, &.{ .{ .str = "EPath" }, .{ .str = "=-*Path" }, .{ .str = "[~];[INSTALLDIR]" }, .{ .str = "CPath" } });
        try db.addRow(feature_components, &.{ .{ .str = "Complete" }, .{ .str = "CPath" } });
    }

    // ---- Feature
    const feature = try db.addTable("Feature", &.{
        .{ .name = "Feature", .type = T.str(38) | T.key },
        .{ .name = "Feature_Parent", .type = T.str(38) | T.nullable },
        .{ .name = "Title", .type = T.str(64) | T.localizable | T.nullable },
        .{ .name = "Description", .type = T.str(255) | T.localizable | T.nullable },
        .{ .name = "Display", .type = T.int2 | T.nullable },
        .{ .name = "Level", .type = T.int2 },
        .{ .name = "Directory_", .type = T.str(72) | T.nullable },
        .{ .name = "Attributes", .type = T.int2 },
    });
    try db.addRow(feature, &.{ .{ .str = "Complete" }, .null, .{ .str = p.name }, .{ .str = p.description }, .{ .int = 1 }, .{ .int = 1 }, .{ .str = "INSTALLDIR" }, .{ .int = 0 } });

    // ---- Media and embedded cabinet
    const media = try db.addTable("Media", &.{
        .{ .name = "DiskId", .type = T.int2 | T.key },
        .{ .name = "LastSequence", .type = T.int2 },
        .{ .name = "DiskPrompt", .type = T.str(64) | T.localizable | T.nullable },
        .{ .name = "Cabinet", .type = T.str(255) | T.nullable },
        .{ .name = "VolumeLabel", .type = T.str(32) | T.nullable },
        .{ .name = "Source", .type = T.str(72) | T.nullable },
    });
    try db.addRow(media, &.{ .{ .int = 1 }, .{ .int = @intCast(sorted_files.len) }, .null, .{ .str = "#" ++ cabinet_name }, .null, .null });
    var cab_out: Writer.Allocating = .init(a);
    try cab.write(gpa, &cab_out.writer, cab_files, .mszip, p.timestamp);
    try db.addStream(cabinet_name, cab_out.written());

    // ---- Icon
    if (p.icon) |icon| {
        const icon_table = try db.addTable("Icon", &.{
            .{ .name = "Name", .type = T.str(72) | T.key },
            .{ .name = "Data", .type = T.binary },
        });
        try db.addRow(icon_table, &.{ .{ .str = icon_key }, .{ .stream = icon } });
    }

    // ---- Upgrades: remove older versions, refuse to downgrade.
    const upgrade_table = try db.addTable("Upgrade", &.{
        .{ .name = "UpgradeCode", .type = T.str(38) | T.key },
        .{ .name = "VersionMin", .type = T.str(20) | T.key | T.nullable },
        .{ .name = "VersionMax", .type = T.str(20) | T.key | T.nullable },
        .{ .name = "Language", .type = T.str(255) | T.key | T.nullable },
        .{ .name = "Attributes", .type = T.int4 | T.key },
        .{ .name = "Remove", .type = T.str(255) | T.nullable },
        .{ .name = "ActionProperty", .type = T.str(72) },
    });
    const migrate_features = 1;
    const only_detect = 2;
    try db.addRow(upgrade_table, &.{ .{ .str = &upgrade_str }, .null, .{ .str = p.version }, .null, .{ .int = migrate_features }, .null, .{ .str = "OLDERVERSIONFOUND" } });
    try db.addRow(upgrade_table, &.{ .{ .str = &upgrade_str }, .{ .str = p.version }, .null, .null, .{ .int = only_detect }, .null, .{ .str = "NEWERVERSIONFOUND" } });

    const launch = try db.addTable("LaunchCondition", &.{
        .{ .name = "Condition", .type = T.str(255) | T.key },
        .{ .name = "Description", .type = T.str(255) | T.localizable },
    });
    try db.addRow(launch, &.{ .{ .str = "NOT NEWERVERSIONFOUND" }, .{ .str = try std.fmt.allocPrint(a, "A newer version of {s} is already installed.", .{p.name}) } });

    // ---- Sequences
    const seq_cols = [_]db_mod.Column{
        .{ .name = "Action", .type = T.str(72) | T.key },
        .{ .name = "Condition", .type = T.str(255) | T.nullable },
        .{ .name = "Sequence", .type = T.int2 | T.nullable },
    };
    const execute = try db.addTable("InstallExecuteSequence", &seq_cols);
    const execute_actions = [_]struct { []const u8, i32 }{
        .{ "FindRelatedProducts", 25 },       .{ "LaunchConditions", 100 },   .{ "ValidateProductID", 700 },
        .{ "CostInitialize", 800 },           .{ "FileCost", 900 },           .{ "CostFinalize", 1000 },
        .{ "MigrateFeatureStates", 1200 },    .{ "InstallValidate", 1400 },   .{ "RemoveExistingProducts", 1401 },
        .{ "InstallInitialize", 1500 },       .{ "ProcessComponents", 1600 }, .{ "UnpublishFeatures", 1800 },
        .{ "RemoveRegistryValues", 2600 },    .{ "RemoveShortcuts", 3200 },   .{ "RemoveEnvironmentStrings", 3300 },
        .{ "RemoveFiles", 3500 },             .{ "RemoveFolders", 3600 },     .{ "CreateFolders", 3700 },
        .{ "InstallFiles", 4000 },            .{ "CreateShortcuts", 4500 },   .{ "WriteRegistryValues", 5000 },
        .{ "WriteEnvironmentStrings", 5200 }, .{ "RegisterUser", 6000 },      .{ "RegisterProduct", 6100 },
        .{ "PublishFeatures", 6300 },         .{ "PublishProduct", 6400 },    .{ "InstallFinalize", 6600 },
    };
    for (execute_actions) |act| try db.addRow(execute, &.{ .{ .str = act[0] }, .null, .{ .int = act[1] } });
    const ui = try db.addTable("InstallUISequence", &seq_cols);
    const ui_actions = [_]struct { []const u8, i32 }{
        .{ "FindRelatedProducts", 25 },    .{ "LaunchConditions", 100 }, .{ "ValidateProductID", 700 },
        .{ "CostInitialize", 800 },        .{ "FileCost", 900 },         .{ "CostFinalize", 1000 },
        .{ "MigrateFeatureStates", 1200 }, .{ "ExecuteAction", 1300 },
    };
    for (ui_actions) |act| try db.addRow(ui, &.{ .{ .str = act[0] }, .null, .{ .int = act[1] } });

    try db.write(out, .{
        .subject = p.name,
        .author = p.manufacturer,
        .comments = p.description,
        .template = p.platform.template(),
        .revision = &package_code,
        .timestamp = p.timestamp,
    });
}

fn validateVersion(v: []const u8) error{InvalidVersion}!void {
    var it = std.mem.splitScalar(u8, v, '.');
    const limits = [_]u32{ 255, 255, 65535 };
    var n: usize = 0;
    while (it.next()) |part| : (n += 1) {
        if (n >= limits.len) return error.InvalidVersion;
        const x = std.fmt.parseInt(u32, part, 10) catch return error.InvalidVersion;
        if (x > limits[n]) return error.InvalidVersion;
    }
    if (n != 3) return error.InvalidVersion;
}

/// Generates unique 8.3 short names per directory, as Windows Installer
/// requires for `DefaultDir` and `FileName` ("SHORT|Long name").
const ShortNames = struct {
    used: std.StringHashMapUnmanaged(void) = .empty,

    fn longName(s: *ShortNames, a: Allocator, dir_id: []const u8, name: []const u8) Allocator.Error![]const u8 {
        if (isShortName(name)) {
            const key = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir_id, try upper(a, name) });
            if (!s.used.contains(key)) {
                try s.used.put(a, key, {});
                return name;
            }
        }
        const dot = std.mem.lastIndexOfScalar(u8, name, '.');
        const stem = if (dot) |d| name[0..d] else name;
        const ext = if (dot) |d| name[d + 1 ..] else "";
        var base_buf: [6]u8 = undefined;
        var base_len: usize = 0;
        for (stem) |c| {
            if (base_len == 6) break;
            if (shortChar(c)) |u| {
                base_buf[base_len] = u;
                base_len += 1;
            }
        }
        if (base_len == 0) {
            @memcpy(base_buf[0..4], "FILE");
            base_len = 4;
        }
        var ext_buf: [3]u8 = undefined;
        var ext_len: usize = 0;
        for (ext) |c| {
            if (ext_len == 3) break;
            if (shortChar(c)) |u| {
                ext_buf[ext_len] = u;
                ext_len += 1;
            }
        }
        var n: usize = 1;
        while (true) : (n += 1) {
            var num_buf: [8]u8 = undefined;
            const num = std.fmt.bufPrint(&num_buf, "~{d}", .{n}) catch unreachable;
            const keep = @min(base_len, 8 - num.len);
            const short = if (ext_len > 0)
                try std.fmt.allocPrint(a, "{s}{s}.{s}", .{ base_buf[0..keep], num, ext_buf[0..ext_len] })
            else
                try std.fmt.allocPrint(a, "{s}{s}", .{ base_buf[0..keep], num });
            const key = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir_id, short });
            if (s.used.contains(key)) continue;
            try s.used.put(a, key, {});
            return std.fmt.allocPrint(a, "{s}|{s}", .{ short, name });
        }
    }

    fn upper(a: Allocator, name: []const u8) Allocator.Error![]u8 {
        const out = try a.dupe(u8, name);
        for (out) |*c| c.* = std.ascii.toUpper(c.*);
        return out;
    }
};

fn shortChar(c: u8) ?u8 {
    return switch (c) {
        'a'...'z' => c - 32,
        'A'...'Z', '0'...'9', '_', '-', '!', '#', '$', '%', '&', '(', ')', '@', '^', '{', '}', '~' => c,
        else => null,
    };
}

fn isShortName(name: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, name, '.');
    const stem = if (dot) |d| name[0..d] else name;
    const ext = if (dot) |d| name[d + 1 ..] else "";
    if (stem.len == 0 or stem.len > 8 or ext.len > 3) return false;
    if (dot != null and ext.len == 0) return false;
    for (stem) |c| if (shortChar(c) == null) return false;
    for (ext) |c| if (shortChar(c) == null) return false;
    return true;
}

const testing = std.testing;

test "short names" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: ShortNames = .{};
    try testing.expectEqualStrings("app.exe", try s.longName(a, "D", "app.exe"));
    try testing.expectEqualStrings("README~1.MAR|README.markdown", try s.longName(a, "D", "README.markdown"));
    try testing.expectEqualStrings("ZSTALL~1|Zstaller Sample", try s.longName(a, "D", "Zstaller Sample"));
    try testing.expectEqualStrings("ZSTALL~2|Zstaller Samples", try s.longName(a, "D", "Zstaller Samples"));
    // Same short name in another directory is fine.
    try testing.expectEqualStrings("ZSTALL~1|Zstaller Sample", try s.longName(a, "E", "Zstaller Sample"));
    try testing.expect(!isShortName("toolong12.exe"));
    try testing.expect(isShortName("SAMPLE.EXE"));
}

test "version validation" {
    try validateVersion("1.2.3");
    try validateVersion("255.255.65535");
    try testing.expectError(error.InvalidVersion, validateVersion("1.2"));
    try testing.expectError(error.InvalidVersion, validateVersion("256.0.0"));
    try testing.expectError(error.InvalidVersion, validateVersion("1.2.3-rc"));
}

test "builds a readable package" {
    const gpa = testing.allocator;
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(gpa, &out.writer, .{
        .name = "Demo App",
        .version = "1.2.3",
        .manufacturer = "Example",
        .description = "A demo",
        .upgrade_code = "{3C1B6E0A-8F7D-4E52-9B1A-6D2C4F8E7A10}",
        .platform = .x64,
        .install_dir = "Demo App",
        .add_to_path = .optional,
        .icon = "ICON",
        .files = &.{
            .{ .path = "demo.exe", .data = "MZ" },
            .{ .path = "docs/README.md", .data = "# Demo\n" },
        },
    });
    var r = try @import("cfb.zig").TestReader.init(gpa, out.written());
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const cab_bytes = (try r.read(try db_mod.encodeStreamName(arena.allocator(), cabinet_name, false))).?;
    defer gpa.free(cab_bytes);
    var files = try cab.extractForTest(gpa, cab_bytes);
    defer {
        for (files.items) |f| gpa.free(f.data);
        files.deinit(gpa);
    }
    try testing.expectEqual(@as(usize, 2), files.items.len);
    try testing.expectEqualStrings("F1", files.items[0].name);
    try testing.expectEqualStrings("MZ", files.items[0].data);
    const icon = (try r.read(try db_mod.encodeStreamName(arena.allocator(), "Icon." ++ icon_key, false))).?;
    defer gpa.free(icon);
    try testing.expectEqualStrings("ICON", icon);
}

test "package is deterministic" {
    const gpa = testing.allocator;
    const product: Product = .{
        .name = "D",
        .version = "1.0.0",
        .manufacturer = "M",
        .description = "d",
        .upgrade_code = "{3C1B6E0A-8F7D-4E52-9B1A-6D2C4F8E7A10}",
        .platform = .arm64,
        .install_dir = "D",
        .files = &.{.{ .path = "d.exe", .data = "x" }},
    };
    var a1: Writer.Allocating = .init(gpa);
    defer a1.deinit();
    var a2: Writer.Allocating = .init(gpa);
    defer a2.deinit();
    try write(gpa, &a1.writer, product);
    try write(gpa, &a2.writer, product);
    try testing.expectEqualSlices(u8, a1.written(), a2.written());
}

test "msitools can read the package (skipped when msiinfo is missing)" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(gpa, &out.writer, .{
        .name = "Demo",
        .version = "2.0.1",
        .manufacturer = "Example",
        .description = "A demo",
        .upgrade_code = "{3C1B6E0A-8F7D-4E52-9B1A-6D2C4F8E7A10}",
        .platform = .arm64,
        .install_dir = "Demo",
        .add_to_path = .always,
        .icon = "ICON",
        .shortcut = .{ .name = "Demo App", .target = "demo.exe" },
        .files = &.{.{ .path = "demo.exe", .data = "MZ" }},
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "demo.msi", .data = out.written() });
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/demo.msi", .{tmp.sub_path});
    defer gpa.free(path);

    const result = std.process.run(gpa, io, .{ .argv = &.{ "msiinfo", "export", path, "Property" } }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => |e| return e,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("msiinfo failed:\n{s}\n", .{result.stderr});
        return error.MsiinfoRejected;
    }
    try testing.expect(std.mem.indexOf(u8, result.stdout, "ProductVersion\t2.0.1") != null);

    const shortcuts = try std.process.run(gpa, io, .{ .argv = &.{ "msiinfo", "export", path, "Shortcut" } });
    defer gpa.free(shortcuts.stdout);
    defer gpa.free(shortcuts.stderr);
    try testing.expect(std.mem.indexOf(u8, shortcuts.stdout, "SStartMenu\tProgramMenuFolder\tDEMOAP~1|Demo App\tC1\t[#F1]") != null);
}

test "shortcut must point at an installed file" {
    const gpa = testing.allocator;
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    var product: Product = .{
        .name = "D",
        .version = "1.0.0",
        .manufacturer = "M",
        .description = "d",
        .upgrade_code = "{3C1B6E0A-8F7D-4E52-9B1A-6D2C4F8E7A10}",
        .platform = .x64,
        .install_dir = "D",
        .shortcut = .{ .name = "D", .target = "missing.exe" },
        .files = &.{.{ .path = "d.exe", .data = "x" }},
    };
    try testing.expectError(error.InvalidShortcut, write(gpa, &out.writer, product));
    product.shortcut = .{ .name = "a/b", .target = "d.exe" };
    try testing.expectError(error.InvalidShortcut, write(gpa, &out.writer, product));
}

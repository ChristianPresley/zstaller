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

//! Output file names for installers.
//!
//! Windows and generic formats use `name-version-os-arch.ext` (EXE
//! installers add `-setup`). Debian packages follow Debian's own
//! `name_version_arch.deb` convention so apt and dpkg tooling recognise them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Target = @import("target.zig").Target;
const Format = @import("target.zig").Format;

pub fn installerFileName(
    gpa: Allocator,
    name: []const u8,
    version: []const u8,
    target: Target,
    format: Format,
) Allocator.Error![]u8 {
    return switch (format) {
        .deb => blk: {
            const pkg = try debPackageName(gpa, name);
            defer gpa.free(pkg);
            const ver = try debVersion(gpa, version);
            defer gpa.free(ver);
            break :blk std.fmt.allocPrint(gpa, "{s}_{s}_{s}.deb", .{ pkg, ver, target.debArch() });
        },
        .exe => std.fmt.allocPrint(gpa, "{s}-{s}-{s}-setup.exe", .{ name, version, target.slug() }),
        .msi => std.fmt.allocPrint(gpa, "{s}-{s}-{s}.msi", .{ name, version, target.slug() }),
        .mcpb => std.fmt.allocPrint(gpa, "{s}-{s}-{s}.mcpb", .{ name, version, target.slug() }),
    };
}

/// Debian package names allow only lowercase letters, digits, '+', '-'
/// and '.'. Uppercase is lowered and '_' becomes '-'.
pub fn debPackageName(gpa: Allocator, name: []const u8) Allocator.Error![]u8 {
    const out = try gpa.dupe(u8, name);
    for (out) |*c| c.* = switch (c.*) {
        'A'...'Z' => c.* + ('a' - 'A'),
        '_' => '-',
        else => c.*,
    };
    return out;
}

/// Returns true when `name` is a valid Debian package name (after
/// `debPackageName`): at least two characters, starts with a letter or
/// digit, and only uses `[a-z0-9+.-]`.
pub fn isValidDebPackageName(name: []const u8) bool {
    if (name.len < 2) return false;
    if (!std.ascii.isAlphanumeric(name[0])) return false;
    for (name) |c| switch (c) {
        'a'...'z', '0'...'9', '+', '-', '.' => {},
        else => return false,
    };
    return true;
}

/// Converts a semantic version to a Debian version. The pre-release
/// separator '-' becomes '~' so that `1.0.0-rc.1` sorts before `1.0.0`.
pub fn debVersion(gpa: Allocator, version: []const u8) Allocator.Error![]u8 {
    const out = try gpa.dupe(u8, version);
    const plus = std.mem.indexOfScalar(u8, out, '+') orelse out.len;
    if (std.mem.indexOfScalar(u8, out[0..plus], '-')) |i| out[i] = '~';
    return out;
}

/// Windows Installer ProductVersion: `major.minor.patch`. Pre-release and
/// build metadata are dropped because MSI versions are purely numeric.
/// Null when a field is over MSI's limits (255.255.65535): clamping would
/// give different releases the same version and break upgrades.
pub fn msiVersion(buf: []u8, v: std.SemanticVersion) ?[]const u8 {
    if (v.major > 255 or v.minor > 255 or v.patch > 65535) return null;
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}", .{ v.major, v.minor, v.patch }) catch unreachable;
}

/// Returns true when `v` is a valid MSI ProductVersion: three numeric
/// fields, at most 255.255.65535.
pub fn isValidMsiVersion(v: []const u8) bool {
    var it = std.mem.splitScalar(u8, v, '.');
    const limits = [_]u32{ 255, 255, 65535 };
    var n: usize = 0;
    while (it.next()) |part| : (n += 1) {
        if (n >= limits.len or part.len == 0) return false;
        const x = std.fmt.parseInt(u32, part, 10) catch return false;
        if (x > limits[n]) return false;
    }
    return n == limits.len;
}

/// What is wrong with `dest` as a path relative to the install directory,
/// or null when every installer can use it.
pub fn installPathProblem(dest: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, dest, '\\') != null) return "uses '\\'; separate folders with '/'";
    if (dest.len > 0 and dest[0] == '/') return "must be relative to the install directory";
    if (!@import("platforms/windows/exe/payload.zig").isSafePath(dest))
        return "is not a valid install path: use a relative path such as 'docs/manual.txt', without '..', empty parts or the characters < > : \" | ? *";
    return null;
}

/// Name of the SHA-256 sidecar written next to `file_name`.
pub fn checksumFileName(gpa: Allocator, file_name: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "{s}.sha256", .{file_name});
}

const testing = std.testing;

fn expectName(expected: []const u8, name: []const u8, version: []const u8, t: Target, f: Format) !void {
    const got = try installerFileName(testing.allocator, name, version, t, f);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "installer file names" {
    try expectName("myapp-1.2.3-windows-x86_64.msi", "myapp", "1.2.3", .windows_x86_64, .msi);
    try expectName("myapp-1.2.3-windows-aarch64-setup.exe", "myapp", "1.2.3", .windows_aarch64, .exe);
    try expectName("myapp_1.2.3_amd64.deb", "myapp", "1.2.3", .ubuntu_x86_64, .deb);
    try expectName("my-app_1.0.0~rc.1+build.5_arm64.deb", "My_App", "1.0.0-rc.1+build.5", .ubuntu_aarch64, .deb);
}

test "debian names and versions" {
    try testing.expect(isValidDebPackageName("my-app"));
    try testing.expect(!isValidDebPackageName("a"));
    try testing.expect(!isValidDebPackageName("-app"));
    try testing.expect(!isValidDebPackageName("app_x"));
    const v = try debVersion(testing.allocator, "2.0.0+git-abc");
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("2.0.0+git-abc", v);
}

test "install paths" {
    try testing.expectEqual(null, installPathProblem("README.md"));
    try testing.expectEqual(null, installPathProblem("docs/manual.txt"));
    for ([_][]const u8{ "", "../x", "docs\\a", "/abs", "a//b", "a:b" }) |bad| {
        try testing.expect(installPathProblem(bad) != null);
    }
}

test "msi version strings" {
    try testing.expect(isValidMsiVersion("26.10.0"));
    try testing.expect(isValidMsiVersion("255.255.65535"));
    try testing.expect(!isValidMsiVersion("26.10"));
    try testing.expect(!isValidMsiVersion("256.0.0"));
    try testing.expect(!isValidMsiVersion("1.0.0-rc.1"));
    try testing.expect(!isValidMsiVersion("1..0"));
}

test "msi version refuses fields over the limits" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1.2.3", msiVersion(&buf, .{ .major = 1, .minor = 2, .patch = 3, .pre = "rc.1" }).?);
    try testing.expectEqualStrings("255.255.65535", msiVersion(&buf, .{ .major = 255, .minor = 255, .patch = 65535 }).?);
    try testing.expectEqual(null, msiVersion(&buf, .{ .major = 2026, .minor = 1, .patch = 0 }));
    try testing.expectEqual(null, msiVersion(&buf, .{ .major = 1, .minor = 256, .patch = 0 }));
    try testing.expectEqual(null, msiVersion(&buf, .{ .major = 1, .minor = 0, .patch = 65536 }));
}

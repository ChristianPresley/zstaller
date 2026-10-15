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

//! The installer target matrix: which operating system, CPU and package
//! formats each supported target produces.
//!
//! To add a target, add a variant here, fill in each switch, and register
//! its platform in `Platform.zig`.

const std = @import("std");

pub const Os = enum {
    windows,
    ubuntu,

    pub fn displayName(os: Os) []const u8 {
        return switch (os) {
            .windows => "Windows",
            .ubuntu => "Ubuntu Linux",
        };
    }
};

pub const Format = enum {
    deb,
    exe,
    msi,

    pub fn extension(f: Format) []const u8 {
        return switch (f) {
            .deb => ".deb",
            .exe => ".exe",
            .msi => ".msi",
        };
    }
};

pub const Target = enum {
    windows_x86_64,
    windows_aarch64,
    ubuntu_x86_64,
    ubuntu_aarch64,

    /// Every supported target, in a stable order.
    pub const all: []const Target = std.enums.values(Target);

    pub fn os(t: Target) Os {
        return switch (t) {
            .windows_x86_64, .windows_aarch64 => .windows,
            .ubuntu_x86_64, .ubuntu_aarch64 => .ubuntu,
        };
    }

    pub fn cpuArch(t: Target) std.Target.Cpu.Arch {
        return switch (t) {
            .windows_x86_64, .ubuntu_x86_64 => .x86_64,
            .windows_aarch64, .ubuntu_aarch64 => .aarch64,
        };
    }

    /// The Zig target used to compile binaries for this installer target.
    ///
    /// Windows uses the GNU ABI so no MSVC toolchain or Windows SDK is
    /// needed. Ubuntu uses musl so binaries are statically linked and run on
    /// every supported Ubuntu release regardless of its glibc version.
    pub fn query(t: Target) std.Target.Query {
        return .{
            .cpu_arch = t.cpuArch(),
            .os_tag = switch (t.os()) {
                .windows => .windows,
                .ubuntu => .linux,
            },
            .abi = switch (t.os()) {
                .windows => .gnu,
                .ubuntu => .musl,
            },
        };
    }

    /// Package formats produced for this target.
    pub fn formats(t: Target) []const Format {
        return switch (t.os()) {
            .windows => &.{ .msi, .exe },
            .ubuntu => &.{.deb},
        };
    }

    /// Architecture as used in file names: `x86_64` or `aarch64`.
    pub fn archName(t: Target) []const u8 {
        return @tagName(t.cpuArch());
    }

    /// Debian architecture name.
    pub fn debArch(t: Target) []const u8 {
        return switch (t.cpuArch()) {
            .x86_64 => "amd64",
            .aarch64 => "arm64",
            else => unreachable,
        };
    }

    /// Windows Installer platform name used in the MSI Template summary
    /// property.
    pub fn msiPlatform(t: Target) []const u8 {
        return switch (t.cpuArch()) {
            .x86_64 => "x64",
            .aarch64 => "Arm64",
            else => unreachable,
        };
    }

    /// Short identifier such as `windows-x86_64`, used in file names and
    /// step names.
    pub fn slug(t: Target) []const u8 {
        return switch (t) {
            inline else => |tag| comptime blk: {
                const name = @tagName(tag);
                const i = std.mem.indexOfScalar(u8, name, '_').?;
                break :blk name[0..i] ++ "-" ++ name[i + 1 ..];
            },
        };
    }

    pub fn parse(s: []const u8) ?Target {
        for (all) |t| {
            if (std.mem.eql(u8, s, t.slug()) or std.mem.eql(u8, s, @tagName(t))) return t;
        }
        return null;
    }
};

const testing = std.testing;

test "every target maps to a valid Zig target" {
    for (Target.all) |t| {
        const q = t.query();
        try testing.expect(q.os_tag != null);
        try testing.expect(t.formats().len > 0);
        try testing.expectEqual(t, Target.parse(t.slug()).?);
        try testing.expectEqual(t, Target.parse(@tagName(t)).?);
    }
}

test "names" {
    try testing.expectEqualStrings("windows-aarch64", Target.windows_aarch64.slug());
    try testing.expectEqualStrings("arm64", Target.ubuntu_aarch64.debArch());
    try testing.expectEqualStrings("amd64", Target.ubuntu_x86_64.debArch());
    try testing.expectEqualStrings("Arm64", Target.windows_aarch64.msiPlatform());
    try testing.expectEqualStrings("x64", Target.windows_x86_64.msiPlatform());
    try testing.expect(Target.parse("macos-x86_64") == null);
}

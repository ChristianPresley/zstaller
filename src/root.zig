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

//! zstaller: a packaged installer generator for Zig projects.
//!
//! This module holds the package writers (.deb, Windows EXE payload,
//! Windows MSI) and their building blocks. Projects normally use the build
//! API in `build.zig` (`addInstallers`) rather than this module directly.

const std = @import("std");
const build_options = @import("build_options");

pub const Metadata = @import("Metadata.zig");
pub const Target = @import("target.zig").Target;
pub const Format = @import("target.zig").Format;
pub const naming = @import("naming.zig");
pub const checksum = @import("checksum.zig");
pub const uuid = @import("uuid.zig");
pub const image = @import("image.zig");
pub const deb = @import("platforms/ubuntu/deb.zig");
pub const exe_payload = @import("platforms/windows/exe/payload.zig");
pub const exe_overlay = @import("platforms/windows/exe/overlay.zig");
pub const exe_cli = @import("platforms/windows/exe/stub/cli.zig");
pub const wizard_assets = @import("platforms/windows/exe/wizard_assets.zig");
pub const wizard_art = @import("platforms/windows/exe/stub/art.zig");
pub const exe_acl = @import("platforms/windows/exe/stub/acl.zig");
pub const pe = @import("platforms/windows/pe.zig");
pub const msi = struct {
    pub const cfb = @import("platforms/windows/msi/cfb.zig");
    pub const cab = @import("platforms/windows/msi/cab.zig");
    pub const database = @import("platforms/windows/msi/database.zig");
    pub const package = @import("platforms/windows/msi/package.zig");
};
pub const archive = struct {
    pub const tar = @import("archive/tar.zig");
    pub const ar = @import("archive/ar.zig");
    pub const deflate = @import("archive/deflate.zig");
};

/// The zstaller release this source tree corresponds to, taken from
/// `.version` in build.zig.zon.
pub const version = std.SemanticVersion.parse(build_options.version) catch
    @compileError("build.zig.zon .version is not a valid semantic version");

test "version round-trips to the build.zig.zon string" {
    var buf: [64]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buf, "{f}", .{version});
    try std.testing.expectEqualStrings(build_options.version, formatted);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(archive);
    std.testing.refAllDecls(msi);
}

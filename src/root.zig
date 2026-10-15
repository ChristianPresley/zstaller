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
//! The cross-compile matrix and package generators (.deb, Windows EXE,
//! Windows MSI) land in later milestones; see README.md for the current
//! status.

const std = @import("std");
const build_options = @import("build_options");

pub const Metadata = @import("Metadata.zig");

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
}

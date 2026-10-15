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

//! The platform interface.
//!
//! Each supported operating system has a build-side module that turns a
//! compiled binary into packages. A platform module must declare:
//!
//!     /// Adds the steps that produce `format` for `ctx.target`, and
//!     /// returns the package file. On a configuration error it calls
//!     /// `ctx.fail(...)` and returns null.
//!     pub fn addPackage(ctx: *const api.Context, format: Format) ?LazyPath
//!
//! To add a platform (for example Fedora RPM or macOS pkg):
//!   1. Add its targets to `Target` and its formats to `Format` in
//!      `src/target.zig`, and an `Os` variant.
//!   2. Write the package format in pure Zig under `src/platforms/<os>/`,
//!      with unit tests, and expose it through `zstaller-pack`.
//!   3. Create `src/build/<os>.zig` implementing `addPackage`, and add it
//!      to `platforms` below.

const std = @import("std");
const api = @import("api.zig");
const LazyPath = std.Build.LazyPath;

pub const platforms = struct {
    pub const windows = @import("windows.zig");
    pub const ubuntu = @import("ubuntu.zig");
};

comptime {
    for (std.enums.values(api.Os)) |os| {
        const P = @field(platforms, @tagName(os));
        const f: fn (*const api.Context, api.Format) ?LazyPath = P.addPackage;
        _ = f;
    }
}

pub fn addPackage(ctx: *const api.Context, format: api.Format) ?LazyPath {
    return switch (ctx.target.os()) {
        inline else => |os| @field(platforms, @tagName(os)).addPackage(ctx, format),
    };
}

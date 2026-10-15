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

const std = @import("std");
const manifest = @import("build.zig.zon");
const api = @import("src/build/api.zig");

// Public build API. See README.md for usage.
pub const Target = api.Target;
pub const Format = api.Format;
pub const Options = api.Options;
pub const ExtraFile = api.ExtraFile;
pub const PathMode = api.PathMode;
pub const WindowsOptions = api.WindowsOptions;
pub const DebOptions = api.DebOptions;
pub const MetadataOverrides = api.MetadataOverrides;
pub const ExecutableFn = api.ExecutableFn;
pub const Output = api.Output;
pub const Installers = api.Installers;

/// Cross-compiles the application for every target in `options.targets`
/// and adds steps that build its installers into
/// `zig-out/<install_subdir>/`, each with a `.sha256` checksum file.
/// Depend on the returned `step`, typically from a step named "installer".
///
/// The calling package must list zstaller in its build.zig.zon.
pub fn addInstallers(b: *std.Build, options: Options) Installers {
    const dep = b.dependencyFromBuildZig(@This(), .{});
    return api.addInstallersWith(b, dep.builder, options);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library module. Consumers will reach it through
    // `b.dependency("zstaller", .{}).module("zstaller")`.
    const mod = b.addModule("zstaller", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Single-source the package version from build.zig.zon.
    const options = b.addOptions();
    options.addOption([]const u8, "version", manifest.version);
    mod.addOptions("build_options", options);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);

    const pack = api.createPackTool(b);
    const pack_step = b.step("pack", "Build the zstaller-pack host tool");
    pack_step.dependOn(&b.addInstallArtifact(pack, .{}).step);
}

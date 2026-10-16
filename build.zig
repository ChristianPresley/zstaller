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
pub const WizardOptions = api.WizardOptions;
pub const InstallRoot = api.InstallRoot;
pub const DesktopShortcut = api.DesktopShortcut;
pub const DebOptions = api.DebOptions;
pub const DebFile = api.DebFile;
pub const DesktopEntry = api.DesktopEntry;
pub const DebScripts = api.DebScripts;
pub const MetadataOverrides = api.MetadataOverrides;
pub const ExecutableFn = api.ExecutableFn;
pub const Program = api.Program;
pub const SignFn = api.SignFn;
pub const SignRequest = api.SignRequest;
pub const InstallCommand = api.InstallCommand;
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

    // The packaging library itself (archives, MSI, payloads). It is what
    // zstaller-pack and the tests are built from; consumers use
    // `addInstallers` above, not this module.
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

    // API reference for build.zig users: `zig build docs`, then serve
    // zig-out/docs (for example `python3 -m http.server -d zig-out/docs`).
    const docs_obj = b.addObject(.{
        .name = "zstaller",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    const docs = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    b.step("docs", "Build the API reference into zig-out/docs").dependOn(&docs.step);

    const pack = api.createPackTool(b);
    const pack_step = b.step("pack", "Build the zstaller-pack host tool");
    pack_step.dependOn(&b.addInstallArtifact(pack, .{}).step);
}

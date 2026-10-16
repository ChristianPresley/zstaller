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
const zstaller = @import("zstaller");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The normal native build: `zig build`, `zig build run`.
    const exe = createExe(b, target, optimize);
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    b.step("run", "Run the sample").dependOn(&run.step);

    // `zig build installer` cross-compiles the sample and writes MSI, EXE
    // and .deb installers to zig-out/installers/. `-Dversion=1.0.1` builds
    // them as another version, which the Windows test uses for upgrades.
    const version = b.option([]const u8, "version", "Build the installers as this version instead of the one in build.zig.zon");
    const installers = zstaller.addInstallers(b, .{
        .executable = createExe,
        // Every target is built by default; listed here for clarity.
        .targets = &.{ .windows_x86_64, .windows_aarch64, .ubuntu_x86_64, .ubuntu_aarch64 },
        .metadata = .{ .version = version },
        .icon = b.path("assets/sample.ico"),
        .extra_files = &.{
            .{ .source = b.path("README.md"), .dest = "README.md" },
        },
        .windows = .{
            .publisher = "The zstaller Authors",
            .display_name = "Zstaller Sample",
            // Keep this GUID fixed for the life of your product so that new
            // MSI versions upgrade old ones.
            .upgrade_code = "{3C1B6E0A-8F7D-4E52-9B1A-6D2C4F8E7A10}",
            .add_to_path = .optional,
            // If the sample is running, offer to force-quit it instead of
            // failing to replace or remove its files.
            .close_running_apps = true,
            // Default install location: C:\Program Files\Zstaller Sample.
            // Users can pick another folder in the wizard.
            .install_root = .program_files,
            .install_dir_name = "Zstaller Sample",
            // Offer an (unticked) desktop shortcut checkbox.
            .desktop_shortcut = .optional,
            // The setup wizard's look. The images are double size
            // (986x624 and 986x116) so they stay sharp on high-DPI
            // displays; 493x312 and 493x58 work too.
            .wizard = .{
                .welcome_image = b.path("assets/wizard-welcome.png"),
                .banner_image = b.path("assets/wizard-banner.png"),
                .license_file = b.path("LICENSE"),
                .accent_color = 0xF7A41D,
            },
        },
        .deb = .{
            .maintainer = "The zstaller Authors <noreply@example.com>",
            .homepage = "https://github.com/ChristianPresley/zstaller",
        },
    });
    b.step("installer", "Build installers for every target").dependOn(installers.step);
}

/// zstaller calls this once per target to cross-compile the application.
fn createExe(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // Smaller installers: drop debug info from release binaries.
        .strip = optimize != .Debug,
    });
    mod.addOptions("options", options);
    // Give the Windows executable the same icon as its installers, so the
    // Start Menu shortcut and Explorer show it.
    if (target.result.os.tag == .windows) {
        mod.addWin32ResourceFile(.{ .file = b.path("assets/sample.rc"), .include_paths = &.{b.path("assets")} });
    }
    return b.addExecutable(.{ .name = "sample", .root_module = mod });
}

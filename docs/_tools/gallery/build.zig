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
//! The documentation site's screenshot project: the sample application,
//! packaged with whichever zstaller options a screenshot needs. Each
//! `-D` option below turns one setting on or off, so every page of the
//! guide can show what that setting does. docs/_tools/capture.sh builds
//! it once per scenario; it is not an example to copy (see
//! examples/sample for that).

const std = @import("std");
const zstaller = @import("zstaller");

const sample = "../../../examples/sample/";

pub fn build(b: *std.Build) void {
    const art = b.option(enum { builtin, custom }, "art", "Wizard artwork") orelse .custom;
    const accent = b.option(u24, "accent", "Accent color of the built-in artwork") orelse 0x0067C0;
    const license = b.option(bool, "license", "Show the License page") orelse true;
    const path = b.option(zstaller.PathMode, "path", "add_to_path") orelse .optional;
    const desktop = b.option(zstaller.DesktopShortcut, "desktop", "desktop_shortcut") orelse .optional;
    const mcp = b.option(enum { none, never, optional, always }, "mcp", "MCP server registration") orelse .optional;
    const dir_change = b.option(bool, "dir-change", "allow_install_dir_change") orelse true;
    const launch = b.option(bool, "launch", "wizard.launch_on_finish") orelse true;
    const scope = b.option(zstaller.Scope, "scope", "windows.scope") orelse .machine;
    const root = b.option(zstaller.InstallRoot, "root", "windows.install_root") orelse .program_files;
    const close = b.option(bool, "close", "close_running_apps") orelse true;
    const hook = b.option(enum { none, ok, fail }, "hook", "Install hooks") orelse .none;
    const texts = b.option(bool, "texts", "Custom welcome and finish text") orelse false;
    const version = b.option([]const u8, "version", "Package version");
    program_version = version orelse "1.0.0";
    const large = b.option([]const u8, "large", "Absolute path of a large file to install too");
    // A deliberate configuration mistake, to show the error it gives.
    const mistake = b.option(enum { none, name, guid, banner, icon, extra, msi_version, charset }, "mistake", "Configuration mistake to make") orelse .none;
    const deb = b.option(bool, "deb", "Also build the Ubuntu x86_64 package") orelse false;

    const targets: []const zstaller.Target = if (deb)
        &.{ .windows_x86_64, .ubuntu_x86_64 }
    else
        &.{.windows_x86_64};

    const installers = zstaller.addInstallers(b, .{
        .executable = createExe,
        .targets = targets,
        .metadata = .{
            .version = if (mistake == .msi_version) "2026.10.0" else version,
            .name = if (mistake == .name) "my app!" else null,
        },
        .programs = &.{.{ .executable = createTool }},
        .mcp = if (mcp == .none) null else .{
            .name = "zstaller-sample",
            .program = "sample-tool",
            .args = &.{"mcp"},
            .icon = b.path(sample ++ "assets/sample.png"),
            .register = switch (mcp) {
                .none, .optional => .optional,
                .never => .never,
                .always => .always,
            },
        },
        .icon = b.path(sample ++ if (mistake == .icon) "assets/sample.png" else "assets/sample.ico"),
        .extra_files = if (large) |file| b.allocator.dupe(zstaller.ExtraFile, &.{
            .{ .source = b.path(sample ++ "README.md"), .dest = "README.md" },
            .{ .source = .{ .cwd_relative = file }, .dest = "large.bin" },
        }) catch @panic("OOM") else &.{.{
            .source = b.path(sample ++ "README.md"),
            .dest = if (mistake == .extra) "../README.md" else "README.md",
        }},
        .windows = .{
            .publisher = "The zstaller Authors",
            .display_name = if (mistake == .charset) "Zstaller Sample \u{2192} Ω" else "Zstaller Sample",
            .upgrade_code = if (mistake == .guid) "3C1B6E0A-8F7D-4E52" else "{3C1B6E0A-8F7D-4E52-9B1A-6D2C4F8E7A10}",
            .add_to_path = path,
            .desktop_shortcut = desktop,
            .close_running_apps = close,
            .scope = scope,
            .install_root = root,
            .install_dir_name = "Zstaller Sample",
            .allow_install_dir_change = dir_change,
            .after_install = switch (hook) {
                .none => null,
                .ok => .{ .program = "sample-tool.exe", .args = &.{"--register"} },
                // sample-tool exits with an error for a file that is not there.
                .fail => .{ .program = "sample-tool.exe", .args = &.{"no-such-file.txt"} },
            },
            .before_uninstall = if (hook == .ok) .{ .program = "sample-tool.exe", .args = &.{"--unregister"} } else null,
            .wizard = .{
                .welcome_image = if (art == .custom) b.path(sample ++ "assets/wizard-welcome.png") else null,
                .banner_image = if (mistake == .banner)
                    b.path(sample ++ "assets/sample.png")
                else if (art == .custom) b.path(sample ++ "assets/wizard-banner.png") else null,
                .license_file = if (license) b.path(sample ++ "LICENSE") else null,
                .accent_color = accent,
                .welcome_text = if (texts) "Setup will install Zstaller Sample, a tiny program that shows how zstaller packages Zig applications.\n\nIt takes a few seconds." else null,
                .finish_text = if (texts) "Zstaller Sample is ready. Open a new terminal and run sample to try it." else null,
                .launch_on_finish = launch,
            },
        },
        .deb = .{
            .maintainer = "The zstaller Authors <noreply@example.com>",
            .homepage = "https://github.com/ChristianPresley/zstaller",
            .long_description =
            \\Prints its version, the platform it was built for and where it is
            \\installed, to show how zstaller packages a Zig program.
            ,
            .copyright = "2026 The zstaller Authors",
            .desktop_entry = .{ .terminal = true, .icon = b.path(sample ++ "assets/sample.png") },
        },
    });
    b.step("installer", "Build the installers").dependOn(installers.step);
}

var program_version: []const u8 = "1.0.0";

fn createExe(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    return createProgram(b, target, optimize, "sample", "src/main.zig");
}

fn createTool(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    return createProgram(b, target, optimize, "sample-tool", "src/tool.zig");
}

fn createProgram(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    source: []const u8,
) *std.Build.Step.Compile {
    const options = b.addOptions();
    options.addOption([]const u8, "version", program_version);
    const mod = b.createModule(.{
        .root_source_file = b.path(b.fmt("{s}{s}", .{ sample, source })),
        .target = target,
        .optimize = optimize,
        .strip = true,
    });
    mod.addOptions("options", options);
    if (target.result.os.tag == .windows and std.mem.eql(u8, name, "sample")) {
        mod.addWin32ResourceFile(.{
            .file = b.path(sample ++ "assets/sample.rc"),
            .include_paths = &.{b.path(sample ++ "assets")},
        });
    }
    return b.addExecutable(.{ .name = name, .root_module = mod });
}

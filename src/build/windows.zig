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

//! Windows packages: a self-contained EXE installer and an MSI.

const std = @import("std");
const api = @import("api.zig");
const naming = @import("../naming.zig");
const uuid = @import("../uuid.zig");
const cli = @import("../platforms/windows/exe/stub/cli.zig");
const payload = @import("../platforms/windows/exe/payload.zig");
const Build = std.Build;
const LazyPath = Build.LazyPath;

pub fn addPackage(ctx: *const api.Context, format: api.Format) ?LazyPath {
    return switch (format) {
        .exe => addExe(ctx),
        .msi => addMsi(ctx),
        else => unreachable,
    };
}

const installer_manifest =
    \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    \\<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
    \\  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    \\    <security>
    \\      <requestedPrivileges>
    \\        <requestedExecutionLevel level="requireAdministrator" uiAccess="false"/>
    \\      </requestedPrivileges>
    \\    </security>
    \\  </trustInfo>
    \\  <dependency>
    \\    <dependentAssembly>
    \\      <assemblyIdentity type="win32" name="Microsoft.Windows.Common-Controls" version="6.0.0.0" processorArchitecture="*" publicKeyToken="6595b64144ccf1df" language="*"/>
    \\    </dependentAssembly>
    \\  </dependency>
    \\  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    \\    <application>
    \\      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
    \\    </application>
    \\  </compatibility>
    \\  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    \\    <windowsSettings>
    \\      <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true/pm</dpiAware>
    \\      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2</dpiAwareness>
    \\    </windowsSettings>
    \\  </application>
    \\</assembly>
    \\
;

/// The install directory name, checked: folders separated by '\\' (or
/// '/'), each a valid Windows file name.
fn installDirName(ctx: *const api.Context) ?[]const u8 {
    const name = ctx.options.windows.install_dir_name orelse ctx.displayName();
    var it = std.mem.splitAny(u8, name, "\\/");
    while (it.next()) |seg| {
        if (!payload.isSafePath(seg)) {
            ctx.fail("windows.install_dir_name '{s}' is not a valid folder name", .{name});
            return null;
        }
    }
    return std.mem.replaceOwned(u8, ctx.b.allocator, name, "/", "\\") catch @panic("OOM");
}

fn addExe(ctx: *const api.Context) ?LazyPath {
    const b = ctx.b;
    const o = ctx.options;
    const w = o.windows.wizard;
    const exe_name = ctx.binary.out_filename;
    const dir_name = installDirName(ctx) orelse return null;

    const payload_run = ctx.runPack("payload");
    payload_run.addArg("--out");
    const payload_bin = payload_run.addOutputFileArg("payload.bin");
    payload_run.addArg("--file");
    payload_run.addFileArg(ctx.binary_file);
    payload_run.addArg(exe_name);
    for (o.extra_files) |f| {
        payload_run.addArg("--file");
        payload_run.addFileArg(f.source);
        payload_run.addArg(f.dest);
    }

    // Wizard artwork and license text, decoded and checked at build time.
    const wizard_run = ctx.runPack("wizard");
    wizard_run.addArg("--out");
    const wizard_bin = wizard_run.addOutputFileArg("wizard.bin");
    if (w.banner_image) |img| {
        wizard_run.addArgs(&.{ "--banner-option", "windows.wizard.banner_image", "--banner" });
        wizard_run.addFileArg(img);
    }
    if (w.welcome_image) |img| {
        wizard_run.addArgs(&.{ "--welcome-option", "windows.wizard.welcome_image", "--welcome" });
        wizard_run.addFileArg(img);
    }
    if (w.license_file) |file| {
        wizard_run.addArg("--license");
        wizard_run.addFileArg(file);
    }

    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(payload_bin, "payload.bin");
    _ = wf.addCopyFile(wizard_bin, "wizard.bin");
    const payload_zig = wf.add("payload.zig",
        \\pub const bytes = @embedFile("payload.bin");
        \\pub const wizard = @embedFile("wizard.bin");
        \\
    );
    const manifest = wf.add("installer.manifest", installer_manifest);

    const config = b.addOptions();
    config.addOption([]const u8, "name", ctx.meta.name);
    config.addOption([]const u8, "display_name", ctx.displayName());
    config.addOption([]const u8, "version", ctx.meta.version);
    config.addOption([]const u8, "publisher", o.windows.publisher orelse "");
    config.addOption([]const u8, "exe_name", exe_name);
    config.addOption([]const u8, "install_dir_name", dir_name);
    config.addOption(cli.InstallRoot, "install_root", switch (o.windows.install_root) {
        .program_files => .program_files,
        .program_data => .program_data,
        .system_drive => .system_drive,
    });
    config.addOption(bool, "allow_install_dir_change", o.windows.allow_install_dir_change);
    config.addOption(cli.DesktopShortcut, "desktop_shortcut", switch (o.windows.desktop_shortcut) {
        .never => .never,
        .optional => .optional,
        .always => .always,
    });
    config.addOption(u32, "accent_color", w.accent_color);
    config.addOption(?[]const u8, "welcome_text", w.welcome_text);
    config.addOption(?[]const u8, "finish_text", w.finish_text);
    config.addOption(bool, "launch_on_finish", w.launch_on_finish);
    config.addOption([]const u8, "registry_key", b.fmt("zstaller.{s}", .{ctx.meta.name}));
    config.addOption(bool, "start_menu_shortcut", o.windows.start_menu_shortcut);
    config.addOption(bool, "close_running_apps", o.windows.close_running_apps);
    config.addOption(bool, "has_icon", o.icon != null);
    config.addOption([]const u8, "description", ctx.meta.description orelse "");
    config.addOption(cli.PathMode, "add_to_path", switch (o.windows.add_to_path) {
        .never => .never,
        .optional => .optional,
        .always => .always,
    });

    const stub_mod = b.createModule(.{
        .root_source_file = ctx.zb.path("src/platforms/windows/exe/stub/main.zig"),
        .target = ctx.resolved_target,
        .optimize = .ReleaseSmall,
        .strip = if (api.needsSymbols(ctx.resolved_target.result)) false else null,
        .imports = &.{
            .{ .name = "zstaller", .module = ctx.zstallerModule(ctx.resolved_target, .ReleaseSmall) },
            .{ .name = "config", .module = config.createModule() },
            .{ .name = "payload", .module = b.createModule(.{ .root_source_file = payload_zig }) },
        },
    });
    stub_mod.linkSystemLibrary("advapi32", .{});
    stub_mod.linkSystemLibrary("user32", .{});
    stub_mod.linkSystemLibrary("ole32", .{});
    stub_mod.linkSystemLibrary("oleaut32", .{});
    stub_mod.linkSystemLibrary("shell32", .{});
    stub_mod.linkSystemLibrary("gdi32", .{});
    stub_mod.linkSystemLibrary("comctl32", .{});
    if (o.icon) |icon| {
        _ = wf.addCopyFile(icon, "app.ico");
        const rc = wf.add("installer.rc", "1 ICON \"app.ico\"\n");
        stub_mod.addWin32ResourceFile(.{ .file = rc, .include_paths = &.{wf.getDirectory()} });
    }

    const stub = b.addExecutable(.{
        .name = b.fmt("{s}-setup-{s}", .{ ctx.meta.name, ctx.target.slug() }),
        .root_module = stub_mod,
        .win32_manifest = manifest,
    });
    stub.subsystem = .windows;
    return api.normalizePe(b, ctx.pack, ctx.target, stub.getEmittedBin(), stub.out_filename);
}

fn addMsi(ctx: *const api.Context) ?LazyPath {
    const b = ctx.b;
    const o = ctx.options;
    const description = ctx.meta.description orelse {
        ctx.fail("a description is required for MSI packages; add .description to build.zig.zon", .{});
        return null;
    };
    const dir_name = installDirName(ctx) orelse return null;
    const upgrade_code = if (o.windows.upgrade_code) |code| blk: {
        const parsed = uuid.parse(code) catch {
            ctx.fail("windows.upgrade_code '{s}' is not a GUID", .{code});
            return null;
        };
        break :blk uuid.format(parsed);
    } else uuid.format(uuid.v5Parts(uuid.zstaller_namespace, &.{ "upgrade-code", ctx.meta.name }));

    var ver_buf: [32]u8 = undefined;
    const msi_version = if (o.windows.msi_version) |v| blk: {
        if (!naming.isValidMsiVersion(v)) {
            ctx.fail("windows.msi_version '{s}' is not an MSI version: use major.minor.build, at most 255.255.65535", .{v});
            return null;
        }
        break :blk v;
    } else naming.msiVersion(&ver_buf, ctx.meta.semver) orelse {
        ctx.fail("version {s} does not fit an MSI ProductVersion (at most 255.255.65535); set windows.msi_version, e.g. \"26.10.0\" for 2026.10.0, and keep it increasing with every release", .{ctx.meta.version});
        return null;
    };
    const run = ctx.runPack("msi");
    run.addArg("--out");
    const out = run.addOutputFileArg("package.msi");
    ctx.addMtimeArg(run);
    run.addArgs(&.{ "--name", ctx.displayName() });
    run.addArgs(&.{ "--version", b.dupe(msi_version) });
    // The full version keeps pre-releases and builds that share a numeric
    // version apart (`1.0.0-rc.1` and `1.0.0`), so one can upgrade the
    // other.
    run.addArgs(&.{ "--release", ctx.meta.version });
    run.addArgs(&.{ "--manufacturer", ctx.publisher() });
    run.addArgs(&.{ "--description", description });
    run.addArgs(&.{ "--upgrade-code", b.dupe(&upgrade_code) });
    run.addArgs(&.{ "--platform", ctx.target.msiPlatform() });
    run.addArgs(&.{ "--install-dir", dir_name, "--install-root", @tagName(o.windows.install_root) });
    run.addArgs(&.{ "--add-to-path", @tagName(o.windows.add_to_path) });
    if (o.windows.start_menu_shortcut or o.windows.desktop_shortcut != .never) {
        run.addArgs(&.{ "--shortcut-name", ctx.displayName(), "--shortcut-target", ctx.binary.out_filename });
        run.addArgs(&.{ "--start-menu", if (o.windows.start_menu_shortcut) "1" else "0" });
        run.addArgs(&.{ "--desktop-shortcut", @tagName(o.windows.desktop_shortcut) });
    }
    if (ctx.meta.license) |l| run.addArgs(&.{ "--license", l });
    if (o.icon) |icon| {
        run.addArg("--icon");
        run.addFileArg(icon);
    }
    run.addArg("--file");
    run.addFileArg(ctx.binary_file);
    run.addArg(ctx.binary.out_filename);
    for (o.extra_files) |f| {
        run.addArg("--file");
        run.addFileArg(f.source);
        run.addArg(f.dest);
    }
    return out;
}

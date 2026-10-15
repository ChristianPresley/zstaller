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
const PathMode = @import("../platforms/windows/exe/stub/cli.zig").PathMode;
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
    \\  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    \\    <application>
    \\      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
    \\    </application>
    \\  </compatibility>
    \\  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    \\    <windowsSettings>
    \\      <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true</dpiAware>
    \\    </windowsSettings>
    \\  </application>
    \\</assembly>
    \\
;

fn addExe(ctx: *const api.Context) ?LazyPath {
    const b = ctx.b;
    const o = ctx.options;
    const exe_name = ctx.binary.out_filename;

    const payload_run = ctx.runPack("payload");
    payload_run.addArg("--out");
    const payload_bin = payload_run.addOutputFileArg("payload.bin");
    payload_run.addArg("--file");
    payload_run.addArtifactArg(ctx.binary);
    payload_run.addArg(exe_name);
    for (o.extra_files) |f| {
        payload_run.addArg("--file");
        payload_run.addFileArg(f.source);
        payload_run.addArg(f.dest);
    }

    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(payload_bin, "payload.bin");
    const payload_zig = wf.add("payload.zig", "pub const bytes = @embedFile(\"payload.bin\");\n");
    const manifest = wf.add("installer.manifest", installer_manifest);

    const config = b.addOptions();
    config.addOption([]const u8, "name", ctx.meta.name);
    config.addOption([]const u8, "display_name", ctx.displayName());
    config.addOption([]const u8, "version", ctx.meta.version);
    config.addOption([]const u8, "publisher", o.windows.publisher orelse "");
    config.addOption([]const u8, "exe_name", exe_name);
    config.addOption([]const u8, "install_dir_name", o.windows.install_dir_name orelse ctx.displayName());
    config.addOption([]const u8, "registry_key", b.fmt("zstaller.{s}", .{ctx.meta.name}));
    config.addOption(bool, "start_menu_shortcut", o.windows.start_menu_shortcut);
    config.addOption(bool, "has_icon", o.icon != null);
    config.addOption([]const u8, "description", ctx.meta.description orelse "");
    config.addOption(PathMode, "add_to_path", switch (o.windows.add_to_path) {
        .never => .never,
        .optional => .optional,
        .always => .always,
    });

    const stub_mod = b.createModule(.{
        .root_source_file = ctx.zb.path("src/platforms/windows/exe/stub/main.zig"),
        .target = ctx.resolved_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "zstaller", .module = ctx.zstallerModule(ctx.resolved_target, .ReleaseSmall) },
            .{ .name = "config", .module = config.createModule() },
            .{ .name = "payload", .module = b.createModule(.{ .root_source_file = payload_zig }) },
        },
    });
    stub_mod.linkSystemLibrary("advapi32", .{});
    stub_mod.linkSystemLibrary("user32", .{});
    stub_mod.linkSystemLibrary("ole32", .{});
    stub_mod.linkSystemLibrary("shell32", .{});
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
    return stub.getEmittedBin();
}

fn addMsi(ctx: *const api.Context) ?LazyPath {
    const b = ctx.b;
    const o = ctx.options;
    const description = ctx.meta.description orelse {
        ctx.fail("a description is required for MSI packages; add .description to build.zig.zon", .{});
        return null;
    };
    const upgrade_code = if (o.windows.upgrade_code) |code| blk: {
        const parsed = uuid.parse(code) catch {
            ctx.fail("windows.upgrade_code '{s}' is not a GUID", .{code});
            return null;
        };
        break :blk uuid.format(parsed);
    } else uuid.format(uuid.v5Parts(uuid.zstaller_namespace, &.{ "upgrade-code", ctx.meta.name }));

    var ver_buf: [32]u8 = undefined;
    const run = ctx.runPack("msi");
    run.addArg("--out");
    const out = run.addOutputFileArg("package.msi");
    run.addArgs(&.{ "--name", ctx.displayName() });
    run.addArgs(&.{ "--version", b.dupe(naming.msiVersion(&ver_buf, ctx.meta.semver)) });
    run.addArgs(&.{ "--manufacturer", ctx.publisher() });
    run.addArgs(&.{ "--description", description });
    run.addArgs(&.{ "--upgrade-code", b.dupe(&upgrade_code) });
    run.addArgs(&.{ "--platform", ctx.target.msiPlatform() });
    run.addArgs(&.{ "--install-dir", o.windows.install_dir_name orelse ctx.displayName() });
    run.addArgs(&.{ "--add-to-path", @tagName(o.windows.add_to_path) });
    if (o.windows.start_menu_shortcut) {
        run.addArgs(&.{ "--shortcut-name", ctx.displayName(), "--shortcut-target", ctx.binary.out_filename });
    }
    if (ctx.meta.license) |l| run.addArgs(&.{ "--license", l });
    if (o.icon) |icon| {
        run.addArg("--icon");
        run.addFileArg(icon);
    }
    run.addArg("--file");
    run.addArtifactArg(ctx.binary);
    run.addArg(ctx.binary.out_filename);
    for (o.extra_files) |f| {
        run.addArg("--file");
        run.addFileArg(f.source);
        run.addArg(f.dest);
    }
    return out;
}

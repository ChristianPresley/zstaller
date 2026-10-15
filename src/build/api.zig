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

//! Implementation of zstaller's public build API. `build.zig` re-exports
//! the types here and provides `addInstallers`.

const std = @import("std");
const Build = std.Build;
const LazyPath = Build.LazyPath;
const Metadata = @import("../Metadata.zig");
const target_mod = @import("../target.zig");
const naming = @import("../naming.zig");
const Platform = @import("Platform.zig");

pub const Target = target_mod.Target;
pub const Format = target_mod.Format;
pub const Os = target_mod.Os;

/// A file installed next to the application binary.
pub const ExtraFile = struct {
    source: LazyPath,
    /// Path relative to the install directory, using '/' separators, e.g.
    /// `README.md` or `docs/manual.txt`. On Ubuntu, files go to
    /// `/usr/share/<package>/<dest>`.
    dest: []const u8,
};

/// Whether Windows installers add the install directory to the system
/// PATH.
pub const PathMode = enum {
    never,
    /// The EXE asks (or honours /PATH, /NOPATH; silent installs default to
    /// no), and the MSI exposes an ADDTOPATH property that defaults to 1.
    optional,
    always,
};

/// Where the default install directory is created. Users can still pick
/// another folder in the EXE wizard (unless
/// `allow_install_dir_change = false`), with `/D=<dir>`, or with the MSI's
/// `INSTALLDIR` property.
pub const InstallRoot = enum {
    /// `C:\Program Files` (the native one on ARM64 and x64).
    program_files,
    /// `C:\ProgramData`.
    program_data,
    /// The root of the Windows drive, `C:\`.
    system_drive,
};

/// Whether the installers create a desktop shortcut.
pub const DesktopShortcut = enum {
    never,
    /// The EXE wizard offers an unticked checkbox (`/DESKTOP` for silent
    /// installs); the MSI exposes a `DESKTOPSHORTCUT` property that
    /// defaults to 0.
    optional,
    always,
};

/// The look and text of the EXE installer's wizard.
///
/// Images may be PNG or BMP. They use the sizes of the Windows Installer
/// banner and dialog bitmaps, at 100% display scaling, or exactly twice
/// that for sharp output on high-DPI displays; any other size fails the
/// build. Transparent areas show white. Without images, the wizard draws
/// its own artwork from `accent_color` and the application icon.
pub const WizardOptions = struct {
    /// Header of the inner pages: 493x58 (or 986x116). The page title and
    /// subtitle are drawn in dark text over its left part, so keep about
    /// the left two-thirds light and put artwork on the right.
    banner_image: ?LazyPath = null,
    /// Background of the Welcome and Finish pages: 493x312 (or 986x624).
    /// Artwork goes in the left 164 pixels (328 at double size); the
    /// heading and text are drawn in dark text over the rest, so keep it
    /// light.
    welcome_image: ?LazyPath = null,
    /// UTF-8 text shown on a License page that the user must accept
    /// before installing. No License page without it.
    license_file: ?LazyPath = null,
    /// Accent color as 0xRRGGBB, used by the built-in artwork.
    accent_color: u24 = 0x0067C0,
    /// Text of the Welcome page. Defaults to a sentence naming the product
    /// and version.
    welcome_text: ?[]const u8 = null,
    /// Text of the Finish page after a successful install.
    finish_text: ?[]const u8 = null,
    /// Offer a "Launch <product>" checkbox, ticked, on the Finish page.
    launch_on_finish: bool = true,
};

pub const WindowsOptions = struct {
    /// Publisher shown in Apps & Features, and the MSI Manufacturer.
    /// Defaults to the package name.
    publisher: ?[]const u8 = null,
    /// Product name shown to users. Defaults to the package name.
    display_name: ?[]const u8 = null,
    /// Directory created in `install_root`. Defaults to `display_name`.
    /// May contain backslashes for nested folders, e.g. `"Acme\\Widget"`.
    install_dir_name: ?[]const u8 = null,
    /// Folder the default install directory is created in.
    install_root: InstallRoot = .program_files,
    /// Let the user choose another install directory in the EXE wizard.
    /// When false the wizard shows the directory but cannot change it
    /// (`/D=<dir>` still works for scripted installs).
    allow_install_dir_change: bool = true,
    /// MSI UpgradeCode GUID. Keep it constant for the life of the product
    /// so new versions upgrade old ones. Defaults to a GUID derived from
    /// the package name.
    upgrade_code: ?[]const u8 = null,
    add_to_path: PathMode = .optional,
    /// Add a Start Menu shortcut, named after `display_name`, that opens
    /// the application. Both installers remove it on uninstall.
    start_menu_shortcut: bool = true,
    /// Desktop shortcut for all users, named after `display_name`.
    desktop_shortcut: DesktopShortcut = .optional,
    /// What the EXE installer and uninstaller do when programs are still
    /// running from the install directory, whose files Windows cannot
    /// replace or delete. When false, they stop before changing anything
    /// and tell the user which programs to close. When true, they list
    /// each program with its process ID and offer to force-quit them; a
    /// silent (`/S`) run force-quits them without asking. The MSI is not
    /// affected: Windows Installer handles files in use itself.
    close_running_apps: bool = false,
    /// The EXE installer's wizard: images, license and text.
    wizard: WizardOptions = .{},
};

pub const DebOptions = struct {
    /// `Maintainer` field, e.g. `Jane Doe <jane@example.com>`. Required
    /// for .deb output unless `windows.publisher` is set, which is then
    /// used instead.
    maintainer: ?[]const u8 = null,
    section: []const u8 = "utils",
    priority: []const u8 = "optional",
    homepage: ?[]const u8 = null,
    /// `Depends` field. Binaries are statically linked (musl) so this is
    /// normally not needed.
    depends: ?[]const u8 = null,
};

/// Values that replace the ones read from build.zig.zon.
pub const MetadataOverrides = struct {
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    description: ?[]const u8 = null,
    license: ?[]const u8 = null,
};

/// Builds the application binary for one target. Called once per target.
pub const ExecutableFn = *const fn (
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *Build.Step.Compile;

pub const Options = struct {
    executable: ExecutableFn,
    targets: []const Target = Target.all,
    optimize: std.builtin.OptimizeMode = .ReleaseSafe,
    /// Manifest to read metadata from, relative to the build root.
    manifest_path: []const u8 = "build.zig.zon",
    metadata: MetadataOverrides = .{},
    /// Windows `.ico` file used for the installer, the uninstall entry and
    /// the MSI product icon.
    icon: ?LazyPath = null,
    extra_files: []const ExtraFile = &.{},
    windows: WindowsOptions = .{},
    deb: DebOptions = .{},
    /// Subdirectory of the install prefix that receives the installers.
    install_subdir: []const u8 = "installers",
    /// Seconds since the Unix epoch used for every timestamp written into
    /// the packages (archive entries, MSI summary information and cabinet
    /// file dates). Defaults to the `SOURCE_DATE_EPOCH` environment
    /// variable when it is set, else 315532800 (1980-01-01). The value is
    /// passed to the packaging steps as an argument, so changing it
    /// rebuilds the installers instead of reusing cached ones.
    source_date_epoch: ?u64 = null,
};

/// The timestamp used when neither `Options.source_date_epoch` nor
/// `SOURCE_DATE_EPOCH` is set: 1980-01-01, the earliest date a cabinet
/// (MS-DOS format) timestamp can hold.
pub const default_source_date_epoch: u64 = 315532800;

pub const Output = struct {
    target: Target,
    format: Format,
    file_name: []const u8,
    file: LazyPath,
    checksum: LazyPath,
};

pub const Installers = struct {
    /// Depends on every installer and checksum being built and installed.
    step: *Build.Step,
    outputs: []const Output,
};

/// Metadata after applying overrides.
pub const ResolvedMetadata = struct {
    name: []const u8,
    version: []const u8,
    semver: std.SemanticVersion,
    description: ?[]const u8,
    license: ?[]const u8,
};

/// Shared state handed to each platform's `addPackage`.
pub const Context = struct {
    b: *Build,
    /// zstaller's own builder, for paths to its sources.
    zb: *Build,
    pack: *Build.Step.Compile,
    options: *const Options,
    meta: ResolvedMetadata,
    target: Target,
    resolved_target: Build.ResolvedTarget,
    binary: *Build.Step.Compile,
    /// The binary to package. For Windows targets this is `binary` after
    /// `normalizePe`; otherwise it is `binary`'s emitted file.
    binary_file: LazyPath,
    /// Seconds since the Unix epoch for package timestamps.
    source_date_epoch: u64,
    top: *Build.Step,

    /// Records a configuration error. The `installer` step fails with
    /// `msg` when run; other steps are unaffected.
    pub fn fail(ctx: *const Context, comptime fmt: []const u8, args: anytype) void {
        const msg = ctx.b.fmt("zstaller: " ++ fmt, args);
        ctx.top.dependOn(&ctx.b.addFail(msg).step);
    }

    /// A `zstaller-pack` invocation.
    pub fn runPack(ctx: *const Context, command: []const u8) *Build.Step.Run {
        return runPackTool(ctx.b, ctx.pack, command, ctx.target);
    }

    /// Adds `--mtime <source_date_epoch>` to a packaging step. Because it
    /// is an argument, the step's cache key includes it.
    pub fn addMtimeArg(ctx: *const Context, run: *Build.Step.Run) void {
        run.addArgs(&.{ "--mtime", ctx.b.fmt("{d}", .{ctx.source_date_epoch}) });
    }

    /// The `zstaller` library module compiled for `target`.
    pub fn zstallerModule(ctx: *const Context, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *Build.Module {
        return createZstallerModule(ctx.zb, target, optimize);
    }

    pub fn displayName(ctx: *const Context) []const u8 {
        return ctx.options.windows.display_name orelse ctx.meta.name;
    }

    pub fn publisher(ctx: *const Context) []const u8 {
        return ctx.options.windows.publisher orelse ctx.meta.name;
    }
};

/// Whether `target` must be built with debug info to get correct code.
///
/// On aarch64 Windows, the LLVM bundled with Zig 0.16 miscompiles
/// thread-local variable accesses when debug info is stripped (`-fstrip`,
/// or ReleaseSmall's default). Without debug info the object file refers
/// to each variable as an offset into the `.tls$` section, and LLVM writes
/// that whole offset into the `add ..., lsl #12` instruction that carries
/// an IMAGE_REL_ARM64_SECREL_HIGH12A relocation instead of only its upper
/// bits. The linker adds the immediate it finds there, so a variable at
/// offset 8 is accessed at 0x8008, far outside the thread's TLS block, and
/// the program faults at startup. With debug info the references name the
/// variables themselves, the immediates stay zero, and the offsets are
/// right, so zstaller keeps debug info for the application and the
/// installer stub on this target. The debug info goes to a separate .pdb
/// that is not packaged.
pub fn needsSymbols(target: std.Target) bool {
    return target.os.tag == .windows and target.cpu.arch == .aarch64;
}

fn runPackTool(b: *Build, pack: *Build.Step.Compile, command: []const u8, target: Target) *Build.Step.Run {
    const run = b.addRunArtifact(pack);
    run.setName(b.fmt("zstaller-pack {s} ({s})", .{ command, target.slug() }));
    run.addArg(command);
    return run;
}

/// Returns a copy of the PE image `file` whose CodeView GUID and
/// timestamps no longer depend on the paths the linker recorded in its
/// .pdb, so the same source produces the same bytes in any directory. See
/// `src/platforms/windows/pe.zig`.
pub fn normalizePe(b: *Build, pack: *Build.Step.Compile, target: Target, file: LazyPath, basename: []const u8) LazyPath {
    const run = runPackTool(b, pack, "pe-normalize", target);
    run.addFileArg(file);
    return run.addOutputFileArg(basename);
}

pub fn createZstallerModule(zb: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *Build.Module {
    const manifest = @import("../../build.zig.zon");
    const options = zb.addOptions();
    options.addOption([]const u8, "version", manifest.version);
    const mod = zb.createModule(.{
        .root_source_file = zb.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", options);
    return mod;
}

pub fn createPackTool(zb: *Build) *Build.Step.Compile {
    const host = zb.graph.host;
    return zb.addExecutable(.{
        .name = "zstaller-pack",
        .root_module = zb.createModule(.{
            .root_source_file = zb.path("src/pack/main.zig"),
            .target = host,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "zstaller", .module = createZstallerModule(zb, host, .ReleaseSafe) }},
        }),
    });
}

/// `addInstallers` with an explicit zstaller builder, so zstaller's own
/// build.zig can use the API on itself.
pub fn addInstallersWith(b: *Build, zb: *Build, options: Options) Installers {
    const top = b.allocator.create(Build.Step) catch @panic("OOM");
    top.* = .init(.{ .id = .custom, .name = "zstaller installers", .owner = b });
    const opts = b.allocator.create(Options) catch @panic("OOM");
    opts.* = options;

    const meta = resolveMetadata(b, opts.*) catch |err| {
        const msg = switch (err) {
            error.ReadFailed => b.fmt("zstaller: cannot read {s}", .{opts.manifest_path}),
            else => b.fmt("zstaller: {s}: {s}", .{ opts.manifest_path, @errorName(err) }),
        };
        top.dependOn(&b.addFail(msg).step);
        return .{ .step = top, .outputs = &.{} };
    };

    const epoch = opts.source_date_epoch orelse
        if (b.graph.environ_map.get("SOURCE_DATE_EPOCH")) |value|
            std.fmt.parseInt(u64, value, 10) catch {
                top.dependOn(&b.addFail(b.fmt("zstaller: SOURCE_DATE_EPOCH is not a non-negative integer: '{s}'", .{value})).step);
                return .{ .step = top, .outputs = &.{} };
            }
        else
            default_source_date_epoch;

    const pack = createPackTool(zb);
    var outputs: std.ArrayList(Output) = .empty;

    for (opts.targets) |t| {
        const resolved = b.resolveTargetQuery(t.query());
        const binary = opts.executable(b, resolved, opts.optimize);
        if (needsSymbols(resolved.result)) binary.root_module.strip = false;
        const binary_file = if (resolved.result.os.tag == .windows)
            normalizePe(b, pack, t, binary.getEmittedBin(), binary.out_filename)
        else
            binary.getEmittedBin();
        const ctx: Context = .{
            .b = b,
            .zb = zb,
            .pack = pack,
            .options = opts,
            .meta = meta,
            .target = t,
            .resolved_target = resolved,
            .binary = binary,
            .binary_file = binary_file,
            .source_date_epoch = epoch,
            .top = top,
        };
        for (t.formats()) |format| {
            const file = Platform.addPackage(&ctx, format) orelse continue;
            const file_name = naming.installerFileName(b.allocator, meta.name, meta.version, t, format) catch @panic("OOM");
            const sum_name = naming.checksumFileName(b.allocator, file_name) catch @panic("OOM");

            const sum_run = ctx.runPack("checksum");
            sum_run.addFileArg(file);
            const checksum = sum_run.addOutputFileArg(sum_name);
            sum_run.addArg(file_name);

            const dir: Build.InstallDir = .{ .custom = opts.install_subdir };
            top.dependOn(&b.addInstallFileWithDir(file, dir, file_name).step);
            top.dependOn(&b.addInstallFileWithDir(checksum, dir, sum_name).step);
            outputs.append(b.allocator, .{
                .target = t,
                .format = format,
                .file_name = file_name,
                .file = file,
                .checksum = checksum,
            }) catch @panic("OOM");
        }
    }
    return .{ .step = top, .outputs = outputs.items };
}

fn resolveMetadata(b: *Build, options: Options) !ResolvedMetadata {
    const io = b.graph.io;
    var diag: Metadata.Diagnostic = .{};
    var m = Metadata.load(b.allocator, io, b.build_root.handle, options.manifest_path, &diag) catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM"),
        error.InvalidSyntax, error.NotAStruct, error.MissingField, error.InvalidField => {
            std.debug.print("zstaller: {s}: {f}\n", .{ options.manifest_path, diag });
            return err;
        },
        else => return error.ReadFailed,
    };
    const o = options.metadata;
    const version = o.version orelse m.version_string;
    const semver = std.SemanticVersion.parse(version) catch return error.InvalidVersionOverride;
    m.name = o.name orelse m.name;
    return .{
        .name = m.name,
        .version = version,
        .semver = semver,
        .description = o.description orelse m.description,
        .license = o.license orelse m.license,
    };
}

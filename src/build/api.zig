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
const mcp = @import("mcp.zig");

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
    /// On unless the user says otherwise: the EXE wizard shows a ticked
    /// checkbox, silent EXE installs honour /NOPATH, and the MSI exposes an
    /// ADDTOPATH property that defaults to 1.
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

/// Who the Windows installers install for.
pub const Scope = enum {
    /// Every user of the machine. Installing needs administrator rights
    /// (a UAC prompt); files go in `install_root`, shortcuts and the PATH
    /// entry are for all users, and the registration is in
    /// HKEY_LOCAL_MACHINE.
    machine,
    /// Only the user who installs, without administrator rights: files go
    /// in `%LOCALAPPDATA%\Programs\<install_dir_name>`, with that user's
    /// Start Menu, desktop, PATH and HKEY_CURRENT_USER. `install_root`
    /// does not apply. Suits developer tools and apps users install
    /// themselves.
    user,
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
    /// Install for every user (administrator rights needed) or only for
    /// the user who installs. See `Scope`.
    scope: Scope = .machine,
    /// Let the user choose another install directory in the EXE wizard.
    /// When false the wizard shows the directory but cannot change it
    /// (`/D=<dir>` still works for scripted installs).
    allow_install_dir_change: bool = true,
    /// MSI UpgradeCode GUID. Keep it constant for the life of the product
    /// so new versions upgrade old ones. Defaults to a GUID derived from
    /// the package name.
    upgrade_code: ?[]const u8 = null,
    /// MSI ProductVersion, `major.minor.build` with limits 255.255.65535.
    /// Defaults to the package version without its pre-release and build
    /// parts. Set it when the package version does not fit, for example
    /// calendar versions such as `2026.10.0`. It must grow with every
    /// release, or upgrades stop working.
    msi_version: ?[]const u8 = null,
    /// Whether the install folder is added to the system PATH. See
    /// `PathMode`.
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
    /// A program to run once the files are installed, for example to
    /// register a service or write machine-wide configuration. It runs
    /// after every install, upgrade and repair, so it must cope with
    /// running more than once. If it exits with a non-zero code, the
    /// install fails: the EXE reports it and leaves the files in place
    /// (the user can uninstall), and the MSI rolls the install back.
    after_install: ?InstallCommand = null,
    /// A program to run when the application is uninstalled, before its
    /// files are removed, to undo what `after_install` did. Upgrades do
    /// not run it. Its exit code is ignored, so a failing hook never
    /// blocks uninstalling.
    before_uninstall: ?InstallCommand = null,
    /// The EXE installer's wizard: images, license and text.
    wizard: WizardOptions = .{},
};

/// A program the Windows installers run from the install directory, which
/// is also its working directory. It runs with administrator rights, as
/// the installing user for the EXE and as LocalSystem for the MSI, without
/// a console window, and the installer waits for it to exit.
pub const InstallCommand = struct {
    /// Installed file name of an `.exe`: the application, one of
    /// `programs`, or an `extra_files` destination.
    program: []const u8,
    /// Its arguments, quoted for you. At most 255 characters in all.
    args: []const []const u8 = &.{},
};

/// The application, or one of its programs, as an MCP (Model Context
/// Protocol) server: a program that AI tools such as Claude start and talk
/// to over standard input and output.
pub const McpOptions = struct {
    /// Server name shown in the AI tools: letters, digits, '_' and '-', at
    /// most 64. Defaults to the package name.
    name: ?[]const u8 = null,
    /// The program that runs the server, by file name without `.exe`: one
    /// of `programs`. Null: the application itself.
    program: ?[]const u8 = null,
    /// Arguments that start it as a server, e.g. `&.{ "mcp", "--stdio" }`.
    args: []const []const u8 = &.{},
    /// Environment variables for it. They end up in plain-text
    /// configuration files, so never put secrets here.
    env: []const McpEnv = &.{},
    /// Also build `<name>-<version>-<target>.mcpb`, an MCP bundle that
    /// Claude Desktop installs with a double-click and the MCP Registry
    /// can list. It holds the server program only.
    bundle: bool = true,
    /// Square PNG icon for the bundle, ideally 512x512.
    icon: ?LazyPath = null,
    /// Register the server with the AI tools of the user who installs.
    /// The installers add a small program, `zstaller-mcp`, next to the
    /// application: on Windows Setup runs it as the user who installs and
    /// the uninstaller runs it to remove the entries again (for every
    /// user); on Ubuntu users run `/usr/lib/<package>/zstaller-mcp
    /// register` themselves and removing the package unregisters.
    /// `.optional`: on by default, with a checkbox in Setup, `/NOMCP` for
    /// silent installs and `REGISTERMCP=0` for the MSI.
    register: McpRegister = .optional,
    /// Which AI tools to register with, for those the user has installed.
    clients: McpClients = .{},
};

pub const McpEnv = struct {
    name: []const u8,
    value: []const u8,
};

pub const McpRegister = enum { never, optional, always };

/// AI tools that keep their MCP servers in a per-user file.
pub const McpClients = struct {
    /// `~/.claude.json`.
    claude_code: bool = true,
    /// `mcp.json` in VS Code's user settings folder.
    vscode: bool = true,
    vscode_insiders: bool = false,
    /// `claude_desktop_config.json`. The `.mcpb` bundle is the usual way
    /// to add a server to Claude Desktop.
    claude_desktop: bool = false,
    /// `~/.cursor/mcp.json`.
    cursor: bool = false,
    /// `~/.codeium/windsurf/mcp_config.json`.
    windsurf: bool = false,
};

pub const DebOptions = struct {
    /// `Maintainer` field, e.g. `Jane Doe <jane@example.com>`. Required
    /// for .deb output unless `windows.publisher` is set in that same
    /// `Name <email>` form, which is then used instead.
    maintainer: ?[]const u8 = null,
    /// `Section` field, e.g. `utils`, `devel`, `net`.
    section: []const u8 = "utils",
    /// `Priority` field.
    priority: []const u8 = "optional",
    /// `Homepage` field: the project's URL.
    homepage: ?[]const u8 = null,
    /// `Depends` field. Binaries are statically linked (musl) so this is
    /// normally not needed.
    depends: ?[]const u8 = null,
    /// The `Copyright` line of `/usr/share/doc/<package>/copyright`,
    /// e.g. `"2026 Example Corp"`. Defaults to `windows.publisher`, else
    /// the package name; Debian expects a year in it.
    copyright: ?[]const u8 = null,
    /// Text that follows the one-line description in `apt show`. Blank
    /// lines separate paragraphs. Debian expects one.
    long_description: ?[]const u8 = null,
    /// Files installed at absolute paths: a man page, shell completions, a
    /// systemd unit, a default configuration. Files in `/etc` are
    /// configuration files: dpkg keeps the administrator's changes on
    /// upgrade.
    files: []const DebFile = &.{},
    /// A menu entry, for applications with a window.
    desktop_entry: ?DesktopEntry = null,
    /// Maintainer scripts that dpkg runs on install, upgrade and removal,
    /// for example to enable a systemd unit. Each must start with `#!`.
    scripts: DebScripts = .{},
};

/// A file in a .deb package at an absolute path.
pub const DebFile = struct {
    source: LazyPath,
    /// Absolute install path, e.g. `/usr/share/man/man1/myapp.1` or
    /// `/etc/myapp/config.toml`.
    dest: []const u8,
    /// Permission bits: 0o755 for programs and scripts.
    mode: u32 = 0o644,
};

/// A freedesktop.org menu entry, written to
/// `/usr/share/applications/<package>.desktop`. Its name is the display
/// name, its comment the description, and it starts the application.
pub const DesktopEntry = struct {
    /// Menu categories, each followed by `;`, e.g. `"Development;IDE;"`.
    categories: []const u8 = "Utility;",
    /// Start the application in a terminal window.
    terminal: bool = false,
    /// Square PNG icon, ideally 256x256 pixels, installed in the hicolor
    /// icon theme. Without one, the menu shows a generic icon.
    icon: ?LazyPath = null,
};

/// .deb maintainer scripts; see deb-postinst(5), deb-prerm(5) and
/// friends. dpkg passes the action (`configure`, `remove`, `upgrade`, ...)
/// as the first argument.
pub const DebScripts = struct {
    preinst: ?LazyPath = null,
    postinst: ?LazyPath = null,
    prerm: ?LazyPath = null,
    postrm: ?LazyPath = null,
};

/// Values that replace the ones read from build.zig.zon.
pub const MetadataOverrides = struct {
    /// Package name: letters, digits, '_', '-' and '.'. Use it for names
    /// Zig does not accept as `.name` in build.zig.zon, such as `my-app`.
    /// It also changes the default MSI upgrade code, so set
    /// `windows.upgrade_code` before renaming a released package.
    name: ?[]const u8 = null,
    /// Semantic version, e.g. one computed from `git describe`.
    version: ?[]const u8 = null,
    /// One-line description. Required for MSI and .deb output.
    description: ?[]const u8 = null,
    /// SPDX license identifier, e.g. `MIT`.
    license: ?[]const u8 = null,
};

/// Builds the application binary for one target. Called once per target.
///
/// It is a plain function, so it cannot use modules or dependencies that
/// `build` created for the native target. Create every module it needs
/// inside it, with the `target` and `optimize` it is given.
pub const ExecutableFn = *const fn (
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *Build.Step.Compile;

/// Another program installed next to the application, such as a
/// command-line tool beside a GUI, or a helper or service it starts.
pub const Program = struct {
    /// Builds it for one target, like `Options.executable`. Its file name
    /// must differ from the application's and every other program's.
    executable: ExecutableFn,
    /// Name of a Start Menu shortcut to it on Windows. Null: no shortcut,
    /// as suits command-line tools and helpers.
    shortcut: ?[]const u8 = null,
};

/// A `Program` built for one target.
pub const BuiltProgram = struct {
    /// Its file name, e.g. `myapp-cli.exe`.
    name: []const u8,
    /// The binary to package (normalized and signed like the
    /// application's).
    file: LazyPath,
    shortcut: ?[]const u8,
};

/// A file `Options.sign` is asked to sign.
pub const SignRequest = struct {
    /// The unsigned file.
    file: LazyPath,
    /// Its file name, such as `myapp.exe` or
    /// `myapp-1.2.0-windows-x86_64.msi`: the name to give the signed copy.
    basename: []const u8,
    kind: Kind,
    target: Target,

    pub const Kind = enum {
        /// The application's Windows executable, before it goes into the
        /// EXE installer and the MSI.
        windows_binary,
        /// The EXE installer. The copy it installs as `uninstall.exe` is
        /// the same file, so it carries the same signature.
        windows_setup,
        /// The MSI package.
        windows_msi,
    };
};

/// Returns a signed copy of `request.file`, typically the output of a Run
/// step that runs `signtool` or `osslsigncode`. The copy replaces the
/// original in the rest of the build, so the installers contain the
/// signed application and checksums are computed over the signed
/// installers. Like `ExecutableFn`, it is a plain function: options it
/// needs (a certificate, say) come from `b` or from the environment.
pub const SignFn = *const fn (b: *Build, request: SignRequest) LazyPath;

pub const Options = struct {
    /// Builds the application for one target. See `ExecutableFn`.
    executable: ExecutableFn,
    /// The targets to package. Each Windows target gets an MSI and an EXE,
    /// each Ubuntu target a .deb.
    targets: []const Target = Target.all,
    /// Optimize mode of the packaged binaries. ReleaseSafe keeps debug
    /// info unless the `executable` function sets `.strip = true`.
    optimize: std.builtin.OptimizeMode = .ReleaseSafe,
    /// Manifest to read metadata from, relative to the build root.
    manifest_path: []const u8 = "build.zig.zon",
    /// Replacements for the metadata read from the manifest.
    metadata: MetadataOverrides = .{},
    /// Windows `.ico` file used for the installer, the uninstall entry and
    /// the MSI product icon.
    icon: ?LazyPath = null,
    /// More programs installed next to the application: in the install
    /// folder on Windows, in `/usr/bin` on Ubuntu.
    programs: []const Program = &.{},
    /// Files installed next to the application (`/usr/share/<package>/`
    /// on Ubuntu).
    extra_files: []const ExtraFile = &.{},
    /// Settings for the Windows EXE and MSI installers.
    windows: WindowsOptions = .{},
    /// Settings for the Ubuntu .deb packages.
    deb: DebOptions = .{},
    /// Package the application as an MCP server. See `McpOptions`.
    mcp: ?McpOptions = null,
    /// Signs Windows files: the application, then the finished EXE and
    /// MSI installers. Null leaves them unsigned. See `SignFn`.
    sign: ?SignFn = null,
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

/// One installer built by `addInstallers`.
pub const Output = struct {
    target: Target,
    /// `.msi`, `.exe` or `.deb`.
    format: Format,
    /// The name it is installed under, e.g. `myapp-1.2.0-windows-x86_64.msi`.
    file_name: []const u8,
    /// The installer in the build cache, for further steps such as
    /// uploading.
    file: LazyPath,
    /// Its `.sha256` file, in `sha256sum` format.
    checksum: LazyPath,
};

pub const Installers = struct {
    /// Depends on every installer and checksum being built and installed.
    step: *Build.Step,
    /// Every installer, in target order.
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
    /// `options.programs`, built for this target.
    programs: []const BuiltProgram,
    /// Seconds since the Unix epoch for package timestamps.
    source_date_epoch: u64,
    top: *Build.Step,
    /// Messages already reported, so a problem shared by every target is
    /// reported once.
    failures: *std.StringHashMapUnmanaged(void),
    /// `options.icon`, once checked to be a Windows .ico file. A PNG
    /// renamed to .ico would otherwise go into the MSI unnoticed and fail
    /// the EXE build with an error about a generated resource file.
    icon: ?LazyPath,
    /// `zstaller-mcp` for this target, when `options.mcp.register` asks
    /// for it (see `mcp.addHelper`).
    mcp_helper: ?LazyPath = null,

    /// Records a configuration error. The `installer` step fails with
    /// `msg` when run; other steps are unaffected.
    pub fn fail(ctx: *const Context, comptime fmt: []const u8, args: anytype) void {
        failOnce(ctx.b, ctx.top, ctx.failures, ctx.b.fmt("zstaller: " ++ fmt, args));
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

fn failOnce(b: *Build, top: *Build.Step, failures: *std.StringHashMapUnmanaged(void), msg: []const u8) void {
    const seen = failures.getOrPut(b.allocator, msg) catch @panic("OOM");
    if (seen.found_existing) return;
    top.dependOn(&b.addFail(msg).step);
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
            // The standard library follows the root module's mode, and
            // compiling it in ReleaseSafe dominates a fresh build (about 38s
            // here against 12s). zstaller's own code keeps its safety checks
            // in the module below; packing speed is the same either way.
            .optimize = .ReleaseSmall,
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

    const failures = b.allocator.create(std.StringHashMapUnmanaged(void)) catch @panic("OOM");
    failures.* = .empty;

    const meta = switch (resolveMetadata(b, opts.*)) {
        .ok => |m| m,
        .failed => |msg| {
            top.dependOn(&b.addFail(b.fmt("zstaller: {s}", .{msg})).step);
            return .{ .step = top, .outputs = &.{} };
        },
    };
    var config_ok = true;
    for (opts.extra_files, 0..) |f, i| {
        if (extraFileProblem(opts.extra_files, i)) |problem| {
            failOnce(b, top, failures, b.fmt("zstaller: extra_files[{d}].dest '{s}' {s}", .{ i, f.dest, problem }));
            config_ok = false;
        }
    }
    if (!config_ok) return .{ .step = top, .outputs = &.{} };

    const epoch = opts.source_date_epoch orelse
        if (b.graph.environ_map.get("SOURCE_DATE_EPOCH")) |value|
            std.fmt.parseInt(u64, value, 10) catch {
                top.dependOn(&b.addFail(b.fmt("zstaller: SOURCE_DATE_EPOCH is not a non-negative integer: '{s}'", .{value})).step);
                return .{ .step = top, .outputs = &.{} };
            }
        else
            default_source_date_epoch;

    const pack = createPackTool(zb);
    const icon: ?LazyPath = if (opts.icon) |path| blk: {
        const run = b.addRunArtifact(pack);
        run.setName("zstaller-pack check-icon");
        run.addArg("check-icon");
        run.addFileArg(path);
        run.addArg(path.getDisplayName());
        break :blk run.addOutputFileArg("icon.ico");
    } else null;
    var outputs: std.ArrayList(Output) = .empty;

    for (opts.targets) |t| {
        const resolved = b.resolveTargetQuery(t.query());
        const binary = opts.executable(b, resolved, opts.optimize);
        const binary_file = packagedBinary(b, opts, pack, t, resolved, binary);
        const programs = b.allocator.alloc(BuiltProgram, opts.programs.len) catch @panic("OOM");
        for (opts.programs, programs) |program, *built| {
            const program_binary = program.executable(b, resolved, opts.optimize);
            built.* = .{
                .name = program_binary.out_filename,
                .file = packagedBinary(b, opts, pack, t, resolved, program_binary),
                .shortcut = program.shortcut,
            };
        }
        var ctx: Context = .{
            .b = b,
            .zb = zb,
            .pack = pack,
            .options = opts,
            .meta = meta,
            .target = t,
            .resolved_target = resolved,
            .binary = binary,
            .binary_file = binary_file,
            .programs = programs,
            .source_date_epoch = epoch,
            .top = top,
            .failures = failures,
            .icon = icon,
        };
        if (!programsFit(&ctx)) continue;
        if (opts.mcp) |m| if (m.register != .never) {
            ctx.mcp_helper = mcp.addHelper(&ctx) orelse continue;
        };
        const mcpb: []const Format = if (opts.mcp) |m| (if (m.bundle) &.{.mcpb} else &.{}) else &.{};
        const formats = std.mem.concat(b.allocator, Format, &.{ t.formats(), mcpb }) catch @panic("OOM");
        for (formats) |format| {
            const package = (if (format == .mcpb) mcp.addBundle(&ctx) else Platform.addPackage(&ctx, format)) orelse continue;
            const file_name = naming.installerFileName(b.allocator, meta.name, meta.version, t, format) catch @panic("OOM");
            const file = switch (format) {
                .exe => signed(b, opts, package, file_name, .windows_setup, t),
                .msi => signed(b, opts, package, file_name, .windows_msi, t),
                .deb, .mcpb => package,
            };
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

/// The file to package for `binary`: on Windows normalized (see
/// `normalizePe`) and signed with `options.sign`.
pub fn packagedBinary(b: *Build, options: *const Options, pack: *Build.Step.Compile, t: Target, resolved: Build.ResolvedTarget, binary: *Build.Step.Compile) LazyPath {
    if (needsSymbols(resolved.result)) binary.root_module.strip = false;
    if (resolved.result.os.tag != .windows) return binary.getEmittedBin();
    const normalized = normalizePe(b, pack, t, binary.getEmittedBin(), binary.out_filename);
    return signed(b, options, normalized, binary.out_filename, .windows_binary, t);
}

/// Checks that the application, `programs`, `extra_files` and the
/// uninstaller do not share a file name, and that program shortcuts have
/// usable, distinct names. Reports what does not and returns false.
fn programsFit(ctx: *const Context) bool {
    const opts = ctx.options;
    const windows = ctx.resolved_target.result.os.tag == .windows;
    var ok = true;
    for (ctx.programs, 0..) |p, i| {
        if (std.ascii.eqlIgnoreCase(p.name, ctx.binary.out_filename) or (windows and std.ascii.eqlIgnoreCase(p.name, "uninstall.exe")) or
            isHelperName(ctx, p.name))
        {
            ctx.fail("programs[{d}] is named '{s}', like a file the installer writes itself; give it another name", .{ i, p.name });
            ok = false;
        }
        for (ctx.programs[0..i], 0..) |other, j| {
            if (std.ascii.eqlIgnoreCase(p.name, other.name)) {
                ctx.fail("programs[{d}] and programs[{d}] are both named '{s}'", .{ j, i, p.name });
                ok = false;
            }
        }
        if (p.shortcut) |name| {
            if (name.len == 0 or std.mem.indexOfAny(u8, name, "\\/:*?\"<>|") != null or name[name.len - 1] == '.' or name[name.len - 1] == ' ') {
                ctx.fail("programs[{d}].shortcut '{s}' cannot be a file name on Windows", .{ i, name });
                ok = false;
            }
            const main_shortcut = opts.windows.start_menu_shortcut and std.ascii.eqlIgnoreCase(name, ctx.displayName());
            if (main_shortcut) {
                ctx.fail("programs[{d}].shortcut '{s}' is the name of the application's own shortcut", .{ i, name });
                ok = false;
            }
            for (ctx.programs[0..i], 0..) |other, j| {
                if (other.shortcut != null and std.ascii.eqlIgnoreCase(name, other.shortcut.?)) {
                    ctx.fail("programs[{d}] and programs[{d}] both have the shortcut '{s}'", .{ j, i, name });
                    ok = false;
                }
            }
        }
    }
    for (opts.extra_files, 0..) |f, i| {
        // On Windows everything shares the install folder, so a folder
        // named like one of those files clashes too.
        const top = if (windows) f.dest[0 .. std.mem.indexOfScalar(u8, f.dest, '/') orelse f.dest.len] else f.dest;
        var clash = std.ascii.eqlIgnoreCase(top, ctx.binary.out_filename) or
            (windows and (std.ascii.eqlIgnoreCase(top, "uninstall.exe") or std.ascii.eqlIgnoreCase(top, ".zstaller-files"))) or
            (windows and isHelperName(ctx, top));
        for (ctx.programs) |p| clash = clash or (windows and std.ascii.eqlIgnoreCase(top, p.name));
        if (clash) {
            ctx.fail("extra_files[{d}].dest '{s}' is, or is in a folder named like, a file the installer writes itself", .{ i, f.dest });
            ok = false;
        }
    }
    return ok;
}

/// Whether `name` is the file name of `zstaller-mcp`, when it is installed.
fn isHelperName(ctx: *const Context, name: []const u8) bool {
    const m = ctx.options.mcp orelse return false;
    if (m.register == .never) return false;
    return std.ascii.eqlIgnoreCase(name, mcp.helperFileName(ctx));
}

/// `file` signed by `options.sign`, or `file` itself without one.
fn signed(b: *Build, options: *const Options, file: LazyPath, basename: []const u8, kind: SignRequest.Kind, target: Target) LazyPath {
    const sign = options.sign orelse return file;
    return sign(b, .{ .file = file, .basename = basename, .kind = kind, .target = target });
}

const MetadataResult = union(enum) {
    ok: ResolvedMetadata,
    /// What is wrong, for the `installer` step's error.
    failed: []const u8,
};

/// Reads the manifest and applies `options.metadata`. Problems are
/// returned as messages and reported only when the `installer` step runs,
/// so `zig build` and `zig build test` stay quiet.
fn resolveMetadata(b: *Build, options: Options) MetadataResult {
    const io = b.graph.io;
    const path = options.manifest_path;
    var diag: Metadata.Diagnostic = .{};
    var m = Metadata.load(b.allocator, io, b.build_root.handle, path, &diag) catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM"),
        error.InvalidSyntax, error.NotAStruct, error.MissingField, error.InvalidField => return .{ .failed = b.fmt("{s}: {f}", .{ path, diag }) },
        else => return .{ .failed = b.fmt("cannot read {s}: {t}", .{ path, err }) },
    };
    const o = options.metadata;
    if (o.name) |name| {
        if (!Metadata.isValidName(name)) return .{ .failed = b.fmt(
            "metadata.name '{s}' is not a valid package name: use letters, digits, '_', '-' and '.'",
            .{name},
        ) };
        m.name = name;
    }
    const version = o.version orelse m.version_string;
    const semver = std.SemanticVersion.parse(version) catch return .{ .failed = b.fmt(
        "metadata.version '{s}' is not a semantic version (MAJOR.MINOR.PATCH, e.g. 1.2.0 or 1.2.0-rc.1)",
        .{version},
    ) };
    if (o.description) |d| if (d.len == 0) return .{ .failed = "metadata.description must not be empty" };
    return .{ .ok = .{
        .name = m.name,
        .version = version,
        .semver = semver,
        .description = o.description orelse m.description,
        .license = o.license orelse m.license,
    } };
}

/// What is wrong with `files[i].dest`, or null when it is a valid install
/// path not used by an earlier entry.
fn extraFileProblem(files: []const ExtraFile, i: usize) ?[]const u8 {
    if (naming.installPathProblem(files[i].dest)) |problem| return problem;
    for (files[0..i]) |earlier| {
        if (std.ascii.eqlIgnoreCase(earlier.dest, files[i].dest)) return "is used by more than one extra file";
        if (isFolderOf(earlier.dest, files[i].dest) or isFolderOf(files[i].dest, earlier.dest))
            return "is a file and also the folder of another extra file";
    }
    return null;
}

/// Whether `path` is inside the folder `dir` (both relative, with `/`).
fn isFolderOf(dir: []const u8, path: []const u8) bool {
    return path.len > dir.len and path[dir.len] == '/' and std.ascii.eqlIgnoreCase(path[0..dir.len], dir);
}

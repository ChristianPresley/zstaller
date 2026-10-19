---
title: Build API
lead: Everything zstaller exports to build.zig. One function does the work; the rest are the types of its options and results.
---

## addInstallers

```zig
const zstaller = @import("zstaller");

pub fn addInstallers(b: *std.Build, options: zstaller.Options) zstaller.Installers
```

Adds the steps that cross-compile your program for each target and package it, and returns them. Call it once from `build`, then hang a step on the result:

```zig
const installers = zstaller.addInstallers(b, .{ .executable = createExe });
b.step("installer", "Build installers").dependOn(installers.step);
```

`build.zig.zon` is read when `build` runs (the path is `options.manifest_path`). Mistakes in the options do not stop `build` or other steps: they fail the installer step when it runs, with a message naming the option. See [Build errors]({{ '/reference/build-errors/' | relative_url }}).

`zig build docs` in the zstaller repository builds an API reference from the doc comments, into `zig-out/docs`.

## Options

The full list, with defaults, is on [All options]({{ '/reference/options/' | relative_url }}). The fields are:

```zig
pub const Options = struct {
    executable: ExecutableFn,
    targets: []const Target = Target.all,
    optimize: std.builtin.OptimizeMode = .ReleaseSafe,
    manifest_path: []const u8 = "build.zig.zon",
    metadata: MetadataOverrides = .{},
    icon: ?LazyPath = null,
    programs: []const Program = &.{},
    extra_files: []const ExtraFile = &.{},
    windows: WindowsOptions = .{},
    deb: DebOptions = .{},
    mcp: ?McpOptions = null,
    sign: ?SignFn = null,
    install_subdir: []const u8 = "installers",
    source_date_epoch: ?u64 = null,
};
```

## ExecutableFn

```zig
pub const ExecutableFn = *const fn (
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile;
```

Builds your program for one target. zstaller calls it once per target (and `programs[i].executable` once per target for each program). It is a plain function pointer, so it cannot use modules or dependencies that `build` created for the native target: create every module it needs inside it, with the `target` and `optimize` it is given.

```zig
fn createExe(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    // A dependency's module, created for this target.
    const dep = b.dependency("somelib", .{ .target = target, .optimize = optimize });
    return b.addExecutable(.{
        .name = "myapp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
            .imports = &.{.{ .name = "somelib", .module = dep.module("somelib") }},
        }),
    });
}
```

## Target

```zig
pub const Target = enum { windows_x86_64, windows_aarch64, ubuntu_x86_64, ubuntu_aarch64 };
```

| Target | Zig target | Packages |
| --- | --- | --- |
| `windows_x86_64` | `x86_64-windows-gnu` | `.exe`, `.msi` (+ `.mcpb`) |
| `windows_aarch64` | `aarch64-windows-gnu` | `.exe`, `.msi` (+ `.mcpb`) |
| `ubuntu_x86_64` | `x86_64-linux-musl` | `.deb` (+ `.mcpb`) |
| `ubuntu_aarch64` | `aarch64-linux-musl` | `.deb` (+ `.mcpb`) |

`Target.all` is every target, the default.

## Installers

```zig
pub const Installers = struct {
    /// Depends on every installer and checksum being built and installed.
    step: *std.Build.Step,
    /// Every installer, in target order.
    outputs: []const Output,
};

pub const Output = struct {
    target: Target,
    format: Format,           // .deb, .exe, .msi or .mcpb
    file_name: []const u8,    // e.g. "myapp-1.2.0-windows-x86_64.msi"
    file: LazyPath,           // the installer, in the build cache
    checksum: LazyPath,       // its .sha256 file
};
```

### outputs

When the configuration has a mistake, `outputs` is empty and `step` fails with the message. Otherwise `outputs` lets later build steps use the packages, for example to collect the MSIs for an upload step:

```zig
const upload = b.step("upload", "Copy the MSIs for upload");
for (installers.outputs) |out| {
    if (out.format != .msi) continue;
    upload.dependOn(&b.addInstallFile(out.file, b.fmt("upload/{s}", .{out.file_name})).step);
    upload.dependOn(&b.addInstallFile(out.checksum, b.fmt("upload/{s}.sha256", .{out.file_name})).step);
}
```

## Program

```zig
pub const Program = struct {
    executable: ExecutableFn,
    /// Name of a Start Menu shortcut to it on Windows. Null: no shortcut.
    shortcut: ?[]const u8 = null,
};
```

See [Multiple programs and files]({{ '/guides/programs-and-files/' | relative_url }}).

## SignFn and SignRequest

```zig
pub const SignFn = *const fn (b: *std.Build, request: SignRequest) LazyPath;

pub const SignRequest = struct {
    file: LazyPath,        // the unsigned file
    basename: []const u8,  // the name to give the signed copy
    kind: Kind,            // .windows_binary, .windows_setup or .windows_msi
    target: Target,
};
```

Return a signed copy of `request.file`, typically the output of a Run step. See [Code signing]({{ '/guides/code-signing/' | relative_url }}).

## Other types

All exported from the `zstaller` module, and described on [All options]({{ '/reference/options/' | relative_url }}):

`MetadataOverrides`, `ExtraFile`, `WindowsOptions`, `WizardOptions`, `InstallRoot`, `Scope`, `PathMode`, `DesktopShortcut`, `InstallCommand`, `DebOptions`, `DebFile`, `DesktopEntry`, `DebScripts`, `McpOptions`, `McpEnv`, `McpRegister`, `McpClients`, `Format`.

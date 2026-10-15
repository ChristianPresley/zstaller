# zstaller

[![CI](https://github.com/ChristianPresley/zstaller/actions/workflows/ci.yml/badge.svg)](https://github.com/ChristianPresley/zstaller/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

A packaged installer generator for Zig projects, written entirely in Zig 0.16
with zero third-party dependencies.

Add zstaller to your project's `build.zig.zon`, call it from `build.zig`, and
`zig build installer` cross-compiles your program and writes ready-to-ship
installers, each with a SHA-256 checksum file, to `zig-out/installers/`:

```
zig-out/installers/
├── myapp-1.2.0-windows-x86_64.msi
├── myapp-1.2.0-windows-x86_64.msi.sha256
├── myapp-1.2.0-windows-x86_64-setup.exe
├── myapp-1.2.0-windows-x86_64-setup.exe.sha256
├── myapp-1.2.0-windows-aarch64.msi            (+ .sha256)
├── myapp-1.2.0-windows-aarch64-setup.exe      (+ .sha256)
├── myapp_1.2.0_amd64.deb                      (+ .sha256)
└── myapp_1.2.0_arm64.deb                      (+ .sha256)
```

Every package is produced by pure Zig code: no WiX, NSIS, `dpkg-deb`, `ar`,
`tar` or Windows SDK is needed, and installers can be built from any host Zig
supports.

## Supported targets

| Target | Zig target | Formats |
| --- | --- | --- |
| `windows_x86_64` | `x86_64-windows-gnu` | MSI, EXE |
| `windows_aarch64` | `aarch64-windows-gnu` | MSI, EXE |
| `ubuntu_x86_64` | `x86_64-linux-musl` | `.deb` (`amd64`) |
| `ubuntu_aarch64` | `aarch64-linux-musl` | `.deb` (`arm64`) |

Linux binaries are linked statically against musl, so one `.deb` works on
every supported Ubuntu release. Windows binaries use the GNU ABI so no MSVC
toolchain is required.

## Installation

Requires [Zig 0.16.0](https://ziglang.org/download/).

```sh
zig fetch --save git+https://github.com/ChristianPresley/zstaller
```

This adds a `zstaller` entry to the `.dependencies` of your `build.zig.zon`.

## Usage

zstaller reads the package `name`, `version`, `description` and `license`
from your `build.zig.zon`. Zig 0.16 accepts the extra `description` and
`license` fields:

```zig
.{
    .name = .myapp,
    .version = "1.2.0",
    .fingerprint = 0x...,
    .minimum_zig_version = "0.16.0",
    .description = "A tool that does useful things",
    .license = "Apache-2.0",
    .dependencies = .{
        .zstaller = .{ .url = "...", .hash = "..." },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

In `build.zig`, move the code that creates your executable into a function
zstaller can call once per target, then add an `installer` step:

```zig
const std = @import("std");
const zstaller = @import("zstaller");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    b.installArtifact(createExe(b, target, optimize));

    const installers = zstaller.addInstallers(b, .{
        .executable = createExe,
        .icon = b.path("assets/myapp.ico"),
        .extra_files = &.{.{ .source = b.path("README.md"), .dest = "README.md" }},
        .windows = .{
            .publisher = "Example Corp",
            .upgrade_code = "{3C1B6E0A-8F7D-4E52-9B1A-6D2C4F8E7A10}",
        },
        .deb = .{ .maintainer = "Jane Doe <jane@example.com>" },
    });
    b.step("installer", "Build installers").dependOn(installers.step);
}

fn createExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = "myapp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
}
```

```sh
zig build installer
```

`addInstallers` returns `Installers`: `step` builds and installs everything,
and `outputs` lists each package (`target`, `format`, `file_name`, `file`,
`checksum`) for further build steps such as signing or uploading.

A complete, tested project lives in [`examples/sample`](examples/sample).

### Options

| Option | Default | Description |
| --- | --- | --- |
| `executable` | required | Builds the program for one target. |
| `targets` | all | Which targets to package, e.g. `&.{ .windows_x86_64, .ubuntu_x86_64 }`. |
| `optimize` | `.ReleaseSafe` | Optimize mode for the packaged binaries. |
| `manifest_path` | `"build.zig.zon"` | Manifest that metadata is read from. |
| `metadata` | none | Overrides for `name`, `version`, `description`, `license`. |
| `icon` | none | `.ico` file for the EXE, Apps & Features and the MSI. |
| `extra_files` | none | Files installed next to the binary (`source`, `dest`). |
| `install_subdir` | `"installers"` | Output directory under `zig-out/`. |
| `windows.publisher` | package name | Publisher and MSI Manufacturer. |
| `windows.display_name` | package name | Product name shown to users. |
| `windows.install_dir_name` | display name | Folder created under Program Files. |
| `windows.upgrade_code` | derived from name | MSI UpgradeCode. Set it once and never change it. |
| `windows.add_to_path` | `.optional` | `.never`, `.optional` or `.always`. |
| `windows.start_menu_shortcut` | `true` | Add an all-users Start Menu shortcut named after the display name. |
| `deb.maintainer` | `windows.publisher` | Debian `Maintainer` field. |
| `deb.section`, `deb.priority` | `utils`, `optional` | Debian control fields. |
| `deb.homepage`, `deb.depends` | none | Debian control fields. |

Errors in the configuration (a missing description, an invalid package
name, a bad GUID) fail only the `installer` step, with a message naming the
problem; `zig build` and `zig build test` keep working.

## What the installers do

### Ubuntu `.deb`

Installs the binary to `/usr/bin/<name>` and extra files to
`/usr/share/<name>/`, with a `copyright` file generated from the license.

```sh
sudo apt install ./myapp_1.2.0_amd64.deb
sudo apt remove myapp
```

Debian package names must be lowercase; versions containing `-` (semver
prereleases) are written with `~` so they sort before the release.

### Windows EXE

A small native setup program (written in Zig) with the files embedded and
compressed. It installs to `Program Files\<install dir>`, registers an entry
in Apps & Features, adds a Start Menu shortcut, writes `uninstall.exe`, and
can add the install directory to the system PATH. An interactive install
ends by offering to launch the application. It requests administrator
rights.

```
myapp-1.2.0-windows-x86_64-setup.exe /S                 silent install
myapp-1.2.0-windows-x86_64-setup.exe /S /D=C:\Tools\myapp
myapp-1.2.0-windows-x86_64-setup.exe /S /PATH           silent, add to PATH
"C:\Program Files\myapp\uninstall.exe" /uninstall /S    silent uninstall
```

Exit codes: 0 success, 1 error, 2 cancelled, 3 bad arguments.

### Windows MSI

A per-machine Windows Installer package with one component per file,
Apps & Features icon, a Start Menu shortcut, major-upgrade support (installing a newer version
replaces the old one; installing an older one is blocked) and an optional
PATH entry controlled by the `ADDTOPATH` property.

```bat
msiexec /i myapp-1.2.0-windows-x86_64.msi /qn
msiexec /i myapp-1.2.0-windows-x86_64.msi /qn ADDTOPATH=0 INSTALLDIR="D:\Apps\myapp"
msiexec /x myapp-1.2.0-windows-x86_64.msi /qn
```

MSI versions use `major.minor.patch` only (major and minor up to 255, patch
up to 65535); prerelease and build suffixes are dropped, so keep MSI release
versions distinct in those three fields. See
[docs/msi.md](docs/msi.md) for how the MSI is written.

## Try the sample installers

Each [GitHub release](https://github.com/ChristianPresley/zstaller/releases)
carries the sample application's MSI, EXE and `.deb` installers, built by
the [release workflow](.github/workflows/release.yml) and installed, run and
uninstalled on x86_64 and ARM64 Windows and Ubuntu before publishing. The
release notes explain how to install, run and remove them.

## Reproducible builds

All archive timestamps come from `SOURCE_DATE_EPOCH` when it is set, and
from 1980-01-01 otherwise. MSI product, package and component GUIDs are
derived from the upgrade code, version and file paths, so the same inputs always give byte-identical installers.

## Adding a platform

Platforms share one interface, described in
[`src/build/Platform.zig`](src/build/Platform.zig):

1. Add the targets to `Target`, an `Os` variant and any new `Format` in
   [`src/target.zig`](src/target.zig), and the file naming in
   [`src/naming.zig`](src/naming.zig).
2. Write the package format in pure Zig under `src/platforms/<os>/`, with
   unit tests, and add a command for it to `zstaller-pack`
   ([`src/pack/main.zig`](src/pack/main.zig)).
3. Create `src/build/<os>.zig` with
   `pub fn addPackage(ctx: *const api.Context, format: Format) ?LazyPath`
   and register it in `Platform.zig`. A compile error points at any
   platform that is missing.

## Limitations

- Installers are not code-signed. Use `Installers.outputs` to add a signing
  step.
- The EXE and MSI user interfaces are minimal (message boxes and the basic
  Windows Installer progress UI).
- MSI strings must be representable in Windows-1252.

## Building from source

```sh
zig build test                   # unit tests
cd examples/sample && zig build installer
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Please follow the
[Code of Conduct](CODE_OF_CONDUCT.md), and report security issues as described
in [SECURITY.md](SECURITY.md).

## License

Licensed under the [Apache License, Version 2.0](LICENSE). See [NOTICE](NOTICE).

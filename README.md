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
| `source_date_epoch` | `SOURCE_DATE_EPOCH`, else 1980-01-01 | Seconds since the Unix epoch for every timestamp in the packages. See [Reproducible builds](#reproducible-builds). |
| `windows.publisher` | package name | Publisher and MSI Manufacturer. |
| `windows.display_name` | package name | Product name shown to users. |
| `windows.install_dir_name` | display name | Folder created in `install_root`; may nest, e.g. `"Acme\\Widget"`. |
| `windows.install_root` | `.program_files` | Where the default install folder goes: `.program_files`, `.program_data` or `.system_drive` (`C:\`). |
| `windows.allow_install_dir_change` | `true` | Let users pick another folder in the EXE wizard. |
| `windows.upgrade_code` | derived from name | MSI UpgradeCode. Set it once and never change it. |
| `windows.add_to_path` | `.optional` | `.never`, `.optional` or `.always`. |
| `windows.start_menu_shortcut` | `true` | Add an all-users Start Menu shortcut named after the display name. |
| `windows.desktop_shortcut` | `.optional` | All-users desktop shortcut: `.never`, `.optional` (an unticked checkbox) or `.always`. |
| `windows.close_running_apps` | `false` | Let the EXE installer and uninstaller force-quit programs running from the install directory, after asking. See [Windows EXE](#windows-exe). |
| `windows.wizard` | built-in look | Images, license and text of the EXE setup wizard. See [Customizing the setup wizard](#customizing-the-setup-wizard). |
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
compressed. Run normally, it shows a setup wizard:

1. **Welcome**, with the product and version, and a note when an older
   version is installed and will be upgraded.
2. **License Agreement**, when `windows.wizard.license_file` is set. Next
   stays disabled until the user accepts.
3. **Choose Install Location**: the folder, a Browse button that opens
   the standard Windows folder picker, and the space required and
   available. An upgrade defaults to the folder the earlier version was
   installed in.
4. **Additional Tasks**: checkboxes for the PATH entry and the desktop
   shortcut, when either is `.optional`.
5. **Installing**, with a progress bar and the file being copied.
6. **Finished**, with a "Launch" checkbox (`windows.wizard.launch_on_finish`),
   or the reason Setup could not finish.

It installs to `Program Files\<install dir>` by default (see
`install_root`), registers an entry in Apps & Features, adds a Start Menu
shortcut and optionally a desktop shortcut, writes `uninstall.exe`, and
can add the install directory to the system PATH. The wizard follows each
monitor's display scaling and uses the application icon in its title bar
and taskbar button. It requests administrator rights.

`uninstall.exe` shows the same window: a confirmation page, progress and a
result page.

```
myapp-1.2.0-windows-x86_64-setup.exe /S                 silent install
myapp-1.2.0-windows-x86_64-setup.exe /S /D=C:\Tools\myapp
myapp-1.2.0-windows-x86_64-setup.exe /S /PATH /DESKTOP  silent, add to PATH and the desktop
"C:\Program Files\myapp\uninstall.exe" /S               silent uninstall
```

`/D=`, `/PATH`, `/NOPATH`, `/DESKTOP` and `/NODESKTOP` also set the
wizard's initial choices. Silent installs never show a window.

`uninstall.exe` uninstalls when run with no options, removes every file the
installer wrote, then deletes itself and the install directory once it has
exited. The setup program also uninstalls with `/uninstall`.

Windows cannot replace or delete the files of a running program. Before
the installer or uninstaller changes anything, it looks for programs
running from the install directory. By default it stops and lists them,
with their process IDs, so the user can close them and try again. With
`.windows.close_running_apps = true` it shows the same list and offers to
force-quit them; a silent (`/S`) run force-quits them without asking.

Exit codes: 0 success, 1 error, 2 cancelled, 3 bad arguments.

#### Customizing the setup wizard

```zig
.windows = .{
    .display_name = "My App",
    .install_dir_name = "Example Corp\\My App",
    .wizard = .{
        .welcome_image = b.path("assets/wizard-welcome.png"),
        .banner_image = b.path("assets/wizard-banner.png"),
        .license_file = b.path("LICENSE"),
        .welcome_text = "Setup will install My App on your computer.",
        .finish_text = "My App is ready. Click Finish to close Setup.",
    },
},
```

The wizard is 493x360 pixels at 100% display scaling, the size of a
Windows Installer dialog, and its images use the Windows Installer (WiX)
banner and dialog bitmap sizes:

| Option | Size | Where | Keep in mind |
| --- | --- | --- | --- |
| `welcome_image` | 493x312, or 986x624 | Welcome and Finish pages, behind everything above the buttons | Put the artwork in the left 164 pixels (328 at double size). The heading and text are drawn in dark type over the rest, so keep it white or very light. |
| `banner_image` | 493x58, or 986x116 | Top of every other page | The page title and subtitle are drawn in dark type over the left part, so keep about the left two-thirds light and put artwork on the right. |

- PNG (any color type, not interlaced) or BMP (8-, 24- or 32-bit,
  uncompressed). Transparent areas show white.
- Supply double size for sharp output on high-DPI displays; the wizard
  scales smoothly to the display's scaling either way.
- Images are decoded and checked when you build. A wrong size or format
  fails the `installer` step with a message such as
  `windows.wizard.banner_image must be 493x58 pixels, or 986x116 for
  high-DPI displays, but 'assets/banner.png' is 500x60`.
- Without images, the wizard draws its own artwork: a gradient side panel
  and a tinted header in `accent_color` (`0xRRGGBB`, default `0x0067C0`),
  with the application icon.
- `license_file` is UTF-8 text shown in a scrolling box.

[`examples/sample`](examples/sample) uses every option, with placeholder
artwork in [`examples/sample/assets`](examples/sample/assets).

### Windows MSI

A per-machine Windows Installer package with one component per file,
Apps & Features icon, a Start Menu shortcut, major-upgrade support (installing a newer version
replaces the old one; installing an older one is blocked), an optional
PATH entry controlled by the `ADDTOPATH` property (default 1) and, with
`desktop_shortcut = .optional`, a desktop shortcut controlled by
`DESKTOPSHORTCUT` (default 0). It installs to the same default folder as
the EXE. The MSI shows Windows Installer's basic progress UI, not the
EXE's wizard.

```bat
msiexec /i myapp-1.2.0-windows-x86_64.msi /qn
msiexec /i myapp-1.2.0-windows-x86_64.msi /qn ADDTOPATH=0 DESKTOPSHORTCUT=1 INSTALLDIR="D:\Apps\myapp"
msiexec /x myapp-1.2.0-windows-x86_64.msi /qn
```

MSI versions use `major.minor.patch` only (major and minor up to 255, patch
up to 65535); prerelease and build suffixes are dropped, so keep MSI release
versions distinct in those three fields. See
[docs/msi.md](docs/msi.md) for how the MSI is written.

## Try the sample installers

Each [GitHub release](https://github.com/ChristianPresley/zstaller/releases)
carries the sample application's MSI, EXE and `.deb` installers. They are
built on a maintainer's machine, never by GitHub, then installed, run and
uninstalled on x86_64 and ARM64 Windows and Ubuntu by the
[release workflow](.github/workflows/release.yml) before it publishes them.
The release notes explain how to install, run and remove them.

## Making a release

Build every installer locally with [PowerShell 7](https://github.com/PowerShell/PowerShell)
and Zig 0.16.0, from a clean checkout of the commit to release:

```sh
pwsh scripts/release.ps1 -OutputDir ~/Desktop/zstaller-installers
```

The script builds the sample for every target into a fresh
`zig-out/release/` with `SOURCE_DATE_EPOCH` set to the commit time, checks
every `.sha256` file and copies the installers and checksums to
`-OutputDir` (default `zig-out/release/installers`), leaving other files
there alone. To publish, push the commit and add `-Tag`:

```sh
pwsh scripts/release.ps1 -Tag v0.2.0
```

This uploads the files to a draft release for that commit and starts the
release workflow, which downloads them, checks their checksums, installs,
runs and uninstalls them on every platform, and publishes the draft only if
all of that passes. It needs the [GitHub CLI](https://cli.github.com/),
signed in.

## Reproducible builds

The same source, Zig version and timestamp give byte-identical installers,
whatever directory, cache or host (Linux or Windows) builds them. CI builds
the sample twice at different paths with separate caches, on Linux and on
Windows, and requires all four builds to match.

- **Timestamps.** Every timestamp written into a package (`.deb` archive
  entries, MSI summary information and cabinet file dates) is
  `source_date_epoch` if set, else the `SOURCE_DATE_EPOCH` environment
  variable, else 1980-01-01. The value is passed to each packaging step as
  an argument, so changing it rebuilds the installers instead of reusing
  cached ones. The EXE installer's payload stores no timestamps.
- **Windows binaries.** The linker derives a PE image's CodeView GUID and
  its timestamps from the hash of its `.pdb`, which records absolute build
  and cache paths. zstaller replaces those fields in the application and the
  EXE installer stub with a SHA-256 of the rest of the image
  ([`src/platforms/windows/pe.zig`](src/platforms/windows/pe.zig)), so the
  binaries depend only on their code. This matters on aarch64 Windows,
  where debug info is kept (see `needsSymbols` in
  [`src/build/api.zig`](src/build/api.zig)); the `.pdb` stays in the build
  cache and no longer matches the packaged binary.
- **GUIDs.** MSI product, package and component GUIDs are derived from the
  upgrade code, version and file paths.

To reproduce a release, check out the commit and use the
`SOURCE_DATE_EPOCH` its release notes give (`scripts/release.ps1` uses the
commit time):

```sh
git checkout <commit>
cd examples/sample
SOURCE_DATE_EPOCH="$(git log -1 --format=%ct)" zig build installer
sha256sum zig-out/installers/*.msi zig-out/installers/*.exe zig-out/installers/*.deb
```

Compare the sums with the release's `.sha256` files. v0.1.0 was built
before these fixes, so its aarch64 Windows installers cannot be reproduced
exactly.

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

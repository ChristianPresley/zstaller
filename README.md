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

## Quick start

These steps take a project made by `zig init` to installers for every
target. You need [Zig 0.16.0](https://ziglang.org/download/) and nothing
else, on Linux, Windows or macOS.

**1. Add zstaller** to your `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/ChristianPresley/zstaller
```

Append `#<tag>` to the URL to pin a release. To use a local checkout, add `.zstaller = .{ .path = "../zstaller" }` by hand;
the path must be relative.

**2. Describe the package.** zstaller reads `name`, `version`,
`description` and `license` from `build.zig.zon`. Zig 0.16 accepts the
two extra fields. MSI and `.deb` packages need the description:

```zig
.{
    .name = .myapp,
    .version = "1.2.0",
    .fingerprint = 0x...,
    .minimum_zig_version = "0.16.0",
    .description = "A tool that does useful things",
    .license = "Apache-2.0",
    .dependencies = .{ .zstaller = .{ .url = "...", .hash = "..." } },
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

**3. Wire it into `build.zig`.** Move the code that creates your
executable into a function zstaller can call once per target, and add an
`installer` step:

```zig
const std = @import("std");
const zstaller = @import("zstaller");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = createExe(b, target, optimize);
    b.installArtifact(exe);
    b.step("run", "Run the app").dependOn(&b.addRunArtifact(exe).step);

    const installers = zstaller.addInstallers(b, .{
        .executable = createExe,
        .deb = .{ .maintainer = "Jane Doe <jane@example.com>" },
    });
    b.step("installer", "Build installers").dependOn(installers.step);
}

/// Builds the program for `target`. zstaller calls it once per installer
/// target, so it creates every module it uses itself.
fn createExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const lib = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    return b.addExecutable(.{
        .name = "myapp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "myapp", .module = lib }},
        }),
    });
}
```

**4. Build:**

```sh
zig build installer
```

The first build compiles your program for four targets plus zstaller's
own tools, which takes about half a minute; later builds only redo what
changed. The installers and their `.sha256` files are in
`zig-out/installers/`.

### The `executable` function

`createExe` is a plain function pointer, so it cannot capture anything
from `build`. Anything your executable imports, such as the `zig init`
template's `myapp` module or a `b.dependency(...)` module, has to be
created inside it with the `target` it receives. Otherwise the build fails
with `no module named 'myapp' available within module 'root'`. A module you
also export with `b.addModule` can stay in `build`; create a second copy
in the function.

Binaries are built `ReleaseSafe` by default and keep their debug info. Set
`.strip = optimize != .Debug` on the root module for smaller installers,
as [`examples/sample`](examples/sample/build.zig) does.

### A fuller example

```zig
const installers = zstaller.addInstallers(b, .{
    .executable = createExe,
    .targets = &.{ .windows_x86_64, .ubuntu_x86_64 },
    .icon = b.path("assets/myapp.ico"),
    .extra_files = &.{
        .{ .source = b.path("README.md"), .dest = "README.md" },
        .{ .source = b.path("docs/manual.txt"), .dest = "docs/manual.txt" },
    },
    .windows = .{
        .publisher = "Example Corp",
        .display_name = "My App",
        // Generate once (e.g. with PowerShell's New-Guid) and never change it.
        .upgrade_code = "{3C1B6E0A-8F7D-4E52-9B1A-6D2C4F8E7A10}",
        .desktop_shortcut = .optional,
        .wizard = .{ .license_file = b.path("LICENSE") },
    },
    .deb = .{
        .maintainer = "Jane Doe <jane@example.com>",
        .homepage = "https://example.com/myapp",
    },
});
```

`addInstallers` returns `Installers`: `step` builds and installs everything,
and `outputs` lists each package (`target`, `format`, `file_name`, `file`,
`checksum`) for further build steps such as uploading.

A complete, tested project lives in [`examples/sample`](examples/sample).
`zig build docs` in this repository builds an API reference of every
option into `zig-out/docs`.

### Options

| Option | Default | Description |
| --- | --- | --- |
| `executable` | required | Builds the program for one target. See [above](#the-executable-function). |
| `targets` | all | Which targets to package, e.g. `&.{ .windows_x86_64, .ubuntu_x86_64 }`. |
| `optimize` | `.ReleaseSafe` | Optimize mode for the packaged binaries. |
| `manifest_path` | `"build.zig.zon"` | Manifest that metadata is read from. |
| `metadata` | none | Overrides for `name`, `version`, `description`, `license`, e.g. a version from `git describe`. |
| `icon` | none | `.ico` file for the EXE, its wizard, Apps & Features and the MSI. Include 16, 32, 48 and 256 pixel images; ImageMagick makes one with `magick app.png -define icon:auto-resize=256,48,32,16 app.ico`. |
| `extra_files` | none | Files installed next to the binary: `source` and `dest`, a relative path that may use `/` for subfolders. |
| `install_subdir` | `"installers"` | Output directory under `zig-out/`. |
| `source_date_epoch` | `SOURCE_DATE_EPOCH`, else 1980 | Timestamp written into packages. See [Reproducible builds](#reproducible-builds). |

Windows (`.windows = .{ ... }`):

| Option | Default | Description |
| --- | --- | --- |
| `publisher` | package name | Publisher in Apps & Features, and the MSI Manufacturer. |
| `display_name` | package name | Product name shown to users, and the shortcut name. |
| `install_dir_name` | display name | Folder created in `install_root`; may nest, e.g. `"Acme\\Widget"`. |
| `install_root` | `.program_files` | Where the default install folder goes: `.program_files`, `.program_data` or `.system_drive` (`C:\`). |
| `allow_install_dir_change` | `true` | Let users pick another folder in the EXE wizard. |
| `upgrade_code` | derived from name | MSI UpgradeCode. Set it once and never change it: a new one makes the next version install beside the old one instead of upgrading it. |
| `msi_version` | package version | MSI ProductVersion (`major.minor.build`, at most 255.255.65535). Set it when your version does not fit, e.g. calendar versions. See [Windows MSI](#windows-msi). |
| `add_to_path` | `.optional` | `.never`, `.optional` (on unless the user unticks it, or passes `/NOPATH` or `ADDTOPATH=0`) or `.always`. |
| `start_menu_shortcut` | `true` | Add an all-users Start Menu shortcut named after the display name. |
| `desktop_shortcut` | `.optional` | All-users desktop shortcut: `.never`, `.optional` (an unticked checkbox) or `.always`. |
| `close_running_apps` | `false` | Let the EXE installer and uninstaller close programs and services that have the installation's files in use, after asking. See [Windows EXE](#windows-exe). |
| `wizard.license_file` | none | UTF-8 text the user must accept in the EXE wizard. |
| `wizard.welcome_image`, `wizard.banner_image` | built-in artwork | Wizard images. See [Customizing the setup wizard](#customizing-the-setup-wizard). |
| `wizard.accent_color` | `0x0067C0` | Color of the built-in artwork, `0xRRGGBB`. |
| `wizard.welcome_text`, `wizard.finish_text` | generated | Text of the Welcome and Finished pages. |
| `wizard.launch_on_finish` | `true` | Offer a ticked "Launch" checkbox on the Finished page. |

Ubuntu (`.deb = .{ ... }`):

| Option | Default | Description |
| --- | --- | --- |
| `maintainer` | `windows.publisher` | Debian `Maintainer` field, `Name <email>`. Required if `windows.publisher` is not set. |
| `section`, `priority` | `utils`, `optional` | Debian control fields. |
| `homepage`, `depends` | none | Debian control fields. Binaries are static, so `depends` is rarely needed. |

Mistakes in the configuration (a missing description, an invalid package
name, a bad GUID, an extra file path that would escape the install folder,
an icon that is not a `.ico`) fail only the `installer` step, once, with a
message naming the option; `zig build` and `zig build test` keep working.

### Names and versions

- **Package name.** `.name` in `build.zig.zon` must be a bare Zig
  identifier, so Zig rejects `.@"my-app"`. Set
  `.metadata = .{ .name = "my-app" }` for names with dashes. Installer
  file names keep the name's case (`MyApp-1.2.0-windows-x86_64.msi`); the
  Debian package name is lowercased with `_` turned into `-` (`myapp`).
- **Changing the name** changes the default upgrade code. Set
  `windows.upgrade_code` to the old one first, or the renamed package
  installs beside the old one instead of upgrading it.
- **Versions** must be semantic versions. Pre-releases work everywhere:
  the `.deb` gets `1.2.0~rc.1`, which sorts before `1.2.0`, and the MSI
  gets ProductVersion `1.2.0` with its own product code, so the final
  release replaces it.

## What the installers do

### Ubuntu `.deb`

Installs the binary to `/usr/bin/<executable name>` (the `.name` your
`executable` function gives it) and extra files to
`/usr/share/<package>/<dest>`, with a `copyright` file generated from the
license in `/usr/share/doc/<package>/`.

```sh
sudo apt install ./myapp_1.2.0_amd64.deb     # install, or upgrade an older version
dpkg -L myapp                                # list the installed files
sudo apt remove myapp                        # uninstall
```

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
myapp-1.2.0-windows-x86_64-setup.exe /S                         silent install
myapp-1.2.0-windows-x86_64-setup.exe /S "/D=D:\Apps\My App"       silent install to another folder
myapp-1.2.0-windows-x86_64-setup.exe /S /NOPATH /DESKTOP        no PATH entry, add a desktop shortcut
"C:\Program Files\myapp\uninstall.exe" /S                       silent uninstall
myapp-1.2.0-windows-x86_64-setup.exe /uninstall /S              the same, from the setup program
```

| Option | Meaning |
| --- | --- |
| `/S`, `/silent`, `/quiet` | No windows. Errors go to standard error and the exit code. |
| `/D=<folder>` | Install folder. Quote the whole option when the path has spaces: `"/D=C:\My Apps\X"`. It may appear anywhere on the command line. |
| `/PATH`, `/NOPATH` | Add, or do not add, the folder to the system PATH (with `add_to_path = .optional`). |
| `/DESKTOP`, `/NODESKTOP` | Create, or do not create, a desktop shortcut (with `desktop_shortcut = .optional`). |
| `/uninstall`, `/u` | Uninstall. `uninstall.exe` does this with no options. |
| `/?`, `/h`, `/help` | Show the options. |

Options are not case-sensitive and may start with `-` instead of `/`.
They also set the wizard's initial choices when `/S` is not given. With
`add_to_path = .optional`, both the wizard and silent installs add the
folder to PATH unless told `/NOPATH`. Setup asks for administrator rights;
run silent installs from an elevated prompt or a deployment tool.

Upgrades replace the files in place, or move the installation when a new
folder is chosen. New files are written before old ones are removed, so a
failed upgrade leaves the earlier version working. Installing an older
version over a newer one is refused; uninstall the newer one first. Only a
PATH entry the installer added itself is ever removed.

`uninstall.exe` uninstalls when run with no options, removes every file the
installer wrote, then deletes itself and the install directory once it has
exited. The setup program also uninstalls with `/uninstall`.

Windows cannot replace or delete files that are in use. Before the
installer or uninstaller changes anything, it looks for programs running
from the install directory and asks Windows (the Restart Manager) which
programs and services have the installed files open. The wizard then shows
a "Programs in Use" page listing each one's full path, process name,
process ID, and the user or service account it runs as; the user closes
them and clicks Retry. With `.windows.close_running_apps = true` the page
also has a Close programs button, which stops services through the service
manager and force-quits other programs after asking. A silent (`/S`) run
prints the same list to standard error and fails, or with
`close_running_apps` closes them without asking.

Exit codes: 0 success, 1 error (including a newer version already
installed), 2 cancelled, 3 bad arguments.

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
msiexec /i myapp-1.2.0-windows-x86_64.msi /qn /l*v install.log
msiexec /i myapp-1.2.0-windows-x86_64.msi /qn ADDTOPATH=0 DESKTOPSHORTCUT=1 INSTALLDIR="D:\Apps\myapp"
msiexec /x myapp-1.2.0-windows-x86_64.msi /qn
msiexec /x {PRODUCT-CODE} /qn
```

Run `msiexec` from an elevated prompt (or a deployment tool such as Intune,
SCCM or Group Policy): the package installs per machine, and a silent
install without administrator rights fails.
`/l*v <file>` writes a log, which is the first place to look when an
install fails. The product code to uninstall by is the key name under
`HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall` whose
`DisplayName` is your product.

| Property | Default | Meaning |
| --- | --- | --- |
| `INSTALLDIR` | `<install_root>\<install_dir_name>` | Install folder. |
| `ADDTOPATH` | `1` | With `add_to_path = .optional`: `0` leaves the folder off the system PATH. |
| `DESKTOPSHORTCUT` | `0` | With `desktop_shortcut = .optional`: `1` creates a desktop shortcut. |

Installing a newer version removes the older one first (a major
upgrade). Installing an older version over a newer one stops with "A newer
version of ... is already installed" (exit code 1603).

MSI versions use `major.minor.patch` only (major and minor up to 255, patch
up to 65535). Pre-release and build suffixes are not part of the MSI
version, but each release still gets its own product code, so the
`1.0.0` MSI replaces the `1.0.0-rc.1` one. A version that does not fit,
such as `2026.10.0`, fails the build; set `windows.msi_version` (for
example `"26.10.0"`) and keep it increasing with every release. See
[docs/msi.md](docs/msi.md) for how the MSI is written.

## Troubleshooting

**`no module named '...' available within module 'root'`**: the
`executable` function uses a module that `build` created. Create it inside
the function; see [The `executable` function](#the-executable-function).

**`expected path relative to build root; found absolute path`**: a `.path`
dependency in `build.zig.zon` must be relative, e.g. `"../zstaller"`.

**`name must be a valid bare zig identifier`**: Zig does not accept dashes
in `.name`. Use an identifier and set `.metadata = .{ .name = "my-app" }`.

**`a description is required ...`**: add `.description = "..."` to
`build.zig.zon`. MSI and `.deb` packages need one.

**`... which MSI packages cannot store: they use the Windows-1252
character set`**: MSI text is limited to Western European characters.
Replace the character the message names, or set a separate
`windows.display_name` or `windows.publisher` for Windows.

**`version ... does not fit an MSI ProductVersion`**: set
`windows.msi_version`; see [Windows MSI](#windows-msi).

**`icon '...' is not a Windows .ico file`**: renaming a PNG is not
enough; convert it, for example with ImageMagick:
`magick app.png -define icon:auto-resize=256,48,32,16 app.ico`.

**Installers are larger than expected**: the binaries keep their debug
info in `ReleaseSafe`. Set `.strip = optimize != .Debug` on the root
module. Windows ARM64 binaries keep it regardless, in a separate `.pdb`
that is not packaged, because of a Zig 0.16 code generation bug (see
`needsSymbols` in [`src/build/api.zig`](src/build/api.zig)).

**SmartScreen says "Windows protected your PC", or UAC shows "Unknown
publisher"**: the installers are not code-signed; see
[Limitations](#limitations).

**"This app can't run on your PC"**: the installer is for the other
Windows architecture. Use the `windows-x86_64` files on Intel and AMD PCs,
`windows-aarch64` on ARM64 PCs.

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

Each platform sits behind one interface,
[`src/build/Platform.zig`](src/build/Platform.zig). The steps to add one
(for example another Linux distribution or macOS) are in
[CONTRIBUTING.md](CONTRIBUTING.md#adding-a-platform).

## Limitations

- Installers are not code-signed, so Windows shows SmartScreen and
  "Unknown publisher" warnings. Signing the files in `Installers.outputs`
  after the build makes their `.sha256` files stale.
- The MSI shows Windows Installer's basic progress UI, not the EXE's
  wizard.
- Each package holds one executable plus `extra_files`, which are not
  executable on Linux.
- MSI strings must be representable in Windows-1252 (Latin letters,
  accents, curly quotes, dashes, the euro and trademark signs).

## Building from source

```sh
zig build test                             # unit tests
zig build docs                             # API reference in zig-out/docs
cd examples/sample && zig build installer  # the sample's installers
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Please follow the
[Code of Conduct](CODE_OF_CONDUCT.md), and report security issues as described
in [SECURITY.md](SECURITY.md).

## License

Licensed under the [Apache License, Version 2.0](LICENSE). See [NOTICE](NOTICE).

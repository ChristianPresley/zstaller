---
title: Output files
lead: What zig build installer writes, and how names and versions become file names and package versions.
---

## The files

Everything goes to `zig-out/<install_subdir>/`, `zig-out/installers/` by default. The sample's:

{% include term.html name="build-outputs" %}

| Package | File name |
| --- | --- |
| EXE installer | `<name>-<version>-windows-<arch>-setup.exe` |
| MSI | `<name>-<version>-windows-<arch>.msi` |
| `.deb` | `<package>_<deb version>_<amd64 or arm64>.deb` |
| MCP bundle | `<name>-<version>-<os>-<arch>.mcpb` (only with `mcp`) |
| Checksum | `<file>.sha256`, next to each of the above |

`<arch>` is `x86_64` or `aarch64`. `zig build installer --prefix <dir>` (or `-p`) writes to `<dir>/installers/` instead.

## Checksums

Each `.sha256` is in `sha256sum` format, so `sha256sum -c` checks it, and PowerShell's `Get-FileHash` gives the same hash:

{% include term.html name="build-checksum" %}

The `.mcpb`'s hash is the `fileSha256` the MCP Registry asks for.

## Names

| From | Example | Used as |
| --- | --- | --- |
| `.name` in `build.zig.zon`, or `metadata.name` | `MyApp` | Windows file names, keeping case: `MyApp-1.2.0-windows-x86_64.msi` |
| The same, lowercased, `_` → `-` | `myapp` | Debian package name and `.deb` file name |
| `windows.display_name` | `My App` | What Windows users see |

`.name` in `build.zig.zon` must be a bare Zig identifier. For a name with dashes, use `.metadata = .{ .name = "my-app" }`. Renaming changes the default MSI upgrade code; set `windows.upgrade_code` to the old one first, or the renamed package installs beside the old one.

## Versions

Versions are [semantic versions](https://semver.org). Pre-release and build parts map to each format so that upgrades sort correctly:

| `version` | File names | `.deb` version | MSI ProductVersion |
| --- | --- | --- | --- |
| `1.2.0` | `1.2.0` | `1.2.0` | `1.2.0` |
| `1.2.0-rc.1` | `1.2.0-rc.1` | `1.2.0~rc.1` (sorts before `1.2.0`) | `1.2.0`, with its own product code |
| `1.2.0+build.5` | `1.2.0+build.5` | `1.2.0+build.5` | `1.2.0` |
| `2026.10.0` | `2026.10.0` | `2026.10.0` | does not fit: set `windows.msi_version` |

`metadata.version` overrides the manifest's, for example a version computed from `git describe` in `build.zig`; the sample's `-Dversion=` option does this.

## Inside the packages

| Package | Contains |
| --- | --- |
| EXE | The setup program with your files appended, compressed, with a SHA-256 it checks before unpacking. |
| MSI | An OLE compound file: installer database, summary information and an MSZIP cabinet. [How the MSI is written]({{ '/msi/' | relative_url }}) |
| `.deb` | An ar archive of `debian-binary`, `control.tar.gz` and `data.tar.gz`. |
| `.mcpb` | A zip of `manifest.json`, the server program and, when `mcp.icon` is set, `icon.png`. |

---
title: Install zstaller
lead: zstaller is a Zig package. You add it to your project like any other dependency; there is nothing else to install.
---

## What you need

- **Zig 0.16.0.** zstaller is written for Zig 0.16.0 and checked against it in CI. Download it from [ziglang.org](https://ziglang.org/download/).
- **Any host Zig supports.** Linux, Windows and macOS can all build every installer, for every target. You do not need Windows to build the Windows installers, or Ubuntu to build the `.deb`.
- **Nothing else.** No WiX, NSIS, `dpkg-deb`, `tar`, MSVC, Windows SDK or third-party Zig packages.

Testing the installers is another matter: you need a Windows PC (or VM) to run the EXE and MSI, and Ubuntu to install the `.deb`. See [Try the installers]({{ '/getting-started/try-it/' | relative_url }}).

## Add the dependency

From your project folder (the one with `build.zig.zon`):

```sh
zig fetch --save git+https://github.com/ChristianPresley/zstaller
```

This downloads zstaller, checks its hash and adds it to `dependencies` in your `build.zig.zon`:

```zig
.dependencies = .{
    .zstaller = .{
        .url = "git+https://github.com/ChristianPresley/zstaller#<commit>",
        .hash = "zstaller-0.2.0-...",
    },
},
```

### Pin a release

Append a tag to the URL to use a published release instead of the newest commit:

```sh
zig fetch --save git+https://github.com/ChristianPresley/zstaller#v{{ site.version }}
```

The [releases page]({{ site.repo_url }}/releases) lists them, and [CHANGELOG.md]({{ site.blob_url }}/CHANGELOG.md) what changed in each.

### Use a local checkout

To work on zstaller and your project together, point the dependency at a folder instead. The path must be relative to your `build.zig.zon`:

```zig
.dependencies = .{
    .zstaller = .{ .path = "../zstaller" },
},
```

An absolute path fails with `expected path relative to build root; found absolute path`.

## Describe your package

zstaller reads four fields from `build.zig.zon`. Zig 0.16 accepts `description` and `license` alongside its own fields, so add them at the top level:

```zig
.{
    .name = .myapp,
    .version = "1.2.0",
    .fingerprint = 0x...,
    .minimum_zig_version = "0.16.0",
    .description = "A tool that does useful things",
    .license = "Apache-2.0",
    .dependencies = .{ ... },
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

| Field | Used for | Required |
| --- | --- | --- |
| `name` | File names, the Debian package name, default display name and MSI upgrade code | Yes |
| `version` | File names and every package's version; must be a [semantic version](https://semver.org) | Yes |
| `description` | MSI summary and the `.deb` description | For MSI and `.deb` |
| `license` | The `.deb` copyright file (an [SPDX identifier](https://spdx.org/licenses/)) | For `.deb` |

`.name` must be a bare Zig identifier, so `my-app` is not allowed there. Set `.metadata = .{ .name = "my-app" }` in `addInstallers` instead; see [Output files]({{ '/reference/output-files/' | relative_url }}) for how names and versions turn into file names.

Next, wire zstaller into `build.zig`: [Your first installers]({{ '/getting-started/first-installers/' | relative_url }}).

---
title: The .deb package
lead: Each Ubuntu target gets a .deb that apt installs, upgrades and removes like any other package. zstaller writes it in pure Zig, and it passes lintian.
---

## Install, run, remove

{% include term.html name="deb-install" %}
{% include term.html name="deb-run" %}

`apt` shows the package like any other, with the description from `build.zig.zon` and `deb.long_description` below it:

{% include term.html name="deb-show" %}

`sudo apt remove sample` uninstalls; `sudo apt purge sample` also removes configuration files and whatever the `postrm` script cleans up:

{% include term.html name="deb-remove" %}
{% include term.html name="deb-purge" %}

## Where files go

{% include term.html name="deb-files" %}

| What | Where | From |
| --- | --- | --- |
| Your program | `/usr/bin/<executable name>` (mode 755) | `executable` |
| Other programs | `/usr/bin/` | `programs` |
| Extra files | `/usr/share/<package>/<dest>` (mode 644) | `extra_files` |
| Copyright file | `/usr/share/doc/<package>/copyright` | `license` in `build.zig.zon`, `deb.copyright` |
| Changelog | `/usr/share/doc/<package>/changelog.gz` | Generated for the version |
| Anything else | Any absolute path | `deb.files` |
| Menu entry | `/usr/share/applications/<package>.desktop`, icon in the hicolor theme | `deb.desktop_entry` |
| MCP helper | `/usr/lib/<package>/zstaller-mcp` | `mcp` (see [MCP servers]({{ '/guides/mcp/' | relative_url }})) |
| lintian override | `/usr/share/lintian/overrides/<package>` | Always (the binaries are static) |

Binaries are linked statically against musl, so the package has no dependencies and one `.deb` works on every supported Ubuntu release.

## Configure it

The sample's `.deb` settings, which produce everything on this page:

```zig
.deb = .{
    .maintainer = "The zstaller Authors <noreply@example.com>",
    .homepage = "https://github.com/ChristianPresley/zstaller",
    .long_description =
    \\Prints its version, the platform it was built for and where it is
    \\installed, to show how zstaller packages a Zig program.
    \\
    \\sample-tool, installed with it, prints the SHA-256 of files.
    ,
    .copyright = "2026 The zstaller Authors",
    .files = &.{
        .{ .source = b.path("linux/sample.1"), .dest = "/usr/share/man/man1/sample.1" },
        .{ .source = b.path("linux/sample-tool.1"), .dest = "/usr/share/man/man1/sample-tool.1" },
        .{ .source = b.path("linux/sample.conf"), .dest = "/etc/sample/sample.conf" },
    },
    .desktop_entry = .{
        .categories = "Utility;",
        .terminal = true,
        .icon = b.path("assets/sample.png"),
    },
    .scripts = .{
        .postinst = b.path("linux/postinst"),
        .postrm = b.path("linux/postrm"),
    },
},
```

The control fields it produces:

{% include term.html name="deb-info" %}

| Option | Control field | Default |
| --- | --- | --- |
| `maintainer` | `Maintainer` | `windows.publisher`, if it is in `Name <email>` form; otherwise required |
| `section` | `Section` | `utils` |
| `priority` | `Priority` | `optional` |
| `homepage` | `Homepage` | none |
| `depends` | `Depends` | none (rarely needed: the binaries are static) |
| `long_description` | The lines after `Description` | none; lintian expects one |
| `copyright` | The notice in the copyright file, with a year | `windows.publisher`, else the package name |

The package name is your package name, lowercased, with `_` turned into `-`. The architecture is `amd64` or `arm64`.

## Files anywhere: `deb.files`

`deb.files` installs files at absolute paths: man pages, shell completions, systemd units, default configuration. Each has a `source`, a `dest` and a `mode` (default `0o644`; use `0o755` for scripts and programs).

- **Man pages** under `/usr/share/man` are gzip-compressed for you and get `.gz` appended, so `man sample` works.
- **Files under `/etc`** are configuration files (*conffiles*): dpkg keeps the administrator's changes when the package is upgraded, asks what to do when both sides changed, and removes them only on purge.

{% include term.html name="deb-conffiles" %}

The complete contents of the sample's package:

{% include term.html name="deb-contents" %}

## A menu entry

`deb.desktop_entry` adds the application to the desktop's application menu, named after `windows.display_name` (or the package name), with the description as its comment and a square PNG icon (ideally 256×256):

{% include term.html name="deb-desktop" title="/usr/share/applications/sample.desktop" %}

Set `terminal = true` for console programs, so the menu opens them in a terminal, and `categories` to [freedesktop.org categories](https://specifications.freedesktop.org/menu-spec/latest/apa.html) such as `"Development;IDE;"`.

## Maintainer scripts

`deb.scripts` sets `preinst`, `postinst`, `prerm` and `postrm`. dpkg runs them on install, upgrade and removal with the action as `$1` (`configure`, `remove`, `purge`, `upgrade`, …). Each must start with `#!`. The sample's create and remove a data folder:

```sh
#!/bin/sh
# linux/postinst
set -e
if [ "$1" = configure ]; then
    mkdir -p /var/lib/sample
fi
```

```sh
#!/bin/sh
# linux/postrm: "purge" also removes the data postinst created.
set -e
if [ "$1" = purge ]; then
    rm -rf /var/lib/sample
fi
```

A service would enable its systemd unit in `postinst` and stop it in `prerm`:

```zig
.deb = .{
    .files = &.{
        .{ .source = b.path("linux/myapp.service"), .dest = "/usr/lib/systemd/system/myapp.service" },
    },
    .scripts = .{ .postinst = b.path("linux/postinst"), .prerm = b.path("linux/prerm") },
},
```

```sh
#!/bin/sh
# linux/postinst: start the service on install, restart it on upgrade.
set -e
if [ "$1" = configure ] && [ -d /run/systemd/system ]; then
    systemctl daemon-reload
    systemctl enable myapp.service
    systemctl restart myapp.service
fi
```

```sh
#!/bin/sh
# linux/prerm: stop it before removal.
set -e
if [ "$1" = remove ] && [ -d /run/systemd/system ]; then
    systemctl disable --now myapp.service
fi
```

With [MCP registration]({{ '/guides/mcp/' | relative_url }}) on, zstaller adds lines to `prerm` to unregister the server for every user, so a `prerm` of your own must be a shell script.

## Checked with lintian

With `long_description` and `copyright` set, the package passes [lintian](https://lintian.debian.org) without errors or warnings, and CI checks that it stays that way:

{% include term.html name="deb-lintian" %}

zstaller's own unit tests also check the packages it writes with `dpkg-deb`, when it is installed.

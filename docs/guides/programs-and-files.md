---
title: Multiple programs and files
lead: Install more than one program, plus documentation, data and any other files, next to your application.
---

## More programs

`programs` adds programs that are installed next to the application, each built by its own function, just like `executable`:

```zig
const installers = zstaller.addInstallers(b, .{
    .executable = createExe,
    .programs = &.{
        // A command-line tool, without a shortcut.
        .{ .executable = createCli },
        // A settings program with its own Start Menu shortcut.
        .{ .executable = createSettings, .shortcut = "My App Settings" },
    },
});

fn createCli(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = "myapp-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
        }),
    });
}
```

Each program is built for every target, normalized for [reproducible builds]({{ '/guides/reproducible-builds/' | relative_url }}) and [signed]({{ '/guides/code-signing/' | relative_url }}) like the application. On Windows they go in the install folder, with an optional Start Menu shortcut (EXE and MSI); on Ubuntu in `/usr/bin`. Every file name must differ from the application's and from each other's.

The sample ships `sample-tool` this way: it prints the SHA-256 of files, runs the [install hooks]({{ '/guides/hooks/' | relative_url }}) and is the [MCP server]({{ '/guides/mcp/' | relative_url }}).

{% include term.html name="silent-files" title="The sample's install folder" %}

## Extra files

`extra_files` installs other files next to the binary:

```zig
.extra_files = &.{
    .{ .source = b.path("README.md"), .dest = "README.md" },
    .{ .source = b.path("docs/manual.txt"), .dest = "docs/manual.txt" },
},
```

`dest` is relative to the install folder and may use `/` for subfolders. On Ubuntu, extra files go to `/usr/share/<package>/<dest>`, with mode 644, so programs belong in `programs` and other executables in `deb.files` with `.mode = 0o755`. Paths that would escape the install folder, or overwrite the application or `uninstall.exe`, fail the build:

{% include term.html name="error-extra" %}

## Files outside the install folder (Ubuntu)

`deb.files` installs files at absolute paths: man pages, completions, systemd units and configuration in `/etc`. See [The .deb package]({{ '/guides/deb/' | relative_url }}#files-anywhere-debfiles). Windows installers have no equivalent; use an [install hook]({{ '/guides/hooks/' | relative_url }}) to put things elsewhere.

## Only some targets

`targets` picks which targets to package:

```zig
.targets = &.{ .windows_x86_64, .ubuntu_x86_64 },
```

The [build API]({{ '/reference/build-api/' | relative_url }}) also returns every package it makes, for further build steps such as uploading.

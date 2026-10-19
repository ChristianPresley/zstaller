---
title: Your first installers
lead: These steps take a project made by zig init to installers for every target. It takes a few minutes, most of it the first build.
---

<ol class="steps">
<li markdown="1">

### Start from a project

Any Zig project with an executable works. To follow along from nothing:

```sh
mkdir myapp && cd myapp
zig init
```

</li>
<li markdown="1">

### Add zstaller and describe the package

```sh
zig fetch --save git+https://github.com/ChristianPresley/zstaller
```

Then add a `description` and a `license` to `build.zig.zon`, as [Install zstaller]({{ '/getting-started/installation/' | relative_url }}#describe-your-package) shows.

</li>
<li markdown="1">

### Move your executable into a function

zstaller builds your program once per target, so it needs a function it can call with each target. Move the code that creates your executable out of `build` into a function with this signature, and call it from `build` for the normal native build too:

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
            .strip = optimize != .Debug,
            .imports = &.{.{ .name = "myapp", .module = lib }},
        }),
    });
}
```

`createExe` is a plain function pointer, so it cannot capture anything from `build`. Every module the executable imports, like the `myapp` module `zig init` makes, has to be created inside it with the `target` it receives. If you leave one in `build`, the build fails with `no module named 'myapp' available within module 'root'`.

`.strip = optimize != .Debug` keeps debug info out of the packaged binaries, which makes the installers much smaller.

</li>
<li markdown="1">

### Build

```sh
zig build installer
```

The first build compiles your program for four targets and zstaller's own tools, which takes about half a minute. Later builds only redo what changed. Everything lands in `zig-out/installers/`:

{% include term.html name="build-outputs" %}

Every file has a `.sha256` next to it in `sha256sum` format, so users can check a download:

{% include term.html name="build-checksum" %}

(The sample is also an [MCP server]({{ '/guides/mcp/' | relative_url }}), which is why it has `.mcpb` files. Yours won't unless you set `.mcp`.)

</li>
</ol>

## What the defaults give you

With nothing but `.executable` and a maintainer, the installers already:

- install to `C:\Program Files\<name>` on Windows and `/usr/bin` on Ubuntu,
- show a [setup wizard]({{ '/guides/setup-wizard/' | relative_url }}) with built-in artwork in Windows blue,
- add a Start Menu shortcut, offer a desktop shortcut and add the folder to PATH unless the user unticks it,
- register in Apps & Features with an uninstaller,
- upgrade earlier versions in place and refuse to downgrade.

Every one of these is a setting. The [options reference]({{ '/reference/options/' | relative_url }}) lists them all; a fuller configuration looks like this:

```zig
const installers = zstaller.addInstallers(b, .{
    .executable = createExe,
    .targets = &.{ .windows_x86_64, .ubuntu_x86_64 },
    .icon = b.path("assets/myapp.ico"),
    .extra_files = &.{
        .{ .source = b.path("README.md"), .dest = "README.md" },
    },
    .windows = .{
        .publisher = "Example Corp",
        .display_name = "My App",
        // Generate once (e.g. with PowerShell's New-Guid) and never change it.
        .upgrade_code = "{3C1B6E0A-8F7D-4E52-9B1A-6D2C4F8E7A10}",
        .wizard = .{ .license_file = b.path("LICENSE") },
    },
    .deb = .{
        .maintainer = "Jane Doe <jane@example.com>",
        .homepage = "https://example.com/myapp",
    },
});
```

> Set `windows.upgrade_code` before your first release and never change it. It is how Windows Installer recognizes later versions of your product as upgrades. The default is derived from the package name, so it changes if you rename the package.

## A complete example

[`examples/sample`]({{ site.repo_url }}/tree/main/examples/sample) in the repository is a complete project that uses almost every option: custom wizard artwork, a license page, a second program, install hooks, an MCP server, and a `.deb` with man pages, a configuration file, a menu entry and maintainer scripts. Its [`build.zig`]({{ site.blob_url }}/examples/sample/build.zig) is commented line by line. Copy the folder to start a project of your own, replacing `.path = "../.."` in its `build.zig.zon` with a `zig fetch --save`.

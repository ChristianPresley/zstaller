---
title: Troubleshooting
lead: Problems people run into, by the message they see.
---

## Building

**`no module named '...' available within module 'root'`**
: The `executable` function uses a module that `build` created. Create it inside the function, with the `target` it receives. See [Your first installers]({{ '/getting-started/first-installers/' | relative_url }}#move-your-executable-into-a-function).

**`expected path relative to build root; found absolute path`**
: A `.path` dependency in `build.zig.zon` must be relative, e.g. `"../zstaller"`.

**`name must be a valid bare zig identifier`**
: Zig does not accept dashes in `.name`. Use an identifier and set `.metadata = .{ .name = "my-app" }`.

**`a description is required ...`**
: Add `.description = "..."` to `build.zig.zon`.

**Any other `error: zstaller: ...`**
: A configuration mistake, named in the message. [Build errors]({{ '/reference/build-errors/' | relative_url }}) has examples of each.

**Installers are larger than expected**
: `ReleaseSafe` binaries keep their debug info. Set `.strip = optimize != .Debug` on the root module in your `executable` function. Windows ARM64 binaries keep it regardless (in a separate, unpackaged `.pdb`) because of a Zig 0.16 code generation bug.

**The first build is slow**
: It compiles your program for four targets and zstaller's tools. Later builds only redo what changed. Set `targets` to what you need while developing.

## Installing on Windows

**SmartScreen says "Windows protected your PC", or UAC shows "Unknown publisher"**
: The installers are not code-signed. See [Code signing]({{ '/guides/code-signing/' | relative_url }}). Users can choose **More info**, then **Run anyway**.

**"This app can't run on your PC"**
: The installer is for the other Windows architecture: `x86_64` for Intel and AMD, `aarch64` for ARM64.

**"Version … is already installed, which is newer"**
: Downgrades are refused. Uninstall the newer version first. See [Upgrades]({{ '/guides/upgrades/' | relative_url }}).

**"… is already installed from its MSI package" or "… is already installed with its setup program"**
: The EXE and the MSI of a product cannot both be installed. Uninstall one first.

**"Users other than administrators can rename or change …" or "… already holds files that other users can change"**
: Setup will not install where a standard user could replace the installed programs. Pick a folder in Program Files, a new folder, or an empty one. See [Folder security]({{ '/guides/folder-path-shortcuts/' | relative_url }}#folder-security).

**A Programs in Use page, or "cannot be uninstalled while its files are in use"**
: Close the listed programs, or set `close_running_apps`. See [Programs in use]({{ '/guides/programs-in-use/' | relative_url }}).

**The program is not found in a terminal after installing**
: PATH changes reach new terminals only. Open a new one. Check that the PATH task was ticked (or `/NOPATH`, `ADDTOPATH=0` not given).

**An MSI install fails**
: Run it with `/l*v install.log` and search the log for `return value 3`: the lines before it say what failed. A silent per-machine install must run elevated.

## Installing on Ubuntu

**`apt` says the package has unmet dependencies**
: zstaller's packages have none unless you set `deb.depends`. Check that value.

**My configuration file was not replaced on upgrade**
: Files in `/etc` are configuration files: dpkg keeps the administrator's version, and asks when both changed. `apt purge` removes them.

## AI tools

**The server does not show up in an AI tool**
: Restart the tool. Check `zstaller-mcp status`. Only tools whose settings folder exists get an entry, and only those in `mcp.clients`. On Ubuntu, each user runs `/usr/lib/<package>/zstaller-mcp register` once.

**"skipped, … already has a different server named '…'"**
: The user set up a server with the same name that runs another program. zstaller leaves it alone. Remove it, or give yours another `mcp.name`.

**`status` says "left behind by an earlier installation"**
: An entry points at a program that is no longer there, for example after the folder moved. Run `zstaller-mcp register` to fix it.

Still stuck? [Open an issue]({{ site.repo_url }}/issues/new/choose) with the message and, for Windows, the msiexec log or Setup's output.

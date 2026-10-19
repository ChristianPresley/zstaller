---
title: Introduction
hide_title: true
description: zstaller turns a Zig project into MSI and EXE installers for Windows and .deb packages for Ubuntu with one zig build installer, in pure Zig.
---

<div class="hero">
<div markdown="1">

# Installers for Zig programs, <em>written in Zig</em>

<p class="lead">Add zstaller to your <code>build.zig</code>, run <code>zig build installer</code>, and get a Windows setup wizard, an MSI for enterprise deployment and Ubuntu packages, for x86_64 and ARM64, from any machine Zig runs on.</p>

<div class="buttons">
<a class="button" href="{{ '/getting-started/installation/' | relative_url }}">Get started</a>
<a class="button secondary" href="{{ '/gallery/' | relative_url }}">See every screen</a>
<a class="button secondary" href="{{ site.repo_url }}">GitHub</a>
</div>

</div>
{% include shot.html name="wizard-welcome" caption="The setup wizard zstaller builds for the sample application." %}
</div>

## What you get

One build step cross-compiles your program for four targets and packages each one:

<div class="formats">
<div><strong>Windows setup EXE</strong><code>myapp-1.2.0-windows-x86_64-setup.exe</code><span>A native wizard, silent installs, an uninstaller.</span></div>
<div><strong>Windows MSI</strong><code>myapp-1.2.0-windows-x86_64.msi</code><span>For Group Policy, Intune and SCCM.</span></div>
<div><strong>Ubuntu package</strong><code>myapp_1.2.0_amd64.deb</code><span>Passes lintian; installs with apt.</span></div>
<div><strong>MCP bundle</strong> <span class="badge">optional</span><code>myapp-1.2.0-windows-x86_64.mcpb</code><span>For AI tools, if your program is an MCP server.</span></div>
</div>

Each comes for x86_64 and ARM64, with a `.sha256` checksum file beside it in `zig-out/installers/`.

{% include term.html name="build-outputs" title="Terminal" %}

## Why zstaller

- **Nothing to install but Zig.** The MSI database, the cabinet inside it, the `.deb`'s ar and tar archives, gzip and the setup program are all written by zstaller's own Zig code. There is no WiX, NSIS, `dpkg-deb` or Windows SDK, and no third-party Zig packages. Build Windows installers on Linux or macOS, and Ubuntu packages on Windows.
- **One description, every format.** Name, version, description and license come from your `build.zig.zon`; one `addInstallers` call sets up every installer.
- **Installers that behave.** Upgrades that keep the old version working until the new one is in place, uninstallers that leave nothing behind, per-user or per-machine installs, PATH entries that are removed cleanly, and a check for programs that are still running.
- **Reproducible.** The same source and timestamp give byte-identical installers on any host, so anyone can check a release.
- **Tested for real.** CI installs, runs and uninstalls the sample on x86_64 and ARM64 Windows and Ubuntu.

## Where to go next

<div class="cards">
<a class="card" href="{{ '/getting-started/first-installers/' | relative_url }}"><strong>Your first installers</strong><span>From <code>zig init</code> to installers in four steps.</span></a>
<a class="card" href="{{ '/guides/setup-wizard/' | relative_url }}"><strong>The setup wizard</strong><span>Every page of the Windows wizard, and the options that shape it.</span></a>
<a class="card" href="{{ '/guides/msi/' | relative_url }}"><strong>MSI for enterprise</strong><span>Silent installs, properties and deployment tools.</span></a>
<a class="card" href="{{ '/guides/deb/' | relative_url }}"><strong>The .deb package</strong><span>Man pages, config files, menu entries and maintainer scripts.</span></a>
<a class="card" href="{{ '/guides/mcp/' | relative_url }}"><strong>MCP servers</strong><span>Bundles for Claude Desktop, and registration with AI tools.</span></a>
<a class="card" href="{{ '/reference/options/' | relative_url }}"><strong>All options</strong><span>Every setting, its default and what it changes.</span></a>
</div>

## Supported targets

| Target | Zig target | Packages |
| --- | --- | --- |
| `windows_x86_64` | `x86_64-windows-gnu` | EXE, MSI |
| `windows_aarch64` | `aarch64-windows-gnu` | EXE, MSI |
| `ubuntu_x86_64` | `x86_64-linux-musl` | `.deb` (`amd64`) |
| `ubuntu_aarch64` | `aarch64-linux-musl` | `.deb` (`arm64`) |

Linux binaries are linked statically against musl, so one `.deb` works on every supported Ubuntu release. Windows binaries use the GNU ABI, so no MSVC is needed. Other platforms can be added behind one interface; see [Adding a platform]({{ '/guides/adding-a-platform/' | relative_url }}).

> **About the screenshots.** Every screenshot on this site is of a real installer built from [`examples/sample`]({{ site.repo_url }}/tree/main/examples/sample) or a variant of it, captured by a script in the repository ([`docs/_tools/capture.sh`]({{ site.blob_url }}/docs/_tools/capture.sh)). The Windows ones are taken under Wine, so window frames and system dialogs have Wine's classic look; the pages zstaller draws itself look the same on Windows. Every terminal transcript is real output.

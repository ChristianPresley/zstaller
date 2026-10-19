---
title: FAQ
---

**Do I need Windows to build Windows installers?**
: No. Every installer is built by Zig code, so Linux, macOS and Windows all build all of them. You need Windows (or a VM) to test them.

**Does zstaller use WiX, NSIS or Inno Setup underneath?**
: No. The MSI database, its cabinet, the setup program, the `.deb` and its archives are all written by zstaller's own Zig code. It has no third-party dependencies.

**EXE or MSI?**
: Both are built. Offer the EXE to people who download and click (it has the wizard, and handles running programs); give the MSI to administrators who deploy with Group Policy, Intune or SCCM. A PC should have one or the other.

**Can I build only some installers?**
: Set `targets`, e.g. `&.{ .windows_x86_64 }`. Each Windows target always gets both an EXE and an MSI.

**Can I package a GUI application?**
: Yes. zstaller packages whatever your `executable` function builds. Give it `.subsystem = .windows` on Windows, an icon resource for its shortcut, and `deb.desktop_entry` with `terminal = false` for the Ubuntu menu.

**Can I install a service?**
: On Ubuntu, install a systemd unit with `deb.files` and enable it from `deb.scripts`, as [The .deb package]({{ '/guides/deb/' | relative_url }}#maintainer-scripts) shows. On Windows, register it with an [`after_install` hook]({{ '/guides/hooks/' | relative_url }}) and remove it with `before_uninstall`; `close_running_apps` stops it before upgrades.

**Can users choose components?**
: No: one feature per MSI, and the EXE installs everything. Optional tasks are PATH, the desktop shortcut and AI-tool registration.

**Does it support macOS, Fedora, Arch, Flatpak, AppImage, 32-bit Windows?**
: Not yet. The platform interface is designed for more; see [Adding a platform]({{ '/guides/adding-a-platform/' | relative_url }}).

**Why are the Linux binaries static?**
: zstaller builds them against musl, so they need nothing from the system and one `.deb` works on every supported Ubuntu.

**Why does the Windows ARM64 build keep debug info?**
: Zig 0.16 miscompiles thread-local storage on ARM64 Windows when the binary is stripped. zstaller keeps the debug info in a separate `.pdb` that is not packaged.

**Can I see the installers without building anything?**
: Download the sample's from a [release]({{ site.repo_url }}/releases), or browse the [screenshot gallery]({{ '/gallery/' | relative_url }}).

**How do I report a bug or ask for a feature?**
: [Open an issue]({{ site.repo_url }}/issues/new/choose). Security problems: see [SECURITY.md]({{ site.blob_url }}/SECURITY.md).

---
title: Limitations
lead: What zstaller does not do yet, so you can plan around it.
---

## Platforms

- Windows (x86_64, ARM64) and Ubuntu `.deb` (x86_64, ARM64) only. No macOS, RPM or other distributions, Flatpak, Snap or AppImage, and no 32-bit or other architectures. The [platform interface]({{ '/guides/adding-a-platform/' | relative_url }}) is ready for them.

## Windows

- The MSI shows Windows Installer's basic progress window only: no license page, folder picker, checkboxes or files-in-use page of its own.
- MSI text must fit Windows-1252, and MSI versions are at most `255.255.65535` (use `msi_version` otherwise).
- One feature per MSI, and no component selection in the EXE.
- Hooks are installed `.exe` files only (no scripts), and there are two: `after_install` and `before_uninstall`.
- The EXE and MSI of a product cannot both be installed on one PC. Per-user and per-machine builds install side by side, so ship one kind.
- No code signing out of the box: you supply the `sign` function and a certificate.

## Ubuntu

- `extra_files` are installed with mode 644; executables go in `programs` or in `deb.files` with `.mode = 0o755`.
- `.deb` packages are not signed (apt verifies repositories, not packages), and zstaller does not build an apt repository.
- MCP registration is a step each user runs once.

## MCP bundles

- A `.mcpb` holds only the server program, without other files.

## About this site

- Screenshots are taken under Wine, so window frames and system dialogs look like classic Windows, and pages that rely on the Restart Manager or service manager show less than on Windows.

---
title: MSI properties
lead: The public properties the MSI understands, and the standard ones zstaller sets.
---

## Public properties

Set them on the msiexec command line, in a transform, or in your deployment tool:

```bat
msiexec /i myapp-1.2.0-windows-x86_64.msi /qn ADDTOPATH=0 DESKTOPSHORTCUT=1 INSTALLDIR="D:\Apps\My App"
```

| Property | Default | Meaning | Applies when |
| --- | --- | --- | --- |
| `INSTALLDIR` | `install_root\install_dir_name` (per user: `%LOCALAPPDATA%\Programs\install_dir_name`) | Install folder. | Always |
| `ADDTOPATH` | `1` | `0` leaves the folder off PATH. | `add_to_path = .optional` |
| `DESKTOPSHORTCUT` | `0` | `1` creates a desktop shortcut. | `desktop_shortcut = .optional` |
| `REGISTERMCP` | `1` | `0` skips registering the MCP server with the user's AI tools. | `mcp` set, `mcp.register = .optional` |

## Standard properties zstaller sets

| Property | Value |
| --- | --- |
| `ProductName` | `windows.display_name` |
| `Manufacturer` | `windows.publisher` |
| `ProductVersion` | The package version as `major.minor.patch`, or `windows.msi_version` |
| `ProductCode` | Derived from the upgrade code and the full version, so every release has its own |
| `UpgradeCode` | `windows.upgrade_code`, or derived from the package name |
| `ALLUSERS` | `1` for per-machine builds; absent for per-user builds |
| `ARPPRODUCTICON` | The `icon`, when set |
| `ARPNOMODIFY`, `ARPNOREPAIR` | `1`: Apps & Features shows Uninstall only |
| `ARPCOMMENTS` | The description |

The sample's full Property table:

{% include term.html name="msi-properties" %}

## Exit codes

msiexec's own. The common ones:

| Code | Meaning |
| --- | --- |
| `0` | Success. |
| `1602` | Cancelled. |
| `1603` | Fatal error: for example a newer version installed, the EXE installation present, or a failing `after_install` hook. The `/l*v` log says which. |
| `1618` | Another installation is in progress. |
| `1925` | Not enough rights: run elevated for a per-machine package. |
| `3010` | Success; a restart is needed to finish (files were in use). |

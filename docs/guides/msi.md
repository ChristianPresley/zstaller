---
title: MSI for enterprise
lead: Every Windows target also gets an MSI, a Windows Installer package that Group Policy, Intune and SCCM can deploy, with silent install and uninstall through msiexec.
---

## What the MSI does

The MSI installs the same files to the same folder as the EXE, and registers the same way: an Apps & Features entry with your icon, a Start Menu shortcut, an optional desktop shortcut and an optional PATH entry. It locks the install folder down like the EXE (only SYSTEM and administrators may change it), supports [per-user builds]({{ '/guides/per-user/' | relative_url }}) and runs your [install hooks]({{ '/guides/hooks/' | relative_url }}). Each installed file is its own component with a stable GUID, so repairs and upgrades work file by file.

What it does not have is the EXE's wizard: double-clicked, it shows Windows Installer's basic progress window and nothing else. (Wine, where this site's screenshots are taken, does not draw that window, so it has no screenshot here.)

Use the EXE for people who download and click, and the MSI for machines that are managed. Don't use both on one machine; [they refuse to install over each other](#exe-or-msi-not-both).

## Install silently

From an elevated prompt or a deployment tool (a per-machine MSI needs administrator rights, and a silent install without them fails):

{% include term.html name="msi-install" title="Command Prompt (administrator)" %}

`/qn` means no UI, and `/l*v install.log` writes a verbose log, which is the first place to look when an install fails. Every action reports its result there; `Return value 1` is success and `3` is a failure:

{% include term.html name="msi-log-tail" title="install.log" %}

Afterwards Windows lists the product in Apps & Features, with the name, version, publisher, comments and icon from the MSI, under `HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall\{ProductCode}`. Its folder is on the system PATH. The MSI writes the folder with a trailing backslash, as Windows Installer writes every folder path (Node.js's MSI does the same); Windows treats it the same as the EXE's entry without one:

{% include term.html name="msi-path" title="Command Prompt" %}

## Properties

Public properties set the optional tasks and the folder:

{% include term.html name="msi-options" title="Command Prompt (administrator)" %}
{% include term.html name="msi-options-files" %}

| Property | Default | Meaning |
| --- | --- | --- |
| `INSTALLDIR` | `install_root\install_dir_name` | Install folder. |
| `ADDTOPATH` | `1` | With `windows.add_to_path = .optional`: `0` leaves the folder off PATH. |
| `DESKTOPSHORTCUT` | `0` | With `windows.desktop_shortcut = .optional`: `1` creates a desktop shortcut. |
| `REGISTERMCP` | `1` | With `mcp.register = .optional`: `0` skips registering the MCP server with the user's AI tools. |

With `.always` or `.never` the property has no effect. The [MSI properties reference]({{ '/reference/msi-properties/' | relative_url }}) has the full list, including the standard ones zstaller sets.

## Upgrades

Installing a newer version replaces the older one in one step (a *major upgrade*):

{% include term.html name="msi-upgrade" title="Command Prompt (administrator)" %}

Installing an older version over a newer one stops, with "A newer version of … is already installed" in the log and exit code 1603 on Windows (Wine, where this transcript was made, reports 67):

{% include term.html name="msi-downgrade" title="Command Prompt (administrator)" %}

Windows Installer recognizes versions of a product by its **upgrade code**. Set `windows.upgrade_code` once, before your first release, and never change it; a new upgrade code makes the next version install beside the old one. Without it, zstaller derives one from the package name, so renaming the package changes it.

```zig
.windows = .{
    // Generate once, e.g. with PowerShell's New-Guid, and keep it forever.
    .upgrade_code = "{3C1B6E0A-8F7D-4E52-9B1A-6D2C4F8E7A10}",
},
```

### Versions

MSI versions are `major.minor.build`, with major and minor up to 255 and build up to 65535. zstaller uses your package version without its pre-release and build parts, and gives every release its own product code, so the `1.0.0` MSI replaces the `1.0.0-rc.1` one even though both are ProductVersion 1.0.0.

A version that does not fit, such as `2026.10.0`, fails the build:

{% include term.html name="error-msi_version" %}

Set `windows.msi_version`, and keep it increasing with every release, or upgrades stop working:

```zig
.windows = .{ .msi_version = "26.10.0" },
```

## Uninstall

By file, or by product code (the key name in the registry, above):

{% include term.html name="msi-uninstall" title="Command Prompt (administrator)" %}

```bat
msiexec /x {PRODUCT-CODE} /qn
```

Users uninstall from Settings > Apps like any other program. The entry has no Modify or Repair buttons.

## Deployment tools

- **Group Policy**: assign the MSI to computers in a Software Installation policy. To change a property, use a transform, or set the defaults you want in `build.zig` (for example `add_to_path = .never`).
- **Intune**: add it as a line-of-business app, or wrap it as a Win32 app with the install command `msiexec /i myapp-1.2.0-windows-x86_64.msi /qn` and the uninstall command `msiexec /x {PRODUCT-CODE} /qn`. Detection by MSI product code works.
- **SCCM / Configuration Manager**: create a Windows Installer deployment type from the MSI; it reads the product code itself.

## EXE or MSI, not both

The EXE and the MSI of a product would put the same files in the same folder under two Apps & Features entries, and uninstalling one would break the other. So each refuses while the other is installed. The EXE looks for the MSI's upgrade code:

{% include shot.html name="exe-refuses-msi" caption="Running the EXE while the MSI is installed." small=true %}

and the MSI looks for the EXE's Apps & Features entry. Windows Installer stops before changing anything, with this message (in a message box, or in the log of a silent install) and exit code 1603:

> Zstaller Sample is already installed with its setup program in C:\Program Files\Zstaller Sample. Uninstall it from Settings > Apps first, or use the setup program to upgrade it.

To switch, uninstall one, then install the other. Repairing and removing an installed MSI are not affected.

## What is inside

zstaller writes the MSI itself, in Zig: an OLE compound file holding the installer database (its tables and string pool), summary information and an MSZIP cabinet compressed on every CPU core. [How the MSI is written]({{ '/msi/' | relative_url }}) explains each layer. `msiinfo` from msitools lists what the sample's MSI holds:

{% include term.html name="msi-tables" %}
{% include term.html name="msi-properties" %}

## Limits

- The UI is Windows Installer's basic progress window: no license page, folder picker or checkboxes. Use the EXE where people install by hand.
- Text in the MSI must fit Windows-1252 (Western European characters).
- There is one feature per MSI; users cannot pick components.
- Windows Installer handles files in use itself, so [`close_running_apps`]({{ '/guides/programs-in-use/' | relative_url }}) applies to the EXE only.

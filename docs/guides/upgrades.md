---
title: Upgrades and uninstalling
lead: Ship a new version and the installers replace the old one in place, keeping it working until the new one is ready. Uninstalling removes everything they put on the machine.
---

## Upgrading with the EXE

Build the new version (bump `version` in `build.zig.zon`) and run its setup program on a PC with the old one. The Welcome page says what will happen:

{% include shot.html name="upgrade-welcome" caption="Version 1.0.0 is installed and will be upgraded." %}

The folder starts where the earlier version is:

{% include shot.html name="upgrade-location" caption="An upgrade defaults to the existing folder." %}

and the rest of the wizard is the same:

{% include shot.html name="upgrade-finished" caption="The new version is installed." %}

How the upgrade works:

- **In place, or moved.** Keep the folder and files are replaced; pick another and the installation moves there, and the old folder is cleaned up.
- **The old version keeps working until the end.** New files are written before old ones are removed, so a failed upgrade leaves the earlier version in place. A failed fresh install removes its folder.
- **Settings carry over.** The PATH entry, shortcuts and AI-tool registrations are updated for the new folder.
- **Running programs** are handled first; see [Programs in use]({{ '/guides/programs-in-use/' | relative_url }}).

### The same version again

Running the setup program of the version that is installed repairs it: it installs the files again, along with the shortcuts and registration.

{% include shot.html name="repair-welcome" caption="This version is already installed; Setup will repair it." %}

### An older version

Installing an older version over a newer one is refused, in the wizard and on the command line:

{% include shot.html name="downgrade-refused" caption="Downgrades are refused." small=true %}
{% include term.html name="downgrade-silent" title="Command Prompt (administrator)" %}

Uninstall the newer version first to go back.

## Upgrading with the MSI

The MSI does a Windows Installer *major upgrade*: installing the new MSI removes the old version and installs the new one in one transaction, and installing an older one fails. [MSI for enterprise]({{ '/guides/msi/' | relative_url }}#upgrades) shows both, and why `upgrade_code` must never change.

## Pre-releases

Versions are semantic versions, and pre-releases upgrade correctly everywhere: `1.2.0-rc.1` → `1.2.0` is an upgrade for the EXE, the MSI (each release has its own product code) and the `.deb` (zstaller writes `1.2.0~rc.1`, which dpkg sorts before `1.2.0`).

## Uninstalling

Users uninstall from Settings > Apps > Installed apps (or the old Programs and Features), which runs `uninstall.exe` from the install folder:

<div class="shots">
{% include shot.html name="uninstall-confirm" caption="The uninstaller's confirmation page." %}
{% include shot.html name="uninstall-finished" caption="Removed." %}
</div>

{% include shot.html name="apps-and-features" caption="The sample in the list of installed programs (Wine's Add/Remove Programs, standing in for Apps & Features)." %}

The uninstaller:

1. checks for [programs still running](#programs-in-use) from the folder,
2. runs the [`before_uninstall` hook]({{ '/guides/hooks/' | relative_url }}), if any,
3. removes the [MCP registrations]({{ '/guides/mcp/' | relative_url }}) it made, from every user profile,
4. removes every file the installer wrote (skipping anything reached through a junction), the shortcuts, its PATH entry and the Apps & Features entry,
5. and once it has exited, a hidden helper copy deletes `uninstall.exe` and the empty folder. The helper starts in `%TEMP%`, so it does not keep the folder open.

Files the application created itself in the install folder are not the installer's, so the folder stays if any are left.

From the command line:

{% include term.html name="silent-uninstall" title="Command Prompt (administrator)" %}

or `setup.exe /uninstall /S`, which finds the installation in the registry. [Silent installs and switches]({{ '/guides/silent-installs/' | relative_url }}#uninstall-silently) has both.

### Programs in use

If the application is running, the uninstaller says so before touching anything:

{% include shot.html name="in-use-uninstall" caption="The uninstaller lists the program that is running." %}

[Programs in use]({{ '/guides/programs-in-use/' | relative_url }}) explains the choices.

## Ubuntu

`sudo apt install ./myapp_1.3.0_amd64.deb` upgrades an installed package, and keeps changes the administrator made to files in `/etc`. `sudo apt remove myapp` uninstalls and `sudo apt purge myapp` also removes the configuration files. See [The .deb package]({{ '/guides/deb/' | relative_url }}).

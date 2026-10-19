---
title: Silent installs and switches
lead: The EXE installer runs without any window with /S, for scripts, provisioning and deployment tools. Its switches also preset the wizard.
---

## Install silently

Run the setup program with `/S` from an elevated prompt (or a deployment tool, which runs elevated). It installs with the defaults and exits with 0. Setup is a Windows program rather than a console one, so Command Prompt does not wait for it unless you use `start /wait`; the transcripts on this page do that, then show the exit code and anything Setup wrote to standard error:

{% include term.html name="silent-install" title="Command Prompt (administrator)" %}

The program is installed, with an uninstaller next to it:

{% include term.html name="silent-files" %}

and, with `add_to_path` left at `.optional`, the folder is on the system PATH, so a new terminal can run it:

{% include term.html name="silent-path" title="Command Prompt" %}
{% include term.html name="silent-run" title="Command Prompt" %}

## Choose what it does

Switches turn the optional tasks on and off and pick the folder:

{% include term.html name="silent-options" title="Command Prompt (administrator)" %}

{% include term.html name="silent-options-files" %}
{% include term.html name="silent-options-desktop" %}

| Switch | Meaning |
| --- | --- |
| `/S`, `/silent`, `/quiet` | No windows. Errors go to standard error and the exit code. |
| `/D=<folder>` | Install folder. Quote the whole switch when the path has spaces: `"/D=C:\My Apps\X"`. It may appear anywhere on the command line. |
| `/PATH`, `/NOPATH` | Add, or do not add, the folder to PATH (with `add_to_path = .optional`). |
| `/DESKTOP`, `/NODESKTOP` | Create, or do not create, a desktop shortcut (with `desktop_shortcut = .optional`). |
| `/MCP`, `/NOMCP` | Register, or do not register, the MCP server with the user's AI tools (with `mcp.register = .optional`). |
| `/uninstall`, `/u` | Uninstall. `uninstall.exe` does this with no switches. |
| `/?`, `/h`, `/help` | Show the switches. |

Switches are not case-sensitive and may start with `-` instead of `/`. Without `/S`, they set the wizard's starting choices, so `setup.exe /NOPATH /DESKTOP` opens the wizard with the PATH box unticked and the desktop box ticked. `/D=` works even when `allow_install_dir_change = false` hides the Browse button, so administrators can still choose.

Defaults for silent installs match the wizard's: PATH and AI tools on, desktop shortcut off, unless the option is `.always` or `.never`.

## Uninstall silently

Run the uninstaller from the install folder with `/S`:

{% include term.html name="silent-uninstall" title="Command Prompt (administrator)" %}

or ask the setup program, which finds the installation in the registry:

{% include term.html name="silent-uninstall-setup" title="Command Prompt (administrator)" %}

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success |
| `1` | Error: the message says what. Includes "a newer version is installed" and "the MSI is installed". |
| `2` | Cancelled (in the wizard) |
| `3` | Bad arguments |

Some failures, as they print:

{% include term.html name="silent-not-installed" title="Command Prompt (administrator)" %}
{% include term.html name="downgrade-silent" title="Command Prompt (administrator)" %}

A switch Setup does not recognize is reported in a message box, even with `/S`, and Setup exits with 3 once it is closed. Check the command line before handing it to a deployment tool:

{% include shot.html name="bad-switch" caption="`setup.exe /S /FOO`." small=true %}

## Programs still running

If programs are running from the install folder, a silent run prints them and fails, or with `close_running_apps = true` closes them without asking. See [Programs in use]({{ '/guides/programs-in-use/' | relative_url }}).

## In PowerShell and deployment tools

PowerShell does not wait for Setup on its own either. Use `Start-Process -Wait` to get the exit code, and `-RedirectStandardError` to keep the error message:

```powershell
$p = Start-Process .\myapp-1.2.0-windows-x86_64-setup.exe -ArgumentList '/S', '/NOPATH' `
    -Wait -PassThru -RedirectStandardError setup-errors.txt
$p.ExitCode
```

Deployment tools such as Intune (as a Win32 app) and SCCM take the same command line. For Group Policy software installation, which only takes MSI packages, use the [MSI]({{ '/guides/msi/' | relative_url }}).

To detect an installation, look for the Apps & Features entry under `HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall` (per-user builds: `HKCU`):

{% include term.html name="silent-registry" title="Command Prompt" %}

---
title: Setup command line
lead: Switches and exit codes of the EXE installer and its uninstaller.
---

```
myapp-1.2.0-windows-x86_64-setup.exe [/S] [/D=<folder>] [/PATH | /NOPATH] [/DESKTOP | /NODESKTOP] [/MCP | /NOMCP]
myapp-1.2.0-windows-x86_64-setup.exe /uninstall [/S]
"C:\Program Files\My App\uninstall.exe" [/S]
```

## Switches

| Switch | Meaning | Applies when |
| --- | --- | --- |
| `/S`, `/silent`, `/quiet` | No windows. Errors go to standard error and the exit code. | Always |
| `/D=<folder>` | Install folder. Quote the whole switch when the path has spaces: `"/D=C:\My Apps\X"`. Anywhere on the command line. | Installing |
| `/PATH`, `/NOPATH` | Add, or do not add, the folder to PATH. | `add_to_path = .optional` |
| `/DESKTOP`, `/NODESKTOP` | Create, or do not create, a desktop shortcut. | `desktop_shortcut = .optional` |
| `/MCP`, `/NOMCP` | Register, or do not register, the MCP server with the user's AI tools. | `mcp.register = .optional` |
| `/uninstall`, `/u` | Uninstall. `uninstall.exe` does this with no switches. | Always |
| `/?`, `/h`, `/help` | Show the switches. | Always |

- Switches are not case-sensitive, and may start with `-` instead of `/`.
- Without `/S`, they preset the wizard's choices.
- `/D=` works even when `allow_install_dir_change = false`.
- Silent installs use the same defaults as the wizard: PATH and AI tools on, desktop shortcut off.

{% include shot.html name="help" caption="`setup.exe /?`" small=true %}

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success. |
| `1` | Error. Includes a newer version installed, the MSI installed, not installed (for `/uninstall`), programs in use, and a failing `after_install` hook. |
| `2` | Cancelled in the wizard. |
| `3` | Bad arguments. |

## Where things are

| What | Per machine | Per user |
| --- | --- | --- |
| Install folder | `install_root\install_dir_name` | `%LOCALAPPDATA%\Programs\install_dir_name` |
| Uninstaller | `<install folder>\uninstall.exe` | the same |
| Apps & Features entry | `HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall\zstaller.<name>` | the same under `HKCU` |
| PATH entry | `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment`, `Path` | `HKCU\Environment`, `Path` |
| Start Menu shortcut | All users' Start Menu, `Programs\<display_name>.lnk` | The user's Start Menu |
| Desktop shortcut | Public desktop | The user's desktop |

[Silent installs and switches]({{ '/guides/silent-installs/' | relative_url }}) shows these in use.

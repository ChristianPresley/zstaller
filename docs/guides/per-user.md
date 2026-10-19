---
title: Per-user installs
lead: With windows.scope = .user, both Windows installers install for the person who runs them, without administrator rights or a UAC prompt, the way many editors and developer tools do.
---

## Turn it on

```zig
.windows = .{
    .scope = .user,
},
```

The sample builds this way with `zig build installer -Dper-user`.

## What changes

The wizard is the same, but the default folder moves into the user's profile:

<div class="shots">
{% include shot.html name="peruser-welcome" caption="No administrator prompt before this page." %}
{% include shot.html name="peruser-location" caption="`%LOCALAPPDATA%\\Programs\\Zstaller Sample`." %}
{% include shot.html name="peruser-options" caption="The PATH entry is the user's own." %}
</div>

| | `.machine` (default) | `.user` |
| --- | --- | --- |
| Administrator rights / UAC | Required | Not needed |
| Install folder | `install_root\install_dir_name` | `%LOCALAPPDATA%\Programs\install_dir_name` |
| Apps & Features entry | `HKEY_LOCAL_MACHINE` | `HKEY_CURRENT_USER` |
| Start Menu and desktop shortcuts | All users' | The user's own |
| PATH | System PATH | The user's PATH |
| Folder locked down to administrators | Yes | No (it is in the user's profile) |
| Install hooks run as | Administrator (MSI: LocalSystem) | The user |
| Seen by other users of the PC | Yes | No |

`install_root` does not apply to per-user builds.

After a per-user install, the entry is under `HKCU`:

{% include term.html name="peruser-registry" title="Command Prompt" %}

and the folder is on the user's PATH:

{% include term.html name="peruser-path" title="Command Prompt" %}

## The MSI

A per-user MSI installs without elevation too: it leaves out `ALLUSERS`, so Windows Installer installs it for the current user. `msiexec /i myapp.msi /qn` works from a normal prompt.

## Choosing

- **Per machine** suits software an administrator deploys, services, and anything every user of a PC needs. Its folder is protected, so standard users cannot tamper with the programs.
- **Per user** suits tools people install for themselves, on PCs where they are not administrators.

A per-user and a per-machine build of the same product are different installations and install side by side, so ship one or the other. If you change your mind between releases, ask users to uninstall the old one.

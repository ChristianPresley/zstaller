---
title: Install folder, PATH and shortcuts
lead: Where the files go, whether the folder is added to PATH, and which shortcuts appear, for both Windows installers.
---

## The install folder

The default folder is `install_root\install_dir_name`:

```zig
.windows = .{
    .install_root = .program_files,     // .program_data or .system_drive
    .install_dir_name = "Example Corp\\My App", // default: display_name
    .allow_install_dir_change = true,
},
```

| `install_root` | Default folder |
| --- | --- |
| `.program_files` (default) | `C:\Program Files\<install_dir_name>`, the native Program Files on both x64 and ARM64 |
| `.program_data` | `C:\ProgramData\<install_dir_name>` |
| `.system_drive` | `C:\<install_dir_name>` |

<div class="shots">
{% include shot.html name="wizard-location" caption="`.program_files`" %}
{% include shot.html name="root-program-data" caption="`.program_data`" %}
{% include shot.html name="root-system-drive" caption="`.system_drive`" %}
</div>

`install_dir_name` may nest folders with backslashes. Users can pick another folder in the wizard, with `/D=` on the command line or with the MSI's `INSTALLDIR`. Set `allow_install_dir_change = false` to take the Browse button away in the wizard (`/D=` and `INSTALLDIR` still work, for administrators):

{% include shot.html name="minimal-location" caption="`allow_install_dir_change = false`." %}

### Folder security

The uninstaller in the folder runs as administrator, and the folder may be on the system PATH, so only SYSTEM and administrators may change it, as in Program Files, wherever it is. Setup creates new folders that way. An existing folder that other users can change is locked down the same way when it is empty or holds an earlier installation; otherwise Setup stops and asks for an empty folder. It also stops at junctions and symbolic links, and inside a folder other users can rename (such as one a user made in `C:\`), except the folders of the application's own default location (`Example Corp` in `C:\Example Corp\My App`), which it locks down. [Per-user installs]({{ '/guides/per-user/' | relative_url }}) skip all of this; their folder is in the user's profile.

## PATH

`windows.add_to_path` decides whether the install folder is added to PATH, so users can run your program from any terminal:

| Value | Wizard | Silent EXE | MSI |
| --- | --- | --- | --- |
| `.optional` (default) | Ticked checkbox | Added unless `/NOPATH` | Added unless `ADDTOPATH=0` |
| `.always` | No checkbox; always added | Always added | Always added |
| `.never` | No checkbox; never added | Never added | Never added |

The entry is appended to the end of the system PATH (the user's PATH for per-user builds), and a new terminal sees it:

{% include term.html name="silent-path" title="Command Prompt" %}
{% include term.html name="silent-run" title="Command Prompt" %}

Uninstalling removes only the entry the installer added. The rest of PATH is left exactly as it was.

## Shortcuts

| Option | Default | What it adds |
| --- | --- | --- |
| `start_menu_shortcut` | `true` | A Start Menu shortcut named after `display_name`, opening the application |
| `desktop_shortcut` | `.optional` | `.optional`: an unticked checkbox, `/DESKTOP`, `DESKTOPSHORTCUT=1`. `.always` or `.never` without asking. |
| `programs[i].shortcut` | none | A Start Menu shortcut for another program; see [Multiple programs and files]({{ '/guides/programs-and-files/' | relative_url }}) |

Shortcuts are for all users, or for the installing user in per-user builds. They use the program's own icon, so give your executable an icon resource (the sample's [`build.zig`]({{ site.blob_url }}/examples/sample/build.zig) shows how).

{% include shot.html name="start-menu" caption="The sample's Start Menu shortcut (Wine's Start menu)." small=true %}
{% include shot.html name="desktop-shortcut" caption="The desktop shortcut, from `/DESKTOP`." small=true %}

The shortcuts the sample's installer created, with the desktop shortcut turned on:

{% include term.html name="shortcuts-start-menu" title="Command Prompt" %}
{% include term.html name="shortcuts-desktop" title="Command Prompt" %}

## Which tasks the wizard offers

The Additional Tasks page shows one checkbox per `.optional` setting, and disappears when nothing is optional:

<div class="shots">
{% include shot.html name="wizard-options" caption="PATH, desktop and AI tools all `.optional`." %}
{% include shot.html name="pathonly-options" caption="Only `add_to_path = .optional`." %}
{% include shot.html name="always-location" caption="Everything `.always`: no Additional Tasks page, Install comes next." %}
</div>

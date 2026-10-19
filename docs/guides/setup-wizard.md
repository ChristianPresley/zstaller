---
title: The setup wizard
lead: Run normally, the EXE installer shows a native Windows wizard. This page walks through every page of it, and the option behind each thing you see.
---

The setup program is a small native Windows program written in Zig, with your files compressed inside it. It is 493×360 pixels at 100% display scaling (the size of a Windows Installer dialog), follows each monitor's scaling, and shows your application's icon in its title bar and taskbar button. It asks for administrator rights unless it is a [per-user build]({{ '/guides/per-user/' | relative_url }}).

The screenshots on this page are of the sample application, which sets custom artwork, a license and every optional checkbox. With fewer options, pages disappear; see [Pages that come and go](#pages-that-come-and-go).

## Welcome

{% include shot.html name="wizard-welcome" caption="The Welcome page: product name and version, and what happens next." %}

The heading and the first sentence come from `windows.display_name` and the package version. Set `windows.wizard.welcome_text` to replace the body text. When an older version is installed, a sentence says it will be upgraded, and when the same version is installed, that Setup will repair it; see [Upgrades and uninstalling]({{ '/guides/upgrades/' | relative_url }}).

The picture on the left is `windows.wizard.welcome_image`, or zstaller's own artwork when you don't set one. The footer shows the product and version on every page.

## License Agreement

{% include shot.html name="wizard-license" caption="The License page, with Next disabled until the box is ticked." %}

Shown only when `windows.wizard.license_file` is set. The file is UTF-8 text, shown in a scrolling box. **Next** stays disabled until the user ticks *I accept the terms of the license agreement*:

{% include shot.html name="wizard-license-accepted" caption="Accepted: Next is enabled." %}

The banner across the top of this and every later page is `windows.wizard.banner_image`.

## Choose Install Location

{% include shot.html name="wizard-location" caption="The install folder, with the space it needs and the space free on that drive." %}

The folder starts as `install_root\install_dir_name`, `C:\Program Files\Zstaller Sample` here. The user can type another path, or click **Browse** for the standard Windows folder picker.

| What you see | Option |
| --- | --- |
| The default folder | `windows.install_root` (`.program_files`, `.program_data`, `.system_drive`) and `windows.install_dir_name` |
| The Browse button and an editable path | `windows.allow_install_dir_change` (default `true`) |
| A folder in the user's profile | `windows.scope = .user` |

An upgrade starts at the folder the earlier version is in. [Install folder, PATH and shortcuts]({{ '/guides/folder-path-shortcuts/' | relative_url }}) shows each choice.

## Additional Tasks

{% include shot.html name="wizard-options" caption="One checkbox for each optional task." %}

This page appears when at least one task is optional:

| Checkbox | Shown when | Starts |
| --- | --- | --- |
| Add *app* to the PATH environment variable | `windows.add_to_path = .optional` (the default) | ticked |
| Create a desktop shortcut | `windows.desktop_shortcut = .optional` (the default) | unticked |
| Add *app* to my AI tools (…) | `mcp` is set and `mcp.register = .optional` (the default) | ticked |

`.always` does the task without asking, and `.never` never does it; either way the checkbox disappears. The AI tools in brackets are the ones in `mcp.clients`; see [MCP servers]({{ '/guides/mcp/' | relative_url }}).

The button on the last page before installing reads **Install**.

## Installing

{% include shot.html name="wizard-installing" caption="Progress and the current step. The buttons are disabled while files are copied." %}

Setup unpacks and checks the payload (it carries a SHA-256, so a damaged download is reported as damaged instead of half-installed), writes the files, then registers the application. If programs are running from the install folder, the [Programs in Use]({{ '/guides/programs-in-use/' | relative_url }}) page comes first.

## Finished

{% include shot.html name="wizard-finished" caption="Done, with the Launch checkbox ticked." %}

The **Launch** checkbox is `windows.wizard.launch_on_finish` (default `true`). The application starts as the signed-in user, not as administrator, even though Setup itself runs elevated. The sample is a console program, so Windows opens a console for it:

{% include shot.html name="wizard-launched" caption="The sample application, launched from the Finished page." %}

Set `windows.wizard.finish_text` to replace the text. If something went wrong, this page shows what happened instead, and the button reads **Close**; for example a failing [install hook]({{ '/guides/hooks/' | relative_url }}):

{% include shot.html name="hook-failed" caption="A failed install explains itself on the last page." %}

## Cancel

Cancel, or closing the window, asks first. Nothing has been changed until the Installing page.

{% include shot.html name="wizard-cancel-confirm" caption="Cancelling asks for confirmation." small=true %}

## Pages that come and go

A minimal configuration has fewer pages. This build has no license, no optional tasks, `allow_install_dir_change = false`, `launch_on_finish = false` and its own welcome and finish text:

```zig
.windows = .{
    .add_to_path = .never,
    .desktop_shortcut = .never,
    .allow_install_dir_change = false,
    .wizard = .{
        .welcome_text = "Setup will install Zstaller Sample, a tiny program that shows how zstaller packages Zig applications.\n\nIt takes a few seconds.",
        .finish_text = "Zstaller Sample is ready. Open a new terminal and run sample to try it.",
        .launch_on_finish = false,
    },
},
```

<div class="shots">
{% include shot.html name="minimal-welcome" caption="Custom `welcome_text`, built-in artwork." %}
{% include shot.html name="minimal-location" caption="No Browse button, and Install comes straight after." %}
{% include shot.html name="minimal-finished" caption="Custom `finish_text` and no Launch checkbox." %}
</div>

The whole sequence, with what decides each page:

| Page | Shown |
| --- | --- |
| Welcome | Always |
| License Agreement | `wizard.license_file` is set |
| Choose Install Location | Always (read-only when `allow_install_dir_change = false`) |
| Additional Tasks | Any of PATH, desktop shortcut or AI tools is `.optional` |
| Programs in Use | Programs are running from the install folder |
| Installing | Always |
| Finished | Always |

## The uninstaller

`uninstall.exe` in the install folder, which Apps & Features runs, uses the same window with three pages:

<div class="shots">
{% include shot.html name="uninstall-confirm" caption="Confirm." %}
{% include shot.html name="uninstall-finished" caption="Done." %}
</div>

See [Upgrades and uninstalling]({{ '/guides/upgrades/' | relative_url }}#uninstalling) for what it removes.

## Command-line help

`setup.exe /?` shows the switches in a message box. Every switch also presets the wizard, so `setup.exe /NOPATH` opens it with the PATH box unticked. See [Silent installs and switches]({{ '/guides/silent-installs/' | relative_url }}).

{% include shot.html name="help" caption="The help message box." small=true %}

---
title: Programs in use
lead: Windows cannot replace or delete a file that a running program has open. Before the EXE installer or uninstaller changes anything, it finds the programs in the way and lets the user deal with them.
---

## What Setup checks

Before installing, upgrading or uninstalling, Setup looks for processes running from the install folder, and asks Windows (the Restart Manager) which programs and services have the installed files open. If there are any, the wizard stops on the **Programs in Use** page, listing each one's full path, process name, process ID and the user or service account it runs as.

## The default: ask the user to close them

With `close_running_apps` left at `false`, the user closes the programs and clicks **Retry**:

{% include shot.html name="in-use-install-no-close" caption="Installing over a running copy, with `close_running_apps = false`." %}

## Offer to close them

```zig
.windows = .{
    .close_running_apps = true,
},
```

adds a **Close programs** button:

{% include shot.html name="in-use-uninstall" caption="The uninstaller, with `close_running_apps = true`." %}

which asks before doing anything:

{% include shot.html name="in-use-close-confirm" caption="Unsaved work in the programs would be lost." small=true %}

Services are stopped through the service manager; other programs are force-quit. Then Setup carries on:

{% include shot.html name="in-use-closed" caption="The program was closed and the uninstall finished." %}

The sample turns this on, because its MCP server may be running inside an AI tool when the user upgrades.

## Silent runs

A silent (`/S`) run cannot ask. Without `close_running_apps` it prints the list to standard error and fails, before changing anything:

{% include term.html name="in-use-silent" title="Command Prompt (administrator)" %}

With `close_running_apps = true` it closes them without asking and carries on, which suits deployment tools that install while users are logged on.

## The MSI

The MSI leaves files in use to Windows Installer, which shows its own "files in use" prompt or schedules the replacement for the next restart. `close_running_apps` does not apply to it.

> **Under Wine** (where these screenshots were taken) there is no Restart Manager or service manager, so only programs running from the install folder are found. On Windows, programs elsewhere that have the files open, and services, are listed too.

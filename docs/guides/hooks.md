---
title: Install hooks
lead: Run one of your installed programs after installing, and another before uninstalling, to set up and clean up what files alone cannot, such as a service, a file association or machine-wide settings.
---

## Set them

```zig
.windows = .{
    .after_install = .{ .program = "myapp.exe", .args = &.{"--register"} },
    .before_uninstall = .{ .program = "myapp.exe", .args = &.{"--unregister"} },
},
```

`program` is an installed `.exe`: the application, one of [`programs`]({{ '/guides/programs-and-files/' | relative_url }}), or an `extra_files` destination. Arguments are quoted for you (at most 255 characters in all).

The sample's `sample-tool --register` writes `%ProgramData%\Zstaller Sample\registered.txt`, and `--unregister` removes it:

{% include term.html name="hook-install" title="Command Prompt (administrator)" %}
{% include term.html name="hook-state" %}
{% include term.html name="hook-uninstall" title="Command Prompt (administrator)" %}
{% include term.html name="hook-state-after" %}

## When they run, and as whom

| | `after_install` | `before_uninstall` |
| --- | --- | --- |
| Runs | After every install, upgrade and repair, once the files are in place | Only on a real uninstall (not when an upgrade replaces the app), before any file is removed |
| A non-zero exit code | Fails the install | Is ignored, so a broken hook never blocks uninstalling |
| Working directory | The install folder | The install folder |
| Window | None (hidden) | None (hidden) |
| Runs as (EXE) | The installing administrator | The administrator uninstalling |
| Runs as (MSI) | LocalSystem, as a deferred custom action | LocalSystem |
| Runs as (per-user builds) | The user | The user |

Because `after_install` runs again on every upgrade and repair, make it safe to run more than once. Because it may run as LocalSystem, it should not rely on the user's profile, `HKEY_CURRENT_USER` or mapped drives.

## When a hook fails

If `after_install` exits with a non-zero code, the EXE reports the code and leaves the files in place, so the user can run Setup again or uninstall:

{% include shot.html name="hook-failed" caption="The Finished page after a failing hook." %}
{% include term.html name="hook-failed-silent" title="Command Prompt (administrator)" %}

The MSI rolls the whole install back and exits with 1603 on Windows (Wine, where these transcripts were made, reports its own code). Nothing is left behind; the install folder is gone:

{% include term.html name="hook-failed-msi" title="Command Prompt (administrator)" %}
{% include term.html name="hook-failed-msi-files" title="Command Prompt" %}

## On Ubuntu

The `.deb` has no hooks option; use maintainer scripts (`deb.scripts`), which dpkg runs on install, upgrade and removal. [The .deb package]({{ '/guides/deb/' | relative_url }}#maintainer-scripts) shows a `postinst` that enables a systemd service.

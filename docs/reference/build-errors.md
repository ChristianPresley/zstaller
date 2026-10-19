---
title: Build errors
lead: zstaller checks your configuration when it builds, and stops with a message that names the option and the value. These are real messages, from a project with each mistake made on purpose.
---

A configuration mistake fails only the `installer` step, once. `zig build`, `zig build run` and `zig build test` keep working, so a half-finished configuration never blocks the rest of your work.

## Package name

{% include term.html name="error-name" %}

Package names use letters, digits, `_`, `-` and `.`. For the `.deb`, the name is also lowercased.

## Upgrade code

{% include term.html name="error-guid" %}

A GUID with braces: `{3C1B6E0A-8F7D-4E52-9B1A-6D2C4F8E7A10}`. PowerShell's `New-Guid` makes one.

## Wizard images

{% include term.html name="error-banner" %}

Images must be exactly the sizes in [Branding the wizard]({{ '/guides/branding/' | relative_url }}#your-own-images), or twice that.

## Icon

{% include term.html name="error-icon" %}

## Extra files

{% include term.html name="error-extra" %}

`dest` is a relative path inside the install folder. It may not escape it, or replace the application, a program or `uninstall.exe`.

## MSI version

{% include term.html name="error-msi_version" %}

## Characters MSI cannot store

{% include term.html name="error-charset" %}

MSI text uses Windows-1252: Latin letters with accents, curly quotes, dashes, € and ™. Set a separate `windows.display_name` or `windows.publisher` if your names need other characters.

## Others

| Message | Fix |
| --- | --- |
| `a description is required for MSI packages; add .description to build.zig.zon` | Add `.description = "..."` to `build.zig.zon`. MSI, `.deb` and MCP bundles need it. |
| `set .deb.maintainer (e.g. "Jane Doe <jane@example.com>") to build .deb packages` | Set `deb.maintainer`, or a `windows.publisher` in `Name <email>` form. |
| `SOURCE_DATE_EPOCH is not a non-negative integer` | Set it to seconds since 1970, e.g. `$(git log -1 --format=%ct)`. |
| `no module named '...' available within module 'root'` | Create the module inside your `executable` function. See [Your first installers]({{ '/getting-started/first-installers/' | relative_url }}). |
| `expected path relative to build root; found absolute path` | A `.path` dependency must be relative. |
| `name must be a valid bare zig identifier` | Use an identifier in `build.zig.zon` and `metadata.name` for the real name. |

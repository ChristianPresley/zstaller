---
title: zstaller-mcp
lead: The small program the installers put next to an MCP server, which adds it to and removes it from people's AI tools.
---

It is installed only when `mcp` is set and `mcp.register` is not `.never`.

| Platform | Location |
| --- | --- |
| Windows | `<install folder>\zstaller-mcp.exe` |
| Ubuntu | `/usr/lib/<package>/zstaller-mcp` |

## Commands

{% include term.html name="mcp-usage" %}

| Command | What it does |
| --- | --- |
| `register` | Adds the server for the current user, to each configured AI tool they have. |
| `unregister` | Removes this installation's entries for the current user. |
| `unregister --all-users` | Removes them from every user profile on the machine. Needs administrator or root. |
| `status` | Shows which tools have an entry, and whether it points at this installation. |

Exit code `0` on success.

## Who runs it

| | Register | Unregister |
| --- | --- | --- |
| EXE | Setup, as the signed-in user (through Explorer), when the AI tools box is ticked or `/MCP` | `uninstall.exe`, `--all-users` |
| MSI | A deferred custom action impersonating the installing user, unless `REGISTERMCP=0` | The uninstall, `--all-users` |
| `.deb` | Each user, once | The package's `prerm`, `--all-users` |

## Examples

{% include term.html name="mcp-register" %}
{% include term.html name="mcp-status" %}
{% include term.html name="mcp-unregister" %}

## Rules it follows

- Writes only to tools whose settings folder exists.
- Changes or removes only entries whose `command` is this installation's program; a same-named server set up by the user is left alone and reported.
- Edits files in place keeping comments and formatting, writes atomically with the original permissions, and keeps `<file>.zstaller.bak` when registering.
- On unregister, removes the backup, an emptied `mcpServers`/`servers` object, and the file if it is then empty.
- Ignores a `XDG_CONFIG_HOME` that belongs to another user (as `sudo -u` can leak).

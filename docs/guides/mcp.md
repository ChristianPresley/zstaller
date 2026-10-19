---
title: MCP servers and AI tools
lead: If your program is an MCP server, zstaller packages it as an MCP bundle for Claude Desktop and registers it with the AI tools of the person who installs it.
---

[MCP](https://modelcontextprotocol.io) (the Model Context Protocol) lets AI tools such as Claude start a program and call the tools it offers, over standard input and output. The sample's `sample-tool mcp` is a small working server with one tool, `sha256`.

## Turn it on

```zig
.programs = &.{.{ .executable = createTool }},
.mcp = .{
    .name = "zstaller-sample",       // name shown in the AI tools
    .program = "sample-tool",        // one of .programs; null: the application
    .args = &.{"mcp"},               // arguments that start the server
    .icon = b.path("assets/sample.png"),
},
```

| Option | Default | Meaning |
| --- | --- | --- |
| `name` | Package name | Server name in the AI tools: letters, digits, `_` and `-`, at most 64. |
| `program` | The application | Which program is the server, by file name without `.exe`. |
| `args` | none | Arguments that start it as a server, e.g. `&.{ "mcp", "--stdio" }`. |
| `env` | none | Environment variables, `&.{.{ .name = "MYAPP_LOG", .value = "warn" }}`. They end up in plain-text files, so never put secrets here. |
| `bundle` | `true` | Build a `.mcpb` bundle per target. |
| `icon` | none | Square PNG for the bundle, ideally 512×512. |
| `register` | `.optional` | Register with the user's AI tools: `.never`, `.optional`, `.always`. |
| `clients` | Claude Code and VS Code | Which AI tools to register with (see below). |

## MCP bundles

Every target gets `<name>-<version>-<target>.mcpb`, an [MCP bundle](https://github.com/modelcontextprotocol/mcpb): a zip with a `manifest.json` and the server program. Claude Desktop installs one with a double-click, and the MCP Registry can list it, with the `fileSha256` from its `.sha256` file.

{% include term.html name="mcpb-contents" %}
{% include term.html name="mcpb-manifest" title="manifest.json" %}

The bundle holds only the server program. A server that needs other installed files should rely on the installers instead. Set `bundle = false` to skip bundles.

## Registering with AI tools

The installers also add the server to the AI tools of the user who installs, so it is there the next time they open them, with no setup. A small program, `zstaller-mcp`, is installed next to your application to do this (on Ubuntu in `/usr/lib/<package>/`).

| AI tool | File | Default |
| --- | --- | --- |
| Claude Code | `~/.claude.json` (`mcpServers`) | on |
| VS Code | `mcp.json` in the user settings folder (`servers`) | on |
| VS Code Insiders | the same, under `Code - Insiders` | off |
| Claude Desktop | `claude_desktop_config.json` | off (the `.mcpb` is the usual way) |
| Cursor | `~/.cursor/mcp.json` | off |
| Windsurf | `~/.codeium/windsurf/mcp_config.json` | off |

```zig
.mcp = .{
    // ...
    .register = .optional,          // .never, .optional or .always
    .clients = .{ .cursor = true }, // the defaults, plus Cursor
},
```

### Windows EXE

The Additional Tasks page has a ticked **Add … to my AI tools** box, naming the tools:

{% include shot.html name="wizard-options" caption="The AI tools checkbox." %}

`/NOMCP` turns it off for silent installs and `/MCP` on. Setup runs `zstaller-mcp register` as the signed-in user (through Explorer, as for Launch), since Setup itself runs as administrator. Before and after a silent install on a PC with Claude Code:

{% include term.html name="mcp-windows-install" title="Command Prompt (administrator)" %}
{% include term.html name="mcp-windows-claude-json" title="C:\Users\jane\.claude.json" %}

`zstaller-mcp status` in the install folder shows the same from the tool's side:

{% include term.html name="mcp-windows-status" title="Command Prompt" %}

An upgrade to another folder unregisters the old folder's entry first. Uninstalling removes the entry from every user profile:

{% include term.html name="mcp-windows-uninstall" title="Command Prompt (administrator)" %}
{% include term.html name="mcp-windows-claude-json-after" title="C:\Users\jane\.claude.json" %}

### Windows MSI

`REGISTERMCP=0` turns it off. An impersonated deferred custom action runs `zstaller-mcp register` as the user who installs; a failure there never fails the install.

### Ubuntu

Package scripts never write to people's home folders, so each user registers once:

{% include term.html name="mcp-register" %}

which adds an entry to each AI tool they have:

{% include term.html name="mcp-claude-json" title="~/.claude.json" %}
{% include term.html name="mcp-vscode-json" title="~/.config/Code/User/mcp.json" %}

Removing the package unregisters it for every user.

## zstaller-mcp

Users can run the helper themselves:

{% include term.html name="mcp-usage" %}
{% include term.html name="mcp-status" %}
{% include term.html name="mcp-unregister" %}

See the [zstaller-mcp reference]({{ '/reference/zstaller-mcp/' | relative_url }}) for where it is and every command.

## How it edits files safely

- Only a tool the user has (its settings folder exists) gets an entry.
- Only entries whose `command` is this installation's program are changed or removed. A server the user set up under the same name is left alone, and reported.
- Files are edited in place, so comments and formatting stay (VS Code allows comments in its JSON).
- Each change is written to a temporary file that replaces the original, keeping its permissions. Registering keeps the previous version as `<file>.zstaller.bak`.
- Unregistering removes that backup, the `mcpServers` (or `servers`) object if nothing else is left in it, and the file if it is then empty, so uninstalling leaves the files as they were before.
- A tool that is running may need a restart to see the change.

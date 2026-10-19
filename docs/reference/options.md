---
title: All options
lead: Every setting of addInstallers, with its default and what it changes. Each links to the guide that shows it.
wide: false
---

## Top level

| Option | Default | What it does |
| --- | --- | --- |
| `executable` | required | Builds your program for one target. See [Build API]({{ '/reference/build-api/' | relative_url }}#executablefn). |
| `targets` | all four | Which targets to package, e.g. `&.{ .windows_x86_64, .ubuntu_x86_64 }`. |
| `optimize` | `.ReleaseSafe` | Optimize mode of the packaged binaries. Debug info stays unless `executable` sets `.strip`. |
| `manifest_path` | `"build.zig.zon"` | Manifest that `name`, `version`, `description` and `license` are read from. |
| `metadata` | none | Overrides: `.name` (for names with dashes), `.version` (e.g. from `git describe`), `.description`, `.license`. Renaming changes the default upgrade code. |
| `icon` | none | `.ico` for the setup program, its wizard, Apps & Features and the MSI. [Branding]({{ '/guides/branding/' | relative_url }}#the-icon) |
| `programs` | none | More programs installed next to the application, each `{ .executable, .shortcut = null }`. [Guide]({{ '/guides/programs-and-files/' | relative_url }}) |
| `extra_files` | none | `{ .source, .dest }` files next to the binary; `dest` may use `/` subfolders. On Ubuntu: `/usr/share/<package>/<dest>`. [Guide]({{ '/guides/programs-and-files/' | relative_url }}#extra-files) |
| `windows` | see below | EXE and MSI settings. |
| `deb` | see below | `.deb` settings. |
| `mcp` | none | Package the application or one of `programs` as an MCP server. [Guide]({{ '/guides/mcp/' | relative_url }}) |
| `sign` | none | Code-signing function for Windows files. [Guide]({{ '/guides/code-signing/' | relative_url }}) |
| `install_subdir` | `"installers"` | Output folder under `zig-out/`. |
| `source_date_epoch` | `SOURCE_DATE_EPOCH`, else 1980-01-01 | Timestamp written into packages. [Guide]({{ '/guides/reproducible-builds/' | relative_url }}) |

## Windows: `.windows`

| Option | Default | What it does |
| --- | --- | --- |
| `publisher` | package name | Publisher in Apps & Features; MSI Manufacturer. |
| `display_name` | package name | Product name in the wizard, shortcuts and Apps & Features. |
| `install_dir_name` | `display_name` | Folder created in `install_root`; may nest, e.g. `"Acme\\Widget"`. |
| `install_root` | `.program_files` | `.program_files`, `.program_data` or `.system_drive` (`C:\`). [Guide]({{ '/guides/folder-path-shortcuts/' | relative_url }}) |
| `scope` | `.machine` | `.machine`: all users, needs administrator rights. `.user`: the current user, no elevation. [Guide]({{ '/guides/per-user/' | relative_url }}) |
| `allow_install_dir_change` | `true` | Whether the wizard lets users pick another folder (`/D=` and `INSTALLDIR` always work). |
| `upgrade_code` | derived from name | MSI UpgradeCode GUID. Set once, never change. [Guide]({{ '/guides/msi/' | relative_url }}#upgrades) |
| `msi_version` | package version | MSI ProductVersion (`major.minor.build`, at most 255.255.65535), for versions that do not fit. |
| `add_to_path` | `.optional` | `.never`, `.optional` (on unless unticked, `/NOPATH` or `ADDTOPATH=0`), `.always`. |
| `start_menu_shortcut` | `true` | Start Menu shortcut named after `display_name`. |
| `desktop_shortcut` | `.optional` | `.never`, `.optional` (an unticked checkbox, `/DESKTOP`, `DESKTOPSHORTCUT=1`), `.always`. |
| `close_running_apps` | `false` | Let the EXE close programs and services using the installed files, after asking. [Guide]({{ '/guides/programs-in-use/' | relative_url }}) |
| `after_install` | none | `{ .program = "x.exe", .args = &.{...} }` run after every install, upgrade and repair. [Guide]({{ '/guides/hooks/' | relative_url }}) |
| `before_uninstall` | none | The same, run before uninstalling. |
| `wizard` | see below | The EXE wizard's look and text. |

### The wizard: `.windows.wizard`

| Option | Default | What it does |
| --- | --- | --- |
| `welcome_image` | built-in artwork | PNG or BMP, 493×312 or 986×624, behind the Welcome and Finished pages. [Guide]({{ '/guides/branding/' | relative_url }}#your-own-images) |
| `banner_image` | built-in artwork | PNG or BMP, 493×58 or 986×116, across the top of the other pages. |
| `accent_color` | `0x0067C0` | Color of the built-in artwork, `0xRRGGBB`. [Guide]({{ '/guides/branding/' | relative_url }}#built-in-artwork) |
| `license_file` | none | UTF-8 text on a License page the user must accept. No page without it. |
| `welcome_text` | generated | Body of the Welcome page. |
| `finish_text` | generated | Body of the Finished page after a successful install. |
| `launch_on_finish` | `true` | A ticked "Launch" checkbox on the Finished page. |

### Hooks: `InstallCommand`

| Field | Meaning |
| --- | --- |
| `program` | Installed file name of an `.exe`: the application, one of `programs`, or an `extra_files` destination. |
| `args` | Its arguments, quoted for you, at most 255 characters in all. |

## Ubuntu: `.deb`

| Option | Default | What it does |
| --- | --- | --- |
| `maintainer` | `windows.publisher` if it is `Name <email>` | `Maintainer` field; required otherwise. |
| `section` | `"utils"` | `Section` field. |
| `priority` | `"optional"` | `Priority` field. |
| `homepage` | none | `Homepage` field. |
| `depends` | none | `Depends` field (rarely needed; binaries are static). |
| `copyright` | `windows.publisher`, else package name | Notice in the copyright file, with a year: `"2026 Example Corp"`. |
| `long_description` | none | Text after the description in `apt show`; blank lines separate paragraphs. |
| `files` | none | `{ .source, .dest, .mode = 0o644 }` at absolute paths. `/etc` files are conffiles; man pages are compressed. [Guide]({{ '/guides/deb/' | relative_url }}#files-anywhere-debfiles) |
| `desktop_entry` | none | Menu entry: `.categories = "Utility;"`, `.terminal = false`, `.icon` (square PNG). [Guide]({{ '/guides/deb/' | relative_url }}#a-menu-entry) |
| `scripts` | none | `.preinst`, `.postinst`, `.prerm`, `.postrm`, each starting with `#!`. [Guide]({{ '/guides/deb/' | relative_url }}#maintainer-scripts) |

## MCP: `.mcp`

| Option | Default | What it does |
| --- | --- | --- |
| `name` | package name | Server name in AI tools: letters, digits, `_`, `-`, at most 64. |
| `program` | the application | Which program is the server: one of `programs`, by file name without `.exe`. |
| `args` | none | Arguments that start it as a server. |
| `env` | none | `{ .name, .value }` environment variables. Stored in plain text: no secrets. |
| `bundle` | `true` | Build a `.mcpb` bundle per target. |
| `icon` | none | Square PNG for the bundle, ideally 512×512. |
| `register` | `.optional` | `.never`, `.optional` (checkbox, `/NOMCP`, `REGISTERMCP=0`), `.always`. |
| `clients` | see below | Which AI tools to register with. |

### `.mcp.clients`

| Field | Default | File |
| --- | --- | --- |
| `claude_code` | `true` | `~/.claude.json` |
| `vscode` | `true` | `mcp.json` in VS Code's user settings folder |
| `vscode_insiders` | `false` | The same, for VS Code Insiders |
| `claude_desktop` | `false` | `claude_desktop_config.json` |
| `cursor` | `false` | `~/.cursor/mcp.json` |
| `windsurf` | `false` | `~/.codeium/windsurf/mcp_config.json` |

## From build.zig.zon

| Field | Used for |
| --- | --- |
| `name` | Package and file names; default display name, publisher and upgrade code. |
| `version` | Semantic version of every package. |
| `description` | MSI summary and `.deb` description. Required for both. |
| `license` | SPDX identifier for the `.deb` copyright file. |

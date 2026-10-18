# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `Options.mcp` packages the application, or one of its programs, as an
  MCP server. Every target gets a `.mcpb` bundle that Claude Desktop
  installs with a double-click (manifest 0.3, checked with the official
  `mcpb validate`). A new reproducible zip writer builds it. The sample's
  `sample-tool mcp` is a small MCP server, and the Linux end-to-end test
  talks to it from inside the bundle.

- The installers register the MCP server with the user's AI tools
  (`mcp.register`, `mcp.clients`): Claude Code and VS Code by default,
  VS Code Insiders, Claude Desktop, Cursor and Windsurf on request. A
  small `zstaller-mcp` program installed with the application edits the
  tools' files in place, keeping comments and formatting, and only ever
  touches entries that run this installation's program. Setup has an
  "Add to my AI tools" box and `/MCP` / `/NOMCP`, the MSI has
  `REGISTERMCP`, and on Ubuntu users run `zstaller-mcp register`.
  Uninstalling removes the entries from every user profile.

- `windows.scope = .user` builds EXE and MSI installers that install for
  the current user only, without administrator rights: into
  `%LOCALAPPDATA%\Programs`, with the user's Start Menu, desktop, PATH
  and `HKEY_CURRENT_USER`. The sample builds them with `-Dper-user`, and
  the Windows end-to-end test installs and removes both.

- The EXE and the MSI of a product refuse to install over each other,
  instead of sharing files under two Apps & Features entries: setup.exe
  checks for the MSI's upgrade code, and the MSI checks for the EXE's
  uninstall entry with `AppSearch` and a launch condition.

- Windows install and uninstall hooks: `windows.after_install` runs an
  installed program once the files are in place (a failure fails the EXE
  install and rolls the MSI back) and `windows.before_uninstall` runs one
  before they are removed. The MSI runs them as deferred custom actions
  as LocalSystem. The sample registers and unregisters `sample-tool`
  this way, and the Windows end-to-end test checks both.

- `.deb` packages pass lintian: they include `changelog.gz` and a
  lintian override for the static binaries, compress manual pages, and
  take a `deb.long_description` and a `deb.copyright` notice. The Linux
  end-to-end test runs lintian and fails on errors and warnings.

- `.deb` packages can install files anywhere (`deb.files`: man pages,
  completions, systemd units, configuration), with files in `/etc` listed
  as conffiles so dpkg keeps local changes on upgrade; a menu entry with
  an icon (`deb.desktop_entry`); and maintainer scripts (`deb.scripts`).
  The sample uses all of them, and the Linux end-to-end test upgrades it
  with a changed configuration file and purges it.

- `Options.programs` packages more programs next to the application, such
  as a command-line tool beside a GUI. Each is built per target like the
  application, normalized and signed the same way, installed in the
  install folder on Windows and in `/usr/bin` (mode 755) on Ubuntu, and
  may have a Start Menu shortcut in the EXE and MSI. The sample ships a
  `sample-tool` this way.

- `Options.sign` signs the Windows application before it is packed, then
  the finished setup program and MSI before their checksums are written.
  The sample builds signed with `-Dsign=<thumbprint>`, and Windows CI
  checks the signatures of the installers, the installed application and
  `uninstall.exe`.

- The EXE installer has a setup wizard: Welcome, License (optional),
  Install location with a folder picker and disk space, Additional tasks,
  a progress page and a Finished page that can launch the application.
  `uninstall.exe` uses the same window. It scales with each monitor's DPI
  and uses the application icon. Silent `/S` installs are unchanged.
- When programs have the installation's files in use, the EXE wizard
  shows a "Programs in Use" page listing each one's full path, process
  name, process ID and user or service account, with Retry and, with
  `close_running_apps`, Close programs. Besides programs running from the
  install directory, it now finds processes and services that have
  installed files open, through the Windows Restart Manager; services are
  stopped through the service manager rather than ended.
- `windows.wizard` customizes the wizard from `build.zig`: a
  `welcome_image` (493x312) and `banner_image` (493x58), at those sizes
  or double, as PNG or BMP; a `license_file`; `welcome_text` and
  `finish_text`; `launch_on_finish`; and the `accent_color` of the
  built-in artwork. Images are decoded and size-checked at build time.
- `windows.install_root` (`.program_files`, `.program_data` or
  `.system_drive`) and nested `install_dir_name` values such as
  `"Acme\\Widget"` set the default install folder of both the EXE and the
  MSI. `windows.allow_install_dir_change = false` locks the folder in the
  wizard.
- Desktop shortcuts: `windows.desktop_shortcut` (`.never`, `.optional`,
  `.always`). The EXE offers a checkbox and accepts `/DESKTOP` and
  `/NODESKTOP`; the MSI has a `DESKTOPSHORTCUT` property.
- The EXE installer defaults to the folder of the installed version when
  it upgrades.
- `.windows.close_running_apps` lets the EXE installer and uninstaller
  force-quit programs running from the install directory. They list each
  program and its process ID and ask first; silent runs do not ask. The
  sample enables it.
- `Options.source_date_epoch` sets the package timestamp from build.zig.
- MSI cabinet file dates follow `SOURCE_DATE_EPOCH` instead of always being
  1980-01-01.
- CI builds the sample twice at different paths with separate caches, on
  Linux and Windows, and requires identical installers across all builds.
- Release notes record the `SOURCE_DATE_EPOCH` and commit used, with the
  commands to rebuild the installers byte for byte.

- `zig build docs` builds an API reference of every build option.
- The README starts with a quick start that works on a fresh `zig init`
  project, documents every option, the EXE command line, MSI properties,
  logging and elevation, and adds a troubleshooting section.
  CONTRIBUTING describes every step of adding a platform.

### Changed

- MSI packages compress their cabinet on every CPU core: 64 MB of
  application files compress in 0.75 s instead of 1.9 s on four cores,
  with byte-identical output.

- Rebuilding installers after an application change is faster: the
  application's files are appended to the linked setup program instead of
  being compiled into it, so the setup program is no longer recompiled
  for every Windows target. The sample's edit-and-rebuild went from 35.9s
  to 22.2s. The ARM64 setup program is 76 KB smaller (simpler panic
  handler). Signing the setup program afterwards keeps working: the
  payload is found before the signature.
- A silent EXE install (`/S`) with `add_to_path = .optional` now adds the
  install folder to PATH, as the wizard's ticked checkbox and the MSI's
  `ADDTOPATH=1` already did. Pass `/NOPATH` to leave it out.
- Installing an older version over a newer one with the EXE is refused,
  as with the MSI.

- Release installers are built locally instead of by GitHub Actions. The
  new `scripts/release.ps1` builds every installer from scratch with
  `SOURCE_DATE_EPOCH` set to the commit time, checks the checksums, copies
  the files to a chosen folder and, with `-Tag`, uploads them to a draft
  release. The release workflow no longer builds anything: it installs,
  runs and uninstalls the uploaded files on every platform and then
  publishes the draft. It no longer runs when a `v*` tag is pushed.
- `zig build installer` is faster on a fresh checkout or CI runner: the
  `zstaller-pack` host tool compiles its standard library in ReleaseSmall
  (zstaller's own code stays ReleaseSafe). The sample went from 48.9s to
  28.7s with identical output.

### Fixed

- `zstaller-mcp` crashed on an AI tool file nested hundreds of thousands
  of levels deep instead of reporting it as invalid, and opening a pipe
  left at a tool's file path made it hang. During `unregister
  --all-users`, which runs as root on uninstall, one user's file could
  stop the entries of every later user from being removed. Such files
  are now skipped and left alone.

- An MSI upgrade that moved the application to another folder left the
  AI tool entries naming the old folder: the old package does not
  unregister during an upgrade, and the new one would not replace an
  entry that runs a different program. An entry under the server's name
  that runs a program of the same file name, at a path where nothing is
  any more, is now treated as left behind by an earlier installation:
  `register` replaces it, `unregister` removes it, and `status` says so.

- Security: install folders outside Program Files no longer inherit
  permissions that let every user replace the installed programs, which
  include the uninstaller that runs as administrator and, possibly, a
  folder on the system PATH. The EXE and MSI now give the install folder
  Program Files permissions (only SYSTEM and administrators can change
  it). The EXE also refuses junctions and symbolic links on the way to the
  install folder, existing folders above it that other users can rename,
  and existing install folders other users can change that hold other
  files. Uninstall skips files reached through a junction.

- Security: the elevated EXE installer no longer loads `RstrtMgr.dll`
  from its own folder, and only loads system DLLs from System32, so a DLL
  planted next to setup.exe cannot run as administrator. The uninstall
  helper now runs from a new folder only administrators and SYSTEM can
  write to, instead of a predictable file name in `%TEMP%`, which for
  SYSTEM uninstalls is writable by every user.
- Configuration mistakes are reported once, by the `installer` step, with
  the option and value at fault. Manifest problems no longer print on
  every `zig build`. Invalid `metadata.name` and `metadata.version`
  overrides are named (a name such as `../x` used to crash the build).
  `extra_files` destinations are checked up front, including ones that
  would overwrite the application or `uninstall.exe`. Text an MSI
  package cannot store is reported with the option and the character.
  An icon that is not a
  `.ico` file is reported as such instead of failing inside a generated
  resource file or going into the MSI.
- The EXE's Apps & Features entry shows the package name as Publisher
  when `windows.publisher` is not set, as documented and as the MSI does.

- MSI packages for pre-release versions no longer share a product code
  with the final release, which made installing `1.0.0` over
  `1.0.0-rc.1` fail with error 1638. Versions over MSI's limits
  (255.255.65535) fail the build instead of being clamped, and the new
  `windows.msi_version` option sets the MSI version for schemes such as
  calendar versions.
- MSI strings may use every Windows-1252 character, including curly
  quotes, en and em dashes and the euro and trademark signs.
- EXE upgrades write the new files before removing old ones, so a
  failure leaves the earlier version working, and a failed fresh install
  removes its folder. An upgrade to another folder cleans up the old one.
- The EXE no longer removes a PATH entry it did not add, no longer leaves
  its entry behind when PATH is unticked on upgrade, and keeps the rest of
  the system PATH exactly as it was.
- A damaged EXE installer reports that it is damaged instead of failing
  unpredictably: the payload carries a SHA-256 checked before unpacking.
- "Launch" on the Finish page starts the application as the signed-in
  user instead of as administrator.

- The EXE uninstaller no longer fails with a bare "AccessDenied" when the
  application is running. Before it changes anything, it checks for
  programs running from the install directory and names each one with its
  process ID. A file that another program has open is named in the error
  too. The installer does the same check before it updates an
  installation.
- The EXE uninstaller now removes the empty install directory when it is
  opened from Explorer. The helper that deletes the uninstaller inherited
  its working directory, which was the install directory, and Windows does
  not delete a directory that a process is using as its working directory.
  The helper now starts in `%TEMP%`.
- Running the EXE installer's `uninstall.exe` directly (for example by
  double-clicking it) now uninstalls the application. The installer and
  uninstaller are the same program and the action was chosen only from the
  `/uninstall` option, so without it the uninstaller installed the
  application again. Run as `uninstall.exe`, it now defaults to uninstall.
- Uninstalling the EXE install no longer leaves `uninstall.exe` and the
  install directory behind. The helper that deleted the running uninstaller
  waited a fixed two seconds, so it failed whenever the uninstaller stayed
  open longer, as it does while showing its final message. A temporary copy
  of the uninstaller now waits for it to exit before deleting it and the
  directory.
- `setup.exe /uninstall` now removes the installation recorded in the
  registry. It used to treat the setup program's own folder (such as
  Downloads) as the install directory.
- Installers are reproducible regardless of build directory, cache
  location or host. The linker derives Windows binaries' CodeView GUID and
  timestamps from their .pdb, which holds absolute paths, so aarch64
  Windows builds (which keep debug info) differed between checkouts. A new
  pure-Zig step, `zstaller-pack pe-normalize`, replaces those fields in the
  application and the EXE installer stub with a hash of the image.
- Changing `SOURCE_DATE_EPOCH` now rebuilds the installers. It was read by
  the packaging tool from the environment, which the Zig build cache does
  not track, so cached installers with the old timestamps were reused. The
  build API now resolves it and passes it as an argument.

## [0.1.0] - 2026-10-14

### Added

- Windows installers add a Start Menu shortcut for all users (MSI
  `Shortcut` table; IShellLink in the EXE stub) and remove it on
  uninstall. Turn it off with `.windows.start_menu_shortcut = false`.
- The EXE installer offers to launch the application when an interactive
  install finishes.
- The sample application shows its version and install location, carries
  the sample icon, and waits for Enter when Windows opened a console just
  for it, so it can be launched from the Start Menu.
- CI installs, runs and uninstalls the ARM64 packages natively on
  `ubuntu-24.04-arm` and `windows-11-arm` runners.
- aarch64 Windows binaries (the application and the EXE installer stub)
  are built with debug info: when it is stripped, Zig 0.16's LLVM encodes
  thread-local variable offsets wrongly (SECREL_HIGH12A immediates hold
  the full offset), so programs read and write outside their TLS block
  and crash at startup. With debug info the offsets are correct.
- Release workflow: builds the sample installers, verifies the exact files
  on x86_64 and ARM64 Windows and Ubuntu, then publishes a GitHub release.

- Build API: `addInstallers(b, options)` cross-compiles the consumer's
  executable for each target and builds its installers, with SHA-256
  checksum files, into `zig-out/installers/`. Options cover targets, icon,
  extra files, Windows and Debian settings and metadata overrides.
- Target matrix: Windows x86_64/aarch64 (GNU ABI) and Ubuntu x86_64/aarch64
  (static musl), behind a common platform interface.
- Ubuntu `.deb` writer in pure Zig (ar, tar and gzip), reproducible via
  `SOURCE_DATE_EPOCH`.
- Windows EXE installer: native Zig setup stub with an embedded compressed
  payload, Program Files install, Apps & Features entry, optional PATH,
  uninstaller, and silent `/S` mode.
- Windows MSI writer in pure Zig: OLE compound file, Windows Installer
  database and string pool, MSZIP cabinet, summary information, major
  upgrades and an optional `ADDTOPATH` property.
- `zstaller-pack` host tool that assembles packages during the build.
- `examples/sample`: a sample project using zstaller, with end-to-end
  install and uninstall tests for Linux and Windows.
- CI runs the sample's installer tests on Linux and Windows.
- `Metadata`: reads `name`, `version`, `description` and `license` from a
  `build.zig.zon` manifest, with field-level diagnostics for missing or
  malformed values.
- Project scaffold: `build.zig`, `build.zig.zon` and a library module that
  builds and tests with Zig 0.16.0.
- Apache License 2.0, NOTICE file and license headers on source files.
- Repository conventions: README, CHANGELOG, CONTRIBUTING, CONTRIBUTORS,
  CODE_OF_CONDUCT, SECURITY, CODEOWNERS, issue and pull request templates.
- CI workflow that checks formatting and runs tests on Linux and Windows.

[Unreleased]: https://github.com/ChristianPresley/zstaller/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ChristianPresley/zstaller/releases/tag/v0.1.0

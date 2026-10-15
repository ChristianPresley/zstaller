# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Release installers are built locally instead of by GitHub Actions. The
  new `scripts/release.ps1` builds every installer from scratch with
  `SOURCE_DATE_EPOCH` set to the commit time, checks the checksums, copies
  the files to a chosen folder and, with `-Tag`, uploads them to a draft
  release. The release workflow no longer builds anything: it installs,
  runs and uninstalls the uploaded files on every platform and then
  publishes the draft. It no longer runs when a `v*` tag is pushed.

### Fixed

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

### Added

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

[Unreleased]: https://github.com/ChristianPresley/zstaller/commits/main

# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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

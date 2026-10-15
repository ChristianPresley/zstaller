# zstaller

[![CI](https://github.com/ChristianPresley/zstaller/actions/workflows/ci.yml/badge.svg)](https://github.com/ChristianPresley/zstaller/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

A packaged installer generator for Zig projects, written entirely in Zig 0.16
with zero third-party dependencies.

The goal: add zstaller to your project's `build.zig.zon`, wire it into
`build.zig`, and run `zig build installer` to cross-compile your software and
produce ready-to-ship installers in `zig-out/installers/`.

## Status

> **Early development.** The repository currently contains the project
> scaffold only. None of the installer generators below are implemented yet.

| Milestone | Scope | Status |
| --- | --- | --- |
| a | Scaffold, license files, `build.zig.zon` metadata parsing | In progress |
| b | Cross-compile matrix | Planned |
| c | Ubuntu `.deb` output (x86_64, aarch64) | Planned |
| d | Windows EXE installer (x86_64, aarch64) | Planned |
| e | Windows MSI installer (x86_64, aarch64) | Planned |
| f | Example project, docs, CI end-to-end | Planned |

## Planned targets

| Platform | Architectures | Formats |
| --- | --- | --- |
| Windows | x86_64, aarch64 | MSI, EXE |
| Ubuntu Linux | x86_64, aarch64 | `.deb` |

Each platform sits behind a common interface so more Linux distributions and
macOS can be added later.

## Requirements

- [Zig 0.16.0](https://ziglang.org/download/). No other toolchain is needed.

## Building from source

```sh
zig build test
```

## Usage

The public build API is being designed and is not usable yet. This section will
document how to add zstaller to `build.zig.zon` and call it from `build.zig`
once it lands.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Please follow the
[Code of Conduct](CODE_OF_CONDUCT.md), and report security issues as described
in [SECURITY.md](SECURITY.md).

## License

Licensed under the [Apache License, Version 2.0](LICENSE). See [NOTICE](NOTICE).

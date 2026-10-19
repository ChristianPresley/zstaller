---
title: Adding a platform
lead: Each platform sits behind one small interface, so another Linux distribution or macOS can be added without touching the others.
---

## The interface

[`src/build/Platform.zig`]({{ site.blob_url }}/src/build/Platform.zig) lists the platforms. Each is a build-side module with one function:

```zig
/// Adds the steps that produce `format` for `ctx.target`, and returns the
/// package file. On a configuration error it calls `ctx.fail(...)` and
/// returns null.
pub fn addPackage(ctx: *const api.Context, format: Format) ?LazyPath
```

`Context` carries the build, the target, the resolved metadata and options, the compiled binary, and helpers to run the `zstaller-pack` tool. The build side only wires up steps; the packaging itself runs in `zstaller-pack`, a Zig program built for the host, so a configuration error fails only the `installer` step, once, with a clear message.

```
src/
├── build/            build-side: options, wiring, one file per OS
│   ├── api.zig       the public options and addInstallers
│   ├── Platform.zig  the platform interface
│   ├── windows.zig
│   └── ubuntu.zig
├── platforms/        the formats, in pure Zig
│   ├── windows/      exe/ (setup program), msi/ (CFB, database, cabinet), pe.zig
│   └── ubuntu/       deb.zig
├── archive/          ar, tar, deflate, zip
├── pack/main.zig     zstaller-pack, the packaging tool
└── mcp/              zstaller-mcp, the AI-tool registrar
```

## Steps

To add one, for example Fedora `.rpm` or macOS `.pkg`:

1. **Targets and formats** in `src/target.zig`: an `Os` variant, the new `Target` variants and any new `Format`. Then fill in every switch over them: `Os.displayName`, `Format.extension`, `Target.os`, `cpuArch`, `query` (the Zig target to cross-compile for), `formats`, `archName`, `slug` and `parse`.
2. **File names** in `naming.installerFileName` (`src/naming.zig`), with a test.
3. **The format** in pure Zig under `src/platforms/<os>/`, with unit tests, and a `zstaller-pack` command for it in `src/pack/main.zig`.
4. **The build side**: `src/build/<os>.zig` with `addPackage`, added to `platforms` in `Platform.zig`. A compile error names any `Os` without one.
5. **End-to-end tests**: a script under `examples/sample/scripts/` that installs, runs and removes the package, a CI job in `.github/workflows/ci.yml`, and the release checks in `.github/workflows/release.yml` and `scripts/release.ps1`.
6. **Docs**: the targets tables in `README.md` and this site, a guide page, and `CHANGELOG.md`.

zstaller has no third-party dependencies, and a new platform should keep it that way: write the format in Zig, and use the platform's own tools only to verify output in tests, as the `.deb` tests use `dpkg-deb` when it is there.

[CONTRIBUTING.md]({{ site.blob_url }}/CONTRIBUTING.md) has the rest: commit messages, license headers and the pull request checklist.

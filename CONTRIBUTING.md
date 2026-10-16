# Contributing to zstaller

Thanks for your interest in improving zstaller. This document explains how to
get set up and what a pull request needs before it can merge.

## Ground rules

- **Zig 0.16.0 only.** Code must build with the 0.16.0 release.
- **Zero third-party dependencies.** Use only the Zig standard library. Do not
  add entries to `.dependencies` in `build.zig.zon` and do not shell out to
  external tools for core functionality. Optional verification in tests (for
  example `dpkg-deb`) is fine when it is skipped if the tool is missing.
- **Every change goes through a pull request.** Never push directly to `main`.
  Create a branch, open a pull request, and wait for CI and review.

## Development setup

1. Install [Zig 0.16.0](https://ziglang.org/download/).
2. Clone the repository and run the tests:

   ```sh
   zig build test
   ```

3. Format your code before committing:

   ```sh
   zig fmt build.zig build.zig.zon src examples
   ```

4. Build the sample's installers, which runs every packaging path end to
   end, and the API reference:

   ```sh
   cd examples/sample && zig build installer
   zig build docs
   ```

## Layout

| Path | What it is |
| --- | --- |
| `build.zig`, `src/build/` | The build API consumers call: options, target loop, per-platform steps. |
| `src/pack/main.zig` | `zstaller-pack`, the host tool the build runs to write each package. |
| `src/platforms/` | The package formats in pure Zig: `.deb`, the MSI, the EXE payload and its installer stub. |
| `src/archive/` | ar, tar and DEFLATE. |
| `src/target.zig`, `src/naming.zig` | Targets, formats and output file names. |
| `examples/sample/` | The end-to-end sample and its CI scripts. |

## Adding a platform

Each platform sits behind one interface, `src/build/Platform.zig`: a
build-side module with

```zig
pub fn addPackage(ctx: *const api.Context, format: Format) ?LazyPath
```

that adds the steps producing `format` for `ctx.target` and returns the
package file, or calls `ctx.fail(...)` and returns null on a
configuration error. To add one, for example Fedora `.rpm` or macOS
`.pkg`:

1. **Targets and formats** in `src/target.zig`: an `Os` variant, the new
   `Target` variants and any new `Format`. Then fill in every switch over
   them: `Os.displayName`, `Format.extension`, `Target.os`, `cpuArch`,
   `query` (the Zig target to cross-compile for), `formats`, `archName`,
   `slug` and `parse`, plus any per-format helper such as `debArch`.
2. **File names** in `naming.installerFileName` (`src/naming.zig`), with a
   test.
3. **The format** in pure Zig under `src/platforms/<os>/`, with unit tests,
   and a `zstaller-pack` command for it in `src/pack/main.zig`.
4. **The build side**: `src/build/<os>.zig` with `addPackage`, added to
   `platforms` in `Platform.zig`. A compile error names any `Os` without
   one.
5. **Tests end to end**: a script under `examples/sample/scripts/` that
   installs, runs and removes the package, a CI job in
   `.github/workflows/ci.yml`, and the release checks in
   `.github/workflows/release.yml` and `scripts/release.ps1`.
6. **Docs**: the targets table and a "What the installers do" section in
   `README.md`, and `CHANGELOG.md`.

## Commit messages

Commits follow [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/)
and **every commit has a message body** explaining what changed and why.

```
<type>(<optional scope>): <short summary in the imperative>

<body: what changed and why, wrapped at 72 columns>

<optional footers, e.g. BREAKING CHANGE: ..., Refs: #123>
```

Common types: `feat`, `fix`, `docs`, `test`, `refactor`, `perf`, `build`, `ci`,
`chore`. Useful scopes: `metadata`, `deb`, `exe`, `msi`, `build`, `ci`.

Example:

```
feat(deb): write control.tar with md5sums

Debian tooling expects an md5sums file listing every file in data.tar.
Generate it while streaming the data archive so the payload is only
read once.
```

Pull request titles follow the same format, since they become the merge
commit summary.

## License headers

Every source file (`.zig`, `.zon`) starts with the Apache 2.0 header:

```zig
// Copyright 2026 The zstaller Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0
```

By contributing you agree that your contributions are licensed under the
Apache License 2.0, as described in section 5 of the license.

## Pull request checklist

- [ ] Conventional Commit title and commit bodies
- [ ] `zig fmt --check build.zig build.zig.zon src examples` passes
- [ ] `zig build test` passes
- [ ] Tests added or updated for behavior changes
- [ ] `CHANGELOG.md` updated under `Unreleased` for user-visible changes
- [ ] Added yourself to `CONTRIBUTORS.md` if this is your first contribution

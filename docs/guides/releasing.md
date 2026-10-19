---
title: Releasing
lead: A release is the files in zig-out/installers, uploaded somewhere people can download them. Here is a dependable way to build, check and publish them.
---

## Build the release

From a clean checkout of the commit you are releasing, with the commit time as the timestamp so the build is [reproducible]({{ '/guides/reproducible-builds/' | relative_url }}):

```sh
git status --short    # nothing uncommitted
SOURCE_DATE_EPOCH="$(git log -1 --format=%ct)" zig build installer
cd zig-out/installers
sha256sum -c *.sha256
```

The packaged binaries are built with `optimize` from `addInstallers` (default `.ReleaseSafe`), not with your normal build's `-Doptimize`.

## Test before you publish

Install, run and uninstall each package on the platform it is for. zstaller's sample does this in two scripts you can adapt: [`test-windows.ps1`]({{ site.blob_url }}/examples/sample/scripts/test-windows.ps1) (silent EXE and MSI installs, upgrades, hooks, per-user builds, the EXE/MSI exclusion) and [`test-linux.sh`]({{ site.blob_url }}/examples/sample/scripts/test-linux.sh) (dpkg-deb, lintian, install, upgrade with a changed configuration file, purge). GitHub Actions has x86_64 and ARM64 runners for both Windows and Ubuntu.

## Publish

Upload every installer with its `.sha256` file, for example to a GitHub release:

```sh
gh release create v1.2.0 --draft --title v1.2.0 zig-out/installers/*
```

Tell users which file is which. A short guide in the release notes helps: EXE for people, MSI for administrators, `x86_64` for most PCs and `aarch64` for ARM64 ones, and how to uninstall. zstaller's own [release notes template]({{ site.blob_url }}/.github/release-notes.md) is an example. If the installers are not [code-signed]({{ '/guides/code-signing/' | relative_url }}), say what SmartScreen will show and how to get past it (**More info**, then **Run anyway**).

## Building in CI instead

The packages do not depend on the machine, so CI can build them. A GitHub Actions job:

```yaml
jobs:
  installers:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: mlugg/setup-zig@v2
        with:
          version: 0.16.0
      - name: Build installers
        run: |
          export SOURCE_DATE_EPOCH="$(git log -1 --format=%ct)"
          zig build installer
      - uses: actions/upload-artifact@v4
        with:
          name: installers
          path: zig-out/installers/
```

To upload from a build step instead, use `outputs` from `addInstallers`; see [Build API]({{ '/reference/build-api/' | relative_url }}#outputs).

## How zstaller releases itself

zstaller's releases carry the sample's installers. They are built on a maintainer's machine by [`scripts/release.ps1`]({{ site.blob_url }}/scripts/release.ps1), never by GitHub:

```sh
pwsh scripts/release.ps1 -OutputDir ~/Desktop/zstaller-installers   # build and check
pwsh scripts/release.ps1 -Tag v{{ site.version }}                         # also upload a draft release
```

The script builds every target into a fresh folder with `SOURCE_DATE_EPOCH` set to the commit time and checks every `.sha256`. With `-Tag` it uploads the files to a draft release and starts the [release workflow]({{ site.blob_url }}/.github/workflows/release.yml), which downloads them, checks their checksums, installs, runs and uninstalls them on x86_64 and ARM64 Windows and Ubuntu, and publishes the draft only if all of that passes.

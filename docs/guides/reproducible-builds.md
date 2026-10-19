---
title: Reproducible builds
lead: The same source, Zig version and timestamp give byte-identical installers, whatever directory, cache or host builds them. Anyone can rebuild a release and check that it matches.
---

## Why it matters

A reproducible installer can be verified: a user, a packager or your own CI can build the same commit and compare checksums with the release, which shows the installer was built from that source and nothing else. zstaller's CI builds the sample twice per host, at different paths with separate caches, on Linux and on Windows, and requires all four builds to match.

## What zstaller does

- **Timestamps.** Every timestamp written into a package (`.deb` archive entries, MSI summary information, cabinet file dates, `.mcpb` zip entries) is `source_date_epoch` if set, else the `SOURCE_DATE_EPOCH` environment variable, else 1980-01-01. The value is passed to each packaging step as an argument, so changing it rebuilds the installers instead of reusing cached ones. The EXE installer's payload stores no timestamps.
- **Windows binaries.** The linker derives a PE image's CodeView GUID and timestamps from its `.pdb`, which records absolute build and cache paths. zstaller replaces those fields in your program and in the setup program with a SHA-256 of the rest of the image, so the binaries depend only on their code.
- **GUIDs.** MSI product, package and component GUIDs are derived from the upgrade code, version and file paths, not generated at random.
- **Order.** Files are written in a fixed order, and the MSI's cabinet compresses on every CPU core with byte-identical output.

## Set the timestamp

Use the commit time, so every build of a commit agrees:

```sh
SOURCE_DATE_EPOCH="$(git log -1 --format=%ct)" zig build installer
```

or in `build.zig`:

```zig
.source_date_epoch = 1760000000,
```

## Check a release

Check out the commit, build with the `SOURCE_DATE_EPOCH` the release used, and compare:

```sh
git checkout <commit>
cd examples/sample
SOURCE_DATE_EPOCH="$(git log -1 --format=%ct)" zig build installer
sha256sum zig-out/installers/*.msi zig-out/installers/*.exe zig-out/installers/*.deb
```

The sums should equal those in the release's `.sha256` files.

## What breaks it

- **Code signing.** Signatures carry their own timestamp. Compare unsigned builds.
- **A different Zig version.** The compiler is part of the input; pin it (`minimum_zig_version`, and your CI's Zig version).
- **Your own build steps** that embed the time, a random value or an absolute path.
- **ARM64 Windows debug info.** Windows ARM64 binaries keep debug info, in a separate `.pdb` that is not packaged, because Zig 0.16 miscompiles thread-local storage when it is stripped. zstaller normalizes the binary, so this does not affect reproducibility, but the `.pdb` in your cache no longer matches the packaged binary.

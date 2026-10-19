---
title: Code signing
lead: Unsigned installers make SmartScreen say "Windows protected your PC" and UAC show "Unknown publisher". Give zstaller a signing function and it signs every Windows file it ships.
---

## What gets signed

Set `sign` to a function that returns a signed copy of a file. zstaller calls it:

1. for each Windows target's application `.exe` (and each of `programs`), before it is packed, so the installed program is signed;
2. for the finished setup program, before its `.sha256` is written. `uninstall.exe` is a copy of the setup program, so it is signed too;
3. for the finished MSI, before its `.sha256` is written.

`.deb` packages are not passed to it: apt checks the signature of the repository, not of the package.

## With osslsigncode (any OS)

[osslsigncode](https://github.com/mtrojnar/osslsigncode) signs Windows files on Linux, macOS and Windows:

```zig
const installers = zstaller.addInstallers(b, .{
    .executable = createExe,
    .sign = sign,
    // ...
});

fn sign(b: *std.Build, request: zstaller.SignRequest) std.Build.LazyPath {
    const run = b.addSystemCommand(&.{ "osslsigncode", "sign", "-h", "sha256" });
    run.addArg("-pkcs12");
    run.addFileArg(b.path("codesign.pfx"));
    run.addArg("-readpass");
    run.addFileArg(b.path("codesign.pass"));
    run.addArgs(&.{ "-t", "http://timestamp.digicert.com", "-in" });
    run.addFileArg(request.file);
    run.addArg("-out");
    return run.addOutputFileArg(request.basename);
}
```

## With signtool (Windows)

`signtool` signs in place, so copy the file first. The sample does this in [`scripts/sign.ps1`]({{ site.blob_url }}/examples/sample/scripts/sign.ps1), using a certificate from the Windows certificate store by thumbprint, and builds signed installers with:

```sh
zig build installer -Dsign=<certificate thumbprint>
```

CI runs exactly that with a throwaway certificate and checks every signature.

## The request

| Field | Meaning |
| --- | --- |
| `file` | The unsigned file (a `LazyPath`). |
| `basename` | Its file name, such as `myapp.exe` or `myapp-1.2.0-windows-x86_64.msi`: the name to give the signed copy. |
| `kind` | `.windows_binary` (your program), `.windows_setup` (the EXE installer) or `.windows_msi`. |
| `target` | Which target it belongs to. |

Like `executable`, `sign` is a plain function: it gets anything else it needs (a certificate path, a thumbprint) from `b`, a build option or the environment.

## Good practice

- Keep certificates and passwords out of the repository: environment variables or files the release machine provides.
- Always timestamp (`-t`), so signatures stay valid after the certificate expires.
- Signatures carry their own timestamp, so signed installers are not [byte-for-byte reproducible]({{ '/guides/reproducible-builds/' | relative_url }}). Compare unsigned builds.

# zstaller sample

A small Zig program that shows how to add zstaller to a project. When run
it prints its version, the platform it was built for and where it is
installed.

```sh
zig build run        # build and run natively
zig build installer  # build every installer into zig-out/installers/
zig build installer -Dversion=1.0.1   # the same, as another version
zig build installer -Dsign=<thumbprint>  # Windows: signed with a certificate from your store (scripts/sign.ps1)
```

The EXE installer shows a setup wizard with the sample's own artwork
([`assets/wizard-welcome.png`](assets/wizard-welcome.png) and
[`assets/wizard-banner.png`](assets/wizard-banner.png), double size) and
its [`LICENSE`](LICENSE) on a License page. Replace them, or remove the
`.wizard` options to see zstaller's built-in artwork.

On Windows the installers add a **Zstaller Sample** Start Menu shortcut;
uninstall from Settings > Apps > Installed apps, or from the command line
as the main README's [Windows EXE](../../README.md#windows-exe) and
[Windows MSI](../../README.md#windows-msi) sections show. On Ubuntu run `sample`
after installing the `.deb`, and `sudo apt remove sample` to remove it.

`scripts/test-windows.ps1` and `scripts/test-linux.sh` install, run and
uninstall the packages end to end; CI and the release workflow run them.

To start your own project from this one, copy the folder and replace
`.path = "../.."` in `build.zig.zon` with a `zig fetch --save` of
zstaller (see the main README's Quick start), then change the name,
version, upgrade code and artwork.

See [`build.zig`](build.zig) for the integration and the main
[zstaller README](../../README.md) for all options.

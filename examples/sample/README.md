# zstaller sample

A small Zig program that shows how to add zstaller to a project. When run
it prints its version, the platform it was built for and where it is
installed.

```sh
zig build run        # build and run natively
zig build installer  # build every installer into zig-out/installers/
```

On Windows the installers add a **Zstaller Sample** Start Menu shortcut;
uninstall from Settings > Apps > Installed apps. On Ubuntu run `sample`
after installing the `.deb`, and `sudo apt remove sample` to remove it.

`scripts/test-windows.ps1` and `scripts/test-linux.sh` install, run and
uninstall the packages end to end; CI and the release workflow run them.

See [`build.zig`](build.zig) for the integration and the main
[zstaller README](../../README.md) for all options.

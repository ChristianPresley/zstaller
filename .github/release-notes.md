These installers package the zstaller sample application
([examples/sample](https://github.com/ChristianPresley/zstaller/tree/main/examples/sample)).
Every file was built by zstaller from Zig sources alone, then installed,
run and uninstalled on x86_64 and ARM64 Windows and Ubuntu runners before
this release was published. Each file has a matching `.sha256` checksum.

The installers are not code-signed, so Windows SmartScreen may say
"Windows protected your PC". Choose **More info**, then **Run anyway**.

## Windows

Pick `x86_64` for most PCs, or `aarch64` for ARM64 devices such as Snapdragon laptops.

**EXE installer** (`sample-<version>-windows-<arch>-setup.exe`): double-click
it, approve the administrator prompt, and answer the questions. It installs
to `C:\Program Files\Zstaller Sample`, adds a **Zstaller Sample** Start Menu
shortcut, optionally adds itself to PATH, and offers to launch the app.

**MSI installer** (`sample-<version>-windows-<arch>.msi`): double-click it for
a progress bar install, or install silently from an administrator terminal:

```
msiexec /i sample-<version>-windows-x86_64.msi /qn
msiexec /i sample-<version>-windows-x86_64.msi /qn ADDTOPATH=0
```

**Run it** from the Start Menu (**Zstaller Sample**), or type `sample` in a
new terminal if you added it to PATH.

**Uninstall** from Settings > Apps > Installed apps > **Zstaller Sample** >
Uninstall, or silently:

```
msiexec /x sample-<version>-windows-x86_64.msi /qn
"C:\Program Files\Zstaller Sample\uninstall.exe" /uninstall /S
```

## AI tools (MCP)

The sample includes a small MCP server with one tool (`sha256`). The EXE
installer's **Add to my AI tools** box, the MSI (unless `REGISTERMCP=0`)
and, on Ubuntu, `/usr/lib/sample/zstaller-mcp register` add it to Claude
Code, VS Code and the other AI tools you have; uninstalling removes it.
For Claude Desktop, open `sample-<version>-<os>-<arch>.mcpb`.

## Ubuntu

```
sudo apt install ./sample_<version>_amd64.deb   # or _arm64.deb
sample
sudo apt remove sample
```

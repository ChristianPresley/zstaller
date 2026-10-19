---
title: Try the installers
lead: Check your installers on the machines they are for, or try the sample's from a release first to see what zstaller makes.
---

## The sample's installers

Every [GitHub release]({{ site.repo_url }}/releases) carries the sample application's EXE, MSI and `.deb` installers for every target, plus its MCP bundles. They were installed, run and uninstalled on x86_64 and ARM64 Windows and Ubuntu before the release was published. The installers are not code-signed, so Windows SmartScreen may say "Windows protected your PC": choose **More info**, then **Run anyway**.

| You have | Download |
| --- | --- |
| A Windows PC with an Intel or AMD processor | `sample-<version>-windows-x86_64-setup.exe` or `.msi` |
| A Windows PC with an ARM64 processor (Snapdragon, for example) | `sample-<version>-windows-aarch64-setup.exe` or `.msi` |
| Ubuntu on x86_64 | `sample_<version>_amd64.deb` |
| Ubuntu on ARM64 (a Raspberry Pi 4 or 5, for example) | `sample_<version>_arm64.deb` |

The wrong Windows architecture shows "This app can't run on your PC".

## On Windows

Double-click the EXE and follow the [wizard]({{ '/guides/setup-wizard/' | relative_url }}). Then:

1. Open **Zstaller Sample** from the Start Menu, or type `sample` in a new terminal.
2. Look for it in Settings > Apps > Installed apps.
3. Uninstall it from there.

{% include shot.html name="wizard-launched" caption="The sample application." %}

To try the MSI instead, uninstall the EXE first (the two [refuse to install over each other]({{ '/guides/msi/' | relative_url }}#exe-or-msi-not-both)), then double-click the MSI or run it [silently]({{ '/guides/msi/' | relative_url }}#install-silently).

A Windows virtual machine is the safest place to test your own installers: Microsoft offers free evaluation images, and Hyper-V, VirtualBox, VMware and UTM all run them. Windows Sandbox, built into Windows Pro, starts a clean Windows in seconds and throws it away when closed.

## On Ubuntu

```sh
sudo apt install ./sample_<version>_amd64.deb
sample
sudo apt remove sample
```

{% include term.html name="deb-run" %}

A container is a quick place to try a `.deb`: `docker run --rm -it -v "$PWD:/pkg" ubuntu:24.04`, then `apt install /pkg/myapp_1.2.0_amd64.deb`.

## Your own

The sample's test scripts install, run, upgrade and uninstall every package without a person clicking: [`test-windows.ps1`]({{ site.blob_url }}/examples/sample/scripts/test-windows.ps1) and [`test-linux.sh`]({{ site.blob_url }}/examples/sample/scripts/test-linux.sh). CI runs them on x86_64 and ARM64 runners; copy and adapt them for your project. [Releasing]({{ '/guides/releasing/' | relative_url }}) has more.

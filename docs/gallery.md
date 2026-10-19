---
title: Screenshot gallery
lead: Every screen the installers show, captured from real builds of the sample with the options each one needs. Click a screenshot to enlarge it; the link under it goes to the option or guide behind it.
wide: true
---

The Windows screenshots were taken under Wine, so window frames and system dialogs (message boxes, Windows Installer's own window, the Start menu) have Wine's classic look. Everything inside the setup window is drawn by zstaller and looks the same on Windows. Terminal output for every scenario is in the guides.

{% for group in site.data.gallery %}
<h2 id="{{ group.title | slugify }}">{{ group.title }}</h2>
<div class="gallery">
{%- for s in group.shots %}
{% include gallery-item.html name=s.name caption=s.caption option=s.option link=s.link %}
{%- endfor %}
</div>
{% endfor %}

## Terminal transcripts

| Scenario | Where |
| --- | --- |
| Building, and what comes out | [Your first installers]({{ '/getting-started/first-installers/' | relative_url }}#build), [Output files]({{ '/reference/output-files/' | relative_url }}) |
| Silent EXE install, switches, uninstall, exit codes | [Silent installs and switches]({{ '/guides/silent-installs/' | relative_url }}) |
| MSI install, log, registry, PATH, properties, upgrade, downgrade, uninstall | [MSI for enterprise]({{ '/guides/msi/' | relative_url }}) |
| Per-user registry and PATH | [Per-user installs]({{ '/guides/per-user/' | relative_url }}) |
| Hooks that succeed and fail, EXE and MSI | [Install hooks]({{ '/guides/hooks/' | relative_url }}) |
| Programs in use, silently | [Programs in use]({{ '/guides/programs-in-use/' | relative_url }}#silent-runs) |
| `.deb` contents, control fields, lintian, apt install/show/remove/purge | [The .deb package]({{ '/guides/deb/' | relative_url }}) |
| MCP bundle, registration on Windows and Ubuntu, `zstaller-mcp` | [MCP servers and AI tools]({{ '/guides/mcp/' | relative_url }}) |
| Every configuration error | [Build errors]({{ '/reference/build-errors/' | relative_url }}) |

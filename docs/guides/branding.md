---
title: Branding the wizard
lead: Give the setup wizard your own artwork, colors, icon and text, or let zstaller draw artwork for you from one color.
---

## Built-in artwork

Without images, the wizard draws its own: a gradient side panel on the Welcome and Finished pages and a tinted header on the others, both in `windows.wizard.accent_color`, with your application's icon. The default color is Windows blue, `0x0067C0`:

<div class="shots">
{% include shot.html name="builtin-welcome" caption="Built-in artwork, default accent color." %}
{% include shot.html name="builtin-license" caption="The header on inner pages." %}
</div>

One line changes the color:

```zig
.windows = .{
    .wizard = .{ .accent_color = 0x2E7D32 },
},
```

<div class="shots">
{% include shot.html name="accent-welcome" caption="`accent_color = 0x2E7D32`." %}
{% include shot.html name="accent-license" caption="The header follows the color." %}
{% include shot.html name="accent-finished" caption="So does the Finished page." %}
</div>

## The icon

`icon` is a Windows `.ico` file. It is used in the wizard's title bar, taskbar button and built-in artwork, for the Apps & Features entry, and as the MSI's product icon:

```zig
.icon = b.path("assets/myapp.ico"),
```

Include 16, 32, 48 and 256 pixel images. ImageMagick makes one from a PNG:

```sh
magick app.png -define icon:auto-resize=256,48,32,16 app.ico
```

A PNG renamed to `.ico` fails the build with a message saying so. The icon of the installed program itself (in the Start Menu and Explorer) is a resource in your executable; the sample adds it with `addWin32ResourceFile` and a one-line [`sample.rc`]({{ site.blob_url }}/examples/sample/assets/sample.rc), as its [`build.zig`]({{ site.blob_url }}/examples/sample/build.zig) shows.

## Your own images

```zig
.windows = .{
    .display_name = "My App",
    .wizard = .{
        .welcome_image = b.path("assets/wizard-welcome.png"),
        .banner_image = b.path("assets/wizard-banner.png"),
    },
},
```

The sample's images, at double size:

<div class="shots">
<figure class="shot"><a class="zoom" href="{{ '/assets/img/wizard-welcome.png' | relative_url }}"><img src="{{ '/assets/img/wizard-welcome.png' | relative_url }}" alt="The sample's welcome image: dark artwork on the left, white on the right"></a><figcaption><code>welcome_image</code>, 986×624. Artwork in the left 328 pixels, the rest white.</figcaption></figure>
<figure class="shot"><a class="zoom" href="{{ '/assets/img/wizard-banner.png' | relative_url }}"><img src="{{ '/assets/img/wizard-banner.png' | relative_url }}" alt="The sample's banner image: white on the left, stripes on the right"></a><figcaption><code>banner_image</code>, 986×116. Light on the left, artwork on the right.</figcaption></figure>
</div>

And how the wizard uses them:

<div class="shots">
{% include shot.html name="wizard-welcome" caption="`welcome_image` fills the Welcome and Finished pages." %}
{% include shot.html name="wizard-license" caption="`banner_image` heads every other page." %}
</div>

The sizes are the Windows Installer (WiX) banner and dialog bitmap sizes, so artwork made for a WiX installer fits:

| Option | Size | Where | Keep in mind |
| --- | --- | --- | --- |
| `welcome_image` | 493×312, or 986×624 | Welcome and Finished pages, behind everything above the buttons | Put the artwork in the left 164 pixels (328 at double size). The heading and text are drawn in dark type over the rest, so keep it white or very light. |
| `banner_image` | 493×58, or 986×116 | Top of every other page | The title and subtitle are drawn in dark type over the left part, so keep about the left two-thirds light and put artwork on the right. |

- PNG (any color type, not interlaced) or BMP (8-, 24- or 32-bit, uncompressed). Transparent areas show white.
- Supply double size for sharp output on high-DPI displays. The wizard scales smoothly to the display's scaling either way.
- Images are decoded and checked when you build. A wrong size or format fails the `installer` step, naming the option and the file:

{% include term.html name="error-banner" %}

## High-DPI displays

The wizard follows each monitor's scaling. At 150%, the window, fonts and built-in artwork scale up, and double-size images are drawn from their full resolution:

<div class="shots">
{% include shot.html name="dpi150-builtin" caption="Built-in artwork at 150%." %}
{% include shot.html name="dpi150-custom-license" caption="Double-size images at 150%." %}
</div>

## Names and text

| Option | Where it shows | Default |
| --- | --- | --- |
| `windows.display_name` | Window title, headings, shortcuts, Apps & Features | Package name |
| `windows.publisher` | Apps & Features, MSI Manufacturer | Package name |
| `windows.wizard.welcome_text` | Body of the Welcome page | "Setup will install *name version* on your computer." and a few lines of guidance |
| `windows.wizard.finish_text` | Body of the Finished page after a successful install | "Setup has installed *name version* on your computer." |
| `windows.wizard.license_file` | License page | No License page |

[The setup wizard]({{ '/guides/setup-wizard/' | relative_url }}#pages-that-come-and-go) shows custom welcome and finish text.

> MSI packages store text in the Windows-1252 character set (Western European letters, curly quotes, dashes, € and ™). A display name or publisher with other characters fails the build; give Windows its own `display_name` or `publisher` if your product name needs them elsewhere. See [Build errors]({{ '/reference/build-errors/' | relative_url }}).

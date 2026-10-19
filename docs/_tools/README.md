# Documentation tools

The documentation site in `docs/` is built by GitHub Pages' own Jekyll
(`.github/workflows/pages.yml`) and published to
<https://christianpresley.github.io/zstaller/>. It has no theme or plugins:
the layout, styles and script are in `docs/_layouts`, `docs/assets/css` and
`docs/assets/js`, and the sidebar comes from `docs/_data/nav.yml`.

## Preview the site

With Ruby and Bundler installed, from the repository root:

```sh
BUNDLE_GEMFILE=docs/_tools/Gemfile bundle install
BUNDLE_GEMFILE=docs/_tools/Gemfile bundle exec jekyll serve --source docs
```

Then open <http://localhost:4000/zstaller/>.

## Screenshots and terminal output

Every screenshot in `docs/assets/shots/` and every transcript in
`docs/_includes/term/` comes from a real installer. `capture.sh` rebuilds
them: it builds `gallery/` (the sample application with every documented
option exposed as a `-D` flag) once per scenario, clicks through the Windows
installers under Wine on a virtual display, and installs the `.deb` on the
machine it runs on. Run it on a disposable Linux machine or container, as
root, with zig 0.16.0, wine, Xvfb, xdotool, ImageMagick, msitools, dpkg and
lintian installed:

```sh
docs/_tools/capture.sh                 # every scenario
docs/_tools/capture.sh wizard msi      # only those
```

The scenarios are the `scenario_*` functions in `capture.sh`. A page shows a
screenshot with `{% include shot.html name="..." caption="..." %}` and a
transcript with `{% include term.html name="..." title="Command Prompt" %}`.

# Whistle mkdocs site

Drop-in mkdocs-material setup for the Whistle docs, with two interchangeable UI
modes (Safe / Playful) toggled from the header.

## Layout

```
mkdocs-site/
├── mkdocs.yml                # Material config
├── requirements.txt
├── overrides/
│   ├── main.html             # extends base.html — preconnects, no-flash init
│   └── home.html             # extends main.html — adds the hero block
└── docs/
    ├── index.md              # uses template: home.html
    ├── how-it-works.md
    ├── trust.md
    ├── assets/
    │   ├── whistle-bolt.svg  # header logo (mask-tinted)
    │   ├── whistle-icon.png  # favicon (app icon)
    │   ├── whistle-logo.png  # full wordmark (unused right now; available)
    │   ├── nostr.svg         # CC0, mbarulli/nostr-logo
    │   ├── mls.png           # cropped from cityroler/mls-logo
    │   └── marmot.png        # cropped from marmot-protocol's README art
    ├── stylesheets/
    │   └── extra.css         # both themes — tokens, components, switcher styles
    └── javascripts/
        └── theme-switcher.js # injects the header toggle + persists choice
```

## Install & serve

From this directory:

```bash
pip install -r requirements.txt
mkdocs serve -a 127.0.0.1:8765
```

## How the Safe / Playful switch works

- **CSS variables in `extra.css`** define a `--w-*` token set under `:root`
  (Safe defaults) and `[data-theme="playful"]` (Playful overrides).
- Material's `--md-*` vars are bound to `--w-*`, so swapping the theme updates
  everything — fonts, colors, button shapes, card chrome — in one DOM swap.
- `theme-switcher.js` sets `data-theme="safe|playful"` on `<html>`, persists
  to `localStorage` under `whistle-ui`, and re-runs after every `navigation.instant`
  page swap. The toggle UI is injected into Material's header.
- `overrides/main.html` runs a tiny inline script in `<head>` that reads
  localStorage *before* paint so the page never flashes the wrong theme.

## Copying into your repo

The intent is that you `cp -r mkdocs-site/* path/to/whistle-repo/` (or merge the
folder structure into your existing branch). Adjust `mkdocs.yml`'s
`site_url`/`repo_url` if needed.

## Things you may want to tweak

- **Colors** — Safe accent is electric blue `#0066E6`; Playful accent is
  brand yellow `#F5C400`. Both pull from your iOS `AccentColor.colorset`.
- **Fonts** — Safe: IBM Plex Sans/Mono. Playful: Unbounded display + DM Sans
  body + JetBrains Mono. All loaded from Google Fonts.
- **Hero copy** — lives in `overrides/home.html`.
- **Sections on home** — `docs/index.md` (uses `template: home.html` frontmatter
  so the hero renders above the article).
- **Dark mode** — not wired yet; add a `slate` scheme palette entry in
  `mkdocs.yml` plus matching `--w-*` overrides in a `[data-md-color-scheme="slate"]`
  block when you want it.

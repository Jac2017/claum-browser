# Claum Chromium patches

These patches are applied on top of the ungoogled-chromium source tree (which
itself sits on top of upstream Chromium). They're applied in the order below
by `claum/scripts/apply-patches.sh`.

| # | Patch                                          | What it does                                                          |
|---|------------------------------------------------|-----------------------------------------------------------------------|
| 01| `01-claum-branding.patch`                      | Rename "Chromium" → "Claum", update About page, menu items, keychain  |
| 02| `02-claum-glass-ui.patch`                      | Frosted-glass toolbar / tab strip / omnibox (CSS + Views patches)     |
| 03| `03-claum-vertical-tabs.patch`                 | Vertical tab sidebar (carried forward from Glass Browser)             |
| 04| `04-claum-component-extensions.patch`          | Register `claum-newtab` + `claude-for-chrome` as component extensions |
| 05| `05-claum-first-run-import.patch`              | Auto-show the import dialog on first run; default to Chrome           |
| 06| `06-claum-extension-import.patch`              | Custom importer that copies installed extensions from Chrome          |
| 07| `07-claum-default-search.patch`                | Set default search (Bing — override with `--claum-default-search=X`)  |

## Rebuilding patches after editing Chromium source

If you locally hack on the Chromium tree inside `~/claum-build/build/src` and
want to roll those changes into a patch:

```bash
cd ~/claum-build/build/src
git diff > ~/claum-browser/claum/patches/99-local-hacks.patch
```

Then rename it with the right ordering prefix and add a header comment.

## Patch format

Every patch must apply from **inside the Chromium source tree**
(`build/src/`), not from the repo root. Paths in the patch headers are relative
to `build/src/`. The apply script cd's there before applying.

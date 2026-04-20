# Claum — architecture tour

This is the 30,000-foot view of how the pieces fit together. If you only have
five minutes, read just this file.

## The stack, top to bottom

```
┌─────────────────────────────────────────────────────────────┐
│  Claum branding  (name, icons, About page, copyright)       │  ← claum/branding
├─────────────────────────────────────────────────────────────┤
│  Claum patches    Glass UI · vertical tabs · component-ext  │  ← claum/patches
│                   loader · first-run import · ext import    │
├─────────────────────────────────────────────────────────────┤
│  Bundled extensions     claum-newtab + claude-for-chrome    │  ← claum/extensions
│                         (loaded as component extensions)    │
├─────────────────────────────────────────────────────────────┤
│  ungoogled-chromium     privacy patches, no Google calls    │  ← upstream
├─────────────────────────────────────────────────────────────┤
│  Chromium               the browser engine itself           │  ← upstream
└─────────────────────────────────────────────────────────────┘
```

Claum doesn't fork Chromium. It's a **patch overlay**: the build script clones
ungoogled-chromium (which itself clones Chromium), then layers Claum's patches
and resources on top right before `gn gen`.

## Flow of a build

1. `claum/scripts/build-mac.sh` (or `build-windows.ps1`) is invoked.
2. It calls `clone_or_update_ungoogled` from `common.sh` to get the upstream
   ungoogled-chromium repo into `~/claum-build`.
3. ungoogled's own pipeline runs:
   - download Chromium tarball,
   - prune Google binaries,
   - apply ungoogled privacy patches,
   - run domain substitution.
4. `install_claum_resources` copies our two extensions into
   `chrome/browser/resources/claum_extensions/`.
5. `apply_claum_patches` walks `claum/patches/*.patch` in lexical order and
   `git apply`s each one onto the Chromium tree.
6. Branding files are dropped into `chrome/app/theme/chromium/`.
7. `gn gen out/Claum --args=...` produces ninja build files.
8. `ninja -C out/Claum chrome` compiles for ~3 hours.
9. The output is `out/Claum/Claum.app` (mac) or `out/Claum/chrome.exe` (win).

## Why component extensions

Our two extensions ship inside the browser binary because:

- **They're part of the product** — the new tab page and Claude side panel
  are core features, not opt-in add-ons.
- **They can't be uninstalled** — users won't accidentally break the new-tab
  override or remove Claude.
- **They auto-update with the browser** — no separate web-store dependency.
- **They get higher API privileges** — component extensions can use APIs
  that regular extensions can't (e.g. private `chrome.system.*`).

The trade-off is that you have to rebuild the browser to update them. For
local development, side-load them as regular extensions instead (see
`claum/extensions/claum-newtab/README.md`).

## Why two extensions, not one

`claum-newtab` and `claude-for-chrome` could in theory be one extension, but:

- They have very different permission profiles. The new-tab extension needs
  `bookmarks` and `topSites`; the Claude extension needs `scripting` and
  `clipboardWrite`. Splitting them keeps the scope minimal.
- They have different release cadences in spirit. The new-tab visuals are
  stable; the Claude integration will iterate fast as the API evolves.
- Side-by-side they make the architecture obvious to contributors.

## The first-run flow

1. User launches Claum for the first time.
2. `chrome/browser/first_run/first_run.cc` runs `DoPostImportTasks`.
3. Our patch (`05-claum-first-run-import.patch`) opens
   `chrome://settings/importData?source=chrome` in a new foreground tab.
4. The user sees the import dialog with Chrome pre-selected and these
   checkboxes (all checked by default):
   - Bookmarks and folders
   - Browsing history
   - Saved passwords
   - Cookies (Claum-specific addition)
   - Search engines
   - Autofill form data
   - Home page
   - **Installed extensions** ← Claum-specific addition
5. On click, `ImporterHost` spawns the standard utility-process importer for
   the regular fields, plus our custom `ChromeExtensionsImporter` for the
   extension list (see `06-claum-extension-import.patch`).
6. The extension importer queues each detected web-store extension for
   re-installation; user sees one bulk-confirmation dialog.

## What I would change next

- Wire the `claum_default_search` GN arg to actually rewrite the default
  prepopulated engine (today the patch is sketched; needs real prepopulated
  ID assignment).
- Replace the placeholder `app.icns` / `app.ico` with real branded art.
- Code-sign + notarize the macOS build (Apple Developer ID required).
- Set up auto-update via Sparkle (mac) and Omaha (win).

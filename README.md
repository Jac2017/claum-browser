# Claum Browser

**Claum** = **Cl**aude + Chrom**ium** — a privacy-focused Chromium fork with a
glass-morphism UI, vertical tabs, Claude AI built in, and first-run data
import from your existing Chrome (or Firefox / Safari / Edge) install.

This repo is a **drop-in overlay** for [`ungoogled-chromium`](https://github.com/ungoogled-software/ungoogled-chromium).
It does NOT vendor Chromium source — you clone that separately and then point
the build scripts here to apply the Claum patches, resources, and pre-installed
extensions on top.

---

## What's in the box

- **Glass UI** — frosted-glass toolbar, tab strip, and omnibox (Apple-style
  translucency). Previously prototyped in `glass-browser-preview.html`.
- **Vertical tabs** — sidebar with tab groups, search, pin, drag-reorder.
- **Pre-installed Claude extensions** — two MV3 extensions bundled as
  *component extensions* (can't be uninstalled, auto-update with the browser):
  1. `claum-newtab` — custom new-tab page, glass sidebar, settings.
  2. `claude-for-chrome` — Claude side panel with per-tab agent context.
- **First-run import wizard** — on first launch, prompts the user to import
  **bookmarks, history, cookies, saved passwords, autofill data, search engines,
  and installed extensions** from Chrome (and Firefox / Safari / Edge if
  present on the device).
- **Builds for** macOS (Apple Silicon, arm64) and Windows (x64).

---

## Quick start

### macOS (Apple Silicon)

```bash
# 1. Clone this repo next to where you want to build
git clone https://github.com/Jac2017/claum-browser.git
cd claum-browser

# 2. Run the one-shot bootstrap (installs deps, clones ungoogled-chromium,
#    fetches Chromium source, applies patches, starts build)
./claum/scripts/build-mac.sh --arch arm64
```

The first build takes **2–4 hours** on an M4 Mac mini and needs ~100 GB free.
Incremental builds are much faster.

When it finishes:

```bash
open ~/claum-build/build/src/out/Claum/Claum.app
```

### Windows x64

```powershell
# From an elevated PowerShell prompt
.\claum\scripts\build-windows.ps1 -Arch x64
```

### GitHub Actions (cloud build, no local disk needed)

Push this repo to GitHub and click **Actions → Build Claum → Run workflow**.
Binaries are produced as downloadable artifacts.

---

## Repo layout

```
claum-browser/
├── README.md                    # You are here
├── CHROMIUM_VERSION             # Pinned Chromium tag (e.g. 146.0.7680.164)
├── .github/workflows/           # Cloud build definitions
│   ├── build-mac.yml
│   └── build-windows.yml
├── claum/
│   ├── branding/                # Product name, Info.plist, icons
│   ├── patches/                 # Ordered Chromium patches
│   ├── resources/               # HTML/CSS/JS injected into Chromium
│   ├── extensions/              # Bundled component extensions
│   │   ├── claum-newtab/        # New-tab page + glass sidebar
│   │   └── claude-for-chrome/   # Claude AI side panel
│   └── scripts/                 # Build + helper scripts
└── docs/                        # Deep-dive docs per subsystem
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for a full tour.

---

## Status

| Component              | Status         | Notes                                     |
|------------------------|---------------|-------------------------------------------|
| Glass UI patch         | scaffolded     | Based on `glass-browser-preview.html`     |
| Vertical tabs          | scaffolded     | Carried forward from Glass Browser branch |
| Claum-newtab extension | merged + rebranded | Was `glass-browser-extension`         |
| Claude-for-Chrome ext. | new, MV3       | Side panel + per-tab agent context        |
| First-run import       | new, patched   | Chrome + Firefox + Safari + Edge          |
| Extension import       | new, custom    | Reads Chrome Preferences, re-installs CRX |
| macOS arm64 build      | scripted       | Tested approach from Glass Browser        |
| Windows x64 build      | scripted       | Equivalent pipeline on PowerShell         |

---

## License

Chromium is BSD-licensed. Ungoogled-chromium patches are BSD-3-Clause.
Claum original code (patches, extensions, resources) is MIT unless noted.

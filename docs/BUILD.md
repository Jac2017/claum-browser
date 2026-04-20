# Claum — detailed build guide

For the impatient, run the one-liner in the repo root README. This doc is
for when something goes wrong.

## Prerequisites

### macOS (Apple Silicon)

- **macOS 12.0 (Monterey) or newer.** macOS 15 Sequoia / 26 Tahoe confirmed.
- **Xcode 15.3+ with Command Line Tools.** `xcode-select --install` gets
  you CLT; the full Xcode from the App Store adds iOS SDKs (not needed).
- **Homebrew** for ninja/python3/node. Install from <https://brew.sh>.
- **~120 GB free disk space.** The source tree alone is ~45 GB unpacked;
  build artifacts push it to ~100 GB total.
- **16 GB RAM minimum, 32 GB recommended.** The build will run on 16 GB, but
  a few linking steps can OOM. Use `NUM_JOBS=4` if that happens.

### Windows

- **Windows 10 or 11, 64-bit.**
- **Visual Studio 2022** (Community edition is fine) with the "Desktop
  development with C++" workload, plus Windows 10 SDK 10.0.22621 or later.
- **Python 3.11+** on PATH. (Chromium's scripts are Python 3.)
- **depot_tools** from Google on PATH. See
  <https://commondatastorage.googleapis.com/chrome-infra-docs/flat/depot_tools/docs/html/depot_tools_tutorial.html>.
- **~150 GB free on an NTFS drive.** Not ReFS, not FAT32.

## The one-liner (mac)

```bash
git clone https://github.com/Jac2017/claum-browser.git
cd claum-browser
./claum/scripts/build-mac.sh --arch arm64
```

Go make dinner. When you come back in 3–4 hours:

```bash
open ~/claum-build/build/src/out/Claum/Claum.app
```

## Step-by-step (if you want to understand)

### 1. Clone the Claum repo

This repo is small (~4 MB). It holds patches, extensions, and scripts — no
Chromium source.

```bash
git clone https://github.com/Jac2017/claum-browser.git ~/claum-browser
cd ~/claum-browser
```

### 2. Clone ungoogled-chromium (automatic)

The build script does this for you into `~/claum-build`. If you want to do
it manually:

```bash
git clone --depth=1 https://github.com/ungoogled-software/ungoogled-chromium.git \
    ~/claum-build
```

### 3. Download the Chromium source tarball (automatic)

The ungoogled pipeline fetches
`chromium-<version>.tar.xz` from Google's archive (~3 GB). On a 100 Mbps link
this is ~5 minutes.

### 4. Unpack and prune (automatic)

- Unpack the tarball into `~/claum-build/build/src/`. Takes ~10 minutes.
- `utils/prune_binaries.py` strips pre-built Google binaries from the tree.
- `utils/patches.py apply` applies ungoogled's privacy patches.
- `utils/domain_substitution.py` rewrites Google domain strings so there are
  no sneaky network calls.

### 5. Stage Claum resources (automatic)

The script `rsync`s our two extensions into
`chrome/browser/resources/claum_extensions/`. This location is important —
it's what the component-extension registration patch references.

### 6. Apply Claum patches (automatic)

`git apply` runs over every `.patch` file in `claum/patches/`, in order.
If any patch fails, the build stops and prints which one. See
[Troubleshooting](#troubleshooting).

### 7. gn gen (automatic)

`gn gen out/Claum --args="<flags>"` produces ninja build files. The flags
are documented inline in `build-mac.sh`; the ones you might want to tweak:

- `chrome_pgo_phase=0` — turn PGO off (faster build, slightly slower browser)
- `symbol_level=0` — no symbols at all (smallest binary)
- `is_component_build=true` — faster rebuilds during development

### 8. ninja (the long part)

```
ninja -C out/Claum chrome
```

On an M4 with 16 GB RAM this takes 2–4 hours. The progress counter climbs
through ~87,000 compile units. You'll see disk and CPU pinned.

## Troubleshooting

### "patch failed" during step 6

Almost always means the Chromium version has drifted from what the patches
were written for. Check:

```bash
cat ~/claum-browser/CHROMIUM_VERSION
```

Make sure that matches the version in
`~/claum-build/chromium_version.txt`. If they differ, either:

- Check out an older ungoogled-chromium that targets your Claum version, or
- Update the patches to match the new Chromium (the affected hunks need
  re-contexted).

### "Killed: 9" during ninja (macOS)

You ran out of RAM. Retry with fewer parallel jobs:

```bash
NUM_JOBS=4 ./claum/scripts/build-mac.sh --arch arm64 --skip-download
```

### "MSB8036: The Windows SDK version X was not found" (Windows)

Your VS install is missing the Windows SDK. Open the Visual Studio Installer,
select "Modify" on VS 2022, check "Windows 10 SDK (10.0.22621.0)" or newer.

### The built Claum launches but the glass UI is missing

You built without `claum_component_extensions=true`. The extensions are
copied but never registered. Re-gen:

```bash
cd ~/claum-build/build/src
gn args out/Claum  # opens editor; check claum_component_extensions is true
ninja -C out/Claum chrome
```

### The extensions load but the Claude side panel shows "No API key"

Expected — the first-install options page opens automatically. Paste your
Anthropic API key there.

### Nothing imports from Chrome

Chrome must be **closed** when you import (otherwise the SQLite files are
locked). Quit Chrome, then re-run the import from
`chrome://settings/importData`.

## Incremental rebuilds

Once the first build succeeds, subsequent builds are fast:

```bash
cd ~/claum-build/build/src
ninja -C out/Claum chrome    # only rebuilds what changed
```

For iteration on the extensions specifically, skip rebuilding the browser
entirely — side-load them instead:

```bash
open ~/claum-build/build/src/out/Claum/Claum.app --args \
  --load-extension=$HOME/claum-browser/claum/extensions/claum-newtab,$HOME/claum-browser/claum/extensions/claude-for-chrome \
  --user-data-dir=/tmp/claum-dev
```

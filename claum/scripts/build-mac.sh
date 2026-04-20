#!/usr/bin/env bash
# ============================================================================
# Claum — macOS build script (Apple Silicon / arm64)
# ----------------------------------------------------------------------------
# One-shot entrypoint. Does, in order:
#   1. Verify prerequisites (Xcode CLT, Homebrew, ninja, python3, disk space).
#   2. Clone ungoogled-chromium into $CLAUM_BUILD_ROOT.
#   3. Run ungoogled's own pipeline to download + unpack Chromium source,
#      prune binaries, and apply the ungoogled privacy patches.
#   4. Copy Claum extensions + resources into the tree.
#   5. Apply Claum's own patches on top.
#   6. Run `gn gen` with Claum's build flags and kick off ninja.
#
# Usage:
#   ./claum/scripts/build-mac.sh --arch arm64
#   ./claum/scripts/build-mac.sh --arch arm64 --default-search duckduckgo
#   ./claum/scripts/build-mac.sh --skip-download   # if source already unpacked
# ============================================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# -------- Parse flags -------------------------------------------------------
ARCH="arm64"
DEFAULT_SEARCH="bing"
SKIP_DOWNLOAD=0
CLEAN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --arch)            ARCH="$2"; shift 2 ;;
    --default-search)  DEFAULT_SEARCH="$2"; shift 2 ;;
    --skip-download)   SKIP_DOWNLOAD=1; shift ;;
    --clean)           CLEAN=1; shift ;;
    --help|-h)
      sed -n '5,20p' "$0"; exit 0 ;;
    *)
      log_err "Unknown flag: $1"; exit 1 ;;
  esac
done

if [ "$ARCH" != "arm64" ] && [ "$ARCH" != "x86_64" ]; then
  log_err "--arch must be arm64 or x86_64 (got: $ARCH)"; exit 1
fi

# -------- Pretty banner -----------------------------------------------------
cat <<BANNER

╔══════════════════════════════════════════════════╗
║   Claum Browser — macOS Build                    ║
║   Arch: ${ARCH}  ·  Chromium ${CHROMIUM_VERSION}      ║
╚══════════════════════════════════════════════════╝

BANNER

# -------- [1/6] Prerequisites ----------------------------------------------
log_step "[1/6] Checking prerequisites"

if ! xcode-select -p >/dev/null 2>&1; then
  log_warn "Xcode Command Line Tools not installed. Running xcode-select --install."
  xcode-select --install
  log_err "Re-run this script after the install dialog completes."
  exit 1
fi
log_ok "Xcode Command Line Tools"

# Make sure Homebrew is on PATH (Apple Silicon keeps it at /opt/homebrew).
if ! command -v brew >/dev/null 2>&1; then
  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  else
    log_err "Homebrew not found. Install from https://brew.sh first."
    exit 1
  fi
fi
log_ok "Homebrew"

for t in ninja python3 node git rsync; do
  if ! command -v "$t" >/dev/null 2>&1; then
    log_warn "$t not found. Installing via Homebrew."
    brew install "$t"
  fi
done
log_ok "ninja / python3 / node / git / rsync"

# Disk space check.
# Chromium release build (no debug symbols, no PGO) needs ~50-60 GB during
# build. We check the volume that holds CLAUM_BUILD_ROOT (which on GitHub
# Actions is a different mount than $HOME — this is why the previous version
# was wrong).
CHECK_PATH="${CLAUM_BUILD_ROOT:-$HOME}"
mkdir -p "$CHECK_PATH"   # ensure it exists so df can stat it
FREE_GB=$(df -g "$CHECK_PATH" | tail -1 | awk '{print $4}')
MIN_GB=50

# In CI environments (GitHub Actions, etc.) we can't prompt interactively,
# so we just warn and continue. Locally we still ask before proceeding.
if [ "$FREE_GB" -lt "$MIN_GB" ]; then
  log_warn "Only ${FREE_GB} GB free at ${CHECK_PATH} — Chromium typically needs ~${MIN_GB}+ GB."
  if [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
    log_warn "Running in CI — continuing anyway. Build may fail with 'No space left on device'."
  else
    read -r -p "     Continue anyway? [y/N] " REPLY
    [[ "$REPLY" =~ ^[Yy]$ ]] || exit 1
  fi
else
  log_ok "Disk: ${FREE_GB} GB free at ${CHECK_PATH}"
fi

# -------- [2/6] Clone ungoogled-chromium -----------------------------------
log_step "[2/6] Syncing ungoogled-chromium"
clone_or_update_ungoogled

# -------- [3/6] Download + unpack Chromium source --------------------------
if [ "$SKIP_DOWNLOAD" -eq 0 ]; then
  log_step "[3/6] Downloading and unpacking Chromium $CHROMIUM_VERSION"
  cd "$CLAUM_BUILD_ROOT"

  # The ungoogled-chromium tooling uses -i for the downloads.ini config
  # (which itself names the Chromium version + tarball URL) and -c for the
  # cache directory where tarballs are downloaded to / read from.
  # Make sure the cache directory exists — downloads.py won't auto-create it.
  mkdir -p build/downloads

  # 1. Download the Chromium source tarball (~3 GB) into build/downloads/
  ./utils/downloads.py retrieve -i downloads.ini -c build/downloads

  # 2. Unpack the tarball into build/src/ (~25 GB unpacked)
  ./utils/downloads.py unpack   -i downloads.ini -c build/downloads build/src

  # 3. Strip Google's pre-built binaries (security + reproducibility)
  ./utils/prune_binaries.py build/src pruning.list

  # 4. Apply the ungoogled-chromium privacy patches on top of stock Chromium
  ./utils/patches.py apply build/src patches

  # 5. Replace google.com / etc. with neutral alternates throughout the source
  ./utils/domain_substitution.py apply \
      -r domain_regex.list \
      -f domain_substitution.list \
      -c build/domsubcache.tar.gz \
      build/src
else
  log_ok "[3/6] Skipping download (--skip-download)"
fi

# -------- [4/6] Copy Claum resources into the tree -------------------------
log_step "[4/6] Staging Claum resources"
install_claum_resources

# -------- [5/6] Apply Claum patches ----------------------------------------
log_step "[5/6] Applying Claum patches"
apply_claum_patches

# Copy branding overlay into the Info.plist-generator directory.
cp "$CLAUM_REPO_DIR/claum/branding/BRANDING" \
   "$CLAUM_BUILD_ROOT/build/src/chrome/app/theme/chromium/BRANDING"
# And the app icons (if present).
if [ -f "$CLAUM_REPO_DIR/claum/branding/icons/app.icns" ]; then
  cp "$CLAUM_REPO_DIR/claum/branding/icons/app.icns" \
     "$CLAUM_BUILD_ROOT/build/src/chrome/app/theme/chromium/mac/app.icns"
fi

# -------- [6/6] gn gen + ninja --------------------------------------------
log_step "[6/6] Running gn gen and ninja"
cd "$CLAUM_BUILD_ROOT/build/src"

OUT_DIR="out/Claum"
if [ "$CLEAN" -eq 1 ] && [ -d "$OUT_DIR" ]; then
  log_warn "Removing previous build output ($OUT_DIR)"
  rm -rf "$OUT_DIR"
fi

# GN args — these tune how the Chromium build system generates ninja files.
# Each one is explained because this is where most build mistakes happen.
GN_ARGS="
  is_debug=false                     # release build (no debug symbols)
  is_official_build=true             # enable optimizations + LTO
  symbol_level=1                     # minimal symbols (keep backtraces readable)
  blink_symbol_level=0               # no blink symbols (saves disk)
  enable_nacl=false                  # NaCl is deprecated, skip
  enable_reading_list=true
  enable_widevine=false              # DRM module — optional
  target_os=\"mac\"
  target_cpu=\"$ARCH\"
  use_system_libjpeg=true
  use_system_zlib=true
  chrome_pgo_phase=0                 # profile-guided opt off (faster build)
  is_component_build=false
  # --- Claum-specific flags ---
  claum_default_search=\"$DEFAULT_SEARCH\"
  claum_component_extensions=true
"

mkdir -p "$OUT_DIR"
gn gen "$OUT_DIR" --args="$GN_ARGS"

# Build the main browser target.
NUM_JOBS="${NUM_JOBS:-$(sysctl -n hw.logicalcpu)}"
log_ok "Starting ninja with $NUM_JOBS parallel jobs"
ninja -C "$OUT_DIR" -j "$NUM_JOBS" chrome

# -------- Done --------------------------------------------------------------
APP_PATH="$CLAUM_BUILD_ROOT/build/src/$OUT_DIR/Claum.app"
cat <<DONE

╔══════════════════════════════════════════════════╗
║                 Build complete                   ║
╠══════════════════════════════════════════════════╣
  Claum.app → $APP_PATH

  Launch it with:
    open "$APP_PATH"
╚══════════════════════════════════════════════════╝
DONE

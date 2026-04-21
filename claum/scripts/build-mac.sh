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

# gn (Generate Ninja) is Chromium's meta-build tool. It's not in Homebrew,
# and ungoogled-chromium prunes the pre-built gn from the Chromium source
# tree — so we build it from its own upstream repo. Takes ~2 minutes.
if ! command -v gn >/dev/null 2>&1; then
  GN_DIR="${GN_DIR:-$HOME/gn}"

  if [ ! -x "$GN_DIR/out/gn" ]; then
    log_warn "gn not found. Building it from source at gn.googlesource.com"

    if [ ! -d "$GN_DIR/.git" ]; then
      # IMPORTANT: do NOT use --depth=1 here. gn's build/gen.py runs
      #   `git describe HEAD --abbrev=12 --match initial-commit`
      # to stamp a version string into last_commit_position.h, and that
      # requires the `initial-commit` tag to be present locally. A shallow
      # clone drops tags, and gen.py dies with "fatal: No names found".
      # A full clone of gn is only ~20 MB — trivial vs. Chromium's 3 GB.
      git clone https://gn.googlesource.com/gn "$GN_DIR"
    fi

    # gn has its own self-hosted bootstrap (no chicken-and-egg problem):
    #   - build/gen.py generates a small ninja file
    #   - ninja then compiles gn into out/gn
    (
      cd "$GN_DIR"
      python3 build/gen.py
      ninja -C out gn
    )
  fi

  # Put the freshly-built gn on PATH for the rest of this script.
  export PATH="$GN_DIR/out:$PATH"
fi
log_ok "gn: $(command -v gn)"

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
# IMPORTANT: ordering inside this block matters. Toolchain downloads (clang,
# Rust) MUST happen BEFORE domain_substitution.py — otherwise the substitution
# rewrites Google URLs in update.py / update_rust.py to fake stand-ins like
# `9oo91eapis.qjz9zk` and the downloads fail with DNS errors.
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

  # 5. Download Chromium's build toolchains (clang + Rust) BEFORE domain
  #    substitution runs. update.py / update_rust.py both contain the real
  #    Google URLs (commondatastorage.googleapis.com) which they need in order
  #    to reach the prebuilt-binary bucket. If domain substitution runs first,
  #    those URLs become "commondatastorage.9oo91eapis.qjz9zk" (intentional
  #    nonsense) and the downloads die with DNS failures.
  log_step "[3a/6] Downloading Chromium build toolchains (clang + Rust)"
  SRC="$CLAUM_BUILD_ROOT/build/src"

  if [ -f "$SRC/tools/clang/scripts/update.py" ]; then
    log_ok "Downloading clang toolchain (~150 MB)"
    python3 "$SRC/tools/clang/scripts/update.py"
  else
    log_warn "clang update script not found — assuming system clang"
  fi

  if [ -f "$SRC/tools/rust/update_rust.py" ]; then
    log_ok "Downloading Rust toolchain (~200 MB)"
    python3 "$SRC/tools/rust/update_rust.py"
  else
    log_warn "Rust update script not found"
  fi

  # Stamp build/util/LASTCHANGE (used for version info embedded in the binary).
  if [ -f "$SRC/build/util/lastchange.py" ]; then
    log_ok "Generating LASTCHANGE"
    python3 "$SRC/build/util/lastchange.py" -o "$SRC/build/util/LASTCHANGE" \
      || log_warn "lastchange.py failed (non-fatal)"
  fi

  # 6. Replace google.com / etc. with neutral alternates throughout the source
  #    NOW it's safe — clang/Rust are already on disk; gn won't need to fetch.
  log_step "[3b/6] Applying domain substitution"
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

# ----------------------------------------------------------------------------
# Stage the bundled Node.js that Chromium's build scripts expect.
# ----------------------------------------------------------------------------
# Chromium's JS bundler (lit.rollup.js and friends) shells out to a Node
# binary that Google hosts on GCS and downloads via a `gclient sync` hook:
#   third_party/node/mac_arm64/node-darwin-arm64/bin/node
# ungoogled-chromium strips those Google-hosted binary downloads for
# privacy. Without the file, ninja dies with:
#     ninja: error: '../../third_party/node/mac_arm64/node-darwin-arm64/bin/node',
#            needed by 'gen/third_party/lit/v3_0/bundled/lit.rollup.js',
#            missing and no known rule to make it
#
# Fix: copy the Homebrew-installed `node` into the expected path. Chromium
# mostly just uses node to run rollup.js / tsc.js; it doesn't care whether
# the binary is the exact pinned version, so the system copy works fine
# for a one-shot build. We use `install -m 0755` instead of cp so the
# binary is marked executable even on filesystems that ignore +x copies.
# ----------------------------------------------------------------------------
log_step "Staging bundled Node.js for Chromium's JS bundler"
NODE_DIR_REL="third_party/node/mac_${ARCH}/node-darwin-${ARCH}/bin"
NODE_DIR_ABS="$CLAUM_BUILD_ROOT/build/src/$NODE_DIR_REL"
mkdir -p "$NODE_DIR_ABS"

if [ ! -x "$NODE_DIR_ABS/node" ]; then
  SYS_NODE="$(command -v node || true)"
  if [ -z "$SYS_NODE" ]; then
    log_err "System node not found on PATH; install it via 'brew install node'"
    exit 1
  fi
  install -m 0755 "$SYS_NODE" "$NODE_DIR_ABS/node"
  echo "  staged $(basename $SYS_NODE) ($("$SYS_NODE" --version)) -> $NODE_DIR_REL/node"
else
  echo "  node already present at $NODE_DIR_REL/node"
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
  use_libcxx_modules=false           # workaround for Xcode 16 SDK modulemap mismatch
  use_clang_modules=false            # turn OFF clang module compilation entirely
  treat_warnings_as_errors=false     # tolerate warnings so build does not abort
  # --- Claum-specific flags ---
  claum_default_search=\"$DEFAULT_SEARCH\"
  claum_component_extensions=true
"

# ----------------------------------------------------------------------------
# NOTE on use_libcxx_modules=false
# ----------------------------------------------------------------------------
# Chromium 146 plus Xcode 16.0/16.1/16.2 have a known mismatch: Chromium's
# libc++ build rules expect modulemap files with numeric suffixes such as
# DarwinFoundation1.modulemap, but the Xcode 16.2 SDK only ships the
# un-suffixed DarwinFoundation.modulemap. So ninja fails with:
#     DarwinFoundation1.modulemap missing and no known rule to make it
# Turning off libc++ module compilation skips that rule entirely.
# If the arg name is wrong, gn will just warn and continue -- same as it
# already does for claum_component_extensions.
# ----------------------------------------------------------------------------
# IMPORTANT: comments INSIDE the GN_ARGS string above must be plain text
# only. Bash does NOT ignore # inside double quotes -- any special chars
# after # still get expanded, so backticks and embedded double-quotes will
# break the build the way they did in run #21. Keep comments up here.
# ----------------------------------------------------------------------------

mkdir -p "$OUT_DIR"

# ---------------------------------------------------------------------------
# MODULEMAP SYMLINK FALLBACK
# ---------------------------------------------------------------------------
# Chromium 146's libc++ build rules can reference SDK modulemap files with
# numeric suffixes (e.g. DarwinFoundation1.modulemap) but the Xcode 16.2
# SDK only ships the un-suffixed names (DarwinFoundation.modulemap). If
# `use_libcxx_modules=false` in the gn args doesn't fully suppress the
# reference, ninja will abort with:
#     ninja: error: '.../DarwinFoundation1.modulemap', needed by ...,
#            missing and no known rule to make it
# As a belt-and-suspenders fix, we scan the SDK's include dir and create
# a `<Name>1.modulemap` symlink for every `<Name>.modulemap` file that
# doesn't already have a numeric-suffix counterpart. This is the minimal
# change that keeps things working without modifying Chromium source.
#
# NOTE: GitHub runners allow sudo without a password, which is why
# `sudo ln` just works here. On a developer machine it will prompt.
# ---------------------------------------------------------------------------
log_step "Creating modulemap symlinks for Xcode 16.x SDK compat"
SDK_INC_DIR="${SDKROOT:-$(xcrun --show-sdk-path)}/usr/include"
if [ -d "$SDK_INC_DIR" ]; then
  # Loop only over files directly under usr/include (not subdirs). `find
  # -maxdepth 1` keeps us from touching per-framework modulemaps that
  # Chromium isn't complaining about.
  for mm in "$SDK_INC_DIR"/*.modulemap; do
    [ -f "$mm" ] || continue
    base=$(basename "$mm" .modulemap)   # e.g. "DarwinFoundation"
    # Skip files that already have a trailing digit (like "Darwin_sys").
    case "$base" in
      *[0-9]) continue ;;
    esac
    target="$SDK_INC_DIR/${base}1.modulemap"
    if [ ! -e "$target" ]; then
      # `sudo ln -sf` creates a relative symlink inside the SDK dir.
      sudo ln -sf "${base}.modulemap" "$target" 2>/dev/null \
        && echo "  linked ${base}1.modulemap -> ${base}.modulemap" \
        || echo "  (could not link ${base}1.modulemap -- continuing)"
    fi
  done
else
  log_warn "SDK include dir not found at $SDK_INC_DIR; skipping modulemap symlinks"
fi

# ---------------------------------------------------------------------------
# FIX: Stock Chromium's chrome/browser/safe_browsing/BUILD.gn defines
# `sources = [...]` and `deps = [...]` inside an outer `if (safe_browsing_mode
# != 0) { ... }` block, and then appends to them with `sources += [...]` and
# `deps += [...]` in a later inner block. When ungoogled's build flips
# safe_browsing_mode to 0, the outer block is skipped — but the later += calls
# still run and gn dies with "Undefined identifier. sources += [" (and later
# the same for `deps +=`).
#
# The helper script inserts guarded initializers at the top of the inner
# `if (safe_browsing_mode != 0) { ... }` block:
#     if (!defined(sources)) { sources = [] }
#     if (!defined(deps))    { deps    = [] }
# which are no-ops if the outer block already populated them, and safely
# initialize to empty lists otherwise. See fix-safe-browsing-gn.py for the
# full write-up. The script is idempotent and safe to re-run.
# ---------------------------------------------------------------------------
log_step "Fixing chrome/browser/safe_browsing/BUILD.gn (ungoogled patch artifact)"
python3 "$CLAUM_REPO_DIR/claum/scripts/fix-safe-browsing-gn.py" \
        "$CLAUM_BUILD_ROOT/build/src"

# ---------------------------------------------------------------------------
# DIAGNOSTIC: dump several windows of the post-patched BUILD.gn so we can
# see exactly what state it's in. We dump:
#   * lines 1-30   — the file header + `source_set("safe_browsing") {` opening
#   * lines 80-160 — the area we already fixed (sources= / deps+)
#   * lines 700-760 — the tail end, where a new "Expecting assignment..."
#                     error showed up at line 746 (likely another stray `}`).
# The `|| true` ensures the diagnostic never fails the build by itself.
# ---------------------------------------------------------------------------
SB_FILE="$CLAUM_BUILD_ROOT/build/src/chrome/browser/safe_browsing/BUILD.gn"
if [ -f "$SB_FILE" ]; then
  # Report the total number of lines so we know whether line 746 is near EOF.
  TOTAL_LINES=$(wc -l < "$SB_FILE")
  log_step "Diagnostic: BUILD.gn has $TOTAL_LINES lines"

  log_step "Diagnostic A: lines 1-30 of safe_browsing/BUILD.gn (file header)"
  cat -n "$SB_FILE" | sed -n '1,30p' || true
  echo "---- end diagnostic A ----"

  log_step "Diagnostic B: lines 80-160 of safe_browsing/BUILD.gn"
  cat -n "$SB_FILE" | sed -n '80,160p' || true
  echo "---- end diagnostic B ----"

  log_step "Diagnostic C: lines 700-760 of safe_browsing/BUILD.gn (around the new error)"
  # If the file is shorter than 700 lines, sed just prints nothing.
  cat -n "$SB_FILE" | sed -n '700,760p' || true
  echo "---- end diagnostic C ----"
else
  log_warn "Could not find $SB_FILE — skipping diagnostic."
fi

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

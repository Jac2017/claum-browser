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
# lib/ sits next to bin/ in the Chromium-expected layout. Modern Homebrew
# node (v22+) is dynamically linked against libnode.<ABI>.dylib, and the
# node binary looks it up via @rpath which dyld resolves to `../lib/` —
# so we MUST populate both bin/ and lib/, otherwise the staged node dies
# at launch with `dyld: Library not loaded: @rpath/libnode.127.dylib`.
NODE_LIB_ABS="$CLAUM_BUILD_ROOT/build/src/third_party/node/mac_${ARCH}/node-darwin-${ARCH}/lib"
mkdir -p "$NODE_DIR_ABS" "$NODE_LIB_ABS"

if [ ! -x "$NODE_DIR_ABS/node" ]; then
  SYS_NODE="$(command -v node || true)"
  if [ -z "$SYS_NODE" ]; then
    log_err "System node not found on PATH; install it via 'brew install node'"
    exit 1
  fi

  # Resolve through any symlinks so we copy the real binary (Homebrew keeps
  # `node` as a symlink under /opt/homebrew/bin that points at the real
  # binary inside /opt/homebrew/Cellar/node/<version>/bin/). We use python3
  # for portability — macOS's /usr/bin/readlink doesn't support `-f`.
  SYS_NODE_REAL="$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$SYS_NODE")"

  install -m 0755 "$SYS_NODE_REAL" "$NODE_DIR_ABS/node"
  echo "  staged $(basename $SYS_NODE) ($("$SYS_NODE" --version)) -> $NODE_DIR_REL/node"

  # Modern Homebrew `node` is linked against libnode.<ABI>.dylib which
  # lives somewhere under the Homebrew Cellar for node. The node binary
  # looks it up via `@rpath/libnode.<ABI>.dylib`, which dyld resolves
  # against `bin/../lib/libnode.<ABI>.dylib` — so we must copy the dylib
  # into the lib/ adjacent to bin/ (NOT inside bin/).
  #
  # Run #24 failed here: the libnode dylib was missing and dyld printed:
  #   Library not loaded: @rpath/libnode.127.dylib
  #   tried: '.../bin/libnode.127.dylib' (no such file),
  #          '.../bin/../lib/libnode.127.dylib' (no such file)
  #
  # We search the whole node install prefix (one level above bin/) because
  # Homebrew has moved dylibs around over the years (sometimes lib/,
  # sometimes libexec/lib/). Copying every libnode.*.dylib we find
  # future-proofs us against ABI version bumps too.
  NODE_PREFIX="$(dirname "$(dirname "$SYS_NODE_REAL")")"
  dylib_count=0
  # `find -print0 | xargs -0` pattern adapted for bash: we read NUL-separated
  # names via a process substitution so filenames with spaces are safe.
  while IFS= read -r -d '' lib; do
    install -m 0644 "$lib" "$NODE_LIB_ABS/$(basename "$lib")"
    echo "  staged $(basename "$lib") -> third_party/node/.../lib/"
    dylib_count=$((dylib_count + 1))
  done < <(find "$NODE_PREFIX" -name 'libnode.*.dylib' -type f -print0 2>/dev/null)

  if [ "$dylib_count" -eq 0 ]; then
    # Not fatal — some older Homebrew node versions are statically linked,
    # in which case the binary has no @rpath dylib deps and this is fine.
    log_warn "No libnode.*.dylib found under $NODE_PREFIX."
    log_warn "  If node fails at runtime with 'Library not loaded: @rpath/libnode...', this is why."
  fi
else
  echo "  node already present at $NODE_DIR_REL/node"
fi

# ----------------------------------------------------------------------------
# Align third_party/node/update_node_binaries with the node we just staged.
# ----------------------------------------------------------------------------
# Chromium ships a check_version.py/check_version.js target that runs at the
# start of ninja and hard-asserts the staged node's `process.version` matches
# the version string in third_party/node/update_node_binaries. Google pins
# this to whatever they shipped that Chromium release with — e.g. 146 pins
# v24.12.0. But macOS runners' Homebrew node can be anything (v22.22.2 at
# time of writing), so the assertion blows up at action [~5684/56129]:
#     AssertionError [ERR_ASSERTION]: Failed NodeJS version check:
#         Expected version 'v24.12.0', but found 'v22.22.2'.
# Run #30 died here. Fix: after staging node, overwrite update_node_binaries
# to match the actual staged binary's `node --version` output. The script
# doesn't care which exact version runs rollup/tsc; only the assertion is
# picky, and we short-circuit it by telling it what we actually have.
# ----------------------------------------------------------------------------
STAGED_NODE_VER="$("$NODE_DIR_ABS/node" --version 2>/dev/null || true)"
UPDATE_FILE="$CLAUM_BUILD_ROOT/build/src/third_party/node/update_node_binaries"
if [ -n "$STAGED_NODE_VER" ]; then
  # Run #31 lesson: check_version.js does NOT read the file as a plain
  # "v22.22.2\n" string — it regex-extracts from the containing shell
  # script. The original update_node_binaries is a bash script that
  # sets `NODE_VERSION="v24.12.0"`, and extractExpectedVersion() reads
  # it looking for that assignment. Writing just "v22.22.2" makes the
  # regex miss and throws "Could not extract NodeJS version".
  #
  # Fix: emit a fake shell script that still sets NODE_VERSION. The
  # actual Chromium script does a bunch of gsutil downloads we don't
  # care about — check_version.js only cares about the one assignment.
  cat > "$UPDATE_FILE" <<UPDATE_EOF
#!/bin/bash
# Synthesized by Claum build-mac.sh to match the staged node binary.
NODE_VERSION="$STAGED_NODE_VER"
UPDATE_EOF
  chmod +x "$UPDATE_FILE"
  echo "  wrote NODE_VERSION=$STAGED_NODE_VER to third_party/node/update_node_binaries"
else
  log_warn "Could not determine staged node version — check_version.js may fail"
fi

# Additional belt-and-suspenders: also patch check_version.js to make it
# a no-op. Chromium only uses node for rollup/tsc; the version check is
# purely defensive against mismatched gclient-synced binaries. Since our
# staged Homebrew node works fine for those tasks, skipping is safe.
CHECK_JS="$CLAUM_BUILD_ROOT/build/src/third_party/node/check_version.js"
if [ -f "$CHECK_JS" ]; then
  # Replace the entire file with an early-exit no-op. We keep the #! line
  # so node accepts it as a script, then immediately exit 0 — which
  # satisfies check_version.py (it only checks exit code 0, not the file
  # contents it ignored). This path is idempotent.
  cat > "$CHECK_JS" <<'NOOP_EOF'
#!/usr/bin/env node
// Neutered by Claum build-mac.sh. See BUILD_NOTES.md run #31.
process.exit(0);
NOOP_EOF
  echo "  neutered third_party/node/check_version.js"
fi

# ----------------------------------------------------------------------------
# Stage google_toolbox_for_mac — a Chromium third_party dep that ungoogled
# strips along with other Google-hosted repos.
# ----------------------------------------------------------------------------
# Chromium uses this Obj-C utility library on macOS for things like UI
# localization (GTMUILocalizer). It lives at:
#   third_party/google_toolbox_for_mac/src/
# After ungoogled's pruning step the `src/` subdirectory is empty, so ninja
# dies with:
#   ninja: error: '../../third_party/google_toolbox_for_mac/src/AppKit/GTMUILocalizer.m',
#          needed by '.../GTMUILocalizer.o', missing and no known rule to make it
#
# Fix: clone the public Apache-2.0 repo into the expected path AFTER the
# pruning step. This mirrors the node-staging pattern (ungoogled-chromium
# PR #2954 discussion): any Google-hosted dep that got pruned must be
# restored AFTER pruning or it just gets deleted again.
#
# Chromium's DEPS file pins a specific commit, but for our purposes the
# public tip-of-main is fine — the library is small and the Obj-C API
# we're using (GTMUILocalizer, GTMLogger, etc.) has been stable for years.
# ----------------------------------------------------------------------------
log_step "Staging google_toolbox_for_mac sources"
GTM_DIR_ABS="$CLAUM_BUILD_ROOT/build/src/third_party/google_toolbox_for_mac/src"
if [ ! -f "$GTM_DIR_ABS/AppKit/GTMUILocalizer.m" ]; then
  # If the directory exists but is missing the expected file, remove it so
  # `git clone` has a clean target. `-rf` is safe here because this path is
  # controlled entirely by us (it's inside our build tree).
  rm -rf "$GTM_DIR_ABS"
  mkdir -p "$(dirname "$GTM_DIR_ABS")"
  # --depth 1 = shallow clone (no history). We only need the working tree,
  # not the full commit history — saves ~50 MB and a few seconds.
  git clone --depth 1 \
    https://github.com/google/google-toolbox-for-mac.git \
    "$GTM_DIR_ABS"
  echo "  cloned google-toolbox-for-mac into third_party/google_toolbox_for_mac/src"
else
  echo "  google_toolbox_for_mac already present"
fi

# ----------------------------------------------------------------------------
# Run #62 fix: relocate GTMDefines.h to where Chromium expects it.
# ----------------------------------------------------------------------------
# Background — what GTMDefines.h is and why this breaks:
#   GTMDefines.h is the umbrella header that every Obj-C file in
#   google-toolbox-for-mac (`#import "GTMDefines.h"`) starts with. It
#   provides debug macros, deprecation guards, etc. — without it, NOTHING
#   in the library compiles.
#
# Chromium's BUILD.gn for third_party/google_toolbox_for_mac was written
# years ago against the OLD upstream layout, where the file lived at:
#   src/Foundation/GTMDefines.h
# Chromium accordingly adds `-I.../src/Foundation` to the compile flags.
#
# Sometime after Chromium pinned its DEPS commit, Google reorganized the
# upstream repo and moved the header to a brand-new path:
#   src/Sources/Defines/Public/GTMDefines.h
# Foundation/ still exists in upstream HEAD, but no longer contains
# GTMDefines.h, so clang fails with:
#   AppKit/GTMUILocalizer.m:19:9: fatal error: 'GTMDefines.h' file not found
#
# Run #62 hit exactly this at ninja [43889/55997] (78% of the build —
# the FURTHEST a Claum build has ever gotten; all earlier blockers
# are now resolved).
#
# Fix — `cp` (not symlink) the relocated header back into the legacy
# Foundation/ path. Copy is safer than symlink because:
#   1. ungoogled-chromium's prune step has been known to follow & delete
#      symlinks pointing outside the prune target.
#   2. sccache hashes file contents, not symlink target paths — a real
#      file gives consistent cache keys across machines.
# We don't pin to an older commit (which would be the "cleanest" fix)
# because earlier tags don't have the AppKit fixes Chromium also relies
# on — pinning back would just trade one breakage for another.
# ----------------------------------------------------------------------------
NEW_DEFINES="$GTM_DIR_ABS/Sources/Defines/Public/GTMDefines.h"
LEGACY_DEFINES="$GTM_DIR_ABS/Foundation/GTMDefines.h"
if [ -f "$NEW_DEFINES" ] && [ ! -f "$LEGACY_DEFINES" ]; then
  # mkdir -p in case Foundation/ ever vanishes from upstream too.
  mkdir -p "$(dirname "$LEGACY_DEFINES")"
  # `install -m 0644` copies the file AND sets sane perms in one step.
  install -m 0644 "$NEW_DEFINES" "$LEGACY_DEFINES"
  echo "  staged GTMDefines.h: Sources/Defines/Public -> Foundation/ (run #62 fix)"
elif [ -f "$LEGACY_DEFINES" ]; then
  echo "  GTMDefines.h already at Foundation/ (no relocation needed)"
else
  # Don't fail the build here — let ninja produce its own error so the
  # build log shows the real missing-file message. Just warn loudly.
  log_warn "  GTMDefines.h not found at either old or new upstream path."
  log_warn "  google-toolbox-for-mac may have been restructured again — check upstream."
fi

# ----------------------------------------------------------------------------
# Stage system `dsymutil` into the Chromium-expected toolchain path.
# ----------------------------------------------------------------------------
# dsymutil is Apple's debug-symbol utility, used by Chromium when packaging
# devtools-frontend (see build/toolchain/mac: the `mac_strip_dsymutil`
# helper invokes `tools/clang/dsymutil/bin/dsymutil`). Chromium normally
# gets a pre-built LLVM dsymutil via its `tools/clang/scripts/update.py`
# gclient hook — ungoogled-chromium strips that hook as part of privacy
# pruning, so the binary never lands in our checkout.
#
# Run #26 failed here at action [1036/56129]:
#     FileNotFoundError: [Errno 2] No such file or directory:
#       '../../tools/clang/dsymutil/bin/dsymutil'
#     [1036/56129] ACTION //third_party/devtools-frontend/.../issue_counter:css_files
#     ninja: build stopped: subcommand failed.
#
# Fix: same "stage after pruning" pattern as node and google_toolbox_for_mac.
# Apple's Xcode ships a perfectly good `dsymutil` — we locate it via
# `xcrun --find dsymutil` and copy it into the expected path.
# ----------------------------------------------------------------------------
log_step "Staging system dsymutil for Chromium toolchain path"
DSYM_DIR_REL="tools/clang/dsymutil/bin"
DSYM_DIR_ABS="$CLAUM_BUILD_ROOT/build/src/$DSYM_DIR_REL"
mkdir -p "$DSYM_DIR_ABS"
if [ ! -x "$DSYM_DIR_ABS/dsymutil" ]; then
  # xcrun --find resolves to the dsymutil inside the active Xcode
  # (DEVELOPER_DIR). This is Apple's dsymutil, not LLVM's — they're API
  # compatible for the ops Chromium uses (dumping debug maps, producing
  # .dSYM bundles), so the substitution works fine for a one-shot build.
  SYS_DSYM="$(xcrun --find dsymutil 2>/dev/null || command -v dsymutil || true)"
  if [ -z "$SYS_DSYM" ] || [ ! -x "$SYS_DSYM" ]; then
    log_err "System dsymutil not found — can't stage into $DSYM_DIR_REL"
    log_err "  Tried: 'xcrun --find dsymutil' and 'command -v dsymutil'"
    exit 1
  fi
  # install -m 0755 both copies AND sets the executable bit. We don't use
  # `ln -s` here because ungoogled's prune pass can follow and delete
  # symlinks that point outside the repo.
  install -m 0755 "$SYS_DSYM" "$DSYM_DIR_ABS/dsymutil"
  echo "  staged $(basename "$SYS_DSYM") -> $DSYM_DIR_REL/dsymutil"
  echo "  (source: $SYS_DSYM)"
else
  echo "  dsymutil already present at $DSYM_DIR_REL/dsymutil"
fi

# ----------------------------------------------------------------------------
# Stage system `otool` as `llvm-otool` for Chromium's linker_driver.py.
# ----------------------------------------------------------------------------
# Chromium's `build/toolchain/apple/linker_driver.py` shells out to
# `third_party/llvm-build/Release+Asserts/bin/llvm-otool` during SOLINK to
# extract the Mach-O table of contents (TOC) that feeds incremental links.
# The `tools/clang/scripts/update.py` gclient hook normally provisions that
# binary — but ungoogled-chromium strips the hook, so the path is empty.
#
# Build #32 proved this: it reached ninja [12846/56129] then died at the
# first SOLINK (libvk_swiftshader.dylib) with:
#
#     FileNotFoundError: [Errno 2] No such file or directory:
#       '../../third_party/llvm-build/Release+Asserts/bin/llvm-otool'
#
# Fix: same "stage after pruning" pattern used for dsymutil above. macOS
# ships `/usr/bin/otool` as part of the Xcode command-line tools, and it
# accepts the same `-l` flag the linker_driver uses (it's literally the
# Apple binutils otool — LLVM's llvm-otool is an argv-compatible re-impl).
# Copy it into the pruned path so the linker driver finds it by literal
# path without needing any GN arg changes.
# ----------------------------------------------------------------------------
log_step "Staging system otool as llvm-otool for linker_driver.py"
OTOOL_DIR_REL="third_party/llvm-build/Release+Asserts/bin"
OTOOL_DIR_ABS="$CLAUM_BUILD_ROOT/build/src/$OTOOL_DIR_REL"
mkdir -p "$OTOOL_DIR_ABS"
if [ ! -x "$OTOOL_DIR_ABS/llvm-otool" ]; then
  # Prefer xcrun to find the otool inside the active Xcode (keeps us in sync
  # with the SDK selected by the workflow's Xcode step). Fall back to
  # command -v otool (Xcode CLT install also puts it in /usr/bin).
  SYS_OTOOL="$(xcrun --find otool 2>/dev/null || command -v otool || true)"
  if [ -z "$SYS_OTOOL" ] || [ ! -x "$SYS_OTOOL" ]; then
    log_err "System otool not found — can't stage into $OTOOL_DIR_REL"
    log_err "  Tried: 'xcrun --find otool' and 'command -v otool'"
    exit 1
  fi
  # Copy rather than symlink so the staged binary is self-contained in the
  # build tree (Chromium's deps graph sometimes stats paths and dislikes
  # symlinks that point outside the repo). mode 0755 = rwx for owner,
  # rx for group+other — same as dsymutil above.
  install -m 0755 "$SYS_OTOOL" "$OTOOL_DIR_ABS/llvm-otool"
  echo "  staged $(basename "$SYS_OTOOL") -> $OTOOL_DIR_REL/llvm-otool"
  echo "  (source: $SYS_OTOOL)"
else
  echo "  llvm-otool already present at $OTOOL_DIR_REL/llvm-otool"
fi

# Apple's /usr/bin/otool is a dispatcher wrapper: when called with Mach-O
# args it execs `otool-classic` from its own directory (argv[0]-relative).
# Run #34 proved this: after we staged /usr/bin/otool as llvm-otool,
# linker_driver invoked it and got:
#     fatal error: .../llvm-otool: can't find or exec:
#       .../third_party/llvm-build/Release+Asserts/bin/otool-classic
# So we also need to stage the classic backend next to our llvm-otool.
if [ ! -x "$OTOOL_DIR_ABS/otool-classic" ]; then
  SYS_OTOOL_CLASSIC="$(xcrun --find otool-classic 2>/dev/null || command -v otool-classic || true)"
  if [ -z "$SYS_OTOOL_CLASSIC" ] || [ ! -x "$SYS_OTOOL_CLASSIC" ]; then
    # Older Xcodes might not expose otool-classic via xcrun; fall back to a
    # common-ish path. If this also doesn't exist, skip — the build will
    # tell us where it lives.
    for CAND in \
        "/Library/Developer/CommandLineTools/usr/bin/otool-classic" \
        "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/otool-classic" \
        "/usr/bin/otool-classic"
    do
      if [ -x "$CAND" ]; then SYS_OTOOL_CLASSIC="$CAND"; break; fi
    done
  fi
  if [ -n "$SYS_OTOOL_CLASSIC" ] && [ -x "$SYS_OTOOL_CLASSIC" ]; then
    install -m 0755 "$SYS_OTOOL_CLASSIC" "$OTOOL_DIR_ABS/otool-classic"
    echo "  staged otool-classic -> $OTOOL_DIR_REL/otool-classic"
    echo "  (source: $SYS_OTOOL_CLASSIC)"
  else
    log_warn "otool-classic not found via xcrun or fallback paths."
    log_warn "  Apple's otool wrapper may fail at runtime; consider swapping to llvm-nm-based TOC extraction."
  fi
else
  echo "  otool-classic already present at $OTOOL_DIR_REL/otool-classic"
fi

# ----------------------------------------------------------------------------
# Pre-emptively stage the rest of the LLVM binutils Chromium expects during
# SOLINK / link-time TOC extraction / dylib fixup.
# ----------------------------------------------------------------------------
# Chromium's build/toolchain/apple/linker_driver.py and related action scripts
# routinely shell out to the following tools by LITERAL path:
#     third_party/llvm-build/Release+Asserts/bin/llvm-nm
#     third_party/llvm-build/Release+Asserts/bin/llvm-ar
#     third_party/llvm-build/Release+Asserts/bin/llvm-install_name_tool
#     third_party/llvm-build/Release+Asserts/bin/llvm-strip
#     third_party/llvm-build/Release+Asserts/bin/llvm-ranlib
#     third_party/llvm-build/Release+Asserts/bin/llvm-lipo
# Each one is pruned for the same reason llvm-otool was (the
# tools/clang/scripts/update.py hook is gone). Rather than burn a 1+ hour
# build cycle per tool, stage them all now — each has an argv-compatible
# Apple equivalent that xcrun can locate inside the active Xcode.
#
# We skip llvm-dwp (DWARF package; Mach-O uses .dSYM not .dwp) and
# llvm-objcopy (no Apple equivalent; Chromium's mac toolchain uses
# install_name_tool + strip instead). If either is actually invoked on mac
# we'll see a FileNotFoundError and add them then.
# ----------------------------------------------------------------------------
log_step "Staging system binutils as llvm-* for Chromium toolchain path"
# Space-separated pairs: "<apple_name> <llvm_staged_name>". Using a case
# statement instead of an associative array to stay POSIX/bash-3 compatible
# (macOS /bin/bash is 3.2 and we're being conservative).
for PAIR in \
    "nm llvm-nm" \
    "ar llvm-ar" \
    "install_name_tool llvm-install_name_tool" \
    "strip llvm-strip" \
    "ranlib llvm-ranlib" \
    "lipo llvm-lipo"
do
  APPLE_NAME="${PAIR% *}"
  LLVM_NAME="${PAIR#* }"
  DEST="$OTOOL_DIR_ABS/$LLVM_NAME"
  if [ -x "$DEST" ]; then
    echo "  $LLVM_NAME already present at $OTOOL_DIR_REL/$LLVM_NAME"
    continue
  fi
  SRC="$(xcrun --find "$APPLE_NAME" 2>/dev/null || command -v "$APPLE_NAME" || true)"
  if [ -z "$SRC" ] || [ ! -x "$SRC" ]; then
    log_warn "System $APPLE_NAME not found via xcrun/command -v — skipping $LLVM_NAME stage"
    log_warn "  If ninja actually calls $LLVM_NAME this build will fail; re-add manually."
    continue
  fi
  install -m 0755 "$SRC" "$DEST"
  echo "  staged $APPLE_NAME -> $OTOOL_DIR_REL/$LLVM_NAME"
  echo "  (source: $SRC)"
done

# ----------------------------------------------------------------------------
# Stage the `esbuild` binary into the DevTools-frontend third_party path.
# ----------------------------------------------------------------------------
# Build #36 (sccache enabled, LTO off) failed at 12m 23s with:
#
#   ninja: error:
#     '../../third_party/devtools-frontend/src/third_party/esbuild/esbuild',
#     needed by 'gen/.../core/common/common.prebundle.js',
#     missing and no known rule to make it
#
# Why it's missing:
#   Chromium's DevTools front-end uses esbuild as its JS bundler — it
#   pre-bundles ESM modules into single files for faster load. Upstream
#   gclient fetches a pinned esbuild binary into
#   `third_party/devtools-frontend/src/third_party/esbuild/esbuild`.
#   ungoogled-chromium's prune pass strips ALL Google-hosted prebuilt
#   binaries, including esbuild, so the file is gone after our checkout.
#
# Why we hit this NOW (and not in earlier runs):
#   Build #34 used is_official_build=true which routed JS bundling through
#   a different rollup-based pipeline. Build #36 added is_official_build=false
#   (so sccache could actually cache .o files instead of LTO IR) — and that
#   flip made DevTools' BUILD.gn switch to the esbuild bundling target,
#   exposing the missing binary.
#
# Fix (same pattern as dsymutil / llvm-otool / etc):
#   1. Install the npm `esbuild` package into a tmp dir; npm fetches the
#      platform-specific binary via the @esbuild/darwin-arm64 optional dep.
#   2. Copy the binary into the expected literal path so ninja's static
#      missing-file check passes and the bundling action can run.
#
# Notes for the novice reader:
#   - `npm install --prefix /tmp/esbuild-stage` puts node_modules in that
#     dir without polluting the build tree's package.json (we don't have one).
#   - `--no-audit --no-fund --silent` keeps CI logs short.
#   - On Apple Silicon the binary lands at:
#       node_modules/@esbuild/darwin-arm64/bin/esbuild
#     On Intel macs it would be node_modules/@esbuild/darwin-x64/bin/esbuild
#     — we detect arch with `uname -m` for portability.
#   - We pin esbuild to 0.21.x (stable, ABI-compatible with what Chromium
#     146's DEPS file pinned). Latest also works but pinning avoids surprise
#     CLI flag changes between npm releases.
# ----------------------------------------------------------------------------
log_step "Staging esbuild binary for DevTools front-end bundler"
ESBUILD_DEST_REL="third_party/devtools-frontend/src/third_party/esbuild"
ESBUILD_DEST_ABS="$CLAUM_BUILD_ROOT/build/src/$ESBUILD_DEST_REL"
mkdir -p "$ESBUILD_DEST_ABS"
if [ ! -x "$ESBUILD_DEST_ABS/esbuild" ]; then
  # Detect macOS arch — npm picks the @esbuild/darwin-{arm64,x64} optional
  # dep based on the host, so the path varies. `uname -m` returns "arm64"
  # on Apple Silicon and "x86_64" on Intel.
  HOST_ARCH="$(uname -m)"
  case "$HOST_ARCH" in
    arm64)   ESBUILD_PKG="darwin-arm64" ;;
    x86_64)  ESBUILD_PKG="darwin-x64" ;;
    *)
      log_err "Unsupported host arch for esbuild staging: $HOST_ARCH"
      exit 1
      ;;
  esac

  # Install into a private tmp prefix so we never collide with anything in
  # the build tree. `--no-save` because there's no parent package.json,
  # `--silent --no-audit --no-fund` to keep CI logs tidy.
  ESBUILD_STAGE="$(mktemp -d -t esbuild-stage.XXXXXX)"
  echo "  installing esbuild@0.21 into $ESBUILD_STAGE"
  if ! npm install --prefix "$ESBUILD_STAGE" \
        --no-save --no-audit --no-fund --silent \
        esbuild@0.21 2>&1 | tail -20
  then
    log_err "npm install esbuild@0.21 failed — see lines above"
    exit 1
  fi

  ESBUILD_SRC="$ESBUILD_STAGE/node_modules/@esbuild/$ESBUILD_PKG/bin/esbuild"
  if [ ! -x "$ESBUILD_SRC" ]; then
    log_err "Expected esbuild binary not found after npm install"
    log_err "  Looked at: $ESBUILD_SRC"
    log_err "  Listing:"
    find "$ESBUILD_STAGE/node_modules/@esbuild" -type f 2>/dev/null | head -10
    exit 1
  fi

  install -m 0755 "$ESBUILD_SRC" "$ESBUILD_DEST_ABS/esbuild"
  echo "  staged esbuild -> $ESBUILD_DEST_REL/esbuild"
  echo "  (source: $ESBUILD_SRC, version: $("$ESBUILD_DEST_ABS/esbuild" --version 2>/dev/null || echo unknown))"

  # Clean up the staging dir — the binary is now copied into the build tree,
  # we don't need the npm install dir anymore. `|| true` so a failed cleanup
  # doesn't fail the whole script.
  rm -rf "$ESBUILD_STAGE" || true
else
  echo "  esbuild already present at $ESBUILD_DEST_REL/esbuild"
fi

# -------- [6/6] gn gen + ninja --------------------------------------------
log_step "[6/6] Running gn gen and ninja"
cd "$CLAUM_BUILD_ROOT/build/src"

OUT_DIR="out/Claum"
if [ "$CLEAN" -eq 1 ] && [ -d "$OUT_DIR" ]; then
  log_warn "Removing previous build output ($OUT_DIR)"
  rm -rf "$OUT_DIR"
fi

# ----------------------------------------------------------------------------
# Locate Homebrew's jpeg-turbo include/lib dirs so we can hand them to GN.
# ----------------------------------------------------------------------------
# We ask Homebrew for the install prefix rather than hard-coding /opt/homebrew
# because:
#   - Apple Silicon runners use /opt/homebrew
#   - Intel runners use /usr/local
#   - A user-local Homebrew install could live anywhere
# `brew --prefix jpeg-turbo` returns the canonical path or an empty string if
# the formula isn't installed. The workflow's "Install build dependencies"
# step runs `brew install jpeg-turbo`, so by the time this script runs the
# prefix WILL exist — we still guard with `|| true` so a missing brew doesn't
# nuke the whole script on a dev machine.
# Run #28 failed at [1037/56129] with:
#     fatal error: 'jpeglib.h' file not found
# in third_party/libyuv/source/mjpeg_decoder.cc because use_system_libjpeg=true
# tells Chromium to do `#include "jpeglib.h"` from a SYSTEM include path, and
# macOS doesn't ship jpeglib.h. Feeding Chromium's cflags the Homebrew
# include dir fixes that resolution without abandoning system libjpeg.
JPEG_TURBO_PREFIX="$(brew --prefix jpeg-turbo 2>/dev/null || true)"
if [ -n "$JPEG_TURBO_PREFIX" ] && [ -d "$JPEG_TURBO_PREFIX/include" ]; then
  # ---------------------------------------------------------------------
  # Run #100 fix (chromium-rawptr plugin firing on jpeg-turbo headers):
  #
  # Run #100 failed at ninja [50369/55953] (~90% done) compiling
  # third_party/pdfium/core/fxcodec/jpeg/jpeg_common.c.  The error was
  # NOT a missing-header or link error this time -- it was the Chromium
  # `find-bad-constructs` clang plugin (with the `check-raw-ptr`
  # sub-check) emitting:
  #     /opt/homebrew/opt/jpeg-turbo/include/jpeglib.h:226:15: error:
  #       [chromium-rawptr] Use raw_ptr<T> instead of a raw pointer.
  # ...20+ times for fields like `JQUANT_TBL *quant_table;` inside the
  # external libjpeg-turbo header.
  #
  # Why the plugin was firing on a third-party system header:
  #   The plugin skips files whose `SourceManager::isInSystemHeader()`
  #   returns true. A header counts as "system" only when the compiler
  #   found it via a SYSTEM include search path (`-isystem`,
  #   `-cxx-isystem`, `--system-header-prefix=`, the SDK sysroot, etc.).
  #   We were adding the Homebrew jpeg-turbo include dir with `-I`,
  #   which is a NORMAL include path -- so the plugin treated jpeglib.h
  #   as first-party Chromium code and enforced raw_ptr<T> on it.
  #
  # Fix: switch from `-I<dir>` to `-isystem<dir>`. Clang accepts the
  # joined form `-isystem<path>` (option spec is `JoinedOrSeparate`),
  # so this is still ONE token and survives whatever tokenization GN
  # does with extra_cflags. Once jpeglib.h is found via a system search
  # path, isInSystemHeader() returns true and the rawptr plugin (and
  # any other Chromium clang plugin warnings) skip the header entirely.
  # Resolution still works the same -- system dirs are searched after
  # `-I` dirs, and these jpeg headers don't exist anywhere else, so the
  # search-order change has no effect on what gets included.
  # ---------------------------------------------------------------------
  JPEG_INC_FLAG="-isystem$JPEG_TURBO_PREFIX/include"
  JPEG_LIB_FLAG="-L$JPEG_TURBO_PREFIX/lib"
  echo "  jpeg-turbo prefix: $JPEG_TURBO_PREFIX"

  # ---------------------------------------------------------------------
  # Run #29 fix: extra_cflags in GN does NOT propagate to every target.
  # Specifically, third_party/libyuv strips extra_cflags from its compile
  # commands, so `#include <jpeglib.h>` in mjpeg_decoder.cc still fails
  # even though we set extra_cflags=-I/opt/homebrew/opt/jpeg-turbo/include.
  #
  # Belt-and-suspenders fix: set CPATH / LIBRARY_PATH env vars, which
  # clang honors as implicit include / library search paths for ALL
  # compilations (ninja inherits them from the parent shell). Also
  # symlink the header directly into /opt/homebrew/include, which is
  # on clang's default Homebrew-aware search list on Apple Silicon.
  # ---------------------------------------------------------------------
  export CPATH="${CPATH:+$CPATH:}$JPEG_TURBO_PREFIX/include"
  export LIBRARY_PATH="${LIBRARY_PATH:+$LIBRARY_PATH:}$JPEG_TURBO_PREFIX/lib"
  echo "  exported CPATH=$CPATH"
  echo "  exported LIBRARY_PATH=$LIBRARY_PATH"

  # Also drop a symlink/copy of jpeglib.h (and its siblings) into a path
  # that IS inside the Chromium source tree — specifically the libyuv
  # include dir, which libyuv's BUILD.gn already adds via -I. That way
  # the header is guaranteed reachable even if env vars get scrubbed by
  # a sandbox or gn toolchain config.
  LIBYUV_INC_DIR="$CLAUM_BUILD_ROOT/build/src/third_party/libyuv/include"
  if [ -d "$LIBYUV_INC_DIR" ]; then
    for h in jpeglib.h jmorecfg.h jconfig.h jerror.h jpegint.h; do
      if [ -f "$JPEG_TURBO_PREFIX/include/$h" ] && [ ! -e "$LIBYUV_INC_DIR/$h" ]; then
        cp "$JPEG_TURBO_PREFIX/include/$h" "$LIBYUV_INC_DIR/$h"
        echo "  copied $h -> third_party/libyuv/include/"
      fi
    done
  fi

  # ---------------------------------------------------------------------
  # Run #63 fix: stage jpeg-turbo dylibs with a lowered LC_BUILD_VERSION.
  #
  # Why: Homebrew on macOS Tahoe (26) ships dylibs whose Mach-O
  # LC_BUILD_VERSION command says "built for macOS 26.0". When ld
  # links Chromium (which targets macOS 12.0) against such a dylib
  # it prints a warning of the form:
  #     warning: 'libjpeg.dylib' has version 26.0.0, which is newer
  #     than target minimum of 12.0.0
  # The Chromium link step uses `-Wl,-fatal_warnings`, so that
  # warning aborts the link with exit code 1 (this is what killed
  # run #63 at the chrome_framework link step).
  #
  # Fix: copy the dylibs into a build-local staging directory and
  # rewrite their LC_BUILD_VERSION to macOS 12.0 with `vtool` (ships
  # with Xcode CLT). Then point -L (and LIBRARY_PATH) at the staged
  # dir instead of the Homebrew dir. The patched dylibs keep their
  # original install_name (LC_ID_DYLIB), so at RUNTIME the chrome_
  # framework binary still loads the real Homebrew dylib via that
  # absolute path — only the link-time metadata is lowered.
  # ---------------------------------------------------------------------
  JPEG_STAGE_DIR="$CLAUM_BUILD_ROOT/build/jpeg-turbo-staged/lib"
  mkdir -p "$JPEG_STAGE_DIR"
  if command -v vtool >/dev/null 2>&1; then
    # Copy preserving symlinks (-RP) so libjpeg.dylib -> libjpeg.0.dylib
    # relationships survive into the staging dir.
    cp -RP "$JPEG_TURBO_PREFIX"/lib/libjpeg*.dylib "$JPEG_STAGE_DIR"/ 2>/dev/null || true
    cp -RP "$JPEG_TURBO_PREFIX"/lib/libturbojpeg*.dylib "$JPEG_STAGE_DIR"/ 2>/dev/null || true
    # vtool only operates on real files, not symlinks. Find the real
    # dylibs (`-type f`) and rewrite each one's build version.
    for dylib in $(find "$JPEG_STAGE_DIR" -maxdepth 1 -type f -name '*.dylib'); do
      # Make the file writable in case Homebrew set it to 444.
      chmod u+w "$dylib"
      # `-set-build-version macos 12.0 12.0` writes minos=12.0, sdk=12.0.
      # `-replace` swaps in place rather than appending an extra
      # LC_BUILD_VERSION command.
      if vtool -set-build-version macos 12.0 12.0 -replace -output "$dylib" "$dylib" 2>/dev/null; then
        echo "  vtool: lowered LC_BUILD_VERSION to macOS 12.0 on $(basename "$dylib")"
      else
        log_warn "vtool failed on $dylib (continuing — link may warn)"
      fi
    done
    # Re-point the linker flags at the staged dir. CPATH stays on the
    # Homebrew include dir (headers don't carry build-version info).
    JPEG_LIB_FLAG="-L$JPEG_STAGE_DIR"
    export LIBRARY_PATH="$JPEG_STAGE_DIR${LIBRARY_PATH:+:$LIBRARY_PATH}"
    echo "  jpeg-turbo staged lib dir: $JPEG_STAGE_DIR"
    echo "  updated LIBRARY_PATH=$LIBRARY_PATH"
  else
    log_warn "vtool not found — link step may emit fatal version-mismatch warning if Homebrew dylibs target a newer macOS than $MAC_DEPLOY_TARGET (see run #63)"
  fi
else
  JPEG_INC_FLAG=""
  JPEG_LIB_FLAG=""
  log_warn "jpeg-turbo not found via brew — build WILL fail on mjpeg_decoder.cc"
fi

# GN args — these tune how the Chromium build system generates ninja files.
# Each one is explained because this is where most build mistakes happen.
#
# extra_cflags / extra_ldflags are appended to EVERY compile/link command,
# which is what we want because Chromium's libyuv target doesn't declare a
# direct dep on //third_party/libjpeg (ungoogled severed it). The extra
# include dir gets every TU that `#include`s jpeglib.h to resolve correctly.
# ----------------------------------------------------------------------------
# sccache hookup — if $CLAUM_USE_SCCACHE is set (CI does this), we pass
# `cc_wrapper = "sccache"` to gn so every clang++ invocation becomes
# `sccache clang++ ...`. sccache talks to a daemon that hits a content-
# addressable cache (GitHub Actions cache backend, 10 GB). On a re-run,
# 95% of .o files are cached and reappear in milliseconds — so even if the
# previous run was killed by the 5h30m timeout, the next run can pick up
# near-instantly and spend its budget on new work + the link phase.
#
# We also turn OFF LTO (is_official_build=false, use_thin_lto=false).
# LTO defers code-gen until link time, which busts per-file caching: the
# compile output is IR not a final .o, so cache hits are tiny and the link
# step still has to redo the whole-program work. For iterative CI builds
# we want cache-friendly; LTO can be re-enabled for release builds once we
# have a successful first build to warm the cache.
# ----------------------------------------------------------------------------
if [ -n "${CLAUM_USE_SCCACHE:-}" ] && command -v sccache >/dev/null 2>&1; then
  # ------------------------------------------------------------------
  # Health-check sccache BEFORE wiring it into the build.
  # ------------------------------------------------------------------
  # Build #37 caught this: when GitHub Actions' cache backend (Azure
  # storage) is unhealthy, sccache crashes during `--start-server`
  # because it can't read its stats blob:
  #
  #   sccache: error: Server startup failed: cache storage failed to
  #     read: Unexpected (permanent) at read => <h2>Our services
  #     aren't available right now</h2>...
  #
  # If sccache then becomes the cc_wrapper for every clang invocation,
  # EVERY .o build dies and we lose 8+ minutes per attempt. The cure
  # is worse than the disease in that case — fall back to direct clang.
  #
  # Strategy:
  #   1. Try `sccache --start-server`. If exit ≠ 0 → fall back.
  #   2. Try `sccache --show-stats`. If it fails or its output contains
  #      a "Server startup failed" / "services aren't available"
  #      message → fall back.
  #   3. Otherwise we're good — wire it in.
  # ------------------------------------------------------------------
  SCCACHE_OK=1
  SCCACHE_PROBE_LOG="$(mktemp)"
  if ! sccache --start-server >"$SCCACHE_PROBE_LOG" 2>&1; then
    log_warn "sccache --start-server exit ≠ 0:"
    sed 's/^/    /' "$SCCACHE_PROBE_LOG"
    SCCACHE_OK=0
  fi
  if [ "$SCCACHE_OK" = "1" ]; then
    if ! sccache --show-stats >"$SCCACHE_PROBE_LOG" 2>&1; then
      log_warn "sccache --show-stats failed:"
      sed 's/^/    /' "$SCCACHE_PROBE_LOG"
      SCCACHE_OK=0
    elif grep -qE "Server startup failed|services aren't available|cache storage failed" "$SCCACHE_PROBE_LOG"; then
      log_warn "sccache stats indicate backend outage:"
      sed 's/^/    /' "$SCCACHE_PROBE_LOG"
      SCCACHE_OK=0
    fi
  fi
  rm -f "$SCCACHE_PROBE_LOG"

  if [ "$SCCACHE_OK" = "1" ]; then
    # ---------------------------------------------------------------
    # Build #42's stats showed sccache only saw 12 compile requests
    # in 5h30m — meaning ninja's clang invocations were NOT going
    # through sccache. Two likely culprits, both fixed below:
    #
    #   1. cc_wrapper="sccache" relies on PATH lookup. Chromium's
    #      build sometimes runs subprocesses with a sanitised PATH
    #      that doesn't include $RUNNER_TOOL_CACHE/sccache/0.x/. Use
    #      the ABSOLUTE PATH so PATH state doesn't matter.
    #   2. cc_wrapper is only honored by the build when GN believes
    #      the compiler is clang. Chromium DOES default to clang on
    #      mac, but we set is_clang=true explicitly to guarantee it.
    #
    # Also: GN style guide canonicalises arg formatting as
    # `name = "value"` (with spaces). gn doesn't actually require
    # the spaces, but matching the style makes greppable diffs in
    # the build dir's args.gn file consistent.
    # ---------------------------------------------------------------
    SCCACHE_BIN="$(command -v sccache)"
    log_ok "sccache resolved to: $SCCACHE_BIN"
    log_ok "sccache version: $(sccache --version)"
    CC_WRAPPER_ARG="cc_wrapper = \"$SCCACHE_BIN\"
  is_clang = true"
    SCCACHE_LTO_OFF='is_official_build=false
    use_thin_lto=false'
  else
    log_warn "sccache health check failed — building WITHOUT cache wrapper."
    log_warn "  Subsequent ninja errors will be your real failures, not cache outages."
    CC_WRAPPER_ARG='is_clang = true'
    # Even with no sccache, keep is_official_build=false: LTO is still a
    # bad idea for our slow incremental retries (we'd lose the link
    # phase's whole work to any single source file change). The whole
    # point of this build is iteration speed, not release perf.
    SCCACHE_LTO_OFF='is_official_build=false
    use_thin_lto=false'
  fi
else
  CC_WRAPPER_ARG='is_clang = true'
  SCCACHE_LTO_OFF='is_official_build=true             # enable optimizations + LTO'
fi

GN_ARGS="
  is_debug=false                     # release build (no debug symbols)
  $SCCACHE_LTO_OFF
  $CC_WRAPPER_ARG
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
  clang_use_chrome_plugins=false     # disable chromium clang plugin: it raises chromium-rawptr errors against /opt/homebrew/.../jpeglib.h (a system header we did not write); see BUILD_NOTES cycle 20 for the cliff fingerprint
  extra_cflags=\"$JPEG_INC_FLAG\"
  extra_cxxflags=\"$JPEG_INC_FLAG\"
  extra_ldflags=\"$JPEG_LIB_FLAG\"
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
# Fix #2 — components/safe_browsing/{password_protection,content/browser}/BUILD.gn
# ---------------------------------------------------------------------------
# Runs #64 and #65 failed at ninja [44760/55997] when CXX-compiling
# password_protection_service_base.cc and client_side_detection_service.cc.
# Those .cc files reference identifiers (PHISHING_REUSE,
# IsEnhancedProtectionEnabled, prefs::kSafeBrowsingEnabled, etc.) that
# ungoogled-chromium's 0001-fix-building-without-safebrowsing.patch strips
# from the matching headers without removing the .cc files from sources.
#
# This script comments out the offending .cc files so ninja stops trying
# to compile them. Idempotent — safe to re-run on re-extraction.
# See claum/scripts/fix-safe-browsing-components-gn.py for the full
# write-up + reasoning of why we do source removal instead of an
# `if (safe_browsing_mode != 0)` wrap.
# ---------------------------------------------------------------------------
log_step "Fixing components/safe_browsing/*/BUILD.gn (Path A — drop dangling .cc)"
python3 "$CLAUM_REPO_DIR/claum/scripts/fix-safe-browsing-components-gn.py" \
        "$CLAUM_BUILD_ROOT/build/src"

# ---------------------------------------------------------------------------
# Fix #3 — stage a stub `components/safe_browsing/core/common/safe_browsing_prefs.h`
# (run #119 fix — cycle 28 BUILD_NOTES; the cliff fingerprint that cycles 26+27
# verified via the raw-logs endpoint at ninja [51391/55953] CXX
# obj/chrome/browser/ui/ui/downloads_list_tracker.o).
# ---------------------------------------------------------------------------
# Background: ungoogled-chromium's safe_browsing patch *deletes* the upstream
# header `components/safe_browsing/core/common/safe_browsing_prefs.h` rather
# than just emptying it. Most consumers of that header live inside
# `components/safe_browsing/` and `chrome/browser/safe_browsing/` and were
# already neutralized by `fix-safe-browsing-components-gn.py` (Path A — drop
# the dangling `.cc` from BUILD.gn).
#
# `chrome/browser/ui/webui/downloads/downloads_list_tracker.cc` is the one
# *real-use* consumer that survives in the ungoogled tree: it backs the
# `chrome://downloads/` page, so dropping it from BUILD.gn would break the
# Downloads UI for end users. Path A doesn't apply.
#
# Looking at the upstream source (chromium/main @ time of writing), the file
# only references safe_browsing_prefs.h symbols inside a
# `#if BUILDFLAG(SAFE_BROWSING_DOWNLOAD_PROTECTION)` gate, and the only
# symbols it actually uses are:
#   * `safe_browsing::SafeBrowsingState` (enum with NO_SAFE_BROWSING,
#     STANDARD_PROTECTION, ENHANCED_PROTECTION)
#   * `safe_browsing::GetSafeBrowsingState(const PrefService&)` returning that enum
#
# So Path B (header stub) is both correct *and* minimal: write a tiny header
# at the upstream path that declares just those symbols, returning
# NO_SAFE_BROWSING from the inline helper. That is the right semantic for
# ungoogled-chromium where safe-browsing is disabled — the Downloads UI will
# render rows with "no safe-browsing verdict" instead of crashing the build.
#
# We also include a couple of common pref-name constants (kSafeBrowsingEnabled
# etc.) declared as `inline constexpr` so any *other* TU that survived the
# ungoogled patch and references them through this header still links. Using
# `inline constexpr` rather than `extern const char[]` means we do not need a
# matching .cc to define them — the value lives in the header.
#
# This step is idempotent (we overwrite the file every run), and only writes
# if the parent dir exists (which it should, since the upstream tree always
# has `components/safe_browsing/core/common/`). On a fresh extraction the
# patch will have removed any prior stub, so we always re-stage.
# ---------------------------------------------------------------------------
log_step "Staging stub safe_browsing_prefs.h (run #119 fix — Path B for downloads_list_tracker.cc)"
SB_PREFS_DIR="$CLAUM_BUILD_ROOT/build/src/components/safe_browsing/core/common"
SB_PREFS_FILE="$SB_PREFS_DIR/safe_browsing_prefs.h"
if [ -d "$SB_PREFS_DIR" ]; then
  # `cat <<'EOF' > "$file"` writes everything between the EOF markers verbatim
  # (the single quotes around 'EOF' disable shell interpolation, so $foo and
  # backticks inside the heredoc are written as literals — important here
  # because the C++ stub itself contains no shell variables).
  cat <<'EOF' > "$SB_PREFS_FILE"
// Copyright 2024 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// CLAUM STUB (re-staged by claum/scripts/build-mac.sh on every build).
//
// ungoogled-chromium's safe_browsing patch deletes the upstream
// safe_browsing_prefs.h. Most TUs that depended on it are dropped from
// BUILD.gn by claum/scripts/fix-safe-browsing-components-gn.py (Path A).
// chrome/browser/ui/webui/downloads/downloads_list_tracker.cc is the one
// real-use consumer that has to keep compiling, because it backs
// chrome://downloads/. This stub provides the minimum surface that file
// needs: the SafeBrowsingState enum and a GetSafeBrowsingState() that
// always returns NO_SAFE_BROWSING (which is the correct semantic when
// safe browsing is disabled).
//
// Common pref-name constants are also exposed as inline constexpr so that
// any sibling TU still pulling them in through this header continues to
// link without us having to ship a matching .cc.

#ifndef COMPONENTS_SAFE_BROWSING_CORE_COMMON_SAFE_BROWSING_PREFS_H_
#define COMPONENTS_SAFE_BROWSING_CORE_COMMON_SAFE_BROWSING_PREFS_H_

// Cycle-36 additions: <string> + <vector> are needed for the
// GetURLAllowlistByPolicy() return type (std::vector<std::string>).
#include <string>
#include <vector>

// Forward-declare PrefService so callers that pass `*profile->GetPrefs()`
// continue to type-check without us pulling in the full prefs header.
class PrefService;
// GURL is used as a parameter type by IsURLAllowlistedByPolicy(); a forward
// declaration is enough because we never deref a GURL inside this stub.
class GURL;

namespace safe_browsing {

// The three protection levels Chromium normally exposes. We keep the
// numeric values stable so any third-party header that references them
// by integer keeps working.
enum SafeBrowsingState {
  NO_SAFE_BROWSING = 0,
  STANDARD_PROTECTION = 1,
  ENHANCED_PROTECTION = 2,
};

// Always report "off" — that is the correct answer for an ungoogled build.
// `inline` lets multiple TUs include this header without ODR violations.
inline SafeBrowsingState GetSafeBrowsingState(const PrefService& /*prefs*/) {
  return NO_SAFE_BROWSING;
}

// Helper predicates that mirror upstream's API surface. Each is a no-op
// for ungoogled (safe browsing is disabled), so they all return false.
inline bool IsSafeBrowsingEnabled(const PrefService& /*prefs*/) {
  return false;
}
inline bool IsEnhancedProtectionEnabled(const PrefService& /*prefs*/) {
  return false;
}
inline bool IsExtendedReportingEnabled(const PrefService& /*prefs*/) {
  return false;
}
inline bool IsExtendedReportingPolicyManaged(const PrefService& /*prefs*/) {
  return false;
}

// --- Cycle-36 additions ---------------------------------------------------
// Two more pref-helpers referenced by chrome_content_browser_client*.cc.
// Upstream signatures (chromium tag 146.0.7680.164,
// components/safe_browsing/core/common/safe_browsing_prefs.h):
//   bool IsURLAllowlistedByPolicy(const GURL& url, const PrefService& pref);
//   std::vector<std::string> GetURLAllowlistByPolicy(PrefService* pref_service);
// In an ungoogled build, no URLs are policy-allowlisted, so we return false
// and an empty list respectively — same "safe defaults" semantic as the
// other helpers above.
inline bool IsURLAllowlistedByPolicy(const GURL& /*url*/,
                                     const PrefService& /*pref*/) {
  return false;
}
inline std::vector<std::string> GetURLAllowlistByPolicy(
    PrefService* /*pref_service*/) {
  return {};
}

// (cycle-38 fix) The cycle-36 stub `class DownloadFileType` block that
// used to live here was REMOVED because it caused a redefinition error
// (run #121, downloads_list_tracker.cc):
//   error: redefinition of 'DownloadFileType'
//   note:  previous definition is here →
//          gen/components/safe_browsing/content/common/proto/
//          download_file_types.pb.h:461
// In other words: the proto-generated DownloadFileType IS present in the
// build tree and is reachable transitively, so we don't need (and must
// not provide) our own stub. chrome_download_manager_delegate.cc keeps
// using `safe_browsing::DownloadFileType` from the proto header.

}  // namespace safe_browsing

namespace prefs {

// Common pref-name constants exposed by upstream's safe_browsing_prefs.h.
// `inline constexpr char[]` (C++17) gives them external linkage without
// needing a matching translation unit to define storage.
inline constexpr char kSafeBrowsingEnabled[] = "safebrowsing.enabled";
inline constexpr char kSafeBrowsingEnhanced[] = "safebrowsing.enhanced";
inline constexpr char kSafeBrowsingScoutReportingEnabled[] =
    "safebrowsing.scout_reporting_enabled";
inline constexpr char kSafeBrowsingExtendedReportingOptInAllowed[] =
    "safebrowsing.extended_reporting_opt_in_allowed";
inline constexpr char kSafeBrowsingProceedAnywayDisabled[] =
    "safebrowsing.proceed_anyway_disabled";
inline constexpr char kSafeBrowsingIncidentsSent[] =
    "safebrowsing.incidents_sent";
inline constexpr char kSafeBrowsingTriggerEventTimestamps[] =
    "safebrowsing.trigger_event_timestamps";
inline constexpr char kSafeBrowsingUnhandledGaiaPasswordReuses[] =
    "safebrowsing.unhandled_gaia_password_reuses";

}  // namespace prefs

#endif  // COMPONENTS_SAFE_BROWSING_CORE_COMMON_SAFE_BROWSING_PREFS_H_
EOF
  echo "  staged stub at $SB_PREFS_FILE ($(wc -l < "$SB_PREFS_FILE") lines)"
else
  log_warn "  parent dir $SB_PREFS_DIR not present — skipping stub stage"
fi

# ---------------------------------------------------------------------------
# Cycle-36 fix #4 — inject #include of our stub safe_browsing_prefs.h into
# the three cc files identified by cycle-32 diagnostic that use safe_browsing
# symbols (IsURLAllowlistedByPolicy / GetURLAllowlistByPolicy /
# IsSafeBrowsingEnabled / DownloadFileType) but no longer #include the
# header after ungoogled-chromium's safe_browsing patch. The cycle-28 stub
# satisfies downloads_list_tracker.cc (which kept its #include); these
# 3 cc files lost the include and need it injected here.
#
# Idempotent — guarded by `grep -q` so re-runs do nothing on already-patched
# files. Insertion is right after the LAST existing #include line so we
# never break a file's preprocessor block ordering.
# ---------------------------------------------------------------------------
log_step "Injecting #include safe_browsing_prefs.h into 3 cc files (cycle-36 fix)"
SB_INC='#include "components/safe_browsing/core/common/safe_browsing_prefs.h"'
SRC_ROOT="$CLAUM_BUILD_ROOT/build/src"
for rel in \
  chrome/browser/chrome_content_browser_client_receiver_bindings.cc \
  chrome/browser/download/chrome_download_manager_delegate.cc \
  chrome/browser/chrome_content_browser_client.cc; do
  fp="$SRC_ROOT/$rel"
  if [ ! -f "$fp" ]; then
    log_warn "  $rel not found — skipping (file may be patched out by ungoogled)"
    continue
  fi
  if grep -qF "$SB_INC" "$fp"; then
    echo "  $rel: include already present, skipping"
    continue
  fi
  # awk inserts $inc right after the LAST line that begins with `#include`.
  # The 2-pass approach (first pass finds the line; second pass writes) is
  # required because we don't know where the last #include is until we've
  # scanned the whole file.
  awk -v inc="$SB_INC" '
    NR == FNR { if (/^#include/) last = NR; next }
    { print; if (FNR == last) print inc }
  ' "$fp" "$fp" > "$fp.cycle36.tmp"
  if [ -s "$fp.cycle36.tmp" ]; then
    mv "$fp.cycle36.tmp" "$fp"
    echo "  $rel: injected include after the last existing #include"
  else
    rm -f "$fp.cycle36.tmp"
    log_warn "  $rel: awk produced empty output, skipping (no edit applied)"
  fi
done

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

# ---------------------------------------------------------------------------
# claum-watcher: dump component safe_browsing BUILD.gn (run #66 instrumentation)
# ---------------------------------------------------------------------------
# Background — runs #64 and #65 both failed at ninja [44760/55997] with
# `password_protection_service_base.cc` and `client_side_detection_service.cc`
# referencing identifiers (`IsEnhancedProtectionEnabled`, `PHISHING_REUSE`,
# `kSafeBrowsingEnabled`, etc.) that were stripped by ungoogled-chromium's
# `0001-fix-building-without-safebrowsing.patch`. The previous watcher
# proposed wrapping the .cc files in `if (safe_browsing_mode != 0)`, but
# the latest diagnostic shows safe_browsing_mode != 0 is ALREADY true in
# this build (these CXX commands ran), so that guard would be a no-op.
#
# To write the right fix we need to see the actual structure of the
# component BUILD.gn files that own these .o targets. The .o paths are:
#   obj/components/safe_browsing/core/browser/password_protection/password_protection/password_protection_service_base.o
#   obj/components/safe_browsing/content/browser/client_side_detection_service/client_side_detection_service.o
# ninja's path convention is obj/<dir>/<target_name>/<source>.o, so the
# owning BUILD.gn files are:
#   components/safe_browsing/core/browser/password_protection/BUILD.gn
#   components/safe_browsing/content/browser/BUILD.gn
# and the GN target names are `password_protection` and
# `client_side_detection_service` respectively.
#
# This diagnostic does not modify the build; it just prints the BUILD.gn
# structure to the workflow log so the next watcher cycle can write a
# precise targeted fix.
# ---------------------------------------------------------------------------
log_step "Diagnostic D: dump component safe_browsing BUILD.gn files (run #66)"

dump_build_gn() {
  # Args: $1 = absolute path to BUILD.gn, $2 = source filename to grep for
  local f="$1"
  local needle="$2"
  if [ ! -f "$f" ]; then
    log_warn "  (file not found: $f)"
    return 0
  fi
  local total
  total=$(wc -l < "$f")
  echo "  $f has $total lines"
  echo "  ---- head (first 40 lines) ----"
  cat -n "$f" | sed -n '1,40p' || true
  echo "  ---- end head ----"
  echo "  ---- context around mentions of $needle (5 lines before/after) ----"
  # `grep -n -B 5 -A 5` prints the matching line with 5 lines of context on
  # either side. The `|| true` swallows grep's exit-1 when there are no
  # matches so we never fail the build from the diagnostic.
  grep -n -B 5 -A 5 "$needle" "$f" || true
  echo "  ---- end context ----"
  echo "  ---- search for any 'sources' assignments (line numbers only) ----"
  grep -n -E '^\s*sources\s*[=+]\s*\[' "$f" || true
  echo "  ---- end sources search ----"
}

PP_BUILD="$CLAUM_BUILD_ROOT/build/src/components/safe_browsing/core/browser/password_protection/BUILD.gn"
CSDS_BUILD="$CLAUM_BUILD_ROOT/build/src/components/safe_browsing/content/browser/BUILD.gn"

echo "==> Diagnostic D-1: password_protection BUILD.gn"
dump_build_gn "$PP_BUILD" "password_protection_service_base.cc"
echo "---- end diagnostic D-1 ----"

echo "==> Diagnostic D-2: content/browser/safe_browsing BUILD.gn"
dump_build_gn "$CSDS_BUILD" "client_side_detection_service.cc"
echo "---- end diagnostic D-2 ----"


gn gen "$OUT_DIR" --args="$GN_ARGS"

# Build the main browser target.
NUM_JOBS="${NUM_JOBS:-$(sysctl -n hw.logicalcpu)}"
log_ok "Starting ninja with $NUM_JOBS parallel jobs"

# ----------------------------------------------------------------------------
# Self-diagnosing ninja wrapper (added 2026-04-29 — runs #53–#62 wedge fix).
# ----------------------------------------------------------------------------
# Background: runs #53–#62 all failed with "Process completed with exit code 1"
# and NO recognizable error string anywhere in the GitHub Actions log UI.
# That's because GitHub's React log virtualizer renders only ~4,700 DOM lines,
# but ninja's output for a Chromium build spans ~45,000+ lines, so the actual
# failure is invisible unless someone downloads the raw log blob.
#
# This wrapper does three things:
#   1. Runs ninja and tees its combined stdout+stderr to $BUILD_LOG_FILE.
#   2. Captures ninja's true exit code via PIPESTATUS (otherwise `tee`
#      would mask it because it always returns 0).
#   3. On non-zero exit, prints a banner + the last 200 lines of the log
#      AND any lines containing classic error markers (FAILED:, error:,
#      fatal error, ninja: error, undefined symbol). Both dumps land at the
#      very end of step 12's stdout, which IS rendered by the GitHub UI
#      (the virtualizer always renders the tail of a long log).
#
# Once we can see the failure here, we can write a real fix.
# ----------------------------------------------------------------------------

# Where to put the log. $CLAUM_BUILD_ROOT is set up earlier in this script
# (defaults to ~/claum-build) and is also uploaded as a GitHub Actions
# artifact on failure (see .github/workflows/build-mac.yml).
BUILD_LOG_FILE="$CLAUM_BUILD_ROOT/build.log"
mkdir -p "$(dirname "$BUILD_LOG_FILE")"
# Truncate any stale log from a previous run so we don't dump the wrong tail.
: > "$BUILD_LOG_FILE"

# Temporarily disable `set -e` so we can capture ninja's exit code instead
# of letting bash bail immediately. We restore it right after.
set +e
# 2>&1 merges stderr into stdout so a single tee captures both streams.
# `tee -a` appends so any lines printed to BUILD_LOG_FILE earlier are kept.
ninja -C "$OUT_DIR" -j "$NUM_JOBS" chrome 2>&1 | tee -a "$BUILD_LOG_FILE"
# PIPESTATUS is a bash-only array of every command's exit code in the pipe.
# [0] is `ninja`, [1] is `tee`. We want ninja's, not tee's (which is always 0).
NINJA_EXIT="${PIPESTATUS[0]}"
set -e

if [ "$NINJA_EXIT" -ne 0 ]; then
  # Big banner so it's easy to spot in the GHA log even when scanning quickly.
  echo ""
  echo "================================================================"
  echo "  CLAUM BUILD: ninja failed with exit code $NINJA_EXIT"
  echo "  Dumping the last 200 lines of build.log + grepped error markers"
  echo "  Full log path on the runner: $BUILD_LOG_FILE"
  echo "  (also uploaded as the 'build-log' workflow artifact)"
  echo "================================================================"
  echo ""

  echo "---- error-marker lines (grep) ----"
  # `|| true` so grep returning 1 (no matches) doesn't kill the script.
  grep -nE "FAILED:|fatal error|ninja: error|undefined symbol|error: "     "$BUILD_LOG_FILE" | tail -50 || true
  echo "---- end error-marker lines ----"
  echo ""

  echo "---- last 200 lines of build.log ----"
  tail -200 "$BUILD_LOG_FILE" || true
  echo "---- end last 200 lines ----"

  # Re-raise the original failure so the GitHub Actions step is still red.
  exit "$NINJA_EXIT"
fi

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

# Build kick (run #101): re-trigger build-mac after [skip ci] swallowed the prior push.

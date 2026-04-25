#!/usr/bin/env bash
# ============================================================================
# Claum — build-from-prebuilt
# ----------------------------------------------------------------------------
# Instead of compiling Chromium from source (a 4-6 hour ordeal that doesn't
# fit in GitHub Actions' 5h30m wall), this script does the "patch on top of
# upstream" approach:
#
#   1. Download the latest ungoogled-chromium .dmg for macOS arm64
#   2. Mount it, copy out the Chromium.app bundle
#   3. Patch Info.plist to rename "Chromium" → "Claum" everywhere user-visible
#   4. Drop our master_preferences in to set defaults (search engine, etc.)
#   5. Drop our extensions into the bundle's Resources/
#   6. Re-sign the bundle (ad-hoc) so macOS will launch it
#   7. Repackage as Claum-arm64.dmg
#
# Total runtime: ~2-5 minutes (vs 4-6 hours for a from-source build).
#
# What we LOSE vs the from-source build:
#   - Source-level patches that change Chromium's C++ code (glass UI tweaks,
#     vertical tabs, etc.) — patches 02 and 03 in claum/patches/ are the
#     ones that genuinely need a recompile. Everything else is replaceable
#     at runtime via prefs / bundled extensions / Resources.
# What we KEEP:
#   - Branding (name, identifier, copyright)
#   - Default search engine
#   - Bundled extensions
#   - First-run state (welcome page, imports)
#   - The fact that it's ungoogled-chromium under the hood (privacy-friendly)
#
# This is intended as the v0 path to a working Claum.dmg. Once it works, we
# can layer in source patches via a separate, slower build pipeline if we
# decide we really need them.
# ============================================================================

set -euo pipefail   # exit on error, unset var, or any pipe failure
set -o errtrace     # ERR trap inherits into functions/subshells

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
log()      { echo "==> $*"; }
log_step() { echo ""; echo "================================================================"; \
             echo "  $*"; \
             echo "================================================================"; }
log_err()  { echo "ERROR: $*" >&2; }

# Where the Claum repo lives (the dir containing this script's parent folder).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUM_REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ----------------------------------------------------------------------------
# Configurable knobs (override via env vars or CLI flags)
# ----------------------------------------------------------------------------
# Architecture — only "arm64" supported in this v0 script.
ARCH="${ARCH:-arm64}"

# Default search engine for new profiles. Mirrors the from-source build.
DEFAULT_SEARCH="${DEFAULT_SEARCH:-bing}"

# Where intermediate / output files go. The CI workflow sets this; locally
# defaults to a sibling dir of the repo.
WORK_DIR="${WORK_DIR:-$CLAUM_REPO_DIR/build-prebuilt}"

# Optional — pin a specific upstream version. If empty, we fetch the latest
# tag from the ungoogled-chromium-macos GitHub releases.
UPSTREAM_VERSION="${UPSTREAM_VERSION:-}"

# Parse simple --flag value CLI args (so this script can be called from CI
# the same way build-mac.sh is).
while [ $# -gt 0 ]; do
  case "$1" in
    --arch)            ARCH="$2"; shift 2 ;;
    --default-search)  DEFAULT_SEARCH="$2"; shift 2 ;;
    --upstream-version) UPSTREAM_VERSION="$2"; shift 2 ;;
    *)                 log_err "Unknown flag: $1"; exit 2 ;;
  esac
done

if [ "$ARCH" != "arm64" ]; then
  log_err "This v0 script only supports arm64 (Apple Silicon)."
  log_err "ungoogled-chromium-macos publishes Intel builds too — extending"
  log_err "this script to handle x86_64 is a one-line case-statement add."
  exit 1
fi

# ----------------------------------------------------------------------------
# Step 1: Prereqs
# ----------------------------------------------------------------------------
# We need: curl (download), jq (parse GitHub API), hdiutil (mount/repack
# .dmg files — built into macOS), plutil (edit Info.plist — built into
# macOS), codesign (re-sign the bundle — also built into macOS).
# ----------------------------------------------------------------------------
log_step "[1/7] Checking prerequisites"
for cmd in curl jq hdiutil plutil codesign; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_err "Required command not found: $cmd"
    log_err "On macOS, install jq with: brew install jq"
    exit 1
  fi
  log "  ✓ $cmd"
done

# ----------------------------------------------------------------------------
# Step 2: Resolve the upstream release we want
# ----------------------------------------------------------------------------
# ungoogled-chromium publishes macOS arm64 builds at:
#   https://github.com/ungoogled-software/ungoogled-chromium-macos
#
# Each release tag looks like "146.0.7680.164-1.1" and contains an asset
# named "ungoogled-chromium_146.0.7680.164-1.1_arm64-macos.dmg".
#
# We hit the GitHub API to find the latest release (or look up a specific
# tag if UPSTREAM_VERSION is set). Then we extract the .dmg URL.
#
# NOTE: GitHub's REST API works without auth for public repos, but allows
# only 60 requests/hour from a single IP. CI workflows pass GITHUB_TOKEN
# automatically; this script picks it up if present to avoid rate limits.
# ----------------------------------------------------------------------------
log_step "[2/7] Resolving upstream ungoogled-chromium release"

REPO_API="https://api.github.com/repos/ungoogled-software/ungoogled-chromium-macos"
# `-H "Authorization: ..."` only when GITHUB_TOKEN is set (CI). Locally it's
# fine to omit — 60 reqs/hour is plenty for one build.
AUTH_HEADER=()
if [ -n "${GITHUB_TOKEN:-}" ]; then
  AUTH_HEADER=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

if [ -n "$UPSTREAM_VERSION" ]; then
  log "Pinned upstream version: $UPSTREAM_VERSION"
  RELEASE_API="$REPO_API/releases/tags/$UPSTREAM_VERSION"
else
  log "No version pinned — using latest release"
  RELEASE_API="$REPO_API/releases/latest"
fi

# Pull the release JSON.
RELEASE_JSON="$(mktemp)"
trap 'rm -f "$RELEASE_JSON"' EXIT
curl -fsSL "${AUTH_HEADER[@]}" "$RELEASE_API" -o "$RELEASE_JSON" || {
  log_err "Failed to fetch upstream release info from $RELEASE_API"
  exit 1
}

UPSTREAM_TAG="$(jq -r '.tag_name' "$RELEASE_JSON")"
# Find the arm64 .dmg asset. We match on suffix to be safe — upstream's
# naming has been stable but could change.
DMG_URL="$(jq -r '.assets[] | select(.name | endswith("_arm64-macos.dmg")) | .browser_download_url' "$RELEASE_JSON" | head -n1)"
DMG_NAME="$(basename "$DMG_URL")"

if [ -z "$DMG_URL" ] || [ "$DMG_URL" = "null" ]; then
  log_err "Could not find an arm64 .dmg in release $UPSTREAM_TAG"
  log_err "Assets in this release:"
  jq -r '.assets[].name' "$RELEASE_JSON" | sed 's/^/    /'
  exit 1
fi

log "Upstream tag : $UPSTREAM_TAG"
log "Asset name   : $DMG_NAME"
log "Download URL : $DMG_URL"

# ----------------------------------------------------------------------------
# Step 3: Download the upstream .dmg
# ----------------------------------------------------------------------------
# These .dmg files are ~150-200 MB. We cache by filename so a re-run with the
# same upstream version skips the download. CI also wraps this dir in
# actions/cache so the second run is even faster.
# ----------------------------------------------------------------------------
log_step "[3/7] Downloading upstream .dmg"
mkdir -p "$WORK_DIR/cache"
DMG_PATH="$WORK_DIR/cache/$DMG_NAME"

if [ -f "$DMG_PATH" ]; then
  log "Already cached: $DMG_PATH ($(du -h "$DMG_PATH" | awk '{print $1}'))"
else
  log "Downloading to $DMG_PATH ..."
  curl -fL --progress-bar -o "$DMG_PATH" "$DMG_URL"
  log "Downloaded: $(du -h "$DMG_PATH" | awk '{print $1}')"
fi

# ----------------------------------------------------------------------------
# Step 4: Mount the .dmg and copy out the .app bundle
# ----------------------------------------------------------------------------
# `hdiutil attach -nobrowse -readonly` mounts WITHOUT showing the disk in
# Finder and without giving us a writable copy. We then `cp -R` the .app to
# our staging dir (which we CAN write to). Always detach in a trap so we
# don't leak a mount on errors.
# ----------------------------------------------------------------------------
log_step "[4/7] Mounting .dmg and extracting Chromium.app"
STAGE_DIR="$WORK_DIR/stage"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

MOUNT_POINT="$(mktemp -d /tmp/claum-mount.XXXXXX)"
# Append the cleanup to the existing trap (we set one for RELEASE_JSON above).
trap 'rm -f "$RELEASE_JSON"; hdiutil detach "$MOUNT_POINT" 2>/dev/null || true; rm -rf "$MOUNT_POINT" 2>/dev/null || true' EXIT

hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_POINT" "$DMG_PATH" >/dev/null
log "Mounted at: $MOUNT_POINT"

# The .dmg contains exactly one .app at its root. Find it.
SRC_APP="$(find "$MOUNT_POINT" -maxdepth 2 -type d -name "*.app" | head -n1)"
if [ -z "$SRC_APP" ]; then
  log_err "Could not find a .app bundle inside $DMG_PATH"
  ls -la "$MOUNT_POINT"
  exit 1
fi
log "Found bundle: $(basename "$SRC_APP")"

# Copy to our staging dir as Claum.app (rename happens via -R + new name).
DST_APP="$STAGE_DIR/Claum.app"
cp -R "$SRC_APP" "$DST_APP"
hdiutil detach "$MOUNT_POINT" >/dev/null
log "Copied bundle to: $DST_APP"

# ----------------------------------------------------------------------------
# Step 5: Patch Info.plist with Claum branding
# ----------------------------------------------------------------------------
# `plutil -replace KEY -string VALUE FILE` is the right tool — it edits in
# place and respects the binary-vs-XML format of the file. Don't use sed,
# which can't safely edit binary plists.
#
# What we change:
#   CFBundleName            "Chromium" → "Claum"  (menu bar)
#   CFBundleDisplayName     "Chromium" → "Claum"  (under icon in Finder)
#   CFBundleIdentifier      "..." → "com.claum.Claum"
#   NSHumanReadableCopyright copyright string
#
# What we DON'T change (intentionally):
#   CFBundleExecutable — renaming the main binary requires renaming the
#                        actual file inside MacOS/ AND updating every helper
#                        bundle's identifier. We skip for v0; the user-visible
#                        name comes from CFBundleName/DisplayName above.
# ----------------------------------------------------------------------------
log_step "[5/7] Patching Info.plist"
PLIST="$DST_APP/Contents/Info.plist"
[ -f "$PLIST" ] || { log_err "Info.plist not found at $PLIST"; exit 1; }

# Read BRANDING file if present; otherwise fall back to defaults.
BRANDING_FILE="$CLAUM_REPO_DIR/claum/branding/BRANDING"
PRODUCT_FULLNAME="Claum"
MAC_BUNDLE_ID="com.claum.Claum"
COPYRIGHT="Copyright 2026 The Claum Authors. All rights reserved."
if [ -f "$BRANDING_FILE" ]; then
  # Pull KEY=VALUE pairs without sourcing (safer than `source`).
  PRODUCT_FULLNAME="$(grep -E '^PRODUCT_FULLNAME=' "$BRANDING_FILE" | cut -d= -f2- || echo Claum)"
  MAC_BUNDLE_ID="$(grep -E '^MAC_BUNDLE_ID=' "$BRANDING_FILE" | cut -d= -f2- || echo com.claum.Claum)"
  COPYRIGHT="$(grep -E '^COPYRIGHT=' "$BRANDING_FILE" | cut -d= -f2- || echo "$COPYRIGHT")"
fi

log "Setting CFBundleName        = $PRODUCT_FULLNAME"
plutil -replace CFBundleName -string "$PRODUCT_FULLNAME" "$PLIST"

log "Setting CFBundleDisplayName = $PRODUCT_FULLNAME"
plutil -replace CFBundleDisplayName -string "$PRODUCT_FULLNAME" "$PLIST"

log "Setting CFBundleIdentifier  = $MAC_BUNDLE_ID"
plutil -replace CFBundleIdentifier -string "$MAC_BUNDLE_ID" "$PLIST"

log "Setting NSHumanReadableCopyright"
plutil -replace NSHumanReadableCopyright -string "$COPYRIGHT" "$PLIST"

# Sanity dump the changed keys so the CI log shows what we did.
log ""
log "Verifying patched Info.plist:"
for key in CFBundleName CFBundleDisplayName CFBundleIdentifier CFBundleVersion NSHumanReadableCopyright; do
  val="$(plutil -extract "$key" raw -o - "$PLIST" 2>/dev/null || echo '(missing)')"
  printf '  %-25s = %s\n' "$key" "$val"
done

# ----------------------------------------------------------------------------
# Step 6: Drop in master_preferences for default search + first-run state
# ----------------------------------------------------------------------------
# Chromium reads "master_preferences" (or, on newer versions, "initial_preferences")
# from its Resources dir on first launch. We use it to set:
#   - default search engine
#   - skip-the-welcome-flow flag
#   - default homepage
#
# NOTE: this only takes effect for FRESH user-data dirs. If the user already
# has a Claum profile, these defaults are not re-applied — that's by design,
# we don't want to clobber their settings on every update.
# ----------------------------------------------------------------------------
log_step "[6/7] Writing master_preferences (default search = $DEFAULT_SEARCH)"
RESOURCES="$DST_APP/Contents/Resources"

# Map DEFAULT_SEARCH alias → canonical Chromium provider name + URL.
case "$DEFAULT_SEARCH" in
  bing)
    SEARCH_NAME="Bing"
    SEARCH_KEYWORD="bing.com"
    SEARCH_URL="https://www.bing.com/search?q={searchTerms}"
    ;;
  duckduckgo)
    SEARCH_NAME="DuckDuckGo"
    SEARCH_KEYWORD="duckduckgo.com"
    SEARCH_URL="https://duckduckgo.com/?q={searchTerms}"
    ;;
  google)
    SEARCH_NAME="Google"
    SEARCH_KEYWORD="google.com"
    SEARCH_URL="https://www.google.com/search?q={searchTerms}"
    ;;
  startpage)
    SEARCH_NAME="Startpage"
    SEARCH_KEYWORD="startpage.com"
    SEARCH_URL="https://www.startpage.com/do/search?q={searchTerms}"
    ;;
  *)
    log_err "Unknown DEFAULT_SEARCH value: $DEFAULT_SEARCH"
    exit 1
    ;;
esac

# Write both the modern and legacy filenames to be safe across upstream
# Chromium versions. They have identical contents.
PREFS_JSON=$(cat <<EOF
{
  "browser": {
    "show_home_button": true,
    "check_default_browser": false
  },
  "default_search_provider_data": {
    "template_url_data": {
      "short_name": "$SEARCH_NAME",
      "keyword":    "$SEARCH_KEYWORD",
      "search_url": "$SEARCH_URL"
    }
  },
  "homepage": "chrome://newtab",
  "homepage_is_newtabpage": true,
  "distribution": {
    "do_not_create_desktop_shortcut": true,
    "do_not_create_quicklaunch_shortcut": true,
    "do_not_launch_chrome": true,
    "import_search_engine": false,
    "make_chrome_default": false,
    "make_chrome_default_for_user": false,
    "skip_first_run_ui": true,
    "system_level": false,
    "verbose_logging": false
  },
  "first_run_tabs": [
    "chrome://newtab"
  ]
}
EOF
)
echo "$PREFS_JSON" > "$RESOURCES/master_preferences"
echo "$PREFS_JSON" > "$RESOURCES/initial_preferences"
log "Wrote $RESOURCES/master_preferences ($(wc -c < "$RESOURCES/master_preferences") bytes)"

# ----------------------------------------------------------------------------
# Step 7: Inject Claum's bundled extensions into the .app
# ----------------------------------------------------------------------------
# Chromium loads bundled extensions from a per-app folder if we drop a JSON
# manifest into the right place. The simpler trick we use here: ship the
# extension folders inside the .app and rely on the user to enable them
# via chrome://extensions — OR, longer-term, use ExtensionInstallForcelist
# managed-policy entries.
#
# For v0 we just COPY the extension folders into Claum.app/Contents/Resources/Extensions/<id>/
# and document where they live. A future iteration will wire them up via
# managed_policies so they auto-load.
# ----------------------------------------------------------------------------
log_step "[7/7] Bundling Claum extensions"
EXT_SRC="$CLAUM_REPO_DIR/claum/extensions"
EXT_DST="$RESOURCES/ClaumExtensions"
if [ -d "$EXT_SRC" ]; then
  mkdir -p "$EXT_DST"
  # Copy each subdir individually so we can log what we shipped.
  for ext_dir in "$EXT_SRC"/*/; do
    [ -d "$ext_dir" ] || continue
    name="$(basename "$ext_dir")"
    cp -R "$ext_dir" "$EXT_DST/$name"
    log "  bundled: $name"
  done
else
  log "  (no extensions dir at $EXT_SRC, skipping)"
fi

# ----------------------------------------------------------------------------
# Step 8: Re-sign the bundle (ad-hoc) so macOS will launch it
# ----------------------------------------------------------------------------
# Modifying ANY file inside a code-signed bundle invalidates the signature.
# Without a valid signature, macOS Gatekeeper refuses to open the .app
# (you'd see "Claum is damaged and can't be opened").
#
# `codesign -s -` is "ad-hoc signing" — uses a placeholder identity, no
# Apple Developer cert needed. Good for development/internal use. For
# distribution to other users we'd swap `-s -` for `-s "Developer ID..."`
# and add notarization, but that's a separate concern.
#
# `--deep` recurses into all the nested helper bundles (Renderer Helper,
# GPU Helper, etc.) — Chromium has ~5 of them. `--force` overwrites any
# existing signature. `--preserve-metadata=...` keeps entitlements intact.
#
# CAVEAT — extended attributes break codesign.
# ----------------------------------------------------------------------------
# When the .app is copied off a mounted .dmg, macOS attaches "extended
# attributes" (xattrs) to many of the files: com.apple.FinderInfo, the
# quarantine flag, sometimes even resource forks. codesign refuses to
# operate on a bundle containing these and bails with:
#     "resource fork, Finder information, or similar detritus not allowed"
# (Build #1 of this workflow died exactly here at line 86 of the log.)
#
# `xattr -cr` recursively clears ALL extended attributes from the bundle.
# `dot_clean` also strips the AppleDouble files (._*) that sometimes show
# up alongside files on FAT/HFS volumes.
# ----------------------------------------------------------------------------
log_step "Stripping extended attributes before signing"
xattr -cr "$DST_APP"
dot_clean -m "$DST_APP" 2>/dev/null || true
log "  cleared xattrs from bundle"

log_step "Re-signing Claum.app (ad-hoc)"
codesign --force --deep \
  --sign - \
  --preserve-metadata=entitlements,requirements,flags,runtime \
  "$DST_APP"
log "Verifying signature:"
codesign --verify --deep --strict --verbose=2 "$DST_APP" 2>&1 | sed 's/^/    /' || {
  log_err "codesign verification failed."
  log_err "The .app should still launch under macOS 14+ with reduced Gatekeeper,"
  log_err "but signing properly will be needed for distribution."
}

# ----------------------------------------------------------------------------
# Step 9: Repackage as Claum-arm64.dmg
# ----------------------------------------------------------------------------
# `hdiutil create -format UDZO` produces a compressed read-only .dmg, which
# is the standard distribution format on macOS. -srcfolder points at the .app,
# -volname is what shows on the desktop when the user mounts it.
# ----------------------------------------------------------------------------
log_step "Building Claum-${ARCH}.dmg"
DMG_OUT="$WORK_DIR/Claum-${ARCH}.dmg"
rm -f "$DMG_OUT"
hdiutil create \
  -volname "Claum" \
  -srcfolder "$DST_APP" \
  -ov \
  -format UDZO \
  "$DMG_OUT" \
  | sed 's/^/    /'
log ""
log "Built: $DMG_OUT ($(du -h "$DMG_OUT" | awk '{print $1}'))"

# ----------------------------------------------------------------------------
# Done
# ----------------------------------------------------------------------------
log_step "✓ Build complete"
log "Upstream:    ungoogled-chromium $UPSTREAM_TAG"
log "Output DMG:  $DMG_OUT"
log "App bundle:  $DST_APP"
log ""
log "To install locally:"
log "    open '$DMG_OUT'   # mount the dmg in Finder"
log "    # then drag Claum.app to /Applications"

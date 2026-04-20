#!/usr/bin/env bash
# ============================================================================
# claum/scripts/common.sh — shared helpers for the build scripts.
# Source this file from build-mac.sh, build-windows.ps1 (via WSL), etc.
# ============================================================================

# Bail on any error, unset variable, or failed pipe.
set -euo pipefail

# --- Paths ------------------------------------------------------------------
# Where this repo lives.
CLAUM_REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

# Where we'll stage the ungoogled-chromium checkout + Chromium source.
# Default to ~/claum-build; override with --build-root.
CLAUM_BUILD_ROOT="${CLAUM_BUILD_ROOT:-$HOME/claum-build}"

# Upstream ungoogled-chromium repo we base Claum on.
UNGOOGLED_REPO="${UNGOOGLED_REPO:-https://github.com/ungoogled-software/ungoogled-chromium.git}"
UNGOOGLED_BRANCH="${UNGOOGLED_BRANCH:-master}"

# Pinned Chromium version (must match CHROMIUM_VERSION at the repo root).
CHROMIUM_VERSION="$(cat "$CLAUM_REPO_DIR/CHROMIUM_VERSION" | tr -d '[:space:]')"

# --- Logging helpers --------------------------------------------------------
# Color codes — skipped if stdout isn't a TTY.
if [ -t 1 ]; then
  _C_BLUE='\033[0;34m'; _C_GREEN='\033[0;32m'; _C_YELLOW='\033[0;33m'
  _C_RED='\033[0;31m';  _C_RESET='\033[0m'
else
  _C_BLUE=''; _C_GREEN=''; _C_YELLOW=''; _C_RED=''; _C_RESET=''
fi
log_step() { echo -e "${_C_BLUE}==>${_C_RESET} $*"; }
log_ok()   { echo -e "${_C_GREEN}  ✓${_C_RESET} $*"; }
log_warn() { echo -e "${_C_YELLOW}  ⚠${_C_RESET} $*"; }
log_err()  { echo -e "${_C_RED}  ✗${_C_RESET} $*" >&2; }

# --- Reusable steps ---------------------------------------------------------

# Clone or update ungoogled-chromium into $CLAUM_BUILD_ROOT.
clone_or_update_ungoogled() {
  if [ -d "$CLAUM_BUILD_ROOT/.git" ]; then
    log_step "Updating ungoogled-chromium"
    git -C "$CLAUM_BUILD_ROOT" fetch --depth=1 origin "$UNGOOGLED_BRANCH"
    git -C "$CLAUM_BUILD_ROOT" reset --hard "origin/$UNGOOGLED_BRANCH"
  else
    log_step "Cloning ungoogled-chromium"
    git clone --depth=1 --branch "$UNGOOGLED_BRANCH" \
      "$UNGOOGLED_REPO" "$CLAUM_BUILD_ROOT"
  fi
  log_ok "ungoogled-chromium ready at $CLAUM_BUILD_ROOT"
}

# Copy Claum extensions + resources into the Chromium source tree.
# Run this AFTER the Chromium source is unpacked to build/src/.
install_claum_resources() {
  local SRC="$CLAUM_BUILD_ROOT/build/src"
  if [ ! -d "$SRC" ]; then
    log_err "Chromium source tree not found at $SRC"
    log_err "Run the ungoogled-chromium download/unpack steps first."
    exit 1
  fi

  log_step "Copying Claum component extensions into the Chromium tree"
  mkdir -p "$SRC/chrome/browser/resources/claum_extensions"
  # Underscore variants — Chromium resource names can't contain dashes.
  rsync -a --delete \
      "$CLAUM_REPO_DIR/claum/extensions/claum-newtab/" \
      "$SRC/chrome/browser/resources/claum_extensions/claum_newtab/"
  rsync -a --delete \
      "$CLAUM_REPO_DIR/claum/extensions/claude-for-chrome/" \
      "$SRC/chrome/browser/resources/claum_extensions/claude_for_chrome/"

  log_ok "Extensions copied"
}

# Apply every patch under claum/patches/ in lexical order.
apply_claum_patches() {
  local SRC="$CLAUM_BUILD_ROOT/build/src"
  pushd "$SRC" >/dev/null
  log_step "Applying Claum patches"
  for p in "$CLAUM_REPO_DIR"/claum/patches/*.patch; do
    [ -e "$p" ] || continue
    echo "     $(basename "$p")"
    if ! git apply --check "$p" 2>/dev/null; then
      log_warn "    skipping (already applied or conflicts)"
      continue
    fi
    git apply "$p"
  done
  popd >/dev/null
  log_ok "Patches applied"
}

# Verify prerequisites are installed. Returns 0 on success, 1 otherwise.
check_tool() {
  local name="$1"; local hint="$2"
  if ! command -v "$name" >/dev/null 2>&1; then
    log_err "$name not found. $hint"
    return 1
  fi
  log_ok "$name ($(command -v "$name"))"
}

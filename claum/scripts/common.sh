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

# Pinned Chromium version (must match CHROMIUM_VERSION at the repo root).
CHROMIUM_VERSION="$(cat "$CLAUM_REPO_DIR/CHROMIUM_VERSION" | tr -d '[:space:]')"

# We want ungoogled-chromium at the tag that matches our pinned Chromium
# version — otherwise the downloads.ini will point at a DIFFERENT Chromium
# version than the one our patches were written for. Upstream tags are
# named <chromium-version>-1 (e.g. 146.0.7680.164-1).
# You can override with UNGOOGLED_BRANCH=<some-ref> if needed.
UNGOOGLED_BRANCH="${UNGOOGLED_BRANCH:-${CHROMIUM_VERSION}-1}"

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
# $UNGOOGLED_BRANCH may be either a branch (e.g. "master") or a tag
# (e.g. "146.0.7680.164-1"). `git clone --branch` accepts both.
clone_or_update_ungoogled() {
  if [ -d "$CLAUM_BUILD_ROOT/.git" ]; then
    log_step "Updating ungoogled-chromium to $UNGOOGLED_BRANCH"
    # Fetch the specific ref. For a tag, --depth=1 + refs/tags/<tag>:refs/tags/<tag>
    # is the reliable incantation; for a branch it's origin/<branch>.
    git -C "$CLAUM_BUILD_ROOT" fetch --depth=1 origin \
        "+refs/heads/${UNGOOGLED_BRANCH}:refs/remotes/origin/${UNGOOGLED_BRANCH}" \
        2>/dev/null \
      || git -C "$CLAUM_BUILD_ROOT" fetch --depth=1 origin \
        "+refs/tags/${UNGOOGLED_BRANCH}:refs/tags/${UNGOOGLED_BRANCH}"
    git -C "$CLAUM_BUILD_ROOT" checkout --force "${UNGOOGLED_BRANCH}"
  else
    log_step "Cloning ungoogled-chromium @ $UNGOOGLED_BRANCH"
    # `git clone --branch` takes either a branch name or a tag name.
    # If the tag doesn't exist upstream, fall back to master with a warning.
    if ! git clone --depth=1 --branch "$UNGOOGLED_BRANCH" \
         "$UNGOOGLED_REPO" "$CLAUM_BUILD_ROOT" 2>/dev/null; then
      log_warn "Tag/branch '$UNGOOGLED_BRANCH' not found upstream — falling back to master."
      log_warn "Chromium version may not match — patches may fail."
      git clone --depth=1 --branch master "$UNGOOGLED_REPO" "$CLAUM_BUILD_ROOT"
    fi
  fi
  log_ok "ungoogled-chromium ready at $CLAUM_BUILD_ROOT ($(git -C "$CLAUM_BUILD_ROOT" rev-parse --short HEAD))"
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

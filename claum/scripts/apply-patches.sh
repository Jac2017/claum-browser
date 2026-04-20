#!/usr/bin/env bash
# ============================================================================
# claum/scripts/apply-patches.sh — apply Claum patches to an existing
# ungoogled-chromium checkout. Useful if you're iterating on patches without
# redoing the full download/unpack.
#
# Usage:
#   ./claum/scripts/apply-patches.sh [--build-root ~/claum-build]
# ============================================================================
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    --build-root) CLAUM_BUILD_ROOT="$2"; shift 2 ;;
    --help|-h)
      sed -n '4,9p' "$0"; exit 0 ;;
    *) log_err "Unknown flag: $1"; exit 1 ;;
  esac
done

install_claum_resources
apply_claum_patches
log_ok "Patches re-applied. You can now re-run ninja."

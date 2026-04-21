#!/usr/bin/env python3
# =============================================================================
# fix-safe-browsing-gn.py
# -----------------------------------------------------------------------------
# Surgical fix for chrome/browser/safe_browsing/BUILD.gn after ungoogled-
# chromium's `fix-building-without-safebrowsing.patch` runs.
#
# BACKGROUND
# ----------
# Stock Chromium's chrome/browser/safe_browsing/BUILD.gn defines a
# `static_library("safe_browsing")` target whose body looks roughly like:
#
#     static_library("safe_browsing") {
#       if (some_condition) {           # OUTER if — defines variables
#         sources = [ ... ]
#         deps    = [ ... ]
#         allow_circular_includes_from = []
#         configs = [ ... ]
#         public_deps = [ ... ]
#       }
#
#       # Later code appends to those variables:
#       if (safe_browsing_mode != 0) {  # INNER if — appends to them
#         sources += [ ... ]
#         deps    += [ ... ]
#       }
#       ...
#       allow_circular_includes_from += [ "//chrome/browser/ui/safety_hub" ]
#     }
#
# After the ungoogled patch is applied, the OUTER if-block ends up wrapped in
# `if (false) { ... }`. That means sources, deps, configs, public_deps, and
# allow_circular_includes_from are NEVER defined at the static_library scope.
# Then later `+= [...]` calls (which still execute) all blow up with:
#
#     ERROR at //chrome/browser/safe_browsing/BUILD.gn:NNN:N: Undefined identifier.
#         sources += [
#         deps += [
#         allow_circular_includes_from += [ "//chrome/browser/ui/safety_hub" ]
#
# WHAT THIS SCRIPT DOES
# ---------------------
# We apply TWO fixes, in order:
#
# Fix #1 — Flip `if (false)` back to `if (true)` for the main definitions
#   block. This is the root-cause fix: it restores the legitimate Chromium
#   code that defines `sources`, `deps`, `allow_circular_includes_from`,
#   `configs`, and `public_deps` in one shot. After this, the later `+= [...]`
#   calls have variables to append to.
#
# Fix #2 — Insert `defined()`-guarded initializers for `sources` and `deps`
#   inside the inner `if (safe_browsing_mode != 0) { ... }` block:
#
#     if (!defined(sources)) { sources = [] }
#     if (!defined(deps))    { deps    = [] }
#
#   This is belt-and-suspenders: if for any reason Fix #1 doesn't apply
#   (e.g. the wrapper was removed by a future patch), this still keeps the
#   inner block safe. `defined(...)` is a gn built-in that returns true when
#   a variable already exists in scope — so when Fix #1 DID succeed and
#   sources/deps are already defined, these guards are no-ops.
#
# IDEMPOTENCY
# -----------
# Each fix has its own idempotency check, so the script is safe to re-run
# any number of times.
#
# USAGE
# -----
#   python3 fix-safe-browsing-gn.py <chromium_src_dir>
# where <chromium_src_dir> is the directory containing chrome/, content/, etc.
# =============================================================================

import pathlib   # cross-platform file path handling
import re        # regex — used for multi-line pattern matching
import sys       # argv + exit codes

# --- 1. Locate the target file ----------------------------------------------
# Expect exactly one positional arg: the path to chromium's `src` directory.
if len(sys.argv) != 2:
    print("Usage: fix-safe-browsing-gn.py <chromium_src_dir>", file=sys.stderr)
    sys.exit(2)

src_dir = pathlib.Path(sys.argv[1])
# `pathlib.Path`'s `/` operator joins paths in an OS-agnostic way.
target = src_dir / "chrome" / "browser" / "safe_browsing" / "BUILD.gn"

if not target.is_file():
    # Bail early so we get a clean error message instead of a cryptic build fail.
    print(f"ERROR: {target} not found", file=sys.stderr)
    sys.exit(1)

# --- 2. Read the file into memory -------------------------------------------
# BUILD.gn files are only a few hundred lines — a single read is fine.
text = target.read_text()


# =============================================================================
# Fix #1 — Flip `if (false) {` back to `if (true) {` in the main block
# =============================================================================
# Look for the pattern:
#
#     static_library("safe_browsing") {
#       if (false) {
#
# and change the inner `if (false)` to `if (true)` so the original Chromium
# variable-definition block actually executes.
#
# Why a regex instead of a simple string replace? Because BUILD.gn files have
# many `if (false) {` lines for various reasons (unrelated targets, debug
# checks, etc.). We want to match ONLY the one immediately inside
# `static_library("safe_browsing") {` — that anchor makes the match precise.
# -----------------------------------------------------------------------------
PATTERN_IF_FALSE = re.compile(
    # Group 1: the static_library opening line plus any whitespace/newline
    # before the `if`. We keep this in the replacement so we don't lose it.
    r'(static_library\("safe_browsing"\) \{\n\s*)'
    # Then the literal `if (false) {` we want to flip
    r'if \(false\) \{'
)

# `re.subn` returns (new_text, replacement_count). count=1 means "only the
# first match" — there should only ever be one anyway, but this is defensive.
text, n_iffalse = PATTERN_IF_FALSE.subn(
    # Backreference \1 keeps the static_library line + indentation, then we
    # write `if (true) {` followed by an inline comment explaining why.
    r'\1if (true) {  # Claum: flipped from if(false) — see fix-safe-browsing-gn.py',
    text,
    count=1,
)

if n_iffalse:
    print("[fix-safe-browsing-gn] Fix #1: flipped if(false) -> if(true) in static_library block")
else:
    # Either already flipped, or the wrapper was never there. Both are fine.
    print("[fix-safe-browsing-gn] Fix #1: no if(false) wrapper found (already flipped or not present)")


# =============================================================================
# Fix #2 — Insert defined()-guarded initializers for sources/deps
# =============================================================================
# This is a belt-and-suspenders safety net: even if Fix #1 didn't apply, this
# keeps the inner `if (safe_browsing_mode != 0) { sources += [...] }` block
# from blowing up.
# -----------------------------------------------------------------------------

# Idempotency check: if we've already inserted our markers, skip. We look for
# our exact inserted text — `!defined(sources)` — to decide.
already_fixed = "!defined(sources)" in text

if already_fixed:
    print("[fix-safe-browsing-gn] Fix #2: already applied — skipping")
else:
    # Regex breakdown:
    #   (if \(safe_browsing_mode != 0\) \{\n  <- group 1: the if-header line
    #    (?:\s*#[^\n]*\n)*                     <- any number of comment lines
    #   )
    #   (\s*)                                   <- group 2: indentation of `sources +=`
    #   (sources\s*\+=\s*\[)                    <- group 3: literal `sources += [`
    PATTERN_GUARDS = re.compile(
        r'(if \(safe_browsing_mode != 0\) \{\n(?:\s*#[^\n]*\n)*)'
        r'(\s*)'
        r'(sources\s*\+=\s*\[)',
    )

    def do_replace(m):
        """Build the replacement text for one regex match.

        We reconstruct the if-header + comments, then insert our guarded
        initializers at the same indentation, and finally the original
        `sources += [` that was already there.
        """
        if_header = m.group(1)   # "if (safe_browsing_mode != 0) {\n<comments>"
        indent    = m.group(2)   # whitespace in front of `sources += [`
        plus_eq   = m.group(3)   # literal `sources += [`

        # Each line uses the same indentation as the original `sources += [`
        # so the file stays consistently formatted.
        inserted = (
            f"{indent}# Initialize sources/deps if the outer block didn't define them.\n"
            f"{indent}# `defined()` is a gn built-in that returns true when the var exists,\n"
            f"{indent}# so this is a no-op when the outer block already populated them.\n"
            f"{indent}if (!defined(sources)) {{\n"
            f"{indent}  sources = []\n"
            f"{indent}}}\n"
            f"{indent}if (!defined(deps)) {{\n"
            f"{indent}  deps = []\n"
            f"{indent}}}\n"
        )

        return f"{if_header}{inserted}{indent}{plus_eq}"

    # `re.subn(..., count=1)` returns (new_text, num_replacements). We expect
    # exactly one match — more than one means the file drifted and we should
    # bail instead of mutating blindly.
    text, n_guards = PATTERN_GUARDS.subn(do_replace, text, count=1)

    if n_guards == 0:
        # We couldn't find the expected pattern. This is non-fatal IF Fix #1
        # already restored the original variable definitions — in that case
        # the inner `sources += [...]` will work fine without our guards.
        # So just warn instead of failing.
        print(
            "[fix-safe-browsing-gn] Fix #2: pattern not found — inner block layout may differ.\n"
            "                          (Non-fatal if Fix #1 succeeded.)"
        )
    else:
        print("[fix-safe-browsing-gn] Fix #2: inserted guarded sources/deps initializers")


# --- 3. Write the result back to disk ---------------------------------------
target.write_text(text)
print(f"[fix-safe-browsing-gn] done: {target}")
sys.exit(0)

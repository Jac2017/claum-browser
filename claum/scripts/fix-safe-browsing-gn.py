#!/usr/bin/env python3
# =============================================================================
# fix-safe-browsing-gn.py
# -----------------------------------------------------------------------------
# Surgical fix for chrome/browser/safe_browsing/BUILD.gn after ungoogled-
# chromium's `fix-building-without-safebrowsing.patch` runs.
#
# BACKGROUND
# ----------
# Stock Chromium's chrome/browser/safe_browsing/BUILD.gn has this shape:
#
#     static_library("safe_browsing") {
#       if (safe_browsing_mode != 0) {          # OUTER if
#         sources = [ ... ]                     # defines `sources`
#         deps    = [ ..., "//services/..." ]   # defines `deps`
#       }                                        # closes outer if (~line 89)
#
#       # Note: is_android is not equivalent to safe_browsing_mode == 2.
#       if (is_android)  { deps += [...] }
#       if (is_chromeos) { deps += [...] }
#
#       if (safe_browsing_mode != 0) {          # INNER if
#         sources += [ ... ]                    # appends — needs `sources`
#         deps    += [ ... ]                    # appends — needs `deps`
#         ...
#       }
#     }
#
# When `safe_browsing_mode == 0` (which the ungoogled build tends to produce),
# the OUTER if-block does not execute, so `sources` and `deps` are never
# defined at the `static_library` scope. Then any `sources += [...]` or
# `deps += [...]` later in the file blows up with
#
#     ERROR ... Undefined identifier.
#         sources += [
#
# (and the same for `deps`). Note that the INNER if-block still evaluates
# because `safe_browsing_mode != 0` — so the += calls run despite the outer
# block having been skipped.
#
# WHAT THIS SCRIPT DOES
# ---------------------
# We insert two small guarded initializations at the TOP of the INNER
# `if (safe_browsing_mode != 0) { ... }` block:
#
#     if (!defined(sources)) {
#       sources = []
#     }
#     if (!defined(deps)) {
#       deps = []
#     }
#
# Why `defined(...)` rather than a bare `sources = []`? Because on builds
# where the outer if DID run, `sources`/`deps` are already defined, and
# assigning them again in an inner scope is a gn error. `defined()` is a
# built-in that lets us initialize ONLY when needed — safe in every config.
#
# IDEMPOTENCY
# -----------
# Re-running the script is a no-op: we look for our own inserted markers
# (`!defined(sources)` and `!defined(deps)`) and skip if present.
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

# --- 3. Insert the guarded `sources`/`deps` initializers --------------------
# We look for the INNER `if (safe_browsing_mode != 0) {` block followed by
# any comment lines, then the first `sources += [` line. We want to insert
# our two initialization blocks BEFORE that `sources += [`.
#
# Regex breakdown:
#   (if \(safe_browsing_mode != 0\) \{\n  <- group 1: the if-header line
#    (?:\s*#[^\n]*\n)*                   <- any number of comment lines
#   )
#   (\s*)                                 <- group 2: indentation of sources+=
#   (sources\s*\+=\s*\[)                  <- group 3: literal "sources += ["
# -----------------------------------------------------------------------------

# Idempotency check: if we've already inserted our markers, do nothing.
# Look for our exact inserted text — `!defined(sources)` — to decide.
already_fixed = "!defined(sources)" in text

if already_fixed:
    print("[fix-safe-browsing-gn] already applied — skipping")
else:
    PATTERN = re.compile(
        # Start: the `if (safe_browsing_mode != 0) {` line, plus any comments
        r'(if \(safe_browsing_mode != 0\) \{\n(?:\s*#[^\n]*\n)*)'
        # Capture the indentation of the first real statement
        r'(\s*)'
        # And the literal `sources += [` — the first thing after the comments
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

        # Build the inserted block. Each line uses the same indentation as
        # the original `sources += [` so the file stays consistently formatted.
        inserted = (
            f"{indent}# Initialize sources/deps if the outer `if (safe_browsing_mode != 0)` block\n"
            f"{indent}# didn't run (the ungoogled patches can skip it). Using `defined()` means\n"
            f"{indent}# this is a no-op when the outer block already populated them.\n"
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
    text, n = PATTERN.subn(do_replace, text, count=1)

    if n == 0:
        # We couldn't find the expected pattern. Fail loudly with context.
        print(
            "ERROR: could not find the `if (safe_browsing_mode != 0)` block\n"
            f"       followed by `sources += [` in {target}.\n"
            "       The file layout may have drifted — inspect it manually.",
            file=sys.stderr,
        )
        sys.exit(1)

    print("[fix-safe-browsing-gn] inserted guarded sources/deps initializers")

# --- 4. Write the result back to disk ---------------------------------------
target.write_text(text)
print(f"[fix-safe-browsing-gn] done: {target}")
sys.exit(0)

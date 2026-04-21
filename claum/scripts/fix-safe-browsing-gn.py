#!/usr/bin/env python3
# =============================================================================
# fix-safe-browsing-gn.py
# -----------------------------------------------------------------------------
# Surgical fix for chrome/browser/safe_browsing/BUILD.gn after ungoogled-
# chromium's patches mangle it. We apply TWO fixes:
#
#   FIX A — Remove the stray `}` on line 89
#   ---------------------------------------
#   ungoogled's patch appears to have removed an enclosing block like
#       if (some_google_feature) {
#         sources = [ ... ]
#         deps = [ ... ]
#       }
#   but it only removed the OPENING `if (...) {` line. The closing `}` was
#   left behind, and it now prematurely closes the surrounding
#   source_set("safe_browsing") { ... } scope.
#
#   Everything after that stray `}` becomes top-level in the file, outside
#   any source_set. Later on you get errors like
#       ERROR at //chrome/browser/safe_browsing/BUILD.gn:243:5:
#       Undefined identifier.    deps += [
#   because `deps` (defined at line 80-88 inside the now-closed source_set)
#   is no longer in scope for `deps += [...]`.
#
#   Removing that one stray `}` reunites everything back inside the
#   source_set, so every later `<var> += [...]` finds its variable.
#
#   FIX B — Insert `sources = []` before `sources += [`
#   ---------------------------------------------------
#   The same patch also removed the original `sources = [ ... ]` assignment.
#   Even after Fix A puts things back inside the source_set, `sources` has
#   no initial value, so `sources += [...]` inside the
#       if (safe_browsing_mode != 0) { ... }
#   block still fails.
#
#   We insert `sources = []` right before the orphan `+=` to give gn
#   something to append to.
#
# IDEMPOTENT: running the script twice does nothing on the second run
# because the bad patterns are already gone.
#
# USAGE:
#   python3 fix-safe-browsing-gn.py <chromium_src_dir>
# where <chromium_src_dir> is the directory containing chrome/, content/, etc.
# =============================================================================

import pathlib   # modern, cross-platform file path handling
import re        # regex — used for multi-line pattern matching
import sys       # for argv and exit codes

# --- 1. Locate the target file ----------------------------------------------
# Expect exactly one positional arg: path to the chromium `src` directory.
if len(sys.argv) != 2:
    print("Usage: fix-safe-browsing-gn.py <chromium_src_dir>", file=sys.stderr)
    sys.exit(2)

src_dir = pathlib.Path(sys.argv[1])
# The `/` operator on Path joins paths in an OS-agnostic way.
target = src_dir / "chrome" / "browser" / "safe_browsing" / "BUILD.gn"

if not target.is_file():
    # Fail loudly if the file isn't where we expect — better to stop early
    # than silently do nothing and have the build fail elsewhere.
    print(f"ERROR: {target} not found", file=sys.stderr)
    sys.exit(1)

# --- 2. Read the file's current contents into memory ------------------------
# read_text() returns the whole file as a single string. These BUILD.gn
# files are only a few hundred lines — reading the full thing is fine.
text = target.read_text()

# ---------------------------------------------------------------------------
# FIX A: Remove the stray `}` on line 89.
# ---------------------------------------------------------------------------
# The signature we're looking for: the unique sequence of lines around the
# stray brace. Matching the surrounding context (instead of a specific line
# number) survives future Chromium version bumps.
#
# Before fix:
#       "//services/preferences/public/cpp",   (line 87)
#     ]                                        (line 88, closes deps list)
#     }                                        (line 89, STRAY — delete this)
#                                              (line 90, blank)
#                                              (line 91, blank)
#     # Note: is_android ...                   (line 92, comment)
#
# After fix: the `  }` line is gone; everything else stays the same.
# ---------------------------------------------------------------------------
STRAY_BRACE_BEFORE = (
    '    "//services/preferences/public/cpp",\n'
    '  ]\n'
    '  }\n'      # <- this line is what we want to delete
    '\n'
    '\n'
    '  # Note: is_android is not equivalent to safe_browsing_mode == 2.\n'
)
STRAY_BRACE_AFTER = (
    '    "//services/preferences/public/cpp",\n'
    '  ]\n'
    '\n'
    '\n'
    '  # Note: is_android is not equivalent to safe_browsing_mode == 2.\n'
)

if STRAY_BRACE_BEFORE in text:
    # str.replace returns a NEW string; we reassign `text` to the fixed one.
    text = text.replace(STRAY_BRACE_BEFORE, STRAY_BRACE_AFTER, 1)
    print("[fix-safe-browsing-gn] Fix A applied: removed stray `}` around line 89")
else:
    # Either Fix A was already applied on a previous run, or upstream
    # changed the file so that this signature no longer matches. Either way,
    # don't abort — just note and move on to Fix B.
    print("[fix-safe-browsing-gn] Fix A: stray-brace pattern not found (maybe already fixed)")

# ---------------------------------------------------------------------------
# FIX B: Insert `sources = []` before the orphan `sources += [`.
# ---------------------------------------------------------------------------
# Even after Fix A reunites everything inside the source_set, `sources`
# still has no initial value (the patch removed the `sources = [ ... ]`
# assignment). We insert a zero-element initialization right before the
# `sources += [...]` inside the if-block.
#
# Regex breakdown:
#   (if \(safe_browsing_mode != 0\) \{\n     <- group 1: the `if (...) {` line
#    (?:\s*#[^\n]*\n)*                       <- non-capturing: any number of
#                                                comment lines that follow
#   )
#   (\s*)                                     <- group 2: whitespace before
#                                                `sources += [` (captures
#                                                the indentation to reuse)
#   (sources\s*\+=\s*\[)                      <- group 3: literal `sources += [`
# ---------------------------------------------------------------------------

# First, an idempotency check: if our inserted `sources = []` marker is
# already right above the `sources += [`, skip Fix B entirely.
already_fixed = re.search(
    r'sources\s*=\s*\[\s*\]\s*\n\s*sources\s*\+=\s*\[',
    text,
)

if already_fixed:
    print("[fix-safe-browsing-gn] Fix B: already applied — skipping")
else:
    PATTERN = re.compile(
        r'(if \(safe_browsing_mode != 0\) \{\n(?:\s*#[^\n]*\n)*)(\s*)(sources\s*\+=\s*\[)',
    )

    def do_replace(m):
        """Build the replacement for one regex match.

        match.group(N) returns the Nth captured group. We stitch them back
        together with a new `sources = []` line inserted between the
        header and the `sources += [`, preserving the original indentation.
        """
        if_header = m.group(1)  # "if (safe_browsing_mode != 0) {\n<comments>\n"
        indent    = m.group(2)  # the whitespace before `sources += [`
        plus_eq   = m.group(3)  # `sources += [`
        return f"{if_header}{indent}sources = []\n{indent}{plus_eq}"

    # `subn` returns (new_string, count). We use count=1 because we only
    # expect one match — multiple matches would mean the file drifted and
    # we should bail rather than mutate blindly.
    text, n = PATTERN.subn(do_replace, text, count=1)

    if n == 0:
        # Fix B was needed (idempotency check said "not applied yet") but
        # we couldn't find the pattern to fix. That means the file
        # structure drifted — fail loudly.
        print(
            "ERROR: Fix B needed but could not find the `if (safe_browsing_mode != 0)`\n"
            f"       block with `sources += [` in {target}.",
            file=sys.stderr,
        )
        sys.exit(1)

    print("[fix-safe-browsing-gn] Fix B applied: inserted `sources = []` before `sources += [`")

# --- 3. Write the final result back to disk ---------------------------------
target.write_text(text)
print(f"[fix-safe-browsing-gn] Done: {target}")
sys.exit(0)

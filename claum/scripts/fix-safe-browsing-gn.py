#!/usr/bin/env python3
# =============================================================================
# fix-safe-browsing-gn.py
# -----------------------------------------------------------------------------
# Surgical fix for chrome/browser/safe_browsing/BUILD.gn.
#
# THE PROBLEM (plain English):
#   ungoogled-chromium includes a patch called
#       fix-building-without-safebrowsing.patch
#   which is applied TWICE in their 111-patch series (as patches #2 and #28).
#   That patch REMOVES the initial `sources = [ ... ]` line from
#   chrome/browser/safe_browsing/BUILD.gn, but it leaves in place a later
#   `sources += [ ... ]` inside an `if (safe_browsing_mode != 0) { ... }`
#   block (around line 114 of the file).
#
#   Because there's no longer a `sources = [...]` in scope, `sources += [...]`
#   references an undefined identifier. `gn gen` then dies with:
#       ERROR at //chrome/browser/safe_browsing/BUILD.gn:114:5:
#       Undefined identifier.    sources += [
#
# THE FIX:
#   Right before `sources += [...]`, insert an empty initialization:
#       sources = []
#   This gives `sources` a defined-but-empty starting value, so `sources +=`
#   becomes a valid append. That's all gn needs to proceed.
#
# WHY A SCRIPT (not a normal .patch file):
#   A .patch file depends on exact line numbers and surrounding context. When
#   Chromium or ungoogled-chromium bump versions, line numbers shift and the
#   patch silently rejects. A regex-based Python script that matches on a
#   distinctive multi-line PATTERN (the `if (safe_browsing_mode != 0) { ... }`
#   block) survives minor upstream changes.
#
# IDEMPOTENT: if the file already contains `sources = []` (because we ran
# before), the script detects that and exits without changes. Safe to run
# multiple times.
#
# HOW TO RUN:
#   python3 fix-safe-browsing-gn.py <chromium_src_dir>
# where <chromium_src_dir> is the directory containing chrome/, content/, etc.
# =============================================================================

import pathlib   # modern, cross-platform file-path handling
import re        # regex engine — used to find the block to fix
import sys       # for argv + exit codes

# --- 1. Locate the file -----------------------------------------------------
# Expect exactly one positional arg: the chromium src directory.
if len(sys.argv) != 2:
    print("Usage: fix-safe-browsing-gn.py <chromium_src_dir>", file=sys.stderr)
    sys.exit(2)

src_dir = pathlib.Path(sys.argv[1])
# The `/` operator on Path objects joins paths in an OS-agnostic way.
target = src_dir / "chrome" / "browser" / "safe_browsing" / "BUILD.gn"

if not target.is_file():
    # Fail loudly — if the file isn't where we expect, we're probably pointed
    # at the wrong directory and we want the build to stop immediately.
    print(f"ERROR: {target} not found", file=sys.stderr)
    sys.exit(1)

# --- 2. Read current contents -----------------------------------------------
text = target.read_text()

# --- 3. Idempotency check ---------------------------------------------------
# If we've already inserted `sources = []` (from a previous run) just before
# the target `sources += [`, do nothing. We use `re.search` rather than a
# naive `in` check so that whitespace between the two statements is tolerated.
already_fixed = re.search(
    r'sources\s*=\s*\[\s*\]\s*\n\s*sources\s*\+=\s*\[',
    text,
)
if already_fixed:
    print(f"[fix-safe-browsing-gn] Already fixed in {target} — skipping.")
    sys.exit(0)

# --- 4. The regex -----------------------------------------------------------
# Break down the pattern:
#   r'(if \(safe_browsing_mode != 0\) \{\n        <- group 1 start: literal "if (safe_browsing_mode != 0) {\n"
#     (?:\s*#[^\n]*\n)*                           <- non-capturing: zero or more comment lines
#   )                                             <- group 1 end
#   (\s*)                                          <- group 2: whitespace before `sources += [` (captures indentation)
#   (sources\s*\+=\s*\[)                          <- group 3: literal `sources += [` (allowing flexible whitespace)
#
# `re.compile` compiles the regex once for efficiency.
PATTERN = re.compile(
    r'(if \(safe_browsing_mode != 0\) \{\n(?:\s*#[^\n]*\n)*)(\s*)(sources\s*\+=\s*\[)',
)

def do_replace(match):
    """Build the replacement string for one regex match.

    `match.group(N)` returns the Nth captured group from the regex.
    We stitch them back together, injecting our `sources = []` line in
    between with the SAME indentation that the `sources += [` uses.
    """
    if_header = match.group(1)  # e.g. "if (safe_browsing_mode != 0) {\n    # comment\n    # comment\n"
    indent    = match.group(2)  # e.g. "    " (the spaces before `sources += [`)
    plus_eq   = match.group(3)  # e.g. "sources += ["

    # The replacement:
    #   <if header>
    #     sources = []       <-- NEW: initialize with empty list
    #     sources += [       <-- ORIGINAL: now valid because `sources` is defined
    return f"{if_header}{indent}sources = []\n{indent}{plus_eq}"

# `subn` returns (new_string, number_of_substitutions). We use `count=1`
# because we only want to patch the first match — multiple matches would
# almost certainly be a sign that the file structure has drifted and we
# should bail rather than mutate blindly.
new_text, n = PATTERN.subn(do_replace, text, count=1)

# --- 5. Write + report ------------------------------------------------------
if n == 0:
    print(
        f"ERROR: could not find `if (safe_browsing_mode != 0) {{ ... sources += [ ... ]`\n"
        f"       pattern in {target}. Either the file has changed upstream\n"
        f"       or the ungoogled patches didn't apply as expected. Aborting.",
        file=sys.stderr,
    )
    sys.exit(1)

target.write_text(new_text)
print(f"[fix-safe-browsing-gn] Inserted `sources = []` before `sources += [` in {target}")
sys.exit(0)

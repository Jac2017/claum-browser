#!/usr/bin/env python3
# =============================================================================
# fix-safe-browsing-components-gn.py
# -----------------------------------------------------------------------------
# Surgical fix for two BUILD.gn files in components/safe_browsing/ that
# reference .cc source files whose required header symbols are stripped by
# ungoogled-chromium's `0001-fix-building-without-safebrowsing.patch`.
#
# Path A from the run #65 escalation note in BUILD_NOTES.md: rather than
# re-injecting the missing symbol declarations into the headers (Path B —
# fragile, has to mirror upstream signatures exactly), we just stop
# compiling the consumer .cc files. Their behavior is moot once safe
# browsing is disabled at the runtime layer anyway.
#
# WHY WE DON'T USE `if (safe_browsing_mode != 0)` HERE
# ----------------------------------------------------
# The previous watcher noted that in this build `safe_browsing_mode != 0`
# is ALREADY true (which is exactly why these CXX commands ran in the
# first place — if the guard were false they'd have been skipped). So
# wrapping in another `if (safe_browsing_mode != 0)` would be a no-op.
#
# The ungoogled patch leaves the build at a contradictory state:
#   * safe_browsing_mode is non-zero (the GN target compiles these .cc files)
#   * but the headers those .cc files include have had the supporting
#     symbol declarations stripped out
# So compilation blows up with 14 distinct "use of undeclared identifier"
# / "no member named" errors at ninja [44760/55997].
#
# WHAT THIS SCRIPT DOES
# ---------------------
# For each (BUILD.gn, source.cc) pair below, we find the line that lists
# the .cc file inside a `sources = [ ... ]` (or similar) list and comment
# it out with a Claum-watcher marker. The result is that ninja simply
# skips compiling those two files, and the dependent code paths (which
# only matter when safe browsing is wired up) are gone too.
#
# The pattern match is intentionally LOOSE — we just look for any line
# that contains the .cc filename in quotes — because the live runner is
# the only place we have the actual BUILD.gn content (raw log access from
# the watcher sandbox is proxy-blocked). The looseness is safe because:
#   * Each .cc filename should appear at most once per BUILD.gn.
#   * If the line we find isn't inside a sources list (e.g. it's in a
#     comment), commenting it again is a harmless no-op.
#
# IDEMPOTENCY
# -----------
# We check for our `# Claum: removed` marker before patching. If found,
# we skip — so re-running the script (or running it on a re-extraction
# of the Chromium source) is safe.
#
# USAGE
# -----
#   python3 fix-safe-browsing-components-gn.py <chromium_src_dir>
# where <chromium_src_dir> is the directory containing chrome/, content/,
# components/, etc. (i.e. the same arg as fix-safe-browsing-gn.py).
# =============================================================================

import pathlib   # cross-platform file path joins
import re        # regex for line matching
import sys       # argv + exit codes


# --- Argument parsing --------------------------------------------------------
# We expect exactly one positional arg: the path to chromium's `src` dir.
if len(sys.argv) != 2:
    print(
        "Usage: fix-safe-browsing-components-gn.py <chromium_src_dir>",
        file=sys.stderr,
    )
    sys.exit(2)

src_dir = pathlib.Path(sys.argv[1])


# --- Targets to patch --------------------------------------------------------
# Each entry is (relative BUILD.gn path, .cc filename to remove from sources).
# Both paths are relative to the chromium `src` directory.
TARGETS = [
    (
        "components/safe_browsing/core/browser/password_protection/BUILD.gn",
        "password_protection_service_base.cc",
    ),
    (
        "components/safe_browsing/content/browser/BUILD.gn",
        "client_side_detection_service.cc",
    ),
]


# --- Per-target patcher ------------------------------------------------------
# Marker we leave on the commented-out line so we can detect already-patched
# files on a re-run. Must be unique to this script.
CLAUM_MARKER = "# Claum: removed (fix-safe-browsing-components-gn.py)"


def patch_one(build_gn: pathlib.Path, cc_name: str) -> bool:
    """Comment out the line in `build_gn` that lists `cc_name` as a source.

    Returns True on success (or already-patched), False if the file is
    missing or the .cc filename can't be located.
    """
    if not build_gn.is_file():
        # Missing file is non-fatal — log and let the build continue. The
        # underlying compile error will re-surface and a future watcher
        # cycle can handle it.
        print(f"[fix-sb-components] WARN: {build_gn} not found, skipping")
        return False

    text = build_gn.read_text()

    # Idempotency: if we've already patched this file, the marker will be
    # present. Skip silently in that case so re-runs are no-ops.
    if CLAUM_MARKER in text:
        print(f"[fix-sb-components] {build_gn.name}: already patched (marker present)")
        return True

    # Build a regex that matches the WHOLE line containing the .cc filename
    # in quotes. We capture leading whitespace so we can preserve indentation
    # when we comment the line out.
    #   ^(\s*)            -> group 1: leading indent
    #   ("[^"]*<cc_name>") -> group 2: the quoted source path (e.g.
    #                        "password_protection_service_base.cc" or
    #                        "core/browser/.../password_protection_service_base.cc")
    #   (,?)               -> group 3: optional trailing comma
    #   (\s*)$             -> group 4: trailing whitespace (kept as-is)
    # `re.escape` defends against any regex metacharacters in the filename
    # (none in practice today, but cheap insurance).
    line_re = re.compile(
        r'^(\s*)("[^"\n]*' + re.escape(cc_name) + r'")(,?)(\s*)$',
        re.MULTILINE,
    )

    matches = line_re.findall(text)
    if not matches:
        print(
            f"[fix-sb-components] ERROR: could not find quoted reference to "
            f"{cc_name} in {build_gn}"
        )
        return False

    if len(matches) > 1:
        # If we get more than one hit, the file has drifted from what we
        # expect. Bail rather than patching blindly — failing here is
        # MUCH preferable to silently breaking the build in a confusing
        # way deep into the CXX phase.
        print(
            f"[fix-sb-components] ERROR: {len(matches)} matches for "
            f"{cc_name} in {build_gn} — refusing to patch ambiguously"
        )
        return False

    def do_replace(m: re.Match) -> str:
        """Comment out the whole sources line and add a Claum marker.

        Result: `<indent># <original line contents>  # Claum: removed ...`
        That keeps the line in place (so line numbers don't shift) but
        gn's parser now treats it as a comment and skips it.
        """
        indent  = m.group(1)
        quoted  = m.group(2)
        comma   = m.group(3)
        # We rebuild the original line content, then prefix with `# ` so gn
        # treats it as a comment. We keep the trailing comma if there was
        # one — preserves the fact that there was a list element here, just
        # in case anyone diffs against upstream.
        original_payload = f"{quoted}{comma}"
        return f"{indent}# {original_payload}  {CLAUM_MARKER}"

    new_text, n = line_re.subn(do_replace, text, count=1)
    # We already validated len(matches) == 1, so n must be 1 here. Defensive
    # assertion in case the regex semantics surprise us.
    if n != 1:
        print(
            f"[fix-sb-components] ERROR: expected 1 substitution but did {n} "
            f"in {build_gn}"
        )
        return False

    build_gn.write_text(new_text)
    print(
        f"[fix-sb-components] patched {build_gn}: commented out source "
        f"reference to {cc_name}"
    )
    return True


# --- Main loop ---------------------------------------------------------------
# Track failures so we can exit non-zero if anything goes wrong. We still
# attempt every target even if an earlier one fails — that gives the build
# log the most useful diagnostic surface in one shot.
all_ok = True
for rel_path, cc_name in TARGETS:
    full_path = src_dir / rel_path
    ok = patch_one(full_path, cc_name)
    if not ok:
        all_ok = False

if not all_ok:
    # Exit 1 so the calling shell script can decide how to react. Today
    # build-mac.sh uses `set -e`, so this will halt the build immediately.
    sys.exit(1)

print("[fix-sb-components] done — all targets patched (or already patched)")
sys.exit(0)

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
#
# Two flavors of entries are supported:
#   1. Explicit: a tuple where the first element is the BUILD.gn path
#      (relative to `src/`). We patch THAT file specifically.
#   2. Auto-discover: a tuple where the first element is None. We walk the
#      `components/safe_browsing/` subtree and patch the first BUILD.gn we
#      find that contains the .cc filename. This is useful when run #82 etc.
#      surfaces a NEW dangling .cc file but we don't yet know which BUILD.gn
#      lists it — Chromium's safe_browsing tree has many BUILD.gn files.
#
# Run #67 (path A) — the original two entries.
# Run #82 — five new dangling .cc files exposed once #67's fix landed.
#   Each of these failed at the CXX phase with either:
#     * "fatal error: 'safe_browsing_prefs.h' file not found" (header
#       stripped by ungoogled-chromium's safe_browsing patch), or
#     * "use of undeclared identifier 'IsURLAllowlistedByPolicy'"
#       (symbol stripped from the same patch)
#   We can't statically know which BUILD.gn file lists each of these .cc
#   files (the live runner is the only place with the actual extracted
#   tree), so we use auto-discovery (None) for them.
TARGETS = [
    (
        "components/safe_browsing/core/browser/password_protection/BUILD.gn",
        "password_protection_service_base.cc",
    ),
    (
        "components/safe_browsing/content/browser/BUILD.gn",
        "client_side_detection_service.cc",
    ),
    # Run #82 dangling files — auto-discover BUILD.gn under components/safe_browsing/
    (None, "safe_browsing_tab_observer.cc"),
    (None, "safe_browsing_blocking_page.cc"),
    (None, "client_side_detection_host.cc"),
    (None, "safe_browsing_navigation_observer_manager.cc"),
    (None, "ui_manager.cc"),
]

# Subtree to walk when auto-discovering which BUILD.gn lists a given .cc
# file. We intentionally limit this to the safe_browsing tree so we don't
# accidentally match an unrelated `ui_manager.cc` elsewhere in Chromium
# (there are MANY files named `ui_manager.cc` across the codebase!).
AUTO_DISCOVER_ROOT = "components/safe_browsing"


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

    # Idempotency (PER-FILE): we used to check `CLAUM_MARKER in text` which
    # told us only if SOMETHING in this BUILD.gn had been patched — fine
    # when each BUILD.gn was patched at most once, but with auto-discover
    # mode multiple cc filenames can point at the same BUILD.gn. Instead,
    # check for a line that looks like our previously-applied patch
    # specifically for THIS cc_name. That makes re-runs no-ops PER cc_name
    # without skipping later cc_names in the same file.
    already_patched_re = re.compile(
        # leading whitespace, our `# ` comment prefix, the quoted source
        # (possibly path-prefixed), optional comma, then the marker text.
        r'^\s*#\s*"[^"\n]*' + re.escape(cc_name) + r'",?\s+' + re.escape(CLAUM_MARKER),
        re.MULTILINE,
    )
    if already_patched_re.search(text):
        print(
            f"[fix-sb-components] {build_gn}: {cc_name} already patched "
            f"(per-file marker present), skipping"
        )
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


# --- Auto-discovery helper ---------------------------------------------------
# Walks the AUTO_DISCOVER_ROOT subtree looking for any BUILD.gn that contains
# the given .cc filename in a quoted string (i.e. probably a sources-list
# entry). Returns a list of matching BUILD.gn paths.
#
# Why we accept multiple matches: a .cc file can legitimately appear in two
# different BUILD.gn files if the same code is built into more than one
# target (e.g. one for production and one for tests). We patch all of them
# so ninja stops compiling that .cc anywhere.
def find_build_gns_with(src_root: pathlib.Path, cc_name: str) -> list:
    # Restrict search to the safe_browsing subtree to avoid matching
    # unrelated files with the same name elsewhere in Chromium.
    discover_root = src_root / AUTO_DISCOVER_ROOT
    if not discover_root.is_dir():
        print(
            f"[fix-sb-components] WARN: auto-discover root "
            f"{discover_root} not found; skipping {cc_name}"
        )
        return []

    needle = f'"{cc_name}"'  # match the .cc surrounded by quotes
    # Also allow a path prefix in front of the .cc name (e.g.
    # "content/browser/safe_browsing_tab_observer.cc"), so the search has
    # to be substring-style on the unquoted form too. We do a quick
    # cheap text search using `in` rather than regex for performance —
    # the file count is small.
    matches = []
    for build_gn in discover_root.rglob("BUILD.gn"):
        try:
            text = build_gn.read_text()
        except OSError:
            continue
        # Match either bare quoted ("foo.cc") or path-prefixed ("a/b/foo.cc").
        if needle in text or f'/{cc_name}"' in text:
            matches.append(build_gn)
    return matches


# --- Main loop ---------------------------------------------------------------
# Track failures so we can exit non-zero if anything goes wrong. We still
# attempt every target even if an earlier one fails — that gives the build
# log the most useful diagnostic surface in one shot.
all_ok = True
for rel_path, cc_name in TARGETS:
    if rel_path is None:
        # Auto-discover mode: search the safe_browsing subtree for any
        # BUILD.gn referencing this .cc file, then patch each one we find.
        candidates = find_build_gns_with(src_dir, cc_name)
        if not candidates:
            print(
                f"[fix-sb-components] WARN: auto-discover found no BUILD.gn "
                f"referencing {cc_name} under {AUTO_DISCOVER_ROOT}; skipping"
            )
            # Don't fail the build if a future Chromium roll has already
            # removed this file — the symptom we wanted to fix would be
            # gone too. Treat as success.
            continue
        # Patch every BUILD.gn that lists this .cc — see find_build_gns_with
        # docstring for why multiple matches are legitimate.
        for build_gn in candidates:
            ok = patch_one(build_gn, cc_name)
            if not ok:
                all_ok = False
    else:
        # Explicit mode: known BUILD.gn path, patch it directly.
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

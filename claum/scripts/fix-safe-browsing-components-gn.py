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
    # Run #84 dangling files — both live in
    #   components/safe_browsing/content/browser/triggers/
    # and broke ninja around tick [46948/55989]:
    #   * trigger_throttler.cc → "fatal error: 'components/safe_browsing/
    #     core/common/safe_browsing_prefs.h' file not found" (header
    #     stripped by ungoogled-chromium's safe_browsing patch).
    #   * trigger_manager.cc   → "use of undeclared identifier
    #     'IsExtendedReportingOptInAllowed' / 'IsExtendedReportingEnabled'"
    #     (same root cause: symbols come from the same stripped header).
    # Both are pure consumers of the disabled safe_browsing prefs surface,
    # so the standard Path-A treatment (drop them from sources lists) is
    # the right move — runtime safe_browsing is off anyway.
    (None, "trigger_throttler.cc"),
    (None, "trigger_manager.cc"),
    # ------------------------------------------------------------------------
    # Run #85 dangling files — three NEW consumers of the same stripped
    # safe_browsing_prefs.h header, this time inside chrome/browser/safe_browsing/
    # (NOT components/safe_browsing/). Build broke at ninja [46970..46978/55987]:
    #
    #   * chrome/browser/safe_browsing/metrics/bundled_settings_metrics_provider.cc
    #       → fatal error: 'components/safe_browsing/core/common/safe_browsing_prefs.h'
    #         file not found
    #
    #   * chrome/browser/safe_browsing/chrome_client_side_detection_host_delegate.cc
    #       → same missing-header error (transitively, via
    #         components/safe_browsing/content/browser/client_side_detection_host.h)
    #
    #   * chrome/browser/safe_browsing/url_checker_delegate_impl.cc:179
    #       → error: no member named 'IsEnhancedProtectionEnabled' in
    #         namespace 'safe_browsing' (symbol declared in the same
    #         stripped safe_browsing_prefs.h)
    #
    # All three .cc files are listed in the static_library("safe_browsing")
    # target inside chrome/browser/safe_browsing/BUILD.gn (we can tell from
    # the obj path: obj/chrome/browser/safe_browsing/safe_browsing/<name>.o).
    # Same Path-A treatment: drop them from sources so ninja stops compiling
    # them. Runtime safe_browsing is off anyway, so these consumers are dead
    # code in this build configuration.
    #
    # Why explicit BUILD.gn paths (not auto-discover): we know exactly which
    # BUILD.gn lists them (the obj path tells us), and we don't want to
    # widen AUTO_DISCOVER_ROOT to include `chrome/` because there are dozens
    # of unrelated files with the same names elsewhere in chrome/ (e.g.
    # other `url_checker_delegate_impl.cc` style names). Explicit is safer.
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "bundled_settings_metrics_provider.cc",
    ),
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "chrome_client_side_detection_host_delegate.cc",
    ),
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "url_checker_delegate_impl.cc",
    ),
    # ------------------------------------------------------------------------
    # Run #86 dangling files — FOUR more consumers of the same stripped
    # safe_browsing_prefs.h header. Same chrome/browser/safe_browsing/ layer
    # as the run #85 trio, peeled back one more level. Build broke at ninja
    # [46977/55984]:
    #
    #   * chrome/browser/safe_browsing/chrome_ping_manager_factory.cc:22
    #       -> fatal error: 'components/safe_browsing/core/common/safe_browsing_prefs.h'
    #          file not found.
    #
    #   * chrome/browser/safe_browsing/chrome_safe_browsing_tab_observer_delegate.cc
    #       -> same missing-header error (transitively, via
    #          components/safe_browsing/content/browser/client_side_detection_host.h).
    #
    #   * chrome/browser/safe_browsing/chrome_safe_browsing_blocking_page_factory.cc:67
    #       -> error: use of undeclared identifier
    #          'IsSafeBrowsingProceedAnywayDisabled' (symbol declared in
    #          the same stripped safe_browsing_prefs.h).
    #
    #   * chrome/browser/safe_browsing/chrome_password_protection_service.cc:131
    #       -> error: unknown type name 'ExtendedReportingLevel' (also
    #          declared in the stripped header).
    #
    # All four .cc files are listed in the static_library("safe_browsing")
    # target inside chrome/browser/safe_browsing/BUILD.gn (the obj path
    # `obj/chrome/browser/safe_browsing/safe_browsing/<name>.o` confirms
    # this — Chromium puts target outputs under
    # `obj/<dir-of-BUILD.gn>/<target-name>/<source>.o`).
    #
    # Same Path-A treatment: drop them from sources so ninja stops
    # compiling them. Runtime safe_browsing is off in this build anyway, so
    # these consumers are dead code in this configuration.
    #
    # Why explicit BUILD.gn paths (not auto-discover): we know exactly
    # which BUILD.gn lists them, and widening AUTO_DISCOVER_ROOT to
    # include `chrome/` would risk false-positive matches on other files
    # with the same names elsewhere in chrome/.
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "chrome_ping_manager_factory.cc",
    ),
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "chrome_safe_browsing_tab_observer_delegate.cc",
    ),
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "chrome_safe_browsing_blocking_page_factory.cc",
    ),
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "chrome_password_protection_service.cc",
    ),
    # ------------------------------------------------------------------------
    # Run #88 dangling files — SIX more consumers of the same stripped
    # safe_browsing_prefs.h header. This is the deepest layer yet:
    # `chrome/browser/safe_browsing/download_protection/` plus the sibling
    # `chrome/browser/safe_browsing/external_app_redirect_checking.cc`. All
    # listed in the same `static_library("safe_browsing")` target inside
    # `chrome/browser/safe_browsing/BUILD.gn` (obj path is
    # `obj/chrome/browser/safe_browsing/safe_browsing/<name>.o` for every
    # one — Chromium puts target outputs under
    # `obj/<dir-of-BUILD.gn>/<target-name>/<source>.o`, regardless of how
    # deep the .cc lives in subdirectories under that BUILD.gn).
    #
    # Build broke at ninja [46998..47004/55980] (i.e. ~47k of ~56k) with a
    # mix of "fatal error: file not found" and "use of undeclared
    # identifier" errors. Specific failure markers from the run #88 log:
    #
    #   * download_protection_service.cc:49
    #       -> fatal error: 'components/safe_browsing/core/common/
    #          safe_browsing_prefs.h' file not found.
    #   * download_protection_util.cc:23
    #       -> same missing-header error.
    #   * external_app_redirect_checking.cc:17
    #       -> same missing-header error.
    #   * check_file_system_access_write_request.cc:229
    #       -> error: use of undeclared identifier 'IsURLAllowlistedByPolicy'.
    #   * check_client_download_request.cc:367,396,405,433,437,438,474
    #       -> errors: use of undeclared identifier
    #          'IsEnhancedProtectionEnabled', 'AreDeepScansAllowedByPolicy',
    #          'GetSafeBrowsingState', 'SafeBrowsingState',
    #          'MatchesEnterpriseAllowlist'.
    #   * check_client_download_request_base.cc:87,90
    #       -> errors: use of undeclared identifier
    #          'IsExtendedReportingEnabled', 'IsEnhancedProtectionEnabled'.
    #
    # Every undeclared identifier above lives in `safe_browsing_prefs.h`
    # (or its sibling helper headers in the same dir), all of which the
    # ungoogled-chromium safe_browsing patch strips. So same Path-A
    # treatment: drop these files from the sources list. Runtime safe
    # browsing is off in Claum anyway, so these consumers are dead code.
    #
    # Why explicit BUILD.gn paths (not auto-discover): we know exactly
    # which BUILD.gn lists them, and AUTO_DISCOVER_ROOT only walks
    # `components/safe_browsing/`. Widening it to chrome/ would risk
    # false-positive matches against same-named files elsewhere.
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "download_protection_service.cc",
    ),
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "download_protection_util.cc",
    ),
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "external_app_redirect_checking.cc",
    ),
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "check_file_system_access_write_request.cc",
    ),
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "check_client_download_request.cc",
    ),
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "check_client_download_request_base.cc",
    ),
    # ------------------------------------------------------------------------
    # Run #89 dangling files — THREE more consumers of the same stripped
    # safe_browsing_prefs.h header. Same Path-A pattern as runs
    # #67/#82/#84/#85/#86/#87/#88 — peeling back another layer of
    # `chrome/browser/safe_browsing/` files that #include the stripped
    # `components/safe_browsing/core/common/safe_browsing_prefs.h`. This
    # round added two new sub-directories under chrome/browser/safe_browsing/:
    #   - gemini_antiscam_protection/  (new in this Chromium roll)
    #   - notification_telemetry/      (new in this Chromium roll)
    #
    # Build broke at ninja [46998..47007/55974] (~84% — deepest we've gotten
    # yet, which is good news: each fix peels back the next layer):
    #
    #   * chrome/browser/safe_browsing/gemini_antiscam_protection/
    #         gemini_antiscam_protection_service_factory.cc:15
    #       -> fatal error: 'components/safe_browsing/core/common/
    #          safe_browsing_prefs.h' file not found.
    #
    #   * chrome/browser/safe_browsing/notification_telemetry/
    #         notification_telemetry_service.cc
    #       -> same missing-header error.
    #
    #   * chrome/browser/safe_browsing/notification_telemetry/
    #         notification_telemetry_service_factory.cc
    #       -> same missing-header error.
    #
    # All three .cc files are listed in the static_library("safe_browsing")
    # target inside chrome/browser/safe_browsing/BUILD.gn (the obj path
    # `obj/chrome/browser/safe_browsing/safe_browsing/<name>.o` confirms
    # this — Chromium puts target outputs under
    # `obj/<dir-of-BUILD.gn>/<target-name>/<source>.o`, regardless of how
    # deep the .cc file lives in subdirectories under that BUILD.gn).
    #
    # Same Path-A treatment: drop them from sources so ninja stops
    # compiling them. Runtime safe_browsing is off in Claum anyway, so
    # these consumers are dead code in this configuration.
    #
    # Why explicit BUILD.gn paths (not auto-discover): same as runs #85/#86/#88
    # — we know exactly which BUILD.gn lists them, and AUTO_DISCOVER_ROOT
    # only walks `components/safe_browsing/`. Widening it to `chrome/`
    # would risk false-positive matches on same-named files elsewhere.
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "gemini_antiscam_protection_service_factory.cc",
    ),
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "notification_telemetry_service.cc",
    ),
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "notification_telemetry_service_factory.cc",
    ),
    # ------------------------------------------------------------------------
    # Run #90 dangling files — SIX more consumers of the same stripped
    # safe_browsing_prefs.h header. Same Path-A pattern as runs
    # #67/#82/#84/#85/#86/#87/#88/#89 — peeling back yet another layer of
    # `chrome/browser/safe_browsing/` files that #include the stripped
    # `components/safe_browsing/core/common/safe_browsing_prefs.h`.
    #
    # Notable: the previous fix (run #89, commit 45321eb) added 3 files
    # under brand-new sub-directories (gemini_antiscam_protection/,
    # notification_telemetry/), but it did NOT cover the older
    # `tailored_security/` subdir nor the top-level `safe_browsing_service.cc`
    # / `safe_browsing_pref_change_handler.cc`. Once those compile-units
    # advanced past their previous failure point, ninja exposed THIS next
    # batch of dangling consumers at almost the same tick (run #90 failed at
    # the `[47005..47011/55971]` cluster, ~84%).
    #
    # Build broke at ninja [47005..47011/55971] with these six FAILED
    # markers, all pointing at the same fatal error `'components/safe_browsing/
    # core/common/safe_browsing_prefs.h' file not found`:
    #
    #   * chrome/browser/safe_browsing/tailored_security/
    #         message_retry_handler.cc
    #       -> obj/chrome/browser/safe_browsing/safe_browsing/
    #          message_retry_handler.o
    #
    #   * chrome/browser/safe_browsing/tailored_security/
    #         tailored_security_service_factory.cc
    #       -> obj/.../tailored_security_service_factory.o
    #
    #   * chrome/browser/safe_browsing/safe_browsing_pref_change_handler.cc
    #       -> obj/.../safe_browsing_pref_change_handler.o
    #       (top-level under chrome/browser/safe_browsing/, not in a subdir)
    #
    #   * chrome/browser/safe_browsing/tailored_security/
    #         chrome_tailored_security_service.cc
    #       -> obj/.../chrome_tailored_security_service.o
    #
    #   * chrome/browser/safe_browsing/tailored_security/
    #         tailored_security_url_observer.cc
    #       -> obj/.../tailored_security_url_observer.o
    #
    #   * chrome/browser/safe_browsing/safe_browsing_service.cc
    #       -> obj/.../safe_browsing_service.o
    #       (top-level under chrome/browser/safe_browsing/, not in a subdir)
    #
    # All six .cc files are listed in the static_library("safe_browsing")
    # target inside chrome/browser/safe_browsing/BUILD.gn — confirmed by the
    # obj path `obj/chrome/browser/safe_browsing/safe_browsing/<name>.o`
    # (Chromium puts target outputs under
    # `obj/<dir-of-BUILD.gn>/<target-name>/<source>.o`, regardless of how
    # deep the .cc lives in subdirectories under that BUILD.gn).
    #
    # Same Path-A treatment: drop them from sources so ninja stops
    # compiling them. Runtime safe_browsing is off in Claum anyway, so
    # these consumers are dead code in this configuration.
    #
    # Why explicit BUILD.gn paths (not auto-discover): same reason as
    # runs #85/#86/#88/#89 — we know exactly which BUILD.gn lists them,
    # and AUTO_DISCOVER_ROOT only walks `components/safe_browsing/`.
    # Widening it to `chrome/` would risk false-positive matches on
    # same-named files elsewhere in the chrome/ tree.
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "message_retry_handler.cc",
    ),
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "tailored_security_service_factory.cc",
    ),
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "safe_browsing_pref_change_handler.cc",
    ),
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "chrome_tailored_security_service.cc",
    ),
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "tailored_security_url_observer.cc",
    ),
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "safe_browsing_service.cc",
    ),
    # ------------------------------------------------------------------------
    # Run #92 dangling files — FOUR more consumers of the same stripped
    # safe_browsing_prefs.h header. Same Path-A pattern as runs #67/.../#90.
    #
    # Build #92 (commit c49f07f) reproduced #91's failure exactly: ninja
    # halted at [47012..47021/55965] with these four FAILED markers, all
    # pointing at:
    #   fatal error: 'components/safe_browsing/core/common/safe_browsing_prefs.h'
    #                file not found
    #
    #   * chrome/browser/safe_browsing/
    #         client_side_detection_intelligent_scan_delegate_desktop.cc:17
    #     -> obj/chrome/browser/safe_browsing/safe_browsing/
    #        client_side_detection_intelligent_scan_delegate_desktop.o
    #
    #   * chrome/browser/safe_browsing/download_protection/
    #         download_protection_delegate_desktop.cc:15
    #     -> obj/.../download_protection_delegate_desktop.o
    #
    #   * chrome/browser/safe_browsing/download_protection/
    #         deep_scanning_request.cc:48
    #     -> obj/.../deep_scanning_request.o
    #
    #   * chrome/browser/safe_browsing/download_protection/
    #         cloud_binary_upload_service.cc
    #     -> obj/.../cloud_binary_upload_service.o
    #
    # All four are listed (with optional subdir prefix) in
    # chrome/browser/safe_browsing/BUILD.gn — confirmed by the
    # obj/<dir-of-BUILD.gn>/<target>/<name>.o output paths. The
    # patch_one regex tolerates `"download_protection/<file>.cc"`-style
    # entries because it matches `"[^"\n]*<cc_name>"`.
    #
    # Same Path-A treatment: comment them out so ninja stops compiling
    # them. Runtime safe_browsing is off in Claum, so they're dead code.
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "client_side_detection_intelligent_scan_delegate_desktop.cc",
    ),
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "download_protection_delegate_desktop.cc",
    ),
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "deep_scanning_request.cc",
    ),
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "cloud_binary_upload_service.cc",
    ),
    # ------------------------------------------------------------------------
    # Run #94 dangling files — THREE more consumers of the same stripped
    # safe_browsing_prefs.h header, this time in the
    # `chrome/browser/safe_browsing/extension_telemetry/` subdirectory.
    # Same Path-A pattern as runs #67/.../#92 — drop them from sources so
    # ninja stops compiling them. Runtime safe_browsing is off in Claum,
    # so they're dead code in this configuration.
    #
    # Build #94 (commit 90fa9e1) failed at ninja [47031..47033/55961] with
    # these three FAILED markers, all pointing at the same missing header:
    #   fatal error: 'components/safe_browsing/core/common/safe_browsing_prefs.h'
    #                file not found
    #
    #   * chrome/browser/safe_browsing/extension_telemetry/
    #         extension_telemetry_config_manager.cc:11
    #     -> obj/chrome/browser/safe_browsing/safe_browsing/
    #        extension_telemetry_config_manager.o
    #
    #   * chrome/browser/safe_browsing/extension_telemetry/
    #         search_hijacking_detector.cc:14
    #     -> obj/.../search_hijacking_detector.o
    #
    #   * chrome/browser/safe_browsing/extension_telemetry/
    #         extension_telemetry_service.cc:60
    #     -> obj/.../extension_telemetry_service.o
    #
    # All three are listed (with `extension_telemetry/` subdir prefix) in
    # chrome/browser/safe_browsing/BUILD.gn — confirmed by the
    # obj/<dir-of-BUILD.gn>/<target>/<name>.o output path. The patch_one
    # regex tolerates the subdir prefix because it matches
    # `"[^"\n]*<cc_name>"`.
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "extension_telemetry_config_manager.cc",
    ),
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "search_hijacking_detector.cc",
    ),
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "extension_telemetry_service.cc",
    ),
    # ------------------------------------------------------------------------
    # Run #95 dangling file — ONE more consumer in
    # `chrome/browser/safe_browsing/incident_reporting/`. This is a
    # Path-B failure (NOT a missing-header / Path-A like runs #87..#94).
    #
    # Build #95 (commit bdaeb90) reached ninja [47051/55958] and then died
    # with this clang error inside state_store.cc:
    #
    #   ../../chrome/browser/safe_browsing/incident_reporting/state_store.cc:88:46:
    #       error: no member named 'kSafeBrowsingIncidentsSent' in namespace 'prefs'
    #   ../../chrome/browser/safe_browsing/incident_reporting/state_store.cc:113:45:
    #       error: no member named 'kSafeBrowsingIncidentsSent' in namespace 'prefs'
    #
    # Translation for novice readers: state_store.cc is trying to read a
    # value out of `prefs::kSafeBrowsingIncidentsSent`, but that constant
    # was deleted by ungoogled-chromium's safe_browsing patch (the same
    # patch that strips `safe_browsing_prefs.h`, which is where this
    # constant used to be defined). Since the symbol no longer exists,
    # the file fails to compile.
    #
    # Same fix recipe as previous runs: comment the .cc out of the
    # `static_library("safe_browsing")` target in
    # `chrome/browser/safe_browsing/BUILD.gn`. Runtime safe_browsing is
    # off in Claum, so dropping incident-reporting plumbing changes
    # nothing user-visible — it's dead code in this configuration.
    #
    # Why this BUILD.gn (not auto-discover): ninja's failed-output path
    # was `obj/chrome/browser/safe_browsing/safe_browsing/state_store.o`,
    # and Chromium's path convention is
    # `obj/<dir-of-BUILD.gn>/<target>/<source>.o`, so the owning BUILD.gn
    # is unambiguously `chrome/browser/safe_browsing/BUILD.gn`. The
    # `patch_one` regex already tolerates the `incident_reporting/` subdir
    # prefix because it matches `"[^"\n]*<cc_name>"`.
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "state_store.cc",
    ),
    # ------------------------------------------------------------------------
    # Run #96 dangling files — TWO more consumers of the same stripped
    # safe_browsing_prefs.h header. Same Path-A pattern as runs
    # #67/.../#95: drop them from the static_library("safe_browsing")
    # target in chrome/browser/safe_browsing/BUILD.gn so ninja stops
    # compiling them. Runtime safe_browsing is off in Claum, so they
    # are dead code in this configuration.
    #
    # Build #96 (commit 50f2d8e) reached ninja [47059..47060/55956]
    # and then failed with these two FAILED markers:
    #
    #   * chrome/browser/safe_browsing/tailored_security/
    #         notification_handler_desktop.cc:25
    #     -> obj/chrome/browser/safe_browsing/safe_browsing/
    #        notification_handler_desktop.o
    #     -> fatal error: 'components/safe_browsing/core/common/
    #        safe_browsing_prefs.h' file not found.
    #
    #   * chrome/browser/safe_browsing/services_delegate_desktop.cc
    #     (the .h is in the include chain at line 12, but the .cc is
    #      what the [47060/55956] CXX rule was compiling)
    #     -> obj/chrome/browser/safe_browsing/safe_browsing/
    #        services_delegate_desktop.o
    #     -> fatal error: same missing safe_browsing_prefs.h.
    #
    # Why this BUILD.gn (not auto-discover): both ninja outputs land
    # under obj/chrome/browser/safe_browsing/safe_browsing/, and
    # Chromium's naming convention is
    # `obj/<dir-of-BUILD.gn>/<target>/<source>.o`, so the owning
    # BUILD.gn is unambiguously chrome/browser/safe_browsing/BUILD.gn.
    # patch_one's regex tolerates the optional `tailored_security/`
    # subdir prefix in the BUILD.gn entry because it matches
    # `"[^"\n]*<cc_name>"`.
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "notification_handler_desktop.cc",
    ),
    (
        "chrome/browser/safe_browsing/BUILD.gn",
        "services_delegate_desktop.cc",
    ),
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

    # NOTE on multi-match handling (run #83 fix):
    # ------------------------------------------
    # Earlier versions of this script bailed when len(matches) > 1, on the
    # theory that ambiguity = drift = unsafe. But run #83 hit the case
    # where `ui_manager.cc` legitimately appears TWICE in
    # `components/safe_browsing/content/browser/BUILD.gn` — once in the
    # production `sources = [...]` list and once in a test/sibling target
    # in the same file. Both references compile the same .cc, both fail
    # with the same "use of undeclared identifier" error, and both need
    # to be removed. Refusing to patch left the build perpetually broken.
    #
    # New policy: comment out ALL matching lines in this file. The pattern
    # `line_re` is anchored to `^...$` with re.MULTILINE so each match is
    # an exact whole-line hit on a quoted source list entry — false
    # positives (e.g. comments, deps lists) are extremely unlikely. If a
    # match accidentally lands somewhere harmless, commenting it out is a
    # no-op anyway.
    #
    # We DO log the multi-match case so the build log makes it obvious
    # we've moved past the old "refuse to patch" behavior.
    if len(matches) > 1:
        print(
            f"[fix-sb-components] note: {len(matches)} matches for "
            f"{cc_name} in {build_gn} — patching all (run #83 policy)"
        )

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

    # `count=0` means "replace ALL matches" (re.sub default). Important for
    # the multi-match case described above. For single-match files this is
    # equivalent to count=1 and behaves the same as before.
    new_text, n = line_re.subn(do_replace, text, count=0)
    # We expect n == len(matches). If it doesn't, our regex/findall got out
    # of sync somehow — bail loudly rather than write a half-patched file.
    if n != len(matches):
        print(
            f"[fix-sb-components] ERROR: expected {len(matches)} substitutions "
            f"but did {n} in {build_gn}"
        )
        return False

    build_gn.write_text(new_text)
    print(
        f"[fix-sb-components] patched {build_gn}: commented out "
        f"{n} source reference{'s' if n != 1 else ''} to {cc_name}"
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

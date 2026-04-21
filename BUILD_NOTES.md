# Claum build debug notes

Running log of failures and fixes. Newest at top. The scheduled task
`claum-build-watcher` reads this to pick up context between runs.

## Run #22 — triggered 2026-04-20 (commit 4b1fad2)

Applied three fixes for the `DarwinFoundation1.modulemap missing` error
that killed run #21 (and earlier iterations):

1. `runs-on: macos-14` → `macos-15` — newer Xcode (16.3+) ships the
   numerically-suffixed modulemaps Chromium 146 references.
2. Added `use_clang_modules=false` and `treat_warnings_as_errors=false`
   to GN_ARGS in claum/scripts/build-mac.sh.
3. Added a pre-`gn gen` step in build-mac.sh that creates
   `<Name>1.modulemap -> <Name>.modulemap` symlinks in the SDK include
   dir for every non-numerically-suffixed modulemap. Belt-and-suspenders
   in case the gn args don't fully suppress the reference.

If run #22 still fails with modulemap errors → try patching
`buildtools/third_party/libc++/BUILD.gn` to drop the modulemap input
entirely. Last-resort option is `use_system_xcode=true`.

## Known-good fixes applied in previous runs

- `claum/scripts/fix-safe-browsing-gn.py` — two-fix helper that patches
  chrome/browser/safe_browsing/BUILD.gn after the ungoogled patch:
  - Fix #1: flip `if (false) {` → `if (true) {` inside
    `static_library("safe_browsing") { ... }` so the variable
    definitions (sources, deps, allow_circular_includes_from, configs,
    public_deps) actually execute.
  - Fix #2: insert `if (!defined(sources)) { sources = [] }` and the
    same for `deps` inside the inner `if (safe_browsing_mode != 0)`
    block, as a safety net.

## Errors we've seen, in order

| Run | Error | Fix |
|-----|-------|-----|
| 24702394300 | gn "Expecting assignment" line 746 | reverted a bogus brace-removal "Fix A" |
| 24703337395 | gn "Undefined identifier" allow_circular_includes_from line 321 | added Fix #1 to fix-safe-browsing-gn.py |
| 24704783537 | ninja DarwinFoundation1.modulemap missing | speculative use_libcxx_modules=false (failed — exit 127 before it ran) |
| 24706328020 | bash exit 127 "command not found" at GN_ARGS | moved multi-line comment OUT of double-quoted string |
| 24707434994 | _in progress_ | — |

## Repo facts

- GitHub: https://github.com/Jac2017/claum-browser
- Workflow: .github/workflows/build-mac.yml (workflow_dispatch only)
- Runs at: https://github.com/Jac2017/claum-browser/actions/workflows/build-mac.yml
- PAT stored at: /sessions/wonderful-stoic-lamport/.gh_token (600 perms, outside repo)
- Current runner: macos-15 (M1, Apple Silicon)
- Target arch: arm64
- Default search: bing
- Chromium version: 146.0.7680.164

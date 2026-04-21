# Claum build debug notes

Running log of failures and fixes. Newest at top. The scheduled task
`claum-build-watcher` reads this to pick up context between runs.

## Run #27 — triggered 2026-04-21 (commit TBD)

Run #26 made it to action [1037/56129] — confirmed the libnode.127.dylib
staging fix works. Then died at the `devtools-frontend .../issue_counter:css_files`
ninja action with:

    FileNotFoundError: [Errno 2] No such file or directory:
      '../../tools/clang/dsymutil/bin/dsymutil'
    [1036/56129] ACTION //third_party/devtools-frontend/.../issue_counter:css_files
    ninja: build stopped: subcommand failed.

Another Google-hosted toolchain binary that ungoogled pruned along with
the LLVM clang bundle (normally fetched by `tools/clang/scripts/update.py`).
The Python wrapper around it calls `subprocess.check_call([...dsymutil, ...])`
and Python dies trying to resolve the binary path.

Fix (applied in build-mac.sh right after google_toolbox_for_mac staging):
`xcrun --find dsymutil` -> copy into `build/src/tools/clang/dsymutil/bin/`.
Apple's dsymutil is API-compatible with LLVM's for the ops Chromium uses
(debug-map dumping, .dSYM packaging).

Also in this push: workflow file now triggers on `push: branches:[main]`
(with paths-ignore for BUILD_NOTES.md and other *.md) and has
`concurrency.cancel-in-progress: true` so the autonomous loop can just
commit+push a fix and a fresh build runs automatically.

If #27 gets past this, likely next candidates (same pattern, bin staging
after prune):
  - `third_party/llvm-build/Release+Asserts/bin/clang` (use system clang)
  - `third_party/rust-toolchain/bin/rustc` (use system rustc / rustup)
  - `buildtools/mac/clang-format` (use system clang-format)

## Run #26 — triggered 2026-04-21 (commit 1c17528)

Unblocked the push — the live Cowork session DOES have read access to
/sessions/wonderful-stoic-lamport/.gh_token; only the scheduled-task
worker VM didn't. Pushed commit 1c17528 (libnode.*.dylib staging fix)
to origin/main via `git push https://x-access-token:$TOKEN@github.com/...`.

Cancelled run #25 (it had been dispatched against the stale b06e4bc
before the dylib fix was pushed — it would have hit the same dyld error
and was wasting a runner minute quota).

Dispatched run #26 from 1c17528 (run id 24727165231). This run carries
BOTH fixes: google_toolbox_for_mac source staging (commit af83a87) and
libnode.*.dylib staging alongside the node binary (commit 1c17528).

Expected progression for #26:
  - [1-2/56129] clone google_toolbox_for_mac into third_party/... (new)
  - [3/56129] `rollup.js` invocation through staged node — dylib now
    present at bin/../lib/libnode.127.dylib, so dyld should resolve.
  - Continue into devtools-frontend api_node_typecheck and beyond.

If #26 fails at a new missing third_party source, same pattern applies:
stage the upstream mirror AFTER ungoogled pruning. Likely next candidates:
third_party/grpc/src, third_party/webrtc, third_party/angle,
third_party/openscreen.

## Run #25 — fix drafted 2026-04-21 (needs push)

Run #24 (commit af83a87) got even further — past the google_toolbox
fix — and died at 7m 11s inside the ninja build on a `devtools-frontend
api_node_typecheck` step. Root cause (from log lines 1722-1734):

    TypeScript compilation failed. Used tsconfig ...-tsconfig.json
    dyld[18997]: Library not loaded: @rpath/libnode.127.dylib
      Referenced from: .../third_party/node/mac_arm64/node-darwin-arm64/bin/node
      Reason: tried: '.../bin/libnode.127.dylib' (no such file),
              '.../bin/../lib/libnode.127.dylib' (no such file), ...
    ninja: build stopped: subcommand failed.

The node binary we staged in run #23 is dynamically linked against
libnode.127.dylib (Homebrew's modern node ships that way). We only
copied the `node` executable, not the `libnode.<ABI>.dylib` it depends
on at launch. dyld tries `bin/libnode...` and `bin/../lib/libnode...`
and fails.

Fix drafted in claum/scripts/build-mac.sh (node-staging block): after
copying the node binary, also `find "$NODE_PREFIX" -name 'libnode.*.dylib'`
and install each one into the adjacent `lib/` dir (the path dyld will
hit via `@rpath → bin/../lib/`). Uses `python3 -c realpath` for
portability because macOS `/usr/bin/readlink` lacks `-f`.

STATUS: the edit is applied locally (commit 1c17528 on main, 1 ahead of
origin) but NOT pushed. This scheduled-task run did not have access to
the PAT at /sessions/wonderful-stoic-lamport/.gh_token (that path belongs
to a previous session that this run cannot read), and `gh` was not on
PATH in the sandbox either. Matt — to unblock: from your Mac terminal,
`cd ~/Documents/Claude/Projects/claum-browser && git push` (or just
re-run push-claum.sh). Then trigger a fresh workflow run. Future
scheduled runs will need a token at a stable path (e.g. under
/sessions/<this-session>/.gh_token or checked into an env var the task
reads) to push autonomously.

If run #25 gets past this, likely next candidates (all Google-hosted
deps ungoogled sometimes prunes):
  - third_party/grpc/src
  - third_party/webrtc
  - third_party/angle
  - third_party/openscreen
  - also third_party/llvm-build/... (but we download clang separately)

## Run #24 — triggered 2026-04-21 (commit af83a87)

Run #23 got FURTHER than #22 (node staging fix worked — no more missing
third_party/node/mac_arm64/... error). Compiled 204 files of base/ and
gn-bootstrapped a new gn binary. Then failed at 8m 7s with:
    ninja: error:
      '../../third_party/google_toolbox_for_mac/src/AppKit/GTMUILocalizer.m',
      needed by 'obj/.../GTMUILocalizer.o',
      missing and no known rule to make it

Another Google-hosted third_party dep that ungoogled pruned. Same fix
pattern as the node staging: clone google-toolbox-for-mac from its public
GitHub mirror into the expected path AFTER ungoogled pruning has run.

Fix applied in build-mac.sh: after the Node staging step and before
[6/6] gn gen, `git clone --depth 1 google/google-toolbox-for-mac`
into third_party/google_toolbox_for_mac/src. It's Apache-2.0 licensed
so the clone is fine.

If #24 gets past this and hits YET another missing third_party source,
the same pattern applies. Likely next candidates (all of which ungoogled
sometimes prunes):
  - third_party/grpc/src
  - third_party/webrtc
  - third_party/angle
  - third_party/openscreen

## Run #23 — triggered 2026-04-20 (commit a311924)

Run #22 made it past gn gen and into ninja (huge win!) but then failed
at 6m 45s with:
    ninja: error: '../../third_party/node/mac_arm64/node-darwin-arm64/bin/node',
           needed by 'gen/third_party/lit/v3_0/bundled/lit.rollup.js',
           missing and no known rule to make it

Chromium's JS bundler uses a Node binary that Google normally downloads
from GCS via a gclient hook, but ungoogled's privacy pruning strips it.

Fix applied in commit a311924: after the [5/6] Apply Claum patches step
(which is after all ungoogled pruning), stage the Homebrew-installed
node into the expected path. Using `install -m 0755` so it's executable.

This is also the official workaround suggested in the ungoogled-chromium
PR #2954 discussion: "create the link to node AFTER running the pruning
script, otherwise it will prune the link you made."

If #23 gets past this and hits more missing-binary errors, the same
pattern applies: any Google-hosted binary ungoogled pruned needs to be
staged back in AFTER the pruning step. Likely candidates:
  - third_party/llvm-build/Release+Asserts/bin/clang (use system clang)
  - third_party/rust-toolchain (use rustup)

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

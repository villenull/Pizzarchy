# P3.6 stable rebase — the finish line (what's left after session 27)

**Written 2026-08-15 (session 27).** The hardware-free rebase is ~90% done and
split across `main` and a branch. This is the exact remaining work, so the next
session (Opus — this is release-plumbing) can finish it without re-deriving.

## What is DONE and on `main`
- Pin measured from inside the stable ISO: `T9-stable-pin.md`.
- 127-commit delta classified, 4 seams: `T9-stable-delta-classification.md`.
- Deck update runbook: `docs/tasks/P36-deck-stable-update-runbook.md`.
- PROGRESS §5.31 / ROADMAP P3.6 / START-HERE updated.

## What is DONE and on the branch `stable-rebase-pin` (commit `5aaed0e`)
Verified-clean pieces of the pin bump, kept OFF `main` because the test suite is
not yet green with them:
- `iso/upstream` submodule `a12bfea` → **`174dd82`**. This alone fixes the one
  BREAKS-US row — the orchestrator now calls `omarchy-apply-system` (checked: 5
  refs, 0 `setup-system`). All 5 overlay patches apply clean on it
  (`git apply --3way --check`, verified).
- `iso/{RUNTIME,UPSTREAM,PKGS}` → `f0020448` / `174dd82` / `bb66b9d`.
- `iso/bin/build`: `BUILD_MIRROR` `edge`→`stable`; `RUNTIME_PACKAGE`
  `omarchy-dev`→`omarchy`; `SETTINGS_PACKAGE`→`omarchy-settings`; guard 6.1
  comments updated.

## Why it's not on `main`: `test/unit/test-iso-build.sh` fixtures are still `-dev`

With `RUNTIME_PACKAGE=omarchy`, `iso/bin/build`'s guard looks for
`pkgbuilds/omarchy` and a runtime that ships `omarchy-apply-system`. The test's
**fixtures** still build `pkgbuilds/omarchy-dev` and an `omarchy-setup-system`
finalizer, so the suite fails (correctly — it's testing the old shape). This is
**Path A** (build the *released* `omarchy` package locally, matching upstream's
stable ISO exactly). `omarchy-pkgs@bb66b9d` **does** ship `pkgbuilds/omarchy`, so
Path A is viable — confirmed, not assumed.

### The fixture refactor (careful — false-green risk)
In `test/unit/test-iso-build.sh` (~16 `omarchy-dev` + ~25 `omarchy-setup-system`
refs): move fixture package name `omarchy-dev`→`omarchy`,
`omarchy-settings-dev`→`omarchy-settings`, and the finalizer fixture
`omarchy-setup-system`→`omarchy-apply-system`. **Do NOT blind-sed** — some refs
are deliberately testing that guard 6.4a *fires* (e.g. case 12, ~L564, mv-renames
the finalizer to prove the guard catches a runtime that dropped the called
binary). Those cases must keep asserting a `build_fail`; only the *baseline
happy-path* fixtures move to the release names. Re-run after `git add` (untracked
new suites slip the shellcheck glob — the thrice-learned trap).

### Alternative — Path B (smaller, but produces a mislabeled ISO)
Keep `RUNTIME_PACKAGE=omarchy-dev` (built locally from the f0020448 source; its
recipe does `provides=omarchy`+`conflicts=omarchy`), move only the channel. Suite
stays green with no fixture edits, but the ISO would carry `omarchy-dev
4.0.0.rN.gf002044`, not `omarchy 4.0.0-1` — inconsistent with a "4.0.0 stable"
release ISO. **Prefer Path A** unless the operator decides the label doesn't
matter. This is the one genuine operator decision in the rebase.

## Then: the actual ISO rebuild (not yet run)
1. `OMARCHY_DECK_PKGS_SRC` → an `omarchy-pkgs@bb66b9d` checkout (has
   `pkgbuilds/omarchy`). `OMARCHY_DECK_RUNTIME_SRC` → `basecamp/omarchy@f0020448`.
2. Give it a **fresh scratch cache** (`OMARCHY_DECK_ISO_BUILD_DIR=…`) — the
   `omarchy-iso-make` `rm -rf` trap (§3.10). Not `iso-build`/`iso-build-2`.
3. **Block synchronously** on the build (chained `timeout` Bash calls); do NOT
   arm a Monitor and yield (the twice-learned stall, START-HERE session-24 note).
4. Verify the built ISO carries **`omarchy 4.0.0-1`** in its offline mirror
   (`var/cache/omarchy/mirror/offline/omarchy-4.0.0-1-any.pkg.tar.zst`) and
   channel `stable` (`root/omarchy_mirror`), and re-inspect the two image facts
   (no `libwayland*`; LUKS default). Record filename/size/sha256.

## Optional: substrate rebuild + full suite (authorized, lower marginal value)
`test/images/vm-neptune-image.sh` with `IMG_OMARCHY_SERVER=https://stable-mirror.omarchy.org/$repo/os/$arch`
(or the stable pkgs URL) rebuilds the QEMU substrate on the stable channel;
then the 15 unit + 4 VM suites + `osk-tty-e2e.py`. Boot chain was classified SAFE
(defaults byte-identical), so this is confirmatory. ⚠️ the prev-substrate note
(§1.1) warns the stable-channel rebuild may hit a broken upstream Arch mirror and
need a workaround.

## To land the branch on main
Finish the fixture refactor, get `test/unit/test-iso-build.sh` + the shellcheck
CI command + the pin/payload suites green, ideally after a successful ISO
rebuild, then `git merge stable-rebase-pin` (or PR it). Baseline for attribution
(session 27): 18/20 sh green + 13/13 py green, 2 pre-existing reds
(`test-ci-workflow.sh`, `test-vm-probe-integrity.sh`) unrelated to the rebase.

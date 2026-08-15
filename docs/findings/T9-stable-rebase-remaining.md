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

## 🔴 UPDATE 2026-08-15 (session 27) — the real build was RUN; Path A hits TWO blockers

The operator chose Path A and asked to finish the rebuild. I ran the real docker
build (branch `stable-rebase-pin`, sources `runtime-src@f0020448` +
`pkgs-src@bb66b9d`, fresh scratch `iso-build-stable`). **The stable rebase itself
is correct — the build passed every rebase-related stage:** guard 6.1
(quattro/stable agree), the runtime/pkgs pins, all 5 overlay patches, guard 6.4a
(orchestrator now calls `omarchy-apply-system`, 424 candidates), and it **built
`omarchy 4.0.0-1` and `omarchy-deck 0.2.0-1` locally and placed them in the
offline mirror.** Then it hit two walls, neither caused by the rebase:

### Blocker 1 — `gamescope-session` is a nonexistent package (pre-existing, §14.6)
The build died in-container at `deck-nvidia-dry-run`: `error: target not found:
gamescope-session`. **`gamescope-session` exists in NO Valve repo** (checked holo,
jupiter, jupiter-staging, holo-staging — jupiter-staging ships `gamescope`
3.16.25-3 but no session package). It was added to
`iso/overlay/configs/deck/deck-install.packages:90` in commit `56c6578` (session
26) to fix the §14.6 "lands in Desktop Mode not Gaming Mode" gap — but the last
real ISO build (session 25, `a27230ff`) predates it, so **this line was never
build-validated and names a package that does not exist.** Independent of the
Omarchy channel (Valve repos are queried the same either way). **Decision owed:**
what actually provides the Gaming-Mode gamescope session now — this is the open
§14.6 question, not a rebase issue. (I fixed a *separate* real channel bug found
here: `deck-valve-repos.patch` targeted `pacman-online-edge.conf`; retargeted to
`stable.conf` so the Valve repos land in the config the stable build reads —
committed on the branch, `4a4073c`. Without it `steamdeck-dsp` didn't resolve.)

### Blocker 2 — guard 6.4b vs release-package versioning (Path A design issue)
Even with gamescope-session fixed, the build would then be **rejected by guard
6.4b** (`iso/bin/build:1108-1111`): it requires the runtime package version to
carry iso/RUNTIME's git short-sha (`*".g$RUNTIME_SHORT"*`), which is how it proves
the ISO's runtime came from our pin and not the channel. The **released `omarchy
4.0.0-1` has a static pkgver with no `.gSHA`**, so `4.0.0-1` fails the pattern
(verified). The `-dev` packages carry it (`4.0.0.rN.gSHA`); the release does not.
**Path A therefore needs guard 6.4b made channel-aware** — on `stable` the channel
serves the *same* fixed release our `--local-source` builds, so the sha-provenance
check is moot there and should be replaced by a release-version-equality check (or
a built-vs-channel content check). This is a **load-bearing boot-chain guard change
= Opus + operator awareness**, not a mechanical edit. It also means the
`test-iso-build.sh` fixture refactor must model whichever invariant is chosen —
completing it against the *old* sha-carrying version would false-green a guard the
real Path A build fails, so I reverted the partial fixture edits rather than ship a
misleading green.

### So: is Path A still the right call?
Both blockers are real. Path A (released `omarchy`, matches upstream's ISO exactly)
now clearly costs: (a) resolve the gamescope-session Gaming-Mode question, and (b)
a guard-6.4b redesign. **Path B** (keep building `omarchy-dev` locally from
`f0020448` — it carries the sha, satisfies 6.4b untouched, and is byte-identical
source to `omarchy 4.0.0-1`) sidesteps (b) entirely; it still hits (a). Given (b),
Path B may now be the pragmatic choice — but that reverses the operator's stated
preference, so it is theirs to make with this new information. **Neither path can
produce a real ISO until the gamescope-session question is answered.**

---

# ✅ RESOLVED 2026-08-15 — operator chose Path B; the ISO BUILDS

Everything above is kept as the reasoning that led here. Outcome:

## The artifact
**`omarchy-2026.08.15-x86_64-quattro.iso`** — 6,854,164,480 B (6.38 GiB),
sha256 **`e9fbd8edb8c69d698c5e575955a2dd27d4f394a704c7b6b55744a817748368c5`**,
`BUILD EXIT 0`, **all eight guards green** (6.1, 6.3, 6.4a, 6.4b, 6.5a, 6.5b, 6.6).
At `~/.cache/omarchy-deck/stable-rebase/iso-build-stable/release/`.

## Blocker 2 — dissolved by measurement, no guard change needed
Path B keeps the `-dev` package NAMES on the `stable` channel. The key fact,
measured rather than assumed: **`pkgs.omarchy.org/stable` serves
`omarchy-dev-4.0.0.r1744.gf002044-1`** — and `gf002044` *is* `iso/RUNTIME`'s pin.
So on stable the `-dev` build **is** the release commit, and guard 6.4b's
sha-provenance check keeps working untouched. (On `edge` it would not: edge already
serves `r1746.gb724f76`, two commits past the release — an independent reason
`BUILD_MIRROR=stable` is right.) Our local build produced exactly
`4.0.0.r1744.gf002044-1`; guard 6.4b passed with no redesign.

## Blocker 1 — root-caused and FIXED (this is the real §14.6 bug)
`gamescope-session` exists in **no** Valve repo (all four package DBs checked).
The session file autologin looks for is shipped by the **gamescope package itself,
and only Valve's build**:

| package | ships `usr/share/wayland-sessions/gamescope-wayland.desktop`? |
|---|---|
| `jupiter-staging/gamescope` 3.16.25-3 | **yes** (plus `usr/bin/start-gamescope-session`) |
| `extra/gamescope` 3.16.25-1 (Arch) | **no** — no `wayland-sessions/` at all |

`deck-mirror.packages` already put Valve's build in the offline mirror, but
**nothing installed it** — `omarchy-deck` does not depend on it and no list named
it — so the target never got the session file and `src/deck-session.sh:931` told
the user to run `pacman -S jupiter-staging/gamescope` by hand. `deck-install.packages`
now names `gamescope` bare.

That exposed a **structural conflict worth remembering**: a package may
legitimately appear in *both* Deck lists — `deck-mirror.packages` decides WHICH
BUILD (repo-qualified), `deck-install.packages` decides THAT IT IS INSTALLED
(bare, single-repo offline resolve) — and both feed the online download, so pacman
aborted on `duplicate target`. `deck-packages.patch` now strips the bare form from
the DOWNLOAD list only. The qualified form must be the survivor: a bare `gamescope`
sent online resolves by **repo order** to Arch's compositor, and the mistake would
be invisible until a target booted into Desktop Mode.

## Verified ON THE BUILT ARTIFACT (not inferred from the build log)
- `root/omarchy_mirror` = **`stable`**; `root/omarchy_iso_ref` = `quattro`
- offline mirror carries `omarchy-dev` + `omarchy-settings-dev`
  **`4.0.0.r1744.gf002044-1`**, `omarchy-deck 0.2.0-1`, and **`gamescope 3.16.25-3`**
  (Valve's — packager `ci-package-builder@steamos.cloud`)
- that gamescope package contains **both** `gamescope-wayland.desktop` and
  `start-gamescope-session` (the two things `deck-session.sh` checks for)
- **`gamescope` is in the ISO's merged install list** (`usr/share/omarchy-iso/omarchy-base.packages`),
  so pacstrap installs it — the mirror-vs-installed distinction that made §14.6
  silent on the build side
- live environment still has **0** `libwayland*` and no compositor binary — T8's
  self-drawn-OSK premise holds on stable

## Other real fixes this required
- `deck-valve-repos.patch` retargeted `pacman-online-edge.conf` →
  `pacman-online-stable.conf` (the config a stable build actually reads; without
  it `steamdeck-dsp` did not resolve at all)
- T12 fixture refreshed to the new pin: `Service.qml` 471→551 lines,
  `limine.conf` **byte-identical**, and **both shipped runtime patches still
  apply** (`test-t12-patch-applier.sh` 38/38) — the seam doing its job
- `test-deck-form.sh` caught genuine upstream drift: stable calls `keyboard_form`
  bare, not `keyboard_form true`. Fixed to match the *call* rather than its
  spelling — and its greps now carry `|| true`, because under `set -euo pipefail`
  a no-match killed the suite inside a command substitution **before** its own
  `|| fail` could report (33 passes, exit 1, no diagnosis). Fail loudly.

## ~~⚠️ What this does NOT prove~~ → ✅ PROVEN, same session

*(Written before the install test ran, kept for the record: "the §14.6 fix is
verified at the payload level … no install run has been done against this ISO,
so 'first boot lands in Gaming Mode' remains unverified.")*

**It has now been run and it passed.** `test/vm/vm-install-controller-test.sh`
against this ISO: **18/18, `install.outcome=success`**, and the disk-image
assertions — gated on a completed install and never executed before in this
project — ran and passed. On the installed target:
`gamescope-wayland.desktop`, `/usr/bin/gamescope`, `start-gamescope-session`,
`gamescope-3.16.25-3` (Valve's) in the pacman DB, **`autologin: gaming`**, and
`Session=gamescope-wayland` in the sddm config. Every `configure_deck` step
succeeded. **Phase 2 exit criterion 1 is closed.**
Detail: `docs/findings/T4-controller-only-install-first-run.md` §15.

Still outstanding, and genuinely: **QEMU is not a Deck.** Gaming Mode
*rendering* and usability on the panel remain P3.2, on hardware.

## Benign build-log note
`==> ERROR: Invalid option -k -- '/boot/vmlinuz-linux' must be readable` appears
mid-build and is **not** a failure: it is a stale `linux.preset` for the plain
`linux` package, which the live ISO does not install. The live kernel is
`linux-t2`, and its initramfs generated successfully two lines earlier. Build
exit 0.

## Landed
Merged to `main`. `main` after the merge: shellcheck green, **18/20 sh**, **13/13
py** — identical to the pre-rebase baseline, with the same two pre-existing reds
(`test-ci-workflow.sh` = CI storage policy, `test-vm-probe-integrity.sh` = a
scanner that cannot classify a heredoc). **No regressions.**

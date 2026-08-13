# T12 — the upstream-patch seam: work spec

**Design and evidence: `docs/findings/T12-upstream-patch-seam.md`. Read it
first — this file is the build order, not the argument.**

**Status:** specified 2026-08-11 (session 21). ⚠️ **The "not started" that stood
here until 2026-08-12 was wrong** — session 21 built most of §3 and never
updated this line. Already in the tree: `src/omarchy-deck-patches/` with the
applier (`omarchy-deck-apply-patches`), the ALPM re-apply hook
(`50-omarchy-deck-reapply-patches.hook`), the failure-surfacing unit
(`omarchy-deck-patch-check.service`) and two patches with `.meta` files
(`0010-lock-blank-timer-20s`, `0020-limine-interface-rotation`), plus
`test/unit/test-t12-patch-applier.sh` at **38 passing assertions**.
**Still owed:** ~~`bin/build`'s guard 6.6~~ ✅ **landed 2026-08-12**;
registering the applier as a
`configure_deck` step, shipping the payload in the `omarchy-deck` package, and
every `[V]`/`[H]` row in §2 — including the destruction test. Check §2's boxes
against the tree before believing any of them.
**Model:** Opus. Same class as `docs/PLAN.md` §11's pacman-hook row — a wrong
guess is silent and boot-adjacent.
**Depends on:** T5d (the `omarchy-deck` package + the `configure_deck` phase
must exist before anything can be shipped in them).
**Size:** S, and it is **not a new slice** — see §0.

---

## 0. This is T5f, widened. Do not open a parallel track.

`docs/tasks/T5-fork-plan.md` §5.2 already requires "an ALPM `PostTransaction`
hook in the `omarchy-deck` package, triggered on
`omarchy-dev`/`omarchy-settings-dev`, that re-applies it" for the Limine
template. That is the same package, trigger, root (`/usr/share/omarchy`) and
failure mode as the lock-timer patch. **One applier, one hook, two patches.**

The T5 edits this implies — for whoever owns those files, not for this task:

- **§5** gains row **5.7** (text is in the finding, §5).
- **§6** gains guard **6.6**: `bin/build` `git apply --check`s every runtime
  patch against the pinned `basecamp/omarchy` checkout and fails on a reject.
  It belongs in **T5b**, where `--local-source` is wired.
- **§7** gains **no row**. T5f absorbs this.
- **§3 gains no S7.** The finding §2 D rejects patching the RUNTIME checkout at
  build time, deliberately overruling
  `docs/findings/T9-lock-wake-and-blank-timing.md` §5.2's proposal. Read that
  section before re-proposing it.

---

## 1. Steps

**1. `iso/overlay-runtime/patches/` + the first patch.**
`0010-lock-blank-timer-20s.patch` — the one-line diff from
`docs/findings/T9-lock-wake-and-blank-timing.md` §5.2 (`interval: 5000` →
`20000`), `-p1`, paths relative to the `basecamp/omarchy` tree root. Plus a
`.meta` sibling naming: the owning requirement (`docs/PROGRESS.md` §5.24a row
2), the target file, and the post-conditions
(`assert_count shell/plugins/lock/Service.qml 'interval: 20000' 1`, plus
`qmllint` because it is a `.qml`).

**2. `omarchy-deck-apply-patches`.** The contract is the finding §3.3, in
order: reverse-check (idempotence) → forward-check (drift) → apply →
post-conditions → `patch-state.json` → non-zero exit if anything is not `ok`.
`set -euo pipefail`. **`git apply`, never `sed`** — the finding §3.3 says why,
with three upstream commits as evidence. **It must not restart the shell**
(finding §3.3, last paragraph — the relaunch path is the one classified
BREAKS US).

**3. The hook**, `50-omarchy-deck-reapply-patches.hook`, installed to
`/usr/share/libalpm/hooks/`. `Type = Package`; targets `omarchy-dev`,
`omarchy`, `omarchy-settings-dev`, `omarchy-settings`; `When = PostTransaction`;
`Depends = omarchy-deck`. **Not `Type = Path`** — measured to miss an upstream
rename silently (finding §2 M3).

**4. `configure_deck` calls the applier** once, inside the target, after
`run_system_finalizer`; a non-zero exit fails the install.

**5. The loud channels.** `omarchy-deck-patch-check.service` (boot oneshot,
`--verify`, leaves a *failed unit* on drift, notifies when a session exists),
and a `src/deck-session.sh` precondition that refuses to proceed against a Deck
whose `patch-state.json` is not `ok`.

**6. Fold in 5.2's Limine-template half** as `0020-limine-interface-rotation.patch`
against `default/limine/limine.conf`. ⚠️ `/boot/limine.conf` is **not**
package-owned and stays with `configure_deck` + the S6 pre-refresh hook — the
applier owns `/usr/share/omarchy` and nothing else.

---

## 2. Done when

- [ ] **[B]** `bin/build` fails on a patch that does not apply to the pinned
      runtime checkout (guard 6.6), and the message names the patch and both
      SHAs.
- [ ] **[B]** Applier unit tests, all five, negatives included:
      (1) clean apply; (2) **second run exits 0 and changes nothing**;
      (3) a fixture carrying upstream's real `interval: 3000` (commit
      `35a6940`) exits non-zero and names the file; (4) a fixture where the
      target file was renamed away exits non-zero; (5) a patch that applies but
      breaks the QML fails on `qmllint`. *(A guard nobody has seen fail is not
      a guard — `docs/tasks/T5-fork-plan.md` §5.4.)*
- [ ] **[V]** QEMU: after install, `interval: 20000` is present **and**
      `patch-state.json` says `ok`.
- [ ] **[V]** The **destruction test**: re-install `omarchy-dev` from the
      cached package in the installed target, then re-assert both. Without this
      the row passes for the wrong reason. Notes: `pacman -U` does not trip
      upstream's direct-upgrade guard, `pacman -Syu` needs
      `OMARCHY_ALLOW_DIRECT_PACMAN=1`; confirm the package file is actually
      still on disk post-install before relying on it (finding §7 lists this as
      inferred).
- [ ] **[V]** Drift is visible without a terminal: with a deliberately stale
      patch, `systemctl --failed` is non-empty after boot.
- [ ] **[H]** T6 / a Deck session: lock, stopwatch `dpmsStatus` ≈ 20 s (the
      method of `docs/PROGRESS.md` §5.24). **Not scheduled by this task — the
      Deck is powered off and every write to it needs operator approval.**

---

## 3. Budget and non-goals

- **≤ 2 runtime patches**, and a third argues for itself — the same pressure
  `docs/tasks/T5-fork-plan.md` §1 puts on the ISO overlay's ≤ 4. Each patch is
  a standing rebase liability against a repo that moves several times a day.
- **Not in scope: patching out `recoverStrandedLock()`.** It is in the same
  file and it is tempting. It is a behavioural change to a security-relevant
  path; operator decision §5.25 #1 chose masking + `above_lock` instead.
  Separate patch, separate approval, separate hardware gate (finding §6.3).
- **Not in scope: §5.24a rows 1 and 3.** Row 1 is a user file
  (`~/.config/hypr/input.lua`, T9 §5.1); row 3 is T8/§5.27's and has no IPC.
- **Not in scope: filing anything upstream.** The clean fix is upstream binding
  `idleBlankTimer.interval` to `shell.json`'s `idle` block, which would delete
  patch 0010 outright. Follow-up below.

## 4. Follow-up (operator-gated, not part of done-when)

Stage a `docs/drafts/` report asking upstream for a `shell.json` knob for the
lock's blank timer. **Draft only — nothing is filed without explicit operator
approval**, exactly like `docs/drafts/upstream-esp-permissions-omarchy.md`,
which has been staged and unsent since 2026-08-10. If upstream takes it, our
patch stops applying on the next upgrade — and that is how we will find out.

---

## 5. Implementation note (session 22, 2026-08-12)

**Built and green. Not wired in** — `iso/` is another agent's tree and T5c/T5d
are blocked (`docs/findings/T5a-parity.md`: the fork's ISO bundles a runtime
missing `omarchy-setup-system`), so steps 1-3 and 6 of §1 are done as a
standalone, testable payload and steps 4-5 are left for T5f.

### What exists

```
src/omarchy-deck-patches/
  omarchy-deck-apply-patches                 -> /usr/bin/
  50-omarchy-deck-reapply-patches.hook       -> /usr/share/libalpm/hooks/
  omarchy-deck-patch-check.service           -> /usr/lib/systemd/system/
  patches/0010-lock-blank-timer-20s.{patch,meta}
  patches/0020-limine-interface-rotation.{patch,meta}
test/fixtures/t12-omarchy-6d7826d/           verbatim upstream @ the RUNTIME pin
test/unit/test-t12-patch-applier.sh          38 assertions, hermetic
test/t12-patch-seam-container-e2e.sh         the destruction test, real pacman
```

Not `iso/overlay-runtime/patches/` as §3.1 of the finding sketched: the
patches ship *in the package*, so the package payload is one directory, and
nothing about them belongs in the ISO builder's tree. Build-time guard 6.6
still wants a repo-side copy or a path into this one — T5b's call.

### What T5f must do to wire it in

1. **Package the directory** (seam S4). `install -Dm755` the applier to
   `/usr/bin`, `-Dm644` the hook to `/usr/share/libalpm/hooks/`, the unit to
   `/usr/lib/systemd/system/`, and `patches/*` to
   `/usr/share/omarchy-deck/patches/`. `depends=(git)`. The exact `package()`
   body that was proven to work is in `test/t12-patch-seam-container-e2e.sh` —
   copy it, do not re-derive it.
2. **Call the applier once in `configure_deck`**, inside the target, after
   `run_system_finalizer`; a non-zero exit fails the install. Note the hook
   targets `omarchy-dev`, *not* `omarchy-deck`, so installing our own package
   does **not** fire it — measured, §1 below. This call is what makes the
   patches live on first boot.
3. **Enable the unit.** `systemctl enable omarchy-deck-patch-check.service`,
   or ship the `multi-user.target.wants` symlink. An installed-but-not-enabled
   unit is silent, which defeats the point of it.
4. **Guard 6.6 in `bin/build`** (T5b): `git apply --check` every patch in
   `src/omarchy-deck-patches/patches/` against the pinned `basecamp/omarchy`
   checkout, fail on a reject, name the patch and both SHAs.
5. **The `src/deck-session.sh` precondition** of §1 step 5 — refuse to iterate
   against a Deck whose `patch-state.json` is not `ok`. Not written here; that
   file was owned by another agent this session.
6. **When `iso/RUNTIME` moves**, refetch `test/fixtures/t12-omarchy-<sha>/` and
   rename it. The suite asserts the directory name equals the pin, so a stale
   fixture cannot sit there unnoticed.

### Three things the design got wrong, found by building it

1. 🔴 **`qmllint` is not on PATH.** The finding §7 says it "is present on any
   Omarchy 4.0 target because quickshell depends on qt6-declarative". Measured
   in a clean `archlinux/archlinux` container: qt6-declarative installs it at
   **`/usr/lib/qt6/bin/qmllint`** and puts nothing on PATH. The
   `/usr/bin/qmllint` that answered on the dev machine is **qt5-declarative's**
   — a different parser for a different Qt. A bare `command -v qmllint` would
   have failed every run on a real target: a permanent false alarm, as useless
   as permanent silence. The applier now searches `/usr/lib/qt6/bin` first and
   falls back to PATH. Re-verified with the real Qt6 tool (6.11.1) against the
   pinned `Service.qml`: exit 0 patched, 255 broken. The substance of §7 holds;
   only the path did not.
2. 🔴 **pacman exits 0 when a `PostTransaction` hook fails.** Measured through
   a real upgrade. The finding said the hook "cannot abort the transaction",
   which is true but understates it: the hook's exit status reaches *nobody*.
   The transcript and the boot unit are not redundancy, they are the only two
   channels — `omarchy-deck-patch-check.service` is load-bearing, not
   belt-and-braces. Its `--verify` exiting 3 is the entire mechanism, which is
   why the unit must have no `-` on `ExecStart`, no `Restart=` and no
   `SuccessExitStatus=`; the suite asserts all three.
3. **The applier needs a `.meta`/patch agreement check the design did not
   mention.** They are two hand-written files and nothing else compares them; a
   stale `.meta` runs its post-conditions against a file the patch never
   touched, and reports green. `git apply --numstat` gives the touched set for
   free, so the mismatch is now `bad_meta`.

Smaller: `assert_count`'s `|` separator collides with ERE alternation (split on
the first and last `|` only), and an invalid expression must be reported as
*un-run* rather than as "0 matches" — the latter would make a "must NOT appear"
assertion pass because the check never ran.

### Verification status against §2

- **[B]** guard 6.6 — ✅ **DONE 2026-08-12** (`0af792f`). `--check` only, every
  failure collected, and each patch's consequence line derived from its own
  `.meta` `requirement:`. **§5's open question is answered: it prefers the copy
  the package SHIPS**, falling back to `src/omarchy-deck-patches/patches/`. ⚠️
  And the shipped copy is **flat beside the PKGBUILD**, not under `patches/` —
  makepkg's `source=()` cannot reach outside the recipe directory. §1 point 4
  still names the `src/` path as the subject; that is now the fallback.
- **[B]** the five applier unit tests — **done**, and superset: 38 assertions,
  every negative asserting exit code, diagnosis *and* that the target file is
  byte-identical afterwards. Mutation-tested: 34 mutations, **0 survivors**.
- **[V]** QEMU install — **not done** (T5c/T5d blocked). The equivalent was
  proven in a container instead: install, `patch-state.json == ok`.
- **[V]** the destruction test — **done in a container, not in QEMU**.
  `test/t12-patch-seam-container-e2e.sh` builds stand-in `omarchy-dev` and
  `omarchy-deck` packages, reinstalls the former, and asserts the hook
  re-applied both patches. It also re-measures the premise (a non-`backup` file
  is reverted with no `.pacnew`, exit 0) and drives drift through a real
  upgrade carrying upstream's own `3000`. `pacman -Qkk` does name the patched
  file, as §3.5 expected. Still wants a QEMU run once T5d lands.
- **[V]** drift visible without a terminal — **partly**: `--verify` exits 3 on
  a drifted tree, which is what leaves the failed unit. Nobody has booted a
  systemd instance and read `systemctl --failed`.
- **[H]** the ~20 s stopwatch — **not scheduled**, Deck powered off.

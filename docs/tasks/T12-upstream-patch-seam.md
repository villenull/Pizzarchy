# T12 — the upstream-patch seam: work spec

**Design and evidence: `docs/findings/T12-upstream-patch-seam.md`. Read it
first — this file is the build order, not the argument.**

**Status:** specified 2026-08-11 (session 21), **not started**.
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

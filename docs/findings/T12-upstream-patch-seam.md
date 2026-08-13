# T12 — the seam for patching upstream Omarchy files in a built image

**Written 2026-08-11 (session 21). Design only: no `src/`, `test/` or `iso/`
file was touched, and nothing was run on the Deck.** The concrete need is
`docs/PROGRESS.md` §5.24a row 2 — the lock screen's display-on time must be
~20 s, not ~2 s — whose one-line fix
(`shell/plugins/lock/Service.qml`, `idleBlankTimer.interval: 5000 → 20000`)
was already source-traced in `docs/findings/T9-lock-wake-and-blank-timing.md`
§5.2 and has **nowhere to live**. This document decides where.

Every claim is tagged:
**(VERIFIED)** — a command was run this session and this is its output ·
**(READ)** — a file was opened and it says this ·
**(INFERRED)** — follows from the above but nobody ran it.

## Provenance

| Thing | Ref | How |
|---|---|---|
| `basecamp/omarchy` runtime pin | **`6d7826d`** | `iso/RUNTIME`, `docs/PROGRESS.md` §5.22 |
| `basecamp/omarchy` head today | **`5817feb`** (= `quattro` HEAD at 2026-08-11 22:xx) | `gh api`, sha256-identical to `quattro` this session **(VERIFIED)** |
| `omacom-io/omarchy-iso` pin | `a12bfea7a86c` | `iso/UPSTREAM` |
| `omarchy-dev` packaging | `omacom-io/omarchy-pkgs@HEAD`, `pkgbuilds/omarchy-dev/PKGBUILD` | `gh api` **(READ)** |
| pacman/ALPM behaviour | `archlinux/archlinux:latest`, pacman 7.x | five container experiments, §2 **(VERIFIED)** |
| `qmllint` | qt6-declarative 6.11.1-3 on this dev machine | run against the real patched file **(VERIFIED)** |

---

## 0. The short answer

1. **The file is package-owned and the revert is silent.** `omarchy-dev`
   installs the whole Quickshell tree with `cp -a shell "$pkgdir/usr/share/omarchy/"`
   and declares **no `backup=()` array** **(READ,** PKGBUILD**)**. A hand-edit
   of `/usr/share/omarchy/shell/plugins/lock/Service.qml` is overwritten by the
   next upgrade with **no `.pacnew`, no `.pacsave`, no warning, exit 0**
   **(VERIFIED,** §2 M2**)**. This is precisely the failure class `CLAUDE.md`
   forbids, so any mechanism that does not *notice* is disqualified before the
   comparison starts.

2. **Recommendation: a patch set shipped in the `omarchy-deck` package,
   applied by one idempotent applier binary, re-applied by an ALPM
   `PostTransaction` hook triggered on the *package* (never on the path).**
   §3 gives the full design. The applier fails loudly on drift because it uses
   `git apply` with real context, not `sed`.

3. **This is not a new mechanism.** `docs/tasks/T5-fork-plan.md` §5.2 already
   requires "an ALPM `PostTransaction` hook in the `omarchy-deck` package,
   triggered on `omarchy-dev`/`omarchy-settings-dev`, that re-applies it" for
   the Limine template. **It is the same hook, the same applier, one more
   patch file.** T12 collapses into slice **T5f** — §5 says exactly how, and
   why that is a better outcome than a seventh seam.

4. **The runner-up is real and upstream-sanctioned, and it still loses.**
   `omarchy plugin clone omarchy.lock` copies the plugin into
   `~/.config/omarchy/plugins/` where it can be edited freely, and the registry
   disables the built-in for you **(READ,** `bin/omarchy-plugin-clone`,
   `shell/services/PluginRegistry.qml:490`**)**. It loses because it converts a
   1-line delta into a permanent ~700-line fork that **silently stops receiving
   upstream fixes** — and this exact file changed 17 times since May and is the
   single **BREAKS US** row of `docs/findings/T9-delta-classification.md`. §2 C.

5. **The delta ahead does not break the seam, and this was measured, not
   assumed.** The T9 §5.2 patch still applies to `quattro` HEAD — the file the
   BREAKS US commit rewrote — with `Hunk #1 succeeded at 413 (offset 40 lines)`
   **(VERIFIED)**. But upstream has retuned this very literal **three times in
   two months** (`30000 → 3000 → 5000`) **(VERIFIED,** commit patches**)**, so
   the seam's real product is not the patch: it is the alarm. §6.

---

## 1. What is actually wrong today

`iso/bin/build` applies `overlay/patches/*.patch` with `git apply --3way`
against a scratch clone of **`omacom-io/omarchy-iso`** — the ISO *builder*
**(READ,** `iso/bin/build:196-211`**)**. Nothing in this repo can express "a
patch against a file that `basecamp/omarchy` ships and `omarchy-dev` installs
onto the target at `/usr/share/omarchy/…`". `docs/tasks/T5-fork-plan.md` §3's
six seams are S1/S2/S3 (builder), S4 (our package), S5 (`/etc/skel`), S6
(user hook dir) — none of them is "modify a file another package owns".

The target file, exactly:

| | |
|---|---|
| Installed path | `/usr/share/omarchy/shell/plugins/lock/Service.qml` |
| Owning package | `omarchy-dev` (`provides=omarchy`, `conflicts=omarchy`) **(READ)** |
| Packaging line | `cp -a shell "$pkgdir/usr/share/omarchy/"` **(READ)** |
| `backup=()` | **absent** — pacman will not preserve a local edit **(READ + VERIFIED)** |
| Read by | `quickshell -n -p "$OMARCHY_PATH/shell"`, `OMARCHY_PATH=/usr/share/omarchy` **(READ,** `bin/omarchy-launch-shell`, `default/bash/env-bootstrap`**)** |
| Config knob for the value | **none** — `interval: 5000` is a QML literal, not bound to `shell.json` (`T9-lock-wake-and-blank-timing.md` §3) |

---

## 2. The candidates, each with its failure mode

Five experiments were run in a throwaway `archlinux/archlinux` container to
settle points that are usually asserted from memory. They are numbered M1–M5
and cited below.

| # | Experiment | Result |
|---|---|---|
| **M1** | Install a package shipping an ALPM hook **and** the package that hook targets, in **one** transaction | **The hook RAN.** `(2/2) T12 measurement hook` **(VERIFIED)** — a `PostTransaction` hook does not need a prior transaction to exist |
| **M2** | Locally modify a package-owned, non-`backup` file, then upgrade the package | File **silently reverted** to upstream content; **no `.pacnew`/`.pacsave`**; pacman exit 0 **(VERIFIED)** |
| **M3** | Same hook expressed as `Type = Path` vs `Type = Package`, then upgrade to a version where upstream **renamed** the file | `Type = Path` **silently did not fire**. `Type = Package` fired **(VERIFIED)** |
| **M4** | Ship the replacement file from our own package | `error: failed to commit transaction (conflicting files)` / `exists in filesystem (owned by …)`; **nothing installed** **(VERIFIED)** |
| **M5** | `pacman -Qkk` against a real package with one file tampered | altered-file count went 2 → 3; `-Qkk` detects it **(VERIFIED)** |

### A. ALPM hook + patch applier, shipped in `omarchy-deck` — **RECOMMENDED**

**Cost.** One hook file, one applier script, one patch file per delta, a state
file, one systemd oneshot for the verify channel, and a unit-test fixture set.
All inside the `omarchy-deck` package that `docs/tasks/T5-fork-plan.md` §5.2
already requires to carry an ALPM hook. `git` is a hard dependency of
`omarchy-dev` **(READ,** PKGBUILD `depends`**)** and is in
`install/omarchy-base.packages` **(READ,** line 44**)**, so `git apply` needs
nothing new on the target.

**Failure mode.** The patch stops applying when upstream edits nearby lines,
and the machine keeps the upstream value. That is *the intended behaviour* —
but it is only safe if the failure is loud on a device with no terminal, which
is what §4 is entirely about. Secondary failure mode: pacman's file database
now lies about `omarchy-dev`'s contents (`-Qkk` reports our file as altered,
M5). That is a real cost and it is accepted deliberately — it is also a free
detector for the tests.

### B. Ship a replacement file in our own package — **REFUTED BY MEASUREMENT**

Not a trade-off, an impossibility: pacman aborts the whole transaction on the
file conflict (M4). Making it work needs `conflicts`/`replaces` on
`omarchy-dev` (i.e. option D by another name) or `--overwrite`, which no
supported install path passes.

### C. `omarchy plugin clone omarchy.lock` — the upstream-sanctioned override

This is the only *drop-in-style* override the QML loader actually has, and it
exists (the task asked; the answer was checked, not guessed):

- `shell/plugins/lock/manifest.json` is a real first-party manifest —
  `id: omarchy.lock`, `kinds: ["service"]`, `keepLoaded: true`,
  `entryPoints.service: Service.qml` **(READ)**.
- `bin/omarchy-plugin-clone` copies the plugin to
  `~/.config/omarchy/plugins/<user>.lock/`, rewrites the manifest id and
  records `omarchy.clonedFrom`, then enables it **(READ)**.
- `PluginRegistry.qml` scans `$HOME/.config/omarchy/plugins` (`pluginsDir`,
  line 11), routes IPC for the built-in id to the clone (`resolveEnabledId`,
  lines 146-157), and when a clone with a non-widget kind is enabled it
  **adds the source to `disabledPlugins[]`** (lines 490-491) **(READ)**.
- `docs/omarchy-shell.md` documents the workflow, including "removing an
  active clone switches back to its built-in source" **(READ)**.

**Failure mode, and it is disqualifying.** The clone is a **point-in-time copy
of the entire plugin** — `Service.qml` (471 lines at our pin, 548 at HEAD) plus
`LockView.qml`. From the moment it is created it receives **no upstream change
of any kind, with no signal**: not the PAM/fingerprint work, not the
stranded-lock recovery, not a security fix. `shell/plugins/lock/Service.qml`
has 17 commits since 2026-05-19 **(VERIFIED,** `gh api commits?path=`**)**, and
`docs/findings/T9-delta-classification.md` §1 makes it the **one BREAKS US file
in the whole 65-file delta**. Freezing the most volatile file in the tree, in
the name of changing one integer, inverts the risk we are trying to manage.

Three lesser costs, all real: it lives in `$HOME`, so it inherits
`docs/tasks/T5-fork-plan.md` §3 trap (a) (write `/etc/skel` **and** the created
user); the clone id is not `omarchy.*`, so `firstParty` is false and it needs a
`plugins[]` entry **as well as** `omarchy.lock` in `disabledPlugins[]`
**(READ,** `isEnabled()` lines 124-140**)** — two edits to the same
`shell.json` that `docs/tasks/T5-fork-plan.md` §5.3 already owns; and getting
that bookkeeping wrong loads **two lock services at once** rather than failing
closed **(INFERRED** from the registry logic, not provoked**)**.

### C′. "Derived clone" — regenerate the clone from upstream + patch on every upgrade

The obvious repair of C: don't freeze it, rebuild it. Same hook as A, but
instead of patching `/usr/share`, the applier re-copies the packaged plugin
into the user's plugin dir and patches the copy. It keeps pacman's file
database honest, which is A's one genuine wart.

**Rejected, on machinery and on failure mode.** It is per-user (walk every home
plus `/etc/skel`) where A is system-wide and user-agnostic; enabling a plugin
the supported way goes over IPC to a **running shell**
(`omarchy-plugin-clone` calls `omarchy-shell shell rescanPlugins` and
`omarchy-plugin-enable` **(READ)**), which does not exist inside a pacstrap
chroot or during an SSH-driven upgrade, so the applier would have to
re-implement `shell.json` semantics with `jq`; and its worst failure —
half-written bookkeeping — is **two live lock services**, where A's worst
failure is *the upstream value*, which is merely the status quo.

### D. Carry a patched fork of the package, or patch the RUNTIME checkout at build time

Two shapes of the same idea. `docs/tasks/T5-fork-plan.md` §2 already adopts
`omarchy-iso-make --local-source <omarchy-checkout>`, so `omarchy-dev` will be
**built by us from a pinned `basecamp/omarchy` checkout**; patching that
checkout before the build is one line of plumbing — this is the **S7** seam
`docs/findings/T9-lock-wake-and-blank-timing.md` §5.2 proposed
(`iso/overlay-runtime/patches/`). ⚠️ **That path never existed.** The payload
lives in `src/omarchy-deck-patches/` and ships flat beside the `omarchy-deck`
PKGBUILD; the task doc §5 is authoritative and guard 6.6 (landed `0af792f`)
reads the shipped copy.

**Rejected as *the* mechanism, and this contradicts T9 §5.2 deliberately.**
Three reasons, in order of weight:

1. **It does not survive the first update.** `omarchy update` pulls
   `omarchy-dev` from the channel; our build-time patch is gone at the first
   upgrade, silently (M2). So a hook is needed *anyway* — and then the patch
   has two homes and two chances to disagree.
2. **It forges provenance.** The package version is derived from the git
   describe of the checkout (`pkgver()`, **READ**), so a patched build ships as
   `omarchy-dev-4.0.0.r1617.g6d7826d-1` while not being `6d7826d`. That breaks
   the content-diff method `docs/findings/T9-iso-comparison.md` used to
   establish our fork point at all.
3. It buys only "the value is right on first boot", which A already provides —
   `configure_deck` calls the same applier during install (§3.4), and M1 shows
   even a hook installed in the same transaction runs.

**What survives from S7 and should be kept:** a *build-time check*. `bin/build`
should `git apply --check` every patch against the pinned RUNTIME checkout and
refuse to build on a reject (§4, guard 6.6). That gets the "fail at build, not
at install" property with none of the three costs above.

### E. A bind-mount / overlay of our file over the packaged path

A systemd unit doing `mount --bind` over
`/usr/share/omarchy/shell/plugins/lock/Service.qml`. **Rejected without
experiment** (**INFERRED**, and flagged as such): either pacman's
rename-into-place fails on the busy mount and a routine upgrade aborts
mid-transaction, or it succeeds underneath and we then run a **stale copy of a
file we can no longer see**, forever, with no signal at all. Both outcomes are
worse than A's; the second is the exact bug class this project exists to
eliminate. It is listed for completeness, not as a contender.

### F. Do nothing — ask upstream instead

The clean fix is upstream's: bind `idleBlankTimer.interval` to the existing
`idle` block in `shell.json`, the way `screensaverTimeoutSeconds` and
`lockTimeoutSeconds` already are (`shell/plugins/services/idle/Service.qml`,
**READ** via T9). That is ~3 lines upstream and deletes our patch outright.

**Rejected as the answer, kept as a follow-up.** It is not ours to schedule,
the operator requirement is live now, and `docs/drafts/` shows how this goes:
the one report staged there (`upstream-esp-permissions-omarchy.md`) is marked
**DRAFT ONLY, not filed**, and has been for a day. **Nothing was sent this
session and nothing should be.** The right move is to keep A, and stage a
second draft asking for the config knob — as a task item with an operator
approval gate, not as a substitute for the seam. If upstream takes it, the
patch's `git apply` fails on the next upgrade, which is exactly how we find
out.

---

## 3. The recommended design

### 3.1 Shape

In the repo (source of truth):

```
iso/overlay-runtime/patches/            # NEW -- patches against basecamp/omarchy
  0010-lock-blank-timer-20s.patch       #   paths relative to the tree root, -p1
  0010-lock-blank-timer-20s.meta        #   owner, PROGRESS ref, post-conditions
```

On the target, shipped by the `omarchy-deck` package (T5 seam S4):

```
/usr/share/omarchy-deck/patches/*.patch|*.meta
/usr/bin/omarchy-deck-apply-patches
/usr/share/libalpm/hooks/50-omarchy-deck-reapply-patches.hook
/usr/lib/systemd/system/omarchy-deck-patch-check.service
/var/lib/omarchy-deck/patch-state.json     (written at runtime)
```

`/usr/share/libalpm/hooks/` — not `/etc/pacman.d/hooks/` — because that is
where upstream's own three hooks land from a package
(`install -Dm644 default/libalpm/hooks/… "$pkgdir/usr/share/libalpm/hooks/…"`,
**READ**), and it leaves `/etc/pacman.d/hooks/` free as the operator's
override.

### 3.2 The hook

```ini
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = omarchy-dev
Target = omarchy
Target = omarchy-settings-dev
Target = omarchy-settings

[Action]
Description = Re-applying Omarchy Deck patches to upstream files...
When = PostTransaction
Depends = omarchy-deck
Exec = /usr/bin/omarchy-deck-apply-patches --from-hook
```

Three decisions in that file, each with evidence:

- **`Type = Package`, never `Type = Path`.** M3: when upstream renames the
  patched file, a `Path` trigger **silently stops firing** and the machine
  quietly loses the fix; the `Package` trigger still fires and the applier then
  fails on a missing target. Silence versus noise, measured.
- **Both `-dev` and stable names.** Operator decision §5.25 #6 is to move to
  4.0 stable when it lands, and the stable package is `omarchy`. A trigger that
  names only `omarchy-dev` becomes a no-op at that rename — the same silent
  class again.
- **`50-`.** Upstream ships `00-` (update guard), `10-` (Hyprland reload
  pause) and `90-` (reload resume) **(READ)**; hooks run in filename order, so
  `50-` lands after the pause and before the resume.

### 3.3 The applier contract

`omarchy-deck-apply-patches [--verify] [--from-hook]`, `set -euo pipefail`,
run with `/usr/share/omarchy` as the patch root. Per patch, in filename order:

1. `git apply --reverse --check -p1 <patch>` succeeds ⇒ **already applied** ⇒
   record `ok`, next patch. *(This is what makes re-runs idempotent —
   `CLAUDE.md`'s re-runnable-scripts rule — and it is what distinguishes
   "already done" from "drifted", which a bare `git apply` cannot do.)*
2. `git apply --check -p1 <patch>` fails ⇒ **DRIFT** ⇒ record `failed` with
   the reject text and the current sha256 of the target file; continue to the
   remaining patches; remember a non-zero exit.
3. Apply it (`--verify` stops before this and reports instead).
4. **Post-conditions from the `.meta`**, and a patch with none is a bug:
   - `assert_count <file> <regex> <n>` — e.g. `interval: 20000` appears
     exactly once. Catches a patch that applied to the wrong one of several
     similar hunks.
   - for `*.qml`: `qmllint <file>` must exit 0. **(VERIFIED:** `qmllint` exits
     **0** on the patched `Service.qml` despite its unresolvable `qs.Commons`
     import — no false alarm — and **255** on a deliberately broken copy. It is
     present on any Omarchy 4.0 target because `quickshell` depends on
     `qt6-declarative` **(VERIFIED,** `pacman -Si quickshell`**)**.)
5. Write `/var/lib/omarchy-deck/patch-state.json`: per-patch status, the
   installed `omarchy-dev` version, target-file sha256, timestamp.
6. Exit non-zero if any patch is not `ok`.

**It uses `git apply`, not `sed`.** A `sed -i 's/interval: 5000/…/'` is the
tempting one-liner and it is the trap: when upstream retunes the literal — as
it did in `35a6940` (`30000 → 3000`) and `af82848` (`3000 → 5000`)
**(VERIFIED)** — the `sed` matches nothing, exits 0, and the fix is gone
silently. The patch's context lines make the same event a reject.

**It must not restart the shell.** The first-party plugin dir is *not* watched
for live reload — `PluginRegistry`'s inotify watcher covers only
`registry.pluginsDir` (`$HOME/.config/omarchy/plugins`) **(READ)** — so the new
value takes effect at the next shell start, and that is fine. Restarting
Quickshell from a pacman hook would be actively dangerous: `omarchy-launch-shell`
now supervises and relaunches it, and **every relaunch re-runs
`checkStrandedLock()`** (`docs/findings/T9-delta-classification.md` §1, §2) —
i.e. the hook would be poking the one code path classified BREAKS US, possibly
while the device is locked.

### 3.4 First install

`configure_deck` (T5 seam S3) calls `omarchy-deck-apply-patches` inside the
target after `run_system_finalizer`, and treats a non-zero exit as an install
failure. This does not depend on hook ordering inside pacstrap, and step 1 of
§3.3 makes it harmless if the hook already ran in the same transaction — which,
per **M1**, it may well have.

### 3.5 What this costs, stated honestly

`pacman -Qkk omarchy-dev` will report the patched file as altered
(**VERIFIED**, M5) — we are knowingly making pacman's database describe the
package rather than the disk, and anyone auditing the machine sees a
"corrupted" file. `docs/tasks/T5-fork-plan.md` §1 caps the ISO overlay at ≤ 4
patch files; this seam deserves its own budget and the same pressure: **≤ 2
runtime patches, and a third has to argue for itself.** Every patch here is a
standing rebase liability against a repo that moves several times a day.

---

## 4. How a stale patch becomes noisy — and how that is tested

A `PostTransaction` hook **cannot** abort the transaction (`AbortOnFail` is a
`PreTransaction` property), so "the hook exits 1" is necessary and nowhere near
sufficient on a device with no terminal. Four channels, deliberately
redundant:

1. **The transcript.** The applier writes the failure to stderr inside the
   pacman run, and `omarchy-update` already tees its whole session to
   `/tmp/omarchy-update.log` via `script -qefc` **(READ,** `bin/omarchy-update:12`**)**.
2. **The state file**, `/var/lib/omarchy-deck/patch-state.json` — machine
   readable, and the thing every other channel and test asserts on.
3. **`omarchy-deck-patch-check.service`**, a boot-time oneshot running
   `--verify`. A drifted patch leaves a **failed unit**, so `systemctl --failed`
   is non-empty and the state is visible without a terminal-based diagnosis;
   when a graphical session exists it also fires
   `omarchy-notification-send` (upstream binary, **READ**).
4. **`src/deck-session.sh` precondition** for the SSH iterate-in-place loop,
   so the dev machine refuses to reason about a Deck whose patches are stale.

### Tests, by tier

- **[B] Build-time — guard 6.6 (new).** `iso/bin/build` runs `git apply
  --check` for every runtime patch against the pinned
  `basecamp/omarchy` checkout that T5b already fetches for `--local-source`,
  and **fails the build** on a reject. This is the cheapest possible discovery
  of "the RUNTIME pin moved and our patch is stale" — before an ISO exists.
  *(Already demonstrated to work: this session ran exactly that check against
  both `6d7826d` and `quattro` HEAD — §6.)*
- **[B] Unit tests of the applier** (`test/unit/`), with the negative cases
  mandatory, per `docs/tasks/T5-fork-plan.md` §5.4's rule that a guard nobody
  has seen fail is not a guard:
  1. clean apply on a fixture tree ⇒ exit 0, post-conditions hold;
  2. **second run is a no-op, exit 0** (idempotence, §3.3 step 1);
  3. fixture where upstream changed the literal to `3000` ⇒ **exit 1**, and the
     message names the file *(this is a real upstream commit's content, not a
     hypothetical — `35a6940`)*;
  4. fixture where upstream **renamed** the file away ⇒ exit 1;
  5. fixture where the patch applies but the post-condition fails (broken QML)
     ⇒ exit 1. `qmllint`'s 0-vs-255 split is already measured, so this test can
     be written against a known-good oracle.
- **[V] QEMU install assertion — the destruction test.** After a real install:
  assert `interval: 20000` in the installed
  `/usr/share/omarchy/shell/plugins/lock/Service.qml`; **then re-install
  `omarchy-dev` from the cached package file and re-assert.** Without the
  second half the row passes for the wrong reason — the same shape as §5.2's
  `omarchy refresh limine` destruction test. Two notes for whoever writes it:
  `pacman -U` does **not** trip upstream's direct-upgrade guard (it aborts only
  when both `-S` and `-u` are present, **READ**), whereas a `pacman -Syu` in a
  test needs `OMARCHY_ALLOW_DIRECT_PACMAN=1`; and the test should assert
  `patch-state.json` says `ok`, not merely that the integer is present.
- **[H] T6 / a Deck session.** Lock the device and stopwatch `dpmsStatus`
  against ~20 s, the method `docs/PROGRESS.md` §5.24 used to measure the
  original ~5-6 s. Not scheduled here; the Deck is powered off.

---

## 5. Interaction with `docs/tasks/T5-fork-plan.md` — it collapses into T5f

**Yes, and say it plainly: this is not a new slice.** T5-fork-plan §5.2 already
carries the box:

> ⚠️ **The template is a packaged file** — `omarchy-dev` owns
> `/usr/share/omarchy/default/limine/`, so the next runtime upgrade reverts our
> patch. It needs an ALPM `PostTransaction` hook in the `omarchy-deck` package,
> triggered on `omarchy-dev`/`omarchy-settings-dev`, that re-applies it.

That is the same package, the same trigger, the same failure mode, and the same
`/usr/share/omarchy` root. The two needs differ only in which file the diff
touches. So:

- **Slice T5f** ("Bake-in 5.2 — three surfaces + the ALPM re-apply hook + the
  `omarchy refresh limine` destruction test") **is widened**, not duplicated:
  its hook becomes the general applier of §3, with **two** patches —
  `interface_rotation: 270` into `default/limine/limine.conf`, and the lock
  blank timer into `shell/plugins/lock/Service.qml`. Model routing is unchanged
  (Opus; it is boot-chain-adjacent and silent-failure-prone, matching
  `docs/PLAN.md` §11's "Pacman hook for kernel-version churn" row).
- **The collapse is partial and the remainder must not be lost.** 5.2's *other*
  Limine surface, `/boot/limine.conf`, is **not** package-owned — it is
  regenerated by `omarchy-refresh-limine` — so that half stays with
  `configure_deck` + the S6 pre-refresh hook. The applier owns
  `/usr/share/omarchy` and nothing else. A single mechanism that tried to own
  both would have to know about two completely different destruction events.
- **§3 gains no S7.** `docs/findings/T9-lock-wake-and-blank-timing.md` §5.2
  proposed a seventh seam, "a patch applied to the RUNTIME checkout before
  `--local-source` builds the package". §2 D rejects that as the mechanism for
  the three reasons given. What it keeps is the *check* — guard **6.6** — which
  belongs in T5b (where `--local-source` is wired) rather than in a new seam.
- **§5 gains one row**, to be pasted by whoever next owns that file (this
  session does not own it):

> ### 5.7 The upstream-QML patch seam
> **Source:** `docs/PROGRESS.md` §5.24a row 2,
> `docs/findings/T12-upstream-patch-seam.md`.
> **Where:** `omarchy-deck` ships `/usr/share/omarchy-deck/patches/`,
> `/usr/bin/omarchy-deck-apply-patches` and
> `/usr/share/libalpm/hooks/50-omarchy-deck-reapply-patches.hook`;
> `configure_deck` (S3) invokes the applier once at install.
> **Verified by:** [B] guard 6.6 + the five applier unit tests including the
> drift and rename negatives · [V] the install-then-reinstall destruction test
> and `patch-state.json == ok` · [H] T6 stopwatch, ~20 s.

- **§7's slice table** therefore needs **no new row**. T12's deliverable is a
  design + spec that T5f executes. It does add a dependency: T5f now also
  depends on 5.6's lock work being understood, since both touch lock behaviour
  — but not on it landing first.

---

## 6. What the delta ahead does to the seam's durability

`docs/findings/T9-delta-classification.md` classified 65 non-test files as
**1 BREAKS US / 27 RE-VERIFY / 37 NO IMPACT**, and the BREAKS US row is
`shell/plugins/lock/Service.qml` — the exact file this seam patches. That is
the part most likely to change the recommendation, so it was measured rather
than reasoned about.

**Measurement 1 — the patch still applies to the post-delta file.** The T9
§5.2 diff was regenerated against `6d7826d` and checked against the file at
`quattro` HEAD (`5817feb`, 548 lines vs 471, sha
`00b804b5…`, byte-identical between `5817feb` and `quattro` this session):

```
$ git apply --check -p1 --verbose blank-timer.patch
Checking patch shell/plugins/lock/Service.qml...
Hunk #1 succeeded at 413 (offset 40 lines).
```

**(VERIFIED.)** `patch -p1 --dry-run` agrees. The stranded-lock work added 77
lines *above* the timer and left its five-line neighbourhood untouched, and
`interval: 5000` still occurs exactly once in the file at both refs
**(VERIFIED)**. So the delta does **not** break the seam, and the RUNTIME pin
can move to `quattro` HEAD without a rebase of this patch.

**Measurement 2 — but this literal is upstream's favourite knob.** The value
has been retuned three times in two months, in commits whose whole subject is
the tuning:

| Commit | Date | Change |
|---|---|---|
| `35a6940` "Just 3 seconds of screen on after lock" | 2026-06-20 | `interval: 30000` → `3000` |
| `af82848` "Give it a little more time" | 2026-07-04 | `3000` → `5000` |
| `1e7bb66` "Recover a session lock stranded by a dead shell (#6692)" | 2026-08-11 | +77 lines, timer untouched |

**(VERIFIED,** per-commit patches via `gh api`**)**, on a file with **17
commits since 2026-05-19** **(VERIFIED)**.

**What that means, stated as consequences rather than reassurance:**

1. **Expect a rebase roughly monthly**, and expect it to arrive as a build
   failure (guard 6.6) or a failed unit, not as a surprise on the panel. Two
   of the three historical changes above would have produced a clean reject;
   the third would have applied untouched.
2. **The one-line patch is the right size *because* of the delta.** A
   mechanism whose maintenance cost scales with upstream's churn (C's frozen
   700-line clone) is disqualified by exactly the evidence that makes the patch
   survivable: the churn is in the file, not in those five lines.
3. **The seam raises the ceiling on the lock mitigation, and that is a trap
   worth naming.** Once patching `Service.qml` is routine, "just patch out
   `recoverStrandedLock()`" (the BREAKS US behaviour) becomes tempting. Do not
   fold that into T12. It is a behavioural change to a security-relevant path
   with an operator decision behind it (§5.25 #1 chose masking and
   `above_lock`, not QML surgery), and it would multiply the rebase surface by
   an order of magnitude. If it is ever wanted, it is a separate patch with its
   own approval, its own post-conditions and its own hardware gate.
4. **The pin is still not a pin.** `quattro` moved twice in two hours during
   the T9 measurement, and operator decision §5.25 #6 is to wait for 4.0
   stable. When the pin moves, this patch is one of the things §5's rows must
   be re-checked against — and it is now the *cheapest* of them to re-check,
   because the check is a single `git apply --check` in the build.

---

## 7. Verified vs. inferred, per the task's instruction

**Verified by running something this session:**
- M1–M5 (pacman/ALPM semantics), each in a throwaway `archlinux/archlinux`
  container: hook-in-same-transaction runs; silent overwrite of a non-`backup`
  file with no `.pacnew`; `Type = Path` silently misses a rename while
  `Type = Package` does not; our-package-ships-the-same-file aborts the
  transaction; `pacman -Qkk` detects a tampered file.
- The T9 §5.2 patch applies to `quattro` HEAD with offset 40 (`git apply
  --check` **and** `patch --dry-run`), and `interval: 5000` occurs exactly once
  at both refs.
- `qmllint` exits 0 on the patched `Service.qml` (unresolved `qs.*` imports do
  not produce a false alarm) and 255 on a deliberately broken copy.
- `quickshell` depends on `qt6-declarative`, which provides `/usr/bin/qmllint`.
- Upstream's history for `shell/plugins/lock/Service.qml`: 17 commits since
  2026-05-19; `30000 → 3000 → 5000` in `35a6940`/`af82848`.
- `Service.qml` at `5817feb` and at `quattro` are sha256-identical.

**Read from source (not run):**
- `omarchy-dev`'s PKGBUILD: installs `shell/` under `/usr/share/omarchy/`,
  ships three ALPM hooks into `/usr/share/libalpm/hooks/`, depends on
  `git`/`quickshell`, has **no** `backup=()`.
- `bin/omarchy-launch-shell`, `default/bash/env-bootstrap` (`OMARCHY_PATH`),
  `bin/omarchy-update-pacman-guard` (aborts only on `-S` + `-u`),
  `bin/omarchy-update` (transcript via `script -qefc`), `bin/omarchy-hook`
  (swallows failures — why the user hook dir is not a candidate here).
- The whole plugin-override path: `bin/omarchy-plugin-clone`,
  `bin/omarchy-plugin-catalog`, `shell/services/PluginRegistry.qml`
  (`pluginsDir`, `isEnabled`, `isDisabled`, `resolveEnabledId`, the
  `addDisabled(clonedFrom)` branch, the inotify watcher scoped to the user
  dir), `shell/plugins/lock/manifest.json`, `docs/omarchy-shell.md`.
- `iso/bin/build` (patches apply to the *builder*, not the runtime),
  `iso/UPSTREAM`, `iso/RUNTIME`, and the empty `iso/overlay/`.

**Inferred, not verified — flagged rather than asserted:**
- Option E's bind-mount failure modes (both branches). Nobody bind-mounted a
  file under a pacman upgrade; the option was rejected without experiment
  because both plausible outcomes lose to A.
- That a hook installed during **pacstrap** (`pacman --root`) runs the same way
  M1 showed for a live root. §3.4 is designed so this does not matter.
- That the offline mirror or `/var/cache/pacman/pkg` still holds the
  `omarchy-dev` package after install, which the [V] destruction test needs to
  run without a network. Whoever writes that test must check it, not assume it.
- That a file-copied clone without the `shell.json` bookkeeping loads two lock
  services (option C′'s worst case). It follows from the registry code as read;
  it was not provoked.
- Every "verified by" row in §4 is a specification, not a result. Nothing in
  this design has been built or run.

---

## 8. What is deliberately not decided here

- **The value.** `20000` comes from `docs/PROGRESS.md` §5.24a row 2 ("~20 s");
  this document does not re-litigate it.
- **§5.24a rows 1 and 3.** Row 1 lands in `~/.config/hypr/input.lua`
  (T9 §5.1) — a *user* file, upstream's sanctioned seam, not this mechanism.
  Row 3 (OSK auto-hide on unlock) is T8/§5.27's, and no IPC exists for it
  (§5.24a note 2).
- **Filing anything upstream.** §2 F. Nothing was sent, and the follow-up is a
  staged draft behind an operator approval gate.

# T9 — Rebase everything onto Omarchy 4.0 beta 2

> **Status: not started. This is `docs/ROADMAP.md` phase 2.9** — a new block
> inserted between "build the product" (phase 2) and "prove it like a user"
> (phase 3), added 2026-08-11 by operator direction after upstream shipped a
> second 4.0 beta.
>
> ✅ **Beta 2 is a published ISO — found and measured 2026-08-11:**
> `https://iso.omarchy.org/omarchy-quattro-beta2.iso`, **6,390,581,248 bytes**,
> Last-Modified **2026-08-10 13:44:37 UTC**. Unlisted (omarchy.org still links
> 3.8.4), **no published checksum**, and cut ~2h14m *after* our own ISO from
> what looks like the same builder commit. Full evidence:
> `docs/findings/T9-beta2-delta.md` §1.
>
> ⚠️ **It is still not a version string.** No 4.0 tag, no GitHub release,
> `version` on `quattro` reads `4.0.0.alpha`, and `pkgs.omarchy.org` serves only
> `edge` and `stable`. **Step 1 still has to turn that ISO into SHAs** — and
> answer the question it raises:
>
> 🔥 **`quattro` HEAD is now ~24 hours and ~30 commits AHEAD of beta 2**, and
> `edge` tracks HEAD within minutes. **A plain `omarchy-update` overshoots beta
> 2** into whatever edge holds that hour. Rebasing onto *beta 2* and rebasing
> onto *edge HEAD* are different targets. Step 1 must say which was chosen.

**Model: Opus.** This touches the boot chain, the session layer and the one
physical device at once, and its whole job is noticing what silently changed.

## Objective

Move every artifact this project owns — the ISO, the QEMU substrate, the two
install scripts, the input/OSK layer and the test Deck — from the 4.0 snapshot
of 2026-08-10 onto the beta 2 snapshot, and **re-establish by measurement**
every recorded fact that names upstream behavior.

The deliverable is not "it still boots". It is a **delta document** that says,
row by row, which of our couplings to Omarchy survived, which drifted, and
which broke — plus the fixes.

## Why this exists as its own block

Three reasons, in order of weight.

1. **Phase 3 starts with a factory reset and ends with a release.** Rebasing
   *during* phase 3 means discovering upstream drift while also trying to
   decide whether the release matrix passed. Separating them keeps one
   variable moving at a time.
2. **The drift is already measured and it is not cosmetic.** Between the
   commit our Deck was installed from and 2026-08-11, upstream changed a
   sudoers file this project quotes verbatim, renamed three `omarchy-apply-*`
   binaries the ISO builder calls, edited the Quickshell **lock service** whose
   idle policy we deliberately neutered, edited the menu file our Desktop Mode
   row extends, and added four migrations that mutate machine state on update
   — one of them Bluetooth, which is an unfinished parity row.
   Detail: `docs/findings/T9-beta2-delta.md`.
3. **P3.6 (rebase onto 4.0 *stable*) is unavoidable and unscheduled.** Doing
   the beta 1 → beta 2 rebase first makes P3.6 the *second* time we run this
   procedure instead of the first, on a step that gates the release.

## Prerequisites

- Phase 2 work that is going to land before the rebase has landed. **This
  block does not gate on T4/T5 being finished** — see "Ordering" below.
- A clean `main`, CI green, all 11 unit suites passing *before* anything moves, so
  every failure afterwards is attributable to the rebase.
- Operator present for anything that writes to the Deck (`docs/START-HERE.md`
  §3). Batch those requests; do not ask per-item.

### Ordering — deliberately flexible on one axis

Steps 1–4 (pin, delta, ISO, substrate) need **no hardware** and can run at any
point. Step 5 (the Deck) should run **after** T5's ISO fork exists if that is
close, because the fork inherits the pin and rebuilding twice is waste — but
waiting is not required. If T5 is weeks out, rebase the Deck now: a test bed
running an old beta silently invalidates every hardware fact recorded against
it.

---

## Steps

### 1. Pin the snapshot — and first, choose the target

**Decide before pinning:** *beta 2 the artifact* (reproducible, and what a user
downloading today gets) or *edge HEAD* (what upstream is about to ship, moving
several times a day). They are ~30 commits apart and diverging. A defensible
default is **beta 2**, because a release test wants a fixed target — but say it
out loud in `docs/PROGRESS.md` §5.22 rather than letting `omarchy-update` decide
by accident.

Record in `docs/PROGRESS.md` §1.1, and **cite it from every later step**. No
step may say "latest".

| What | How to read it | Recorded value |
|---|---|---|
| Beta 2 ISO | `curl -sSI https://iso.omarchy.org/omarchy-quattro-beta2.iso` | **6,390,581,248 B, 2026-08-10 13:44:37 UTC** ✅ |
| Its sha256 | ours, computed after download — **upstream publishes none** | *(fill in)* |
| `omacom-io/omarchy-iso` SHA it was cut from | inspect the ISO, or bracket by timestamp: after `a12bfea` (11:30), before `e5f2b46` (16:19) | *(fill in)* |
| `basecamp/omarchy` SHA on the ISO | `omarchy-version` / the `omarchy-dev` package version *inside* the image | *(fill in)* |
| Channel the ISO carries (mirror **and** pkgs) | `omarchy-version-channel` after install | *(fill in)* |

⚠️ **The channel is two settings, not one**, and they can disagree —
`omarchy-version-channel` prints `edge / stable` when they do. Measured
2026-08-11: the Arch mirror is one of `stable-mirror` / `rc-mirror` /
`mirror`(edge), the Omarchy package channel is only `stable` or `edge`, and
**`--rc` pins the Arch mirror while still taking Omarchy packages from edge**.
§3.10 records the matching trap on the builder side.

⚠️ **`omarchy-dev`'s version is a git-describe** — `4.0.0.rN.gSHA` — not a
release name. Two "beta 2" installs can differ by 40 commits and both call
themselves 4.0.0. **The SHA is the pin; the words are not.**

⚠️ **Downloading the ISO needs operator approval** — 6.0 GB, and there is no
published checksum to verify it against. Record our own sha256 and state
plainly that it attests to *what we downloaded*, not to what upstream built.

### 2. Measure the delta against our seams — before touching anything

Extend `docs/findings/T9-beta2-delta.md` (seeded 2026-08-11) so its baseline is
our *current* Deck state and its head is the step-1 pin. For each changed
upstream file that touches a surface we couple to, one row:
**no impact · re-verify · breaks us**, with the reason.

The seams, and what reads them:

| Upstream surface | Ours that couples to it |
|---|---|
| `etc/sudoers.d/*`, polkit | `deck-session.sh` timezone + priv-write stages, §5.15, §5.17 |
| `bin/omarchy-menu`, `default/omarchy/omarchy-menu.jsonc` | P2.4's Desktop Mode row (extension file) |
| `shell/plugins/lock/*`, `shell.json` | the idle policy — **screensaver 150 s, lock 86400 s**, load-bearing |
| `default/hypr/**` | `monitors.lua` rotation (transform **3**), uwsm session start |
| Limine / `limine-mkinitcpio-hook` / snapper | `omarchy-deck-kernel.sh` — all ten stages |
| `install/omarchy-base.packages`, `migrations/*.sh` | T5's payload, ISO size, offline pacman |
| `omarchy-iso` installer path (cidata, finalizers) | `test/vm/vm-install-test.sh`, `test/lib/vm-cidata.sh` |
| GTK4 / layer-shell / Hyprland version | `deck_osk_wayland.py`, `deck-input-mapper.py` |

⚠️ **Read the new `migrations/*.sh` before updating anything.** They run on
`omarchy-update`, they are machine-wide, and at least one of them takes `sudo`
and rewrites `/etc/bluetooth/main.conf`. A migration is upstream code executing
against our carefully-staged state — the exact thing that can silently revert a
load-bearing setting.

### 3. Take upstream's beta 2 ISO as the reference — *then* rebuild ours

**Both, in this order, and they answer different questions.**

**3a — Download upstream's beta 2 ISO** (operator approval: 6.0 GB, no
published checksum). It is the artifact a user actually gets, and it is the
only way to read what beta 2 *contains*: which `omarchy-iso` commit built it,
which package channel it carries, and which `omarchy-dev` version installs from
it. Mount it and read; do not infer from the branch. Record our own sha256 and
label it as ours.

⚠️ **Do not assume it differs much from what we already built.** Ours came from
`a12bfea` at 11:30 UTC; beta 2 is stamped 13:44 UTC the same day, before the
builder's next commit. If the inspection shows they match, **say so and skip
3b** — a rebuild that reproduces a file we already have is not evidence of
anything.

**3b — Rebuild ours from the pinned `omarchy-iso`** (T5's fork base). Inherit
§3.10's three gotchas, none of which are optional:

1. `OMARCHY_ISO_REF` and `OMARCHY_MIRROR` must agree — build with
   `OMARCHY_MIRROR=edge` (what `--quattro` sets) or the channels disagree.
2. Keep upstream's loud guard. It refuses to ship an installer with no
   prompts; that is the discipline `docs/PLAN.md` §8.1 wants more of.
3. **Point the container at a scratch pacman cache**, not the host's.
   `omarchy-iso-make` `sudo rm -rf`s whatever it is given, and the dev
   machine's cache holds 2700+ packages.

Then **re-run P1.4's static inspection on the new image**, not just a checksum.
Two facts were *measured from the built ISO* and both re-scope work if they
changed: the live image has **no Wayland compositor** (which is why T8 draws
its own OSK — `docs/findings/T2-gamepad-spike.md` §4) and the installer
**defaults to full-disk encryption** (§5.12).

Record: filename, size, sha256, build date, `omarchy-iso` SHA. Keep the old ISO
until step 5 passes.

### 4. Rebuild the QEMU substrate and re-run everything that needs no hardware

`test/images/vm-neptune-image.sh` builds a substrate that deliberately mimics a
Quattro system — limine + hook versions, the fstab options copied from a real
Quattro `/etc/fstab`, the ESP layout. **If upstream moved and the substrate did
not, every VM suite passes while testing a system that no longer exists.**
Rebuild it from the new ISO, then run, in this order:

```bash
mapfile -t files < <(git ls-files '*.sh'); shellcheck -x "${files[@]}"
for f in test/unit/test-*.sh; do ./"$f"; done
for f in test/unit/test-*.py; do python3 "$f"; done
```

then the VM suites (install, kernel-stage, idempotency, hook), then by hand:

```bash
python3 test/osk-tty-e2e.py
```

⚠️ **Two globs, not one** — the shell glob misses all five Python suites, which
is where the entire input layer's coverage lives. And `osk-tty-e2e.py` is in
neither on purpose; it needs `/dev/uinput`.

**A green run here is necessary and not sufficient.** Session 17 is the
standing counter-example: the mapper suite was green while the mapper was a
complete no-op on hardware.

### 5. Bring the Deck to beta 2 — snapshot first

⚠️ **Operator approval required before any of this.** Prepare it, describe
exactly what will happen, wait.

**Recommended: in-place `omarchy-update`, not a reinstall.** Phase 3 (P3.1/P3.2)
already buys the clean-install proof from a factory reset, and burning a Deck
rebuild here spends the same hours twice. In-place also keeps snapshots #1–#7
and the SSH loop intact. The gap it leaves — the *installer* path changed
(deferred provisioning, factory snapshots, the renamed `omarchy-apply-system`
finalizer) — is exactly what step 4's QEMU install test covers, which is why
step 4 is not optional.

*(If the operator prefers a reinstall, it is defensible — it tests the real
artifact — but then say plainly in `docs/PROGRESS.md` that phase 3's install is
no longer the first from this ISO.)*

Order of operations:

1. **`snapper` snapshot #8, before anything.** Named for this step.
2. Confirm the channel (`omarchy-version-channel`) matches the step-1 pin;
   `omarchy-channel-set` if not.
3. `omarchy-update`, then read what the migrations actually did.

   🔥 **`omarchy-update` does not land on beta 2 — it lands on whatever `edge`
   holds that hour**, which on 2026-08-11 was already ~30 commits past it. If
   step 1 chose beta 2 as the target, this is the step where that choice is
   either honoured or silently lost. Either pin the update, or record honestly
   that the Deck now runs *edge as of `<date>`* and not beta 2. **Do not write
   "the Deck is on beta 2" if what ran was an unpinned update** — that is the
   silent-inaccuracy failure `CLAUDE.md` exists to prevent.
4. **Re-run every `deck-session.sh` install stage.** They are idempotent by
   design (`CLAUDE.md`) — this is the first real test of that claim against a
   moved substrate, and any stage that now fails is a genuine finding.
5. `./src/deck-session.sh stage-audit-privileges` — §5.17's gate.
6. Re-verify the load-bearing settings **the way §5.20 says to**:
   `dconf read -d` for `screen-keyboard-enabled` and `input-sources` (never
   `gsettings get`, which returns the user's value and passes while the site
   default is missing), and `shell.json` for screensaver 150 s / lock 86400 s.
   ⚠️ `lock: 0` locks *instantly*; it does not disable.
7. Re-check `lizard_mode` (§5.21 — a reboot resets it to `Y`) and that the
   backlight sysfs node is still **0644**. If it is 666, Steam fell back, which
   means a helper broke.
8. **Soak the session switch.** Not 20 cycles necessarily, but not one either:
   §5.18 first appeared on cycle 4.

### 6. The hands-on pass — what a script cannot see

Batch into one operator session, and do it **after** step 5, on the Deck:

- STEAM+X raises the OSK; characters land; the layer surface never steals focus
- Both trackpad cursors move, diagonals included *(session 17's worst bug was
  invisible to every single-axis test)*
- Steam's **Power → Switch to Desktop** and the way back, both directions
- The Desktop Mode row is still in the Omarchy menu after the menu file moved
- Gaming Mode is usable on screen — R-38's standard, not "the session exists"
- Anything step 2 marked **re-verify**

### 7. Update the record — and delete what is now false

- `docs/PROGRESS.md`: the pin in §1.1, a §5.22 outcome entry, and **every §7
  fact that names upstream behavior**. §7 is "don't re-derive"; a stale entry
  there is worse than no entry.
- **The known-stale one:** `src/deck-session.sh` (~line 1157) quotes
  `/etc/sudoers.d/omarchy-tzupdate` as granting `tzupdate` *and*
  `timedatectl set-timezone`. Upstream dropped the `tzupdate` half on
  2026-08-11 (#6694). Our own grant is independent and unaffected — but the
  comment is now wrong, and its reasoning ("that file belongs to a package on a
  beta distro, and if it changed the picker would go back to failing silently")
  was **vindicated four days later**. Update the quote; keep the reasoning and
  say it was borne out.
- `docs/ROADMAP.md`: tick phase 2.9's exit criteria; leave P3.6 (stable) alone.
- `docs/START-HERE.md`: the state block and the T9 row.

---

## Done when

- [ ] The pin is three SHAs + a version string + a channel, written down, and
      every step below cites it
- [ ] `docs/findings/T9-beta2-delta.md` classifies **every** changed upstream
      file that touches a listed seam — no "probably fine" rows
- [ ] A new ISO is built from the pinned `omarchy-iso`, sha256 recorded, and
      **re-inspected** for the compositor and encryption facts
- [ ] The QEMU substrate is rebuilt from that ISO and all 11 unit suites + the
      shellcheck command + the VM suites + `osk-tty-e2e.py` pass
- [ ] The Deck runs beta 2, every `deck-session.sh` stage re-ran clean, and the
      load-bearing settings are verified with `dconf read -d`
- [ ] Both switch directions soaked, ≥5 cycles, zero start-limit-hit
- [ ] The hands-on list is signed off by the operator, on screen
- [ ] Every fact in §7 that names upstream behavior is re-checked or deleted

## Failure modes

- **"It still boots" declared as success.** The failure mode of a rebase is
  silent degradation, not a crash. Lizard mode reverting, an OSK GSetting
  reset by a migration, the idle lock coming back — all invisible to a boot.
- **Testing the new system with the old substrate.** The QEMU image encodes
  Quattro's fstab and ESP layout. Rebuild it, or step 4 is theatre.
- **A migration reverting a load-bearing setting.** They run as root,
  machine-wide, and one already rewrites `/etc/bluetooth/main.conf`. Read them
  first; re-verify our settings after.
- **Rebuilding the ISO against the host pacman cache.** §3.10 item 3 — it gets
  `rm -rf`'d.
- **Pinning by name instead of SHA.** `4.0.0.rN.gSHA` moves several times a
  day on `edge`.
- **Doing this and phase 3 together.** Two moving variables, one matrix.

## Escalate if

- **Quattro stable ships before this block finishes** — the r/omarchy thread the
  operator cited is titled *"Omarchy Quattro will be shipping this week"*. If
  stable lands mid-block, stop and re-decide: rebasing onto beta 2 and then
  again onto stable days later is two operator sessions for one outcome, and
  P3.6 already owns the second one
- The published beta 2 ISO turns out to differ **materially** from what we
  built at `a12bfea` — that would mean upstream ships something the builder
  repo does not produce, which is a T5 problem, not a T9 one
- An upstream change makes one of the five hard constraints in `CLAUDE.md`
  unsatisfiable (Limine, no-AUR-helper, loud failure, idempotence)
- The Quickshell menu extension mechanism (P2.4) is gone or changed shape —
  that is T3's last integration point and it has no fallback
- The delta implies the Deck should be **reinstalled** rather than updated —
  operator decision, not ours

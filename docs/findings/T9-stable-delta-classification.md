# T9 / P3.6 — delta classification, our pin `6d7826d` → Omarchy 4.0.0 **stable** `f0020448`

**Measured 2026-08-15 (session 27, autonomous overnight run), dev machine only,
read-only against a bare clone of `basecamp/omarchy`.** Every row in the four
seam tables below was written after reading the actual
`git diff 6d7826d f0020448 -- <path>` hunk (or `git show f0020448:<path>` for
added files). Nothing is inferred from a filename or commit subject. This is the
stable-target companion to `T9-delta-classification.md` (which measured the
beta2/edge-HEAD drift); it supersedes that doc wherever they disagree, because
this one measures against the **released** tag.

## The pin this is measured against

Full measurement in `PIN-MEASURED` (reproduced in `docs/PROGRESS.md` §1.1 / §5.26).
In one line: **basecamp/omarchy `f0020448` (tag v4.0.0) · omarchy-iso `174dd82` ·
omarchy-pkgs `bb66b9d` · channel `stable` · runtime package `omarchy 4.0.0-1`
(renamed from `omarchy-dev`) · settings `omarchy-settings 4.0.0-1` · ISO
`omarchy-4.0.0.iso` 6,273,040,384 B sha256 `9224fab3…` (matches upstream's
published release checksum).**

## Scope of the move

- **127 commits**, 243 non-test files changed (316 total). Much bigger than the
  65-file beta2 delta — this is a real release, not a same-day rebuild.
- The 4.0.0 headline changes that touch our seams: privilege escalation moved to
  **pkexec/polkit**, the menu became a **JSONC command palette in the shell**,
  hyprlock was replaced by a **shell-integrated PAM lock**, Hyprland config went
  **all-Lua for 0.56**, and the beta `-dev`/`edge` packages became **released
  `omarchy`/`stable` packages**.

## Verdict roll-up (all four seams)

| Verdict | Count | The rows |
|---|---|---|
| **BREAKS US** | **1** | Orchestrator calls `/usr/bin/omarchy-setup-system`, renamed to `omarchy-apply-system` (R082). **Auto-fixed by the submodule bump** — omarchy-iso `174dd82` already calls `omarchy-apply-system` (commit `d6cd2d3`); and if not bumped, `iso/bin/build` guard 6.4a `build_fail`s loudly the instant `iso/RUNTIME` moves (test-iso-build case 12 encodes this). |
| **RE-VERIFY (hands-on)** | 6 | limine-cmdline migration `1786482992` (sudo limine-mkinitcpio; no-op expected on Deck); stranded-lock recovery path (already mitigated: `idle.lock=86400` + sleep-lock mask + `above_lock=2`); Bluetooth migration `1786380259` (BT parity row); `KeyboardLayout` rewrite (OSK-desync, inert on single-layout Deck); `shell.qml putBarWidget` (rewrites shell.json config.bar only); clamshell parser reads `scale` not `transform` (we ship no monitors.lua). |
| **NO IMPACT** | rest | Detailed per seam below. |

## The two things that would have been scary and AREN'T

1. **No migration reverts a load-bearing setting.** `omarchy-defaults.conf` is
   **byte-identical** at both refs; the limine migration only rebuilds the UKI
   from unchanged on-disk drop-ins, so it *preserves* our `fbcon=rotate:1`. No
   migration touches idle 150s/86400s, transform 3, lizard_mode, or backlight
   perms.
2. **The Desktop Mode menu row mechanism survives** (T3's fallback-free
   integration point): `Menu.qml` userMenuPath is byte-identical, the merge
   logic isn't in the delta, and the `omarchy-menu.jsonc` dotted-id schema is
   unchanged.

## The one operational risk that is NEW and matters for the Deck update

**SSH-abort, not reverted settings.** Omarchy grants `%wheel ALL=(ALL:ALL) ALL`
**without `NOPASSWD`**, so the 5 stable migrations that call `sudo` (bluetooth
`1786380259`, limine rebuilds `1786482992`/`1786605598`, wpa_supplicant unmask
`1786567036`, plus the copy-url repair `1786643346` which can `exit 1`) will
**prompt or hang under a headless `omarchy-update` over SSH** with no cached sudo
timestamp. We update the Deck over SSH. The runbook
(`docs/tasks/P36-deck-stable-update-runbook.md`) prime-sudo step exists for
exactly this. On the Deck the NVIDIA/Apple-gated ones early-exit; the live risk
is the two limine rebuilds and the bluetooth toggle.

---

## Note on the `tzupdate` comment (T9 §7 to-do — CLOSED, no edit)

The T9 step-7 list said to fix a stale `src/deck-session.sh` comment quoting
`/etc/sudoers.d/omarchy-tzupdate` as granting `tzupdate` + `timedatectl`. **Re-measured
2026-08-15: the comment is already correct** — it lives at `src/deck-session.sh`
~1696–1717 (not the ~1157 the old note claimed), already records the 2026-08-11
`tzupdate` drop as a dated historical note, and our installed grant (line ~1732)
plus stable's `omarchy-tzupdate` both = `timedatectl set-timezone *` only. Verify-don't-trust
paid off: no edit was needed.

---

## Per-seam detail

The four sections below are the verbatim per-seam classifications, each produced
by an independent agent reading the actual hunks. Re-checked against the summaries
above by the assembling session.


---

# Delta A — BOOT-CHAIN seam classification, `6d7826d` → `f0020448` (v4.0.0 stable)

**Measured 2026-08-15, dev machine, read-only against the bare clone at
`/home/huyke/.cache/omarchy-deck/stable-rebase/omarchy.git`.** Every row below
was written after reading the actual `git diff 6d7826d f0020448 -- <path>` hunk
(or `git show f0020448:<path>` for added files). Nothing is inferred from a
filename or commit subject. Seam = kernel / Limine / mkinitcpio / snapper /
the `setup-*`→`apply-*` renames as they touch the boot & finalizer path.

## Verdicts at a glance

| Verdict | Count |
|---|---|
| **BREAKS US** | **1** |
| **RE-VERIFY** | **1** |
| NO IMPACT | 9 |

---

## Classification table

| STATUS | path | one-line reason (from the hunk) | fix needed |
|---|---|---|---|
| **BREAKS US** | `bin/omarchy-apply-system` (R082, was `bin/omarchy-setup-system`) | The finalizer the ISO calls in the chroot was renamed; stable ships `bin/omarchy-apply-system` and **no longer ships `omarchy-setup-system`** (`git cat-file -e f0020448:bin/omarchy-setup-system` → MISSING). Our orchestrator still shells out to the old name (`.../phases_impl.py:1140,1142` → `"/usr/bin/omarchy-setup-system"`). Guard 6.4a (`iso/bin/build:505-506` greps `/usr/bin/omarchy-*` from the orchestrator; `:612-651` requires every one to exist in the runtime `bin/` or our deck pkg) will **`build_fail`** the moment `iso/RUNTIME` moves to a stable SHA, with the "THE PINNED RUNTIME DOES NOT SHIP IT … a rename" message. Guard 6.4b repeats it against the built `.pkg.tar.zst`. **The guard HOLDS — it fires correctly** (test proof: `test/unit/test-iso-build.sh` case 12, `:564-575`, mv-renames the fixture binary and asserts `BUILD_STATUS -eq 1` + "guard 6.4a" + names `/usr/bin/omarchy-setup-system`). | Edit `iso/upstream/configs/airootfs/usr/share/omarchy-iso/orchestrator/phases_impl.py:1140` and `:1142`: `"/usr/bin/omarchy-setup-system"` → `"/usr/bin/omarchy-apply-system"`. Also update the stale prose comments naming the old binary: `phases_impl.py:14,601,1008` (not build-breaking — bare, no `/usr/bin/` prefix, so the guard's regex ignores them). Do this in lockstep with moving `iso/RUNTIME` to a stable pin — the git ref and the finalizer name must move together (T5-fork-plan §0). |
| **RE-VERIFY** | `migrations/1786482992.sh` (A) — driven by `test/shell.d/limine-cmdline-migration-test.sh` (A) | The limine-cmdline migration. On `omarchy-update` it reads `/proc/cmdline`, and if the booted line is missing **any** param in `/etc/limine-entry-tool.d/omarchy-defaults.conf` (`KERNEL_CMDLINE[default]+=` lines) it runs **`sudo limine-mkinitcpio`** and drops `/var/lib/omarchy/migrations/1786482992`. This is the brief's top-risk shape (root, machine-wide, over our SSH loop) — but it **does NOT rewrite any config or revert a boot setting**: it only rebuilds the UKI from the on-disk `limine-entry-tool.d/` drop-ins, so our `fbcon=rotate:1` (`/etc/limine-entry-tool.d/50-deck-fbcon-rotation.conf`) is *preserved*, not clobbered. `omarchy-defaults.conf` is **byte-identical at both refs** (`git show 6d7826d:… == git show f0020448:…`), so stable introduces no new cmdline param; on a Deck already booting those params the migration is a no-op (`(( ${#missing[@]} )) || exit 0`). | No source edit. Live check on the Deck: (1) run `omarchy-update` with a **tty** — the `sudo limine-mkinitcpio` line prompts, same class as the P22 sudo-migration note; (2) confirm `/proc/cmdline` carries all six default params + our `fbcon=rotate:1` so the migration is a no-op; (3) if it *does* fire, confirm the rebuilt UKI still contains `fbcon=rotate:1` and boots rotated. |
| NO IMPACT | `etc/mkinitcpio.conf.d/omarchy_hooks.conf` (M) | Adds a block that filters the `kms` hook out of `HOOKS` **only when `nvidia_drm` is early-loaded via `MODULES` and NVIDIA owns every 0x03 PCI class device**. Entire block is gated `if [[ " ${MODULES[*]:-} " == *" nvidia_drm "* ]]`. The Deck is AMD — no `nvidia.conf`, no `nvidia_drm` in MODULES — so the block is skipped and the `HOOKS=(… kms …)` line is unchanged from our pin. Our `linux-neptune` UKI rebuild sources this file but the outcome is identical. | none |
| NO IMPACT | `migrations/1786605598.sh` (A) — NVIDIA-only kms initramfs rebuild | Doubly gated away from the Deck: requires **`/etc/mkinitcpio.conf.d/nvidia.conf` to exist** (`[[ -f $hooks_conf && -f $nvidia_conf ]] || exit 0`) AND, after sourcing both drop-ins, that `kms` actually dropped out (`[[ $hooks != *" kms "* ]] || exit 0`). The Deck has no `nvidia.conf` → first gate exits 0 before any `sudo limine-mkinitcpio`. | none |
| NO IMPACT | `bin/omarchy-apply-hardware` (R083, was `bin/omarchy-setup-hardware`) | Same rename + `hidden=true`; now invoked as `omarchy-apply-hardware` **from inside `omarchy-apply-system`** (updated in the same commit). Our orchestrator never calls it directly, so it is **not** in guard 6.4a's `REQUIRED_TARGET_BINS` (confirmed: the orchestrator references only `omarchy-hibernation-setup`, `omarchy-provision-user`, `omarchy-setup-system`). Only stale mention in our tree is the captured manifest `iso/upstream/manifests/fresh-4-semantic.json:2983` — a reference artifact, not consumed by any guard. | none (optional doc hygiene on the manifest) |
| NO IMPACT | `bin/omarchy-apply-lock` (R097, was `bin/omarchy-setup-lock`) | Adjacent to the lock/PAM path, not the boot chain. Our orchestrator does not call it; its upstream callers (`install/config/lockscreen-pam.sh`, `omarchy-upgrade-to-quattro`) were updated in the same range. Not in `REQUIRED_TARGET_BINS`. | none |
| NO IMPACT | `install/hardware/apple/fix-t2.sh` (M) | The **only** `limine-entry-tool.d` write in the whole delta besides the defaults file: it writes `/etc/limine-entry-tool.d/t2-mac.conf` with `KERNEL_CMDLINE[default]+=" intel_iommu=on …"`. Apple-T2 hardware-gated; the Deck's DMI vendor is Valve. The changed hunk only moves the brcmfmac block out to the new script; the limine block is untouched. | none |
| NO IMPACT | `install/hardware/all.sh` (M) | Single added line: `run_logged .../apple/fix-brcmfmac-supplicant.sh`. Apple-gated leaf. The "Panther Lake kernel" swap at line 18 is **unchanged** (present at both refs, not in the hunk) and Intel-gated. | none |
| NO IMPACT | `migrations/1781043107.sh` (M) | "Move current Omarchy theme state to ~/.local/state" — theme-state relocation, no kernel/limine/snapper. | none |
| NO IMPACT | `migrations/1784767406.sh` (M) | "Remove the obsolete Voxtype Hyprland toggle" — deletes a user toggle file. No boot content. | none |
| NO IMPACT | `test/shell.d/snapper-test.sh` (M) | Only boot-adjacent snapper file in the delta, and it is a test. The one changed line is the `setup-system` → `apply-system` grep target (`:74`); the asserted snapper policy (timeline disable, `snapper-cleanup.timer` + `limine-snapper-sync.service` enable) is **unchanged**. No snapper config/policy file is in the delta at all. | none |

---

## What is provably NOT in this delta (load-bearing negatives)

- **The packaged Limine cmdline defaults did not move.**
  `etc/limine-entry-tool.d/omarchy-defaults.conf` is **not** in
  `delta-namestatus.txt` and is byte-identical at `6d7826d` and `f0020448`.
  `initramfs_async=0` and the five other default params were **already in our
  pin**. Stable introduces no new kernel command-line parameter. This is why
  migration `1786482992` is a no-op on an up-to-date Deck rather than a config
  rewrite.
- **No change to the Limine machinery our `src/omarchy-deck-kernel.sh` couples
  to.** Nothing in-range touches `limine-entry-tool`, `limine-mkinitcpio-hook`,
  the Limine config grammar, ESP handling / `fmask`, UKI naming
  (`CUSTOM_UKI_NAME="omarchy"`), `default_entry:`, `BOOT_ORDER`, or
  `ENABLE_LIMINE_FALLBACK`. `src/omarchy-deck-kernel.sh` (all ~10 stages) has
  **no row that breaks** — its coupling surface (T9-coupling-inventory §1) is
  untouched by this delta. ⚠️ Still not promotable to a *package* fact: the
  `limine` / `limine-mkinitcpio-hook` packages move independently of this
  branch.
- **No snapper policy change.** `default/snapper/root` is not in the delta;
  `MAX_SNAPSHOT_ENTRIES=6` / `NUMBER_LIMIT=5` are unchanged in
  `omarchy-defaults.conf`. Only `test/shell.d/snapper-test.sh` changed, and only
  its rename grep target.
- **The `setup-*`→`apply-*` rename affects exactly one thing on our boot/
  finalizer path**: the ISO orchestrator's call to `omarchy-setup-system`. The
  guard was purpose-built for it (`iso/bin/build` guard 6.4a/6.4b) and it fires
  correctly; the test (`test/unit/test-iso-build.sh` case 12) already encodes
  this exact stable scenario as an expected `build_fail`.

## Top risks (short)

The single actionable break is the **`omarchy-setup-system` → `omarchy-apply-system`
finalizer rename**: the moment `iso/RUNTIME` is repinned to stable, guard 6.4a
refuses the build (loudly, before docker) because our
`phases_impl.py:1140,1142` call a binary stable no longer ships. This is a
one-line-each fix in our orchestrator, and it must land in the same commit that
moves the runtime pin — the git ref and the finalizer name are two independent
pins that this rename split apart. Everything else in the boot seam is either
hardware-gated away from the Deck (the two NVIDIA/kms changes, the T2 limine
drop-in) or a rebuild-from-existing-config migration that **preserves** our
`fbcon=rotate:1` rather than reverting it. The brief's worst-case — a migration
that rewrites Limine config or kernel cmdline and reverts a load-bearing boot
setting — **does not exist in this range**: `migrations/1786482992.sh` only ever
runs `limine-mkinitcpio` against the unchanged on-disk drop-ins, and
`omarchy-defaults.conf` did not change. The one live check owed is running that
migration with a tty (the `sudo limine-mkinitcpio` prompts over SSH) and
confirming the Deck's `/proc/cmdline` makes it a no-op.

---

# Delta B — LOCK / SESSION-LOCK / IDLE seam classification

**Stable rebase.** Range `6d7826d` (our pin) .. `f0020448` (v4.0.0 stable).
Every row below was written after reading the **actual hunk** with
`git -C …/omarchy.git diff 6d7826d f0020448 -- <path>` (or `git show
f0020448:<path>` for adds). Nothing is inferred from a filename.

Priors relied on: `docs/findings/T9-lock-service-mitigation.md` (tier-0
hardware-equivalent proof of the `above_lock=2` + sleep-lock-mask mitigation),
`docs/findings/T9-lock-wake-and-blank-timing.md` (the blank-timer patch),
`docs/findings/T9-delta-classification.md` (the beta2 BREAKS-US row).

## Verdict on the stranded-lock question (asked first because it is the seam)

**The beta2 BREAKS-US row STAYS in stable, byte-for-byte the same mechanism —
and it is already mitigated in our tree, so it is now RE-VERIFY (PASS), not
BREAKS US.**

- The stranded-lock code (`strandedLock`/`strandedLockResolved`,
  `checkStrandedLock()`, `recoverStrandedLock()→beginLock()`,
  `strandedLockCheckProc` running `omarchy-hyprland-session-locked`, the 500 ms
  ×20 retry timer, and arming from `Component.onCompleted` /
  `onScreensChanged` / `onPasswordPamConfiguredChanged`) is **added in this
  range** — it was absent at our pin `6d7826d` (`omarchy-hyprland-session-locked`
  did not exist at `6d7826d`). It is identical in shape to what
  `T9-lock-service-mitigation.md` analysed against `quattro`. No new arming
  site, no new producer.
- `recoverStrandedLock()` still calls `beginLock()` without reading `idle.lock`
  — exactly the gap the beta2 row named. **But that finding already proved
  (tier 0, pixel-counted on real Hyprland) that the correct answer is to make
  the lock *answerable* (`above_lock=2`) and remove the only *undeliberate*
  producer (mask `omarchy-sleep-lock.service`), not to prevent recovery.** Both
  mitigations are now **implemented in our tree**, so nothing here breaks us:
  - `src/deck-session.sh:3600` writes `idle.lock=86400` / screensaver 150 (D).
  - `src/deck-session.sh:~3412` `install_sleep_lock_mask` masks
    `omarchy-sleep-lock.service` at `/etc/systemd/user` (F).
  - `src/deck-session.sh:3127-3163` installs the `deck-input-mapper-virtual-keyboard`
    device rule and (per the OSK stage) the `above_lock=2` layer rule for
    namespace `deck-osk` (G).
  - `src/omarchy-deck-patches/patches/0010-lock-blank-timer-20s.patch` retunes
    the blank timer (see below).
- **The lock UI itself did not change in this range.** `LockView.qml` and
  `shell/plugins/lock/manifest.json` are **unchanged** (`--stat` shows only
  `Service.qml` touched in `shell/plugins/lock/`). The surface is still
  `ext-session-lock` via `sessionLock` (`WlSessionLock`), `keepLoaded: true`.
  Its render-above-every-layer-surface behaviour — the whole reason our OSK
  needs `above_lock=2` — is identical to what tier-0 measured.

### The release-notes "hyprlock replaced by shell PAM flow" claim
**True, but it happened *before* our pin.** At `6d7826d` the shell-integrated
lock already carried `authenticatingPassword`, `fingerprintAuthenticating`,
`fingerprintConfigured`, `refreshFingerprintStatus()` and `fingerprintPam`.
There are **no hyprlock files anywhere in the `f0020448` tree**, and hyprlock
appears nowhere in the delta. So the password+fingerprint PAM lock is not new to
this rebase; it is what our pin already shipped. The Deck has **no fingerprint
reader**, so `fingerprintConfigured` is false and every fingerprint path is
inert on our hardware.

### (b) Does the new lock trap a controller-only user above our layer-shell OSK?
Same trap surface as before, **no new shape**. It is `ext-session-lock`, which
renders above layer surfaces; our OSK (`src/deck_osk_wayland.py`, namespace
`deck-osk`, `KeyboardMode.NONE`, empty input region) is invisible under it
*unless* the `above_lock=2` rule is applied — which our tree applies, and which
tier 0 proved renders the OSK over a live lock while keystrokes still land in
the password field. The one caveat from tier 0 is unchanged: `above_lock` buys
nothing in the *stranded* (dead-client) state, which is precisely why the
`recoverStrandedLock()` delta is a fix — it replaces the unanswerable
`lockdead.png` splash with a real password box the OSK can sit over.

### (c) Is the idle-policy neutering (screensaver 150 / lock 86400) still right?
**Yes — the setting did not move or rename.** `config/omarchy/shell.json` is
**not in the delta**; at `f0020448` it still reads
`{"idle":{"screensaver":150,"lock":300}, …}` with the top-level `idle` key.
`shell/plugins/services/idle/` is **unchanged**, so `secondsFromConfig`
(including `lock:0` = fire-immediately, and the 32-bit Timer ceiling) is intact
and our `86400` is still the right shape. Our write path
(`src/deck-session.sh:3600`, `OMARCHY_SHELL_JSON_REL=.config/omarchy/shell.json`)
is unaffected. **The only thing that can silently mutate that file is the new
`shell.qml`/`PluginRegistry` `putBarWidget` write-back** (RE-VERIFY below), and
it touches `config.bar` only.

---

## Classification table

| STATUS | path | reason (from the hunk) | fix needed |
|---|---|---|---|
| **RE-VERIFY (PASS)** | `shell/plugins/lock/Service.qml` (M) | +86/-6. Adds the stranded-lock re-lock (`checkStrandedLock`/`recoverStrandedLock`→`beginLock()`, `strandedLockCheckProc`, 500 ms×20 `strandedLockRetryTimer`, arming from `Component.onCompleted`/`onScreensChanged`/`onPasswordPamConfiguredChanged`). Also retargets the blank-timer gate `!root.authenticating` → `!root.authenticatingPassword` and renames `onAuthenticatingChanged`→`onAuthenticatingPasswordChanged` (fingerprint PAM stays armed the whole lock; inert on the readerless Deck). | None to land the rebase. Our mitigations (D+F+G) already cover it. **Re-verify** patch `0010` still applies (it does — see below) and that the `above_lock`/mask stages are present. This is the beta2 "BREAKS US" row, downgraded. |
| **RE-VERIFY (PASS)** | `src/omarchy-deck-patches/patches/0010-lock-blank-timer-20s.patch` (OUR file, vs stable `Service.qml`) | Stable shifts the `idleBlankTimer` block from line 373 to line **416** and rewrites the `onTriggered` body 3 lines below the patched `interval: 5000`. The patch's own context lines (`Timer {` / `id: idleBlankTimer` / `interval: 5000` / `repeat: false` / `property double armedAt: 0` / `onTriggered: {`) are all byte-identical at `f0020448`. | **`git apply --check` PASSES** against stable's file (verified, plain and `--recount`) — the harness `omarchy-deck-apply-patches` uses `git apply`, which tolerates the line offset. No rebase of the patch needed for this delta. |
| **RE-VERIFY** | `bin/omarchy-hyprland-session-locked` (A) | New. `hyprctl -j monitors` → `jq`: `LOCK` in any `solitaryBlockedBy` ⇒ exit 0; a `readable` monitor (not `WORKSPACE`-only) ⇒ 1; else 2. This is the read-only sensor `recoverStrandedLock()` and `omarchy-restart-shell` consume. Tier-0 (`T9-lock-service-mitigation.md` T0.3) already confirmed this exact logic on real Hyprland. | None. It cannot create a lock; it reports one. Keep it in mind only as the trigger for the (mitigated) recovery path. |
| **RE-VERIFY** | `shell/shell.qml` (M) | `putBarWidget` now routes to `pluginRegistry.putBarWidget(...)` inside a `try` (returns the registry error string); adds `togglePanelAt(section,index)`. `putBarWidget` is the IPC front door that makes the shell rewrite `~/.config/omarchy/shell.json` — **the file carrying our idle policy**. Registry edits `config.bar` only, so top-level `idle` should survive. | Re-read `idle.screensaver`/`idle.lock` from the user's `shell.json` after any `omarchy-update` (the §5.20 readback), since an unattended `putBarWidget` can now rewrite that file. Not a code change. |
| **RE-VERIFY** | `shell/plugins/bar/widgets/KeyboardLayout.qml` (M), `KeyboardLayoutModel.js` (A), `KeyboardLayout.manifest.json` (M) | Full rewrite. New `UNTYPED_KEYBOARDS = /^(hl-virtual-keyboard\|power-button\|sleep-button\|lid-switch\|video-bus)/` decides which devices the widget will read/`switchxkblayout`. **Our OSK device `deck-input-mapper-virtual-keyboard` is NOT in that set**, so `isTypedKeyboard()` returns true for it — the widget is now eligible to *select and cycle* our synthetic keyboard, where the old code only excluded `hl-virtual-keyboard`. Label is now `xkbcli list --load-exotic` briefs, not the first 3 chars. | Latent, not live: on the single-layout Deck session every device (incl. ours, pinned `kb_layout=us` single via `src/deck-session.sh:3151`) has no comma in `kb.layout` ⇒ `multipleLayouts=false` ⇒ widget hides and a click is a no-op `switchxkblayout … next` that wraps back. **If** the session ever gains a 2nd layout, verify a widget click cannot run `switchxkblayout deck-input-mapper-virtual-keyboard next` and desync the OSK keycode→char map. `xkbcli` ships with `libxkbcommon` (payload note). |
| NO IMPACT | `bin/omarchy-apply-lock` (R097, from `omarchy-setup-lock`) | Header-only: drops `group=setup`/`name=lock`, adds `hidden=true`. Body unchanged. Its callers (`lockscreen-pam.sh`, upgrade-to-quattro) were updated in-range. | We never call it. Grepped `src/` — no reference. |
| NO IMPACT | `bin/omarchy-system-lock` (M) | Adds `pkill -x ttfx` + `timeout 1s pidwait -x ttfx` before the existing screensaver `pkill`. This is producer C (the menu "Lock" row). Behaviour toward the lock itself is unchanged. | We never call it; the `system.lock` menu row is deliberately left alone (a lock the user asks for is not a lockout, and `above_lock` makes it answerable). |
| NO IMPACT | `install/config/lockscreen-pam.sh` (M) | One line: `omarchy-setup-lock` → `omarchy-apply-lock`. Still writes `/etc/pam.d/omarchy-lock-password`, i.e. `passwordPamConfigured=true`. | Install-time; not called from `src/`. That PAM file being present is the *desired* precondition — it is the gate that lets `recoverStrandedLock()` show an answerable box rather than a dead splash. |
| NO IMPACT | `install/user/first-run/enable-user-units.sh` (M) | Adds only `omarchy-crash-watch.service`; the `omarchy-sleep-lock.service` line is unchanged. | Our F mask lives at `/etc/systemd/user`, which precedes `~/.config/systemd/user`-less first-run enables in systemd's search order, so a per-user `enable --now` still resolves to the `/dev/null` mask. `omarchy-sleep-lock.service`, `omarchy-system-sleep-lock`, `omarchy-system-sleep-monitor` are all **unchanged** in range. |
| NO IMPACT | `bin/omarchy-toggle-idle` (unchanged in range; present at both refs) | The new menu row `trigger.toggle.idle-lock` "Stay Awake" → `omarchy-toggle-idle`. Grep shows it drives a systemd idle-inhibit state, **not** `shell.json`. | Orthogonal to our idle neutering; existed at our pin. |
| NO IMPACT | tests: `lock-stranded-recovery-test.sh` (A), `hyprland-session-locked-test.sh` (A), `lock-blank-fingerprint-test.sh` (A), `system-lock-test.sh` (A), `keyboard-layout-test.sh` (A), `lock-fingerprint-indicator-test.sh` (M), `lock-password-overflow-test.sh` (M) | All are static-text (node regex over `Service.qml`) or fake-`hyprctl` (canned JSON) assertions — they pin the code paths, they do not provoke a real lock. `lock-stranded-recovery` asserts `exitCode===2 ⇒ return` and the `Component.onCompleted→checkStrandedLock()` arming; `lock-blank-fingerprint` asserts the `!authenticatingPassword` gate; `hyprland-session-locked` drives the helper against fake monitor JSON. | Out of scope by the brief; read to locate the code, as instructed. No coupling to `src/`. |

---

## Top risks

The seam is **quieter than the beta2 delta made it look.** The single scary row
— `shell/plugins/lock/Service.qml`'s automatic re-lock — is genuinely present
and unchanged in stable, but it is the row this project already spent
`T9-lock-service-mitigation.md` on and *already shipped countermeasures for*:
`idle.lock=86400` (D), the `omarchy-sleep-lock.service` mask (F), and the
`above_lock=2` layer rule (G), the last proven on real Hyprland to render our
OSK over a live lock while keystrokes reach the password field. Nothing in
`6d7826d..f0020448` weakens any of those three: `shell.json`'s schema is
unchanged, the idle engine is unchanged, `LockView.qml`/the lock manifest are
unchanged, the `ext-session-lock` surface is the same, and the
`omarchy-sleep-lock` unit our mask targets is byte-identical. So there is **no
BREAKS US row** — no file in `src/` is falsified by this delta.

The two things actually worth a hands-on look, both RE-VERIFY not breaks:
**(1)** patch `0010` — confirmed to still `git apply` cleanly, but stable
rewrites the `onTriggered` body immediately below its context, so it is the one
piece of ours living in a file upstream keeps editing; keep the monthly-rebase
expectation the meta already sets. **(2)** the `KeyboardLayout` rewrite now
treats our `deck-input-mapper-virtual-keyboard` as a *typed* keyboard eligible
for `switchxkblayout` — harmless on today's single-layout Deck (widget hides,
click is a no-op) but a latent way to desync the OSK if the session ever grows a
second layout. Everything else in the seam is rename churn (`setup-`→`apply-`),
producer-C cosmetics (`omarchy-system-lock` killing `ttfx`), or test files.

The one operational note that outlives this delta: the new
`putBarWidget`/`PluginRegistry` write-back (`shell.qml`) can now rewrite the
user's `shell.json` unattended during an update. It edits `config.bar` only, so
`idle` *should* survive, but our idle policy lives in that same file — re-read
`idle.screensaver`/`idle.lock` after any `omarchy-update` rather than assuming.

---

# Delta-C — MENU + HYPRLAND-DEFAULTS + MONITORS seam

Range `6d7826d` (pin) → `f0020448` (v4.0.0 stable). Bare clone:
`/home/huyke/.cache/omarchy-deck/stable-rebase/omarchy.git`.
Every row below was read from the actual hunk, not inferred from the filename.

## Verdict on the Desktop Mode menu-row mechanism

**IT SURVIVES — cleanly, no change to the extension shape.** This was T3's last
integration point with no fallback, so it was checked to the metal:

- `shell/plugins/menu/Menu.qml:51` in stable is **byte-identical** to what our
  coupler comment quotes (`src/deck-session.sh:181-183`):
  `property string userMenuPath: Quickshell.env("HOME") + "/.config/omarchy/extensions/omarchy-menu.jsonc"`.
  The user extension path did not move.
- `shell/plugins/menu/MenuModel.js` is **not in the delta at all** — unchanged
  between pin and stable. `mergeMenuSources(defaultItems, userItems)` still
  exists (line 65) and still appends unknown ids, exactly as
  `src/deck-session.sh:198-201` assumes for `MENU_ROW_ID=gaming` landing at the
  tail of the root order.
- `default/omarchy/omarchy-menu.jsonc` schema is **unchanged**: still a flat map
  of dotted string ids to `{"icon","label","action",...}` objects, parent
  inferred from the dotted id. All 4.0.0 changes are content (new rows:
  `learn.herdr-keybindings`, `trigger.capture.qr`, `install.preinstalls`, Grok
  Bot, etc.) plus an **optional** new `"title"` field on a few submenu parents
  (`setup.default.agent`, `.browser`, `.terminal`, `.editor`). Adding an
  optional key does not affect our row, which sets `icon`/`label`/`action` only.
- **No root-id collision.** Stable defines no bare `"gaming"` root id (top-level
  ids are: about, apps, install, learn, remove, setup, style, system, trigger,
  update). The `install.gaming*` ids are children of `install`, a different
  namespace from our root `gaming`. Our row still lands as a fresh root row.
- The verb interface our input-mapper couples to (`omarchy-menu toggle apps`,
  `omarchy-menu toggle`, `omarchy-menu toggle system`) is **unchanged**: stable
  `bin/omarchy-menu` still `case`s on `toggle|summon|close|refresh|ping` with
  `route="${2-root}"`. The only hunk swaps the internal `menu_payload` helper
  from perl to `jq` — an implementation detail behind the same argv.

No action required for our Desktop Mode row. Our coupler at
`src/deck-session.sh:181-201,MENU_ROW_ID` continues to apply verbatim.

## (b) Hyprland default Lua vs. transform-3 / uwsm

**No impact.** None of the four `default/hypr/*.lua` hunks touch monitor
transform, rotation, `hl.monitor`, or uwsm session start:

- `apps/system.lua` — About-window sizing comment/rule only.
- `bindings/applications.lua` — one added bind (Herdr).
- `bindings/utilities.lua` — added binds (Herdr keybindings, bar-panel 1-9,
  reworked slurp capture binds), `omarchy-launch-agent`→`omarchy-agent --pick`.
  Still uses `hl.config({ cursor = {...} })` / `hl.get_config(...)` — the **same
  nested-table `hl.config` API our greeter Lua relies on** (coupler §4), so this
  is mild positive evidence the greeter API is intact.
- `nvidia.lua` — swaps `lspci | grep nvidia` for a cached-sysfs detector binary.
  Deck is an AMD APU; the whole `if` never fires. Irrelevant.

The Deck panel transform (`transform = 3`, `eDP-1`, `scale = 1.25`) lives in our
greeter Lua at `src/deck-session.sh:610-616,2146` and in the runtime
`monitors.lua` surface — neither is one of these files. `hl.monitor`'s
keyword-table signature is **confirmed still current** by stable's
`bin/omarchy-hyprland-monitor-clamshell`, which parses
`hl.monitor({ output = "", mode = "preferred", position = "auto", scale = ... })`
— identical shape to our greeter call plus our extra `transform` key.

## (c) Monitor handling vs. portrait-native / transform-3

**No breakage.** The 4.0.0 monitor binaries detect the internal panel **by name**
(`^(eDP|LVDS|DSI)-`), never by orientation, so a portrait-native / transform-3
panel is not an assumption any of them violates:

- `omarchy-hw-external-monitors` — tightened the internal-panel skip from a glob
  to a regex `-(eDP|LVDS|DSI)-`; `eDP-1` still matches, still skipped.
- `omarchy-hyprland-monitor-external-active` — adds `all` to `hyprctl monitors`;
  same name-based external test.
- `omarchy-hyprland-monitor-clamshell` — rewrote `configured_monitor_scale` to
  read **scale** (not transform) from `monitors.lua`, with a new fallback chain.
  It parses `scale=`, so our `transform = 3` does not interfere; but it *does*
  read the user `monitors.lua` shape (our coupler §14), so RE-VERIFY that the
  rotated-desktop `monitors.lua` a user might write still yields a scale here.
  We ship no `monitors.lua` (no stage writes it), so this is a runtime-desktop
  concern, not an install-time break.

## Classification table

| STATUS | path | reason (from hunk) | fix needed |
|---|---|---|---|
| NO IMPACT | `default/omarchy/omarchy-menu.jsonc` | Same dotted-id/object schema; only new content rows + optional `title` key. No mechanism change. | none |
| NO IMPACT | `shell/plugins/menu/Menu.qml` | Only hunk: card-height constant `0.6`→`0.7`. `userMenuPath:51` (extension path) byte-identical to our coupler quote. | none |
| NO IMPACT | `shell/plugins/menu/MenuModel.js` | Not in delta; `mergeMenuSources` append behavior unchanged (our root `gaming` row still appends). | none |
| NO IMPACT | `bin/omarchy-menu` | Verb `case` (toggle/summon/close/refresh/ping) + `route="${2-root}"` unchanged; only `menu_payload` perl→jq internally. Our `toggle apps/system` args hold. | none |
| NO IMPACT | `bin/omarchy-menu-keybindings` | awk priority reorder + cache key `v8`→`v11`. We never invoke it (grep of src/tools/test: 0 hits). | none |
| NO IMPACT | `bin/omarchy-menu-images` | flock-based thumbnail locking, vips migration. Not invoked by us. | none |
| NO IMPACT | `bin/omarchy-menu-share` | `find\|fzf`→`omarchy-file-select`. Not invoked by us. | none |
| NO IMPACT | `bin/omarchy-menu-herdr-keybindings` (NEW) | New Herdr-app binary; additive, we never reference it. | none |
| NO IMPACT | `default/hypr/apps/system.lua` | About-window sizing comment/rule only; no monitor/transform. | none |
| NO IMPACT | `default/hypr/bindings/applications.lua` | One added Herdr bind. | none |
| NO IMPACT | `default/hypr/bindings/utilities.lua` | Added binds + `hl.config` cursor call (same API our greeter uses); no transform/uwsm. | none |
| NO IMPACT | `default/hypr/nvidia.lua` | NVIDIA detector swap; Deck is AMD, branch never fires. | none |
| NO IMPACT | `bin/omarchy-hw-external-monitors` | Internal-panel skip regex `-(eDP\|LVDS\|DSI)-`; `eDP-1` still skipped. | none |
| NO IMPACT | `bin/omarchy-hyprland-monitor-external-active` | `hyprctl monitors all -j`; name-based external test unchanged. | none |
| NO IMPACT | `bin/omarchy-monitor-state` | No transform/orientation logic in hunk. | none |
| RE-VERIFY | `bin/omarchy-hyprland-monitor-clamshell` | New `configured_monitor_scale` fallback chain parses user `monitors.lua`. Reads `scale`, not `transform`, so transform-3 is safe — but it touches our `monitors.lua` coupling surface (deck-session.sh §14). | Runtime-only; if a user writes a rotated `monitors.lua`, confirm scale still resolves. We ship none, so no install break. |
| NO IMPACT | `bin/omarchy-hyprland-monitor-modeless` (NEW) | New probe binary; additive. | none |
| NO IMPACT | `bin/omarchy-hyprland-monitor-watch` | No transform/orientation change in hunk. | none |
| NO IMPACT | `bin/omarchy-hyprland-session-locked` (NEW) | New lock-state probe; additive, not referenced. | none |

## Top risks

There are **none that break us in this seam.** The single load-bearing,
fallback-free coupling — the Desktop Mode menu row extending
`~/.config/omarchy/extensions/omarchy-menu.jsonc` — survives the rebase
completely: the extension path (`Menu.qml:51`), the merge logic
(`MenuModel.js:mergeMenuSources`, unchanged), the JSONC dotted-id schema, and
the absence of a colliding root `gaming` id were each verified against stable's
tree, not inferred. The `omarchy-menu` verb argv our input-mapper drives
(`toggle apps` / `toggle` / `toggle system`) is also unchanged. Transform-3
rotation is untouched by any `default/hypr` Lua and by every monitor binary
(all detect the panel by name `eDP-1`, never by orientation), and stable's
clamshell parser independently confirms the `hl.monitor({...})` keyword-table
signature our greeter uses is still current. The only item worth a second look
is `omarchy-hyprland-monitor-clamshell`'s rewritten `monitors.lua` scale parser
(RE-VERIFY), and only at runtime — it reads `scale`, not `transform`, and we
ship no `monitors.lua`, so it cannot break an install.

Out-of-scope note carried for the rebaser: our greeter Lua is a SHA-pinned
mirror (`UPSTREAM_GREETER_SHA256=353fe59d…`) of `/usr/share/sddm/hyprland.lua`,
owned by the **omarchy-settings-dev** package — not present in this
basecamp/omarchy delta. Its drift is guarded by a warn-only hash check
(`deck-session.sh:2114`) and must be re-mirrored separately if that package
moved between the pin and 4.0.0.

---

# Delta D — Packages / Migrations / Installer / Sudoers-Polkit seam

Range: `6d7826d` (our pin) .. `f0020448` (v4.0.0 stable).
Seam owner scope: 14 migrations, `install/omarchy-base.packages`, install scripts,
`etc/sudoers.d/omarchy-tzupdate`, all polkit/pkexec touch points.
Method mirrors `docs/findings/T9-delta-classification.md`. Every file read in full
from actual content, not inferred from names.

## Decisive cross-cutting fact — Omarchy `%wheel` sudo is NOT passwordless

`bin/omarchy-provision-owner:737` writes `/etc/sudoers.d/00-omarchy-wheel`:

```
%wheel ALL=(ALL:ALL) ALL
```

That is `ALL`, **not** `NOPASSWD: ALL`. So every migration that shells out to `sudo`
(bluetooth power, `limine-mkinitcpio`, `systemctl unmask`) needs a password unless a
sudo timestamp is already cached (as it is when `omarchy-update` itself runs under a
sudo the operator authenticated). **A non-interactive SSH `omarchy-update` with no
cached sudo timestamp will block/abort at the first `sudo` migration.** This is the
single most important thing to verify for the SSH iterate loop. The only narrow
`NOPASSWD` grants Omarchy ships are `omarchy-tzupdate` and `omarchy-dev-path` — nothing
that covers these migration `sudo` calls.

## Classification table

| STATUS | path | reason (actual hunk/content) | fix needed |
|---|---|---|---|
| RE-VERIFY | `install/omarchy-base.packages` | Only two additions, no removals: `+libvips` (l70), `+zbar` (l147). Both also pulled by migrations 1786386460 / 1786447584. They enlarge the offline pacman payload + ISO size. | Confirm T5 offline payload (`iso/upstream/builder/build-iso.sh` copies this file to `/usr/share/omarchy-iso/omarchy-base.packages`, consumed by `orchestrator/phases_impl.py:728`) caches `libvips` + `zbar`. Trivial size delta; no coupler breaks. |
| NO IMPACT | `etc/sudoers.d/omarchy-tzupdate` | Dropped the `tzupdate` half; stable content is exactly `%wheel ALL=(root) NOPASSWD: /usr/bin/timedatectl set-timezone *`. Our stage depends only on the surviving `timedatectl set-timezone *` half. | None — see note below; our comment is already correct. |
| NO IMPACT | `install/hardware/bluetooth.sh` | Stops writing `AutoEnable=false` into `/etc/bluetooth/main.conf`; leaves stock default. Power state now held in the rfkill soft block by `omarchy-bluetooth-power`. Our repo never wrote `main.conf` (grep of `src/` + `iso/` finds no `AutoEnable`/`main.conf` writer), so no setting of ours reverts. | None; but pairs with migration 1786380259 below (RE-VERIFY). |
| NO IMPACT | `install/config/lockscreen-pam.sh` | Single-line rename `omarchy-setup-lock` → `omarchy-apply-lock` (bin rename R097). Runs at install; no privilege/PAM policy change. | None. Confirm no hardcoded `omarchy-setup-lock` in our repo (none in seam). |
| NO IMPACT | `install/hardware/all.sh` | Adds `run_logged .../apple/fix-brcmfmac-supplicant.sh`. New script is Apple-gated. | None (Deck is not Apple; script self-exits). |
| NO IMPACT | `install/hardware/apple/fix-brcmfmac-supplicant.sh` (NEW) | Only fires on `lspci 106b:180[12]` or Apple `sys_vendor` + brcmfmac IDs. | None (Deck skips). |
| NO IMPACT | `install/hardware/apple/fix-t2.sh` | Removes the inline `brcmfmac.conf` write (moved into the new supplicant script). Apple-T2 only. | None. |
| NO IMPACT | `install/hardware/bluetooth.sh` (privilege) / polkit/pkexec sweep | The 4.0.0 "privilege moved to pkexec/polkit" change is entirely inside the Quickshell `shell/plugins/lock` polkit dialog + a few `bin/` helpers (`omarchy-dns`, `omarchy-dev-install-ydoo`, `omarchy-update-stay-awake`, `omarchy-apply-lock` reads `PKEXEC_UID`). None in our seam; the only delta `pkexec` diff hunks are in `test/shell.d/*` test doubles. Our `src/deck-session.sh` timezone stage still uses `sudo`, not pkexec, and that path is unaffected. | None. Cross-check with the shell/lock seam owner. |
| NO IMPACT | `install/user/first-run/enable-user-units.sh` | Adds `omarchy-crash-watch.service` to the `--user` enable list. Non-privileged user unit. | None. |
| NO IMPACT | `install/user/first-run/welcome.sh` | Copy/text-only (keybind cheatsheet notification). | None. |
| RE-VERIFY | `install/user/first-run/wifi.sh` | Rewritten to gate on `nm-online -q -s/-x/-t` instead of `ping 1.1.1.1`. Touches the first-run wifi/update prompt — adjacent to our load-bearing "Wi-Fi must work in live ISO" + orchestrator wifi coupler. Logic is first-run notification only, not connectivity itself. | Confirm our orchestrator wifi flow does not depend on the old `ping`-based prompt text/behavior. |
| NO IMPACT | `install/user/mise-work.sh` | Comment-only wording change. | None. |

## Migrations run as root on `omarchy-update` — what each mutates

All 14 read in full. State mutation, revert risk against our load-bearing settings
(idle 150s/86400s, transform 3, lizard_mode, backlight sysfs perms, `main.conf`,
NM/wifi), and SSH-abort risk called out per row.

| migration | mutates | reverts one of ours? | SSH-abort risk |
|---|---|---|---|
| `1781043107.sh` (M) | Moves `~/.config/omarchy/current` → `~/.local/state/omarchy/current`; rewrites theme paths in terminal/hypr configs; relinks 6 theme symlinks. All `$HOME`, user-owned. | No — pure per-user theme-state relocation. Does not touch idle/rotation/lizard/backlight/BT/wifi. | None (no sudo). |
| `1784767406.sh` (M) | `rm` obsolete voxtype toggle; `hyprctl reload` unless `OMARCHY_UPGRADE_TO_QUATTRO_LIVE=1`. | No. | None. |
| `1786380259.sh` (NEW) | **`sudo omarchy-bluetooth-power on/off`** (writes `/dev/rfkill` soft block); **`sudo sed -i 's/^AutoEnable=false$/#AutoEnable=true/' /etc/bluetooth/main.conf`**; writes marker `/var/lib/omarchy/migrations/1786380259`. | Touches `/etc/bluetooth/main.conf` — the file the prompt flags. But it reverts *only the exact line Omarchy itself wrote*; we never wrote `AutoEnable`, so nothing of ours is reverted. It **does** change Deck BT runtime state (rfkill) — Bluetooth parity is unfinished, so re-verify against that row, not a regression of a shipped setting. | **Yes if no cached sudo** — two `sudo` calls. Comment claims sudo is used *specifically* so SSH doesn't abort on `/dev/rfkill`, but that assumes NOPASSWD, which Omarchy does not grant. |
| `1786386460.sh` (NEW) | `omarchy-pkg-add libvips`. | No. | Pacman install — needs sudo/network; over SSH inherits update's elevation. |
| `1786391100.sh` (NEW) | Apple/brcmfmac only: appends to `/etc/modprobe.d/brcmfmac.conf`, sets `reboot-required`. | No (Deck not Apple → early `exit 0`). | None on Deck. |
| `1786447584.sh` (NEW) | `omarchy-pkg-add zbar`. | No. | Pacman install (as above). |
| `1786451567.sh` (NEW) | Repairs dangling literal-`~` theme symlinks from 1781043107. User-owned, narrow. | No. | None. |
| `1786482992.sh` (NEW) | **`sudo limine-mkinitcpio`** + marker, iff booted `/proc/cmdline` is missing any `KERNEL_CMDLINE[default]` param from `/etc/limine-entry-tool.d/omarchy-defaults.conf`. | Boot-chain — **Limine is our hard constraint.** Rebuild uses the same `limine-mkinitcpio` mechanism `src/omarchy-deck-kernel.sh` drives, off `/etc/default/limine`; it regenerates the UKI, does not hand-clobber our cmdline. Could fire on the Deck if our booted cmdline lacks an omarchy-defaults param. | **Yes if no cached sudo.** Also mutates the boot image unattended — highest-consequence root action in the set. |
| `1786517850.sh` (NEW) | `rm -rf ~/.cache/omarchy/notification-images`. | No. | None. |
| `1786539345.sh` (NEW) | Symlinks `diagnose-crash` skill into `~/.agents|.claude|.codex|.pi`; `systemctl --user enable/start omarchy-crash-watch.service` (falls back to writing the wants symlink when no user manager, e.g. TTY/SSH). | No. All `--user`, no sudo. | None (explicitly TTY/SSH-safe). |
| `1786549201.sh` (NEW) | `omarchy-hook-install post-update ...setup-agent.hook` (per-user hook file). | No. | None. |
| `1786567036.sh` (NEW) | **`sudo systemctl unmask wpa_supplicant.service`** (+ `--runtime`); **`sudo systemctl restart NetworkManager.service`** iff a wifi device is `unavailable` (skipped when `OMARCHY_UPGRADE_TO_QUATTRO_LIVE=1`). | Touches NM/wifi — load-bearing. Guarded: only restarts NM when `nmcli` reports `wifi:unavailable`. On a Deck whose wifi is *working*, state is `connected`, guard is false → no restart, connection preserved. Only fires the mask-removal at all if `wpa_supplicant` is `masked*` (iwd-era installs). | **Yes if no cached sudo** (two `sudo` calls). Restart-NM branch is the one that could drop an SSH-over-wifi session — but only when wifi is already `unavailable` (i.e. SSH wouldn't be up on wifi anyway). |
| `1786605598.sh` (NEW) | **`sudo limine-mkinitcpio`** + marker, iff `/etc/mkinitcpio.conf.d/nvidia.conf` exists AND evaluated HOOKS drop `kms`. | No — `[[ -f $nvidia_conf ]] || exit 0`; Deck has no NVIDIA drop-in → early exit. | None on Deck. |
| `1786643346.sh` (NEW) | Rewrites Chromium-family `Preferences` JSON to repair the Copy-URL extension shortcut (per-user). Uses **`gum confirm`** and will `exit 1` if an affected browser profile is open or no terminal is available. | No — user config only. | **Yes, conditional.** Only when a browser profile actually carries a ghost `copy-url` binding AND that profile is open (or no tty for `gum`); then it deliberately `exit 1`s to stay pending, which aborts the update run. Low probability on a fresh Deck, non-zero over headless SSH if a browser is running. |

## Known-issue confirmation — `src/deck-session.sh` tzupdate comment

The prompt cited `~line 1157` quoting the sudoers as granting **both** `tzupdate` and
`timedatectl set-timezone`. The live location is **`src/deck-session.sh` lines
1696–1717** (line numbers drifted), and it is **already correct** — no fix needed:

- Line 1709 quotes the *old* form only as a dated historical note ("upstream's file
  read:").
- Lines 1711–1714 already record the 2026-08-11 drop (basecamp/omarchy #6694) and show
  the new form `%wheel ALL=(root) NOPASSWD: /usr/bin/timedatectl set-timezone *` —
  byte-identical to stable `f0020448:etc/sudoers.d/omarchy-tzupdate`.
- The grant we actually install (line 1732) is `${invoking_user} ALL=(root) NOPASSWD:
  ${TIMEDATECTL_BIN} set-timezone *` — the surviving half only.

So our timezone stage's dependency is intact and its comment matches stable. **No edit
required.** (The `iso/upstream/builder/build-iso.sh:120` `arch_packages` list still
carries the `tzupdate` *binary* for the live ISO clock via `omarchy-install-dashboard`;
that is the package, unaffected by the sudoers grant drop — NO IMPACT.)

## Top risks

The dominant risk is not a reverted setting — it is **root migrations that call `sudo`
under an SSH `omarchy-update` when Omarchy grants `%wheel ALL` without `NOPASSWD`**
(`00-omarchy-wheel`). Five migrations shell to `sudo`: bluetooth (1786380259), the two
`limine-mkinitcpio` rebuilds (1786482992 unconditional-ish on Deck, 1786605598 no-op on
Deck), and wpa_supplicant unmask (1786567036). If the update's sudo timestamp isn't
already cached they will prompt/hang, contradicting the migrations' own comments that
assume `sudo` cannot abort. **1786482992 is the sharpest edge**: it can rebuild the
Deck's Limine boot image unattended (`sudo limine-mkinitcpio`) if the booted cmdline
lacks any `omarchy-defaults.conf` param — a Limine-only, boot-critical action, exactly
our hard-constraint territory; verify our `/etc/default/limine` cmdline is a superset of
omarchy-defaults so it either no-ops or rebuilds cleanly. Secondary: **1786380259**
changes Deck Bluetooth runtime state via rfkill and reverts `AutoEnable=false` in
`/etc/bluetooth/main.conf` (only the line Omarchy wrote, so no setting of *ours* is
lost, but it moves the unfinished BT parity row). **1786567036**'s NM restart cannot
hurt a working wifi link (guarded on `wifi:unavailable`) but confirm it. **1786643346**
can `exit 1`/abort the whole update if a Chromium profile with a ghost Copy-URL binding
is open under a headless SSH session. Package delta is benign: `+libvips +zbar`, no
removals — just re-confirm both land in the T5 offline payload.

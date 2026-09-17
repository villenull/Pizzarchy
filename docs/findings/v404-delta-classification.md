# v4.0.4 delta classification — our runtime `f0020448` (v4.0.0) → upstream `c668141e` (v4.0.4)

**Measured 2026-09-16/17 (session 34+), dev machine only, read-only against a
bare clone of `github.com/omacom/omarchy` (note: upstream moved from
`basecamp/omarchy` to `omacom/omarchy`; same project, new owner path) plus a
shallow `omacom/omarchy-pkgs` checkout for the kernel PKGBUILD.** Every row in
the four seam tables below was written after reading the actual
`git diff f0020448 c668141e -- <path>` hunk (or `git show c668141e:<path>` for
added files). Nothing is inferred from a filename or commit subject. This is
the v4.0.4 companion to `T9-stable-delta-classification.md` (which measured
`6d7826d` → `f0020448`); it supersedes that doc wherever they disagree.

## The pins this is measured against

- **From:** `f0020448ca87` (tag v4.0.0) — our `iso/RUNTIME`.
- **To:** `c668141e9c42b13c80c9ca4ea108e11708c5e8a5` (tag v4.0.4).
- **Kernel source:** `omacom/omarchy-pkgs`, `pkgbuilds/linux-omarchy/PKGBUILD`:
  `pkgbase=linux-omarchy`, `pkgver=7.2.5`, `pkgrel=4` (BORE variant identical
  version, +1 scheduler patch).
- Operator decision recorded for this move: **ADOPT upstream `linux-omarchy`
  and retire our Neptune kernel stack.**

## Scope of the move

- **109 commits**, 394 files changed (+26,278/−1,194). Larger than the stable
  delta, but most of it is far from our seams (AI-app menu rows, theme
  scaffolding, browser-policy hardening, security backports).
- The headline change that touches our seams: **the generic Omarchy kernel.**
  Commit `ec73ba5d` ("Migrate to linux-omarchy except on T2 Macs", backport of
  `#11845`) deletes `install/hardware/intel/ptl-kernel.sh`, swaps
  `install/omarchy-other.packages` from `linux`/`linux-headers`/`linux-ptl`* to
  `linux-omarchy`/`linux-omarchy-headers`, rewrites the packaged
  `BOOT_ORDER`, and adds migration `1789325478.sh`. Two follow-ups complete
  it: `dc0d8945`/`28d5251e`/`8f3ab025` (kernel-headers-as-guarantee; final
  state: migration `1789444024.sh`, interim `bin/omarchy-pkg-add-kernel-headers`
  deleted again before the tag).
- Fresh-install kernel path lives in **`omarchy-iso`** (the `UPSTREAM` pin,
  `configurator`'s `detect_kernel` → `user_configuration.json` `kernels=` →
  archinstall), which is a **different repo and NOT in this diff's range**.
  Everything below about "how a fresh install gets its kernel" is therefore
  stated from the in-range facts (availability list + migration) plus our own
  tree's measured wiring (`deck-form.sh` S6 block), never as an upstream-fresh-install
  claim.

## Verdict roll-up (all four seams)

| Verdict | Count | The rows |
|---|---|---|
| **BREAKS US (adopt-driven)** | **1** | The Neptune kernel is retired by decision: `detect_kernel` override, both package lists, and the Neptune stages of `src/omarchy-deck-kernel.sh` must be retargeted/retired in the same commit that moves the pin. Nothing upstream breaks them — the decision does. Listed as BREAKS-US because shipping v4.0.4 + Neptune is an untested, two-kernel configuration nobody owns. |
| **RE-VERIFY (hands-on)** | 7 | `1789325478` dual-kernel window on the live Deck (BOOT_ORDER prefers linux-omarchy while our `default_entry` still points at Neptune); `1787865477` dropping the `input` group (mapper opens `root:input 0660` nodes); plugin-auth shell.qml growth vs `idle` policy; SSH-hardening migration vs the key-based SSH loop; `1789444024` headers repair (needs Valve-free success); clamshell `configured_monitor_scale` "auto" delegation (runtime-only, same as T9); `1788662350` system-sleep ownership repair (unread body). |
| **NO IMPACT** | rest | Detailed per seam below. |

## The two things that would have been scary and AREN'T

1. **Upstream still does not own `default_entry:`.** At `c668141e` the only
   `default_entry` in the tree is the template `default/limine/limine.conf:3`
   (`default_entry: 2`, byte-identical to our pin). `limine-entry-tool`,
   `limine-mkinitcpio`, the migration, and the packaged drop-in all write
   *entries* or *order* — none writes the pointer. T9-coupling-inventory row 60
   ("nothing upstream owns `default_entry:`") survives this delta. Our
   `stage_default_entry` remains the sole owner; it needs retargeting, not
   retirement (see §Boot-ownership answer).
2. **The Desktop Mode menu-row mechanism survives again.** `Menu.qml:51`
   `userMenuPath` is byte-identical, `MenuModel.js` is not in the delta,
   `bin/omarchy-menu` is not in the delta, the JSONC dotted-id schema is
   unchanged, and there is still no bare `"gaming"` root id. Only content rows
   were added (AI apps, sudoless-docker, remove.ai subtree).

## The one operational risk that is NEW and matters for the Deck update

**The update installs a second kernel and asks for a reboot while our pointer
still names the first.** Migration `1789325478` (runs on `omarchy-update`)
`omarchy-pkg-add`s `linux-omarchy`+headers, writes
`BOOT_ORDER="linux-omarchy, linux-omarchy-*, *, *fallback, Snapshots"` into
`/etc/default/limine`, rebuilds, verifies, and sets `reboot-required` — while
explicitly **keeping the old kernel**. On our Deck the old kernel is Neptune
and our `default_entry` is the Neptune entry-path, so post-migration the
machine carries two kernels, boots Neptune (pointer beats order), and waits
for a reboot into a kernel nobody has validated on the panel. The runbook must
treat "update applied, reboot pending" as a dual-kernel window: verify
`limine-entry-tool --tree` shows the linux-omarchy entry, retarget
`default_entry`, and only then reboot — over SSH with the key path confirmed
first (migration `1788124236` hardens sshd in the same update).

---

## Delta A — BOOT-CHAIN seam (`f0020448` → `c668141e`)

**Seam = kernel packaging / Limine order+pointer / mkinitcpio / installer
kernel path / the Neptune retirement surface.**

### A.1 The linux-omarchy kernel path, end to end (traced, not inferred)

| Step | Evidence (read, not guessed) |
|---|---|
| Package | `pkgbuilds/linux-omarchy` in omarchy-pkgs: `pkgbase=linux-omarchy`, `pkgver=7.2.5`, `pkgrel=4`. 93 `.patch` sources: Arch-base + CachyOS scheduler/mm/btrfs/fuse/drm set. **Zero** mentions of neptune/steamdeck/valve/vangogh/jupiter/deck/handheld in the PKGBUILD. `provides=(KSMBD-MODULE NTSYNC-MODULE VIRTUALBOX-GUEST-MODULES WIREGUARD-MODULE)` — it does **not** `provide=linux` (same non-providing shape the old `linux-ptl` had). |
| Fresh-install availability | `install/omarchy-other.packages`: `linux`, `linux-headers`, `linux-ptl`, `linux-ptl-headers` **removed**, `linux-omarchy`, `linux-omarchy-headers` **added**. (This list is the ISO builder's availability list; the archinstall `kernels=` selection itself lives in omarchy-iso, out of range — our `detect_kernel` override is what feeds it on the Deck path.) |
| Existing-system migration | `migrations/1789325478.sh` (44 lines, NEW): x86_64-gated, T2-gated (`omarchy-pkg-present linux-t2` **or** running `*-t2*` kernel → `exit 0`), installs `linux-omarchy` + `linux-omarchy-headers` via `omarchy-pkg-add`, **keeps the old kernel**, deletes any `BOOT_ORDER=` in `/etc/default/limine` and appends the exact-kernel-first order, `sudo limine-mkinitcpio linux-omarchy`, **fails the migration** unless `limine-entry-tool --tree` shows the new entry, sets `reboot-required`. Retry-safe (marker `/var/lib/omarchy/migrations/1789325478`). |
| Headers repair | `migrations/1789444024.sh` (NEW, final form of the `28d5251e`/`8f3ab025` sequence): for `linux-omarchy`/`linux-t2`, if the kernel is present, `omarchy-pkg-add` its headers. All hardware DKMS installers (`fix-bcm43xx`, `fix-tuxedo-backlight`, `fix-yt6801`, `ipu7-camera`, `fix-spi-keyboard`, `nvidia.sh`) now install **only their driver** — the `linux-headers` explicit installs are gone. |
| Default boot **order** | Packaged `etc/limine-entry-tool.d/omarchy-defaults.conf`: `BOOT_ORDER="linux-t2, linux-omarchy, linux-omarchy-*, *, *fallback, Snapshots"` (was `"*, *fallback, Snapshots"`). Pinned by new `test/shell.d/limine-defaults-test.sh`. |
| Default boot **pointer** | Nobody's: template `default/limine/limine.conf:3` still `default_entry: 2`; no new writer anywhere in range. |
| Precedent shape | The deleted `install/hardware/intel/ptl-kernel.sh` is the exact shape the brief expected (`omarchy-pkg-add` + `BOOT_ORDER` drop-in) — and it was **deleted** by this delta, not generalized. There is no surviving per-model kernel installer to imitate; the generic kernel + migration is the whole mechanism. |

### A.2 Classification table

| STATUS | path | reason (from the hunk) | fix needed |
|---|---|---|---|
| **BREAKS-US (adopt)** | OUR `iso/.../deck-form.sh:3345-3346,3420-3442` (`DECK_NEPTUNE_SERIES`, `DECK_KERNEL_PKG`, `detect_kernel`) | Override still names `linux-neptune-611`. After the pin moves, archinstall pacstraps Neptune as THE kernel while the runtime is linux-omarchy: two kernels, two UKIs, untested. Upstream did not break this — the adopt decision makes the old value wrong. | **EDIT**: `DECK_KERNEL_PKG="linux-omarchy"` (drop the series constant or repurpose); keep predicate + override structure (upstream default is still stock `linux` for non-T2, wrong for Deck); re-transcribe the else-branch from the NEW omarchy-iso submodule (`test-deck-form.sh` agreement checks must be updated to the new names). |
| **BREAKS-US (adopt)** | OUR `iso/overlay/configs/deck/deck-install.packages:244` (`linux-neptune-611`) | Pacstraps Neptune onto every target. Must go in the same commit as the `detect_kernel` retarget, or install and kernel-choice disagree. | **RETIRE** the line. No replacement line: `linux-omarchy` reaches the target via the runtime's own lists + archinstall `kernels=` (it is in `omarchy-other.packages`, which `deck-packages.patch` already merges into the mirror download). |
| **BREAKS-US (adopt)** | OUR `iso/overlay/configs/deck/deck-mirror.packages:72` (`linux-neptune-611`) + `:161` (`-headers`) | Carries 350+ MiB of kernel nobody installs. | **RETIRE** both lines. The `-headers` line was already a recommended cut (mirror-only, reader-less — §A.4); this delta executes it. |
| **BREAKS-US (adopt)** | OUR `src/omarchy-deck-kernel.sh:238-248` + `stage_kernel`/`stage_firmware_swap`/`stage_prune` | Neptune install path, Valve-firmware `-Rdd` dance, `linux-neptune-*` glob prune. Dead after adopt; running `stage_kernel` post-adopt would reinstall the retired kernel. | **RETIRE** the Neptune stages (see retirement list §R). Do NOT delete the file: tests pin it (`test-deck-form.sh:3654-3676` series agreement, `test-duplicated-upstream-facts.sh`, five VM suites). |
| **EDIT (retarget)** | OUR `src/omarchy-deck-kernel.sh` `stage_default_entry`/`reconcile_default_entry`/`default_entry_pick_pkgbase` (`:856-899`) | Sole owner of the pointer (upstream still owns nothing — verified §A.1). The pick logic is keyed on the Neptune glob/pin; it must key on `linux-omarchy` after adopt. | **EDIT**: pick `linux-omarchy` (exact), keep path-form write + refuse-to-write-without-entry behavior. |
| **KEEP (as verifier)** | OUR `95-omarchy-deck-kernel.hook` + `stage_reconcile`/`reconcile_uki` | Upstream's hook generates UKIs; ours verifies + repairs (the migration itself admits `limine-mkinitcpio` "can return success after skipping a failed kernel build" — verification has proven value). Retarget the glob from `linux-neptune-*` to `linux-omarchy`, keep the verify-only default. | **EDIT** glob + pick; keep file, keep hook. |
| **KEEP** | OUR `stage_repos` (Valve repos append-last) | Everything in §D-still-needed below that comes from Valve (`steamdeck-dsp`, Valve `gamescope`) still needs `jupiter-staging`/`holo-staging`. Posture unchanged (append-last, P16 audit stands). | none. |
| **RE-VERIFY** | `migrations/1789325478.sh` (A) on the live Deck | Dual-kernel window (see operational risk): BOOT_ORDER prefers linux-omarchy, our pointer still names Neptune, `reboot-required` is set. Also needs `sudo` (no NOPASSWD — T9 finding carries over) and network (Valve repos are NOT on the Deck's pacman.conf; `omarchy-pkg-add` of a non-[omarchy] package must resolve — confirm the migration's package source on the Deck before running). | Hands-on over SSH: confirm package source, run with primed sudo, verify `--tree`, retarget pointer, then reboot. |
| **RE-VERIFY** | `migrations/1789444024.sh` (A) | Headers repair is idempotent and Valve-free (headers come from [omarchy]) — should succeed on the Deck. Confirm it no-ops-or-installs cleanly rather than assuming. | Run after `1789325478`; check `pacman -Q linux-omarchy-headers`. |
| NO IMPACT | `etc/limine-entry-tool.d/omarchy-defaults.conf` (M) | New packaged BOOT_ORDER prefers T2 then linux-omarchy. Our `50-deck-fbcon-rotation.conf` sets only `KERNEL_CMDLINE[default]+=`, never BOOT_ORDER — no writer collision. Drop-ins sort: ours (`50-*`) vs defaults filename unchanged; order between them is irrelevant (disjoint keys). | none. |
| NO IMPACT | `install/hardware/all.sh` (M) + `install/hardware/intel/ptl-kernel.sh` (D) | The only kernel-swap installer is deleted; nothing else in `all.sh` names a kernel. Deck is not Dell/Intel-PTL-gated anyway. | none (delete our references to the precedent, not code). |
| NO IMPACT | `install/hardware/nvidia.sh` (M) + DKMS installers (M) | Headers logic removed in favor of the migration guarantee; Deck is AMD (no `nvidia.conf`, same gate as T9). | none. |
| NO IMPACT | `install/omarchy-base.packages` (M) | `quickshell-git`→`quickshell` (matches migration `1787399318`), `mise`→`mise-bin`, `+qt6-imageformats +cups-pk-helper`, `-cups-browsed -cups-pdf`. No kernel, no cmdline, no Limine. | none (note: packaged quickshell is what our shell runs against — fine). |
| NO IMPACT | `bin/omarchy-apply-system` | **Unchanged in range** (empty diff). Our orchestrator's finalizer call stays valid. | none. |
| NO IMPACT | `default/limine/limine.conf` | Template `default_entry: 2` byte-identical. Our stage converts exactly this to path form. | none. |

### A.3 What is provably NOT in this delta (load-bearing negatives)

- **No `default_entry:` writer was added.** `git grep default_entry c668141e`
  returns only the template. Our pointer ownership is uncontested.
- **No `limine-entry-tool.d` writer besides the packaged defaults file.**
  No installer writes a competing `BOOT_ORDER` drop-in (the ptl drop-in died
  with its script).
- **`linux-omarchy` carries no Deck hardware enablement.** The PKGBUILD names
  no Valve/Neptune/Deck patch and no Deck firmware; its `optdepends` is
  Arch's `linux-firmware`. Whatever the Deck needs beyond mainline 7.2.5 must
  still come from our lists (§D-still-needed) — the kernel swap does not
  absorb any of them.
- **The old kernel is kept, never removed**, by both the migration and the
  package lists (no `pacman -Rdd linux` anywhere in range). There is no
  forced single-kernel state to reconcile with — until we remove Neptune
  ourselves, every machine in transition has two kernels.

---

## Delta B — LOCK / IDLE seam

| STATUS | path | reason (from the hunk) | fix needed |
|---|---|---|---|
| **RE-VERIFY** | `shell/shell.qml` (M, +771/−29) + `shell/plugins/lock/manifest.json` (M) | The growth is the plugin-auth boundary backport (`#9618`: `omarchy.capabilities`, narrow service proxies) + keepLoaded hot-reload honor (`#9485`). The lock manifest gains `"omarchy": {"capabilities": ["authentication"]}`. Idle plumbing is **preserved**: `publicIdleConfigFor` still reads `shellConfig.idle`, `idleConfig` still flows to services. Our mitigations (D idle 86400, F sleep-lock mask, G `above_lock=2`) couple to the idle *config* and the `ext-session-lock` surface, neither of which moved. But: a capabilities gate on plugin *loading* is new, and 771 lines were not read in full. | Hands-on: after update, re-read `idle.screensaver`/`idle.lock` from the user's `shell.json`, confirm the lock still answers over OSK, confirm no capability declaration is required of anything we ship (we ship a menu *extension jsonc*, not a shell plugin — expected none). |
| NO IMPACT | `shell/plugins/lock/Service.qml` | **Not in the delta.** The stranded-lock mechanism T9 classified is byte-identical. | none. |
| NO IMPACT | `shell/plugins/lock/LockView.qml` (M) | One line: `textFormat: Text.PlainText` on the password placeholder. Cosmetic, no behavior. | none. |
| NO IMPACT | `shell/plugins/menu/Menu.qml` (M, lock-adjacent only as menu surface) | Seven added `textFormat: Text.PlainText` lines. Cosmetic. | none. |
| NO IMPACT | `bin/omarchy-toggle-input-device` (M) + `default/hypr/disabled-input-device.lua` (A) + migration `1787618700` | Injection-hardening rewrite (device names as data, not Lua). We never call the toggle; the migration only acts when `$HOME/.local/state/omarchy/toggles/hypr/*-disabled.lua` exists (ours never does — Deck gate has no such writer). | none. |
| **RE-VERIFY** | `migrations/1787865477.sh` (A) — drops the `input` group grant | Removes `$USER` from `input` unless `xpadneo-dkms`/`ydotool` is installed. Our mapper's own comments record a `root:input 0660` node opened via group membership (`deck-input-mapper.py:981-984`), while `deck-session.sh:4386-4392` records `/dev/uinput` via the `uaccess` ACL. Which physical-pad nodes the mapper opens, and under which grant, decides whether this migration deafens the controller. `omarchy-provision-owner` got the matching replay filter in the same range. | Hands-on on the Deck (SSH is live): `id -nG deck`, `pacman -Qq xpadneo-dkms ydotool`, and exercise the mapper's pad open path after the migration runs. If the pad needs the group, the fix is an explicit grant in `deck-session.sh`, not a fight with the migration. |

---

## Delta C — MENU + MONITOR seam

| STATUS | path | reason (from hunk) | fix needed |
|---|---|---|---|
| NO IMPACT | `shell/plugins/menu/Menu.qml` | Only `textFormat: Text.PlainText` additions. `userMenuPath:51` byte-identical to our coupler quote. | none. |
| NO IMPACT | `shell/plugins/menu/MenuModel.js` | Not in the delta. `mergeMenuSources` append behavior unchanged. | none. |
| NO IMPACT | `bin/omarchy-menu` | Not in the delta. Verb argv (`toggle apps`/`toggle`/`toggle system`) unchanged. | none. |
| NO IMPACT | `default/omarchy/omarchy-menu.jsonc` | Content only: new AI rows (`install.ai.t3-code/hermes/openclaw/perplexity`, `remove.ai.*`, agent rows), icon-font swaps, `style.unlock` quoting fix, `update.themes` gains `when`. Schema unchanged; still no bare `"gaming"` root id (verified by grep at `c668141e`). Our root `gaming` row still lands fresh. | none. |
| NO IMPACT | `bin/omarchy-hyprland-monitor-clamshell` (M) | Monitor-name injection guard + `configured_monitor_scale` "auto"/unparseable delegation to the compositor. Reads `scale`, not `transform`; we ship no `monitors.lua`, and our `desktop_rotation` step writes explicit `scale = 1.25` which passes `valid_scale`. | none (runtime-only re-verify carried from T9 if a user hand-writes `monitors.lua`). |
| NO IMPACT | `default/hypr/*` Lua (M) | Bindings/helpers/paths/toggles churn; no monitor-transform/uwsm signature change affecting our greeter. | none. |

---

## Delta D — PACKAGES / MIGRATIONS / INSTALLER / PRIVILEGE seam

| STATUS | path | reason (from hunk/content) | fix needed |
|---|---|---|---|
| **RE-VERIFY** | `migrations/1788124236.sh` (A) — sshd hardening | Disables password auth (or sshd) when a usable key exists. Our SSH loop is key-based (`ssh steamdeck` now live), so the expected outcome is password-auth off + key still working — but the migration runs *inside the same update window* as the kernel migration, and a misread `authorized_keys` check could close the loop's access. | Confirm key login before AND after the update; keep a fallback console path for the reboot. |
| **RE-VERIFY** | `migrations/1788662350.sh` (A) — system-sleep ownership repair | Body not read line-by-line; repairs ownership under `/usr/lib/systemd/system-sleep`. Our power-button files live in `/etc/udev/rules.d` + `/etc/systemd/logind.conf.d` (T13), and T12's patches touch lock/Limine only — expected untouched, but the owning directories overlap in spirit. | Read the body before the update; `ls` our two files after. |
| NO IMPACT | `migrations/1788102906.sh` (A) — legacy udev quarantine | Removes/quarantines only exact Omarchy-3-generated two-line power/wifi bodies. Our `zz-deck-power-button.rules` matches neither name nor body. | none. |
| NO IMPACT | `migrations/1788025225.sh` (A) — retired-installer privileged files | Removes leftover privileged files of retired installers. Our sudoers/udev files are current, not retired. | Re-check our filenames against its list at update time (cheap grep). |
| NO IMPACT | `etc/sudoers.d/omarchy-tzupdate` (M) | Tightened to `^set-timezone [A-Za-z0-9_+][A-Za-z0-9_+.-]*(/...)*$`. Our stage installs its own per-user grant for `timedatectl set-timezone *` and depends only on that half — intact. | none. |
| NO IMPACT | `etc/sudoers.d/omarchy-asdcontrol` (D), `omarchy-dns`/`omarchy-theme-browser` (A) | None are in our privilege path (we use `sudo`, not pkexec, for timezone/priv-write). | none. |
| NO IMPACT | `install/user/first-run/wifi.sh` (M) | `--exec` quoting cosmetics only. First-run notification, not connectivity. | none. |
| NO IMPACT | `bin/omarchy-hibernation-setup` (M), `bin/omarchy-provision-owner` (M, minus groups) | Root-owned staging hardening; autologin unit `@UNIT@` templating; browser-policy dir setup. We call none of these; the `input`/`docker` replay filter affects re-provisioning, covered by the `1787865477` row. | none. |
| NO IMPACT | Remaining ~24 migrations (theme staging, cups split/removal, browser-policy, docker-group opt-in, mise-bin switch, quickshell 0.3.1 return, cursor/hermes/muse wrappers, kitty conf, xcompose, fido2, font retire, rc-channel, tzupdate-adjacent) | User-config or hardware-gated (Apple/T2/Broadcom/Tuxedo/Surface) content; none touches Deck paths, idle policy, Limine, or our files. Each was summarized from its header echo + body scan. | none. |

---

## §R — Concrete retirement edit list (adopt `linux-omarchy`, retire Neptune)

Each row: file → symbol/line → verdict. Order is landing order (same commit
where noted). `set -euo pipefail` applies to every edited script; no silent
failures.

| # | File | Symbol / line | Verdict | Change |
|---|---|---|---|---|
| R1 | `iso/overlay/configs/airootfs/usr/share/omarchy-iso/deck-form.sh` | `DECK_NEPTUNE_SERIES` (`:3345`), `DECK_KERNEL_PKG` (`:3346`) | **EDIT** | `DECK_KERNEL_PKG="linux-omarchy"`; delete the series constant (the suffix is Valve's versioning, meaningless for the generic kernel) and its "four places must agree" block, replaced by a two-place agreement (`omarchy-other.packages` + here) enforced by `test-deck-form.sh`. |
| R2 | same file | `detect_kernel()` (`:3420-3442`) | **EDIT (keep structure)** | Keep the override + `deck_form_is_steam_deck` predicate; Deck branch returns the R1 name; **re-transcribe the else-branch** from the NEW omarchy-iso submodule (it may now return `linux-omarchy` itself — read it, don't assume). |
| R3 | same file | S6 comment block (`:3251-3344`) | **EDIT** | Rewrite the "WHY THIS IS AN OVERRIDE" reasoning for the new world (stock `linux` avoided, not Neptune ensured); keep the line-number-measured ordering proof, re-measured against the new submodule. |
| R4 | `iso/overlay/configs/deck/deck-install.packages` | `linux-neptune-611` (`:244`) + its comment block (`:191-244`) | **RETIRE** | Delete line + block. No replacement (kernel arrives via runtime lists + archinstall `kernels=`). |
| R5 | `iso/overlay/configs/deck/deck-mirror.packages` | `linux-neptune-611` (`:72`), `linux-neptune-611-headers` (`:161`) + comments | **RETIRE** | Delete both. The `-headers` deletion executes the cut P33/F1 already recommended. |
| R6 | `src/omarchy-deck-kernel.sh` | `NEPTUNE_SERIES_DEFAULT` (`:238`), `KERNEL_PKG` (`:244`), `NEPTUNE_PKGBASE_GLOB` (`:248`), `stage_kernel` (`:601-656`), `stage_firmware_swap` (`:556-599`), `stage_prune` (`:974-1029`) | **RETIRE** | Remove Neptune install/firmware/prune stages. **Do NOT delete the file** — `test-deck-form.sh`, `test-duplicated-upstream-facts.sh`, and five VM suites pin it. |
| R7 | same file | `default_entry_pick_pkgbase` (`:859-871`), `stage_default_entry` (`:873-886`), `reconcile_default_entry` (`:891-899`), `apply_default_entry` (`:838-854`) | **EDIT (retarget)** | Pick exact `linux-omarchy`; keep path-form write, keep refuse-without-entry, keep no-Neptune warn-vs-fail reconcile split. |
| R8 | same file | `reconcile_uki` (`:901-958`), `stage_uki` (`:960-971`), `stage_reconcile` (`:1035-1063`), `hook_text` (`:1065-1174`), `HOOK_*` (`:276-279`) | **EDIT (retarget, keep as verifier)** | Glob `linux-omarchy` (exact + `linux-omarchy-*` variants for the entry check, mirroring the migration's verification); the hook stays verify-and-repair, never generate-from-scratch. |
| R9 | same file | `stage_repos`, `require_valve_repos`, `VALVE_REPOS`, `stage_preconditions`, `stage_esp_detect`, `stage_esp_permissions`, `INSTALL_STAGES` | **KEEP** | Valve repos still source §D-still-needed; ESP/permissions stages are kernel-independent. |
| R10 | `test/unit/test-deck-form.sh` | series-agreement checks (`:3654-3676`) | **EDIT** | Assert `DECK_KERNEL_PKG == linux-omarchy` (and cross-check `omarchy-other.packages`), not series equality. |
| R11 | `test/images/vm-neptune-image.sh`, `test/vm/vm-*-test.sh`, `test/lib/vm-assertions.sh` | Neptune substrate + kernel assertions | **EDIT** | Rebase substrate on `linux-omarchy` (or generic `linux` + migration); keep the `default_entry: 2` fragile-index property — `stage-default-entry` still exists to repair exactly that. |
| R12 | `iso/overlay/configs/deck/pkgbuilds/omarchy-deck/` + `src/deck-session.sh` rotation/fbcon stages | T12 patches, `50-deck-fbcon-rotation.conf` writer | **KEEP** | Kernel-independent (cmdline token + Limine template patch). Untouched. |

Out of scope for the retirement commit (explicit non-goals): LCD support
claims (still OLED-only per CLAUDE.md), DKMS/*-headers policy (upstream now
guarantees headers; our reader-less `-headers` line dies with R5), and the
`linux-firmware-neptune` question (already cut, stays cut).

## §D-still-needed — Deck packages that MUST STAY after the kernel retires

`linux-omarchy` absorbs **none** of these (verified: no Deck patch, no Deck
firmware, no session file, no DSP blob in or beside the PKGBUILD):

| Package (where listed) | Why it stays |
|---|---|
| `jupiter-staging/gamescope` + bare `gamescope` (dual) | Only Valve's build ships `gamescope-wayland.desktop` (Gaming Mode session). Upstream has no gamescope handling at all in this range. |
| `jupiter-staging/steamdeck-dsp` + bare `steamdeck-dsp` (dual) | Audio DSP firmware; proprietary, Deck-only. |
| `mangohud`, `lib32-mangohud` (bare — Arch wins, newer) | `/usr/bin/mangoapp` overlay; `deck-session.sh` warns without it. |
| `steam` (fetch, online) | Subscriber Agreement; deliberately unbundled. Upstream never bundles it either. |
| `python-evdev` (target) | Input-mapper dependency; `session_bake` fails loudly without it. |
| `vulkan-radeon`, `lib32-vulkan-radeon` pins | Deterministic AMD provider selection for `steam`'s virtual deps. Upstream's `vulkan.sh` auto-detect would also pick `vulkan-radeon` on the Deck — but the pins make it order-independent; keep. |
| Valve repos append-last (`stage_repos`) | Source for the first two rows; P16 audit stands. |
| `50-deck-fbcon-rotation.conf` (`fbcon=rotate:1`) | Console rotation is panel physics, not kernel version. Keep verbatim. |

## §Boot-ownership answer (the single biggest question)

**After adopt, upstream owns the boot *order* and we own the boot *pointer* —
and that split is stable, not a collision.**

- Upstream (packaged `omarchy-defaults.conf` + migration-owned
  `/etc/default/limine`, which has priority over all drop-ins) decides the
  *ordering* of entries: `linux-t2, linux-omarchy, linux-omarchy-*, *,
  *fallback, Snapshots`.
- We (`stage_default_entry`, retargeted per R7) decide the *pointer*:
  `default_entry: Omarchy/linux-omarchy` in path form, written only when the
  UKI + menu entry verify, refusing otherwise.
- Limine resolves the pointer first and falls back to order — so the pointer
  is the precise instrument and order is the safety net. No write-write
  collision exists (disjoint keys, disjoint files), and the T9 finding that
  "nothing upstream owns `default_entry:`" was re-verified at `c668141e`.
- The one ordering hazard is transitional, not structural: until R7 lands and
  runs, our pointer names Neptune while upstream's order prefers linux-omarchy
  (machine boots Neptune — safe, old kernel kept). The retirement commit must
  land R1–R8 together, and the Deck update runbook must retarget the pointer
  before the first reboot into the new kernel.

## Re-verify checklist (hands-on, Deck via `ssh steamdeck`)

1. `1789325478` package source on the Deck (Valve repos absent from its
   pacman.conf — where does `omarchy-pkg-add linux-omarchy` resolve from?);
   run with primed sudo; `limine-entry-tool --tree` shows `linux-omarchy`.
2. `id -nG deck` + mapper pad-open exercise after `1787865477` (input-group row).
3. `idle.screensaver`/`idle.lock` readback from `~/.config/omarchy/shell.json`
   after update (plugin-auth shell.qml growth).
4. Key-based SSH before + after `1788124236` (sshd hardening).
5. `pacman -Q linux-omarchy-headers` after `1789444024`.
6. First reboot only after pointer retarget (R7) verified on the ESP console
   listing.

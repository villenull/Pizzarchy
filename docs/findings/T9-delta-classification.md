# T9 step 2 — complete delta classification, `354c2f0` → `quattro` HEAD

**Measured 2026-08-11 (P2.9b), dev machine only.** Every row below was written
after reading the actual patch hunk from the `compare` API. Nothing here is
inferred from a commit subject.

## Provenance — the head MOVED since the seed was written

| | SHA | Date (UTC) | Note |
|---|---|---|---|
| Baseline | `354c2f0` | 2026-08-10 ~12:00 | last `quattro` commit before the P1.5 Deck install |
| Head **at seed time** | `1c9dfc5` | 2026-08-11 12:32 | *"Greet the first login with a keybindings toast again"* — 37 commits, 60 non-test files |
| **Head at this measurement** | **`5817feb`** | **2026-08-11 14:30** | *"Mute all audio on right-click (#6708)"* — **38 commits, 90 files, 65 non-test** |

⚠️ `quattro` moved twice in the ~2 h between the seed and this pass. **This is
still not a pin.** Everything below is classified against `5817feb`; if
`docs/PROGRESS.md` §1.1 records a different SHA, re-run the method in §5.

Reproduce:

```bash
gh api "repos/basecamp/omarchy/compare/354c2f0...quattro" > compare.json
python3 -c "import json;d=json.load(open('compare.json'));[print(f['status'],f['filename']) for f in d['files']]"
```

## Verdicts at a glance

| Verdict | Count |
|---|---|
| **BREAKS US** | **1** |
| **RE-VERIFY** | **27** |
| NO IMPACT | 37 |
| **Total non-test files** | **65** |

*(25 test files also changed and are out of scope by the brief. Two of them —
`test/shell.d/snapper-test.sh`, `test/shell.d/upgrade-to-quattro-test.sh` — were
read anyway because they are the only other places the boot chain is named; both
changed by exactly one line, the `setup-` → `apply-` rename. No snapper policy
moved.)*

---

## 1. The one that BREAKS US

### 🔴 `shell/plugins/lock/Service.qml` — an automatic lock that does not read our idle policy

The patch adds `checkStrandedLock()` / `recoverStrandedLock()`. When
`omarchy-hyprland-session-locked` (new, see §2) exits 0 and
`passwordPamConfigured` is true, the shell calls **`beginLock()` directly**:

```qml
function recoverStrandedLock() {
  if (!strandedLock || locked || !passwordPamConfigured) return
  strandedLock = false
  logEvent("lock-stranded: recovering")
  beginLock()
}
```

It is armed from three places: `Component.onCompleted`, `onScreensChanged`, and
`onPasswordPamConfiguredChanged`, plus a 500 ms × 20 retry timer.

**What is broken is the guarantee, verifiably, by reading the code.**
`src/deck-session.sh:180-197` neuters Omarchy's idle policy (screensaver 150 s,
**lock 86400 s**) precisely so that a keyboard-less handheld can never be shown
an unanswerable password prompt. `beginLock()` on this path never consults
`idle.lock`. Our mitigation is now **insufficient by construction** — it covers
the idle timer and nothing else.

Two things make it worse rather than better:

- The lock surface is `ext-session-lock`, which renders above every layer
  surface and takes input exclusively. `src/deck_osk_wayland.py` is a
  layer-shell overlay (`LayerShell.set_namespace(window, "deck-osk")`, line 268)
  with `KeyboardMode.NONE` and an empty input region. **It would not be visible
  over a lock surface**, so even though the mapper's uinput keystrokes would
  still be delivered, the user cannot see what they are typing.
- `bin/omarchy-launch-shell` (below) now **relaunches the shell up to 5× per
  minute**, and every relaunch re-runs `Component.onCompleted → checkStrandedLock()`.

**Not yet proven to fire on the Deck.** The trigger requires the compositor to
hold a stale `ext-session-lock` (Hyprland's failsafe, or the locker's client
dying). That is what step 5/6 must provoke deliberately: kill `quickshell` while
locked and watch what comes back. Do not treat "it did not lock during a soak"
as evidence the invariant holds.

---

## 2. The 27 RE-VERIFY rows, by priority

🔴 = do this before/immediately after the Deck update · 🟠 = before signing off
step 5 · 🟡 = one look, cheap

| Pri | File | The specific thing to check |
|---|---|---|
| 🔴 | `bin/omarchy-hyprland-session-locked` | The sensor for the lock above. `solitaryBlockedBy` containing `LOCK` ⇒ exit 0. On a single-display Deck there is no second monitor to disambiguate, so exit 2 (undetermined) is the common early answer and the retry timer keeps asking. |
| 🔴 | `bin/omarchy-launch-shell` | New supervisor loop; multiplies the stranded-lock path and changes what "the shell died" looks like. |
| 🔴 | `default/bash/envs` | Non-login bash (**our SSH loop**) now exports the system locale. See §3.4 — this meets `src/deck-session.sh:1601-1606`, whose whole argument is glob/lexical ordering. |
| 🔴 | `bin/omarchy-hyprland-monitor-watch` | New `recover_modeless` background loop runs `hyprctl reload` repeatedly (3 s → 60 s backoff) whenever any enabled monitor reports 0×0. Fires at start, on monitor add/remove, and on `configreloaded`. The Deck's internal panel is the only display, and this loop now runs across the session-switch window `docs/PROGRESS.md` §5.18 lives in. |
| 🔴 | `migrations/1786380259.sh` | Runs `sudo omarchy-bluetooth-power on\|off` and `sudo sed -i` on `/etc/bluetooth/main.conf` during `omarchy-update`. **Machine-wide, as root, over our SSH loop.** Its own comment says `/dev/rfkill` is only writable from an active graphical seat. Run the update with a tty; the `sudo` lines will prompt. |
| 🔴 | `etc/sudoers.d/omarchy-tzupdate` | Function unaffected — our grant `/etc/sudoers.d/99-deck-set-timezone` (`src/deck-session.sh:260`) is independent and the half we duplicate (`timedatectl set-timezone *`) survived. **`src/deck-session.sh:1159` quotes the old line verbatim and is now wrong.** T9 step 7 owns the edit. |
| 🟠 | `shell/services/PluginRegistry.qml` | New `putBarWidget` verb mutates `~/.config/omarchy/shell.json` — **the file carrying our idle policy**. It edits only `config.bar` through `shellConfigMutator`, so `idle` should survive; re-read it the §5.20 way after any update. |
| 🟠 | `shell/shell.qml` | The IPC front door for the above (`putBarWidget` now returns the registry's error string; new `togglePanelAt`). Same shell.json write-back concern. |
| 🟠 | `bin/omarchy-bar` | `put` used to give up when the shell was not running; it now retries for ~5 s and re-asks without the anchor. This makes the shell.json write-back **more** likely during an update, not less. No migration in this range calls it — but the patch's own comment says migrations do. |
| 🟠 | `default/omarchy/omarchy-menu.jsonc` | P2.4's extension seam. **The schema is unchanged** (`"icon"/"label"/"action"`, same file), so the mechanism our Desktop Mode row uses (`src/deck-session.sh:2043-2047`) survives. Verify the row still appears on screen (T9 step 6). |
| 🟠 | `default/hypr/bindings/utilities.lua` | While a slurp `selection` layer is open, upstream now globally binds **RETURN, CTRL+RETURN, TAB, CTRL+TAB and all four arrows**. `src/deck-input-mapper.py:133-159` emits exactly `ENTER ESC SPACE TAB PAGEUP PAGEDOWN LEFT RIGHT UP DOWN` — **6 of those 8 binds collide with the mapper's entire navigation set.** Previously only RETURN was bound. Reachable controller-only via the Omarchy menu's Capture → Region. |
| 🟠 | `bin/omarchy-hyprland-monitor-clamshell` | Rewritten `~/.config/hypr/monitors.lua` parser (comment stripping, per-output rules, catch-all `output = ""`, `local omarchy_monitor_scale` resolution). I traced our recorded line — `hl.monitor({ output = "eDP-1", mode = "preferred", position = "auto", scale = 1.25, transform = 3 })` — through it: matches `monitor_rule_regex`, extracts `1.25`, `lua_scalar` leaves it alone (not a Lua identifier). **No break predicted**, but the parser is new and this is the file our rotation lives in (`src/deck-session.sh:282-284`). |
| 🟠 | `bin/omarchy-hyprland-monitor-modeless` | The sensor driving the reload loop above. `hyprctl monitors all -j`, any `.disabled != true and (width==0 or height==0)` ⇒ exit 0. |
| 🟠 | `bin/omarchy-provision-owner` | First-boot OOBE screen re-centers vertically off `stty size` and repaints on VT resize; `ttfx --xterm-colors`; the "Starting Omarchy..." card is gone. This renders on the Deck's **unrotated** VT (fbcon/rotate is 0 — `src/deck-session.sh:272-278`), so centering math on an 800×1280 scanout is a look-at-a-screen item for T4/T5. |
| 🟠 | `bin/omarchy-system-factory-reset` | **The degraded (no `@factory`) path is deleted** — a machine without the snapshot is now refused outright, where it previously ran a reduced reset. ROADMAP **P3.1 plans a factory reset on this Deck**. Confirm `btrfs subvolume list /` shows `@factory` *before* P3.1, not during it. |
| 🟠 | `bin/omarchy-apply-system` | Renamed from `omarchy-setup-system`; `omacom-io/omarchy-iso` HEAD `d6cd2d3` exists to call the new name. **Our ISO was built at `a12bfea`, which calls the old one.** An ISO from `a12bfea` finalizing against a newer runtime calls a binary that no longer exists. T5/step-3b: the builder SHA and the package pin must move together. |
| 🟠 | `install/omarchy-base.packages` | `+libvips`, `+zbar`. T5 payload and ISO size (`docs/tasks/T5-iso-and-payload.md`). |
| 🟡 | `bin/omarchy-bluetooth-power` (added) | **The BT power model changed.** rfkill soft block is now the persisted state; `AutoEnable` returns to its stock default. P2.2 parity row. |
| 🟡 | `bin/omarchy-bluetooth-device` | `power_on` routes through the new helper because BlueZ refuses to power up under an rfkill block. |
| 🟡 | `install/hardware/bluetooth.sh` | Stops forcing `AutoEnable=false`. Same model change, install-time half. |
| 🟡 | `shell/plugins/panels/bluetooth/Panel.qml` | Panel toggle now `execDetached(["omarchy-bluetooth-power", …])` instead of writing BlueZ `Powered`. |
| 🟡 | `shell/plugins/bar/Bar.qml` | A hidden bar now **stays mapped**, parked off-screen with negative margins + `ExclusionMode.Ignore`, instead of unmapping. A permanently-live layer surface sits alongside our OSK overlay (`deck-osk` namespace). No focus contest predicted — ours asks for no keyboard and has an empty input region — but look at the OSK's placement once with the bar hidden. |
| 🟡 | `shell/plugins/bar/widgets/KeyboardLayout.qml` | Label now resolved from `xkbcli list --load-exotic` (spawned once per bar, i.e. per monitor) rather than the first word of the keymap. Reads the **xkb** layout from `hyprctl devices` — *not* `org.gnome.desktop.input-sources` — but it is the visible place a layout regression would surface. `xkbcli` is not in `omarchy-base.packages`; it arrives with `libxkbcommon`. |
| 🟡 | `install/user/first-run/wifi.sh` | `ping 1.1.1.1` replaced by `nm-online -q -s -t 30` / `-x` / `-t 3600`, run **detached**. A first boot with no network now holds a background job for up to an hour. Adjacent to T4's Wi-Fi screen (though this is post-install, not the live ISO). |
| 🟡 | `migrations/1786386460.sh` | `omarchy-pkg-add libvips` — needs network during `omarchy-update`; T5 payload. |
| 🟡 | `migrations/1786447584.sh` | `omarchy-pkg-add zbar` — same. |
| 🟡 | `bin/omarchy-system-factory-reset-finish` | Degraded scrub kept only as a legacy path behind the `wipe-degraded` marker, and now also deletes nested snapper snapshots. P3.1. |

---

## 3. Full classification — one row per changed non-test file

Ordered by path. "grepped" always means over `src/` and `test/` in this repo.

| File | Status | What the patch actually does | Verdict | Why |
|---|---|---|---|---|
| `AGENTS.md` | modified | Documents that a group whose commands are all `omarchy:hidden=true` gets no `GROUP_DESCRIPTIONS` entry; `apply-`/`provision-` deliberately absent | NO IMPACT | Upstream contributor doc. Grepped `GROUP_DESCRIPTIONS`, `AGENTS.md` — zero hits |
| `agents/skills/install-scripts.md` | modified | `omarchy-setup-{system,hardware}` → `omarchy-apply-*` in the contributor skill | NO IMPACT | Doc only. Grepped `setup-system\|setup-hardware` in `src/`/`test/` — zero hits. (Stale in our *docs*: `docs/findings/R1-10.2.md:147,171-172` still names the old binaries — T9 step 7) |
| `bin/omarchy-agent-usage-claude` | modified | Adds `scoped_window()` + `scoped_limits()` so model-scoped entries in the `limits` array become titled windows | NO IMPACT | Grepped `agent-usage`, `usage-claude` — zero hits |
| `bin/omarchy-apply-hardware` | renamed (`bin/omarchy-setup-hardware`) | `group=setup`→`apply`, `hidden=true`, self-references in usage/error text | NO IMPACT | Grepped `setup-hardware\|apply-hardware` — zero hits. Its only caller (`omarchy-apply-system`) was updated in the same commit |
| `bin/omarchy-apply-lock` | renamed (`bin/omarchy-setup-lock`) | Drops `group=setup`/`name=lock`, adds `hidden=true` | NO IMPACT | Grepped `setup-lock\|apply-lock` — zero hits. Its two callers (`install/config/lockscreen-pam.sh`, `omarchy-upgrade-to-quattro`) were updated in the same range |
| `bin/omarchy-apply-system` | renamed (`bin/omarchy-setup-system`) | Same rename; now calls `omarchy-apply-hardware` | **RE-VERIFY** | No `src/` coupling, but `omarchy-iso` HEAD `d6cd2d3` exists to call the new name and **our ISO is from `a12bfea`, which calls the old one** — T5/step 3b must move builder SHA and package pin together |
| `bin/omarchy-bar` | modified | `put` waits out a shell that is still starting (`ask_to_put`, `OMARCHY_SHELL_READY_ATTEMPTS`) and re-asks without `--before/--after` when the anchor is missing | **RE-VERIFY** | This is the unattended CLI path that makes the shell rewrite `~/.config/omarchy/shell.json` — the file carrying our idle policy (`src/deck-session.sh:194-197`) |
| `bin/omarchy-bluetooth-device` | modified | `power_on` calls `omarchy-bluetooth-power on` instead of `bluetoothctl power on` | **RE-VERIFY** | BT is an open parity row (ROADMAP P2.2). `test/hw-probe.sh:37-40` reads `bt.rfkill`/`bt.powered`; **an rfkill block is now a deliberate "off", not a fault** |
| `bin/omarchy-bluetooth-power` | added | Persists BT on/off via the rfkill soft block (systemd-rfkill restores it at boot); `on\|off\|toggle\|is-on` | **RE-VERIFY** | Same — the meaning of what `test/hw-probe.sh:40` reports changed |
| `bin/omarchy-capture-qr` | added | hyprpicker freeze → slurp → grim → `zbarimg -Sdisable -Sqrcode.enable`, result to `wl-copy --sensitive` only | NO IMPACT | Grepped `capture\|slurp\|grim\|zbar` in `src/` — zero hits. Payload note: pulls `zbar` |
| `bin/omarchy-capture-region` | modified | Adds keyboard window selection: `--take-window`, `--select-window next\|prev\|left\|right\|up\|down`, cursor-warp probing, marker files | NO IMPACT | Grepped `capture-region` — zero hits. Its layer namespace is `selection`; ours is `deck-osk` (`src/deck_osk_wayland.py:268`) — no collision. *(The Hyprland binds it needs are the RE-VERIFY row on `utilities.lua`, not this file)* |
| `bin/omarchy-file-select` | modified | Adds `--directory` to the xdg-desktop-portal file chooser; filters skipped in directory mode | NO IMPACT | Grepped `file-select\|portal` — zero hits |
| `bin/omarchy-hyprland-monitor-clamshell` | modified | Rewrites the `monitors.lua` parser: strips comments, per-output rules, catch-all `output = ""`, resolves `local omarchy_monitor_scale` | **RE-VERIFY** | Parses the file that carries our rotation (`src/deck-session.sh:282-284`, PROGRESS §5.11). Traced our line through it — resolves `scale = 1.25` correctly; verify, don't rewrite |
| `bin/omarchy-hyprland-monitor-modeless` | added | Exit 0 when any enabled monitor is 0×0, 1 when not, 2 when the compositor won't answer | **RE-VERIFY** | Sensor for the new reload loop below |
| `bin/omarchy-hyprland-monitor-watch` | modified | Adds `recover_modeless`: a flock'd background loop that `hyprctl reload`s on 3 s→60 s backoff while a monitor has no mode; armed at start, on monitor add/remove, and on `configreloaded` | **RE-VERIFY** | New unbounded-in-time reload loop on a single-display device, active across the session-switch window (`docs/PROGRESS.md` §5.18). A reload re-reads `monitors.lua`, so the transform survives — the concern is the loop, not the config |
| `bin/omarchy-hyprland-reload-guard` | modified | Adds a `paused` query verb (`compgen -G "$state_dir/*"`) | NO IMPACT | Grepped `reload-guard` — zero hits; only `monitor-watch` consumes it |
| `bin/omarchy-hyprland-session-locked` | added | Exit 0 when any monitor's `solitaryBlockedBy` contains `LOCK`, 1 unlocked, 2 undetermined | **RE-VERIFY** | The trigger for the BREAKS US row. Consumed by `lock/Service.qml` and `omarchy-restart-shell` |
| `bin/omarchy-launch-shell` | modified | Backgrounds Quickshell and supervises it: TERM trap, `compositor_alive()` probe, relaunch up to 5× in 60 s, then gives up | **RE-VERIFY** | Each relaunch re-runs the lock service's `Component.onCompleted → checkStrandedLock()` — it multiplies the BREAKS US path |
| `bin/omarchy-launch-terminal-herdr` | added | `exec omarchy-launch-terminal herdr` | NO IMPACT | Grepped `herdr` — zero hits |
| `bin/omarchy-menu` | modified | Menu IPC payload built with `jq -nc --arg` instead of `perl -MJSON::PP` | NO IMPACT | Payload shape `{menu:"<route>"}` unchanged; our Desktop Mode row is an *extension file* (`src/deck-session.sh:2043-2047`), not a caller. Verified `jq` is in `install/omarchy-base.packages` at `quattro`, so the new dep ships |
| `bin/omarchy-menu-herdr-keybindings` | added | Renders Herdr bindings by parsing `herdr --default-config` TOML plus the user config | NO IMPACT | Grepped `herdr` — zero hits |
| `bin/omarchy-menu-images` | modified | Thumbnails via `VIPS_CONCURRENCY=1 vipsthumbnail` fanned out with `xargs -P $(nproc)` instead of serial ImageMagick `magick`; failed rows pruned | NO IMPACT | Grepped `menu-images\|thumbnail\|wallpaper` in `src/` — zero hits. Payload note: pulls `libvips` |
| `bin/omarchy-menu-keybindings` | modified | Reorders cheatsheet priorities (Keybindings first, Omarchy menu second), adds Herdr rows, cache key `v8`→`v11` | NO IMPACT | Grepped `menu-keybindings` — zero hits |
| `bin/omarchy-menu-share` | modified | Replaces `find \| fzf` with `omarchy-file-select`; distinguishes "chooser did not open" (exit > 1) from "user cancelled" | NO IMPACT | Grepped `menu-share` — zero hits |
| `bin/omarchy-provision-first-run` | modified | One log string: "show" → "schedule" Wi-Fi/update notifications | NO IMPACT | Log text only |
| `bin/omarchy-provision-owner` | modified | Vertically centers the first-boot setup block, repaints on VT resize, `GUM_FILTER_PADDING`, `ttfx --xterm-colors` + `cols-2` canvas, drops the "Starting Omarchy..." card, keeps the cursor hidden on success | **RE-VERIFY** | This is the first-boot OOBE on the Deck's **unrotated** VT (`src/deck-session.sh:272-278`); centering math on an 800×1280 scanout is a T4/T5 look-at-a-screen item |
| `bin/omarchy-restart-shell` | modified | Lock detection via `omarchy-hyprland-session-locked` instead of grepping `"LOCK"` out of `hyprctl monitors` | NO IMPACT | Grepped `restart-shell` — zero hits. We restart **sddm**, not the shell (`src/deck-session.sh:304`, `753`+) |
| `bin/omarchy-shell` | modified | `"Not ready to accept queries yet"` now fails instead of being returned as a result | NO IMPACT | Grepped `omarchy-shell` in `src/` — zero hits |
| `bin/omarchy-system-factory-reset` | modified | Deletes the degraded (no-`@factory`) reset path and `rollback_degraded_rekey`; `require_factory_snapshot` now refuses such machines outright | **RE-VERIFY** | ROADMAP **P3.1** plans a factory reset on this Deck. Grepped `@factory\|factory-reset` in `src/`/`test/` — zero hits, so no code coupling; the coupling is to the plan |
| `bin/omarchy-system-factory-reset-finish` | modified | Degraded scrub retained only for resets staged by an older Omarchy (`wipe-degraded`), folded in the snapper-snapshot wipe | **RE-VERIFY** | Same P3.1 reason, lower weight |
| `bin/omarchy-theme-color` | modified | Validates theme keys/values against a charset before they reach `sed` replacement text; announces rejections (injection fix, #6694) | NO IMPACT | Grepped `theme-color\|THEME_COLORS` — zero hits |
| `bin/omarchy-theme-set-keyboard-asus-rog` | modified | Guards on file existence and a 6-hex-digit colour before `asusctl` | NO IMPACT | ASUS hardware; grepped `asusctl` — zero hits |
| `bin/omarchy-theme-set-keyboard-f16` | modified | Same hex guard; passes the hex to python as `argv[1]` rather than interpolating it into source | NO IMPACT | Framework hardware; grepped `qmk_hid` — zero hits |
| `bin/omarchy-theme-set-vscode` | modified | Validates `.name`/`.extension` from the theme descriptor; escapes `&`/`\|` for the `sed` write into `settings.json` | NO IMPACT | Grepped `vscode` — zero hits |
| `bin/omarchy-upgrade-to-quattro` | modified | `configure_lock_authentication` calls `omarchy-apply-lock` (was `omarchy-setup-lock`) | NO IMPACT | This is the 3.x→4.0 in-place upgrader; our Deck was installed from the 4.0 beta ISO. Grepped `upgrade-to-quattro` — zero hits |
| `config/herdr/config.toml` | modified | Adds `window_title = "{hostname}: {workspace}"` | NO IMPACT | Grepped `herdr` — zero hits |
| `default/bash/envs` | modified | When `LANG` is unset, sources `/etc/locale.conf` and exports `LANG` + 12 `LC_*` vars — explicitly so **SSH** sessions stop landing in the C locale | **RE-VERIFY** | Directly hits our SSH iterate-in-place loop (`docs/PLAN.md` §9.4). See §3.4 below — `src/deck-session.sh:1601-1606` asserts a winner across a `*.conf` **glob**, whose order is `LC_COLLATE`-dependent, and the whole `zz-`/`zy-` argument (`:351-361`) rests on lexical order |
| `default/hypr/bindings/applications.lua` | modified | Adds `SUPER + CTRL + RETURN` → Herdr | NO IMPACT | `src/deck-input-mapper.py:133-159` emits **no modifiers at all** (ENTER ESC SPACE TAB PAGEUP PAGEDOWN LEFT RIGHT UP DOWN) — a SUPER+CTRL chord is unreachable from the pad |
| `default/hypr/bindings/utilities.lua` | modified | Renames two cheatsheet binds, adds `SUPER+CTRL+K`; replaces the single slurp `RETURN` bind with RETURN / CTRL+RETURN / TAB / CTRL+TAB / 4 arrows using per-handle `unbind()`; adds `SUPER + CTRL + code:10..18` → `togglePanelAt right N` | **RE-VERIFY** | The slurp binds are **unmodified** keys and overlap 6 of the 10 keys the mapper emits, for as long as a selection layer is open. The SUPER+CTRL binds do not collide |
| `default/omarchy/omarchy-menu.jsonc` | modified | Adds `trigger.capture.qr`; `trigger.share.file/folder` drop the `xdg-terminal-exec` wrapper | **RE-VERIFY** | P2.4's extension seam. **Schema unchanged** — `"icon"/"label"/"action"` at the same path — so our Desktop Mode row's mechanism (`src/deck-session.sh:2043-2047`) survives; presence must be re-verified on screen |
| `docs/file-layout.md` | modified | Renames in the orchestration section; documents the new welcome/wifi first-run split | NO IMPACT | Upstream doc |
| `etc/sudoers.d/omarchy-tzupdate` | modified | `-%wheel … /usr/bin/tzupdate, /usr/bin/timedatectl set-timezone *` → `+%wheel … /usr/bin/timedatectl set-timezone *` | **RE-VERIFY** | Function unaffected — our grant (`src/deck-session.sh:260`) is independent and the half we duplicate survived. **`src/deck-session.sh:1159` quotes the old line verbatim and is now false** |
| `install/config/lockscreen-pam.sh` | modified | Calls `omarchy-apply-lock` | NO IMPACT | Install-time; grepped `lockscreen-pam` — zero hits. *(Context: this is what makes `passwordPamConfigured` true, the gate on the §1 lock)* |
| `install/hardware/all.sh` | modified | Adds `apple/fix-brcmfmac-supplicant.sh` to the hardware run | NO IMPACT | Apple-gated leaf; the Deck's DMI vendor is Valve |
| `install/hardware/apple/fix-brcmfmac-supplicant.sh` | added | Writes `options brcmfmac feature_disable=0x82000` on Macs, gated on the T2 PCI ID **or** `sys_vendor == Apple*` + a Broadcom ID list | NO IMPACT | Hardware-gated away from the Deck. Confirms the pattern our LCD gating follows (`docs/PLAN.md` §9.6) |
| `install/hardware/apple/fix-t2.sh` | modified | Removes the brcmfmac block (moved to the new script); the `limine-entry-tool.d` block is untouched | NO IMPACT | Apple-gated. **This is the only place `limine` appears in the whole delta as a `-`/`+` line, and it is a deletion of an unrelated hunk** |
| `install/hardware/bluetooth.sh` | modified | Stops forcing `AutoEnable=false`; leaves BlueZ's stock default | **RE-VERIFY** | Install-time half of the BT model change; P2.2 |
| `install/omarchy-base.packages` | modified | `+libvips`, `+zbar` | **RE-VERIFY** | T5 payload + ISO size (`docs/tasks/T5-iso-and-payload.md`) |
| `install/user/first-run/welcome.sh` | modified | `$'...'` for real newlines; two lines instead of three; still `--exec omarchy-menu-keybindings` | NO IMPACT | Grepped `first-run\|notification-send` in `src/` — zero hits |
| `install/user/first-run/wifi.sh` | modified | Replaces `ping -c3 1.1.1.1` with `nm-online -q -s -t 30` / `-x -t 30` / `-t 3600`, run detached in the background | **RE-VERIFY** | Adjacent to T4's Wi-Fi screen; a networkless Deck first boot now holds a background job up to an hour. (Post-install, **not** the live ISO — the `CLAUDE.md` live-ISO Wi-Fi constraint is untouched by this delta) |
| `install/user/mise-work.sh` | modified | Comment only: "degraded reset" → "factory snapshot predating the tarball" | NO IMPACT | Comment |
| `migrations/1786380259.sh` | added | Records BT power in the rfkill soft block (`sudo omarchy-bluetooth-power on\|off`), reverts `AutoEnable=false` → `#AutoEnable=true` in `/etc/bluetooth/main.conf`, marker at `/var/lib/omarchy/migrations/1786380259` | **RE-VERIFY** | Root, machine-wide, runs on `omarchy-update`, over our SSH loop. P2.2 |
| `migrations/1786386460.sh` | added | `omarchy-pkg-add libvips` | **RE-VERIFY** | Network during update; T5 payload |
| `migrations/1786391100.sh` | added | Appends the brcmfmac option on Macs, then `omarchy-state set reboot-required`; gated on `sys_vendor == Apple*` or the T2 PCI ID | NO IMPACT | The guard `exit 0`s on a Valve/Jupiter DMI before touching anything |
| `migrations/1786447584.sh` | added | `omarchy-pkg-add zbar` | **RE-VERIFY** | Network during update; T5 payload |
| `shell/plugins/agents/Panel.qml` | modified | `limitWindow()` takes an explicit `title`; the label elides right against the percentage | NO IMPACT | Grepped `agents\|Panel.qml` in `src/` — zero hits |
| `shell/plugins/bar/Bar.qml` | modified | Hidden bar stays **mapped**, parked off-screen via negative `margins` + `ExclusionMode.Ignore` (≈20 ms vs ≈150 ms reveal); adds per-surface hover counting and `panelWidgetIdAt()` | **RE-VERIFY** | A permanently-live layer surface next to our OSK overlay (`deck-osk`). No focus contest predicted (`KeyboardMode.NONE`, empty input region) — check the OSK's placement once with the bar hidden |
| `shell/plugins/bar/widgets/KeyboardLayout.manifest.json` | modified | Declares `omarchy.clonePaths` for `KeyboardLayoutModel.js` | NO IMPACT | Manifest plumbing |
| `shell/plugins/bar/widgets/KeyboardLayout.qml` | modified | Label from `xkbcli list --load-exotic` briefs (`"English (US)"` → `EN`) instead of the first 3 chars of the keymap; one `xkbcli` per bar at startup | **RE-VERIFY** | Reads the **xkb** layout from `hyprctl devices`, not `org.gnome.desktop.input-sources` — but it is where a layout regression becomes visible |
| `shell/plugins/bar/widgets/KeyboardLayoutModel.js` | added | Qt-free `layoutBriefs()`/`shortLabel()` parsing of `xkbcli` YAML | NO IMPACT | Pure label math |
| `shell/plugins/lock/Service.qml` | modified | **Stranded-lock detection + automatic re-lock** — see §1 | **BREAKS US** | `recoverStrandedLock() → beginLock()` never reads `idle.lock`, so `src/deck-session.sh:180-197`'s neutering no longer covers every path to a password prompt |
| `shell/plugins/panels/audio/Panel.qml` | modified | Right-click on the output icon calls `toggleAllMuted()` instead of `toggleOutputMute()` | NO IMPACT | Grepped `pactl\|wireplumber\|audio` in `src/` — zero hits (`test/hw-probe.sh` reads pactl but never writes) |
| `shell/plugins/panels/bluetooth/Panel.qml` | modified | `toggleBluetooth()` execs `omarchy-bluetooth-power on\|off` detached instead of writing `adapter.enabled` | **RE-VERIFY** | P2.2 |
| `shell/services/PluginRegistry.qml` | modified | Adds clone-aware `findRelativeBarLocation()` and the unattended `putBarWidget()` (leaves a placed widget alone, drops an unfindable anchor) | **RE-VERIFY** | Mutates `~/.config/omarchy/shell.json`, which carries our idle policy. Only `config.bar` is touched, so `idle` should survive — verify, don't assume |
| `shell/shell.qml` | modified | `putBarWidget` IPC routes to the registry verb inside a `try`, returning parse errors; adds `togglePanelAt(section, index)` | **RE-VERIFY** | Same shell.json write-back path; also the IPC endpoint the new `SUPER+CTRL+N` binds drive |

---

## 4. The three load-bearing settings — evidence, not reassurance

The brief asked for anything that could silently revert these. Here is what was
actually checked.

### 4.1 `org.gnome.desktop.a11y.applications screen-keyboard-enabled` — CLEAR

Grepped all 65 patches for `gsettings|dconf|screen-keyboard|input-sources`.
**One hit: `docs/file-layout.md`**, and only as prose naming
`install/user/first-run/gnome-theme.sh` and `gtk-primary-paste.sh` — **neither
of which is in this delta**. No migration, installer or shell file in the range
writes dconf.

Our site database (`/etc/dconf/db/local.d/50-deck-desktop`,
`src/deck-session.sh:1864-1880`) is untouched by upstream. Still re-verify with
`dconf read -d` after the update — a *package* upgrade outside this file range
(dconf, squeekboard, gsettings-desktop-schemas) can still ship a new default.

### 4.2 `org.gnome.desktop.input-sources sources` — CLEAR, same evidence

Same grep. The one input-adjacent change,
`shell/plugins/bar/widgets/KeyboardLayout.qml`, reads `active_keymap` from
`hyprctl devices` and an `xkbcli` table — it never touches GSettings.

### 4.3 The `shell.json` idle policy — SCHEMA CLEAR, POLICY BYPASSED

Three separate findings, and they do not agree:

1. **The shipped defaults did not move.** `config/omarchy/shell.json` is *not*
   in the changed-file list; read at `quattro` it still says
   `{"screensaver": 150, "lock": 300}`, top-level keys
   `["version","idle","bar","plugins"]`. A package upgrade will not rewrite our
   user file.
2. **The idle engine did not move.** `shell/plugins/services/idle/IdleModel.js`
   and `.../idle/Service.qml` exist upstream and are **not** in the delta — so
   `secondsFromConfig`'s behaviour, including ⚠️ `lock: 0` meaning *fire
   immediately*, is unchanged. Our 86400 is still the right shape.
3. 🔥 **But two new code paths now write or bypass that file:**
   - `shell/services/PluginRegistry.qml` + `shell/shell.qml` + `bin/omarchy-bar`
     make the shell rewrite `~/.config/omarchy/shell.json` unattended. It edits
     only `config.bar`, so `idle` *should* survive — unverified on our file.
   - `shell/plugins/lock/Service.qml` locks the device **without consulting
     `idle.lock` at all** (§1). This is the silent revert the brief was asking
     about, and it does not revert the setting — it routes around it.

### 4.4 A fourth thing worth flagging that the brief did not name

`default/bash/envs` gives **SSH sessions the system locale**. Three assumptions
in `src/deck-session.sh` are lexical-order or byte-order arguments made under
the C locale:

- `:351-361` — the `zz-`/`zy-` naming argument for `/etc/sddm.conf.d`
- `:1601-1606` — `cat /etc/sddm.conf.d/*.conf | grep '^CompositorCommand=' | tail -1`,
  where the **shell glob's order is `LC_COLLATE`**, and the assertion is that
  our file is the last one
- `:1688-1697` — `systemctl show` value comparisons (numeric, low risk)

glibc's `en_US.UTF-8` collation ignores punctuation in its first pass, so
`zy-` < `zz-` still holds and no break is predicted — but the ordering claim in
that comment was already wrong once before (`:351-356` records the
`95-deck-session.conf` bug: "the bug was in a comment asserting an ordering
nobody checked"). Re-check it under the locale the Deck will now actually have.

## 5. What is provably NOT in this delta

Stated as negatives because they are load-bearing:

- **The boot chain.** Grepped all 65 patches for
  `limine|mkinitcpio|snapper|/efi|uki|esp`. Six files matched; every matching
  `+`/`-` line is either a **deletion** from the removed degraded factory-reset
  path (`limine-update`, `/etc/limine-entry-tool.d/99-omarchy-provisioning-unlock.conf`,
  `/etc/mkinitcpio.conf.d/99-omarchy-provisioning-key.conf`) or a comment about
  snapper snapshots. **Nothing configures Limine, `limine-mkinitcpio-hook`,
  snapper policy, the ESP or `mkinitcpio` differently.**
  `src/omarchy-deck-kernel.sh` has **no row in this table** — the seed's §3.7
  hypothesis is confirmed by grep, not assumed.
  ⚠️ Still not promotable to a fact for the *pin*: the `limine` and
  `limine-mkinitcpio-hook` **packages** move independently of this branch.
- **The greeter.** `default/sddm/hyprland.lua` — the file our greeter config
  mirrors — is not in the delta, and its sha256 is **identical at both refs**:
  `353fe59d7d46b21946cdc48000eef7b131e9e577c1d6117f07c3137cdbf0fe67`, which is
  exactly `UPSTREAM_GREETER_SHA256` at `src/deck-session.sh:334`. **Our mirror
  is still current and `stage_greeter`'s drift warning will stay silent.**
  `etc/sddm.conf.d/10-wayland.conf` (`CompositorCommand`) and `10-theme.conf`
  are likewise untouched.
- **Steam / gamescope / SteamOS.** Grepped all patches for
  `steamos|gamescope|steam` — **zero hits**. None of
  `steamos-session-select`, `steamos-priv-write`, `steamos-set-timezone`,
  `steamos-update` or `/usr/share/wayland-sessions/gamescope-wayland.desktop`
  is touched.
- **uwsm / the session target.** Grepped for
  `uwsm|sddm|wayland-session|display-manager` — three files matched, all in
  comments or in the unchanged `uwsm-app -- localsend` menu line.
  `wayland-session@hyprland.desktop.target` (`src/deck-session.sh:239`) is not
  redefined anywhere in the range.
- **squeekboard / the OSK.** Grepped for `squeekboard|on-screen|osk` — zero
  hits. Our fallback backend is untouched.

## 6. Method

```bash
gh api "repos/basecamp/omarchy/compare/354c2f0...quattro" > compare.json   # 90 files, 65 non-test
# one patch per file, so every verdict cites something read
python3 -c "import json,os;d=json.load(open('compare.json'));[open('patches/'+f['filename'].replace('/','__'),'w').write(f.get('patch','')) for f in d['files'] if not f['filename'].startswith('test/')]"
grep -lniE 'gsettings|dconf|screen-keyboard|input-sources' patches/*
grep -lniE 'limine|mkinitcpio|snapper|/efi|uki' patches/*
grep -lniE 'steamos|gamescope|steam' patches/*
for ref in 354c2f0 quattro; do gh api "repos/basecamp/omarchy/contents/default/sddm/hyprland.lua?ref=$ref" -q .content | base64 -d | sha256sum; done
```

⚠️ `compare` caps at 300 files; at 90 this range is well inside it. A future
range that exceeds it must be paged, not silently truncated.

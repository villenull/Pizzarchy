# FAST-INSTALL — four Deck installation variants

Operator decisions, 2026-09-23/24: target 3–8 seconds from final form confirmation to ready-to-reboot **when background work has finished**. First A press may erase the disk before final confirmation, but the first screen must say plainly that pressing A immediately wipes the **built-in drive** and that stopping leaves no working system. The microSD and USB boot medium must never be targets. Only OLED/NVMe hardware is verified; unsupported/ambiguous disks are a dead end, not a guess.

The first screen shows the Omarchy logo and a prominent “This will install Omarchy on your Steam Deck. Proceed?” question. After A starts the common restore, the controller/D-pad answers **Omarchy pre-installs?** then **Gaming Mode?**, each Yes/No with No the safe default. **Both No choices say they can be installed later from the Omarchy desktop**, backed by actual working actions (not merely a promise). Gaming Yes says Internet is required. If Gaming Yes has no connection, the network screen stays until connected or B goes back to the Gaming choice; it must not claim a working Gaming Mode without Steam. Gaming No is a desktop-only Omarchy machine with **password SDDM login** and a controller-operable on-screen keyboard at the greeter. Four combinations are real, not decorative. The No/No path should be fastest.

## What “pre-installs” means

The **pinned Omarchy 4.0.4 runtime** `bin/omarchy-remove-preinstalls` is the authority. It removes all preinstalled web-app launchers, TUI wrappers, mise launchers and these 13 packages: `aether cliamp libreoffice-fresh xournalpp pinta obsidian obs-studio kdenlive moonlight-qt lazydocker omacut omacalc omawrite`. `bin/omarchy-install-preinstalls` restores the same set; No must leave `~/.local/state/omarchy/preinstalls-removed` so the menu offers Install > Preinstalls. Core Omarchy, Deck input, Wi-Fi/audio/power and `linux-omarchy` remain in every variant. Avoid installing then removing 13 packages on the fast path.

## Clock and stages

`S0 A → early start (validate exactly one built-in NVMe, partition/wipe, restore the common minimal image) → pre-installs Yes/No → Gaming Yes/No → optional offline package work → Wi-Fi only if Gaming Yes → Steam launcher/client online only if Gaming Yes → identity screens → S5 final summary → late joins early and provisions the user.`

Clock A starts at S5 confirm. A 3–8-second post-confirm result is conditional: the form must outlast the common image restore, optional package transaction, UKI build and (for Gaming Yes) Valve’s Steam download. A quick form or a slow network necessarily leaves visible post-confirm wait. The research baseline is `docs/findings/INSTALL-SPEED.md`: 252 seconds post-form today, including ~86 seconds pacman and ~132 seconds Steam bootstrap on the operator’s measured link. Do not hide a residual wait in a first-boot black screen.

### C1: live CLI and state

`omarchy-deck-early start <disk>` starts transient `omarchy-deck-early.service` with output in `/var/log/omarchy-deck-early.log`, returns immediately and is idempotent on the same disk. A different disk or any SD/USB target is refused. `network-ready` marks confirmed connectivity; `status` prints one of absent/running/done/failed. `/run/omarchy-deck/early/{status,phase,error,timing.json}` records work/failure. `/run/omarchy-deck/steam/{status,error,progress}` records Steam separately: Steam download failure is reported, never silently reclassified as a successful Gaming Mode install. First-stage destructive action is authorized by the S0 warning, not S5.

### C2: answers and package placement

The form atomically writes `/run/omarchy-deck/choices/preinstalls` and `/run/omarchy-deck/choices/gaming`, each exactly `yes` or `no`, then writes `choices/locked` last once both are answered. Early restores a **single common minimal root image** immediately at S0; it waits for `locked` before any optional package transaction. Pre-installs cannot be changed after lock because their package transaction may already run. On the Gaming=yes network screen B may change Gaming to No **before network-ready**, so Gaming-only package transactions must wait for confirmed connectivity and re-read the choice; there is no route back to Pre-installs from that screen. Early runs only the requested offline package delta from the bundled mirror, installs the Steam launcher online and bootstraps Valve’s client only for Gaming=yes. All pacman mutations finish before the Limine/UKI finalizer. Gaming=no never fetches Steam or starts Gaming Mode services. Package decisions cannot be deferred to first boot merely to make the install timer look faster.

The image includes the full common Deck hardware/core closure including `linux-omarchy`, its headers, AMD firmware/microcode, and `qt6-virtualkeyboard`; it excludes the 13 optional apps and Gaming-only packages. Keep optional packages available offline in the ISO mirror. Steam launcher/client remain online because Valve’s client is not redistributable. No stock `linux` kernel may remain installed alongside `linux-omarchy`. Variant package counts derive from what was actually installed, not the maximum variant.

### C3: staged Steam home

Gaming=yes bootstraps the client into `/home/.omarchy-deck-staging`, uid/gid 1000 and mode 0700. Late creates the account at uid/gid 1000, renames the staging home to `/home/<user>`, re-seeds missing `/etc/skel` files, repairs Valve’s absolute links, and applies the Steam OOBE seed last. A real Valve 2.4 GiB tree was inspected; absolute path hits are symlinks and rotating logs, not binaries/config. Gaming=no skips the staging/Steam path entirely.

### C4: orchestrator and login

`OMARCHY_INSTALL_STAGE=early|late|full`, with full preserving the upstream single-pass path. Early uses deferred no-user provisioning for the common restore, identity-free Deck steps and finalizes Limine after optional package mutations. Late joins early, applies user credentials/hostname/timezone/keymap, runs user-dependent Deck steps, removes the OOBE pending marker and service enablement, validates boot, snapshots and syncs. Gaming=yes boots to Steam Gaming Mode with Omarchy desktop switch; Gaming=no has no Steam/Gaming services, but keeps controller mapper, desktop OSK and power behavior. For Gaming=no SDDM requires a password and Qt Virtual Keyboard (`InputMethod=qtvirtualkeyboard`) reachable by Deck trackpad/controller, with the Omarchy desktop session selected. Gaming autologin must be applied **after** upstream `configure_login` or it is deleted.

### C5: screen and unattended verification

S0 shows the logo, prominent proceed question and irreversible built-in-drive wipe warning. No second disk erase confirmation. D-pad selects the two Yes/No choices in pre-installs then Gaming order. If Gaming Yes, Internet is mandatory and B at network returns to Gaming choice; Gaming No bypasses network. S5 shows choices, early phase/failure and Steam status honestly. Cidata carries `preinstalls`, `gaming` (yes/no) and `form-delay-seconds` (non-negative integer) to exercise all variants without a controller. `/var/log/omarchy-deck-stages-timing.json` records early/late phases and `late.finished_at - late.confirmed_at`; serial markers go explicitly to `/dev/ttyS0` for QEMU. A failed early stage blocks success and is diagnosable.

### C6: in-place opt-ins from the desktop

Pre-installs No uses Omarchy's existing Install > Preinstalls action and leaves its marker present until the restore succeeds. Gaming No must also expose a **real** desktop action to enable Steam Deck Gaming Mode later: install the Gaming-only package set and Steam client online, apply the same session-switch layer/autologin/first-boot safeguards as Gaming Yes, and switch only once readiness is verified. The action must refuse or retry offline and fail visibly without leaving the desktop locked out. It must never wipe the disk. No fake menu row pointing to an unimplemented command.

## Verification

Focused shell/Python behavior probes → complete unit/shellcheck gate → real ISO build and package closure audit → timed QEMU installs for all four choices, including a 0-second form and a longer simulated form → inspect installed disk/boot/login and greeter keyboard surface. A physical Deck reinstall wipes the drive and requires the operator’s separate confirmation; SSH into the currently installed Deck is not needed for this work.

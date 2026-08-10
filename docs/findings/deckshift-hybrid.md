# FINDING — DeckShift evaluated, and why it was dropped

> ## ⚠️ SUPERSEDED as a decision; kept as evidence
>
> **This documents a DeckShift hybrid that was built, spliced onto Valve's
> session, and booted once on the Deck. That approach has since been
> reversed** — see `docs/PROGRESS.md` §2.4. This project ships its own session
> layer (`src/deck-session.sh`).
>
> Three things here are still load-bearing and are why the file is kept:
>
> 1. **The evidence that Valve's `gamescope` ships the entire SteamOS
>    session**, and that ChimeraOS's AUR session *collides* with it on
>    `gamescope-session.target`. That collision is the technical reason
>    DeckShift and Deck hardware do not compose.
> 2. **The record of what was hand-edited on the operator's Deck.** The
>    phase-1 rebuild (`docs/ROADMAP.md` P1.5) wipes these rather than unwinding
>    them; until then this table is the inventory of the contamination.
> 3. **Two bugs and one group-membership trap** that generalise beyond
>    DeckShift.
>
> The `/tmp` backup paths below are no longer load-bearing — restoring the
> hand-edited state stopped mattering once the rebuild was planned
> (`docs/PROGRESS.md` §2.5).

---

**Session 8, 2026-08-09.** Written before the first Gaming Mode boot. Nothing
below marked "untested" has been validated on hardware.

## Decisions taken that session — both since reversed

1. ~~**Pivot to Omarchy 3.8.4** as v0's target, not Quattro 4.x.~~
   **Reversed:** the target is Omarchy 4.0 (`docs/PROGRESS.md` §2.3), and the
   "v0" framing itself is gone (`docs/PROGRESS.md` §2.1). The underlying
   observation still holds — the Deck runs `v3.8.4-4-gedce5809` from git with
   no `omarchy` pacman package — it is now a *test-asset gap*, not a target.
2. ~~**DeckShift owns session switching.**~~ **Reversed** (`docs/PROGRESS.md`
   §2.4). `src/deck-session.sh` owns it. The `steamos-session-select` shim
   survives the reversal — it was always this project's own code.
3. **Hybrid: DeckShift's UX layer over Valve's native session.** The reason
   this was forced is §2 below, and that reasoning is what ultimately argued
   for dropping DeckShift entirely.

*Original text follows.*

1. **Pivot to Omarchy 3.8.4** as v0's target, not Quattro 4.x. The Deck runs
   `v3.8.4-4-gedce5809` from git, no `omarchy` pacman package. This closes
   `docs/PROGRESS.md`'s "which Omarchy" question outright — T3's
   shell integration is now testable on the only test asset.
2. **DeckShift owns session switching.** `src/deck-session.sh` is retired as a
   switcher. Its `steamos-session-select` shim survives (see below).
3. **Hybrid: DeckShift's UX layer over Valve's native session**, rather than
   DeckShift's intended ChimeraOS session. Forced by §2 below.

## The blocking finding: the AUR session packages cannot coexist

`gamescope-session-git` ships `/usr/lib/systemd/user/gamescope-session.target`,
already owned by Valve's `gamescope 3.16.25-3` (steamos.cloud build). Exactly
one file collides, but it is the whole unit graph.

Valve's:

    Requires/BindsTo=gamescope-session.service
    Upholds=steam-launcher.service
    Wants=ibus-gamescope.service
    Wants=steam-notif-daemon.service
    Wants=galileo-mura-setup.service      <- OLED mura correction
    Wants=gamescope-mangoapp.service

ChimeraOS's is a three-line stub with no dependencies — it doesn't need them,
because `gamescope-session-plus@.service` drives everything itself. It is a
self-contained session for generic PCs, which is why DeckShift uses it.

The AUR package declares no `Conflicts`, so pacman fails the transaction on a
file conflict. **Installing it with `--overwrite` would replace Valve's graph
with the stub**, silently dropping OLED mura correction, the Steam launcher
wiring, IBus and mangoapp. It would also churn on every `gamescope` upgrade,
which restores Valve's file and re-breaks ChimeraOS's session.

The two sessions are mutually exclusive on disk. On Deck hardware Valve's is
strictly better, and DeckShift's reason for using ChimeraOS's (no access to
Valve's repos on a generic PC) does not apply here.

## What was changed on the Deck

| File | Change |
|---|---|
| `/usr/local/bin/gamescope-session-nm-wrapper:163` | execs `/usr/bin/start-gamescope-session` instead of `/usr/share/gamescope-session-plus/gamescope-session-plus steam` |
| `/usr/share/wayland-sessions/gamescope-session-steam-nm.desktop` | `Name=` was "Gaming Mode (ChimeraOS)", now "(SteamOS)" — it was false |
| `/usr/local/bin/steamos-session-select` | retained, repointed at DeckShift's `switch-to-desktop` |
| `/etc/sddm.conf.d/95-deck-session.conf` | removed |
| `/usr/local/bin/deck-session-select` | removed |
| `/etc/sudoers.d/99-deck-session-select` | removed (`visudo -c` clean after) |

Backups of all six originals:
`/tmp/claude-1000/-home-huyke/caa11b2c-e6fc-4461-b45a-b331d00ee16f/scratchpad/backup-preswitch/`
Restoring `gamescope-session-nm-wrapper` alone reverts the entire hybrid.

The splice needs no env plumbing: `/usr/lib/steamos/gamescope-session` already
exports both vars the wrapper sets (`STEAM_ENABLE_VOLUME_HANDLER`,
`STEAM_DISABLE_AUDIO_DEVICE_SWITCHING`) plus HDR, VRR, fan control, dynamic
backlight and mangoapp.

## Why the shim was kept against the original plan

`gamescope-session-steam-git` would have provided `/usr/bin/steamos-session-select`.
With the AUR packages excluded, **nothing else on the system provides it**, and
Steam's Power → Switch to Desktop shells out to it by name. Without it that
affordance silently does nothing — `docs/PLAN.md` §8.1's failure mode, in the one
place a controller-only user cannot work around it.

It is repointed at DeckShift's `switch-to-desktop` specifically, not at
`gaming-session-switch`, because `switch-to-desktop` performs the synchronous
CPU-governor / power-profile restore *before* SDDM restarts. Bypassing it
strands the governor at `performance`.

## The re-login prerequisite

DeckShift grants its sudoers rules to **`%video`**, not to the user:

    %video ALL=(ALL) NOPASSWD: /usr/local/bin/gaming-session-switch
    %video ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart sddm
    %video ALL=(ALL) NOPASSWD: /usr/bin/chvt

It added `huyke` to `video` at 18:14, after the 18:06 login. `id -nG huyke`
shows the grant; the live session's `id` does not. **Every switch attempt from
a pre-18:14 session fails silently via `sudo -n`.** Directly parallel to the
§4.4 finding that the installer must add the user to `input`.

## ⚠️ The hybrid is a hand-edit

Re-running `./deckshift.sh` restores the ChimeraOS line at :163. DeckShift's
pacman hook is safe (it only re-applies `setcap cap_sys_nice` to gamescope),
but a DeckShift upgrade or reinstall silently reverts the hybrid. **This is the
piece that must become a script in this repo** — but not before it is proven.

## Untested — the whole point of the next session

Gaming Mode has **never** been entered on this Deck (zero gamescope activity in
any prior boot's journal). The genuinely unproven assumption: whether Valve's
`start-gamescope-session` tolerates being launched from inside DeckShift's
wrapper rather than directly as SDDM's `Exec`. It looks fine — it blocks on
`systemctl --user --wait start gamescope-session.target` and traps signals for
cleanup — but that is reading, not evidence.

Test order (steps 1–2 gate everything, ~10 seconds):

1. `id -nG` — confirm `video` is in the live session's credentials.
2. `sudo -n /usr/local/bin/gaming-session-switch gaming` — confirm the grant
   resolves. Exact call DeckShift makes.
3. `switch-to-gaming`. Kills the session; expect SDDM → Steam Big Picture.
4. In Gaming Mode: controller input, audio, and whether Steam's Power menu
   lists **Switch to Desktop** at all.
5. Return via **both** paths, in separate cycles: Super+Shift+R, then
   Steam → Power → Switch to Desktop. The second exercises the rewritten shim
   and is the controller-only path.
6. Back on desktop: `journalctl --user -b -1 -u 'gamescope-session*'`,
   `journalctl -t gamescope-wrapper -b -1`, and confirm
   `/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor` restored.

Black screen at step 3: `Ctrl+Alt+F2` to a TTY, restore the wrapper backup.

## Loose ends deliberately not touched

- **`git revert bcdab80` would be wrong** — it deletes the source of the
  surviving `steamos-session-select` shim. `src/deck-session.sh` needs hand-editing
  down to the shim installer plus the wrapper patch, once the hybrid is proven.
- **`/etc/sddm.conf.d/autologin.conf` still says `Session=omarchy`**, which
  resolves to no session file at all (no `omarchy.desktop`, no `/usr/share/xsessions/`).
  DeckShift's `zz-` drop-in sorts last so it wins in practice — but that stale
  Omarchy 3.8.4 entry is one filename away from mattering.
- **DeckShift's Settings TUI display keys go inert.** Refresh rate / output /
  GPU in `~/.config/environment.d/gamescope-session-plus.conf` are consumed by
  `gamescope-session-plus@.service`, which no longer runs. Valve's session uses
  `GAMESCOPE_MODE_SAVE_FILE=~/.config/gamescope/modes.cfg` and Steam's own
  in-Gaming-Mode display settings instead — arguably better, since that path is
  controller-navigable, but it is a behaviour change to verify at step 4.

## Corrected from last session

`src/deck-session.sh`'s drop-in never won, on any machine. Its own comment claimed
`95-deck-session.conf` "sorts after Omarchy's `autologin.conf`" — `9` < `a`, so
`autologin.conf` always overrode it. Undetected because Gaming Mode was never
booted. Worth keeping as a lesson even though the file is now deleted: the bug
was in a comment asserting an ordering nobody checked.

#!/usr/bin/env bash
#
# deck-session.sh -- two-way Gaming Mode <-> Desktop Mode session switching
# for a Steam Deck running Omarchy. T3's session layer.
#
# ===========================================================================
# WHAT UPSTREAM ALREADY DOES -- verified by reading what the installed
# packages actually ship (jupiter-staging/gamescope 3.16.25-3, Valve's build).
# ===========================================================================
#
# Valve's gamescope package already ships the ENTIRE SteamOS Gaming Mode
# session. This is worth stating because PLAN.md 6.4 says to fork
# 28allday/Super-Shift-S-Omarchy-Deck-Mode "because it solves the hard part",
# and that is no longer true:
#
#   /usr/share/wayland-sessions/gamescope-wayland.desktop  the session entry
#   /usr/bin/start-gamescope-session                       the entry point
#   /usr/lib/steamos/gamescope-session                     the real launcher
#   /usr/lib/systemd/user/gamescope-session.target         the unit graph
#   ... plus steam-launcher, ibus-gamescope, steam-notif-daemon,
#       gamescope-mangoapp and galileo-mura-setup (OLED mura correction).
#
# The closest prior art (28allday/deckshift) pulls ChimeraOS's
# gamescope-session from the AUR to get this -- necessarily, because DeckShift
# targets generic PCs with no access to Valve's repos. On Deck hardware with
# jupiter-staging configured, none of that is needed. DeckShift is also
# unlicensed, so this project cannot ship or vendor it at all.
#
# So this script does NOT build a session and does NOT fork one. It supplies
# the one thing Valve does not ship outside SteamOS: the mechanism for
# switching between that session and the Omarchy desktop, in both directions.
#
# ===========================================================================
# THE GAP THIS CLOSES
# ===========================================================================
#
# Steam's "Power -> Switch to Desktop" in Gaming Mode shells out to
# `steamos-session-select <target>`, and the target it actually passes is
# **plasma**, not `desktop` -- SteamOS's desktop is KDE. Observed in the sudo
# audit trail on this hardware. stage_session_select's dispatch accepts
# desktop|plasma|omarchy for that reason; do not "simplify" the plasma arm away.
#
# That binary is in NO repo configured here -- re-verified with `pacman -F`
# against core/extra/multilib/omarchy/jupiter-staging/holo-staging, which finds
# nothing. Note the attribution this comment used to carry was wrong:
# steamos-customizations-jupiter IS available (jupiter-staging) and does NOT
# ship it; that package is GRUB and holo-* machinery, which the Limine-only
# constraint forbids anyway.
#
# Without the binary, Steam's own affordance silently does nothing -- which is
# PLAN.md 8.1's failure mode, in the one place a controller-only user has no way
# to work around.
#
# So: install a `steamos-session-select` that behaves the way Steam expects,
# plus a matching path back from the desktop.
#
# Steam needs a SECOND thing, found later and by measurement rather than
# reasoning: it drives a set of privileged helpers out of
# /usr/bin/steamos-polkit-helpers/, by ABSOLUTE path. That whole tree belongs
# to SteamOS and is absent here, so each call returns 127. Three of them are
# handled in this script -- steamos-update (whose absence blocks Steam's
# first-run setup behind a false network error), steamos-set-timezone and
# steamos-priv-write. The rest (fan control, ALS, dock/BIOS updaters) are
# deliberately NOT supplied: see PROGRESS.md 5.15 for the jupiter-hw-support
# decision, and note that jupiter-fan-control lands in P2.3, which requires
# per-item operator approval every time.
#
# ===========================================================================
# WHY steamos-priv-write IS WORTH SHIPPING -- it is NOT "brightness is broken"
# ===========================================================================
#
# Steam does not simply fail when a privileged helper is missing. It falls
# back, and the fallback is the problem. Read from Steam's own console log on
# this hardware, one slider movement:
#
#   privileged write polkit:39638 -> /sys/class/backlight/amdgpu_bl0/brightness
#   RunCommand: ... /usr/bin/steamos-polkit-helpers/steamos-priv-write \
#                     "/sys/class/backlight/amdgpu_bl0/brightness" "39638"
#   Error: BWriteValueToFileAsUser: steamos-priv-write failed ...: 39638
#   RunCommand: ... echo "39638" | sudo -n tee "/sys/.../brightness"
#   RunCommand: ... sudo -n chmod a+w "/sys/.../brightness"
#
# Three tiers: the helper, then `sudo -n tee`, then `sudo -n chmod a+w` so no
# privilege is needed next time. So on THIS device the brightness slider works
# -- but only because /etc/sudoers.d/99-deck-testing grants the desktop user
# blanket NOPASSWD, a test-rig artifact owned by no package. Remove that (and
# the shipped ISO must) and tiers 2 and 3 both fail with it.
#
# PROGRESS.md 5.15 recorded "the slider does nothing". That is the right
# conclusion about the PRODUCT reached through a wrong belief about the test
# Deck, where it currently works. Do not "verify" this by moving the slider
# here and concluding it is fine.
#
# Supplying tier 1 is therefore a security fix as much as a feature: it stops
# Steam reaching for blanket sudo, and it stops the chmod that leaves sysfs
# nodes world-writable after every Gaming Mode start (observed: both
# .../amdgpu_bl0/brightness and .../status:white/led_brightness_multiplier
# are mode 666, restamped each boot).
#
# Note the two families resolve DIFFERENTLY, but BOTH land in /usr/bin:
#   steamos-session-select        via PATH, and that PATH is only
#                                 "/usr/bin:/bin" inside Steam's runtime
#   steamos-polkit-helpers/*      by absolute path, /usr/bin/steamos-polkit-helpers/
#
# So /usr/local/bin -- the conventional home for exactly this kind of local
# shim -- is unreachable for anything Steam invokes. Both stages verify
# reachability, not just existence, because the difference is invisible from a
# shell where /usr/local/bin is on PATH.
#
# ===========================================================================
# SECURITY TRADEOFF -- read before extending
# ===========================================================================
#
# Switching sessions means restarting the display manager, which is root-only.
# Steam invokes the hook as the unprivileged desktop user, so something has to
# bridge that.
#
# This uses a sudoers drop-in granting NOPASSWD on exactly one absolute path
# (${SELECT_BIN}) and nothing else. That is a real privilege grant and is
# deliberately narrow: the target is root-owned 0755, so a user who could
# rewrite it would already need root. The drop-in is validated with
# `visudo -c` before installation -- a malformed sudoers file breaks sudo
# for every user on the machine, so it is never written unvalidated.
#
# polkit would be the more conventional mechanism. It is not used here
# because the action would still amount to "this user may restart the display
# manager", and a sudoers line saying exactly that is far easier to audit
# than a polkit rule plus a helper. Revisit if this ships as a package.
#
set -euo pipefail

readonly PROG=deck-session

# The two session names, as SDDM knows them: the basename of the .desktop in
# a wayland-sessions directory, without the extension. Discovered rather than
# assumed -- see stage_preconditions.
readonly GAMING_SESSION=gamescope-wayland
DESKTOP_SESSION=""   # resolved at runtime; Omarchy's own entry

readonly SELECT_BIN=/usr/local/bin/deck-session-select

# /usr/bin, NOT /usr/local/bin. Steam's runtime narrows PATH to exactly
# "/usr/bin:/bin" -- read from the running Steam process's own environ, with
# SYSTEM_PATH unset so the ${PATH} fallback in its command template applies.
# The shim spent P1.5 in /usr/local/bin, where it existed, worked when invoked
# by hand, and was invisible to the one caller that matters.
readonly STEAM_SHIM=/usr/bin/steamos-session-select
readonly STEAM_SHIM_LEGACY=/usr/local/bin/steamos-session-select

# What Steam's runtime actually offers. Used to prove the shim is reachable
# rather than merely present.
readonly STEAM_RUNTIME_PATH=/usr/bin:/bin
readonly SUDOERS_FILE=/etc/sudoers.d/99-deck-session-select
readonly RETURN_DESKTOP_FILE=/usr/share/applications/deck-return-to-gaming.desktop

# --- the one command that means "go back to Gaming Mode" -------------------
#
# ONE constant, used by BOTH ways back: the .desktop entry's Exec= and the
# Quickshell menu row's action. They were separate string literals in two
# heredocs for exactly one session, which is one session too many -- a shim
# rename that reached only one of them leaves a launcher icon and a menu row
# that disagree, and the one that is wrong does nothing at all with no error
# anywhere. assert_return_action_agrees() re-derives both from what actually
# gets rendered and refuses to install if they have drifted.
#
# ${STEAM_SHIM}, NOT ${SELECT_BIN}: the shim in /usr/bin is the unprivileged
# entry point (it re-invokes ${SELECT_BIN} through the sudoers grant). A menu
# row or .desktop pointing at ${SELECT_BIN} would need a password nobody on a
# Deck can type.
readonly RETURN_ACTION="${STEAM_SHIM} gamescope"
readonly RETURN_LABEL="Return to Gaming Mode"
readonly RETURN_DESCRIPTION="Switch back to the Steam Big Picture session"

# --- the Quickshell menu row (Omarchy 4.0) --------------------------------
#
# Omarchy 4.0's menu is Quickshell, and its ONE documented extension point is a
# per-user JSONC file. Read out of the pinned runtime rather than a blog post:
# shell/plugins/menu/Menu.qml:51 --
#
#   property string userMenuPath: Quickshell.env("HOME")
#                                 + "/.config/omarchy/extensions/omarchy-menu.jsonc"
#
# IDs are object keys and the parent is inferred from the dotted id, so
# "gaming" is a ROOT row and "system.gaming" would sit under System. See
# stage_menu_row for why this one is at the root.
readonly MENU_EXT_REL=.config/omarchy/extensions/omarchy-menu.jsonc
# /etc/skel as well as the invoking user's home, and that is not belt and
# braces: docs/tasks/T5-fork-plan.md §3 trap (a) records that the ISO's
# `useradd` runs in phase 3 of 14, BEFORE our configure_deck phase, so a stage
# that seeds only skel produces a Deck whose first and only user never gets the
# row. The verification below reads the USER's copy for the same reason.
readonly MENU_EXT_SKEL="/etc/skel/${MENU_EXT_REL}"

# The row's id. A NEW id lands at the END of the root order
# (MenuModel.js:mergeMenuSources appends); reusing an existing id would keep
# that id's position and merge our fields on top of Omarchy's. Deliberately new
# -- overriding one of Omarchy's own rows to make room would be a surprise.
readonly MENU_ROW_ID=gaming

# 🔴 U+F0297, Nerd Font `md-gamepad_variant`. A GLYPH, not an icon file, which
# sidesteps docs/findings/P16-redistribution-and-trademark.md entirely -- we
# ship a codepoint, not artwork.
#
# ⚠️ The value this comment block used to suggest (U+F04B4) was WRONG. Checked
# against the cmap of the font Omarchy's menu actually asks for
# (Style.qml:272, "JetBrainsMono Nerd Font"): U+F04B4 is `md-smoking`, a
# cigarette. Nothing would have reported that -- a wrong-but-present glyph
# renders perfectly. U+F0297 is one codepoint (verified: `len(s) == 1`, not a
# surrogate pair), it is in that font, and its Nerd Font name carries no
# vendor: `md-steam`, `fa-steam` and `md-microsoft_xbox_controller` all exist
# and are all the wrong answer here.
readonly MENU_ROW_ICON=$'\U000F0297'

# The row is spliced into a file this script does not own, between whole-line
# markers, exactly as install_osk_kb_layout_rule does for Hyprland's Lua. See
# stage_menu_row for why this is a splice and not a rewrite.
readonly MENU_ROW_BEGIN="// >>> deck-session.sh: return to Gaming Mode >>>"
readonly MENU_ROW_END="// <<< deck-session.sh: return to Gaming Mode <<<"

# --- the boot-time re-assert (operator decision, 2026-08-12) ---------------
#
# Steam's own Power -> "Switch to Desktop" REWRITES the default session to the
# desktop, undoing stage-default-session. The product behaves the way stock
# SteamOS does instead: Desktop Mode is a one-shot session and any reboot
# returns to Gaming Mode.
readonly BOOT_DEFAULT_UNIT_NAME=deck-boot-default-gaming.service
readonly BOOT_DEFAULT_UNIT="/etc/systemd/system/${BOOT_DEFAULT_UNIT_NAME}"

# 🔴 THE ESCAPE HATCH. With this unit enabled a broken Gaming Mode is
# re-asserted on EVERY boot, and the operator has one device. Touch this file
# and the unit's ConditionPathExists=! skips it -- no edit, no unit file, no
# systemctl, and `systemctl status` says out loud that a condition skipped it.
# stage_boot_default_gaming creates the directory so the escape is one `touch`,
# and prints both this path and the `systemctl disable` form.
readonly BOOT_DEFAULT_OVERRIDE=/etc/deck-session/no-boot-default-gaming

# The display manager, by BOTH names. sddm.service carries
# `[Install] Alias=display-manager.service` and `systemctl enable sddm` makes
# /etc/systemd/system/display-manager.service a symlink to it -- confirmed on
# this machine, not assumed. Ordering against a unit name that does not exist
# is a silent no-op in systemd, so naming only the alias would leave the
# re-assert unordered on a machine where the alias was never installed.
readonly BOOT_DEFAULT_BEFORE_ALIAS=display-manager.service
readonly BOOT_DEFAULT_BEFORE_REAL=sddm.service

# --- Desktop session settings (PROGRESS.md §5.20, §2.6, R-38) -------------
#
# Three values that decide whether the shipped device works and which lived,
# until this stage existed, only as hand edits on the test Deck -- exactly the
# "absent from a built image, and no test notices" problem T5 records. Every one
# was found by something failing on a screen, never by a check failing.
#
# The two GSettings go in a dconf SYSTEM database rather than a user's dconf,
# because the image creates a user we have never met: a `gsettings set` run
# during install writes one account's database and a later account gets the
# broken default back.
readonly DCONF_PROFILE=/etc/dconf/profile/user
# `install -D` creates db/local.d, so the directory needs no constant of its own.
readonly DCONF_SITE_FILE=/etc/dconf/db/local.d/50-deck-desktop

# squeekboard's auto-show gate. Ships `false`; with it unset the on-screen
# keyboard NEVER appears on text focus no matter what else is correct, which is
# how §5.20 was first mis-recorded as "focus-triggered show does not work".
readonly OSK_KEY=/org/gnome/desktop/a11y/applications/screen-keyboard-enabled

# squeekboard warns `No system layout` and draws no keys without an input
# source. Empty by default on this Deck.
readonly INPUT_SOURCES_KEY=/org/gnome/desktop/input-sources/sources

# --- The on-screen keyboard's XKB layout (PROGRESS.md 5.20) ---------------
#
# THE DEFECT, reported from the panel 2026-08-12: "many of the keys don't type
# what they should". They are not mistyped by us. The OSK draws a US layout and
# emits raw KEYCODES through the mapper's uinput device (src/deck_osk_layout.py:
# the ';' key is `KEY_SEMICOLON`); which CHARACTER that becomes is decided
# entirely downstream, by the XKB keymap the compositor has bound to that
# device. This Deck's session is Latin American -- /etc/vconsole.conf carries
# XKBLAYOUT=latam and Omarchy's own default/hypr/input.lua reads kb_layout
# straight out of that file -- so AC10 is 'n-tilde' and the OSK's ';' types it.
# Measured, not inferred: `hyprctl devices -j` reports every keyboard on the
# Deck, ours included, as layout=latam / "Spanish (Latin American)".
#
# ⚠️ The keycodes are RIGHT and the mapper needs no change. Only the
# translation is wrong.
#
# ⚠️ PER DEVICE, NOT SESSION-WIDE -- operator decision 2026-08-12. Physical
# keyboards and the rest of the desktop keep Latin American; only our virtual
# keyboard is pinned. Nothing here touches vconsole, localectl, the dconf input
# source, or Omarchy's global kb_layout.
#
# ⚠️ NOT the same thing as INPUT_SOURCES_KEY above. That one exists so
# squeekboard has a layout to DRAW; this one decides what the compositor TYPES
# for a keycode. They are different layers and both are needed.
readonly OSK_KB_LAYOUT=us

# The uinput device src/deck-input-mapper.py creates, verbatim (its
# `UInput(..., name=...)`). Kept here so test/unit/test-deck-session.sh can
# assert the mapper still declares exactly this -- a rename there would leave
# the rule below matching nothing, which is the silent no-op this whole block
# is written to avoid.
readonly OSK_UINPUT_NAME="deck-input-mapper virtual keyboard"

# What a Hyprland device rule has to match: Hyprland lowercases the device name
# and turns spaces into dashes (`deviceNameToInternalString`). MEASURED on the
# Deck 2026-08-12 with `hyprctl devices -j`, not derived from the header.
readonly OSK_HYPR_DEVICE=deck-input-mapper-virtual-keyboard

# 🔴 Why the rule is declared for suffixed names too, and why that is not
# belt-and-braces padding.
#
# Our uinput device declares BOTH keys and REL axes, so Hyprland binds it
# TWICE -- once as a keyboard, once as a pointer -- and
# `InputManager::getNameForNewDevice` appends -1, -2 ... to whichever copy asks
# for a name that is already taken. Measured on the Deck: the KEYBOARD holds
# the bare name and the POINTER holds `-1`. Which half wins the bare name is
# device-enumeration order and nothing in Hyprland promises it stays that way;
# a mapper restart that flipped it would leave the rule attached to a pointer,
# where kb_layout is inert, and the keyboard back on latam -- with no error
# anywhere. `kb_layout` on a pointer costs nothing. Guessing wrong costs the
# entire fix, silently.
readonly OSK_HYPR_DEVICE_ALIASES=3

# Hyprland's Lua config is a user dotfile: hyprland.lua does `require("hypr.input")`
# and package.path resolves that to ~/.config/hypr/input.lua. There is no
# system-wide drop-in for it, so this is patched into the desktop user's file
# the same way the idle policy is patched into their shell.json -- and, like
# that one, it is owed a T5 bake-in row (T5-fork-plan.md 5.3).
readonly HYPR_INPUT_LUA_REL=.config/hypr/input.lua
# Omarchy's shipped skeleton, used only to SEED an absent file. Not a fallback
# we edit: `require("hypr.input")` errors outright when the user has no
# input.lua, so creating one is strictly better than leaving it missing.
readonly HYPR_INPUT_LUA_TEMPLATE=/usr/share/omarchy/config/hypr/input.lua

# The block is delimited so a re-run replaces its own work instead of appending
# a second copy, and so the user's own overrides above it are never touched.
readonly OSK_KB_RULE_BEGIN="-- >>> deck-session.sh: on-screen keyboard XKB layout >>>"
readonly OSK_KB_RULE_END="-- <<< deck-session.sh: on-screen keyboard XKB layout <<<"

# A global assigned by the LAST line of the block, so its presence in a live
# compositor proves the whole block executed.
#
# ⚠️ `hyprctl eval` CANNOT read it back with a bare Lua return: on 0.56.2 eval
# prints "ok" -- its own status, not the value -- and exits 0 for every
# expression that does not raise, a nil global included. Measured 2026-08-12
# with a nonexistent name as the negative control. (The readback recipe written
# into the Deck's own input.lua for the above_lock sentinel is therefore a
# no-op; docs/tasks/T5-fork-plan.md 5.6 carries the corrected text that a built
# image must bake in.) What eval DOES surface is a Lua error: exit 7, with the
# message. So the probe is an assertion, not a read -- see
# verify_osk_kb_layout, and test/unit/test-hyprctl-syntax.sh scanner 3, which
# fails the build if the readback shape is written down anywhere again.
readonly OSK_KB_SENTINEL=DECK_OSK_KB_LAYOUT

# --- Omarchy idle policy (R-38) -------------------------------------------
#
# Omarchy ships screensaver=150s and lock=300s. The LOCK is the problem: it is a
# password prompt, autologin does not cover it, and on a keyboard-less handheld
# no available on-screen keyboard can reach a layer-shell lock surface. Five
# idle minutes would lock the device out of itself.
#
# ⚠️ `lock: 0` does NOT disable it -- IdleModel.secondsFromConfig only rejects
# negative and non-finite values, so 0 is accepted and `lockDelaySeconds === 0`
# is the fire-immediately branch. Disabling means a LARGE timeout.
#
# ⚠️ And that timeout has a ceiling: lockDelaySeconds*1000 feeds a QML
# Timer.interval, a 32-bit int, so anything past ~2147483s (~24.8 days)
# overflows. A day is effectively never for a handheld and is nowhere near it.
#
# 🔴 THIS COVERS THE IDLE PRODUCER ONLY, AND THAT IS NOT THE ONLY ONE.
# Measured 2026-08-11 (docs/findings/T9-lock-service-mitigation.md): Omarchy
# also ships `omarchy-sleep-lock.service`, a systemd-inhibit on logind's
# PrepareForSleep that runs `omarchy-shell lock lock` -- so **the power button
# locks this device**, no idle involved -- and a `system.lock` row in the same
# menu our Desktop Mode row lives in.
# An earlier version of this comment claimed the settings below mean the
# handheld "can never be shown an unanswerable password prompt". That was
# false when it was written. The settings below are necessary, not sufficient.
# The suspend producer is now covered by SLEEP_LOCK_GLOBAL_MASK below; the menu row is
# deliberately left alone -- a lock the user ASKS for is not a lockout.
readonly OMARCHY_SHELL_JSON_REL=.config/omarchy/shell.json
readonly OMARCHY_SHELL_JSON_DEFAULTS=/usr/share/omarchy/config/omarchy/shell.json
readonly IDLE_SCREENSAVER_SECONDS=150
readonly IDLE_LOCK_SECONDS=86400

# --- The suspend lock producer, and why we resume unlocked ----------------
#
# 🔴 THIS PROJECT SHIPS A HANDHELD THAT RESUMES FROM SLEEP UNLOCKED, ON
# PURPOSE. That is a security trade-off, taken deliberately, and it is written
# here rather than only in a findings document because the next person to read
# this constant is the one who might "fix" it.
#
# Why a lock on resume is not a password prompt on this device -- it is a lost
# session (docs/findings/T13-power-button-and-sleep.md §5.3, all measured):
#
#   * There is NO KEYBOARD. The only text input is our own on-screen keyboard,
#     which reaches a lock surface at all only because of a Hyprland
#     `above_lock = 2` layer rule -- a user config file one Lua syntax error
#     away from being silently discarded (docs/PROGRESS.md §5.24).
#   * There is NO UNLOCK IPC. Omarchy's shell exposes `lock`, `isLocked`,
#     `status`, `preview` and `hidePreview`, and nothing that releases a lock
#     (measured with `qs ipc show`, docs/PROGRESS.md §5.24).
#   * docs/RECOVERY.md's documented escape does NOT work against a healthy
#     lock: `clear_crashed_lockscreen` refuses one, measured against a real
#     locked Deck 2026-08-11.
#
# So the failure mode of "lock on resume" is not "the user types a password".
# It is "the user holds power for ten seconds and loses their work", every
# time the OSK path is even slightly wrong. ⚠️ The trade-off is real and is
# not free: a lost or stolen Deck is an open session. Full-disk encryption is
# the separate axis that answers that (docs/tasks/T5-fork-plan.md §5.5), and
# the user can still lock deliberately from the System menu.
#
# WHY /etc AND NOT $HOME. The operator's Deck was masked BY HAND on 2026-08-11
# with `~/.config/systemd/user/omarchy-sleep-lock.service -> /dev/null`
# (docs/findings/P22-deck-conformance-sweep.md §3.1, measured). That mask is
# per-user state: a fresh install, a second user or a wiped home loses it, and
# the unit's PRESET is `enabled`, so `systemctl --user preset-all` or simply a
# new user re-arms it. The enablement symlink is still sitting under the mask
# in that same home. An installer's artefact has to outlive all of that, so it
# goes in /etc/systemd/user -- which is byte-for-byte what
# `systemctl --global mask` writes, and is the reason that path exists.
#
# ⚠️ PRECEDENCE, because it is what makes this work: systemd resolves a user
# unit BY NAME through ~/.config/systemd/user, then /etc/systemd/user, then
# /usr/lib/systemd/user, and a symlink to /dev/null anywhere in that chain
# masks it. A `.wants/` symlink from an enable/preset does not inject a
# fragment path, so an enabled-but-masked unit stays masked -- which is
# exactly the state measured on the Deck, one level up in $HOME. That the same
# holds one level down in /etc is INFERRED from the search order, not yet
# measured on hardware; verify with `systemctl --user is-enabled` returning
# `masked` for a user whose home carries no mask of its own.
#
# ⚠️ NOT `systemctl --global mask`: the symlink has to be bakeable into an
# image by a build that has no running systemd for the target (T5), and `ln`
# needs none. The artefact is identical either way.
readonly SLEEP_LOCK_UNIT=omarchy-sleep-lock.service
readonly SLEEP_LOCK_GLOBAL_MASK="/etc/systemd/user/${SLEEP_LOCK_UNIT}"
# Where a per-user mask would sit, relative to a home directory. Ours does not
# go here -- this is only what gets checked for a user file SHADOWING /etc.
readonly SLEEP_LOCK_USER_UNIT_REL=".config/systemd/user/${SLEEP_LOCK_UNIT}"

# --- Desktop-mode input mapper (ROADMAP P2.1, T3 §4) ----------------------
readonly MAPPER_SRC_NAME=deck-input-mapper.py
readonly MAPPER_BIN=/usr/local/bin/deck-input-mapper

# The OSK layout core (T8). Imported by the mapper, so it needs a real directory
# rather than a sibling of MAPPER_BIN: the mapper is installed WITHOUT its .py
# extension and /usr/local/bin is not a place to put importable modules. The
# mapper derives this path as <its own dir>/../lib/deck-osk -- keep them in step.
readonly OSK_SRC_NAME=deck_osk_layout.py
readonly OSK_LIB_DIR=/usr/local/lib/deck-osk
# Every module the mapper may import, installed together. The layout core is
# needed always (it decides which keycodes the uinput device declares); the TTY
# renderer only by --osk-backend=tty, which is the installer's keyboard. They
# ship as a set because a half-installed pair is the failure that degrades
# silently -- the mapper starts, navigation works, and the keyboard is missing.
OSK_MODULES=("$OSK_SRC_NAME" deck_osk_tty.py deck_osk_wayland.py)
readonly OSK_MODULES

# Which keyboard STEAM+X opens in Desktop Mode (T8 step 7).
#
# `layer` is our own overlay: two cursors, one per trackpad, drawn by us. It
# replaces squeekboard as the DEFAULT -- but squeekboard is deliberately NOT
# removed. The mapper falls back to it automatically if the overlay cannot
# start or dies (`osk_fall_back`), because our overlay needs a compositor, a
# preloaded library and a live process, and squeekboard needs none of those.
# The worst case is therefore the behaviour that shipped before this change,
# not a handheld with no way to type.
#
# ⚠️ Set this to `dbus` to put squeekboard back in charge without touching
# anything else. That is the whole rollback.
readonly MAPPER_OSK_BACKEND=layer
# /etc/systemd/user, not ~/.config: this is installed by an installer and has to
# apply to whatever user the image creates, so T5 can bake it in unchanged.
readonly MAPPER_UNIT=/etc/systemd/user/deck-input-mapper.service

# VERIFIED on hardware, and worth verifying again if Omarchy's session wiring
# changes: `hyprland-session.target` does NOT exist, and a unit WantedBy a
# nonexistent target enables without error and never starts -- silent success,
# which this project forbids. Omarchy 4.0 drives Hyprland through uwsm, whose
# real target is this one.
readonly MAPPER_WANTED_BY=wayland-session@hyprland.desktop.target

# --- Lizard mode: the controller firmware's own input emulation -----------
#
# PROGRESS.md 5.21 is the defect, 5.9 / R-29 the measurements, and operator
# decision 2 in 5.25 the approval -- which grants persisting `N` only WITH the
# fallback, and calls the fallback the non-negotiable half.
#
# /sys/module/hid_steam/parameters/lizard_mode is a MODULE PARAMETER: it is Y
# at every boot and a reboot resets it. What each value costs was measured on
# hardware, not reasoned:
#
#   Y  the firmware emits its own pointer, Enter, Esc, Tab and arrows -- and
#      SWALLOWS X, Y, L1, R1, STEAM and QAM entirely. Those six reach no evdev
#      node at all, so deck-input-mapper.py is a complete no-op, STEAM+X cannot
#      be detected, and there is no Space for archinstall's multi-select. The
#      device is degraded, and always usable.
#   N  those six appear on the pad node and the firmware's pointer disappears,
#      which makes the mapper the ONLY input path on the device.
#
# THE INVARIANT THIS INSTALLS: lizard mode is off IF AND ONLY IF the mapper is
# running. No persistence file, no modprobe.d option, no boot-time flag -- the
# knob's lifetime is bound to the service's, by that service's own
# ExecStartPost=/ExecStopPost=. Boot leaves Y, so a mapper that never starts
# leaves a usable device, and ExecStopPost= hands input back to the firmware
# when it dies. The worst case is losing STEAM+X, not losing input.
#
# ⚠️ WITH ONE MEASURED EXCEPTION -- see render_lizard_dropin. A SIGKILL of the
# whole cgroup takes ExecStopPost= with it, and lizard mode stays off until the
# next boot. Measured on systemd 261, not inferred.
#
# EXPLICITLY REJECTED: a modprobe.d drop-in setting the parameter at module
# load. It applies before any userspace check can run, so a boot where the
# mapper cannot start would present a handheld with no pointer and no keys --
# the exact failure the fallback exists to prevent, made unconditional.
#
# (The rejected directive is deliberately not quoted verbatim anywhere in this
# repo: test/unit/test-deck-session.sh greps src/ for it with no carve-out for
# comments, and a carve-out is how that check would come to pass for the wrong
# reason.)
readonly LIZARD_SYSFS=/sys/module/hid_steam/parameters/lizard_mode
readonly LIZARD_HELPER=/usr/local/sbin/deck-lizard-mode
readonly LIZARD_SUDOERS=/etc/sudoers.d/99-deck-lizard-mode

# Derived from MAPPER_UNIT, not spelled out: a drop-in is only a drop-in if it
# sits in `<unit path>.d`, and a file in the wrong directory is inert -- valid,
# installed, and doing nothing. The two must not be able to drift.
readonly LIZARD_DROPIN="${MAPPER_UNIT}.d/50-deck-lizard-mode.conf"

# The unit the drop-in's OnFailure= reaches. It exists because ExecStopPost= has
# a measured hole -- systemd spawns it INTO the mapper's cgroup, so a cgroup-wide
# SIGKILL kills it too -- and OnFailure= starts a SEPARATE unit, in its own
# cgroup, which survives. Both halves are kept: ExecStopPost= is synchronous and
# covers the ordinary paths, OnFailure= covers the ones that kill it. The table
# above render_lizard_dropin has the measurements for both.
#
# Same directory as MAPPER_UNIT, and for the same reason: an installer writes it
# for a user it has never met, so T5 can bake it into the image unchanged.
readonly LIZARD_RESTORE_UNIT=/etc/systemd/user/deck-lizard-restore.service

# The absolute sudo, for the drop-in's Exec lines. systemd runs Exec= without a
# shell and wants an absolute path for the first token. NOT the same thing as
# this script's own ${SUDO}, which is "sudo" or the empty string depending on
# whether we are already root.
readonly SUDO_BIN=/usr/bin/sudo

readonly STATE_FILE=/var/lib/deck-session/next-session

# Steam resolves its privileged helpers by ABSOLUTE path, not through PATH --
# measured from Steam's own logs on this hardware, not inferred:
#
#   PATH="${SYSTEM_PATH-${PATH}}"  /usr/bin/steamos-polkit-helpers/steamos-update check
#
# so anything installed here has to live at that exact path. /usr/local/bin is
# not an option for these the way it is for steamos-session-select (which Steam
# *does* invoke through PATH). Nothing in this project may assume the two
# families resolve the same way.
readonly POLKIT_HELPER_DIR=/usr/bin/steamos-polkit-helpers
readonly UPDATE_STUB="${POLKIT_HELPER_DIR}/steamos-update"
readonly TIMEZONE_HELPER="${POLKIT_HELPER_DIR}/steamos-set-timezone"
readonly PRIV_WRITE_HELPER="${POLKIT_HELPER_DIR}/steamos-priv-write"

# Separate drop-ins, one per helper, rather than one file granting both. They
# are independent grants with different blast radii and either may need to be
# revoked without the other.
readonly PRIV_WRITE_SUDOERS=/etc/sudoers.d/99-deck-priv-write
readonly TIMEZONE_SUDOERS=/etc/sudoers.d/99-deck-set-timezone

# The sysfs node stage-priv-write-helper verifies its write path against: the
# exact one Steam moves for the brightness slider on this hardware, read from
# Steam's own log (see this file's header). Named rather than repeated inline
# so the stage and verify_priv_write_helper cannot drift apart.
readonly DECK_BACKLIGHT=/sys/class/backlight/amdgpu_bl0/brightness

# Called by absolute path from the timezone helper's sudo line, because that is
# the form omarchy-settings-dev's own sudoers rule matches (see
# stage_timezone_helper). `timedatectl` bare would resolve through PATH and
# miss the grant.
readonly TIMEDATECTL_BIN=/usr/bin/timedatectl

# Named once so the stub, its --help and this script's own output cannot drift
# into telling a user three different things about how to update the machine.
readonly REAL_UPDATE_HINT='sudo pacman -Syu'

# --- Display rotation (PROGRESS.md 5.11) ----------------------------------
#
# The Deck's panel scans out 800x1280 PORTRAIT and is mounted rotated, so every
# surface that does not rotate itself renders sideways. No kernel DEFAULT
# corrects it -- fbcon/rotate is 0 out of the box on both stock Arch and
# Neptune -- but the TTY is no longer left that way: this project sets
# fbcon=rotate:1 on the kernel cmdline via the drop-in
# /etc/limine-entry-tool.d/50-deck-fbcon-rotation.conf (PROGRESS.md 5.11;
# measured live in /proc/cmdline and in every limine.conf entry 2026-08-12,
# docs/findings/P22-deck-conformance-sweep.md 6). That fixes the text console
# ONLY -- fbcon does not touch what a compositor draws -- so the greeter and
# the desktop still need a per-surface userspace transform, which is what the
# values below are. Gaming Mode is exempt: gamescope applies its own transform.
#
# transform 3 (270 deg) and NOT 1: both were applied on this hardware and
# looked at, and 1 renders upside down. R-19 recorded transform,1 by inference.
readonly PANEL_OUTPUT=eDP-1
readonly PANEL_TRANSFORM=3
readonly PANEL_SCALE=1.25

# Omarchy's greeter config is package-owned (omarchy-settings-dev), so editing
# it in place would be undone by the next upgrade. Ship our own beside it and
# repoint SDDM instead.
readonly GREETER_LUA=/usr/local/share/deck-session/greeter-hyprland.lua
readonly UPSTREAM_GREETER_LUA=/usr/share/sddm/hyprland.lua

# Ours must sort AFTER Omarchy's 10-wayland.conf (which sets CompositorCommand)
# to win, and is deliberately a different file from SDDM_DROPIN because
# deck-session-select rewrites that one on every switch -- a CompositorCommand
# living there would vanish the first time anyone changed session.
readonly SDDM_GREETER_DROPIN=/etc/sddm.conf.d/zy-deck-greeter.conf

# A systemd drop-in, NOT an sddm.conf one -- this is about the unit's restart
# policy, not about SDDM's own settings.
readonly SDDM_UNIT_DROPIN=/etc/systemd/system/sddm.service.d/50-deck-switch-resilience.conf

# The restart is handed to a transient unit rather than run inline. See
# render_restart_helper for the three measured reasons.
readonly RESTART_HELPER=/usr/local/lib/deck-session/restart-sddm
readonly SWITCH_UNIT=deck-session-switch

# sddm ships TimeoutStopSec=5, and a Gaming Mode teardown does not fit in it --
# measured at 5.008s, i.e. systemd SIGKILLed sddm mid-teardown and then started
# the replacement 3ms later, against a VT the killed compositor still held.
# 30s is generous rather than tuned: the cost of it being too long is a slow
# switch, and the cost of it being too short is a device with no session.
readonly SDDM_STOP_TIMEOUT=30

# Bound on the post-stop settle loop, in 0.1s units. Never unbounded: a stuck
# seat must not mean sddm is never started again.
#
# 60s, matching steam-launcher.service's own TimeoutStopSec. R-28: that unit is
# PartOf=graphical-session.target and Steam takes tens of seconds to exit --
# measured at ~29s, and systemd will wait 60. Giving up before systemd does
# would just hand the problem back to the autologin retry loop, which is the
# thrash this bound exists to prevent.
#
# It sounds long and is not, on the normal path: the loop breaks the moment the
# check passes, and 18 of 20 measured switches clear it immediately. The cost is
# paid only when Steam is genuinely still shutting down, and the alternative
# there is 30s of visible flicker rather than 30s of waiting.
readonly VT_SETTLE_MAX=600

# Our greeter config is a self-contained MIRROR of upstream's settings plus the
# monitor transform -- not an include, because Hyprland's Lua parser offers no
# documented way to source another file and a greeter that fails to parse is a
# device with no graphical way in. The cost of copying is drift, so the stage
# checks this hash and warns when upstream's file changes. Update both together.
readonly UPSTREAM_GREETER_SHA256=353fe59d7d46b21946cdc48000eef7b131e9e577c1d6117f07c3137cdbf0fe67

# Every file this script installs carries this line, so a re-run recognises
# its own output (the idempotency requirement) and refuses to clobber someone
# else's. Keyed on a marker rather than on file type, because a symlink test
# would not survive the first time we install a real script.
#
# The COMMENT PREFIX varies by file type and the bare text is what we match on.
# This is not fussiness: the marker was originally '#'-only, and embedding it in
# a Lua config put a '#' on line 2, where Lua only accepts one on line 1. That
# is a syntax error, so Hyprland discarded the entire greeter config and fell
# back to defaults -- rotated -- without logging anything. Add a new prefix here
# rather than reusing one that happens to be nearby.
readonly INSTALL_MARKER_TEXT="installed-by: ${PROG}.sh"
readonly INSTALL_MARKER="# ${INSTALL_MARKER_TEXT}"        # shell, ini/sddm.conf
readonly INSTALL_MARKER_LUA="-- ${INSTALL_MARKER_TEXT}"   # lua (hyprland config)
# jsonc (the Quickshell menu extension). A NEW prefix rather than a reused one,
# per the paragraph above: '#' is not a comment in JSON or in JSONC, and
# Quickshell's parser does not report the error -- MenuModel.js:parseMenuJsonc
# catches and `return []`, and Menu.qml's FileView sets printErrors: false, so a
# '#' in that file silently drops EVERY user row with nothing logged anywhere.
# ⚠️ Only WHOLE-LINE '//' comments survive: stripJsonc matches
# /^\s*\/\/[^\n]*(\n|$)/gm, so a comment after a value on the same line breaks
# the parse.
readonly INSTALL_MARKER_JSONC="// ${INSTALL_MARKER_TEXT}"

# BUG FIX (was 95-deck-session.conf): SDDM reads /etc/sddm.conf.d/*.conf in
# lexical order and LATER files win. The previous name carried a comment
# claiming it "sorts after Omarchy's autologin.conf" -- it does not, because
# '9' < 'a', so autologin.conf overrode it on every machine. The bug was in a
# comment asserting an ordering nobody checked, and it went undetected because
# Gaming Mode had never been booted, so the code path was never exercised.
#
# 'zz-' sorts after any plausible neighbour. Confirmed empirically rather than
# reasoned: DeckShift's own zz- drop-in was observed winning over
# autologin.conf on this hardware.
readonly SDDM_DROPIN=/etc/sddm.conf.d/zz-deck-session.conf

# ---------------------------------------------------------------------------
# THE POWER BUTTON  (stage-power-button -- OPT-IN, not in INSTALL_STAGES)
# ---------------------------------------------------------------------------
#
# Today, on the operator's Deck: a press in Desktop Mode flashes Omarchy's
# System menu and does nothing else; a press in Gaming Mode does nothing at
# all. Neither is a bug in anything -- the key was simply never wired to sleep.
# Omarchy ships /etc/systemd/logind.conf.d/10-ignore-power-button.conf
# (HandlePowerKey=ignore, system-wide, package-owned) and binds XF86PowerOff to
# `omarchy-menu toggle system` in Hyprland. Gaming Mode is Valve's stock
# gamescope session, which has no such bind, and Valve's own handler
# (steamos-powerbuttond) is in none of this project's package lists.
#
# All of that is READ, and the evidence is docs/findings/T13-power-button-and-
# sleep.md §2 and §4. What follows is the part that was MEASURED, on the
# operator's Deck (Valve Galileo, OLED), 2026-08-12, n=3 presses -- one tap and
# two deliberate holds -- with python-evdev watching all 18 input nodes:
#
#   ONE physical press produces TWO KEY_POWER presses, on two nodes:
#
#     event4  "AT Translated Set 2 keyboard"  ID_PATH=platform-i8042-serio-0
#             A REAL KEY. Down on press, up on release, tracking a 2.92 s hold
#             exactly. This is the one worth keeping.
#     event2  ACPI LNXPWRBN                   ID_PATH=acpi-LNXPWRBN:00
#             A FIRE-AND-FORGET NOTIFY. One instantaneous press+release
#             131-198 ms after the press, INDEPENDENT of hold length. It can
#             never express a hold, so it can never satisfy a long-press.
#     event0  ACPI PNP0C0C                    ID_PATH=acpi-PNP0C0C:00
#             Silent across all three presses.
#
# and all three carry TAGS=:power-switch: (udevadm info, same session), because
# /usr/lib/udev/rules.d/70-power-switch.rules tags every input node with
# ID_INPUT_KEY=1. That tag is exactly what systemd-logind watches.
#
# 🔴 TWO TRAPS, and the whole shape of this stage is built out of them.
#
#   1. HandlePowerKey= DEFAULTS TO `poweroff`, not `suspend` (man logind.conf,
#      systemd 261 -- the version the Deck runs). Merely deleting Omarchy's
#      drop-in would hard-power-off the Deck on every tap: worse than the menu
#      flash it replaces. The value is therefore written EXPLICITLY, and this
#      stage re-reads it back out of the installed file rather than trusting a
#      redirect.
#
#   2. TWO PRESSES PER PRESS MEANS TWO SUSPEND REQUESTS, the second landing at
#      or just after resume -- an immediate re-suspend loop, on a device whose
#      only other escape is a ten-second hardware hold. Indistinguishable from
#      a Deck that will not wake. So the duplicate is removed FIRST, and the
#      handler is enabled SECOND -- in the file layout, in the order this stage
#      writes, and in the order the undo instructions it prints undo them.
#
# This independently reproduces Valve's own answer: on Jupiter and Galileo they
# blacklist the ACPI power button by name (STEAMOS_POWER_BUTTON_IGNORE=1 in
# steamos-power-button.hwdb) so their powerbuttond binds the real key instead.
# Two routes, one conclusion (T13 §4.1).
readonly POWER_UDEV_TAG=power-switch

# The upstream rule that ADDS the tag. Ours must be read after it: "-=" removes
# a value from a list, so a rule that runs first removes nothing at all and
# leaves both sources live -- a silent no-op that ends in trap 2 above.
readonly POWER_UDEV_TAGGER=70-power-switch.rules

# udev reads *.rules from every rules directory as ONE filename-sorted
# sequence, and systemd-logind reads logind.conf.d/*.conf the same way with
# later files winning. Both names below are 'zz-' for the reason SDDM_DROPIN is
# (see the BUG FIX note above it): a numeric prefix that was *documented* as
# sorting last did not, and nobody checked. verify_power_button_ordering checks
# these two against the files actually on disk rather than trusting this
# comment -- which is the part that comment lacked.
readonly POWER_UDEV_RULE=/etc/udev/rules.d/zz-deck-power-button.rules
readonly POWER_LOGIND_DROPIN=/etc/systemd/logind.conf.d/zz-deck-power-button.conf

# Searched for rivals, in the ordering check. Both tools merge every directory
# into one sort by BASENAME, so a rival in any of them can win.
readonly -a POWER_UDEV_DIRS=(/etc/udev/rules.d /run/udev/rules.d /usr/lib/udev/rules.d)
readonly -a POWER_LOGIND_DIRS=(/etc/systemd/logind.conf.d /run/systemd/logind.conf.d /usr/lib/systemd/logind.conf.d)

# BOTH ACPI nodes, not only the one measured firing. acpi-PNP0C0C:00 was silent
# across all three presses -- but it advertises KEY_POWER and carries the tag,
# so it is a second source waiting for a firmware or kernel change to wake it.
# Untagging a node that emits nothing costs exactly nothing; leaving it costs
# the suspend loop in trap 2 if it ever starts emitting. The costs are wildly
# asymmetric, so both go.
#
# The Lid Switch (acpi-PNP0C0D:00, event1) is deliberately NOT here. The same
# upstream rule tags it, logind's HandleLidSwitch= is a different question, and
# nothing about the lid was measured. This stage changes the power key only.
POWER_ACPI_ID_PATHS=(acpi-LNXPWRBN:00 acpi-PNP0C0C:00)
readonly POWER_ACPI_ID_PATHS

# The single source left standing. If this node is missing or untagged, then
# untagging the ACPI ones leaves logind watching NOTHING and the power button
# becomes dead rather than fixed -- so it is checked before anything is written.
readonly POWER_KEEP_ID_PATH=platform-i8042-serio-0

# HandlePowerKeyLongPress= is set EXPLICITLY to systemd's own default rather
# than left to inherit, for the same reason HandlePowerKey= is: this file
# should say what the Deck does, not depend on what else lands in the
# directory. `ignore` and not `poweroff`, on three grounds:
#
#   - The threshold is UNKNOWN. systemd's LONG_PRESS_DURATION has never been
#     read from source, and SteamOS's 1 s is powerbuttond's alarm(1) -- a
#     different program (T13 §4.0, §4.1). No number appears anywhere in this
#     stage on purpose; do not import one from the other.
#   - A long-press power off would shadow the ten-second hardware hold that
#     docs/RECOVERY.md documents as the escape of last resort, with an abrupt
#     poweroff at an unknown, earlier moment.
#   - It would fire for real here, unlike on most hardware: event4 does track
#     holds. That makes it a live hazard rather than a dead setting.
readonly POWER_KEY_ACTION=suspend
readonly POWER_KEY_LONG_PRESS_ACTION=ignore

# Only verified hardware. Every measurement above was taken on an OLED
# (Galileo); an LCD (Jupiter) may enumerate its power button differently, and
# CLAUDE.md forbids claiming LCD support that has not been tested. An ungated
# rule that misfires on hardware nobody has measured is worse than no rule --
# see verify_power_button_model for the argument in full.
readonly POWER_MODEL=Galileo
readonly POWER_DMI_PRODUCT=/sys/class/dmi/id/product_name

# 🔴 The interaction that could strand the operator, and it is NOT this stage's
# to fix: suspend on this Deck must resume UNLOCKED, deliberately, because the
# device has no keyboard (T5 §5.6, T13 §5.3). That holds only while
# omarchy-sleep-lock.service stays masked -- it is what locks the screen on
# PrepareForSleep. Making the power button suspend while that unit is live
# turns every press into an unanswerable password prompt (blast-radius R2 in
# T13 §7), so the stage says so out loud before it finishes.
#
# ⚠️ THE UNIT AND ITS MASK PATH ARE DECLARED ONCE, WAY ABOVE, as SLEEP_LOCK_UNIT
# and SLEEP_LOCK_GLOBAL_MASK -- read the WHY there. This block used to redeclare
# both, and used to say the mask was "HAND-APPLIED on the test Deck and not
# shipped from src/ at all". That expired: install_sleep_lock_mask ships it from
# stage-desktop-settings. What has NOT changed is that this stage must still
# check rather than assume -- the stages can be run one at a time, and a Deck
# whose power button suspends before its mask is installed is the bad ordering.
#
# The search path, in systemd's own precedence order, for answering "is it
# masked HERE" rather than "did we install ours". ~/.config/systemd/user comes
# ahead of all three and is per-user, so it is not in this list.
readonly -a SLEEP_LOCK_UNIT_DIRS=(/etc/systemd/user /usr/local/lib/systemd/user /usr/lib/systemd/user)

readonly -a INSTALL_STAGES=(
  stage-preconditions
  stage-session-select
  stage-steam-hook
  stage-update-stub
  stage-timezone-helper
  stage-priv-write-helper
  stage-greeter-rotation
  stage-sddm-resilience
  stage-return-icon
  # Immediately after the .desktop entry, and the adjacency is the point: the
  # two halves of "return to Gaming Mode" run the same command string, and
  # stage-menu-row asserts that they still agree before it writes anything. Run
  # apart, a drift in one would be found by whichever ran second, later.
  stage-menu-row
  stage-input-mapper
  # Immediately after the mapper, and the adjacency is the point: this stage
  # turns lizard mode off only for as long as deck-input-mapper.service runs,
  # so it installs a drop-in for a unit that must already exist. Ordering it
  # before the mapper would install a fallback for nothing.
  stage-lizard-mode
  stage-desktop-settings
)

log()  { printf '[%s] %s\n' "$PROG" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$PROG" "$*" >&2; }
fail() { printf '[%s] ERROR: %s\n' "$PROG" "$*" >&2; exit 1; }
usage_error() { printf '[%s] usage: %s\n' "$PROG" "$*" >&2; exit 2; }

SUDO=""
INTERACTIVE=1
[[ -t 0 ]] || INTERACTIVE=0

# ---------------------------------------------------------------------------

stage_preconditions() {
  local tool
  for tool in systemctl install findmnt; do
    command -v "$tool" >/dev/null 2>&1 ||
      fail "required tool '$tool' not found"
  done

  if [[ $EUID -eq 0 ]]; then
    SUDO=""
  else
    command -v sudo >/dev/null 2>&1 || fail "not root and sudo not found"
    SUDO="sudo"
    if ! $SUDO -n true 2>/dev/null; then
      # The fallback reads its password from /dev/tty, so redirecting stdin
      # does not disarm it. Only reach it when there is a human present.
      [[ $INTERACTIVE -eq 1 ]] ||
        fail "sudo needs a password and this is a non-interactive run. Re-run as root, or configure NOPASSWD, or run with a terminal attached."
      $SUDO true || fail "sudo escalation failed -- re-run as root"
    fi
  fi

  # Deck hardware gate. Same reasoning as omarchy-deck-kernel.sh: only OLED
  # (Galileo) is verified hardware, but refusing to run on an LCD (Jupiter)
  # is worse than running untested, and nothing downstream claims LCD support.
  local product="" vendor=""
  [[ -r /sys/class/dmi/id/product_name ]] && product=$(</sys/class/dmi/id/product_name)
  [[ -r /sys/class/dmi/id/sys_vendor ]]   && vendor=$(</sys/class/dmi/id/sys_vendor)
  if ! [[ ${product,,} =~ (steam\ deck|jupiter|galileo) || ${vendor,,} == *valve* ]]; then
    fail "not Steam Deck hardware (product='${product:-?}' vendor='${vendor:-?}'). Refusing to rewrite session configuration."
  fi
  log "hardware: ${vendor:-unknown} ${product:-unknown}"

  # SDDM is the switching mechanism. Without it there is nothing to restart.
  systemctl list-unit-files sddm.service --no-pager 2>/dev/null | grep -q sddm ||
    fail "sddm.service not found. This script switches sessions by restarting the display manager and supports SDDM only (which is what Omarchy installs)."

  # The Gaming Mode session must already exist -- we do not build one.
  # Checked by *file*, not by package, so a differently-packaged gamescope
  # still satisfies it.
  local found="" d
  for d in /usr/share/wayland-sessions /usr/local/share/wayland-sessions; do
    [[ -f "$d/${GAMING_SESSION}.desktop" ]] && { found="$d/${GAMING_SESSION}.desktop"; break; }
  done
  # NOTE the qualified package name in the message. `pacman -S gamescope`
  # installs ARCH's build, which is the bare compositor and ships none of this
  # -- pacman resolves by repo order, not version, and Arch's repos come first
  # by design (PROGRESS.md 5.13, docs/findings/P16-repo-overlap-audit.md).
  # Arch's is 3.16.25-1, Valve's is 3.16.25-3: same upstream version, so a
  # version check would not tell them apart. Checking for the session FILE is
  # what distinguishes them, which is why this test is written this way.
  [[ -n $found ]] ||
    fail "no ${GAMING_SESSION}.desktop in any wayland-sessions directory. Install Valve's build explicitly -- 'sudo pacman -S jupiter-staging/gamescope' -- because a bare 'pacman -S gamescope' installs Arch's bare compositor, which ships no SteamOS session. Then re-run."
  log "gaming session: ${found}"

  # The launcher the session entry points at has to exist too -- a dangling
  # Exec= is exactly the silent failure this project exists to prevent.
  command -v start-gamescope-session >/dev/null 2>&1 ||
    fail "${found} exists but start-gamescope-session is not on PATH -- the gamescope install is incomplete, or the session file came from somewhere other than Valve's package. Reinstall with 'sudo pacman -S jupiter-staging/gamescope'. Do not switch sessions until this resolves."

  # Resolve the desktop session by discovery. Omarchy ships its own entry in
  # /usr/local/share, which is why this is not hardcoded.
  local cand
  for d in /usr/local/share/wayland-sessions /usr/share/wayland-sessions; do
    for cand in omarchy hyprland-uwsm hyprland; do
      if [[ -f "$d/${cand}.desktop" ]]; then DESKTOP_SESSION=$cand; break 2; fi
    done
  done
  [[ -n $DESKTOP_SESSION ]] ||
    fail "found no desktop session (.desktop for omarchy/hyprland-uwsm/hyprland) in any wayland-sessions directory"
  log "desktop session: ${DESKTOP_SESSION}"

  # DeckShift is deliberately not supported alongside this. Both install a
  # steamos-session-select and both write an SDDM drop-in; whichever ran last
  # wins, which is not a state anyone can reason about. Warn rather than fail
  # so this stage stays a pure probe.
  if [[ -e /usr/local/bin/switch-to-gaming || -e /usr/local/bin/gaming-session-switch ]]; then
    warn "DeckShift appears to be installed (/usr/local/bin/switch-to-gaming). This project ships its own session layer and does not use it -- see PROGRESS.md 2.4. Remove DeckShift before relying on these stages, or the two will fight over SDDM's session and Steam's hook."
  fi

  # mangoapp is only Wants= in the unit graph, so its absence is not fatal --
  # but the session exports STEAM_USE_MANGOAPP=1, so the performance overlay
  # would be silently dead. Warn, do not fail.
  command -v mangoapp >/dev/null 2>&1 ||
    warn "mangoapp not found (install mangohud) -- Gaming Mode's performance overlay will not work, though the session will still start"

  log "stage-preconditions: ok"
}

# ---------------------------------------------------------------------------

# Refuse to overwrite a file this script did not write.
#
# If a package ever lands one of these paths for real -- SteamOS's own
# customizations, or a future jupiter-* package -- its version is the
# authoritative one and quietly replacing it with ours would be the wrong
# outcome, in a place nobody would think to look. Fail loudly instead and let
# a human decide.
assert_ours_or_absent() {
  local path=$1 whose=$2
  # Matched on the bare text, so a file using any comment prefix is recognised.
  if $SUDO test -e "$path" && ! $SUDO grep -qF -- "$INSTALL_MARKER_TEXT" "$path" 2>/dev/null; then
    fail "${path} exists but was not written by ${PROG}.sh -- ${whose} owns it. Inspect it rather than overwriting it."
  fi
}

# Prove the NOPASSWD grant actually works.
#
# BUG FIX: the previous version probed with a warm sudo credential cache, so
# it passed whether or not the sudoers rule had parsed -- a check that only
# passes because of ambient state is worse than no check. Clear the cache
# first, and be honest about the case where the answer is unprovable.
verify_nopasswd() {
  local bin=$1 user=$2
  [[ $EUID -ne 0 ]] || return 0   # already root; nothing to prove

  # -K removes the cached timestamp entirely, so the probe below cannot
  # succeed on a credential someone else established.
  sudo -K 2>/dev/null || true

  # `sudo -n -l <cmd>` asks "may I run this without a password" WITHOUT
  # running it -- safer than invoking the target just to read its error text.
  if ! sudo -n -l "$bin" >/dev/null 2>&1; then
    fail "installed ${SUDOERS_FILE} but '${bin}' is still not invokable passwordless. Inspect that file; sudo would not confirm the grant."
  fi

  # Honesty check. If this user already has blanket NOPASSWD, the probe above
  # would have passed no matter what we wrote, so it proves nothing about our
  # drop-in. Say that rather than claiming a verified grant.
  if sudo -n -l /usr/bin/true >/dev/null 2>&1; then
    warn "this user already has broad passwordless sudo, so the check above does NOT prove ${SUDOERS_FILE} is what granted access. The grant is installed but unverified."
  else
    log "verified: ${user} can invoke it without a password, via ${SUDOERS_FILE}"
  fi

  # Re-establish credentials the probe just cleared, so later stages in the
  # same run do not hit an unexpected prompt.
  if [[ $INTERACTIVE -eq 1 ]]; then
    sudo -v 2>/dev/null || true
  fi
}

stage_session_select() {
  log "installing ${SELECT_BIN}"

  # Resolved here, not at switch time, and baked into the generated shim.
  # SDDM's [Autologin] needs BOTH User= and Session=; with Session= alone it
  # ignores the block entirely and shows the greeter (found on hardware,
  # P1.5 phase F -- docs/findings/P15-live-iso-recon.md R-16). Deriving the
  # user inside the shim from $SUDO_USER would write User=root whenever the
  # shim is reached from a root context, i.e. a root graphical autologin.
  # The autologin user is a property of the machine, so decide it at install.
  local invoking_user=${SUDO_USER:-${USER:-$(id -un)}}
  [[ -n $invoking_user && $invoking_user != root ]] ||
    fail "cannot determine the unprivileged user to autologin (got '${invoking_user}'). Re-run as that user with sudo, not as root directly."

  local tmp
  tmp=$(mktemp) || fail "mktemp failed"

  cat >"$tmp" <<EOF
#!/usr/bin/env bash
# deck-session-select -- switch the Deck between Gaming Mode and the desktop.
# Installed by ${PROG}.sh. Runs as root (see the sudoers drop-in).
#
# Usage: deck-session-select {gamescope|desktop} [--no-restart]
set -euo pipefail

GAMING_SESSION=${GAMING_SESSION}
DESKTOP_SESSION=${DESKTOP_SESSION}
SDDM_DROPIN=${SDDM_DROPIN}
STATE_FILE=${STATE_FILE}

die() { printf 'deck-session-select: %s\n' "\$*" >&2; exit 1; }

[[ \$EUID -eq 0 ]] || die "must run as root (invoke via sudo)"

restart=1
target=""
while [[ \$# -gt 0 ]]; do
  case \$1 in
    gamescope|gaming|gamescope-wayland) target=\$GAMING_SESSION ;;
    desktop|plasma|omarchy)             target=\$DESKTOP_SESSION ;;
    --no-restart)                       restart=0 ;;
    *) die "unknown argument '\$1' (expected: gamescope | desktop [--no-restart])" ;;
  esac
  shift
done
[[ -n \$target ]] || die "no session specified (expected: gamescope | desktop)"

# Verify the target session actually exists before committing to it. Writing
# a Session= that SDDM cannot resolve produces a login loop with no desktop
# and, under autologin, no session picker to escape with.
found=""
for d in /usr/local/share/wayland-sessions /usr/share/wayland-sessions; do
  [[ -f "\$d/\${target}.desktop" ]] && { found="\$d/\${target}.desktop"; break; }
done
[[ -n \$found ]] || die "target session '\${target}' has no .desktop in any wayland-sessions directory -- refusing to write a config that cannot log in"

install -d -m 0755 "\$(dirname "\$STATE_FILE")"
printf '%s\n' "\$target" >"\$STATE_FILE"

# Autologin Session= is the switch. The drop-in is named to sort LAST in
# /etc/sddm.conf.d, so it wins over any other autologin config without
# editing a file we do not own. See the SDDM_DROPIN comment in ${PROG}.sh --
# an earlier name sorted *before* autologin.conf and silently never applied.
#
# User= is required, not optional: SDDM applies [Autologin] only when BOTH
# User= and Session= are present. An earlier version wrote Session= alone on
# the assumption that Omarchy supplied User= from its own autologin.conf --
# Omarchy 4.0 ships no such file, so autologin never fired and every switch
# landed on the greeter instead (P1.5 phase F, R-16).
install -d -m 0755 "\$(dirname "\$SDDM_DROPIN")"
cat >"\$SDDM_DROPIN" <<INNER
# Written by deck-session-select. Do not edit by hand -- rewritten on every
# session switch. Named to sort last in /etc/sddm.conf.d so Session= wins.
[Autologin]
User=${invoking_user}
Session=\${target}
# Relogin=true, and this is a SAFETY property, not a convenience (PROGRESS.md
# 5.18). SDDM ships Relogin=false in /usr/lib/sddm/sddm.conf.d/default.conf,
# which means autologin fires ONCE: if that session dies, SDDM shows the
# greeter. Measured on hardware, soak cycle 4 --
#
#   Starting Wayland user session: "uwsm start ... Hyprland"
#   Session started true
#   session closed for user deck        <- one millisecond later
#   Adding new display...               <- the greeter
#
# On a Deck that greeter is a password prompt with no keyboard to answer it,
# i.e. an unrecoverable state, which CLAUDE.md's controller-only rule forbids.
# Retrying autologin is the same tradeoff already taken in
# stage-sddm-resilience: a loop that can still recover beats a dead end that
# cannot. If the session is genuinely broken this loops -- that is a dev-time
# failure, visible in the journal, with Ctrl+Alt+F2 as the escape.
Relogin=true
INNER

# Verify the write landed rather than trusting the redirect. All three keys are
# checked: Session= alone is the exact silent failure this stage exists to
# avoid, so a drop-in missing User= must be treated as a failed write, and
# without Relogin= a dead session strands the user at a password prompt.
grep -q "^Session=\${target}\$" "\$SDDM_DROPIN" ||
  die "wrote \$SDDM_DROPIN but Session=\${target} is not there on re-read"
grep -q "^User=${invoking_user}\$" "\$SDDM_DROPIN" ||
  die "wrote \$SDDM_DROPIN but User=${invoking_user} is not there on re-read -- SDDM ignores [Autologin] without it"
grep -q "^Relogin=true\$" "\$SDDM_DROPIN" ||
  die "wrote \$SDDM_DROPIN but Relogin=true is not there on re-read -- without it a session that dies leaves a password greeter no controller can answer"

printf 'deck-session-select: next session is %s (%s)\n' "\$target" "\$found"

if [[ \$restart -eq 1 ]]; then
  printf 'deck-session-select: handing the sddm restart to ${SWITCH_UNIT}.service\n'
  # NOT \`systemctl restart sddm\` from here. That is what PROGRESS.md 5.16 is
  # about, and the reason is measured, not theoretical -- see
  # render_restart_helper. Two things make running it inline wrong:
  #
  #   1. sddm's KillMode=control-group means this process is inside the cgroup
  #      the stop is about to kill. The caller dies mid-restart.
  #   2. \`restart\` issues the start as soon as the stop job finishes -- 3ms
  #      after a SIGKILL, in the failure that was recorded -- so the new sddm
  #      races a VT the killed compositor has not released.
  #
  # A transient unit lives in system.slice, so it survives the teardown and can
  # sequence stop -> settle -> start properly.

  # Clear any stale unit from a previous switch so --unit= cannot collide.
  # --collect should already have removed it; this is belt and braces.
  systemctl reset-failed ${SWITCH_UNIT}.service 2>/dev/null || true

  systemd-run --collect --quiet \\
    --unit=${SWITCH_UNIT} \\
    --description='deck-session-select: sddm restart for a session switch' \\
    ${RESTART_HELPER} ||
      die "could not launch ${SWITCH_UNIT}.service; the session was NOT switched. The next-session state is already written, so a reboot will land in \$target."
fi
EOF

  $SUDO install -m 0755 -o root -g root "$tmp" "$SELECT_BIN" ||
    fail "could not install ${SELECT_BIN}"
  rm -f "$tmp"
  $SUDO test -x "$SELECT_BIN" || fail "${SELECT_BIN} is not executable after install"

  # --- the restart helper the transient unit runs ---
  assert_ours_or_absent "$RESTART_HELPER" "something else"
  log "installing ${RESTART_HELPER}"
  $SUDO install -d -m 0755 -o root -g root "$(dirname "$RESTART_HELPER")" ||
    fail "could not create $(dirname "$RESTART_HELPER")"
  tmp=$(mktemp) || fail "mktemp failed"
  render_restart_helper "$invoking_user" >"$tmp" ||
    fail "could not render the sddm restart helper"
  $SUDO install -m 0755 -o root -g root "$tmp" "$RESTART_HELPER" ||
    fail "could not install ${RESTART_HELPER}"
  rm -f "$tmp"
  $SUDO test -x "$RESTART_HELPER" || fail "${RESTART_HELPER} is not executable after install"

  # systemd-run is how the restart escapes sddm's cgroup. Without it the switch
  # silently falls back to nothing at all, so check now rather than at 2am.
  command -v systemd-run >/dev/null 2>&1 ||
    fail "systemd-run not found; ${SELECT_BIN} needs it to restart sddm outside the session being torn down"

  # --- sudoers drop-in, validated before installation ---
  # invoking_user is resolved and guarded at the top of this stage, where the
  # autologin drop-in needs it too.
  log "granting ${invoking_user} NOPASSWD on ${SELECT_BIN} only"
  tmp=$(mktemp) || fail "mktemp failed"
  cat >"$tmp" <<EOF
# Installed by ${PROG}.sh. Lets the desktop user switch between Gaming Mode
# and the desktop, which requires restarting the display manager.
#
# Scoped to exactly one root-owned 0755 binary and nothing else. See the
# SECURITY TRADEOFF note in ${PROG}.sh before widening this.
${invoking_user} ALL=(root) NOPASSWD: ${SELECT_BIN}
EOF

  # A malformed sudoers file breaks sudo for everyone. Never install one
  # unvalidated -- check the candidate file itself, before it is in place.
  $SUDO visudo -c -f "$tmp" >/dev/null ||
    fail "generated sudoers snippet failed validation -- refusing to install it. Candidate left at ${tmp}"

  $SUDO install -m 0440 -o root -g root "$tmp" "$SUDOERS_FILE" ||
    fail "could not install ${SUDOERS_FILE}"
  rm -f "$tmp"

  verify_nopasswd "$SELECT_BIN" "$invoking_user"

  log "stage-session-select: ok"
}

# ---------------------------------------------------------------------------

# The body of the transient unit that actually restarts sddm. Written to
# stdout; split out so test/unit/test-deck-session.sh can check its shape with
# no Deck, no root and no VM, the same way render_update_stub is.
#
# WHY THIS EXISTS AT ALL -- measured on hardware, PROGRESS.md 5.16 / R-26:
#
#   13:11:02.815  sddm: Signal received: SIGTERM
#   13:11:07.822  sddm: sddm-helper (start-gamescope-session) crashed (exit code 1)
#   13:11:07.823  systemd: sddm.service: State 'stop-sigterm' timed out. Killing.
#   13:11:07.823  systemd: Killing process 939 (sddm) with signal SIGKILL
#   13:11:07.826  systemd: sddm.service: Failed with result 'timeout'
#   13:11:07.830  systemd: Started Simple Desktop Display Manager      <- +3ms
#   13:11:11      systemd: Start request repeated too quickly -> start-limit-hit
#
# The teardown did not fit in sddm's TimeoutStopSec=5, so systemd killed it and
# started the replacement three milliseconds later, against a VT the killed
# compositor still held. The greeter crashed, Restart=always retried, and
# StartLimitBurst=2 latched the unit to failed -- no graphical session, and on
# the product no way back.
#
# NOTE this corrects R-26's own account of the fix. It called RestartSec=3 "the
# more important half", reasoning that at 100ms every retry lands before the VT
# is free. RestartSec does not gate this at all: the fatal start came from an
# explicit `systemctl restart` transaction, and RestartSec only spaces
# Restart=always auto-restarts. That is why the gap was 3ms and not 100ms. The
# shipped drop-in helps the retry path; it never touched the cause.
#
# Takes the desktop user as $1. It has a default so the unit suite can render
# this without a Deck: relying on stage_session_select's `local invoking_user`
# being visible through bash's dynamic scoping would work when called from
# there and blow up under `set -u` when called directly.
render_restart_helper() {
  local session_user=${1:-${SUDO_USER:-${USER:-$(id -un)}}}
  cat <<EOF
#!/usr/bin/env bash
#
# restart-sddm -- stop sddm, wait for the seat to be free, start it again.
${INSTALL_MARKER}
#
# Run as a transient systemd unit (${SWITCH_UNIT}.service) launched by
# deck-session-select, NOT inline. sddm's KillMode=control-group would
# otherwise kill the caller mid-restart, because a session switch is issued
# from inside the session being torn down.
#
# The sequence is stop -> settle -> start rather than \`systemctl restart\`
# precisely so the start cannot be issued while the previous compositor still
# holds the VT. See deck-session.sh's render_restart_helper for the journal
# extract this is built from.
#
set -uo pipefail

note() {
  printf 'restart-sddm: %s\n' "\$1" >&2
  command -v logger >/dev/null 2>&1 && logger -t restart-sddm -- "\$1"
  return 0
}

# Blocking: systemd does not return until the stop job is done, including the
# SIGKILL fallback. With TimeoutStopSec raised to ${SDDM_STOP_TIMEOUT}s in the
# drop-in, this is normally a clean teardown rather than a kill.
if ! systemctl stop sddm; then
  note "'systemctl stop sddm' reported failure; continuing to the start anyway, because leaving the device with no display manager is the worse outcome"
fi

# The stop job is complete, but the outgoing graphical session can still be
# unwinding. TWO conditions, because either alone is not enough:
#
#   1. logind has dropped the seat's sessions. Not fuser -- systemd-logind
#      holds /dev/tty1 permanently, so fuser reports the VT busy forever.
#   2. no compositor process remains for the desktop user.
#
# (2) was added after PROGRESS.md 5.18: on soak cycle 4 the seat list was
# already empty while the previous session's uwsm/Hyprland was still exiting,
# sddm started the next session into that, and it died one millisecond later.
# An empty seat list is NOT the same as the outgoing session being finished.
session_user=${session_user}

# ⚠️ THESE ARE comm NAMES, MEASURED ON HARDWARE -- NOT BINARY NAMES.
#
# The kernel truncates comm to 15 characters (TASK_COMM_LEN), and \`pgrep -x\`
# matches against comm. An earlier version of this gate listed 'gamescope' and
# was a NO-OP for the whole Gaming Mode direction:
#
#   inside a live gamescope session, \`pgrep -u deck -x gamescope\` returns 0
#   the compositor's comm is 'gamescope-wl'; its launcher is 'start-gamescope'
#   (truncated from start-gamescope-session)
#
# A gate that matches nothing reports "settled" instantly and looks like it is
# working, which is precisely the silent success this project exists to avoid.
# Verified present, per session:
#   desktop  -> Hyprland, start-hyprland, uwsm  (also quickshell, omarchy-hyprlan)
#   gaming   -> gamescope-wl, start-gamescope
# Re-measure with \`ps -u <user> -o comm= | sort -u\` before editing this list.
# THIRD condition, and the one that addresses PROGRESS.md 5.18(a)'s root cause.
#
# R-28: steam-launcher.service is PartOf=graphical-session.target with
# TimeoutStopSec=60, and Steam takes tens of seconds to exit -- measured at ~29s
# with NO "Stopped Steam Launcher" line in between, while every other unit stops
# in ~50ms. It is a UNIT IN THE USER MANAGER, so neither of the two conditions
# above can see it: it owns no logind session and its processes are not named
# after a compositor. Starting sddm into that window is what makes the incoming
# session's \`uwsm start ... Hyprland\` exit in ~1ms.
#
# Asked generally (any deactivating unit) rather than by name, because
# steam-launcher is simply the slowest example rather than a special case.
user_manager_busy() {
  local out
  # A user manager that is not running is legitimately "nothing to wait for",
  # and errors here must not hang the switch -- but they must not be invisible
  # either, so the outcome is reported in the settle note below.
  out=\$(systemctl --machine="\${session_user}@.host" --user \\
          list-units --state=deactivating --no-legend 2>/dev/null) || {
    USER_MANAGER_QUERY_OK=0
    return 1
  }
  USER_MANAGER_QUERY_OK=1
  [[ -n \$out ]]
}

outgoing_gone() {
  [[ -z \$(loginctl show-seat seat0 -p Sessions --value 2>/dev/null) ]] || return 1
  # -x: exact comm match, so this cannot match a window title or a wrapper
  # script whose command line merely mentions one of them. -f would.
  pgrep -u "\$session_user" -x 'Hyprland|start-hyprland|gamescope-wl|start-gamescope|uwsm' >/dev/null 2>&1 && return 1
  user_manager_busy && return 1
  return 0
}

settled=0
i=0
USER_MANAGER_QUERY_OK=-1   # -1 = never attempted, 0 = failed, 1 = succeeded
while [[ \$i -lt ${VT_SETTLE_MAX} ]]; do
  if outgoing_gone; then
    settled=1
    break
  fi
  i=\$((i + 1))
  sleep 0.1
done

# The user-manager query is the condition that addresses 5.18(a)'s cause, so a
# silently failing one would quietly restore the old behaviour. Say which.
case \${USER_MANAGER_QUERY_OK} in
  0) note "could not query \${session_user}'s systemd user manager, so the steam-launcher teardown check (PROGRESS.md 5.18a / R-28) did NOT run. The switch will still work, but the autologin thrash can return." ;;
esac

if [[ \$settled -eq 1 ]]; then
  note "outgoing session gone after \$((i / 10)).\$((i % 10))s; starting sddm"
else
  # Loud, and then proceed anyway. A stuck seat is still better answered by
  # starting sddm than by leaving the device with nothing -- this whole file
  # exists because the device was left with nothing.
  note "outgoing session was STILL present after ${VT_SETTLE_MAX} tenths of a second; starting sddm anyway. steam-launcher.service is the usual reason (R-28) -- check 'journalctl _PID=\$(pgrep -u \${session_user} -x systemd)' for a 'Stopping Steam Launcher...' with no matching 'Stopped'."
fi

if ! systemctl start sddm; then
  note "'systemctl start sddm' FAILED -- the device may have no graphical session. Recover with: systemctl reset-failed sddm && systemctl start sddm"
  exit 1
fi
EOF
}

# ---------------------------------------------------------------------------

stage_steam_hook() {
  # Steam's Power -> Switch to Desktop runs `steamos-session-select desktop`.
  # Providing it under that exact name is what makes Steam's own affordance
  # work, which matters because it is the controller-reachable one.
  #
  assert_ours_or_absent "$STEAM_SHIM" "something else (DeckShift? SteamOS's steamos-customizations?)"

  # Steam invokes this unprivileged, so the shim escalates on its own via the
  # narrowly-scoped sudoers grant from stage-session-select. A plain symlink
  # would not work: sudo has to be in the call path.
  log "installing Steam's Switch-to-Desktop hook: ${STEAM_SHIM}"
  local wrapper
  wrapper=$(mktemp) || fail "mktemp failed"
  render_steam_shim >"$wrapper" ||
    fail "could not render the steamos-session-select shim"
  $SUDO install -m 0755 -o root -g root "$wrapper" "$STEAM_SHIM" ||
    fail "could not install ${STEAM_SHIM}"
  rm -f "$wrapper"

  # MIGRATION. The shim used to live in /usr/local/bin, where Steam cannot see
  # it. Remove our old copy so exactly one exists and nobody debugging this
  # later has to work out which is live.
  if $SUDO test -e "$STEAM_SHIM_LEGACY"; then
    if $SUDO grep -qF -- "$INSTALL_MARKER_TEXT" "$STEAM_SHIM_LEGACY" 2>/dev/null; then
      log "removing our old, Steam-unreachable copy: ${STEAM_SHIM_LEGACY}"
      $SUDO rm -f "$STEAM_SHIM_LEGACY" ||
        fail "could not remove ${STEAM_SHIM_LEGACY}"
    else
      warn "${STEAM_SHIM_LEGACY} exists and is not ours, so it is left alone. Be aware Steam cannot reach /usr/local/bin at all (its runtime PATH is ${STEAM_RUNTIME_PATH}), so whichever tool installed that file is probably broken in the same way this project was."
    fi
  fi

  # Verify Steam could FIND it, which is a different question from whether it
  # exists. Resolved against Steam's own PATH with a scrubbed environment, so a
  # /usr/local/bin on the operator's interactive PATH cannot make this pass.
  local resolved
  resolved=$(env -i PATH="$STEAM_RUNTIME_PATH" sh -c 'command -v steamos-session-select' 2>/dev/null) || resolved=""
  [[ -n $resolved ]] ||
    fail "installed ${STEAM_SHIM} but 'steamos-session-select' does not resolve on Steam's runtime PATH (${STEAM_RUNTIME_PATH}). Steam's Switch to Desktop would silently do nothing."
  log "verified: Steam can resolve it on PATH=${STEAM_RUNTIME_PATH} -> ${resolved}"

  log "stage-steam-hook: ok"
}

# The Steam-facing shim's body, written to stdout.
#
# Split out of stage_steam_hook so test/unit/test-deck-session.sh can reach it.
# It was the last generated file in this script still written as an inline
# heredoc, and the suite's own header flagged it as the remaining blind spot:
# its INSTALL_MARKER line was unverified, and the marker is what stops a re-run
# refusing to proceed (or clobbering somebody else's file). Session 16's
# mutation run confirmed the gap was real -- deleting that marker was the one
# fault the suite could not see.
#
# `exec sudo -n`, not plain sudo: this shim is the whole call path from Steam
# to ${SELECT_BIN}, and -n guarantees it can never block on a password prompt
# Steam has no way to render.
render_steam_shim() {
  cat <<EOF
#!/usr/bin/env bash
# steamos-session-select -- compatibility shim so Steam's "Switch to Desktop"
# works. Steam calls this unprivileged; the real work needs root.
${INSTALL_MARKER}
set -euo pipefail
exec sudo -n ${SELECT_BIN} "\$@"
EOF
}

# ---------------------------------------------------------------------------

stage_update_stub() {
  # Steam's first run in Gaming Mode reports "unable to download the required
  # updates -- please check your network connection (2)". The network is fine;
  # the error is a lie. What actually happens, from Steam's own logs:
  #
  #   YieldingCheckForUpdateOS: Command '... /usr/bin/steamos-polkit-helpers/steamos-update check ...' returned: 127
  #   YieldingApplyUpdateOS: applying OS update
  #   steamos-update returned: 127
  #   YieldingApplyUpdateOS: OS update result: 2
  #
  # 127 is "command not found": the whole ${POLKIT_HELPER_DIR} tree is absent,
  # because it belongs to SteamOS and this device is Arch + Omarchy. Steam
  # renders that as a network error and, during OOBE, will not proceed past it.
  #
  # No configured repo provides this binary. jupiter-hw-support ships six other
  # helpers but not this one, and steamos-customizations-jupiter ships none at
  # all (it is GRUB machinery, which the Limine-only constraint forbids anyway).
  # So there is nothing to install and the choice is between a stub and leaving
  # a false error on the first screen a user ever sees. Operator chose the stub
  # -- see PROGRESS.md 5.14.
  #
  # It is deliberately NOT a step toward a real updater. This device genuinely
  # cannot self-update the way SteamOS does (no RAUC, no A/B rootfs), and the
  # stub says so in its header, in --help, and in the journal.
  #
  # THE DESTINATION IS A PARAMETER -- see "THE VERIFICATION SEAM" above
  # verify_update_stub. Production passes nothing and gets ${UPDATE_STUB}.
  local stub=${1:-$UPDATE_STUB}
  assert_ours_or_absent "$stub" "a real SteamOS updater"

  log "installing the steamos-update stub: ${stub}"
  # dirname, not ${POLKIT_HELPER_DIR}: identical for the default, and it keeps
  # the directory that gets created and the file that lands in it in step.
  $SUDO install -d -m 0755 -o root -g root "$(dirname "$stub")" ||
    fail "could not create $(dirname "$stub")"

  local tmp
  tmp=$(mktemp) || fail "mktemp failed"
  render_update_stub >"$tmp" ||
    fail "could not render the steamos-update stub"

  $SUDO install -m 0755 -o root -g root "$tmp" "$stub" ||
    fail "could not install ${stub}"
  rm -f "$tmp"

  verify_update_stub "$stub"

  log "stage-update-stub: ok"
  log "NOTE: this stub updates nothing. Real updates: ${REAL_UPDATE_HINT}"
}

# ===========================================================================
# THE VERIFICATION SEAM -- read this before adding another verify_* function
# ===========================================================================
#
# Several stages verify their work by EXECUTING what they just installed, at
# the absolute path the real caller resolves. That is the strongest check
# available and it is why these stages are trusted -- but it also made them
# unreachable from test/unit/, because the absolute path is a readonly
# constant, so a suite running off-Deck would have had to execute the REAL
# /usr/bin/steamos-polkit-helpers/steamos-update (which exists on any machine
# with gamescope-session installed, and `exec pkexec`s).
#
# The fix, and its shape matters:
#
#   * The verification is a FUNCTION that takes the path to exercise. A test
#     passes a copy under a fake root, or a deliberately broken stub, and gets
#     the same checks run against it. This is the same move render_update_stub
#     made for generated text, for the same reason.
#   * The parameter DEFAULTS to the absolute constant, and every caller in this
#     file passes either nothing or the destination the stage just installed
#     to. On a Deck the behaviour is byte-for-byte what it was.
#   * Nothing here reads a path from the ENVIRONMENT. That was considered and
#     rejected for these paths in test/unit/test-deck-session.sh's header: an
#     env override would let a mis-set variable install a working-looking file
#     somewhere Steam never looks, which is the silent-failure class this whole
#     project exists to prevent, introduced by the test seam itself. A function
#     argument cannot be set by accident.
#   * There is NO "skip the check when handed a stub" branch anywhere below,
#     deliberately. A verification that can be turned off is not one.
#
# Exercise the installed stub. Steam depends on three exit codes and this
# stage's entire value is that they are checked by RUNNING the file rather than
# by trusting the write.
verify_update_stub() {
  local stub=${1:-$UPDATE_STUB}

  # `check` answering 7 is the single behaviour Steam's first-run flow depends
  # on.
  local rc=0
  "$stub" check >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 7 ]] ||
    fail "${stub} installed but 'check' exited ${rc}, not 7. Steam reads 7 as 'up to date'; anything else puts the first-run update dialog back."

  rc=0
  "$stub" --supports-duplicate-detection >/dev/null 2>&1 || rc=$?
  [[ $rc -ne 0 ]] ||
    fail "${stub} claims duplicate-detection support (exit 0). It does not implement it; that would make Steam depend on behaviour that is not there."

  # The apply path must NOT exit 0. This assertion is the whole reason it is
  # here: an earlier version of this stub exited 0, Steam read that as "update
  # applied", and rebooted the Deck to finish it -- once per OOBE pass.
  rc=0
  "$stub" >/dev/null 2>&1 || rc=$?
  [[ $rc -ne 0 ]] ||
    fail "${stub} exits 0 on the apply path. Steam reads 0 as 'an OS update was applied' and REBOOTS the device to complete it, on every first-run pass. It must report 'nothing to apply' (7) instead."

  log "verified: 'check' exits 7 (up to date), capability probe declines,"
  log "          apply exits ${rc} (non-zero, so Steam will not reboot)"
}

# The stub's body, written to stdout.
#
# Split out of stage_update_stub so test/unit/test-deck-session.sh can render
# it and execute the result with no root, no Deck and no VM. The exit codes
# below are a protocol Steam depends on, and two of them were settled by
# measurement on hardware rather than by reading Steam's docs -- see the case
# arms. The three assertions above still run against the really-installed file
# on a real Deck; the unit test is additive, not a replacement for them.
#
# Deliberately takes no path argument. UPDATE_STUB stays a readonly absolute
# because Steam resolves this helper by absolute path (see POLKIT_HELPER_DIR
# above); making it overridable would create a way to install a
# working-looking stub somewhere Steam never looks, which is the exact class
# of silent failure this file's header warns about.
render_update_stub() {
  cat <<EOF
#!/usr/bin/env bash
#
# steamos-update -- A STUB. IT UPDATES NOTHING.
${INSTALL_MARKER}
#
# WHY THIS EXISTS
#   Steam's Gaming Mode checks for OS updates by running this exact absolute
#   path. On SteamOS it is a real updater backed by RAUC and an A/B rootfs.
#   This device is not SteamOS -- it is Arch + Omarchy, updated with pacman --
#   so the path was missing, Steam got exit 127, and it told the user "unable
#   to download the required updates: check your network connection". That
#   message is alarming and false, and during first-run setup Steam will not
#   move past it.
#
# WHAT IT DOES
#   Answers "already up to date" and exits. It does not download, stage,
#   verify or apply anything, and it is not a partial implementation of
#   something that will.
#
# TO ACTUALLY UPDATE THIS SYSTEM
#   ${REAL_UPDATE_HINT}   (from Desktop Mode)
#
set -euo pipefail

# An unrecognised verb must not be answered silently -- this project exists
# partly because upstream tooling reported success while doing nothing. Steam
# discards our stderr, so the journal is the only place a human can find it.
note() {
  printf 'steamos-update (stub): %s\n' "\$1" >&2
  command -v logger >/dev/null 2>&1 && logger -t steamos-update-stub -- "\$1"
  return 0
}

case \${1-} in
  check)
    # 7 is SteamOS's "already up to date". Exit 0 would tell Steam an update
    # IS available, and it would immediately call us again to apply it --
    # ending in the same failure dialog by a longer route.
    exit 7
    ;;
  --supports-duplicate-detection)
    # A capability probe. We download nothing, so we cannot detect a duplicate
    # download; claiming the capability would invite Steam to depend on
    # behaviour that does not exist. Non-zero means "not supported", which is
    # what Steam already observed while this path was missing, so this keeps
    # it on the code path it has been using all along.
    exit 1
    ;;
  ""|apply)
    # The apply path -- 7 here too, and emphatically NOT 0.
    #
    # Exit 0 means "an update was applied", and Steam responds by REBOOTING to
    # finish it. Measured on hardware, not guessed:
    #
    #   YieldingApplyUpdateOS: applying OS update
    #   steamos-update returned: 0
    #   YieldingApplyUpdateOS: OS update result: 1
    #
    # followed straight away by systemd-reboot. During first-run setup Steam
    # calls apply DIRECTLY without checking first, so exit 0 rebooted the Deck
    # on every OOBE pass: a boot loop, caused by the stub meant to quiet a
    # cosmetic error. 7 says "nothing to apply", which leaves Steam with
    # nothing to finish and no reason to reboot.
    note "nothing to apply; this OS is updated with '${REAL_UPDATE_HINT}'"
    exit 7
    ;;
  -h|--help|help)
    cat <<'USAGE'
steamos-update (STUB) -- reports "up to date" and does nothing else.

This is NOT the real SteamOS updater. It exists so Steam's Gaming Mode stops
reporting a network error for a missing SteamOS binary. This device is Arch +
Omarchy; its OS does not update the way SteamOS's does.

  check                            exit 7 (already up to date)
  --supports-duplicate-detection   exit 1 (not supported)
  (no argument) | apply            exit 7 (nothing to apply). NOT 0 -- Steam
                                   reads 0 as "applied" and reboots.

To really update this system, from Desktop Mode:  ${REAL_UPDATE_HINT}
USAGE
    exit 0
    ;;
  *)
    # Answer as "up to date" rather than erroring: an unanticipated verb from
    # a future Steam client should not resurrect the first-run dialog. The
    # journal line above is how this stops being silent.
    note "unrecognised argument '\$1' -- answering 'up to date'. If Steam now depends on this verb, the stub needs extending."
    exit 7
    ;;
esac
EOF
}

# ---------------------------------------------------------------------------

stage_timezone_helper() {
  # Steam's OOBE timezone picker calls this once per highlighted entry --
  # 28 times in one pass on this hardware -- always with a single positional
  # argument, read from Steam's own log rather than guessed:
  #
  #   /usr/bin/steamos-polkit-helpers/steamos-set-timezone America/Chicago
  #
  # Without it every call returns 127 and the picker silently does nothing:
  # the user chooses a timezone, sees no error, and the clock stays wrong.
  #
  # THE DESTINATION IS A PARAMETER -- see "THE VERIFICATION SEAM" above
  # verify_update_stub. Production passes nothing and gets ${TIMEZONE_HELPER}.
  local helper=${1:-$TIMEZONE_HELPER}
  assert_ours_or_absent "$helper" "a real SteamOS helper"

  command -v "$TIMEDATECTL_BIN" >/dev/null 2>&1 ||
    fail "${TIMEDATECTL_BIN} not found; the timezone helper would install and then fail at runtime"

  log "installing the steamos-set-timezone helper: ${helper}"
  $SUDO install -d -m 0755 -o root -g root "$(dirname "$helper")" ||
    fail "could not create $(dirname "$helper")"

  local tmp
  tmp=$(mktemp) || fail "mktemp failed"
  render_timezone_helper >"$tmp" ||
    fail "could not render the steamos-set-timezone helper"
  $SUDO install -m 0755 -o root -g root "$tmp" "$helper" ||
    fail "could not install ${helper}"
  rm -f "$tmp"

  # --- the sudoers grant ---
  #
  # omarchy-settings-dev ALREADY ships an equivalent rule in
  # /etc/sudoers.d/omarchy-tzupdate, and the desktop user is in wheel, so this
  # helper would work with no grant of our own. We install one anyway,
  # deliberately: that file belongs to a package on a beta distro, and if it
  # changed the picker would go back to failing silently -- the exact defect
  # this stage exists to remove, in a place nobody would look. Duplicating one
  # narrow rule is cheap; sudo takes the last match and both say the same thing.
  #
  # ⚠️ THAT ARGUMENT WAS PROVEN RIGHT IN FOUR DAYS. Measured on this hardware
  # 2026-08-10, upstream's file read:
  #
  #   %wheel ALL=(root) NOPASSWD: /usr/bin/tzupdate, /usr/bin/timedatectl set-timezone *
  #
  # and upstream dropped the tzupdate half on 2026-08-11 (basecamp/omarchy
  # #6694, "Fix command injection in theme install, drop tzupdate NOPASSWD"):
  #
  #   %wheel ALL=(root) NOPASSWD: /usr/bin/timedatectl set-timezone *
  #
  # The half this stage depends on survived, so nothing here breaks -- but the
  # dependency was real and it moved. See PROGRESS.md 5.22.
  local invoking_user=${SUDO_USER:-${USER:-$(id -un)}}
  [[ -n $invoking_user && $invoking_user != root ]] ||
    fail "could not determine the desktop user (got '${invoking_user}'); run this as that user via sudo, not as root directly"

  log "granting ${invoking_user} NOPASSWD on '${TIMEDATECTL_BIN} set-timezone' only"
  tmp=$(mktemp) || fail "mktemp failed"
  cat >"$tmp" <<EOF
# Installed by ${PROG}.sh. Lets Steam's OOBE timezone picker set the system
# timezone from Gaming Mode, where there is no keyboard to answer a polkit
# admin prompt (org.freedesktop.timedate1.set-timezone defaults to
# auth_admin_keep, which is unanswerable on a controller).
#
# Scoped to one subcommand of one absolute path. Deliberately NOT the whole of
# timedatectl: set-time and set-ntp are not needed here.
${invoking_user} ALL=(root) NOPASSWD: ${TIMEDATECTL_BIN} set-timezone *
EOF
  $SUDO visudo -c -f "$tmp" >/dev/null ||
    fail "generated sudoers snippet failed validation -- refusing to install it. Candidate left at ${tmp}"
  $SUDO install -m 0440 -o root -g root "$tmp" "$TIMEZONE_SUDOERS" ||
    fail "could not install ${TIMEZONE_SUDOERS}"
  rm -f "$tmp"

  verify_timezone_helper "$helper"

  log "stage-timezone-helper: ok"
}

# Exercise the installed timezone helper. Takes the path for the reason set out
# in "THE VERIFICATION SEAM" above verify_update_stub.
verify_timezone_helper() {
  local helper=${1:-$TIMEZONE_HELPER}

  # Verify by running it, not by trusting the write -- and verify against the
  # timezone the machine is ALREADY set to, so a passing test changes nothing.
  local before after
  before=$(timedatectl show -p Timezone --value) ||
    fail "could not read the current timezone"
  "$helper" "$before" ||
    fail "${helper} failed setting the timezone to its current value (${before}). The helper installed but does not work; the picker would still fail silently."
  after=$(timedatectl show -p Timezone --value) ||
    fail "could not re-read the timezone after the helper ran"
  [[ $after == "$before" ]] ||
    fail "the helper changed the timezone from ${before} to ${after} while being asked for ${before}"

  # A bad timezone must be refused, not passed to timedatectl. Steam sends only
  # names out of its own list, but a helper that writes whatever it is handed
  # is not one worth having behind a sudo grant.
  local rc=0
  "$helper" ../../etc/shadow >/dev/null 2>&1 || rc=$?
  [[ $rc -ne 0 ]] ||
    fail "${helper} accepted a path-traversal timezone. It must validate against /usr/share/zoneinfo before elevating."

  log "verified: helper set the timezone to its existing value (${after}) and rejects a traversal argument"
}

# The timezone helper's body, written to stdout. Split out for the same reason
# render_update_stub is -- see the note above that function.
render_timezone_helper() {
  cat <<EOF
#!/usr/bin/env bash
#
# steamos-set-timezone -- set the system timezone for Steam's Gaming Mode.
${INSTALL_MARKER}
#
# WHY THIS EXISTS
#   Steam's first-run timezone picker runs this exact absolute path, once per
#   entry it highlights. On SteamOS it is one of Valve's polkit helpers. This
#   device is Arch + Omarchy, that tree does not exist here, and every call
#   returned 127 -- so the picker appeared to work and changed nothing.
#
# WHY IT USES sudo AND NOT polkit
#   timedatectl already speaks polkit, but org.freedesktop.timedate1's
#   set-timezone action defaults to auth_admin_keep: an admin password prompt.
#   In Gaming Mode there is no keyboard to answer it. A narrow sudoers grant
#   (see ${TIMEZONE_SUDOERS}) is the mechanism that works on a controller.
#
set -euo pipefail

note() {
  printf 'steamos-set-timezone: %s\n' "\$1" >&2
  command -v logger >/dev/null 2>&1 && logger -t steamos-set-timezone -- "\$1"
  return 0
}

tz=\${1-}

if [[ -z \$tz ]]; then
  note "called with no timezone argument"
  exit 2
fi

# Validate BEFORE elevating. The sudo grant below covers 'timedatectl
# set-timezone <anything>', so this check is the only thing standing between a
# caller-supplied string and a privileged command.
#
# Rejecting '..' explicitly: the zoneinfo test alone would already refuse a
# traversal, but failing on the shape of the argument gives a caller a
# comprehensible error instead of "no such timezone".
case \$tz in
  ..|../*|*/..|*/../*)
    note "refusing a timezone containing '..': '\${tz}'"
    exit 3
    ;;
  /*)
    note "refusing an absolute path as a timezone: '\${tz}'"
    exit 3
    ;;
esac

if [[ ! \$tz =~ ^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)*\$ ]]; then
  note "refusing a timezone with unexpected characters: '\${tz}'"
  exit 3
fi

# The authoritative check: it has to be a zone this system actually has.
if [[ ! -f /usr/share/zoneinfo/\${tz} ]]; then
  note "no such timezone on this system: '\${tz}'"
  exit 3
fi

if [[ \$EUID -eq 0 ]]; then
  exec ${TIMEDATECTL_BIN} set-timezone "\$tz"
fi

# -n so this can never block waiting for a password. Steam discards our
# stderr and would hang rather than show a prompt it cannot render.
#
# The refusal is distinguished from a timedatectl failure so the journal line
# names the right cause -- Steam discards stderr, so that line is the only
# place a human ever sees why the picker stopped working.
rc=0
sudo -n ${TIMEDATECTL_BIN} set-timezone "\$tz" || rc=\$?
if [[ \$rc -ne 0 ]]; then
  if ! sudo -n -l ${TIMEDATECTL_BIN} set-timezone "\$tz" >/dev/null 2>&1; then
    note "sudo will not run '${TIMEDATECTL_BIN} set-timezone' without a password, so the timezone cannot be set. Check ${TIMEZONE_SUDOERS}."
  else
    note "'${TIMEDATECTL_BIN} set-timezone \${tz}' failed with status \${rc}."
  fi
  exit 4
fi
EOF
}

# ---------------------------------------------------------------------------

stage_priv_write_helper() {
  # Tier 1 of the three-tier fallback documented in this file's header. See
  # that note before touching this: the point is NOT that brightness is broken
  # on this Deck (it works, via blanket sudo), it is that the fallbacks which
  # make it work must not ship.
  #
  # Signature, read from Steam's log rather than guessed -- two quoted
  # positional arguments, path then value:
  #
  #   steamos-priv-write "/sys/class/backlight/amdgpu_bl0/brightness" "39638"
  #   steamos-priv-write "/sys/class/leds/status:white/led_brightness_multiplier" "100"
  #   steamos-priv-write "/dev/drm_dp_aux0" ""
  #
  # The third is why this whitelists rather than writes what it is told: a DP
  # AUX channel is a display-link side band, Steam passes it an EMPTY value,
  # and what that does is not understood here. It is not whitelisted, so this
  # helper refuses it loudly. Steam already tolerates that refusal -- it has
  # been getting 127 for it all along.
  #
  # THE DESTINATION AND THE NODE IT IS VERIFIED AGAINST ARE PARAMETERS -- see
  # "THE VERIFICATION SEAM" above verify_update_stub. Production passes nothing
  # and gets ${PRIV_WRITE_HELPER} and ${DECK_BACKLIGHT}.
  local helper=${1:-$PRIV_WRITE_HELPER}
  local backlight=${2:-$DECK_BACKLIGHT}
  assert_ours_or_absent "$helper" "a real SteamOS helper"

  log "installing the steamos-priv-write helper: ${helper}"
  $SUDO install -d -m 0755 -o root -g root "$(dirname "$helper")" ||
    fail "could not create $(dirname "$helper")"

  local tmp
  tmp=$(mktemp) || fail "mktemp failed"
  render_priv_write_helper >"$tmp" ||
    fail "could not render the steamos-priv-write helper"
  $SUDO install -m 0755 -o root -g root "$tmp" "$helper" ||
    fail "could not install ${helper}"
  rm -f "$tmp"

  local invoking_user=${SUDO_USER:-${USER:-$(id -un)}}
  [[ -n $invoking_user && $invoking_user != root ]] ||
    fail "could not determine the desktop user (got '${invoking_user}'); run this as that user via sudo, not as root directly"

  log "granting ${invoking_user} NOPASSWD on ${PRIV_WRITE_HELPER} only"
  tmp=$(mktemp) || fail "mktemp failed"
  cat >"$tmp" <<EOF
# Installed by ${PROG}.sh. Lets Gaming Mode write the small set of sysfs nodes
# it needs (screen brightness, the status LED) without Steam falling back to
# 'sudo -n tee' on an arbitrary path and then 'sudo -n chmod a+w' on it.
#
# The grant is on the helper, not on the paths, so the WHITELIST INSIDE THE
# HELPER is the actual security boundary. The helper is root-owned 0755: a
# user who could rewrite it would already have root. Read the header of
# ${PROG}.sh before widening either.
${invoking_user} ALL=(root) NOPASSWD: ${PRIV_WRITE_HELPER}
EOF
  $SUDO visudo -c -f "$tmp" >/dev/null ||
    fail "generated sudoers snippet failed validation -- refusing to install it. Candidate left at ${tmp}"
  $SUDO install -m 0440 -o root -g root "$tmp" "$PRIV_WRITE_SUDOERS" ||
    fail "could not install ${PRIV_WRITE_SUDOERS}"
  rm -f "$tmp"

  verify_priv_write_helper "$helper" "$backlight"

  log "stage-priv-write-helper: ok"
  log "NOTE: this covers brightness and the status LED only. Steam also asks"
  log "      for /dev/drm_dp_aux0, which is deliberately NOT whitelisted."
}

# Exercise the installed priv-write helper. Takes the helper and the node to
# write for the reason set out in "THE VERIFICATION SEAM" above
# verify_update_stub.
#
# NOTE what the second parameter is NOT: it is not a way to widen what the
# helper will write. The whitelist that decides that lives INSIDE the rendered
# helper and is anchored on literal /sys/class/... prefixes, so handing this a
# path outside that subtree makes the helper REFUSE -- which is why the caller
# below still has to pass a real, whitelisted node to exercise the write path
# at all.
verify_priv_write_helper() {
  local helper=${1:-$PRIV_WRITE_HELPER}
  local bl=${2:-$DECK_BACKLIGHT}

  # Verify by running it against the real backlight, at its CURRENT value, so
  # a passing check leaves the screen exactly as it found it.
  if [[ -r $bl ]]; then
    local before after
    before=$(cat "$bl") || fail "could not read ${bl}"
    "$helper" "$bl" "$before" ||
      fail "${helper} failed writing ${bl} its own current value (${before}). Gaming Mode's brightness slider would fall through to the sudo tee/chmod path."
    after=$(cat "$bl") || fail "could not re-read ${bl}"
    [[ $after == "$before" ]] ||
      fail "${helper} changed ${bl} from ${before} to ${after} while being asked for ${before}"
    log "verified: wrote ${bl} its existing value (${before}) through the helper"
  else
    warn "${bl} not present, so the helper's write path was NOT exercised. On non-Deck hardware that is expected; on a Deck it is not."
  fi

  # The whitelist is the security boundary, so prove it refuses rather than
  # trusting that it is written correctly.
  local rc=0
  "$helper" /etc/shadow x >/dev/null 2>&1 || rc=$?
  [[ $rc -ne 0 ]] ||
    fail "${helper} accepted /etc/shadow. Its whitelist is the only thing bounding a root write; it is not working."

  rc=0
  "$helper" "$bl" 'not-a-number' >/dev/null 2>&1 || rc=$?
  [[ $rc -ne 0 ]] ||
    fail "${helper} accepted a non-numeric brightness value."

  log "verified: refuses a non-whitelisted path and a non-numeric value"
}

# The priv-write helper's body, written to stdout. Split out for the same
# reason render_update_stub is -- see the note above that function.
render_priv_write_helper() {
  cat <<EOF
#!/usr/bin/env bash
#
# steamos-priv-write -- write a value to one of a few allowed sysfs nodes,
# on behalf of Steam's Gaming Mode.
${INSTALL_MARKER}
#
# WHY THIS EXISTS
#   Steam changes screen brightness by running this exact absolute path. When
#   it is missing, Steam does not give up -- it falls back to
#   'echo VALUE | sudo -n tee PATH' and then 'sudo -n chmod a+w PATH'. Those
#   need blanket passwordless sudo, and the chmod leaves system nodes
#   world-writable after every Gaming Mode start. Answering here means Steam
#   never reaches for either.
#
# THE WHITELIST BELOW IS THE SECURITY BOUNDARY
#   The sudoers grant that makes this work covers this binary with ANY
#   arguments. Nothing else bounds what gets written as root. Do not widen the
#   patterns without deciding that the new path is safe for an unprivileged
#   caller to set to an arbitrary integer.
#
set -euo pipefail

note() {
  printf 'steamos-priv-write: %s\n' "\$1" >&2
  command -v logger >/dev/null 2>&1 && logger -t steamos-priv-write -- "\$1"
  return 0
}

path=\${1-}
value=\${2-}

if [[ -z \$path ]]; then
  note "called with no path"
  exit 2
fi

# Reject traversal on the literal argument. The patterns below anchor on a
# leading /sys/class/... prefix, and bash's case globs let '*' span '/', so
# without this a '..' could walk out of the whitelisted subtree.
case \$path in
  *..*)
    note "refusing a path containing '..': '\${path}'"
    exit 3
    ;;
esac

# One component, no slashes in it. Colons are allowed because real LED names
# carry them ('status:white').
if   [[ \$path =~ ^/sys/class/backlight/[A-Za-z0-9_.:+-]+/brightness\$ ]]; then
  :
elif [[ \$path =~ ^/sys/class/leds/[A-Za-z0-9_.:+-]+/led_brightness_multiplier\$ ]]; then
  :
else
  # LOUD, not silent. Steam discards stderr, so the journal line is where a
  # human finds out that a Steam client started asking for something new --
  # which is the signal to decide whether it belongs here, not to widen the
  # list reflexively.
  note "refusing a path that is not whitelisted: '\${path}'. If Gaming Mode now needs it, add it deliberately in deck-session.sh."
  exit 3
fi

# Every whitelisted node takes an unsigned integer. Steam does send an empty
# value for other paths (notably /dev/drm_dp_aux0), so this is a real case and
# not a theoretical one.
if [[ ! \$value =~ ^[0-9]+\$ ]]; then
  note "refusing a non-numeric value '\${value}' for '\${path}'"
  exit 4
fi

if [[ \$EUID -ne 0 ]]; then
  # -n so this can never block on a password prompt Steam cannot render.
  # Re-runs this same file, so every check above runs again as root.
  #
  # NOT 'exec sudo': on a refusal, exec leaves only sudo's own message on a
  # stderr that Steam discards, so the failure would reach nobody. Running it
  # as a child costs one process and lets the refusal be identified and
  # journalled. The inner run's exit code is propagated unchanged, so the
  # codes above still mean what they say.
  rc=0
  sudo -n ${PRIV_WRITE_HELPER} "\$path" "\$value" || rc=\$?
  if [[ \$rc -ne 0 ]] && ! sudo -n -l ${PRIV_WRITE_HELPER} >/dev/null 2>&1; then
    note "sudo will not run ${PRIV_WRITE_HELPER} without a password, so Gaming Mode cannot set '\${path}'. Check ${PRIV_WRITE_SUDOERS}."
  fi
  exit \$rc
fi

if [[ ! -w \$path ]]; then
  note "'\${path}' is not writable even as root"
  exit 5
fi

# The kernel rejects out-of-range values itself; report that rather than
# swallowing it, so a failed write is never mistaken for a successful one.
if ! printf '%s\n' "\$value" >"\$path" 2>/dev/null; then
  note "the kernel refused value '\${value}' for '\${path}'"
  exit 6
fi
EOF
}

# ---------------------------------------------------------------------------

stage_greeter_rotation() {
  # The SDDM greeter is one of the three surfaces that render sideways. It is
  # fixed the same way the desktop is -- a compositor transform -- because the
  # greeter IS a Hyprland instance: Omarchy drives it with
  #
  #   CompositorCommand=start-hyprland -- --config /usr/share/sddm/hyprland.lua
  #
  # so the greeter reads a Hyprland Lua config and hl.monitor() applies there
  # exactly as it does in the user's session.
  #
  # NOT fixed here, and not fixable this way -- both render before any
  # compositor exists, and both are now fixed in the boot chain instead
  # (operator-approved and seen on the panel 2026-08-11, PROGRESS.md 5.11):
  #   - the Limine boot menu -- `interface_rotation: 90` in /boot/limine.conf.
  #     R-19's recorded 270 was 180 degrees wrong.
  #   - the console/TTY -- `fbcon=rotate:1` on the kernel cmdline, via
  #     /etc/limine-entry-tool.d/50-deck-fbcon-rotation.conf.
  #
  # THE TWO SYSTEM PATHS THIS STAGE READS ARE PARAMETERS -- see "THE
  # VERIFICATION SEAM" above verify_update_stub. Production passes nothing and
  # gets ${UPSTREAM_GREETER_LUA} and ${SDDM_GREETER_DROPIN}.
  local upstream=${1:-$UPSTREAM_GREETER_LUA}
  local dropin=${2:-$SDDM_GREETER_DROPIN}

  [[ -f $upstream ]] ||
    fail "${upstream} not found -- Omarchy's greeter config has moved, so mirroring it here would be guesswork. Re-check CompositorCommand in $(dirname "$dropin")/ before continuing."

  # Drift check. Ours is a copy, so upstream changing its greeter settings is
  # something a human has to notice; a silent divergence would show up months
  # later as a greeter that lost a setting nobody remembers.
  local actual
  actual=$(sha256sum "$upstream" | awk '{print $1}')
  if [[ $actual != "$UPSTREAM_GREETER_SHA256" ]]; then
    warn "${upstream} has changed since ${GREETER_LUA} was mirrored from it (expected ${UPSTREAM_GREETER_SHA256:0:12}…, got ${actual:0:12}…). Diff the two and re-mirror, then update UPSTREAM_GREETER_SHA256. Proceeding: the transform below is still correct, but any NEW upstream greeter setting is not being carried over."
  fi

  log "installing the greeter compositor config: ${GREETER_LUA}"
  $SUDO install -d -m 0755 -o root -g root "$(dirname "$GREETER_LUA")" ||
    fail "could not create $(dirname "$GREETER_LUA")"

  local tmp
  tmp=$(mktemp) || fail "mktemp failed"
  cat >"$tmp" <<EOF
-- Hyprland config for the SDDM Wayland greeter on a Steam Deck.
${INSTALL_MARKER_LUA}
--
-- A MIRROR of ${UPSTREAM_GREETER_LUA} (Omarchy's own greeter config, package
-- owned by omarchy-settings-dev) plus the panel transform. Editing upstream's
-- file directly would be reverted by the next package upgrade, so SDDM is
-- repointed here instead -- see ${SDDM_GREETER_DROPIN}.
--
-- If upstream's greeter config gains a setting, it must be copied down here by
-- hand. stage-greeter-rotation warns when its hash changes.
hl.config({
  misc = {
    disable_hyprland_logo = true,
    disable_splash_rendering = true,
    force_default_wallpaper = 0,
  },

  animations = {
    enabled = false,
  },
})

-- The whole reason this file exists. transform = ${PANEL_TRANSFORM} (270 deg), confirmed by
-- looking at the hardware; ${PANEL_OUTPUT} scans out portrait and is mounted rotated.
-- transform = 1 renders upside down.
hl.monitor({ output = "${PANEL_OUTPUT}", mode = "preferred", position = "auto", scale = ${PANEL_SCALE}, transform = ${PANEL_TRANSFORM} })
EOF
  # Prove it PARSES before installing it. Hyprland does not fail loudly on a
  # broken Lua config: it discards the file, falls back to built-in defaults,
  # and logs nothing beyond "loading lua mgr". The greeter then comes up
  # rotated and unstyled, looking like the transform simply did not work. This
  # check exists because that is exactly what happened -- a '#' comment on
  # line 2, legal in shell, a syntax error in Lua.
  if command -v luac >/dev/null 2>&1; then
    local luaerr
    if ! luaerr=$(luac -p "$tmp" 2>&1); then
      rm -f "$tmp"
      fail "the greeter config this stage generates is not valid Lua: ${luaerr}. Refusing to install it -- Hyprland would silently ignore it and the greeter would render rotated with no error anywhere."
    fi
    log "verified: generated greeter config is valid Lua"
  else
    warn "luac not found, so the generated greeter config was NOT syntax-checked. A Lua syntax error here is silent: Hyprland discards the config and falls back to defaults. Install the 'lua' package to enable this check."
  fi

  $SUDO install -m 0644 -o root -g root "$tmp" "$GREETER_LUA" ||
    fail "could not install ${GREETER_LUA}"
  rm -f "$tmp"

  log "pointing SDDM's greeter compositor at it: ${dropin}"
  tmp=$(mktemp) || fail "mktemp failed"
  cat >"$tmp" <<EOF
# Written by ${PROG}.sh. Repoints SDDM's Wayland greeter compositor at a config
# that rotates the Deck's panel (PROGRESS.md 5.11).
${INSTALL_MARKER}
#
# Named 'zy-' so it sorts AFTER Omarchy's 10-wayland.conf and wins the
# CompositorCommand key, and so it stays clear of 'zz-deck-session.conf', which
# deck-session-select rewrites on every session switch.
[General]
DisplayServer=wayland

[Wayland]
CompositorCommand=start-hyprland -- --config ${GREETER_LUA}
EOF
  $SUDO install -m 0644 -o root -g root "$tmp" "$dropin" ||
    fail "could not install ${dropin}"
  rm -f "$tmp"

  verify_greeter_compositor_command "$dropin"

  log "stage-greeter-rotation: ok"
  log "NOTE: autologin means the greeter is normally skipped, so this is not"
  log "      exercised on a normal boot. To see it, disable the [Autologin]"
  log "      section and restart sddm."
}

# Verify the greeter override actually WINS. SDDM takes the LAST value for a
# key across its drop-in directory in lexical order, so asserting our file
# exists proves nothing about which value the greeter will use.
#
# Takes our drop-in's path -- the directory to sweep is its dirname -- for the
# reason set out in "THE VERIFICATION SEAM" above verify_update_stub. Reading a
# hardcoded /etc/sddm.conf.d made this stage's outcome a property of whichever
# machine ran it, which is what kept it out of the unit suite.
verify_greeter_compositor_command() {
  local dropin=${1:-$SDDM_GREETER_DROPIN}
  local conf_dir
  conf_dir=$(dirname "$dropin")

  local winner
  winner=$(cat "$conf_dir"/*.conf 2>/dev/null | grep '^CompositorCommand=' | tail -1)
  [[ $winner == "CompositorCommand=start-hyprland -- --config ${GREETER_LUA}" ]] ||
    fail "installed ${dropin} but the last CompositorCommand across ${conf_dir} is '${winner}'. Something sorts after 'zy-' and overrides it; the greeter would still render rotated."
  log "verified: ours is the winning CompositorCommand"
}

# ---------------------------------------------------------------------------

stage_sddm_resilience() {
  # Observed on hardware, switching Gaming Mode -> Desktop through Steam's own
  # menu item: the switch left the Deck with NO graphical session at all, and
  # recovering needed `systemctl reset-failed sddm` over SSH -- which is exactly
  # what a controller-only user does not have.
  #
  # The mechanism, from sddm's shipped unit:
  #
  #   TimeoutStopSec=5   StartLimitIntervalSec=30   StartLimitBurst=2   RestartSec=100ms
  #
  # The FIRST domino is the stop timing out, which R-26 did not record. A
  # Gaming Mode teardown does not fit in 5s (Steam is slow to exit), so systemd
  # SIGKILLs sddm and then runs the restart's start job 3ms later, against a VT
  # the killed compositor still holds. The greeter dies, Restart=always retries,
  # and StartLimitBurst=2 latches the unit to `failed` -- no graphical session,
  # and on the product no way back.
  #
  # ⚠️ R-26 called RestartSec=3 "the more important half", reasoning that at
  # 100ms every retry lands before the VT is free. RestartSec does not gate the
  # fatal start at all -- that one comes from an explicit `systemctl restart`
  # transaction, and RestartSec only spaces Restart=always auto-restarts. Hence
  # the measured 3ms. Both directives below still earn their place on the RETRY
  # path, but the cause is addressed by TimeoutStopSec here plus the stop ->
  # settle -> start sequencing in render_restart_helper.
  #
  # TRADEOFF, deliberate: disabling the rate limit means a genuinely broken SDDM
  # config retries forever instead of stopping. On a device with no keyboard,
  # a loop that can still recover beats a black screen that cannot -- and a
  # permanently broken config is a dev-time failure, which the journal shows
  # either way.
  log "installing SDDM restart resilience: ${SDDM_UNIT_DROPIN}"
  $SUDO install -d -m 0755 -o root -g root "$(dirname "$SDDM_UNIT_DROPIN")" ||
    fail "could not create $(dirname "$SDDM_UNIT_DROPIN")"

  local tmp
  tmp=$(mktemp) || fail "mktemp failed"
  cat >"$tmp" <<EOF
# Written by ${PROG}.sh -- see stage-sddm-resilience.
${INSTALL_MARKER}
#
# Session switching restarts SDDM while the outgoing compositor still holds
# VT1. Upstream's TimeoutStopSec=5 / StartLimitIntervalSec=30 /
# StartLimitBurst=2 / RestartSec=100ms turns that transient race into a
# PERMANENT failure: the Deck ends up with no graphical session and needs
# 'systemctl reset-failed sddm' from a shell.
[Unit]
# 0 disables rate limiting. See the tradeoff note in stage-sddm-resilience.
StartLimitIntervalSec=0

[Service]
# THE CAUSE. Upstream's 5s does not fit a Gaming Mode teardown -- measured at
# 5.008s, i.e. systemd SIGKILLed sddm mid-teardown and started the replacement
# 3ms later against a VT that was still held. Letting the stop finish is what
# stops the race happening, rather than surviving it.
TimeoutStopSec=${SDDM_STOP_TIMEOUT}

# Give the outgoing session time to release the VT before RETRYING. 100ms did
# not, and every retry inside that window is wasted. This governs the
# Restart=always path only; it does not affect an explicit restart.
RestartSec=3
EOF
  $SUDO install -m 0644 -o root -g root "$tmp" "$SDDM_UNIT_DROPIN" ||
    fail "could not install ${SDDM_UNIT_DROPIN}"
  rm -f "$tmp"

  $SUDO systemctl daemon-reload || fail "systemctl daemon-reload failed"

  # Verify the values systemd ACTUALLY resolved. A drop-in in the right place
  # with a typo'd directive is silently ignored, so reading the file back would
  # prove nothing.
  local limit restart_usec stop_usec
  limit=$(systemctl show sddm -p StartLimitIntervalUSec --value 2>/dev/null)
  restart_usec=$(systemctl show sddm -p RestartUSec --value 2>/dev/null)
  stop_usec=$(systemctl show sddm -p TimeoutStopUSec --value 2>/dev/null)
  [[ $limit == "0" || $limit == "infinity" ]] ||
    fail "installed ${SDDM_UNIT_DROPIN} but systemd still reports StartLimitIntervalUSec=${limit}. The drop-in was not applied; a failed switch would still leave the Deck with no session."

  # This one is a fail, not a warn: it is the directive that addresses the
  # cause. At upstream's 5s the teardown is SIGKILLed and the race is back.
  [[ $stop_usec == "${SDDM_STOP_TIMEOUT}s" || $stop_usec == "${SDDM_STOP_TIMEOUT}"* ]] ||
    fail "TimeoutStopSec resolved to '${stop_usec}', not ${SDDM_STOP_TIMEOUT}s. That is the directive that keeps sddm's teardown from being SIGKILLed at 5s, which is what puts the VT race back."

  [[ $restart_usec == "3s" ]] ||
    warn "RestartSec resolved to '${restart_usec}', not 3s. The rate limit is lifted so a switch can still recover, but retries may again land before the VT is free."

  log "verified: StartLimitIntervalUSec=${limit}, TimeoutStopUSec=${stop_usec}, RestartUSec=${restart_usec}"
  log "stage-sddm-resilience: ok"
}

# ---------------------------------------------------------------------------

stage_input_mapper() {
  # Ships src/deck-input-mapper.py as a --user service so the Deck's controller
  # drives the Omarchy desktop. Gaming Mode needs nothing here: Steam takes the
  # controller over itself (docs/findings/hardware-parity.md).
  #
  # The mapper picks its device by CAPABILITY (BTN_SOUTH), not by name or event
  # number. That matters: node numbers are not stable between the live ISO and
  # an installed system -- PROGRESS.md 5.9's event5/event4/event11 are event6/
  # event5/event7 here -- and the device is named "Steam Deck", not "Steam Deck
  # Controller". Anything matching on either would bind the wrong node.
  #
  # ⚠️ THIS STAGE HAS NO VERIFICATION SEAM, AND THE REASON IS EXTERNAL. The
  # mapper probe further down runs a readonly absolute path, which is the same
  # thing that kept four sibling stages out of the unit suite until they grew a
  # verify_* function taking that path as an argument (see "THE VERIFICATION
  # SEAM" above verify_update_stub). The blocker here is not this file:
  # test/unit/test-osk-install-layout.sh sed's this function's body out of
  # deck-session.sh and greps it for three code shapes -- the module install
  # loop's destination, the renderers' import line, and the command substitution
  # that runs the mapper. Move any of them into a verify_input_mapper() and that
  # suite goes red.
  #
  # Note what NOT to do about it: the patterns are deliberately not quoted in
  # this comment, because a comment its greps matched would keep the suite green
  # with the code deleted -- the "the regex matched a comment, not the code"
  # artifact PROGRESS.md §7 records, manufactured on purpose. Split this stage
  # and that suite in the same change, or leave both alone.
  local src_dir
  src_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  [[ -f "${src_dir}/${MAPPER_SRC_NAME}" ]] ||
    fail "${MAPPER_SRC_NAME} not found beside ${PROG}.sh (looked in ${src_dir}). This stage installs it; sync the whole src/ directory, not just this script."
  local osk_module
  for osk_module in "${OSK_MODULES[@]}"; do
    [[ -f "${src_dir}/${osk_module}" ]] ||
      fail "${osk_module} not found beside ${PROG}.sh (looked in ${src_dir}). The mapper imports it for the on-screen keyboard; sync the whole src/ directory."
  done

  # python-evdev is in Arch's [extra], NOT the AUR -- CLAUDE.md forbids AUR-only
  # dependencies. Checked by import rather than by `pacman -Q`, because that is
  # what actually has to work at runtime.
  python3 -c 'import evdev' 2>/dev/null ||
    fail "python-evdev is not importable. Install it with 'sudo pacman -S --needed python-evdev' (it is in [extra], not the AUR). The mapper cannot run without it."

  # /dev/uinput is the other hard precondition: no uinput, no virtual keyboard.
  # On this device the ACL comes from steam-jupiter-stable's udev rules
  # (60-steam-input.rules tags uinput uaccess), so it is granted to whoever holds
  # the active local session -- NOT via the `input` group, which T3 §4 assumed.
  # Tested by opening it, because the permission bits alone do not tell you:
  # /dev/uinput is root:root 0660 and the access is an ACL.
  python3 -c 'import os; os.close(os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK))' 2>/dev/null ||
    warn "/dev/uinput is not writable by ${USER:-$(id -un)} right now. If this user has no active local graphical session that is expected (uaccess grants it per-session) and the service will still work once logged in. If it persists inside the desktop, the mapper will fail to create its virtual keyboard."

  # The OSK modules go in FIRST. The mapper imports the layout core at module
  # load and degrades to navigation-only without it (loudly, never silently), so
  # installing the script first would leave a window where a restart brings up a
  # mapper with no character keys and a warning nobody is watching for.
  $SUDO install -d -m 0755 -o root -g root "$OSK_LIB_DIR" ||
    fail "could not create ${OSK_LIB_DIR}"
  for osk_module in "${OSK_MODULES[@]}"; do
    log "installing the OSK module: ${OSK_LIB_DIR}/${osk_module}"
    $SUDO install -m 0644 -o root -g root "${src_dir}/${osk_module}" "${OSK_LIB_DIR}/${osk_module}" ||
      fail "could not install ${OSK_LIB_DIR}/${osk_module}"
  done

  log "installing the input mapper: ${MAPPER_BIN}"
  $SUDO install -m 0755 -o root -g root "${src_dir}/${MAPPER_SRC_NAME}" "$MAPPER_BIN" ||
    fail "could not install ${MAPPER_BIN}"

  # Verify by RUNNING it, not by checking the file landed. A uinput device emits
  # only the keycodes it declared, so a core that installed but does not import
  # produces a mapper whose character keys are silently dead -- exactly the
  # failure this project exists to attack. --type --dry-run resolves the text
  # through the layout and prints the keystrokes without touching /dev/uinput,
  # so it works here with no session and no pad attached.
  local probe
  probe=$("$MAPPER_BIN" --type 'aA1!' --dry-run 2>&1) ||
    fail "${MAPPER_BIN} --type failed; the OSK layout core did not load. Output: ${probe}"
  grep -q KEY_LEFTSHIFT <<<"$probe" ||
    fail "${MAPPER_BIN} resolved no shift modifier for 'A'; ${OSK_LIB_DIR}/${OSK_SRC_NAME} is not the file the mapper imported. Output: ${probe}"
  log "verified: the mapper imports the OSK layout core and resolves shifted characters"

  # The renderers are not on the --type path, so they need their own check:
  # without them --osk-backend=tty/layer comes up with no keyboard and one
  # warning line. Imported from the INSTALLED directory, which is what the
  # mapper does. deck_osk_wayland imports `gi` inside main(), so importing it
  # here needs no GTK and no display.
  local osk_import
  osk_import=$(python3 -c "
import sys
sys.path.insert(0, '${OSK_LIB_DIR}')
import deck_osk_layout, deck_osk_tty, deck_osk_wayland
print(len(deck_osk_tty.render(deck_osk_layout.OnScreenKeyboard(), deck_osk_layout.Cursors())))
" 2>&1) ||
    fail "the OSK modules in ${OSK_LIB_DIR} do not import. The installer's keyboard would be missing. Output: ${osk_import}"
  [[ $osk_import == 5 ]] ||
    fail "the installed OSK renderer drew ${osk_import} rows for the letters layer, expected 5. Output: ${osk_import}"
  log "verified: the installed OSK modules import and render"

  assert_ours_or_absent "$MAPPER_UNIT" "something else"
  log "installing the user unit: ${MAPPER_UNIT}"
  $SUDO install -d -m 0755 -o root -g root "$(dirname "$MAPPER_UNIT")" ||
    fail "could not create $(dirname "$MAPPER_UNIT")"

  local tmp
  tmp=$(mktemp) || fail "mktemp failed"
  cat >"$tmp" <<EOF
${INSTALL_MARKER}
[Unit]
Description=Steam Deck controller to keyboard/mouse mapper (Desktop Mode)
Documentation=file://${MAPPER_BIN}
# PartOf, so it goes away with the session rather than lingering into Gaming
# Mode, where Steam owns the controller and a second reader would fight it.
# PartOf propagates stop/restart only -- it adds no ordering.
PartOf=graphical-session.target
#
# ⚠️ DELIBERATELY NO After=graphical-session.target. That looks obviously right
# and creates an ORDERING CYCLE with the target this unit is WantedBy:
#
#   deck-input-mapper.service: Found ordering cycle:
#     graphical-session.target/start after wayland-session@hyprland.desktop.target/start
#     after deck-input-mapper.service/start - after graphical-session.target
#   Job deck-input-mapper.service/start deleted to break ordering cycle
#
# systemd resolves the cycle by DELETING this unit's start job, so the service
# silently never runs. Measured on hardware.
#
# 🔴 THIS COMMENT USED TO END "the mapper needs no ordering anyway: it reads
# evdev and writes uinput, and never talks to the compositor." That was TRUE
# when written and QUIETLY EXPIRED (docs/PROGRESS.md §5.28): the mapper has
# since grown children that do talk to the compositor -- omarchy-menu on
# STEAM/QAM, the layer-shell keyboard, the focus watcher, hyprctl -- so this
# unit STARTING EARLY, with an environment of one variable, shipped a Deck that
# cold-booted with no keyboard, no launcher and no menu.
#
# The ordering stays absent (the cycle above is real). The mapper now resolves
# the session environment AT SPAWN TIME instead of inheriting it, and polls for
# it on its own loop until it arrives. ⚠️ If you are tempted to "fix" this with
# ordering here, read §5.28 first, and note that any test of it MUST BOOT THE
# MACHINE -- a mapper restarted by hand always passes.
#
# StartLimit* live in [Unit], not [Service]. Putting them in [Service] is not an
# error -- systemd logs "Unknown key ... ignoring" and carries on unbounded.
StartLimitBurst=5
StartLimitIntervalSec=60

[Service]
Type=simple
ExecStart=${MAPPER_BIN} --osk-backend=${MAPPER_OSK_BACKEND}
# The pad may not have enumerated yet at session start. Restart rather than
# fail permanently -- but bounded (above), so a genuinely missing device shows
# up in the journal instead of spinning silently.
Restart=on-failure
RestartSec=2

[Install]
WantedBy=${MAPPER_WANTED_BY}
EOF
  $SUDO install -m 0644 -o root -g root "$tmp" "$MAPPER_UNIT" ||
    fail "could not install ${MAPPER_UNIT}"
  rm -f "$tmp"

  # The target must EXIST. A unit WantedBy a nonexistent target enables with no
  # error and never starts, which is the silent failure T3 §4 warns about.
  #
  # `list-units`, NOT `list-unit-files`: this is a TEMPLATE INSTANCE that uwsm
  # creates at runtime, so it has no unit file on disk and list-unit-files finds
  # nothing. The first version of this check used that and warned on a target
  # that was demonstrably active -- a check failing for the wrong reason is as
  # bad as one passing for the wrong reason.
  if systemctl --user list-units --all --no-legend "$MAPPER_WANTED_BY" 2>/dev/null | grep -q .; then
    log "verified: ${MAPPER_WANTED_BY} exists in this user manager"
  else
    warn "${MAPPER_WANTED_BY} is not known to this user manager. Over SSH with no graphical session that is normal; inside the desktop it means the unit will enable and never start -- check 'systemctl --user list-units --all | grep wayland-session'."
  fi

  $SUDO systemctl --global enable deck-input-mapper.service >/dev/null 2>&1 ||
    fail "could not enable deck-input-mapper.service for all users"

  log "verified: unit installed and enabled --global, wanted by ${MAPPER_WANTED_BY}"
  log "stage-input-mapper: ok"
  log "NOTE: it starts with the NEXT desktop session. Button-mapping correctness"
  log "      cannot be checked from here -- it needs someone pressing buttons."
}

# ---------------------------------------------------------------------------
# LIZARD MODE -- PROGRESS.md 5.21, and the one stage that can cost the operator
# their only input device. Read the LIZARD_* constants above before editing.
# ---------------------------------------------------------------------------

# The lizard-mode helper's body, written to stdout. Split out for the same
# reason render_update_stub is -- see the note above that function.
#
# The sysfs node is a PARAMETER, baked in at render time, for the reason set out
# in "THE VERIFICATION SEAM" above verify_update_stub: production passes nothing
# and gets ${LIZARD_SYSFS}. It is emphatically NOT taken from the helper's own
# argv, because the sudoers grant covers this file and a caller-supplied path
# would turn that grant into "write Y or N to any file, as root".
render_lizard_helper() {
  local node=${1:-$LIZARD_SYSFS}
  cat <<EOF
#!/usr/bin/env bash
#
# deck-lizard-mode -- turn the Steam Deck controller firmware's own input
# emulation ("lizard mode") on or off.
${INSTALL_MARKER}
#
# THE ARGUMENT NAMES LIZARD MODE, NOT THE MAPPER. Reading it the other way round
# is the whole hazard, so it is spelled out here and in every message below:
#
#   on   -> ${node}=Y
#           The FIRMWARE provides input: pointer, Enter, Esc, Tab, arrows. It
#           also swallows X, Y, L1, R1, STEAM and QAM entirely, so
#           deck-input-mapper is a no-op. This is the SAFE value -- degraded,
#           but a device a human can always drive.
#   off  -> ${node}=N
#           Those six buttons reach the pad node and the firmware's own pointer
#           disappears. The mapper becomes the ONLY input path on the device.
#
# ONLY deck-input-mapper.service should call this. Its ExecStartPost= says
# \`off\` and its ExecStopPost= says \`on\`; that pair is what binds lizard mode's
# lifetime to the mapper's. Run by hand, \`off\` will happily leave a handheld
# with no input at all, and \`${LIZARD_HELPER} on\` is the way back -- over SSH,
# because by then nothing else works.
#
# WHY THERE IS NO EUID CHECK IN HERE: the node is root-writable and world-
# readable, so an unprivileged caller already gets a loud EACCES from the write
# below. Duplicating the check would add nothing except a second place for the
# two to disagree, and it would stop the unit suite from running this exact
# file against a sandboxed node with no root at all.
#
set -euo pipefail

NODE=${node}

note() {
  printf 'deck-lizard-mode: %s\n' "\$1" >&2
  command -v logger >/dev/null 2>&1 && logger -t deck-lizard-mode -- "\$1"
  return 0
}

# STRICT argv: exactly one argument, exactly 'on' or 'off'. An unrecognised verb
# is refused rather than guessed at, because both guesses are wrong in a way
# that ends with a device nobody can drive -- guess 'on' and the mapper is
# silently a no-op, guess 'off' and a machine with no mapper has no input.
# Extra arguments are refused too: this file sits behind a sudo grant, and
# "arguments we ignored" is not a property worth having there.
if [[ \$# -ne 1 ]]; then
  note "expected exactly one argument, 'on' or 'off'; got \$# (\${*:-<none>})"
  exit 2
fi

case \$1 in
  on)  want=Y ;;
  off) want=N ;;
  *)
    note "unknown argument '\$1' -- expected 'on' (the firmware provides input) or 'off' (deck-input-mapper does)"
    exit 2
    ;;
esac

if [[ ! -e \$NODE ]]; then
  note "\${NODE} does not exist. hid_steam is not loaded, or this kernel's build has no lizard_mode parameter. NOT reporting success: something has to notice."
  exit 3
fi

if ! printf '%s\n' "\$want" >"\$NODE"; then
  note "could not write '\${want}' to \${NODE}. This has to run as root; deck-input-mapper.service reaches it through sudo (see ${LIZARD_SUDOERS})."
  exit 4
fi

# READ BACK, and fail if the value did not take. A successful write is not proof
# for a module parameter: the write lands in the kernel's setter, and a value it
# declined leaves the node reading what it read before, with exit 0 here. That
# is the silent-success shape this project exists to attack, and it is the one
# failure that would make everything downstream believe input had moved when it
# had not.
if ! got=\$(cat "\$NODE"); then
  note "wrote '\${want}' to \${NODE} but could not read it back to confirm it"
  exit 5
fi

if [[ \$got != "\$want" ]]; then
  note "wrote '\${want}' to \${NODE} but it reads back '\${got}' -- lizard mode is NOT '\$1'. Treat input as being wherever '\${got}' says it is."
  exit 5
fi

printf 'deck-lizard-mode: lizard mode is now %s (%s=%s)\n' "\$1" "\$NODE" "\$got"
EOF
}

# The systemd drop-in that makes the invariant true. Written to stdout, split
# out for the same reason render_update_stub is.
#
# ===========================================================================
# DOES ExecStopPost= REALLY RUN ON EVERY FAILURE PATH? -- MEASURED, systemd 261
# ===========================================================================
#
# The whole safety argument rests on this, so it was probed with a real user
# unit rather than read off systemd.service(5). Every row is "did the
# ExecStopPost= actually run":
#
#   systemctl stop                                  ran
#   main process exits non-zero                     ran
#   main process SIGKILLed (kill -9 $MAINPID)       ran
#   ExecStart= binary missing (status 203)          ran
#   ExecStartPost= fails                            ran
#   Restart= start limit exhausted                  ran, once per REAL start
#                                                   attempt. The refused start
#                                                   starts nothing, so there is
#                                                   nothing left to hand back
#   ----------------------------------------------------------------------
#   WHOLE CGROUP SIGKILLed                          STARTED, THEN KILLED
#
# 🔴 THE LAST ROW IS A REAL HOLE and it is the one case this design does not
# cover. systemd spawns ExecStopPost= INTO the unit's own cgroup, so a
# cgroup-wide SIGKILL kills it too. From the journal of the probe:
#
#   lzprobe.service: Killed unit cgroup '...' with SIGKILL on client request
#   lzprobe.service: Main process exited, code=killed, status=9/KILL
#   lzprobe.service: Control process exited, code=killed, status=9/KILL  <- us
#   lzprobe.service: Failed with result 'signal'
#
# Reachable three ways: `systemctl kill -s SIGKILL` (whose DEFAULT --kill-whom
# is NOT main), `--kill-whom=all|cgroup`, and systemd-oomd, which kills by
# writing cgroup.kill. A debugging session is exactly when a human types the
# first of those.
#
# ===========================================================================
# WHICH IS WHY OnFailure= EXISTS -- ALSO MEASURED, SAME PROBE
# ===========================================================================
#
# OnFailure= starts a SEPARATE unit, so systemd gives it its OWN cgroup and the
# kill that defeats ExecStopPost= cannot reach it. Probed against a unit
# mirroring this one exactly (Restart=on-failure, RestartSec=2,
# StartLimitBurst=5, StartLimitIntervalSec=60):
#
#   how it died                        ExecStopPost   OnFailure   ended at
#   ---------------------------------------------------------------------
#   systemctl stop                     ran            no          lizard on
#   systemctl kill (default SIGTERM)   ran            no          lizard on
#   SIGKILL of the main pid only       ran            RAN         lizard off,
#                                                                 mapper back
#   systemctl kill -s SIGKILL          KILLED         RAN         lizard off,
#     (default --kill-whom)                                       mapper back
#   --kill-whom=all -s SIGKILL         KILLED         RAN         lizard off,
#                                                                 mapper back
#   cgroup.kill (systemd-oomd)         KILLED         RAN         lizard off,
#                                                                 mapper back
#   start limit exhausted              KILLED         RAN LAST    LIZARD ON,
#                                                                 no mapper
#   ExecStart= missing, limit hit      ran            RAN LAST    LIZARD ON,
#                                                                 no mapper
#
# The two rows that matter: every cgroup-kill path now ends with input working,
# and every path that ends with NO MAPPER ends with LIZARD ON. There is no
# longer a way to reach "lizard off and nothing reading the pad" that survives
# more than one RestartSec.
#
# ⚠️ ONE DOCUMENTED SURPRISE, because it contradicts systemd.unit(5).
# That page says a unit using Restart= "enters the failed state only after the
# start limits are reached", which would mean OnFailure= does not fire on a
# crash that restarts cleanly. IT FIRES ANYWAY -- measured on every restarting
# row above. So the knob really does flap: off -> (crash) -> on -> (restart)
# -> off. That is deliberate and it is the safe direction:
#
#   * The restore only ever writes ON. It can never turn lizard mode off.
#   * Measured margin: the restore lands ~0.5s after the kill, the restart's
#     ExecStartPost ~2.2s after it. RestartSec=2 is what buys the ~1.7s.
#   * If it ever lost that race, the cost is a mapper running against a device
#     the firmware still owns -- STEAM+X dead until the next restart. Annoying,
#     visible, and NOT a loss of input.
#
# Do not "fix" the flap by making the restore conditional on the mapper's state:
# during an auto-restart the mapper is `activating`, not `failed`, so every
# condition worth writing skips the restore in precisely the cgroup-kill case
# it exists for.
render_lizard_dropin() {
  cat <<EOF
${INSTALL_MARKER}
#
# Binds lizard mode's lifetime to deck-input-mapper.service's, which is the
# whole safety argument for turning it off at all (PROGRESS.md 5.21, operator
# decision 2 in 5.25):
#
#   * Boot leaves the module parameter at Y, so a mapper that never starts
#     leaves a device the firmware still drives.
#   * ExecStopPost= runs on a clean stop, when the service exits unexpectedly,
#     and when the service FAILED TO START and is being shut down again --
#     systemd.service(5), and measured rather than taken on trust: see the
#     table above render_lizard_dropin in ${PROG}.sh.
#   * Worst case is losing STEAM+X until the next start. Not losing input.
#
# 🔴 ExecStopPost= HAS ONE MEASURED HOLE: a SIGKILL of the WHOLE CGROUP
# (\`systemctl kill -s SIGKILL\`, whose default --kill-whom is not main, or
# systemd-oomd) kills it too, because systemd spawns it into this unit's own
# cgroup. That is what OnFailure= below is for: it starts a SEPARATE unit, which
# gets its own cgroup and survives the same kill. Both were measured -- the
# table above render_lizard_dropin in ${PROG}.sh has every path.
#
# OnFailure= is NOT a duplicate of ExecStopPost=. ExecStopPost= is synchronous
# and covers the ordinary paths; OnFailure= is asynchronous and covers the ones
# that kill it. Removing either leaves a real gap.
#
# NEITHER LINE IS PREFIXED WITH '-', deliberately. If lizard mode cannot be
# turned off then the mapper is a no-op anyway, and a loud failure that leaves
# the firmware in charge is the correct outcome -- '-' would make it a silent
# one, and this unit would then run as a process that reads a permanently
# silent device.
#
# ⚠️ ExecStartPost= for Type=simple runs as soon as the mapper is FORKED, not
# once it is reading. There is a short window -- one process start -- where
# lizard mode is off and the mapper has not opened the pad yet. It is bounded
# by ExecStopPost=: if the mapper dies in that window the service fails and
# lizard mode goes straight back on. Closing it properly needs Type=notify and
# an sd_notify() in deck-input-mapper.py.
[Unit]
# The half ExecStopPost= cannot cover. Measured: it fires on every cgroup-kill
# path, and it fires LAST when the start limit is reached -- so the state a
# dead mapper leaves behind is lizard mode ON.
OnFailure=${LIZARD_RESTORE_UNIT##*/}

[Service]
ExecStartPost=${SUDO_BIN} -n ${LIZARD_HELPER} off
ExecStopPost=${SUDO_BIN} -n ${LIZARD_HELPER} on
EOF
}

# The unit OnFailure= reaches. Written to stdout, split out for the same reason
# render_update_stub is.
#
# WHY A WHOLE SEPARATE UNIT FOR ONE COMMAND: because a separate unit is the only
# way to get a separate CGROUP, and the cgroup is the entire point. ExecStopPost=
# runs inside the mapper's cgroup and dies with it under a cgroup-wide SIGKILL;
# this runs in its own and does not. Measured, both ways -- see the table above
# render_lizard_dropin.
#
# Type=oneshot with no RemainAfterExit=, so it returns to inactive after each
# run and OnFailure= can trigger it again. Measured: six consecutive triggers,
# six runs.
#
# ⚠️ NO [Install] SECTION, deliberately. This unit is reached by OnFailure= and
# by nothing else. Enabling it would run it at every session start -- turning
# lizard mode ON just as the mapper was turning it off, which is a race with the
# one thing that must win.
render_lizard_restore_unit() {
  cat <<EOF
${INSTALL_MARKER}
[Unit]
Description=Restore Steam Deck lizard mode after ${MAPPER_UNIT##*/} failed
Documentation=file://${LIZARD_HELPER}

[Service]
Type=oneshot
# 'on' -- towards the SAFE value, always. This unit can never turn lizard mode
# off, which is what makes it harmless when it races a restarting mapper: the
# worst it can do is leave the firmware in charge while the mapper runs, i.e.
# cost STEAM+X. It cannot cost input.
ExecStart=${SUDO_BIN} -n ${LIZARD_HELPER} on
EOF
}

# Run the helper one way and prove the node moved. Not folded into
# verify_lizard_helper because both directions need identical treatment, and a
# copy-pasted second half is how the two drift.
lizard_expect() {   # lizard_expect <helper> <node> <on|off> <Y|N>
  local helper=$1 node=$2 verb=$3 want=$4 got
  $SUDO "$helper" "$verb" ||
    fail "'${helper} ${verb}' failed. Lizard mode cannot be controlled on this machine, so the mapper would either be a no-op (if it stayed on) or the only input path with no way back (if it stayed off). Neither is shippable."
  got=$(cat "$node") ||
    fail "could not read ${node} after '${helper} ${verb}'"
  [[ $got == "$want" ]] ||
    fail "'${helper} ${verb}' reported success but ${node} reads '${got}', expected '${want}'. The helper is not verifying its own write."
  log "verified: '${helper} ${verb}' left ${node} at ${want}"
}

# Put the node back the way this stage found it, THROUGH THE HELPER, so the
# restore is itself verified rather than assumed.
#
# Warns and returns non-zero rather than calling `fail`: its main caller is an
# EXIT trap, where the process is already on its way out with a status that
# means something, and a second exit would hide the first failure.
lizard_restore() {   # lizard_restore <helper> <node> <Y|N>
  local helper=$1 node=$2 want=$3 verb got
  case $want in
    Y) verb=on ;;
    N) verb=off ;;
    *) warn "cannot restore lizard mode to '${want}': not a value the node takes"; return 1 ;;
  esac
  if ! $SUDO "$helper" "$verb"; then
    warn "COULD NOT RESTORE lizard mode to '${want}'. If it is currently N and deck-input-mapper is not running, this device has NO pointer and NO keys -- run 'sudo ${LIZARD_HELPER} on' over SSH."
    return 1
  fi
  if ! got=$(cat "$node"); then
    warn "ran '${helper} ${verb}' to restore lizard mode but could not re-read ${node} to confirm it"
    return 1
  fi
  if [[ $got != "$want" ]]; then
    warn "tried to restore lizard mode to '${want}' but ${node} reads '${got}'. If that is N and deck-input-mapper is not running, run 'sudo ${LIZARD_HELPER} on' over SSH."
    return 1
  fi
  log "restored lizard mode to ${want} -- the value this stage found"
  return 0
}

# Exercise the installed helper BOTH WAYS and leave the machine as it was found.
# Takes the helper and the node for the reason set out in "THE VERIFICATION
# SEAM" above verify_update_stub.
#
# ⚠️ THE RESTORE IS THE POINT, not politeness. A stage that returned 0 having
# left lizard mode off, with no mapper running, would itself be the hazard the
# whole design exists to avoid: a handheld with no input, installed by the thing
# that was supposed to make input safe.
verify_lizard_helper() {
  local helper=${1:-$LIZARD_HELPER}
  local node=${2:-$LIZARD_SYSFS}

  # World-readable 0644, so this needs no privilege -- and reading it directly
  # rather than through ${SUDO} keeps the check honest on a machine where sudo
  # is the thing that is broken.
  [[ -e $node ]] ||
    fail "${node} does not exist, so lizard mode cannot be exercised. hid_steam is not loaded, or this is not a Deck. Refusing to install a fallback that has never been run."

  local before
  before=$(cat "$node") || fail "could not read ${node}"
  case $before in
    Y|N) ;;
    *) fail "${node} reads '${before}', which is neither Y nor N. Something other than this project is driving that parameter; stopping rather than guessing what to put back." ;;
  esac
  log "lizard mode is ${before} right now; this check restores that value before it returns"

  # From here to `trap - EXIT` the node may be at a value the machine did not
  # start with, and every `fail` below is an exit. So the restore is a TRAP, not
  # a line at the bottom: a line at the bottom is unreachable from exactly the
  # paths that need it most.
  #
  # shellcheck disable=SC2064  # expanded NOW on purpose: the trap has to carry
  # this call's own helper, node and pre-run value, not whatever those names
  # happen to mean at exit time.
  trap "lizard_restore $(printf '%q %q %q' "$helper" "$node" "$before") || true" EXIT

  # OFF first, then ON, so the last thing this does before restoring is hand
  # input back to the firmware. If the process is killed between the two, the
  # device is left usable.
  #
  # ⚠️ The 'off' step opens a window -- one `cat` long -- where lizard mode is
  # off and no mapper is running, i.e. the device has no input. It is
  # unavoidable: "exercise the helper both ways" and "never leave input in an
  # unproven state" cannot both be had without turning it off once. Keep the
  # window this short.
  lizard_expect "$helper" "$node" off N
  lizard_expect "$helper" "$node" on  Y

  trap - EXIT
  lizard_restore "$helper" "$node" "$before" ||
    fail "could not restore lizard mode to '${before}' after verifying it. Do not reboot expecting this to clear if it is N and the mapper is not running -- run 'sudo ${LIZARD_HELPER} on' now."

  log "verified: the helper drives ${node} both ways, reads back, and the value it started at (${before}) is restored"
}

# Prove the sudoers grant works, without running the helper again.
#
# Takes the helper for the same seam reason; ${LIZARD_HELPER} is never executed
# here, only asked about.
verify_lizard_grant() {
  local helper=${1:-$LIZARD_HELPER}
  [[ $EUID -ne 0 ]] || return 0   # already root; nothing to prove

  # -K first, for the reason verify_nopasswd documents: a probe that passes on a
  # warm credential cache proves nothing about the drop-in.
  sudo -K 2>/dev/null || true

  local verb
  for verb in off on; do
    # `sudo -n -l <cmd> <args>` asks whether the grant covers this exact
    # invocation WITHOUT running it. The args matter here: the grant names
    # 'on' and 'off' explicitly, so asking about the bare path would answer a
    # question nobody asks.
    sudo -n -l "$helper" "$verb" >/dev/null 2>&1 ||
      fail "installed ${LIZARD_SUDOERS} but sudo will not run '${helper} ${verb}' without a password. deck-input-mapper.service is a USER unit, so its ExecStartPost=/ExecStopPost= run as the desktop user and would hang or fail. Inspect that drop-in."
  done

  # Honesty check, same as verify_nopasswd's and for the same reason: this Deck
  # carries /etc/sudoers.d/99-deck-testing (PROGRESS.md 5.17), under which the
  # probe above passes no matter what we wrote.
  if sudo -n -l /usr/bin/true >/dev/null 2>&1; then
    warn "this user already has broad passwordless sudo, so the check above does NOT prove ${LIZARD_SUDOERS} is what granted it. The grant is installed but unverified."
  else
    log "verified: the desktop user may run the helper 'on' and 'off' with no password, via ${LIZARD_SUDOERS}"
  fi

  if [[ $INTERACTIVE -eq 1 ]]; then
    sudo -v 2>/dev/null || true
  fi
}

stage_lizard_mode() {
  # Installs the four pieces that make "lizard mode is off IF AND ONLY IF the
  # mapper is running" true, and nothing else:
  #
  #   1. ${LIZARD_HELPER}        validates, writes, reads back, fails loudly
  #   2. ${LIZARD_SUDOERS}       the desktop user may run exactly that, both ways
  #   3. ${LIZARD_RESTORE_UNIT}  a separate unit, so a separate CGROUP -- the
  #                              half that survives a cgroup-wide SIGKILL
  #   4. ${LIZARD_DROPIN}        deck-input-mapper.service's own ExecStartPost=/
  #                              ExecStopPost=/OnFailure=
  #
  # It deliberately does NOT start, restart or enable anything. Starting the
  # mapper from here would turn lizard mode off on a live machine on the
  # strength of a service nobody has watched work, which is precisely the
  # decision 5.25 says belongs to the operator, in front of the Deck.
  #
  # THE DESTINATION AND THE SYSFS NODE ARE PARAMETERS -- see "THE VERIFICATION
  # SEAM" above verify_update_stub. Production passes nothing and gets
  # ${LIZARD_HELPER} and ${LIZARD_SYSFS}.
  local helper=${1:-$LIZARD_HELPER}
  local node=${2:-$LIZARD_SYSFS}

  assert_ours_or_absent "$helper" "something else"
  assert_ours_or_absent "$LIZARD_DROPIN" "something else"
  assert_ours_or_absent "$LIZARD_RESTORE_UNIT" "something else"
  assert_ours_or_absent "$LIZARD_SUDOERS" "another package's sudoers drop-in"

  # A drop-in for a unit that does not exist is inert: installed, valid, and
  # doing nothing. stage-input-mapper runs immediately before this one in
  # INSTALL_STAGES, but a single-stage run can reach here without it.
  $SUDO test -f "$MAPPER_UNIT" ||
    fail "${MAPPER_UNIT} is not installed, so ${LIZARD_DROPIN} would never apply and lizard mode would be turned off by nothing and back on by nothing. Run 'stage-input-mapper' first."

  # --- 1. the helper ---
  log "installing the lizard-mode helper: ${helper}"
  $SUDO install -d -m 0755 -o root -g root "$(dirname "$helper")" ||
    fail "could not create $(dirname "$helper")"

  local tmp
  tmp=$(mktemp) || fail "mktemp failed"
  render_lizard_helper "$node" >"$tmp" ||
    fail "could not render the lizard-mode helper"
  $SUDO install -m 0755 -o root -g root "$tmp" "$helper" ||
    fail "could not install ${helper}"
  rm -f "$tmp"

  # --- 2. the sudoers grant ---
  #
  # deck-input-mapper.service is a USER unit (/etc/systemd/user), so its
  # ExecStartPost= and ExecStopPost= run as the desktop user. Something has to
  # bridge that to a root-only sysfs write, and this is the same narrow-sudoers
  # tradeoff the header of this file already argues for ${SELECT_BIN}.
  local invoking_user=${SUDO_USER:-${USER:-$(id -un)}}
  [[ -n $invoking_user && $invoking_user != root ]] ||
    fail "could not determine the desktop user (got '${invoking_user}'); run this as that user via sudo, not as root directly"

  log "granting ${invoking_user} NOPASSWD on '${LIZARD_HELPER} on|off' only"
  tmp=$(mktemp) || fail "mktemp failed"
  cat >"$tmp" <<EOF
${INSTALL_MARKER}
# Installed by ${PROG}.sh. Lets deck-input-mapper.service -- a USER unit, so its
# ExecStartPost=/ExecStopPost= run unprivileged -- turn the controller
# firmware's lizard mode off while it is running and back on when it stops.
#
# Scoped to one absolute path AND to its two legal arguments. The helper
# validates its own argv and refuses everything else, so this is a second,
# independent boundary rather than the only one. The node it writes is baked
# into the helper at install time and is not reachable from its argv, so this
# grant cannot become "write Y or N to an arbitrary file as root".
#
# The helper is root-owned 0755: a user who could rewrite it already has root.
${invoking_user} ALL=(root) NOPASSWD: ${LIZARD_HELPER} on, ${LIZARD_HELPER} off
EOF

  # A malformed sudoers file breaks sudo for every user on the machine. Never
  # install one unvalidated -- check the candidate before it is in place.
  $SUDO visudo -c -f "$tmp" >/dev/null ||
    fail "generated sudoers snippet failed validation -- refusing to install it. Candidate left at ${tmp}"
  $SUDO install -m 0440 -o root -g root "$tmp" "$LIZARD_SUDOERS" ||
    fail "could not install ${LIZARD_SUDOERS}"
  rm -f "$tmp"

  # --- 3. the OnFailure unit ---
  #
  # Installed BEFORE the drop-in that names it, so there is never a moment where
  # OnFailure= points at a unit that does not exist. Neither is active, so the
  # ordering costs nothing and removes a state nobody would think to check.
  local restore_name=${LIZARD_RESTORE_UNIT##*/}
  log "installing the OnFailure unit: ${LIZARD_RESTORE_UNIT}"
  $SUDO install -d -m 0755 -o root -g root "$(dirname "$LIZARD_RESTORE_UNIT")" ||
    fail "could not create $(dirname "$LIZARD_RESTORE_UNIT")"
  tmp=$(mktemp) || fail "mktemp failed"
  render_lizard_restore_unit >"$tmp" ||
    fail "could not render the lizard-mode restore unit"
  $SUDO install -m 0644 -o root -g root "$tmp" "$LIZARD_RESTORE_UNIT" ||
    fail "could not install ${LIZARD_RESTORE_UNIT}"
  rm -f "$tmp"

  # --- 4. the drop-in ---
  log "installing the systemd drop-in: ${LIZARD_DROPIN}"
  $SUDO install -d -m 0755 -o root -g root "$(dirname "$LIZARD_DROPIN")" ||
    fail "could not create $(dirname "$LIZARD_DROPIN")"
  tmp=$(mktemp) || fail "mktemp failed"
  render_lizard_dropin >"$tmp" ||
    fail "could not render the lizard-mode drop-in"
  $SUDO install -m 0644 -o root -g root "$tmp" "$LIZARD_DROPIN" ||
    fail "could not install ${LIZARD_DROPIN}"
  rm -f "$tmp"

  # A drop-in on disk is not a drop-in systemd has read.
  local unit_name=${MAPPER_UNIT##*/}
  if systemctl --user daemon-reload 2>/dev/null; then
    log "reloaded this user's systemd manager so ${unit_name} picks the drop-in up"
  else
    warn "could not reload this user's systemd manager. Over SSH with no session that is normal and the drop-in applies from the next desktop session; inside the desktop it means ${unit_name} is still running without its fallback."
  fi

  # Ask systemd what it actually PARSED, when there is a manager to ask. This is
  # the only check that can see the '-' prefix question at all: `ignore_errors`
  # is systemd's own report of whether a failure here would be swallowed, and a
  # swallowed ExecStartPost= is a mapper running against a silent device.
  #
  # All four questions are asked together, because they are one property split
  # across two files: ExecStopPost= covers the ordinary deaths, OnFailure= covers
  # the cgroup-wide SIGKILL that kills ExecStopPost=, and a fallback that is
  # only half parsed is a fallback with a hole nobody can see from the disk.
  local parsed
  parsed=$(systemctl --user show "$unit_name" -p ExecStopPost --value 2>/dev/null) || parsed=""
  if [[ -z $parsed ]]; then
    warn "this user's systemd manager cannot report ${unit_name}'s ExecStopPost=, so the drop-in and ${restore_name} were verified as FILE CONTENT only. Re-check inside a desktop session with 'systemctl --user show ${unit_name} -p ExecStopPost -p OnFailure'."
  else
    [[ $parsed == *"${LIZARD_HELPER} on"* ]] ||
      fail "systemd parsed ${unit_name} with ExecStopPost=${parsed}, which does not run '${LIZARD_HELPER} on'. Without it a mapper that dies leaves lizard mode off, and the device with no input."
    [[ $parsed != *"ignore_errors=yes"* ]] ||
      fail "systemd parsed ${unit_name}'s ExecStopPost= with ignore_errors=yes -- something prefixed it with '-'. A silently ignored failure here is exactly the fallback not working, on the one path that has to."

    local on_failure
    on_failure=$(systemctl --user show "$unit_name" -p OnFailure --value 2>/dev/null) || on_failure=""
    [[ $on_failure == *"$restore_name"* ]] ||
      fail "systemd parsed ${unit_name} with OnFailure=${on_failure:-<empty>}, which does not name ${restore_name}. ExecStopPost= alone does NOT survive a cgroup-wide SIGKILL -- 'systemctl kill -s SIGKILL' defaults to killing the whole cgroup, and it takes ExecStopPost= with it. Without OnFailure= that path leaves lizard mode off with nothing reading the pad."

    # The unit OnFailure= names has to be one systemd can actually load. A
    # nonexistent or unparseable target makes OnFailure= a line that resolves to
    # nothing, and systemd reports that only when it tries to trigger it -- i.e.
    # in the failure, which is the worst possible time to find out.
    local restore_load
    restore_load=$(systemctl --user show "$restore_name" -p LoadState --value 2>/dev/null) || restore_load=""
    [[ $restore_load == loaded ]] ||
      fail "systemd reports ${restore_name} as LoadState=${restore_load:-<empty>}, not 'loaded'. OnFailure= would then resolve to nothing, and would say so only at the moment it was needed."

    local restore_exec
    restore_exec=$(systemctl --user show "$restore_name" -p ExecStart --value 2>/dev/null) || restore_exec=""
    [[ $restore_exec == *"${LIZARD_HELPER} on"* ]] ||
      fail "systemd parsed ${restore_name} with ExecStart=${restore_exec:-<empty>}, which does not run '${LIZARD_HELPER} on'. The unit exists and does not restore anything."
    [[ $restore_exec != *"ignore_errors=yes"* ]] ||
      fail "systemd parsed ${restore_name}'s ExecStart= with ignore_errors=yes -- something prefixed it with '-'. The last line of defence must not be the one that fails quietly."

    log "verified: systemd parses ${unit_name} with an ExecStopPost= AND an OnFailure=${restore_name} that both restore lizard mode, neither ignoring errors"
  fi

  verify_lizard_grant "$helper"
  verify_lizard_helper "$helper" "$node"

  log "stage-lizard-mode: ok"
  log "NOTE: nothing was started. Lizard mode is still whatever it was, and goes"
  log "      off only when deck-input-mapper.service next starts -- and back on"
  log "      when it stops, crashes or is killed, by ExecStopPost= or, when a"
  log "      cgroup-wide SIGKILL takes that with it, by ${restore_name}."
  log "      A reboot restores it too: the parameter does not persist."
}

# ---------------------------------------------------------------------------

render_dconf_site_file() {
  cat <<EOF
${INSTALL_MARKER}
#
# Site defaults for the Deck. These are DEFAULTS, not locks: a user may still
# change them, and a user-level value shadows everything here.

[org/gnome/desktop/a11y/applications]
# squeekboard's auto-show gate. Ships false; without it the on-screen keyboard
# never appears on text focus, and nothing logs a reason.
screen-keyboard-enabled=true

[org/gnome/desktop/input-sources]
# squeekboard warns 'No system layout' and has no keys to draw without this.
sources=[('xkb','us')]
EOF
}

# The Hyprland Lua that pins OUR virtual keyboard, and nothing else, to `us`.
#
# THE SHAPE IS MEASURED, not guessed. Hyprland 0.56.2 replaced the old
# `device:<name> { ... }` config section with a Lua call, and the argument is a
# FLAT table with a required `name` -- `hl.device(spec: HL.DeviceSpec)` in
# /usr/share/hypr/stubs/hl.meta.lua, backed by `m_deviceConfigs` in
# src/config/lua/ConfigManager.hpp. Probed live on the Deck:
#
#   hyprctl eval 'hl.device({ kb_layout = "us" })'
#     -> error: hl.device: 'name' field is required and must be a string
#   hyprctl eval 'hl.device(7)'
#     -> error: hl.device: argument must be a table
#
# 🔴 THE ANTI-NO-OP DESIGN, which is the point of the sentinel on the last
# line. `hl.device` VALIDATES: the binary carries
# "hl.device: unknown field '{}'", so a misspelt field raises rather than being
# ignored, and a raise aborts the rest of the chunk -- which means the sentinel
# assignment below never runs. So "the rule silently did nothing" and "the
# sentinel is absent" are the same observable, and verify_osk_kb_layout turns
# that into a loud failure. A block that cannot be wrong quietly.
#
# kb_variant/kb_model/kb_rules are pinned EXPLICITLY rather than left to
# inherit. Unset device fields fall back to the global option
# (`getDeviceString(dev, field, fallback)`), and inheriting a variant chosen for
# a different layout is how you get a keymap that fails to compile -- on this
# Deck the global variant is empty, but the ISO installs whatever the user
# picked and nothing here may depend on it being empty.
render_osk_kb_layout_lua() {
  local names="\"${OSK_HYPR_DEVICE}\"" i
  for ((i = 1; i <= OSK_HYPR_DEVICE_ALIASES; i++)); do
    names="${names}, \"${OSK_HYPR_DEVICE}-${i}\""
  done

  cat <<EOF
${OSK_KB_RULE_BEGIN}
${INSTALL_MARKER_LUA}
--
-- The on-screen keyboard draws a US layout and emits raw KEYCODES through
-- ${MAPPER_BIN}'s uinput device. Which character a keycode becomes is decided
-- by the XKB keymap bound to that device, so on a Latin American session the
-- OSK's ';' key types 'n-tilde'. This pins OUR virtual keyboard, and only it,
-- to '${OSK_KB_LAYOUT}'. Physical keyboards and the rest of the desktop keep the session
-- layout -- do NOT "simplify" this into input.kb_layout, which would change
-- every keyboard on the machine.
--
-- The suffixed names are not padding: this uinput device declares keys AND
-- relative axes, so Hyprland binds it twice and appends -1/-2/... to whichever
-- copy loses the race for the bare name. Attaching the rule to only one of them
-- would work until the order flipped, and then fail with no error anywhere.
for _, deck_osk_device in ipairs({ ${names} }) do
  hl.device({
    name = deck_osk_device,
    kb_layout = "${OSK_KB_LAYOUT}",
    kb_variant = "",
    kb_model = "",
    kb_rules = "",
  })
end

-- Deliberately the LAST line: hl.device raises on an unknown field, and a raise
-- skips everything after it. Its absence in a live compositor therefore means
-- the rule above did not take. deck-session.sh asserts it with
--   hyprctl eval 'if ${OSK_KB_SENTINEL} ~= "${OSK_KB_LAYOUT}" then error("...") end'
-- because eval reports Lua errors and cannot report values.
${OSK_KB_SENTINEL} = "${OSK_KB_LAYOUT}"
${OSK_KB_RULE_END}
EOF
}

# run_as_desktop_user <user> <cmd...>
#
# ⚠️ `$SUDO -u <user> …` is NOT enough on its own. stage_preconditions sets
# SUDO="" when this script is ALREADY root, so under `sudo ./deck-session.sh`
# that expansion degrades to running `-u` as a command -- "bash: -u: command not
# found", i.e. a write that never happens. Dropping privilege needs sudo
# precisely in the case where $SUDO is empty, which is the opposite of every
# other use of it in this file.
#
# (The three `$SUDO -u` calls further down stage_desktop_settings predate this
# and carry the same hazard. They are left alone deliberately -- changing them
# is a separate change with its own tests -- but do not copy them.)
run_as_desktop_user() {
  local user=$1; shift
  if [[ -n $SUDO ]]; then
    "$SUDO" -u "$user" "$@"
  elif [[ $EUID -eq 0 ]]; then
    command -v sudo >/dev/null 2>&1 ||
      fail "running as root and sudo is not available, so nothing can be written as ${user}. A root-owned file in their ~/.config would be worse than none."
    sudo -u "$user" "$@"
  else
    fail "cannot run as ${user}: this process is neither root nor holding an escalation path (SUDO is empty and EUID is ${EUID}). stage-preconditions sets that up; running a stage without it would write the wrong file as the wrong user."
  fi
}

# install_osk_kb_layout_rule <desktop-user> <path to input.lua> [template]
#
# Splices the block above into the user's Hyprland input config, replacing any
# previous copy of itself. Everything outside the markers is preserved
# byte-for-byte, which matters more here than anywhere else in this file: on the
# test Deck that same file carries the `above_lock = 2` layer rule, and losing it
# makes the lock screen unanswerable on a device with no physical keyboard.
install_osk_kb_layout_rule() {
  local user=$1
  local target=$2
  local template=${3:-$HYPR_INPUT_LUA_TEMPLATE}

  # The two names must stay in step: OSK_UINPUT_NAME is what the mapper
  # declares, OSK_HYPR_DEVICE is what a rule matches. Deriving one and comparing
  # it to the other means a mapper rename tracked in only one of them stops the
  # stage instead of shipping a rule that matches no device.
  local derived=${OSK_UINPUT_NAME,,}
  derived=${derived// /-}
  [[ $derived == "$OSK_HYPR_DEVICE" ]] ||
    fail "the uinput device name '${OSK_UINPUT_NAME}' normalises to '${derived}', but the rule matches '${OSK_HYPR_DEVICE}'. Hyprland lowercases the name and turns spaces into dashes; a rule naming anything else matches no device and does nothing at all."

  local block tmp
  block=$(mktemp) || fail "mktemp failed"
  render_osk_kb_layout_lua >"$block" ||
    fail "could not render the on-screen keyboard's layout rule"

  tmp=$(mktemp) || { rm -f "$block"; fail "mktemp failed"; }

  # Not sed/awk: the markers have to be matched as whole lines and an
  # unterminated previous block has to be refused rather than half-deleted.
  python3 - "$target" "$block" "$template" "$OSK_KB_RULE_BEGIN" "$OSK_KB_RULE_END" >"$tmp" <<'PY' || {
import pathlib, sys
target, block, template = (pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]),
                           pathlib.Path(sys.argv[3]))
begin, end = sys.argv[4], sys.argv[5]

if target.exists():
    body, source = target.read_text(), "existing"
elif template.exists():
    body, source = template.read_text(), "template"
else:
    body, source = "", "empty"

kept, skipping = [], False
for line in body.splitlines():
    if line.strip() == begin:
        skipping = True
        continue
    if skipping:
        if line.strip() == end:
            skipping = False
        continue
    kept.append(line)
if skipping:
    sys.exit(f"{target} has our start marker and no end marker. Refusing to guess "
             "where the old block ended -- remove it by hand and re-run.")

text = "\n".join(kept).rstrip("\n")
sys.stdout.write((text + "\n\n") if text else "")
sys.stdout.write(block.read_text())
sys.stderr.write(f"seeded-from: {source}\n")
PY
    rm -f "$block" "$tmp"
    fail "could not splice the keyboard-layout rule into ${target}"
  }
  rm -f "$block"

  # A Lua syntax error does not fail loudly: Hyprland discards the file and
  # falls back, which here means losing the user's whole input.lua -- the
  # above_lock rule included. This is the same trap stage-greeter-rotation was
  # written after, with a worse blast radius.
  if command -v luac >/dev/null 2>&1; then
    local luaerr
    if ! luaerr=$(luac -p "$tmp" 2>&1); then
      rm -f "$tmp"
      fail "the patched ${target} is not valid Lua: ${luaerr}. Refusing to install it -- Hyprland discards a config it cannot parse WITHOUT logging a reason, so this would silently take the on-screen keyboard's above_lock rule down with it."
    fi
    log "verified: the patched ${target} parses as Lua"
  else
    warn "luac not found, so the patched ${target} was NOT syntax-checked. A Lua syntax error there is silent: Hyprland discards the whole file, which would drop the OSK's above_lock rule as well as this one. Install the 'lua' package to enable this check."
  fi

  chmod 0644 "$tmp" || { rm -f "$tmp"; fail "could not make the staged ${target} readable by ${user}"; }
  log "installing the on-screen keyboard's layout rule: ${target}"
  run_as_desktop_user "$user" install -D -m 0644 "$tmp" "$target" || {
    rm -f "$tmp"
    fail "could not install ${target} as ${user}"
  }
  rm -f "$tmp"

  grep -qxF -- "$OSK_KB_RULE_END" "$target" ||
    fail "${target} does not carry '${OSK_KB_RULE_END}' after being installed. The write reported success and the file does not have the rule in it."
}

# verify_osk_kb_layout <desktop-user> <uid> [runtime-dir]
#
# 🔴 The runtime directory is a PARAMETER, and that is a safety property rather
# than a testing convenience: with the constant baked in, running the unit suite
# on any developer machine that happens to run Hyprland would reload THAT
# person's live desktop. See "THE VERIFICATION SEAM" above verify_update_stub.
#
# Three outcomes, and only one of them is silence-free by accident:
#   - no live compositor  -> WARN, loudly, with the command to run later. The
#                            rule is on disk and applies to the next session;
#                            claiming it works would be the lie.
#   - live, sentinel gone -> FAIL. The block did not execute.
#   - live, wrong layout  -> FAIL, naming what the device actually reads.
verify_osk_kb_layout() {
  local user=$1 uid=$2
  local runtime_dir=${3:-/run/user/${uid}}

  local manual="hyprctl -j devices"

  local sig="" d
  for d in "$runtime_dir"/hypr/*/; do
    [[ -S "${d}.socket.sock" ]] || continue
    d=${d%/}
    sig=${d##*/}
  done

  if [[ -z $sig ]]; then
    warn "no live Hyprland instance under ${runtime_dir}/hypr, so the keyboard-layout rule is installed but has NOT been observed working. It applies to ${user}'s next session. Check it there with: ${manual} -- the '${OSK_HYPR_DEVICE}' keyboard must read layout '${OSK_KB_LAYOUT}' while every other keyboard keeps the session layout."
    return 0
  fi

  command -v hyprctl >/dev/null 2>&1 ||
    fail "a Hyprland instance is live (${sig}) but hyprctl is not on PATH, so the rule this stage just installed cannot be checked at all. Refusing to report success for a keyboard nobody has seen type."

  # ⚠️ HYPRLAND_INSTANCE_SIGNATURE is not optional. Without it hyprctl exits
  # before doing anything (R-46), and a check that never ran reads exactly like
  # a check that passed.
  local -a hy=(env "XDG_RUNTIME_DIR=${runtime_dir}" "HYPRLAND_INSTANCE_SIGNATURE=${sig}" hyprctl)

  # `config-only` so this does not churn the monitors on a live desktop. The
  # reload is what makes the readback below mean anything: without it we would
  # be reading whatever was loaded before this stage wrote the file.
  "${hy[@]}" reload config-only >/dev/null 2>&1 ||
    fail "'hyprctl reload config-only' failed against instance ${sig}. The rule is written to disk but the running session has not picked it up, and this stage will not call that success."

  # The sentinel. eval cannot RETURN a value on 0.56.2 -- it prints 'ok' and
  # exits 0 for `return <anything>`, nil included -- but it does surface a Lua
  # error as exit 7. So assert, do not read.
  local evalout
  if ! evalout=$("${hy[@]}" eval "if ${OSK_KB_SENTINEL} ~= '${OSK_KB_LAYOUT}' then error('${OSK_KB_SENTINEL} is not \"${OSK_KB_LAYOUT}\"') end" 2>&1); then
    fail "the running compositor does not have ${OSK_KB_SENTINEL} set to '${OSK_KB_LAYOUT}' (${evalout}). That global is the LAST line of the block this stage installed, so its absence means the block did not run to the end -- either Hyprland discarded the file, or hl.device raised on it. The keyboard is still typing the session layout."
  fi
  log "verified: ${OSK_KB_SENTINEL} is set in the live compositor, so the whole rule block executed"

  local devices global
  devices=$("${hy[@]}" -j devices 2>&1) ||
    fail "could not read 'hyprctl -j devices' from instance ${sig}: ${devices}"
  global=$("${hy[@]}" -j getoption input:kb_layout 2>&1) ||
    fail "could not read 'hyprctl -j getoption input:kb_layout' from instance ${sig}: ${global}"

  # ⚠️ The "did it stay per-device?" half is not decoration. A rule that leaked
  # into the global input config would look PERFECT from our own device's row
  # and would have changed every physical keyboard on the machine.
  local verdict
  verdict=$(python3 - "$OSK_HYPR_DEVICE" "$OSK_HYPR_DEVICE_ALIASES" "$OSK_KB_LAYOUT" "$devices" "$global" <<'PY'
import json, sys

base, aliases, want, devices_json, global_json = sys.argv[1:6]
names = {base} | {"%s-%d" % (base, i) for i in range(1, int(aliases) + 1)}
try:
    keyboards = json.loads(devices_json).get("keyboards", [])
    global_layout = json.loads(global_json).get("str", "")
except ValueError as exc:
    sys.exit("hyprctl did not return JSON: %s" % exc)

# No keyboards at all is not "our device is missing" -- it is a device list
# worth drawing no conclusion from, so say so instead of reporting absence.
if not keyboards:
    sys.exit("hyprctl reported no keyboards at all")

ours = [k for k in keyboards if k.get("name") in names]
others = [k for k in keyboards if k.get("name") not in names]
if not ours:
    print("absent")
elif [k for k in ours if k.get("layout") != want]:
    print("wrong %s" % [k for k in ours if k.get("layout") != want][0].get("layout"))
elif global_layout != want and [k for k in others if k.get("layout") == want]:
    print("sessionwide %s" % [k for k in others if k.get("layout") == want][0].get("name"))
else:
    print("ok %d" % len(others))
PY
) || fail "could not read the keyboard layouts back out of hyprctl's device list"

  case $verdict in
    absent*)
      warn "no keyboard named '${OSK_HYPR_DEVICE}' is bound right now, so the rule could not be observed taking effect. That is what a stopped deck-input-mapper.service looks like -- the rule is correct and inert until the mapper runs. Start it and re-check with: ${manual}"
      ;;
    wrong\ *)
      fail "the keyboard '${OSK_HYPR_DEVICE}' reads layout '${verdict#wrong }', not '${OSK_KB_LAYOUT}'. The rule loaded (the sentinel is set) and did not attach to this device -- most likely the name it matches has changed. Compare ${OSK_HYPR_DEVICE} against '${manual}'."
      ;;
    sessionwide\ *)
      fail "the keyboard '${verdict#sessionwide }' also reads '${OSK_KB_LAYOUT}' while the session's own input:kb_layout does not. This rule went SESSION-WIDE instead of per-device, which is exactly what it must not do: every physical keyboard on the machine just changed layout."
      ;;
    ok*)
      log "verified: '${OSK_HYPR_DEVICE}' reads layout '${OSK_KB_LAYOUT}' and ${verdict#ok } other keyboard(s) kept the session layout"
      ;;
    *)
      fail "unexpected verdict '${verdict}' from the device-list check; refusing to guess whether the keyboard works"
      ;;
  esac
}

# Mask omarchy-sleep-lock.service for every user of this image. Read the
# SLEEP_LOCK_* constants above first -- the WHY is there, and it is a security
# decision, not a tidy-up.
#
# THE DESTINATION IS A PARAMETER -- see "THE VERIFICATION SEAM" above
# verify_update_stub. Production passes nothing and gets ${SLEEP_LOCK_GLOBAL_MASK};
# the unit suite passes a path under its fake root, because the read-back below
# resolves the symlink DIRECTLY rather than through $SUDO and would otherwise
# be inspecting the developer's real /etc.
install_sleep_lock_mask() {
  local mask=${1:-$SLEEP_LOCK_GLOBAL_MASK}

  # Idempotent, and it has to be: this stage is re-run by the SSH iterate loop
  # and again by every image build. `ln -sfn` alone would be idempotent too,
  # but it would also silently replace whatever else is there -- so look first.
  if [[ -L $mask ]]; then
    local existing
    existing=$(readlink -- "$mask") ||
      fail "${mask} is a symlink that cannot be read; refusing to guess what it points at"
    if [[ $existing == /dev/null ]]; then
      log "${SLEEP_LOCK_UNIT} is already masked at ${mask}"
      return 0
    fi
    fail "${mask} is a symlink to '${existing}', not to /dev/null. Something else owns this path -- an alias or a drop-in, not a mask. Refusing to replace it; remove it by hand if it is stale, then re-run."
  elif [[ -e $mask ]]; then
    fail "${mask} exists and is not a symlink, so it is a real unit file overriding ${SLEEP_LOCK_UNIT} rather than masking it. Refusing to replace it; move it aside by hand, then re-run."
  fi

  log "masking ${SLEEP_LOCK_UNIT} for every user: ${mask} -> /dev/null"
  $SUDO install -d -m 0755 -o root -g root "$(dirname "$mask")" ||
    fail "could not create $(dirname "$mask")"
  # -n matters: without it, an existing symlink-to-a-directory at $mask would
  # make ln create the link INSIDE that directory, and the mask would land at a
  # name systemd never looks up. The branches above already refuse that case;
  # -n is the second line of defence, and costs nothing.
  $SUDO ln -sfn /dev/null "$mask" ||
    fail "could not create the mask symlink ${mask}"

  # Read it back rather than trusting the write, for one specific reason:
  # systemd treats ONLY a symlink to /dev/null as a mask. A regular empty file
  # at the same path loads as a unit with no directives -- which is not masked,
  # starts nothing, and looks identical in a directory listing. Anything that
  # produced that instead would be a silent no-op, and the device would lock on
  # resume with every file the installer promised present.
  [[ -L $mask ]] ||
    fail "${mask} is not a symlink after installing it; systemd masks a unit only via a symlink to /dev/null, so the sleep lock would still run"
  local got
  got=$(readlink -- "$mask") ||
    fail "could not read back ${mask} after installing it"
  [[ $got == /dev/null ]] ||
    fail "${mask} points at '${got}', not /dev/null -- that is not a mask, and the Deck would lock on resume with no way to unlock it"
  log "verified: ${mask} is a symlink to /dev/null, so ${SLEEP_LOCK_UNIT} is masked for every user, including ones this image has not created yet"
}

stage_desktop_settings() {
  # Installs the settings that decide whether the on-screen keyboard works, what
  # it TYPES, and whether the Deck can lock itself out -- when idle, and when it
  # is suspended, which are two separate producers. See the constants
  # above for why each one exists; every one of them was discovered by something
  # failing on a screen, and none of them fails a test today.
  #
  # BOTH PARAMETERS ARE SEAMS, not options a Deck ever passes: the XKB rule's
  # verification talks to a LIVE compositor, and hardcoding /run/user/<uid> would
  # make the unit suite reload the desktop of whoever ran it; the sleep-lock mask
  # is read back at an absolute path, which off-Deck is the developer's own /etc.
  # Production passes nothing. See "THE VERIFICATION SEAM" above
  # verify_update_stub.
  local hypr_runtime=${1:-}
  local sleep_lock_mask=${2:-}

  command -v dconf >/dev/null 2>&1 ||
    fail "dconf not found; the on-screen keyboard's defaults cannot be installed"
  command -v python3 >/dev/null 2>&1 ||
    fail "python3 not found; ${OMARCHY_SHELL_JSON_REL} must be edited as JSON, not by regex"

  # --- 1. the dconf profile ---
  #
  # Without a profile naming a system-db, dconf reads ONLY the user database and
  # every default below is inert. The file is absent on a stock Omarchy install,
  # so this is a creation, not an edit.
  if [[ -e $DCONF_PROFILE ]]; then
    if grep -qx "system-db:local" "$DCONF_PROFILE"; then
      log "dconf profile already reads the site database"
    else
      # Appending blind could reorder somebody else's profile, and profile order
      # is precedence. Refuse rather than guess.
      fail "${DCONF_PROFILE} exists but does not list 'system-db:local'; merge it by hand -- profile order is precedence and this stage will not guess"
    fi
  else
    log "creating ${DCONF_PROFILE} so site defaults are read at all"
    local tmp
    tmp=$(mktemp) || fail "mktemp failed"
    printf 'user-db:user\nsystem-db:local\n' >"$tmp"
    $SUDO install -D -m 0644 -o root -g root "$tmp" "$DCONF_PROFILE" ||
      fail "could not install ${DCONF_PROFILE}"
    rm -f "$tmp"
  fi

  # --- 2. the site defaults ---
  assert_ours_or_absent "$DCONF_SITE_FILE" "another package's dconf defaults"

  log "installing site defaults: ${DCONF_SITE_FILE}"
  local tmp
  tmp=$(mktemp) || fail "mktemp failed"
  render_dconf_site_file >"$tmp" || fail "could not render the dconf site defaults"
  $SUDO install -D -m 0644 -o root -g root "$tmp" "$DCONF_SITE_FILE" ||
    fail "could not install ${DCONF_SITE_FILE}"
  rm -f "$tmp"

  # dconf keyfiles do nothing until compiled into the binary database.
  $SUDO dconf update || fail "dconf update failed; the site defaults are on disk but not compiled"

  # --- verify the DEFAULT, not the effective value ---
  #
  # This is the whole reason `-d` is here. `gsettings get` (or a plain
  # `dconf read`) returns the USER's value when one exists, so on any machine
  # where someone once ran `gsettings set` by hand -- this test Deck, for
  # instance -- the check would pass while the site default was missing or
  # wrong. That is precisely the "passes for the wrong reason" failure this
  # project keeps finding. `-d` ignores the user database.
  local got
  got=$(dconf read -d "$OSK_KEY" 2>/dev/null || true)
  [[ $got == "true" ]] ||
    fail "site default for ${OSK_KEY} reads '${got:-<empty>}', not 'true' -- the OSK would never auto-show for a new user"
  got=$(dconf read -d "$INPUT_SOURCES_KEY" 2>/dev/null || true)
  [[ $got == *"'xkb'"* && $got == *"'us'"* ]] ||
    fail "site default for ${INPUT_SOURCES_KEY} reads '${got:-<empty>}' -- squeekboard would have no layout to draw"
  log "verified: both on-screen-keyboard defaults are set in the SITE database"

  # A user-level value shadows the site default. Warn only when it actually
  # DISAGREES: an override that matches changes nothing, and warning about it
  # would fire on every run and teach the operator to ignore the message.
  #
  # ⚠️ Compare effective against default -- do NOT test "does a user value
  # exist". A plain `dconf read` resolves through the whole profile, so it
  # returns the site default too and would report an override for every user.
  # Isolating the user database by pointing DCONF_PROFILE at a nonexistent file
  # does not work either: dconf then reads NO database and always returns empty,
  # which is a check that cannot fail. Both were tried on hardware.
  local eff dflt
  eff=$(dconf read "$OSK_KEY" 2>/dev/null || true)
  dflt=$(dconf read -d "$OSK_KEY" 2>/dev/null || true)
  [[ $eff == "$dflt" ]] ||
    warn "${OSK_KEY} resolves to '${eff}' for this user but the site default is '${dflt}'. A user-level value is shadowing it, and the on-screen keyboard follows the user value -- 'dconf reset ${OSK_KEY}' to fall back to the default this stage installs."

  # --- 3. the two lock producers: suspend (B) and idle (A) ---
  #
  # They are INDEPENDENT and neither covers the other (T13 §5.2): the idle
  # policy is a timer inside the Quickshell idle service, the sleep lock is a
  # systemd unit holding a --mode=delay inhibitor on logind's PrepareForSleep
  # that calls the same `omarchy-shell lock lock` IPC from outside that service
  # entirely. Setting idle.lock has no effect on the sleep path and masking the
  # unit has no effect on the idle path. They are adjacent here because a reader
  # who fixes one and stops has fixed half a defect.
  local invoking_user=${SUDO_USER:-${USER:-$(id -un)}}
  [[ -n $invoking_user && $invoking_user != root ]] ||
    fail "could not determine the desktop user (got '${invoking_user}'); run this as that user via sudo, not as root directly"
  local home
  home=$(getent passwd "$invoking_user" | cut -d: -f6) ||
    fail "could not resolve ${invoking_user}'s home directory"
  [[ -n $home ]] || fail "empty home directory for ${invoking_user}"
  local shell_json="${home}/${OMARCHY_SHELL_JSON_REL}"

  # --- 3a. the SUSPEND producer, masked at image level ---
  #
  # First of the two, because it is the one whose failure is unrecoverable: an
  # idle lock takes five minutes to arrive and the power button takes one press.
  install_sleep_lock_mask ${sleep_lock_mask:+"$sleep_lock_mask"}

  # A user unit file SHADOWS the /etc one -- ~/.config/systemd/user comes first
  # in systemd's search path. Warn only when it actually DISAGREES, for the same
  # reason the dconf check below does: the operator's own Deck carries a
  # hand-made mask at exactly this path (P22 §3.1), and a warning that fires on
  # a file which agrees with us teaches the operator to ignore the message.
  local user_unit="${home}/${SLEEP_LOCK_USER_UNIT_REL}"
  if [[ -e $user_unit || -L $user_unit ]]; then
    if [[ -L $user_unit && $(readlink -- "$user_unit") == /dev/null ]]; then
      log "${invoking_user} also has a per-user mask at ${user_unit}; it agrees with ours and is now redundant, not wrong"
    else
      warn "${user_unit} exists and is not a mask. ~/.config/systemd/user comes BEFORE /etc/systemd/user in systemd's search path, so this file shadows the mask this stage just installed and ${SLEEP_LOCK_UNIT} may still lock the Deck on resume. Remove it, or replace it with a symlink to /dev/null."
    fi
  fi

  # --- 3b. the IDLE producer ---

  # A user shell.json REPLACES Omarchy's defaults rather than merging with them,
  # so writing a file containing only an idle block would silently strip the
  # bar. Seed from the shipped defaults when absent, and patch in place
  # otherwise.
  if [[ ! -e $shell_json ]]; then
    [[ -e $OMARCHY_SHELL_JSON_DEFAULTS ]] ||
      fail "${shell_json} is absent and ${OMARCHY_SHELL_JSON_DEFAULTS} does not exist to seed from; writing an idle-only file would strip the bar"
    log "seeding ${shell_json} from Omarchy's shipped defaults"
    $SUDO -u "$invoking_user" install -D -m 0644 "$OMARCHY_SHELL_JSON_DEFAULTS" "$shell_json" ||
      fail "could not seed ${shell_json}"
  fi

  log "setting Omarchy idle policy: screensaver=${IDLE_SCREENSAVER_SECONDS}s lock=${IDLE_LOCK_SECONDS}s"
  $SUDO -u "$invoking_user" python3 - "$shell_json" "$IDLE_SCREENSAVER_SECONDS" "$IDLE_LOCK_SECONDS" <<'PY' ||
import json, sys, pathlib
path, screensaver, lock = pathlib.Path(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
try:
    cfg = json.loads(path.read_text())
except (OSError, ValueError) as exc:
    sys.exit(f"could not parse {path} as JSON: {exc}")
if not isinstance(cfg, dict):
    sys.exit(f"{path} is not a JSON object")
# Patch only the idle block. Everything else -- bar layout, plugins, version --
# belongs to the user and a rewrite would silently drop it.
idle = cfg.setdefault("idle", {})
idle["screensaver"], idle["lock"] = screensaver, lock
path.write_text(json.dumps(cfg, indent=2) + "\n")
PY
    fail "could not patch the idle policy into ${shell_json}"

  # Re-read as the shell will, rather than trusting the write.
  local check
  check=$($SUDO -u "$invoking_user" python3 - "$shell_json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
idle = cfg.get("idle", {})
print(idle.get("screensaver"), idle.get("lock"), len(cfg))
PY
  ) || fail "could not re-read ${shell_json} after writing it"
  local want="${IDLE_SCREENSAVER_SECONDS} ${IDLE_LOCK_SECONDS}"
  [[ $check == "$want "* ]] ||
    fail "${shell_json} reads back as '${check}', expected '${want} ...' -- the idle policy did not take"
  [[ ${check##* } -gt 1 ]] ||
    fail "${shell_json} now has only ${check##* } top-level key(s); the rest of the config was lost, which would strip the bar"
  log "verified: ${shell_json} carries the idle policy and kept ${check##* } top-level keys"

  # --- 4. what the on-screen keyboard actually TYPES ---
  #
  # Separate from the dconf input source above, and not a duplicate of it: that
  # one gives squeekboard a layout to DRAW, this one tells the compositor which
  # character our uinput device's keycodes mean.
  local uid
  uid=$(getent passwd "$invoking_user" | cut -d: -f3) ||
    fail "could not resolve ${invoking_user}'s uid"
  [[ $uid =~ ^[0-9]+$ ]] ||
    fail "getent reported a non-numeric uid ('${uid}') for ${invoking_user}; the compositor's runtime directory cannot be located from it"

  install_osk_kb_layout_rule "$invoking_user" "${home}/${HYPR_INPUT_LUA_REL}"
  verify_osk_kb_layout "$invoking_user" "$uid" ${hypr_runtime:+"$hypr_runtime"}

  log "stage-desktop-settings: ok"
  log "NOTE: Omarchy re-reads shell.json live (FileView watchChanges), but the"
  log "      dconf defaults apply to sessions started AFTER this, and any"
  log "      user-level value keeps shadowing them until it is reset."
  log "NOTE: the keyboard layout rule is PER DEVICE. Physical keyboards and the"
  log "      rest of the desktop keep the session layout; only"
  log "      '${OSK_HYPR_DEVICE}' is pinned to '${OSK_KB_LAYOUT}'."
  log "NOTE: ${SLEEP_LOCK_UNIT} is masked, so this Deck RESUMES FROM SLEEP"
  log "      UNLOCKED, deliberately -- it has no keyboard and no unlock IPC."
  log "      A lock the user asks for (System menu, SUPER+CTRL+L) still works."
  log "      A unit already running in this session keeps running; the mask"
  log "      applies from the next graphical session on."
}

# ---------------------------------------------------------------------------

# The .desktop entry's body. Split out as a render_* function for the reason
# every other one here was: the string that matters (Exec=) has a second copy
# in the Quickshell menu row, and assert_return_action_agrees compares what is
# RENDERED rather than what a comment claims is rendered.
#
# The marker goes on line 1 as a '#' comment: the Desktop Entry spec ignores
# comment lines and does not require the group header to be first, and
# desktop-file-validate accepts it (asserted in
# test/unit/test-deck-session-stages.sh \u00a75).
render_return_desktop() {
  cat <<EOF
${INSTALL_MARKER}
[Desktop Entry]
Type=Application
Name=${RETURN_LABEL}
Comment=${RETURN_DESCRIPTION}
Exec=${RETURN_ACTION}
Icon=input-gaming
Terminal=false
Categories=Game;
Keywords=steam;gaming;gamescope;deck;
EOF
}

stage_return_icon() {
  # A .desktop entry is the shell-agnostic half of "return to Gaming Mode":
  # every launcher on every shell reads /usr/share/applications, so this works
  # identically on Omarchy 3.x (waybar-era) and on 4.0's Quickshell rewrite.
  #
  # Icon=input-gaming, and both halves of that are deliberate.
  #
  # It RESOLVES: the previous value `steamicon` matched nothing on this system
  # (the installed files are steam.png), so the entry showed a broken icon.
  # Verified against /usr/share/icons rather than assumed.
  #
  # And it is NOT Valve artwork. `steam` would resolve, but
  # docs/findings/P16-redistribution-and-trademark.md says not to ship Valve's
  # iconography. input-gaming is a standard freedesktop name.
  #
  # \u26a0\ufe0f THIS COMMENT USED TO SAY pinning "is deliberately NOT done here" and
  # described the Quickshell menu row as future work. That stopped being true
  # when stage-menu-row landed: the SHELL-SPECIFIC half is now
  # ${PROG}.sh stage-menu-row, which splices a row into
  # ~/${MENU_EXT_REL} (and /etc/skel's copy). The two halves share
  # ${RETURN_ACTION} through one constant and stage-menu-row refuses to run if
  # they have drifted apart.
  #
  # This stage used to be the one that silently clobbered: no marker in the file
  # it wrote and no ownership check in front of the write, so a .desktop that
  # some other package (or a user) had put at this path was overwritten without
  # a word. Every other stage refuses that, and now so does this one.
  assert_ours_or_absent "$RETURN_DESKTOP_FILE" "another package's desktop entry"

  log "installing ${RETURN_DESKTOP_FILE}"
  local tmp
  tmp=$(mktemp) || fail "mktemp failed"
  render_return_desktop >"$tmp" || fail "could not render the return-to-Gaming .desktop entry"
  $SUDO install -m 0644 -o root -g root "$tmp" "$RETURN_DESKTOP_FILE" ||
    fail "could not install ${RETURN_DESKTOP_FILE}"
  rm -f "$tmp"
  log "stage-return-icon: ok"
  log "NOTE: the Quickshell menu row is the shell-specific half and is installed"
  log "      by '${PROG}.sh stage-menu-row', which runs next in a full install."
}

# ---------------------------------------------------------------------------
# THE QUICKSHELL MENU ROW
# ---------------------------------------------------------------------------
#
# \ud83d\udd34 WHY THIS STAGE VALIDATES WHAT IT WRITES, read out of the pinned runtime:
#
#   MenuModel.js:parseMenuJsonc   try { JSON.parse(stripped) } catch (e) { return [] }
#   Menu.qml (user FileView)      printErrors: false
#
# A malformed extension file therefore drops EVERY user row and reports nothing,
# anywhere. Our row would simply not be there and nothing would say why -- this
# project's cardinal failure mode (docs/PROGRESS.md \u00a75.30c). So the file is
# parsed after it is written and the row is read back out of it, the way
# deck-session-select greps its own three keys back out of the SDDM drop-in.
#
# What is emitted is strict, comment-free JSON for the row itself (which is
# valid JSONC), because stripJsonc only removes WHOLE-LINE '//' comments and
# trailing commas: a comment after a value on the same line breaks the parse.

# The marker-delimited block spliced into the extension file. Everything about
# its shape is load-bearing:
#
#   - whole-line '//' comments only, so stripJsonc removes them cleanly;
#   - the row itself is strict JSON on ONE line;
#   - it ends with a trailing comma, which stripJsonc removes when our block is
#     the only content and which separates entries when it is not. That is what
#     lets the block be spliced in at a fixed position (immediately after the
#     object's opening brace) whether the rest of the file is empty or full.
render_menu_row_block() {
  cat <<EOF
${MENU_ROW_BEGIN}
${INSTALL_MARKER_JSONC}
// The controller-only way back to Gaming Mode. Everything between these two
// markers is rewritten by ${PROG}.sh; edit outside them.
// Remove the row by deleting these lines, or by adding your own "${MENU_ROW_ID}"
// entry below -- a later duplicate key wins in JSON.
"${MENU_ROW_ID}": {"icon": "${MENU_ROW_ICON}", "label": "${RETURN_LABEL}", "action": "${RETURN_ACTION}", "description": "${RETURN_DESCRIPTION}"},
${MENU_ROW_END}
EOF
}

# The two halves of "return to Gaming Mode" must run the SAME command.
#
# Compared from what is rendered, not from the constants, because a constant
# both sides agree on proves nothing if one of the heredocs stopped using it.
# This is cheap and it runs before anything is written.
assert_return_action_agrees() {
  local from_desktop from_menu line

  from_desktop=""
  while IFS= read -r line; do
    [[ $line == Exec=* ]] || continue
    from_desktop=${line#Exec=}
    break
  done < <(render_return_desktop)
  [[ -n $from_desktop ]] ||
    fail "render_return_desktop emits no Exec= line at all, so the .desktop entry launches nothing. Refusing to install a menu row that claims to match it."

  from_menu=$(render_menu_row_block | python3 -c '
import json, re, sys
raw = sys.stdin.read()
raw = re.sub(r"^\s*//[^\n]*(\n|$)", "", raw, flags=re.M)
raw = re.sub(r",(\s*$)", r"\1", raw)
try:
    row = json.loads("{" + raw + "}")
except ValueError as exc:
    sys.exit("the rendered menu row is not valid JSON: %s" % exc)
sys.stdout.write(list(row.values())[0].get("action", ""))
') || fail "could not read the action back out of the rendered menu row block"

  [[ $from_desktop == "$RETURN_ACTION" ]] ||
    fail "${RETURN_DESKTOP_FILE}'s Exec= renders as '${from_desktop}' but the shared constant is '${RETURN_ACTION}'. The two ways back to Gaming Mode have drifted; whichever is wrong does nothing at all and reports no error."
  [[ $from_menu == "$RETURN_ACTION" ]] ||
    fail "the Quickshell menu row's action renders as '${from_menu}' but the shared constant is '${RETURN_ACTION}'. The two ways back to Gaming Mode have drifted; whichever is wrong does nothing at all and reports no error."
  [[ $from_menu == "$from_desktop" ]] ||
    fail "the .desktop entry runs '${from_desktop}' and the menu row runs '${from_menu}'. They must be the same command."
  log "verified: the .desktop entry and the menu row both run '${RETURN_ACTION}'"
}

# splice_menu_row <existing-or-absent path> <block file>  -> new content on stdout
#
# \u26a0\ufe0f A SPLICE, NOT A REWRITE, and that is the whole answer to "do not clobber".
#
# This file is a DOCUMENTED, user-facing extension point, and on a stock Omarchy
# it already exists: the shipped template is all comments and parses to {}. So
# assert_ours_or_absent cannot be used here -- it would refuse on every stock
# install, which is a stage that never runs. Rewriting the file as strict JSON
# would work and would silently delete the schema documentation in it, plus any
# comment the user wrote.
#
# So this preserves every byte outside its own markers, exactly as
# install_osk_kb_layout_rule does for input.lua. No JSONC merger is invented:
# the row is inserted immediately after the object's opening brace as text, and
# the RESULT is then parsed the way Quickshell parses it. A file that would not
# parse is never installed.
#
# It refuses, loudly, on the three cases where a splice cannot be honest:
#   - the existing file does not parse (Quickshell is ALREADY silently dropping
#     every row in it -- that gets said out loud);
#   - our begin marker is present with no end marker (do not guess where the
#     old block ended);
#   - the file is not a JSON object at all.
splice_menu_row() {
  local target=$1 block=$2

  python3 - "$target" "$block" "$MENU_ROW_BEGIN" "$MENU_ROW_END" \
           "$MENU_ROW_ID" "$RETURN_ACTION" "$INSTALL_MARKER_JSONC" <<'PY'
import json, pathlib, re, sys

target, block = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
begin, end, row_id, action, marker = sys.argv[3:8]

# Quickshell's own two transformations, copied from
# shell/plugins/menu/MenuModel.js:stripJsonc at the pinned runtime.
COMMENT = re.compile(r"^\s*//[^\n]*(\n|$)", re.M)
TRAILING = re.compile(r",(\s*[}\]])")


def strip_jsonc(text):
    return TRAILING.sub(r"\1", COMMENT.sub("", text))


def parse(text, what):
    stripped = strip_jsonc(text)
    if not stripped.strip():
        return {}
    try:
        value = json.loads(stripped)
    except ValueError as exc:
        sys.exit(
            f"{what} is not valid JSONC ({exc}).\n"
            "  Quickshell does not report this: MenuModel.js catches the parse error and\n"
            "  returns an empty list, and Menu.qml sets printErrors: false -- so EVERY row\n"
            "  in that file is being silently discarded right now, not just ours.\n"
            "  Fix it or move it aside, then re-run this stage."
        )
    if not isinstance(value, dict):
        sys.exit(f"{what} parses as {type(value).__name__}, not a JSON object of menu ids")
    return value


raw = target.read_text() if target.exists() else ""

# Validate what is already there BEFORE touching it, so a file that was already
# broken is reported as already broken rather than blamed on this stage.
parse(raw, str(target))

kept, skipping, seen = [], False, False
for line in raw.splitlines():
    if line.strip() == begin:
        skipping, seen = True, True
        continue
    if skipping:
        if line.strip() == end:
            skipping = False
        continue
    kept.append(line)
if skipping:
    sys.exit(
        f"{target} carries our start marker with no end marker. Refusing to guess where "
        "the old block ended -- remove it by hand and re-run."
    )

block_lines = block.read_text().splitlines()

# Where the object opens. Whole-line comments and blanks are skipped; the first
# line with content must open the object, and '{' must be the first thing on it.
opener = None
for i, line in enumerate(kept):
    bare = line.strip()
    if not bare or bare.startswith("//"):
        continue
    if not bare.startswith("{"):
        sys.exit(
            f"{target} does not open with a JSON object (first content line is {line!r}). "
            "The Quickshell menu extension is an object of menu ids; refusing to splice into "
            "something else."
        )
    opener = (i, line.index("{"))
    break

out = []
if opener is None:
    # No object at all: an absent file, or one that is nothing but comments and
    # has already lost its braces. Anything that WAS there is kept above the new
    # object only if it is comments, which is exactly what `kept` holds here.
    out.extend(kept)
    out.append(marker)
    out.append("{")
    out.extend(block_lines)
    out.append("}")
else:
    i, col = opener
    out.extend(kept[:i])
    out.append(kept[i][: col + 1])
    out.extend(block_lines)
    rest = kept[i][col + 1 :]
    if rest.strip():
        out.append(rest)
    out.extend(kept[i + 1 :])

text = "\n".join(out).rstrip("\n") + "\n"

# The check this whole stage exists for: parse the RESULT the way Quickshell
# will, and refuse to hand back something it would silently discard.
merged = parse(text, "the patched " + str(target))
if row_id not in merged:
    sys.exit(f"the patched {target} parses but has no '{row_id}' row in it")
got = merged[row_id].get("action")
if got != action:
    sys.exit(
        f"the patched {target} parses but '{row_id}' runs {got!r}, not {action!r}. "
        "A row with the wrong action is the worst outcome here: it appears in the menu, "
        "it is pressable, and it does not switch the session."
    )

sys.stdout.write(text)
sys.stderr.write("replaced-existing-block\n" if seen else "inserted-new-block\n")
PY
}

# verify_menu_row <path> -- read the row back out of an INSTALLED file.
#
# The path is a parameter and the caller passes the USER's copy, never skel's:
# docs/tasks/T5-fork-plan.md \u00a73 trap (a) is explicit that a check reading only
# /etc/skel is the check that passes on a Deck whose only user never got the file.
verify_menu_row() {
  local path=${1:?verify_menu_row needs the file to read}

  local got
  got=$(python3 - "$path" "$MENU_ROW_ID" <<'PY'
import json, pathlib, re, sys
path, row_id = pathlib.Path(sys.argv[1]), sys.argv[2]
if not path.exists():
    sys.exit(f"{path} does not exist after being installed")
raw = path.read_text()
stripped = re.sub(r",(\s*[}\]])", r"\1", re.sub(r"^\s*//[^\n]*(\n|$)", "", raw, flags=re.M))
try:
    menu = json.loads(stripped)
except ValueError as exc:
    sys.exit(f"{path} does not parse as JSONC after being installed: {exc}")
if row_id not in menu:
    sys.exit(f"{path} parses but carries no '{row_id}' row (ids: {sorted(menu)})")
sys.stdout.write(menu[row_id].get("action", ""))
PY
  ) || fail "could not read the '${MENU_ROW_ID}' row back out of ${path}. Quickshell reports nothing when this file is wrong, so an unverified write here is an unverified feature."

  [[ $got == "$RETURN_ACTION" ]] ||
    fail "${path} carries a '${MENU_ROW_ID}' row whose action is '${got}', not '${RETURN_ACTION}'. The row would appear in the menu and not switch the session."
  log "verified: ${path} parses as Quickshell parses it and '${MENU_ROW_ID}' runs '${RETURN_ACTION}'"
}

stage_menu_row() {
  # PLACEMENT: a ROOT row ("${MENU_ROW_ID}"), not "system.${MENU_ROW_ID}".
  #
  # Two presses versus one, on the one affordance CLAUDE.md's controller-only
  # rule cannot let fail. Under System it would sit beside lock/restart, which
  # is the tidier taxonomy and the wrong tradeoff: this is the way OUT of the
  # desktop on a device whose owner is expected to spend most of its life in
  # Gaming Mode. MenuModel.js appends new ids to the END of the root order, so
  # it lands last on the root menu and reorders nothing Omarchy ships.
  command -v python3 >/dev/null 2>&1 ||
    fail "python3 not found; ${MENU_EXT_REL} must be edited and validated as JSON, not by regex -- and an unvalidated write here is silently discarded by Quickshell"

  # Before anything is written: the two ways back must run the same command.
  assert_return_action_agrees

  local invoking_user=${SUDO_USER:-${USER:-$(id -un)}}
  [[ -n $invoking_user && $invoking_user != root ]] ||
    fail "could not determine the desktop user (got '${invoking_user}'); run this as that user via sudo, not as root directly"
  local home
  home=$(getent passwd "$invoking_user" | cut -d: -f6) ||
    fail "could not resolve ${invoking_user}'s home directory"
  [[ -n $home ]] || fail "empty home directory for ${invoking_user}"

  local user_ext="${home}/${MENU_EXT_REL}"

  # \u26a0\ufe0f NOT seeded from Omarchy's shipped template when absent, and the contrast
  # with shell.json is the reason. A user shell.json REPLACES Omarchy's
  # defaults, so an idle-only file strips the bar. This file MERGES:
  # mergeMenuSources(defaults, user) walks the defaults first and then the user
  # file, so a file containing nothing but our row is complete and safe.
  local block tmp
  block=$(mktemp) || fail "mktemp failed"
  render_menu_row_block >"$block" || { rm -f "$block"; fail "could not render the menu row"; }

  local dest
  for dest in "$user_ext" "$MENU_EXT_SKEL"; do
    tmp=$(mktemp) || { rm -f "$block"; fail "mktemp failed"; }

    # The skel copy is read through $SUDO (it is root-owned); the user's own
    # file is read directly, which is correct in both contexts this stage runs
    # in -- as the user under sudo (EUID 0) or as the user with $SUDO set.
    local existing=$dest
    if [[ $dest == "$MENU_EXT_SKEL" ]]; then
      if $SUDO test -e "$dest"; then
        $SUDO cat "$dest" >"$tmp.in" 2>/dev/null || { rm -f "$block" "$tmp"; fail "could not read ${dest}"; }
      else
        : >"$tmp.in"
      fi
      existing="$tmp.in"
    fi

    log "splicing the '${MENU_ROW_ID}' row into ${dest}"
    splice_menu_row "$existing" "$block" >"$tmp" || {
      rm -f "$block" "$tmp" "$tmp.in"
      fail "refusing to install ${dest}: the merged file would not survive Quickshell's own parser (see the message above). Nothing was written."
    }
    chmod 0644 "$tmp" || { rm -f "$block" "$tmp" "$tmp.in"; fail "could not stage ${dest}"; }

    if [[ $dest == "$MENU_EXT_SKEL" ]]; then
      $SUDO install -D -m 0644 -o root -g root "$tmp" "$dest" ||
        { rm -f "$block" "$tmp" "$tmp.in"; fail "could not install ${dest}"; }
    else
      run_as_desktop_user "$invoking_user" install -D -m 0644 "$tmp" "$dest" ||
        { rm -f "$block" "$tmp"; fail "could not install ${dest} as ${invoking_user}"; }
    fi
    rm -f "$tmp" "$tmp.in"
  done
  rm -f "$block"

  # \ud83d\udd34 The USER's copy is what gets verified. /etc/skel is too late for the user
  # the ISO creates (T5 \u00a73 trap (a)), so a check that read skel's copy would
  # pass on precisely the Deck where the row is missing.
  verify_menu_row "$user_ext"

  log "stage-menu-row: ok"
  log "NOTE: the row lands at the END of the root menu (new ids are appended),"
  log "      it runs '${RETURN_ACTION}', and Omarchy re-reads this file live."
  log "NOTE: /etc/skel's copy is for users created LATER. The user the ISO"
  log "      creates already exists by our phase, which is why ${user_ext}"
  log "      is written and verified separately."
}

# ---------------------------------------------------------------------------

# Does one sudoers line hand out effectively-unrestricted root?
#
# Split out as a pure predicate so test/unit/test-deck-session.sh can exercise
# it with no Deck and no root. Takes the line, returns 0 if it is blanket.
#
# "Blanket" means the command spec is ALL. It deliberately does NOT try to
# judge whether a *named* command is dangerous, because that judgement is
# hopeless: this project's own audit trail shows the install stages legitimately
# running `install` against /etc/sudoers.d/, and a NOPASSWD grant on `install`,
# `tee`, `cp` or `chmod` is full root by a longer route. See
# docs/findings/P16-repo-overlap-audit.md's sibling note in PROGRESS.md 5.17.
# So this flags the honest case and leaves the rest to a human.
sudoers_line_is_blanket() {
  local line=$1
  # Strip comments and surrounding whitespace.
  line=${line%%#*}
  line=${line#"${line%%[![:space:]]*}"}
  line=${line%"${line##*[![:space:]]}"}
  [[ -n $line ]] || return 1
  # Defaults lines are settings, not grants.
  [[ $line == Defaults* ]] && return 1
  # A grant looks like:  <who> <host>=(<runas>) [NOPASSWD:] <commands>
  # Blanket iff the command spec, after the last ':' or ')', is exactly ALL.
  local cmds=${line##*)}
  cmds=${cmds##*:}
  cmds=${cmds#"${cmds%%[![:space:]]*}"}
  cmds=${cmds%"${cmds##*[![:space:]]}"}
  [[ $cmds == ALL ]]
}

# Does the line grant its commands WITHOUT a password?
#
# Split from the blanket test because the two combine differently, and getting
# that wrong makes the release check unusable. `deck ALL=(ALL) ALL` is blanket
# but password-protected -- it is the ordinary admin grant every Arch/Omarchy
# install ships, and failing a release on it would be a false positive that
# teaches people to ignore the check. The hazard is blanket AND passwordless.
sudoers_line_is_nopasswd() {
  local line=$1
  line=${line%%#*}
  [[ $line == *NOPASSWD:* ]]
}

# NOT in INSTALL_STAGES. This installs nothing and is for release verification
# (T6) and for answering PROGRESS.md 5.17 on a given machine.
stage_audit_privileges() {
  log "auditing sudoers grants under /etc/sudoers.d"
  local f found=0 line
  local -a passwordless=() with_password=()

  while IFS= read -r f; do
    [[ -n $f ]] || continue
    while IFS= read -r line; do
      sudoers_line_is_blanket "$line" || continue
      if sudoers_line_is_nopasswd "$line"; then
        passwordless+=("${f##*/}: ${line}")
      else
        with_password+=("${f##*/}: ${line}")
      fi
    done < <($SUDO cat "$f" 2>/dev/null)
    found=$((found + 1))
  done < <($SUDO sh -c 'ls -1 /etc/sudoers.d/* 2>/dev/null')

  log "inspected ${found} drop-in(s)"

  # Informational, deliberately NOT a failure: this is the ordinary admin grant
  # every Arch/Omarchy install ships. Failing on it would be the false positive
  # that teaches people to ignore this check.
  local b
  for b in "${with_password[@]}"; do
    log "blanket grant, password required (normal): ${b}"
  done

  if [[ ${#passwordless[@]} -eq 0 ]]; then
    log "no PASSWORDLESS blanket grants -- nothing here would ship unrestricted root"
    log "stage-audit-privileges: ok"
    return 0
  fi

  for b in "${passwordless[@]}"; do
    warn "PASSWORDLESS BLANKET ROOT: ${b}"
  done
  fail "${#passwordless[@]} sudoers drop-in(s) grant unrestricted root with NO password. On this dev Deck that is deliberate (PROGRESS.md 5.17 -- the iterate-in-place loop needs it), but an ISO that ships one is not a product. Exclude them from the image before release."
}

stage_default_session() {
  # Deliberately NOT in INSTALL_STAGES. Flipping the default is the one
  # irreversible-feeling step: autologin is enabled, so SDDM shows no session
  # picker, and a Gaming Mode that fails to start leaves no graphical way
  # back. Run it explicitly, only after both directions are proven to work.
  log "setting the default session to Gaming Mode (${GAMING_SESSION})"
  $SUDO "$SELECT_BIN" gamescope --no-restart ||
    fail "could not set the default session"
  log "default session set. It takes effect on the next login or reboot."
  log "To undo: sudo ${SELECT_BIN} desktop --no-restart"
  log "If Gaming Mode fails to start, Ctrl+Alt+F2 reaches a TTY."
  log "NOTE: Steam's own Power -> 'Switch to Desktop' REWRITES this default."
  log "      '${PROG}.sh stage-boot-default-gaming' re-asserts it at every boot,"
  log "      which is what makes Desktop Mode a one-shot session like SteamOS's."
}

# ---------------------------------------------------------------------------
# A REBOOT ALWAYS LANDS IN GAMING MODE
# ---------------------------------------------------------------------------
#
# THE DECISION (operator, 2026-08-12). Steam's Power -> "Switch to Desktop"
# ultimately drives ${STEAM_SHIM}, which rewrites Session= in ${SDDM_DROPIN} --
# it undoes stage-default-session, permanently, from a menu the user reaches in
# two presses. Stock SteamOS does not behave that way: its desktop is a one-shot
# session and a reboot returns to Gaming Mode. This makes that true here.
#
# 🔴 IT RE-RUNS THE EXISTING WRITER. `${SELECT_BIN} gamescope --no-restart`, not
# a second copy of the same write. That writer already checks the target
# session's .desktop exists before committing, and already re-reads Session=,
# User= and Relogin= back out of the drop-in. A second implementation of one
# write is the drift this project keeps paying for -- see the two halves of
# "return to Gaming Mode" and assert_return_action_agrees, in this file, one
# session ago.
#
# --no-restart is not an optimisation: the restart path hands sddm to a
# transient unit, and doing that from a unit ordered BEFORE sddm has even
# started would be a race against a display manager that does not exist yet.
# All the boot-time re-assert has to do is write the config sddm is about to
# read.
render_boot_default_unit() {
  cat <<EOF
${INSTALL_MARKER}
#
# Re-assert Gaming Mode as the default session, once per boot, BEFORE the
# display manager reads its configuration.
#
# ORDERING IS THE WHOLE UNIT. Landing after sddm has read /etc/sddm.conf.d is a
# silent no-op: the write succeeds, the journal says so, and the machine logs
# into the desktop anyway. Determined from the units on disk rather than from
# habit --
#
#   /usr/lib/systemd/system/sddm.service   [Install] Alias=display-manager.service
#   /etc/systemd/system/display-manager.service -> ../../../usr/lib/systemd/system/sddm.service
#   graphical.target                       Wants=display-manager.service
#                                          After=display-manager.service
#
# so graphical.target is what pulls the display manager in, both names resolve
# to the same unit, and being Before= it inside that same transaction is what
# guarantees the write happens first. Both names are listed because ordering
# against a unit that does not exist is a silent no-op in systemd, and the alias
# only exists once sddm has been enabled.
#
# WantedBy=graphical.target, NOT WantedBy=${BOOT_DEFAULT_BEFORE_REAL}: a session
# SWITCH restarts sddm, and a unit wanted by sddm would be dragged into that
# restart and fight the switch the user just asked for. Wanted by the target, it
# runs once per boot and stays active for the rest of it -- which is exactly
# "Desktop Mode is a one-shot session".
#
# FAILURE IS LOUD BUT NOT FATAL. Nothing Requires= this unit, so if
# ${SELECT_BIN} dies (no gamescope session on the machine, say) the unit fails,
# sddm still starts, and the Deck still boots -- into whatever the default was.
# A failed unit is this project's established no-terminal signal: it survives a
# reboot and shows up in \`systemctl --failed\` (the same reasoning as
# omarchy-deck-patch-check.service). ExecStart carries NO leading '-'.
#
# THE ESCAPE HATCH is the ConditionPathExists=! below. With this unit enabled a
# broken Gaming Mode is re-asserted on EVERY boot, so there has to be a way out
# that needs no editor:
#
#   sudo touch ${BOOT_DEFAULT_OVERRIDE}
#
# skips it from the next boot on, and \`systemctl status ${BOOT_DEFAULT_UNIT_NAME}\`
# then says out loud that a condition skipped it. \`sudo systemctl disable
# ${BOOT_DEFAULT_UNIT_NAME}\` is the permanent form.

[Unit]
Description=Re-assert Gaming Mode as the default session before the display manager starts
Documentation=file://${BOOT_DEFAULT_UNIT}
Before=${BOOT_DEFAULT_BEFORE_ALIAS}
Before=${BOOT_DEFAULT_BEFORE_REAL}
After=local-fs.target
ConditionPathExists=!${BOOT_DEFAULT_OVERRIDE}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${SELECT_BIN} gamescope --no-restart
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=graphical.target
EOF
}

# verify_boot_default_ordering [unit-name]
#
# Ask systemd what it PARSED, not what we wrote. stage_sddm_resilience
# established this: a drop-in that looks right and did not apply is the failure
# mode, and only the manager can tell the difference. The unit name is a
# parameter so the unit suite can point this at a name its stub answers for.
#
# Both directions are checked, and the second is the one that matters: a unit
# ordered AFTER the display manager parses cleanly, starts cleanly, logs a
# successful write, and does nothing at all.
verify_boot_default_ordering() {
  local unit=${1:-$BOOT_DEFAULT_UNIT_NAME}
  local before after

  before=$(systemctl show "$unit" -p Before --value 2>/dev/null) ||
    fail "systemctl could not report ${unit}'s ordering. The unit is on disk; whether systemd will run it before the display manager is unknown, and an unknown here is a silent no-op."
  after=$(systemctl show "$unit" -p After --value 2>/dev/null) || after=""

  # ⚠️ THE ORDER OF THESE THREE GUARDS IS DELIBERATE, and it is the session-16
  # lesson: they share an exit code, so whichever fires first is the whole
  # diagnosis a human gets. A unit ordered AFTER the display manager also names
  # neither unit in Before=, so the generic "names neither" message would fire
  # first and describe the symptom instead of the cause. Most specific first.
  [[ $after != *"$BOOT_DEFAULT_BEFORE_ALIAS"* && $after != *"$BOOT_DEFAULT_BEFORE_REAL"* ]] ||
    fail "systemd parsed ${unit} with After='${after}', i.e. ordered AFTER the display manager. That is the silent no-op this unit exists to avoid -- sddm reads ${SDDM_DROPIN} at start, so a write that lands afterwards changes nothing until the boot after next."

  [[ -n $before ]] ||
    fail "systemd reports NO Before= ordering for ${unit} at all. Either the unit did not load or the ordering directives were dropped -- either way the re-assert would race the display manager."

  [[ $before == *"$BOOT_DEFAULT_BEFORE_ALIAS"* || $before == *"$BOOT_DEFAULT_BEFORE_REAL"* ]] ||
    fail "systemd parsed ${unit} with Before='${before}', which names neither ${BOOT_DEFAULT_BEFORE_ALIAS} nor ${BOOT_DEFAULT_BEFORE_REAL}. The re-assert would land after sddm had already read its configuration: the write succeeds, nothing complains, and the Deck boots to the desktop anyway."

  log "verified: systemd orders ${unit} before the display manager (Before='${before}')"
}

# NOT in INSTALL_STAGES, and deliberately -- same reasoning as
# stage_default_session, which it is meant to be run beside.
#
# stage_default_session is excluded because flipping the default is the one
# irreversible-feeling step: autologin means no session picker, so a Gaming Mode
# that fails to start leaves no graphical way back. This stage carries that same
# risk on EVERY boot rather than on one, so if anything the argument for keeping
# it opt-in is stronger, not weaker. A bare `./deck-session.sh` on a machine
# whose Gaming Mode has never been proven would otherwise arm a boot-time
# re-assert nobody asked for.
#
# The pair is the intended usage:
#   sudo ./deck-session.sh stage-default-session        (now)
#   sudo ./deck-session.sh stage-boot-default-gaming    (and at every boot)
stage_boot_default_gaming() {
  # The unit runs the writer stage-session-select installs. Without it the unit
  # would fail at every boot with a 203/EXEC nobody would connect to this.
  $SUDO test -x "$SELECT_BIN" ||
    fail "${SELECT_BIN} is not installed or not executable. Run '${PROG}.sh stage-session-select' first -- this stage only schedules that writer, it does not contain a second copy of it."

  assert_ours_or_absent "$BOOT_DEFAULT_UNIT" "another package's unit"

  # The escape hatch has to be one `touch` at a TTY, so its directory exists
  # before anyone needs it. Creating it does NOT arm the override: the unit
  # checks for the FILE.
  $SUDO install -d -m 0755 -o root -g root "$(dirname "$BOOT_DEFAULT_OVERRIDE")" ||
    fail "could not create $(dirname "$BOOT_DEFAULT_OVERRIDE") -- the escape hatch has to be reachable with a single 'touch' from a TTY"

  log "installing ${BOOT_DEFAULT_UNIT}"
  local tmp
  tmp=$(mktemp) || fail "mktemp failed"
  render_boot_default_unit >"$tmp" || fail "could not render ${BOOT_DEFAULT_UNIT_NAME}"
  $SUDO install -D -m 0644 -o root -g root "$tmp" "$BOOT_DEFAULT_UNIT" ||
    fail "could not install ${BOOT_DEFAULT_UNIT}"
  rm -f "$tmp"

  $SUDO systemctl daemon-reload ||
    fail "systemctl daemon-reload failed; ${BOOT_DEFAULT_UNIT_NAME} is on disk but systemd has not read it"
  $SUDO systemctl enable "$BOOT_DEFAULT_UNIT_NAME" ||
    fail "could not enable ${BOOT_DEFAULT_UNIT_NAME}. An installed-but-not-enabled unit is silent: it would never run and nothing would report that."

  verify_boot_default_ordering

  log "stage-boot-default-gaming: ok"
  log "Every boot now re-asserts Gaming Mode as the default session. Steam's"
  log "Power -> 'Switch to Desktop' still works and still lasts until reboot,"
  log "which is how stock SteamOS behaves."
  log ""
  log "🔴 ESCAPE HATCH -- read this before rebooting:"
  log "   If Gaming Mode is broken, this unit re-asserts it at EVERY boot."
  log "   Reach a TTY with Ctrl+Alt+F2 and run ONE of:"
  log "     sudo touch ${BOOT_DEFAULT_OVERRIDE}     (skip it, keep the unit)"
  log "     sudo systemctl disable ${BOOT_DEFAULT_UNIT_NAME}   (permanent)"
  log "   Then: sudo ${SELECT_BIN} desktop --no-restart"
  log "   Removing ${BOOT_DEFAULT_OVERRIDE} re-arms it. See docs/RECOVERY.md."
}

# ---------------------------------------------------------------------------
# stage-power-button -- one short press suspends the Deck
# ---------------------------------------------------------------------------
#
# The constants block above carries the measurement and the two traps. This
# section is the machinery. Read this first if you are about to change it:
#
# NOTHING HERE TAKES EFFECT UNTIL A REBOOT, and that is deliberate.
# This stage writes two files and reloads nothing: no `udevadm control
# --reload-rules`, no `udevadm trigger`, no `systemctl restart systemd-logind`.
# Three reasons, in order of weight:
#
#   1. Removing a udev TAG does not reliably un-register a device logind has
#      ALREADY enumerated -- the monitor is filtered ON that tag, so the change
#      event announcing the removal is the very event the filter drops. A
#      reload could therefore leave the handler armed with the duplicate still
#      live inside logind, which is trap 2 exactly.
#   2. At boot there is no such race: udev processes a device's rules before
#      the uevent is released to listeners, so logind never sees the tag.
#   3. Restarting logind on a machine the operator is sitting in front of is a
#      far larger blast radius than rebooting on purpose.
#
# So the stage's own runtime effect is two files on disk, and the entire
# behavioural change happens at a reboot the operator chooses. It says so.
#
# EVERY host access in this section goes through $SUDO -- including the reads.
# That is not decoration: it is what lets test/unit/test-deck-session-stages.sh
# run the whole stage against a fake root with no seams in src/ at all, the
# property that suite's header calls "$SUDO, which needed nothing from src/".
# `$SUDO find <dir>` and `$SUDO cat <file>` take their paths as arguments, so
# the harness's shim rewrites them; a `sh -c 'ls /etc/...'` would not be
# rewritten and would read the developer's real machine. Do not introduce one.

# True when $1 sorts strictly after $2.
#
# LC_ALL=C, because a locale that ignores punctuation would answer a different
# question than the one udev and systemd ask. Both actually sort with
# strverscmp_improved rather than byte order; the two agree for every name in
# play here (letters beat digits under both, which is the whole point of the
# 'zz-' prefix), and C collation is the conservative reading -- a name that
# wins under C and loses under strverscmp does not exist in this alphabet.
power_sorts_after() {   # power_sorts_after <candidate> <rival>
  [[ $1 != "$2" ]] || return 1
  [[ $(printf '%s\n%s\n' "$1" "$2" | LC_ALL=C sort | tail -n1) == "$1" ]]
}

# Refuse to run on hardware nobody has measured.
#
# THE ARGUMENT, because this is a policy call and not an obvious one.
# stage_preconditions deliberately does NOT refuse an LCD Deck, reasoning that
# "refusing to run on an LCD is worse than running untested". That reasoning
# does not survive contact with this stage, for one reason: every other stage
# installs something whose failure mode is a feature not working, while this
# one rewires a HARDWARE BUTTON on a device whose only fallback is a
# ten-second hold. Its entire content is a claim about how one measured model
# enumerates that button --  three ID_PATHs, read off a Galileo. On a Jupiter
# those may differ, and the two failure modes are (a) our rule matches nothing
# and the duplicate survives -> the suspend loop, or (b) it matches too much
# and logind watches nothing -> a dead button. The status quo on an unmeasured
# model is a menu flash: annoying, and working software.
#
# There is deliberately NO override flag. A flag is how "unverified" quietly
# becomes "supported"; CLAUDE.md forbids claiming LCD support anywhere. The way
# to run this on a Jupiter is to repeat T13 §2.2's capture on a Jupiter and add
# what it measures -- which is a code change, reviewed, with evidence.
verify_power_button_model() {
  local product=""
  $SUDO test -r "$POWER_DMI_PRODUCT" ||
    fail "cannot read ${POWER_DMI_PRODUCT}, so the model is unknown. This stage rewires the power button using ID_PATHs measured on one specific model; it will not guess."
  product=$($SUDO cat -- "$POWER_DMI_PRODUCT") ||
    fail "reading ${POWER_DMI_PRODUCT} failed. Refusing to rewire the power button on an unidentified machine."
  product=${product//$'\n'/}
  [[ -n $product ]] ||
    fail "${POWER_DMI_PRODUCT} is empty. Refusing to rewire the power button on an unidentified machine."

  [[ ${product,,} == "${POWER_MODEL,,}" ]] ||
    fail "this machine reports product_name='${product}', and every measurement behind this stage was taken on '${POWER_MODEL}' (the OLED Deck). 'Jupiter' is the LCD Deck and it has never been measured: it may enumerate its power button differently, in which case this rule either matches nothing (leaving the duplicate press, and a suspend loop) or matches too much (leaving logind nothing to watch, and a dead button). Today's behaviour on an unmeasured model -- the System menu flashing -- is at least working software. To support this model, repeat the capture in docs/findings/T13-power-button-and-sleep.md §2.2 on it and add what it measures to POWER_ACPI_ID_PATHS / POWER_KEEP_ID_PATH. There is no override flag on purpose."

  log "model: ${product} -- the hardware every measurement behind this stage was taken on"
}

# Prove both files will actually WIN, against what is on this disk.
#
# 🔴 This is the check whose absence is a silent no-op in both directions. A
# udev rule read BEFORE ${POWER_UDEV_TAGGER} removes a tag that has not been
# added yet: it parses, it applies, it does nothing, and the duplicate press
# survives into a machine whose handler is now armed. A logind drop-in that
# sorts before Omarchy's 10-ignore-power-button.conf is overridden by it: the
# file is on disk, the setting is correct, and HandlePowerKey is still
# `ignore`. Neither leaves a trace anywhere.
#
# So: scan for the files that assign the same things, and assert ours sorts
# after every one of them. This is the check the SDDM drop-in did not have when
# its comment claimed an ordering that was false on every machine.
verify_power_button_ordering() {
  local ours_rule ours_conf d f base
  ours_rule=${POWER_UDEV_RULE##*/}
  ours_conf=${POWER_LOGIND_DROPIN##*/}

  # --- udev: every file that ADDS the tag must be read before ours ---
  local taggers=0
  for d in "${POWER_UDEV_DIRS[@]}"; do
    $SUDO test -d "$d" || continue
    while IFS= read -r f; do
      [[ -n $f ]] || continue
      base=${f##*/}
      [[ $base != "$ours_rule" ]] || continue
      $SUDO grep -qF -- "TAG+=\"${POWER_UDEV_TAG}\"" "$f" || continue
      taggers=$((taggers + 1))
      power_sorts_after "$ours_rule" "$base" ||
        fail "${ours_rule} sorts BEFORE ${base}, which is a udev rule that adds TAG+=\"${POWER_UDEV_TAG}\" (${f}). udev reads every rules directory as one filename-sorted sequence, so ours would run first and remove a tag that has not been added yet -- it parses, it applies, and it does nothing. Rename ${ours_rule} to something that sorts after ${base}."
    done < <($SUDO find "$d" -maxdepth 1 -name '*.rules' -type f 2>/dev/null | sort)
  done
  [[ $taggers -gt 0 ]] ||
    fail "found no udev rule anywhere in ${POWER_UDEV_DIRS[*]} that adds TAG+=\"${POWER_UDEV_TAG}\". This stage's whole premise is that ${POWER_UDEV_TAGGER} tags the power buttons and that ours then untags two of them; with nothing adding the tag, either logind is watching no power switch at all (so HandlePowerKey= would be dead) or something tags it by a mechanism this stage does not understand. Investigate before installing anything."
  log "verified: ${ours_rule} is read after all ${taggers} udev rule(s) that add TAG+=\"${POWER_UDEV_TAG}\""

  # --- logind: every drop-in that assigns HandlePowerKey= must lose to ours ---
  local rivals=0
  for d in "${POWER_LOGIND_DIRS[@]}"; do
    $SUDO test -d "$d" || continue
    while IFS= read -r f; do
      [[ -n $f ]] || continue
      base=${f##*/}
      [[ $base != "$ours_conf" ]] || continue
      $SUDO grep -qE '^[[:space:]]*HandlePowerKey[[:space:]]*=' "$f" || continue
      rivals=$((rivals + 1))
      power_sorts_after "$ours_conf" "$base" ||
        fail "${ours_conf} sorts BEFORE ${base}, which also assigns HandlePowerKey= (${f}). systemd merges logind.conf.d from every directory into one basename-sorted sequence and the LAST assignment wins, so ${base} would override us: the file would be on disk, the setting would read correctly, and the power button would still do whatever ${base} says. Rename ${ours_conf} to something that sorts after ${base}."
    done < <($SUDO find "$d" -maxdepth 1 -name '*.conf' -type f 2>/dev/null | sort)
  done
  # Zero rivals is legitimate -- it means nothing else claims the key -- but it
  # is worth saying, because on this product the expected count is one
  # (Omarchy's package-owned 10-ignore-power-button.conf) and a zero here means
  # either that file moved or this is not the machine we think it is.
  if [[ $rivals -eq 0 ]]; then
    log "note: no other logind drop-in assigns HandlePowerKey= on this machine (expected one: Omarchy's 10-ignore-power-button.conf)"
  else
    log "verified: ${ours_conf} is read after all ${rivals} logind drop-in(s) that assign HandlePowerKey="
  fi
}

# Prove the rule will match the devices it names, on THIS machine, BEFORE
# writing anything.
#
# 🔴 Both halves matter and they fail in opposite directions:
#
#   - An ID_PATH that matches nothing means the duplicate press survives. The
#     rule installs cleanly, udev applies it cleanly, and the next press
#     suspends twice. That is the suspend loop, arrived at by a typo.
#   - A missing or untagged keeper means untagging the ACPI nodes leaves logind
#     with no power-switch device at all. HandlePowerKey= then has nothing to
#     act on and the button becomes DEAD -- a different failure from the one
#     the operator reported, introduced by the fix for it.
#
# Read-only: `udevadm info --query=property` and nothing else. No trigger, no
# control, no settle.
verify_power_button_premise() {
  local dev line id tags found_keep="" f
  local -a untag_found=() tagged=()

  for f in "${POWER_ACPI_ID_PATHS[@]}"; do
    [[ $f != "$POWER_KEEP_ID_PATH" ]] ||
      fail "POWER_KEEP_ID_PATH (${POWER_KEEP_ID_PATH}) also appears in POWER_ACPI_ID_PATHS. That would untag the ONE node this design keeps, leaving logind watching nothing and the power button dead. Refusing to render a rule that disables its own single source."
  done

  while IFS= read -r dev; do
    [[ -n $dev ]] || continue
    id=""; tags=""
    while IFS= read -r line; do
      case $line in
        ID_PATH=*) id=${line#ID_PATH=} ;;
        TAGS=*)    tags=${line#TAGS=} ;;
      esac
    done < <($SUDO udevadm info --query=property --name "$dev" 2>/dev/null)
    [[ -n $id ]] || continue
    [[ $tags == *":${POWER_UDEV_TAG}:"* ]] || continue
    tagged+=("${id} (${dev##*/})")
    [[ $id != "$POWER_KEEP_ID_PATH" ]] || found_keep=$dev
    for f in "${POWER_ACPI_ID_PATHS[@]}"; do
      [[ $id != "$f" ]] || untag_found+=("$id")
    done
  done < <($SUDO find /dev/input -maxdepth 1 -name 'event*' 2>/dev/null | sort)

  [[ ${#tagged[@]} -gt 0 ]] ||
    fail "no input device under /dev/input carries TAGS=:${POWER_UDEV_TAG}: at all. Either udev has not processed these devices, or this machine does not enumerate its power button the way the measurement in docs/findings/T13-power-button-and-sleep.md §2.2 recorded. Nothing has been written."
  log "power-switch devices udev reports on this machine: ${tagged[*]}"

  [[ -n $found_keep ]] ||
    fail "no device carries ID_PATH=${POWER_KEEP_ID_PATH} AND TAGS=:${POWER_UDEV_TAG}:. That node is the SINGLE SOURCE this design keeps -- the real key that tracks a hold. Untagging the ACPI buttons without it would leave systemd-logind watching no power switch at all, and the power button would go from flashing a menu to doing nothing whatsoever. Nothing has been written."

  local want
  for want in "${POWER_ACPI_ID_PATHS[@]}"; do
    local hit=""
    for f in "${untag_found[@]+"${untag_found[@]}"}"; do
      [[ $f != "$want" ]] || hit=$f
    done
    [[ -n $hit ]] ||
      fail "the rule would untag ID_PATH=${want}, and NO device on this machine matches that with TAGS=:${POWER_UDEV_TAG}:. A rule that matches nothing installs cleanly, applies cleanly and does nothing -- which here means the duplicate KEY_POWER press survives and the next press suspends twice, at or just after resume. Re-run the capture in docs/findings/T13-power-button-and-sleep.md §2.2 on this machine and correct POWER_ACPI_ID_PATHS. Nothing has been written."
  done
  log "verified: every ID_PATH this rule untags is present and currently tagged, and ${POWER_KEEP_ID_PATH} survives as the single source"
}

# 🔴 R2, said out loud rather than assumed away.
#
# A WARNING and not a failure, and the reason is that the answer is only half
# readable from here. omarchy-sleep-lock.service is a USER unit; it can be
# masked globally (a /dev/null symlink under /etc/systemd/user, which this can
# see -- install_sleep_lock_mask is what ships ours) or per user (under
# ~/.config/systemd/user, which it cannot see, and which is how it was masked
# by hand on the test Deck). Failing on an unreadable half would block the fix
# on a machine that is actually fine; saying nothing would ship a power button
# whose every press might raise a password prompt on a device with no keyboard.
# So: report exactly what is knowable, and print the one command that settles
# the rest.
#
# ⚠️ CHECKS, rather than assuming stage-desktop-settings already ran. The stages
# are individually invocable, and "power button suspends, mask not yet
# installed" is precisely the bad ordering.
warn_if_sleep_lock_live() {
  local d unit=""
  if $SUDO test -L "$SLEEP_LOCK_GLOBAL_MASK" &&
     [[ $($SUDO readlink -- "$SLEEP_LOCK_GLOBAL_MASK" 2>/dev/null) == /dev/null ]]; then
    log "verified: ${SLEEP_LOCK_UNIT} is masked for every user (${SLEEP_LOCK_GLOBAL_MASK} -> /dev/null), so a suspend cannot raise a lock screen"
    return 0
  fi

  for d in "${SLEEP_LOCK_UNIT_DIRS[@]}"; do
    if $SUDO test -f "$d/$SLEEP_LOCK_UNIT"; then unit="$d/$SLEEP_LOCK_UNIT"; break; fi
  done

  if [[ -z $unit ]]; then
    log "note: ${SLEEP_LOCK_UNIT} is not installed on this machine, so nothing locks the screen on suspend"
    return 0
  fi

  warn "${unit} exists and is NOT masked globally. If it is also unmasked for the desktop user, every suspend this stage enables will lock the screen -- and this Deck has no keyboard to answer the password prompt with (docs/findings/T13-power-button-and-sleep.md §5.3, blast radius R2). Check BEFORE the first press, as the desktop user:  systemctl --user is-enabled ${SLEEP_LOCK_UNIT}   -- it must say 'masked'. If it does not:  systemctl --user mask ${SLEEP_LOCK_UNIT}"
}

# The udev rule. Written to stdout so the unit suite can check its shape with
# no Deck, no root and no VM -- the same move render_update_stub made.
render_power_udev_rule() {
  local p
  cat <<EOF
${INSTALL_MARKER}
#
# Drop the ACPI power-button nodes from udev's "${POWER_UDEV_TAG}" tag, so that
# systemd-logind watches exactly ONE device for KEY_POWER on this machine.
#
# WHY -- MEASURED on the operator's Deck (Valve ${POWER_MODEL}, OLED),
# 2026-08-12, n=3 presses: one tap and two deliberate holds. One physical press
# produced TWO KEY_POWER presses:
#
#   ${POWER_KEEP_ID_PATH}
#       "AT Translated Set 2 keyboard" -- a REAL key. Down on press, up on
#       release, tracking a 2.92 s hold exactly. KEPT: it is the only node that
#       can express a hold at all.
#   acpi-LNXPWRBN:00
#       a fire-and-forget notify -- one instantaneous press+release 131-198 ms
#       after the press, INDEPENDENT of hold length. This is the duplicate.
#   acpi-PNP0C0C:00
#       silent across all three presses, but tagged and advertising KEY_POWER.
#
# Full trace: docs/findings/T13-power-button-and-sleep.md §2.2.
#
# 🔴 WITHOUT THIS FILE, HandlePowerKey=suspend GETS TWO SUSPEND REQUESTS PER
# PRESS, ~198 ms apart -- the second landing at or just after resume. That is a
# re-suspend loop on a device whose only other escape is a ten-second hardware
# hold, i.e. indistinguishable from a Deck that will not wake. This rule must
# be in place BEFORE anything sets HandlePowerKey= to a value that acts.
#
# Valve reached the same answer from their own measurements: on Jupiter and
# Galileo they blacklist the ACPI power button by name
# (STEAMOS_POWER_BUTTON_IGNORE=1, steamos-power-button.hwdb) so that their
# powerbuttond binds the real key instead.
#
# BOTH ACPI nodes, not just the one that fires: a silent node that advertises
# KEY_POWER and carries the tag is a second source waiting for a firmware or
# kernel change. Untagging it costs nothing.
#
# The Lid Switch (acpi-PNP0C0D:00) is deliberately untouched -- same upstream
# rule tags it, but nothing about the lid was measured and HandleLidSwitch= is
# a separate question.
#
# ORDERING: this file must be read AFTER ${POWER_UDEV_TAGGER}, which is what
# adds the tag. "-=" removes a value from a list (udev(7), "-=", since v217),
# so a rule read first removes nothing and silently leaves both sources live.
# udev reads every rules directory as one filename-sorted sequence, which is
# what the 'zz-' prefix is for. deck-session.sh asserts that against the files
# on disk before installing this -- it does not trust this paragraph.

ACTION=="remove", GOTO="deck_power_button_end"
SUBSYSTEM!="input", GOTO="deck_power_button_end"
KERNEL!="event*", GOTO="deck_power_button_end"

EOF
  for p in "${POWER_ACPI_ID_PATHS[@]}"; do
    printf 'ENV{ID_PATH}=="%s", TAG-="%s"\n' "$p" "$POWER_UDEV_TAG"
  done
  printf '\nLABEL="deck_power_button_end"\n'
}

# The logind drop-in. Stdout, same reason.
render_power_logind_dropin() {
  cat <<EOF
${INSTALL_MARKER}
#
# One short press of the power button suspends the Deck.
#
# 🔴 THE VALUE IS WRITTEN OUT EXPLICITLY AND MUST STAY THAT WAY.
# HandlePowerKey= defaults to **poweroff**, not suspend (man logind.conf,
# systemd 261 -- the version this Deck runs). A version of this file that
# merely removed Omarchy's drop-in, or that left the value blank, would
# hard-power-off the Deck on every tap: strictly worse than the System menu
# flash it replaces, and with data loss on every press.
#
# WHY A NEW FILE AND NOT AN EDIT. Omarchy ships
# /etc/systemd/logind.conf.d/10-ignore-power-button.conf (HandlePowerKey=ignore)
# and the omarchy package OWNS that path -- omarchy-upgrade-to-quattro passes
# pacman --overwrite for it by name, so any edit or deletion comes back on the
# next upgrade. systemd merges logind.conf.d from /etc, /run and /usr/lib into
# one basename-sorted sequence in which the LAST assignment wins, so a 'zz-'
# name beats a '10-' one without touching a file we do not own. deck-session.sh
# checks that ordering against the files actually on disk before installing
# this.
#
# 🔴 REQUIRES ${POWER_UDEV_RULE}, which must already be in place. One physical
# press produces TWO KEY_POWER presses on this hardware (MEASURED -- T13 §2.2);
# with both still tagged \`power-switch\`, this setting gets two suspend
# requests ~198 ms apart and the second lands at or just after resume.
#
# HandlePowerKeyLongPress=${POWER_KEY_LONG_PRESS_ACTION} is systemd's own default, restated here rather
# than inherited so this file says what the Deck does. Not \`poweroff\`: the
# threshold is a number nobody has read (systemd's LONG_PRESS_DURATION is
# unread; SteamOS's 1 s belongs to powerbuttond's alarm(1), a different
# program), and a long-press poweroff would shadow the ten-second hardware hold
# that docs/RECOVERY.md documents as the escape of last resort. NO duration
# appears in this file on purpose.
#
# GAMING MODE. This is system-wide, not per-session, which is the point: Gaming
# Mode is Valve's stock gamescope session, it binds nothing to this key, and
# Valve's own handler (steamos-powerbuttond) is in none of this project's
# package lists -- which is exactly why the button does nothing there today.
# ⚠️ One unmeasured caveat: if anything in that session takes a logind
# **low-level inhibitor** on handle-power-key, Handle*= is ignored for as long
# as it is held (man logind.conf) and Gaming Mode stays dead. Unverified.
# \`systemd-inhibit --list\` in Gaming Mode answers it in one read-only command.
#
# RESUMES UNLOCKED, ON PURPOSE. This Deck has no keyboard; a lock screen on
# resume is an unanswerable password prompt, so ${SLEEP_LOCK_UNIT} stays
# masked (T5 §5.6, T13 §5.3). That is a deliberate security trade-off, and it
# is a DIFFERENT stage's artefact -- deck-session.sh checks it is in place
# before it finishes here, rather than assuming the stages ran in order.
#
# Desktop Mode also still runs Omarchy's own XF86PowerOff bind
# (\`omarchy-menu toggle system\`), which is a USER config concern and is not
# changed here. With the duplicate press gone, one press opens that menu and
# LEAVES IT OPEN behind the suspend. See deck-session.sh's stage-power-button
# output for the one-line fix and why it belongs in ~/.config/hypr/bindings.lua.

[Login]
HandlePowerKey=${POWER_KEY_ACTION}
HandlePowerKeyLongPress=${POWER_KEY_LONG_PRESS_ACTION}
EOF
}

# NOT in INSTALL_STAGES, and for the same reason stage_default_session and
# stage_boot_default_gaming are not: this changes what a HARDWARE BUTTON does
# on a device the operator cannot rescue remotely. Getting it wrong does not
# produce a feature that fails to work, it produces a Deck that suspends itself
# on resume, or one whose power button is inert. A bare `./deck-session.sh`
# must not arm that on a machine where nobody has yet pressed the button and
# watched.
#
# ORDER OF WRITES IS THE SAFETY PROPERTY. The udev rule (remove the duplicate)
# goes first, the logind drop-in (arm the handler) second. A run that dies
# between them leaves a machine with one fewer redundant tag and today's
# behaviour otherwise -- harmless. The reverse order would leave the handler
# armed with the duplicate live, which is the one state this whole stage exists
# to avoid.
stage_power_button() {
  local tool
  for tool in find udevadm readlink; do
    command -v "$tool" >/dev/null 2>&1 ||
      fail "required tool '${tool}' not found; this stage verifies what it is about to write and will not install unverified"
  done

  verify_power_button_model
  verify_power_button_ordering
  verify_power_button_premise

  assert_ours_or_absent "$POWER_UDEV_RULE" "another package's udev rule"
  assert_ours_or_absent "$POWER_LOGIND_DROPIN" "another package's logind configuration"

  # --- 1. remove the duplicate press ---------------------------------------
  log "installing ${POWER_UDEV_RULE}"
  local tmp p
  tmp=$(mktemp) || fail "mktemp failed"
  render_power_udev_rule >"$tmp" || fail "could not render the udev rule"
  $SUDO install -D -m 0644 -o root -g root "$tmp" "$POWER_UDEV_RULE" ||
    fail "could not install ${POWER_UDEV_RULE}"
  rm -f "$tmp"

  # Re-read what landed rather than trusting the redirect -- deck-session-select
  # greps its three keys back out of the SDDM drop-in for the same reason.
  $SUDO grep -qF -- "TAG-=\"${POWER_UDEV_TAG}\"" "$POWER_UDEV_RULE" ||
    fail "wrote ${POWER_UDEV_RULE} but no TAG-=\"${POWER_UDEV_TAG}\" is in it on re-read. A rule that does not REMOVE the tag leaves both KEY_POWER sources live, and the handler installed next would suspend twice per press."
  for p in "${POWER_ACPI_ID_PATHS[@]}"; do
    $SUDO grep -qF -- "ENV{ID_PATH}==\"${p}\", TAG-=\"${POWER_UDEV_TAG}\"" "$POWER_UDEV_RULE" ||
      fail "wrote ${POWER_UDEV_RULE} but the line untagging ID_PATH=${p} is not there on re-read"
  done
  $SUDO grep -qF -- 'LABEL="deck_power_button_end"' "$POWER_UDEV_RULE" ||
    fail "wrote ${POWER_UDEV_RULE} but its GOTO target LABEL is missing on re-read -- udev refuses to load a rules file whose GOTO has no matching LABEL, so the whole file would be dropped"
  ! $SUDO grep -q -- "^ENV{ID_PATH}==\"${POWER_KEEP_ID_PATH}\"" "$POWER_UDEV_RULE" ||
    fail "wrote ${POWER_UDEV_RULE} and it untags ${POWER_KEEP_ID_PATH}, the one node this design keeps. That would leave systemd-logind watching no power switch at all."
  log "verified: ${POWER_UDEV_RULE} untags ${#POWER_ACPI_ID_PATHS[@]} ACPI node(s) and leaves ${POWER_KEEP_ID_PATH} alone"

  # --- 2. and ONLY NOW arm the handler -------------------------------------
  log "installing ${POWER_LOGIND_DROPIN}"
  tmp=$(mktemp) || fail "mktemp failed"
  render_power_logind_dropin >"$tmp" || fail "could not render the logind drop-in"
  $SUDO install -D -m 0644 -o root -g root "$tmp" "$POWER_LOGIND_DROPIN" ||
    fail "could not install ${POWER_LOGIND_DROPIN}"
  rm -f "$tmp"

  $SUDO grep -qxF -- '[Login]' "$POWER_LOGIND_DROPIN" ||
    fail "wrote ${POWER_LOGIND_DROPIN} but it has no [Login] section on re-read -- systemd would log 'Unknown section' and ignore every setting in it, and the power button would stay exactly as it is"
  $SUDO grep -qxF -- "HandlePowerKey=${POWER_KEY_ACTION}" "$POWER_LOGIND_DROPIN" ||
    fail "wrote ${POWER_LOGIND_DROPIN} but 'HandlePowerKey=${POWER_KEY_ACTION}' is not there on re-read. This value is never allowed to be implicit: HandlePowerKey= DEFAULTS TO poweroff, so a drop-in that overrides Omarchy's 'ignore' without naming a value hard-powers-off the Deck on every tap."
  $SUDO grep -qxF -- "HandlePowerKeyLongPress=${POWER_KEY_LONG_PRESS_ACTION}" "$POWER_LOGIND_DROPIN" ||
    fail "wrote ${POWER_LOGIND_DROPIN} but 'HandlePowerKeyLongPress=${POWER_KEY_LONG_PRESS_ACTION}' is not there on re-read"
  log "verified: ${POWER_LOGIND_DROPIN} sets HandlePowerKey=${POWER_KEY_ACTION} explicitly"

  warn_if_sleep_lock_live

  log "stage-power-button: ok"
  log ""
  log "🔴 NOTHING HAS CHANGED YET. This stage reloaded no udev rules and"
  log "   restarted no services, on purpose: removing a udev tag does not"
  log "   reliably un-register a device logind has already enumerated, so a"
  log "   live reload could arm the handler with the duplicate press still"
  log "   inside logind -- the one state this is built to avoid. A REBOOT"
  log "   applies both files in the right order, with no such race:"
  log "     sudo reboot"
  log ""
  log "After that reboot, ONE short press of the power button suspends the Deck,"
  log "in Desktop Mode and in Gaming Mode alike (the drop-in is system-wide)."
  log "A long press does nothing: no threshold in this project has been read"
  log "from source, and the ten-second hardware hold is unchanged."
  log ""
  log "⚠️ DESKTOP MODE WILL ALSO LEAVE THE SYSTEM MENU OPEN behind the suspend."
  log "   Omarchy binds XF86PowerOff to 'omarchy-menu toggle system'. Today the"
  log "   duplicate press toggles it open and shut again, which is the 'flash'"
  log "   that was reported; with the duplicate gone, one press opens it and"
  log "   leaves it open. That bind is a USER config file and is NOT changed by"
  log "   this stage. The supported fix, as the desktop user, in"
  log "   ~/.config/hypr/bindings.lua:"
  log "     hl.unbind(\"XF86PowerOff\")"
  log "   ⚠️ A Lua syntax error there makes Hyprland discard the WHOLE file"
  log "   silently, with 'hyprctl configerrors' still clean. Check it with"
  log "   'luac -p ~/.config/hypr/bindings.lua' before rebooting."
  log ""
  log "🔴 UNDO -- in this order, so the handler is never armed alone:"
  log "     sudo rm -f ${POWER_LOGIND_DROPIN}    # first: disarm the handler"
  log "     sudo rm -f ${POWER_UDEV_RULE}   # second: restore the tags"
  log "     sudo reboot"
  log "   Removing only the first restores today's behaviour exactly (Omarchy's"
  log "   10-ignore-power-button.conf takes over again). Removing only the"
  log "   second is the dangerous half and is why the order is written down."
}

# ---------------------------------------------------------------------------

run_stage() {
  local stage=$1
  local fn=${stage//-/_}
  declare -F "$fn" >/dev/null || usage_error "unknown stage '${stage}'"
  # Every stage needs the probes; they install nothing and write nothing.
  [[ $stage == stage-preconditions ]] || stage_preconditions
  "$fn"
}

main() {
  case ${1:-} in
    "")
      stage_preconditions
      local s
      for s in "${INSTALL_STAGES[@]:1}"; do "${s//-/_}"; done
      log "done. Both switch directions are installed but NOT yet the default."
      log "Test first:  ${STEAM_SHIM} gamescope     (switches now, ends this session)"
      log "Then, once proven: ./${PROG}.sh stage-default-session"
      ;;
    list-stages) printf '%s\n' "${INSTALL_STAGES[@]}" stage-audit-privileges stage-default-session stage-boot-default-gaming stage-power-button ;;
    -h|--help|help)
      cat <<EOF
${PROG}.sh -- two-way Gaming Mode <-> Desktop session switching for a Deck

  ${PROG}.sh                        install everything except the default flip
  ${PROG}.sh <stage>                run one stage
  ${PROG}.sh list-stages            stage names, for CI
  ${PROG}.sh stage-audit-privileges report sudoers drop-ins that grant blanket
                                    root; fails if any do (release check, T6)
  ${PROG}.sh stage-default-session  make Gaming Mode the default (do this last)
  ${PROG}.sh stage-boot-default-gaming
                                    re-assert Gaming Mode as the default at
                                    EVERY boot, so Desktop Mode is a one-shot
                                    session the way stock SteamOS's is. Steam's
                                    own 'Switch to Desktop' rewrites the default
                                    and this is what undoes that. Opt-in for the
                                    same reason stage-default-session is, and
                                    meant to be run beside it.
                                    Escape hatch, no editor needed:
                                      sudo touch ${BOOT_DEFAULT_OVERRIDE}
                                      sudo systemctl disable ${BOOT_DEFAULT_UNIT_NAME}
  ${PROG}.sh stage-power-button     make ONE SHORT PRESS of the power button
                                    suspend the Deck, in both modes. Writes two
                                    files and reloads nothing -- it takes effect
                                    at the next reboot, on purpose. Opt-in for
                                    the same reason the two above are: it
                                    changes what a hardware button does on a
                                    device whose only other escape is a
                                    ten-second hold. ${POWER_MODEL} (OLED) only;
                                    it refuses on any other model, because the
                                    device paths it uses were measured on one.
                                    Undo, in this order:
                                      sudo rm -f ${POWER_LOGIND_DROPIN}
                                      sudo rm -f ${POWER_UDEV_RULE}
                                      sudo reboot

After installing:
  steamos-session-select gamescope  switch to Gaming Mode now
  steamos-session-select desktop    switch to the desktop now

Stages also cover Gaming Mode / display defects (PROGRESS.md 5.11, 5.14, 5.15):
  stage-menu-row           splices a 'Return to Gaming Mode' row into the
                           Quickshell menu (~/${MENU_EXT_REL}
                           and /etc/skel's copy). Same command as the .desktop
                           entry, by one shared constant; the file is parsed
                           after writing because Quickshell silently discards
                           every row in one it cannot parse.
  stage-update-stub        a steamos-update stub, so Steam's first run stops
                           reporting a false network error
  stage-timezone-helper    steamos-set-timezone, so OOBE's timezone picker
                           stops silently doing nothing
  stage-priv-write-helper  steamos-priv-write, so Gaming Mode's brightness
                           slider stops falling back to blanket 'sudo tee'
                           and 'sudo chmod a+w' on system nodes
  stage-greeter-rotation   rotates the SDDM greeter for the Deck's panel.
                           The user's desktop needs a matching transform in
                           ~/.config/hypr/monitors.lua; the Limine menu and
                           the TTY are NOT covered here.
  stage-lizard-mode        binds the controller firmware's lizard mode to
                           deck-input-mapper.service: off while it runs, on
                           again when it stops, crashes or is killed -- by
                           ExecStopPost=, and by an OnFailure= unit for the
                           cgroup-wide SIGKILL that kills ExecStopPost= too.
                           Nothing persists it: a reboot restores it, on purpose.

Exit codes: 0 success, 1 stage failure, 2 usage error.
EOF
      ;;
    *) run_stage "$1" ;;
  esac
}

# Sourcing this file defines its functions and runs nothing, so
# test/unit/test-deck-session.sh can call render_update_stub and
# assert_ours_or_absent directly without installing anything. Executing it
# behaves exactly as it did before this guard existed.
#
# Two things a sourcing shell inherits and must expect: `set -euo pipefail`
# from the top of this file, and every constant above as `readonly` -- so
# sourcing twice into one shell aborts on "readonly variable". Source once.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi

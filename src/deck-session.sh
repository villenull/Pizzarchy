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
# menu our Desktop Mode row lives in. Nothing in this file touches either.
# An earlier version of this comment claimed the settings below mean the
# handheld "can never be shown an unanswerable password prompt". That was
# false when it was written. The settings below are necessary, not sufficient.
readonly OMARCHY_SHELL_JSON_REL=.config/omarchy/shell.json
readonly OMARCHY_SHELL_JSON_DEFAULTS=/usr/share/omarchy/config/omarchy/shell.json
readonly IDLE_SCREENSAVER_SECONDS=150
readonly IDLE_LOCK_SECONDS=86400

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
# surface that does not rotate itself renders sideways. fbcon/rotate is 0 on
# both stock Arch and Neptune, so no kernel this project ships corrects it and
# the fix is per-surface, in userspace. Gaming Mode is exempt: gamescope
# applies its own transform.
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
  # NOT fixed here, and not fixable this way:
  #   - the Limine boot menu, which renders before any compositor exists. It is
  #     the first thing a user sees and still has no known fix (R-19).
  #   - the console/TTY, which needs fbcon=rotate:1 on the kernel cmdline. That
  #     touches the boot chain and is held for separate operator approval.
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
# silently never runs. Measured on hardware. The mapper needs no ordering
# anyway: it reads evdev and writes uinput, and never talks to the compositor.
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
# Reachable three ways: `systemctl kill` (whose DEFAULT --kill-whom is NOT
# main), `--kill-whom=all|cgroup`, and systemd-oomd, which kills by writing
# cgroup.kill. In that case lizard mode stays off with no mapper running -- a
# Deck with no pointer and no keys until the next boot, where the module
# parameter resets to Y. A ~10s power-button hold is the recovery that needs no
# keyboard, which is why this is a bad day and not a brick.
#
# NOT mitigated here, deliberately. The fix is an `OnFailure=` unit, which runs
# in its OWN cgroup and therefore survives; that is a fourth installed file and
# a change to the design rather than an implementation detail, so it is
# reported rather than smuggled in. systemd-oomd is disabled and inactive on
# Omarchy today, which is what makes recording this acceptable for now.
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
# 🔴 ONE MEASURED EXCEPTION: a SIGKILL of the WHOLE CGROUP (\`systemctl kill\`
# with its default --kill-whom, or systemd-oomd) kills this ExecStopPost= too,
# because systemd spawns it into the unit's own cgroup. Lizard mode then stays
# off until the next boot. The table above render_lizard_dropin has the journal
# extract and the reason it is recorded rather than fixed.
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
[Service]
ExecStartPost=${SUDO_BIN} -n ${LIZARD_HELPER} off
ExecStopPost=${SUDO_BIN} -n ${LIZARD_HELPER} on
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
  # Installs the three pieces that make "lizard mode is off IF AND ONLY IF the
  # mapper is running" true, and nothing else:
  #
  #   1. ${LIZARD_HELPER}   validates, writes, reads back, fails loudly
  #   2. ${LIZARD_SUDOERS}  the desktop user may run exactly that, both ways
  #   3. ${LIZARD_DROPIN}   deck-input-mapper.service's own ExecStartPost=/
  #                         ExecStopPost= turn it off and back on
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

  # --- 3. the drop-in ---
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

  # Ask systemd what it actually parsed, when there is a manager to ask. This is
  # the only check that can see the '-' prefix question at all: `ignore_errors`
  # is systemd's own report of whether a failure here would be swallowed, and a
  # swallowed ExecStartPost= is a mapper running against a silent device.
  local parsed
  parsed=$(systemctl --user show "$unit_name" -p ExecStopPost --value 2>/dev/null) || parsed=""
  if [[ -z $parsed ]]; then
    warn "this user's systemd manager cannot report ${unit_name}'s ExecStopPost=, so the drop-in was verified as FILE CONTENT only. Re-check inside a desktop session with 'systemctl --user show ${unit_name} -p ExecStopPost'."
  else
    [[ $parsed == *"${LIZARD_HELPER} on"* ]] ||
      fail "systemd parsed ${unit_name} with ExecStopPost=${parsed}, which does not run '${LIZARD_HELPER} on'. Without it a mapper that dies leaves lizard mode off, and the device with no input."
    [[ $parsed != *"ignore_errors=yes"* ]] ||
      fail "systemd parsed ${unit_name}'s ExecStopPost= with ignore_errors=yes -- something prefixed it with '-'. A silently ignored failure here is exactly the fallback not working, on the one path that has to."
    log "verified: systemd parses ${unit_name} with an ExecStopPost= that restores lizard mode and does not ignore errors"
  fi

  verify_lizard_grant "$helper"
  verify_lizard_helper "$helper" "$node"

  log "stage-lizard-mode: ok"
  log "NOTE: nothing was started. Lizard mode is still whatever it was, and goes"
  log "      off only when deck-input-mapper.service next starts -- and back on"
  log "      when it stops, crashes or is killed. A reboot restores it too."
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

stage_desktop_settings() {
  # Installs the three settings that decide whether the on-screen keyboard
  # works and whether an idle Deck can lock itself out. See the constants above
  # for why each one exists; all three were discovered by something failing on a
  # screen, and none of them fails a test today.
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

  # --- 3. Omarchy's idle policy ---
  local invoking_user=${SUDO_USER:-${USER:-$(id -un)}}
  [[ -n $invoking_user && $invoking_user != root ]] ||
    fail "could not determine the desktop user (got '${invoking_user}'); run this as that user via sudo, not as root directly"
  local home
  home=$(getent passwd "$invoking_user" | cut -d: -f6) ||
    fail "could not resolve ${invoking_user}'s home directory"
  [[ -n $home ]] || fail "empty home directory for ${invoking_user}"
  local shell_json="${home}/${OMARCHY_SHELL_JSON_REL}"

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

  log "stage-desktop-settings: ok"
  log "NOTE: Omarchy re-reads shell.json live (FileView watchChanges), but the"
  log "      dconf defaults apply to sessions started AFTER this, and any"
  log "      user-level value keeps shadowing them until it is reset."
}

# ---------------------------------------------------------------------------

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
  # PINNING it to a bar/dock IS shell-specific and is deliberately NOT done
  # here -- see TASK-T3 step 6. For Omarchy 4.0 the mechanism is the Quickshell
  # menu, extended via ~/.config/omarchy/extensions/omarchy-menu.jsonc:
  #
  #   "gaming": {"icon":"\udb81\udcb4","label":"Return to Gaming Mode",
  #              "action":"${STEAM_SHIM} gamescope"}
  #
  # That takes a Nerd Font GLYPH rather than an icon file, which sidesteps the
  # artwork question entirely. It is per-user config, so T5 has to seed it the
  # same way it seeds monitors.lua -- see PROGRESS.md 5.11.
  #
  # This stage used to be the one that silently clobbered: no marker in the file
  # it wrote and no ownership check in front of the write, so a .desktop that
  # some other package (or a user) had put at this path was overwritten without
  # a word. Every other stage refuses that, and now so does this one. The marker
  # goes on line 1 as a '#' comment: the Desktop Entry spec ignores comment
  # lines and does not require the group header to be first, and
  # desktop-file-validate accepts it.
  assert_ours_or_absent "$RETURN_DESKTOP_FILE" "another package's desktop entry"

  log "installing ${RETURN_DESKTOP_FILE}"
  local tmp
  tmp=$(mktemp) || fail "mktemp failed"
  cat >"$tmp" <<EOF
${INSTALL_MARKER}
[Desktop Entry]
Type=Application
Name=Return to Gaming Mode
Comment=Switch back to the Steam Big Picture session
Exec=${STEAM_SHIM} gamescope
Icon=input-gaming
Terminal=false
Categories=Game;
Keywords=steam;gaming;gamescope;deck;
EOF
  $SUDO install -m 0644 -o root -g root "$tmp" "$RETURN_DESKTOP_FILE" ||
    fail "could not install ${RETURN_DESKTOP_FILE}"
  rm -f "$tmp"
  log "stage-return-icon: ok"
  log "NOTE: pinning this to a bar/dock is shell-specific and is not done here"
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
    list-stages) printf '%s\n' "${INSTALL_STAGES[@]}" stage-audit-privileges stage-default-session ;;
    -h|--help|help)
      cat <<EOF
${PROG}.sh -- two-way Gaming Mode <-> Desktop session switching for a Deck

  ${PROG}.sh                        install everything except the default flip
  ${PROG}.sh <stage>                run one stage
  ${PROG}.sh list-stages            stage names, for CI
  ${PROG}.sh stage-audit-privileges report sudoers drop-ins that grant blanket
                                    root; fails if any do (release check, T6)
  ${PROG}.sh stage-default-session  make Gaming Mode the default (do this last)

After installing:
  steamos-session-select gamescope  switch to Gaming Mode now
  steamos-session-select desktop    switch to the desktop now

Stages also cover Gaming Mode / display defects (PROGRESS.md 5.11, 5.14, 5.15):
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
                           again when it stops, crashes or is killed. Nothing
                           persists it -- a reboot restores it too, on purpose.

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

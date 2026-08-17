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
# ⚠️ `amdgpu_bl0` ABOVE IS A VERBATIM LOG QUOTE FROM ONE KERNEL, NOT A PATH THIS
# SCRIPT MAY ASSUME. The same physical Deck enumerated the SAME panel as
# `amdgpu_bl1` on stock `linux 7.1.8-arch1-3` (measured 2026-08-15, with no
# amdgpu_bl0 present at all). The index is DRM enumeration order. Everything
# below discovers the node -- see BACKLIGHT_GLOB and find_backlight.
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
# ===========================================================================
# CHROOT MODE -- DECK_SESSION_CHROOT=1, and why this file grew one
# ===========================================================================
#
# This script was written for a RUNNING Deck, reached over SSH. That is how it
# was proven (sessions 15-26, every capability watched working on hardware) and
# it is why the stages verify themselves by starting processes, asking systemd
# what it parsed, and writing sysfs.
#
# 🔴 IT WAS ALSO NEVER RUN BY THE INSTALLER, and that is a shipped defect:
# docs/findings/P32-steam-never-installed.md's general shape -- a component that
# exists, is tested, and is wired into nothing. An ISO-installed Deck had no
# "Switch to Desktop" row in Steam's power menu, no way back from the desktop,
# and no target-side input mapper. Every one of those lives here.
#
# So `configure_deck`'s deck_session_bake step runs THIS FILE, unchanged, inside
# the target via arch-chroot, one stage per invocation, with
# DECK_SESSION_CHROOT=1. Not a Python re-implementation of it: a second copy of
# this logic is the drift this project keeps paying for (see the two halves of
# "return to Gaming Mode", and assert_return_action_agrees).
#
# WHAT A CHROOT IS NOT. There is no systemd manager to talk to, no D-Bus, no
# session, no compositor, and no user to escalate from -- the process is already
# root and `sudo` cannot be relied on (PAM, no tty, no audit socket). What a
# chroot DOES have is the target's whole filesystem, its binaries, and -- via
# arch-chroot's bind mounts -- the INSTALLING MACHINE's /proc, /sys, /dev and
# /run. That last one is the trap: /sys is the live Deck's, not the target's,
# and /run/user/<uid> may hold the INSTALLER's own compositor.
#
# THE THREE RULES THIS MODE FOLLOWS
#
#   1. FILE-LEVEL WORK IS DONE NOW. Everything that is "write a file, install a
#      unit, create an enablement symlink, splice a dotfile" happens at install
#      time. The goal is a Deck that switches sessions out of the box, not one
#      that would if a first-boot service worked.
#   2. WHAT CANNOT RUN IS DEFERRED **OUT LOUD**, through defer(), which prints a
#      single greppable line naming what was skipped, why, and how to check it
#      on the installed machine. There is no silent skip anywhere in this file
#      and this mode does not introduce the first one (CLAUDE.md).
#   3. THE NORMAL PATH IS UNTOUCHED. Every branch below is `if in_chroot`, and
#      with DECK_SESSION_CHROOT unset this file behaves byte-for-byte as it did
#      on the Deck. test/unit/test-deck-session-bake.sh drives the chroot half;
#      the two existing suites keep driving the other one.
#
# 🔴 WHAT IS DEFERRED IS ALWAYS A **VERIFICATION**, NEVER AN ARTEFACT. Nothing
# the installed system needs is left to first boot. The four deferred checks are
# systemd's parse of the sddm drop-in, the timezone helper's round trip through
# timedatectl, the lizard-mode node toggle, and the live-compositor readback of
# the keyboard layout rule -- each of which needs a running system to ANSWER,
# and none of which is needed to WRITE anything.
#
# ⚠️ THE ONE STAGE THAT MUST NOT BE BAKED is stage-desktop-settings, and it is
# not a judgement call: three orchestrator steps (session_dconf, idle_policy,
# mask_sleep_lock) already write its dconf, idle-policy and sleep-lock halves at
# install time, and the site file they write carries no marker of ours, so
# assert_ours_or_absent would -- correctly -- refuse. Measured on the operator's
# Deck 2026-08-15: /etc/dconf/db/local.d/50-deck-desktop written 11:25 by the
# installer. Its FOURTH half, the on-screen keyboard's XKB rule, is owned by
# nothing else, which is why stage-osk-kb-layout exists. See BAKE_STAGES.
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
readonly RETURN_LABEL="Gaming Mode"
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
# "gaming" is a ROOT row and "system.gaming" sits under System.
readonly MENU_EXT_REL=.config/omarchy/extensions/omarchy-menu.jsonc
# /etc/skel as well as the invoking user's home, and that is not belt and
# braces: docs/tasks/T5-fork-plan.md §3 trap (a) records that the ISO's
# `useradd` runs in phase 3 of 14, BEFORE our configure_deck phase, so a stage
# that seeds only skel produces a Deck whose first and only user never gets the
# row. The verification below reads the USER's copy for the same reason.
readonly MENU_EXT_SKEL="/etc/skel/${MENU_EXT_REL}"

# The row's id. A NEW id lands at the END of its parent's order
# (MenuModel.js:mergeMenuSources appends); reusing an existing id would keep
# that id's position and merge our fields on top of Omarchy's. Deliberately new
# -- overriding one of Omarchy's own rows to make room would be a surprise.
#
# 🔴 UNDER System, NOT AT THE ROOT, as of 2026-08-16. It was `gaming` -- a root
# row -- and the operator saw the consequence on hardware: a root row appears in
# BOTH menus, so "Gaming Mode" showed up in the apps menu (STEAM) *and* the
# Omarchy menu (QAM). One way back to Gaming Mode should have one home.
#
# The cost, stated rather than discovered: this is now one press deeper. That
# is the trade the operator chose, and it puts the row beside Omarchy's own
# Lock / Suspend / Logout / Reboot / Shutdown -- which is where a
# session-switching action belongs, and where someone looking for it will
# think to look.
#
# The dotted parent must be one Omarchy actually defines: `system` is declared
# at default/omarchy/omarchy-menu.jsonc:28, with system.screensaver / .lock /
# .suspend / .hibernate / .logout / .reboot / .shutdown as its children. Read
# off the pinned runtime, not assumed.
readonly MENU_ROW_ID=system.gaming

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
# 🔴 WRITTEN AS A JSON ESCAPE, NOT AS A CHARACTER, AND NOT AS $'\U000F0297'.
# Found on the Deck 2026-08-12, after 28 green suites: `$'\U...'` is
# LOCALE-DEPENDENT. Under a UTF-8 locale bash expands it to the character
# (f3 b0 8a 97); under C/POSIX it silently emits the literal ten ASCII bytes
# `\U000F0297`. The dev machine is UTF-8 and every test passed; an ssh session
# to the Deck runs LC_CTYPE="POSIX", so the rendered row carried an invalid
# JSON escape and the stage refused to install it. The failure was loud only
# because the stage parses back what it renders.
#
# `\udb80\ude97` is the UTF-16 surrogate pair for U+F0297 and is pure ASCII in
# this file, so no locale can change what gets written. JSON.parse (Quickshell)
# and json.loads (our readback) both recombine it; verified round-tripping to
# U+F0297. The glyph is md-gamepad_variant -- see the cmap note above.
readonly MENU_ROW_ICON='\udb80\ude97'

# --- the row's on-screen notice (operator request, 2026-08-16) -------------
#
# The switch takes seconds and used to give NO feedback at all: the press
# appeared to do nothing until gamescope came up. This says it is happening.
#
# \ud83d\udd34 OMARCHY'S OWN OSD, NOT A MECHANISM OF OURS, AND NOT A NOTIFICATION EITHER.
# The operator's requirement was that this "look exactly like the one for
# logging out in omarchy", so the template is Omarchy's own logout path,
# /usr/bin/omarchy-system-logout, read off the pinned runtime:
#
#     nohup bash -c "sleep 2 && uwsm stop" >/dev/null 2>&1 &
#     omarchy-osd -i logout -m "Logging out" -d 5000
#
# `omarchy-osd` is /usr/bin's, ships with omarchy, and hands a payload to the
# same Quickshell shell that draws the volume and brightness OSDs. So this
# looks like the platform because it IS the platform. An earlier draft of this
# used omarchy-notification-send instead: that renders the blue-bordered
# notification TOAST in the corner, which is a different Omarchy widget in a
# different place. The OSD is the centred card logout uses. Do not swap them
# back, and do not reach for notify-send, hyprctl notify or a daemon of ours --
# matching what logout already does is the entire requirement.
#
# \u26a0\ufe0f -i TAKES A NAME **OR** A GLYPH. OsdModel.js:iconFor maps a vocabulary
# (logout, volume, brightness, reboot...) and then falls through to
# `if (n.length > 0) return name` -- an unrecognised value is drawn verbatim.
# There is no gamepad NAME in that vocabulary, so the glyph is passed directly,
# and it is ${MENU_ROW_ICON}: the same codepoint the menu row itself shows, so
# the row and the OSD it raises carry one icon. See MENU_ROW_ICON above for why
# it is written as a JSON escape and must stay one.
readonly MENU_ROW_NOTICE="Launching Gaming Mode"

# Upstream's own numbers, deliberately. `omarchy-system-logout` asks for 5000ms
# and lets the session die under it, which is why the operator perceives the
# logout OSD as "about 3 seconds" -- the duration is an upper bound the
# teardown cuts short, not a measured lifetime. Matching the pair is what makes
# this feel like logout rather than merely resemble it. Neither number is
# asserted in the suites: they are Omarchy's timing, not ours to pin.
readonly MENU_ROW_OSD_MS=5000

# \ud83d\udd34 THE ORDERING IS THE WHOLE TRICK, AND IT IS UPSTREAM'S. The switch is
# BACKGROUNDED WITH A LEAD-IN FIRST and the OSD is drawn second, exactly as
# omarchy-system-logout backgrounds `sleep 2 && uwsm stop` before drawing its
# own. Two things fall out of that order, and both are load-bearing:
#
#   1. THE OSD GETS TIME TO RENDER. The Quickshell shell drawing it dies with
#      Hyprland when `systemctl stop sddm` runs, so a switch invoked inline
#      would tear down the very process being asked to draw. The lead-in is the
#      window in which it appears; after that the compositor stops and the last
#      frame it drew -- the one with the OSD in it -- is what stays on screen.
#   2. THE SWITCH IS UNCONDITIONAL. It is scheduled BEFORE `omarchy-osd` is
#      ever invoked, in a separate `nohup`'d shell, so nothing the OSD does can
#      prevent it. If omarchy-osd is missing, renamed or broken, the failure is
#      logged and the session still switches. That guarantee is STRUCTURAL --
#      it comes from the ordering, not from the `|| logger` -- which matters
#      because this notice is cosmetic and losing the only
#      controller-reachable way back to Gaming Mode would not be.
#
# Kept as its own constant so assert_return_action_agrees can require the row
# to START with it, i.e. can check property (2) rather than trust it.
readonly MENU_ROW_LEAD=2
readonly MENU_ROW_SWITCH="nohup bash -c 'sleep ${MENU_ROW_LEAD} && exec ${RETURN_ACTION}' >/dev/null 2>&1 &"

# What the row actually runs.
#
# \u26a0\ufe0f ONE LINE, AND SINGLE QUOTES ONLY. This string is emitted inside a JSON
# string in render_menu_row_block; a `"` or `\` would need escaping there, and
# a malformed extension file makes Quickshell drop EVERY user row and say
# nothing (see THE QUICKSHELL MENU ROW below). Everything here is ASCII for the
# same reason MENU_ROW_ICON is -- PROGRESS.md's locale trap -- including the
# icon, which stays a JSON escape until Quickshell's own parser decodes it.
#
# Menu.qml runs this through `bash -lc` (Commons/Util.qml:54, execDetached), so
# `&`, `>` and `||` are all honoured. A .desktop Exec= could NOT carry this --
# see assert_return_action_agrees.
readonly MENU_ROW_ACTION="${MENU_ROW_SWITCH} omarchy-osd -i '${MENU_ROW_ICON}' -m '${MENU_ROW_NOTICE}' -d ${MENU_ROW_OSD_MS} || logger -t deck-session 'omarchy-osd failed; the Gaming Mode switch was scheduled before it and still runs'"

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

# The sibling file, and the ONLY supported place to take an Omarchy default
# binding away: hyprland.lua requires "hypr.bindings" AFTER
# "default.hypr.omarchy", so an `hl.unbind` in here runs against a keymap the
# defaults have already populated. Same seeding rule as input.lua -- the
# `require` errors outright when the file is missing, so an absent one is
# seeded from Omarchy's skeleton rather than left out.
readonly HYPR_BINDINGS_LUA_REL=.config/hypr/bindings.lua
readonly HYPR_BINDINGS_LUA_TEMPLATE=/usr/share/omarchy/config/hypr/bindings.lua

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
# The suspend producer is now covered by SLEEP_LOCK_GLOBAL_OVERRIDE below; the
# menu row is deliberately left alone -- a lock the user ASKS for is not a lockout.
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
# (docs/findings/P22-deck-conformance-sweep.md §3.1, measured). That is
# per-user state: a fresh install, a second user or a wiped home loses it, and
# the unit's PRESET is `enabled`, so `systemctl --user preset-all` or simply a
# new user re-arms it. An installer's artefact has to outlive all of that, so
# it goes in /etc/systemd/user, the system-wide override directory for USER
# units, and the reason that path exists at all.
#
# ⚠️ PRECEDENCE, because it is what makes this work: systemd resolves a user
# unit BY NAME through ~/.config/systemd/user, then /etc/systemd/user, then
# /usr/lib/systemd/user, and the FIRST fragment found wins outright -- the
# later ones are never read. A `.wants/` symlink from an enable/preset does not
# inject a fragment path, so an enabled unit still resolves through that same
# search. Measured on the operator's Deck 2026-08-16: with only /etc/systemd/user
# carrying a file, `systemctl --user is-enabled` reported it, and /usr/lib's
# fragment did not run -- so /etc beating /usr/lib for this unit is now a
# measurement, not the inference this comment used to record.
#
# 🔴 IT IS AN INERT OVERRIDE, NOT A MASK, AND THE DIFFERENCE IS A SHIPPED
# DEFECT. Masking (the `-> /dev/null` symlink this used to install) does stop
# the lock -- and it also makes `systemctl --user enable --now` REFUSE:
#
#   Failed to enable unit: Unit /etc/systemd/user/omarchy-sleep-lock.service is masked
#
# Upstream's first-run step
# /usr/share/omarchy/install/user/first-run/enable-user-units.sh enables six
# units in ONE `enable --now`, under `set -euo pipefail`, so our mask killed
# the whole step. omarchy-provision-first-run then logged
# "Failed: enable user systemd units (exit code: 1)", never wrote its
# first-run-user done marker, and REPLAYED THE ENTIRE FIRST-RUN SEQUENCE ON
# EVERY LOGIN -- including the "Update System" and "Learn Keybindings"
# notifications, which are supposed to fire once and which reappeared every
# time the operator entered Desktop Mode. Confirmed end to end on the
# operator's Deck 2026-08-16 (docs/PROGRESS.md §5.24).
#
# So we ship a real unit of our own at the winning path instead: valid, so
# `enable --now` accepts and starts it; inert, so starting it does nothing.
# Upstream's fragment -- `ExecStart=/usr/bin/omarchy-system-sleep-monitor`,
# which execs `systemd-inhibit --what=sleep --mode=delay` and runs
# `omarchy-system-sleep-lock` on logind's PrepareForSleep -- is never read, so
# the inhibitor is never taken and the lock is never called. That is a stronger
# statement than "the service did not start": there is no code path from
# PrepareForSleep to the lock screen left anywhere in the resolved unit.
# Measured on the Deck 2026-08-16: after `enable --now`, ExecStart resolved to
# /usr/bin/true, `systemd-inhibit --list` carried no "Lock screen before
# suspend" holder, and no omarchy-system-sleep-monitor process existed.
#
# ⚠️ [Install] MUST MATCH UPSTREAM'S (`WantedBy=graphical-session.target`).
# `enable` writes .wants symlinks from whatever [Install] says; a unit with no
# [Install] makes `enable` fail just as loudly as a mask did, which is the same
# defect wearing a different hat.
#
# ⚠️ A PER-USER MASK NOW BREAKS THIS. ~/.config/systemd/user is searched FIRST,
# so a leftover hand-made `-> /dev/null` there shadows our override and
# re-creates the enable failure above. stage-desktop-settings says so out loud.
readonly SLEEP_LOCK_UNIT=omarchy-sleep-lock.service
readonly SLEEP_LOCK_GLOBAL_OVERRIDE="/etc/systemd/user/${SLEEP_LOCK_UNIT}"
# Where a per-user unit file would sit, relative to a home directory. Ours does
# not go here -- this is only what gets checked for a user file SHADOWING /etc.
readonly SLEEP_LOCK_USER_UNIT_REL=".config/systemd/user/${SLEEP_LOCK_UNIT}"
# What an inert unit has to run. Absolute (systemd requires it), and coreutils'
# `true` is present on any Arch/Omarchy target. Named as a constant so the
# renderer and its verification cannot drift apart.
readonly SLEEP_LOCK_INERT_EXEC=/usr/bin/true
readonly SLEEP_LOCK_WANTED_BY=graphical-session.target

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

# What `systemctl --global enable deck-input-mapper.service` writes, and the one
# artefact that distinguishes "installed" from "installed AND enabled". Derived
# from the two constants above rather than typed a third time: it is checked in
# two places now (the stage's own read-back, and the every-boot verifier), and a
# path that disagrees with itself is how an enabled-looking unit that never
# starts gets shipped.
readonly MAPPER_GLOBAL_WANTS="${MAPPER_UNIT%/*}/${MAPPER_WANTED_BY}.wants/${MAPPER_UNIT##*/}"

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
# one Steam moves for the brightness slider. DISCOVERED at runtime, never
# assumed -- see find_backlight, and read the two measurements below before
# putting a literal back.
#
# 🔴 THE NODE INDEX IS ENUMERATION ORDER, NOT HARDWARE. Both of these are the
# SAME physical panel on the SAME OLED Deck (Galileo):
#
#   /sys/class/backlight/amdgpu_bl0/brightness   Neptune kernel, read from
#                                                Steam's own log (this file's
#                                                header quotes it verbatim)
#   /sys/class/backlight/amdgpu_bl1/brightness   stock linux 7.1.8-arch1-3,
#                                                measured 2026-08-15 -- and
#                                                there was NO amdgpu_bl0 at all
#
# `amdgpu_bl0` was a readonly constant here until that second measurement. What
# it cost is worth stating, because it is subtler than "brightness broke": the
# RENDERED HELPER was never wrong -- its whitelist is a PATTERN over
# /sys/class/backlight/<one component>/brightness and it accepted bl1 the whole
# time (verified on the Deck 2026-08-15: the installed helper wrote bl1 and
# exited 0). What broke was this stage's own VERIFICATION. With a node that does
# not exist, verify_priv_write_helper takes its "not present" arm and WARNS, so
# the write path shipped unexercised on the one machine that has a panel -- the
# check passing for the wrong reason, which is the failure class this project
# exists to remove.
#
# WHY THE GLOB IS `amdgpu_bl*` AND NOT `*`. Discovery decides which node this
# stage WRITES during verification; it is not the security boundary (that is the
# helper's own pattern, which must stay wider because STEAM names the path, not
# us). On a Deck the panel is always an amdgpu backlight, and a wider glob would
# happily pick up an `intel_backlight` or a DDC-backed external monitor on a
# developer's machine and write to it. Narrow here, bounded there.
readonly BACKLIGHT_GLOB='/sys/class/backlight/amdgpu_bl*/brightness'
# Where the candidates are looked for when the glob matches nothing, so that
# "this machine has no backlight at all" and "this machine has one under a name
# we do not know" can be told apart -- they are different findings and only the
# second is a bug in this file.
readonly BACKLIGHT_CLASS_DIR=/sys/class/backlight

# 🔴 THE NODE MAY NOT BE DISCOVERED IN A CHROOT, AND THIS IS THE REASON.
# arch-chroot bind-mounts /sys from the INSTALLING system, and the installer
# boots the live ISO's stock archiso kernel while the target boots Neptune. The
# two enumerate the panel differently -- MEASURED, twice, on one physical Deck:
# the installer's kernel offered `amdgpu_bl1` and the installed system offers
# only `amdgpu_bl0` (PROGRESS.md 5.38 D10). So an install-time discovery answers
# a question about the WRONG MACHINE, and even a write that succeeded there
# would have recorded a node the target does not have. It did not succeed: the
# real install's stage-priv-write-helper FAILED with
# "'/sys/class/backlight/amdgpu_bl1/brightness' is not writable even as root".
#
# So in chroot mode the discovery is not attempted and the write path is not
# exercised. verify_priv_write_helper is handed this whitelist-SHAPED path that
# cannot exist, exactly as the "this machine has no backlight" arm does, so its
# boundary checks (refuses /etc/shadow, refuses a non-numeric value) still run
# for the right reason -- and the write half is deferred, out loud, to a unit
# that re-asks the question on the target's OWN kernel. See
# render_first_boot_verify.
readonly BACKLIGHT_CHROOT_SENTINEL="${BACKLIGHT_CLASS_DIR}/deck-session-chroot-cannot-answer-this/brightness"

# --- late-binding verification (PROGRESS.md 5.38) ---------------------------
#
# 🔴 THE GENERAL FORM OF D10, and it is not only about brightness: a check that
# reads HARDWARE STATE inside the installer's chroot is asking the live ISO's
# kernel about a machine that will boot a different one. Some such checks are
# safe -- DMI is firmware, and /sys/class/dmi/id/product_name reads the same on
# both kernels because the installer runs ON the target hardware. Others are
# not: driver-assigned names and indices (backlight nodes) and udev's runtime
# database (which rules ran, which tags are live) belong to whichever kernel and
# udevd are running right now.
#
# The answer is not to guess better at install time. It is to ask on the target,
# once it is up, and to say so loudly either way. This unit is that seam: one
# script, installed by whichever stage needs it, running every boot as root.
#
# WHY EVERY BOOT AND NOT ONCE. A marker file makes "the check has run" and "the
# check passed" indistinguishable after the fact -- the exact confusion this
# project keeps paying for. The checks are cheap, read-mostly and idempotent
# (the brightness one writes the panel its own current value), so running them
# on every boot costs nothing and puts a fresh, dated verdict in the journal
# instead of a stale one from an install nobody can see any more.
readonly FIRST_BOOT_VERIFY_BIN=/usr/local/lib/deck-session/first-boot-verify
readonly FIRST_BOOT_VERIFY_NAME=deck-session-verify.service
readonly FIRST_BOOT_VERIFY_UNIT="/etc/systemd/system/${FIRST_BOOT_VERIFY_NAME}"
readonly FIRST_BOOT_VERIFY_WANTS="/etc/systemd/system/multi-user.target.wants/${FIRST_BOOT_VERIFY_NAME}"
# The syslog tag every line it writes carries, so one grep finds the whole
# verdict:  journalctl -t deck-session-verify -b
readonly FIRST_BOOT_VERIFY_TAG=deck-session-verify

# --- Steam's first run (PROGRESS.md 5.35) -----------------------------------
#
# MEASURED, from Steam's own ~/.local/share/Steam/logs/bootstrap_log.txt on the
# installed Deck, 2026-08-15:
#
#   15:08:15  steam -gamepadui starts, "Downloading Update..."
#   15:08:15  "Download failed: http error 0" -> "Steam needs to be online to
#             update."                                <-- the modal the operator saw
#   15:08:16  relaunches, retries the same request, SUCCEEDS
#   15:09:51  "Extracting package..."
#   15:10:14  "Update complete, launching..."
#   15:10:18  the new client starts
#
# Two separate defects live in that table and they have separate fixes.
#
# 🐞 E2 -- THE ERROR IS A RACE, NOT A BROKEN NETWORK. One second apart, the
# identical request fails and then works: Steam is started before
# NetworkManager has connectivity. So Steam's start is ordered after a BOUNDED
# wait for connectivity.
#
# ⚠️ AND NOT ON network-online.target, which is the obvious answer and the wrong
# one. deck_wifi.py's first-boot unit says why in its own comment (it takes
# Wants=network.target deliberately): on a Deck with no network at all that
# target is reached only by TIMEOUT, so the cost lands on exactly the machines
# least able to afford it. On this machine it would not even do that --
# NetworkManager-wait-online.service is MASKED here (read off the Deck
# 2026-08-15), so network-online.target is never reached at all and an ordering
# on it would either hang or be silently meaningless.
#
# What is used instead is `nm-online`, which takes its own bound as an
# argument, run from a wrapper that ALWAYS exits 0. Both halves matter: the
# bound stops a networkless Deck paying for a network fix, and the exit 0 stops
# a Wi-Fi problem from turning into "Gaming Mode does not start".
readonly STEAM_LAUNCHER_UNIT=steam-launcher.service
readonly STEAM_WAIT_ONLINE_BIN=/usr/local/lib/deck-session/steam-wait-online
readonly STEAM_WAIT_DROPIN="/etc/systemd/user/${STEAM_LAUNCHER_UNIT}.d/50-deck-wait-online.conf"
# Seconds. Chosen against the measurement above rather than picked: the retry
# that worked was ONE second after the failure, so almost any bound closes the
# race, and the number's real job is to be a ceiling on a Deck that will never
# come online. 20 s is well under the ~120 s Steam then spends updating, so on a
# connected Deck it costs nothing. ⚠️ It is NOT what a networkless Deck pays --
# that is `-x`'s job, not this number's, and the difference matters because this
# wait runs at EVERY Gaming Mode start and not only the first. Read the note
# above render_steam_wait_online.
readonly STEAM_WAIT_SECONDS=20
# Phase 1's ceiling. Separate from the one above because it bounds a DIFFERENT
# question -- "has NetworkManager finished its startup pass yet" -- which on this
# hardware is already true by the time Gaming Mode starts (graphical.target at
# 20.25 s, PROGRESS.md 5.35) and so normally costs nothing.
readonly STEAM_WAIT_STARTUP_SECONDS=5
readonly NM_ONLINE_BIN=/usr/bin/nm-online

# 🔴 THE ONE CHANNEL THAT SURVIVES THE FIRST BOOT.
#
# Both artefacts in this section run ONCE, during the two minutes nobody can
# see, and P33 shipped both reporting only to the journal. That was measurably
# the wrong choice: PROGRESS.md 5.35 recorded that `journalctl --list-boots` on
# the installed Deck showed **only boot 0** -- the first boot was never
# captured -- so the stage's own advice ("confirm on the first boot with
# journalctl --user -u ...") was unanswerable at the moment it mattered, and the
# splash's failure on 2026-08-16 left no trace anywhere.
#
# So every branch of both scripts also appends one timestamped line to a FILE in
# the desktop user's home. It is readable in Desktop Mode with a text editor, by
# a person with no terminal and no SSH, after any number of reboots.
readonly FIRST_BOOT_LOG_REL=.local/state/deck-session/first-boot.log

# 🆕 E1 -- THE "DON'T TURN ME OFF" SPLASH.
#
# For ~2 minutes on the first boot, gamescope is up, Steam is updating itself
# headless, and the panel is black with no channel to say so: the cmdline is
# `quiet splash loglevel=0 systemd.show_status=false`, so the console prints
# nothing, and plymouth-quit ran at 659 ms -- three orders of magnitude before
# the window opens.
#
# 🔴 IT LIVES IN THE SESSION, NOT THE BOOT PATH, and that was decided rather
# than fallen into (docs/tasks/P33-fix-round.md §1). Holding plymouth past
# plymouth-quit puts a splash bug on the critical path of every boot; a session
# client that fails to start leaves exactly today's black screen. The failure
# modes are not comparable, so the placement is not a preference.
#
# 🔴 AND IT MUST NOT BE ABLE TO OUTLIVE STEAM. A splash that fails to exit is a
# permanently black-with-text panel -- strictly worse than the defect it fixes,
# and on a device whose only escape is a ten-second hardware hold. It is
# therefore bounded THREE independent ways, none of which depends on the other
# two working: the script's own deadline, systemd's RuntimeMaxSec= on the unit,
# and PartOf= so that a session teardown takes it with it.
readonly SPLASH_UNIT_NAME=deck-steam-splash.service
readonly SPLASH_UNIT="/etc/systemd/user/${SPLASH_UNIT_NAME}"
readonly SPLASH_BIN=/usr/local/lib/deck-session/steam-first-boot-splash
readonly SPLASH_IMAGE=/usr/local/share/deck-session/steam-first-boot.png
# Relative to the desktop user's home. Shown ONCE: later boots reach Gaming
# Mode in ~39 s and the splash must not appear in front of a client that is
# about to draw. Written BEFORE anything is displayed, deliberately -- a splash
# that crashes must not get a second attempt at every boot forever.
readonly SPLASH_MARKER_REL=.local/state/deck-session/steam-first-boot-shown
# 🔴 THE MARKER IS STAMPED WITH THIS, AND THAT IS WHY THE FIX IS TESTABLE AT ALL.
#
# P33's marker held only a date, and it was written before the attempt (see
# above -- that ordering is deliberate and is kept). The consequence was not
# noticed until hardware: the 2026-08-16 boot drew nothing, wrote the marker
# anyway, and thereby disabled the feature on that Deck **for ever**. Any fix
# shipped afterwards would have been untestable without a human deleting a
# dotfile by hand, on a device with no keyboard.
#
# So the marker records WHICH implementation had its one attempt. A marker whose
# first field is not this string -- including every P33 marker, which starts
# with a date -- is treated as belonging to a different implementation, and this
# one gets its own single attempt. The safety property is unchanged: one attempt
# per implementation, never one per boot.
#
# ⚠️ BUMP THIS when the splash changes in a way that deserves another attempt on
# a Deck that has already run it. Do not bump it for a comment.
readonly SPLASH_ATTEMPT_ID=p34-1
# Seconds. The measured update was 123 s end to end; this is that with room and
# a hard stop. It is a CEILING, not a duration -- the normal exit is Steam's UI
# appearing.
readonly SPLASH_MAX_SECONDS=300
# The process that only exists once the Steam CLIENT is running. The updater
# that runs during those two minutes is not it, which is what makes this a
# usable "Steam is drawing now" signal rather than "Steam was started".
readonly SPLASH_STEAM_READY_PROC=steamwebhelper
# gamescope's logical output, which is landscape: the panel is 800x1280 portrait
# and gamescope applies its own transform (that is why Gaming Mode is exempt
# from the rotation work in PANEL_TRANSFORM above). An image drawn portrait here
# would be the one thing on the Deck rotated the wrong way.
readonly SPLASH_IMAGE_SIZE=1280x800
readonly SPLASH_VIEWER=/usr/bin/imv

# ⚠️ NO NEW PACKAGE IS NEEDED FOR ANY OF THIS, and that was CHECKED rather than
# hoped for. All three tools this section leans on are already in Omarchy's own
# base list (runtime-src/install/omarchy-base.packages), which is installed on
# the target before the bake runs -- `imagemagick` line 59, `imv` line 60,
# `networkmanager` (which ships nm-online) line 64. Read 2026-08-15, and
# confirmed present on the installed Deck the same day.
#
# So nothing here touches iso/upstream/builder/build-iso.sh's package list or
# iso/overlay/configs/deck/*.packages. Every one is still checked at the point
# of use, because "in a package list today" and "on this machine" are different
# claims -- and a missing one costs the splash, never the stage.

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

# THE MENU FLASH, and why the udev rule above does not touch it.
#
# Omarchy binds this key in Desktop Mode --
#   /usr/share/omarchy/default/hypr/bindings/utilities.lua:
#   o.bind("XF86PowerOff", "Power menu", "omarchy-menu toggle system",
#          { locked = true })
# -- so a press ALSO toggles the System menu. That is a second handler for one
# button, and it is what the operator has been seeing flash before the Deck
# sleeps.
#
# 🔴 THE UDEV RULE CANNOT FIX IT, and believing otherwise cost this stage's
# output a paragraph of wrong advice. `power-switch` is a tag systemd-logind
# filters on; Hyprland does not look at it at all -- libinput opens EVERY input
# device on the seat. So the untagged ACPI node keeps delivering KEY_POWER to
# the compositor, one physical press stays TWO XF86PowerOff events there, and
# `toggle` therefore opens the menu and closes it again.
#
# MEASURED on the operator's Deck 2026-08-16, by replaying T13 §2.2's two
# sources through two uinput keyboards 165 ms apart with logind's
# handle-power-key blocked (so only the compositor could answer):
#
#   17:00:18.379 openlayer>>omarchy-menu
#   17:00:18.493 closelayer>>omarchy-menu
#
# 114 ms of System menu, on screen, per press. A single synthetic event in the
# same harness left the menu OPEN, which is the same mechanism seen from the
# other side. The suspend that follows is a THIRD, independent actor; it is not
# what closes the menu, it just makes the flash brief.
#
# So the fix is to remove the second handler, not to make suspend faster: one
# `hl.unbind` in the user's own bindings.lua, installed by this stage alongside
# the two files that make the key suspend, because arming one without the other
# is what produced the defect.
readonly POWER_MENU_BIND_KEY=XF86PowerOff

# Delimited for the same reason OSK_KB_RULE_* is: a re-run replaces its own
# block instead of appending a second copy, and the user's own bindings above
# it are never touched.
readonly POWER_BIND_RULE_BEGIN="-- >>> deck-session.sh: power button, no System menu >>>"
readonly POWER_BIND_RULE_END="-- <<< deck-session.sh: power button, no System menu <<<"

# Assigned by the LAST line of that block, so its presence in a live compositor
# proves the block executed. Asserted with `hyprctl eval 'if ... then error()'`,
# never read back -- see OSK_KB_SENTINEL for why a readback cannot fail.
readonly POWER_BIND_SENTINEL=DECK_POWER_MENU_UNBOUND

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
# omarchy-sleep-lock.service resolves to our inert override -- upstream's
# fragment is what locks the screen on PrepareForSleep. Making the power button
# suspend while upstream's unit is the one that resolves turns every press into
# an unanswerable password prompt (blast-radius R2 in T13 §7), so the stage says
# so out loud before it finishes.
#
# ⚠️ THE UNIT AND ITS OVERRIDE PATH ARE DECLARED ONCE, WAY ABOVE, as
# SLEEP_LOCK_UNIT and SLEEP_LOCK_GLOBAL_OVERRIDE -- read the WHY there,
# including why it is a real inert unit and not a mask. This block used to
# redeclare both, and used to say the mask was "HAND-APPLIED on the test Deck
# and not shipped from src/ at all". That expired: install_sleep_lock_override
# ships it from stage-desktop-settings. What has NOT changed is that this stage
# must still check rather than assume -- the stages can be run one at a time,
# and a Deck whose power button suspends before the override is installed is
# the bad ordering.
#
# The search path, in systemd's own precedence order, for answering "which
# fragment would win HERE" rather than "did we install ours".
# ~/.config/systemd/user comes ahead of all three and is per-user, so it is not
# in this list.
readonly -a SLEEP_LOCK_UNIT_DIRS=(/etc/systemd/user /usr/local/lib/systemd/user /usr/lib/systemd/user)

# --- the pizza (stage-pizza) ----------------------------------------------
#
# `pizza` is the project's own command on the installed system: a dispatcher
# that execs a separate `pizza-<subcommand>` executable, so a subcommand can be
# written, tested and shipped on its own. src/pizza's own header is the contract.
#
# This stage installs the dispatcher, the `pizza pizza` subcommand and the art.
# It does NOT run `pizza pizza`: that writes ~/.config/fastfetch/config.jsonc
# and ~/.bashrc, and doing it from a chroot would be writing user config on
# behalf of a user who has never logged in -- and then verifying it by rendering
# fastfetch, which in here would read the INSTALLER's machine. The command
# lands; a human turns it on.
#
# ⚠️ THE OTHER SUBCOMMAND IN src/ IS DELIBERATELY NOT LISTED HERE, and this
# comment does not name it either -- its own unit suite greps this file and
# iso/overlay for its name and fails on any hit, because "off by default,
# always" is a property of the whole install path rather than of one script.
# `pizza help` already reports it as missing rather than hiding it. Adding it
# here is a one-line change, for its owner to make when it should ship.
readonly PIZZA_BIN_DIR=/usr/local/bin
readonly PIZZA_SHARE_DIR=/usr/local/share/pizza
readonly PIZZA_DISPATCHER_NAME=pizza
readonly -a PIZZA_SUBCOMMANDS=(pizza-pizza pizza-ssh)
# The art the command uses, and the ONLY place the choice is written down.
# Swapping the pizza is a one-file change: replace src/pizza-art/pizza.txt (the
# alternates live beside it) and re-run the stage. Nothing here, and nothing in
# any test, knows what is inside it.
readonly PIZZA_ART_NAME=pizza.txt
readonly PIZZA_ART_ALT_GLOB='pizza-alt-*.txt'

# ⚠️ TWO PLACES, AND THE SECOND IS NOT A FALLBACK -- it is the shape the ISO
# actually ships. deck_session_bake.stage_payload() copies "every regular file
# in asset_dir, FLAT" (its own docstring), so the build stages src/pizza-art/*
# alongside deck-session.sh rather than under a subdirectory, and a target-side
# run finds the art beside the script. A dev-machine run finds it in the repo
# layout. Both are real; neither is a guess. This is the same one-authority /
# two-layouts arrangement src/deck-input-mapper.py's OSK_SEARCH_DIRS uses.
readonly -a PIZZA_ART_SEARCH_DIRS=(pizza-art .)

readonly -a INSTALL_STAGES=(
  stage-preconditions
  stage-session-select
  stage-steam-hook
  stage-update-stub
  stage-timezone-helper
  stage-priv-write-helper
  # Beside the other three Steam-facing stages, and after them: it installs a
  # drop-in on Valve's steam-launcher.service and a splash for Steam's first
  # run, neither of which is worth anything if the stubs above did not land.
  stage-steam-first-run
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
  # Last, and it is the cheapest stage in the file: three root-owned files under
  # /usr/local and no system state at all. It installs the `pizza` command; it
  # does not turn the easter egg on. Ordering it after everything that matters
  # means a failure here can never be mistaken for a failure of the install.
  stage-pizza
)

# The stages the ISO's installer bakes into a target, in run order. Read out of
# this file by deck_session_bake.py through `list-bake-stages`, so the list has
# ONE home and it is next to the stages it names.
#
# It is INSTALL_STAGES with two deliberate differences:
#
#   - stage-desktop-settings is OUT. Three orchestrator steps (session_dconf,
#     idle_policy, mask_sleep_lock) already write its dconf, idle-policy and
#     sleep-lock halves at install time, from the same constants. Running this
#     stage after them is not merely redundant: the site file they write carries
#     no marker of ours, so assert_ours_or_absent refuses it -- correctly, and
#     the whole stage would fail. Measured on the operator's Deck 2026-08-15
#     (/etc/dconf/db/local.d/50-deck-desktop, written 11:25 by the installer).
#   - stage-osk-kb-layout is IN, and it is the half of stage-desktop-settings
#     that nothing else owns: the per-device XKB pin for the on-screen
#     keyboard's uinput device. deck_input.py's docstring is explicit that this
#     rule is deck-session.sh's to write and that its own block is a different
#     one, so this is a division of labour that already exists on paper.
#
#   - stage-power-button is IN, as of PROGRESS.md 5.38 D9, and it was NOT
#     before. 🔴 The reason for the change is that leaving it out shipped a
#     Deck whose power button does nothing at all: Omarchy's package-owned
#     /etc/systemd/logind.conf.d/10-ignore-power-button.conf resolves
#     HandlePowerKey=ignore, logind logs 'Power key pressed short' on every
#     press and drops it, and the whole of this file's T13 work -- the udev
#     untagging, the sort-order proof, the double-suspend guard -- was written,
#     unit-tested, documented and reached by no code path. That is the P32
#     family (Steam, the mapper, steamos-session-select, the reserved-username
#     list), and the argument that kept it out ("a bare run must not arm a
#     hardware button on a machine nobody has watched") is an argument about a
#     BARE RUN, which is why it stays out of INSTALL_STAGES and stays in
#     list-stages. The installer is not a bare run: it is building the product,
#     on hardware it has just identified, from a plan a human approved.
#     What answers the safety half instead is that the stage refuses any model
#     but ${POWER_MODEL} (it now SKIPS rather than fails when baked, so a VM
#     install is not a failed stage), and that the one live question a chroot
#     cannot answer -- did the udev rule actually match? -- is deferred to
#     ${FIRST_BOOT_VERIFY_NAME}, which DISARMS the handler on the target if it
#     did not.
#
# The two remaining opt-in stages stay opt-in here too, on their own arguments,
# which chroot mode does not change: stage-default-session (deck_autologin.py
# already writes and verifies the autologin drop-in -- a second writer of one
# file is the drift this project pays for) and stage-boot-default-gaming (arms
# a re-assert at EVERY boot on a machine whose Gaming Mode nobody has yet
# watched start; it is an operator decision, and its ordering check needs a
# live systemd).
readonly -a BAKE_STAGES=(
  stage-preconditions
  stage-session-select
  stage-steam-hook
  stage-update-stub
  stage-timezone-helper
  stage-priv-write-helper
  stage-steam-first-run
  stage-greeter-rotation
  stage-sddm-resilience
  stage-return-icon
  stage-menu-row
  stage-input-mapper
  stage-lizard-mode
  stage-osk-kb-layout
  # Before the power button, because everything is. It writes three root-owned
  # files under /usr/local and touches no system state, so it is safe anywhere
  # in this list -- it sits here so the last thing the installer does is still
  # the hardware-button stage below.
  stage-pizza
  # Last, and the ordering is not arbitrary: it writes the two files that
  # change what a hardware button does, and every other stage should already
  # have had its chance to fail before anything rewires the power key. It also
  # depends on stage-desktop-settings' sleep-lock mask being decided (it checks
  # rather than assumes -- warn_if_sleep_lock_live), and on the verification
  # unit stage-priv-write-helper installs, which is above it.
  stage-power-button
)

log()  { printf '[%s] %s\n' "$PROG" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$PROG" "$*" >&2; }
fail() { printf '[%s] ERROR: %s\n' "$PROG" "$*" >&2; exit 1; }
usage_error() { printf '[%s] usage: %s\n' "$PROG" "$*" >&2; exit 2; }

# --- chroot mode ------------------------------------------------------------
#
# Read the CHROOT MODE block in this file's header before touching anything
# below. The short form: DECK_SESSION_CHROOT=1 says "you are inside arch-chroot,
# as root, on a target that has never booted", and every branch it selects does
# the file-level work anyway and defers only what needs a running system.
CHROOT_MODE=0
if [[ ${DECK_SESSION_CHROOT:-0} == 1 ]]; then
  CHROOT_MODE=1
fi
readonly CHROOT_MODE

in_chroot() { [[ $CHROOT_MODE -eq 1 ]]; }

# 🔴 THE ONE OUTPUT SHAPE THE INSTALLER PARSES. deck_session_bake.py greps for
# this prefix and copies every line into /var/log/omarchy-deck-install.json, so
# a deferred check is a fact in the install record rather than a line in a log
# nobody reads. Keep it one line and keep the prefix.
#
# ⚠️ This is NOT a way to skip something quietly. Every call site defers a
# CHECK, never an artefact -- if you find yourself deferring a write, the
# artefact is missing from the shipped image and defer() is hiding it.
defer() { printf '[%s] DEFERRED (chroot): %s\n' "$PROG" "$*" >&2; }

# Who the desktop user is.
#
# ${DECK_SESSION_USER} first, and only chroot mode ever sets it: inside
# arch-chroot this process is root, there is no SUDO_USER, and $USER is root or
# unset -- so every stage that resolves a user would fail with "cannot determine
# the unprivileged user". The installer knows the answer (it created the
# account, and deck_user.resolve_target_user CONFIRMS it against the target's
# own /etc/passwd rather than trusting what archinstall was told), so it passes
# it in. The two existing forms are unchanged and still come first off a Deck.
desktop_user() { printf '%s' "${DECK_SESSION_USER:-${SUDO_USER:-${USER:-$(id -un)}}}"; }

# A compositor runtime directory that cannot exist, handed to verify_osk_kb_layout
# in chroot mode. NOT a way of skipping the check: that function's "no live
# Hyprland" arm already warns loudly and names the command to run later, which is
# exactly the right report here. What this avoids is the opposite mistake --
# arch-chroot bind-mounts /run, so /run/user/<uid> inside the chroot is the
# INSTALLER's, and a real hyprctl reload would be fired at the installer's own
# session mid-install.
readonly CHROOT_NO_HYPR_RUNTIME=/nonexistent/deck-session-chroot-has-no-compositor

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

  if in_chroot; then
    # Inside arch-chroot there is nothing to escalate FROM: the process is
    # already root, and `sudo` there has no tty, no PAM session and no audit
    # socket to rely on. A non-root chroot run is a caller bug, not a state to
    # work around, so it stops here rather than half-installing as the wrong uid.
    [[ $EUID -eq 0 ]] ||
      fail "DECK_SESSION_CHROOT=1 but this process is EUID ${EUID}, not root. Chroot mode is entered only by the installer, through 'arch-chroot <target> ${PROG}.sh <stage>', which is always root -- there is no escalation path inside a chroot."
    SUDO=""
    log "chroot mode: running inside the install target as root, with no systemd manager, no D-Bus and no session"
  elif [[ $EUID -eq 0 ]]; then
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
    if in_chroot; then
      # 🔴 A WARNING AND NOT A REFUSAL, ONLY HERE, AND THE ARGUMENT IS NARROW.
      # arch-chroot bind-mounts /sys, so this DMI reads the machine doing the
      # installing -- which is the machine that will run the target. Refusing
      # would be defensible; what it would actually cost is the whole automated
      # QEMU install tier (CLAUDE.md's second testing tier), where nothing is a
      # Deck and this phase would then be exercised by nobody but hardware.
      # Everything the baked stages write is inert on a machine that is not a
      # Deck -- and the one stage that would NOT be inert on other hardware,
      # the power button, keeps its own model gate. ⚠️ That stage IS baked now
      # (PROGRESS.md 5.38 D9); what makes this warning still safe is
      # verify_power_button_model, which on a baked run reports the machine as
      # unsupported and writes nothing rather than rewiring a button on
      # hardware nobody has measured.
      warn "this machine reports product='${product:-?}' vendor='${vendor:-?}', which is not Steam Deck hardware. Continuing because chroot mode is the installer's, and an ISO built for the Deck may legitimately be installed in a VM for testing -- but NOTHING below has been exercised on this hardware."
    else
      fail "not Steam Deck hardware (product='${product:-?}' vendor='${vendor:-?}'). Refusing to rewrite session configuration."
    fi
  fi
  log "hardware: ${vendor:-unknown} ${product:-unknown}"

  # SDDM is the switching mechanism. Without it there is nothing to restart.
  if in_chroot; then
    # `systemctl list-unit-files` asks the unit-file loader rather than the
    # manager, but the target has never booted and this is the one precondition
    # cheap enough to answer from the disk it is actually about. Same three
    # directories systemd searches, in its own precedence order.
    local sddm_unit="" ud
    for ud in /etc/systemd/system /usr/local/lib/systemd/system /usr/lib/systemd/system; do
      [[ -f "$ud/sddm.service" ]] && { sddm_unit="$ud/sddm.service"; break; }
    done
    [[ -n $sddm_unit ]] ||
      fail "no sddm.service unit file anywhere on the target (looked in /etc/systemd/system, /usr/local/lib/systemd/system, /usr/lib/systemd/system). This script switches sessions by restarting the display manager and supports SDDM only, which is what Omarchy installs -- so an image without it cannot switch sessions at all."
    log "display manager: ${sddm_unit}"
  else
    systemctl list-unit-files sddm.service --no-pager 2>/dev/null | grep -q sddm ||
      fail "sddm.service not found. This script switches sessions by restarting the display manager and supports SDDM only (which is what Omarchy installs)."
  fi

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
  local invoking_user; invoking_user=$(desktop_user)
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
  local session_user=${1:-$(desktop_user)}
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
  local invoking_user; invoking_user=$(desktop_user)
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

  if in_chroot; then
    # `timedatectl show` is a D-Bus call to systemd-timedated. In a chroot there
    # is no bus and no manager, so the round trip cannot be performed -- and
    # running it against the INSTALLER's bus would be worse than not running it,
    # because it would answer about the wrong machine.
    #
    # What CAN be exercised is the half that decides whether this file is safe
    # to sit behind a sudo grant: every validation in it runs BEFORE any
    # elevation, so the refusal path needs no timedatectl at all. That is run
    # here, against the file that was just installed.
    local rc=0
    "$helper" ../../etc/shadow >/dev/null 2>&1 || rc=$?
    [[ $rc -ne 0 ]] ||
      fail "${helper} accepted a path-traversal timezone. It must validate against /usr/share/zoneinfo before elevating."
    rc=0
    "$helper" >/dev/null 2>&1 || rc=$?
    [[ $rc -ne 0 ]] ||
      fail "${helper} exited 0 with no argument at all; it must refuse rather than elevate on an empty timezone."
    log "verified (chroot): the helper refuses a traversal argument and an empty one, both before it elevates"
    defer "the timezone round trip (set the current zone, read it back) needs systemd-timedated on a live D-Bus, which a chroot has neither of. The helper and its sudoers grant are installed; the set path first runs when Steam's OOBE picker uses it. Confirm on the installed machine with: /usr/bin/steamos-polkit-helpers/steamos-set-timezone \"\$(timedatectl show -p Timezone --value)\""
    return 0
  fi

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
# LATE-BINDING VERIFICATION -- the answer to PROGRESS.md 5.38 D10
# ---------------------------------------------------------------------------

# The body of ${FIRST_BOOT_VERIFY_BIN}, written to stdout. Same seam as every
# other render_* here: the unit suite can read it with no Deck, no root and no
# VM.
#
# 🔴 WHY THIS FILE EXISTS AT ALL, given that this project's rule is "nothing the
# installed system NEEDS is left to first boot". It leaves no artefact to first
# boot. Both artefacts -- the priv-write helper and the power-button files --
# are written at install time, complete, by their own stages. What is deferred
# here is a pair of QUESTIONS THE INSTALLER'S KERNEL CANNOT ANSWER:
#
#   1. Does Steam's brightness write actually land? The node is named by the
#      KERNEL, and the installer's kernel is not the target's -- measured, one
#      Deck, two answers (amdgpu_bl1 in the ISO, amdgpu_bl0 installed).
#   2. Did the power-button udev rule match? udev's tags are runtime state of
#      whichever udevd is running, so the chroot can only see the installer's.
#
# ⚠️ IT DUPLICATES A LITTLE LOGIC FROM THIS FILE, AND THAT IS DELIBERATE RATHER
# THAN CARELESS. deck-session.sh is NOT installed on the target -- the bake
# stages it into /var/tmp and deletes it (deck_session_bake.py's docstring says
# why: an unowned 5000-line script in /usr/local would be a second, unversioned
# source of truth on every Deck). So a first-boot check either carries the few
# lines it needs or the script has to ship, and shipping it is the larger harm.
# What it carries is kept to the smallest possible restatement, every constant
# is interpolated from the ones above rather than retyped, and it deliberately
# does NOT restate find_backlight's three-outcome contract -- it has its own
# two outcomes, because by the time it runs, "no backlight on this machine"
# is no longer an ordinary answer.
render_first_boot_verify() {
  local user=${1:-$(desktop_user)}
  cat <<EOF
#!/usr/bin/env bash
#
# deck-session first-boot / every-boot verification.
${INSTALL_MARKER}
#
# Runs as root from ${FIRST_BOOT_VERIFY_NAME}. Read the LATE-BINDING
# VERIFICATION block in ${PROG}.sh before changing anything here.
#
# Every line it writes is tagged '${FIRST_BOOT_VERIFY_TAG}':
#   journalctl -t ${FIRST_BOOT_VERIFY_TAG} -b
#
# ...AND every line is also appended to ~/${FIRST_BOOT_LOG_REL}, because this
# device has no terminal in normal use. A verdict that only exists in the
# journal is a verdict only someone with SSH can read, and SSH does not survive
# a reinstall (PROGRESS.md 5.36). That file opens in a text editor.
#
# NOT 'set -e'. The checks are independent and a machine with a brightness
# problem must still get its power-button verdict. Each one records its own
# outcome and the exit status is the union, so a failure is visible in
# 'systemctl --failed' rather than only in a log nobody opens.
set -uo pipefail

failures=0

# Written AS ${user}, not as root: this is the same file the Steam first-run
# scripts append to, and a root-owned copy would make every one of their writes
# fail (they redirect with '|| true', so the loss would be silent). Every step
# of the append is best-effort for the same reason -- a logging problem must
# never change a verdict.
user_home=\$(getent passwd ${user} 2>/dev/null | cut -d: -f6)
log_file=""
[[ -n \$user_home ]] && log_file="\${user_home}/${FIRST_BOOT_LOG_REL}"

say() {
  printf '%s\n' "\$1"
  logger -t ${FIRST_BOOT_VERIFY_TAG} -- "\$1" 2>/dev/null || true
  [[ -n \$log_file ]] || return 0
  local line
  printf -v line '%s ${FIRST_BOOT_VERIFY_TAG}: %s' "\$(date -Iseconds)" "\$1"
  runuser -u ${user} -- bash -c 'mkdir -p -- "\$(dirname -- "\$1")" 2>/dev/null; printf "%s\n" "\$2" >>"\$1"' _ "\$log_file" "\$line" 2>/dev/null || true
}
bad()  { say "FAIL: \$1"; failures=\$((failures + 1)); }

# --- 1. brightness, on the kernel that is actually running -----------------
#
# Gated on the helper existing: stage-priv-write-helper installs both, so if
# the helper is absent this check has nothing to say and says so.
if [[ -x ${PRIV_WRITE_HELPER} ]]; then
  nodes=()
  for p in ${BACKLIGHT_GLOB}; do
    [[ -e \$p ]] && nodes+=("\$p")
  done

  if [[ \${#nodes[@]} -eq 0 ]]; then
    have=\$(ls -1 ${BACKLIGHT_CLASS_DIR} 2>/dev/null | tr '\n' ' ')
    bad "no backlight matches ${BACKLIGHT_GLOB} on this running kernel (\$(uname -r)). ${BACKLIGHT_CLASS_DIR} carries: \${have:-<nothing>}. Gaming Mode's brightness slider has no node to drive, and the whitelist in ${PRIV_WRITE_HELPER} would refuse whatever Steam names."
  else
    # Deterministic, and said out loud when there is a choice -- the same rule
    # find_backlight follows, for the same reason.
    if [[ \${#nodes[@]} -gt 1 ]]; then
      mapfile -t nodes < <(printf '%s\n' "\${nodes[@]}" | sort -V)
      say "note: more than one backlight matches (\${nodes[*]}); taking \${nodes[0]}"
    fi
    bl=\${nodes[0]}
    before=\$(cat "\$bl" 2>/dev/null) || before=""
    if [[ -z \$before ]]; then
      bad "could not read \${bl}"
    else
      # AS THE DESKTOP USER, not as root, and that is the point: root would
      # exercise the helper's inner branch only. Going through ${user} runs the
      # real path Steam runs -- sudo -n, the sudoers grant, then the whitelist.
      rc=0
      runuser -u ${user} -- ${PRIV_WRITE_HELPER} "\$bl" "\$before" >/dev/null 2>&1 || rc=\$?
      after=\$(cat "\$bl" 2>/dev/null) || after=""
      if [[ \$rc -ne 0 ]]; then
        bad "${PRIV_WRITE_HELPER} exited \${rc} writing \${bl} its own current value (\${before}) as ${user}. Gaming Mode's brightness slider will fall back to 'sudo -n tee' and 'sudo -n chmod a+w', which need blanket sudo and leave the node world-writable. See: journalctl -t steamos-priv-write -b"
      elif [[ \$after != "\$before" ]]; then
        bad "${PRIV_WRITE_HELPER} changed \${bl} from \${before} to \${after} while being asked for \${before}"
      else
        say "ok: brightness -- ${PRIV_WRITE_HELPER} accepted \${bl} as ${user} and wrote \${before} (kernel \$(uname -r))"
      fi
    fi
  fi
else
  say "note: ${PRIV_WRITE_HELPER} is not installed, so there is no brightness path to verify"
fi

# --- 2. the power-button rule, against this kernel's udev database ---------
#
# Gated on the drop-in existing, so this is silent on a machine where
# stage-power-button never ran (an LCD Deck, a VM, an opt-out).
if [[ -e ${POWER_LOGIND_DROPIN} ]]; then
  if ! command -v udevadm >/dev/null 2>&1; then
    bad "${POWER_LOGIND_DROPIN} is installed but udevadm is missing, so whether the power-button rule matched cannot be checked"
  else
    keep_tagged=0
    still_tagged=""
    for dev in /dev/input/event*; do
      [[ -e \$dev ]] || continue
      props=\$(udevadm info --query=property --name "\$dev" 2>/dev/null) || continue
      id=\$(printf '%s\n' "\$props" | sed -n 's/^ID_PATH=//p' | head -n1)
      # 🔴 CURRENT_TAGS, NOT TAGS, AND THE DIFFERENCE IS THE WHOLE CHECK.
      # udev keeps two lists: TAGS is CUMULATIVE -- every tag the device has
      # ever carried, and \`TAG-=\` never takes anything out of it -- while
      # CURRENT_TAGS is what the latest uevent left in place, which is what
      # systemd-logind's tag filter matches on.
      #
      # Reading TAGS here made this check unfalsifiable: 70-power-switch.rules
      # adds the tag, ${POWER_UDEV_RULE##*/} removes it, TAGS still lists
      # it, and the verdict below concluded "the rule did NOT untag" on a
      # machine where it had worked perfectly -- then deleted the drop-in and
      # left the operator with a power button that did nothing. MEASURED on the
      # operator's Deck 2026-08-16 (\`udevadm info -q property\`): the two ACPI
      # nodes carry TAGS=:power-switch: with NO CURRENT_TAGS line at all, the
      # surviving i8042 node carries both, and logind logs exactly ONE
      # 'Power key pressed short' per press -- one source, i.e. the rule took.
      #
      # ⚠️ verify_power_button_premise deliberately reads TAGS instead, and that
      # is not an inconsistency: it asks "is this the kind of node that gets
      # tagged" BEFORE installing, and must keep saying yes on a re-run after
      # our own rule has already removed the current tag.
      tags=\$(printf '%s\n' "\$props" | sed -n 's/^CURRENT_TAGS=//p' | head -n1)
      [[ -n \$id ]] || continue
      case ":\${tags}:" in *":${POWER_UDEV_TAG}:"*) tagged=1 ;; *) tagged=0 ;; esac
      [[ \$id != "${POWER_KEEP_ID_PATH}" ]] || keep_tagged=\$tagged
EOF
  local p
  for p in "${POWER_ACPI_ID_PATHS[@]}"; do
    cat <<EOF
      if [[ \$id == "${p}" && \$tagged -eq 1 ]]; then still_tagged="\${still_tagged} ${p}"; fi
EOF
  done
  cat <<EOF
    done

    if [[ -n \$still_tagged ]]; then
      # 🔴 THE ONE STATE THIS WHOLE DESIGN EXISTS TO AVOID, and the only one
      # worth undoing automatically: the handler is armed and a second
      # KEY_POWER source is still live, so one press becomes two suspend
      # requests ~198 ms apart and the second lands at or just after resume.
      # On a device whose only other escape is a ten-second hardware hold that
      # is indistinguishable from a Deck that will not wake, so the handler is
      # DISARMED here rather than reported and left running. Removing the
      # drop-in restores exactly today's behaviour: Omarchy's
      # 10-ignore-power-button.conf takes the key back.
      rm -f ${POWER_LOGIND_DROPIN}
      bad "the power-button udev rule did NOT untag:\${still_tagged} on this kernel (CURRENT_TAGS still lists ${POWER_UDEV_TAG}), so KEY_POWER still has more than one source while HandlePowerKey=${POWER_KEY_ACTION} was armed -- the re-suspend loop. ${POWER_LOGIND_DROPIN} has been REMOVED, which restores the previous behaviour. ⚠️ In Desktop Mode that now means the power button does NOTHING: stage-power-button also removed Omarchy's ${POWER_MENU_BIND_KEY} menu bind, and that block is still in ~/${HYPR_BINDINGS_LUA_REL}. Delete it to get the menu back. ${POWER_UDEV_RULE} is left in place; it is harmless alone. Re-run the capture in docs/findings/T13-power-button-and-sleep.md 2.2 on this machine and correct POWER_ACPI_ID_PATHS."
    elif [[ \$keep_tagged -ne 1 ]]; then
      # Not disarmed: a missing keeper means logind is watching nothing, i.e.
      # the button is DEAD. That is a defect, but removing the drop-in cannot
      # improve it and would only hide which change caused it.
      bad "no device carries ID_PATH=${POWER_KEEP_ID_PATH} with CURRENT_TAGS=:${POWER_UDEV_TAG}: on this kernel. That is the single KEY_POWER source this design keeps, so systemd-logind has nothing to act on and the power button does nothing. ${POWER_LOGIND_DROPIN} is left in place so the cause stays visible."
    else
      say "ok: power button -- ${POWER_KEEP_ID_PATH} is the surviving tagged KEY_POWER source and the ACPI duplicate(s) are untagged"
    fi
  fi
else
  say "note: ${POWER_LOGIND_DROPIN} is not installed, so there is no power-button rule to verify"
fi

# --- 3. the desktop input mapper: installed, and enabled -------------------
#
# 🔴 THIS CHECK EXISTS BECAUSE ITS ABSENCE COST A WHOLE HARDWARE ROUND.
# 2026-08-16: stage-input-mapper died at a keyboard-geometry assertion and
# exited BEFORE writing ${MAPPER_UNIT}. The install reported success overall,
# the desktop came up, and STEAM, QAM, STEAM+X and STEAM+Y were ALL dead, with
# nothing on the machine saying why. lizard_mode back at Y was the only visible
# trace and it was a symptom, not the cause. Finding it took a reinstall and an
# SSH session, on a device that has neither in normal use.
#
# It asks nothing about button MAPPING -- that needs a person pressing buttons.
# It asks the one question that turned out to matter: is the thing there.
#
# ⚠️ GATED ON THE STAGE HAVING RUN AT ALL, like its two siblings above and for
# the same reason: a check that fails on a machine where the stage was never
# selected is a check failing for the wrong reason, and this file already says
# that is as bad as one passing for the wrong reason. The gate is ANY of the
# three artefacts stage-input-mapper writes -- because the failure being hunted
# is precisely a machine that has SOME of them.
if [[ ! -x ${MAPPER_BIN} && ! -e ${MAPPER_UNIT} && ! -d ${OSK_LIB_DIR} ]]; then
  say "note: no part of stage-input-mapper is installed here (no ${MAPPER_BIN}, no ${MAPPER_UNIT}, no ${OSK_LIB_DIR}), so there is no desktop input mapper to verify"
elif [[ ! -x ${MAPPER_BIN} ]]; then
  bad "${OSK_LIB_DIR} or ${MAPPER_UNIT} exists but ${MAPPER_BIN} does not, so stage-input-mapper started and did not finish: Desktop Mode has no controller support at all -- no STEAM button, no QAM menu, no on-screen keyboard, no STEAM+Y. Read /var/log/omarchy-deck-install.json for the stage that failed and why."
elif [[ ! -e ${MAPPER_UNIT} ]]; then
  bad "${MAPPER_BIN} is installed but ${MAPPER_UNIT} is not, so nothing ever starts it: the desktop has no STEAM button, no QAM menu, no on-screen keyboard and no STEAM+Y. stage-input-mapper died between installing the binary and installing the unit -- read /var/log/omarchy-deck-install.json for the stage that failed and why."
elif [[ ! -L ${MAPPER_GLOBAL_WANTS} ]]; then
  bad "${MAPPER_UNIT} exists but ${MAPPER_GLOBAL_WANTS} is not a symlink, so the unit is installed and NOT enabled. It would never start, and nothing else on this machine would say so."
else
  say "ok: input mapper -- ${MAPPER_BIN} is installed and ${MAPPER_UNIT} is enabled for ${MAPPER_WANTED_BY}"
fi

if [[ \$failures -gt 0 ]]; then
  say "\${failures} check(s) failed. This unit is deliberately allowed to fail so the machine says so: systemctl status ${FIRST_BOOT_VERIFY_NAME}"
  exit 1
fi
say "all checks passed"
EOF
}

# Install (or refresh) the verifier and its unit. Idempotent, and safe to call
# from more than one stage: the content is the same either way, and the two
# stages that call it check DIFFERENT halves of it -- each half gates itself on
# its own artefact being present, so a machine that ran only one stage gets only
# that stage's verdict and a 'note:' line for the other.
install_first_boot_verify() {
  local tmp
  assert_ours_or_absent "$FIRST_BOOT_VERIFY_BIN" "another package's verification helper"
  assert_ours_or_absent "$FIRST_BOOT_VERIFY_UNIT" "another package's unit"

  $SUDO install -d -m 0755 -o root -g root "$(dirname "$FIRST_BOOT_VERIFY_BIN")" ||
    fail "could not create $(dirname "$FIRST_BOOT_VERIFY_BIN")"

  tmp=$(mktemp) || fail "mktemp failed"
  render_first_boot_verify >"$tmp" || fail "could not render ${FIRST_BOOT_VERIFY_BIN}"
  $SUDO install -m 0755 -o root -g root "$tmp" "$FIRST_BOOT_VERIFY_BIN" ||
    fail "could not install ${FIRST_BOOT_VERIFY_BIN}"
  rm -f "$tmp"

  tmp=$(mktemp) || fail "mktemp failed"
  cat >"$tmp" <<EOF
${INSTALL_MARKER}
#
# Asks, on the target's OWN kernel, the two questions the installer's chroot
# could only ask of the live ISO's -- see the LATE-BINDING VERIFICATION block
# in ${PROG}.sh, and PROGRESS.md 5.38.
[Unit]
Description=deck-session late-binding verification (brightness, power button)
# udev must have processed the input devices before their tags mean anything,
# and logind must have read its configuration before its behaviour is worth
# asking about. Neither is Requires=: this unit must never be able to stop the
# machine reaching a session.
After=systemd-udevd.service systemd-logind.service
ConditionPathExists=${FIRST_BOOT_VERIFY_BIN}

[Service]
Type=oneshot
ExecStart=${FIRST_BOOT_VERIFY_BIN}
# Bounded. The checks start no services and wait on nothing, so anything past
# this is wedged rather than slow -- and a wedged verification must not hold a
# boot open.
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
EOF
  $SUDO install -D -m 0644 -o root -g root "$tmp" "$FIRST_BOOT_VERIFY_UNIT" ||
    fail "could not install ${FIRST_BOOT_VERIFY_UNIT}"
  rm -f "$tmp"

  # 🔴 THE SYMLINK, NOT 'systemctl enable', WHEN THERE IS NO MANAGER. In chroot
  # mode `systemctl enable` would need to talk to a manager the target does not
  # have; the symlink IS what enable writes, and writing it directly is what
  # deck_wifi.py's first-boot unit does for the same reason. On a running
  # machine the manager is asked properly, so this stays the one code path that
  # is different rather than two that drift.
  if in_chroot; then
    $SUDO install -d -m 0755 -o root -g root "$(dirname "$FIRST_BOOT_VERIFY_WANTS")" ||
      fail "could not create $(dirname "$FIRST_BOOT_VERIFY_WANTS")"
    $SUDO ln -sf "$FIRST_BOOT_VERIFY_UNIT" "$FIRST_BOOT_VERIFY_WANTS" ||
      fail "could not enable ${FIRST_BOOT_VERIFY_NAME}"
    [[ -L $FIRST_BOOT_VERIFY_WANTS ]] ||
      fail "wrote ${FIRST_BOOT_VERIFY_WANTS} but it is not a symlink on re-read, so the verification would never run and nothing would say so"
  else
    $SUDO systemctl enable "$FIRST_BOOT_VERIFY_NAME" >/dev/null 2>&1 ||
      fail "could not enable ${FIRST_BOOT_VERIFY_NAME}"
  fi
  log "installed ${FIRST_BOOT_VERIFY_BIN} and enabled ${FIRST_BOOT_VERIFY_NAME}"
}

# ---------------------------------------------------------------------------

# find_backlight [glob] [class-dir] -- print the panel's brightness node.
#
# 🔴 THIS IS A DISCOVERY, AND IT REPLACED A CONSTANT THAT WAS WRONG ON THE
# OPERATOR'S OWN DECK. Read the BACKLIGHT_GLOB block above for the two
# measurements (bl0 on Neptune, bl1 on stock linux 7.1.8-arch1-3, same panel).
#
# THREE OUTCOMES, ALL LOUD, and they are three because they are three different
# facts about the machine -- collapsing them is how "the check did not run" got
# mistaken for "the check passed":
#
#   exit 0  the node, on stdout. With more than one candidate the FIRST by
#           version sort is taken and every candidate is named on stderr:
#           deterministic beats plausible, and a human is told there was a
#           choice rather than left to discover it.
#   exit 1  ${BACKLIGHT_CLASS_DIR} holds nothing at all -- this machine has no
#           backlight. On a dev box or in QEMU that is ordinary; the caller
#           warns and skips the write check, which is what it did before.
#   exit 2  there ARE backlights and none of them is an amdgpu one. On a Deck
#           that is a real finding (the panel moved to a name this file does not
#           know), so the caller FAILS rather than shrugging.
#
# ⚠️ NOTHING HERE LOGS TO STDOUT except the path. `log` writes to stdout and the
# caller captures it, so an informational line printed with it would be read
# back as part of the node's path.
find_backlight() {
  local pattern=${1:-$BACKLIGHT_GLOB}
  local class_dir=${2:-$BACKLIGHT_CLASS_DIR}
  local -a candidates=()
  local p

  # Deliberately unquoted: this expansion IS the glob. With no match bash leaves
  # the pattern itself, which the -e test then drops -- so nullglob is not
  # needed and this behaves the same whether or not a caller has set it.
  for p in $pattern; do
    [[ -e $p ]] && candidates+=("$p")
  done

  if [[ ${#candidates[@]} -eq 0 ]]; then
    local -a others=()
    if [[ -d $class_dir ]]; then
      for p in "$class_dir"/*; do
        [[ -e $p ]] && others+=("${p##*/}")
      done
    fi
    if [[ ${#others[@]} -gt 0 ]]; then
      printf '[%s] ERROR: %s\n' "$PROG" \
        "no backlight matches ${pattern}, but ${class_dir} does carry: ${others[*]}. The panel is enumerated under a name this script does not know, so Gaming Mode's brightness slider cannot be verified against it. Add the name to BACKLIGHT_GLOB in ${PROG}.sh -- do not hardcode an index, it is DRM enumeration order (amdgpu_bl0 on Neptune, amdgpu_bl1 on stock linux 7.1.8, same Deck)." >&2
      return 2
    fi
    printf '[%s] WARNING: %s\n' "$PROG" \
      "no backlight anywhere under ${class_dir} (it is empty or absent). This machine has no panel backlight -- ordinary off a Deck, and not ordinary on one." >&2
    return 1
  fi

  if [[ ${#candidates[@]} -gt 1 ]]; then
    # sort -V, not plain sort: it orders bl2 before bl10, which byte order does
    # not. The choice is arbitrary in the sense that nothing here can know which
    # of two panels Steam will drive -- so it is made the SAME way every time,
    # and said out loud.
    mapfile -t candidates < <(printf '%s\n' "${candidates[@]}" | sort -V)
    printf '[%s] WARNING: %s\n' "$PROG" \
      "more than one backlight matches ${pattern}: ${candidates[*]}. Taking the first by version sort (${candidates[0]}) so this is deterministic, but nothing here knows which one Steam drives -- check it on the device with 'ls /sys/class/backlight'." >&2
  fi

  printf '%s' "${candidates[0]}"
}

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
  # ⚠️ THE NODE NAME IN THAT FIRST LINE IS THE KERNEL'S, NOT OURS, AND IT MOVES.
  # The same Deck's Steam logged `amdgpu_bl1` on stock linux 7.1.8-arch1-3
  # (2026-08-15). That is precisely why the rendered helper matches a PATTERN
  # over /sys/class/backlight/<one component>/brightness rather than one literal
  # path -- Steam names the node, so the whitelist has to accept whichever name
  # the kernel gave it, while staying anchored to that one subtree. Verified on
  # hardware the same day: the installed helper accepted bl1 and wrote it.
  #
  # The third is why this whitelists rather than writes what it is told: a DP
  # AUX channel is a display-link side band, Steam passes it an EMPTY value,
  # and what that does is not understood here. It is not whitelisted, so this
  # helper refuses it loudly. Steam already tolerates that refusal -- it has
  # been getting 127 for it all along.
  #
  # THE DESTINATION AND THE NODE IT IS VERIFIED AGAINST ARE PARAMETERS -- see
  # "THE VERIFICATION SEAM" above verify_update_stub. Production passes nothing
  # and gets ${PRIV_WRITE_HELPER} plus whatever find_backlight discovers.
  local helper=${1:-$PRIV_WRITE_HELPER}
  local backlight=${2:-}
  assert_ours_or_absent "$helper" "a real SteamOS helper"

  # ⚠️ RESOLVED HERE, NOT AS A ${2:-...} DEFAULT, and the reason is that this
  # discovery can FAIL. `fail` inside a $( ) runs in a subshell, so a default of
  # ${2:-$(find_backlight)} would print the diagnosis and then carry on with an
  # empty value -- a loud message followed by a silent skip, which is worse than
  # either. Resolving it as a statement lets each outcome be answered properly.
  if [[ -z $backlight ]] && in_chroot; then
    # 🔴 THE INSTALLER'S KERNEL IS NOT THE TARGET'S. This exact discovery, run
    # here, is what made the real install's stage-priv-write-helper the one
    # stage that FAILED (PROGRESS.md 5.38 D10): it found
    # /sys/class/backlight/amdgpu_bl1/brightness -- which exists on the live
    # ISO's stock archiso kernel and does NOT exist on the installed Deck, whose
    # Neptune kernel offers only amdgpu_bl0 -- and then could not write it.
    #
    # Note what was NOT wrong, so it does not get re-diagnosed: the helper's
    # whitelist is a pattern and accepts either name (measured and disproved as
    # a cause in 0becd4b), and find_backlight's three outcomes are correct --
    # they were just asked of the wrong machine. Nothing below is a workaround
    # for a flaky check; the check is simply not answerable from in here, and
    # even an answer that had SUCCEEDED would have been about the ISO.
    #
    # So: no discovery, no write, and the question is handed to a unit that asks
    # it on the target's own kernel.
    backlight=$BACKLIGHT_CHROOT_SENTINEL
    defer "the backlight node cannot be discovered at install time -- arch-chroot bind-mounts /sys from the LIVE ISO, whose kernel enumerates the panel differently from the Neptune kernel the target boots (measured: amdgpu_bl1 in the installer, amdgpu_bl0 installed). The helper and its sudoers grant ARE installed, and the helper's whitelist is a pattern that accepts whichever name the kernel gives it. The write path is exercised on the target instead, by ${FIRST_BOOT_VERIFY_NAME}, on every boot. Confirm on the installed machine with: journalctl -t ${FIRST_BOOT_VERIFY_TAG} -b"
  elif [[ -z $backlight ]]; then
    local blrc=0
    backlight=$(find_backlight) || blrc=$?
    case $blrc in
      0) log "backlight: ${backlight} (discovered, not assumed)" ;;
      1)
        # No backlight on this machine at all. Not fatal: the helper is still
        # worth installing, and verify_priv_write_helper's own "not present" arm
        # already says out loud that the write path went unexercised. It is
        # handed a whitelist-SHAPED path that cannot exist, so its non-numeric
        # refusal is still exercised for the right reason rather than being
        # refused earlier as an empty argument.
        backlight="${BACKLIGHT_CLASS_DIR}/deck-session-no-backlight-here/brightness"
        ;;
      *)
        fail "could not identify this machine's panel backlight (see the message above). Refusing to report stage-priv-write-helper as ok with its one write path unverified -- that is exactly how the amdgpu_bl0 constant survived: the check took its 'absent' arm and warned, on the only machine that has a panel."
        ;;
    esac
  fi

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

  local invoking_user; invoking_user=$(desktop_user)
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

  # The deferred half, and it is a VERIFICATION rather than an artefact: both
  # files above are complete and Steam can use them from the target's first
  # second. What is installed here is the thing that ASKS whether they work, on
  # the kernel that will actually be running.
  if in_chroot; then
    install_first_boot_verify
  fi

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
  # No constant default: the node is DISCOVERED (find_backlight) and the stage
  # above resolves it before calling this. A default here would be a second,
  # stale answer to the question the discovery exists to ask -- which is what
  # the removed ${DECK_BACKLIGHT} was.
  local bl=${2:?verify_priv_write_helper needs the backlight node to exercise}

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
  elif [[ $bl == "$BACKLIGHT_CHROOT_SENTINEL" ]]; then
    # NOT the "no panel here" case, and saying so matters: the panel exists, the
    # installer's kernel simply cannot be asked about the target's. The stage
    # has already printed a DEFERRED line naming where the answer comes from
    # instead, so this stays a log rather than a second warning about the same
    # fact.
    log "the write path is not exercised here on purpose -- see the DEFERRED line above; ${FIRST_BOOT_VERIFY_NAME} asks the target's own kernel"
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

# 🔴 SUCCESS IS JOURNALLED TOO, AND THAT IS NOT SYMMETRY FOR ITS OWN SAKE.
# "The brightness slider moved" is not evidence that this helper ran: Steam
# falls back to 'sudo -n tee' and then 'sudo -n chmod a+w' when the helper
# fails, so the panel dims either way and an apparent-motion check has already
# fooled this project once (PROGRESS.md 5.33a). Without this line there is
# nothing in the journal that distinguishes tier 1 from tier 2, and the only
# recorded outcome of a working helper is silence -- which is indistinguishable
# from it never being called. One greppable line settles it:
#   journalctl -t steamos-priv-write -b | grep accepted
note "accepted: wrote '\${value}' to '\${path}'"
EOF
}

# ---------------------------------------------------------------------------
# stage-steam-first-run -- the race, and the two silent minutes after it
# ---------------------------------------------------------------------------
#
# Read the "Steam's first run" constants block above for the measurement this
# whole stage is shaped by. Both halves are drop-ins and neither edits a file
# this project does not own: steam-launcher.service belongs to Valve's
# gamescope package.

# The bounded wait, written to stdout. Same seam as every other render_* here.
#
# 🔴 IT ALWAYS EXITS 0, AND THAT IS THE POINT, NOT AN OVERSIGHT. It is an
# ExecStartPre= on the unit that starts Steam. A non-zero exit there means
# Gaming Mode does not start -- i.e. a Wi-Fi problem would be converted into an
# unusable Deck, which is a far worse defect than the error modal this exists to
# remove. So the outcome is REPORTED (every branch logs, to the journal AND to
# ~/${FIRST_BOOT_LOG_REL}, by name) and never propagated. That is not "silently
# swallowing a failure": the failure is loud, it just is not fatal, because being
# fatal here is wrong.
#
# 🔴 WHY THIS IS NOT `nm-online -s`, WHICH IS WHAT P33 SHIPPED AND WHY IT DID
# NOTHING. From nm-online(1), verbatim:
#
#     -s | --wait-for-startup
#       Wait for NetworkManager startup to complete, rather than waiting for
#       network connectivity specifically. [...] **After startup has completed,
#       nm-online -s will just return immediately, regardless of the current
#       network state.**
#
# NetworkManager reaches "startup complete" early in boot; graphical.target on
# this Deck is at 20.25 s (PROGRESS.md 5.35). So by the time Steam is started the
# condition `-s` tests is long since true, the ExecStartPre= returns 0 in
# milliseconds, and **no wait happens at all** -- which is exactly what the
# 2026-08-16 hardware boot showed: the drop-in was installed and Steam still hit
# "Steam needs to be online to update." `-s` was chosen to avoid burning the
# whole timeout on a networkless Deck, and it does avoid that; it just also
# avoids doing the job.
#
# The shape that keeps both properties is two phases:
#
#   1. `-s -t ${STEAM_WAIT_STARTUP_SECONDS}` -- has NM finished trying? Normally
#      already true, so normally free. Its job is to make phase 2's answer
#      meaningful rather than premature.
#   2. `-x -t ${STEAM_WAIT_SECONDS}` -- wait for ACTUAL connectivity, but `-x`
#      ("Exit immediately if NetworkManager is not running or connecting") is the
#      escape hatch that `-s` was standing in for: a Deck with no network at all
#      is not connecting, so it returns at once instead of burning 20 s at every
#      Gaming Mode start. A Deck that IS connecting gets waited for, which is the
#      one-second race PROGRESS.md 5.35 measured.
#
# ⚠️ `-x` is checked at runtime rather than assumed: if this nm-online does not
# have it, phase 2 says so and Steam starts anyway. Unverified on the target's
# NetworkManager -- see the report for the command that settles it.
render_steam_wait_online() {
  cat <<EOF
#!/usr/bin/env bash
#
# Wait, briefly, for the network before Steam starts.
${INSTALL_MARKER}
#
# WHY: Steam's very first run asks for its own update before NetworkManager has
# connectivity, gets "Steam needs to be online to update.", and then succeeds on
# a retry ONE SECOND LATER (measured -- PROGRESS.md 5.35). The modal is the only
# lasting damage, and it is avoidable by starting one second later.
#
# WHY NOT network-online.target: on a Deck with no network that target is
# reached only by timeout, and here NetworkManager-wait-online.service is masked
# so it is never reached at all. See the constants block in ${PROG}.sh.
set -uo pipefail

# Two destinations, on purpose. The journal is the convenient one; the file is
# the one that still exists on the next boot -- the FIRST boot's journal was not
# retained on this hardware (PROGRESS.md 5.35), which is how P33's outcome here
# came to be unknowable. Failing to open the file is itself only a warning: this
# script's contract is that it exits 0 no matter what.
log_file="\${HOME:-/home/\$(id -un)}/${FIRST_BOOT_LOG_REL}"
mkdir -p "\$(dirname "\$log_file")" 2>/dev/null || true
say() {
  printf 'deck-steam-wait-online: %s\n' "\$1" >&2
  printf '%s deck-steam-wait-online: %s\n' "\$(date -Iseconds)" "\$1" >>"\$log_file" 2>/dev/null || true
}

if [[ ! -x ${NM_ONLINE_BIN} ]]; then
  say "${NM_ONLINE_BIN} is not installed, so connectivity cannot be waited for. Steam starts now; if this machine has no network yet it may show 'Steam needs to be online to update.' once and recover on its own retry."
  exit 0
fi

# Phase 1 -- has NetworkManager finished trying? Normally already true, so
# normally instant. -q: no output of its own; every line here is ours.
startup_rc=0
${NM_ONLINE_BIN} -q -s -t ${STEAM_WAIT_STARTUP_SECONDS} || startup_rc=\$?
[[ \$startup_rc -eq 0 ]] ||
  say "NetworkManager had not finished its startup pass within ${STEAM_WAIT_STARTUP_SECONDS}s (nm-online -s exited \${startup_rc}); waiting for connectivity anyway"

# Phase 2 -- the one that does the work. NOT -s: read the note above
# render_steam_wait_online for why -s is a no-op here by nm-online's own
# documented behaviour.
started=\$(date +%s)
rc=0
${NM_ONLINE_BIN} -q -x -t ${STEAM_WAIT_SECONDS} || rc=\$?
waited=\$(( \$(date +%s) - started ))

if [[ \$rc -eq 0 ]]; then
  say "connectivity confirmed after \${waited}s; starting Steam"
elif [[ \$rc -eq 2 ]]; then
  # 2 is nm-online's "unknown or unspecified error", which is also what it exits
  # with on an option it does not understand. Named rather than lumped in with
  # "offline", because the two want different fixes and this script is the only
  # thing that will ever have seen the difference.
  say "nm-online exited 2 after \${waited}s -- an error, not an answer (an unsupported -x on this NetworkManager would look exactly like this). Starting Steam ANYWAY. Check with: ${NM_ONLINE_BIN} -x -t 1; echo \\\$?"
else
  say "nm-online exited \${rc} after \${waited}s -- this machine is not online. Starting Steam ANYWAY, on purpose: a Deck with no Wi-Fi must still reach Gaming Mode. Steam may show 'Steam needs to be online to update.' once."
fi
exit 0
EOF
}

# The splash. Written to stdout, same seam.
#
# 🔴 THE THREE BOUNDS, AND WHY THERE ARE THREE. A splash that cannot exit is a
# permanently black-with-text panel, which is strictly worse than the two silent
# minutes it replaces. So no single mechanism is trusted to end it:
#
#   1. this script's own deadline (${SPLASH_MAX_SECONDS}s), which it enforces
#      itself and which does not depend on detecting Steam at all;
#   2. RuntimeMaxSec= on ${SPLASH_UNIT_NAME}, which systemd enforces even if
#      this script is wedged in an uninterruptible read;
#   3. PartOf=gamescope-session.target, so ending the session ends this.
#
# The NORMAL exit is none of those -- it is ${SPLASH_STEAM_READY_PROC}
# appearing, which is the Steam client's UI process and cannot be running while
# the updater is still unpacking. ⚠️ That signal is REASONED, not measured: it
# has not been watched on hardware, which is exactly why it is not the only way
# out.
render_steam_splash() {
  cat <<EOF
#!/usr/bin/env bash
#
# "Don't turn me off. Steam is unpacking." -- shown once, on the first boot.
${INSTALL_MARKER}
#
# Read the "Steam's first run" constants block in ${PROG}.sh before changing
# anything here, and the three-bounds note above render_steam_splash.
set -uo pipefail

# Two destinations, on purpose -- see the identical note in the wait helper.
# The 2026-08-16 hardware boot drew nothing and left NOTHING to read: the unit's
# journal was in a boot that was never retained. Whatever this does next time, it
# says so in a file that outlives the boot.
log_file="\${HOME:-/home/\$(id -un)}/${FIRST_BOOT_LOG_REL}"
mkdir -p "\$(dirname "\$log_file")" 2>/dev/null || true
say() {
  printf 'deck-steam-splash: %s\n' "\$1" >&2
  printf '%s deck-steam-splash: %s\n' "\$(date -Iseconds)" "\$1" >>"\$log_file" 2>/dev/null || true
}

marker="\${HOME:-/home/\$(id -un)}/${SPLASH_MARKER_REL}"

# ONCE PER IMPLEMENTATION. Later boots reach Gaming Mode in ~39 s and there is
# nothing to cover, so a splash that ran must not run again -- but a marker left
# by a DIFFERENT build must not silence this one for ever either. That is not
# hypothetical: it is what P33's date-only marker did to this Deck on
# 2026-08-16. Read the SPLASH_ATTEMPT_ID note in ${PROG}.sh.
if [[ -e \$marker ]]; then
  seen=""
  read -r seen _ <"\$marker" 2>/dev/null || true
  if [[ -z \$seen ]]; then
    # Present but empty or unreadable. We cannot tell which implementation ran,
    # so we assume one did: this whole design would rather miss a message than
    # cover a Gaming Mode that is about to draw.
    say "\${marker} exists but could not be read; treating the splash as already shown"
    exit 0
  fi
  if [[ \$seen == ${SPLASH_ATTEMPT_ID} ]]; then
    exit 0
  fi
  say "\${marker} records attempt '\${seen}', not '${SPLASH_ATTEMPT_ID}' -- a different splash from the one that already ran, so this one gets its own single attempt"
fi

# 🔴 WRITTEN BEFORE ANYTHING IS DRAWN. If displaying the splash is what breaks
# this machine, it gets exactly one chance to do so -- not one per boot, for
# ever. The cost of being wrong in this direction is missing the message once;
# the cost of being wrong in the other is a Deck that covers its own screen at
# every start.
mkdir -p "\$(dirname "\$marker")" 2>/dev/null || true
printf '%s %s\n' "${SPLASH_ATTEMPT_ID}" "\$(date -Iseconds)" >"\$marker" 2>/dev/null ||
  say "could not write \${marker}; the splash may be shown again next boot"

[[ -r ${SPLASH_IMAGE} ]] || { say "FAILED: ${SPLASH_IMAGE} is missing; showing nothing. Re-run 'deck-session.sh stage-steam-first-run' on this machine to draw and install it."; exit 0; }
[[ -x ${SPLASH_VIEWER} ]] || { say "FAILED: ${SPLASH_VIEWER} is missing; showing nothing. Install the 'imv' package."; exit 0; }

# Draw INSIDE gamescope, not beside it. gamescope publishes its nested
# compositor's socket as GAMESCOPE_WAYLAND_DISPLAY in the session environment
# file steam-launcher.service also reads; WAYLAND_DISPLAY at this point is the
# OUTER session's, and a client on that one would be behind gamescope's own
# fullscreen surface where nobody would ever see it.
#
# 🔴 AND IF IT IS NOT SET, SAY SO AND STOP. P33 fell through this branch in
# silence, which on the target means /usr/bin/imv (a two-line wrapper: Wayland if
# WAYLAND_DISPLAY is set, X11 otherwise) execs imv-x11 against a DISPLAY that a
# user unit does not have, dies in under a second, and leaves a black panel and
# no explanation. A missing session environment is a real, diagnosable state --
# EnvironmentFile= is prefixed '-' precisely so it cannot fail the unit -- and it
# must be named rather than guessed at from the outside.
if [[ -n \${GAMESCOPE_WAYLAND_DISPLAY:-} ]]; then
  export WAYLAND_DISPLAY=\$GAMESCOPE_WAYLAND_DISPLAY
  say "drawing on gamescope's nested display (WAYLAND_DISPLAY=\${WAYLAND_DISPLAY})"
else
  say "FAILED: GAMESCOPE_WAYLAND_DISPLAY is not set, so there is no compositor to draw on and no way to tell one from the outer session. %t/gamescope-environment was missing or did not contain it. Showing nothing."
  exit 0
fi

# 🔴 THE VIEWER'S OWN OUTPUT GOES IN THE LOG, NOT THE JOURNAL. This is the line
# that says "Failed to connect to Wayland display" or "Unsupported image format"
# -- the single most useful sentence there is when nothing appears -- and P33
# sent it somewhere that did not survive the boot.
${SPLASH_VIEWER} -f -x ${SPLASH_IMAGE} >>"\$log_file" 2>&1 &
viewer=\$!
started=\$(date +%s)
say "showing ${SPLASH_IMAGE} (pid \${viewer}) until ${SPLASH_STEAM_READY_PROC} appears, or ${SPLASH_MAX_SECONDS}s, whichever comes first"

# The deadline is computed once, up front, so nothing inside the loop can push
# it out -- a loop that re-reads its own bound is a loop that can fail to end.
deadline=\$(( \$(date +%s) + ${SPLASH_MAX_SECONDS} ))
reason="deadline"
while [[ \$(date +%s) -lt \$deadline ]]; do
  # The viewer died on its own (no compositor, unsupported image, killed).
  # Nothing left to take down, and no reason to keep counting.
  #
  # 🔴 AND HOW LONG IT LASTED IS THE WHOLE DIAGNOSIS. A viewer that ran for two
  # minutes handed over to Steam; a viewer that was gone in four seconds never
  # drew a frame, and that is the case P33 shipped with no way to tell apart --
  # both were reported as the neutral "the viewer exited". Its own stderr is
  # immediately above this line in the same file.
  if ! kill -0 "\$viewer" 2>/dev/null; then
    alive=\$(( \$(date +%s) - started ))
    if [[ \$alive -lt 5 ]]; then
      reason="FAILED: the viewer exited after \${alive}s without drawing -- read the ${SPLASH_VIEWER} line above this one for why"
    else
      reason="the viewer exited after \${alive}s"
    fi
    viewer=""
    break
  fi
  if pgrep -x ${SPLASH_STEAM_READY_PROC} >/dev/null 2>&1; then
    # A short settle so the message does not vanish a frame before Steam's own
    # first frame lands, which would read as a flicker rather than a handover.
    sleep 2
    reason="${SPLASH_STEAM_READY_PROC} is running"
    break
  fi
  sleep 2
done

if [[ -n \$viewer ]]; then
  kill "\$viewer" 2>/dev/null || true
  # TERM first, then make sure. A viewer that ignores TERM must not become the
  # permanent black-with-text screen this whole design is arranged against.
  for _ in 1 2 3 4 5; do
    kill -0 "\$viewer" 2>/dev/null || break
    sleep 1
  done
  kill -9 "\$viewer" 2>/dev/null || true
fi
say "splash down (\${reason})"
exit 0
EOF
}

# Draw the message. Not a heredoc, because the artefact is a PNG: ImageMagick
# is asked to make it at install time so that nothing has to render text at
# first boot, on the one machine that is already busy.
#
# THE WORDING IS THE REQUIREMENT, not a placeholder. The operator asked for
# "something to tell users like don't turn me off. steam is unpacking." -- in
# those terms, so that is what it says, in those terms.
render_steam_splash_image() {   # render_steam_splash_image <outfile> [magick]
  local out=$1
  local magick=${2:-}
  local font=""

  if [[ -z $magick ]]; then
    if   command -v magick  >/dev/null 2>&1; then magick=magick
    elif command -v convert >/dev/null 2>&1; then magick=convert
    else return 2
    fi
  fi

  # A real font file if fontconfig can name one, and ImageMagick's built-in
  # default otherwise. Not fatal either way: an ugly message is worth far more
  # than no message, and a chroot with a cold fontconfig cache is ordinary.
  if command -v fc-match >/dev/null 2>&1; then
    font=$(fc-match -f '%{file}' 'monospace:bold' 2>/dev/null) || font=""
    [[ -r $font ]] || font=""
  fi

  local -a fontargs=()
  [[ -z $font ]] || fontargs=(-font "$font")

  "$magick" -size "$SPLASH_IMAGE_SIZE" xc:'#0e0e12' \
    "${fontargs[@]+"${fontargs[@]}"}" -gravity center \
    -fill '#f2f2f5' -pointsize 84 -annotate +0-150 "Don't turn me off." \
    -fill '#f2f2f5' -pointsize 64 -annotate +0-40  "Steam is unpacking." \
    -fill '#9a9aa6' -pointsize 34 -annotate +0+70  "It does this once, the first time you start." \
    -fill '#9a9aa6' -pointsize 34 -annotate +0+120 "It takes a couple of minutes." \
    -fill '#9a9aa6' -pointsize 34 -annotate +0+170 "The screen stays dark while it works." \
    "png:$out"
}
# 🔴 'png:' IS LOAD-BEARING AND IS NOT DECORATION. ImageMagick picks its output
# codec from the FILE EXTENSION, and the caller writes to a mktemp path, which
# has none: without the explicit prefix it fails with "no encode delegate for
# this image format `XC'" and produces a zero-byte file. Caught by rendering to
# a suffix-less path, which is what production does -- a test that only ever
# passed a name ending in .png would have shipped this. The stage's own gate
# would then have warned and installed no splash on EVERY install, which is a
# feature silently absent everywhere rather than a loud failure once.

stage_steam_first_run() {
  # --- E2: the bounded wait, and the drop-in that uses it ------------------
  log "installing ${STEAM_WAIT_ONLINE_BIN}"
  assert_ours_or_absent "$STEAM_WAIT_ONLINE_BIN" "another package's helper"
  assert_ours_or_absent "$STEAM_WAIT_DROPIN" "another package's unit drop-in"

  $SUDO install -d -m 0755 -o root -g root "$(dirname "$STEAM_WAIT_ONLINE_BIN")" ||
    fail "could not create $(dirname "$STEAM_WAIT_ONLINE_BIN")"

  local tmp
  tmp=$(mktemp) || fail "mktemp failed"
  render_steam_wait_online >"$tmp" || fail "could not render ${STEAM_WAIT_ONLINE_BIN}"
  $SUDO install -m 0755 -o root -g root "$tmp" "$STEAM_WAIT_ONLINE_BIN" ||
    fail "could not install ${STEAM_WAIT_ONLINE_BIN}"
  rm -f "$tmp"

  tmp=$(mktemp) || fail "mktemp failed"
  cat >"$tmp" <<EOF
${INSTALL_MARKER}
#
# Start Steam after a BOUNDED wait for connectivity -- PROGRESS.md 5.35, and
# the "Steam's first run" constants block in ${PROG}.sh.
#
# A DROP-IN and not an edit: ${STEAM_LAUNCHER_UNIT} belongs to Valve's gamescope
# package, so an edit would be reverted by the next upgrade with nothing to say
# it had been.
[Service]
# No '-' prefix is needed and none is used: ${STEAM_WAIT_ONLINE_BIN} exits 0 on
# every path by construction, which is a stronger guarantee than the prefix and
# is testable. Read the note above render_steam_wait_online.
ExecStartPre=${STEAM_WAIT_ONLINE_BIN}
EOF
  $SUDO install -D -m 0644 -o root -g root "$tmp" "$STEAM_WAIT_DROPIN" ||
    fail "could not install ${STEAM_WAIT_DROPIN}"
  rm -f "$tmp"

  $SUDO grep -qxF -- "ExecStartPre=${STEAM_WAIT_ONLINE_BIN}" "$STEAM_WAIT_DROPIN" ||
    fail "wrote ${STEAM_WAIT_DROPIN} but 'ExecStartPre=${STEAM_WAIT_ONLINE_BIN}' is not in it on re-read, so Steam would still start before the network and show the update error on first run"
  log "verified: ${STEAM_LAUNCHER_UNIT} waits up to ${STEAM_WAIT_STARTUP_SECONDS}s for NetworkManager's startup"
  log "          pass and then up to ${STEAM_WAIT_SECONDS}s for real connectivity, and starts regardless"

  # --- E1: the splash -------------------------------------------------------
  #
  # 🔴 GATED, AND ABSENCE IS NOT A FAILURE. Everything above is installed
  # whatever happens here: the race fix and the splash are independent, and a
  # target without ImageMagick should still stop showing the error modal. A
  # missing splash is the behaviour this Deck has today.
  local out
  out=$(mktemp) || fail "mktemp failed"
  local imrc=0
  render_steam_splash_image "$out" >/dev/null 2>&1 || imrc=$?
  if [[ $imrc -ne 0 || ! -s $out ]]; then
    rm -f "$out"
    warn "could not draw ${SPLASH_IMAGE} (ImageMagick returned ${imrc}, or produced nothing). The 'don't turn me off' splash is NOT installed; the first boot will show ~2 minutes of black panel while Steam updates itself, which is exactly today's behaviour. The connectivity fix above IS installed. Install imagemagick and re-run this stage to add the splash."
    log "stage-steam-first-run: ok (without the splash)"
    return 0
  fi

  $SUDO install -D -m 0644 -o root -g root "$out" "$SPLASH_IMAGE" ||
    fail "could not install ${SPLASH_IMAGE}"
  rm -f "$out"
  log "drew ${SPLASH_IMAGE} (${SPLASH_IMAGE_SIZE}, gamescope's landscape logical output)"

  # 🔴 CHECKED HERE, NOT ONLY AT FIRST BOOT. The splash script checks its viewer
  # too and degrades correctly, but it does that once, in the two minutes nobody
  # is watching, on a machine whose first-boot journal is not retained
  # (PROGRESS.md 5.35). Install time is the moment a missing viewer can still be
  # reported to somebody who can act on it -- and it lands in
  # /var/log/omarchy-deck-install.json, which survives.
  #
  # A warning, not a failure: everything else in this stage is still worth
  # installing, and imv arriving later (it is in Omarchy's own base list) makes
  # the splash work with no further action.
  [[ -x $SPLASH_VIEWER ]] ||
    warn "${SPLASH_VIEWER} is not on this target, so the splash will install but draw nothing on the first boot. It is line 60 of Omarchy's own omarchy-base.packages, so this means that package set did not land. Install 'imv'."

  assert_ours_or_absent "$SPLASH_BIN" "another package's helper"
  assert_ours_or_absent "$SPLASH_UNIT" "another package's unit"

  tmp=$(mktemp) || fail "mktemp failed"
  render_steam_splash >"$tmp" || fail "could not render ${SPLASH_BIN}"
  $SUDO install -D -m 0755 -o root -g root "$tmp" "$SPLASH_BIN" ||
    fail "could not install ${SPLASH_BIN}"
  rm -f "$tmp"

  tmp=$(mktemp) || fail "mktemp failed"
  cat >"$tmp" <<EOF
${INSTALL_MARKER}
#
# Say "don't turn me off" for the ~2 minutes of Steam's first-run self-update,
# during which the panel is otherwise black -- PROGRESS.md 5.35.
[Unit]
Description=Deck first-boot notice while Steam unpacks itself
# PartOf, so ending the session ends this. One of the three independent bounds
# on a splash that must never outlive Steam -- see render_steam_splash.
PartOf=gamescope-session.target
After=gamescope-session.service
# 🔴 NOTHING MAY DEPEND ON THIS. No Requires=, no Before= on steam-launcher: a
# splash that fails must cost a message, never a session. Gaming Mode starting
# is the product; this is a courtesy on top of it.
Before=${STEAM_LAUNCHER_UNIT}

[Service]
Type=simple
ExecStart=${SPLASH_BIN}
# The environment gamescope publishes for the session -- the same file
# ${STEAM_LAUNCHER_UNIT} reads, and where GAMESCOPE_WAYLAND_DISPLAY comes from.
# '-' so a missing file is not a failure: without it the splash finds no
# compositor, says so, and exits.
EnvironmentFile=-%t/gamescope-environment
# BOUND 2 OF 3, and the one systemd enforces regardless of what the script is
# doing. ${SPLASH_MAX_SECONDS}s is the script's own deadline plus slack, so in
# a healthy run this never fires.
RuntimeMaxSec=$((SPLASH_MAX_SECONDS + 30))
# A splash that failed is not a failed boot.
SuccessExitStatus=0 1
Restart=no

[Install]
WantedBy=gamescope-session.target
EOF
  $SUDO install -D -m 0644 -o root -g root "$tmp" "$SPLASH_UNIT" ||
    fail "could not install ${SPLASH_UNIT}"
  rm -f "$tmp"

  $SUDO grep -qE '^RuntimeMaxSec=' "$SPLASH_UNIT" ||
    fail "wrote ${SPLASH_UNIT} without RuntimeMaxSec=. That is the bound systemd enforces when the script cannot enforce its own, and without it a wedged splash is a permanently black-with-text panel -- worse than the defect it replaces."

  # The error is CAPTURED, not discarded. '>/dev/null 2>&1 || fail' throws away
  # the one sentence that says which of a dozen things went wrong -- and this
  # file's own hard constraint is that a failure is never silent. The stdout
  # half is still dropped; it is only the success chatter.
  local enable_err
  enable_err=$($SUDO systemctl --global enable "$SPLASH_UNIT_NAME" 2>&1 >/dev/null) ||
    fail "could not enable ${SPLASH_UNIT_NAME} for all users: ${enable_err:-systemctl said nothing}"

  if in_chroot; then
    # Same readback stage-input-mapper does, for the same reason: --global
    # enable needs no manager, but "exited 0" and "the symlink is there" are
    # different claims and an installed-but-not-enabled unit is silent.
    local wants_link="/etc/systemd/user/gamescope-session.target.wants/${SPLASH_UNIT_NAME}"
    [[ -L $wants_link ]] ||
      fail "'systemctl --global enable' exited 0 but ${wants_link} is not a symlink, so the splash is installed and would never run"
    log "verified: ${wants_link} -> $(readlink -- "$wants_link")"
    # 🔴 THE DEFERRAL NAMES A FILE, NOT A JOURNAL. P33's version said "confirm
    # with journalctl --user -u ... -b" and that advice could not be followed:
    # the installed Deck's persistent journal held only boot 0 (PROGRESS.md
    # 5.35), so the first boot -- the only one this runs on -- was already gone
    # by the time anyone asked. Both scripts now append to a file in the user's
    # home instead, readable in Desktop Mode with no terminal and no SSH.
    defer "whether the splash actually DRAWS cannot be checked at install time -- it needs a running gamescope session, and the target has never booted. It is installed, enabled for gamescope-session.target, and bounded three ways so it cannot outlive Steam. After the first boot, read ~/${FIRST_BOOT_LOG_REL} -- every branch of both first-run scripts writes one timestamped line there, and a line beginning 'FAILED:' names the cause."
  fi

  log "stage-steam-first-run: ok"
  log "NOTE: the splash is shown ONCE per implementation (${SPLASH_ATTEMPT_ID}), on the"
  log "      first Gaming Mode session, and is bounded at ${SPLASH_MAX_SECONDS}s by the script,"
  log "      $((SPLASH_MAX_SECONDS + 30))s by systemd, and by the session itself. Its marker is"
  log "      ~/${SPLASH_MARKER_REL}; remove that file to see it again."
  log "      What it did lands in ~/${FIRST_BOOT_LOG_REL}, which"
  log "      survives the boot the journal did not."
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

  if in_chroot; then
    # There is no manager to reload and none to interrogate: the target has
    # never booted. The drop-in is in the directory systemd reads at start, so
    # the ARTEFACT is complete -- what cannot happen here is asking systemd what
    # it PARSED, which is the check this stage otherwise leans on entirely.
    #
    # So it is re-read as FILE CONTENT, which is strictly weaker (a directive
    # systemd rejects would still be present), and that weakness is stated in
    # the deferral rather than papered over.
    local key
    for key in "StartLimitIntervalSec=0" "TimeoutStopSec=${SDDM_STOP_TIMEOUT}" "RestartSec=3"; do
      $SUDO grep -qxF -- "$key" "$SDDM_UNIT_DROPIN" ||
        fail "wrote ${SDDM_UNIT_DROPIN} but '${key}' is not in it on re-read. Without it a session switch can still leave the Deck with no display manager, which is the failure this stage exists to remove."
    done
    log "verified (file content): the drop-in carries StartLimitIntervalSec=0, TimeoutStopSec=${SDDM_STOP_TIMEOUT} and RestartSec=3"
    defer "systemd's own parse of ${SDDM_UNIT_DROPIN} cannot be checked inside a chroot -- there is no manager to ask, so a directive systemd would reject reads as correct here. It applies at the target's first boot. Confirm on the installed machine with: systemctl show sddm -p StartLimitIntervalUSec -p TimeoutStopUSec -p RestartUSec"
    log "stage-sddm-resilience: ok"
    return 0
  fi

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
  #
  # 🔴 EXCEPT IN A CHROOT, WHERE IT IS THE WRONG /dev ENTIRELY -- found by the
  # PROGRESS.md 5.38 D10 audit, and it is the same defect one subsystem over.
  # arch-chroot bind-mounts /dev, so this opens the LIVE ISO's uinput node, as
  # the INSTALLER's root, and then reports the answer as if it were about the
  # target: root can always open it, so the probe passes for a reason that has
  # nothing to do with the machine being built, and its warning text ("this user
  # has no active local graphical session") describes a situation that cannot
  # arise in here. It writes no conclusion into the target, so the cost is a
  # misleading line in the install record rather than a broken Deck -- but a
  # check that can only pass is not a check, and this file's own rule is that
  # what cannot be answered is said out loud rather than answered wrongly.
  if in_chroot; then
    defer "whether /dev/uinput is openable by the desktop user cannot be tested at install time -- arch-chroot bind-mounts /dev, so the node in here is the LIVE ISO's and this process is root, which can open it whatever the target's ACLs will be. The access comes from a udev uaccess tag granted to whoever holds the active local session, so it can only be answered from inside one. Confirm in the first desktop session with: python3 -c 'import os; os.close(os.open(\"/dev/uinput\", os.O_WRONLY))'"
  else
    python3 -c 'import os; os.close(os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK))' 2>/dev/null ||
      warn "/dev/uinput is not writable by ${USER:-$(id -un)} right now. If this user has no active local graphical session that is expected (uaccess grants it per-session) and the service will still work once logged in. If it persists inside the desktop, the mapper will fail to create its virtual keyboard."
  fi

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
# ⚠️ --grab is LOAD-BEARING, and only safe because of [Install] above.
#
# Without it Hyprland reads the same evdev node we do: `hyprctl devices` lists
# BOTH `deck-input-mapper-virtual-keyboard-1` (ours) and
# `valve-software-steam-controller` (the raw pad) as mice. So with the OSK up,
# the right pad drove the key cursor AND the system pointer at the same time --
# the pointer wandering across whatever sat behind the keyboard. The suppression
# at deck-input-mapper.py's pointer branch (`not mapper.osk_active`) was already
# correct and already working; it just cannot gate a device it does not own.
#
# This never showed before P37 because stage-input-mapper was broken, so the
# unit was never installed and the desktop OSK never ran. The installer's tty
# OSK has no pointer to fight, which is why that backend's comment claims the
# question is "answered" -- answered for tty only.
#
# 🔴 THE SAFETY ARGUMENT IS [Install], NOT THIS LINE. WantedBy= is
# wayland-session@hyprland.desktop.target, so this unit starts for the Hyprland
# session and NOT for gamescope. If anyone ever adds a gamescope target here,
# --grab takes the pad away from Steam and Gaming Mode stops accepting input
# entirely. Verified on hardware 2026-08-16: pointer no longer doubles, the
# keyboard still types, and the pad still drives the pointer with the OSK down.
ExecStart=${MAPPER_BIN} --osk-backend=${MAPPER_OSK_BACKEND} --grab
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
  if in_chroot; then
    defer "whether ${MAPPER_WANTED_BY} exists cannot be answered in a chroot -- it is a TEMPLATE INSTANCE uwsm creates at runtime, so it has no unit file on disk and no manager here has ever seen it. The unit is installed and enabled; if that target never appears, the mapper enables and never starts. Confirm in the first desktop session with: systemctl --user list-units --all | grep wayland-session"
  elif systemctl --user list-units --all --no-legend "$MAPPER_WANTED_BY" 2>/dev/null | grep -q .; then
    log "verified: ${MAPPER_WANTED_BY} exists in this user manager"
  else
    warn "${MAPPER_WANTED_BY} is not known to this user manager. Over SSH with no graphical session that is normal; inside the desktop it means the unit will enable and never start -- check 'systemctl --user list-units --all | grep wayland-session'."
  fi

  $SUDO systemctl --global enable deck-input-mapper.service >/dev/null 2>&1 ||
    fail "could not enable deck-input-mapper.service for all users"

  # 🔴 READ THE ENABLEMENT BACK, and only in chroot mode, because only there is
  # `systemctl --global enable` doing something nobody has watched. It needs no
  # manager -- with --global there is none to need, it just writes a .wants
  # symlink -- but "exited 0" and "the symlink is there" are different claims,
  # and an installed-but-not-enabled unit is silent in exactly the way this
  # project keeps being bitten by. Off a Deck this is left alone: on a running
  # system the next line's claim is already covered by the manager itself.
  if in_chroot; then
    [[ -L $MAPPER_GLOBAL_WANTS ]] ||
      fail "'systemctl --global enable' exited 0 but ${MAPPER_GLOBAL_WANTS} is not a symlink, so the mapper is installed and NOT enabled -- it would never start, and nothing would say so. That is the silent failure this project exists to remove."
    log "verified: ${MAPPER_GLOBAL_WANTS} -> $(readlink -- "$MAPPER_GLOBAL_WANTS")"
  fi

  # 🔴 THE RENDERER CHECK RUNS *AFTER* THE UNIT IS INSTALLED AND ENABLED, AND
  # THAT ORDER IS THE FIX FOR A SHIPPED DEFECT. It used to run before, and on
  # 2026-08-16 it failed for a reason that had nothing to do with the mapper --
  # `fail` exits the stage, so the unit was never written, the mapper never
  # started, and STEAM, QAM, STEAM+X and STEAM+Y all went dead together on
  # hardware. That is upside down: the mapper's own contract, asserted in
  # test/unit/test-osk-install-layout.sh, is that a broken OSK core costs THE
  # OSK AND NOTHING ELSE -- `--list` still works, the keyboard says DISABLED
  # loudly, navigation and the menus survive. A verification of the keyboard
  # must not be able to take out the whole input path; it can only refuse to
  # certify it. The stage still exits non-zero and still lands in
  # /var/log/omarchy-deck-install.json as a failed stage, so nothing is
  # swallowed -- but the Deck it leaves behind has working buttons.
  #
  # The late-binding verifier answers, on the target's own kernel and at every
  # boot, the question this stage cannot: is the mapper actually there? Calling
  # it here as well as from the two stages that already do is deliberate -- it
  # is idempotent and renders identical content, and a Deck whose priv-write and
  # power-button stages both failed must still be told when its input path is
  # missing. Installed BEFORE the renderer check below, so a broken keyboard
  # cannot also cost the machine the check that would have reported it.
  install_first_boot_verify

  # The renderers are not on the --type path, so they need their own check:
  # without them --osk-backend=${MAPPER_OSK_BACKEND} comes up with no keyboard
  # and one warning line. Imported from the INSTALLED directory, which is what
  # the mapper does. deck_osk_wayland imports `gi` inside main(), so importing
  # it here needs no GTK and no display.
  #
  # 🔴 WHAT THIS ASSERTS, AND WHAT IT DELIBERATELY NO LONGER DOES. It asserted a
  # literal `5` rows until 2026-08-16, when KEY_ROWS made each key row two
  # console rows and the true count became 10; the stale number then failed the
  # install. The replacement DERIVED the expected count from the same modules in
  # a SECOND python invocation, and shipped two fresh defects in one line: it
  # named an interpreter variable that does not exist anywhere in this file
  # (`$target_python` -- shellcheck's SC2154 caught it and nothing else did),
  # and it called `.layer()` on what is a property. On hardware the stage then
  # failed on a render that had returned the CORRECT answer, and because the
  # check sat ABOVE the unit install, the mapper was never installed at all:
  # STEAM, QAM, STEAM+X and STEAM+Y all went dead together.
  #
  # So the expectation is gone rather than fixed. Deriving it from the modules
  # under test made it very nearly tautological -- it could only ever restate
  # what the renderer had just computed -- while carrying the full cost of a
  # second interpreter, a second sys.path and a second failure mode. What is
  # left is what this stage can honestly answer about the INSTALLED copy, in ONE
  # process, with no number that can go stale:
  #
  #   * all three modules import from ${OSK_LIB_DIR}
  #   * the renderer draws a positive number of rows
  #   * every row is the same width, and that width is positive
  #
  # The last is the renderer's own documented invariant ("Every row is the same
  # width by construction", deck_osk_tty.width) and it is the shape that breaks
  # on screen: a ragged grid wraps the VT and pushes the keyboard off the
  # bottom. The exact geometry is pinned where it can be pinned without a Deck,
  # in test/unit/test-osk-install-layout.sh.
  local osk_import
  osk_import=$(LC_ALL=C python3 -c "
import sys
sys.path.insert(0, '${OSK_LIB_DIR}')
import deck_osk_layout, deck_osk_tty, deck_osk_wayland
rows = deck_osk_tty.render(deck_osk_layout.OnScreenKeyboard(), deck_osk_layout.Cursors())
widths = {sum(len(text) for text, _ in row) for row in rows}
if not rows:
    raise SystemExit('the renderer drew no rows at all')
if len(widths) != 1 or min(widths) <= 0:
    raise SystemExit('the renderer drew rows of differing or zero width: %s' % sorted(widths))
print('%d rows x %d columns' % (len(rows), widths.pop()))
" 2>&1) ||
    fail "the OSK modules in ${OSK_LIB_DIR} do not import, or do not render a usable grid. The installer's keyboard would be missing or wrapped. ${MAPPER_UNIT} is installed and enabled, so the mapper's buttons still work; the on-screen keyboard is what is in doubt. Output: ${osk_import}"
  log "verified: the installed OSK modules import and render (${osk_import})"

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

  if in_chroot; then
    # 🔴 THE ONE DEFERRAL THAT IS ABOUT SAFETY RATHER THAN CAPABILITY, and it is
    # the reason this branch is not "the node is missing, warn".
    #
    # arch-chroot bind-mounts /sys, so ${node} inside the chroot is the LIVE
    # INSTALLING MACHINE's module parameter -- not the target's. The check below
    # would therefore turn lizard mode OFF and then ON on a Deck that is at that
    # moment running the installer's own deck-input-mapper, and `on` hands input
    # back to the controller firmware, which swallows X, Y, L1, R1, STEAM and
    # QAM. The window is short and the cost is the operator losing buttons in
    # the middle of an install they cannot then drive. Nothing about the TARGET
    # is learned in exchange: the target's hid_steam has never been loaded.
    #
    # What is exercised instead is the helper's argv contract, which needs no
    # node and is what stands between a sudo grant and an arbitrary write.
    local rc=0
    "$helper" >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 2 ]] ||
      fail "'${helper}' with no argument exited ${rc}, not 2. Its strict argv check is the second boundary in front of ${LIZARD_SUDOERS}, and it is not working."
    rc=0
    "$helper" sideways >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 2 ]] ||
      fail "'${helper} sideways' exited ${rc}, not 2. An unrecognised verb must be refused, never guessed at -- both guesses end with a device nobody can drive."
    rc=0
    "$helper" on off >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 2 ]] ||
      fail "'${helper} on off' exited ${rc}, not 2. Extra arguments must be refused: this file sits behind a sudo grant."
    log "verified (chroot): the helper refuses no argument, an unknown verb and extra arguments, all with exit 2"
    defer "lizard mode is NOT toggled at install time. /sys inside arch-chroot is the INSTALLING machine's, so exercising ${node} here would hand input back to the controller firmware while the installer's own mapper is running -- and would prove nothing about the target, whose hid_steam has never been loaded. The helper, its grant, its OnFailure unit and the mapper drop-in are all installed; the invariant takes effect the first time deck-input-mapper.service starts. Confirm on the installed machine with: sudo ${LIZARD_HELPER} off && cat ${LIZARD_SYSFS} && sudo ${LIZARD_HELPER} on"
    return 0
  fi

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
  local invoking_user; invoking_user=$(desktop_user)
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
  if in_chroot; then
    # No user manager exists on a target that has never booted, and the one the
    # INSTALLER is running is not the one that will read this drop-in. Asking it
    # anything would produce an answer about the wrong machine.
    #
    # The drop-in and the unit it belongs to were both written and read back
    # above as files, and the four systemd-parse assertions below are the ones
    # that cannot be made here. They are worth naming individually because they
    # cover a real hole -- a '-' prefix would make a failure silent -- so the
    # deferral says exactly which command re-runs them.
    defer "systemd's parse of ${unit_name} (ExecStopPost=, OnFailure=, ${restore_name}'s LoadState and ExecStart=, and whether either was prefixed with '-') cannot be checked in a chroot: the target has no user manager and the installer's is a different machine's. All four files are installed. Confirm inside the first desktop session with: systemctl --user show ${unit_name} -p ExecStopPost -p OnFailure && systemctl --user show ${restore_name} -p LoadState -p ExecStart"
  elif systemctl --user daemon-reload 2>/dev/null; then
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
  local parsed=""
  if ! in_chroot; then
    parsed=$(systemctl --user show "$unit_name" -p ExecStopPost --value 2>/dev/null) || parsed=""
  fi
  if in_chroot; then
    : # already deferred above, with the exact command that re-runs these four
  elif [[ -z $parsed ]]; then
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
# ✅ FIXED 2026-08-12: this used to predict a live failure in the three
# `$SUDO -u` calls further down stage_desktop_settings, and it did fire on
# real hardware the first time `stage-desktop-settings` ran under `sudo
# ./deck-session.sh` (root from the start, SUDO=""): `-u: command not found`,
# and the idle policy silently never got written. All three now go through
# this function.
run_as_desktop_user() {
  local user=$1; shift

  # 🔴 CHROOT MODE USES setpriv, NOT sudo, AND THAT IS NOT A PREFERENCE.
  # Inside arch-chroot there is no tty, no PAM session, no logind and no audit
  # socket; `sudo -u` there is a dependency on a stack the target has never
  # started, and its failure mode is a write that does not happen. setpriv is
  # util-linux, does no PAM at all, and is a straight setresuid/setresgid --
  # which is exactly and only what this function needs. --clear-groups because
  # inheriting root's supplementary groups into a "run as the desktop user" call
  # would make the privilege drop a half-measure.
  #
  # Every call site passes ABSOLUTE paths, so nothing here depends on $HOME or
  # the cwd changing with the uid.
  if in_chroot; then
    [[ $EUID -eq 0 ]] ||
      fail "chroot mode expects to be root, and this process is EUID ${EUID}; refusing to pretend it can become ${user}"
    command -v setpriv >/dev/null 2>&1 ||
      fail "setpriv (util-linux) is not on the target, so nothing can be written as ${user} from inside the chroot. A root-owned file in their ~/.config would be worse than none."
    local uid gid entry
    entry=$(getent passwd "$user") ||
      fail "no '${user}' in the target's passwd database, so nothing can be written as them"
    uid=$(cut -d: -f3 <<<"$entry")
    gid=$(cut -d: -f4 <<<"$entry")
    [[ $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ ]] ||
      fail "the target's passwd entry for '${user}' has a non-numeric uid/gid ('${uid}'/'${gid}'); refusing to guess who to become"
    local rc=0
    setpriv --reuid="$uid" --regid="$gid" --clear-groups -- "$@" || rc=$?
    return $rc
  fi

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

# splice_marked_lua_block <target> <block file> <begin> <end> <template> <out>
#
# Writes <target> into <out> with the contents of <block file> as the ONE copy
# of the block between <begin> and <end>. Everything outside the markers is
# preserved byte-for-byte, which is the whole point: these are user dotfiles
# that carry the user's own overrides, and on the test Deck input.lua also
# carries the `above_lock = 2` layer rule whose loss makes the lock screen
# unanswerable on a device with no physical keyboard.
#
# An absent <target> is seeded from <template> rather than created empty:
# hyprland.lua `require`s these modules by name and a missing file RAISES,
# taking the whole config down with it.
#
# Not sed/awk: the markers have to be matched as whole lines and an
# unterminated previous block has to be refused rather than half-deleted.
#
# ⚠️ TWO CALLERS -- input.lua's XKB pin and bindings.lua's power-key unbind.
# Keep it generic; anything specific to either block belongs in that block's
# own render_*/install_* pair.
splice_marked_lua_block() {
  local target=$1 block=$2 begin=$3 end=$4 template=$5 out=$6

  python3 - "$target" "$block" "$template" "$begin" "$end" >"$out" <<'PY'
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

  splice_marked_lua_block \
    "$target" "$block" "$OSK_KB_RULE_BEGIN" "$OSK_KB_RULE_END" "$template" "$tmp" || {
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

# The one line that stops the System menu flashing on every power press. Read
# the POWER_MENU_BIND_KEY block above for the measurement it comes from.
#
# `hl.unbind` and NOT a rival `o.bind` of our own: two binds on one key both
# fire, so binding it to something inert would replace one handler with two.
# Unbinding is also the idiom Omarchy documents for taking a default away --
# ~/.config/hypr/bindings.lua ships with `hl.unbind("SUPER + SHIFT + B")` as its
# worked example, and hyprland.lua requires that file AFTER the defaults, which
# is what makes the order work.
#
# ⚠️ IT IS DELIBERATELY TOLERANT OF THE KEY BEING UNBOUND ALREADY. Probed live
# on the Deck 2026-08-16: `hyprctl eval 'hl.unbind([[XF86Massage]])'` on a name
# nothing has ever bound prints `ok` and exits 0. So an Omarchy release that
# drops its own bind does not turn this block into a raise -- which matters,
# because a raise here would discard the user's WHOLE bindings.lua silently.
render_power_menu_unbind_lua() {
  cat <<EOF
${POWER_BIND_RULE_BEGIN}
${INSTALL_MARKER_LUA}
--
-- The power button suspends this Deck (systemd-logind, see
-- ${POWER_LOGIND_DROPIN}). Omarchy also binds it to its System menu, in
-- default/hypr/bindings/utilities.lua:
--
--   o.bind("${POWER_MENU_BIND_KEY}", "Power menu", "omarchy-menu toggle system",
--          { locked = true })
--
-- Two handlers for one button. Worse, the compositor sees ONE physical press
-- as TWO ${POWER_MENU_BIND_KEY} events -- the real key on platform-i8042-serio-0 and an
-- ACPI notify on acpi-LNXPWRBN:00 ~165 ms later -- because libinput opens every
-- device on the seat and does not care about the 'power-switch' udev tag that
-- ${POWER_UDEV_RULE} edits. So 'toggle' runs twice and the System menu
-- opens and closes: measured at 114 ms of visible menu per press, on this
-- hardware, immediately before the screen sleeps.
--
-- Removing the bind is the fix. It does not touch suspend, which is logind's.
hl.unbind("${POWER_MENU_BIND_KEY}")

-- Deliberately the LAST line: its absence in a live compositor means the block
-- did not run to the end, which is the only symptom Hyprland gives for a file
-- it discarded. deck-session.sh asserts it with
--   hyprctl eval 'if ${POWER_BIND_SENTINEL} ~= true then error("...") end'
-- because eval reports Lua errors and cannot report values.
${POWER_BIND_SENTINEL} = true
${POWER_BIND_RULE_END}
EOF
}

# install_power_menu_unbind <desktop-user> <path to bindings.lua> [template]
#
# Same splice, same luac gate, same reasoning as install_osk_kb_layout_rule --
# and the file it edits is the one Omarchy hands the user for exactly this, so
# everything outside our markers is theirs and survives byte-for-byte.
install_power_menu_unbind() {
  local user=$1
  local target=$2
  local template=${3:-$HYPR_BINDINGS_LUA_TEMPLATE}

  local block tmp
  block=$(mktemp) || fail "mktemp failed"
  render_power_menu_unbind_lua >"$block" ||
    fail "could not render the power-button unbind"

  tmp=$(mktemp) || { rm -f "$block"; fail "mktemp failed"; }

  splice_marked_lua_block \
    "$target" "$block" "$POWER_BIND_RULE_BEGIN" "$POWER_BIND_RULE_END" "$template" "$tmp" || {
    rm -f "$block" "$tmp"
    fail "could not splice the power-button unbind into ${target}"
  }
  rm -f "$block"

  # A Lua syntax error is silent: Hyprland discards the file and falls back,
  # with 'hyprctl configerrors' still clean. Here that would take every personal
  # keybinding in the user's bindings.lua down with it.
  if command -v luac >/dev/null 2>&1; then
    local luaerr
    if ! luaerr=$(luac -p "$tmp" 2>&1); then
      rm -f "$tmp"
      fail "the patched ${target} is not valid Lua: ${luaerr}. Refusing to install it -- Hyprland discards a config it cannot parse WITHOUT logging a reason, so this would silently drop every binding in that file."
    fi
    log "verified: the patched ${target} parses as Lua"
  else
    warn "luac not found, so the patched ${target} was NOT syntax-checked. A Lua syntax error there is silent: Hyprland discards the whole file, which would drop the user's own bindings as well as this one. Install the 'lua' package to enable this check."
  fi

  chmod 0644 "$tmp" || { rm -f "$tmp"; fail "could not make the staged ${target} readable by ${user}"; }
  log "installing the power-button unbind: ${target}"
  run_as_desktop_user "$user" install -D -m 0644 "$tmp" "$target" || {
    rm -f "$tmp"
    fail "could not install ${target} as ${user}"
  }
  rm -f "$tmp"

  grep -qxF -- "$POWER_BIND_RULE_END" "$target" ||
    fail "${target} does not carry '${POWER_BIND_RULE_END}' after being installed. The write reported success and the file does not have the unbind in it."
}

# verify_power_menu_unbind <desktop-user> <uid> [runtime-dir]
#
# The runtime directory is a PARAMETER for the reason spelled out above
# verify_osk_kb_layout: baked in, a unit-suite run on a developer's own Hyprland
# box would reload THEIR desktop.
#
# Two questions, and the second is the one that matters to the operator:
#   - did our block execute?      -> the sentinel, asserted, never read back
#   - is the key bound to anything now? -> `hyprctl -j binds`, which is the
#     observable the flash comes from. A sentinel that is set while the bind is
#     still there would mean `hl.unbind` had stopped working, and the menu would
#     still flash.
verify_power_menu_unbind() {
  local user=$1 uid=$2
  local runtime_dir=${3:-/run/user/${uid}}

  local manual="hyprctl -j binds"

  local sig="" d
  for d in "$runtime_dir"/hypr/*/; do
    [[ -S "${d}.socket.sock" ]] || continue
    d=${d%/}
    sig=${d##*/}
  done

  if [[ -z $sig ]]; then
    warn "no live Hyprland instance under ${runtime_dir}/hypr, so the power-button unbind is installed but has NOT been observed working. It applies to ${user}'s next session. Check it there with: ${manual} -- no bind may name '${POWER_MENU_BIND_KEY}'."
    return 0
  fi

  command -v hyprctl >/dev/null 2>&1 ||
    fail "a Hyprland instance is live (${sig}) but hyprctl is not on PATH, so the unbind this stage just installed cannot be checked at all. Refusing to report success for a menu nobody has seen stay shut."

  # ⚠️ HYPRLAND_INSTANCE_SIGNATURE is not optional (R-46): without it hyprctl
  # exits before doing anything, and a check that never ran reads as a pass.
  local -a hy=(env "XDG_RUNTIME_DIR=${runtime_dir}" "HYPRLAND_INSTANCE_SIGNATURE=${sig}" hyprctl)

  "${hy[@]}" reload config-only >/dev/null 2>&1 ||
    fail "'hyprctl reload config-only' failed against instance ${sig}. The unbind is written to disk but the running session has not picked it up, and this stage will not call that success."

  local evalout
  if ! evalout=$("${hy[@]}" eval "if ${POWER_BIND_SENTINEL} ~= true then error('${POWER_BIND_SENTINEL} is not set') end" 2>&1); then
    fail "the running compositor does not have ${POWER_BIND_SENTINEL} set (${evalout}). That global is the LAST line of the block this stage installed, so its absence means the block did not run to the end -- most likely Hyprland discarded ${HYPR_BINDINGS_LUA_REL} over a Lua error elsewhere in it. The System menu still flashes on every power press."
  fi
  log "verified: ${POWER_BIND_SENTINEL} is set in the live compositor, so the whole unbind block executed"

  local binds verdict
  binds=$("${hy[@]}" -j binds 2>&1) ||
    fail "could not read 'hyprctl -j binds' from instance ${sig}: ${binds}"

  verdict=$(python3 - "$POWER_MENU_BIND_KEY" "$binds" <<'PY'
import json, sys

key, binds_json = sys.argv[1:3]
try:
    binds = json.loads(binds_json)
except ValueError as exc:
    sys.exit("hyprctl did not return JSON: %s" % exc)

# An empty bind list is not "our key is gone" -- it is a list worth drawing no
# conclusion from, so say so rather than report success.
if not binds:
    sys.exit("hyprctl reported no keybindings at all")

still = [b for b in binds if b.get("key") == key]
print("bound %d" % len(still) if still else "ok")
PY
) || fail "could not read the keybinding list back out of hyprctl"

  case $verdict in
    ok)
      log "verified: nothing in the live compositor binds ${POWER_MENU_BIND_KEY}, so a press reaches systemd-logind and nothing else"
      ;;
    bound\ *)
      fail "${verdict#bound } keybinding(s) still name ${POWER_MENU_BIND_KEY} in the live compositor. Our block ran (the sentinel is set) and the key is still bound, so either hl.unbind no longer removes it or something re-binds it after ${HYPR_BINDINGS_LUA_REL}. The System menu will still flash before the Deck sleeps. Compare: ${manual}"
      ;;
    *)
      fail "unexpected verdict '${verdict}' from the keybinding check; refusing to guess whether the menu still opens"
      ;;
  esac
}

# The inert override that replaces omarchy-sleep-lock.service. Written to
# stdout so the unit suite can check its shape with no Deck, no root and no VM
# -- the same move render_update_stub and render_power_udev_rule made, and the
# reason the ISO installer's own half can assert byte agreement with this one
# instead of two hand-written copies drifting apart.
#
# Read the SLEEP_LOCK_* constants above first. Every line below is load-bearing
# and the WHY for each is there:
#   * no ExecStart of upstream's -> nothing ever inhibits sleep or calls the lock
#   * Type=oneshot + RemainAfterExit -> `enable --now` starts it, it exits 0,
#     and it stays "active" rather than looking like a crashed service
#   * [Install] WantedBy matching upstream -> `enable` writes the same .wants
#     symlink upstream's first-run step expects, and exits 0
render_sleep_lock_override() {
  cat <<EOF
${INSTALL_MARKER}
#
# INERT OVERRIDE of Omarchy's ${SLEEP_LOCK_UNIT}, installed by ${PROG}.sh.
#
# This Steam Deck RESUMES FROM SLEEP UNLOCKED, on purpose: it has no keyboard,
# and Omarchy's shell exposes no unlock IPC, so a lock screen on resume is not
# "type your password", it is a lost session. See docs/PROGRESS.md §5.24 and
# docs/findings/T13-power-button-and-sleep.md §5.3.
#
# systemd resolves a user unit by name through ~/.config/systemd/user, then
# /etc/systemd/user, then /usr/lib/systemd/user, first fragment wins. This file
# therefore replaces upstream's, whose ExecStart runs
# omarchy-system-sleep-monitor -- a systemd-inhibit on logind's PrepareForSleep
# that calls omarchy-system-sleep-lock. That path is not reachable while this
# file is here.
#
# It is a real unit rather than a mask (-> /dev/null) because a mask makes
# \`systemctl --user enable --now\` fail, which killed upstream's first-run step
# and made the first-run notifications replay on every single login.
#
# TO RESTORE UPSTREAM'S BEHAVIOUR: delete this file, then
#   systemctl --user daemon-reload && systemctl --user restart ${SLEEP_LOCK_UNIT}
# The Deck will lock on suspend again. Read §5.24 before you do.
[Unit]
Description=Omarchy sleep lock (neutralised: this Deck resumes unlocked)
Documentation=file://${SLEEP_LOCK_GLOBAL_OVERRIDE}

[Service]
Type=oneshot
ExecStart=${SLEEP_LOCK_INERT_EXEC}
RemainAfterExit=yes

[Install]
WantedBy=${SLEEP_LOCK_WANTED_BY}
EOF
}

# Install that override for every user of this image. Read the SLEEP_LOCK_*
# constants above first -- the WHY is there, and it is a security decision, not
# a tidy-up.
#
# THE DESTINATION IS A PARAMETER -- see "THE VERIFICATION SEAM" above
# verify_update_stub. Production passes nothing and gets
# ${SLEEP_LOCK_GLOBAL_OVERRIDE}; the unit suite passes a path under its fake
# root, because the read-back below reads the file DIRECTLY rather than through
# $SUDO and would otherwise be inspecting the developer's real /etc.
install_sleep_lock_override() {
  local dest=${1:-$SLEEP_LOCK_GLOBAL_OVERRIDE}

  # 🔴 A MASK AT THIS PATH IS OUR OWN PREVIOUS OUTPUT, and it is the defect
  # being fixed -- so this one shape is REPLACED rather than refused. Every
  # other foreign shape still stops the run. Without this branch the fix would
  # never reach a Deck installed by an older ISO: assert_ours_or_absent cannot
  # read a marker out of /dev/null, and the stage would fail on every re-run.
  if [[ -L $dest ]]; then
    local existing
    existing=$(readlink -- "$dest") ||
      fail "${dest} is a symlink that cannot be read; refusing to guess what it points at"
    if [[ $existing == /dev/null ]]; then
      log "${dest} is an old-style MASK of ${SLEEP_LOCK_UNIT} (ours, from a previous release). Replacing it with the inert override: a mask makes 'systemctl --user enable --now' fail, which replays Omarchy's first-run notifications on every login."
      $SUDO rm -f -- "$dest" ||
        fail "could not remove the old mask at ${dest}"
    else
      fail "${dest} is a symlink to '${existing}', which is neither our old mask nor a unit file. Something else owns this path -- an alias or a drop-in. Refusing to replace it; remove it by hand if it is stale, then re-run."
    fi
  fi

  # Idempotent, and it has to be: this stage is re-run by the SSH iterate loop
  # and again by every image build. `install` alone would be idempotent too, but
  # it would also silently replace whatever else is there -- so look first.
  assert_ours_or_absent "$dest" "another package's ${SLEEP_LOCK_UNIT} override"

  log "installing the inert ${SLEEP_LOCK_UNIT} override for every user: ${dest}"
  $SUDO install -d -m 0755 -o root -g root "$(dirname "$dest")" ||
    fail "could not create $(dirname "$dest")"

  local tmp
  tmp=$(mktemp) || fail "mktemp failed"
  render_sleep_lock_override >"$tmp" ||
    { rm -f "$tmp"; fail "could not render the ${SLEEP_LOCK_UNIT} override"; }
  $SUDO install -m 0644 -o root -g root "$tmp" "$dest" ||
    { rm -f "$tmp"; fail "could not install ${dest}"; }
  rm -f "$tmp"

  # Read it back rather than trusting the write, and check the three properties
  # that matter -- separately, because each has its own failure mode and each
  # would otherwise fail silently:
  #
  #   1. It is a regular file, not a symlink. A `-> /dev/null` mask here is the
  #      exact regression this fix exists to prevent: it stops the lock AND
  #      breaks upstream's first-run enable, so the notifications replay.
  #   2. Its ExecStart is ours. Anything else -- most of all upstream's
  #      omarchy-system-sleep-monitor -- means the file that landed is not the
  #      inert one and the Deck locks on resume.
  #   3. It has an [Install] section. Without one `systemctl --user enable`
  #      fails just as loudly as the mask did, which is the same defect again.
  [[ ! -L $dest ]] ||
    fail "${dest} is a symlink after installing it. A symlink here is either a mask (which breaks 'systemctl --user enable --now' and replays Omarchy's first-run notifications every login) or someone else's unit -- neither is the inert override this installs"
  [[ -f $dest ]] ||
    fail "${dest} is not a regular file after installing it, so nothing overrides ${SLEEP_LOCK_UNIT} and the Deck would lock on resume with no way to unlock it"
  grep -qx "ExecStart=${SLEEP_LOCK_INERT_EXEC}" "$dest" ||
    fail "${dest} does not carry 'ExecStart=${SLEEP_LOCK_INERT_EXEC}'. Whatever is there is not the inert override, so the sleep lock may still run and the Deck would resume to a password prompt it has no keyboard for."
  # DIRECTIVES only. The file's own header explains what it replaced, and that
  # explanation names upstream's monitor -- checking the whole file would refuse
  # our own documentation.
  ! grep -v '^#' "$dest" | grep -q 'omarchy-system-sleep-monitor' ||
    fail "${dest} still names omarchy-system-sleep-monitor in a directive -- that is upstream's lock-on-suspend path, not an inert override"
  grep -qx '\[Install\]' "$dest" ||
    fail "${dest} has no [Install] section, so 'systemctl --user enable' would refuse it and upstream's first-run step would fail exactly as the old mask made it fail"
  grep -qx "WantedBy=${SLEEP_LOCK_WANTED_BY}" "$dest" ||
    fail "${dest} does not say 'WantedBy=${SLEEP_LOCK_WANTED_BY}', so 'systemctl --user enable' would write a .wants symlink somewhere upstream's first-run step does not expect"
  log "verified: ${dest} is a real, inert, enable-able unit (ExecStart=${SLEEP_LOCK_INERT_EXEC}, WantedBy=${SLEEP_LOCK_WANTED_BY}), so ${SLEEP_LOCK_UNIT} starts and does nothing for every user, including ones this image has not created yet"
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
  # make the unit suite reload the desktop of whoever ran it; the sleep-lock
  # override is read back at an absolute path, which off-Deck is the developer's
  # own /etc. Production passes nothing. See "THE VERIFICATION SEAM" above
  # verify_update_stub.
  local hypr_runtime=${1:-}
  local sleep_lock_override=${2:-}

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
  local invoking_user; invoking_user=$(desktop_user)
  [[ -n $invoking_user && $invoking_user != root ]] ||
    fail "could not determine the desktop user (got '${invoking_user}'); run this as that user via sudo, not as root directly"
  local home
  home=$(getent passwd "$invoking_user" | cut -d: -f6) ||
    fail "could not resolve ${invoking_user}'s home directory"
  [[ -n $home ]] || fail "empty home directory for ${invoking_user}"
  local shell_json="${home}/${OMARCHY_SHELL_JSON_REL}"

  # --- 3a. the SUSPEND producer, neutered at image level ---
  #
  # First of the two, because it is the one whose failure is unrecoverable: an
  # idle lock takes five minutes to arrive and the power button takes one press.
  install_sleep_lock_override ${sleep_lock_override:+"$sleep_lock_override"}

  # A user unit file SHADOWS the /etc one -- ~/.config/systemd/user comes first
  # in systemd's search path. Warn only when it actually DISAGREES, for the same
  # reason the dconf check below does: a warning that fires on a file which
  # agrees with us teaches the operator to ignore the message.
  #
  # 🔴 A PER-USER MASK IS NO LONGER "REDUNDANT, NOT WRONG". This block used to
  # say exactly that, and it was true while /etc carried a mask too. It is not
  # true now: a `-> /dev/null` here shadows the inert override just installed
  # and makes `systemctl --user enable --now` fail again, which is what replays
  # Omarchy's first-run notifications on every login (§5.24). The operator's
  # Deck carried one, hand-made, until it was reinstalled.
  local user_unit="${home}/${SLEEP_LOCK_USER_UNIT_REL}"
  if [[ -e $user_unit || -L $user_unit ]]; then
    if [[ -L $user_unit && $(readlink -- "$user_unit") == /dev/null ]]; then
      warn "${user_unit} is a per-user MASK of ${SLEEP_LOCK_UNIT}. ~/.config/systemd/user comes BEFORE /etc/systemd/user in systemd's search path, so it shadows the inert override this stage just installed. It stops the lock, but it also makes 'systemctl --user enable --now' refuse the unit, which fails Omarchy's first-run step and REPLAYS the first-run notifications on every login. Remove it:  rm ${user_unit} && systemctl --user daemon-reload"
    elif [[ -f $user_unit ]] && grep -qF -- "$INSTALL_MARKER_TEXT" "$user_unit" 2>/dev/null; then
      log "${invoking_user} also has a copy of our override at ${user_unit}; it agrees with ours and is now redundant, not wrong"
    else
      warn "${user_unit} exists and is not ours. ~/.config/systemd/user comes BEFORE /etc/systemd/user in systemd's search path, so this file shadows the override this stage just installed and ${SLEEP_LOCK_UNIT} may still lock the Deck on resume. Inspect it; remove it if it is stale."
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
    run_as_desktop_user "$invoking_user" install -D -m 0644 "$OMARCHY_SHELL_JSON_DEFAULTS" "$shell_json" ||
      fail "could not seed ${shell_json}"
  fi

  log "setting Omarchy idle policy: screensaver=${IDLE_SCREENSAVER_SECONDS}s lock=${IDLE_LOCK_SECONDS}s"
  run_as_desktop_user "$invoking_user" python3 - "$shell_json" "$IDLE_SCREENSAVER_SECONDS" "$IDLE_LOCK_SECONDS" <<'PY' ||
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
  check=$(run_as_desktop_user "$invoking_user" python3 - "$shell_json" <<'PY'
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
  #
  # ⚠️ ITS OWN STAGE SINCE 2026-08-15, and called from here so a full run is
  # unchanged. The extraction is not tidying: the ISO's installer bakes the
  # session layer stage by stage, and the other three halves of THIS stage are
  # already written at install time by configure_deck's session_dconf,
  # idle_policy and mask_sleep_lock steps -- so the baked list needs this half
  # WITHOUT them. See BAKE_STAGES.
  stage_osk_kb_layout ${hypr_runtime:+"$hypr_runtime"}

  log "stage-desktop-settings: ok"
  log "NOTE: Omarchy re-reads shell.json live (FileView watchChanges), but the"
  log "      dconf defaults apply to sessions started AFTER this, and any"
  log "      user-level value keeps shadowing them until it is reset."
  log "NOTE: the keyboard layout rule is PER DEVICE. Physical keyboards and the"
  log "      rest of the desktop keep the session layout; only"
  log "      '${OSK_HYPR_DEVICE}' is pinned to '${OSK_KB_LAYOUT}'."
  log "NOTE: ${SLEEP_LOCK_UNIT} is overridden by an inert unit of ours, so this"
  log "      Deck RESUMES FROM SLEEP UNLOCKED, deliberately -- it has no keyboard"
  log "      and no unlock IPC. A lock the user asks for (System menu,"
  log "      SUPER+CTRL+L) still works. It is a real unit rather than a mask so"
  log "      that Omarchy's first-run 'systemctl --user enable --now' still"
  log "      succeeds; a mask fails it and replays the first-run notifications"
  log "      on every login. An instance already running in this session keeps"
  log "      running; the override applies from the next graphical session on."
}

# ---------------------------------------------------------------------------

# stage-osk-kb-layout -- pin OUR virtual keyboard, and only it, to `us`.
#
# WHY IT IS A STAGE OF ITS OWN. It was the fourth and last part of
# stage-desktop-settings, and it is the only part of that stage the ISO's
# installer can run: configure_deck's session_dconf, idle_policy and
# mask_sleep_lock steps already write the other three at install time, from
# these same constants, and the dconf site file they write carries no marker of
# ours -- so a baked stage-desktop-settings would hit assert_ours_or_absent and
# refuse, correctly. Nothing else anywhere writes this rule: deck_input.py
# splices the SAME input.lua with different markers and its docstring is
# explicit that kb_layout is deck-session.sh's to own.
#
# NOT in INSTALL_STAGES, because stage-desktop-settings calls it and running it
# twice in one pass would be pointless work with a second chance to fail. It IS
# in BAKE_STAGES.
#
# THE COMPOSITOR RUNTIME DIRECTORY IS A SEAM ($1), for the reason spelled out
# above verify_osk_kb_layout: with it baked in, a unit-suite run on a developer's
# own Hyprland box would reload THEIR desktop.
stage_osk_kb_layout() {
  local hypr_runtime=${1:-}

  local invoking_user; invoking_user=$(desktop_user)
  [[ -n $invoking_user && $invoking_user != root ]] ||
    fail "could not determine the desktop user (got '${invoking_user}'); run this as that user via sudo, not as root directly"

  local home
  home=$(getent passwd "$invoking_user" | cut -d: -f6) ||
    fail "could not resolve ${invoking_user}'s home directory"
  [[ -n $home ]] || fail "empty home directory for ${invoking_user}"

  local uid
  uid=$(getent passwd "$invoking_user" | cut -d: -f3) ||
    fail "could not resolve ${invoking_user}'s uid"
  [[ $uid =~ ^[0-9]+$ ]] ||
    fail "getent reported a non-numeric uid ('${uid}') for ${invoking_user}; the compositor's runtime directory cannot be located from it"

  # 🔴 In a chroot the seam is pointed somewhere that cannot exist, ON PURPOSE.
  # arch-chroot bind-mounts /run, so /run/user/${uid} in here is the INSTALLER's
  # -- and verify_osk_kb_layout's live arm runs `hyprctl reload`. Left alone, an
  # install would reload the compositor the operator is looking at. Its "no live
  # Hyprland" arm is the honest report for a machine that has never booted, and
  # it already names the command to check with later.
  if in_chroot; then
    hypr_runtime=$CHROOT_NO_HYPR_RUNTIME
    defer "the keyboard-layout rule cannot be observed taking effect at install time -- it needs a live Hyprland, and the target has never booted. The rule is written to ${home}/${HYPR_INPUT_LUA_REL} and applies to ${invoking_user}'s first session. Confirm there with: hyprctl -j devices  -- '${OSK_HYPR_DEVICE}' must read layout '${OSK_KB_LAYOUT}' while every other keyboard keeps the session layout"
  fi

  install_osk_kb_layout_rule "$invoking_user" "${home}/${HYPR_INPUT_LUA_REL}"
  verify_osk_kb_layout "$invoking_user" "$uid" ${hypr_runtime:+"$hypr_runtime"}

  log "stage-osk-kb-layout: ok"
  log "NOTE: the rule is PER DEVICE. Physical keyboards and the rest of the"
  log "      desktop keep the session layout; only '${OSK_HYPR_DEVICE}' is"
  log "      pinned to '${OSK_KB_LAYOUT}'."
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
NoDisplay=true
EOF
}

stage_return_icon() {
  # A .desktop entry is the shell-agnostic half of "return to Gaming Mode":
  # every launcher on every shell reads /usr/share/applications, so this works
  # identically on Omarchy 3.x (waybar-era) and on 4.0's Quickshell rewrite.
  #
  # 🔴 NoDisplay=true SINCE 2026-08-16, AND IT IS THE POINT OF THIS ENTRY NOW.
  # Operator, from hardware: "Gaming Mode" was listed in the Apps menu, between
  # Foot and Google Contacts, because the apps provider enumerates
  # /usr/share/applications -- so this file and stage-menu-row's row were TWO
  # visible ways back, in two different menus. Moving the menu row to
  # system.gaming did not touch this one; they are separate artefacts and the
  # first fix missed it.
  #
  # The trade, stated plainly rather than discovered later: NoDisplay removes
  # this from EVERY launcher list, including search, so it is no longer a
  # human-discoverable fallback if stage-menu-row fails. It remains installed
  # and exec'able by desktop-id, and the ${RETURN_ACTION} it names is still the
  # one shared constant both halves agree on -- so this stays the place the
  # action is defined, not a second UI.
  #
  # If the menu row ever stops being the primary route, drop NoDisplay rather
  # than adding a third way back.
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
"${MENU_ROW_ID}": {"icon": "${MENU_ROW_ICON}", "label": "${RETURN_LABEL}", "action": "${MENU_ROW_ACTION}", "description": "${RETURN_DESCRIPTION}"},
${MENU_ROW_END}
EOF
}

# The two halves of "return to Gaming Mode" must run the SAME command.
#
# Compared from what is rendered, not from the constants, because a constant
# both sides agree on proves nothing if one of the heredocs stopped using it.
# This is cheap and it runs before anything is written.
#
# ⚠️ THE MENU ROW IS NO LONGER BYTE-IDENTICAL TO Exec=, and the checks below
# say exactly how far they are allowed to differ. Since 2026-08-16 the row
# wraps ${RETURN_ACTION} in Omarchy's own OSD sequence (see MENU_ROW_ACTION),
# which a .desktop Exec= could not carry anyway: Exec= is argv per the Desktop
# Entry spec, not a shell line, so `a & b || c` there would be handed to the
# switch as arguments rather than run. The row goes through `bash -lc` and can.
#
# So: Exec= must still be EXACTLY the shared command, and the row must BEGIN
# with ${MENU_ROW_SWITCH} -- the nohup'd, lead-in'd copy of that same command.
# Anchoring at the START is the point rather than an implementation detail: it
# is what proves the switch is scheduled BEFORE the OSD can fail, which is the
# property that keeps a cosmetic notice from being able to strand the user in
# the desktop. Anchoring at the end would permit exactly the inversion that
# would break it.
# The row's action AS QUICKSHELL WILL SEE IT: render_menu_row_block put through
# a JSON parse, so every escape in it is decoded exactly once.
#
# 🔴 THIS EXISTS SO THE ICON ESCAPE CANNOT BREAK THE COMPARISONS. $MENU_ROW_ACTION
# carries ${MENU_ROW_ICON} as the ASCII text 󰊗 -- deliberately, per
# MENU_ROW_ICON's own note -- while anything read back out of a written file has
# been through json.loads and holds the single character U+F0297 instead. The two
# are the same action and are NOT the same bytes, so comparing a decoded readback
# against the raw constant would fail on a correct install. Both sides are put
# through this one function instead, and neither caller decodes anything itself.
rendered_menu_action() {
  render_menu_row_block | python3 -c '
import json, re, sys
raw = sys.stdin.read()
raw = re.sub(r"^\s*//[^\n]*(\n|$)", "", raw, flags=re.M)
raw = re.sub(r",(\s*$)", r"\1", raw)
try:
    row = json.loads("{" + raw + "}")
except ValueError as exc:
    sys.exit("the rendered menu row is not valid JSON: %s" % exc)
sys.stdout.write(list(row.values())[0].get("action", ""))
'
}

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

  from_menu=$(rendered_menu_action) ||
    fail "could not read the action back out of the rendered menu row block"

  [[ $from_desktop == "$RETURN_ACTION" ]] ||
    fail "${RETURN_DESKTOP_FILE}'s Exec= renders as '${from_desktop}' but the shared constant is '${RETURN_ACTION}'. The two ways back to Gaming Mode have drifted; whichever is wrong does nothing at all and reports no error."
  # The scheduled copy must itself still be the shared command -- checked here
  # so a typo in MENU_ROW_SWITCH cannot make the two checks below vacuous.
  [[ $MENU_ROW_SWITCH == *"$RETURN_ACTION"* ]] ||
    fail "MENU_ROW_SWITCH is '${MENU_ROW_SWITCH}', which does not contain the shared command '${RETURN_ACTION}'. The menu row would schedule something else."
  # The row may DECORATE the switch; it may not reorder it. Anchored at the
  # START: the switch must already be scheduled before anything that can fail
  # runs, so a broken OSD cannot leave the user with no way back to Gaming Mode.
  [[ $from_menu == "$MENU_ROW_SWITCH"* ]] ||
    fail "the Quickshell menu row runs '${from_menu}', which does not BEGIN with '${MENU_ROW_SWITCH}'. The session switch must be scheduled first, before the on-screen notice, so that a notice that fails cannot stop the switch."
  [[ $from_menu == *"$from_desktop"* ]] ||
    fail "the .desktop entry runs '${from_desktop}' and the menu row runs '${from_menu}', which does not contain it. The row may wrap the switch in a notice; it must still run the same command."
  log "verified: the .desktop entry runs '${RETURN_ACTION}' and the menu row schedules it first, before the notice"
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

  # The action the merged file must end up carrying, DECODED the way Quickshell
  # decodes it -- not $MENU_ROW_ACTION, whose icon is still a \uXXXX escape at
  # this point. See rendered_menu_action.
  local want
  want=$(rendered_menu_action) ||
    fail "could not read the action back out of the rendered menu row block"

  python3 - "$target" "$block" "$MENU_ROW_BEGIN" "$MENU_ROW_END" \
           "$MENU_ROW_ID" "$want" "$INSTALL_MARKER_JSONC" <<'PY'
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

  local want
  want=$(rendered_menu_action) ||
    fail "could not read the action back out of the rendered menu row block"

  [[ $got == "$want" ]] ||
    fail "${path} carries a '${MENU_ROW_ID}' row whose action is '${got}', not '${want}'. The row would appear in the menu and not switch the session."
  # Belt and braces on the half that matters: the comparison above is against
  # what we rendered, so it would still pass if the constant itself had been
  # edited into something that never switches. A row that only draws a notice
  # is a row that looks like it works.
  [[ $got == *"$RETURN_ACTION"* ]] ||
    fail "${path}'s '${MENU_ROW_ID}' row does not run '${RETURN_ACTION}' at all, so pressing it would draw a notice and never switch the session."
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

  local invoking_user; invoking_user=$(desktop_user)
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
  log "      it shows Omarchy's own notice and then runs '${RETURN_ACTION}',"
  log "      and Omarchy re-reads this file live."
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

# ---------------------------------------------------------------------------
# THE PIZZA
# ---------------------------------------------------------------------------
#
# Installs the `pizza` command. Read the PIZZA constants block above for what
# this does NOT do (it does not turn the easter egg on) and why.
#
# Every file it writes is root-owned under /usr/local, which is what makes this
# stage identical in a chroot and on a live Deck: no user, no home directory, no
# service, no reload. So there is no in_chroot branch here and no defer() -- the
# artefact IS the whole stage, and its verification runs the thing it just
# installed rather than checking that a write returned zero.
stage_pizza() {
  # THE TWO DESTINATIONS ARE PARAMETERS -- see "THE VERIFICATION SEAM" above
  # verify_update_stub. Production passes nothing and gets the constants; the
  # unit suite passes sandbox directories, so the verification below executes
  # the copy it just installed under a fake root instead of whatever the machine
  # running the tests happens to have in /usr/local/bin.
  local bin_dir=${1:-$PIZZA_BIN_DIR}
  local share_dir=${2:-$PIZZA_SHARE_DIR}

  # THE SOURCE DIRECTORY IS A PARAMETER TOO, and for a reason the two above do
  # not have: `install` reads its source as root through $SUDO, and the unit
  # suite's sudo double rewrites every absolute path that is not already inside
  # its sandbox -- source paths included. Without this the suite could not run
  # this stage at all. Production passes nothing and reads from beside the
  # script, which is where a deck-sync and the ISO's payload both put it.
  local src_dir=${3:-}
  if [[ -z $src_dir ]]; then
    src_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  fi

  local dispatcher="${src_dir}/${PIZZA_DISPATCHER_NAME}"
  [[ -f $dispatcher ]] ||
    fail "${PIZZA_DISPATCHER_NAME} not found beside ${PROG}.sh (looked in ${src_dir}). This stage installs it; sync the whole src/ directory, not just this script."

  local sub
  for sub in "${PIZZA_SUBCOMMANDS[@]}"; do
    [[ -f "${src_dir}/${sub}" ]] ||
      fail "${sub} not found beside ${PROG}.sh (looked in ${src_dir}). The dispatcher execs it by name; installing one without the other ships a command that reports its own subcommand as missing."
  done

  local art="" art_dir="" candidate
  for candidate in "${PIZZA_ART_SEARCH_DIRS[@]}"; do
    if [[ -f "${src_dir}/${candidate}/${PIZZA_ART_NAME}" ]]; then
      art_dir="${src_dir}/${candidate}"
      art="${art_dir}/${PIZZA_ART_NAME}"
      break
    fi
  done
  [[ -n $art ]] ||
    fail "the pizza art ${PIZZA_ART_NAME} is in none of ${PIZZA_ART_SEARCH_DIRS[*]} under ${src_dir}. fastfetch does NOT warn about a logo file it cannot read -- it silently draws its builtin distro logo instead -- so shipping the command without its art would install a feature that appears to work and does nothing."

  # bash -n on every shipped script BEFORE anything is copied. A syntax error in
  # a /usr/local/bin file is only found when a human runs it, which for an
  # easter egg could be months.
  local script
  for script in "$dispatcher" "${PIZZA_SUBCOMMANDS[@]/#/${src_dir}/}"; do
    bash -n "$script" ||
      fail "${script} is not valid bash. Refusing to install it."
  done

  log "installing the pizza art: ${share_dir}/${PIZZA_ART_NAME}"
  $SUDO install -d -m 0755 -o root -g root "$share_dir" ||
    fail "could not create ${share_dir}"
  $SUDO install -m 0644 -o root -g root "$art" "${share_dir}/${PIZZA_ART_NAME}" ||
    fail "could not install ${share_dir}/${PIZZA_ART_NAME}"

  # The alternates travel with it, so swapping the pizza on an installed Deck is
  # one `cp` and a re-run rather than a re-sync of the repo.
  local alt
  for alt in "${art_dir}"/${PIZZA_ART_ALT_GLOB}; do
    [[ -f $alt ]] || continue
    $SUDO install -m 0644 -o root -g root "$alt" "${share_dir}/$(basename -- "$alt")" ||
      fail "could not install ${share_dir}/$(basename -- "$alt")"
  done

  log "installing the pizza command: ${bin_dir}/${PIZZA_DISPATCHER_NAME}"
  $SUDO install -d -m 0755 -o root -g root "$bin_dir" ||
    fail "could not create ${bin_dir}"
  $SUDO install -m 0755 -o root -g root "$dispatcher" "${bin_dir}/${PIZZA_DISPATCHER_NAME}" ||
    fail "could not install ${bin_dir}/${PIZZA_DISPATCHER_NAME}"
  for sub in "${PIZZA_SUBCOMMANDS[@]}"; do
    log "installing the pizza subcommand: ${bin_dir}/${sub}"
    $SUDO install -m 0755 -o root -g root "${src_dir}/${sub}" "${bin_dir}/${sub}" ||
      fail "could not install ${bin_dir}/${sub}"
  done

  verify_pizza "${bin_dir}/${PIZZA_DISPATCHER_NAME}" "${share_dir}/${PIZZA_ART_NAME}"

  log "stage-pizza: ok"
  log "NOTHING IS ENABLED. The command is installed and the logo is untouched."
  log "   In a desktop session, as the desktop user:  pizza pizza"
  log "   and to put it back exactly:                 pizza pizza off"
}

# verify_pizza <installed dispatcher> <installed art>
#
# The path is a PARAMETER for the reason set out in "THE VERIFICATION SEAM"
# above verify_update_stub: with the constant baked in, the unit suite would
# exercise whatever is really in /usr/local/bin on the machine running it.
#
# It RUNS what was installed, twice, because both halves fail silently:
#   - `pizza pizza check` validates the art byte by byte (fastfetch treats an
#     unreadable logo as "draw something else", with nothing on stderr);
#   - `pizza` with no arguments must name every subcommand, which is what proves
#     the dispatcher found the file it dispatches to.
verify_pizza() {
  local dispatcher=${1:?verify_pizza needs the installed dispatcher}
  local art=${2:?verify_pizza needs the installed art}

  local out
  out=$(PIZZA_ART="$art" "$dispatcher" pizza check 2>&1) ||
    fail "the installed '${dispatcher} pizza check' failed against ${art}: ${out}"
  log "verified: ${art} is a well-formed fastfetch logo, per the installed command"

  out=$("$dispatcher" 2>&1) ||
    fail "'${dispatcher}' with no arguments exited non-zero. It must print its help."

  # Per SUBCOMMAND LINE, not per substring of the whole help: the word "pizza"
  # appears in the help's own title, so a whole-output match for it would pass
  # with no subcommands listed at all.
  local sub name line
  for sub in "${PIZZA_SUBCOMMANDS[@]}"; do
    name=${sub#pizza-}
    line=$(grep -E "^[[:space:]]+${name}[[:space:]]" <<<"$out" | head -n 1) ||
      line=""
    [[ -n $line ]] ||
      fail "'${dispatcher}' does not list a '${name}' subcommand in its help, so the dispatcher is not seeing ${sub} even though it was just installed."
    [[ $line != *"NOT INSTALLED"* ]] ||
      fail "'${dispatcher}' reports its own '${name}' subcommand as NOT INSTALLED: '${line}'. The dispatcher and ${sub} are in different directories, or ${sub} is not executable."
  done
  log "verified: ${dispatcher} dispatches to every subcommand this stage installed"
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
#
# ⚠️ THE GATE IS UNCHANGED. WHAT A REJECTION *COSTS* IS DIFFERENT WHEN BAKED.
# A human typing `./deck-session.sh stage-power-button` on the wrong machine has
# made a mistake and deserves a non-zero exit. The installer has not: it runs
# every baked stage on whatever it is installing onto, including a QEMU VM whose
# DMI is not a Deck at all, and a `fail` there would turn "this hardware is not
# supported, so nothing was written" -- a correct and complete outcome -- into a
# failed stage in /var/log/omarchy-deck-install.json and a `partial` bake. That
# is a false alarm, and false alarms are how real ones stop being read.
#
# So the REFUSAL is identical either way (nothing is written on any model but
# ${POWER_MODEL}, no flag overrides it); only the exit path differs, and in
# chroot mode the stage says out loud what it skipped and why.
power_model_reject() {
  if in_chroot; then
    warn "$1"
    return 1
  fi
  fail "$1"
}

verify_power_button_model() {
  local product=""
  $SUDO test -r "$POWER_DMI_PRODUCT" ||
    { power_model_reject "cannot read ${POWER_DMI_PRODUCT}, so the model is unknown. This stage rewires the power button using ID_PATHs measured on one specific model; it will not guess."; return 1; }
  product=$($SUDO cat -- "$POWER_DMI_PRODUCT") ||
    { power_model_reject "reading ${POWER_DMI_PRODUCT} failed. Refusing to rewire the power button on an unidentified machine."; return 1; }
  product=${product//$'\n'/}
  [[ -n $product ]] ||
    { power_model_reject "${POWER_DMI_PRODUCT} is empty. Refusing to rewire the power button on an unidentified machine."; return 1; }

  [[ ${product,,} == "${POWER_MODEL,,}" ]] ||
    { power_model_reject "this machine reports product_name='${product}', and every measurement behind this stage was taken on '${POWER_MODEL}' (the OLED Deck). 'Jupiter' is the LCD Deck and it has never been measured: it may enumerate its power button differently, in which case this rule either matches nothing (leaving the duplicate press, and a suspend loop) or matches too much (leaving logind nothing to watch, and a dead button). Today's behaviour on an unmeasured model -- the System menu flashing -- is at least working software. To support this model, repeat the capture in docs/findings/T13-power-button-and-sleep.md §2.2 on it and add what it measures to POWER_ACPI_ID_PATHS / POWER_KEEP_ID_PATH. There is no override flag on purpose."; return 1; }

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

  # 🔴 /run IS THE INSTALLING MACHINE'S, NOT THE TARGET'S. arch-chroot
  # bind-mounts it (see the CHROOT MODE block), so scanning /run/udev/rules.d
  # and /run/systemd/logind.conf.d from in here asks the LIVE ISO what it has
  # generated -- the same class of mistake as discovering a backlight node in
  # the installer's kernel (PROGRESS.md 5.38 D10). A rival found there tells us
  # nothing about the machine being built, and could fail this stage over a file
  # that will not exist on the target. Both directories are volatile by
  # definition and are empty on a target that has never booted, so the honest
  # scan in chroot mode is the persistent directories only, said out loud.
  local -a udev_dirs=("${POWER_UDEV_DIRS[@]}") logind_dirs=("${POWER_LOGIND_DIRS[@]}")
  if in_chroot; then
    udev_dirs=(); logind_dirs=()
    for d in "${POWER_UDEV_DIRS[@]}";   do [[ $d == /run/* ]] || udev_dirs+=("$d");   done
    for d in "${POWER_LOGIND_DIRS[@]}"; do [[ $d == /run/* ]] || logind_dirs+=("$d"); done
    defer "the runtime rule directories (/run/udev/rules.d, /run/systemd/logind.conf.d) are NOT scanned for sort-order rivals at install time -- arch-chroot bind-mounts /run from the live ISO, so what is in there belongs to the installer and not to the target. The persistent directories (${udev_dirs[*]} ${logind_dirs[*]}) ARE scanned and ours is proven to sort last among them. Confirm on the installed machine with: systemd-analyze cat-config systemd/logind.conf | grep -n HandlePowerKey"
  fi

  # --- udev: every file that ADDS the tag must be read before ours ---
  local taggers=0
  for d in "${udev_dirs[@]}"; do
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
    fail "found no udev rule anywhere in ${udev_dirs[*]} that adds TAG+=\"${POWER_UDEV_TAG}\". This stage's whole premise is that ${POWER_UDEV_TAGGER} tags the power buttons and that ours then untags two of them; with nothing adding the tag, either logind is watching no power switch at all (so HandlePowerKey= would be dead) or something tags it by a mechanism this stage does not understand. Investigate before installing anything."
  log "verified: ${ours_rule} is read after all ${taggers} udev rule(s) that add TAG+=\"${POWER_UDEV_TAG}\""

  # --- logind: every drop-in that assigns HandlePowerKey= must lose to ours ---
  local rivals=0
  for d in "${logind_dirs[@]}"; do
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

  # A statement about the CONSTANTS, not about the machine, so it runs
  # everywhere -- including in a chroot, where nothing else here can.
  for f in "${POWER_ACPI_ID_PATHS[@]}"; do
    [[ $f != "$POWER_KEEP_ID_PATH" ]] ||
      fail "POWER_KEEP_ID_PATH (${POWER_KEEP_ID_PATH}) also appears in POWER_ACPI_ID_PATHS. That would untag the ONE node this design keeps, leaving logind watching nothing and the power button dead. Refusing to render a rule that disables its own single source."
  done

  # 🔴 THIS ONE CANNOT BE ANSWERED IN A CHROOT, AND THAT IS STRUCTURAL.
  # It reads udev's RUNTIME DATABASE -- which devices exist, which tags are on
  # them right now -- and arch-chroot bind-mounts /dev and /run from the live
  # ISO, so every answer here belongs to the installer's kernel and the
  # installer's udevd. It is the same defect that made stage-priv-write-helper
  # the one stage to fail on the real install (PROGRESS.md 5.38 D10), applied to
  # a different subsystem, and it must not be answered by guessing harder.
  #
  # The ID_PATHs at stake are ACPI and platform names, which come from firmware
  # rather than from driver enumeration order, so they are FAR more likely to be
  # stable across kernels than a DRM backlight index -- but "far more likely"
  # is not a measurement, and this project has been wrong about exactly that
  # shape of assumption twice.
  #
  # So the artefacts are still written here (rule 1 of chroot mode: nothing the
  # installed system needs is left to first boot), and the question is asked on
  # the target by ${FIRST_BOOT_VERIFY_NAME} -- which, uniquely among the
  # deferred checks, can also ACT on the answer: if the ACPI duplicates are
  # still tagged once the real kernel is up, it removes the logind drop-in and
  # the machine falls back to exactly today's behaviour instead of into the
  # re-suspend loop.
  if in_chroot; then
    defer "which input devices exist and which carry TAGS=:${POWER_UDEV_TAG}: cannot be read at install time -- arch-chroot bind-mounts /dev and /run from the LIVE ISO, so udev's database in here is the installer's kernel's, not the target's. Both power-button files ARE installed. The premise is re-checked on the target by ${FIRST_BOOT_VERIFY_NAME} at every boot, and it REMOVES ${POWER_LOGIND_DROPIN} if the ACPI duplicate is still tagged there -- so the worst case is the power button behaving as it does today, not a suspend loop. Confirm on the installed machine with: journalctl -t ${FIRST_BOOT_VERIFY_TAG} -b"
    return 0
  fi

  while IFS= read -r dev; do
    [[ -n $dev ]] || continue
    id=""; tags=""
    while IFS= read -r line; do
      # ⚠️ TAGS AND NOT CURRENT_TAGS, DELIBERATELY, and the opposite of what the
      # first-boot verifier reads -- see the long note at its `tags=` line. This
      # is a PRE-INSTALL premise: "is this the kind of node udev tags", asked so
      # a rule that would match nothing is refused. TAGS is cumulative and
      # survives our own `TAG-=`, which is exactly what keeps a SECOND run of
      # this stage from failing on the machine the first run fixed. CURRENT_TAGS
      # here would make the stage non-idempotent.
      # `TAGS=*` cannot match a CURRENT_TAGS= line: case anchors at the start.
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
# neutered globally (a real inert unit under /etc/systemd/user, which this can
# see -- install_sleep_lock_override is what ships ours) or per user (under
# ~/.config/systemd/user, which it cannot see, and which is how it was masked
# by hand on the test Deck before that Deck was reinstalled). Failing on an
# unreadable half would block the fix on a machine that is actually fine;
# saying nothing would ship a power button whose every press might raise a
# password prompt on a device with no keyboard. So: report exactly what is
# knowable, and print the one command that settles the rest.
#
# ⚠️ CHECKS, rather than assuming stage-desktop-settings already ran. The stages
# are individually invocable, and "power button suspends, override not yet
# installed" is precisely the bad ordering.
#
# ⚠️ THE OLD MASK IS ITS OWN VERDICT, not a pass and not a plain failure. A
# `-> /dev/null` symlink at our path is what an earlier release of this script
# installed. It does stop the lock, so the power button is safe -- but it also
# makes upstream's first-run `systemctl --user enable --now` fail, which
# replays Omarchy's first-run notifications on every login (§5.24). Reporting
# that as "verified" would hide a live defect behind a green line.
warn_if_sleep_lock_live() {
  local d unit="" ours=$SLEEP_LOCK_GLOBAL_OVERRIDE

  if $SUDO test -L "$ours"; then
    if [[ $($SUDO readlink -- "$ours" 2>/dev/null) == /dev/null ]]; then
      warn "${ours} is the OLD MASK (-> /dev/null) this project used to install. A suspend cannot raise a lock screen, so the power button is safe -- but a masked unit makes 'systemctl --user enable --now' refuse, which fails Omarchy's first-run step, leaves its done marker unwritten and REPLAYS the first-run notifications on every login. Re-run:  ${PROG}.sh stage-desktop-settings"
    else
      warn "${ours} is a symlink to '$($SUDO readlink -- "$ours" 2>/dev/null)', which is neither our inert override nor our old mask. Something else owns that path and this cannot tell whether ${SLEEP_LOCK_UNIT} still locks the screen on suspend. Inspect it before pressing power."
    fi
    return 0
  fi

  if $SUDO test -f "$ours" &&
     $SUDO grep -qF -- "$INSTALL_MARKER_TEXT" "$ours" 2>/dev/null &&
     $SUDO grep -qx "ExecStart=${SLEEP_LOCK_INERT_EXEC}" "$ours" 2>/dev/null; then
    log "verified: ${SLEEP_LOCK_UNIT} resolves to our inert override for every user (${ours}, ExecStart=${SLEEP_LOCK_INERT_EXEC}), so a suspend cannot raise a lock screen"
    return 0
  fi

  for d in "${SLEEP_LOCK_UNIT_DIRS[@]}"; do
    if $SUDO test -f "$d/$SLEEP_LOCK_UNIT"; then unit="$d/$SLEEP_LOCK_UNIT"; break; fi
  done

  if [[ -z $unit ]]; then
    log "note: ${SLEEP_LOCK_UNIT} is not installed on this machine, so nothing locks the screen on suspend"
    return 0
  fi

  warn "${unit} exists and is NOT overridden globally by ours. If it is also live for the desktop user, every suspend this stage enables will lock the screen -- and this Deck has no keyboard to answer the password prompt with (docs/findings/T13-power-button-and-sleep.md §5.3, blast radius R2). Check BEFORE the first press, as the desktop user:  systemctl --user show -p FragmentPath ${SLEEP_LOCK_UNIT}   -- it must name ${ours}. If it does not:  ${PROG}.sh stage-desktop-settings"
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
# Desktop Mode ALSO had Omarchy's own ${POWER_MENU_BIND_KEY} bind
# (\`omarchy-menu toggle system\`) answering this key, which is what made the
# System menu flash before the screen slept. That is a USER config concern and
# not a logind one, so it is not fixed in this file -- stage-power-button
# installs an \`hl.unbind\` into ~/${HYPR_BINDINGS_LUA_REL} in the same run.
# ⚠️ Removing THIS file alone therefore leaves the power button doing nothing
# in Desktop Mode; the undo printed by stage-power-button removes both.

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
# ⚠️ IT *IS* IN BAKE_STAGES, as of PROGRESS.md 5.38 D9, and the two facts are
# not in tension -- read the BAKE_STAGES comment for the argument. The short
# form: keeping it out of the installer did not make anything safer, it shipped
# a Deck whose power button does nothing, because Omarchy's package-owned
# 10-ignore-power-button.conf owns the key and nothing of ours ever contested
# it. The safety this comment is about is preserved by the model gate and by
# ${FIRST_BOOT_VERIFY_NAME}, which disarms the handler on the target if the
# udev rule turns out not to have matched.
#
# ORDER OF WRITES IS THE SAFETY PROPERTY. The udev rule (remove the duplicate)
# goes first, the logind drop-in (arm the handler) second. A run that dies
# between them leaves a machine with one fewer redundant tag and today's
# behaviour otherwise -- harmless. The reverse order would leave the handler
# armed with the duplicate live, which is the one state this whole stage exists
# to avoid.
stage_power_button() {
  # The compositor runtime directory is a SEAM ($1), exactly as it is for
  # stage_osk_kb_layout and for the same reason: baked in, a unit-suite run on a
  # developer's own Hyprland box would reload THEIR desktop.
  local hypr_runtime=${1:-}

  local tool
  for tool in find readlink; do
    command -v "$tool" >/dev/null 2>&1 ||
      fail "required tool '${tool}' not found; this stage verifies what it is about to write and will not install unverified"
  done
  # udevadm is needed by the premise check, which only runs outside a chroot.
  # Requiring it in here would fail a bake on a target that has not installed
  # systemd's udev tools yet, over a check that is not being run.
  if ! in_chroot; then
    command -v udevadm >/dev/null 2>&1 ||
      fail "required tool 'udevadm' not found; this stage verifies what it is about to write and will not install unverified"
  fi

  # 🔴 THE MODEL GATE IS THE FIRST THING, AND IN A BAKE IT IS A SKIP.
  # See verify_power_button_model for why the refusal is identical on every
  # model and only the exit path differs. Nothing has been written at this
  # point, so returning here leaves the machine exactly as it was found: the
  # power button keeps whatever behaviour Omarchy gave it.
  if ! verify_power_button_model; then
    log "stage-power-button: SKIPPED -- this is not a ${POWER_MODEL} (see the warning above). Nothing was written; the power button is unchanged."
    return 0
  fi

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

  # --- 3. and take the SECOND handler away ---------------------------------
  #
  # Last, and after the two files above, because it is only correct once the key
  # suspends: on a machine where this stage stopped at the model gate, Omarchy's
  # menu bind is the ONLY thing the power button does in Desktop Mode and
  # removing it would leave a dead button. The gate is above, so reaching here
  # means the key now suspends and the menu is pure flash. See the
  # POWER_MENU_BIND_KEY block for the measurement.
  local invoking_user; invoking_user=$(desktop_user)
  [[ -n $invoking_user && $invoking_user != root ]] ||
    fail "could not determine the desktop user (got '${invoking_user}'); the power-key unbind lives in their own ~/${HYPR_BINDINGS_LUA_REL} and there is no system-wide drop-in for it"

  local home uid
  home=$(getent passwd "$invoking_user" | cut -d: -f6) ||
    fail "could not resolve ${invoking_user}'s home directory"
  [[ -n $home ]] || fail "empty home directory for ${invoking_user}"
  uid=$(getent passwd "$invoking_user" | cut -d: -f3) ||
    fail "could not resolve ${invoking_user}'s uid"
  [[ $uid =~ ^[0-9]+$ ]] ||
    fail "getent reported a non-numeric uid ('${uid}') for ${invoking_user}; the compositor's runtime directory cannot be located from it"

  # 🔴 In a chroot the seam is pointed somewhere that cannot exist, ON PURPOSE:
  # arch-chroot bind-mounts /run, so /run/user/${uid} in here belongs to the
  # INSTALLER's compositor and verify's live arm would reload the desktop the
  # operator is looking at. Its "no live Hyprland" arm is the honest report for
  # a machine that has never booted.
  if in_chroot; then
    hypr_runtime=$CHROOT_NO_HYPR_RUNTIME
    defer "the power-key unbind cannot be observed taking effect at install time -- it needs a live Hyprland and the target has never booted. It is written to ${home}/${HYPR_BINDINGS_LUA_REL} and applies to ${invoking_user}'s first session. Confirm there with: hyprctl -j binds  -- no bind may name ${POWER_MENU_BIND_KEY}"
  fi

  install_power_menu_unbind "$invoking_user" "${home}/${HYPR_BINDINGS_LUA_REL}"
  verify_power_menu_unbind "$invoking_user" "$uid" ${hypr_runtime:+"$hypr_runtime"}

  # The premise check above deferred rather than ran, so the thing that WILL
  # run it has to exist. Installed here as well as in stage-priv-write-helper
  # because the stages are individually invocable and neither may assume the
  # other ran; install_first_boot_verify is idempotent and writes identical
  # content from either caller.
  if in_chroot; then
    install_first_boot_verify
    log "stage-power-button: ok"
    log ""
    log "🔴 NOTHING TAKES EFFECT UNTIL THE TARGET BOOTS, which is the whole"
    log "   safety property here: udev applies ${POWER_UDEV_RULE##*/} before the"
    log "   uevent reaches logind, so the tag is gone before there is anything"
    log "   to arm. The install is not a live machine and reloads nothing."
    log ""
    log "   On that first boot ${FIRST_BOOT_VERIFY_NAME} re-asks the question"
    log "   this chroot could not: it reads udev's database on the target's own"
    log "   kernel, and if the ACPI duplicate is STILL tagged it deletes"
    log "   ${POWER_LOGIND_DROPIN} -- restoring today's behaviour rather than"
    log "   leaving a Deck that suspends itself on resume. Read the verdict:"
    log "     journalctl -t ${FIRST_BOOT_VERIFY_TAG} -b"
    log ""
    log "   The ${POWER_MENU_BIND_KEY} unbind in ~/${HYPR_BINDINGS_LUA_REL} is the"
    log "   third artefact and the one that stops the System menu flashing. It"
    log "   is user config, not a service, so it takes effect at the first"
    log "   Desktop Mode session with no reload of anything."
    return 0
  fi

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
  log "DESKTOP MODE NO LONGER FLASHES THE SYSTEM MENU. Omarchy binds"
  log "   ${POWER_MENU_BIND_KEY} to 'omarchy-menu toggle system', and the compositor sees"
  log "   ONE physical press as TWO of those events (the real key, then the ACPI"
  log "   notify ~165 ms later -- libinput reads every device on the seat and"
  log "   ignores the udev tag this stage edits), so 'toggle' opened the menu and"
  log "   closed it again: 114 ms of visible menu per press, MEASURED on this"
  log "   hardware 2026-08-16. The bind is now removed in"
  log "   ~/${HYPR_BINDINGS_LUA_REL}, so a press reaches logind and nothing else."
  log ""
  log "🔴 UNDO -- in this order, so the handler is never armed alone:"
  log "     sudo rm -f ${POWER_LOGIND_DROPIN}    # first: disarm the handler"
  log "     sudo rm -f ${POWER_UDEV_RULE}   # second: restore the tags"
  log "   and delete the block between ${POWER_BIND_RULE_BEGIN}"
  log "   and its closing marker in ~/${HYPR_BINDINGS_LUA_REL} to give the"
  log "   power button its Omarchy menu back."
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
    list-stages) printf '%s\n' "${INSTALL_STAGES[@]}" stage-osk-kb-layout stage-audit-privileges stage-default-session stage-boot-default-gaming stage-power-button ;;
    # 🔴 THE INSTALLER'S OWN LIST, and it is printed rather than duplicated for
    # one reason: deck_session_bake.py runs these stages one at a time inside
    # arch-chroot, and a copy of this list in Python would be a second place for
    # it to be wrong. The module asks the script; the script answers from
    # BAKE_STAGES, which sits beside the stages themselves.
    list-bake-stages) printf '%s\n' "${BAKE_STAGES[@]}" ;;
    -h|--help|help)
      cat <<EOF
${PROG}.sh -- two-way Gaming Mode <-> Desktop session switching for a Deck

  ${PROG}.sh                        install everything except the default flip
  ${PROG}.sh <stage>                run one stage
  ${PROG}.sh list-stages            stage names, for CI
  ${PROG}.sh list-bake-stages       the stages the ISO's installer bakes into a
                                    target, in order. Read by the orchestrator's
                                    deck_session_bake step, which runs each one
                                    inside arch-chroot with DECK_SESSION_CHROOT=1

ENVIRONMENT
  DECK_SESSION_CHROOT=1             chroot mode: you are inside arch-chroot, as
                                    root, on a target that has never booted.
                                    Every stage does its file-level work and
                                    prints a 'DEFERRED (chroot):' line for each
                                    check that needs a running system. Read the
                                    CHROOT MODE block at the top of this file.
  DECK_SESSION_USER=<name>          who the desktop user is. Only chroot mode
                                    sets it -- there is no SUDO_USER in there.
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
  stage-menu-row           splices a 'Gaming Mode' row into the
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
  stage-steam-first-run    two fixes for Steam's FIRST start (PROGRESS.md 5.35):
                           a bounded ${STEAM_WAIT_SECONDS}s wait for connectivity before Steam
                           starts, so the "Steam needs to be online to update."
                           modal never appears; and a one-time fullscreen
                           "don't turn me off, Steam is unpacking" notice for
                           the ~2 minutes it then spends updating itself behind
                           a black panel. Both degrade to today's behaviour --
                           the wait always exits 0, and the splash is bounded
                           three ways so it cannot outlive Steam. Both write
                           every outcome to ~/${FIRST_BOOT_LOG_REL},
                           because the first boot's journal is not retained.
  stage-greeter-rotation   rotates the SDDM greeter for the Deck's panel.
                           The user's desktop needs a matching transform in
                           ~/.config/hypr/monitors.lua; the Limine menu and
                           the TTY are NOT covered here.
  stage-pizza              installs the 'pizza' command (a dispatcher plus
                           'pizza pizza', which swaps fastfetch's logo for an
                           ASCII pizza and greets every new interactive terminal
                           with it). Installs only -- it enables nothing. Turn it
                           on from a desktop session with 'pizza pizza', and off
                           again, exactly, with 'pizza pizza off'.
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

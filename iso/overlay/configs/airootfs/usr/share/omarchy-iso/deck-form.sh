#!/usr/bin/env bash
# deck-form.sh -- the Deck-specific installer screens (T4, P2.5/P2.6).
#
# INSTALL PATH: this file lives here, at src/deck-form.sh, and T5's ISO
# overlay build installs it to /usr/share/omarchy-iso/deck-form.sh. The
# shipped location and this repo's location are deliberately different --
# same pattern as src/deck-input-mapper.py, installed elsewhere by
# src/deck-session.sh's stage-input-mapper. T5 owns the install step; this
# file does not install itself anywhere.
#
# ===========================================================================
# THE DECISION THIS FILE IMPLEMENTS: WRAP. DO NOT REPLACE. DO NOT FEED.
# docs/tasks/T4-screen-spec.md §1 has the full argument; the short version:
# ===========================================================================
#
# Upstream's `configurator` (bash + gum, ~1200 lines) already turns every
# wizard answer into user_configuration.json / user_credentials.json, via
# prompt functions it sources from setup-form.sh (omarchy_prompt_keyboard,
# _username, _password, _identity, _hostname, _timezone). T4's own patch P1
# (docs/tasks/T4-screen-spec.md §1.2, `overlay/patches/configurator.patch`,
# NOT owned by this file) adds one line to `configurator`:
#
#     source /usr/share/omarchy-iso/deck-form.sh
#
# placed immediately before `wait_for_stable_terminal`, i.e. after every
# function `configurator` and the vendored `setup-form.sh` define, and
# before the flow actually runs. Bash keeps the LAST definition of a
# function name, so a function defined below with the same name as an
# upstream prompt function REPLACES that one screen; every name this file
# does not redefine keeps behaving exactly as upstream shipped it. The
# archinstall JSON schema, the artefact files, and the 14-phase orchestrator
# are never touched here -- only the screens are ours.
#
# This file has no main() and produces no output unless something else
# sources it and calls one of its functions. Running it directly does
# nothing observable, on purpose (see SOURCE-SAFETY below).
#
# ===========================================================================
# SOURCE-SAFETY -- read before adding ANYTHING above a function definition
# ===========================================================================
#
# This file is `source`d into TWO processes this repo does not control the
# internals of: upstream's `configurator` (via patch P1) and
# test/unit/test-deck-form.sh (this repo's own suite, no VM). Everything
# below the constants block is therefore inside a function.
# src/deck-session.sh carries the identical rule, for the identical reason:
# a sourced file's top-level statements run at SOURCE time, in the SOURCING
# shell's own process -- a stray top-level command here runs inside
# configurator's flow, at import time, before any screen exists to show a
# symptom on.
#
# WHY THIS FILE DOES NOT `set -euo pipefail` (CLAUDE.md's own baseline):
# also source-safety. A `set -e` here would change how upstream's ~1200-line
# `configurator` handles ITS OWN failures for the rest of a run this file
# does not own and has not read in full -- and this file cannot `exit`
# either, for the same reason (that would kill the whole installer process
# out from under configurator's own flow, not just this screen). `-u` and
# `pipefail` are set below, matching the choice test/lib/vm-installer-
# screens.sh already made for the identical reason (it too is sourced into
# a script it does not own): they catch a typo'd variable or a broken pipe
# without changing how the SOURCING script's own commands are allowed to
# fail. Loud-failure discipline (CLAUDE.md: never silently swallow a
# failure) is enforced per FUNCTION instead: every function that can fail
# returns non-zero and says why via deck_form_warn/deck_form_die, and every
# call site in this file checks that return.
# ===========================================================================
#
# ===========================================================================
# SCOPE OF WHAT IS ACTUALLY BUILT HERE (see also this session's final report)
# ===========================================================================
#
# Built by an earlier session, in the priority order
# docs/tasks/T4-screen-spec.md §4 asked for:
#   1. The bounded text-entry mode (§2.3) -- deck_form_text_prompt and its
#      collaborators. The mechanism every text screen needs.
#   2. S0 Welcome/disclosure.
#   3. S3 Account -- constants, validation predicates, and the override
#      functions. Both of this item's original UNVERIFIED assumptions have
#      since been READ rather than inferred, and both were WRONG: upstream's
#      variable-name contract for what a prompt function sets (corrected
#      below, `$password`/`$hostname`), and the reserved-username list, which
#      is `OMARCHY_RESERVED_USERNAMES` and a REGEX STRING, not an array named
#      `RESERVED_USERNAMES` (docs/PROGRESS.md §5.34 D1 -- it shipped dead, and
#      `root` was an accepted username until P33; see the S3 block).
#   4. S1 Wi-Fi -- ONLY the pure, testable slice §4 S1 itself calls out for
#      [U] coverage: the SSID list builder and its iwctl-output parser.
#      (COMPLETED 2026-08-12 -- see item 9 below.)
#   5. S8 Failure -- the menu contents and the cancel-fallback decision
#      layer (the one the spec's own §4 S8 flags as needing mutation
#      testing), plus the menu loop and log pager. ⚠️ NOT WIRED UP: upstream's
#      `failure_menu` lives in `omarchy-install-dashboard`, a separate process
#      this file is never sourced into, so the loop is named
#      `deck_form_failure_menu` and waits on T4a's patch seam. S8 does not
#      appear on a real ISO today.
#
# ⚠️ CORRECTION found THIS session, by actually reading the real
# `iso/upstream/configs/airootfs/root/configurator` (not available to the
# session that built S3): upstream's own `user_form` reads back `$password`
# (not `user_password`) and `$hostname` (not `hostname_value`) -- see
# `write_user_files`/`user_step`'s own table, which read `$password` and
# `$hostname` directly. S3's `_password` and `deck_form_hostname_body` set
# the WRONG variable names, so on the real ISO today `$password` and
# `$hostname` are left unset (configurator has no `set -u`, so this fails
# SILENT -- an empty password hash and an empty hostname reach the artefact,
# not a crash). NOT fixed here: S3 is out of this session's file-ownership
# scope ("do not rebuild, do not restructure"). S5 below is built against
# the REAL contract (matching upstream, which is what write_user_files
# actually reads), not against S3's current wrong names, so fixing S3 is a
# prerequisite for S5 to show correct values -- flagged loudly in this
# session's final report, and as a spawned follow-up task.
#
# This session (T4 continuation) adds:
#   6. S2 Region (timezone) -- overrides `omarchy_prompt_timezone` (the REAL
#      name, confirmed this session at `configurator` line 260; not a guess).
#      Two-level area/city pick, geo-guess sanitisation, UTC/empty-list
#      fallbacks, all as pure functions; the gum-driving wrapper is thin,
#      proven at [V] like S8's `failure_menu` already is.
#   7. S4 Disk -- overrides `requires_full_disk_install` (suppresses the
#      free-space install mode, upstream's own skip path), `disk_form`
#      (RM-based eligibility, not name-based; auto-skips the picker when
#      exactly one disk is eligible; a dead-end screen -- Reboot/Power off,
#      never a shell -- when none is), and `confirm_disk_overwrite` (our
#      text, cursor defaults to "No", and `encrypt_installation` is an
#      unconditional constant `false` -- no Ctrl+C toggle exists at all).
#   9. S1 Wi-Fi, the rest of it (2026-08-12) -- the interactive scan/select
#      flow, the passphrase prompt through §2.3's bounded text-entry mode,
#      §5's whole failure tree (no hardware / iwd dead / no networks /
#      wrong passphrase, bounded at 3 / no DHCP / captive portal), and --
#      since 2026-08-16 -- NO skip: the connection is required, and the S1
#      block below carries the operator's decision and the three parts of it.
#      and U1's NetworkManager credential hand-off. S1 is invoked from the
#      END OF `greeter` -- upstream has no Wi-Fi screen to override, so
#      there is no upstream name for it; see the S1 block's own "WHERE
#      THIS SCREEN IS CALLED FROM" comment for why that is the seam and
#      not a third patch hunk. U1's finding: upstream does NOTHING about
#      carrying credentials across (measured against iso/upstream, not
#      inferred), so this file stages a NetworkManager keyfile that T5's
#      `configure_deck` phase must install -- contract in the U1 block.
#
#   8. S5 Summary -- `deck_final_summary`, the NEW function name patch P1
#      hunk 2 calls directly (`docs/tasks/T4-screen-spec.md §1.2`), not an
#      override of an existing upstream name. On "Go back" it re-runs
#      upstream's own `user_step`/`disk_form`/`select_installation` itself
#      (mirroring upstream's own recap-loop shape in `user_step`), since
#      nothing later in `configurator`'s flow loops back to it for us.
#
# NOT built, and why (see this session's final report for the full
# reasoning):
#   - S6 Progress/tips and S7 Completion/reboot. Both upstream screens
#     (`render_finish`, the dashboard's tips array, `failure_menu`) live in
#     `configs/airootfs/usr/local/bin/omarchy-install-dashboard` -- a
#     SEPARATE PROCESS this file is never sourced into (`configurator` only
#     sources `deck-form.sh`; it never touches the dashboard binary at all,
#     confirmed by reading both files this session). Defining a function
#     named `render_finish` or a tips-array override HERE would be exactly
#     the failure mode T4-screen-spec.md §6.4 exists to catch: a function
#     defined under a name nothing in this process ever calls, silently
#     never appearing on the real ISO. T4-screen-spec.md §7 already flags
#     this ("deck-form.sh cannot reach them ... decide in T4a") and this
#     session did not invent a new file to work around its own scope
#     boundary (iso/ is explicitly off limits: two other agents own it).
#     Fixing S6/S7 needs a THIRD additive overlay file (an
#     `omarchy-install-dashboard` replacement) or a patch to it -- neither
#     is `src/deck-form.sh`.
#
# 10. THE KEYBOARD LAYOUT (2026-08-12, `docs/PROGRESS.md` §5.20a) -- the gap
#     item 9's session left open, closed, and NOT the way §3 deviation 2
#     originally wrote it. See the "S2b" block below for the whole argument.
#     One sentence: `$keyboard` is the user's preference and still reaches
#     archinstall's `"kb_layout"`; the LIVE console keymap is pinned to the
#     layout the on-screen keyboard actually draws, and upstream's
#     `loadkeys "$keyboard"` -- which typed the ACCOUNT PASSWORD under a
#     keymap the OSK does not draw -- is gone. deviation 2's own remedy
#     ("`keyboard` becomes the constant `us`") is not implemented, because
#     it is the session-wide shape the operator explicitly rejected on the
#     desktop side of the identical defect the same day (commit e8c3698).

set -uo pipefail

readonly DECK_FORM_PROG=deck-form

deck_form_log()  { printf '[%s] %s\n' "$DECK_FORM_PROG" "$*" >&2; }
deck_form_warn() { printf '[%s] WARNING: %s\n' "$DECK_FORM_PROG" "$*" >&2; }
# Never exits (see SOURCE-SAFETY above) -- logs and returns 1. Callers that
# need to stop must return themselves; this only stops itself from being
# silent about why.
deck_form_die()  { printf '[%s] ERROR: %s\n' "$DECK_FORM_PROG" "$*" >&2; return 1; }

# ===========================================================================
# §2.3 -- bounded text-entry mode
# ===========================================================================
#
# Lizard mode cannot type (§2.1: no Space, no OSK -- it needs two absolute
# cursors lizard mode does not provide); `lizard_mode=N` plus our mapper
# makes deck-input-mapper the ONLY input path on the device. Neither mode
# alone can run a controller-only installer, so every text screen borrows N
# for exactly the duration of one prompt and hands it back on every exit
# path -- never at boot, never for the whole flow.
#
# §2.3's own reasoning for BOUNDED rather than a one-time flip at boot:
# the blast radius of a dead mapper is one prompt, seconds long, not a
# lifetime with no way back; lizard_mode=Y is the FAILURE-SAFE state, not a
# state anyone has to reach (a reboot restores it too, since the parameter
# does not persist -- §2.1's own measurement).

readonly DECK_LIZARD_SYSFS=/sys/module/hid_steam/parameters/lizard_mode
readonly DECK_MAPPER_BIN=/usr/local/bin/deck-input-mapper
readonly DECK_OSK_BOUND_MARKER="deck-input-mapper: bound"
# ✅ BOTH OF THESE ARE REAL AS OF 2026-08-12. T4-screen-spec.md §2.3's two
# named mapper flags -- `--osk-start-shown` and a machine-readable "bound"
# line -- now exist in src/deck-input-mapper.py (see its `BOUND_MARKER`
# block, which is the authority on what the marker promises; the two spellings
# are cross-checked by BOTH suites). This block used to say they did not, and
# that every real prompt therefore timed out and degraded.
#
# What the marker means, from the consumer's side: the mapper is bound to a
# pad, that pad's fd is in its selector, its uinput keyboard is open, and --
# because we pass `--osk-start-shown` -- the on-screen keyboard is DRAWN.
# Not requested, drawn. So it is safe to start typing the moment it appears,
# which is the only property this file needs from it.
#
# The mapper prints it on STDERR. This file redirects the mapper's stdout and
# stderr into one file (see deck_form_text_prompt), so the stream is not
# load-bearing here -- but it is what §2.3 specifies and what the journal
# gets, so do not "simplify" the capture to stdout only.
#
# ⚠️ THE DEGRADE PATH IS STILL LIVE AND STILL THE POINT. The mapper
# deliberately withholds the marker when the keyboard was asked for and is not
# on the screen -- no OSK modules, an unopenable tty, or a console too narrow
# to draw a row -- so a timeout here still means exactly what it meant before:
# run the prompt, WITHOUT an OSK, and say so. Both paths are unit-tested below
# against fake mappers (one that prints the marker, one that never does).
readonly -a DECK_MAPPER_ARGS=(--osk-backend=tty --osk-start-shown)
# --- the bind deadline: DERIVED FROM THE MAPPER, not chosen ----------------
#
# 🔴 THIS WAS 5, AND 5 WAS A NUMBER NOBODY MEASURED (docs/PROGRESS.md §5.34
# D2). On real hardware the mapper bound LATER than 5 s, the wait below
# expired, and -- because nothing killed the mapper on expiry -- the on-screen
# keyboard then came up anyway, underneath a warning saying it had not. A
# false statement, left on screen, next to the thing it denied. QEMU could
# never catch it: with no gamepad the bind never happens there, so the message
# was always true in the VM.
#
# The number below is not a bigger guess. It is read off the mapper's OWN
# worst case, which this file must not be shorter than:
#
#   src/deck-input-mapper.py: NO_PAD_GRACE_SECONDS = 30.0
#
# `pick_device` deliberately tolerates up to that long with NO pad present
# (its own comment: exiting on the enumeration gap "burned 4 of 5 restarts"),
# rescanning every 1.0 s, before it gives up and exits. So any deadline under
# 30 s can, by construction, time out on a mapper that is still patiently
# doing exactly what it was designed to do and is about to succeed -- which is
# D2's mechanism, whatever the proximate cause of the delay was on the day.
# test/unit/test-deck-form.sh reads NO_PAD_GRACE_SECONDS out of the mapper and
# FAILS if this constant ever drops back below it, so the two cannot drift.
#
# The +5 is the rest of the startup, measured on the Deck 2026-08-15 (session
# 29, over SSH, warm cache): `deck-input-mapper --list` -- full interpreter
# start, `import evdev`, compiling the 193 KB script -- takes 1.02-1.18 s
# there, and the OSK module load plus the first tty draw happen after that and
# before the marker. 5 s covers those with room, plus the 0.1 s poll
# granularity below. ⚠️ UNVERIFIED, and stated as such: the bind time INSIDE
# THE LIVE ISO was not measured. The installer's mapper runs from squashfs
# with no bytecode cache, on a console rather than over SSH, immediately after
# `lizard_mode` is written -- and none of that is reproducible from a running
# installed system. The bound above does not depend on that number; it only
# has to be larger than it, and NO_PAD_GRACE_SECONDS is the largest the mapper
# itself will ever allow.
#
# THE COST OF BEING WRONG IS NOT SYMMETRIC, which is why this errs long. A
# deadline that is too SHORT abandons a working keyboard on a device with no
# other way to type (CLAUDE.md: no keyboard or terminal for a standard
# install). A deadline that is too LONG only makes a genuinely-dead mapper
# take longer to declare -- and not even that in practice, because the wait
# below also returns the moment the mapper PROCESS exits, which is what
# actually happens in QEMU and on every hard failure.
readonly DECK_OSK_BIND_DEADLINE=35
readonly DECK_OSK_POLL_INTERVAL=0.1

# --- the console keymap the OSK actually draws (§5.20a) --------------------
#
# 🔴 THE SECOND HALF OF THE OSK'S CONTRACT, and the half a bare console does
# not get for free. The mapper's uinput device emits raw KEYCODES
# (src/deck_osk_layout.py binds ';' to KEY_SEMICOLON); which CHARACTER a
# keycode becomes is decided downstream. In a Wayland session that decision
# is per-device XKB, and src/deck-session.sh already pins OUR device -- and
# only ours -- with `readonly OSK_KB_LAYOUT=us` (commit e8c3698). A bare
# console has no XKB and no per-device anything: `loadkeys` sets ONE keymap
# for the whole virtual terminal, so the only way for the installer's console
# to type what the OSK draws is for that one keymap to be the OSK's.
#
# So this constant is not "US, arbitrarily". It is "whatever
# src/deck_osk_layout.py draws", and test/unit/test-deck-form.sh asserts it
# against `OSK_KB_LAYOUT` in src/deck-session.sh so the two cannot drift.
# The day the OSK grows per-layout tables (§3 deviation 2's own named
# follow-on), this stops being a constant and starts being the OSK's
# reported layout -- and nothing else here has to change.
readonly DECK_CONSOLE_KEYMAP=us

# --- the console FONT (P33 A3) ---------------------------------------------
#
# The other half of "the installer is unreadable on a 7 inch panel"
# (docs/PROGRESS.md §5.34 D3). The Deck's framebuffer is 800x1280 -- READ off
# the hardware 2026-08-15, `/sys/class/graphics/fb0/virtual_size` = `800,1280`
# -- and the kernel cmdline carries `fbcon=rotate:1`. At the console default
# of 8x16 that is 100 columns of 8-pixel-wide glyphs on a handheld screen.
#
# ⚠️ THIS IS NOT ONLY THE KEYBOARD'S PROBLEM, which is why it is pinned here
# and not inside the OSK. Every gum screen in the flow -- the disclosure text,
# the network list, the timezone picker, the summary -- draws at the same
# size. Doubling the glyph doubles all of them at once.
#
# NO NEW PACKAGE, and that is checked rather than assumed. `kbd` cannot be
# absent from any Arch live ISO: `pacman -Qi kbd` reports `Required By:
# systemd`, so it is pulled in by the base system itself, not by anything this
# project chose. It is also already the source of `loadkeys`, which this file
# has always called. And it ships this font: VERIFIED 2026-08-15 on the Deck
# AND on the dev machine --
# `/usr/share/kbd/consolefonts/latarcyrheb-sun32.psfu.gz`, `pacman -Qo` says
# `kbd 2.10.0-1`, and `setfont` is `/usr/bin/setfont` from the same package.
# `solar24x32` is the only other 32-pixel-tall font kbd carries; this one is
# preferred because it is the same Lat/Ar/Cyr/Heb coverage as the 8x16
# `latarcyrheb-sun16` the console already defaults to, so no glyph that
# rendered before stops rendering.
#
# 🔴 DISABLED 2026-08-16 AFTER MEASURING IT ON THE PANEL. Set empty = no font
# is pinned and the console keeps its 8x16 default. The machinery below stays
# (tested, and correct if a future font is ever wanted); only the value is off.
#
# ⚠️ THE ARITHMETIC THAT USED TO STAND HERE WAS WRONG ON BOTH AXES. It claimed
# "16x32 gives 50 columns and 40 rows where 8x16 gave 100 and 80". The Deck's
# console is 1280x800 in its own frame (`fbcon=rotate:1`), so the real numbers
# are:
#
#     8x16                160 cols x 50 rows     (what we had, and keep)
#     latarcyrheb-sun32    80 cols x 25 rows     (what this pinned)
#
# It halved BOTH axes. 25 rows cannot hold the Omarchy logo, a prompt and a
# 7-row keyboard at once, so on hardware the greeter's logo filled the screen,
# the keyboard's top rows drew over each other, and THE USERNAME AND PASSWORD
# PROMPTS WERE PUSHED OFF THE SCREEN ENTIRELY -- strictly worse than the small
# font it was meant to fix, and a `CLAUDE.md` violation (a screen you cannot
# read is a screen you cannot complete without a keyboard). Photographed by the
# operator, 2026-08-16; verdict: "I prefer the sizing for the install menu that
# we had before. The only thing I would have changed was the keyboard being
# too small."
#
# 🔴 AND THE FONT WAS NEVER WHAT FIXED THE KEYBOARD. `deck_osk_tty.py`'s grid
# now derives its cell width from the real column count (P33 Agent B), so at
# the DEFAULT font it renders 160 columns wide instead of the old hardcoded 80
# -- twice the width, at the sizing the operator asked to keep. The font pin
# was a second, independent change that only cost rows.
#
# Before setting this to anything again: count the ROWS, not just the columns,
# and check the tallest screen still fits.
readonly DECK_CONSOLE_FONT=

# deck_form_console_tty
# Upstream's own guard, kept verbatim in spirit: `loadkeys` only means
# anything on a Linux virtual console, not in a terminal emulator
# (`configurator`'s own comment at its keyboard step). Split out and
# overridable so the unit suite can exercise BOTH branches without a real VT
# -- and, just as importantly, so running the suite from a real VT on a dev
# machine can never re-key that machine's console.
deck_form_console_tty() {
  if [[ -n ${DECK_FORM_TTY_OVERRIDE:-} ]]; then
    printf '%s\n' "$DECK_FORM_TTY_OVERRIDE"
    return 0
  fi
  tty 2>/dev/null || true
}

# deck_form_pin_console_keymap [keymap]
#
# Makes the console type what the OSK draws. Idempotent, and deliberately
# NOT bounded the way lizard mode is: §2.3 borrows lizard_mode=N and hands
# it back because lizard_mode=Y is the failure-safe state. Here the pinned
# value IS the failure-safe state -- it is the layout every keycode the OSK
# can emit was drawn under -- so there is nothing to hand back to, and a
# "restore" would be restoring the defect.
#
# ⚠️ Upstream writes `loadkeys "$keyboard" 2>/dev/null`. Dropping the
# `2>/dev/null` is not tidying: a failure here means the console is typing
# something other than what the user is looking at, on a screen whose value
# is MASKED, and CLAUDE.md's "never silently swallow a failure" applies with
# unusual force to a discard of exactly that message.
deck_form_pin_console_keymap() {
  local keymap=${1:-$DECK_CONSOLE_KEYMAP}
  local tty_name err rc=0
  tty_name=$(deck_form_console_tty)
  if [[ $tty_name != /dev/tty* ]]; then
    deck_form_log "not on a Linux virtual console (tty is '${tty_name:-none}') -- loadkeys would do nothing here, so the keymap is left alone"
    return 0
  fi
  err=$(loadkeys "$keymap" 2>&1) || rc=$?
  if ((rc != 0)); then
    deck_form_warn "could not pin the console keymap to '$keymap' (loadkeys exited $rc: ${err:-no output}). Anything typed on this console may not be the character the on-screen keyboard drew -- INCLUDING THE ACCOUNT PASSWORD, which is masked, so nobody would see it happen."
    return 1
  fi
  return 0
}

# deck_form_pin_console_font [font]
#
# Pinned at the same points, and for the same reason, as
# deck_form_pin_console_keymap above: at the point of use, so the property
# holds without depending on any ordering between screens.
#
# 🔴 NEVER FATAL, AND THAT IS A DIFFERENT RULE FROM THE KEYMAP'S. A wrong
# keymap silently substitutes characters in a MASKED password field, so that
# function returns non-zero and its callers act on it. A missing font changes
# nothing about what gets typed -- it only means the screen stays small. "A
# prompt with a small font beats no prompt" (docs/tasks/P33-fix-round.md A3),
# so this returns 0 on every path a caller can reach and reports the failure
# by warning, never by stopping a screen from being drawn.
#
# Not silent, though: CLAUDE.md's rule is "never swallow a failure", not
# "never continue past one". `setfont`'s own stderr is forwarded rather than
# discarded, exactly as the keymap pin forwards `loadkeys`'.
#
# Idempotent: setting the font that is already loaded is a no-op the console
# does not repaint, so calling this before every prompt costs one exec and
# changes nothing after the first.
deck_form_pin_console_font() {
  local font=${1:-$DECK_CONSOLE_FONT}
  local tty_name err rc=0
  # 🔴 EMPTY MEANS "PIN NOTHING", and it must return BEFORE the tty branch.
  # DECK_CONSOLE_FONT is empty in shipping builds (see its own comment). Left
  # unguarded this would run `setfont ""` on the Deck's real console, fail, and
  # print the "could not set the console font" warning on EVERY prompt --
  # noise on the exact screens the operator has to read. The unit suite cannot
  # catch that: it has no VT, so it returns at the tty guard below and never
  # reaches the exec. Found by reading, not by a test.
  [[ -n $font ]] || return 0
  tty_name=$(deck_form_console_tty)
  if [[ $tty_name != /dev/tty* ]]; then
    # Same guard as the keymap: `setfont` addresses a Linux virtual console,
    # not a terminal emulator. Silent here on purpose -- this branch is the
    # normal case on a dev machine and in the unit suite, and the keymap pin
    # beside it already says the same thing once.
    return 0
  fi
  err=$(setfont "$font" 2>&1) || rc=$?
  if ((rc != 0)); then
    deck_form_warn "could not set the console font to '$font' (setfont exited $rc: ${err:-no output}). The installer stays at the console default (8x16), which is hard to read on the Deck's panel -- but every screen still works."
    return 0
  fi
  return 0
}

# deck_form_lizard_write <sysfs-path> <value>
#
# §2.3's explicit QEMU branch, quoted directly: "hid_steam may not be loaded
# in QEMU, and lizard_mode will not exist there. Step 1 must treat a missing
# file as 'not applicable, continue', and that branch must be unit-tested --
# otherwise every QEMU run silently exercises a different code path from the
# Deck." A missing file is therefore NOT a failure here (returns 0, warns);
# a write that was attempted against a file that DOES exist and failed
# (permissions, a read-only remount) is a real, reportable defect and
# returns 1.
deck_form_lizard_write() {
  local path=$1 value=$2
  if [[ ! -e $path ]]; then
    deck_form_warn "lizard-mode knob not present at $path -- not applicable here (expected under QEMU, T4-screen-spec.md §2.3), continuing without touching it"
    return 0
  fi
  if ! printf '%s' "$value" >"$path" 2>/dev/null; then
    deck_form_warn "could not write '$value' to $path"
    return 1
  fi
  return 0
}

# deck_form_wait_for_marker <file> <marker> <deadline-seconds> [<poll-interval>] [<watch-pid>]
#
# Polls FILE for a line containing MARKER until it appears, the deadline
# elapses, or (if WATCH_PID is given and non-zero) the process being watched
# exits. Never blocks past the deadline -- that bound is what makes a
# hung or dead mapper a DEGRADED prompt (§2.3: "the prompt runs WITHOUT an
# OSK, which is a degradation the screen must state, not swallow") rather
# than a device with no way to advance a screen at all.
#
# Returns:
#   0  the marker appeared
#   1  the deadline elapsed with the process still running
#   2  the process exited without ever printing the marker
#
# WHY 2 EXISTS AS A SEPARATE ANSWER (P33 A2). The two are different facts and
# the screen says different things about them, so collapsing them would be the
# same species of mistake as the false warning this whole change is fixing:
# "it is taking too long" and "it is gone" are not interchangeable. It also
# matters for cost -- the mapper's own NO_PAD_GRACE_SECONDS makes it EXIT
# after ~30 s when no gamepad exists at all, which is precisely the QEMU case,
# so watching the pid is what keeps a 35 s deadline from being 35 s of dead
# waiting in every VM run.
#
# ⚠️ THE RE-CHECK AFTER THE PROCESS DIES IS LOAD-BEARING, not defensive
# padding. A process can write the marker and exit in the same instant this
# loop is sleeping -- the unit suite's own fake mappers do exactly that -- and
# an implementation that answered "it exited" without looking one more time
# would report a bind that happened as a bind that did not.
deck_form_wait_for_marker() {
  local file=$1 marker=$2 deadline=$3 interval=${4:-$DECK_OSK_POLL_INTERVAL}
  local watch_pid=${5:-0}
  local waited=0
  while true; do
    if [[ -r $file ]] && LC_ALL=C command grep -qF -- "$marker" "$file" 2>/dev/null; then
      return 0
    fi
    if [[ $watch_pid != 0 ]] && ! kill -0 "$watch_pid" 2>/dev/null; then
      sleep "$interval"
      if [[ -r $file ]] && LC_ALL=C command grep -qF -- "$marker" "$file" 2>/dev/null; then
        return 0
      fi
      return 2
    fi
    awk -v w="$waited" -v d="$deadline" 'BEGIN { exit !(w >= d) }' && return 1
    sleep "$interval"
    waited=$(awk -v w="$waited" -v i="$interval" 'BEGIN { print w + i }')
  done
}

# deck_form_text_prompt_cleanup <sysfs-path> <mapper-pid> <stderr-file>
#
# Idempotent by construction (kill -0 guards a pid that already exited;
# writing 'Y' to a file already 'Y' is a no-op write) -- that is what makes
# it safe to call BOTH from the ordinary post-prompt path in
# deck_form_text_prompt AND from that function's EXIT-trap safety net
# without the two racing or double-acting on anything observable.
#
# Restores the CONSTANT Y, never "whatever the value was before this
# prompt" -- §2.3: "lizard_mode=Y is the failure mode, not a state anyone
# has to reach." Restoring to a remembered prior value would let a stale
# lizard_mode=N some earlier, unrelated bug left behind quietly re-arm.
deck_form_text_prompt_cleanup() {
  local sysfs=$1 mapper_pid=$2 stderr_file=$3
  if [[ $mapper_pid != 0 ]] && kill -0 "$mapper_pid" 2>/dev/null; then
    kill "$mapper_pid" 2>/dev/null
    wait "$mapper_pid" 2>/dev/null
  fi
  deck_form_lizard_write "$sysfs" Y ||
    deck_form_warn "could not restore lizard mode to Y at $sysfs -- the device may be left with no firmware pointer AND no mapper. This is exactly the state §2.3 exists to prevent."
  rm -f "$stderr_file"
}

# deck_form_abandon_mapper <sysfs-path> <mapper-pid> <stderr-file> <reason>
#
# 🔴 THE OTHER HALF OF P33 A2, and the half that is not a number.
# docs/PROGRESS.md §5.34 D2: on hardware the deadline expired, the code warned
# "this prompt runs WITHOUT it" -- and then LEFT THE MAPPER RUNNING, so the
# keyboard drew a second later and the user read a sentence denying the thing
# they were looking at. Raising the deadline alone would only make that rarer,
# not wrong less often; a rare false statement is still a false statement, and
# this project's own rules do not have a rate threshold for one.
#
# So the warning is made TRUE BY CONSTRUCTION instead of by hope: on expiry
# the mapper is killed, and the prompt really does run without it. Nothing on
# screen has to be retracted because nothing false was said.
#
# ⚠️ LIZARD MODE GOES BACK TO Y HERE, IMMEDIATELY -- not at the end of the
# prompt. Without it this function would produce the exact state §2.3 exists
# to prevent and deck_form_text_prompt_cleanup already names: no firmware
# pointer AND no mapper, i.e. a device with no input at all, on a screen the
# user now has no way to leave. With lizard mode restored they still cannot
# type (§2.1: no Space, no OSK) but they can still move a cursor and press
# Enter or Escape, which is the difference between a degraded screen and a
# dead handheld. Reusing the cleanup function rather than open-coding the
# three steps is deliberate: it is already idempotent by construction, so the
# ordinary post-prompt cleanup that runs later is a no-op rather than a race.
#
# THE MAPPER'S OWN OUTPUT IS REPORTED, NOT DELETED. It is the only place the
# REASON lives -- "no gamepad present", "the console is too narrow to draw a
# row", an unopenable tty -- and the cleanup below removes the file. Throwing
# that away while announcing a degradation would be swallowing the failure at
# the exact moment it was finally observable.
deck_form_abandon_mapper() {
  local sysfs=$1 mapper_pid=$2 stderr_file=$3 reason=$4
  local captured=''
  [[ -r $stderr_file ]] && captured=$(LC_ALL=C tail -n 20 -- "$stderr_file" 2>/dev/null)
  deck_form_warn "$reason -- this prompt runs WITHOUT the on-screen keyboard, and the mapper has been stopped so that stays true"
  if [[ -n $captured ]]; then
    deck_form_log "the on-screen keyboard's helper said, before it was stopped:"
    printf '%s\n' "$captured" >&2
  else
    deck_form_log "the on-screen keyboard's helper produced no output at all, which is itself the only evidence there is"
  fi
  deck_form_text_prompt_cleanup "$sysfs" "$mapper_pid" "$stderr_file"
}

# deck_form_text_prompt <prompt-fn> [args...]
#
# Runs PROMPT_FN (a gum-driving screen body) with lizard mode off and the
# mapper's on-screen keyboard coming up, for exactly the duration of that
# one call -- §2.3's whole design, spelled out as five numbered steps
# there. Sets DECK_FORM_OSK_UP=1/0 before calling PROMPT_FN so it can say
# so on screen when degraded (§2.3: "a degradation the screen must state,
# not swallow" -- this file's job is to make that fact available, not to
# decide how each screen phrases it).
#
# Overridable via DECK_TEXT_PROMPT_LIZARD_SYSFS / _MAPPER_BIN / _DEADLINE,
# which exist SPECIFICALLY so the unit suite can point this at fixtures
# and a fake mapper instead of real hardware and a real Python process.
#
# THE ABORT-SAFETY NET. §2.3 step 5 says "trap/always ... including
# set -e" -- but this file cannot itself set -e (SOURCE-SAFETY above), so
# an unguarded nonzero exit inside PROMPT_FN could be running under a
# set -e this file does not control (whatever configurator's own shell
# state happens to be). Empirically, a bash `trap ... RETURN` set inside
# this function is NOT scoped only to this function's own return -- it can
# re-fire on a LATER, unrelated ancestor function's return (confirmed by
# hand while building this, not assumed), which would re-run mapper
# teardown at a time with no relationship to this prompt. `trap ... EXIT`
# does not have that problem, but it is a SHELL-GLOBAL registration, and
# this file has no visibility into whether configurator already owns one
# (its own tte-animation cleanup is a plausible reason it might, per §4
# S0's "leaves the tty in raw/no-echo mode when killed" note). Silently
# clobbering someone else's EXIT trap is a worse failure than not having a
# safety net, so: only arm one when EXIT is provably unowned; otherwise
# warn, loudly, and rely on the ordinary post-return cleanup a few lines
# below (which covers every path that does not itself abort the shell).
deck_form_text_prompt() {
  local prompt_fn=$1; shift
  local sysfs=${DECK_TEXT_PROMPT_LIZARD_SYSFS:-$DECK_LIZARD_SYSFS}
  local mapper_bin=${DECK_TEXT_PROMPT_MAPPER_BIN:-$DECK_MAPPER_BIN}
  local deadline=${DECK_TEXT_PROMPT_DEADLINE:-$DECK_OSK_BIND_DEADLINE}

  local stderr_file mapper_pid=0 osk_up=0
  stderr_file=$(mktemp) || { deck_form_die "mktemp failed"; return 1; }

  # STEP 0 (§5.20a). Every caller of this function is, by construction, a
  # screen whose text is typed on the OSK -- that is what this function is
  # FOR. So the console keymap is pinned HERE, at the point of use, rather
  # than only once in `keyboard_form` below: the property "whatever types a
  # password does so under the keymap the OSK draws" then holds without
  # depending on any ordering between screens at all. That matters concretely
  # -- upstream re-enters `keyboard_form` from `user_step` on both Esc-back
  # and "No, change it" (configurator:273, :292), so "S1 runs before the
  # first loadkeys" (this file's S0/S1 argument) protects the Wi-Fi
  # passphrase and nothing after it. Never fatal: a prompt with a doubtful
  # keymap still beats no prompt, and the failure is stated loudly.
  deck_form_pin_console_keymap ||
    deck_form_warn "this prompt runs with an UNVERIFIED console keymap -- what you type may not be what the on-screen keyboard shows"

  # STEP 0b (P33 A3). Beside the keymap, at the point of use, for the identical
  # reason: no ordering between screens has to hold for it to be true here.
  # Never gated -- see deck_form_pin_console_font's own "never fatal" note --
  # and deliberately BEFORE the mapper starts, so the on-screen keyboard reads
  # the console geometry this sets rather than the one it replaced.
  deck_form_pin_console_font

  deck_form_lizard_write "$sysfs" N ||
    deck_form_warn "could not turn lizard mode off -- this prompt runs WITHOUT the on-screen keyboard"

  if [[ -x $mapper_bin ]]; then
    "$mapper_bin" "${DECK_MAPPER_ARGS[@]}" >"$stderr_file" 2>&1 &
    mapper_pid=$!
    local wait_rc=0
    deck_form_wait_for_marker "$stderr_file" "$DECK_OSK_BOUND_MARKER" \
      "$deadline" "$DECK_OSK_POLL_INTERVAL" "$mapper_pid" || wait_rc=$?
    case $wait_rc in
      0) osk_up=1 ;;
      2)
        # The mapper is already gone. Nothing to kill, but everything else
        # abandon does still applies -- lizard mode back to Y, and its own
        # last words reported instead of deleted unread.
        deck_form_abandon_mapper "$sysfs" "$mapper_pid" "$stderr_file" \
          "the on-screen keyboard's helper exited without ever reporting bound"
        mapper_pid=0
        ;;
      *)
        deck_form_abandon_mapper "$sysfs" "$mapper_pid" "$stderr_file" \
          "on-screen keyboard did not report bound within ${deadline}s"
        mapper_pid=0
        ;;
    esac
  else
    deck_form_warn "mapper not found at $mapper_bin -- this prompt runs WITHOUT the on-screen keyboard"
  fi

  local armed_exit_trap=0
  if [[ -z $(trap -p EXIT) ]]; then
    # shellcheck disable=SC2064  # values must be captured NOW, not deferred
    trap "deck_form_text_prompt_cleanup '$sysfs' '$mapper_pid' '$stderr_file'" EXIT
    armed_exit_trap=1
  else
    deck_form_warn "an EXIT trap is already installed; this prompt's abort-safety net is NOT armed (the ordinary post-prompt cleanup still covers a normal return)"
  fi

  local rc=0
  # Not local, and not read anywhere in THIS file -- it is how PROMPT_FN
  # (and, on the real ISO, whatever text it draws) learns whether the OSK
  # actually came up, per §2.3's "a degradation the screen must state, not
  # swallow". Global on purpose.
  # shellcheck disable=SC2034
  DECK_FORM_OSK_UP=$osk_up
  "$prompt_fn" "$@" || rc=$?

  deck_form_text_prompt_cleanup "$sysfs" "$mapper_pid" "$stderr_file"
  [[ $armed_exit_trap -eq 1 ]] && trap - EXIT

  return "$rc"
}

# ===========================================================================
# S0 -- Welcome and disclosure
# ===========================================================================

# 2026-09-24 hardware feedback: two lines, not eight. The operator cut
# everything but the fact and the keys -- the wipe scope now lives on the
# drive screen and the wipe confirm, where the choice is actually made.
readonly -a DECK_S0_LINES=(
  "This will install Omarchy on your Steam Deck."
)
# The prompt names both keys: A installs, B cancels. The old "Press A to
# erase the drive and begin" is retired with the bare-Enter greeter -- B is
# now a real answer, so the line must say so.
readonly DECK_S0_PROMPT_LINE="Press A to install, B to cancel"

# deck_form_s0_text
# Split out so the [U] suite asserts on the FUNCTION'S OWN OUTPUT
# (T4-screen-spec.md §4 S0: "asserted on the function's output, not on a
# screenshot") rather than needing a tty to read a screen back from.
deck_form_s0_text() {
  local line
  for line in "${DECK_S0_LINES[@]}"; do printf '%s\n' "$line"; done
  printf '%s\n' "$DECK_S0_PROMPT_LINE"
}

# deck_form_s0_wait_key <tty> -- S0's A/B answer. Prints "proceed" (A/Enter)
# or "cancel" (B/Esc) and returns 0; returns 1 only when the tty cannot be
# read at all (fail loudly, never guess). Loops on any other key: on a
# controller only A and B exist, and accepting a third byte as consent
# would be consent by typo.
# An empty read is Enter in cooked mode; a raw tty delivers it as CR (\r)
# instead (upstream's own tte animation leaves the tty raw when killed
# mid-frame -- the reason greeter runs `stty sane` first). Accepting only
# the empty read would loop forever on a raw tty, so \r counts as Enter
# too. \n is accepted alongside it for completeness (read -n1 can never
# yield it -- a newline terminates the read and arrives empty -- but the
# intent "either newline byte is Enter" should not depend on that).
# DECK_S0_TTY is overridable so the unit suite never needs a real
# controlling terminal.
deck_form_s0_wait_key() {
  local tty=$1 key=""
  while true; do
    key=""
    if ! IFS= read -r -n1 key <"$tty" 2>/dev/null; then
      deck_form_warn "could not read the S0 answer from $tty -- refusing to guess consent"
      return 1
    fi
    if [[ -z $key || $key == $'\r' || $key == $'\n' ]]; then
      printf 'proceed\n'
      return 0
    fi
    if [[ $key == $'\e' ]]; then
      printf 'cancel\n'
      return 0
    fi
  done
}

# deck_form_draw_s0
# The ONE way S0 is drawn: the big Omarchy logo the same way every other
# screen draws it (clear_logo then echo) before the text. Greeter AND the
# B-from-drive-screen path both call this, so the two can never drift into
# showing different welcomes.
deck_form_draw_s0() {
  clear_logo
  echo
  deck_form_s0_text
}

# deck_form_drain_tty <tty> -- discard already-pending input. Always
# returns 0: draining is best-effort hygiene before a destructive read,
# never a gate.
#
# SAFETY (2026-09-24 hardware follow-up): the drive screen's gum choose is
# answered with A (Enter), and a held or bouncing controller button -- or
# key autorepeat from the mapper -- can leave a second Enter sitting in
# the tty buffer. The wipe confirm's own wait_key would then consume that
# STALE byte and confirm the wipe with nobody pressing anything. Draining
# first means only a NEW press counts.
#
# Bounded (DECK_DRAIN_MAX_BYTES) and gated to character devices and fifos.
# A regular file never consumes -- every open re-reads byte 1 -- so an
# unbounded "until empty" loop would spin forever on the unit suite's own
# file fixtures; pending input is a tty concept anyway, so files correctly
# skip. Each iteration is a timed read, so an idle tty costs one timeout
# and the bill is proportional to actual pending bytes, plus a loud word
# when the bound itself runs out (a held key may still have input queued).
# The read-write open (`<>`, not `<`) never blocks on a fifo with no
# writer the way a read-only open does.
readonly DECK_DRAIN_MAX_BYTES=64
readonly DECK_DRAIN_POLL_SECS=0.05
deck_form_drain_tty() {
  local tty=$1 i=0 drained_byte
  if [[ ! -c $tty && ! -p $tty ]]; then
    return 0
  fi
  while (( i < DECK_DRAIN_MAX_BYTES )); do
    # shellcheck disable=SC2034  # drained_byte is deliberately discarded -- draining IS the use
    if ! IFS= read -r -t "$DECK_DRAIN_POLL_SECS" -n1 drained_byte <>"$tty" 2>/dev/null; then
      return 0
    fi
    i=$(( i + 1 ))
  done
  deck_form_warn "discarded $i pending input bytes from $tty and stopped at the bound -- a held key may still have input queued"
  return 0
}

# The wipe confirm's release gate: keep draining until no byte has arrived
# for DECK_CONFIRM_QUIET_SECS.
#
# WHY deck_form_drain_tty ABOVE IS NOT ENOUGH HERE (2026-09-24 hardware
# review). That drain stops at the FIRST 50 ms gap -- but VT typematic
# autorepeat keeps sending Enters ~every 30 ms for as long as A is held, so
# holding A from the drive screen straight through the confirm's draw leaves
# no 50 ms gap at all: the drain consumes its 64-byte bound and returns while
# input is still flowing, and the confirm's own wait_key then reads the next
# autorepeat Enter as a NEW press. The wipe confirms itself with nobody
# pressing anything.
#
# So the confirm drains until QUIET, not until the first gap: only a full
# DECK_CONFIRM_QUIET_SECS with zero bytes -- longer than the typematic delay
# (~250 ms), so a held key can never produce it -- proves the key was
# released. Only a press AFTER that silence counts.
#
# Bounded by DECK_CONFIRM_QUIET_CAP_SECS of silent draining: past the cap a
# warning is issued and the wait continues LOUDLY rather than returning --
# the cap bounds how long the drain stays silent, never what it accepts. A
# cap-hit that returned "drained" would re-arm the exact defect (accepting
# while input still flows). Always returns 0: like deck_form_drain_tty this
# is hygiene before a destructive read, never a gate -- the wait_key after
# it is what blocks for the real answer.
#
# Regular files skip, like deck_form_drain_tty: they never consume (every
# open re-reads byte 1), so "until quiet" would never arrive. Pending input
# is a tty concept anyway.
readonly DECK_CONFIRM_QUIET_SECS=0.6
readonly DECK_CONFIRM_QUIET_CAP_SECS=10
deck_form_drain_until_quiet() {
  local tty=$1
  if [[ ! -c $tty && ! -p $tty ]]; then
    return 0
  fi
  local quiet_byte drained=0 warned=0 start=$EPOCHSECONDS
  while true; do
    # shellcheck disable=SC2034  # quiet_byte is deliberately discarded -- draining IS the use
    if IFS= read -r -t "$DECK_CONFIRM_QUIET_SECS" -n1 quiet_byte <>"$tty" 2>/dev/null; then
      drained=$(( drained + 1 ))
      if (( warned == 0 )) && (( EPOCHSECONDS - start >= DECK_CONFIRM_QUIET_CAP_SECS )); then
        deck_form_warn "discarded $drained pending input bytes from $tty over ${DECK_CONFIRM_QUIET_CAP_SECS}s without a ${DECK_CONFIRM_QUIET_SECS}s silence -- a key may be held down. Still waiting for release, NOT accepting."
        warned=1
      fi
    else
      return 0
    fi
  done
}

# deck_form_s0_cancel_menu -- B on S0: the safe exit. Nothing is erased yet,
# so this says so and offers Reboot / Power off (the existing dead-end
# pattern: never a shell). Never returns on a real machine; under the suite's
# stubs it returns so the caller can be asserted.
deck_form_s0_cancel_menu() {
  local choice action systemctl_bin=${DECK_SYSTEMCTL_BIN:-systemctl}
  while true; do
    clear_logo
    echo
    say "Install cancelled. The drive was not touched."
    echo
    choice=$(deck_form_disk_dead_end_items | gum choose --header "What next?") || choice=""
    action=$(deck_form_disk_dead_end_action_for "$choice")
    case $action in
      reboot)   "$systemctl_bin" reboot ;;
      poweroff) "$systemctl_bin" poweroff ;;
      *)        : ;;
    esac
  done
}
# ===========================================================================
# FAST-INSTALL C4 -- the early stage (docs/tasks/FAST-INSTALL.md contracts
# C1/C4; the binary itself is Stages' slice, this file only shells out to it)
# ===========================================================================
#
# The erase consent is TWO presses: S0's A (proceed to drive selection)
# and the wipe confirm's A (start the wipe). Greeter runs S0, the drive
# screen, and the wipe confirm in a loop (S0 -> drive list ⇄ confirm),
# then runs `omarchy-deck-early start` on the CONFIRMED disk. Zero
# eligible disks reach the existing dead end BEFORE anything is erased; a
# failed start aborts loudly.
#
# DECK_EARLY_BIN exists so the [U] suite can point this at a fake instead
# of starting a real background install on the test machine. The default is
# C1's live-ISO command name.
readonly DECK_EARLY_BIN_DEFAULT=omarchy-deck-early
readonly DECK_EARLY_ERROR_FILE_DEFAULT=/run/omarchy-deck/early/error
readonly DECK_EARLY_PHASE_FILE_DEFAULT=/run/omarchy-deck/early/phase
# The early stage's own log (omarchy-deck-early's DECK_EARLY_LOG). A
# controller user cannot open it, so the failure menu prints its tail.
# Overridable (DECK_EARLY_LOG_FILE) the way the other stage paths are, so
# the unit suite can point it at a fixture.
readonly DECK_EARLY_LOG_FILE_DEFAULT=/var/log/omarchy-deck-early.log
readonly DECK_EARLY_LOG_TAIL_LINES=12
readonly DECK_STEAM_STATUS_FILE_DEFAULT=/run/omarchy-deck/steam/status
readonly DECK_STEAM_ERROR_FILE_DEFAULT=/run/omarchy-deck/steam/error
readonly DECK_STEAM_PROGRESS_FILE_DEFAULT=/run/omarchy-deck/steam/progress
readonly DECK_STEAM_POLL_SECS=1

deck_form_early_bin() { printf '%s\n' "${DECK_EARLY_BIN:-$DECK_EARLY_BIN_DEFAULT}"; }

# deck_form_start_early_install <disk> -- S0 flow's selected drive.
# Verified-OLED gate, then sets the global `disk` (configurator's JSON
# writers read it) and starts the early stage on the CHOSEN disk. Returns
# nonzero -- and aborts -- when the machine is not a verified OLED Deck,
# when the disk is empty, or when the start fails. Never returns 0 without
# the early stage running. Eligibility is decided by the drive selection
# screen before this is called; this keeps only the final safety gates.
deck_form_start_early_install() {
  local chosen=${1:-} early_bin product_msg vendor_msg
  # OLED wipe gate FIRST -- before anything is probed for erasure. Kernel
  # selection may accept Jupiter/generic Valve (harmless, reversible); the
  # irreversible wipe may not. A Jupiter (unverified LCD), a generic laptop
  # NVMe, or unreadable DMI reaches the dead end here, with the reason SAID.
  if ! deck_form_is_oled_deck; then
    product_msg="unreadable"; vendor_msg="unreadable"
    [[ -r ${DECK_DMI_PRODUCT:-$DECK_DMI_PRODUCT_DEFAULT} ]] && product_msg=$(<"${DECK_DMI_PRODUCT:-$DECK_DMI_PRODUCT_DEFAULT}")
    [[ -r ${DECK_DMI_VENDOR:-$DECK_DMI_VENDOR_DEFAULT} ]] && vendor_msg=$(<"${DECK_DMI_VENDOR:-$DECK_DMI_VENDOR_DEFAULT}")
    deck_form_warn "not a verified OLED Deck (product='${product_msg}', vendor='${vendor_msg}') -- refusing to wipe"
    deck_form_disk_dead_end
    abort "This installer wipes only a verified OLED Steam Deck (Galileo/Valve) with its built-in NVMe or microSD card."
    return 1
  fi
  if [[ -z $chosen ]]; then
    deck_form_warn "no install disk was selected -- refusing to guess which one to erase"
    deck_form_disk_dead_end
    abort "No install disk was selected."
    return 1
  fi
  # shellcheck disable=SC2034
  disk=$chosen
  early_bin=$(deck_form_early_bin)
  say "Installing to $chosen -- this drive is being wiped now."
  if ! "$early_bin" start "$disk"; then
    deck_form_warn "'$early_bin start $disk' failed -- the background install never started, and nothing was erased by it"
    abort "The background install failed to start."
    return 1
  fi
  return 0
}
# deck_form_early_network_ready -- S1's hand-off (C1). Attempts the marker
# write up to DECK_EARLY_MARKER_TRIES times (bounded: the write is idempotent
# and instantaneous, so retrying is cheap) and returns 0 once it lands.
# Returns 1 on persistent failure -- NEVER 0: a silent success here leaves
# the early stage waiting on the marker forever while the network works,
# which is the exact silent-continuation CLAUDE.md forbids. Callers respond
# on screen (deck_form_network_ready_or_stop); this function only reports,
# loudly, via deck_form_warn.
readonly DECK_EARLY_MARKER_TRIES=3
deck_form_early_network_ready() {
  local early_bin tries=0 max=${DECK_EARLY_MARKER_TRIES_OVERRIDE:-$DECK_EARLY_MARKER_TRIES}
  early_bin=$(deck_form_early_bin)
  while (( tries < max )); do
    tries=$(( tries + 1 ))
    if "$early_bin" network-ready; then
      return 0
    fi
    deck_form_warn "'$early_bin network-ready' failed (attempt $tries of $max)"
  done
  deck_form_warn "'$early_bin network-ready' failed $tries times -- the background install was NOT told the network is up"
  return 1
}

# deck_form_network_ready_or_stop -- the screen-level half of the hand-off.
# Success returns 0 silently: the happy path -- including every QEMU run --
# stays keypress-free, and the existing S1 tests pin that (empty gum log).
# Persistent failure is said ON SCREEN with the consequence, then offers Try
# again / Stop the install: retry re-runs the bounded helper, Stop reaches
# the existing dead end (Reboot / Power off, never a shell) and aborts.
# There is deliberately no "continue anyway": continuing would build a
# machine whose Steam silently never downloads -- the black-screen outcome
# S1 exists to prevent, via the operator's no-Skip decision.
deck_form_network_ready_or_stop() {
  while true; do
    if deck_form_early_network_ready; then
      return 0
    fi
    clear_logo
    echo
    say --foreground 1 "The installer could not tell the background install the network is up."
    say "Without that signal Steam is never downloaded, and the Deck boots with no Steam."
    echo
    if gum confirm --affirmative "Try again" --negative "Stop the install" "Tell the background install again?"; then
      continue
    fi
    deck_form_disk_dead_end
    abort "The background install was never told the network is up."
    return 1
  done
}

# deck_form_early_status -- C1's `status` word (absent/running/done/failed).
# A binary that cannot be asked is "unknown", said loudly -- S5 must show
# the state honestly, and "unknown" is honest where a guess would not be.
deck_form_early_status() {
  local early_bin out
  early_bin=$(deck_form_early_bin)
  if ! out=$("$early_bin" status 2>/dev/null); then
    deck_form_warn "'$early_bin status' failed -- showing the early install state as unknown"
    printf 'unknown\n'
    return 0
  fi
  printf '%s\n' "$out"
  return 0
}

# deck_form_early_error -- C1's one-line reason, or empty. Commas become
# semicolons: S5 renders this inside a `gum table -s ","` row.
deck_form_early_error() {
  local file=${DECK_EARLY_ERROR_FILE:-$DECK_EARLY_ERROR_FILE_DEFAULT}
  local err=""
  if [[ -r $file ]]; then
    err=$(head -n 1 "$file" 2>/dev/null | tr ',' ';')
  fi
  printf '%s\n' "$err"
  return 0
}

deck_form_early_status_display() {
  local st err
  st=$(deck_form_early_status)
  if [[ $st == failed ]]; then
    err=$(deck_form_early_error)
    if [[ -n $err ]]; then
      printf 'failed: %s\n' "$err"
      return 0
    fi
  fi
  printf '%s\n' "$st"
  return 0
}

# deck_form_steam_status -- Steam's own record (Steam's slice owns the
# values: pending/running/done/incomplete/skipped/failed). Shown verbatim;
# a file that is missing or empty is "unknown" -- early has not reported
# yet -- not a failure.
deck_form_steam_status() {
  local file=${DECK_STEAM_STATUS_FILE:-$DECK_STEAM_STATUS_FILE_DEFAULT}
  local val=""
  if [[ -r $file ]]; then
    val=$(head -n 1 "$file" 2>/dev/null | tr ',' ';')
  fi
  [[ -n $val ]] || val=unknown
  printf '%s\n' "$val"
  return 0
}

deck_form_steam_error() {
  local file=${DECK_STEAM_ERROR_FILE:-$DECK_STEAM_ERROR_FILE_DEFAULT}
  local err=""
  if [[ -r $file ]]; then
    err=$(head -n 1 "$file" 2>/dev/null | tr ',' ';')
  fi
  printf '%s\n' "$err"
  return 0
}

deck_form_steam_status_display() {
  local st err
  st=$(deck_form_steam_status)
  case $st in
    failed|incomplete)
      err=$(deck_form_steam_error)
      if [[ -n $err ]]; then
        printf '%s: %s\n' "$st" "$err"
        return 0
      fi
      ;;
  esac
  printf '%s\n' "$st"
  return 0
}

# deck_form_steam_progress_line -- the last Valve progress/phase line written
# by the orchestrator's write_steam_progress (e.g. "downloading Steam's
# client update: 72,551 of 502,420 KB (14%)" or "Steam client bootstrap:
# ... (72s of 600s)"). Empty when nothing reported yet -- not a failure.
deck_form_steam_progress_line() {
  local file=${DECK_STEAM_PROGRESS_FILE:-$DECK_STEAM_PROGRESS_FILE_DEFAULT}
  local line=""
  if [[ -r $file ]]; then
    line=$(head -n 1 "$file" 2>/dev/null)
  fi
  printf '%s\n' "$line"
  return 0
}

# deck_form_early_phase -- C1's free-text phase word ("Preparing install
# target", "Installing Arch + Omarchy", ...). Empty when nothing yet.
deck_form_early_phase() {
  local file=${DECK_EARLY_PHASE_FILE:-$DECK_EARLY_PHASE_FILE_DEFAULT}
  local val=""
  if [[ -r $file ]]; then
    val=$(head -n 1 "$file" 2>/dev/null)
  fi
  printf '%s\n' "$val"
  return 0
}

# deck_form_parse_steam_progress <line> -- pure parser for Valve's numbers.
# Prints "done total" in KB (commas stripped), or returns 1 when the line
# carries no "X of Y KB" pair. Never crashes on unparseable input: the
# caller shows an indeterminate display instead.
deck_form_parse_steam_progress() {
  local line=${1:-} have_kb total_kb rest
  [[ $line =~ ([0-9][0-9,]*)" of "([0-9][0-9,]*" KB") ]] || return 1
  have_kb=${BASH_REMATCH[1]//,/}
  rest=${BASH_REMATCH[2]}
  total_kb=${rest% KB}
  total_kb=${total_kb//,/}
  [[ $have_kb =~ ^[0-9]+$ && $total_kb =~ ^[0-9]+$ ]] || return 1
  printf '%s %s\n' "$have_kb" "$total_kb"
  return 0
}

# deck_form_steam_percent <done-kb> <total-kb> -- integer 0-100, clamped.
# Zero total is indeterminate (prints empty, returns 1) rather than a crash.
deck_form_steam_percent() {
  local have_kb=${1:-} total_kb=${2:-} pct
  [[ $have_kb =~ ^[0-9]+$ && $total_kb =~ ^[0-9]+$ ]] || return 1
  (( total_kb > 0 )) || return 1
  pct=$(( have_kb * 100 / total_kb ))
  (( pct < 0 )) && pct=0
  (( pct > 100 )) && pct=100
  printf '%s\n' "$pct"
  return 0
}

# deck_form_steam_rate <done0> <t0> <done1> <t1> -- MB/s with two decimals,
# from successive KB readings and epoch seconds. Non-positive elapsed or
# non-numeric input is indeterminate (prints empty, returns 1), never a
# divide-by-zero. A backwards counter reads as 0.00, not negative.
deck_form_steam_rate() {
  local have0=${1:-} t0=${2:-} have1=${3:-} t1=${4:-}
  local dt dkb
  [[ $have0 =~ ^[0-9]+$ && $have1 =~ ^[0-9]+$ && $t0 =~ ^[0-9]+$ && $t1 =~ ^[0-9]+$ ]] || return 1
  dt=$(( t1 - t0 ))
  (( dt > 0 )) || return 1
  dkb=$(( have1 - have0 ))
  (( dkb < 0 )) && dkb=0
  awk -v kb="$dkb" -v dt="$dt" 'BEGIN { printf "%.2f", kb / 1024 / dt }'
  printf '\n'
  return 0
}

# deck_form_steam_eta <remaining-kb> <rate-mb-s> -- seconds left, floored.
# Empty/zero rate is indeterminate (returns 1): no ETA without motion.
deck_form_steam_eta() {
  local remaining=${1:-} rate=${2:-}
  [[ $remaining =~ ^[0-9]+$ ]] || return 1
  awk -v r="$remaining" -v rate="$rate" 'BEGIN { ok = (rate + 0 > 0); if (!ok) exit 1; printf "%d", (r / 1024) / rate }' || return 1
  printf '\n'
  return 0
}

# deck_form_format_eta <seconds> -- "MM:SS" (hours fold into minutes).
deck_form_format_eta() {
  local secs=${1:-}
  [[ $secs =~ ^[0-9]+$ ]] || return 1
  printf '%02d:%02d\n' $(( secs / 60 )) $(( secs % 60 ))
  return 0
}

# deck_form_format_mb <kb> -- "1,234.5 MB" style from integer KB.
deck_form_format_mb() {
  local kb=${1:-} whole frac grouped
  [[ $kb =~ ^[0-9]+$ ]] || return 1
  whole=$(( kb / 1024 ))
  frac=$(( (kb % 1024) * 10 / 1024 ))
  grouped=$(printf '%s' "$whole" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta')
  printf '%s.%s MB\n' "$grouped" "$frac"
  return 0
}

# ===========================================================================
# FAST-INSTALL four variants -- the preinstalls/gaming choice screens
# (docs/tasks/FAST-INSTALL.md C2/C5/C6). Read by Stages' early worker AFTER
# the common restore: the worker gates on `choices/locked`, never on these
# files appearing, so the screens below must never block the S0-A restore.
# ===========================================================================
#
# SHAPE OF THE FLOW (2026-09-24, revised per hardware feedback): S0 welcome,
# drive selection (NVMe/microSD, B back to welcome), wipe confirm (A wipes,
# B back to the list), early start on the CONFIRMED disk, preinstalls
# Yes/No, Steam Yes/No, Wi-Fi iff Steam=yes, Steam progress iff Steam=yes,
# identity, S5. B goes one screen back: Steam -> preinstalls; preinstalls B
# is a no-op redraw (the wipe already started -- there is no cancel that
# tells the truth any more, and B must never return to the confirm, the
# drive list, or S0). After BOTH answers the files plus `locked` are
# written atomically; preinstalls is then NOT revisable (the package
# delta may already be installing). Wi-Fi B is the narrow exception: it
# flips Steam yes->no (rewriting `gaming`, clearing any stale network-ready)
# before network-ready ever fired -- there is no path back to preinstalls
# from Wi-Fi. The progress screen's failure menu may also flip Steam to no,
# but only while the stage still allows it (see its own comment).
#
# DECK_CHOICES_DIR exists so the [U] suite and Stages' tests point this at a
# temp dir instead of /run. Values are lowercase yes/no + trailing newline.
readonly DECK_CHOICES_DIR_DEFAULT=/run/omarchy-deck/choices
readonly DECK_CHOICES_LOCKED_FILE=locked

deck_form_choices_dir() { printf '%s\n' "${DECK_CHOICES_DIR:-$DECK_CHOICES_DIR_DEFAULT}"; }

# deck_form_choice_write <name> <yes|no> -- atomic (mktemp in-dir + rename),
# 0644. Refuses anything but yes/no LOUDLY: a typo'd value the worker
# misreads as "no" would silently drop Gaming Mode.
deck_form_choice_write() {
  local name=$1 value=$2
  local dir tmp
  dir=$(deck_form_choices_dir)
  if [[ $value != yes && $value != no ]]; then
    deck_form_warn "refusing to write choice '$name' with non-yes/no value '$value'"
    return 1
  fi
  if ! mkdir -p "$dir" 2>/dev/null; then
    deck_form_warn "could not create choices dir $dir"
    return 1
  fi
  tmp=$(mktemp "$dir/.$name.XXXXXX") || { deck_form_warn "mktemp failed in $dir"; return 1; }
  printf '%s\n' "$value" >"$tmp" || { deck_form_warn "could not write $tmp"; rm -f "$tmp"; return 1; }
  chmod 644 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$dir/$name" || { deck_form_warn "could not publish $dir/$name"; rm -f "$tmp"; return 1; }
  return 0
}

# deck_form_choice_read <name> -- prints the value, or "unset" when absent.
# The S5 rows and the worker-gating logic share this: one spelling of
# "no answer yet", never two.
deck_form_choice_read() {
  local name=$1 val=""
  local dir
  dir=$(deck_form_choices_dir)
  if [[ -f $dir/$name ]]; then
    val=$(head -n 1 "$dir/$name" 2>/dev/null | tr -d '[:space:]')
  fi
  if [[ -z $val ]]; then val="unset"; fi
  printf '%s\n' "$val"
  return 0
}

# deck_form_choices_locked -- 0 iff the locked marker exists.
deck_form_choices_locked() {
  local dir
  dir=$(deck_form_choices_dir)
  [[ -f $dir/$DECK_CHOICES_LOCKED_FILE ]]
}

# deck_form_choices_lock -- publish the locked marker last (Stages gates on
# it). Atomic like the choices.
deck_form_choices_lock() {
  local dir tmp
  dir=$(deck_form_choices_dir)
  mkdir -p "$dir" 2>/dev/null || { deck_form_warn "could not create choices dir $dir"; return 1; }
  tmp=$(mktemp "$dir/.locked.XXXXXX") || { deck_form_warn "mktemp failed in $dir"; return 1; }
  printf 'locked\n' >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$dir/$DECK_CHOICES_LOCKED_FILE" || { rm -f "$tmp"; return 1; }
  return 0
}

# deck_form_yesno_screen <result-var> <title> <yes-line> <no-line> <default: yes|no>
# D-pad controller yes/no via `gum choose` rows "Yes"/"No" (gum confirm has
# no up/down list semantics on this hardware; choose rows do). Stores
# "yes", "no", or "back" (B/Esc cancel) in $result-var and returns 0.
# Never guesses: an unrecognised row redraws.
#
# The answer travels via printf -v, NOT stdout: this screen draws chrome
# (clear_logo/say/echo all write the terminal) and callers run screens for
# side effects -- capturing stdout swallows blank `echo` lines into the
# answer (measured: pre=$'\n\nno', which the atomic writer then loudly
# refuses). Same reason deck_form_offline_detect's own comment bans `v=$(...)`
# for globals.
deck_form_yesno_screen() {
  local resultvar=$1 title=$2 yes_line=$3 no_line=$4 default=$5
  local choice ans
  while true; do
    clear_logo
    echo
    say "$title"
    say --foreground 8 "$yes_line"
    say --foreground 8 "$no_line"
    say --foreground 8 "B goes back."
    if [[ $default == yes ]]; then
      choice=$(printf 'Yes\nNo\n' | gum choose --header "Choose" --selected Yes) || choice=""
    else
      choice=$(printf 'Yes\nNo\n' | gum choose --header "Choose" --selected No) || choice=""
    fi
    case $choice in
      Yes) ans=yes ;;
      No)  ans=no ;;
      "")  ans=back ;;
      *)   continue ;;
    esac
    printf -v "$resultvar" '%s' "$ans"
    return 0
  done
}

# deck_form_preinstalls_screen <result-var> -- stores yes/no/back. No carries the C6
# promise: both No choices say they can be installed later from the desktop
# (preinstalls via the existing menu action, Gaming via the conversion
# script Steam builds) -- backed by real actions, never a bare promise.
# The cursor starts on Yes (2026-09-24 hardware feedback).
deck_form_preinstalls_screen() {
  deck_form_yesno_screen "$1" \
    "Install Omarchy pre-installs?" \
    "Yes: office, media and creative apps are ready on first boot." \
    "No: skip them now. (Can be installed later from the Omarchy desktop.)" \
    yes
}

# deck_form_gaming_screen <result-var> -- the "Install Steam?" question.
# Yes installs Steam / Gaming Mode and requires Internet; No says it can
# be added later from the desktop (C6 conversion script). The stored value
# stays `gaming` yes/no: Stages gates on it, so the name does not change.
# The cursor starts on Yes (2026-09-24 hardware feedback).
deck_form_gaming_screen() {
  deck_form_yesno_screen "$1" \
    "Install Steam?" \
    "Yes: installs Steam and boots into Gaming Mode. (Requires Internet.)" \
    "No: desktop-only Omarchy. (Can be installed later from the Omarchy desktop.)" \
    yes
}

# deck_form_run_choice_screens -- preinstalls then Gaming, with B-back.
# Writes NOTHING until both are answered, then publishes preinstalls +
# gaming + locked atomically (locked LAST: Stages gates on it). Returns:
#   0 both answered and locked (globals DECK_PREINSTALLS/DECK_GAMING set)
#   1 only when publishing the answers fails (caller aborts)
# B on preinstalls -- the first screen AFTER the wipe started -- is a
# no-op that redraws the same screen (2026-09-24 hardware feedback). The
# old behaviour called deck_form_s0_cancel_menu, whose "The drive was not
# touched." is FALSE once the wipe has begun, and B must never return to
# the wipe confirm, the drive list, or S0 from here. B on Gaming returns
# to preinstalls.
# Globals (shellcheck: set here, read by summary/S5): DECK_PREINSTALLS,
# DECK_GAMING.
deck_form_run_choice_screens() {
  local pre="" game=""
  while true; do
    if [[ -z $pre ]]; then
      deck_form_preinstalls_screen pre
      if [[ $pre == back ]]; then
        pre=""
        continue
      fi
    fi
    deck_form_gaming_screen game
    if [[ $game == back ]]; then
      pre=""
      continue
    fi
    # shellcheck disable=SC2034
    DECK_PREINSTALLS=$pre
    # shellcheck disable=SC2034
    DECK_GAMING=$game
    deck_form_choice_write preinstalls "$pre" || return 1
    deck_form_choice_write gaming "$game" || return 1
    deck_form_choices_lock || return 1
    return 0
  done
}

# deck_form_choice_answer <name> -- the locked answer for `preinstalls` or
# `gaming`: the global first (it mirrors the file), the persisted file
# second. Prints "yes" or "no" and returns 0; returns 1 when neither has
# an answer (e.g. a dry run where greeter never ran the choice screens).
deck_form_choice_answer() {
  local name=$1 val=""
  case $name in
    preinstalls) val=${DECK_PREINSTALLS:-} ;;
    gaming)      val=${DECK_GAMING:-} ;;
    *)           deck_form_warn "unknown choice '$name'"; return 1 ;;
  esac
  if [[ -z $val ]]; then
    val=$(deck_form_choice_read "$name")
  fi
  if [[ $val != yes && $val != no ]]; then
    return 1
  fi
  printf '%s\n' "$val"
  return 0
}

# deck_form_readonly_screen <result-var> <title> <answer>
# One Deck question shown READ-ONLY (2026-09-24 hardware feedback, operator
# decision): the background install is already acting on the answer, so it
# is shown but cannot be changed. Same logo + title as the real screen so
# it is recognisably the same screen. Stores "forward" (A on Continue) or
# "back" (B/Esc) in $result-var and returns 0. Never guesses: an
# unrecognised row redraws.
deck_form_readonly_screen() {
  local resultvar=$1 title=$2 answer=$3
  local choice ans answer_word=No
  [[ $answer == yes ]] && answer_word=Yes
  while true; do
    clear_logo
    echo
    say "$title"
    say "Your answer: $answer_word -- already being installed, can't be changed now."
    say "Press A to continue, B to go back"
    choice=$(printf 'Continue\n' | gum choose --header "Choose") || choice=""
    case $choice in
      Continue) ans=forward ;;
      "")       ans=back ;;
      *)        continue ;;
    esac
    printf -v "$resultvar" '%s' "$ans"
    return 0
  done
}

# deck_form_readonly_choices -- walk the locked Deck questions backwards
# from the keyboard layout screen. One screen per B: Install Steam? first,
# then pre-installs; B on pre-installs stays there (nothing before it is
# reachable -- B must never return to the wipe confirm, the drive list, or
# S0 once the wipe has started). A moves forward one screen; A on the last
# one returns to the keyboard layout screen (returns 0).
deck_form_readonly_choices() {
  local screen=gaming answer nav title
  while true; do
    if [[ $screen == gaming ]]; then
      title="Install Steam?"
      answer=$(deck_form_choice_answer gaming) || return 1
    else
      title="Install Omarchy pre-installs?"
      answer=$(deck_form_choice_answer preinstalls) || return 1
    fi
    deck_form_readonly_screen nav "$title" "$answer"
    if [[ $screen == gaming ]]; then
      if [[ $nav == back ]]; then
        screen=preinstalls
      else
        return 0
      fi
    else
      if [[ $nav == forward ]]; then
        screen=gaming
      fi
    fi
  done
}

# greeter -- overrides upstream's own S0 screen.
#
# ⚠️ THE ONE LINE THIS FUNCTION MAY NOT DROP: `stty sane`. Upstream's own
# comment (READ, T4-screen-spec.md §4 S0) says its `tte` colour animation
# leaves the tty in raw/no-echo mode if killed mid-frame, which silently
# kills every gum prompt that follows unless something runs `stty sane`
# first. "Losing it is invisible until S1 refuses input" is the spec's own
# phrasing for exactly why this is worth a standalone, named, testable call
# rather than folding it into a bigger block where a future edit could trim
# it without noticing.
#
# DECK_S0_TTY is overridable so the unit suite never needs a real
# controlling terminal.
# ⚠️ THIS FUNCTION ALSO RUNS S1. See the S1 block's own "WHERE THIS SCREEN
# IS CALLED FROM" comment for the full argument -- the short version is that
# upstream has no Wi-Fi screen to override, §1.4's patch budget is already
# spent, §3 promotes Wi-Fi to first, and `greeter` is the earliest point in
# upstream's flow this file owns. It must stay BEFORE `keyboard_form`, which
# runs `loadkeys`.
greeter() {
  local tty=${DECK_S0_TTY:-/dev/tty}
  # P33 A3, and this is the EARLIEST point in upstream's flow this file owns
  # (see this function's own note above and S1's "WHERE THIS SCREEN IS CALLED
  # FROM"). Pinning the font here is what makes S0's disclosure text and S1's
  # network list legible too -- deck_form_text_prompt's copy only ever reaches
  # the text screens. Never gated: a small font is not a reason to skip a
  # screen.
  deck_form_pin_console_font
  deck_form_draw_s0
  deck_form_stty_sane "$tty"
  # S0's A/B answer: A proceeds to drive selection; B (Esc) is the safe
  # exit -- nothing erased yet. A bare read that accepts anything as
  # consent is how a typo becomes a wipe, so only these two bytes answer.
  # Drained first like the confirm (trivial here, same helper): S0 is not
  # destructive, but a stale Enter skipping the welcome is still a press
  # nobody made.
  local s0_answer drive_choice="" confirm_answer
  deck_form_drain_tty "$tty"
  if ! s0_answer=$(deck_form_s0_wait_key "$tty"); then
    abort "Could not read the S0 answer -- refusing to guess consent."
    return 1
  fi
  if [[ $s0_answer == cancel ]]; then
    deck_form_s0_cancel_menu
    abort "Install cancelled at the first screen."
    return 1
  fi
  # Drive selection (2026-09-24, revised per hardware feedback): NVMe and
  # microSD are both eligible; USB never is, and the boot medium is always
  # excluded. The screen always draws -- even with one entry -- so the user
  # sees what will be wiped. B here returns to the welcome screen (which
  # redraws S0 through deck_form_draw_s0, the same logo + text as the first
  # showing). Zero eligible is the dead end. After a drive is picked, the
  # wipe confirm asks again -- and the wipe starts ONLY on that A. B on the
  # confirm returns to the drive list. A failed start aborts before anything
  # else. The loop is: S0 -> drive list ⇄ confirm -> start early install.
  while true; do
    deck_form_drive_screen drive_choice || return 1
    if [[ $drive_choice == back ]]; then
      deck_form_draw_s0
      deck_form_stty_sane "$tty"
      deck_form_drain_tty "$tty"
      if ! s0_answer=$(deck_form_s0_wait_key "$tty"); then
        abort "Could not read the S0 answer -- refusing to guess consent."
        return 1
      fi
      if [[ $s0_answer == cancel ]]; then
        deck_form_s0_cancel_menu
        abort "Install cancelled at the first screen."
        return 1
      fi
      drive_choice=""
      continue
    fi
    if ! deck_form_wipe_confirm confirm_answer "$drive_choice" "$tty"; then
      abort "Could not read the wipe confirmation -- refusing to guess consent."
      return 1
    fi
    if [[ $confirm_answer == proceed ]]; then
      break
    fi
    drive_choice=""
  done
  deck_form_start_early_install "$drive_choice" || return 1
  # The two choice screens (preinstalls, then Steam/Gaming), with B-back
  # between them. Locked on completion: Stages gates on `choices/locked`.
  deck_form_run_choice_screens || return 1
  # Wi-Fi ONLY when Steam=yes (Stages skips its network gate entirely on
  # steam=no, so no marker is ever needed there). Steam=yes with no
  # connection keeps the network screen until connected, or B returns to
  # the Steam choice (flipping to no, clearing any stale marker state).
  if [[ ${DECK_GAMING:-no} == yes ]]; then
    deck_form_wifi_screen_gaming || return 1
    deck_form_steam_progress_screen || return 1
  fi
}
deck_form_stty_sane() {
  local tty=$1
  if ! stty sane <"$tty" 2>/dev/null; then
    deck_form_warn "could not reset $tty with 'stty sane' -- later prompts may misbehave (raw/no-echo tty), continuing anyway"
  fi
  return 0
}

# ===========================================================================
# S2b -- the keyboard layout  🔴 §5.20a: the installer typed the account
#        password under a keymap the on-screen keyboard does not draw
# ===========================================================================
#
# THE DEFECT, READ out of the pinned tree rather than inferred. Upstream's
# `keyboard_form` (configurator:189) ends:
#
#     if [[ $(tty 2>/dev/null) == "/dev/tty"* ]]; then
#       loadkeys "$keyboard" 2>/dev/null          # :225
#     fi
#
# and `user_form` (configurator:246) then runs `omarchy_prompt_username` and
# `omarchy_prompt_password` (:252-253) -- so every character of the ACCOUNT
# PASSWORD is typed after that `loadkeys`. Our OSK emits US keycodes; under a
# `latam` console keymap those keycodes are different characters. The
# password field is MASKED, so the substitution is invisible: the user sets a
# password they cannot reproduce, on a device with no physical keyboard, and
# finds out at the first lock screen -- which `docs/PROGRESS.md` §5.24
# already established is unanswerable without our OSK. Upstream's own comment
# at configurator:1015 states the intent this breaks for us ("the keyboard
# chosen above is already loaded, so the LUKS passphrase entered in the user
# step is typed under the right layout") -- correct for a machine with a
# keyboard, and load-bearing only for a LUKS passphrase we do not have
# (§3 deviation 4: encryption is off).
#
# ⚠️ The desktop fix does NOT reach here. Commit e8c3698 pins our virtual
# keyboard with a per-device Hyprland `kb_layout` rule. A bare console has no
# XKB and no per-device anything -- keycodes go through `loadkeys` and the
# kernel keymap -- so that rule is meaningless in the installer.
#
# ---------------------------------------------------------------------------
# WHAT THIS DOES INSTEAD, AND WHY IT IS NOT WHAT §3 DEVIATION 2 SAID
# ---------------------------------------------------------------------------
#
# TWO SETTINGS, NOT ONE. They have been conflated because upstream reads one
# variable for both:
#
#   (a) the LIVE console keymap, for the ~2 minutes the installer is on
#       screen. This is a MECHANISM, not a preference. Its only correct
#       value is the layout the OSK draws (DECK_CONSOLE_KEYMAP above),
#       because the OSK is the only thing typing.
#   (b) `$keyboard`, which upstream interpolates into the archinstall JSON as
#       `"kb_layout": "$keyboard"` (configurator:778 and :1164 -- READ). This
#       is a real PREFERENCE: it decides the INSTALLED system's keymap, and
#       on this project's own measurement it propagates further than the
#       console -- Omarchy's `default/hypr/input.lua` reads `kb_layout`
#       straight out of `/etc/vconsole.conf` (src/deck-session.sh's §5.20
#       block), which is how this Deck's desktop ended up on `latam`.
#
# So this override changes (a) and leaves (b) entirely alone. The user's pick
# still reaches archinstall, byte for byte.
#
# 🔴 §3 deviation 2 says instead: "`keyboard` becomes the constant `us`" --
# i.e. change (b) too, and drop the picker. NOT IMPLEMENTED, deliberately,
# and the spec is updated rather than quietly ignored. Three reasons:
#
#  1. It is the SESSION-WIDE shape the operator explicitly rejected the same
#     day, one layer up. e8c3698's own message: "PER DEVICE, per operator
#     decision: physical keyboards keep Latin American, and the suite FAILS
#     if every keyboard ends up on us while the session layout does not --
#     session-wide is a defect here, not a simpler version of the fix."
#     Hard-coding `kb_layout=us` is exactly that, moved earlier: it forces
#     every physical keyboard on the installed machine to US to protect a
#     password that is typed on the OSK.
#  2. Deviation 2's stated reasons both dissolve. "The OSK is US-only, so
#     `loadkeys` makes the drawn keys lie" is an argument against (a) only,
#     and (a) is fixed here. Its other reason -- upstream's own rationale for
#     the screen, the LUKS passphrase -- it already notes "evaporates when
#     encryption is off".
#  3. It is a silent lie in the artefact. A user who picked `latam` on a
#     screen upstream still draws would find `"kb_layout": "us"` written to
#     their machine, with nothing on screen saying so.
#
# WHAT IS NOT DONE HERE, and is a real residual risk: `omarchy_prompt_keyboard`
# is NOT overridden. Upstream's picker keeps running, unmodified. This repo
# does not vendor `setup-form.sh` (nothing here has its body; the S3
# reserved-username block records what that cost when it was guessed at
# instead of read), so its navigability on a
# controller is UNVERIFIED, and if it falls back to `gum filter`'s
# narrow-by-typing the way `omarchy_prompt_timezone` does (§3 deviation 3)
# it needs the same treatment. That is a [V] question against a real ISO and
# a new screen's worth of design; it is not this fix, and inventing a layout
# picker blind would be the guessing this file's header exists to forbid.

# deck_form_keyboard_status_action <status> <back> <signal> <allow-defer>
#
# The pure decision half of the loop below, split out so upstream's four
# outcomes are a truth table a unit test can drive rather than a shape only a
# real `gum` can reach. Prints exactly one of:
#   accept | reask | defer-offer | abort
#
# `OMARCHY_FORM_BACK` / `OMARCHY_FORM_SIGNAL` come from `setup-form.sh`,
# which this repo does not vendor, so they are passed in rather than read --
# and if they arrive empty or non-numeric the answer is `abort` WITH a
# warning, never a guess. Guessing `back` wrong would silently turn "the user
# pressed Esc" into "end the install", or worse, an unrecognised failure into
# an infinite re-ask.
deck_form_keyboard_status_action() {
  local status=$1 back=${2:-} signal=${3:-} allow_defer=${4:-false}

  if [[ ! $status =~ ^-?[0-9]+$ ]]; then
    deck_form_warn "keyboard prompt returned a non-numeric status '$status' -- treating it as a failure"
    printf 'abort\n'
    return 0
  fi
  ((status == 0)) && { printf 'accept\n'; return 0; }

  if [[ ! $back =~ ^-?[0-9]+$ || ! $signal =~ ^-?[0-9]+$ ]]; then
    deck_form_warn "OMARCHY_FORM_BACK/OMARCHY_FORM_SIGNAL are not usable numbers (back='$back' signal='$signal') -- setup-form.sh was not sourced, so Esc and Ctrl+C cannot be told apart from a real failure. Treating status $status as a failure."
    printf 'abort\n'
    return 0
  fi

  ((status == back)) && { printf 'reask\n'; return 0; }
  if [[ $allow_defer == true ]] && ((status == signal)); then
    printf 'defer-offer\n'
    return 0
  fi
  printf 'abort\n'
}

# keyboard_form [allow-defer-provisioning]
#
# Overrides `configurator`'s own (:206). The NAME is measured, not chosen:
# `configurator` calls `keyboard_form` bare (no `true` argument since the
# 4.0.0-stable rebase) at :1044 (top level), :288 (Esc unwind out of the
# user step) and :308 ("No, change it" on the recap). All three re-enter
# this function, which is why the fix cannot be "run the text screens
# earlier" -- there is no "earlier" that survives a re-edit.
#
# The loop mirrors upstream's structure deliberately, including the
# deferred-provisioning Ctrl+C path (unreachable on a Deck -- §2.2 item 1,
# there is no Ctrl -- but reachable on the `bin/omarchy-iso-configurator` dry
# run, and dropping it would be a silent feature removal, not a
# simplification). The ONE line that differs is the tail: upstream loads the
# user's chosen layout, and we pin the OSK's instead.
#
# Parity note: the defer path returns before the pin, exactly as upstream
# returns before its `loadkeys`. That path skips `user_form` entirely
# (configurator:992-1010 sets the account fields to empty constants), so
# nothing on it types anything.
keyboard_form() {
  local allow_defer_provisioning="${1:-false}"
  local status action

  while true; do
    clear_logo
    echo
    say "Let's setup your machine..."
    if [[ $allow_defer_provisioning == true ]]; then
      say --foreground 8 "Press Ctrl+C to prepare this machine for another owner."
    fi
    echo

    # Upstream's picker, untouched -- see this block's "WHAT IS NOT DONE
    # HERE". A missing `omarchy_prompt_keyboard` (setup-form.sh unsourced)
    # surfaces as status 127 and lands in `abort` below, loudly, rather than
    # as an install that silently never asked.
    omarchy_prompt_keyboard && status=0 || status=$?

    action=$(deck_form_keyboard_status_action \
               "$status" "${OMARCHY_FORM_BACK:-}" "${OMARCHY_FORM_SIGNAL:-}" \
               "$allow_defer_provisioning")
    case $action in
      accept) break ;;
      reask)
        # B on the keyboard layout screen walks back to the Deck questions
        # READ-ONLY (2026-09-24 hardware feedback, operator decision: the
        # background install is already acting on those answers, so they
        # are shown but cannot be changed). When the answers are empty --
        # e.g. a dry run where greeter never ran the choice screens -- keep
        # the old behaviour and re-ask the picker. A failed walk warns
        # loudly and falls back to re-asking, never stops the install
        # silently.
        if deck_form_choice_answer preinstalls >/dev/null 2>&1 &&
           deck_form_choice_answer gaming >/dev/null 2>&1; then
          deck_form_readonly_choices ||
            deck_form_warn "the read-only review of the Deck answers failed -- re-asking the keyboard layout instead of stopping"
        fi
        continue
        ;;
      defer-offer)
        if confirm_prepare_for_another_owner; then
          # shellcheck disable=SC2034  # read by configurator:991
          defer_provisioning=true
          return 0
        fi
        continue
        ;;
      *)
        deck_form_warn "the keyboard screen failed (status $status) -- ending the install rather than continuing with an unknown layout"
        abort
        return 1
        ;;
    esac
  done

  # 🔴 NOT `loadkeys "$keyboard"`. That is the whole defect. `$keyboard`
  # keeps the user's pick and travels on to `"kb_layout"`; the console gets
  # the layout the OSK draws.
  deck_form_pin_console_keymap || return 1
  return 0
}

# ===========================================================================
# S3 -- Account
# ===========================================================================

# Never prompted (§3 deviation 5 / §4 S4's model gate is a DIFFERENT
# concern; this is §4 S3's "never-prompted" hostname constant).
readonly DECK_HOSTNAME=steamdeck

# READ this session, T4-screen-spec.md §4 S3: upstream's own username
# pattern, quoted verbatim from setup-form.sh's validation.
readonly DECK_USERNAME_PATTERN='^[a-z_][a-z0-9_-]*[$]?$'

deck_form_username_valid() {
  [[ $1 =~ $DECK_USERNAME_PATTERN ]]
}

deck_form_password_nonblank() {
  [[ -n $1 ]]
}

deck_form_passwords_match() {
  [[ $1 == "$2" ]]
}

# --- the reserved-username list: SOURCED, never copied ---------------------
#
# T4-screen-spec.md §4 S3's own verified-by note: "the reserved/pattern
# predicates, sourced from upstream's own setup-form.sh constants rather
# than copied -- a copy would pass while upstream's list changed." §1.1
# item 2 confirms setup-form.sh is vendored into the LIVE ISO at
# /usr/share/omarchy-iso/setup-form.sh by builder/build-iso.sh, so on the
# real ISO this file CAN source it at runtime -- it just is not checked
# into THIS repo (nothing here vendors it), so it cannot be sourced during
# `source`-based unit testing either. Both are handled the same way: point
# at a fixture instead of the real path.
#
# ✅ READ, NOT INFERRED (2026-08-15, session 29). This block used to say the
# variable name below was "(INFERRED, NOT READ this session)" and to ask that
# it be verified "before this ships". IT SHIPPED UNVERIFIED, and the inference
# was wrong in two ways at once (docs/PROGRESS.md §5.34 D1): the name was not
# `RESERVED_USERNAMES`, and the value was not a bash array. Verified now
# against the real vendored file, at
# ~/.cache/omarchy-deck/p32-build/runtime-src/install/provisioning/setup-form.sh
# line 82 -- the exact file `iso/upstream/builder/build-iso.sh` copies to
# `/usr/share/omarchy-iso/setup-form.sh` (its `cp "$setup_form" ...`, and
# `$setup_form` is `install/provisioning/setup-form.sh` out of the omarchy
# source):
#
#     OMARCHY_RESERVED_USERNAMES='^(root|bin|daemon|mail|ftp|http|nobody|dbus|
#     systemd-coredump|...|sddm)$'
#
# A REGEX STRING, matched with `[[ $username =~ $OMARCHY_RESERVED_USERNAMES ]]`
# at that file's own line 111. So the old code's `declare -p` + nameref on an
# ARRAY failed for every input, `deck_form_username_reserved` returned 1
# always, and -- because this file replaces `omarchy_prompt_username` wholesale
# -- upstream's own check never ran either. Both checks were gone and `root`
# was an accepted username on the shipped ISO.
#
# ⚠️ WHY THIS STILL SOURCES INSTEAD OF COPYING THE 31 NAMES. Unchanged from
# T4-screen-spec.md §4 S3's own verified-by note: "sourced from upstream's own
# setup-form.sh constants rather than copied -- a copy would pass while
# upstream's list changed." The bug was the wrong NAME, not the sourcing.
# The degradation is still loud and still the point: a rename upstream warns
# and continues rather than silently validating against nothing, which is
# exactly the behaviour that made D1 findable at all.
readonly DECK_SETUP_FORM_SH=/usr/share/omarchy-iso/setup-form.sh
readonly DECK_RESERVED_USERNAMES_VAR=OMARCHY_RESERVED_USERNAMES
# The loaded regex, or empty when it could not be loaded. NOT an array: see
# above. Empty is a meaningful state and is handled explicitly in
# deck_form_username_reserved -- an empty regex matches EVERY string, so
# treating "unloaded" as "match against ''" would reject every username the
# user could possibly type.
DECK_LOADED_RESERVED_PATTERN=''

# deck_form_load_reserved_usernames
# Overridable via DECK_SETUP_FORM_SH_OVERRIDE for the unit suite.
#
# 🔴 THE ROOT CAUSE OF T4's BUG 1 (docs/findings/T4-controller-only-install-
# first-run.md §2, root-caused and fixed here). This function used to
# `source "$setup_form"` DIRECTLY into the caller's shell -- which, on the
# real ISO, is `configurator`'s own process, the SAME process deck-form.sh
# was itself sourced into. `$setup_form` (DECK_SETUP_FORM_SH, below) is
# `/usr/share/omarchy-iso/setup-form.sh` -- the EXACT file build-iso.sh
# vendors upstream's own copy to (READ, builder/build-iso.sh: `cp
# "$setup_form" "$build_cache_dir/airootfs/usr/share/omarchy-iso/setup-
# form.sh"`), and the exact file that ALREADY defines
# omarchy_prompt_identity/_hostname/_timezone/_username/_password/_keyboard
# -- the very names this file overrides. `source` redefines a function in
# whatever shell actually runs it, no matter how deep the call stack: the
# instant a user typed a single PATTERN-VALID username (so this function
# got called from inside `omarchy_prompt_username`'s loop), that `source`
# silently re-installed upstream's own prompt bodies over every one of
# deck-form.sh's overrides, for the rest of the install -- which is exactly
# why `omarchy_prompt_identity`/`_hostname`/`_timezone` (asked AFTER the
# username step) ran as upstream's unmodified screens on the real ISO,
# while `greeter` and `disk_form`/`confirm_disk_overwrite` (never downstream
# of this call) did not. Measured directly, not inferred: sourcing the real
# vendored setup-form.sh into a shell that had deck-form.sh's overrides
# loaded flips `declare -f omarchy_prompt_identity` from
# `deck_form_identity_body` to upstream's own body, in one call.
#
# THE FIX: never let `$setup_form` touch THIS shell's function table at all.
# `source` runs inside a `$( ... )` COMMAND SUBSTITUTION instead -- that is a
# genuine subshell (a forked copy of this process), so it starts with every
# function this file already defined, but any redefinition IT makes (every
# name setup-form.sh declares) is thrown away the instant the subshell exits.
# The only thing that crosses back out to the real shell is plain text on
# stdout: the reserved-username list, one name per line, captured with
# `mapfile`. No `eval`, and no function name from setup-form.sh is ever
# defined in this process again.
deck_form_load_reserved_usernames() {
  local setup_form=${DECK_SETUP_FORM_SH_OVERRIDE:-$DECK_SETUP_FORM_SH}
  DECK_LOADED_RESERVED_PATTERN=''
  if [[ ! -r $setup_form ]]; then
    deck_form_warn "cannot read $setup_form -- the reserved-username list is UNAVAILABLE this run (pattern validation still applies)"
    return 1
  fi
  local pattern_out rc=0
  pattern_out=$(
    # shellcheck disable=SC1090  # a runtime/fixture path, not knowable at lint time
    source "$setup_form" >/dev/null 2>&1
    # `-v` rather than `declare -p`: it answers "is this name SET" for a
    # scalar without also succeeding for a name that exists but is unset, and
    # without printing anything this subshell would then have to suppress.
    [[ -v $DECK_RESERVED_USERNAMES_VAR ]] || exit 1
    # Indirect expansion, not a nameref: `${!VAR}` is the plain-scalar read,
    # and the ONLY thing that crosses back out of this subshell is its text.
    # The subshell itself is T4 bug 1's fix and must not be undone -- see this
    # function's block comment above.
    printf '%s\n' "${!DECK_RESERVED_USERNAMES_VAR}"
  ) || rc=$?
  if ((rc != 0)); then
    deck_form_warn "sourced $setup_form but it defines no '$DECK_RESERVED_USERNAMES_VAR' -- the reserved-username list is UNAVAILABLE this run"
    return 1
  fi
  # An empty value is NOT a usable regex (it matches everything), so it is
  # treated as a failed load rather than quietly turned into "every username
  # is reserved". Upstream defining the name as the empty string is the same
  # class of event as upstream renaming it, and gets the same loud answer.
  if [[ -z $pattern_out ]]; then
    deck_form_warn "sourced $setup_form and '$DECK_RESERVED_USERNAMES_VAR' is EMPTY -- an empty pattern matches every name, so the reserved-username list is treated as UNAVAILABLE this run"
    return 1
  fi
  DECK_LOADED_RESERVED_PATTERN=$pattern_out
  return 0
}

# deck_form_username_reserved <name>
#
# 0 = reserved (refuse it), 1 = not reserved (or no list to check against).
#
# FAILS OPEN, deliberately and unchanged from the array version: with no
# pattern loaded nothing is reported reserved, because the alternative --
# rejecting names on a list we could not read -- would strand a user at a
# screen with no way forward and nothing true to tell them. The unreadable
# list has already been warned about loudly at the point it failed to load.
deck_form_username_reserved() {
  local name=$1
  [[ -n $DECK_LOADED_RESERVED_PATTERN ]] || return 1
  # UNQUOTED on the right of =~ on purpose: quoting it would make bash match
  # the pattern LITERALLY, which is upstream's own spelling at setup-form.sh
  # line 111 and the difference between "reject root" and "reject the literal
  # string ^(root|bin|...)$".
  [[ $name =~ $DECK_LOADED_RESERVED_PATTERN ]]
}

# --- the override functions themselves --------------------------------------
#
# ⚠️ (INFERRED, NOT READ this session): the exact global-variable contract
# each of these must satisfy to hand its answer to upstream's
# write_user_files (which variable name(s) it reads back out) was not
# available this session -- setup-form.sh's body was not in this repo to
# read. Below, each override sets a plausibly-named variable (matching the
# function's own subject) and ALSO prints its answer on stdout, so at least
# ONE integration path is real; wiring this to upstream's actual variable
# name is flagged here as unfinished, and is the single largest confidence
# gap in this file -- see this session's final report.

deck_form_username_body() { gum input --placeholder "Username" --prompt "Username> "; }
deck_form_password_body() { gum input --password --placeholder "Password" --prompt "Password> "; }
deck_form_confirm_body()  { gum input --password --placeholder "Confirm" --prompt "Confirm> "; }

# deck_form_account_notice <message>
#
# T4 bug 2 (docs/findings/T4-controller-only-install-first-run.md §5,
# MEASURED: 16/22/28/34 console rows across four failed username submits,
# growing by 6 every time, never settling). Root cause: every retry in
# omarchy_prompt_username/_password warned with a bare `deck_form_warn`
# (println to the console, never cleared) on top of `deck_form_text_prompt`'s
# OWN per-call warnings (mapper-not-found / OSK-timeout / keymap-pin-failed),
# so a user who mistyped a few times watched the screen grow without bound --
# on real hardware, eventually off the visible console entirely.
#
# Upstream's OWN retry loops (setup-form.sh's omarchy_prompt_username/
# _password, READ) never have this problem: every invalid attempt goes
# through configurator's `notice()`, and `notice()`'s FIRST line is
# `clear_logo` (READ, configurator:180-185) -- it wipes the screen before
# showing the new message, every time, so the screen is always exactly
# "logo + this attempt's one message", never "every attempt's messages
# stacked". This helper is that same repaint, adapted to `deck_form_warn`'s
# louder (CLAUDE.md-mandated, stderr, un-timed) style instead of upstream's
# timed `gum spin` notice -- the loudness is kept, the accumulation is not.
#
# Deliberately clears the screen even on the FIRST invalid attempt, which
# also wipes whatever header upstream's `user_form`/`step` drew before
# calling into this file (e.g. "Let's setup your user account..."). That is
# not a regression introduced here -- it is upstream's own behaviour:
# `notice()` unconditionally clears on every call, first attempt included,
# because upstream's own header is drawn by the SAME `step`/`clear_logo`
# mechanism and is expected to be repainted, not preserved, once a retry
# begins.
deck_form_account_notice() {
  clear_logo
  deck_form_warn "$1"
}

omarchy_prompt_username() {
  local candidate
  while true; do
    candidate=$(deck_form_text_prompt deck_form_username_body) || return 1
    if ! deck_form_username_valid "$candidate"; then
      deck_form_account_notice "'$candidate' is not a valid username (lowercase letters/digits/-/_, starting with a letter or _)"
      continue
    fi
    deck_form_load_reserved_usernames
    if deck_form_username_reserved "$candidate"; then
      deck_form_account_notice "'$candidate' is a reserved name -- choose another"
      continue
    fi
    # (INFERRED variable name, see this function's block comment above)
    # shellcheck disable=SC2034
    username=$candidate
    printf '%s\n' "$candidate"
    return 0
  done
}

omarchy_prompt_password() {
  local pw confirm
  while true; do
    pw=$(deck_form_text_prompt deck_form_password_body) || return 1
    if ! deck_form_password_nonblank "$pw"; then
      deck_form_account_notice "password cannot be blank"
      continue
    fi
    confirm=$(deck_form_text_prompt deck_form_confirm_body) || return 1
    if ! deck_form_passwords_match "$pw" "$confirm"; then
      deck_form_account_notice "passwords did not match -- try again"
      continue
    fi
    # 🔴 THE NAME IS `password`, AND IT IS MEASURED. Upstream's configurator
    # reads `$password` at four sites in the pinned iso/upstream tree:
    #   256  password_hash=$(printf '%s' "$password" | openssl passwd -6 -stdin)
    #   441  password_escaped=$(echo -n "$password" | jq -Rsa)
    #   698  printf "%s" "$password" | cryptsetup luksFormat ...
    #   699  printf "%s" "$password" | cryptsetup open ...
    # This was `user_password` for one session, a name configurator never
    # reads. `configurator` has no `set -u`, so nothing would have failed:
    # `openssl passwd -6` would have hashed the EMPTY STRING and produced a
    # valid hash for it, and the install would have finished green with a
    # PASSWORDLESS ACCOUNT. Nobody would find that until first login.
    # shellcheck disable=SC2034
    password=$pw
    return 0
  done
}

# The names are `omarchy_prompt_identity` and `omarchy_prompt_hostname`, and
# that is MEASURED, not chosen: upstream's own `configurator` calls them at
# lines 258-259 of `configs/airootfs/root/configurator` in the pinned
# `iso/upstream` tree.
#
# ⚠️ This was briefly written as `_identity` / `_hostname` too, on the reading
# that T4-screen-spec.md §1.1 and §4 S3 disagreed. They do not: §1.1 writes
# `omarchy_prompt_keyboard, _username, _password, _identity, ...` -- the
# prefix is ELIDED after the first entry, not replaced. Overriding a name
# upstream never calls is a screen that silently never appears, which is the
# whole failure mode T4 §6.4 is built around, so the aliases are gone rather
# than kept "just in case".
# Full name and email, as upstream's setup-form asks them (used for git;
# Enter skips either). Through deck_form_text_prompt, like the username, so
# the on-screen keyboard and controller work. These were stubbed to empty
# until 2026-09-24; the operator asked for them back on every install path.
deck_form_full_name_body() { gum input --placeholder "Used for git authentication (hit return to skip)" --prompt "Full name> "; }
deck_form_email_body() { gum input --placeholder "Used for git authentication (hit return to skip)" --prompt "Email address> "; }
deck_form_identity_body() {
  # (MEASURED global names: upstream's user_step recap reads $full_name /
  # $email_address at configurator:297-298 and write_user_files persists them
  # at :443-444 -- asserted in test/unit/test-deck-form.sh, not inferred.)
  # shellcheck disable=SC2034
  full_name=$(deck_form_text_prompt deck_form_full_name_body) || return $?
  # shellcheck disable=SC2034
  email_address=$(deck_form_text_prompt deck_form_email_body) || return $?
}
omarchy_prompt_identity() { deck_form_identity_body; }

deck_form_hostname_body() {
  # MEASURED, same as the password above: configurator reads `$hostname` at
  # lines 283, 768 and 1154. `hostname_value` was read by nothing, and would
  # have produced `"hostname": ""` in the archinstall JSON, silently.
  # shellcheck disable=SC2034
  hostname=$DECK_HOSTNAME
  printf '%s\n' "$DECK_HOSTNAME"
}
omarchy_prompt_hostname() { deck_form_hostname_body; }

# ===========================================================================
# S1 -- Wi-Fi  🔴 "the hardest screen in the flow" (T4-screen-spec.md §4 S1)
# ===========================================================================
#
# WHERE THIS SCREEN IS CALLED FROM, AND WHY IT IS NOT ITS OWN PATCH HUNK.
# Upstream has NO Wi-Fi screen at all -- `build-iso.sh`'s own comment is
# "The install is entirely offline and the live environment needs no Wi-Fi
# driver" -- so there is no upstream function name to override, and the
# override-name contract (test/unit/test-deck-form.sh) would correctly
# reject a bare `deck_wifi_screen` as a name `configurator` never calls.
#
# §3's screen table says Wi-Fi is "KEPT and promoted to first". Upstream's
# top-level flow is, verbatim (configurator lines ~985-1000):
#
#     wait_for_stable_terminal
#     greeter                 <-- S0, ALREADY ours
#     keyboard_form true
#     ... user_step / disk_form / select_installation
#
# So the first point in that flow we already own is `greeter`, and S1 hangs
# off the end of it. Three reasons that is the right seam and not a hack:
#
#  1. It costs ZERO extra patch hunks. §1.4's budget is two, both spent
#     (the `source` line and `deck_final_summary || abort`). A third hunk
#     to call S1 would be a spec change, and §1.4's own note prefers
#     legible seams over clever ones -- but it prefers NO new seam most.
#  2. S1 must run before S2, because S2's one-press timezone default comes
#     from `tzupdate -p`, which needs the network (§3 deviation 3). Anything
#     later than `greeter` and the geo-guess is dead.
#  3. 🔴 It runs BEFORE `keyboard_form`, and that is load-bearing rather
#     than incidental: `keyboard_form` ends by running `loadkeys` (READ,
#     configurator line ~228). §2.2 item 4's hazard is that the OSK emits
#     US keycodes while the console applies whatever keymap `loadkeys` last
#     set -- so a passphrase typed AFTER `keyboard_form` under a non-US
#     keymap would be silently mistyped, on the one screen where a single
#     wrong character is indistinguishable from a wrong password. Running
#     S1 before any `loadkeys` means the passphrase is always typed under
#     the boot default, which is the layout the OSK actually draws.
#
# ===========================================================================
# 🔴 THE CONNECTION IS REQUIRED. OPERATOR DECISION, 2026-08-16, AND THE
#    "Skip -- set up Wi-Fi later" ROW IS GONE.
# ===========================================================================
#
# The operator, verbatim: "There should be no 'Skip -- set up Wi-Fi later'
# option at all. Instead, where the installer says 'Wi-Fi' we should write:
# Wi-Fi / (something like) An internet connection is required during install."
#
# WHY THE ROW WAS A DEFECT AND NOT A COURTESY. `steam` is the only entry left
# in configs/deck/deck-fetch.packages, and it stays online on Steam Subscriber
# Agreement grounds. A Deck that finishes an install with no Steam boots
# gamescope with nothing to display -- measured on hardware,
# docs/findings/P32-steam-never-installed.md: "identical to a dead one --
# black, no messages, not even a cursor." The previous round put a warning in
# front of the row. A warning in front of a trapdoor is still a trapdoor; it
# only means the user falls through it having read more.
#
# REMOVING THE ROW IS ONE THIRD OF THE CHANGE. On its own it would turn a bad
# choice into a trap, which is worse. The other two thirds:
#
#  1. THE SCREEN STATES THE REQUIREMENT AND THE REASON, above the list
#     (deck_form_wifi_required_text). A requirement nobody explained reads as
#     a wall; the reason is what makes it a requirement.
#  2. A DECK THAT ALREADY HAS A CONNECTION IS NEVER STOPPED HERE AT ALL --
#     see deck_form_wifi_screen's own first block. The question this screen
#     asks the MACHINE is "is there a network?", never "did you configure the
#     radio?" (orchestrator/deck_pkgs.py DECISION 2).
#  3. THE DEAD END IS A SCREEN, NOT A LOOP (deck_form_net_dead_end). A Deck
#     that genuinely cannot reach a network cannot install -- that IS the
#     intended outcome now -- but it is said in words, on a screen with
#     somewhere to go, rather than left as a list that silently will not
#     advance.
#
# ⚠️ WHAT DID NOT CHANGE, AND MUST NOT: A MACHINE WITH NO WI-FI HARDWARE IS
# NOT A USER DECLINING WI-FI. The no-radio and dead-iwd paths still state the
# consequence and continue, keypress-free -- see deck_form_offline_note's own
# block for the QEMU argument, which is unchanged and still load-bearing.
#
# S1 STILL NEVER FAILS THE INSTALL FROM A PATH A USER CAN REACH: every branch
# ends in `return 0` from deck_form_wifi_screen, so `greeter` ignores its
# status -- but logs it, so a nonzero return is visible rather than swallowed.
# The dead end does not "return"; it either reboots, powers off, or goes back
# to the list.

readonly DECK_NET_RESCAN_ROW="Rescan"

# The list's last row. It does NOT skip anything -- it opens the dead-end
# screen, which explains and offers Reboot / Power off / back to the list.
# Named as a stop rather than as a skip on purpose: "Skip" promised an install
# that would still work, and that promise was the defect.
readonly DECK_NET_STOP_ROW="Stop the install"

# Gaming-gate back row. Shown ONLY when the Wi-Fi screen runs inside the
# Gaming=yes gate (deck_form_wifi_screen_gaming sets DECK_WIFI_GAMING_GATE=1):
# B-on-list in the old shape redrew, which is correct for a mandatory
# network -- but Gaming B must be able to reach the Gaming choice to flip
# yes->no (four-variant flow). The row is explicit (never the Esc fallback:
# Esc still redraws, per deck_form_net_choice_action's rule) and returns to
# the Gaming question; the reversal rewrites `gaming` to no and clears any
# stale marker BEFORE network-ready ever fired.
readonly DECK_NET_GAMING_BACK_ROW="Back to Gaming choice"

# What marks a secured network in the list.
#
# 🔴 THIS WAS U+1F512 🔒 AND THE CONSOLE CANNOT DRAW IT. Confirmed by looking
# at the screen: docs/images/install-02-wifi.png, captured from the shipping
# ISO, shows a solid box in front of every secured SSID. The Linux console font
# has no glyph for an astral-plane emoji and substitutes the missing-character
# box, so the row said "there is something here" and nothing more. It still
# distinguished secured from open, which is exactly why it survived -- every
# test asserted the BYTES were present, and the bytes were present. None of
# them could see that the pixels were a box.
#
# ASCII, deliberately: this list is drawn on a bare tty by the installer,
# before any font or locale work the installed system might do. A marker that
# depends on the console font being anything in particular is the bug again.
#
# Open networks carry no marker. The asymmetry is the point -- the eye is
# meant to catch the ones that will ask for a password.
readonly DECK_NET_SECURED_GLYPH='* '

# Where a wireless interface is DETECTED. §5's own detection column says
# "`ip -br link` has no wireless device" -- ⚠️ that is not something
# `ip -br link` can answer: it prints NAME/STATE/MAC/flags and says nothing
# about whether a link is wireless (a Deck's `wlan0` and a USB `enp0s20u1`
# are indistinguishable in that output, and the name `wlan0` is a udev
# convention, not a guarantee). The kernel's own answer is the presence of
# a `wireless` subdirectory under the interface in sysfs, which is exactly
# what `iw`/`iwd` themselves key off. Detecting by NAME PATTERN would be
# the same class of mistake §3 deviation 5 already caught for the microSD
# ("by lsblk -dno RM, not by name").
readonly DECK_NET_SYSFS_DEFAULT=/sys/class/net

# §5: "Bounded at 3 tries, then back to the network list, so nobody is
# stuck in a loop they cannot escape."
readonly DECK_NET_MAX_PASSPHRASE_TRIES=3
# §5: "empty get-networks after two tries".
readonly DECK_NET_SCAN_TRIES=2
readonly DECK_NET_SCAN_SETTLE=2        # seconds for the scan to populate
# §5: "wlan0 has no address after 20 s".
readonly DECK_NET_DHCP_DEADLINE=20
readonly DECK_NET_DHCP_POLL=1

# Captive-portal probe. NetworkManager's own connectivity endpoint and its
# own expected body, chosen so the installed system and the installer agree
# about what "online" means. ⚠️ (INFERRED, NOT MEASURED) that `curl` exists
# in the live environment -- §2.4's table does not list it. A missing curl
# is handled as "cannot check", stated on screen, never as "online".
readonly DECK_NET_PORTAL_URL="http://ping.archlinux.org/nm-check.txt"
readonly DECK_NET_PORTAL_EXPECT="NetworkManager is online"

# The live-side artefact directory. /root is where upstream's own
# `write_user_files` puts user_configuration.json / user_credentials.json,
# so a consumer that already knows where to find those knows where to find
# ours. Nothing here is written to the TARGET -- see the U1 block below.
readonly DECK_NET_STATE_DIR_DEFAULT=/root
readonly DECK_NET_STAGED_NMCONNECTION=deck-wifi.nmconnection
readonly DECK_NET_OUTCOME_FILE=deck-wifi-outcome

# 🔴 DELETED 2026-08-16: DECK_NET_OFFLINE_CONFIRM_DEFAULT, and the
# `gum confirm --affirmative "Install anyway, with no Steam"` it aimed. It was
# the safe cursor on a question that is no longer asked, because the answer it
# defended against is no longer offered (see the block at the top of S1). Left
# in place it would have been a constant nothing reads, next to a comment
# describing a screen that does not exist -- this project treats dead code and
# false comments as the same defect class (docs/PROGRESS.md §5.33b).

deck_form_strip_ansi() {
  # ESC [ ... <letter> -- the CSI form iwctl's own colouring uses.
  sed -E $'s/\x1b\\[[0-9;]*[A-Za-z]//g'
}

deck_form_trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

# deck_form_col_index <line> <needle>
# Byte offset of NEEDLE's first occurrence in LINE, or nothing (status 1)
# if absent. Used to find column boundaries from the HEADER row itself,
# because splitting a data row on whitespace would corrupt an SSID that
# contains a space -- a real, common case, not a hypothetical one.
deck_form_col_index() {
  local haystack=$1 needle=$2
  local prefix=${haystack%%"$needle"*}
  [[ $prefix == "$haystack" ]] && return 1
  printf '%s' "${#prefix}"
}

# deck_form_sanitize_ssid <raw-ssid>
#
# T4-screen-spec.md §4 S1's own framing: a hostile SSID is attacker-
# controlled text about to be drawn on a ROOT console -- treat it as data,
# not as trusted display text. Three concrete hazards, one pass:
#   - a control byte (0x00-0x1F, 0x7F) could be an ANSI escape that
#     repaints the menu, a CR/LF that injects a fake extra row, or a tab
#     that corrupts THIS FILE'S OWN TAB-separated internal encoding
#   - a literal '|' could be misread as a row delimiter by a naive caller
# Both are replaced with '?', one-for-one, rather than dropped: deleting
# the SSID entirely would let an attacker's network silently disappear a
# REAL one from the list by taking its row. LC_ALL=C throughout -- this is
# a security boundary, not a display nicety, and must not depend on the
# locale grep/tr happen to be running under (the same reasoning
# test/lib/vm-installer-screens.sh's own header documents for its own
# byte-safety choices).
deck_form_sanitize_ssid() {
  local ssid=$1
  LC_ALL=C printf '%s' "$ssid" | LC_ALL=C tr -d '\000-\037\177' | LC_ALL=C tr '|' '?'
}

# deck_form_parse_iwctl_networks <raw-text-file>
#
# Parses `iwctl station wlan0 get-networks` output into
# "ssid<TAB>security<TAB>signal" lines (ANSI stripped). Column boundaries
# come from the HEADER ROW's own label positions, not from splitting on
# whitespace, for the same SSID-with-spaces reason deck_form_col_index's
# comment gives.
#
# ⚠️ (INFERRED, NOT READ this session): iwctl's exact column layout and
# row-count-below-the-header. Based on iwd's documented `station
# get-networks` table shape (three columns: Network name / Security /
# Signal, an optional leading '>' marking the currently-connected network,
# a single '---' rule line between the header and the data). NOT
# re-derived from a live capture -- confirm against a real Deck's `iwctl`
# before this ships. The fixture in test/unit/test-deck-form.sh encodes
# this exact assumption and would need updating alongside it.
deck_form_parse_iwctl_networks() {
  local raw=$1
  local clean header_line header_text sec_col sig_col data_start
  clean=$(deck_form_strip_ansi <"$raw")

  header_line=$(printf '%s\n' "$clean" | LC_ALL=C command grep -n 'Network name' | head -1 | cut -d: -f1)
  if [[ -z $header_line ]]; then
    deck_form_warn "no 'Network name' header found in iwctl output -- cannot parse"
    return 1
  fi
  header_text=$(printf '%s\n' "$clean" | sed -n "${header_line}p")
  sec_col=$(deck_form_col_index "$header_text" "Security") ||
    { deck_form_warn "no 'Security' column found in iwctl output"; return 1; }
  sig_col=$(deck_form_col_index "$header_text" "Signal") ||
    { deck_form_warn "no 'Signal' column found in iwctl output"; return 1; }

  data_start=$((header_line + 2))
  local line ssid security signal
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    LC_ALL=C command grep -qE '^-+$' <<<"$line" && continue
    # The connected-network marker replaces column 0 with '>' but does NOT
    # shorten the line (iwctl keeps every row the same width as the
    # header). Substituting it back to a space -- not stripping it with
    # `${line#>}` -- is load-bearing: stripping removes a BYTE, shifting
    # every column boundary computed from the header left by one for this
    # row only. Found by running this exact parser against a fixture
    # containing a connected row: the Security/Signal split landed one
    # character early, ONLY on that row.
    local body=$line
    [[ ${body:0:1} == ">" ]] && body=" ${body:1}"
    ssid=$(deck_form_trim "${body:0:sec_col}")
    security=$(deck_form_trim "${body:sec_col:$((sig_col - sec_col))}")
    signal=$(deck_form_trim "${body:sig_col}")
    [[ -n $ssid ]] || continue
    printf '%s\t%s\t%s\n' "$ssid" "$security" "$signal"
  done < <(printf '%s\n' "$clean" | tail -n "+$data_start")
}

# deck_form_build_network_rows <parsed-networks-file>
#
# PARSED-NETWORKS-FILE is deck_form_parse_iwctl_networks's own output
# format. Produces the rows gum choose shows: one per network (sanitized
# SSID, a lock glyph for anything not 'open'), then Rescan, then Stop.
#
# 🔴 THE ROW ORDER CHANGED WITH THE SKIP ROW'S REMOVAL (2026-08-16).
# T4-screen-spec.md §4 S1's literal order was "a literal final row
# Skip -- set up Wi-Fi later and Rescan"; the spec is superseded here by the
# operator's decision, not ignored. Rescan is now the row directly under the
# networks because it is the ACTION THAT LEADS SOMEWHERE -- plugging in a dock
# or moving closer and rescanning is the whole recovery -- and Stop is last
# because it is the only row that does not continue the install.
deck_form_build_network_rows() {
  local parsed=$1
  local ssid security signal safe_ssid glyph
  while IFS=$'\t' read -r ssid security signal; do
    [[ -n $ssid ]] || continue
    safe_ssid=$(deck_form_sanitize_ssid "$ssid")
    if [[ $security == open ]]; then glyph=""; else glyph=$DECK_NET_SECURED_GLYPH; fi
    printf '%s%s\n' "$glyph" "$safe_ssid"
  done <"$parsed"
  # Gaming-gate back row FIRST of the fixed rows (above Rescan): it is the
  # way out of a mandatory network, so it must read before the recovery
  # action, not after Stop. Plain lists (no gate) are byte-identical to
  # before -- existing row-order tests pin that.
  if [[ ${DECK_WIFI_GAMING_GATE:-} == 1 ]]; then
    printf '%s\n' "$DECK_NET_GAMING_BACK_ROW"
  fi
  printf '%s\n' "$DECK_NET_RESCAN_ROW"
  printf '%s\n' "$DECK_NET_STOP_ROW"
}

# --- S1: from a chosen ROW back to the real network -------------------------
#
# 🔴 THE SUBTLETY THAT MAKES THIS TWO FUNCTIONS INSTEAD OF A `sed`.
# `gum choose` hands back the DISPLAYED row, and the displayed row is the
# SANITISED SSID plus possibly a lock glyph. Recovering the SSID by string
# surgery on that row would hand `iwctl connect` the sanitised text -- i.e.
# for any SSID that actually needed sanitising, we would try to join a
# network whose name does not exist, and the user would see "that didn't
# work" forever with no clue why. So the row is mapped back by POSITION:
# build_network_rows emits exactly one row per parsed line, in order, so
# row N is parsed line N, and the RAW bytes come from the parsed file.
#
# ⚠️ Stated limitation, not a silent one: two networks whose sanitised
# display collapses to the same string are indistinguishable in the list,
# and the FIRST is chosen. iwctl orders get-networks by signal, so the
# first is the stronger one -- an attacker who names their network to
# collide with a real one must also out-signal it to be picked. There is no
# fix that keeps the list honest (appending a disambiguator would let a
# hostile SSID choose what the real network's row looks like).
deck_form_row_index() {
  local rows_file=$1 choice=$2 idx
  idx=$(LC_ALL=C command grep -nxF -- "$choice" "$rows_file" 2>/dev/null | head -1 | cut -d: -f1)
  if [[ -z $idx ]]; then
    deck_form_warn "the chosen row is not in the list that was drawn -- refusing to guess which network was meant"
    return 1
  fi
  printf '%s\n' "$idx"
}

# deck_form_network_at <parsed-file> <1-based-index>
# The raw "ssid<TAB>security<TAB>signal" line, unsanitised, or a reported
# failure. Never prints a partial line and never prints nothing on success.
deck_form_network_at() {
  local parsed=$1 idx=$2 line
  if [[ ! $idx =~ ^[0-9]+$ ]] || [[ $idx -lt 1 ]]; then
    deck_form_warn "network index '$idx' is not a positive integer"
    return 1
  fi
  line=$(sed -n "${idx}p" "$parsed" 2>/dev/null)
  if [[ -z $line ]]; then
    deck_form_warn "no network at row $idx -- the list and the scan disagree, which means the scan changed under the menu"
    return 1
  fi
  printf '%s\n' "$line"
}

# deck_form_net_choice_action <gum-choose-output-or-empty>
#
# S8's lesson applied before S1 can repeat it: upstream's failure menu made
# Esc SELECT an action ("Drop to shell") via `|| choice=...`, so the one
# gesture a controller-only user reaches for became the most destructive
# one. Here an empty choice -- B/Esc, or gum exiting nonzero for any other
deck_form_net_choice_action() {
  local choice=$1
  case $choice in
    "")                        printf 'redraw\n' ;;
    "$DECK_NET_STOP_ROW")      printf 'stop\n' ;;
    "$DECK_NET_RESCAN_ROW")    printf 'rescan\n' ;;
    "$DECK_NET_GAMING_BACK_ROW") printf 'gaming-back\n' ;;
    *)                         printf 'connect\n' ;;
  esac
}

# deck_form_net_security_class <iwctl-security-field>
#
# open        -> none          join with no passphrase
# psk / wep   -> passphrase    the S1 text-entry path
# anything    -> unsupported   8021x (WPA-Enterprise) needs a certificate,
#                              an identity and usually a CA bundle -- none
#                              of which this screen can collect, and NONE
#                              of which a passphrase prompt would obtain.
#                              Offering the prompt anyway would produce
#                              three guaranteed-failing tries and a user
#                              who thinks they mistyped. Say so instead.
# The default arm is `unsupported`, not `passphrase`, on purpose: a
# security type iwd grows in a future release is something we have not
# tested, and §CLAUDE.md's rule is not to claim support that was never
# tested.
deck_form_net_security_class() {
  local security=$1
  case $security in
    open)     printf 'none\n' ;;
    psk|wep)  printf 'passphrase\n' ;;
    *)        printf 'unsupported\n' ;;
  esac
}

# deck_form_wifi_iface [<sysfs-net-root>]
# First interface with a `wireless` subdirectory. Glob order is bash's own
# sort, so this is deterministic across runs rather than "whatever readdir
# said". A machine with no wireless interface is a REPORTED condition
# (return 1), which §5's first row turns into "No Wi-Fi hardware found --
# continuing offline" -- and which is also every QEMU run, so it must not
# block.
deck_form_wifi_iface() {
  local root=${1:-${DECK_NET_SYSFS:-$DECK_NET_SYSFS_DEFAULT}}
  local dir
  for dir in "$root"/*; do
    [[ -d $dir/wireless ]] || continue
    printf '%s\n' "${dir##*/}"
    return 0
  done
  deck_form_warn "no wireless interface under $root (no directory has a 'wireless' subdirectory)"
  return 1
}

# deck_form_has_ipv4 <ip--4--br-addr-output>
#
# §5: "Associated, no DHCP ... This is the case a naive 'did connect exit 0'
# check calls success." 🔴 A link-local 169.254.0.0/16 address is what the
# kernel/networkd hands out when DHCP FAILED, so counting it as an address
# would reintroduce exactly the false success this row exists to catch --
# the check would go green on the one outcome it was written to detect.
# 127.0.0.0/8 is excluded for the same reason (a loopback address is never
# evidence that a wireless link got configured).
deck_form_has_ipv4() {
  local text=$1 addr
  while IFS= read -r addr; do
    [[ -n $addr ]] || continue
    [[ $addr == 169.254.* ]] && continue
    [[ $addr == 127.* ]] && continue
    return 0
  done < <(LC_ALL=C printf '%s\n' "$text" |
             LC_ALL=C command grep -oE '(^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}' |
             LC_ALL=C command grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')
  return 1
}

# deck_form_connect_verdict <iwctl-exit-status> <iwctl-output>
#
# ⚠️ Belt AND braces, deliberately. §5's detection column says "iwctl …
# connect non-zero", and that is the primary signal -- but iwctl is an
# interactive-first tool that has been observed to print a failure and
# still exit 0 in non-interactive use, and this file cannot verify which
# behaviour the pinned iwd has without a Deck. Trusting only the exit
# status would turn a wrong passphrase into "connected", and then into a
# DHCP timeout twenty seconds later with the wrong message on screen.
# ⚠️ (INFERRED, NOT MEASURED): the exact strings below are iwctl's usual
# error vocabulary, not a live capture. Confirm against a real Deck. Being
# wrong here is SAFE IN ONE DIRECTION ONLY -- a missed string degrades to
# the exit-status check plus the DHCP gate, while a false match would
# report failure on a working join, so nothing generic ("error", "fail")
# is matched.
deck_form_connect_verdict() {
  local status=$1 output=$2
  if [[ $status != 0 ]]; then
    printf 'failed\n'
    return 0
  fi
  case $output in
    *"Operation failed"*|*"Invalid arguments"*|*"Not connected"*|\
    *"Network not found"*|*"Timed out"*|*"Invalid passphrase"*|*"Invalid format"*)
      printf 'failed\n' ;;
    *)
      printf 'ok\n' ;;
  esac
}

# deck_form_portal_verdict <probe-exit-status> <probe-body>
#
# §5: "Captive portal | HTTP probe returns a redirect | State plainly that
# this network needs a browser and cannot be used during install ... Do not
# attempt to render a portal."
#
# Three outcomes, not two. `unreachable` is separate from `portal` because
# they need different sentences: a portal is a network the user could fix
# by using a phone, while an unreachable probe on an associated link is
# usually DNS or an upstream outage, and telling someone to open a browser
# they do not need is worse than saying the check could not be made. An
# unreachable probe is NOT treated as a hard failure -- the association and
# the DHCP lease both succeeded, so the install proceeds and the fetch
# either works or degrades where it happens.
deck_form_portal_verdict() {
  local status=$1 body=$2
  if [[ $status != 0 ]]; then
    printf 'unreachable\n'
    return 0
  fi
  case $body in
    *"$DECK_NET_PORTAL_EXPECT"*) printf 'online\n' ;;
    *)                           printf 'portal\n' ;;
  esac
}

# deck_form_net_failure_action_for <gum-choose-output-or-empty>
# The post-association failure menu (§5's DHCP row: "offer Retry / Pick
# another / Skip"). Same cancel discipline as
# deck_form_net_choice_action: empty redraws, never acts.
#
# 🔴 THE SKIP ENTRY IS GONE FROM HERE TOO (2026-08-16), and that is not
# tidiness. It was the SECOND way out of S1 without a network -- the one the
# old offline gate's own comment called "the other way a user leaves S1
# without Wi-Fi", and a rule enforced on one of two doors is not a rule. Both
# remaining answers lead back to a screen that can still succeed; the only way
# to leave S1 without a connection is now the dead end, which says so.
readonly -a DECK_NET_FAILURE_ITEMS=("Try again" "Pick another network")
deck_form_net_failure_items() {
  printf '%s\n' "${DECK_NET_FAILURE_ITEMS[@]}"
}
deck_form_net_failure_action_for() {
  local choice=$1
  case $choice in
    "")                       printf 'redraw\n' ;;
    "Try again")              printf 'retry\n' ;;
    "Pick another network")   printf 'another\n' ;;
    *)                        printf 'redraw\n' ;;
  esac
}

# ===========================================================================
# §5's consequence text, and the gate in front of it (P33 L1)
# ===========================================================================
#
# 🔴 WHAT CHANGED, 2026-08-16, AND WHY THE OLD TEXT WAS A DEFECT IN ITSELF.
# It read:
#
#   "Without a network the install still completes, but the audio DSP firmware
#    and Steam are not downloaded. Speakers will sound thin and Gaming Mode
#    will have no Steam until the Deck is connected."
#
# Two things wrong with that, both measured rather than argued:
#
#  1. THE DSP HALF IS NO LONGER TRUE. `steamdeck-dsp` was moved out of
#     configs/deck/deck-fetch.packages into deck-mirror.packages +
#     deck-install.packages on 2026-08-15 (operator decision; read this
#     session out of deck-fetch.packages' own ⚠️ note and confirmed present in
#     both other lists). It now rides in the OFFLINE MIRROR, so an offline
#     install gets it and the speakers are fine. `steam` is the only entry
#     left in the fetch list, and it stays online on Steam Subscriber
#     Agreement grounds, which is not negotiable.
#     ✅ FIXED 2026-08-16. DECK_S0_LINES carried the identical stale claim
#     ("Steam and the audio DSP firmware are downloaded from Valve during
#     setup") and could not be corrected in the same pass, because
#     test/vm/vm-installer-screens-test.sh asserted that sentence VERBATIM and
#     the two files had different owners -- a test pinning user-facing prose in
#     place is how the lie survived a month. Both were changed together in
#     105523c; the screen now says "Steam is downloaded from Valve during
#     setup; everything else is already on this USB stick."
#
#  2. "Gaming Mode will have no Steam" MASSIVELY understates the outcome.
#     docs/findings/P32-steam-never-installed.md, on hardware: with no Steam,
#     gamescope starts with nothing to display and the panel stays black --
#     "identical to a dead one -- black, no messages, not even a cursor." The
#     operator lost an evening to exactly that screen. A user reading the old
#     sentence would picture Gaming Mode minus one icon. They get a device
#     that looks bricked.
#
# 🔴 AND THE TEXT WAS EFFECTIVELY INVISIBLE. On every path it was `say`n and
# then the flow returned straight into the next screen, whose first act is
# `clear_logo` (a full `\033[H\033[2J`). The consequence was wiped before
# anyone could read it. That is why the offline path now ENDS ON A SCREEN THE
# USER HAS TO ANSWER rather than on three lines of prose in flight.
#
# ---------------------------------------------------------------------------
# THE QUESTION IS "IS THERE ANY NETWORK?", NOT "DID YOU CONFIGURE WI-FI?"
# ---------------------------------------------------------------------------
#
# ⚠️ DO NOT turn this into "you may not skip Wi-Fi".
# orchestrator/deck_pkgs.py's own DECISION 2 is explicit, and it is right: a
# Deck on a dock's ethernet legitimately records `wifi status=skipped` and is
# perfectly fine, and refusing to proceed "would silently deny that machine
# its Steam on the strength of an answer about the radio". So the gate below
# DETECTS the real state instead of asking, and only the machine that has no
# network by ANY route is made to confirm.
#
# The detection is deliberately built out of parts this file already had, and
# both are already unit-tested against fixtures:
#   - deck_form_has_ipv4, applied to `ip -4 -br addr show` with NO device
#     filter, i.e. every interface. It already excludes 169.254/16 (which is
#     what the kernel hands out when DHCP FAILED) and 127/8, so "has an
#     address" cannot go green on the two non-answers.
#   - deck_form_wifi_portal_check, NetworkManager's own connectivity endpoint,
#     so the installer and the installed system agree about what "online"
#     means.
readonly DECK_NET_VERDICT_DEFAULT=offline

# deck_form_addr_present
# True when ANY interface holds a routable IPv4 address -- ethernet on a dock,
# a USB adapter, a tethered phone, or wlan0 itself. Deliberately not filtered
# to a device: the whole point is that the answer must not be about the radio.
deck_form_addr_present() {
  local ip_bin=${DECK_IP_BIN:-ip} out
  out=$("$ip_bin" -4 -br addr show 2>/dev/null) || out=""
  deck_form_has_ipv4 "$out"
}

# deck_form_net_probe -> online | portal | unreachable | unchecked
#
# deck_form_wifi_portal_check collapses "curl is missing" and "the probe ran
# and failed" into one `unreachable`, which is right for ITS caller (both mean
# "do not claim online") and wrong for this one: "we could not look" and "we
# looked and there was nothing there" must not produce the same screen.
#
# ✅ MEASURED, so `unchecked` should never fire on a real ISO: `curl` is not in
# archiso releng's packages.x86_64, but `git` IS in build-iso.sh's
# `arch_packages` (its line 121) and `pacman -Si git` lists `curl` as a hard
# Depends On. Read on the dev machine 2026-08-16, not assumed. The branch is
# kept anyway -- a dependency is not a guarantee, and the alternative is this
# function lying about a check it never made.
deck_form_net_probe() {
  local curl_bin=${DECK_CURL_BIN:-curl}
  if ! command -v "$curl_bin" >/dev/null 2>&1; then
    deck_form_warn "no '$curl_bin' in the live environment -- whether this network reaches the internet was NOT checked"
    printf 'unchecked\n'
    return 0
  fi
  deck_form_wifi_portal_check
}

# deck_form_network_verdict_for <has-addr:0|1> <probe-verdict>
#   -> online | unproven | offline
#
# 🔴 THE ADDRESS DECIDES WHETHER THE USER IS STOPPED; THE PROBE ONLY DECIDES
# WHAT THE SCREEN SAYS. That split is the whole design, and it is what keeps
# the dock-ethernet Deck frictionless:
#
#   * no routable address anywhere  -> `offline`. There is no network by any
#     route. This is the ONLY verdict that demands an explicit confirmation,
#     and it is a fact about the machine, not an answer the user gave.
#   * an address, and the probe confirmed the internet -> `online`. One line,
#     no press, straight on. A dock user must not be interrogated.
#   * an address, but the probe did not confirm (a captive portal, an
#     unreachable endpoint, or no curl to look with) -> `unproven`. There IS a
#     network; we cannot promise it reaches Valve. The consequence is stated
#     in full, and the confirm defaults to Continue, because stopping a
#     machine that has a working link on the strength of a probe we could not
#     complete is the deck_pkgs.py DECISION 2 mistake in a different costume.
deck_form_network_verdict_for() {
  local has_addr=$1 probe=$2
  if [[ $has_addr != 1 ]]; then
    printf 'offline\n'
    return 0
  fi
  case $probe in
    online) printf 'online\n' ;;
    *)      printf 'unproven\n' ;;
  esac
}

# deck_form_network_verdict -- the [V] half: gathers, then delegates.
# The probe is SKIPPED when there is no address, and that is not an
# optimisation: with no routable address the probe cannot succeed, and running
# it would spend curl's 5 s timeout on every offline install to learn nothing.
deck_form_network_verdict() {
  local has_addr=0 probe=skipped
  deck_form_addr_present && has_addr=1
  [[ $has_addr == 1 ]] && probe=$(deck_form_net_probe)
  deck_form_network_verdict_for "$has_addr" "$probe"
}

# The consequence itself. Four lines, no side effects, one copy -- so every
# call site draws the SAME words and a [U] test can assert them without a
# terminal (the deck_form_s0_text pattern this file already uses).
# ⚠️ Line length is load-bearing, not style: the console is 160 columns and
# `say` pads left by (160-81)/2 = 39, so a line over 121 columns WRAPS and
# silently costs a row. docs/PROGRESS.md §5.40 is what a row overrun does on
# this hardware -- it pushed the username and password prompts off the screen
# and shipped. test/unit/test-deck-form.sh asserts the width and the row
# budget for both screens below.
deck_form_wifi_offline_text() {
  printf '%s\n' "Steam is downloaded during setup, so with no network it is NOT installed."
  printf '%s\n' "A Deck with no Steam boots to a BLACK SCREEN -- no Gaming Mode, no message, nothing to press."
  printf '%s\n' "It is not broken. It looks exactly like it is."
  printf '%s\n' "Wi-Fi can be set up from Desktop Mode afterwards, and Steam installed from there."
}

deck_form_wifi_offline_notice() {
  local line
  while IFS= read -r line; do say "$line"; done < <(deck_form_wifi_offline_text)
}

# deck_form_wifi_required_text -- what the Wi-Fi screen says above its list.
#
# 🔴 THE OPERATOR'S SHAPE, KEPT: the screen's title is `Wi-Fi` (step's own
# line) and the first line below it is the requirement, in their words. The
# rest is the REASON, because a requirement without one reads as a wall and
# this one has a very good reason -- and because the third line is the only
# place in the whole installer that describes what a Steam-less Deck actually
# looks like when it boots.
#
# Four lines, one copy, no side effects: the deck_form_s0_text /
# deck_form_wifi_offline_text pattern, so the [U] suite asserts the real
# words without a terminal.
#
# ⚠️ Line length is load-bearing here too: 121 columns is the say() budget
# (see deck_form_wifi_offline_text's own note and §5.40). The unit suite
# checks every line of this function against it.
deck_form_wifi_required_text() {
  printf '%s\n' "An internet connection is required during install -- it cannot continue without one."
  printf '%s\n' "Steam is downloaded from Valve during setup; it is not on this USB stick."
  printf '%s\n' "Without Steam the Deck boots to a BLACK SCREEN: no Gaming Mode, no message, nothing to press."
  printf '%s\n' "Ethernet on a dock or a USB adapter counts too -- plug one in, then choose Rescan."
}

deck_form_wifi_required_notice() {
  local line
  while IFS= read -r line; do say "$line"; done < <(deck_form_wifi_required_text)
}

# deck_form_offline_headline <verdict>
# One sentence naming the state that was DETECTED. Split out so S1's gate and
# S5's recap cannot drift into describing the same machine two ways.
deck_form_offline_headline() {
  case ${1:-$DECK_NET_VERDICT_DEFAULT} in
    online)
      printf '%s\n' "This Deck already has a network connection, so Steam will still be downloaded." ;;
    unproven)
      printf '%s\n' "This Deck has a network address, but the internet could not be confirmed." ;;
    *)
      printf '%s\n' "No network was found -- no Wi-Fi, and nothing on a dock or a USB adapter either." ;;
  esac
}

# deck_form_offline_detect
# Runs the detection ONCE and remembers it in the global DECK_NET_VERDICT, so
# S5 can recap the SAME state without re-probing on every redraw of a screen
# that loops -- a 5 s curl per redraw would be a new bug in the name of fixing
# one. Echoes the verdict as well, for callers that want it inline.
#
# 🔴 CALL IT AS A COMMAND AND THEN READ THE GLOBAL. NEVER `v=$(...)`.
# That is not style: a command substitution runs this function in a SUBSHELL,
# so the assignment below lands in a process that exits one line later and
# DECK_NET_VERDICT is never set in the caller at all. Every in-file caller did
# exactly that until 2026-08-16, which meant S5's recap always fell back to
# `$DECK_NET_VERDICT_DEFAULT` (= offline) -- i.e. a Deck on a dock's ethernet
# was told, on the last screen before the install, that it would boot to a
# black screen. The precise false statement the detection was added to
# prevent, produced by the detection working perfectly and being thrown away.
# Found by reading, not by a test; test/unit/test-deck-form.sh now asserts the
# global survives into the caller's shell.
deck_form_offline_detect() {
  # shellcheck disable=SC2034  # read by deck_final_summary, deliberately global
  DECK_NET_VERDICT=$(deck_form_network_verdict)
  printf '%s\n' "$DECK_NET_VERDICT"
}

# deck_form_offline_note [<already-detected-verdict>]
#
# The NON-BLOCKING half: state what was detected and carry on. Used on the two
# paths where the user made no choice at all -- there is no Wi-Fi hardware, or
# iwd would not start.
#
# The optional argument exists so a caller that has ALREADY detected does not
# pay for a second detection (and, more importantly, cannot end up describing
# the machine with a verdict different from the one it acted on). With no
# argument it detects for itself, which is what makes it usable on its own.
#
# 🔴 WHY THESE TWO PATHS ARE NOT GATED, DECIDED DELIBERATELY.
#  1. There is nothing to decide. With no radio and no iwd there is no network
#     list to go back to and no Wi-Fi to join; a confirm would be a question
#     whose only real answer is "yes".
#  2. ⚠️ IT WOULD BREAK BOTH QEMU TIERS, WHICH ARE NOT THIS FILE'S TO FIX.
#     Every QEMU run takes this path (no wlan0 in a VM -- see
#     test/vm/vm-installer-screens-test.sh's own note), and both harnesses
#     cross the greeter with a SINGLE `ret` that must land on "Select keyboard
#     layout". An extra screen there turns the cheap tier red -- or worse,
#     hangs it: `gum confirm --default=false` was MEASURED (session 23, cited
#     in vm-install-controller-test.sh) NOT to accept Enter as the affirmative,
#     so a bare Enter would answer "go back" and loop forever. A stuck job that
#     reports nothing is strictly worse than a failure.
#  3. The consequence is still put in front of the user, and on a screen they
#     have to answer: S5 recaps the same detected verdict and the same
#     consequence text immediately above its "Ready to install?" gate.
deck_form_offline_note() {
  local verdict=${1:-}
  if [[ -z $verdict ]]; then
    deck_form_offline_detect >/dev/null
    verdict=${DECK_NET_VERDICT:-$DECK_NET_VERDICT_DEFAULT}
  fi
  say "$(deck_form_offline_headline "$verdict")"
  [[ $verdict == online ]] && return 0
  deck_form_wifi_offline_notice
  return 0
}

# ===========================================================================
# 🔴 DELETED 2026-08-16: deck_form_offline_gate, the "Install anyway, with no
#    Steam" confirm.
# ===========================================================================
#
# It was the screen that stood between the Skip row and the rest of the
# install. With no Skip row and no Skip entry in the failure menu, nothing
# could ever reach it: the two call sites named in its own comment were the
# only two, and both are gone. It is deleted rather than left unreachable
# because an unreachable function with a confident comment is how
# T4-screen-spec.md §6.4's failure mode starts, and this file has already paid
# for it once (the S8 block below is the receipt).
#
# What survives from it, and where:
#   - the detection            -> deck_form_offline_detect, now called at the
#                                 TOP of deck_form_wifi_screen, which is what
#                                 keeps an already-connected Deck out of the
#                                 list entirely
#   - the consequence text     -> deck_form_wifi_offline_notice, unchanged,
#                                 still shown on the no-radio paths and on S5
#   - "the dangerous answer is
#      never the default"      -> no longer applicable HERE (the dangerous
#                                 answer is not offered), and still enforced
#                                 where it is, at DECK_DISK_CONFIRM_DEFAULT

# ===========================================================================
# The dead end: a Deck that cannot reach any network cannot install
# ===========================================================================
#
# 🔴 THIS IS THE INTENDED OUTCOME, AND IT MUST BE LEGIBLE. Removing the Skip
# row means a machine with a radio, no other link and nothing joinable has no
# way forward -- which is correct (the alternative is a black-screen Deck) and
# is exactly the kind of state a user has to be TOLD they are in. A list that
# silently will not advance is a bug report; a screen that says what is
# required, why, and what the remaining choices are is a decision.
#
# Same shape and same reasons as deck_form_disk_dead_end below -- Reboot /
# Power off, never a shell, empty-or-unrecognised choice REDRAWS -- with one
# row that screen does not have: a way back to the network list. The disk dead
# end is genuinely terminal (no disk will appear while you stand there); this
# one is not (plugging in a dock, or walking closer to an access point, fixes
# it), so refusing to go back would be false.
readonly -a DECK_NET_DEAD_END_ITEMS=("Back to the network list" "Reboot" "Power off")

deck_form_net_dead_end_items() { printf '%s\n' "${DECK_NET_DEAD_END_ITEMS[@]}"; }

# deck_form_net_dead_end_action_for <gum-choose-output-or-empty>
#   -> back | reboot | poweroff | redraw
deck_form_net_dead_end_action_for() {
  local choice=$1
  case $choice in
    "Back to the network list") printf 'back\n' ;;
    Reboot)                     printf 'reboot\n' ;;
    "Power off")                printf 'poweroff\n' ;;
    *)                          printf 'redraw\n' ;;
  esac
}

# deck_form_net_dead_end
# Returns 1 to go back to the network list. Every other answer either ends the
# machine's power state or redraws; there is no return value that means
# "continue the install", because there is no such answer on this screen.
#
# ⚠️ A FAILED `systemctl` REDRAWS AND SAYS SO -- it does not fall through.
# Falling through would continue an install the user just asked to stop, which
# is both the silent-failure rule (CLAUDE.md) and the worst possible reading
# of a button labelled "Power off".
deck_form_net_dead_end() {
  local choice action systemctl_bin=${DECK_SYSTEMCTL_BIN:-systemctl}
  while true; do
    clear_logo
    echo
    say --foreground 1 "This Deck cannot be installed without an internet connection."
    deck_form_wifi_required_notice
    echo
    choice=$(deck_form_net_dead_end_items | gum choose --header "What next?") || choice=""
    action=$(deck_form_net_dead_end_action_for "$choice")
    case $action in
      back)   return 1 ;;
      reboot)
        "$systemctl_bin" reboot ||
          deck_form_warn "'$systemctl_bin reboot' failed -- the Deck is still on this screen. Hold the power button to switch it off."
        ;;
      poweroff)
        "$systemctl_bin" poweroff ||
          deck_form_warn "'$systemctl_bin poweroff' failed -- the Deck is still on this screen. Hold the power button to switch it off."
        ;;
      *) : ;;
    esac
  done
}

# ===========================================================================
# U1 -- the NetworkManager credential hand-off
# ===========================================================================
#
# 🔴 WHAT UPSTREAM ACTUALLY DOES ABOUT THIS: NOTHING. Measured against the
# pinned tree in iso/upstream (omacom-io/omarchy-iso@a12bfea7a86c), not
# inferred from the spec's prose:
#
#   - `configurator` contains no `iwd`, `iwctl`, `nmcli`, `NetworkManager`
#     or `wlan` at all. Its ONLY network statement is the literal
#     `"network_config": { "type": "iso" }` it writes into
#     user_configuration.json, at lines 770 and 1156.
#   - The 14-phase orchestrator (orchestrator/*.py) contains no network
#     code either -- the only matches for "network" in the whole package
#     are `network-online.target` in an unrelated Tailscale unit.
#   - The string `system-connections` and the string `nmconnection` appear
#     ZERO times anywhere in iso/upstream.
#
# So the entire hand-off is delegated to archinstall's `type: iso` handler,
# and that handler cannot produce a NetworkManager profile: it copies
# /var/lib/iwd/*.psk and installs+enables **iwd** on the target, while
# Omarchy's own package set installs and enables **NetworkManager**
# (manifests/fresh-4.json: "is_enabled:NetworkManager" = enabled; the
# manifest of a fresh install contains no iwd package at all). Two managers
# claiming wlan0 is not a hand-off, it is a conflict -- and NetworkManager
# does not read iwd's PSK store when running its default wpa_supplicant
# backend.
#
# ⚠️ The archinstall half of that paragraph is (INFERRED): archinstall's
# source is not vendored into this repo, so `copy_iso_network_config`'s
# behaviour is recalled, not read. The REPO-GROUNDED half is enough on its
# own to justify what follows -- nothing in upstream ever writes a
# NetworkManager connection, so if we want one, we write it.
#
# WHAT THIS FILE CAN AND CANNOT DO. deck-form.sh runs in the live ISO
# BEFORE the target disk is partitioned; there is no /mnt to write into
# yet. So this file STAGES the connection profile in the live root and a
# later, target-side step installs it. §5 names that step: "configure_deck
# writes /etc/NetworkManager/system-connections/<ssid>.nmconnection (mode
# 0600) itself" -- and `configure_deck` is T5's orchestrator phase (T5-fork
# -plan.md §3 seam S3), a different component this file does not own.
#
# 🔴 THE CONTRACT, so the two halves cannot drift silently:
#   /root/deck-wifi.nmconnection   a complete NetworkManager keyfile, mode
#                                  0600, present ONLY if a network was
#                                  actually joined. `configure_deck` copies
#                                  it to
#                                  /mnt/etc/NetworkManager/system-connections/
#                                  preserving mode 0600 (NetworkManager
#                                  REFUSES to load a group/world-readable
#                                  keyfile, so a copy that widens the mode
#                                  fails silently at first boot).
#   /root/deck-wifi-outcome        `key=value` lines recording what S1 did.
#                                  ⚠️ PARSE IT, NEVER `source` IT: the ssid
#                                  value is attacker-controlled text.
#
# Until that phase exists, staging is still the right thing to do: the file
# is inert, and the alternative (do nothing now, discover at T5 that S1
# never captured the PSK) is the failure this comment exists to prevent.

# deck_form_nmconnection_safe <text>
# True when TEXT can be written into a NetworkManager keyfile as a plain
# ini value without changing its own meaning. Rejects control bytes (a
# newline would inject an ini line or a whole [section]) and leading or
# trailing whitespace (GKeyFile strips it on read, so the value that comes
# back out would not be the value that went in -- a silently WRONG SSID or
# passphrase, which is worse than a refusal). An empty string is also not
# safe: a keyfile with `ssid=` is a profile for nothing.
#
# ⚠️ Why not encode instead: NetworkManager's keyfile format does document
# a byte-list form for `ssid` (`ssid=77;121;`), which would carry any bytes
# at all. It is NOT used here because nothing in this project has ever
# tested that NM accepts it, and a keyfile NM rejects is a Deck that boots
# with no Wi-Fi and no visible reason -- exactly U1's own cost column. A
# loud refusal, with the install still proceeding, is the honest trade.
deck_form_nmconnection_safe() {
  local text=$1
  [[ -n $text ]] || return 1
  [[ $text == *[$'\001'-$'\037']* ]] && return 1
  [[ $text == *$'\177'* ]] && return 1
  [[ $text == [[:space:]]* ]] && return 1
  [[ $text == *[[:space:]] ]] && return 1
  return 0
}

# deck_form_nmconnection <ssid> <psk> <uuid>
# The keyfile itself. An empty PSK means an open network and emits NO
# [wifi-security] section (NetworkManager treats the presence of that
# section as "this network is secured", so an empty psk= would make an open
# network unjoinable).
deck_form_nmconnection() {
  local ssid=$1 psk=$2 uuid=$3
  if ! deck_form_nmconnection_safe "$ssid"; then
    deck_form_warn "SSID cannot be written to a NetworkManager keyfile without changing its meaning (control bytes, or leading/trailing whitespace) -- NOT staging a profile for it"
    return 1
  fi
  if ! deck_form_nmconnection_safe "$uuid"; then
    deck_form_warn "refusing to write a keyfile with an unusable uuid"
    return 1
  fi
  if [[ -n $psk ]] && ! deck_form_nmconnection_safe "$psk"; then
    deck_form_warn "passphrase cannot be written to a NetworkManager keyfile without changing its meaning -- NOT staging a profile"
    return 1
  fi
  printf '[connection]\n'
  printf 'id=%s\n' "$ssid"
  printf 'uuid=%s\n' "$uuid"
  printf 'type=wifi\n'
  printf 'autoconnect=true\n'
  printf '\n[wifi]\n'
  printf 'mode=infrastructure\n'
  printf 'ssid=%s\n' "$ssid"
  if [[ -n $psk ]]; then
    printf '\n[wifi-security]\n'
    printf 'key-mgmt=wpa-psk\n'
    printf 'psk=%s\n' "$psk"
  fi
  printf '\n[ipv4]\n'
  printf 'method=auto\n'
  printf '\n[ipv6]\n'
  printf 'addr-gen-mode=default\n'
  printf 'method=auto\n'
}

# deck_form_stage_nmconnection <path> <ssid> <psk>
#
# 🔴 The file is created 0600 BEFORE any secret is written into it, not
# chmod'd afterwards. `printf >file; chmod 600 file` leaves the passphrase
# world-readable for the window between the two, and this runs on a live
# ISO whose root filesystem other processes share.
deck_form_stage_nmconnection() {
  local path=$1 ssid=$2 psk=$3 uuid
  uuid=$(deck_form_uuid) || return 1
  rm -f "$path"
  if ! (umask 077 && : >"$path"); then
    deck_form_warn "could not create $path"
    return 1
  fi
  if ! deck_form_nmconnection "$ssid" "$psk" "$uuid" >"$path"; then
    rm -f "$path"
    return 1
  fi
  return 0
}

# Overridable so the [U] suite gets a deterministic uuid.
deck_form_uuid() {
  local src=${DECK_UUID_SOURCE:-/proc/sys/kernel/random/uuid} uuid
  uuid=$(cat "$src" 2>/dev/null)
  if [[ -z $uuid ]]; then
    deck_form_warn "could not read a uuid from $src"
    return 1
  fi
  printf '%s\n' "$uuid"
}

# deck_form_wifi_record_outcome <state-dir> <status> <ssid>
# Two lines, key=value, SSID sanitised. See the contract note above: this
# file is parsed by its consumer, never sourced.
deck_form_wifi_record_outcome() {
  local dir=$1 status=$2 ssid=$3 path
  path="$dir/$DECK_NET_OUTCOME_FILE"
  if ! printf 'status=%s\nssid=%s\n' "$status" "$(deck_form_sanitize_ssid "$ssid")" >"$path"; then
    deck_form_warn "could not record the Wi-Fi outcome to $path"
    return 1
  fi
  return 0
}

# --- the interactive halves -------------------------------------------------
#
# Everything below drives gum / iwctl / ip / curl and is therefore [V]-tier
# by T4-screen-spec.md §6.1's own split; every DECISION any of them makes
# has been pulled out into a pure function above, which is where the [U]
# assertions live. That is the same shape S2's omarchy_prompt_timezone and
# S4's deck_form_disk_dead_end already use in this file.

deck_form_wifi_passphrase_body() {
  local ssid=$1 safe
  # 🔴 SANITISE BEFORE DRAWING. The SSID goes into a gum --prompt string,
  # which is written straight to the console: an SSID carrying an ANSI
  # escape would repaint or scroll the screen the user is typing a password
  # into. This is the same threat deck_form_sanitize_ssid exists for, and
  # the prompt is a sink for it just as much as the menu is.
  safe=$(deck_form_sanitize_ssid "$ssid")
  if [[ ${DECK_FORM_OSK_UP:-0} != 1 ]]; then
    # stderr, not stdout: this function's stdout IS the passphrase.
    # §2.3: "a degradation the screen must state, not swallow."
    # The way out named here changed with the Skip row's removal, and it had
    # to: telling someone to pick a row that no longer exists is worse than
    # saying nothing. What IS still true with no keyboard -- B cancels this
    # prompt and, after the bounded tries, lands back on the list, where an
    # open network or a wired connection needs nothing typed at all.
    deck_form_warn "the on-screen keyboard did not start -- there is no way to type a password here. Press B to go back to the network list: an open network, or ethernet on a dock, needs no password."
  fi
  # 🔴 --password, and it is MEASURED, not stylistic: T4 §4 S1's flow trace
  # records that the real wizard never echoes a password. The OSK is how
  # the user types; the field shows dots.
  gum input --password --placeholder "Wi-Fi password" --prompt "Password for ${safe}> "
}

# deck_form_wifi_scan <iface> <out-parsed-file>
# §5: "empty get-networks after two tries". A failing `scan` is warned
# about but not fatal -- iwd keeps a cache, and a scan that returns an
# error while the cache is populated is still a usable list.
deck_form_wifi_scan() {
  local iface=$1 out=$2
  local iwctl=${DECK_IWCTL_BIN:-iwctl}
  local tries=${DECK_NET_SCAN_TRIES_OVERRIDE:-$DECK_NET_SCAN_TRIES}
  local settle=${DECK_NET_SCAN_SETTLE_OVERRIDE:-$DECK_NET_SCAN_SETTLE}
  local raw i
  raw=$(mktemp) || { deck_form_die "mktemp failed"; return 1; }
  : >"$out"
  for ((i = 1; i <= tries; i++)); do
    "$iwctl" station "$iface" scan >/dev/null 2>&1 ||
      deck_form_warn "'iwctl station $iface scan' failed on attempt $i -- reading whatever iwd already has cached"
    [[ $settle == 0 ]] || sleep "$settle"
    if "$iwctl" station "$iface" get-networks >"$raw" 2>/dev/null &&
       deck_form_parse_iwctl_networks "$raw" >"$out" 2>/dev/null &&
       [[ -s $out ]]; then
      rm -f "$raw"
      return 0
    fi
  done
  rm -f "$raw"
  : >"$out"
  deck_form_warn "no networks after $tries scan attempts on $iface"
  return 1
}

deck_form_wifi_connect() {
  local iface=$1 ssid=$2 psk=$3
  local iwctl=${DECK_IWCTL_BIN:-iwctl}
  local out status=0 verdict
  # ⚠️ The passphrase is passed as an argv element, so it is briefly
  # visible in /proc to anything that can read it. Accepted, and bounded:
  # the live ISO is single-user root with no login prompt and no other
  # accounts, and iwctl offers no stdin form for a non-interactive join.
  # Recorded here rather than left for someone to rediscover.
  if [[ -n $psk ]]; then
    out=$("$iwctl" --passphrase "$psk" station "$iface" connect "$ssid" 2>&1) || status=$?
  else
    out=$("$iwctl" station "$iface" connect "$ssid" 2>&1) || status=$?
  fi
  verdict=$(deck_form_connect_verdict "$status" "$out")
  if [[ $verdict != ok ]]; then
    deck_form_warn "iwctl connect reported failure (status $status)"
    return 1
  fi
  return 0
}

deck_form_wifi_wait_dhcp() {
  local iface=$1
  local ip_bin=${DECK_IP_BIN:-ip}
  local deadline=${DECK_NET_DHCP_DEADLINE_OVERRIDE:-$DECK_NET_DHCP_DEADLINE}
  local poll=${DECK_NET_DHCP_POLL_OVERRIDE:-$DECK_NET_DHCP_POLL}
  local waited=0 out
  while true; do
    out=$("$ip_bin" -4 -br addr show dev "$iface" 2>/dev/null) || out=""
    deck_form_has_ipv4 "$out" && return 0
    if [[ $waited -ge $deadline ]]; then
      deck_form_warn "$iface associated but has no routable IPv4 address after ${deadline}s -- DHCP did not complete"
      return 1
    fi
    [[ $poll == 0 ]] || sleep "$poll"
    waited=$((waited + poll))
  done
}

deck_form_wifi_portal_check() {
  local curl_bin=${DECK_CURL_BIN:-curl}
  local url=${DECK_NET_PORTAL_URL_OVERRIDE:-$DECK_NET_PORTAL_URL}
  local body status=0
  if ! command -v "$curl_bin" >/dev/null 2>&1; then
    deck_form_warn "no '$curl_bin' in the live environment -- the captive-portal check was NOT performed"
    printf 'unreachable\n'
    return 0
  fi
  body=$("$curl_bin" -fsS --max-time 5 -- "$url" 2>/dev/null) || status=$?
  deck_form_portal_verdict "$status" "$body"
}

# deck_form_wifi_failure_menu <headline>
# The shared "we associated but it did not work" menu (§5's DHCP and
# captive-portal rows). Prints one of retry/another on stdout (skip was
# removed with the Skip row -- see deck_form_net_failure_action_for); loops
# on redraw so a cancelled prompt can never fall through to an action.
deck_form_wifi_failure_menu() {
  local headline=$1 choice action
  while true; do
    say --foreground 1 "$headline"
    choice=$(deck_form_net_failure_items | gum choose --header "What next?") || choice=""
    action=$(deck_form_net_failure_action_for "$choice")
    [[ $action == redraw ]] && continue
    printf '%s\n' "$action"
    return 0
  done
}

# deck_form_wifi_join <iface> <raw-ssid> <security-class>
#
# Status vocabulary:
#   0  connected      DECK_WIFI_SSID is set, the profile is staged
#   1  back to list   this network did not work; the caller redraws
#   3  try this same network again (the DHCP menu's own "Try again")
#
# 🔴 STATUS 2 ("skip the whole screen") IS GONE, 2026-08-16. It existed only
# for the Skip entry inside the failure menu, which is gone with the row on the
# list -- see deck_form_net_failure_action_for. Keeping the branch would have
# left a documented status nothing can return, which is the same defect as a
# comment that is not true.
deck_form_wifi_join() {
  local iface=$1 ssid=$2 class=$3
  local state_dir=${DECK_NET_STATE_DIR:-$DECK_NET_STATE_DIR_DEFAULT}
  local tries=0 psk="" action portal
  local max=${DECK_NET_MAX_PASSPHRASE_TRIES_OVERRIDE:-$DECK_NET_MAX_PASSPHRASE_TRIES}
  local safe_ssid
  safe_ssid=$(deck_form_sanitize_ssid "$ssid")

  while true; do
    if [[ $class == passphrase ]]; then
      tries=$((tries + 1))
      if [[ $tries -gt $max ]]; then
        say "That password was rejected $max times. Back to the network list."
        return 1
      fi
      # §2.3's bounded text-entry mode -- the ONLY place S1 types.
      psk=$(deck_form_text_prompt deck_form_wifi_passphrase_body "$ssid") || return 1
      if [[ -z $psk ]]; then
        say "No password entered."
        continue
      fi
    fi

    if deck_form_wifi_connect "$iface" "$ssid" "$psk"; then
      break
    fi

    if [[ $class == passphrase ]]; then
      # §5, verbatim: "Back to the passphrase prompt with 'That didn't
      # work -- check the password', passphrase cleared."
      say --foreground 1 "That didn't work -- check the password."
      psk=""
      continue
    fi
    say --foreground 1 "Could not join $safe_ssid."
    return 1
  done

  if ! deck_form_wifi_wait_dhcp "$iface"; then
    action=$(deck_form_wifi_failure_menu "Joined $safe_ssid, but it never handed out an address.")
    case $action in
      # 3 == "run this same join again", handled by the caller's inner
      # loop. It is a separate status from 1 (back to the list) because
      # the two are genuinely different screens to return to, and folding
      # them together would make "Try again" silently mean "pick another".
      retry)   return 3 ;;
      another) return 1 ;;
    esac
    return 1
  fi

  portal=$(deck_form_wifi_portal_check)
  if [[ $portal == portal ]]; then
    # §5: "State plainly that this network needs a browser and cannot be
    # used during install ... Do not attempt to render a portal."
    say --foreground 1 "$safe_ssid needs a web sign-in page, which this installer cannot show."
    say "Pick a different network -- the install needs one that reaches the internet on its own."
    action=$(deck_form_wifi_failure_menu "This network needs a browser sign-in.")
    case $action in
      retry|another) return 1 ;;
    esac
    return 1
  fi
  if [[ $portal == unreachable ]]; then
    say "Connected to $safe_ssid, but the internet check did not answer. Continuing."
  fi

  DECK_WIFI_SSID=$safe_ssid
  if ! deck_form_stage_nmconnection "$state_dir/$DECK_NET_STAGED_NMCONNECTION" "$ssid" "$psk"; then
    # Loud, and NOT fatal: the install is on the network right now, so it
    # will fetch what it needs. What is lost is the hand-off to the
    # installed system, and the user is told so rather than finding out at
    # first boot (U1's own cost column).
    say --foreground 3 "Connected, but this network's name could not be saved for the installed system."
    say "You will need to join Wi-Fi again after the first boot."
  fi
  deck_form_wifi_record_outcome "$state_dir" connected "$ssid" ||
    deck_form_warn "the Wi-Fi outcome was not recorded"
  # FAST-INSTALL C4: S1 reports connected, so the early stage's online work
  # (Steam) may start. The marker call is LOUD: on persistent failure the
  # screen offers Try again / Stop instead of silently continuing to a
  # Steam-less install. Abort exits in production, so `return 1` below only
  # runs under stubs -- where it sends the caller back to the list, never on.
  deck_form_network_ready_or_stop || return 1
  say "Connected to $safe_ssid."
  return 0
}
# deck_form_wifi_screen_gaming -- the Gaming=yes network gate (four-variant
# flow). Gaming=yes REQUIRES Internet (Steam downloads from Valve): this
# wrapper stays in the network screen until connected, or B anywhere backs
# out to the Gaming choice. The reversal (Gaming yes->no) rewrites the
# `gaming` file to no and clears any marker state BEFORE network-ready ever
# fired -- network-ready only fires on success paths below, so a flipped
# answer can never leave a stale "online" signal for the worker. There is
# deliberately no path back to preinstalls from here: once both choices were
# answered the files are LOCKED (the package delta may already be running),
# and un-asking preinstalls would contradict installed packages.
deck_form_wifi_screen_gaming() {
  local rc=0
  # shellcheck disable=SC2034
  DECK_WIFI_GAMING_GATE=1
  while true; do
    DECK_WIFI_WANT_GAMING_BACK=""
    deck_form_wifi_screen && rc=0 || rc=$?
    if [[ $rc -eq 0 ]]; then
      return 0
    fi
    if [[ ${DECK_WIFI_WANT_GAMING_BACK:-} == yes ]]; then
      # shellcheck disable=SC2034
      DECK_GAMING=no
      deck_form_choice_write gaming no || return 1
      deck_form_gaming_opt_out_cleanup || deck_form_warn "gaming opt-out cleanup reported an issue -- continuing desktop-only"
      return 0
    fi
    return 1
  done
}
# success), and a removal error is warned, not fatal.
deck_form_gaming_opt_out_cleanup() {
  local marker=${DECK_NETWORK_READY_FILE:-/run/omarchy-deck/network-ready}
  if [[ -e $marker ]]; then
    rm -f "$marker" || { deck_form_warn "could not clear stale $marker after Gaming yes->no"; return 1; }
  fi
  return 0
}
# deck_form_steam_progress_text <status> <line> -- one human line for the
# progress screen: Valve's parsed numbers once downloading, the raw line
# when unparseable (indeterminate, never a crash), else the early phase.
deck_form_steam_progress_text() {
  local status=${1:-} line=${2:-} parsed have_kb total_kb pct
  local have_mb total_mb
  if parsed=$(deck_form_parse_steam_progress "$line"); then
    have_kb=${parsed%% *}; total_kb=${parsed##* }
    pct=$(deck_form_steam_percent "$have_kb" "$total_kb") || pct=""
    have_mb=$(deck_form_format_mb "$have_kb") || have_mb=""
    total_mb=$(deck_form_format_mb "$total_kb") || total_mb=""
    if [[ -n $pct && -n $have_mb && -n $total_mb ]]; then
      printf 'Downloading Steam: %s%% (%s of %s)\n' "$pct" "$have_mb" "$total_mb"
      return 0
    fi
  fi
  if [[ -n $line ]]; then
    printf '%s\n' "$line"
    return 0
  fi
  local phase
  phase=$(deck_form_early_phase)
  if [[ -n $phase ]]; then
    printf 'Preparing Steam: %s\n' "$phase"
    return 0
  fi
  printf 'Preparing Steam download...\n'
  return 0
}

# deck_form_steam_bar <percent> <width> -- "####-----" bar, pure/testable.
# Empty/unparseable percent draws "?" marks (indeterminate), never a crash.
deck_form_steam_bar() {
  local pct=${1:-} width=${2:-20} filled i bar=""
  if [[ ! $pct =~ ^[0-9]+$ ]]; then
    for (( i = 0; i < width; i++ )); do bar="${bar}?"; done
    printf '[%s]\n' "$bar"
    return 0
  fi
  (( pct > 100 )) && pct=100
  filled=$(( pct * width / 100 ))
  for (( i = 0; i < filled; i++ )); do bar="${bar}#"; done
  for (( i = filled; i < width; i++ )); do bar="${bar}-"; done
  printf '[%s]\n' "$bar"
  return 0
}

# deck_form_steam_failure_action_for <choice> -- failure menu decision:
# retry (re-poll), continue without Steam (flip gaming to no -- only if the
# stage still allows it, checked by the caller), reboot/poweroff.
# Empty/unrecognised redraws, never guesses.
deck_form_steam_failure_action_for() {
  local choice=${1:-}
  case $choice in
    "Try again") printf 'retry\n' ;;
    "Continue without Steam") printf 'without-steam\n' ;;
    "Reboot") printf 'reboot\n' ;;
    "Power off") printf 'poweroff\n' ;;
    *) printf 'redraw\n' ;;
  esac
}

# deck_form_steam_failure_items -- menu rows; split out so the suite asserts
# the menu never offers a shell.
deck_form_steam_failure_items() { printf '%s\n' "Try again" "Continue without Steam" "Reboot" "Power off"; }

# deck_form_steam_may_drop_gaming <early-status> <steam-status> -- 0 iff
# flipping gaming yes->no is still allowed: the early stage has not
# finished (done) and Steam itself has not finished (done/installed). Once
# either landed, un-asking contradicts installed bytes.
deck_form_steam_may_drop_gaming() {
  local early=${1:-} steam=${2:-}
  [[ $early == "done" ]] && return 1
  [[ $steam == "done" || $steam == installed ]] && return 1
  return 0
}

# deck_form_steam_progress_screen -- the NEW blocking Steam download screen
# (Steam=yes only). Polls steam/status + steam/progress and the early phase
# about once a second: a bar with percent, downloaded/total MB, rate (MB/s
# from successive readings) and ETA, plus the early phase before Steam
# starts. Proceeds automatically on steam done/installed. Steam skipped is
# NOT waited on (gaming was flipped to no upstream -- proceed). Steam
# failed/incomplete shows the error with a menu: Try again (re-poll),
# Continue without Steam (flip gaming to no ONLY if the stage still allows
# it), or Reboot/Power off -- never a shell, never a silent skip. Early
# failed aborts loudly with the early failure menu, same as S5.
deck_form_steam_progress_screen() {
  local status="" line="" early="" err action choice
  local systemctl_bin=${DECK_SYSTEMCTL_BIN:-systemctl}
  local last_have="" last_t="" have_kb total_kb parsed now rate="" eta="" eta_text=""
  local pct="" bar text
  while true; do
    if [[ ${DECK_GAMING:-no} != yes ]]; then
      return 0
    fi
    status=$(deck_form_steam_status)
    case $status in
      "done"|installed)
        return 0 ;;
      skipped)
        return 0 ;;
      failed|incomplete)
        err=$(deck_form_steam_error)
        clear_logo
        echo
        say --foreground 1 "The Steam download failed."
        [[ -n $err ]] && say --foreground 1 "$err"
        # The failure screen's own readily available log: the last progress
        # line the stage wrote. Shown when there is one, skipped when not.
        line=$(deck_form_steam_progress_line)
        [[ -n $line ]] && say --foreground 1 "$line"
        say "Steam comes from Valve during setup; without it there is no Gaming Mode."
        echo
        choice=$(deck_form_steam_failure_items | gum choose --header "What next?") || choice=""
        action=$(deck_form_steam_failure_action_for "$choice")
        case $action in
          retry) continue ;;
          without-steam)
            early=$(deck_form_early_status)
            if deck_form_steam_may_drop_gaming "$early" "$status"; then
              # shellcheck disable=SC2034
              DECK_GAMING=no
              deck_form_choice_write gaming no || return 1
              deck_form_gaming_opt_out_cleanup || deck_form_warn "gaming opt-out cleanup reported an issue -- continuing desktop-only"
              return 0
            fi
            say --foreground 3 "The install has already finished that part, so Steam can no longer be un-asked here."
            continue ;;
          reboot) "$systemctl_bin" reboot ;;
          poweroff) "$systemctl_bin" poweroff ;;
          *) continue ;;
        esac
        continue ;;
    esac
    early=$(deck_form_early_status)
    if [[ $early == failed ]]; then
      deck_form_early_failed_menu
      abort "The background install failed."
      return 1
    fi
    line=$(deck_form_steam_progress_line)
    text=$(deck_form_steam_progress_text "$status" "$line")
    pct=""
    if parsed=$(deck_form_parse_steam_progress "$line"); then
      have_kb=${parsed%% *}; total_kb=${parsed##* }
      pct=$(deck_form_steam_percent "$have_kb" "$total_kb" 2>/dev/null) || pct=""
      now=$(date +%s)
      if [[ -n $last_have && -n $last_t && $have_kb =~ ^[0-9]+$ && $last_have =~ ^[0-9]+$ ]]; then
        rate=$(deck_form_steam_rate "$last_have" "$last_t" "$have_kb" "$now" 2>/dev/null) || rate=""
        if [[ -n $rate ]]; then
          eta=$(deck_form_steam_eta "$(( total_kb - have_kb ))" "$rate" 2>/dev/null) || eta=""
          [[ -n $eta ]] && eta_text=$(deck_form_format_eta "$eta" 2>/dev/null) || eta_text=""
        fi
      fi
      last_have=$have_kb; last_t=$now
    fi
    bar=$(deck_form_steam_bar "$pct" 20)
    clear_logo
    echo
    say "Downloading Steam from Valve..."
    say "$bar"
    say "$text"
    if [[ -n $rate ]]; then
      if [[ -n $eta_text ]]; then
        say --foreground 8 "${rate} MB/s, about ${eta_text} left"
      else
        say --foreground 8 "${rate} MB/s"
      fi
    elif [[ -n $early && $early != "done" ]]; then
      say --foreground 8 "Early install: $early"
    fi
    echo
    # Bounded by the stage, not by this file: every iteration re-reads
    # steam/status (done/skipped/failed all return above) and the early
    # state (failed aborts above), so the loop ends when the download or
    # the install does. The sleep honours DECK_STEAM_POLL_SECS_OVERRIDE so
    sleep "${DECK_STEAM_POLL_SECS_OVERRIDE:-$DECK_STEAM_POLL_SECS}"
  done
}


# can reach; a nonzero return means this function's OWN plumbing broke.
deck_form_wifi_screen() {
  local state_dir=${DECK_NET_STATE_DIR:-$DECK_NET_STATE_DIR_DEFAULT}
  local systemctl_bin=${DECK_SYSTEMCTL_BIN:-systemctl}
  local iface parsed rows choice action line ssid security class join_rc

  DECK_WIFI_SSID=""

  step "Wi-Fi"

  # 🔴 FIRST QUESTION: DOES THIS MACHINE ALREADY HAVE A NETWORK? Asked of the
  # MACHINE, before a single row is drawn, and answered by
  # deck_form_offline_detect (any interface, 169.254/16 and 127/8 excluded,
  # plus NetworkManager's own connectivity endpoint for the wording).
  #
  # If it does, this screen is over. No list, no confirm, no keypress -- a
  # Deck on a dock's ethernet, a USB adapter or a tethered phone is ALREADY in
  # the state the requirement demands, and orchestrator/deck_pkgs.py DECISION
  # 2 is explicit that refusing it "would silently deny that machine its Steam
  # on the strength of an answer about the radio". Making it walk a mandatory
  # Wi-Fi list would be that mistake wearing the new rule as a hat.
  #
  # ONE LINE IS SAID, AND IT IS NOT DECORATION. Silence here is
  # indistinguishable from the detection never having run -- the user pressed
  # A on a screen that promised Wi-Fi and got the keyboard screen instead, with
  # nothing on the record explaining why. The line costs one row and no press,
  # and its absence is what the unit suite would catch if this block were ever
  # "simplified" away.
  #
  # ⚠️ AN ADDRESS IS ENOUGH; A CONFIRMED PROBE IS NOT REQUIRED. `unproven` (an
  # address, but curl could not confirm the internet) does NOT go to the list
  # either: the machine has a link, and stopping it on the strength of a check
  # we could not complete is the same DECISION 2 error. It is told exactly what
  # was and was not established, and the install proceeds -- which is also what
  # the S5 recap will repeat, from the same global, a few screens later.
  #
  # THE COST, STATED: a Deck that is on ethernet AND wanted to save Wi-Fi
  # credentials for the installed system does not get asked here. That is a
  # deliberate trade -- Desktop Mode joins Wi-Fi in two presses after the
  # install, and the alternative is interrogating every already-connected
  # machine to serve the rarer case.
  local verdict
  deck_form_offline_detect >/dev/null
  verdict=${DECK_NET_VERDICT:-$DECK_NET_VERDICT_DEFAULT}
  if [[ $verdict != offline ]]; then
    deck_form_offline_note "$verdict"
    # `skipped` is S1's existing vocabulary for "this screen configured no
    # Wi-Fi" (deck_wifi.py KNOWN_STATUSES, deck_pkgs.py
    # NO_NETWORK_WIFI_STATUSES). Not a new value: those two modules validate
    # the set and are owned elsewhere, and deck_pkgs.py's own DECISION 2 names
    # this exact machine -- "a Deck on a dock's ethernet legitimately has
    # status=skipped" -- so the record already means what happened here.
    deck_form_wifi_record_outcome "$state_dir" skipped ""
    # FAST-INSTALL C4: an existing link IS S1 reporting connected (Main's
    # ethernet rule): the early stage's online work may start. Without this
    # the early stage would wait on the marker forever on a docked Deck.
    # Same loudness as the join path: Stay keypress-free when it lands
    # (both VM tiers take neither this branch nor any confirm here), and
    # offer Try again / Stop when it persistently fails.
    deck_form_network_ready_or_stop || return 1
    return 0
  fi

  if ! iface=$(deck_form_wifi_iface); then
    say "No Wi-Fi hardware found -- continuing offline."
    # ⚠️ STILL NON-BLOCKING, AND STILL DELIBERATELY DIFFERENT FROM A USER WHO
    # DECLINED. There is no radio: there is no list to draw, nothing to
    # rescan, and no answer a confirm could collect that would change
    # anything. This is also the path EVERY QEMU run takes (no wlan0 in a VM),
    # and both VM harnesses cross the greeter with a single `ret` that must
    # land on the keyboard screen -- see deck_form_offline_note's own block.
    # S5 is where this machine's user meets the consequence on a screen they
    # have to answer.
    deck_form_offline_note "$verdict"
    deck_form_wifi_record_outcome "$state_dir" no-hardware ""
    return 0
  fi

  local iwd_status
  if ! iwd_status=$("$systemctl_bin" start iwd 2>&1); then
    # §5: "Same, with the unit's status line shown. Never swallow."
    say --foreground 1 "The Wi-Fi service (iwd) would not start -- continuing offline."
    [[ -n $iwd_status ]] && say "$iwd_status"
    deck_form_offline_note "$verdict"
    deck_form_wifi_record_outcome "$state_dir" iwd-failed ""
    return 0
  fi

  parsed=$(mktemp) || { deck_form_die "mktemp failed"; return 1; }
  rows=$(mktemp) || { deck_form_die "mktemp failed"; rm -f "$parsed"; return 1; }

  while true; do
    step "Wi-Fi"
    # The requirement and its reason, ABOVE the list and inside the loop, so a
    # rescan or a cancelled menu redraws them with the list rather than
    # scrolling them off. This is the operator's shape: the screen is titled
    # `Wi-Fi` and says "An internet connection is required during install"
    # directly beneath it.
    deck_form_wifi_required_notice
    if ! deck_form_wifi_scan "$iface" "$parsed"; then
      # §5's sentence was "No networks found. Move closer, or skip." -- the
      # second half named a row that no longer exists. Rescan is what is
      # actually there, and it is what a user who has just moved closer, or
      # just plugged in a dock, needs to press.
      say "No networks found. Move closer, plug in a dock, or choose Rescan."
    fi
    deck_form_build_network_rows "$parsed" >"$rows"

    choice=$(gum choose --header "Networks" <"$rows") || choice=""
    action=$(deck_form_net_choice_action "$choice")
    case $action in
      redraw) continue ;;
      rescan) continue ;;
      gaming-back)
        # Gaming-gate back row: return to the Gaming choice. Signals the
        # wrapper (DECK_WIFI_WANT_GAMING_BACK) and returns 1 -- the wrapper
        # rewrites `gaming` to no and clears stale marker state. Only drawn
        # inside the Gaming=yes gate (row only exists then).
        # shellcheck disable=SC2034
        DECK_WIFI_WANT_GAMING_BACK=yes
        rm -f "$parsed" "$rows"
        return 1
        ;;
      stop)
        # The dead end is the only way out of S1 without a connection, and it
        # never returns "continue": it reboots, powers off, or comes back here
        # (return 1). Nothing is recorded on the way in -- a user who goes back
        # to the list did not stop the install, and a record saying they did
        # would be a lie about a run that is still going.
        deck_form_net_dead_end
        continue
        ;;
    esac

    local idx
    if ! idx=$(deck_form_row_index "$rows" "$choice"); then continue; fi
    if ! line=$(deck_form_network_at "$parsed" "$idx"); then continue; fi
    ssid=${line%%$'\t'*}
    security=${line#*$'\t'}
    security=${security%%$'\t'*}
    class=$(deck_form_net_security_class "$security")

    if [[ $class == unsupported ]]; then
      say --foreground 1 "$(deck_form_sanitize_ssid "$ssid") uses enterprise security ($security), which needs a certificate this installer cannot collect."
      say "Pick another network -- the install needs one it can join on its own."
      continue
    fi

    while true; do
      join_rc=0
      deck_form_wifi_join "$iface" "$ssid" "$class" || join_rc=$?
      [[ $join_rc -eq 3 ]] || break    # 3 == the DHCP menu's "Try again"
    done
    case $join_rc in
      0)
        rm -f "$parsed" "$rows"
        return 0
        ;;
      # Every other status -- including the failure menu's own answers -- goes
      # back to the list. There is no longer a status that leaves this screen
      # without a network; that door is the dead end, and it is a row on the
      # list rather than an exit hidden behind a failed join.
      *) continue ;;
    esac
  done
}

# ===========================================================================
# S8 -- Failure: MOVED. It was never in the right process, and the rows here
# were the wrong rows.
# ===========================================================================
#
# 🔴 REMOVED 2026-08-12, and the removal is the point. This file used to
# define `failure_menu` plus a row list and a decision layer for it, all
# fully unit-tested and all DEAD: upstream's `failure_menu` lives at
# `omarchy-install-dashboard:609` and is called at `:735` -- a SEPARATE
# PROCESS that never sources this file. `configurator` does not contain the
# name at all.
#
# ⚠️ And the rows were wrong on top of being unreachable. Ours offered
# "Retry install", which the dashboard has no mechanism to perform, and
# omitted upstream's own "Upload log for support". So relocating this code
# unchanged -- which `docs/tasks/T4a-dashboard-screens.md` §4 originally
# suggested -- would have shipped a menu that lies about what it can do.
#
# ➡️ S8 now lives in `src/deck-dashboard.sh`, which wraps upstream's REAL
# menu (Upload log / View full log / Reboot / Power off, reusing upstream's
# own helpers) and fixes only the actual defect: "Drop to shell" is removed,
# and a cancelled `gum choose` -- the one thing a controller-only Deck can
# express, via B/Esc -- now redraws instead of dropping to a bare shell.
#
# Deleting tested code feels like a loss. It is not: every one of those
# assertions passed against a function nothing could ever call, in a shape
# that contradicted upstream. That is the exact false confidence
# T4-screen-spec.md §6.4 exists to prevent.
# ===========================================================================
# S2 -- Region (timezone)
# ===========================================================================
#
# T4-screen-spec.md §4 S2: narrowed to timezone only (§3 deviation 2 -- the
# keyboard-layout half is a DIFFERENT override, `omarchy_prompt_keyboard`,
# out of this session's five named screens; not touched here).
#
# Overrides `omarchy_prompt_timezone` -- the REAL name: `user_form` calls it
# at `configurator` line 260, read directly this session (not inferred).
# Upstream's own contract (same file, `user_step`'s recap table and both
# JSON writers): sets the global `timezone`.
#
# The flat ~600-row `timedatectl list-timezones` list is replaced by a
# two-level area/city pick (§3 deviation 3) because lizard mode has no
# PageUp/PageDown (§2.1) and `gum filter`'s narrow-by-typing fallback needs
# an OSK this screen does not raise (no text entry here at all -- see below).

# deck_form_tz_areas <timezone-list-file>
# The area list is DERIVED from the fixture/live list itself (the first
# path component of every entry, plus the bare "UTC" line as its own
# pseudo-area) rather than a hand-typed array -- so "every area present" is
# true by construction against whatever `timedatectl` actually returns,
# instead of this file's own guess at the IANA zone tree's shape.
deck_form_tz_areas() {
  local file=$1
  awk -F/ '{ print $1 }' "$file" | LC_ALL=C sort -u
}

# deck_form_tz_cities_for_area <timezone-list-file> <area>
# Everything after "<area>/" for that area; the bare "UTC" line maps to the
# single pseudo-city "UTC" so the UTC "area" is reachable and selectable the
# same way every other area is (T4-screen-spec.md §4 S2: "UTC reachable").
deck_form_tz_cities_for_area() {
  local file=$1 area=$2 line
  while IFS= read -r line; do
    if [[ $line == "$area" ]]; then
      [[ $area == UTC ]] && printf 'UTC\n'
      continue
    fi
    [[ $line == "$area"/* ]] || continue
    printf '%s\n' "${line#"$area"/}"
  done <"$file" | LC_ALL=C sort -u
}

# deck_form_tz_full <area> <city>
# Inverse of the split above -- UTC/UTC collapses back to the bare zone name
# "UTC" (what `timedatectl` and the JSON writer's "$timezone" both expect),
# every other pair rejoins with a single slash.
deck_form_tz_full() {
  local area=$1 city=$2
  if [[ $area == UTC && $city == UTC ]]; then
    printf 'UTC\n'
  else
    printf '%s/%s\n' "$area" "$city"
  fi
}

# T4-screen-spec.md §4 S2's own verified-by row, quoted exactly: the guess
# "must match ^[A-Za-z_]+/[A-Za-z0-9_+-]+$ or be discarded" -- tzupdate's
# output is network-derived text (§4 S1's own "hostile SSID" reasoning
# applies just as much to a geo-IP lookup result). ⚠️ This pattern (copied
# verbatim from the spec) has no allowance for a THIRD path segment
# (e.g. "America/Argentina/Buenos_Aires", a real IANA zone) -- a known,
# spec-inherited limitation, not something introduced here.
readonly DECK_TZ_GUESS_PATTERN='^[A-Za-z_]+/[A-Za-z0-9_+-]+$'
readonly DECK_TZ_DEFAULT_AREA=Europe
readonly DECK_TZ_FALLBACK_TZ=UTC

# deck_form_tz_sanitize_guess <raw-guess>
# Prints the guess back out (trimmed) if it matches the pattern above;
# returns 1 and prints nothing otherwise -- "discarded", per the spec.
deck_form_tz_sanitize_guess() {
  local raw
  raw=$(deck_form_trim "$1")
  if [[ $raw =~ $DECK_TZ_GUESS_PATTERN ]]; then
    printf '%s\n' "$raw"
    return 0
  fi
  return 1
}

deck_form_tz_guess_area() { printf '%s\n' "${1%%/*}"; }
deck_form_tz_guess_city() { printf '%s\n' "${1#*/}"; }

# deck_form_tz_default_area
# §4 S2's stated no-guess fallback: "the area list opens on Europe with
# nothing pre-selected, which is a visible default, not a silent one."
deck_form_tz_default_area() { printf '%s\n' "$DECK_TZ_DEFAULT_AREA"; }

# omarchy_prompt_timezone -- overrides upstream's own S2 screen.
#
# Thin on purpose, same split as S8's failure_menu/deck_form_failure_action_for:
# every decision the [U] suite can actually prove lives in the pure functions
# above; this loop's own gum choose/tzupdate/timedatectl calls are real side
# effects, proven at [V] (T4-screen-spec.md §6.1's own tier assignment for
# exactly this kind of function).
#
# Overridable via DECK_TZ_LIST_CMD_OVERRIDE / DECK_TZ_GUESS_CMD_OVERRIDE so
# a [V]-tier or manual run can point this at something other than the real
# `timedatectl`/`tzupdate` binaries; the [U] suite exercises the pure
# functions directly instead of this wrapper, so it does not need them.
omarchy_prompt_timezone() {
  local list_cmd=${DECK_TZ_LIST_CMD_OVERRIDE:-timedatectl list-timezones}
  local guess_cmd=${DECK_TZ_GUESS_CMD_OVERRIDE:-tzupdate -p}
  local tzlist_file guess="" raw_guess area city full

  tzlist_file=$(mktemp) || { deck_form_die "mktemp failed"; return 1; }
  # shellcheck disable=SC2086  # deliberately word-split: these are command lines, not paths
  $list_cmd >"$tzlist_file" 2>/dev/null

  if [[ ! -s $tzlist_file ]]; then
    deck_form_warn "timedatectl list-timezones returned nothing -- falling back to $DECK_TZ_FALLBACK_TZ"
    say "No timezone list is available -- defaulting to $DECK_TZ_FALLBACK_TZ."
    timezone=$DECK_TZ_FALLBACK_TZ
    rm -f "$tzlist_file"
    return 0
  fi

  if command -v "${guess_cmd%% *}" >/dev/null 2>&1; then
    # shellcheck disable=SC2086  # deliberately word-split, see list_cmd above
    raw_guess=$($guess_cmd 2>/dev/null | tail -1) || raw_guess=""
    guess=$(deck_form_tz_sanitize_guess "$raw_guess") || guess=""
  fi

  area=$(deck_form_tz_default_area)
  [[ -n $guess ]] && area=$(deck_form_tz_guess_area "$guess")

  while true; do
    step "Where are you?"
    if [[ -n $guess ]]; then
      say "Detected: $guess -- press A to keep it"
    fi
    area=$(deck_form_tz_areas "$tzlist_file" | gum choose --header "Area" --selected "$area") ||
      { rm -f "$tzlist_file"; return 1; }

    local city_sel=""
    [[ -n $guess ]] && [[ $(deck_form_tz_guess_area "$guess") == "$area" ]] &&
      city_sel=$(deck_form_tz_guess_city "$guess")
    city=$(deck_form_tz_cities_for_area "$tzlist_file" "$area" | gum choose --header "City in $area" --selected "$city_sel") ||
      continue   # B from the city list: back to the area list

    full=$(deck_form_tz_full "$area" "$city")
    timezone=$full
    rm -f "$tzlist_file"
    return 0
  done
}

# ===========================================================================
# S4 -- Disk
# ===========================================================================
#
# T4-screen-spec.md §4 S4, §3 deviation 5, and the task's own constraint:
# `docs/PROGRESS.md` §5.12 -- the 4.0 installer defaults to FULL-DISK
# ENCRYPTION, which bricks a keyboard-less Deck at the LUKS prompt. The
# ENCRYPTION-DEFAULT DECISION ITSELF (§5.12, `docs/tasks/T5-fork-plan.md`
# §5.5) is not this file's to make in the sense of picking a policy --
# T4-screen-spec.md §3 deviation 4 ALREADY MADE that decision in the spec
# this file implements: "Encryption: cut as a screen; it is a constant,
# `false`." What follows enforces that constant unconditionally: no Ctrl+C
# toggle exists in ANY override below, ever -- unlike upstream, where the
# toggle is merely hidden behind a key this hardware cannot produce (§2.2
# item 1), here it does not exist as code at all.
#
# ⚠️ WHAT THIS FILE CANNOT FIX: `docs/PROGRESS.md` §5.12a /
# `docs/tasks/T5-fork-plan.md` §5.1's coupling box -- upstream's
# `configure_login` (in the ORCHESTRATOR, `phases_impl.py`, a Python file in
# a completely different component this file has no reach into at all, not
# even in principle the way `omarchy-install-dashboard` at least shares a
# process boundary with something) writes `autologin.conf` only
# `if ctx.encrypt`. Forcing `encrypt_installation=false` here, correctly,
# ALSO means a Deck installed through this file boots to an unanswerable
# SDDM password prompt unless something else guarantees autologin
# unconditionally -- T5's job (§5.1+§5.5, "do them in the same slice or
# neither"), not reachable from `configurator` at all. Building S4 without
# saying this would be reporting an unbricking fix that only replaces one
# brick with another. Said here, and in this session's final report.

# deck_form_disk_list <lsblk-fixture-file> [<exclude-device>]
# lsblk-fixture-file: lines of "NAME TYPE RM TRAN" (matches
# `lsblk -dpno NAME,TYPE,RM,TRAN`'s own column order). Eligible targets are
# the built-in NVMe (TYPE==disk, RM==0, TRAN==nvme) AND the Deck's microSD
# reader (TYPE==disk, NAME ^/dev/mmcblk[0-9]+$). The SD match is by NAME,
# not by TRAN/RM, on purpose: lsblk reports the reader's TRAN as empty or
# "mmc" and RM as 0 or 1 depending on kernel/card, so neither field
# identifies it robustly. USB (TRAN==usb, or a /dev/sd* name) is never a
# target, and a USB NVMe enclosure must not be mistaken for the internal
# drive either (TRAN distinguishes the bus for NVMe; the name does not).
# EXCLUDE-DEVICE (the resolved boot/install medium, upstream's own
# `get_root_disk` walk) is dropped by exact NAME match -- so an ISO booted
# from microSD never lists that card. An empty result is a REPORTED failure
# (return 1), never a silently empty list -- §4 S4's own verified-by row.
deck_form_disk_list() {
  local file=$1 exclude=${2:-}
  local name type rm tran found=0
  while read -r name type rm tran; do
    [[ -n $name ]] || continue
    [[ $type == disk ]] || continue
    if [[ $name =~ ^/dev/mmcblk[0-9]+$ ]]; then
      : # microSD: eligible regardless of TRAN/RM (see above)
    elif [[ $tran == nvme && $rm == 0 ]]; then
      : # built-in NVMe
    else
      continue
    fi
    [[ -n $exclude && $name == "$exclude" ]] && continue
    printf '%s\n' "$name"
    found=1
  done <"$file"
  if [[ $found -eq 0 ]]; then
    deck_form_warn "no eligible install disk found in $file (no built-in NVMe or microSD: every candidate is USB, removable non-SD, or the boot medium)"
    return 1
  fi
  return 0
}

# deck_form_disk_is_sd <device> -- 0 iff the device is the microSD reader
# path (/dev/mmcblkN, whole disk). Shared by the label and the row text so
# the two can never disagree about which drive is the card.
deck_form_disk_is_sd() {
  [[ ${1:-} =~ ^/dev/mmcblk[0-9]+$ ]]
}

# deck_form_disk_label <device>
# "Internal SSD (NVMe) <vendor+model> (<size>)" or "microSD card (<size>)";
# falls back to the bare device path when lsblk has nothing to say. Used by
# the drive screen rows and the S5 summary row, so the two can never
# independently drift. DECK_LSBLK_BIN is overridable so the [U] suite can
# point this at a fake `lsblk` instead of needing a real block device.
deck_form_disk_label() {
  local device=$1 lsblk=${DECK_LSBLK_BIN:-lsblk}
  local size vendor model label prefix=""
  size=$("$lsblk" -dno SIZE "$device" 2>/dev/null)
  vendor=$("$lsblk" -dno VENDOR "$device" 2>/dev/null | sed 's/ *$//')
  model=$("$lsblk" -dno MODEL "$device" 2>/dev/null | sed 's/ *$//')
  if deck_form_disk_is_sd "$device"; then
    prefix="microSD card"
  else
    prefix="Internal SSD (NVMe)"
  fi
  if [[ -n $vendor && -n $model && $model != *"$vendor"* ]]; then
    label="$vendor $model"
  elif [[ -n $model ]]; then
    label=$model
  elif [[ -n $vendor ]]; then
    label=$vendor
  else
    label=$device
  fi
  if [[ -n $size ]]; then
    printf '%s %s (%s)\n' "$prefix" "$label" "$size"
  else
    printf '%s %s\n' "$prefix" "$label"
  fi
}

# deck_form_disk_encryption_mode
# T4-screen-spec.md §6.5's own named example of a single-string mutation a
# shallow test would miss ("the encryption constant"). Pulled into its own
# one-line function, rather than inlined in confirm_disk_overwrite, purely
# so the [U] suite can assert this exact fact directly instead of only
# indirectly through a gum-driving function it cannot safely execute.
deck_form_disk_encryption_mode() { printf 'false\n'; }

# Upstream's S4 erase-confirm screen is gone (the wipe confirm is now
# `deck_form_wipe_confirm`, asked with S0's A/B key reader between the
# drive list and the early start), so confirm_disk_overwrite below returns
# 0 without drawing anything, and there is no gum confirm whose default
# could drift back to the dangerous affirmative.

readonly -a DECK_DISK_DEAD_END_ITEMS=(Reboot "Power off")

deck_form_disk_dead_end_items() { printf '%s\n' "${DECK_DISK_DEAD_END_ITEMS[@]}"; }

# deck_form_disk_dead_end_action_for <gum-choose-output-or-empty>
# Same shape and same reason as deck_form_failure_action_for: an empty or
# unrecognised choice redraws, NEVER guesses at reboot/poweroff -- §4 S4:
# "a dead-end screen offering Reboot / Power off, never a shell."
deck_form_disk_dead_end_action_for() {
  local choice=$1
  case $choice in
    Reboot)       printf 'reboot\n' ;;
    "Power off")  printf 'poweroff\n' ;;
    *)            printf 'redraw\n' ;;
  esac
}

# deck_form_disk_dead_end -- the "no eligible disk" screen.
# Thin wrapper around the pure decision above, proven at [V] like
# failure_menu. Never returns to a caller that would fall through to a bare
# shell; if systemctl itself fails, the loop simply redraws rather than
# guessing at anything else to do.
deck_form_disk_dead_end() {
  local choice action systemctl_bin=${DECK_SYSTEMCTL_BIN:-systemctl}
  while true; do
    clear_logo
    echo
    say --foreground 1 "No eligible install disk was found."
    say "Every disk on this machine is either removable or is the boot medium."
    echo
    choice=$(deck_form_disk_dead_end_items | gum choose --header "What next?") || choice=""
    action=$(deck_form_disk_dead_end_action_for "$choice")
    case $action in
      reboot)   "$systemctl_bin" reboot ;;
      poweroff) "$systemctl_bin" poweroff ;;
      *)        : ;;
    esac
  done
}

# deck_form_eligible_disks -- the resolver the drive screen and the S0 flow
# share. Built-in NVMe + microSD (see deck_form_disk_list), boot-medium
# exclusion via upstream's own get_root_disk walk. Fails loudly when
# nothing is eligible. Never draws anything: safe to call before any screen.
deck_form_eligible_disks() {
  local boot_source exclude_disk lsblk_bin=${DECK_LSBLK_BIN:-lsblk}
  boot_source=$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || true)
  if [[ -z $boot_source ]]; then
    deck_form_warn "could not determine the live boot medium (findmnt gave no source for /run/archiso/bootmnt) -- the boot-medium exclusion cannot work, so the boot device may be listed as an install target"
  fi
  exclude_disk=$(get_root_disk "$boot_source")

  local lsblk_tmp
  lsblk_tmp=$(mktemp) || { deck_form_die "mktemp failed"; return 1; }
  "$lsblk_bin" -dpno NAME,TYPE,RM,TRAN >"$lsblk_tmp" 2>/dev/null
  deck_form_disk_list "$lsblk_tmp" "$exclude_disk"
  local rc=$?
  rm -f "$lsblk_tmp"
  return $rc
}

# deck_form_drive_row <device> -- one controller-navigable chooser row:
# "device | label". The device path is the machine-readable half (row
# parsing splits on the first " | "); the label is deck_form_disk_label.
deck_form_drive_row() {
  local device=$1 label
  label=$(deck_form_disk_label "$device")
  printf '%s | %s\n' "$device" "$label"
}

# deck_form_drive_device_for <chooser-row> -- the device half of a row, or
# empty when the row is not one of ours. Empty/cancel redraws, never guesses.
deck_form_drive_device_for() {
  local row=${1:-}
  [[ $row == "/dev/"*" | "* ]] || return 1
  printf '%s\n' "${row%% | *}"
  return 0
}

# deck_form_drive_screen <result-var> -- the NEW drive selection screen.
# Lists every eligible target (NVMe and microSD) with its label, always --
# even with exactly one entry, so the user sees what will be wiped. Stores
# the chosen device, or "back" on B/Esc, in $result-var and returns 0.
# Zero eligible is the existing dead end (never returns). Unrecognised rows
# redraw, never guess at a wipe target.
deck_form_drive_screen() {
  local resultvar=$1 eligible device rows choice picked
  if ! eligible=$(deck_form_eligible_disks); then
    deck_form_disk_dead_end
    abort "No eligible install disk was found."
    return 1
  fi
  rows=""
  while IFS= read -r device; do
    [[ -n $device ]] || continue
    rows="${rows}$(deck_form_drive_row "$device")"$'\n'
  done <<<"$eligible"
  [[ -n $rows ]] || {
    deck_form_disk_dead_end
    abort "No eligible install disk was found."
    return 1
  }
  while true; do
    clear_logo
    echo
    say "Where should Omarchy be installed?"
    # Plain `say`, NOT --foreground 8: on hardware this line drew faint gray
    # and read as decoration next to the question. It states the consequence
    # of the choice below, so it draws in the question's own colour.
    say "The drive you choose will be wiped. B goes back."
    choice=$(printf '%s' "$rows" | gum choose --header "Select install drive") || choice=""
    if [[ -z $choice ]]; then
      printf -v "$resultvar" '%s' "back"
      return 0
    fi
    if picked=$(deck_form_drive_device_for "$choice"); then
      if LC_ALL=C command grep -qxF "$picked" <<<"$eligible"; then
        printf -v "$resultvar" '%s' "$picked"
        return 0
      fi
    fi
  done
}

# deck_form_wipe_confirm <result-var> <disk> <tty> -- the "are you sure?"
# screen. Stores "proceed" (A/Enter) or "back" (B/Esc) in $result-var and
# returns 0; returns 1 only when the tty cannot be read at all (fail
# loudly, never guess).
# The answer is read with the same single-byte A/B reader as S0
# (deck_form_s0_wait_key) -- NOT a gum confirm whose highlighted default
# could turn A into the wrong answer on the destructive question. The wipe
# starts ONLY on "proceed"; "back" returns to the drive list.
#
# The answer travels via printf -v, NOT stdout: this screen draws chrome
# (clear_logo/echo/say all write the terminal) and capturing stdout would
# swallow the blank `echo` line into the answer ("\\nproceed", which never
# equals "proceed" -- an infinite drive-confirm loop, and on the real ISO,
# not just under tests). Same reason deck_form_yesno_screen documents.
deck_form_wipe_confirm() {
  local resultvar=$1 disk=$2 tty=$3 label answer
  label=$(deck_form_disk_label "$disk")
  clear_logo
  echo
  say "Are you sure? This will wipe $label."
  say "Press A to wipe and install, B to go back"
  # A held or bouncing A from the drive screen's own answer may still be
  # queued -- or still ARRIVING, under typematic autorepeat. Drain until the
  # input has been quiet for a full release window, so only a NEW press
  # after a proven release confirms the wipe (see
  # deck_form_drain_until_quiet: a first-gap drain is defeated by a held A).
  deck_form_drain_until_quiet "$tty"
  # The tty may have been left raw (upstream's own tte animation leaves it
  # raw/no-echo when killed mid-frame -- greeter's `stty sane` note). A raw
  # tty delivers Enter as CR, which the old reader looped on forever; the
  # reader now accepts it, and this reset makes the confirm robust even if
  # something since greeter left the line discipline raw again. Never fatal
  # (deck_form_stty_sane only warns).
  deck_form_stty_sane "$tty"
  if ! answer=$(deck_form_s0_wait_key "$tty"); then
    deck_form_warn "could not read the wipe confirmation from $tty -- refusing to guess consent"
    return 1
  fi
  if [[ $answer == proceed ]]; then
    printf -v "$resultvar" '%s' "proceed"
  else
    printf -v "$resultvar" '%s' "back"
  fi
  return 0
}

# disk_form -- overrides upstream's own disk picker.
#
# FAST-INSTALL: the drive was already chosen on the drive screen and the
# wipe confirm, and the early stage is already erasing it
# (`deck_form_start_early_install` set the global `disk`). So this reuses
# that disk and draws NOTHING: re-offering a picker here -- on the Deck
# with NVMe + microSD, the old code did exactly that -- would offer a
# choice that contradicts the running wipe.
#
# If `disk` is unset at this point, that is a bug in the flow (every path
# that reaches here ran the drive screen first), so this fails loudly via
# abort instead of silently picking one.
#
# The other paths that can reach the disk machinery cannot re-offer a
# drive either: `confirm_disk_overwrite` draws nothing and returns 0, so
# upstream's `select_installation` Full-disk branch (the only one reachable
# -- `requires_full_disk_install` suppresses the mode picker) confirms
# without asking; the deferred-provisioning `disk_form` loop (unreachable
# on a Deck -- there is no Ctrl+C -- but reachable in a dry run) lands in
# the abort below rather than guessing; and `deck_final_summary`'s
# "Go back" re-runs `user_step` only, never `disk_form`.
disk_form() {
  if [[ -n ${disk:-} ]]; then
    return 0
  fi
  deck_form_warn "disk_form reached with no disk selected -- the drive screen should have set one before the early stage started. Refusing to guess which drive to erase."
  abort "No install disk was selected."
}

# requires_full_disk_install -- overrides upstream's own free-space
# eligibility check. §3 deviation 5: the free-space install mode (BitLocker
# scan, Windows-ESP detection, a `cfdisk` fallback -- none of it navigable
# with a controller, §4 S4's own citation of `run_partition_decide` /
# `not_enough_space` / `open_partition_tool`) is suppressed entirely by
# always reporting "yes, only full-disk is available", which is upstream's
# OWN existing skip path: `select_installation` sets `full_disk_only=true`
# and never calls `install_mode_form` when this returns success (0).
# Unconditional and on purpose -- this does NOT run upstream's real
# filesystem/parted probe, because the whole point is that the answer must
# always be the same regardless of what is actually on the disk.
requires_full_disk_install() { return 0; }

# confirm_disk_overwrite -- overrides upstream's own S4 confirm screen.
#
# Consent now lives earlier in the flow (S0's A plus the wipe confirm's A,
# where `deck_form_start_early_install` runs). Upstream still CALLS
# this name twice -- `select_installation`'s "Full disk install" branch and
# the `until confirm_disk_overwrite` deferred-provisioning loop -- so it
# must keep existing and must keep SUCCEEDING (return 0) without drawing
# anything: re-prompting here would offer a disk choice that contradicts
# the early stage already erasing one. `disk` was set by the confirmed
# start, `encrypt_installation` stays the unconditional constant `false`,
# and `deck_final_summary`'s "Go back" re-runs `user_step` itself (never
# `disk_form`/`select_installation`). The old gum-confirm body is
# deleted, not kept as a fallback.
confirm_disk_overwrite() {
  # shellcheck disable=SC2034
  encrypt_installation=$(deck_form_disk_encryption_mode)
  return 0
}

# ===========================================================================
# S5 -- Summary
# ===========================================================================
#
# T4-screen-spec.md §4 S5 / §1.2 patch P1 hunk 2: `deck_final_summary` is
# NOT an override of an existing upstream function -- it is the exact new
# name the spec's own patch calls directly
# (`deck_final_summary || abort`, placed immediately before
# `write_user_files`). That call site is owned by patch P1 (iso/, not this
# file), but the NAME is fixed by the spec, and defining it here is what
# makes that hunk's call resolve to something real instead of "command not
# found" the first time an install reaches it.

readonly DECK_WIFI_NOT_CONNECTED="Not connected"
readonly DECK_SUMMARY_DESKTOP=Omarchy
readonly DECK_SUMMARY_BOOT="Gaming Mode"

# ===========================================================================
# S5's pre-reboot warning (P33 L2) -- "the deck will reboot, just wait"
# ===========================================================================
#
# Operator request, 2026-08-16, after watching a real first boot:
# "can we add a warning in the step right before the reboot that the deck will
#  reboot and to just wait the two mins etc."
#
# 🔴 THE NUMBERS ARE MEASURED, NOT ROUNDED UP FOR COMFORT.
#
# ⚠️ SUPERSEDED ONCE ALREADY. This block used to say "about two minutes",
# from docs/PROGRESS.md §5.35 (2m03s, read off Steam's bootstrap_log.txt on
# the P36-era install). P37 shipped the pre-seeded Steam bootstrap AND the
# splash, and both landed, so that figure is now wrong in two ways: the wait
# is shorter, and most of it is no longer black. Re-measured 2026-08-16 on
# the P37 install over SSH, from `journalctl -b 0 -o short-precise`:
#
#   16:01:33.99  kernel starts
#   16:01:42.50  deck-steam-splash draws on gamescope-0   => 8.5s black
#   16:01:47.91  Steam: "Verifying installation..."
#   16:02:15.37  Steam: "Update complete, launching Steam..."  => 27.5s
#   16:02:21.94  splash down, steamwebhelper running     => 39.4s of splash
#
# and `systemd-analyze` on the same boot: 4.724s firmware + 7.281s loader +
# 5.756s kernel + 16.883s userspace = 34.646s. The 12.0s of firmware+loader
# is black too and precedes the journal entirely, so the black window is
# ~20s and the whole wait to Gaming Mode is ~60s.
#
# "About a minute" below is that ~60s. "About 40 seconds" is the 34.646s.
# The wording deliberately does NOT name a black-screen duration: the
# operator's 20-30s was an eyeball estimate, and a second number is a
# second thing to go stale. Say the wait, say some of it is black, stop.
#
# ⚠️ WHERE THIS *SHOULD* LIVE, AND WHY IT DOES NOT. The literal last screen
# before the reboot is S7 -- `render_finish` / `reboot_prompt`, which live in
# `omarchy-install-dashboard`, overridden in
# /usr/share/omarchy-iso/deck-dashboard.sh. That is a SEPARATE PROCESS this
# file is never sourced into (see the S8 block above: defining a name here
# that only the dashboard calls is dead code on a real ISO). S5 is the last
# screen `configurator` -- and therefore this file -- owns, so the warning is
# given here, immediately above the point of no return. Putting a second copy
# on S7 is a one-line addition to deck-dashboard.sh's `render_finish`, which
# already carries a custom line, and it is reported rather than done because
# this file's owner does not own that file.
readonly -a DECK_S5_REBOOT_LINES=(
  "When the install finishes the Deck reboots on its own."
  "The first boot then takes about a minute while Steam finishes installing itself."
  "The screen is BLACK for part of it. That is normal. Don't turn me off -- just wait."
  "After that it starts in Gaming Mode, and every later boot takes about 40 seconds."
)

# Split out for the same reason as deck_form_s0_text: asserted on the
# function's own output, not on a screenshot.
deck_form_reboot_notice_text() {
  local line
  for line in "${DECK_S5_REBOOT_LINES[@]}"; do printf '%s\n' "$line"; done
}

deck_form_reboot_notice() {
  local line
  while IFS= read -r line; do say "$line"; done < <(deck_form_reboot_notice_text)
}

# deck_form_summary_rows
# Prints "Field,Value" CSV rows -- upstream's own `user_step` table
# convention (`gum table -s ","`) -- built from the SAME globals
# `write_user_files` / the JSON writers read when they emit the real
# artefacts. T4-screen-spec.md §4 S5's own warning: "the only screen whose
# bug would be invisible in both a screenshot and an artefact taken alone"
# is exactly the case where the screen and the artefact are built from two
# DIFFERENT values that happen to agree by accident -- reading the same
# globals here is what rules that out structurally rather than by
# inspection.
#
# DECK_WIFI_SSID is set by S1's (not yet built, see this file's own header)
# interactive flow; read defensively here so this function has a defined
# answer even before that exists.
deck_form_summary_rows() {
  local pw_mask disk_label wifi_display encryption_display early_display steam_display pre_display game_display
  # shellcheck disable=SC2154  # set by upstream's user_form / S3's override -- see this file's header CORRECTION note
  pw_mask=$(printf '%*s' "${#password}" '' | tr ' ' '*')
  disk_label=$(deck_form_disk_label "$disk")
  wifi_display=${DECK_WIFI_SSID:-$DECK_WIFI_NOT_CONNECTED}
  if [[ $encrypt_installation == true ]]; then
    encryption_display=On
  else
    encryption_display=Off
  fi
  # FAST-INSTALL C4: the early stage started at S0-A and the Steam fetch
  # inside it -- read live, not from a global S1 could not have set, so the
  # row and the stage can never disagree the way DECK_NET_VERDICT once did.
  early_display=$(deck_form_early_status_display)
  steam_display=$(deck_form_steam_status_display)
  # Four-variant choices: read from the SAME globals the choice screens set
  # (which mirror the locked files -- see deck_form_choice_write), so the
  # row and Stages' input can never disagree. Unset (unattended path that
  # skipped the screens) reads as "unset", never as a guessed yes/no.
  pre_display=${DECK_PREINSTALLS:-$(deck_form_choice_read preinstalls)}
  game_display=${DECK_GAMING:-$(deck_form_choice_read gaming)}

  printf 'Field,Value\n'
  printf 'Username,%s\n' "$username"
  printf 'Password,%s\n' "$pw_mask"
  # shellcheck disable=SC2154  # set by upstream's user_form / S3's override -- see this file's header CORRECTION note
  printf 'Hostname,%s\n' "$hostname"
  printf 'Timezone,%s\n' "$timezone"
  # §5.20a. Added when the layout stopped being a constant this file forced
  # and went back to being the user's own preference: `$keyboard` is the
  # exact global `write_user_files` interpolates into `"kb_layout"`
  # (configurator:778, :1164), so the row and the artefact are the same
  # value by construction -- which is precisely §4 S5's stated property.
  # Deliberately NOT `${keyboard:-}`: an unset `keyboard` here would mean
  # the screen that sets it never ran, and printing an empty cell would hide
  # that behind a plausible-looking table.
  # shellcheck disable=SC2154  # set by keyboard_form / upstream's defer path
  printf 'Keyboard,%s\n' "$keyboard"
  printf 'Wi-Fi,%s\n' "$wifi_display"
  printf 'Disk,%s\n' "$disk_label"
  printf 'Encryption,%s\n' "$encryption_display"
  printf 'Desktop,%s\n' "$DECK_SUMMARY_DESKTOP"
  printf 'Boot,%s\n' "$DECK_SUMMARY_BOOT"
  printf 'Pre-installs,%s\n' "$pre_display"
  printf 'Gaming Mode,%s\n' "$game_display"
  printf 'Early install,%s\n' "$early_display"
  printf 'Steam download,%s\n' "$steam_display"
}

# deck_final_summary -- the S5 screen.
# FAST-INSTALL C4: the erase already began at S0-A, so this screen reports
# the early stage honestly instead of re-asking about the disk. On decline
# ("Go back") it re-runs upstream's own user_step ONLY -- no disk_form, no
# select_installation: re-offering a disk choice (or an erase confirm, via
# select_installation -> confirm_disk_overwrite) would contradict the stage
# already running on $disk.
#
# If the early stage failed, S5 says so and offers the failure menu
# (Reboot / Power off, never a shell -- the existing dead-end pattern)
# instead of Install: there is nothing to wait for and no LATE to run.
# deck_form_early_log_tail -- the last lines of the early stage's own log,
# ANSI-stripped (the log carries colour codes a bare console would print
# literally). Prints nothing and returns 1 when the log is missing,
# unreadable, or empty -- the caller says so instead of printing nothing.
deck_form_early_log_tail() {
  local file=${DECK_EARLY_LOG_FILE:-$DECK_EARLY_LOG_FILE_DEFAULT}
  local tail
  if [[ ! -r $file ]]; then
    return 1
  fi
  tail=$(tail -n "$DECK_EARLY_LOG_TAIL_LINES" -- "$file" 2>/dev/null | deck_form_strip_ansi)
  [[ -n $tail ]] || return 1
  printf '%s\n' "$tail"
  return 0
}

# deck_form_early_failed_log_notice -- the failure menu's log block, split
# out so the unit suite asserts it without driving the menu's own infinite
# loop. Prints the tail in the error colour above the menu; when the log
# cannot be shown, says that instead of printing nothing.
deck_form_early_failed_log_notice() {
  local file=${DECK_EARLY_LOG_FILE:-$DECK_EARLY_LOG_FILE_DEFAULT}
  local line log_tail
  if log_tail=$(deck_form_early_log_tail); then
    say --foreground 1 "The early install log says:"
    while IFS= read -r line; do
      say --foreground 1 "$line"
    done <<<"$log_tail"
  else
    say --foreground 1 "The early install log at $file could not be read -- it is missing or empty."
  fi
}

deck_form_early_failed_menu() {
  local choice action err systemctl_bin=${DECK_SYSTEMCTL_BIN:-systemctl}
  err=$(deck_form_early_error)
  while true; do
    clear_logo
    echo
    say --foreground 1 "The background install failed before it finished."
    [[ -n $err ]] && say --foreground 1 "$err"
    deck_form_early_failed_log_notice
    say "Nothing more can be installed from here, and Install is not offered."
    echo
    choice=$(deck_form_disk_dead_end_items | gum choose --header "What next?") || choice=""
    action=$(deck_form_disk_dead_end_action_for "$choice")
    case $action in
      reboot)   "$systemctl_bin" reboot ;;
      poweroff) "$systemctl_bin" poweroff ;;
      *)        : ;;
    esac
  done
}

deck_final_summary() {
  local early_state
  while true; do
    early_state=$(deck_form_early_status)
    if [[ $early_state == failed ]]; then
      deck_form_early_failed_menu
      abort "The background install failed."
      return 1
    fi
    clear_logo
    echo
    deck_form_summary_rows | gum table -s ',' -p | sed "s/^/${PADDING_LEFT_SPACES:-}/"
    echo
    # §5: the offline consequence is "stated once, on S1 and again on S5".
    # This is the S5 half, and since S1 stopped offering a way to decline a
    # network it is the ONLY screen a no-radio Deck meets it on that it has to
    # answer. Keyed on the same global the Wi-Fi row
    # above is built from, so the sentence and the row can never disagree.
    #
    # P33 L1: it now recaps the state S1 DETECTED (DECK_NET_VERDICT) rather
    # than assuming "no SSID" means "no network" -- a Deck on a dock's
    # ethernet has no SSID and is perfectly fine, and telling that user their
    # Deck will boot black would be a false statement on the last screen
    # before the install. An unset verdict means S1 never ran (this screen is
    # reachable on its own from `user_step`'s recap loop), and the safe
    # reading of "we do not know" is the warning, not the reassurance.
    if [[ -z ${DECK_WIFI_SSID:-} ]]; then
      local net_verdict=${DECK_NET_VERDICT:-$DECK_NET_VERDICT_DEFAULT}
      say --foreground 3 "$(deck_form_offline_headline "$net_verdict")"
      [[ $net_verdict == online ]] || deck_form_wifi_offline_notice
      echo
    fi
    # P33 L2. Unconditional -- every install reboots, and the two-minute black
    # panel is not conditional on anything the screens above decided.
    deck_form_reboot_notice
    echo
    if gum confirm --affirmative "Install" --negative "Go back" --default=true "Ready to install?"; then
      return 0
    fi
    user_step || return 1
  done
}

# ===========================================================================
# S6 -- THE KERNEL. One kernel on the installed Deck, and it is linux-omarchy.
# ===========================================================================
#
# Operator decision, 2026-09-17 (v4.0.4 rebase): the installed Deck boots
# linux-omarchy and NOTHING ELSE. No stock `linux`, no second kernel, no
# fallback entry. Upstream's own default is now linux-omarchy for non-T2
# machines, so the Deck branch agrees with stock omarchy-iso on the package
# name -- the override still exists because T2 probing must never run on Deck
# hardware, and because a bare upstream default is not a Deck decision.
#
# 🔴 WHY THIS IS AN OVERRIDE AND NOT A PACKAGE-LIST LINE.
#
# Stock `linux` does not come from any package list this repo owns. It comes
# from archinstall itself:
#
#   archinstall_adapter.py:139   Installer(..., kernels=arch_config.kernels)
#   phases_impl.py:257           installer.minimal_installation(...)
#
# and `arch_config.kernels` is read out of `user_configuration.json`, which
# THIS SCRIPT'S HOST writes, from `$kernel_choice`:
#
#   configurator:824             "kernels": [ "$kernel_choice" ],   (free_space)
#   configurator:1213            "kernels": [ "$kernel_choice" ],   (full_disk)
#
# and `$kernel_choice` is assigned, at both sites, from `detect_kernel`. As
# of omarchy-iso 7cfb7111 upstream's own default answer is linux-omarchy for
# non-T2 machines -- the right package, chosen for the wrong reason. Without
# this override a Deck would still land on linux-omarchy, but only because no
# T2 PCI ID matched, and a future upstream default move would silently move
# the Deck with it. The override names the Deck kernel deliberately, and
# keeps Deck detection ahead of the T2 probe, so the target gets ONE kernel
# and ONE UKI and Limine's ordering never decides what boots.
# (Nobody has measured ESP headroom for two ~75 MB UKIs either.)
#
# 🔴 THE ORDERING, WHICH IS THE ONLY THING THAT MAKES THIS WORK.
#
# A redefinition only takes effect if the `source` happens before the CALL.
# Verified against the pinned submodule iso/upstream @ 7cfb7111a, by line
# number, not by memory:
#
#   414   detect_kernel() { ... }                  definition
#   665   kernel_choice=$(detect_kernel)           inside run_partition_decide()
#                                                  (function body, lines 520-679)
#   1035  defer_provisioning=false                 <-- deck-form-invocation.patch
#   1036  install_target="full_disk"                   hunk 1's context anchor;
#                                                      the `source` lands HERE
#                                                      (patched file: 1057)
#   1040  wait_for_stable_terminal                 top-level flow starts
#   1107  kernel_choice=$(detect_kernel)           TOP LEVEL, column 0
#                                                  (patched file: 1158)
#
# Both call sites are reached AFTER the source:
#
#   * Line 1107 is the one every Deck install takes (the full_disk branch).
#     It is 101 lines BELOW the insertion point (patched file: 1158 vs 1057).
#     Unambiguous.
#   * Line 665 is a function BODY. Bodies resolve names at call time, not at
#     definition time, and run_partition_decide's only caller is
#     select_installation:1021, which itself only runs from line 1078 -- also
#     below the source. It is additionally unreachable on this ISO:
#     `requires_full_disk_install` above returns 0 unconditionally, so
#     select_installation sets full_disk_only=true, skips install_mode_form,
#     and "Free space install" can never be chosen.
#
# Nothing at configurator's top level executes detect_kernel before line 1035;
# everything above 1031 is definitions. test-deck-form.sh asserts this
# ordering mechanically against the pinned file so an upstream move that
# hoisted the call above the anchor fails the suite instead of silently
# reverting the target to an unpinned kernel.

# --- the package name ------------------------------------------------------
#
# 🔴 THIS NAME EXISTS IN TWO PLACES AND THEY MUST AGREE. It is not derived at
# runtime, deliberately:
#
#   install/omarchy-other.packages (upstream runtime)   linux-omarchy
#   here                                                DECK_KERNEL_PKG
#
# WHY NOT DERIVE IT FROM THE SHIPPED LIST. The obvious derivation is to grep
# /usr/share/omarchy-iso/omarchy-base.packages (which build-iso.sh builds by
# merging deck-install.packages into the runtime's base list) for
# `^linux-omarchy$`. Rejected, because the derivation has failure modes
# and this function CANNOT REPORT ONE. It is called as `$(detect_kernel)` --
# a command substitution, i.e. a subshell. `abort`/`exit` from in here kills
# only the subshell; configurator (no `set -e`) then carries on with
# `kernel_choice=""` and writes `"kernels": [ "" ]` into the JSON. A silent
# empty kernel is strictly worse than the problem being solved, and it is the
# same shape as the two silently-wrong globals this suite already pins.
#
# So the copies are held in agreement where failure is free and loud instead:
# test-deck-form.sh reads the runtime's omarchy-other.packages and fails if
# it disagrees. One CHECKED copy, not two hand-kept ones.
#
# linux-omarchy is upstream's generic kernel (pkgbase linux-omarchy,
# 7.2.5-4 at the v4.0.4 pin), adopted by operator decision 2026-09-17. The
# Valve Neptune series pin is retired with it: there is no series suffix to
# track on a generic kernel.
readonly DECK_KERNEL_PKG="linux-omarchy"

# --- the hardware predicate ------------------------------------------------
#
# REUSED, NOT INVENTED: this is src/omarchy-deck-kernel.sh's own Deck gate
# (lines 324-334 of that file), transcribed unchanged, down to the case-folded
# match and the vendor OR. Recorded DMI values, from that file and from
# test/unit/test-steamos-shims.sh (read off the physical Galileo test unit,
# 2026-08-15): product_name is "Galileo" (OLED) or "Jupiter" (LCD); sys_vendor
# is "Valve". The QEMU suites feed the same strings
# (`-smbios type=1,manufacturer=Valve,product=Galileo`).
#
# 🔴 WHAT AN LCD DECK (Jupiter) GETS, AND WHY. It gets linux-omarchy, the
# same as an OLED. This is a deliberate call, not an oversight:
#
#   * CLAUDE.md's constraint is "OLED is the only VERIFIED hardware ... don't
#     CLAIM LCD support that hasn't been tested". It is a rule about claims,
#     not a rule that every path must refuse to run on a Jupiter. The
#     sibling gate in src/omarchy-deck-kernel.sh -- which modifies the boot
#     chain, a strictly more dangerous act than naming a package -- already
#     resolved this exact question the same way, in its own words: "the LCD
#     string is accepted here because refusing to run is worse than running
#     on an untested-but-plausible Deck, but nothing downstream claims LCD
#     support." Diverging here would leave the ISO's installer and the
#     installed system's own kernel manager disagreeing about what a Deck is.
#   * The alternative is worse on its own terms. Refusing here does not mean
#     "no kernel"; it means the else branch, which on current upstream is
#     still linux-omarchy -- but reached by accident (no T2 PCI ID) rather
#     than by Deck detection, and hostage to the next upstream default move.
#     Naming it here makes the Deck path deliberate rather than coincidental.
#   * linux-omarchy is a single generic kernel: there is no per-model split
#     to choose between, so "the right kernel for a Jupiter" is not a
#     different package.
#
# ⚠️ Being honest about what is unproven: linux-omarchy has never been booted
# on a Jupiter by this project. NOTHING anywhere in this repo may state
# that LCD is supported on the strength of this comment -- the claim being
# made here is only "the generic kernel is the better of the unverified
# options on that model", which is a reasoned default, not a measurement.
#
# The two sysfs reads are behind DECK_* overrides so the [U] suite can fake
# every branch in a temp dir, matching DECK_NET_SYSFS / DECK_LSBLK_BIN etc.
readonly DECK_DMI_PRODUCT_DEFAULT=/sys/class/dmi/id/product_name
readonly DECK_DMI_VENDOR_DEFAULT=/sys/class/dmi/id/sys_vendor

# deck_form_is_steam_deck -- the predicate, pulled out of detect_kernel so the
# [U] suite can assert the hardware decision directly rather than only through
# the kernel name it produces (same reason deck_form_disk_encryption_mode is
# its own one-liner: T4-screen-spec.md §6.5's "a single-string mutation a
# shallow test would miss").
# Returns 0 on Steam Deck hardware of EITHER model, 1 otherwise. Never fails
# on an unreadable/absent sysfs node -- an absent node is a legitimate
# "not a Deck" answer (a VM, a laptop), not an error.
# (Unchanged by the OLED wipe gate below: kernel SELECTION stays broad --
# naming linux-omarchy on a Jupiter is harmless and reversible. Wiping is
# not, so the wipe has its own narrower predicate.)
deck_form_is_steam_deck() {
  local product="" vendor=""
  local product_path=${DECK_DMI_PRODUCT:-$DECK_DMI_PRODUCT_DEFAULT}
  local vendor_path=${DECK_DMI_VENDOR:-$DECK_DMI_VENDOR_DEFAULT}

  # `if/fi`, not `[[ ... ]] && ...`: this file is sourced into test-deck-form.sh
  # under `set -e`, where a trailing && list that evaluates false would abort
  # the whole suite rather than take the "not a Deck" branch.
  if [[ -r $product_path ]]; then product=$(<"$product_path"); fi
  if [[ -r $vendor_path ]];  then vendor=$(<"$vendor_path");  fi

  [[ ${product,,} =~ (steam\ deck|jupiter|galileo) || ${vendor,,} == *valve* ]]
}

# deck_form_is_oled_deck -- the WIPE gate. product_name==Galileo AND
# sys_vendor contains Valve, EXACT on the product (the recorded factory
# string). Narrower than deck_form_is_steam_deck ON PURPOSE: the kernel
# predicate accepts Jupiter and generic Valve strings because naming
# linux-omarchy there is harmless and reversible; wiping a disk is not. An
# LCD Deck (Jupiter, unverified), a generic laptop NVMe, or unreadable DMI
# all answer 1: the S0-A wipe refuses, loudly, before anything is erased.
# Shares the DECK_DMI_PRODUCT/DECK_DMI_VENDOR seams so the [U] suite fakes
# every branch in a temp dir.
deck_form_is_oled_deck() {
  local product="" vendor=""
  local product_path=${DECK_DMI_PRODUCT:-$DECK_DMI_PRODUCT_DEFAULT}
  local vendor_path=${DECK_DMI_VENDOR:-$DECK_DMI_VENDOR_DEFAULT}

  if [[ -r $product_path ]]; then product=$(<"$product_path"); fi
  if [[ -r $vendor_path ]];  then vendor=$(<"$vendor_path");  fi

  # Trailing newlines are command-substitution-stripped by $(<...); a
  # literal "Galileo\n" from sysfs therefore compares equal. Embedded
  # whitespace or case drift does NOT match: fail closed, never fuzzy.
  if [[ $product == Galileo && $vendor == *Valve* ]]; then
    return 0
  fi
  return 1
}



# detect_kernel -- OVERRIDES upstream's own (configurator:414).
#
# The name is upstream's exactly. It has to be: a definition under any other
# name is not a broken override, it is NO override, silently, and the target
# quietly gets whatever upstream's default is while every unit test on the
# helper above stays green. test-deck-form.sh's override-name scanner already
# covers this class, and a dedicated assertion pins this one by definition site.
detect_kernel() {
  if deck_form_is_steam_deck; then
    printf '%s\n' "$DECK_KERNEL_PKG"
    return 0
  fi

  # TRANSCRIBED FROM UPSTREAM, iso/upstream @ 7cfb7111a, configurator:414-420,
  # verbatim apart from the DECK_LSPCI_BIN test seam (which defaults to the
  # bare `lspci` upstream calls). Upstream's own comment: "T2 Macs need their
  # own kernel for keyboard/wifi drivers."
  #
  # Kept rather than deleted because this file is a WRAP, not a fork: on any
  # machine that is not a Deck -- a QEMU install, a developer's laptop, a T2
  # Mac someone points this ISO at -- the answer must be exactly what stock
  # omarchy-iso would have given, or this override has changed behaviour it
  # was never asked to change. At 7cfb7111 that answer is linux-t2 on T2
  # Macs, linux-omarchy everywhere else.
  local lspci_bin=${DECK_LSPCI_BIN:-lspci}
  if "$lspci_bin" -nn 2>/dev/null | grep -q "106b:180[12]"; then
    echo "linux-t2"
  else
    echo "linux-omarchy"
  fi
}

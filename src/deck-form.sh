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
#      functions, with two UNVERIFIED assumptions flagged inline (see
#      "INFERRED, NOT READ" below): upstream's exact variable-name contract
#      for what a prompt function sets, and the reserved-username list's
#      real contents (not available in this repo -- see the load function).
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
#      wrong passphrase, bounded at 3 / no DHCP / captive portal / skip),
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
#   - The keyboard-layout half of §3 deviation 2 ("keyboard becomes the
#     constant `us`") is `omarchy_prompt_keyboard`/`keyboard_form`, not any
#     of S2/S4/S5/S6/S7 as scoped by §4. Not touched; flagged as a gap.

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
# ⚠️ ASPIRATIONAL, NOT YET REAL: T4-screen-spec.md §2.3 names TWO mapper
# flags that do not exist in src/deck-input-mapper.py at the time this file
# was written -- `--osk-start-shown` and a machine-readable "bound" line on
# stderr. Growing the mapper to speak them is explicitly a T4/T8 follow-on,
# NOT this session's job (this session's file ownership is src/deck-form.sh
# and its test only -- src/deck-input-mapper.py is untouched). Until they
# land, the mapper this file spawns will not print DECK_OSK_BOUND_MARKER,
# deck_form_wait_for_marker will time out on every real prompt, and
# deck_form_text_prompt will degrade exactly the way §2.3 requires an
# unavailable OSK to degrade: LOUDLY, with the prompt still running. That
# degrade path is real and unit-tested below; the "OSK comes up" path is
# exercised against a FAKE mapper standing in for the not-yet-real flags.
readonly -a DECK_MAPPER_ARGS=(--osk-backend=tty --osk-start-shown)
readonly DECK_OSK_BIND_DEADLINE=5      # seconds -- §2.3 step 2's "a deadline"
readonly DECK_OSK_POLL_INTERVAL=0.1

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

# deck_form_wait_for_marker <file> <marker> <deadline-seconds> [<poll-interval>]
#
# Polls FILE for a line containing MARKER until it appears or DEADLINE
# elapses. Never blocks past the deadline -- that bound is what makes a
# hung or dead mapper a DEGRADED prompt (§2.3: "the prompt runs WITHOUT an
# OSK, which is a degradation the screen must state, not swallow") rather
# than a device with no way to advance a screen at all.
deck_form_wait_for_marker() {
  local file=$1 marker=$2 deadline=$3 interval=${4:-$DECK_OSK_POLL_INTERVAL}
  local waited=0
  while true; do
    if [[ -r $file ]] && LC_ALL=C command grep -qF -- "$marker" "$file" 2>/dev/null; then
      return 0
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

  deck_form_lizard_write "$sysfs" N ||
    deck_form_warn "could not turn lizard mode off -- this prompt runs WITHOUT the on-screen keyboard"

  if [[ -x $mapper_bin ]]; then
    "$mapper_bin" "${DECK_MAPPER_ARGS[@]}" >"$stderr_file" 2>&1 &
    mapper_pid=$!
    if deck_form_wait_for_marker "$stderr_file" "$DECK_OSK_BOUND_MARKER" "$deadline"; then
      osk_up=1
    else
      deck_form_warn "on-screen keyboard did not report bound within ${deadline}s -- this prompt runs WITHOUT it"
    fi
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

readonly -a DECK_S0_LINES=(
  "This installs Omarchy on your Steam Deck and erases the internal drive."
  "It includes proprietary firmware from AMD and Valve (graphics, Wi-Fi, Bluetooth, audio DSP) -- the Deck does not work without it."
  "Steam and the audio DSP firmware are downloaded from Valve during setup."
)
readonly DECK_S0_PROMPT_LINE="Press A to begin"

# deck_form_s0_text
# Split out so the [U] suite asserts on the FUNCTION'S OWN OUTPUT
# (T4-screen-spec.md §4 S0: "asserted on the function's output, not on a
# screenshot") rather than needing a tty to read a screen back from.
deck_form_s0_text() {
  local line
  for line in "${DECK_S0_LINES[@]}"; do printf '%s\n' "$line"; done
  printf '%s\n' "$DECK_S0_PROMPT_LINE"
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
  deck_form_s0_text
  deck_form_stty_sane "$tty"
  IFS= read -r _ <"$tty" 2>/dev/null
  # Never gated on its status: S1 returns 0 on every path a user can reach
  # (§5 -- "the install must still succeed"), so a nonzero here is this
  # file's own plumbing failing, which is logged rather than swallowed and
  # still does not stop the install.
  deck_form_wifi_screen ||
    deck_form_warn "the Wi-Fi screen returned $? -- continuing the install offline"
}

deck_form_stty_sane() {
  local tty=$1
  stty sane <"$tty" 2>/dev/null || true
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
# ⚠️ (INFERRED, NOT READ this session): the array name below,
# DECK_RESERVED_USERNAMES_VAR's value, is this file's ASSUMPTION about what
# setup-form.sh calls its own reserved-name list -- the spec says "a
# 51-name list" but does not name the variable, and this session had no
# access to the file itself (see docs/tasks/T4-screen-spec.md §10's own
# "not done" list). Verify the real name against the vendored copy before
# this ships. Until then this degrades LOUDLY (warns, treats the list as
# empty) rather than silently validating against nothing while looking like
# it checked something.
readonly DECK_SETUP_FORM_SH=/usr/share/omarchy-iso/setup-form.sh
readonly DECK_RESERVED_USERNAMES_VAR=RESERVED_USERNAMES
declare -a DECK_LOADED_RESERVED_USERNAMES=()

# deck_form_load_reserved_usernames
# Overridable via DECK_SETUP_FORM_SH_OVERRIDE for the unit suite.
deck_form_load_reserved_usernames() {
  local setup_form=${DECK_SETUP_FORM_SH_OVERRIDE:-$DECK_SETUP_FORM_SH}
  DECK_LOADED_RESERVED_USERNAMES=()
  if [[ ! -r $setup_form ]]; then
    deck_form_warn "cannot read $setup_form -- the reserved-username list is UNAVAILABLE this run (pattern validation still applies)"
    return 1
  fi
  # ⚠️ Unset before sourcing, deliberately. `source` runs in THIS shell, so
  # a PRIOR successful load's array would otherwise still be sitting in
  # scope -- and a later call whose file fails to redefine it (corrupted,
  # replaced with something malformed) would then read that stale value
  # and report success on a list that was never actually loaded THIS time.
  # Found by running this exact suite twice in the same shell.
  unset "$DECK_RESERVED_USERNAMES_VAR" 2>/dev/null || true
  # shellcheck disable=SC1090  # a runtime/fixture path, not knowable at lint time
  source "$setup_form"
  if ! declare -p "$DECK_RESERVED_USERNAMES_VAR" >/dev/null 2>&1; then
    deck_form_warn "sourced $setup_form but it defines no '$DECK_RESERVED_USERNAMES_VAR' array -- the reserved-username list is UNAVAILABLE this run"
    return 1
  fi
  local -n src_array="$DECK_RESERVED_USERNAMES_VAR"
  DECK_LOADED_RESERVED_USERNAMES=("${src_array[@]}")
  return 0
}

deck_form_username_reserved() {
  local name=$1 candidate
  for candidate in ${DECK_LOADED_RESERVED_USERNAMES[@]+"${DECK_LOADED_RESERVED_USERNAMES[@]}"}; do
    [[ $name == "$candidate" ]] && return 0
  done
  return 1
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

omarchy_prompt_username() {
  local candidate
  while true; do
    candidate=$(deck_form_text_prompt deck_form_username_body) || return 1
    if ! deck_form_username_valid "$candidate"; then
      deck_form_warn "'$candidate' is not a valid username (lowercase letters/digits/-/_, starting with a letter or _)"
      continue
    fi
    deck_form_load_reserved_usernames
    if deck_form_username_reserved "$candidate"; then
      deck_form_warn "'$candidate' is a reserved name -- choose another"
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
      deck_form_warn "password cannot be blank"
      continue
    fi
    confirm=$(deck_form_text_prompt deck_form_confirm_body) || return 1
    if ! deck_form_passwords_match "$pw" "$confirm"; then
      deck_form_warn "passwords did not match -- try again"
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
deck_form_identity_body() {
  # (INFERRED variable names -- see the block comment above)
  # shellcheck disable=SC2034
  full_name=""
  # shellcheck disable=SC2034
  email_address=""
  printf '\n'
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
# S1 NEVER BLOCKS AND NEVER FAILS THE INSTALL. Every branch below ends in
# `return 0` from deck_form_wifi_screen: no hardware, iwd dead, no networks,
# three wrong passphrases, no DHCP, a captive portal, or an explicit Skip
# all continue the install offline with the consequence stated on screen
# (§5: "The install must still succeed. What is banned is silence").
# `greeter` therefore ignores its status -- but logs it, so a nonzero return
# is visible rather than swallowed.

readonly DECK_NET_SKIP_ROW="Skip -- set up Wi-Fi later"
readonly DECK_NET_RESCAN_ROW="Rescan"

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
# SSID, a lock glyph for anything not 'open'), then Skip, then Rescan --
# matching T4-screen-spec.md §4 S1's literal row order ("a literal final
# row Skip -- set up Wi-Fi later and Rescan").
deck_form_build_network_rows() {
  local parsed=$1
  local ssid security signal safe_ssid glyph
  while IFS=$'\t' read -r ssid security signal; do
    [[ -n $ssid ]] || continue
    safe_ssid=$(deck_form_sanitize_ssid "$ssid")
    if [[ $security == open ]]; then glyph=""; else glyph=$'\360\237\224\222 '; fi
    printf '%s%s\n' "$glyph" "$safe_ssid"
  done <"$parsed"
  printf '%s\n' "$DECK_NET_SKIP_ROW"
  printf '%s\n' "$DECK_NET_RESCAN_ROW"
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
# reason -- REDRAWS. It is deliberately NOT mapped to `skip`, even though
# skip is harmless: "the cancel fallback maps to the menu, not to an
# action" is the rule, and Skip is already a row the user can pick on
# purpose. Mutation-test target (§6.5: single-string changes).
deck_form_net_choice_action() {
  local choice=$1
  case $choice in
    "")                        printf 'redraw\n' ;;
    "$DECK_NET_SKIP_ROW")      printf 'skip\n' ;;
    "$DECK_NET_RESCAN_ROW")    printf 'rescan\n' ;;
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
readonly -a DECK_NET_FAILURE_ITEMS=("Try again" "Pick another network")
deck_form_net_failure_items() {
  printf '%s\n' "${DECK_NET_FAILURE_ITEMS[@]}"
  printf '%s\n' "$DECK_NET_SKIP_ROW"
}
deck_form_net_failure_action_for() {
  local choice=$1
  case $choice in
    "")                       printf 'redraw\n' ;;
    "Try again")              printf 'retry\n' ;;
    "Pick another network")   printf 'another\n' ;;
    "$DECK_NET_SKIP_ROW")     printf 'skip\n' ;;
    *)                        printf 'redraw\n' ;;
  esac
}

# --- §5's consequence text, stated on S1's skip and again on S5 -------------
#
# "That text is not decoration -- it is docs/tasks/T5-fork-plan.md §4.1's
# requirement (i) rendered." Kept as one function with no side effects so
# both call sites draw the SAME words and a [U] test can assert them
# without a terminal (the deck_form_s0_text pattern).
deck_form_wifi_offline_text() {
  printf '%s\n' "Without a network the install still completes, but the audio DSP firmware and Steam are not downloaded."
  printf '%s\n' "Speakers will sound thin and Gaming Mode will have no Steam until the Deck is connected."
  printf '%s\n' "Wi-Fi can be set up from Desktop Mode afterwards."
}

deck_form_wifi_offline_notice() {
  local line
  while IFS= read -r line; do say "$line"; done < <(deck_form_wifi_offline_text)
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
    deck_form_warn "the on-screen keyboard did not start -- there is no way to type here. Choose '$DECK_NET_SKIP_ROW' on the network list to continue without Wi-Fi."
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
# captive-portal rows). Prints one of retry/another/skip on stdout; loops
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
# Status vocabulary, chosen to match upstream's own three-value convention
# (§1.1 item 3) rather than inventing a fourth kind of return:
#   0  connected      DECK_WIFI_SSID is set, the profile is staged
#   1  back to list   this network did not work; the caller redraws
#   2  skip the whole screen (the user asked for it inside a failure menu)
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
      skip)    return 2 ;;
    esac
    return 1
  fi

  portal=$(deck_form_wifi_portal_check)
  if [[ $portal == portal ]]; then
    # §5: "State plainly that this network needs a browser and cannot be
    # used during install ... Do not attempt to render a portal."
    say --foreground 1 "$safe_ssid needs a web sign-in page, which this installer cannot show."
    say "Use a different network, or skip Wi-Fi and set it up from Desktop Mode later."
    action=$(deck_form_wifi_failure_menu "This network needs a browser sign-in.")
    case $action in
      retry|another) return 1 ;;
      skip)          return 2 ;;
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
  say "Connected to $safe_ssid."
  return 0
}

# deck_form_wifi_screen -- S1 itself. Always returns 0 on any path a user
# can reach; a nonzero return means this function's OWN plumbing broke.
deck_form_wifi_screen() {
  local state_dir=${DECK_NET_STATE_DIR:-$DECK_NET_STATE_DIR_DEFAULT}
  local systemctl_bin=${DECK_SYSTEMCTL_BIN:-systemctl}
  local iface parsed rows choice action line ssid security class join_rc

  DECK_WIFI_SSID=""

  step "Wi-Fi"

  if ! iface=$(deck_form_wifi_iface); then
    say "No Wi-Fi hardware found -- continuing offline."
    deck_form_wifi_offline_notice
    deck_form_wifi_record_outcome "$state_dir" no-hardware ""
    return 0
  fi

  local iwd_status
  if ! iwd_status=$("$systemctl_bin" start iwd 2>&1); then
    # §5: "Same, with the unit's status line shown. Never swallow."
    say --foreground 1 "The Wi-Fi service (iwd) would not start -- continuing offline."
    [[ -n $iwd_status ]] && say "$iwd_status"
    deck_form_wifi_offline_notice
    deck_form_wifi_record_outcome "$state_dir" iwd-failed ""
    return 0
  fi

  parsed=$(mktemp) || { deck_form_die "mktemp failed"; return 1; }
  rows=$(mktemp) || { deck_form_die "mktemp failed"; rm -f "$parsed"; return 1; }

  while true; do
    step "Wi-Fi"
    if ! deck_form_wifi_scan "$iface" "$parsed"; then
      # §5: "'Rescan' and 'Skip' only. Say 'No networks found. Move
      # closer, or skip.'" -- which is what build_network_rows produces
      # from an empty parse, since it always appends both rows.
      say "No networks found. Move closer, or skip."
    fi
    deck_form_build_network_rows "$parsed" >"$rows"

    choice=$(gum choose --header "Networks" <"$rows") || choice=""
    action=$(deck_form_net_choice_action "$choice")
    case $action in
      redraw) continue ;;
      rescan) continue ;;
      skip)
        say "Continuing without Wi-Fi."
        deck_form_wifi_offline_notice
        deck_form_wifi_record_outcome "$state_dir" skipped ""
        rm -f "$parsed" "$rows"
        return 0
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
      say "Pick another network, or skip Wi-Fi."
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
      2)
        say "Continuing without Wi-Fi."
        deck_form_wifi_offline_notice
        deck_form_wifi_record_outcome "$state_dir" skipped ""
        rm -f "$parsed" "$rows"
        return 0
        ;;
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
# lsblk-fixture-file: lines of "NAME TYPE RM" (matches
# `lsblk -dpno NAME,TYPE,RM`'s own column order). Keeps TYPE=="disk" and
# RM=="0" -- §3 deviation 5's own warning, quoted: "the microSD must be
# excluded ... by lsblk -dno RM, not by name. Excluding mmcblk* would also
# exclude the 64GB LCD Deck's internal eMMC." RM, not a name pattern, is
# the only test applied here, so an internal eMMC (RM=0) is kept exactly
# like an internal NVMe. EXCLUDE-DEVICE (the resolved boot/install medium,
# upstream's own `get_root_disk` walk -- reused live in disk_form below,
# not reimplemented here) is dropped by exact NAME match. An empty result
# is a REPORTED failure (return 1), never a silently empty list -- §4 S4's
# own verified-by row.
deck_form_disk_list() {
  local file=$1 exclude=${2:-}
  local name type rm found=0
  while read -r name type rm; do
    [[ -n $name ]] || continue
    [[ $type == disk ]] || continue
    [[ $rm == 0 ]] || continue
    [[ -n $exclude && $name == "$exclude" ]] && continue
    printf '%s\n' "$name"
    found=1
  done <"$file"
  if [[ $found -eq 0 ]]; then
    deck_form_warn "no eligible install disk found in $file (every candidate is removable or is the boot medium)"
    return 1
  fi
  return 0
}

# deck_form_disk_autoselect <newline-separated eligible devices>
# §4 S4: "When exactly one eligible disk exists -- the expected Deck case --
# the picker is skipped." Prints the device and succeeds when there is
# EXACTLY one; fails (prints nothing) for zero or more than one, so the
# caller knows a real picker is needed. A pure decision, split out
# specifically so "skip the picker with one disk, show it with two" is
# provable without a live lsblk/gum -- the same shape as
# deck_form_failure_action_for.
deck_form_disk_autoselect() {
  local list=$1 count
  count=$(printf '%s\n' "$list" | LC_ALL=C command grep -c .)
  if [[ $count -eq 1 ]]; then
    printf '%s\n' "$list"
    return 0
  fi
  return 1
}

# deck_form_disk_label <device>
# "<vendor+model> (<size>)", falling back to the bare device path if lsblk
# has nothing to say. Used both by the S4 confirm text and the S5 summary
# row, so the two can never independently drift. DECK_LSBLK_BIN is
# overridable so the [U] suite can point this at a fake `lsblk` instead of
# needing a real block device on the test machine.
deck_form_disk_label() {
  local device=$1 lsblk=${DECK_LSBLK_BIN:-lsblk}
  local size vendor model label
  size=$("$lsblk" -dno SIZE "$device" 2>/dev/null)
  vendor=$("$lsblk" -dno VENDOR "$device" 2>/dev/null | sed 's/ *$//')
  model=$("$lsblk" -dno MODEL "$device" 2>/dev/null | sed 's/ *$//')
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
    printf '%s (%s)\n' "$label" "$size"
  else
    printf '%s\n' "$label"
  fi
}

# deck_form_disk_encryption_mode
# T4-screen-spec.md §6.5's own named example of a single-string mutation a
# shallow test would miss ("the encryption constant"). Pulled into its own
# one-line function, rather than inlined in confirm_disk_overwrite, purely
# so the [U] suite can assert this exact fact directly instead of only
# indirectly through a gum-driving function it cannot safely execute.
deck_form_disk_encryption_mode() { printf 'false\n'; }

# DECK_DISK_CONFIRM_DEFAULT: §6.5's OTHER named example ("S4's default
# cursor"). gum confirm with no --default flag defaults to the AFFIRMATIVE
# (matches upstream's own confirm_disk_overwrite, which never passes
# --default and where the affirmative IS the dangerous action) --
# T4-screen-spec.md §4 S4 requires the opposite here ("The cursor starts on
# No"), so this must be explicit, and is kept as its own named constant so a
# mutation that drops or flips it is a one-line, directly assertable change.
readonly DECK_DISK_CONFIRM_DEFAULT=false

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
  local choice action
  while true; do
    clear_logo
    echo
    say --foreground 1 "No eligible install disk was found."
    say "Every disk on this machine is either removable or is the boot medium."
    echo
    choice=$(deck_form_disk_dead_end_items | gum choose --header "What next?") || choice=""
    action=$(deck_form_disk_dead_end_action_for "$choice")
    case $action in
      reboot)   systemctl reboot ;;
      poweroff) systemctl poweroff ;;
      *)        : ;;
    esac
  done
}

# disk_form -- overrides upstream's own disk picker.
# Reuses upstream's OWN `get_root_disk`/`get_disk_info` (still defined --
# this file does not override them) rather than reimplementing the boot-
# medium walk, per this file's general wrap philosophy: override only the
# screen, not machinery upstream already got right.
disk_form() {
  step "Let's select where to install Omarchy..."

  local boot_source exclude_disk lsblk_bin=${DECK_LSBLK_BIN:-lsblk}
  boot_source=$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || true)
  exclude_disk=$(get_root_disk "$boot_source")

  local lsblk_tmp
  lsblk_tmp=$(mktemp) || { deck_form_die "mktemp failed"; abort; return; }
  "$lsblk_bin" -dpno NAME,TYPE,RM >"$lsblk_tmp" 2>/dev/null

  local eligible
  if ! eligible=$(deck_form_disk_list "$lsblk_tmp" "$exclude_disk"); then
    rm -f "$lsblk_tmp"
    deck_form_disk_dead_end
    abort "No eligible install disk was found."
    return
  fi
  rm -f "$lsblk_tmp"

  local sole
  if sole=$(deck_form_disk_autoselect "$eligible"); then
    disk=$sole
    return 0
  fi

  local disk_options="" device disk_info
  while IFS= read -r device; do
    [[ -n $device ]] || continue
    disk_info=$(get_disk_info "$device")
    disk_options="$disk_options$disk_info"$'\n'
  done <<<"$eligible"

  local selected_display
  selected_display=$(echo "$disk_options" | gum choose --header "Select install disk") || abort
  disk=$(echo "$selected_display" | awk '{print $1}')
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
confirm_disk_overwrite() {
  local label confirm_status
  label=$(deck_form_disk_label "$disk")

  clear_logo
  echo
  say "Everything on $label will be erased. There is no recovery."
  say "This install is not encrypted, so the Deck can start without anyone typing a passphrase."
  echo
  gum confirm --affirmative "Yes, erase and install" --negative "No, go back" \
    --default="$DECK_DISK_CONFIRM_DEFAULT" "Confirm erasing $disk?"
  confirm_status=$?

  # Unconditional, every path through this function, including the decline
  # branch below -- there is no code path in which this is ever anything
  # but false (see deck_form_disk_encryption_mode's own comment above).
  encrypt_installation=$(deck_form_disk_encryption_mode)

  [[ $confirm_status -eq 0 ]] && return 0
  return 1
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
  local pw_mask disk_label wifi_display encryption_display
  # shellcheck disable=SC2154  # set by upstream's user_form / S3's override -- see this file's header CORRECTION note
  pw_mask=$(printf '%*s' "${#password}" '' | tr ' ' '*')
  disk_label=$(deck_form_disk_label "$disk")
  wifi_display=${DECK_WIFI_SSID:-$DECK_WIFI_NOT_CONNECTED}
  if [[ $encrypt_installation == true ]]; then
    encryption_display=On
  else
    encryption_display=Off
  fi

  printf 'Field,Value\n'
  printf 'Username,%s\n' "$username"
  printf 'Password,%s\n' "$pw_mask"
  # shellcheck disable=SC2154  # set by upstream's user_form / S3's override -- see this file's header CORRECTION note
  printf 'Hostname,%s\n' "$hostname"
  printf 'Timezone,%s\n' "$timezone"
  printf 'Wi-Fi,%s\n' "$wifi_display"
  printf 'Disk,%s\n' "$disk_label"
  printf 'Encryption,%s\n' "$encryption_display"
  printf 'Desktop,%s\n' "$DECK_SUMMARY_DESKTOP"
  printf 'Boot,%s\n' "$DECK_SUMMARY_BOOT"
}

# deck_final_summary -- the S5 screen.
# On decline ("Go back"), §4 S5: "matching upstream's existing user_step
# recap loop." Nothing later in configurator's own flow loops back INTO
# this function for us (it runs once, right before write_user_files), so
# this re-drives upstream's own user_step/disk_form/select_installation
# itself and redraws the summary -- the same recap-then-redo shape
# user_step already uses internally, applied here to the whole flow instead
# of just the account fields.
deck_final_summary() {
  while true; do
    clear_logo
    echo
    deck_form_summary_rows | gum table -s ',' -p | sed "s/^/${PADDING_LEFT_SPACES:-}/"
    echo
    # §5: the offline consequence is "stated once, on S1's skip and again
    # on S5". This is the S5 half. Keyed on the same global the Wi-Fi row
    # above is built from, so the sentence and the row can never disagree.
    if [[ -z ${DECK_WIFI_SSID:-} ]]; then
      deck_form_wifi_offline_notice
      echo
    fi
    if gum confirm --affirmative "Install" --negative "Go back" --default=true "Ready to install?"; then
      return 0
    fi
    user_step || return 1
    disk_form
    select_installation
  done
}

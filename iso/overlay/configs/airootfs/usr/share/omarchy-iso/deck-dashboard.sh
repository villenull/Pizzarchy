#!/usr/bin/env bash
# deck-dashboard.sh -- the Deck-specific install-progress/completion/failure
# screens (T4a: S6 tips, S7 completion, S8 failure menu).
#
# INSTALL PATH: this file lives in the ISO overlay, at
# iso/overlay/configs/airootfs/usr/share/omarchy-iso/deck-dashboard.sh, which
# is its SHIPPED path minus the overlay prefix -- iso/bin/build step 4 rsyncs
# overlay/configs/ over the scratch upstream tree, so it lands on the ISO at
# /usr/share/omarchy-iso/deck-dashboard.sh with no install step of its own.
# There is exactly ONE copy and this is it; it was promoted out of
# src/deck-dashboard.sh on 2026-08-12, in the same change as the patch that
# sources it. src/iso-patches/README.md states the rule: a file that ships on
# the ISO and nowhere else lives in the overlay, at its shipped path -- no
# src/ duplicate, because a second copy is drift and it hides the file from
# tools/iso-payload-audit.sh, which walks the overlay tree.
#
# ===========================================================================
# WHY THIS IS A SEPARATE FILE FROM deck-form.sh, NOT MORE FUNCTIONS IN IT
# ===========================================================================
# docs/tasks/T4a-dashboard-screens.md §0-§1 has the full argument, verified
# against the pinned iso/upstream tree, not inferred: `.automated_script.sh`
# runs `configurator` and `omarchy-install-dashboard` as TWO SEPARATE
# PROCESSES, sequentially -- `configurator` exits before the dashboard binary
# even starts. deck-form.sh is sourced into `configurator`'s process image
# (via patch P1, docs/tasks/T4-screen-spec.md §1.2); it has no reach into a
# process that does not exist yet when `configurator` runs. `tips`,
# `render_finish` and `failure_menu` are upstream names that live entirely
# inside `omarchy-install-dashboard`
# (configs/airootfs/usr/local/bin/omarchy-install-dashboard in the pinned
# iso/upstream tree) -- confirmed by grep, not assumed: that file sources
# nothing (`grep -n '^source\|^\. \|source /' ...` returns zero lines), so
# there is no seam inside it for an ADDITIVE file the way deck-form.sh is
# additive to `configurator`. The seam here is therefore a one-line PATCH,
# not a source statement inside `configurator`:
#
#     source /usr/share/omarchy-iso/deck-dashboard.sh
#
# added by iso/overlay/patches/omarchy-install-dashboard.patch immediately
# (promoted 2026-08-12, in the same change that moved THIS file into the
#  overlay -- the patch and the file it sources are one unit, and
#  test/unit/test-iso-build.sh section 19 enforces that mechanically by
#  deriving the sourced path out of every promoted patch and requiring a
#  file behind it)
# after `launch_child` (the last function `omarchy-install-dashboard`
# defines) and before that file's own main flow runs
# (`[[ -e $TTY_PATH ]] || exit 2`). Bash keeps the LAST definition of a
# name, so `tips`/`render_finish`/`failure_menu` defined below REPLACE
# upstream's own; every name this file does not redefine keeps behaving
# exactly as upstream shipped it -- the identical mechanism deck-form.sh
# uses for `configurator`, just anchored to a different file's function
# boundaries (see docs/tasks/T4a-dashboard-screens.md §1 for why THAT
# placement, and only that placement, is valid). This file has no main() and
# produces no output unless something else sources it and calls one of its
# functions. Running it directly does nothing observable, on purpose (see
# SOURCE-SAFETY below).
#
# ===========================================================================
# SOURCE-SAFETY -- read before adding ANYTHING above a function definition
# ===========================================================================
# This file is `source`d into TWO processes this repo does not control the
# internals of: upstream's `omarchy-install-dashboard` (via the patch above)
# and test/unit/test-deck-dashboard.sh (this repo's own suite, no VM).
# Everything below the constants block is therefore inside a function --
# src/deck-form.sh carries the identical rule, for the identical reason: a
# sourced file's top-level statements run at SOURCE time, in the SOURCING
# shell's own process, before any screen exists to show a symptom on.
#
# WHY THIS FILE DOES NOT ITSELF CALL `set -e`/`exit`: unlike `configurator`,
# `omarchy-install-dashboard` line 8 already runs the WHOLE script under
# `set -euo pipefail`, in effect by the time this file's source line
# executes (it is placed after line 8, not before it). This file must not
# change that behaviour for the REST of a ~90-line flow it does not own --
# the identical reasoning deck-form.sh's own header gives for `configurator`,
# just against a script that already has `-e` rather than one that might not.
# `-u`/`pipefail` are restated below anyway: harmless when `omarchy-install-
# dashboard` already set them, and load-bearing when this file is sourced
# standalone (e.g. by its own unit suite, which does not otherwise inherit
# them). Loud-failure discipline (CLAUDE.md: never silently swallow a
# failure) is enforced per FUNCTION instead, matching deck-form.sh's own
# convention: every function that can fail returns non-zero and says why via
# deck_dashboard_warn/deck_dashboard_die.
# ===========================================================================
#
# ===========================================================================
# WHAT UPSTREAM'S OWN MACHINERY IS REUSED, NOT REIMPLEMENTED
# ===========================================================================
# `center`, `blank_line`, `render_logo`, `install_duration`, `term_cols`,
# `interactive`, `find_log_uploader`, `upload_failure_log`, `view_failure_log`,
# `render_failure`, and the globals `CLEAR`/`SHOW_CURSOR`/`CONTENT_WIDTH`/
# `TTY_PATH`/`LOGO_HEIGHT`/`LOGO_PATH`/`CSI`/`OMARCHY_UI_FAILURE_ACTION` are
# all defined earlier in `omarchy-install-dashboard`, above this file's own
# source line, so they are in scope by the time any function below runs --
# and NONE of them are redefined here. This is the same "override only the
# screen, not machinery upstream already got right" rule deck-form.sh's own
# header states for S4 (`confirm_disk_overwrite` reuses `clear_logo`/`say`/
# `gum` rather than reimplementing them).

set -uo pipefail

readonly DECK_DASHBOARD_PROG=deck-dashboard

deck_dashboard_log()  { printf '[%s] %s\n' "$DECK_DASHBOARD_PROG" "$*" >&2; }
deck_dashboard_warn() { printf '[%s] WARNING: %s\n' "$DECK_DASHBOARD_PROG" "$*" >&2; }
# Never exits (see SOURCE-SAFETY above) -- logs and returns 1.
deck_dashboard_die()  { printf '[%s] ERROR: %s\n' "$DECK_DASHBOARD_PROG" "$*" >&2; return 1; }

# ===========================================================================
# S6 -- Progress tips
# ===========================================================================
#
# Overrides upstream's own 18-entry `tips` array (omarchy-install-dashboard
# lines 56-75), every one of which names a keyboard shortcut ("Super + ...")
# -- meaningless on a device with no keyboard. `tips` is DATA upstream reads
# via `current_tip()` (`"${tips[...]}"`), not a function: there is nothing
# to wrap, only to replace, so this is a plain array assignment --
# last-definition-wins, exactly like a function override, because bash
# resolves `tips` at the point `current_tip()` RUNS (after this file has
# sourced), not at the point upstream's own array literal executed.
#
# T4-screen-spec.md §4 S6's own [U] check, both enforced by
# test/unit/test-deck-dashboard.sh: no entry contains "Super"; no entry
# exceeds CONTENT_WIDTH (omarchy-install-dashboard's own LOGO_WIDTH-derived
# content column, ~81 cols against the real Deck logo -- see that file's
# `logo_width()`). Checked by eye against 81 when this array was drafted
# (docs/tasks/T4a-dashboard-screens.md §3); the unit suite checks it again,
# in bytes, so a future edit cannot silently regrow past it.
#
# ✅ THE OPEN ITEM ABOVE IS NOW CLOSED -- and it was right to worry.
#
# T4a §3 flagged that these entries named chords "on faith just because they
# read plausibly", and asked for them to be re-checked against what the input
# layer actually ships. Done 2026-08-16, against src/deck-input-mapper.py and
# against the live Deck over SSH. FOUR OF THE NINE WERE FALSE:
#
#   "Steam and Gaming Mode are always one button press away"
#       Gaming Mode is THREE presses: QAM, System, Gaming Mode. It is a
#       `system.gaming` row (deck-session.sh writes it into
#       ~/.config/omarchy/extensions/omarchy-menu.jsonc) and the dotted id
#       nests it under System. The operator caught this one on hardware.
#   "Press the STEAM button, then Power, to switch between Gaming and Desktop"
#       Same error, different route, and STEAM is not even the button.
#   "The STEAM button opens the Omarchy menu for apps, settings, and more"
#       STEAM is `omarchy-menu toggle apps` -- the APPS menu. The Omarchy
#       menu is QAM (`omarchy-menu toggle`). This had the two swapped.
#   "Use the QAM (... button) for quick settings and volume"
#       QAM opens the Omarchy menu. There is no separate quick-settings panel.
#
#   "Both trackpads act as a mouse" was half true and is now precise: the
#   pointer comes from the RIGHT pad only (POINTER_AXES / POINTER_CLICK_HALF).
#   R2/L2 were correct -- TRIGGER_BUTTON_MAP is BTN_TR2 -> BTN_LEFT,
#   BTN_TL2 -> BTN_RIGHT.
#
# Update and Style > Theme were CONFIRMED, not assumed: both are real rows in
# /usr/share/omarchy/default/omarchy/omarchy-menu.jsonc on the installed Deck
# (`update`, `style.theme`).
#
# 🔴 THE RULE THAT WOULD HAVE CAUGHT THESE EARLIER. Every entry here must name
# a chord or a menu path that some OTHER file actually implements. This file
# implements none of them, so an entry is only ever as true as the last time
# somebody checked it against that file. If you add one, cite where it lives.
# shellcheck disable=SC2034  # read by upstream's own current_tip(), not in this file
tips=(
  # deck-input-mapper.py: OSK_CHORD_HOLD (BTN_MODE) + OSK_CHORD_PRESS (BTN_NORTH)
  "STEAM + X opens the on-screen keyboard in Desktop Mode"
  # deck-input-mapper.py: CLOSE_WINDOW_ARGV, hl.dsp.window.close()
  "STEAM + Y closes the window you are looking at"
  # deck-input-mapper.py:35,38 -- `omarchy-menu toggle apps` vs `toggle`
  "The STEAM button opens the apps menu; QAM opens the Omarchy menu"
  # deck-session.sh writes the system.gaming row; System is where it nests
  "Back to Gaming Mode: press QAM, choose System, then Gaming Mode"
  # deck-input-mapper.py: POINTER_CLICK_HALF, TRIGGER_BUTTON_MAP
  "The right trackpad is the mouse -- R2 left-clicks, L2 right-clicks"
  "A controller works everywhere in Desktop Mode, not just in games"
  # omarchy-menu.jsonc: the `update` root row
  "Keep the system fresh with Update in the Omarchy menu"
  # omarchy-menu.jsonc: the `style.theme` row
  "Switch themes from Style > Theme in the Omarchy menu"
  # deck-session.sh: stage-power-button
  "The power button suspends the Deck, in Gaming Mode and on the desktop"
)

# ===========================================================================
# S7 -- Completion
# ===========================================================================
#
# Overrides upstream's own `render_finish` (omarchy-install-dashboard lines
# 451-480). T4-screen-spec.md §4 S7: "Add one line: 'Your Deck will start in
# Gaming Mode.'" -- otherwise "good" per the spec, so this reuses upstream's
# OWN structure and helpers rather than reimplementing any of them (see the
# file header's "machinery reused" list above).
#
# `reboot_prompt` (omarchy-install-dashboard lines 482-501) needs NO
# override: a single-button `gum confirm` already takes Enter (A in lizard
# mode), matching T4-screen-spec.md §4 S7's own "Works as-is" row.
render_finish() {
  local duration effect_canvas_width
  duration="$(install_duration || true)"
  duration="${duration:-Complete}"
  effect_canvas_width="$(term_cols)"
  (( effect_canvas_width > 1 )) && effect_canvas_width=$((effect_canvas_width - 1))

  {
    printf '%s%s' "$SHOW_CURSOR" "$CLEAR"
    blank_line
    render_logo
    blank_line
    center "Installed Omarchy in ${duration}" "$CONTENT_WIDTH"
    center "Your Deck will start in Gaming Mode." "$CONTENT_WIDTH"
    blank_line
  } >"$TTY_PATH"

  # Unchanged from upstream's own laser-etch block (omarchy-install-dashboard
  # lines 467-479) -- machinery this file has no opinion about, reused
  # verbatim rather than re-derived, per this file's own header rule.
  if command -v tte >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 && [[ -f $LOGO_PATH ]]; then
    printf '%s%d;1H\0337' "$CSI" "$((LOGO_HEIGHT + 2))" >"$TTY_PATH"
    timeout 8s tte -i "$LOGO_PATH" \
      --canvas-width "$effect_canvas_width" \
      --anchor-text c \
      --frame-rate 260 \
      --reuse-canvas \
      laseretch \
      >"$TTY_PATH" 2>/dev/null || true
    printf '%s%d;1H' "$CSI" "$((LOGO_HEIGHT + 8))" >"$TTY_PATH"
  fi

  # 🔴 THE LAST THING ON SCREEN BEFORE THE REBOOT, and it is drawn AFTER the
  # laser-etch block on purpose: `tte` anchors its canvas absolutely at
  # LOGO_HEIGHT+2 and would paint straight over anything written above it.
  # After the block the cursor is parked at LOGO_HEIGHT+8, so these lines land
  # under the effect on the tte path and under the summary without it -- both
  # well inside the measured 50-row console (docs/PROGRESS.md §7).
  #
  # WHY IT IS REPEATED HERE. deck-form.sh's S5 already says this before the
  # install starts, but S5 is minutes and a full install earlier -- and S7 is
  # the screen the operator is actually looking at when they press the button
  # that reboots. docs/PROGRESS.md §5.35 measured the wait it describes: Steam
  # unpacks itself for 2m03s on a panel that shows nothing at all, which
  # `docs/findings/P32-steam-never-installed.md` records as being
  # indistinguishable from a dead device. A warning that arrives before the
  # thing it warns about, and is not repeated at the moment of the thing, is
  # how the offline notice went unread (P34/L1).
  #
  # deck-form.sh is NOT sourced into this process (this file's own header), so
  # the wording is duplicated rather than shared. If one changes, change both --
  # test/unit/test-deck-dashboard.sh asserts the substance of it here.
  {
    blank_line
    center "The Deck reboots on its own from here." "$CONTENT_WIDTH"
    center "The first boot takes about a minute while Steam finishes" "$CONTENT_WIDTH"
    center "installing itself. The screen is BLACK for part of it." "$CONTENT_WIDTH"
    center "That is normal. Don't turn me off -- just wait." "$CONTENT_WIDTH"
    blank_line
    # ⚠️ APPEND, not truncate. On a real tty `>` and `>>` are the same thing,
    # which is why this is easy to get wrong and impossible to notice on
    # hardware -- but test/unit/test-deck-dashboard.sh points TTY_PATH at a
    # FILE, and `>` here silently erased the "Installed Omarchy in <duration>"
    # line this block is supposed to follow. The suite caught it; the panel
    # never would have.
  } >>"$TTY_PATH"
}

# ===========================================================================
# S8 -- Failure menu
# ===========================================================================
#
# 🔴 THIS IS THE FIX FOR A REAL, LIVE DEFECT, not new scope invented here.
# src/deck-form.sh already defines a function named `failure_menu` with a
# tested pure decision layer behind it (`deck_form_failure_menu_items`/
# `deck_form_failure_action_for`), but it is sourced into `configurator`'s
# process, which never calls anything by that name -- dead code on a real
# ISO today, found by grep against both files, not assumed
# (docs/tasks/T4a-dashboard-screens.md §4). That array also names a menu row
# ("Retry install") the real dashboard has no mechanism for: there is no
# retry loop anywhere in `omarchy-install-dashboard` -- a failed install
# always `exit`s with `$failure_status` once `failure_menu` returns. Rather
# than port deck-form.sh's speculative menu into the wrong-shaped process
# a second time, this override reuses UPSTREAM'S OWN real menu shape
# (omarchy-install-dashboard lines 609-661, read this session) and changes
# exactly the one thing T4-screen-spec.md §4 S8 flags.
#
# THE DEFECT: upstream's own `failure_menu` maps a CANCELLED `gum choose`
# -- including a plain Esc/B press, the ONLY way a controller-only Deck can
# send that cancellation at all (there is no Ctrl-C) -- to
# `choice="Drop to shell"`, whose case arm `return 0`s straight back to the
# caller, which then unconditionally `exit`s the dashboard process. On this
# hardware that is a keyboard-less handheld left at whatever a bare process
# exit surfaces underneath it. "Drop to shell" is ALSO a literal, selectable
# menu row upstream (not just the cancel fallback), so a stray press on that
# row does the identical thing on purpose; this override removes both.
#
# THE FIX: never offer "Drop to shell" as a row, and map cancellation to a
# REDRAW (show the menu again) instead of "act as if that row was chosen".
# The only ways out of this menu are now Reboot and Power off -- the two
# real machine-state transitions the pad can always reach without a
# keyboard. No shell escape exists in this function at all, matching
# deck-form.sh's own DECK_FAILURE_MENU_ITEMS design intent (no shell
# escape, ever) even though that array's own contents are not reused
# verbatim here (see above for why).
failure_menu() {
  local choice uploader

  [[ ${OMARCHY_UI_FAILURE_ACTION:-} == "exit" ]] && return 0
  # The failure screen and log tail have already rendered; exit with the
  # installer's status instead of blocking on a menu nobody can answer --
  # identical short-circuit to upstream's own, unchanged.
  interactive || return 0

  while true; do
    uploader=""
    uploader=$(find_log_uploader || true)
    if [[ -n $uploader ]]; then
      # shellcheck disable=SC2094  # stdin/stderr on the same tty, not a real
      # read/write race -- copied unchanged from upstream's own failure_menu
      # (omarchy-install-dashboard line 621), which uses the identical shape.
      choice=$(gum choose \
        --height 5 \
        --header "What would you like to do?" \
        "Upload log for support" \
        "View full log" \
        "Reboot" \
        "Power off" \
        <"$TTY_PATH" 2>"$TTY_PATH") || choice=""
    else
      # shellcheck disable=SC2094  # see the identical note above
      choice=$(gum choose \
        --height 4 \
        --header "What would you like to do?" \
        "View full log" \
        "Reboot" \
        "Power off" \
        <"$TTY_PATH" 2>"$TTY_PATH") || choice=""
    fi

    case "$choice" in
      "Upload log for support")
        upload_failure_log
        render_failure "${failure_status:-1}" "${failure_summary:-}" >"$TTY_PATH" 2>/dev/null || true
        ;;
      "View full log")
        view_failure_log
        render_failure "${failure_status:-1}" "${failure_summary:-}" >"$TTY_PATH" 2>/dev/null || true
        ;;
      "Reboot")
        reboot 2>/dev/null || systemctl reboot 2>/dev/null || true
        ;;
      "Power off")
        poweroff 2>/dev/null || systemctl poweroff 2>/dev/null || true
        ;;
      "")
        # Cancelled (Esc/B, the ONLY cancellation this hardware can send) --
        # redraw, never treat as a chosen action. This is the one branch the
        # defect above lived in: upstream's own `|| choice="Drop to shell"`
        # becomes `|| choice=""` above, and this arm is the no-op that lets
        # the `while true` loop redraw the menu instead of falling into a
        # `return 0` that exits the whole process. No other case arm is
        # needed for "unrecognised" because gum choose only ever returns one
        # of the four rows offered, or fails (handled by `|| choice=""`).
        ;;
    esac
  done
}

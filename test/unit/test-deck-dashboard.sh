#!/usr/bin/env bash
# Unit tests for deck-dashboard.sh -- T4a's S6/S7/S8 screens, which live
# in `omarchy-install-dashboard`, a process separate from `configurator`
# (see deck-dashboard.sh's own header, and docs/tasks/T4a-dashboard-screens.md
# §1). No VM, no gum, no Deck: every collaborator this file would normally
# reach for on the real ISO (`gum choose`, `reboot`/`poweroff`, the real
# `find_log_uploader`/`upload_failure_log`/`view_failure_log`/`render_failure`/
# `interactive`/`install_duration`/`term_cols`/`center`/`blank_line`/
# `render_logo` that upstream defines ABOVE this file's own source line) is
# either a fixture, a PATH-shadowed fake executable, or a minimal stand-in
# function defined in this suite -- same split test-deck-form.sh already
# uses for `configurator`'s own helpers.

set -euo pipefail

# ⚠️ SUITE-LEVEL WATCHDOG -- same rationale as test-deck-form.sh's own: the
# S8 section below drives `failure_menu`'s `while true` loop for real (a fake
# gum, a fake reboot/poweroff), and a regression that breaks the cancel/
# redraw or the reboot/poweroff short-circuit turns that loop into a genuine
# infinite spin with no external bound. A hung CI job that reports NOTHING is
# worse than a red test -- re-exec under `timeout` rather than trust every
# call site below to remember its own bound.
if [[ -z ${DECK_DASHBOARD_TEST_WATCHDOG:-} ]]; then
  export DECK_DASHBOARD_TEST_WATCHDOG=1
  exec timeout --signal=KILL 120 "$0" "$@"
fi

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

# deck-dashboard.sh was promoted out of src/ into the ISO overlay on
# 2026-08-12, together with the patch that sources it (src/iso-patches/
# README.md: a file that ships on the ISO and nowhere else lives in the
# overlay, at its shipped path -- one copy, no src/ duplicate). The overlay
# path below is the shipped path with iso/overlay/configs/ prefixed;
# iso/bin/build step 4 rsyncs overlay/configs/ over the upstream tree, so
# what this suite sources is byte-for-byte what the ISO carries.
DASHBOARD_SH="$REPO_ROOT/iso/overlay/configs/airootfs/usr/share/omarchy-iso/deck-dashboard.sh"
[[ -r $DASHBOARD_SH ]] ||
  { printf 'not ok - %s\n' "deck-dashboard.sh is not at $DASHBOARD_SH -- it ships on the ISO and nowhere else, so the overlay is its only home"; exit 1; }

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# deck-dashboard.sh does not `set -euo pipefail` itself (source-safety -- see
# its own header: `omarchy-install-dashboard` already runs under `-e` by the
# time this file's source line executes, and must not have that changed for
# the rest of a script this file does not own). Source it under THIS suite's
# stricter mode so a real bug (an unset variable, a broken pipe) still
# surfaces here, matching test-deck-form.sh's identical choice for
# src/deck-form.sh.
# shellcheck source=../../iso/overlay/configs/airootfs/usr/share/omarchy-iso/deck-dashboard.sh
source "$DASHBOARD_SH"

DASHBOARD="$REPO_ROOT/iso/upstream/configs/airootfs/usr/local/bin/omarchy-install-dashboard"
CONFIGURATOR="$REPO_ROOT/iso/upstream/configs/airootfs/root/configurator"

# ===========================================================================
# S6 -- tips array
# ===========================================================================

echo "--- S6 tips array ------------------------------------------------------"

[[ ${#tips[@]} -gt 0 ]] || fail "tips must be a non-empty array -- an empty override is worse than upstream's own 18 entries"
pass "tips is non-empty (${#tips[@]} entries)"

# T4-screen-spec.md §4 S6's own [U] check, verbatim: "no entry contains
# Super". A Deck has no keyboard at all, so every one of upstream's 18
# "Super + ..." tips is not just irrelevant but actively wrong here.
for t in "${tips[@]}"; do
  [[ $t == *Super* ]] && fail "tips entry contains 'Super', a keyboard-only shortcut this hardware cannot produce" "entry: $t"
done
pass "no tips entry names a keyboard 'Super' shortcut"

# CONTENT_WIDTH is LOGO_WIDTH-derived at runtime (omarchy-install-dashboard's
# own logo_width(), reading the real Deck logo.txt this repo does not carry);
# 81 is that file's own documented fallback when no logo is present
# (docs/tasks/T4a-dashboard-screens.md §3's own bound, checked by eye when
# this array was drafted). Checked here in bytes so a future edit cannot
# silently regrow past it without this suite noticing.
DECK_DASHBOARD_TEST_CONTENT_WIDTH=81
for t in "${tips[@]}"; do
  len=${#t}
  (( len <= DECK_DASHBOARD_TEST_CONTENT_WIDTH )) ||
    fail "tips entry exceeds the ${DECK_DASHBOARD_TEST_CONTENT_WIDTH}-column content width" "len=$len: $t"
done
pass "every tips entry fits within the ${DECK_DASHBOARD_TEST_CONTENT_WIDTH}-column content width"

# ===========================================================================
# S7 -- render_finish
# ===========================================================================

echo "--- S7 render_finish ----------------------------------------------------"

# Minimal stand-ins for the real dashboard's own machinery this file reuses
# (see deck-dashboard.sh's header: these are all defined ABOVE this file's
# own source line in the real omarchy-install-dashboard, so sourcing
# deck-dashboard.sh ALONE -- this suite's whole point, no VM -- leaves them
# undefined otherwise). Each stub prints to stdout, which render_finish's own
# `{ ... } >"$TTY_PATH"` group redirects into TTY_PATH for inspection below.
blank_line() { printf 'BLANK\n'; }
render_logo() { printf 'LOGO\n'; }
center() { printf 'CENTER:%s\n' "$1"; }
install_duration() { printf '3m 14s'; }
term_cols() { printf '80\n'; }
SHOW_CURSOR=""
CLEAR=""
CONTENT_WIDTH=81
LOGO_HEIGHT=3
CSI=$'\033['
# Deliberately a path that does NOT exist: render_finish's own tte-etch
# block is gated on `[[ -f $LOGO_PATH ]]` (unchanged from upstream, see this
# file's header on reused machinery), so this guarantees a deterministic
# skip of that block regardless of whether tte/timeout happen to be
# installed on the machine running this suite.
LOGO_PATH="$work/no-such-logo.txt"
TTY_PATH="$work/finish-tty.out"

render_finish
[[ -s $TTY_PATH ]] || fail "render_finish produced no output on TTY_PATH"

LC_ALL=C grep -qF "CENTER:Installed Omarchy in 3m 14s" "$TTY_PATH" ||
  fail "render_finish must still show upstream's own 'Installed Omarchy in <duration>' line" "$(cat "$TTY_PATH")"

# 🔴 THE REBOOT WARNING IS THE LAST THING THE OPERATOR READS BEFORE PRESSING
# THE BUTTON THAT REBOOTS. docs/PROGRESS.md §5.35 measured what it describes:
# 2m03s on a panel showing nothing, which P32-steam-never-installed.md records
# as indistinguishable from a dead device. deck-form.sh's S5 says this too, but
# minutes and a whole install earlier -- and the offline notice already proved
# that a warning delivered early and not repeated goes unread (P34/L1).
#
# Asserted on SUBSTANCE, not on an exact sentence: a test that pins prose
# verbatim is what kept a false DSP disclosure on the greeter for a month
# (105523c). These check that the screen says the three things that matter.
LC_ALL=C grep -qF "BLACK SCREEN" "$TTY_PATH" ||
  fail "render_finish must warn that the first boot shows a black screen" "$(cat "$TTY_PATH")"
LC_ALL=C grep -qiF "two minutes" "$TTY_PATH" ||
  fail "render_finish must say roughly how long the black screen lasts -- 'wait' with no duration is not actionable" "$(cat "$TTY_PATH")"
LC_ALL=C grep -qiF "turn me off" "$TTY_PATH" ||
  fail "render_finish must tell the user not to power the Deck off during that wait" "$(cat "$TTY_PATH")"
pass "S7 warns about the black first boot: what it looks like, how long, and not to power off"

# The warning must come AFTER the summary, not replace it -- the bug this
# caught on first write was a `>` where `>>` was meant, which erased the line
# above. On a real tty both redirections behave identically, so only a suite
# pointing TTY_PATH at a file can see it.
finish_out="$(cat "$TTY_PATH")"
[[ ${finish_out%%BLACK SCREEN*} == *"Installed Omarchy in 3m 14s"* ]] ||
  fail "the reboot warning must FOLLOW the completion summary, not truncate it" "$finish_out"
pass "the reboot warning is appended below the summary, not written over it"
pass "render_finish keeps upstream's own duration line"

# 🔴 THE ONE LINE THIS OVERRIDE EXISTS FOR (T4-screen-spec.md §4 S7).
LC_ALL=C grep -qF "CENTER:Your Deck will start in Gaming Mode." "$TTY_PATH" ||
  fail "render_finish must add 'Your Deck will start in Gaming Mode.' -- the whole point of the S7 override" "$(cat "$TTY_PATH")"
pass "render_finish adds 'Your Deck will start in Gaming Mode.'"

# Ordering: the added line must come AFTER the duration line (so it reads as
# a continuation of the finish message, not a non-sequitur before it) and
# BEFORE the trailing blank line upstream's own layout ends the block with.
duration_line=$(LC_ALL=C grep -n "CENTER:Installed Omarchy in 3m 14s" "$TTY_PATH" | cut -d: -f1)
gaming_line=$(LC_ALL=C grep -n "CENTER:Your Deck will start in Gaming Mode." "$TTY_PATH" | cut -d: -f1)
(( gaming_line == duration_line + 1 )) ||
  fail "the Gaming Mode line must immediately follow the duration line" "duration at $duration_line, gaming mode at $gaming_line"
pass "the Gaming Mode line immediately follows the duration line, matching T4a §3's specified layout"

LC_ALL=C grep -qF "LOGO" "$TTY_PATH" || fail "render_finish must still render the logo (upstream's own render_logo call)"
pass "render_finish still renders the logo -- machinery reused, not dropped"

# ===========================================================================
# S8 -- failure_menu
# ===========================================================================

echo "--- S8 failure_menu setup ------------------------------------------------"

mkdir -p "$work/bin"

# Fake `gum choose`: pops one line off a queue file per call and logs every
# argument it was invoked with (so a test can assert on exactly what rows
# were offered, including catching a menu that still contains "Drop to
# shell"). Popping the literal string CANCEL simulates a cancelled `gum
# choose` -- exit 1, nothing on stdout -- which is the ONLY way a
# controller-only Deck (no Ctrl-C) can cancel a `gum choose` at all: a plain
# Esc/B press. An exhausted queue blocks (via `exec sleep`, not a busy loop)
# rather than erroring, so a caller that keeps looping after its last
# scripted answer degrades to "eventually killed by the suite watchdog /
# per-scenario timeout below" instead of racing a tight empty-queue loop.
cat >"$work/bin/gum" <<'FAKEGUM'
#!/usr/bin/env bash
set -uo pipefail
if [[ ${1:-} != choose ]]; then exit 0; fi
shift
: "${FAKE_GUM_QUEUE:?FAKE_GUM_QUEUE not set}"
: "${FAKE_GUM_LOG:?FAKE_GUM_LOG not set}"
{
  printf -- '--- call ---\n'
  for a in "$@"; do printf '%s\n' "$a"; done
} >>"$FAKE_GUM_LOG"
if [[ ! -s $FAKE_GUM_QUEUE ]]; then
  exec sleep 100
fi
next=$(head -n1 "$FAKE_GUM_QUEUE")
tail -n +2 "$FAKE_GUM_QUEUE" >"$FAKE_GUM_QUEUE.tmp" && mv "$FAKE_GUM_QUEUE.tmp" "$FAKE_GUM_QUEUE"
if [[ $next == CANCEL ]]; then
  exit 1
fi
printf '%s\n' "$next"
exit 0
FAKEGUM

# Fake `reboot`/`poweroff`: log the call and succeed. A REAL reboot/poweroff
# never returns to the caller (the machine goes down); these fakes DO
# return, which is why the scenarios below still need the queue-exhaustion
# block above and a per-scenario timeout rather than expecting failure_menu
# to ever return on its own after one of these fires.
cat >"$work/bin/reboot" <<'FAKEREBOOT'
#!/usr/bin/env bash
printf 'reboot\n' >>"${FAKE_POWER_LOG:?FAKE_POWER_LOG not set}"
exit 0
FAKEREBOOT
cat >"$work/bin/poweroff" <<'FAKEPOWEROFF'
#!/usr/bin/env bash
printf 'poweroff\n' >>"${FAKE_POWER_LOG:?FAKE_POWER_LOG not set}"
exit 0
FAKEPOWEROFF
chmod +x "$work/bin/gum" "$work/bin/reboot" "$work/bin/poweroff"

touch "$work/tty"

# The driver: a standalone bash script (not a function in THIS shell) so
# each scenario can be bounded by `timeout` from the OUTSIDE without that
# `exit`ing the whole suite process when a scenario deliberately runs
# failure_menu's infinite loop past its last scripted answer. Sources
# deck-dashboard.sh fresh and defines the small set of stand-ins for
# omarchy-install-dashboard's own machinery that failure_menu calls
# (interactive/find_log_uploader/upload_failure_log/view_failure_log/
# render_failure -- all real functions THAT file defines above this file's
# own source line, so undefined when deck-dashboard.sh is sourced alone).
cat >"$work/driver.sh" <<'DRIVER'
#!/usr/bin/env bash
set -uo pipefail
REPO_ROOT="$1"
# shellcheck source=/dev/null
source "$REPO_ROOT/iso/overlay/configs/airootfs/usr/share/omarchy-iso/deck-dashboard.sh"

TTY_PATH="$2"
interactive() { [[ ${FAKE_INTERACTIVE:-yes} == yes ]]; }
find_log_uploader() {
  [[ -n ${FAKE_UPLOADER:-} ]] || return 1
  printf '%s' "$FAKE_UPLOADER"
  return 0
}
upload_failure_log() { printf 'upload_failure_log called\n' >>"${FAKE_CALL_LOG:?}"; return 0; }
view_failure_log()   { printf 'view_failure_log called\n'   >>"${FAKE_CALL_LOG:?}"; return 0; }
render_failure()     { return 0; }

failure_menu
DRIVER
chmod +x "$work/driver.sh"

echo "--- S8 short-circuits (no gum call at all) -------------------------------"

: >"$work/gum.log"; : >"$work/power.log"; : >"$work/call.log"; : >"$work/queue"
PATH="$work/bin:$PATH" \
  FAKE_GUM_QUEUE="$work/queue" FAKE_GUM_LOG="$work/gum.log" FAKE_POWER_LOG="$work/power.log" \
  FAKE_CALL_LOG="$work/call.log" OMARCHY_UI_FAILURE_ACTION=exit FAKE_INTERACTIVE=yes \
  timeout 5 bash "$work/driver.sh" "$REPO_ROOT" "$work/tty" >/dev/null 2>&1 || true
[[ -s $work/gum.log ]] && fail "OMARCHY_UI_FAILURE_ACTION=exit must return before ever calling gum" "$(cat "$work/gum.log")"
pass "OMARCHY_UI_FAILURE_ACTION=exit short-circuits before showing any menu"

: >"$work/gum.log"; : >"$work/power.log"; : >"$work/call.log"; : >"$work/queue"
PATH="$work/bin:$PATH" \
  FAKE_GUM_QUEUE="$work/queue" FAKE_GUM_LOG="$work/gum.log" FAKE_POWER_LOG="$work/power.log" \
  FAKE_CALL_LOG="$work/call.log" FAKE_INTERACTIVE=no \
  timeout 5 bash "$work/driver.sh" "$REPO_ROOT" "$work/tty" >/dev/null 2>&1 || true
[[ -s $work/gum.log ]] && fail "a non-interactive run (FAKE_INTERACTIVE=no) must return before ever calling gum" "$(cat "$work/gum.log")"
pass "the non-interactive short-circuit (upstream's own 'interactive || return 0') still applies"

echo "--- S8 no shell escape, ever ----------------------------------------------"

# 🔴 THE DEFECT THIS OVERRIDE EXISTS TO FIX. Two cancels (Esc/B, the only
# cancellation this hardware can send) followed by 'Power off'. A correct
# override redraws on each cancel and only reaches Power off (and therefore
# the power log) on the THIRD gum call; a regression back to upstream's own
# `choice="Drop to shell"` + `return 0` on cancel would exit after the FIRST
# cancel and never reach it -- so "poweroff was attempted" is proof the
# redraw path, not the shell-escape path, actually ran.
printf 'CANCEL\nCANCEL\nPower off\n' >"$work/queue"
: >"$work/gum.log"; : >"$work/power.log"; : >"$work/call.log"
PATH="$work/bin:$PATH" \
  FAKE_GUM_QUEUE="$work/queue" FAKE_GUM_LOG="$work/gum.log" FAKE_POWER_LOG="$work/power.log" \
  FAKE_CALL_LOG="$work/call.log" FAKE_INTERACTIVE=yes FAKE_UPLOADER=/bin/true \
  timeout 5 bash "$work/driver.sh" "$REPO_ROOT" "$work/tty" >/dev/null 2>&1 || true

LC_ALL=C grep -qF "Drop to shell" "$work/gum.log" &&
  fail "the menu must NEVER offer 'Drop to shell' -- that is the exact defect this override exists to remove" "$(cat "$work/gum.log")"
pass "the menu never offers 'Drop to shell' as a selectable row (with-uploader branch)"

calls=$(LC_ALL=C grep -c -- '--- call ---' "$work/gum.log")
(( calls >= 3 )) || fail "expected at least 3 gum calls (2 cancels + the Power off pick), got $calls" "$(cat "$work/gum.log")"
pass "the menu redrew across both cancels ($calls gum calls observed)"

LC_ALL=C grep -qF "poweroff" "$work/power.log" ||
  fail "'Power off' must actually invoke poweroff -- if this is empty, cancel silently exited before ever reaching the Power off pick (the shell-escape regression)" "power.log: $(cat "$work/power.log" 2>/dev/null); gum.log: $(cat "$work/gum.log")"
pass "cancelling twice then picking 'Power off' really invokes poweroff -- proves redraw, not shell-escape, handled both cancels"

echo "--- S8 no-uploader branch --------------------------------------------------"

printf 'View full log\nCANCEL\nPower off\n' >"$work/queue"
: >"$work/gum.log"; : >"$work/power.log"; : >"$work/call.log"
PATH="$work/bin:$PATH" \
  FAKE_GUM_QUEUE="$work/queue" FAKE_GUM_LOG="$work/gum.log" FAKE_POWER_LOG="$work/power.log" \
  FAKE_CALL_LOG="$work/call.log" FAKE_INTERACTIVE=yes \
  timeout 5 bash "$work/driver.sh" "$REPO_ROOT" "$work/tty" >/dev/null 2>&1 || true

LC_ALL=C grep -qF "Drop to shell" "$work/gum.log" &&
  fail "the no-uploader menu must NEVER offer 'Drop to shell' either" "$(cat "$work/gum.log")"
pass "the menu never offers 'Drop to shell' (no-uploader branch)"

LC_ALL=C grep -qF "Upload log for support" "$work/gum.log" &&
  fail "the no-uploader branch must not offer 'Upload log for support' when find_log_uploader fails" "$(cat "$work/gum.log")"
pass "the no-uploader branch correctly drops the upload row"

LC_ALL=C grep -qF "view_failure_log called" "$work/call.log" ||
  fail "'View full log' must call view_failure_log" "$(cat "$work/call.log")"
pass "'View full log' calls view_failure_log"

LC_ALL=C grep -qF "poweroff" "$work/power.log" ||
  fail "the no-uploader branch must still reach Power off after a cancel" "$(cat "$work/power.log")"
pass "the no-uploader branch also survives a cancel and reaches Power off"

echo "--- S8 Reboot really calls reboot -------------------------------------------"

printf 'Reboot\n' >"$work/queue"
: >"$work/gum.log"; : >"$work/power.log"; : >"$work/call.log"
PATH="$work/bin:$PATH" \
  FAKE_GUM_QUEUE="$work/queue" FAKE_GUM_LOG="$work/gum.log" FAKE_POWER_LOG="$work/power.log" \
  FAKE_CALL_LOG="$work/call.log" FAKE_INTERACTIVE=yes \
  timeout 5 bash "$work/driver.sh" "$REPO_ROOT" "$work/tty" >/dev/null 2>&1 || true
LC_ALL=C grep -qF "reboot" "$work/power.log" ||
  fail "'Reboot' must actually invoke reboot" "$(cat "$work/power.log")"
pass "'Reboot' really invokes reboot"

echo "--- S8 Upload log for support calls upload_failure_log ----------------------"

printf 'Upload log for support\nCANCEL\nPower off\n' >"$work/queue"
: >"$work/gum.log"; : >"$work/power.log"; : >"$work/call.log"
PATH="$work/bin:$PATH" \
  FAKE_GUM_QUEUE="$work/queue" FAKE_GUM_LOG="$work/gum.log" FAKE_POWER_LOG="$work/power.log" \
  FAKE_CALL_LOG="$work/call.log" FAKE_INTERACTIVE=yes FAKE_UPLOADER=/bin/true \
  timeout 5 bash "$work/driver.sh" "$REPO_ROOT" "$work/tty" >/dev/null 2>&1 || true
LC_ALL=C grep -qF "upload_failure_log called" "$work/call.log" ||
  fail "'Upload log for support' must call upload_failure_log" "$(cat "$work/call.log")"
pass "'Upload log for support' calls upload_failure_log"

# ===========================================================================
# The OVERRIDE-NAME contract, checked against upstream's own source
# ===========================================================================
#
# 🔴 THE MOST IMPORTANT SECTION IN THIS FILE, mirroring test-deck-form.sh's
# own (see that file for the full history: this project shipped a dead
# override FOUR times before that check existed, and a fifth time --
# `failure_menu`, defined in `deck-form.sh`, sourced into the wrong PROCESS
# entirely -- which is the discovery that produced this task in the first
# place). A function defined here under a name `omarchy-install-dashboard`
# never itself defines is not a broken screen, it is NO screen: it silently
# never overrides anything, while every pure-logic assertion above (which
# calls these functions directly, not through the real dashboard) stays
# green. This is the check that would have caught the `failure_menu` defect
# on day one had it existed for deck-form.sh's own suite too.
echo "--- the OVERRIDE-NAME contract, checked against upstream's own source ---"

# Never a silent skip -- this assertion is the only thing standing between
# an unverified name and a screen that never appears on the real ISO.
[[ -r $DASHBOARD ]] ||
  fail "iso/upstream is not checked out, so the override-name contract was NOT verified. Run: git submodule update --init iso/upstream"

overrides=$(grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$DASHBOARD_SH" |
              tr -d '()' | grep -v '^deck_dashboard_' | sort -u)
[[ -n $overrides ]] ||
  fail "found NO override functions in deck-dashboard.sh -- this scanner is broken, not the file"

while read -r fn; do
  [[ -z $fn ]] && continue
  # A real function DEFINITION in the dashboard file, not merely an
  # occurrence (unlike test-deck-form.sh's check against `configurator`,
  # which sources these names from setup-form.sh so only reads them; here
  # tips/render_finish/failure_menu are DEFINED in this exact file, so the
  # tighter "is this actually a function/array definition" check is both
  # available and correct).
  if [[ $fn == tips ]]; then
    LC_ALL=C grep -qE '^tips=\(' "$DASHBOARD" ||
      fail "deck-dashboard.sh overrides 'tips', but omarchy-install-dashboard does not define 'tips=(' -- the name (or the file) has drifted"
  else
    LC_ALL=C grep -qE "^${fn}\(\)" "$DASHBOARD" ||
      fail "deck-dashboard.sh defines '${fn}', which is not a function omarchy-install-dashboard itself defines. That is not a broken screen, it is NO screen, and it fails SILENTLY"
  fi
done <<<"$overrides"
pass "every override deck-dashboard.sh defines is a name/array omarchy-install-dashboard actually defines"

# Negative control: a scanner that stopped matching would report a clean
# tree no matter what. Prove it still rejects a name that cannot exist.
if LC_ALL=C grep -qE '^definitely_not_a_real_dashboard_function\(\)' "$DASHBOARD"; then
  fail "override scanner negative control is broken: it found a function that cannot exist"
fi
pass "override scanner negative control: it correctly rejects a name that isn't there"

# Positive control: prove the scanner really does find a known-live name,
# the same shape test-deck-form.sh uses for its own scanner.
LC_ALL=C grep -qE '^render_finish\(\)' "$DASHBOARD" ||
  fail "override scanner positive control failed: 'render_finish' is DEFINITELY defined in omarchy-install-dashboard and the scanner could not see it"
pass "override scanner positive control: it really does find a known-live name"

# The reverse-direction guard: none of these three names live in
# `configurator` instead -- if they did, deck-dashboard.sh's own override
# would be sourced into the wrong PROCESS (the T4a discovery, mirrored).
if [[ -r $CONFIGURATOR ]]; then
  for fn in render_finish failure_menu; do
    if LC_ALL=C grep -qE "^${fn}\(\)" "$CONFIGURATOR"; then
      fail "'$fn' is ALSO defined in configurator -- if it is configurator's own name, sourcing it via deck-dashboard.sh (which only reaches omarchy-install-dashboard) is the wrong-process mistake this task exists to fix"
    fi
  done
  LC_ALL=C grep -qE '^tips=\(' "$CONFIGURATOR" &&
    fail "'tips=(' is ALSO defined in configurator -- re-check which process actually owns it"
  pass "render_finish/failure_menu/tips are not configurator's own names -- the two-process split T4a found still holds"
else
  printf 'not ok - iso/upstream configurator is not checked out, so the reverse-direction guard was NOT verified\n'
  printf 'run: git submodule update --init iso/upstream\n' >&2
  exit 1
fi

# ===========================================================================
# The patch itself: applies cleanly, lands the source line in the one valid
# place (docs/tasks/T4a-dashboard-screens.md §1's placement rule)
# ===========================================================================

echo "--- the patch applies, and lands the source line in the right place -----"

# Promoted 2026-08-12 out of src/iso-patches/ into the overlay, in the same
# change that moved deck-dashboard.sh -- iso/bin/build applies every
# overlay/patches/*.patch it finds, so from here on this patch is live on the
# very next build and its target file had better be on the ISO.
PATCH="$REPO_ROOT/iso/overlay/patches/omarchy-install-dashboard.patch"
[[ -r $PATCH ]] || fail "iso/overlay/patches/omarchy-install-dashboard.patch is missing"
[[ ! -e "$REPO_ROOT/src/iso-patches/omarchy-install-dashboard.patch" ]] ||
  fail "omarchy-install-dashboard.patch exists in BOTH src/iso-patches/ and iso/overlay/patches/ -- promotion is a git mv, not a copy"

command -v patch >/dev/null 2>&1 ||
  fail "no 'patch' binary available to verify iso/overlay/patches/omarchy-install-dashboard.patch applies -- cannot verify the patch, not skipping silently"

scratch_root="$work/patch-scratch"
mkdir -p "$scratch_root/configs/airootfs/usr/local/bin"
cp "$DASHBOARD" "$scratch_root/configs/airootfs/usr/local/bin/omarchy-install-dashboard"
if ! ( cd "$scratch_root" && patch -p1 --batch --fuzz=0 <"$PATCH" >"$work/patch-apply.log" 2>&1 ); then
  fail "the patch does NOT apply cleanly against the pinned iso/upstream omarchy-install-dashboard" "$(cat "$work/patch-apply.log")"
fi
pass "the patch applies cleanly (patch -p1) against the pinned iso/upstream omarchy-install-dashboard"

patched="$scratch_root/configs/airootfs/usr/local/bin/omarchy-install-dashboard"
bash -n "$patched" || fail "the patched omarchy-install-dashboard is not valid bash syntax"
pass "the patched file is still valid bash"

source_count=$(LC_ALL=C grep -c '^source /usr/share/omarchy-iso/deck-dashboard.sh$' "$patched")
[[ $source_count -eq 1 ]] ||
  fail "the patched file must contain exactly one 'source /usr/share/omarchy-iso/deck-dashboard.sh' line, found $source_count"
pass "the patch adds exactly one source line"

# docs/tasks/T4a-dashboard-screens.md §1's own placement rule, checked
# mechanically: the source line must land strictly between launch_child's
# closing brace (the last function omarchy-install-dashboard defines) and
# the main flow's first line. Landing it earlier (e.g. before render_finish
# is defined at upstream's own line 451) would let upstream's OWN
# definition, which still executes after this file's source line, clobber
# this file's override right back to stock -- silently, since bash keeps
# only the LAST definition of a name.
source_line=$(LC_ALL=C grep -n '^source /usr/share/omarchy-iso/deck-dashboard.sh$' "$patched" | cut -d: -f1)
launch_child_close=$(awk '/^launch_child\(\) \{/{f=1; next} f && /^}/{print NR; exit}' "$patched")
# shellcheck disable=SC2016  # single-quoted on purpose: a literal '$TTY_PATH' regex, not expansion
main_flow_line=$(LC_ALL=C grep -n '^\[\[ -e \$TTY_PATH \]\] || exit 2$' "$patched" | cut -d: -f1)
[[ -n $source_line ]] || fail "could not find the source line in the patched file"
[[ -n $launch_child_close ]] || fail "could not find launch_child's own closing brace in the patched file"
[[ -n $main_flow_line ]] || fail "could not find the main-flow guard line in the patched file"

(( source_line > launch_child_close )) ||
  fail "the source line must land AFTER launch_child's own closing brace (line $launch_child_close), found it at line $source_line"
(( source_line < main_flow_line )) ||
  fail "the source line must land BEFORE the main flow starts (line $main_flow_line), found it at line $source_line"
pass "the source line lands strictly between launch_child's end (line $launch_child_close) and the main flow (line $main_flow_line) -- the one valid placement"

echo "All test-deck-dashboard.sh assertions passed."

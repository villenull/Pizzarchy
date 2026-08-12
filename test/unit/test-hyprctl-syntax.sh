#!/usr/bin/env bash
# Guards the three ways a `hyprctl` call in this repo fails while LOOKING fine.
#
# WHY THIS EXISTS
#
# All three were measured on the Deck, all three cost real time, and none is
# visible to any other check in this repo, because in every case the command
# exits 0 without doing -- or reporting -- anything, and the caller cannot tell
# that apart from success.
#
#   1. 🔴 `hyprctl dispatch`'s old string syntax is a LUA PARSE ERROR on
#      Hyprland 0.56.2 (what the Deck runs -- `hyprctl version`). It is not an
#      unknown-command error, it is a syntax error:
#
#        $ hyprctl dispatch movetoworkspacesilent 2,address:0x...
#        error: [string "return hl.dispatch(movetoworkspacesilent 2,ad..."]:1:
#               ')' expected near '2'
#
#      The working form is Lua: `hyprctl dispatch 'hl.dsp.focus({ workspace = 2 })'`.
#      Namespaces are enumerated in docs/findings/T10-steam-extest-results.md §3.
#      ⚠️ The error goes to STDERR, so `>/dev/null 2>&1` or a pipeline makes it
#      invisible -- the §5.28 shape, where a load-bearing call did nothing while
#      every check passed. (docs/PROGRESS.md §5.30b.)
#
#   2. 🔴 `hyprctl` over SSH has no `HYPRLAND_INSTANCE_SIGNATURE` and exits
#      immediately with `HYPRLAND_INSTANCE_SIGNATURE not set! (is hyprland
#      running?)` (R-46, docs/findings/P18-osk-hardware-pass.md). This is worse
#      in a runbook than in code: `ssh deck 'hyprctl reload && hyprctl
#      configerrors'` prints no config errors -- because it never ran -- and the
#      operator ticks the checkbox. That is exactly what docs/RECOVERY.md's
#      lock escape did for two sessions before anyone executed it.
#
#   3. 🔴 `hyprctl eval 'return <sentinel>'` NEVER REPORTS THE VALUE. Measured
#      on the Deck 2026-08-12 (Hyprland 0.56.2): eval prints `ok` -- its own
#      status, not the expression's result -- and exits 0 for every expression
#      that does not raise. Negative control, run live:
#
#        $ hyprctl eval "return DECK_NOPE"     # a name that has never existed
#        ok
#        $ echo $?
#        0
#
#      The only thing eval surfaces is a Lua error: `hyprctl eval 'error("x")'`
#      prints `error: ...` and exits 7. So a sentinel READBACK passes whether
#      or not the config loaded -- and the sentinel exists precisely because
#      Hyprland answers a Lua syntax error by discarding the WHOLE file while
#      `hyprctl configerrors` stays clean (docs/PROGRESS.md §7). The working
#      form is an ASSERTION:
#
#        hyprctl eval 'if DECK_INPUT_LUA_LOADED == nil then error("input.lua was discarded") end'
#
#      exit 0 = loaded, exit 7 = discarded. `verify_osk_kb_layout` in
#      src/deck-session.sh is the reference implementation; copy its shape.
#      This one has already misled a session: the readback was cited as proof
#      that a config change had loaded, and it was not proof (§5.30c).
#
# WHAT IT DOES NOT CHECK
#
# Query subcommands (`hyprctl -j clients`, `-j monitors`, `cursorpos`,
# `version`, `configerrors`, `reload`) are NOT affected by #1 -- only
# `dispatch` grew the Lua API. They are left alone deliberately; flagging them
# would train people to ignore this suite.
#
# ⚠️ NOTHING HERE IS VERIFIED AGAINST A LIVE COMPOSITOR. This suite asserts
# which SHAPE of command is written down. That the Lua shape works is the
# T10 measurement's claim, not this file's.
#
# No Docker, no VM, no root, no network, no Hyprland: this suite only reads
# files that git already tracks.

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SELF=test/unit/test-hyprctl-syntax.sh

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2; exit 1; }

# --- what is in scope, and why the exclusions are not loopholes ---------------
#
# iso/upstream/**        a vendored read-only mirror of basecamp/omarchy. Its
#                        omarchy-iso-test DOES carry an old-form dispatch
#                        (`hyprctl dispatch workspace 1`, stderr discarded,
#                        `|| true`). We do not get to fix upstream's file here;
#                        editing the mirror would just be reverted by the next
#                        vendor refresh. Recorded in docs/PROGRESS.md §5.30b.
# docs/findings/**       these QUOTE the broken form as the evidence for this
# docs/PROGRESS.md       suite's existence. Flagging the finding that found the
# docs/START-HERE.md     bug would be self-defeating.
# this file              same reason -- the fixtures below are deliberately bad.
in_scope() {
  case $1 in
    iso/upstream/*|docs/findings/*|docs/PROGRESS.md|docs/START-HERE.md|"$SELF") return 1 ;;
    *) return 0 ;;
  esac
}

# --others --exclude-standard is deliberate: a brand-new script with a bad
# dispatch in it is exactly when this suite is most useful, and it is not yet
# tracked. Ignored files stay out (build artefacts, test/images/*.raw).
mapfile -t TRACKED < <(cd "$REPO_ROOT" && git ls-files --cached --others --exclude-standard)
((${#TRACKED[@]} > 0)) ||
  fail "the file list is non-empty" \
    "git ls-files returned nothing from ${REPO_ROOT}. An empty scan set passes
every assertion below while checking nothing -- the 'found nothing reads as
found no problems' bug class. Refusing to continue."

SCOPE=()
for f in "${TRACKED[@]}"; do in_scope "$f" && SCOPE+=("$f"); done
((${#SCOPE[@]} > 0)) || fail "the in-scope file list is non-empty" "every tracked file was excluded"

# The files this suite exists to protect must actually be in scope. If one is
# renamed, the scan silently stops covering it and everything still passes.
for must in docs/RECOVERY.md src/deck-session.sh docs/tasks/P2.9-deck-session-runbook.md \
            docs/tasks/T5-fork-plan.md; do
  printf '%s\n' "${SCOPE[@]}" | grep -qxF "$must" ||
    fail "the files this suite exists to protect are in scope" \
      "${must} is not in the scan set -- it was renamed, deleted, or newly
excluded. Update this suite rather than letting its coverage lapse silently."
done
pass "scan set built: ${#SCOPE[@]} tracked files, the four load-bearing ones present"

# --- scanner 1: old-syntax `hyprctl dispatch` --------------------------------
#
# A dispatch is accepted ONLY when its first argument opens a quote and that
# quote is immediately followed by `hl.` -- i.e. a Lua expression. `\"` is
# allowed because a dispatch nested inside a double-quoted shell string is
# written `hyprctl dispatch "hl.dsp.window.close({ ... })"` with the quote
# escaped. Anything else (a bareword like `workspace 1`, or an unexpanded
# variable whose contents this suite cannot see) is reported, on purpose:
# a human should look, and the reviewer's default should be "prove it".
DISPATCH_ANY='hyprctl([[:space:]]+-[^[:space:]]+)*[[:space:]]+dispatch[[:space:]]'
DISPATCH_OK="hyprctl([[:space:]]+-[^[:space:]]+)*[[:space:]]+dispatch[[:space:]]+\\\\?['\"]hl\\."

scan_old_dispatch() {
  local file
  for file in "$@"; do
    [[ -f $REPO_ROOT/$file ]] || continue
    grep -nE "$DISPATCH_ANY" -- "$REPO_ROOT/$file" 2>/dev/null |
      grep -vE "$DISPATCH_OK" |
      sed "s|^|${file}:|" || true
  done
}

# --- scanner 2: `hyprctl` over ssh with no instance signature -----------------
#
# Matches a line that runs ssh and hyprctl together and mentions no way of
# resolving the instance. Scoped to lines shaped like commands: markdown prose
# and blockquotes talking ABOUT the hazard are not commands anyone will paste.
SSH_HYPRCTL='(^|[^[:alnum:]_-])ssh[[:space:]][^;|]*hyprctl'
SSH_HAS_SIG='HYPRLAND_INSTANCE_SIGNATURE|--instance|hyprctl[[:space:]]+-i[[:space:]]'

scan_ssh_no_signature() {
  local file
  for file in "$@"; do
    [[ -f $REPO_ROOT/$file ]] || continue
    grep -nE "$SSH_HYPRCTL" -- "$REPO_ROOT/$file" 2>/dev/null |
      grep -vE "$SSH_HAS_SIG" |
      grep -vE '^\s*[0-9]+:\s*>' |
      sed "s|^|${file}:|" || true
  done
}

# --- scanner 3: `hyprctl eval 'return <sentinel>'`, a readback that cannot fail
#
# Matches an `eval` whose Lua expression OPENS with `return`. That is the dead
# readback form of hazard 3 above: eval reports its own status, never the
# value, so the caller learns nothing and reads it as a pass.
#
# `return` must be followed by a NON-WORD character, so `eval 'returns_ok()'`
# -- an ordinary call to a function whose name starts with those six letters --
# is not flagged. That is a real distinction and the good fixture pins it.
#
# Any leading flags are tolerated (`--instance 0`, `-i 1`) because a runbook
# that resolves the instance with a flag rather than the environment variable is
# still running the broken probe. `[^|;&]*` keeps the match inside one command,
# so a pipeline whose LATER stage happens to say `return` is not attributed to
# hyprctl.
#
# ⚠️ Prose that QUOTES the broken form is not exempted by a comment-stripping
# rule, deliberately: the defect being guarded lives in a COMMENT inside the
# Deck's own input.lua, telling a human which command to run. A scanner that
# skipped comments would miss the exact instance that motivated it. The files
# whose job is to discuss the hazard (docs/PROGRESS.md, docs/findings/**,
# docs/START-HERE.md, this file) are excluded by in_scope above; everywhere else
# the literal shape is reported and the prose is written so it does not use it.
EVAL_RETURN="hyprctl[[:space:]][^|;&]*eval[[:space:]]+\\\\?['\"][[:space:]]*return[^[:alnum:]_]"

scan_eval_return() {
  local file
  for file in "$@"; do
    [[ -f $REPO_ROOT/$file ]] || continue
    grep -nE "$EVAL_RETURN" -- "$REPO_ROOT/$file" 2>/dev/null |
      sed "s|^|${file}:|" || true
  done
}

# --- the positive controls ----------------------------------------------------
#
# ⚠️ THE LOAD-BEARING PART. All three scanners above are greps, and a grep that
# has stopped matching reports zero hits -- which is indistinguishable from a
# clean tree. Every assertion in this file would pass with all three regexes
# replaced by `xyzzy`. So each scanner is first run against a file that is KNOWN
# BAD and must flag it, and against one that is KNOWN GOOD and must not.
FIXTURES=$(mktemp -d) || fail "mktemp -d failed"
trap 'rm -rf "$FIXTURES"' EXIT
mkdir -p "$FIXTURES/fx"

cat >"$FIXTURES/fx/bad.sh" <<'BADEOF'
hyprctl dispatch movetoworkspacesilent 2,address:0xdeadbeef
hyprctl dispatch workspace 1 >/dev/null 2>&1 || true
ssh steamdeck 'hyprctl reload && hyprctl configerrors'
BADEOF

# Scanner 3 gets its OWN bad fixture rather than four more lines in the file
# above: fx/bad.sh's hit COUNTS are asserted for the other two scanners, and an
# `ssh ... hyprctl` line added here would silently change scanner 2's expected
# number from 1 to 2 -- fixing one control by breaking another.
cat >"$FIXTURES/fx/bad-eval.sh" <<'BADEVALEOF'
hyprctl eval 'return DECK_INPUT_LUA_LOADED'
ssh steamdeck 'export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr/ | head -1); hyprctl eval "return DECK_OSK_KB_LAYOUT"'
hyprctl --instance 0 eval 'return  DECK_INPUT_LUA_LOADED'
ssh deck "export HYPRLAND_INSTANCE_SIGNATURE=x; hyprctl eval \"return DECK_INPUT_LUA_LOADED\""
BADEVALEOF

cat >"$FIXTURES/fx/good.sh" <<'GOODEOF'
hyprctl eval 'if DECK_INPUT_LUA_LOADED == nil then error("input.lua was discarded") end'
hyprctl eval "if DECK_OSK_KB_LAYOUT ~= 'us' then error('the rule did not load') end"
hyprctl eval 'returns_a_value_and_is_not_the_broken_form()'
hyprctl dispatch 'hl.dsp.focus({ workspace = 2 })'
hyprctl dispatch "hl.dsp.window.close({ window = \"address:$a\" })"
hyprctl -j clients | jq -r '.[].address'
hyprctl cursorpos
ssh steamdeck 'export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr/ | head -1); hyprctl eval "hl.clear_crashed_lockscreen()"'
ssh steamdeck 'hyprctl --instance 0 eval "hl.monitor({})"'
GOODEOF

control_hits=$(REPO_ROOT=$FIXTURES scan_old_dispatch fx/bad.sh) || true
[[ $(grep -c . <<<"${control_hits:-}") == 2 ]] ||
  fail "CONTROL: the old-dispatch scanner flags known-bad lines" \
    "expected 2 hits in the bad fixture, got:
${control_hits:-<nothing>}
The scanner is broken. A broken scanner reports a clean tree, so every
assertion below it would pass while checking nothing. Fix DISPATCH_ANY /
DISPATCH_OK -- do not delete this control."

control_clean=$(REPO_ROOT=$FIXTURES scan_old_dispatch fx/good.sh) || true
[[ -z ${control_clean//[[:space:]]/} ]] ||
  fail "CONTROL: the old-dispatch scanner accepts the Lua form" \
    "the scanner flagged valid 0.56.2 syntax, which would make this suite
unpassable and get it deleted:
${control_clean}"
pass "CONTROL: old-dispatch scanner flags both bad forms, accepts both Lua forms"

control_hits=$(REPO_ROOT=$FIXTURES scan_ssh_no_signature fx/bad.sh) || true
[[ $(grep -c . <<<"${control_hits:-}") == 1 ]] ||
  fail "CONTROL: the ssh-signature scanner flags a known-bad line" \
    "expected 1 hit in the bad fixture, got:
${control_hits:-<nothing>}
See the note above -- a scanner that matches nothing passes everything."

control_clean=$(REPO_ROOT=$FIXTURES scan_ssh_no_signature fx/good.sh) || true
[[ -z ${control_clean//[[:space:]]/} ]] ||
  fail "CONTROL: the ssh-signature scanner accepts a resolved instance" \
    "flagged a command that does resolve the instance:
${control_clean}"
pass "CONTROL: ssh-signature scanner flags the bare form, accepts export and --instance"

control_hits=$(REPO_ROOT=$FIXTURES scan_eval_return fx/bad-eval.sh) || true
[[ $(grep -c . <<<"${control_hits:-}") == 4 ]] ||
  fail "CONTROL: the eval-readback scanner flags known-bad lines" \
    "expected 4 hits in the bad fixture, got:
${control_hits:-<nothing>}
This scanner exists because a readback reports nothing and reads as a pass. A
BROKEN scanner does the same thing one level up: it reports a clean tree and
every assertion below passes while checking nothing. Fix EVAL_RETURN -- do not
delete this control."

control_clean=$(REPO_ROOT=$FIXTURES scan_eval_return fx/good.sh) || true
[[ -z ${control_clean//[[:space:]]/} ]] ||
  fail "CONTROL: the eval-readback scanner accepts the assertion form" \
    "the scanner flagged the WORKING probe (or an ordinary call to a function
whose name merely starts with 'return'), which would make this suite unpassable
and get it deleted:
${control_clean}"
pass "CONTROL: eval-readback scanner flags all four readback spellings, accepts the assertion form"

# --- the actual assertions ----------------------------------------------------

hits=$(scan_old_dispatch "${SCOPE[@]}") || true
[[ -z ${hits//[[:space:]]/} ]] ||
  fail "no old-syntax 'hyprctl dispatch' anywhere this project ships or runs" \
    "${hits}

Hyprland 0.56.2 parses a dispatch argument as LUA. The bareword form above is
a SYNTAX ERROR, reported on stderr, and the command does nothing. Rewrite it as
  hyprctl dispatch 'hl.dsp.<namespace>.<action>({ ... })'
using the namespace listing in docs/findings/T10-steam-extest-results.md §3,
and do NOT discard stderr. If a query subcommand can answer the question
instead (hyprctl -j clients / -j monitors / cursorpos), prefer that -- queries
are unaffected by this change."
pass "no old-syntax 'hyprctl dispatch' in ${#SCOPE[@]} in-scope files"

hits=$(scan_ssh_no_signature "${SCOPE[@]}") || true
[[ -z ${hits//[[:space:]]/} ]] ||
  fail "every 'hyprctl' run over ssh resolves HYPRLAND_INSTANCE_SIGNATURE" \
    "${hits}

Over SSH the variable is unset and hyprctl exits before doing anything:
  HYPRLAND_INSTANCE_SIGNATURE not set! (is hyprland running?)
A command that never ran produces no errors, which reads as a pass. Resolve the
instance first, the way docs/RECOVERY.md does:
  ssh deck 'export HYPRLAND_INSTANCE_SIGNATURE=\$(ls -t /run/user/1000/hypr/ | head -1); hyprctl ...'"
pass "no 'hyprctl' over ssh without an instance signature"

hits=$(scan_eval_return "${SCOPE[@]}") || true
[[ -z ${hits//[[:space:]]/} ]] ||
  fail "no 'hyprctl eval' sentinel READBACK -- the probe must assert, not read" \
    "${hits}

On Hyprland 0.56.2 'hyprctl eval' prints 'ok' -- its own status, not the value
-- and exits 0 for every expression that does not raise, including a global that
has never existed (measured with 'return DECK_NOPE' as the negative control).
A readback therefore passes whether the config loaded or not, which is the exact
opposite of what a sentinel is for: Hyprland discards a Lua file with a syntax
error WHOLESALE and 'hyprctl configerrors' still comes back clean.

Rewrite it as an assertion, which eval does report (exit 7, with the message):
  hyprctl eval 'if DECK_INPUT_LUA_LOADED == nil then error(\"input.lua was discarded\") end'
exit 0 = loaded, exit 7 = discarded. Copy the shape from verify_osk_kb_layout in
src/deck-session.sh rather than inventing a variant, and remember R-46: over ssh
the call needs HYPRLAND_INSTANCE_SIGNATURE or it never runs at all."
pass "no 'hyprctl eval' readback of a sentinel -- every probe asserts"

printf 'all hyprctl-syntax tests passed\n'

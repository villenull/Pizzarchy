#!/usr/bin/env bash
# Guards the two ways a `hyprctl` call in this repo fails while LOOKING fine.
#
# WHY THIS EXISTS
#
# Both were measured on the Deck, both cost real time, and neither is visible
# to any other check in this repo, because in both cases the command exits
# without doing anything and the caller cannot tell that apart from success.
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
for must in docs/RECOVERY.md src/deck-session.sh docs/tasks/P2.9-deck-session-runbook.md; do
  printf '%s\n' "${SCOPE[@]}" | grep -qxF "$must" ||
    fail "the files this suite exists to protect are in scope" \
      "${must} is not in the scan set -- it was renamed, deleted, or newly
excluded. Update this suite rather than letting its coverage lapse silently."
done
pass "scan set built: ${#SCOPE[@]} tracked files, the three load-bearing ones present"

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

# --- the positive controls ----------------------------------------------------
#
# ⚠️ THE LOAD-BEARING PART. Both scanners above are greps, and a grep that has
# stopped matching reports zero hits -- which is indistinguishable from a clean
# tree. Every assertion in this file would pass with both regexes replaced by
# `xyzzy`. So each scanner is first run against a file that is KNOWN BAD and
# must flag it, and against one that is KNOWN GOOD and must not.
FIXTURES=$(mktemp -d) || fail "mktemp -d failed"
trap 'rm -rf "$FIXTURES"' EXIT
mkdir -p "$FIXTURES/fx"

cat >"$FIXTURES/fx/bad.sh" <<'BADEOF'
hyprctl dispatch movetoworkspacesilent 2,address:0xdeadbeef
hyprctl dispatch workspace 1 >/dev/null 2>&1 || true
ssh steamdeck 'hyprctl reload && hyprctl configerrors'
BADEOF

cat >"$FIXTURES/fx/good.sh" <<'GOODEOF'
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

printf 'all hyprctl-syntax tests passed\n'

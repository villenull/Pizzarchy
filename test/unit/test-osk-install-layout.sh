#!/usr/bin/env bash
# Unit tests for where the OSK layout core is INSTALLED, and whether the mapper
# can still find it there. No Deck, no VM, no root: builds a throwaway tree in
# the shape stage-input-mapper produces and runs the real script inside it.
#
# ⚠️ Why this suite exists. The install path is derived TWICE, independently:
#
#   deck-session.sh      OSK_LIB_DIR=/usr/local/lib/deck-osk   (literal)
#   deck-input-mapper.py <script dir>/../lib/deck-osk          (computed)
#
# Nothing makes those agree. Move MAPPER_BIN to /usr/bin and the mapper looks in
# /usr/lib while the stage writes to /usr/local/lib, and the result is a mapper
# that starts, logs one line nobody reads, and has no character keys. Session 17
# lost a day to exactly that shape of defect: present, enumerated, silent.

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- the two paths must agree, and are read from the sources -----------------

mapper_bin=$(grep -oP '^readonly MAPPER_BIN=\K\S+' "$REPO_ROOT/src/deck-session.sh") ||
  fail "MAPPER_BIN is declared in deck-session.sh"
osk_lib_dir=$(grep -oP '^readonly OSK_LIB_DIR=\K\S+' "$REPO_ROOT/src/deck-session.sh") ||
  fail "OSK_LIB_DIR is declared in deck-session.sh"
osk_src=$(grep -oP '^readonly OSK_SRC_NAME=\K\S+' "$REPO_ROOT/src/deck-session.sh") ||
  fail "OSK_SRC_NAME is declared in deck-session.sh"

# What the mapper will actually search, given where the stage puts the script.
derived="$(dirname -- "$(dirname -- "$mapper_bin")")/lib/deck-osk"
[[ $derived == "$osk_lib_dir" ]] ||
  fail "the stage's OSK_LIB_DIR is where the mapper will look" \
       "stage installs to $osk_lib_dir; mapper derives $derived from MAPPER_BIN=$mapper_bin"
pass "the install directory and the mapper's search path agree ($osk_lib_dir)"

[[ -f "$REPO_ROOT/src/$osk_src" ]] ||
  fail "the module named by OSK_SRC_NAME exists in src/" "$osk_src"
pass "OSK_SRC_NAME names a file that exists ($osk_src)"

# Every module the stage ships must exist. They install as a SET: a mapper with
# the layout core but no renderer starts, navigates, and has no keyboard.
osk_modules_line=$(grep -oP '^OSK_MODULES=\(\K[^)]+' "$REPO_ROOT/src/deck-session.sh") ||
  fail "OSK_MODULES is declared in deck-session.sh"
# shellcheck disable=SC2206  # deliberate word-splitting of a known-safe list
osk_modules=(${osk_modules_line//\"\$OSK_SRC_NAME\"/$osk_src})
[[ ${#osk_modules[@]} -ge 2 ]] ||
  fail "OSK_MODULES lists the renderer as well as the core" "${osk_modules[*]}"
for mod in "${osk_modules[@]}"; do
  [[ -f "$REPO_ROOT/src/$mod" ]] ||
    fail "every module in OSK_MODULES exists in src/" "missing: $mod"
done
pass "OSK_MODULES lists ${#osk_modules[@]} modules and all exist (${osk_modules[*]})"

# --- build the installed shape and run the real script in it -----------------
#
# Mirrors stage-input-mapper: the script loses its .py extension, the module
# keeps its name and goes in the lib directory.

root="$work/root"
mkdir -p "$root$(dirname -- "$mapper_bin")" "$root$osk_lib_dir"
install -m 0755 "$REPO_ROOT/src/deck-input-mapper.py" "$root$mapper_bin"
for mod in "${osk_modules[@]}"; do
  install -m 0644 "$REPO_ROOT/src/$mod" "$root$osk_lib_dir/$mod"
done

# --dry-run resolves text through the layout and prints keystrokes without
# opening /dev/uinput, so this needs no session, no pad and no privileges.
out=$("$root$mapper_bin" --type 'aA1!' --dry-run 2>&1) ||
  fail "the installed mapper types through the layout core" "$out"
pass "the installed mapper finds the layout core and resolves text"

grep -q 'KEY_LEFTSHIFT' <<<"$out" ||
  fail "a capital resolves to a shifted keystroke" "$out"
pass "a capital resolves to shift + key, not a bare keycode"

grep -q 'KEY_A' <<<"$out" || fail "a letter resolves to its keycode" "$out"
pass "a letter resolves to its keycode"

# The renderer is not on the --type path, so it needs its own check from the
# INSTALLED directory: it also has to find the layout core from there, and
# `import deck_osk_layout` inside it is the thing that would break.
rendered=$(python3 -c "
import sys
sys.path.insert(0, '$root$osk_lib_dir')
import deck_osk_layout as osk, deck_osk_tty as tty
rows = tty.render(osk.OnScreenKeyboard(), osk.Cursors())
print(len(rows), tty.width(rows))
" 2>&1) || fail "the installed renderer imports and draws" "$rendered"
[[ $rendered == "5 73" ]] ||
  fail "the installed renderer draws 5 rows, 73 columns" "got: $rendered"
pass "the installed renderer imports the core from the same directory and draws (5 rows, 73 cols)"

# The mapper must not have quietly fallen back to the copy in src/: that would
# make this suite pass on a dev machine and fail on the Deck, which is worse
# than failing here. Deleting the installed module must break it.
mv "$root$osk_lib_dir/$osk_src" "$work/stashed"
if broken=$("$root$mapper_bin" --type 'aA' --dry-run 2>&1); then
  fail "removing the installed module must make --type fail" "it still succeeded: $broken"
fi
pass "removing the installed module breaks --type, so the pass above was not a src/ fallback"

grep -q 'DISABLED' <<<"$broken" ||
  fail "a missing core says so on stderr" "$broken"
pass "a missing core is reported loudly, not swallowed"

# ⚠️ Loud but NOT fatal is deliberate: with lizard_mode=N the mapper is the only
# input path on the device, so refusing to start would leave a handheld with no
# pointer and no keys (docs/PROGRESS.md §5.9, §5.21). Navigation must survive.
mv "$work/stashed" "$root$osk_lib_dir/$osk_src"
listing=$("$root$mapper_bin" --list 2>&1) ||
  fail "--list works with the core present" "$listing"
mv "$root$osk_lib_dir/$osk_src" "$work/stashed"
listing=$("$root$mapper_bin" --list 2>&1) ||
  fail "--list must still work with the core MISSING -- navigation outlives the OSK" "$listing"
pass "a missing core costs the OSK and nothing else: --list still works"

# A core that is PRESENT but does not import is a different code path from one
# that is absent, and it is the likelier of the two: a half-written file, a
# partial rsync, a bad edit. It must degrade the same way.
printf 'this is not valid python(\n' >"$root$osk_lib_dir/$osk_src"
listing=$("$root$mapper_bin" --list 2>&1) ||
  fail "--list must survive a core that fails to IMPORT, not just one that is absent" "$listing"
grep -q 'DISABLED' <<<"$listing" ||
  fail "a broken core is reported loudly" "$listing"
pass "a broken (not merely missing) core also degrades loudly rather than killing the mapper"
mv "$work/stashed" "$root$osk_lib_dir/$osk_src"

# --- the stage must actually install it, and verify by running it ------------
#
# ⚠️ STATIC checks on the script text. stage-input-mapper writes to /usr/local
# and needs root, so this suite cannot run it; the stage verifies itself at
# runtime instead (that is the pattern every stage in deck-session.sh follows).
# These assertions only catch the install or the verification being DELETED,
# which is the failure that would otherwise reach the Deck unannounced.

stage_body=$(sed -n '/^stage_input_mapper()/,/^}/p' "$REPO_ROOT/src/deck-session.sh")
[[ -n $stage_body ]] ||
  fail "stage_input_mapper() is findable in deck-session.sh" \
       "the function name changed; this suite's static checks are now vacuous"
pass "stage_input_mapper() located in deck-session.sh"

grep -q 'install .*osk_module.*OSK_LIB_DIR' <<<"$stage_body" ||
  fail "the stage installs each OSK module into OSK_LIB_DIR" "$stage_body"
pass "the stage installs each OSK module into OSK_LIB_DIR"

# shellcheck disable=SC2016  # a grep PATTERN matching literal ${...} in the
# stage's source; expanding it here would search for this shell's variables.
grep -q 'for osk_module in "\${OSK_MODULES\[@\]}"' <<<"$stage_body" ||
  fail "the stage loops over OSK_MODULES rather than naming one file" "$stage_body"
pass "the stage ships the whole OSK_MODULES set, not just the core"

grep -q 'import deck_osk_layout, deck_osk_tty, deck_osk_wayland' <<<"$stage_body" ||
  fail "the stage verifies BOTH renderers import -- neither is on the --type path" "$stage_body"
pass "the stage verifies both renderers import from the installed directory"

[[ ${#osk_modules[@]} -eq 3 ]] ||
  fail "OSK_MODULES carries the core and both renderers" "${osk_modules[*]}"
pass "OSK_MODULES carries the core and both renderers"

# Match the INVOCATION, not the string "--type": the failure message beside it
# also contains "--type", so a looser grep passes with the check deleted.
# (Mutation-tested: replacing the command with `true` survived a bare grep.)
# shellcheck disable=SC2016  # a grep PATTERN: \$ matches a literal dollar in
# the stage's source, which is the whole point of the assertion.
grep -q '\$("\$MAPPER_BIN" --type' <<<"$stage_body" ||
  fail "the stage verifies the core by RUNNING the mapper, not by stat-ing a file" "$stage_body"
pass "the stage verifies the install by running the mapper's --type path"

printf '\nall OSK install-layout tests passed\n'

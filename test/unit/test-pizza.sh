#!/usr/bin/env bash
# Unit tests for src/pizza (the dispatcher) and src/pizza-pizza (the easter
# egg), with no root, no VM, no Deck and no network.
#
# ---------------------------------------------------------------------------
# WHAT IS ASSERTED, AND WHAT IS DELIBERATELY NOT
# ---------------------------------------------------------------------------
#
# 🔴 NOTHING HERE PINS THE ART. Not a byte of it, not a line of it, not its
# width. This project has five recorded instances of a test that pinned a value
# it did not own and went red on somebody else's legitimate change, and the art
# is the most obviously swappable thing in this repo -- the whole point of
# src/pizza-art/pizza.txt is that replacing it is a one-file change.
#
# So what is asserted about the art is its CONTRACT (pure ASCII, no raw ANSI,
# only $1..$9, rectangular, sane size), which every candidate must satisfy and
# which a new candidate satisfies too. And what is asserted about the mechanism
# is that it is idempotent, that `off` is byte-exact, and that a malformed art
# file is refused loudly. Change the pizza; this suite stays green.
#
# ---------------------------------------------------------------------------
# THE FASTFETCH SEAM
# ---------------------------------------------------------------------------
#
# pizza-pizza refuses to install unless it can render fastfetch and SEE the
# pizza in the output -- that is what catches a fastfetch whose duplicate-key
# rule is not the one this depends on. The CI runner has no fastfetch, so §4-§7
# run against a stub that models the two behaviours measured on real ones:
#
#   * duplicate JSON keys resolve FIRST-wins (measured on 2.66.0 dev, 2.67.0
#     Deck, both with a two-"logo" config naming two different files);
#   * a logo file that cannot be read is not an error -- fastfetch silently
#     draws its builtin distro logo instead (measured the same way).
#
# §8 then runs the SAME cases against the real fastfetch when the machine has
# one, so the model above is checked rather than assumed. It is skipped, out
# loud, where there is none.

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
PIZZA="$REPO_ROOT/src/pizza"
PIZZA_PIZZA="$REPO_ROOT/src/pizza-pizza"
ART_DIR="$REPO_ROOT/src/pizza-art"

assertions=0
pass()      { assertions=$((assertions + 1)); printf 'ok - %s\n' "$1"; }
fail_test() { printf 'not ok - %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2; exit 1; }
skip()      { printf 'ok - # SKIP %s\n' "$1"; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

[[ -x $PIZZA ]]       || fail_test "src/pizza exists and is executable" "a command nobody can run is not installed"
[[ -x $PIZZA_PIZZA ]] || fail_test "src/pizza-pizza exists and is executable"
pass "src/pizza and src/pizza-pizza exist and are executable"

# ===========================================================================
# 1. The art contract -- every candidate, not just the active one
# ===========================================================================
#
# Both alternates are shipped by stage-pizza so the pizza can be swapped on a
# Deck with one `cp`, which means all of them are load-bearing and all of them
# have to satisfy the contract.

shopt -s nullglob
art_files=("$ART_DIR"/*.txt)
shopt -u nullglob
[[ ${#art_files[@]} -ge 1 ]] ||
  fail_test "src/pizza-art carries at least one logo" "found none in ${ART_DIR}"
pass "src/pizza-art carries ${#art_files[@]} logo file(s)"

[[ -f "$ART_DIR/pizza.txt" ]] ||
  fail_test "src/pizza-art/pizza.txt is the active logo" \
    "deck-session.sh's PIZZA_ART_NAME names it and stage-pizza installs it; without it the stage aborts"
pass "src/pizza-art/pizza.txt is present -- the one name deck-session.sh knows"

for art in "${art_files[@]}"; do
  name=$(basename -- "$art")
  problems=$(python3 - "$art" <<'PY'
import sys
raw = open(sys.argv[1], "rb").read()
bad = []
for off, b in enumerate(raw):
    if b == 0x1B:
        bad.append("raw ESC at offset %d (colour must come from logo.color, "
                   "not from bytes in the art)" % off)
        break
    if b > 0x7F:
        bad.append("non-ASCII byte 0x%02X at offset %d (the Linux console draws "
                   "a box for these -- see DECK_NET_SECURED_GLYPH)" % (b, off))
        break
    if b < 0x20 and b != 0x0A:
        bad.append("control byte 0x%02X at offset %d" % (b, off))
        break
if not bad:
    text = raw.decode("ascii")
    if not text.endswith("\n"):
        bad.append("no trailing newline")
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    holders = {"$%d" % n for n in range(1, 10)}
    widths, indents = [], set()
    for i, line in enumerate(lines, 1):
        plain, j = [], 0
        while j < len(line):
            if line[j] == "$":
                if line[j:j + 2] in holders:
                    j += 2
                    continue
                bad.append("line %d: '$' that is not $1..$9" % i)
                break
            plain.append(line[j])
            j += 1
        plain = "".join(plain)
        if plain.rstrip() != plain:
            bad.append("line %d: trailing whitespace" % i)
        widths.append(len(plain.rstrip()))
        if plain.strip():
            indents.add(len(plain) - len(plain.lstrip(" ")))
    # 🔴 THIS REQUIRED EVERY ROW FLUSH RIGHT AND AT MOST TWO INDENTS. Both
    # described the SQUARE pizza rather than the format, and both refused the
    # ROUND one the operator picked -- a circle is short on nearly every row by
    # construction. fastfetch pads short rows itself and has no opinion on
    # shape. Shape is an art decision and this file does not own it.
    if widths:
        w = max(widths)
        if not (30 <= w <= 60):
            bad.append("%d cols, outside 30..60" % w)
        if all(x == 0 for x in widths):
            bad.append("every row is blank")
    if not (10 <= len(lines) <= 30):
        bad.append("%d rows, outside 10..30" % len(lines))
print("; ".join(bad))
PY
)
  [[ -z $problems ]] || fail_test "${name} satisfies the fastfetch logo contract" "$problems"
  pass "${name}: pure ASCII, no raw ANSI, only \$1..\$9, no trailing space, sane size"
done

# The installed command must agree with this suite about what "well-formed"
# means -- two validators that disagree would let one of them pass a file the
# other refuses, at install time, on a Deck.
for art in "${art_files[@]}"; do
  PIZZA_ART="$art" "$PIZZA_PIZZA" check >/dev/null 2>&1 ||
    fail_test "'pizza pizza check' accepts $(basename -- "$art")" \
      "this suite says the file is well-formed and the shipped command says it is not"
done
pass "'pizza pizza check' accepts every shipped logo, so the two validators agree"

# ===========================================================================
# 2. The dispatcher
# ===========================================================================

run() {   # run <expected rc> <desc> -- command...
  local expect=$1 desc=$2; shift 2
  local rc=0
  "$@" >"$work/out" 2>"$work/err" || rc=$?
  [[ $rc -eq $expect ]] ||
    fail_test "$desc" "exited ${rc}, expected ${expect}"$'\n'"stdout:"$'\n'"$(cat "$work/out")"$'\n'"stderr:"$'\n'"$(cat "$work/err")"
  pass "$desc"
}
in_out() { grep -qF -- "$1" "$work/out" || fail_test "$2" "not on stdout: ${1}"$'\n'"$(cat "$work/out")"; pass "$2"; }
in_out_re() { grep -qE -- "$1" "$work/out" || fail_test "$2" "no line matched /${1}/:"$'\n'"$(cat "$work/out")"; pass "$2"; }
in_err() { grep -qF -- "$1" "$work/err" || fail_test "$2" "not on stderr: ${1}"$'\n'"$(cat "$work/err")"; pass "$2"; }

run 0 "bare 'pizza' exits 0 and prints its help" "$PIZZA"
in_out_re '^  pizza +[a-z]' "the help lists the 'pizza' subcommand as its own row"
in_out_re '^  ssh +[a-z]' "and lists 'ssh', which this repo does not implement, rather than hiding it"
run 0 "'pizza help' prints the same help" "$PIZZA" help
run 0 "'pizza --help' too" "$PIZZA" --help

run 2 "an unknown subcommand is a usage error, not a crash" "$PIZZA" nosuchthing
in_err "no subcommand 'nosuchthing'" "and it says which name it could not resolve"

run 2 "a subcommand name that is a path is refused before anything is resolved" "$PIZZA" ../../bin/sh
in_err "is not a subcommand name" "and says names are not paths"

run 2 "an absolute path is refused too" "$PIZZA" /bin/sh

# The seam, and the argument pass-through with it.
subdir="$work/subs"
mkdir -p "$subdir"
cat >"$subdir/pizza-echo" <<'STUB'
#!/usr/bin/env bash
printf 'ARGS:%s\n' "$*"
exit 7
STUB
chmod +x "$subdir/pizza-echo"
run 7 "the dispatcher returns the subcommand's own exit status, unchanged" \
  env PIZZA_SUBCOMMAND_DIR="$subdir" "$PIZZA" echo one "two three"
in_out 'ARGS:one two three' "and hands it every remaining argument, quoting intact"

# A subcommand that exists but is not executable is not a subcommand: the
# dispatcher must say so rather than exec'ing something it cannot run.
cp "$subdir/pizza-echo" "$subdir/pizza-inert"
chmod 0644 "$subdir/pizza-inert"
run 2 "a non-executable pizza-<name> is reported missing, not exec'd" \
  env PIZZA_SUBCOMMAND_DIR="$subdir" "$PIZZA" inert

# ===========================================================================
# 3. The stub fastfetch -- see THE FASTFETCH SEAM above
# ===========================================================================

stub_bin="$work/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/fastfetch" <<'STUB_FF'
#!/usr/bin/env bash
# Test double for fastfetch. Models exactly two measured behaviours: duplicate
# JSON keys resolve FIRST-wins, and an unreadable logo file is silently replaced
# by the builtin distro logo. See test/unit/test-pizza.sh §3.
set -uo pipefail
config=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --config) config=$2; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n $config ]] && export FF_CONFIG_PATH="$config"
exec python3 - <<'PY'
import json, os, re, sys

path = os.environ.get("FF_CONFIG_PATH") or os.path.join(
    os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
    "fastfetch", "config.jsonc")
if not os.path.exists(path):
    sys.stdout.write("BUILTIN-DISTRO-LOGO\n")
    sys.exit(0)
raw = open(path).read()
raw = re.sub(r"^\s*//[^\n]*(\n|$)", "", raw, flags=re.M)
raw = re.sub(r",(\s*[}\]])", r"\1", raw)
try:
    # FIRST-wins, which is what fastfetch's parser does and what python's
    # default (last-wins) does not.
    cfg = json.loads(raw, object_pairs_hook=lambda pairs: {
        k: v for k, v in reversed(pairs)})
except ValueError as exc:
    sys.stderr.write("fastfetch: cannot parse %s: %s\n" % (path, exc))
    sys.exit(1)
source = (cfg.get("logo") or {}).get("source")
if not source or not os.path.exists(os.path.expanduser(source)):
    sys.stdout.write("BUILTIN-DISTRO-LOGO\n")
    sys.exit(0)
for line in open(os.path.expanduser(source)):
    sys.stdout.write(re.sub(r"\$[1-9]", "", line.rstrip("\n")) + "   MODULES\n")
PY
STUB_FF
chmod +x "$stub_bin/fastfetch"
pass "the stub fastfetch models first-wins duplicate keys and the silent missing-logo fallback"

# ===========================================================================
# 4. `pizza pizza` -- install, idempotency, and what it leaves outside markers
# ===========================================================================

# Stock, as measured on the Deck 2026-08-16: a system config exists and the user
# has none at all.
sys_cfg="$work/etc-fastfetch.jsonc"
cat >"$sys_cfg" <<'SYSCFG'
{
  "$schema": "https://example.invalid/schema.json",
  "logo": {
    "type": "file",
    "source": "~/.config/omarchy/branding/about.txt",
    "color": { "1": "green" }
  },
  "modules": ["title"]
}
SYSCFG

stock_rc=$'# Omarchy environment\n[[ $- != *i* ]] && return\n\n# Add your own exports, aliases, and functions here.\n'

sandbox_reset() {
  rm -rf "${work:?}/home"
  mkdir -p "$work/home/cfg"
  printf '%s' "$stock_rc" >"$work/home/bashrc"
  cp "$work/home/bashrc" "$work/home/bashrc.stock"
}

pz() {    # pz <args...> -- run pizza-pizza against the sandbox
  local rc=0
  PATH="$stub_bin:$PATH" \
  XDG_CONFIG_HOME="$work/home/cfg" \
  PIZZA_ART="${PZ_ART:-$ART_DIR/pizza.txt}" \
  PIZZA_FASTFETCH_TEMPLATE="$sys_cfg" \
  PIZZA_BASHRC="$work/home/bashrc" \
  "$PIZZA_PIZZA" "$@" >"$work/out" 2>"$work/err" || rc=$?
  return $rc
}
user_cfg="$work/home/cfg/fastfetch/config.jsonc"

sandbox_reset
run 0 "'pizza pizza' installs against a stock sandbox" pz
[[ -f $user_cfg ]] || fail_test "it creates the user fastfetch config" "stock Omarchy has none; ${user_cfg} should now exist"
pass "it creates the user fastfetch config Omarchy documents as the override"
grep -qxF -- '// >>> pizza pizza: ASCII pizza logo >>>' "$user_cfg" ||
  fail_test "the logo block is delimited by a begin marker" "$(cat "$user_cfg")"
grep -qxF -- '// <<< pizza pizza: ASCII pizza logo <<<' "$user_cfg" ||
  fail_test "the logo block is delimited by an end marker" "$(cat "$user_cfg")"
pass "the logo block carries whole-line begin/end markers, the shape deck-session.sh uses"
grep -qxF -- '# >>> pizza pizza: fastfetch greeting >>>' "$work/home/bashrc" ||
  fail_test "the greeting block is delimited by a begin marker" "$(cat "$work/home/bashrc")"
pass "the greeting block carries whole-line begin/end markers too"

# The seeded copy still has Omarchy's own config in it -- that is what makes
# `off` able to delete the file and restore stock exactly.
grep -qF 'about.txt' "$user_cfg" ||
  fail_test "the seeded config keeps Omarchy's own logo entry" \
    "our block wins by being FIRST, not by deleting theirs -- deleting it would make 'off' unable to restore"
grep -qF '"modules"' "$user_cfg" ||
  fail_test "the seeded config keeps Omarchy's modules" "the Hardware/Software/Age panels would be lost"
pass "the seeded config still carries Omarchy's own logo entry and modules, untouched below our block"

first_cfg=$(sha256sum "$user_cfg" | cut -d' ' -f1)
first_rc=$(sha256sum "$work/home/bashrc" | cut -d' ' -f1)
run 0 "a second run succeeds" pz
run 0 "and a third" pz
[[ $(sha256sum "$user_cfg" | cut -d' ' -f1) == "$first_cfg" ]] ||
  fail_test "re-running is byte-identical in the fastfetch config" "the block was appended again instead of replaced"$'\n'"$(cat "$user_cfg")"
[[ $(sha256sum "$work/home/bashrc" | cut -d' ' -f1) == "$first_rc" ]] ||
  fail_test "re-running is byte-identical in the shell rc" "the block was appended again instead of replaced"$'\n'"$(cat "$work/home/bashrc")"
pass "running it three times leaves both files byte-identical to running it once"

# Exactly one block each, which is the property a substring check misses.
[[ $(grep -cxF -- '// >>> pizza pizza: ASCII pizza logo >>>' "$user_cfg") -eq 1 ]] ||
  fail_test "exactly one logo block after three runs" "$(cat "$user_cfg")"
[[ $(grep -cxF -- '# >>> pizza pizza: fastfetch greeting >>>' "$work/home/bashrc") -eq 1 ]] ||
  fail_test "exactly one greeting block after three runs" "$(cat "$work/home/bashrc")"
pass "there is exactly one of each block, not three"

run 0 "'pizza pizza status' reports the installed state" pz status
in_out "logo      on" "status says the logo half is on"
in_out "greeting  on" "status says the greeting half is on"
in_out "pizza pizza is ON" "and gives a one-line verdict"

# ===========================================================================
# 5. `pizza pizza off` -- byte-exact, and only what is ours
# ===========================================================================

run 0 "'pizza pizza off' succeeds" pz off
cmp -s "$work/home/bashrc" "$work/home/bashrc.stock" ||
  fail_test "the shell rc is byte-for-byte what it was before" \
    "diff:"$'\n'"$(diff "$work/home/bashrc.stock" "$work/home/bashrc" || true)"
pass "the shell rc is restored byte-for-byte -- removing our block leaves no trace"
[[ ! -e $user_cfg ]] ||
  fail_test "the user fastfetch config is gone" \
    "stock Omarchy has no such file; what was left after our block was removed was a plain copy of the system config"$'\n'"$(cat "$user_cfg")"
pass "the user fastfetch config is removed, because stock Omarchy has none"

run 0 "'off' is idempotent -- running it again is not an error" pz off
in_out "carries no block of ours" "and says there was nothing to remove rather than pretending it removed something"

run 0 "'status' after 'off' reports stock" pz status
in_out "pizza pizza is OFF" "status says it is off"

# --- a user who put something of their own in the file ---------------------
#
# The rule that deletes the user config on `off` must be "what is left is a
# plain copy of the system config", not "we created it".
sandbox_reset
run 0 "install again, into a sandbox that will grow a user edit" pz
printf '// a note the user added\n' >>"$user_cfg"
run 0 "'off' with a user edit present" pz off
[[ -f $user_cfg ]] ||
  fail_test "a config carrying the user's own edit is KEPT" "it was deleted, taking their edit with it"
grep -qF 'a note the user added' "$user_cfg" ||
  fail_test "the user's edit survives 'off'" "$(cat "$user_cfg")"
grep -qxF -- '// >>> pizza pizza: ASCII pizza logo >>>' "$user_cfg" &&
  fail_test "our block is gone even though the file was kept" "$(cat "$user_cfg")"
in_out "was KEPT" "and it says out loud that the file was kept, and why"
pass "a config carrying anything of the user's is kept, minus our block; only a plain copy is deleted"

# --- everything outside the markers is preserved ---------------------------
sandbox_reset
printf '# a line the user wrote after the greeting\nexport USER_THING=1\n' >>"$work/home/bashrc"
cp "$work/home/bashrc" "$work/home/bashrc.stock"
run 0 "install into an rc with the user's own lines in it" pz
grep -qF 'export USER_THING=1' "$work/home/bashrc" ||
  fail_test "the user's own rc lines survive the install" "$(cat "$work/home/bashrc")"
run 0 "and remove it again" pz off
cmp -s "$work/home/bashrc" "$work/home/bashrc.stock" ||
  fail_test "the rc with user lines is restored byte-for-byte" \
    "$(diff "$work/home/bashrc.stock" "$work/home/bashrc" || true)"
pass "an rc carrying the user's own lines round-trips byte-for-byte"

# ===========================================================================
# 6. The greeting runs for interactive shells and ONLY interactive shells
# ===========================================================================
#
# 🔴 THE ONE THAT WOULD BREAK `pizza ssh`. A greeting that prints in a
# non-interactive shell corrupts scp, rsync and `ssh host command`, all of which
# read that stream as protocol. Both directions are asserted, against the
# INSTALLED file rather than the renderer, because what ships is the bytes.

sandbox_reset
run 0 "install, to get a real rc to execute" pz

greeting_block=$(python3 - "$work/home/bashrc" <<'PY'
import sys
keep, out = False, []
for line in open(sys.argv[1]):
    line = line.rstrip("\n")
    if line.strip() == "# >>> pizza pizza: fastfetch greeting >>>":
        keep = True
        continue
    if keep:
        if line.strip() == "# <<< pizza pizza: fastfetch greeting <<<":
            break
        out.append(line)
sys.stdout.write("\n".join(out))
PY
)
[[ -n $greeting_block ]] || fail_test "the greeting block can be read back out of the rc"

noninteractive=$(PATH="$stub_bin:$PATH" bash --noprofile --norc -c "$greeting_block" </dev/null 2>&1)
[[ -z $noninteractive ]] ||
  fail_test "the greeting block prints NOTHING in a non-interactive shell" \
    "it emitted, which would corrupt scp/rsync/'ssh host command':"$'\n'"${noninteractive}"
pass "the installed greeting block prints nothing at all in a non-interactive shell"

# The positive direction, so "silent" is not passing because the block is inert.
printf '%s\n' "$greeting_block" >"$work/greeting.bash"
interactive=$(PATH="$stub_bin:$PATH" bash --noprofile --norc -i \
  -c "source '$work/greeting.bash'" </dev/null 2>&1 || true)
grep -qF 'MODULES' <<<"$interactive" ||
  fail_test "the greeting block DOES run fastfetch in an interactive shell" \
    "nothing was printed, so the guard is refusing everything:"$'\n'"${interactive}"
pass "and it does run fastfetch in an interactive shell, so the guard is a guard and not an off switch"

# A whole rc, sourced non-interactively, the way `ssh host command` sources it.
whole=$(PATH="$stub_bin:$PATH" bash --noprofile --norc \
  -c "source '$work/home/bashrc'; printf 'hi\n'" </dev/null 2>&1)
[[ $whole == "hi" ]] ||
  fail_test "sourcing the whole patched rc non-interactively prints only the command's own output" \
    "expected exactly 'hi', got:"$'\n'"${whole}"
pass "sourcing the whole patched rc non-interactively yields exactly the command's own output"

run 0 "clean up the sandbox" pz off

# ===========================================================================
# 7. Failing loudly -- the cases where fastfetch would fail SILENTLY
# ===========================================================================

# --- a missing art file ---------------------------------------------------
sandbox_reset
PZ_ART="$work/does-not-exist.txt"
run 1 "a missing art file fails the install" pz
unset PZ_ART
in_err "does not exist" "and the failure names the missing file"
in_err "silently" "and says why it matters: fastfetch would draw its builtin logo and report nothing"
[[ ! -e $user_cfg ]] || fail_test "nothing was written when the art was missing" "$(cat "$user_cfg")"
cmp -s "$work/home/bashrc" "$work/home/bashrc.stock" ||
  fail_test "the shell rc was not touched when the art was missing"
pass "a missing art file leaves both files exactly as they were -- it degrades to stock, loudly"

# --- art with a non-ASCII byte in it --------------------------------------
sandbox_reset
printf '###\xe2\x96\x88###\n###   ###\n' >"$work/utf8-art.txt"
PZ_ART="$work/utf8-art.txt"
run 1 "art carrying a non-ASCII byte is refused" pz
unset PZ_ART
in_err "non-ASCII" "and the refusal names the byte, and says the Linux console draws a box for it"
[[ ! -e $user_cfg ]] || fail_test "nothing was written for non-ASCII art"
pass "non-ASCII art is refused before anything is written"

# --- art with a raw ANSI escape in it -------------------------------------
sandbox_reset
printf '\033[31m####\n####\n' >"$work/ansi-art.txt"
PZ_ART="$work/ansi-art.txt"
run 1 "art carrying a raw ANSI escape is refused" pz
unset PZ_ART
in_err "ESC" "and the refusal says colour belongs in the config's colour mapping"
pass "art with baked-in ANSI is refused -- colour must degrade to readable monochrome"

# --- art too wide for the panel -------------------------------------------
#
# 🔴 THIS WAS "ragged art is refused". It guarded the flush-right rule, which
# is gone with the square pizza. Width is the rule that survived and the one
# with a real consequence: fastfetch draws the logo LEFT of the info panel, so
# over-wide art pushes the panel off a 1280x800 screen. Kept as a negative
# control so the relaxation above cannot quietly become "checks nothing".
sandbox_reset
python3 - "$work/too-wide-art.txt" <<'PYX'
import sys
open(sys.argv[1], "w").write("\n".join(["#" * 80] * 12) + "\n")
PYX
PZ_ART="$work/too-wide-art.txt"
run 1 "art too wide for the panel is refused" pz
unset PZ_ART
in_err "outside 30..60" "and the refusal names the budget it broke"
pass "over-wide art is refused -- the size rule is still enforced"

# --- bare `pizza pizza` toggles -------------------------------------------
#
# Operator, 2026-08-16: "if pizza pizza is turned on, ever running it again
# should revert to the default omarchy settings". Asserted as a round trip
# from stock and back, because a toggle that only ever turns ON looks correct
# on a machine that was already off.
sandbox_reset
run 0 "toggle from stock turns it ON" pz
in_out "The pizza is served" "the first bare run installs"
run 0 "status agrees it is on" pz status
in_out "pizza pizza is ON" "both halves present after one bare run"

run 0 "toggling again turns it OFF" pz
run 0 "status agrees it is off" pz status
in_out "pizza pizza is OFF" "a second bare run reverted to stock Omarchy"
cmp -s "$work/home/bashrc" "$work/home/bashrc.stock" ||
  fail_test "the toggle-off restores the shell rc byte-for-byte" \
    "diff:"$'\n'"$(diff "$work/home/bashrc.stock" "$work/home/bashrc" || true)"
pass "bare 'pizza pizza' toggles, and toggling off is byte-exact"

# 🔴 HALF INSTALLED MUST TOGGLE **ON**, NOT OFF. If one block is missing --
# a half-finished run, a hand-edited rc -- the user running the command wants
# the pizza, not to have the remaining half silently removed and be told
# nothing happened. Only BOTH present counts as on.
run 0 "set up, then break one half" pz
python3 - "$work/home/bashrc" <<'PYX'
import sys, re
p = sys.argv[1]
t = open(p).read()
t = re.sub(r"# >>> pizza pizza: fastfetch greeting >>>.*?# <<< pizza pizza: fastfetch greeting <<<\n",
           "", t, flags=re.S)
open(p, "w").write(t)
PYX
run 0 "toggling a half-installed state completes it" pz
run 0 "status after completing" pz status
in_out "pizza pizza is ON" "half-installed toggles ON, it does not remove the other half"
run 0 "clean up" pz off

# --- a begin marker with no end marker ------------------------------------
sandbox_reset
{ printf '%s' "$stock_rc"
  printf '# >>> pizza pizza: fastfetch greeting >>>\nfastfetch\n'
} >"$work/home/bashrc"
run 1 "a block whose end marker was deleted by hand stops the run" pz
in_err "no end marker" "and refuses to guess where the old block ended"
pass "a half-removed block is refused rather than guessed at"

# --- a fastfetch that does not draw the pizza -----------------------------
#
# The check that exists because the whole logo mechanism rests on one measured
# parser behaviour. A fastfetch that resolved duplicate keys the other way would
# leave the block installed and the logo unchanged -- silently, without this.
sandbox_reset
cat >"$stub_bin/fastfetch" <<'LAST_WINS'
#!/usr/bin/env bash
# A fastfetch that resolves duplicate keys LAST-wins, i.e. one our block cannot
# win against. It renders successfully; it just does not draw the pizza.
printf 'SOME-OTHER-LOGO   MODULES\n'
LAST_WINS
run 1 "a fastfetch that does not draw the pizza fails the install" pz
in_err "did NOT draw the pizza" "and says the likely cause is the duplicate-key rule"
in_err "restored" "and says both files were put back"
cmp -s "$work/home/bashrc" "$work/home/bashrc.stock" ||
  fail_test "the shell rc is restored when the render check fails" \
    "$(diff "$work/home/bashrc.stock" "$work/home/bashrc" || true)"
[[ ! -e $user_cfg ]] ||
  fail_test "the user fastfetch config is removed when the render check fails" \
    "it did not exist before the run, so 'restored' means gone"$'\n'"$(cat "$user_cfg")"
pass "a failed render check restores BOTH files to exactly what they were, including 'there was no file'"

# ===========================================================================
# 8. The same questions, against a REAL fastfetch, when there is one
# ===========================================================================
#
# §3-§7 model fastfetch. This checks the model. It is skipped out loud rather
# than silently where the machine has no fastfetch (the CI runner does not).

if command -v fastfetch >/dev/null 2>&1; then
  ff_home="$work/ffreal"
  mkdir -p "$ff_home/fastfetch"
  printf 'PIZZA-FIRST-KEY\n' >"$work/ff-first.txt"
  printf 'PIZZA-SECOND-KEY\n' >"$work/ff-second.txt"
  cat >"$ff_home/fastfetch/config.jsonc" <<EOF
{
  "logo": { "type": "file", "source": "$work/ff-first.txt" },
  "logo": { "type": "file", "source": "$work/ff-second.txt" },
  "modules": ["title"]
}
EOF
  ff_out=$(cd /tmp && XDG_CONFIG_HOME="$ff_home" fastfetch --pipe 2>&1) || ff_out="<fastfetch failed>"
  grep -qF 'PIZZA-FIRST-KEY' <<<"$ff_out" ||
    fail_test "the real fastfetch resolves duplicate JSON keys FIRST-wins" \
      "this is the one parser behaviour the whole logo mechanism rests on. $(fastfetch --version 2>&1) said:"$'\n'"${ff_out}"
  pass "the real $(fastfetch --version 2>&1 | head -1) resolves duplicate keys first-wins, as the stub models"

  printf '{ "logo": { "type": "file", "source": "%s/nope.txt" }, "modules": ["title"] }\n' "$work" \
    >"$ff_home/fastfetch/config.jsonc"
  ff_rc=0
  (cd /tmp && XDG_CONFIG_HOME="$ff_home" fastfetch --pipe >/dev/null 2>&1) || ff_rc=$?
  [[ $ff_rc -eq 0 ]] ||
    fail_test "the real fastfetch treats an unreadable logo file as a non-error" \
      "it exited ${ff_rc}; the stub models a silent fallback, and 'pizza pizza status' warns on that basis"
  pass "the real fastfetch exits 0 on an unreadable logo file -- the silent fallback the validator exists to catch"

  # And the whole thing end to end, with the real binary doing the rendering.
  sandbox_reset
  real_rc=0
  XDG_CONFIG_HOME="$work/home/cfg" \
  PIZZA_ART="$ART_DIR/pizza.txt" \
  PIZZA_FASTFETCH_TEMPLATE="$sys_cfg" \
  PIZZA_BASHRC="$work/home/bashrc" \
    "$PIZZA_PIZZA" >"$work/out" 2>"$work/err" || real_rc=$?
  [[ $real_rc -eq 0 ]] ||
    fail_test "'pizza pizza' installs and self-verifies against the real fastfetch" \
      "stdout:"$'\n'"$(cat "$work/out")"$'\n'"stderr:"$'\n'"$(cat "$work/err")"
  in_out "bare 'fastfetch' picks up" "and it proves the file is found by discovery, not only by --config"
  XDG_CONFIG_HOME="$work/home/cfg" \
  PIZZA_ART="$ART_DIR/pizza.txt" \
  PIZZA_FASTFETCH_TEMPLATE="$sys_cfg" \
  PIZZA_BASHRC="$work/home/bashrc" \
    "$PIZZA_PIZZA" off >/dev/null 2>&1
  pass "the whole install/verify/remove cycle runs against the real fastfetch on this machine"
else
  skip "no fastfetch on this machine, so §8's checks against the real parser did not run. They are the ones that validate §3's stub; run this suite somewhere with fastfetch before trusting a change to the logo mechanism."
fi

printf '\nall pizza tests passed (%d assertions)\n' "$assertions"

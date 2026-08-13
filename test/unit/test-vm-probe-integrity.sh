#!/usr/bin/env bash
# Static integrity checks over test/vm/'s suites and their in-guest probes.
# No QEMU, no substrate image, no root -- everything here is text over source.
#
# ===========================================================================
# WHY THIS FILE EXISTS
# ===========================================================================
#
# Three defect classes, each of which had a live instance in test/vm/ on
# 2026-08-12, and each of which is invisible to every tool the repo already
# runs.
#
# 1. A GUEST PAYLOAD THAT DOES NOT PARSE.
#    Every VM suite ships code to the guest inside a QUOTED heredoc.
#    `bash -n` on the SUITE cannot see into a quoted heredoc -- to bash it is
#    an opaque string -- and shellcheck does not follow it either. So the outer
#    file can be perfectly clean while the thing that actually runs in the VM
#    cannot be parsed at all. vm-gamepad-spike-test.sh was in exactly that
#    state from the commit that introduced it (861f922, 2026-08-10): a stale
#    duplicated copy of two sections left an unmatched `fi`, a call to a
#    `resync` that no longer existed, and a `$WITNESS_PID` that is never set.
#    The suite could not have run for two days and nothing said so, because
#    the only thing that would have said so is a ~15-minute VM boot.
#
#    ⚠️ THE FIRST VERSION OF THIS FILE ONLY LOOKED FOR `<<'PROBE'`, WHICH IS
#    THE SAME MISTAKE ONE LEVEL UP. A delimiter spelled into the scanner is a
#    filename list wearing a disguise: the eight `PROBE` bodies were checked
#    and the ten OTHER guest payloads in the same directory -- `PAD`, `TUI`,
#    `PY`, `UD` -- were not checked by anything, in this repo, ever. A suite
#    that shipped a broken virtual pad, or a new suite that called its probe
#    `<<'GUEST'`, would have sailed through a green run. Section A now DERIVES
#    the delimiter set from the source, checks bash payloads with `bash -n` and
#    Python payloads with `compile()`, and treats a payload it cannot classify
#    as a failure unless it is declared -- because "the scanner did not
#    recognise it" and "there is nothing wrong with it" must not look alike.
#
# 2. A GREP OVER CONSOLE BYTES THAT IS NOT BYTE-SAFE.
#    T4's §6.4 lie #7: a bare `grep` over a /dev/vcsN capture silently returns
#    nothing when the screen contains a high byte, because the kernel's screen
#    buffer is ONE BYTE PER CELL in the console charmap and is not UTF-8.
#    docs/findings/T4-harness-first-run.md is the write-up; the corrected
#    reference implementation is test/lib/vm-installer-screens.sh.
#
#    ⚠️ THE COMFORTING VERSION OF THIS IS FALSE. It is tempting to say the
#    in-guest probes are safe because systemd starts services with no LANG.
#    test/images/vm-neptune-image.sh writes `LANG=en_US.UTF-8` into the
#    substrate's /etc/locale.conf; systemd puts that in the manager
#    environment and every service inherits it. The probes really do grep
#    non-UTF-8 bytes in a UTF-8 locale, and the only reason they have been
#    returning right answers is that their captures happen to contain no high
#    bytes yet.
#
# 3. A CHECK WHOSE PASSING STATE LOOKS LIKE ITS NOT-HAVING-RUN STATE.
#    docs/PROGRESS.md §5.30c: "a check that proves something is ABSENT must
#    also prove it was LOOKING." A suite that never propagates its exit status
#    is the crudest form -- it prints FAIL and returns 0.
#
# ===========================================================================
# EVERY SCANNER HERE CARRIES A POSITIVE AND A NEGATIVE CONTROL
# ===========================================================================
#
# The pattern is test/unit/test-hyprctl-syntax.sh's, for its reason: a regex
# that stops matching reports a clean tree forever, and a clean tree is what
# success looks like. So each scanner is first run against a fixture built to
# be caught (positive control -- it MUST be flagged) and a fixture built to be
# clean (negative control -- it must NOT be flagged), and only then against
# the real tree. If a scanner is ever edited into uselessness, the positive
# control fails long before the tree goes quietly green.
#
# The scanners are also asserted to have found a non-zero number of subjects.
# A file glob that matches nothing scans nothing and passes.

set -uo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
VM_DIR="$REPO_ROOT/test/vm"

status=0
checks=0
pass() { checks=$((checks + 1)); printf 'ok - %s\n' "$1"; }
fail() {
  checks=$((checks + 1))
  status=1
  printf 'not ok - %s\n' "$1"
  [[ -n ${2:-} ]] && printf '      %s\n' "$2" >&2
  return 0
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# ---------------------------------------------------------------------------
# The payload scanner, shared by section A and used nowhere else.
# ---------------------------------------------------------------------------

# payload::openers <file> -- one record per QUOTED heredoc opener, in file
# order:  <line>|<delimiter>|<nth occurrence of that delimiter>|<opener text>
#
# ⚠️ THE DELIMITER SET IS DERIVED, NOT LISTED. Nothing here knows the word
# "PROBE". A suite that ships its guest script as `<<'GUEST'` is discovered on
# the same terms as the eight that use PROBE, which is the whole point: the
# next broken payload will be in a file nobody has thought to name yet.
#
# Unquoted heredocs (`<<EOF`) are deliberately out of scope -- their bodies are
# expanded by the outer shell, so they are not standalone programs and `$vars`
# in them would parse as nothing in particular.
payload::openers() {
  LC_ALL=C command awk '
    match($0, /<<-?\047[A-Za-z_][A-Za-z0-9_]*\047/) {
      d = substr($0, RSTART, RLENGTH)
      sub(/^<<-?\047/, "", d)
      sub(/\047$/, "", d)
      n[d]++
      printf "%d|%s|%d|%s\n", FNR, d, n[d], $0
    }' "$1"
}

# payload::extract <file> <delimiter> <nth> -- prints that heredoc's body.
#
# The occurrence index is load-bearing, not tidiness: vm-installer-screens-test.sh
# and vm-iso-probe-feasibility.sh ship two and three separate `PY` programs.
# Concatenating them and parsing the result is a different question from the one
# being asked, and it can answer either way by luck -- two valid programs can
# concatenate into an invalid one, and (with a trailing `\` or an open bracket)
# two invalid ones into something that compiles.
payload::extract() {
  local file=$1 delim=$2 want=$3
  LC_ALL=C command awk -v d="$delim" -v want="$want" '
    !grab && match($0, "<<-?\047" d "\047") {
      n++
      if (n == want) { grab = 1; dash = (substr($0, RSTART + 2, 1) == "-") }
      next
    }
    grab {
      t = $0
      if (dash) sub(/^\t+/, "", t)
      if (t == d) exit
      print
    }
  ' "$file"
}

# payload::lang <opener-line> <first-body-line> -- bash | python | unknown.
# The shebang wins where there is one; otherwise the interpreter named on the
# opener line decides (`python3 - <<'PY'` has no shebang and never will).
payload::lang() {
  local opener=$1 first=$2
  case $first in
    '#!'*python*) printf 'python\n'; return 0 ;;
    '#!'*sh)      printf 'bash\n';   return 0 ;;
  esac
  case $opener in
    *python3*|*python\ *) printf 'python\n'; return 0 ;;
  esac
  printf 'unknown\n'
}

# payload::parses_bash / payload::parses_python <text> -- true if the extracted
# body is a valid program. Each prints the interpreter's own diagnosis for the
# caller to report.
#
# ⚠️ THESE ARE FUNCTIONS, AND THAT IS THE POINT. The bash one was a bare
# `bash -n` inlined twice -- once in the positive control, once in the loop over
# the real tree -- and mutation testing found the hole immediately: replacing
# the LOOP's copy with `true` left the control passing and every suite reported
# as parsing. A control that exercises a different code path from the thing it
# certifies certifies nothing. Every caller goes through here.
payload::parses_bash() {
  bash -n <<<"$1" 2>&1
}
payload::parses_python() {
  python3 -c 'import sys; compile(sys.stdin.read(), "<payload>", "exec")' <<<"$1" 2>&1
}

# ---------------------------------------------------------------------------
# SECTION A -- every in-guest probe is syntactically valid bash
# ---------------------------------------------------------------------------

printf '# --- A. guest payloads parse ---\n'

# The Python half of this section is worth nothing without an interpreter, and
# "python3 is missing" must not read as "no Python payload is broken".
command -v python3 >/dev/null ||
  { printf 'not ok - python3 is required to check Python guest payloads\n' >&2; exit 1; }

# Negative control: a valid heredoc must extract and parse.
cat >"$work/ctl-good.sh" <<'OUTER'
cat >"$probe_src" <<'PROBE'
#!/usr/bin/env bash
if [[ -f /etc/hostname ]]; then
  echo yes
fi
PROBE
echo "after the heredoc"
OUTER
ctl_good=$(payload::extract "$work/ctl-good.sh" PROBE 1)
if [[ -n $ctl_good ]] && payload::parses_bash "$ctl_good" >/dev/null 2>&1; then
  pass "control (negative): a valid bash payload extracts and parses"
else
  fail "control (negative): a valid bash payload extracts and parses" \
    "the extractor or the parse check is broken; every result below is meaningless"
fi

# The extractor must stop at the delimiter, not run on into the outer script.
if [[ $ctl_good != *"after the heredoc"* ]]; then
  pass "control: the extractor stops at the closing delimiter"
else
  fail "control: the extractor stops at the closing delimiter" \
    "it swallowed the line after PROBE, so it would 'parse' the outer script too"
fi

# Positive control: the exact defect found in vm-gamepad-spike-test.sh --
# a stale duplicated block leaving an unmatched `fi`. This MUST be caught.
cat >"$work/ctl-bad.sh" <<'OUTER'
cat >"$probe_src" <<'PROBE'
#!/usr/bin/env bash
if [[ -f /etc/hostname ]]; then
  echo yes
fi
  echo "stale tail"
fi
PROBE
OUTER
ctl_bad=$(payload::extract "$work/ctl-bad.sh" PROBE 1)
if [[ -n $ctl_bad ]] && ! payload::parses_bash "$ctl_bad" >/dev/null 2>&1; then
  pass "control (positive): an unmatched 'fi' inside a bash payload IS caught"
else
  fail "control (positive): an unmatched 'fi' inside a bash payload IS caught" \
    "the scanner cannot see the defect it exists for -- it would report the tree clean forever"
fi

# Python controls. `bash -n` is happy with almost any Python file, so a Python
# payload run through the bash checker is a check that cannot fail; these prove
# the Python path is a different, working code path and not decoration.
cat >"$work/ctl-py.sh" <<'OUTER'
python3 - <<'PY' 2>/dev/null
import sys
if sys.argv:
    print("ok")
PY
python3 - <<'PY'
def broken(:
    pass
PY
OUTER
ctl_py_good=$(payload::extract "$work/ctl-py.sh" PY 1)
ctl_py_bad=$(payload::extract "$work/ctl-py.sh" PY 2)
if [[ -n $ctl_py_good ]] && payload::parses_python "$ctl_py_good" >/dev/null 2>&1; then
  pass "control (negative): a valid Python payload extracts and compiles"
else
  fail "control (negative): a valid Python payload extracts and compiles" \
    "the Python path is broken, so every Python payload below is reported wrong"
fi
if [[ -n $ctl_py_bad ]] && ! payload::parses_python "$ctl_py_bad" >/dev/null 2>&1; then
  pass "control (positive): a Python syntax error in a payload IS caught"
else
  fail "control (positive): a Python syntax error in a payload IS caught" \
    "Python payloads are being waved through -- vm-spike-pad.py and friends would be unchecked"
fi
# ...and the two results above are only meaningful if each occurrence came back
# on its own. Asserted on the text, not on a parse: a concatenation of the two
# would ALSO fail to compile, so "the bad one is caught" cannot tell the
# difference between splitting correctly and never splitting at all.
if [[ $ctl_py_good == *'print("ok")'* && $ctl_py_good != *'def broken'* ]] &&
   [[ $ctl_py_bad == *'def broken'* && $ctl_py_bad != *'print("ok")'* ]]; then
  pass "control: same-delimiter payloads are extracted separately, by occurrence"
else
  fail "control: same-delimiter payloads are extracted separately, by occurrence" \
    "the two PY bodies bled into each other; multi-PY suites are being asked the wrong question"
fi

# ⚠️ THE ANTI-HARD-CODING CONTROL. A payload under a delimiter that appears
# NOWHERE in this repo must still be discovered and flagged. If someone
# reintroduces a spelled-in delimiter list, this is what goes red -- and it goes
# red before a real suite with a novel delimiter goes silently unchecked.
cat >"$work/ctl-novel.sh" <<'OUTER'
cat >"$guest_src" <<'GUESTPAYLOAD'
#!/usr/bin/env bash
while true; do
  echo hi
echo "no done"
GUESTPAYLOAD
OUTER
novel_delims=$(payload::openers "$work/ctl-novel.sh" | cut -d'|' -f2)
ctl_novel=$(payload::extract "$work/ctl-novel.sh" GUESTPAYLOAD 1)
if [[ $novel_delims == GUESTPAYLOAD ]] && [[ -n $ctl_novel ]] &&
   ! payload::parses_bash "$ctl_novel" >/dev/null 2>&1; then
  pass "control (positive): a broken payload under an UNKNOWN delimiter is discovered and caught"
else
  fail "control (positive): a broken payload under an UNKNOWN delimiter is discovered and caught" \
    "the delimiter set is being assumed rather than derived; a new suite could ship anything"
fi

# Now the real tree.
mapfile -t suites < <(find "$VM_DIR" -maxdepth 1 -name '*.sh' -type f | LC_ALL=C sort)
if (( ${#suites[@]} >= 8 )); then
  pass "found ${#suites[@]} VM suites to scan"
else
  fail "found ${#suites[@]} VM suites to scan" \
    "expected at least 8; a glob that matches nothing scans nothing and passes"
fi

# ⚠️ HARD STOP ON ZERO, and it is not belt-and-braces. Found by mutation
# testing this file: with the find pattern broken so `suites` is empty,
# `scan_unsafe_console_greps "${suites[@]}"` in section B calls awk WITH NO
# FILE ARGUMENTS, awk reads standard input, and the whole suite HANGS instead
# of failing. A test that hangs in CI is worse than one that fails -- it burns
# the timeout and reports nothing. Bail here, loudly, before that can happen.
if (( ${#suites[@]} == 0 )); then
  printf 'not ok - there are no VM suites to scan at all (%s)\n' "$VM_DIR" >&2
  printf 'aborting rather than hanging: the scanners below would read stdin\n' >&2
  exit 1
fi

# test/lib is in scope too: vm-installer-screens.sh is sourced INTO the probes,
# so its heredocs run in the guest exactly like the suites' own.
subjects=("${suites[@]}" "$REPO_ROOT"/test/lib/*.sh)

# ⚠️ A PAYLOAD THIS SCANNER CANNOT CLASSIFY IS A FAILURE, NOT A SKIP -- unless
# it is declared here, and every declaration is asserted to still match
# something real (the section-B deferral idiom, for the section-B reason). The
# alternative is an `else: continue` that silently absorbs the next language
# somebody ships to a guest.
#   entry: <basename>|<delimiter>|<why it is not a program>
not_a_program=(
  "vm-iso-probe-feasibility.sh|UD|cloud-init user-data: YAML data read by cloud-init, not an executable payload"
)

bash_payloads=0
python_payloads=0
unknown_payloads=()
for f in "${subjects[@]}"; do
  name=${f##*/}
  while IFS='|' read -r lineno delim nth opener; do
    [[ -n ${delim:-} ]] || continue
    body=$(payload::extract "$f" "$delim" "$nth")
    if [[ -z $body ]]; then
      fail "$name:$lineno: the <<'$delim' payload extracts to something" \
        "it was found by the opener scan and then extracted to nothing -- the two halves of this scanner disagree, and this payload is being checked by neither"
      continue
    fi
    lang=$(payload::lang "$opener" "${body%%$'\n'*}")
    case $lang in
      bash)
        bash_payloads=$((bash_payloads + 1))
        if err=$(payload::parses_bash "$body"); then
          pass "$name:$lineno: its <<'$delim' bash payload parses"
        else
          fail "$name:$lineno: its <<'$delim' bash payload parses" "$err"
        fi
        ;;
      python)
        python_payloads=$((python_payloads + 1))
        if err=$(payload::parses_python "$body"); then
          pass "$name:$lineno: its <<'$delim' Python payload compiles"
        else
          fail "$name:$lineno: its <<'$delim' Python payload compiles" "$err"
        fi
        ;;
      *)
        unknown_payloads+=("$name|$delim|$lineno")
        ;;
    esac
  done < <(payload::openers "$f")
done

# Every unclassified payload must be declared.
for u in ${unknown_payloads[@]+"${unknown_payloads[@]}"}; do
  uname=${u%%|*}; rest=${u#*|}; udelim=${rest%%|*}; uline=${rest#*|}
  declared=0
  for d in "${not_a_program[@]}"; do
    [[ ${d%%|*} == "$uname" && ${d#*|} == "$udelim|"* ]] && declared=1
  done
  if (( declared )); then
    pass "$uname:$uline: <<'$udelim' is declared not-a-program"
  else
    fail "$uname:$uline: <<'$udelim' is a guest payload this scanner cannot classify" \
      "add a language to payload::lang, or declare it in not_a_program with a reason -- an unrecognised payload must never look like a checked one"
  fi
done

# ...and every declaration must still correspond to a real unclassified payload,
# so the list cannot rot into a permanent allowlist.
for d in "${not_a_program[@]}"; do
  dfile=${d%%|*}; drest=${d#*|}; ddelim=${drest%%|*}
  if printf '%s\n' ${unknown_payloads[@]+"${unknown_payloads[@]}"} |
     LC_ALL=C command grep -qaF -- "$dfile|$ddelim|"; then
    pass "not_a_program entry still applies: $dfile <<'$ddelim'"
  else
    fail "not_a_program entry is STALE: $dfile <<'$ddelim'" \
      "that payload is gone or is now classified -- delete the entry, or the next unclassifiable payload in that file is silently excused"
  fi
done

# Non-vacuity. Counted per language, because one number can hide the other
# going to zero: this section's whole history is a scanner that checked eight
# bash probes and believed it had checked everything shipped to a guest.
if (( bash_payloads >= 8 )); then
  pass "$bash_payloads bash guest payloads were actually parsed"
else
  fail "$bash_payloads bash guest payloads were actually parsed" \
    "expected at least 8; if the extraction stops matching, this loop checks nothing and reports success"
fi
if (( python_payloads >= 8 )); then
  pass "$python_payloads Python guest payloads were actually compiled"
else
  fail "$python_payloads Python guest payloads were actually compiled" \
    "expected at least 8; the virtual pads, the fullscreen TUI and the kdmode probes are all Python, and none of them was checked by anything before 2026-08-12"
fi
if (( bash_payloads + python_payloads == 0 )); then
  printf 'not ok - zero guest payloads were checked; the extractor has gone stale\n' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# SECTION B -- greps over console captures are byte-safe
# ---------------------------------------------------------------------------
#
# ⚠️ SCOPE, DELIBERATELY NARROW. Only greps whose SUBJECT is a console byte
# stream are in scope: a `$OUT/screen.*` capture or /dev/vcsN itself. Greps
# over /proc/mounts, `modinfo`, `pacman -Q` or an ls listing are ASCII by
# construction and are none of this scanner's business -- widening it to every
# grep in the tree would make it noise, and a noisy scanner gets disabled.

printf '# --- B. console-capture greps are byte-safe ---\n'

# scan_unsafe_console_greps <file...> -- prints "file:line: text" for every
# grep over a console capture that is not both LC_ALL=C and -a.
scan_unsafe_console_greps() {
  LC_ALL=C command awk '
    # Comment lines are prose about greps, not greps.
    { line = $0; t = line; sub(/^[[:space:]]+/, "", t) }
    t ~ /^#/ { next }
    # In scope: the line runs a grep AND names a console byte stream.
    line !~ /grep/ { next }
    line !~ /\$OUT\/screen\.|\/dev\/vcs/ { next }
    {
      safe_locale = (line ~ /LC_ALL=C[[:space:]]+(command[[:space:]]+)?grep/)
      # -a may appear anywhere in the flag cluster: -a, -ac, -qaF, -an ...
      safe_binary = (line ~ /grep[[:space:]]+-[A-Za-z]*a/)
      if (!safe_locale || !safe_binary)
        printf "%s:%d: %s\n", FILENAME, FNR, t
    }
  ' "$@"
}

# Negative control: a hardened grep must NOT be flagged.
cat >"$work/ctl-safe-grep.sh" <<'EOF'
emit "osk.shown=$(LC_ALL=C command grep -ac 'shift' "$OUT/screen.2-osk-shown")"
emit "rows=$(LC_ALL=C command grep -an 'x' "$OUT/screen.now" | cut -d: -f1)"
LC_ALL=C command grep -qaF 'marker' "$OUT/screen.a"
emit "mounted=$(grep -c ' /run/deckprobe ' /proc/mounts)"
# a comment mentioning grep -c 'shift' "$OUT/screen.foo" must not be flagged
EOF
if [[ -z $(scan_unsafe_console_greps "$work/ctl-safe-grep.sh") ]]; then
  pass "control (negative): hardened console greps, and an ASCII-source grep, are not flagged"
else
  fail "control (negative): hardened console greps are not flagged" \
    "$(scan_unsafe_console_greps "$work/ctl-safe-grep.sh")"
fi

# Positive control: each of the three ways to be unsafe must be caught --
# no LC_ALL=C, no -a, and neither. This is the mutation that matters: if the
# scanner stops matching, the tree below goes green while unsafe.
cat >"$work/ctl-unsafe-grep.sh" <<'EOF'
emit "a=$(grep -c 'shift' "$OUT/screen.2-osk-shown")"
emit "b=$(LC_ALL=C command grep -c 'shift' "$OUT/screen.2-osk-shown")"
emit "c=$(command grep -ac 'shift' "$OUT/screen.2-osk-shown")"
snap() { grep -n 'x' /dev/vcs2; }
EOF
unsafe_hits=$(scan_unsafe_console_greps "$work/ctl-unsafe-grep.sh" | LC_ALL=C command grep -ac '' )
if [[ $unsafe_hits == 4 ]]; then
  pass "control (positive): all four unsafe console greps are caught (bare, no -a, no LC_ALL=C, /dev/vcs)"
else
  fail "control (positive): all four unsafe console greps are caught" \
    "flagged $unsafe_hits of 4 -- the scanner has a hole and would pass an unsafe tree"
fi

# ⚠️ A SELF-EXPIRING DEFERRAL, NOT AN EXEMPTION LIST.
#
# One hit is outside this audit's ownership. It is recorded here rather than
# fixed because another session owns that file, and it is recorded in a form
# that CANNOT quietly become permanent: each entry is asserted to STILL MATCH
# something. The moment the owner fixes the line, this file goes red demanding
# the entry be deleted. An exemption list that rots into a list of things
# nobody looks at is the same defect class this whole file is about.
#
# entry: <basename>:<line-substring that identifies the offending grep>
#
# ✅ The one deferred entry this list used to carry (`vm-installer-screens-test.sh`'s
# greeter-wait grep, found 2026-08-12) was fixed 2026-08-13 as part of migrating
# that file to drive the real Deck-forked ISO (docs/findings/T4-controller-only-install-first-run.md):
# the marker string itself changed (upstream's "Press Return to Start Install"
# never appears on that ISO) AND `LC_ALL=C` was added at the same time, so
# there is nothing left to defer. The array is empty on purpose -- see this
# block's own header: an exemption list that rots into a list of things
# nobody looks at is the same defect class this whole file is about.
deferred=()

deferred_still_needed=1
for d in "${deferred[@]}"; do
  dfile=${d%%:*}
  dneedle=${d#*:}
  if LC_ALL=C command grep -qaF -- "$dneedle" "$VM_DIR/$dfile" 2>/dev/null; then
    pass "deferral still applies: $dfile still carries the grep it names"
  else
    deferred_still_needed=0
    fail "deferral is STALE: $dfile no longer carries '$dneedle'" \
      "the owner fixed it -- delete this entry from the 'deferred' array above, or the next real hit in that file is silently ignored"
  fi
done

tree_hits=$(scan_unsafe_console_greps "${suites[@]}" "$REPO_ROOT"/test/lib/*.sh)
undeferred=$tree_hits
for d in "${deferred[@]}"; do
  undeferred=$(LC_ALL=C command grep -avF -- "${d#*:}" <<<"$undeferred")
done
undeferred=$(LC_ALL=C command grep -av '^$' <<<"$undeferred")

if [[ -z $undeferred ]]; then
  pass "no undeferred locale-unsafe console grep in test/vm or test/lib"
else
  fail "no undeferred locale-unsafe console grep in test/vm or test/lib" "$undeferred"
fi

# The subtraction above must not be able to hide everything: if the deferral
# list ever grew to swallow the scanner's whole output, this says so.
if (( deferred_still_needed == 1 )) && (( ${#deferred[@]} <= 3 )); then
  pass "the deferral list is short (${#deferred[@]} entries) and every entry is live"
else
  fail "the deferral list is short and every entry is live" \
    "${#deferred[@]} entries -- deferrals are for work another session owns this week, not a permanent allowlist"
fi

# And the scanner must have had subjects: if no file in the tree contains a
# console grep at all, "zero unsafe" above is vacuous.
console_grep_lines=$(LC_ALL=C command grep -ac 'screen\.\|/dev/vcs' "${suites[@]}" 2>/dev/null | \
  LC_ALL=C command awk -F: '{ n += $NF } END { print n + 0 }')
if (( console_grep_lines >= 20 )); then
  pass "the tree really does contain console-capture handling ($console_grep_lines lines)"
else
  fail "the tree really does contain console-capture handling ($console_grep_lines lines)" \
    "expected >= 20; with none, 'no unsafe greps' is true of an empty set"
fi

# ---------------------------------------------------------------------------
# SECTION C -- every VM suite propagates its verdict as an exit status
# ---------------------------------------------------------------------------
#
# A suite that logs "FAILED" and returns 0 is the §5.30c shape at the coarsest
# possible grain: a CI caller, deck-sync, or a human running `&& echo ok` sees
# success. Every suite currently ends with `exit $status` or an explicit exit
# in both branches; this keeps it that way.

printf '# --- C. suites propagate their verdict ---\n'

# suite_propagates <file> -- true if the last 25 lines contain an `exit`
# carrying a status (a variable or an explicit non-zero), not just `exit 0`.
suite_propagates() {
  local f=$1 tail_text
  tail_text=$(tail -n 25 "$f")
  LC_ALL=C command grep -qaE '^[[:space:]]*exit[[:space:]]+("?\$[A-Za-z_]|1)' <<<"$tail_text"
}

# shellcheck disable=SC2016 # the literal text 'exit $status' IS the fixture
printf 'exit $status\n' >"$work/ctl-exit-good.sh"
printf 'log "FAILED"\nfi\n' >"$work/ctl-exit-bad.sh"
if suite_propagates "$work/ctl-exit-good.sh"; then
  pass "control (negative): a suite ending in 'exit \$status' is accepted"
else
  fail "control (negative): a suite ending in 'exit \$status' is accepted" \
    "the matcher is broken, so every suite below would be reported as failing"
fi
if ! suite_propagates "$work/ctl-exit-bad.sh"; then
  pass "control (positive): a suite that ends without propagating IS caught"
else
  fail "control (positive): a suite that ends without propagating IS caught" \
    "the matcher accepts anything and this whole section is decoration"
fi

for suite in "${suites[@]}"; do
  name=${suite##*/}
  if suite_propagates "$suite"; then
    pass "$name: propagates its verdict as an exit status"
  else
    fail "$name: propagates its verdict as an exit status" \
      "it can log FAILED and still return 0 to whatever ran it"
  fi
done

# ---------------------------------------------------------------------------
# SECTION D -- the anti-vacuity facts are wired at BOTH ends
# ---------------------------------------------------------------------------
#
# A guard field is worth nothing if the guest emits it and the host never
# reads it, or if the host checks a key the guest never writes -- the second
# is worse, because `field` returns "" and the check fails for a reason that
# has nothing to do with the system under test.
#
# ⚠️ This is a deliberately SHORT, EXPLICIT table rather than a general rule
# derived from the source. A general rule would have to model every way a key
# can be built (the kernel suites compose them as "${tag}.name"), and a
# scanner that models something badly is worse than one that lists what it
# means. Each row is a guard added by the 2026-08-12 probe audit.

printf '# --- D. anti-vacuity guards are wired at both ends ---\n'

# rows: <suite> <emitted-key-fragment> <consumed-key>
wiring=(
  "vm-osk-tty-test.sh|unit.ran=1|field unit.ran"
  "vm-osk-tty-test.sh|canary.highbyte_rows=|field canary.highbyte_rows"
  "vm-osk-tty-test.sh|probe.done=1|field probe.done"
  "vm-gamepad-spike-test.sh|unit.ran=1|field unit.ran"
  "vm-gamepad-spike-test.sh|probe.done=1|field probe.done"
  "vm-kernel-hook-test.sh|.limine_conf_present=|field after_remove.limine_conf_present"
  "vm-kernel-hook-test.sh|.log_lines=|field reinstall1.log_lines"
  "vm-kernel-stage-test.sh|prereq.strip_control_core_survived=|field prereq.strip_control_core_survived"
  "vm-default-entry-test.sh|fail.strip_lines_after=|field fail.strip_lines_after"
  "vm-kernel-idempotency-test.sh|state_\${tag}_efi_lines=|state_\${tag}_efi_lines"
)

for row in "${wiring[@]}"; do
  IFS='|' read -r wf emitted consumed <<<"$row"
  path="$VM_DIR/$wf"
  if [[ ! -f $path ]]; then
    fail "$wf exists (wiring table)" "the table names a file that is not there"
    continue
  fi
  if LC_ALL=C command grep -qaF -- "$emitted" "$path"; then
    pass "$wf: emits '$emitted'"
  else
    fail "$wf: emits '$emitted'" \
      "the guard field was removed from the probe, so the host-side check now reads '' forever"
  fi
  if LC_ALL=C command grep -qaF -- "$consumed" "$path"; then
    pass "$wf: consumes '$consumed'"
  else
    fail "$wf: consumes '$consumed'" \
      "the guard is emitted into the report and nothing ever reads it -- a fact nobody checks is not a check"
  fi
done

# The table itself must not be empty, and must cover more than one suite.
covered=$(printf '%s\n' "${wiring[@]}" | cut -d'|' -f1 | LC_ALL=C sort -u | LC_ALL=C command grep -ac '')
if (( ${#wiring[@]} >= 8 && covered >= 4 )); then
  pass "the wiring table covers ${#wiring[@]} guards across $covered suites"
else
  fail "the wiring table covers ${#wiring[@]} guards across $covered suites" \
    "an emptied table makes this whole section pass without asserting anything"
fi

# ---------------------------------------------------------------------------

printf '\n%d checks run\n' "$checks"
if (( status == 0 )); then
  printf 'all vm probe-integrity tests passed\n'
else
  printf 'FAILURES above\n' >&2
fi
exit $status

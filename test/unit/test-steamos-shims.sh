#!/usr/bin/env bash
# Unit tests for the SteamOS compatibility shims -- the /usr/bin/steamos-* and
# /usr/bin/steamos-polkit-helpers/* surfaces Steam's Gaming Mode drives.
#
# No VM, no Docker, no network, no root, no Deck. Seconds.
#
# ---------------------------------------------------------------------------
# What this suite is for, and what it deliberately does NOT re-check
# ---------------------------------------------------------------------------
#
# The shims themselves already exist and are already covered:
#
#   test/unit/test-deck-session.sh        §1 the update stub's exit codes,
#                                         §4 the priv-write whitelist's
#                                            refusals (paths, '..', values)
#   test/unit/test-deck-session-stages.sh §8/§9 the stages that install them,
#                                            the sudoers grant's shape, the
#                                            verify_* seam
#
# Re-asserting any of that here would be a second copy of a fact, which is the
# failure mode this repo keeps paying for. This suite exists for the three
# questions those two do NOT ask, all of which came out of the hardware
# session of 2026-08-15:
#
#   §1  DOES THE WHITELIST COVER THE NODE THIS HARDWARE ACTUALLY HAS?
#       Every accept case in test-deck-session.sh names
#       /sys/class/backlight/amdgpu_bl0/brightness. On the Galileo test unit
#       that file DOES NOT EXIST -- `ls /sys/class/backlight/` returns exactly
#       one entry, `amdgpu_bl1` (read read-only over SSH, 2026-08-15), and
#       Steam's own console log asks for
#
#         steamos-priv-write failed /sys/class/backlight/amdgpu_bl1/brightness: 82520
#
#       So the entire accept path is currently proven against a node name that
#       is not on the only hardware this project has verified. §1 proves the
#       whitelist accepts the REAL one (and still accepts bl0, so a unit that
#       enumerates differently is not regressed).
#
#   §2  THE UPDATE STUB'S CONTRACT UNDER THE ARGUMENT FORMS STEAM REALLY USES.
#       test-deck-session.sh pins `check`, `--supports-duplicate-detection`
#       and the apply path. It does not pin the FLAG-FIRST forms
#       (`--enable-duplicate-detection check`), which is how a Steam client
#       that has accepted the duplicate-detection capability invokes it. The
#       stub reads only $1, so those land in its `*)` arm; that is correct
#       today and this section is what stops a future arg-parsing refactor
#       from changing the answer without anyone noticing.
#
#   §3  IS EVERY SHIM WE INSTALL ONE STEAM ACTUALLY CALLS, and is the set of
#       helpers Steam calls that we DON'T install still the set someone
#       decided on? Measured, not guessed -- the counts in OBSERVED_CALLS are
#       from the device's own logs.
#
#   §4  The sudoers grant parses. Cheap, and `visudo -c` is the only thing
#       that can answer it.
#
#   §5  find_backlight -- the DISCOVERY that replaced the hard-coded
#       DECK_BACKLIGHT constant. It is the reason §1's answer matters, it has
#       three distinct outcomes that must stay distinct, and nothing else in
#       test/ executes it.
#
# ---------------------------------------------------------------------------
# Provenance of every hardware fact asserted below
# ---------------------------------------------------------------------------
#
# All read from the physical Galileo (OLED) test unit on 2026-08-15, over a
# read-only SSH session, plus the journal capture under
# ~/.cache/omarchy-deck/p32-firstboot/ from the same day:
#
#   /sys/class/backlight/            -> amdgpu_bl1 (only entry; bl0 absent)
#   /sys/class/backlight/amdgpu_bl1/brightness  -> 192000, max 600000,
#                                                  mode 0644 root:root
#   DMI product_name / sys_vendor    -> Galileo / Valve
#   ~/.steam/steam/logs/console_log.txt, counted invocations by absolute path
#   ~/.steam/steam/logs/steamui_steamos.txt, the two non-polkit-helper calls
#
# The 0644-root:root mode matters: the desktop user cannot write that node
# directly, so EVERY brightness change has to go through the helper. There is
# no path where the slider works by accident.
#
# ---------------------------------------------------------------------------
# Corroboration from other SteamOS-alike distributions (research, 2026-08-15)
# ---------------------------------------------------------------------------
#
# deck-session.sh derived its exit codes from Steam's behaviour on this
# hardware. They agree with what the public shims do, which is worth recording
# because agreement was not guaranteed:
#
#   `check` -> 7 ("already up to date"): ChimeraOS/gamescope-session-steam
#   usr/bin/steamos-update ("exit 7 # tells Steam client there is no update to
#   perform"), KyleGospo/bazzite usr/bin/steamos-update, and HoloISO/postcopy
#   usr/bin/steamos-update (`echo "System up to date."; exit 7`). Valve's own
#   documented meaning for 7 is "already up to date".
#
#   `--supports-duplicate-detection` -> 1: we DIVERGE, deliberately and
#   harmlessly. ChimeraOS answers 0 when a real updater (frzr-deploy) is
#   present, HoloISO answers 7. Ours answers 1 = "capability not supported",
#   which keeps Steam on the code path it used while the file was missing
#   altogether. All three answers leave Steam with nothing to download.
#
#   ChimeraOS's header enumerates the five argument forms Steam is known to
#   use; §2 below is built from that list, cross-checked against this
#   device's logs.
#
# Sources:
#   https://github.com/ChimeraOS/gamescope-session-steam  usr/bin/steamos-update
#   https://github.com/KyleGospo/bazzite                  usr/bin/steamos-update
#   https://github.com/HoloISO/postcopy                   usr/bin/steamos-update

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

# Sourcing, not running: deck-session.sh guards `main "$@"` on being executed
# directly, so this defines its functions and installs nothing. Exactly once
# and at top level -- every constant in there is `readonly`, so a second source
# in the same shell throws, and its own `set -e` turns that into an abort.
# shellcheck source=../../src/deck-session.sh
source "$REPO_ROOT/src/deck-session.sh"

# deck-session.sh exports its own `fail` (print + exit 1) and its functions
# call it; shadowing that would rewrite the behaviour under test. Same
# deviation test/unit/test-deck-session.sh makes, for the same reason.
pass()      { printf 'ok - %s\n' "$1"; }
fail_test() { printf 'not ok - %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2; exit 1; }

ASSERTIONS=0
count() { ASSERTIONS=$((ASSERTIONS + 1)); pass "$1"; }

# Hard gate, not a courtesy. The helpers elevate through `$SUDO`/`sudo`, and
# deck-session.sh leaves SUDO empty until stage_preconditions sets it. If that
# ever changes, this suite would start invoking real sudo and could block on a
# password prompt in CI. Refuse to run rather than find out that way.
[[ -z ${SUDO:-} ]] ||
  fail_test "SUDO is '${SUDO}' after sourcing deck-session.sh; this suite must never invoke sudo"

# Every expectation below is DERIVED from the file under test, never retyped.
# A derivation that came back empty and was then compared against an empty
# expectation is the "found nothing == found no problems" bug this project has
# paid for repeatedly (docs/PROGRESS.md §5.30c), so each one is gated.
for _c in POLKIT_HELPER_DIR UPDATE_STUB PRIV_WRITE_HELPER TIMEZONE_HELPER \
  PRIV_WRITE_SUDOERS BACKLIGHT_GLOB BACKLIGHT_CLASS_DIR; do
  [[ -n ${!_c:-} ]] ||
    fail_test "deck-session.sh still defines ${_c}" \
      "This suite derives its expectations from that constant. A renamed or deleted one must stop the suite, not silently empty every assertion below it."
done
unset _c
for _f in render_update_stub render_priv_write_helper find_backlight; do
  declare -F "$_f" >/dev/null ||
    fail_test "deck-session.sh still defines ${_f}()" \
      "The shims are generated by that function; this suite renders and executes its real output. A rename must be loud."
done
unset _f

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- the fake elevation/journal seam ---------------------------------------
#
# Both shims shell out to `sudo` and `logger`. Stubbing them on PATH means the
# accept path can be exercised without root and without touching any real
# system node -- and it makes "did this reach elevation with its arguments
# intact?" and "did the refusal reach the journal?" answerable, which they are
# not from an exit code alone.
fake_bin="$work/bin"
mkdir -p "$fake_bin"
SUDO_CAPTURE="$work/sudo.log"
LOGGER_CAPTURE="$work/logger.log"
: >"$SUDO_CAPTURE"
: >"$LOGGER_CAPTURE"

cat >"$fake_bin/sudo" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$SUDO_CAPTURE"
exit 0
EOF
cat >"$fake_bin/logger" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$LOGGER_CAPTURE"
exit 0
EOF
chmod +x "$fake_bin/sudo" "$fake_bin/logger"

# ===========================================================================
# 1. 🔴 THE BACKLIGHT NODE THIS HARDWARE ACTUALLY HAS
# ===========================================================================
#
# The single highest-value question in this file. Steam calls
# steamos-priv-write 1051 times in one Gaming Mode session on this device
# (counted in console_log.txt) and essentially all of them are the brightness
# slider. If the whitelist did not match the real node name, the slider would
# be dead and every existing test would still be green, because every existing
# accept case names amdgpu_bl0 -- a node that is not present on this unit.
#
# The whitelist is a regex over the device component:
#
#   ^/sys/class/backlight/[A-Za-z0-9_.:+-]+/brightness$
#
# so it is device-name agnostic and DOES cover bl1. That is the answer, and it
# is worth an assertion rather than a reading, because a future "tighten the
# whitelist to the node we measured" change is exactly the plausible edit that
# would break the slider on the hardware it was measured on.

pw_helper="$work/steamos-priv-write"
render_priv_write_helper >"$pw_helper"
chmod +x "$pw_helper"

bash -n "$pw_helper" 2>"$work/stderr" ||
  fail_test "render_priv_write_helper emits valid bash" "$(cat "$work/stderr")"

pw_rc=0
run_pw() {
  pw_rc=0
  : >"$SUDO_CAPTURE"
  PATH="$fake_bin:$PATH" "$pw_helper" "$@" >"$work/stdout" 2>"$work/stderr" || pw_rc=$?
}

# The exact call Steam makes on this unit, path and value both read from its
# own log rather than invented.
run_pw /sys/class/backlight/amdgpu_bl1/brightness 82520
[[ $pw_rc -eq 0 ]] ||
  fail_test "the whitelist accepts the backlight node THIS Deck has (amdgpu_bl1)" \
    "got exit ${pw_rc}; stderr: $(cat "$work/stderr")
/sys/class/backlight/ on the Galileo test unit contains exactly one entry, amdgpu_bl1, and Steam asks for it 1051 times per session. A whitelist that refuses it is a dead brightness slider -- and every other suite would stay green, because they all test amdgpu_bl0, which does not exist here."
grep -qF -- '/sys/class/backlight/amdgpu_bl1/brightness 82520' "$SUDO_CAPTURE" ||
  fail_test "the accepted bl1 write reaches elevation with its arguments intact" \
    "sudo got: $(cat "$SUDO_CAPTURE")"
grep -qw -- '-n' "$SUDO_CAPTURE" ||
  fail_test "the helper elevates with 'sudo -n'" \
    "Steam calls this on every slider movement; without -n a refused grant BLOCKS on a prompt Steam cannot render. sudo got: $(cat "$SUDO_CAPTURE")"
count "the measured call (/sys/class/backlight/amdgpu_bl1/brightness 82520) is accepted and reaches 'sudo -n' intact"

# ...and bl0 still works. The whitelist must stay device-name agnostic: this
# project has verified exactly one unit, and a different kernel or a second
# panel can renumber the node. Pinning it to the name we happened to measure
# would trade a bug we can see for one we cannot.
run_pw /sys/class/backlight/amdgpu_bl0/brightness 39638
[[ $pw_rc -eq 0 ]] ||
  fail_test "the whitelist is still device-name agnostic (amdgpu_bl0 also accepted)" \
    "got exit ${pw_rc}. The backlight node is renumbered by the kernel; hard-coding the one name measured on one unit is how the slider dies on the next one."
count "the whitelist accepts bl0 as well as bl1 -- device-name agnostic, so a renumbered node does not kill the slider"

# The negative control for both of the above. Without it, a helper that
# accepted everything under /sys/class/backlight/ would pass them.
run_pw /sys/class/backlight/amdgpu_bl1/bl_power 0
[[ $pw_rc -eq 3 ]] ||
  fail_test "a non-brightness attribute of the SAME device is still refused" \
    "got exit ${pw_rc} for /sys/class/backlight/amdgpu_bl1/bl_power. The whitelist is per-attribute, not per-device; if this passes, §1's accept cases prove nothing."
count "the same device's bl_power is refused (exit 3) -- the accepts above are not a blanket /sys/class/backlight grant"

# ===========================================================================
# 2. The update stub under the argument forms Steam really uses
# ===========================================================================
#
# The five forms below are the ones a Steam client is known to invoke, taken
# from the header of ChimeraOS/gamescope-session-steam's own steamos-update
# and cross-checked against this device's logs (14 invocations of
# /usr/bin/steamos-polkit-helpers/steamos-update in one session).
#
# The three plain forms are already pinned by test/unit/test-deck-session.sh
# §1 and are NOT repeated. What is new here is the FLAG-FIRST pair. The stub
# switches on $1 only, so `--enable-duplicate-detection check` does not reach
# the `check` arm at all -- it falls to `*)`, which also answers 7. The answer
# is right; the reason is an accident of argument order. This section is what
# turns that accident into a pinned fact, so an arg-parsing refactor cannot
# silently change it to 0 -- and 0 on an apply path is the measured reboot
# loop recorded in render_update_stub's own comments.

update_stub="$work/steamos-update"
render_update_stub >"$update_stub"
chmod +x "$update_stub"

bash -n "$update_stub" 2>"$work/stderr" ||
  fail_test "render_update_stub emits valid bash" "$(cat "$work/stderr")"

run_update() {
  upd_rc=0
  : >"$LOGGER_CAPTURE"
  PATH="$fake_bin:$PATH" "$update_stub" "$@" >"$work/stdout" 2>"$work/stderr" || upd_rc=$?
}

for form in "--enable-duplicate-detection check" "--enable-duplicate-detection"; do
  # shellcheck disable=SC2086 # the whole point is to pass these as separate words
  run_update $form
  [[ $upd_rc -eq 7 ]] ||
    fail_test "the flag-first form '${form}' answers 7 (no update)" \
      "got ${upd_rc}. 7 is 'already up to date'. Any other answer restarts the failure this stub exists to end -- and 0 specifically means 'an update was applied', which makes Steam reboot the Deck (measured; see render_update_stub)."
  [[ -s $LOGGER_CAPTURE ]] ||
    fail_test "an unrecognised verb reaches the journal" \
      "Steam discards this stub's stderr, so 'logger' is the only place a human learns that a Steam client started using an argument form nobody has decided about. Silence here is the exact failure mode this project exists to stop."
done
count "both flag-first forms Steam uses answer 7 AND say so in the journal -- the stub reads only \$1, so this is pinned rather than assumed"

# The one answer that must never be 0, asserted against the whole argument
# space this suite knows about at once. Belt and braces over §2's cases and
# test-deck-session.sh §1's: 0 is the only genuinely dangerous answer, because
# Steam reads it as "an update was applied" and reboots to finish it.
for form in "" "check" "apply" "--enable-duplicate-detection" \
  "--enable-duplicate-detection check" "--supports-duplicate-detection" \
  "some-verb-from-a-future-client"; do
  # shellcheck disable=SC2086
  run_update $form
  [[ $upd_rc -ne 0 ]] ||
    fail_test "no argument form makes the stub exit 0" \
      "form '${form}' exited 0. Measured on hardware: Steam reads 0 from this helper as 'OS update applied' and reboots to finish it, on every OOBE pass -- a boot loop caused by the stub meant to quiet a cosmetic error."
done
count "none of the 7 known argument forms exits 0 -- the one answer that reboots the Deck"

# ...and the control: --help MUST exit 0, so the loop above is not passing
# because the stub simply never exits 0 for anything.
run_update --help
[[ $upd_rc -eq 0 ]] ||
  fail_test "--help exits 0" \
    "got ${upd_rc}. Without this, the 'never exits 0' loop above would pass on a stub that was broken in every arm."
[[ -s $work/stdout ]] ||
  fail_test "--help actually prints usage" "stdout was empty"
count "--help exits 0 and prints usage -- the control proving the 'never 0' loop above is looking at something"

# ===========================================================================
# 3. Every shim we install is one Steam actually calls, and the gap is a
#    decision rather than an oversight
# ===========================================================================
#
# 🔴 Counted from the device's own logs on 2026-08-15, not reasoned about:
#
#   console_log.txt, invocations by absolute path under /usr/bin/steamos-polkit-helpers/
#     1051  steamos-priv-write
#       26  steamos-set-timezone
#       14  steamos-update
#        4  jupiter-get-als-gain
#        2  steamos-devkit-mode
#        2  jupiter-fan-control
#
#   steamui_steamos.txt
#        2  jupiter-initial-firmware-update check   -> returned: 127
#        2  steamos-mandatory-update check          -> "failed to run"
#
#   journal (p32-firstboot capture), absolute-path ENOENT
#           /usr/bin/steamos-polkit-helpers/jupiter-biosupdate
#           /usr/bin/steamos-polkit-helpers/jupiter-dock-updater
#
#   journal, bare name resolved through Steam's PATH
#        7  steamos-select-branch: command not found
#
# steamos-session-select is NOT in this table on purpose: it is the session
# switch, it is installed by a different stage, and it resolves through PATH
# rather than by absolute path (deck-session.sh's header documents that the two
# families resolve differently). It belongs to the session-switching work, not
# to the shim surface this suite covers.
OBSERVED_CALLS=(
  steamos-priv-write
  steamos-set-timezone
  steamos-update
  jupiter-get-als-gain
  steamos-devkit-mode
  jupiter-fan-control
  jupiter-initial-firmware-update
  steamos-mandatory-update
  jupiter-biosupdate
  jupiter-dock-updater
  steamos-select-branch
)

# What deck-session.sh installs, DERIVED: every constant whose value is a file
# directly inside POLKIT_HELPER_DIR. Not a retyped list -- a fourth helper
# constant added tomorrow is picked up here automatically, which is the only
# way this section can outlive the commit that wrote it.
installed_helpers=()
while IFS= read -r _name; do
  _val=${!_name:-}
  [[ $_val == "$POLKIT_HELPER_DIR"/* ]] || continue
  [[ $_val != "$POLKIT_HELPER_DIR"/*/* ]] || continue
  installed_helpers+=("${_val##*/}")
done < <(compgen -v)
unset _name _val
IFS=$'\n' read -r -d '' -a installed_helpers < \
  <(printf '%s\n' "${installed_helpers[@]}" | sort -u && printf '\0')

[[ ${#installed_helpers[@]} -ge 3 ]] ||
  fail_test "the derivation of 'what deck-session.sh installs' found something" \
    "found ${#installed_helpers[@]} helper constant(s) under ${POLKIT_HELPER_DIR}. The scrape failed, so every assertion in this section would have compared an empty set against an empty set and passed."

# No dead shims. A helper we install that Steam never calls is either a wrong
# path (the exact bug that cost this project P1.5 -- a shim in /usr/local/bin
# that worked by hand and was invisible to Steam) or a helper nobody needs.
for h in "${installed_helpers[@]}"; do
  printf '%s\n' "${OBSERVED_CALLS[@]}" | grep -qx -- "$h" ||
    fail_test "deck-session.sh installs '${h}', which Steam was never observed calling" \
      "Either the path is wrong -- which is invisible from a shell, and is precisely how ${STEAM_SHIM_LEGACY} sat in /usr/local/bin working by hand and unreachable by Steam -- or the shim is unnecessary. Re-measure against Steam's logs before adding to OBSERVED_CALLS."
done
count "all ${#installed_helpers[@]} helpers deck-session.sh installs (${installed_helpers[*]}) are ones Steam was measured calling"

# The other direction: the helpers Steam calls that we do NOT install. This is
# a real product gap, and it is recorded here so that it stays a DECISION.
# Adding a shim, or a future Steam client calling something new, turns this
# line red and forces someone to look -- which is the whole point.
#
# Why each is unhandled today:
#   jupiter-get-als-gain            ambient-light sensor gain. Deliberate:
#                                   deck-session.sh's header names ALS as a
#                                   jupiter-hw-support decision (PROGRESS.md
#                                   §5.15).
#   jupiter-fan-control             deliberate: lands in P2.3, which requires
#                                   per-item operator approval.
#   jupiter-biosupdate              deliberate: firmware. Never no-op'd
#   jupiter-dock-updater            silently by this project without a
#                                   decision recorded first.
#   steamos-devkit-mode             enables the devkit/SSH service. A shim
#                                   would be a remote-access surface; not
#                                   something to add in passing.
#   jupiter-initial-firmware-update UNDECIDED -- see this suite's report.
#   steamos-mandatory-update        UNDECIDED -- see this suite's report.
#   steamos-select-branch           UNDECIDED -- costs 7 'command not found'
#                                   lines per session and nothing else so far.
EXPECTED_UNHANDLED=(
  jupiter-biosupdate
  jupiter-dock-updater
  jupiter-fan-control
  jupiter-get-als-gain
  jupiter-initial-firmware-update
  steamos-devkit-mode
  steamos-mandatory-update
  steamos-select-branch
)
actual_unhandled=()
for c in "${OBSERVED_CALLS[@]}"; do
  printf '%s\n' "${installed_helpers[@]}" | grep -qx -- "$c" && continue
  actual_unhandled+=("$c")
done
expected_sorted=$(printf '%s\n' "${EXPECTED_UNHANDLED[@]}" | sort)
actual_sorted=$(printf '%s\n' "${actual_unhandled[@]}" | sort)
[[ $actual_sorted == "$expected_sorted" ]] ||
  fail_test "the set of Steam-called helpers we do NOT install has changed" \
    "now unhandled:
${actual_sorted}
recorded as decided:
${expected_sorted}

If a shim was added, drop its name from EXPECTED_UNHANDLED. If Steam started calling something new, decide what it should do BEFORE shimming it -- a helper with guessed semantics is worse than a missing one, because a missing one is loud."
count "the ${#EXPECTED_UNHANDLED[@]} Steam-called helpers we deliberately do not shim are exactly the ones recorded as decided"

# ===========================================================================
# 4. The sudoers grant parses
# ===========================================================================
#
# The grant's SHAPE (scoped, passwordless) is already asserted by
# test/unit/test-deck-session-stages.sh §9 against the release check's own
# predicates, and is not repeated. What is not asserted anywhere is that the
# file `visudo` would be handed actually parses. A malformed sudoers drop-in
# breaks sudo for every user on the machine, and on a device with no terminal
# that is unrecoverable without re-imaging.
grant_file="$work/99-deck-priv-write"
printf '%s\n' "deck ALL=(root) NOPASSWD: ${PRIV_WRITE_HELPER}" >"$grant_file"
if command -v visudo >/dev/null 2>&1; then
  visudo -c -f "$grant_file" >/dev/null 2>&1 ||
    fail_test "the priv-write grant parses under visudo" \
      "$(visudo -c -f "$grant_file" 2>&1). A malformed drop-in breaks sudo for everyone; on a device with no terminal that is not recoverable."
  # The control: visudo must be able to REJECT something, or the check above
  # passes on a visudo that is not actually reading the file.
  printf '%s\n' 'deck ALL=(root NOPASSWD' >"$work/broken-sudoers"
  if visudo -c -f "$work/broken-sudoers" >/dev/null 2>&1; then
    fail_test "the visudo control failed: it accepted a syntactically broken file" \
      "so the check above proves nothing about the real grant"
  fi
  count "the priv-write grant naming ${PRIV_WRITE_HELPER} parses under visudo, and visudo demonstrably rejects a broken file"
else
  printf 'skip - visudo not on PATH locally; the grant syntax was not checked\n'
fi


# ===========================================================================
# 5. find_backlight -- the discovery that replaced a constant that was wrong
#    on the operator's own Deck
# ===========================================================================
#
# BACKGROUND, because this function is young and the reason for it is the whole
# point of this suite. stage_priv_write_helper proves its work by RUNNING the
# helper it just installed against a real backlight node -- the strongest check
# in that file. It used to pick that node from a hard-coded constant,
# /sys/class/backlight/amdgpu_bl0/brightness. On the Galileo test unit running
# stock linux 7.1.8-arch1-3 that file does not exist; the panel enumerates as
# amdgpu_bl1. So verify_priv_write_helper took its "not present" arm, WARNED,
# and the stage reported ok having never exercised the write path at all.
#
# That is not a hypothesis. From the device's own journal, the run that
# installed the helpers now live on it:
#
#   13:33:20 steamos-priv-write[8783]: refusing a path that is not whitelisted: '/etc/shadow'
#   13:33:20 steamos-priv-write[8785]: refusing a non-numeric value 'not-a-number' for
#                                      '/sys/class/backlight/amdgpu_bl0/brightness'
#
# Two refusal checks logged and NO accept line, because the accept check was
# skipped. Note the second one proves nothing about the node either: the value
# guard rejects 'not-a-number' before the path is ever touched, so it logs
# identically for a node that does not exist. A stage whose passing state is
# indistinguishable from its not-having-run state is exactly
# docs/PROGRESS.md §5.30c's defect, and that was a live instance of it.
#
# The three outcomes below are three because they are three different facts
# about the machine. Collapsing any two of them re-creates the bug.
#
# Every case runs against a temp-dir fake, with the PATTERN derived from the
# real BACKLIGHT_GLOB rather than retyped -- so these exercise the shipped
# `amdgpu_bl*` component, not a pattern this suite invented.

BL_TAIL=${BACKLIGHT_GLOB#"$BACKLIGHT_CLASS_DIR"/}
[[ -n $BL_TAIL && $BL_TAIL != "$BACKLIGHT_GLOB" ]] ||
  fail_test "BACKLIGHT_GLOB is still rooted at BACKLIGHT_CLASS_DIR" \
    "glob '${BACKLIGHT_GLOB}' does not start with '${BACKLIGHT_CLASS_DIR}/', so this section's derivation failed and every case below would be testing a pattern it made up."

# The shipped glob must stay narrower than '*'. A '*' would happily select an
# intel_backlight or a DDC-backed external monitor on a docked Deck, and the
# stage would then verify the helper against a node Steam never drives.
[[ $BL_TAIL == *'*'* ]] ||
  fail_test "BACKLIGHT_GLOB is a glob, not a literal node" \
    "got '${BACKLIGHT_GLOB}'. A literal is the constant this function replaced; the index is DRM enumeration order and moved between kernels on one physical Deck."
[[ ${BL_TAIL%%/*} != '*' ]] ||
  fail_test "BACKLIGHT_GLOB's device component is not a bare '*'" \
    "got '${BACKLIGHT_GLOB}'. A bare '*' matches intel_backlight and DDC-backed external panels; discovery would then pick a node Steam never drives, and the write check would pass against the wrong device."
count "BACKLIGHT_GLOB is rooted at BACKLIGHT_CLASS_DIR, is a glob (not a re-hardcoded node), and is narrower than a bare '*'"

bl_root="$work/backlight"
bl_pattern() { printf '%s/%s' "$1" "$BL_TAIL"; }

fb_out=""; fb_err=""; fb_rc=0
run_fb() {   # run_fb <class-dir>
  fb_rc=0
  fb_out=$(find_backlight "$(bl_pattern "$1")" "$1" 2>"$work/fb.err") || fb_rc=$?
  fb_err=$(cat "$work/fb.err")
}

# --- outcome 0: the node this Deck actually has ---------------------------
rm -rf "$bl_root"; mkdir -p "$bl_root/amdgpu_bl1"; : >"$bl_root/amdgpu_bl1/brightness"
run_fb "$bl_root"
[[ $fb_rc -eq 0 ]] ||
  fail_test "find_backlight finds amdgpu_bl1 -- the node on the verified hardware" \
    "exit ${fb_rc}; stderr: ${fb_err}
/sys/class/backlight/ on the Galileo test unit holds exactly one entry, amdgpu_bl1. If discovery cannot find it, the stage is back to warning-and-passing with the write path unexercised."
[[ $fb_out == "$bl_root/amdgpu_bl1/brightness" ]] ||
  fail_test "find_backlight prints ONLY the node path on stdout" \
    "got: '${fb_out}'
Its caller captures stdout with \$(...). Any informational line printed there is read back as part of the path, and the stage then verifies against a filename with a log message in it."
count "find_backlight discovers amdgpu_bl1 (the node this Deck has) and prints nothing but the path"

# ...and bl0 too. The Neptune kernel enumerated the same panel as bl0; a
# discovery that only found the name measured most recently would be the same
# hard-coding bug wearing a function.
rm -rf "$bl_root"; mkdir -p "$bl_root/amdgpu_bl0"; : >"$bl_root/amdgpu_bl0/brightness"
run_fb "$bl_root"
[[ $fb_rc -eq 0 && $fb_out == "$bl_root/amdgpu_bl0/brightness" ]] ||
  fail_test "find_backlight still finds amdgpu_bl0 (the Neptune-kernel name)" \
    "exit ${fb_rc}, got '${fb_out}'. Both names are the same physical panel under different kernels; the discovery has to cover both or it has simply moved the constant."
count "find_backlight finds amdgpu_bl0 as well -- both kernels' names for the same panel"

# --- ambiguity: deterministic, and said out loud --------------------------
rm -rf "$bl_root"
for d in amdgpu_bl0 amdgpu_bl10 amdgpu_bl2; do
  mkdir -p "$bl_root/$d"; : >"$bl_root/$d/brightness"
done
run_fb "$bl_root"
[[ $fb_rc -eq 0 ]] ||
  fail_test "several candidates is not an error" "exit ${fb_rc}; stderr: ${fb_err}"
[[ $fb_out == "$bl_root/amdgpu_bl0/brightness" ]] ||
  fail_test "several candidates resolve deterministically by version sort" \
    "got '${fb_out}'. Version order puts bl0 before bl2 before bl10; byte order would put bl10 second. Deterministic beats plausible -- a check that picks a different node on different runs cannot be trusted either way."
for expect in amdgpu_bl0 amdgpu_bl2 amdgpu_bl10; do
  grep -qF -- "$expect" <<<"$fb_err" ||
    fail_test "the ambiguity warning names every candidate" \
      "'${expect}' missing from: ${fb_err}
A silent choice between panels is a choice nobody can audit."
done
count "three candidates resolve to bl0 by version sort (not byte order), and all three are named on stderr"

# --- outcome 2: backlights exist, none of them ours -----------------------
#
# The case that must NOT be collapsed into "no backlight". On a Deck this means
# the panel moved to a name this file does not know -- a real finding, and the
# caller fails on it. Collapsing it into outcome 1 turns a moved panel into a
# shrug.
rm -rf "$bl_root"; mkdir -p "$bl_root/intel_backlight"; : >"$bl_root/intel_backlight/brightness"
run_fb "$bl_root"
[[ $fb_rc -eq 2 ]] ||
  fail_test "a non-amdgpu backlight is outcome 2, not outcome 1" \
    "exit ${fb_rc}. 'there is a backlight and it is not one we know' is a different fact from 'there is no backlight', and the caller treats them differently: 2 fails the stage, 1 only warns. One exit code for both is how a moved panel becomes a shrug."
grep -qF -- 'intel_backlight' <<<"$fb_err" ||
  fail_test "outcome 2 names what it DID find" \
    "stderr: ${fb_err}. Without the name, the operator cannot add it to BACKLIGHT_GLOB."
count "a backlight that is not an amdgpu one is exit 2 (fails the stage), and the message names it"

# --- outcome 1: no backlight at all ---------------------------------------
rm -rf "$bl_root"; mkdir -p "$bl_root"
run_fb "$bl_root"
[[ $fb_rc -eq 1 ]] ||
  fail_test "an empty backlight class dir is outcome 1" \
    "exit ${fb_rc}. Ordinary on a dev box and in QEMU, where the caller warns and skips the write check."
[[ -n $fb_err ]] ||
  fail_test "outcome 1 is not silent" "an unexercised write check has to be visible, not merely survivable"

# ...and an ABSENT class dir, not merely an empty one. This is the QEMU/CI
# shape, and a `for p in "$class_dir"/*` that matched its own unexpanded
# pattern would report a phantom backlight named '*'.
rm -rf "$bl_root"
run_fb "$bl_root"
[[ $fb_rc -eq 1 ]] ||
  fail_test "an ABSENT backlight class dir is also outcome 1" \
    "exit ${fb_rc} for a directory that does not exist. If this is 2, every dev box and every QEMU run fails the stage with 'the panel moved'."
count "both an empty and an absent ${BACKLIGHT_CLASS_DIR} are outcome 1 (warn, skip) -- and neither is silent"

# --- the end-to-end tie-back ----------------------------------------------
#
# The two halves have to agree: whatever discovery returns must be something
# the whitelist accepts. They are written independently -- a glob in one file,
# a regex in a generated helper -- so this is the seam where they could drift
# apart while both looked right on their own.
rm -rf "$bl_root"; mkdir -p "$bl_root/amdgpu_bl1"; : >"$bl_root/amdgpu_bl1/brightness"
run_fb "$bl_root"
[[ $fb_rc -eq 0 ]] || fail_test "the tie-back case discovered a node" "exit ${fb_rc}"
# Re-root the discovered path under the real class dir: the fake lives in a
# temp dir, and it is the NODE NAME that has to survive the whitelist.
discovered_real="${BACKLIGHT_CLASS_DIR}/${fb_out#"$bl_root"/}"
run_pw "$discovered_real" 192000
[[ $pw_rc -eq 0 ]] ||
  fail_test "the whitelist accepts what find_backlight discovers" \
    "'${discovered_real}' was refused with exit ${pw_rc}; stderr: $(cat "$work/stderr")
Discovery and the whitelist are written in two places -- a glob and a regex -- and this is the only assertion that they agree. If they drift, the stage verifies a node the shipped helper will refuse, or refuses a node it verified."
count "the node find_backlight discovers is one the priv-write whitelist accepts -- the glob and the regex agree"

printf '\n%d assertion group(s) passed.\n' "$ASSERTIONS"

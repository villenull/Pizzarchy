#!/usr/bin/env bash
# vm-osk-tty-test.sh -- T8 step 4's untested half, answered in a VM:
# can the on-screen keyboard we draw and an installer TUI share one console?
#
# Usage: ./vm-osk-tty-test.sh [substrate.raw]
#
# Env vars (all optional):
#   VM_RUN_TIMEOUT_SEC           whole-run ceiling, default 1800
#   VM_MEM_MB / VM_SMP           guest size, defaults 4096 / 4
#   VM_OVMF_CODE / VM_OVMF_VARS  override firmware probing
#
# ===========================================================================
# THE EXPERIMENT
# ===========================================================================
#
# The installer has no compositor, so T8 draws its keyboard straight onto the
# console with escape sequences -- into the same 25 rows `gum` and
# `archinstall` are drawing on. `deck_osk_tty.write_at` documents the intended
# way to keep them apart: shrink the TUI's REPORTED window with TIOCSWINSZ so
# it never lays out below a chosen row, and draw the keyboard underneath.
#
# That mechanism was designed and never tested. This tests it:
#
#   virtual Deck pad (uinput) --> deck-input-mapper --osk-backend=tty
#        ^ scripted trackpad         |            |
#          and trigger presses       |            +--> draws rows 19-23 of
#                                    |                 /dev/tty2
#                                    +--> uinput keyboard --> active VT --> gum
#                                                             (told it has 18
#                                                              rows, so it
#                                                              stays above)
#
# ⚠️ OBSERVED THROUGH /dev/vcs2, WHICH IS THE KERNEL'S OWN COPY OF THE SCREEN.
# No tmux, no terminal emulator, no escape-sequence reconstruction. The T2
# spike used `tmux capture-pane`, which cannot answer this question: tmux would
# own the screen and redraw over anything the mapper painted, which is exactly
# the collision under test. A session-18 prototype tried reconstructing the
# screen from a pty's byte stream and mis-read a correct render twice.
#
# WHAT THIS PROVES AND DOES NOT PROVE
#   Proves: the keyboard and a real TUI coexist on one console; the keyboard
#   types into that TUI through the kernel input layer; and gum RECEIVES the
#   characters (asserted from what gum wrote to a file, not from pixels).
#   Does not prove: the Deck's own panel geometry or rotation, or archinstall's
#   full flow.
#
# ===========================================================================
# THE SECOND EXPERIMENT -- R-52, the fork R-49 left open
# ===========================================================================
#
# R-49 ended with the console no longer being shrunk, which left nothing
# confining a TUI to the top of it. `gum` does not need confining: it is
# line-oriented, uses three rows, and never reaches the bottom. A full-screen
# curses application -- archinstall's menu -- is a different question, and
# section 5 answers it with a real curses TUI on its own VT.
#
# ⚠️ IT ASSERTS BY COUNTING ROWS, NOT BY GREPPING FOR A WORD, and that is the
# entire lesson of R-49. Five keyboard rows clamped onto one line still
# contained `shift`, so every substring check passed on a keyboard that was
# unusable. This suite's own `osk.shown` check is one of those, and it is kept
# only because section 3 has other evidence. Section 5 uses
# `deck_osk_tty.rows_on_screen`, which asks how many console lines carry a
# WHOLE keyboard row -- the same function the unit suite mutation-tests, not a
# second implementation that could drift from it.
#
# The measurement it makes, taken in the guest, rows out of five:
#
#                                            intact rows   `grep -c shift`
#   keyboard drawn over the TUI ............      5              1
#   ordinary repaint, all but last line ....      1              1   <- lies
#   ordinary repaint, every line ...........      0              1   <- lies
#   hard repaint (clearok / clear_logo) ....      0              0
#   one pad sample later ...................      5         (not measured)
#                                                       and the TUI is down five
#
# ⚠️ THE TWO MIDDLE ROWS ARE THE POINT. An ordinary curses repaint does not
# erase the keyboard -- ncurses diffs against its own model of the physical
# screen, which has never heard of us, so it writes only the cells whose
# content changed and PUNCHES ONE CHARACTER THROUGH each keyboard row. What is
# left looks exactly like a keyboard, greps exactly like a keyboard, and has
# one key per row whose drawn label has been overwritten by that character. The
# word grep never catches it at all; only the row count does.
#
# ===========================================================================
# ⚠️ EVERY GREP IN THE IN-GUEST PROBE IS `LC_ALL=C command grep -a`
# ===========================================================================
# Added 2026-08-12 by the audit that followed T4's §6.4 lie #7 (the harness,
# not the wizard, was wrong -- docs/findings/T4-harness-first-run.md).
#
# THE ASSUMPTION THAT WAS NOT TRUE. Every grep below reads either a /dev/vcsN
# snapshot or a program's stderr. `/dev/vcsN` is the kernel's screen buffer:
# ONE BYTE PER CELL in the console's own charmap, NOT UTF-8. A box-drawing or
# block glyph on screen is a single high byte (0xB3, 0xB0...) which is invalid
# UTF-8. It would be comforting to believe the probe runs in the C locale --
# it does not: test/images/vm-neptune-image.sh writes `LANG=en_US.UTF-8` into
# the substrate's /etc/locale.conf, systemd hands that to every service, and
# this probe IS a service. So the guest greps in a UTF-8 locale, over a byte
# stream that is not UTF-8.
#
# MEASURED, on this dev machine's GNU grep, against a 5-line fixture holding
# one 0xB3 row and one 0xB0/0xB1 row plus the word `shift`, using this file's
# own `diag.rows_with_keys` pattern:
#
#   LC_ALL=C           grep -n  -> rows 1,2,3     (correct)
#   LC_ALL=C           grep -an -> rows 1,2,3     (correct)
#   LC_ALL=en_US.UTF-8 grep -n  -> row 1 ONLY, and "binary file matches" on
#                                  STDERR -- which this probe redirects into
#                                  probe.log, so the loss is silent
#   LC_ALL=en_US.UTF-8 grep -an -> rows 1,2,3     (correct)
#
# Note which half is load-bearing HERE: for this grep `-a` alone is enough,
# where for `screens::nonblank_rows` in test/lib/vm-installer-screens.sh it was
# `LC_ALL=C` alone. Neither flag fixes both cases, so both are always applied.
#
# IS IT MISFIRING TODAY? No -- and that is the whole point of writing it down.
# `deck_osk_tty.render()` was checked while making this change and emits pure
# ASCII, and `gum input` draws no borders, so the captures currently contain no
# high bytes and the old greps happened to return the right answers. The
# keyboard is ONE GLYPH away from that stopping: `deck_osk_layout` already
# carries `◀ ▶ ▲ ▼ ☺` for the pixel renderer, and the day the tty renderer
# borrows one, `row.osk_last` starts coming back EMPTY and this suite fails
# while blaming the mapper. (The same glyph would also break `osk_rows()`
# below, which decodes the capture as UTF-8 with errors="replace": a single
# 0xB3 becomes U+FFFD and can never equal the rendered character. That one is
# in shipped code, `src/deck_osk_tty.py`, and is only recorded here.)
#
# Neither side is wrong and neither yields. So the keyboard is summoned for one
# text-entry prompt and killed after it (`docs/tasks/T4-screen-spec.md` §2.3),
# which T4 §1's wrap makes sufficient: every text-entry moment is a prompt
# function of ours, and archinstall's curses menu never runs interactively at
# all. There is no pty relay here because nothing needs one.

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

BASE_DISK=${1:-$REPO_ROOT/test/images/neptune-substrate.raw}

RUN_TIMEOUT=${VM_RUN_TIMEOUT_SEC:-1800}
MEM_MB=${VM_MEM_MB:-4096}
SMP=${VM_SMP:-4}

WORK=${VM_WORK_DIR:-$(mktemp -d /var/tmp/vm-osk-tty.XXXXXX)}

log() { printf '[vm-gamepad-spike] %s\n' "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

[[ -f $REPO_ROOT/src/deck-input-mapper.py ]] || fail "deck-input-mapper.py not found next to this script"
if [[ ! -f $BASE_DISK ]]; then
  log "substrate image not found at $BASE_DISK -- building it"
  "$REPO_ROOT/test/images/vm-neptune-image.sh" "$BASE_DISK" || fail "could not build the substrate image"
fi

for tool in qemu-system-x86_64 qemu-img mcopy sfdisk base64; do
  command -v "$tool" >/dev/null || fail "required tool '$tool' not found"
done

# shellcheck source=../lib/vm-disk-image.sh
source "$REPO_ROOT/test/lib/vm-disk-image.sh"

find_ovmf() {
  local c
  for c in "$@"; do [[ -f $c ]] && { printf '%s\n' "$c"; return 0; }; done
  return 1
}
OVMF_CODE=${VM_OVMF_CODE:-$(find_ovmf \
  /usr/share/edk2/x64/OVMF_CODE.4m.fd \
  /usr/share/OVMF/OVMF_CODE_4M.fd \
  /usr/share/OVMF/OVMF_CODE.fd \
  /usr/share/edk2/ovmf/OVMF_CODE.fd)}
OVMF_VARS_TEMPLATE=${VM_OVMF_VARS:-$(find_ovmf \
  /usr/share/edk2/x64/OVMF_VARS.4m.fd \
  /usr/share/OVMF/OVMF_VARS_4M.fd \
  /usr/share/OVMF/OVMF_VARS.fd \
  /usr/share/edk2/ovmf/OVMF_VARS.fd)}
[[ -n $OVMF_CODE && -f $OVMF_CODE ]] || fail "OVMF CODE firmware not found — install edk2-ovmf. Override with VM_OVMF_CODE."
[[ -n $OVMF_VARS_TEMPLATE && -f $OVMF_VARS_TEMPLATE ]] || fail "OVMF VARS firmware not found. Override with VM_OVMF_VARS."

if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  ACCEL_ARGS=(-cpu host -enable-kvm -machine "q35,accel=kvm")
else
  log "WARNING: /dev/kvm not accessible — falling back to TCG (slow)."
  ACCEL_ARGS=(-cpu max -machine "q35,accel=tcg")
fi

mkdir -p "$WORK"
log "work dir: $WORK"

disk="$WORK/target.raw"
ovmf_vars="$WORK/OVMF_VARS.fd"
result_img="$WORK/result.raw"
result_txt="$WORK/report.txt"
pidfile="$WORK/qemu.pid"
serial_log="$WORK/serial.log"

log "copying the substrate image (the test must not mutate it)"
case $BASE_DISK in
  *.qcow2) qemu-img convert -O raw "$BASE_DISK" "$disk" || fail "qemu-img convert failed" ;;
  *)       cp --reflink=auto --sparse=always "$BASE_DISK" "$disk" || fail "cp of the substrate image failed" ;;
esac

cp "$OVMF_VARS_TEMPLATE" "$ovmf_vars"
qemu-img create -f raw "$result_img" 64M >/dev/null

# --- payload -----------------------------------------------------------------

# A Deck-shaped virtual pad: BOTH trackpads as absolute axes, BTN_MODE for the
# STEAM+X chord, and both trigger buttons. The T2 spike's pad had none of those
# -- it predates the measurements in P17 -- so this one is separate rather than
# shared.
pad_src="$WORK/vm-osk-pad.py"
cat >"$pad_src" <<'PAD'
#!/usr/bin/env python3
"""Scripted Deck-shaped pad. Commands on stdin, one per line:
  key <BTN_NAME> <0|1>   |  tap <BTN_NAME>
  abs <AXIS> <value>     |  sleep <seconds>
Axis names are the measured ones: HAT0X/HAT0Y are the LEFT trackpad,
HAT1X/HAT1Y the right (docs/findings/P17-input-and-osk.md R-29..R-31)."""
import sys, time
from evdev import UInput, AbsInfo, ecodes as e

AXIS = AbsInfo(0, -32768, 32767, 0, 0, 0)
caps = {
    e.EV_KEY: [e.BTN_SOUTH, e.BTN_EAST, e.BTN_NORTH, e.BTN_WEST, e.BTN_TL, e.BTN_TR,
               e.BTN_START, e.BTN_SELECT, e.BTN_MODE, e.BTN_TL2, e.BTN_TR2,
               e.BTN_DPAD_UP, e.BTN_DPAD_DOWN, e.BTN_DPAD_LEFT, e.BTN_DPAD_RIGHT],
    e.EV_ABS: [(e.ABS_X, AXIS), (e.ABS_Y, AXIS),
               (e.ABS_HAT0X, AXIS), (e.ABS_HAT0Y, AXIS),
               (e.ABS_HAT1X, AXIS), (e.ABS_HAT1Y, AXIS)],
}
ui = UInput(caps, name="OSK Virtual Deck Pad", vendor=0x28de, product=0x1205)
print("pad-ready", flush=True)
AX = {n: getattr(e, "ABS_" + n) for n in ("X", "Y", "HAT0X", "HAT0Y", "HAT1X", "HAT1Y")}
for line in sys.stdin:
    parts = line.split()
    if not parts:
        continue
    if parts[0] == "key":
        ui.write(e.EV_KEY, getattr(e, parts[1]), int(parts[2])); ui.syn()
    elif parts[0] == "tap":
        ui.write(e.EV_KEY, getattr(e, parts[1]), 1); ui.syn(); time.sleep(0.06)
        ui.write(e.EV_KEY, getattr(e, parts[1]), 0); ui.syn()
    elif parts[0] == "abs":
        ui.write(e.EV_ABS, AX[parts[1]], int(parts[2])); ui.syn()
    elif parts[0] == "sleep":
        time.sleep(float(parts[1]))
    print(f"did {line.strip()}", flush=True)
ui.close()
PAD

# A full-screen curses TUI, standing in for archinstall's menu. `gum` is the
# easy case and section 3 already has it; this is the one R-49 left open.
tui_src="$WORK/vm-fullscreen-tui.py"
cat >"$tui_src" <<'TUI'
#!/usr/bin/env python3
"""A full-screen curses TUI -- the archinstall-shaped half of R-52.

Real curses, real terminfo, laid out over EVERY row of the console, unlike
`gum`, which lives in its top three.

IT REPAINTS ON A KEYSTROKE, not on a timer. The keystrokes arrive from the
on-screen keyboard through uinput and the VT, so the collision is driven by the
real input path rather than by a clock this suite would race.

⚠️ THERE ARE TWO KINDS OF REPAINT AND THEY FAIL DIFFERENTLY. This was found by
running it, and the first version of this file asserted the wrong one.

  1. AN ORDINARY REPAINT. ncurses copies the window into `newscr` and then
     diffs `newscr` against its own model of the physical screen -- and it has
     no model of anything the mapper painted. So a "full repaint" writes only
     the cells whose CONTENT changed, which here is the one digit of `PASS nn`,
     and PUNCHES A SINGLE CHARACTER THROUGH EACH KEYBOARD ROW. The keyboard
     still looks like a keyboard. `touchline` does not save you: it forces the
     window's lines into `newscr`, one layer above the diff that matters.
  2. A HARD REPAINT -- `clearok`. curses throws its model away, clears, and
     rewrites everything, which is what upstream's own `clear_logo`
     (`\033[H\033[2J`, T4 §2.5) does on every validation failure. That one
     really does erase the keyboard.

Three keystrokes, one for each case: an ordinary repaint of every line but the
console's last, an ordinary repaint of all of them, then a hard one.
"""
import curses
import pathlib
import time

OUT = pathlib.Path("/root/osktest")

# ⚠️ The mapper redraws the keyboard the instant a trigger event lands, which
# is BEFORE this character has been delivered. The collision under test is the
# repaint that comes AFTER that redraw, so a pause makes the ordering a fact
# rather than a race between two things that both happen in microseconds.
SETTLE = 0.6


def paint(screen, first, last, generation, hard=False):
    _, cols = screen.getmaxyx()
    for row in range(first, last + 1):
        text = f"MENU LINE {row:02d} PASS {generation:02d} ".ljust(cols - 1, "-")
        try:
            screen.addstr(row, 0, text[:cols - 1])
        except curses.error:
            pass
    screen.touchline(first, last - first + 1)
    if hard:
        screen.clearok(True)
    screen.refresh()


def main(screen):
    curses.curs_set(0)
    rows, _ = screen.getmaxyx()
    screen.clear()
    paint(screen, 0, rows - 1, 0)
    (OUT / "tui.paints").write_text("0")
    received = ""
    generation = 0
    while True:
        code = screen.getch()
        if code < 0:
            continue
        received += chr(code) if 32 <= code < 127 else "?"
        (OUT / "tui.received").write_text(received)
        time.sleep(SETTLE)
        generation += 1
        last = rows - 2 if generation == 1 else rows - 1
        paint(screen, 0, last, generation, hard=generation >= 3)
        (OUT / "tui.paints").write_text(str(generation))


curses.wrapper(main)
TUI

probe_src="$WORK/omarchy-deck-osk-probe.sh"
cat >"$probe_src" <<'PROBE'
#!/usr/bin/env bash
# In-guest probe: can the TTY on-screen keyboard and an installer TUI share one
# console? NOT `set -e` -- a failure of the thing under test is a result to
# report, not a reason to abort before reporting it.
set -uo pipefail

RESULT_DEV=/dev/disk/by-id/virtio-vmresult
OUT=/root/osktest
mkdir -p "$OUT"
exec >"$OUT/probe.log" 2>&1
set -x

RESULTS=$OUT/results
: >"$RESULTS"
emit() { printf '%s\n' "$*" >>"$RESULTS"; }

# The report's first fact is that its author ran at all (T4 §6.4 lie #3): a
# report with content but no `unit.ran=1` means every other line in it is
# unexplained, and `finish` writes a report even when the probe dies early.
emit "unit.ran=1"

# --- the grep canary ---------------------------------------------------------
#
# ⚠️ THE ASSUMPTION EVERY LATER GREP RESTS ON, TURNED INTO A MEASUREMENT.
#
# It is tempting to argue that these probes are safe because systemd starts
# them with no LANG, i.e. in the C locale. THAT IS FALSE HERE and it was worth
# checking rather than asserting: test/images/vm-neptune-image.sh writes
# `LANG=en_US.UTF-8` into the substrate's /etc/locale.conf, systemd puts that in
# the manager environment, and every service inherits it. (Verified on the dev
# machine, which has the same file: `systemctl show-environment` prints
# LANG=en_US.UTF-8.) So this probe greps a byte stream that is not UTF-8 while
# sitting in a UTF-8 locale, and nothing but the flags below saves it.
#
# Asserting the locale NAME would be the weaker fix -- it pins a proxy, and the
# suite would still be wrong in a locale nobody thought to enumerate. This
# instead asserts the BEHAVIOUR, against a fixture built to contain the exact
# byte that broke T4's extraction (0xB3, CP437's box-drawing vertical, the
# separator on upstream's real summary screen). Two lines, two controls:
#
#   canary.ascii     a NEGATIVE control -- a plain ASCII row must still be
#                    found. If this ever reads 0 the grep is broken outright
#                    and every "0" below means nothing.
#   canary.highbyte  the POSITIVE control -- the row that only a byte-safe
#                    grep can see. This is the one that goes to 0 the moment
#                    somebody "simplifies" an `LC_ALL=C command grep -a` back
#                    to `grep`, and it fails HERE, naming the cause, instead of
#                    silently subtracting rows from row.osk_last.
printf 'canary ascii row\n\263 canary highbyte row \263\n' >"$OUT/canary.bin"
emit "locale.lang=${LANG:-<unset>}"
emit "locale.lc_all=${LC_ALL:-<unset>}"
emit "canary.ascii=$(LC_ALL=C command grep -ac 'canary ascii row' "$OUT/canary.bin")"
emit "canary.highbyte=$(LC_ALL=C command grep -ac 'canary highbyte row' "$OUT/canary.bin")"
emit "canary.highbyte_rows=$(LC_ALL=C command grep -an 'canary' "$OUT/canary.bin" | cut -d: -f1 | tr '\n' ',')"

finish() {
  {
    echo "=== T8 OSK / TUI CONSOLE-SHARING PROBE ==="
    cat "$RESULTS"
    echo "=== SCREEN CAPTURES ==="
    for f in "$OUT"/screen.*; do
      [[ -f $f ]] || continue
      echo "--- ${f##*/} ---"
      cat "$f"
    done
    echo "=== MAPPER STDERR ==="
    tail -40 "$OUT/mapper.err" 2>/dev/null
  } >"$OUT/report.txt" 2>&1
  if [[ -b $RESULT_DEV ]]; then
    dd if="$OUT/report.txt" of="$RESULT_DEV" bs=1M conv=fsync status=none
  fi
  sync
  systemctl poweroff -i
}
trap finish EXIT

# --- 0. packages -------------------------------------------------------------
pacman -Sy --noconfirm --needed python-evdev gum >"$OUT/pacman.log" 2>&1
emit "pkg.evdev=$(pacman -Q python-evdev 2>/dev/null | cut -d' ' -f2)"
emit "pkg.gum=$(pacman -Q gum 2>/dev/null | cut -d' ' -f2)"

# The mapper imports the OSK modules from ../lib/deck-osk relative to itself,
# exactly as stage-input-mapper installs them. Mirror that here rather than
# dropping everything in one directory, so the layout under test is the shipped
# one.
install -d /usr/local/bin /usr/local/lib/deck-osk
install -m 0755 /root/deck-input-mapper.py /usr/local/bin/deck-input-mapper
for m in deck_osk_layout.py deck_osk_tty.py deck_osk_wayland.py; do
  install -m 0644 "/root/$m" "/usr/local/lib/deck-osk/$m"
done
emit "osk.modules=$(ls /usr/local/lib/deck-osk | tr '\n' ',')"
/usr/local/bin/deck-input-mapper --type 'aA' --dry-run >"$OUT/type.out" 2>&1
emit "osk.type_ok=$((1 - $?))"

# --- 1. the pad, and the mapper ----------------------------------------------
mkfifo /tmp/padfifo
python3 /root/vm-osk-pad.py <>/tmp/padfifo >"$OUT/pad.log" 2>&1 &
sleep 3
emit "pad.ready=$(LC_ALL=C command grep -ac pad-ready "$OUT/pad.log")"
pad() { printf '%s\n' "$*" >/tmp/padfifo; sleep 0.12; }

# ⚠️ THE LAYOUT UNDER TEST. The console is 25 rows. The TUI is told it has 18,
# so it never draws below row 18; the keyboard takes 19-23. That is the
# TIOCSWINSZ mechanism `deck_osk_tty.write_at` documents and which nothing had
# ever tested.
# ⚠️ Derived, not guessed. The first run of this suite assumed a 25-row console
# and the guest's was 50 -- which left the keyboard drawn in the middle of the
# screen with 31 blank rows under it. The Deck's console will be a third size
# again, so nothing here may hardcode a height.
CONSOLE_ROWS=$(stty size </dev/tty2 2>/dev/null | cut -d' ' -f1)
CONSOLE_ROWS=${CONSOLE_ROWS:-25}
OSK_HEIGHT=5                       # the letters layer is five rows
TUI_ROWS=$((CONSOLE_ROWS - OSK_HEIGHT))
OSK_TOP=$((TUI_ROWS + 1))
# ⚠️ R-49: the console is NOT shrunk any more. `stty rows N` on a Linux VT
# resizes the console itself -- measured, /dev/vcs2 went from 50 to 45 rows --
# so shrinking the TUI out of the bottom rows deletes the very rows the
# keyboard needs. The keyboard now takes the bottom of the FULL console and the
# TUI is left believing it has all of it.
emit "console.rows=${CONSOLE_ROWS}"
emit "layout.tui_rows=${TUI_ROWS}"
emit "layout.osk_top=${OSK_TOP}"

# gum on VT2, with its window shrunk BEFORE it starts so it lays out small.
openvt -c 2 -s -f -- bash -c \
  "gum input --placeholder 'Wi-Fi password' --prompt 'pass> ' >/root/osktest/typed.txt" &
sleep 3
chvt 2
sleep 1
emit "vt.active=$(fgconsole 2>/dev/null)"

# ⚠️ /dev/vcs2 is the KERNEL's copy of what is on that console. No terminal
# emulator, no escape-sequence reconstruction, no tmux: this is the screen.
snap() { fold -w "$(stty size </dev/tty2 2>/dev/null | cut -d' ' -f2 || echo 80)" \
           </dev/vcs2 >"$OUT/screen.$1" 2>/dev/null; }
snap 1-gum-only
emit "gum.drew=$(LC_ALL=C command grep -ac 'pass>' "$OUT/screen.1-gum-only")"

/usr/local/bin/deck-input-mapper --device 'OSK Virtual Deck Pad' \
  --osk-backend tty --osk-tty /dev/tty2 --osk-top-row "$OSK_TOP" \
  >"$OUT/mapper.out" 2>"$OUT/mapper.err" &
sleep 3
emit "mapper.bound=$(LC_ALL=C command grep -ac 'reading /dev' "$OUT/mapper.err")"

# --- 2. summon the keyboard --------------------------------------------------
pad "key BTN_MODE 1"; pad "key BTN_NORTH 1"; pad "key BTN_NORTH 0"; pad "key BTN_MODE 0"
sleep 1
snap 2-osk-shown
emit "osk.shown=$(LC_ALL=C command grep -ac 'shift' "$OUT/screen.2-osk-shown")"
# --- R-49 diagnostics: is the console still 50 rows, and where did all five
# keyboard rows actually land? Two candidate causes, and these separate them:
# (a) `stty rows` RESIZED the console, so row 46 does not exist and the kernel
#     clamped; (b) the explicit --osk-top-row never reached the draw and the
#     automatic "as low as it fits" placement ran against a 45-row winsize.
emit "diag.stty_at_snap=$(stty size </dev/tty2 2>/dev/null | tr ' ' 'x')"
emit "diag.vcs2_bytes=$(wc -c </dev/vcs2 2>/dev/null)"
emit "diag.screen_lines=$(wc -l <"$OUT/screen.2-osk-shown")"
emit "diag.rows_with_keys=$(LC_ALL=C command grep -an 'q *w *e *r *t\|a *s *d *f *g\|z *x *c *v *b\|shift\|1 *2 *3 *4 *5' "$OUT/screen.2-osk-shown" | cut -d: -f1 | tr '\n' ',')"
emit "gum.survived=$(LC_ALL=C command grep -ac 'pass>' "$OUT/screen.2-osk-shown")"

# Which rows does each occupy? The whole question, answered from the kernel's
# own screen buffer.
emit "row.gum=$(LC_ALL=C command grep -an 'pass>' "$OUT/screen.2-osk-shown" | head -1 | cut -d: -f1)"
emit "row.osk_last=$(LC_ALL=C command grep -an 'shift' "$OUT/screen.2-osk-shown" | head -1 | cut -d: -f1)"

# --- 3. type a Wi-Fi passphrase with the trackpads ---------------------------
# Right cursor -> 'h' on the home row, then type; then shift; then a digit.
pad "abs HAT1X -20000"; pad "abs HAT1Y 3000"; sleep 0.3
pad "key BTN_TR2 1"; pad "key BTN_TR2 0"; sleep 0.4
snap 3-typed-h
# The prompt line as the kernel has it, so the typed character is visible in
# the report rather than inferred. (grep -c 'pass>' proved nothing: the prompt
# is there whether or not anything was typed.)
emit "typed.prompt_line=$(LC_ALL=C command grep -am1 'pass>' "$OUT/screen.3-typed-h" | tr -s ' ' | cut -c1-40)"

pad "abs HAT1X 13000"; pad "abs HAT1Y 3000"; sleep 0.3   # -> 'l' (20000 is BACKSPACE)
pad "key BTN_TR2 1"; pad "key BTN_TR2 0"; sleep 0.4
pad "abs HAT0X -30000"; pad "abs HAT0Y -30000"; sleep 0.3  # left -> shift
pad "key BTN_TL2 1"; pad "key BTN_TL2 0"; sleep 0.4
snap 4-shifted
emit "osk.shift_shown=$(LC_ALL=C command grep -ac 'Shift' "$OUT/screen.4-shifted")"
pad "abs HAT1X -20000"; pad "abs HAT1Y 3000"; sleep 0.3   # -> 'h', capitalised
pad "key BTN_TR2 1"; pad "key BTN_TR2 0"; sleep 0.5

pad "abs HAT0X -30000"; pad "abs HAT0Y -30000"; sleep 0.2  # digit '1'
pad "abs HAT0Y 30000"; sleep 0.2
pad "key BTN_TL2 1"; pad "key BTN_TL2 0"; sleep 0.5
snap 5-final

# Submit, so gum writes what it received to disk -- the only assertion that
# cannot be faked by anything drawn on screen.
#
# ⚠️ The axis maths matters and got this wrong once. The pad's Y grows UPWARD
# and the cursor's does not, so a POSITIVE y is near the TOP. `enter` is on row
# 3 of 5, which needs y normalised to ~0.7, i.e. a raw value near -13000. The
# first run used +10000, which is row 1 (`yuiop`) -- so Enter was never pressed,
# gum never submitted, and the file it writes on submit stayed empty.
pad "abs HAT1X 26000"; pad "abs HAT1Y -13000"; sleep 0.3   # right -> enter
pad "key BTN_TR2 1"; pad "key BTN_TR2 0"; sleep 1.5
# ⚠️ Counted BEFORE the submit. gum exiting makes `openvt` deallocate VT2, so
# every later draw hits EIO and the mapper correctly disables the tty keyboard
# and says so. Counting after would call that expected teardown a defect.
emit "mapper.errors_before_submit=$(LC_ALL=C command grep -aci 'traceback' "$OUT/mapper.err")"
emit "gum.received=$(tr -d '\n' </root/osktest/typed.txt 2>/dev/null)"
emit "gum.received_len=$(tr -d '\n' </root/osktest/typed.txt 2>/dev/null | wc -c)"

# --- 4. dismiss, and check the console is left clean -------------------------
pad "key BTN_MODE 1"; pad "key BTN_NORTH 1"; pad "key BTN_NORTH 0"; pad "key BTN_MODE 0"
sleep 1
snap 6-dismissed
emit "osk.gone=$(LC_ALL=C command grep -ac 'shift' "$OUT/screen.6-dismissed")"
emit "mapper.alive=$(pgrep -cf deck-input-mapper)"
emit "mapper.errors=$(LC_ALL=C command grep -aci 'traceback\|DISABLED' "$OUT/mapper.err")"

# --- 5. R-52: the same console, but with a FULL-SCREEN curses TUI on it -------
#
# Everything above used `gum`, which is line-oriented: three rows at the top,
# never reaching the bottom, so of course it coexists. This is the case R-49
# left open -- a curses application laid out over the whole console.
#
# A fresh VT and a fresh mapper. VT2 was deallocated the moment gum exited,
# which is what disabled the first mapper's keyboard (R-48), so reusing either
# would measure that teardown instead of this collision.
pkill -f 'deck-input-[m]apper'
sleep 1

openvt -c 3 -s -f -- env TERM=linux python3 /root/vm-fullscreen-tui.py &
sleep 3
chvt 3
sleep 2
emit "curses.vt_active=$(fgconsole 2>/dev/null)"

C3_ROWS=$(stty size </dev/tty3 2>/dev/null | cut -d' ' -f1)
C3_ROWS=${C3_ROWS:-25}
OSK_TOP3=$((C3_ROWS - OSK_HEIGHT + 1))
emit "curses.console_rows=${C3_ROWS}"
emit "curses.osk_top=${OSK_TOP3}"

snap3() { fold -w "$(stty size </dev/tty3 2>/dev/null | cut -d' ' -f2 || echo 80)" \
            </dev/vcs3 >"$OUT/screen.$1" 2>/dev/null; }

# ⚠️ COUNTED, NOT GREPPED, AND THIS IS THE WHOLE POINT OF THE SECTION.
# `rows_on_screen` asks how many console lines carry a WHOLE keyboard row;
# `grep -c shift` asks whether one word is anywhere on the screen. R-49 is the
# difference between those two questions, and both are emitted below so the
# report shows them disagreeing rather than asserting that they do.
#
# It is the SHIPPED function, imported from the installed module -- not a
# reimplementation in bash that could drift from the one the unit suite
# mutation-tests.
osk_rows() {
  python3 - "$1" <<'PY'
import sys
sys.path.insert(0, "/usr/local/lib/deck-osk")
import deck_osk_layout as osk
import deck_osk_tty as tty
rows = tty.render(osk.OnScreenKeyboard(), osk.Cursors())
with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
    print(len(tty.rows_on_screen(fh.read(), rows)))
PY
}
tui_rows() { LC_ALL=C command grep -ac '^MENU LINE' "$1"; }

# 5a. The TUI alone. Both halves of this are vacuity guards: a TUI that never
# started would make every later number meaningless, and a counter that finds a
# keyboard before one is drawn is not counting keyboards.
snap3 7-tui-alone
emit "curses.tui_rows_alone=$(tui_rows "$OUT/screen.7-tui-alone")"
emit "curses.osk_rows_alone=$(osk_rows "$OUT/screen.7-tui-alone")"

/usr/local/bin/deck-input-mapper --device 'OSK Virtual Deck Pad' \
  --osk-backend tty --osk-tty /dev/tty3 --osk-top-row "$OSK_TOP3" \
  >"$OUT/mapper2.out" 2>"$OUT/mapper2.err" &
sleep 3
emit "curses.mapper_bound=$(LC_ALL=C command grep -ac 'reading /dev' "$OUT/mapper2.err")"

# 5b. Summon it, and MOVE A CURSOR before looking. The keyboard draws over a
# full-screen TUI perfectly well -- that was never the problem.
#
# ⚠️ The cursor move is not decoration. `osk_rows` renders with DEFAULT cursor
# positions, because a probe reading a console back cannot know where the
# thumbs were; the screen therefore has its right-hand highlight somewhere the
# render does not, and matching anyway is `face_of`'s whole job. Without this
# move the two would coincide and the tolerance would never be exercised here
# at all -- measured: five separate `face_of` mutations survived the VM checks
# until this line moved up from 5c.
pad "key BTN_MODE 1"; pad "key BTN_NORTH 1"; pad "key BTN_NORTH 0"; pad "key BTN_MODE 0"
sleep 1
pad "abs HAT1X -20000"; pad "abs HAT1Y 3000"; sleep 0.5
snap3 8-osk-over-tui
emit "curses.osk_rows_drawn=$(osk_rows "$OUT/screen.8-osk-over-tui")"
emit "curses.tui_rows_with_osk=$(tui_rows "$OUT/screen.8-osk-over-tui")"

# 5c. Type one character with the right trackpad. It reaches the curses app the
# way it reached gum -- uinput, active VT, stdin -- and the app asks curses to
# repaint every line but the console's last. What curses then actually writes
# is the finding; see the header.
pad "key BTN_TR2 1"; pad "key BTN_TR2 0"
sleep 3
snap3 9-after-partial-repaint
emit "curses.paints_partial=$(cat "$OUT/tui.paints" 2>/dev/null)"
emit "curses.osk_rows_after_partial=$(osk_rows "$OUT/screen.9-after-partial-repaint")"
emit "curses.grep_shift_after_partial=$(LC_ALL=C command grep -ac 'shift' "$OUT/screen.9-after-partial-repaint")"

# 5d. A second character. This repaint covers every line -- and STILL only
# writes the cells ncurses believes changed, because its model of the physical
# screen has never heard of the keyboard.
pad "key BTN_TR2 1"; pad "key BTN_TR2 0"
sleep 3
snap3 10-after-full-repaint
emit "curses.paints_full=$(cat "$OUT/tui.paints" 2>/dev/null)"
emit "curses.osk_rows_after_full=$(osk_rows "$OUT/screen.10-after-full-repaint")"
emit "curses.grep_shift_after_full=$(LC_ALL=C command grep -ac 'shift' "$OUT/screen.10-after-full-repaint")"

# 5e. A third, and this one is a HARD repaint -- `clearok`, which is what
# upstream's `clear_logo` does on every validation failure (T4 §2.5). Only now
# does the keyboard actually leave the screen.
pad "key BTN_TR2 1"; pad "key BTN_TR2 0"
sleep 3
snap3 11-after-hard-repaint
emit "curses.paints_hard=$(cat "$OUT/tui.paints" 2>/dev/null)"
emit "curses.osk_rows_after_hard=$(osk_rows "$OUT/screen.11-after-hard-repaint")"
emit "curses.grep_shift_after_hard=$(LC_ALL=C command grep -ac 'shift' "$OUT/screen.11-after-hard-repaint")"
emit "curses.tui_rows_after_hard=$(tui_rows "$OUT/screen.11-after-hard-repaint")"
emit "curses.received=$(tr -d '\n' <"$OUT/tui.received" 2>/dev/null)"

# 5f. And back the other way, so the fight is shown to be mutual rather than
# the keyboard simply losing. One pad sample is enough to make the mapper
# repaint, and it takes five rows off a TUI that has no idea it lost them.
pad "abs HAT1X -19000"
sleep 1
snap3 12-osk-repainted
emit "curses.osk_rows_after_nudge=$(osk_rows "$OUT/screen.12-osk-repainted")"
emit "curses.tui_rows_after_nudge=$(tui_rows "$OUT/screen.12-osk-repainted")"
emit "curses.mapper_alive=$(pgrep -cf deck-input-mapper)"
emit "curses.mapper_errors=$(LC_ALL=C command grep -aci 'traceback' "$OUT/mapper2.err")"

# ⚠️ The closing bookend. `finish` runs from an EXIT trap, so a probe that dies
# in section 3 still ships a well-formed report with sections 4 and 5 simply
# absent -- and every check over those fields would then be comparing "" to a
# number, which fails, but fails blaming the mapper instead of naming the truth.
# This field is the difference between "the keyboard misbehaved" and "the probe
# never got that far".
emit "probe.done=1"
PROBE


unit_text="[Unit]
Description=T8 OSK / TUI console-sharing probe
After=network-online.target
Wants=network-online.target
Before=graphical.target

[Service]
Type=oneshot
ExecStartPre=/usr/bin/cp /boot/omarchy-deck-osk-probe.sh /root/omarchy-deck-osk-probe.sh
ExecStartPre=/usr/bin/cp /boot/deck-input-mapper.py /root/deck-input-mapper.py
ExecStartPre=/usr/bin/cp /boot/vm-osk-pad.py /root/vm-osk-pad.py
ExecStartPre=/usr/bin/cp /boot/vm-fullscreen-tui.py /root/vm-fullscreen-tui.py
ExecStartPre=/usr/bin/cp /boot/deck_osk_layout.py /root/deck_osk_layout.py
ExecStartPre=/usr/bin/cp /boot/deck_osk_tty.py /root/deck_osk_tty.py
ExecStartPre=/usr/bin/cp /boot/deck_osk_wayland.py /root/deck_osk_wayland.py
ExecStart=/usr/bin/bash /root/omarchy-deck-osk-probe.sh
TimeoutStartSec=0
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console
"
dropin_text="[Unit]
Wants=omarchy-deck-osk.service
"

log "writing payload onto the guest ESP (rootless, mtools at byte offset)"
esp_offset=$(disk_image::esp_offset "$disk") || fail "could not locate the ESP on $disk"
for f in "$REPO_ROOT/src/deck-input-mapper.py" \
         "$REPO_ROOT/src/deck_osk_layout.py" \
         "$REPO_ROOT/src/deck_osk_tty.py" \
         "$REPO_ROOT/src/deck_osk_wayland.py" \
         "$pad_src" "$tui_src" "$probe_src"; do
  MTOOLS_SKIP_CHECK=1 mcopy -o -i "${disk}@@${esp_offset}" "$f" "::/${f##*/}" ||
    fail "mcopy of ${f##*/} onto the ESP failed"
done

cred_unit="io.systemd.credential.binary:systemd.extra-unit.omarchy-deck-osk.service=$(base64 -w0 <<<"$unit_text")"
cred_dropin="io.systemd.credential.binary:systemd.unit-dropin.multi-user.target=$(base64 -w0 <<<"$dropin_text")"

# --- boot --------------------------------------------------------------------

log "booting the substrate headless (timeout ${RUN_TIMEOUT}s)"
qemu-system-x86_64 \
  "${ACCEL_ARGS[@]}" \
  -smp "$SMP" -m "$MEM_MB" \
  -smbios type=1,manufacturer=Valve,product=Galileo,version=1 \
  -smbios type=2,manufacturer=Valve,product=Galileo \
  -smbios "type=11,value=${cred_unit}" \
  -smbios "type=11,value=${cred_dropin}" \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$ovmf_vars" \
  -drive file="$disk",format=raw,if=none,id=drive0 \
  -device virtio-blk-pci,drive=drive0,bootindex=1 \
  -drive file="$result_img",format=raw,if=none,id=result0 \
  -device virtio-blk-pci,drive=result0,serial=vmresult \
  -nic user,model=virtio-net-pci \
  -display none -vga std \
  -serial "file:${serial_log}" \
  -daemonize -pidfile "$pidfile" \
  -no-reboot ||
  fail "qemu-system-x86_64 failed to launch"

qemu_pid=$(cat "$pidfile")
log "qemu pid $qemu_pid"

elapsed=0
while kill -0 "$qemu_pid" 2>/dev/null; do
  sleep 15
  elapsed=$((elapsed + 15))
  if (( elapsed >= RUN_TIMEOUT )); then
    kill "$qemu_pid" 2>/dev/null
    sleep 2
    kill -9 "$qemu_pid" 2>/dev/null
    fail "guest did not power off within ${RUN_TIMEOUT}s (work dir preserved: $WORK)"
  fi
done
log "guest powered off after ${elapsed}s"

# --- results -----------------------------------------------------------------

tr -d '\0' <"$result_img" >"$result_txt"
[[ -s $result_txt ]] || fail "the guest wrote nothing to the result device. Check $serial_log and $WORK."
log "report: $result_txt"

field() {
  local key=$1 line
  while IFS= read -r line; do
    if [[ $line == "${key}="* ]]; then
      printf '%s\n' "${line#*=}"
      return 0
    fi
  done <"$result_txt"
  return 1
}

status=0
check() {
  local what=$1 got=$2 want=$3
  if [[ $got == "$want" ]]; then
    log "ok   ${what} = ${got}"
  else
    log "FAIL ${what} = '${got}' (expected '${want}')"
    status=1
  fi
}

# ⚠️ Vacuity bookends, first and last. See the two `emit` calls they read.
check "unit.ran (the probe executed at all)" "$(field unit.ran)" 1

# ⚠️ THE GREP CANARY, CHECKED BEFORE ANYTHING IT PROTECTS. Every screen check
# below is a grep over /dev/vcsN bytes; these two say those greps can still see
# a high byte in whatever locale the guest actually booted with. Checked here,
# first, because a canary read after the checks it guards explains a failure
# nobody can act on any more.
check "canary: an ASCII row is found (the grep works at all)" "$(field canary.ascii)" 1
check "canary: a CP437 0xB3 row is counted"                   "$(field canary.highbyte)" 1
# ⚠️ THIS IS THE ONE THAT ACTUALLY CATCHES A REGRESSION, and the two above are
# not, which is worth stating rather than letting three green lines imply three
# proofs. Measured against real GNU grep on the fixture this probe writes:
# `grep -c` on a FIXED string finds the 0xB3 row in either locale, so the two
# counts above stay 1 even with the flags stripped. `grep -n` does not -- in
# en_US.UTF-8 it enumerates row 1 and then declares the file binary on stderr,
# so this reads "1," instead of "1,2,". Same asymmetry the reference library
# records (test/lib/vm-installer-screens.sh's header): which half of
# `LC_ALL=C -a` is load-bearing depends on the grep, so both are always used
# and only the row enumeration is trusted to prove it.
check "canary: BOTH rows are enumerated by grep -n (the real regression test)" \
      "$(field canary.highbyte_rows)" "1,2,"
log "note   the guest ran these greps under LANG=$(field locale.lang) LC_ALL=$(field locale.lc_all) -- recorded, not assumed"

check "packages installed"          "$(field pkg.gum | LC_ALL=C command grep -ac .)" 1
check "all three OSK modules present" "$(field osk.modules)" "deck_osk_layout.py,deck_osk_tty.py,deck_osk_wayland.py,"
check "the mapper resolves text"    "$(field osk.type_ok)" 1
check "the pad came up"             "$(field pad.ready)" 1
check "VT2 is the active console"   "$(field vt.active)" 2
check "gum drew on it"              "$(field gum.drew)" 1
check "the mapper bound to the pad" "$(field mapper.bound)" 1

# --- the question this suite exists for --------------------------------------
check "STEAM+X drew the keyboard on the console" "$(field osk.shown)" 1
check "and gum SURVIVED it -- both on one console" "$(field gum.survived)" 1
check "the keyboard sits below the TUI, not over it" \
      "$(( $(field row.osk_last) > $(field row.gum) ))" 1
check "the keyboard occupies exactly the rows it was given" \
      "$(field row.osk_last)" "$(( $(field layout.osk_top) + 4 ))"
log "note   requested osk_top=$(field layout.osk_top), last row landed at $(field row.osk_last) (expected $(( $(field layout.osk_top) + 4 )))"
log "diag   stty_at_snap=$(field diag.stty_at_snap) vcs2_bytes=$(field diag.vcs2_bytes) screen_lines=$(field diag.screen_lines)"
log "diag   rows carrying keyboard content: $(field diag.rows_with_keys)"

# --- typing reaches the TUI ---------------------------------------------------
check "shift redrew the keyboard"   "$(field osk.shift_shown)" 1
check "gum RECEIVED what was typed" "$(field gum.received)" "hlH1"
check "dismissing cleared the keyboard" "$(field osk.gone)" 0
check "the mapper survived the whole run" "$(field mapper.alive)" 1
check "no traceback while the console was alive" "$(field mapper.errors_before_submit)" 0

# --- R-52: the fork R-49 left open, decided by COUNTING ROWS ------------------
#
# ⚠️ Not one of these greps for a keyboard. Every number below is "how many
# console lines carry a WHOLE keyboard row", which is the only question that
# separates a keyboard from the wreckage of one -- see this file's header.
curses_rows=$(field curses.console_rows)
check "the curses TUI took the whole console"      "$(field curses.tui_rows_alone)" "$curses_rows"
check "VT3 is the active console"                  "$(field curses.vt_active)" 3
check "and nothing counted as a keyboard before one was drawn" \
                                                   "$(field curses.osk_rows_alone)" 0
check "the second mapper bound to the pad"         "$(field curses.mapper_bound)" 1
check "the keyboard draws over a full-screen TUI fine -- all five rows" \
                                                   "$(field curses.osk_rows_drawn)" 5
check "...costing the TUI exactly those five"      "$(field curses.tui_rows_with_osk)" \
                                                   "$(( curses_rows - 5 ))"
check "the TUI received all three characters the trackpads typed" \
                                                   "$(field curses.received)" "hhh"
check "and repainted once per character"           "$(field curses.paints_hard)" 3

# ⭐ THE MEASUREMENT THIS SECTION EXISTS FOR. Each row count is paired with the
# word grep taken off the SAME screen, because the pair is the finding: for two
# of the three repaints the grep says the keyboard is fine while the count says
# it is destroyed, and the grep is what an earlier session believed.
check "⭐ an ordinary repaint of all but the last line leaves ONE row of five" \
                                                   "$(field curses.osk_rows_after_partial)" 1
check "⭐ ...while the console still greps as 'shift'" \
                                                   "$(field curses.grep_shift_after_partial)" 1
check "⭐ an ordinary repaint of EVERY line leaves NO intact row" \
                                                   "$(field curses.osk_rows_after_full)" 0
check "⭐ ...and the console STILL greps as 'shift' -- the word never catches it" \
                                                   "$(field curses.grep_shift_after_full)" 1
check "only a HARD repaint (clearok, i.e. clear_logo) erases the keyboard" \
                                                   "$(field curses.osk_rows_after_hard)" 0
check "...and only then does the word go too"      "$(field curses.grep_shift_after_hard)" 0
check "...leaving the TUI holding the whole console again" \
                                                   "$(field curses.tui_rows_after_hard)" "$curses_rows"
check "one pad sample repaints the keyboard"       "$(field curses.osk_rows_after_nudge)" 5
check "...taking five rows back off the TUI -- neither side yields" \
                                                   "$(field curses.tui_rows_after_nudge)" \
                                                   "$(( curses_rows - 5 ))"
check "the mapper survived the collision"          "$(field curses.mapper_alive)" 1
check "with no traceback"                          "$(field curses.mapper_errors)" 0
check "done (the probe ran to its last line)"      "$(field probe.done)" 1
log "note   R-52 rows/greps: drawn 5 -> partial $(field curses.osk_rows_after_partial)/grep $(field curses.grep_shift_after_partial) -> full $(field curses.osk_rows_after_full)/grep $(field curses.grep_shift_after_full) -> hard $(field curses.osk_rows_after_hard)/grep $(field curses.grep_shift_after_hard) -> one pad sample $(field curses.osk_rows_after_nudge)"

if [[ $status -eq 0 ]]; then
  log "PASS — a LINE-ORIENTED prompt shares the console (gum stays above, the keyboard draws below, and what the trackpads typed reached gum); a FULL-SCREEN curses TUI does not, and R-52 counts exactly how it fails"
  rm -rf "$WORK"
else
  log "FAILED — full report: $result_txt (work dir preserved: $WORK)"
fi
exit $status

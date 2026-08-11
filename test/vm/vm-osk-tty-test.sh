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
emit "pad.ready=$(grep -c pad-ready "$OUT/pad.log")"
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
emit "gum.drew=$(grep -c 'pass>' "$OUT/screen.1-gum-only")"

/usr/local/bin/deck-input-mapper --device 'OSK Virtual Deck Pad' \
  --osk-backend tty --osk-tty /dev/tty2 --osk-top-row "$OSK_TOP" \
  >"$OUT/mapper.out" 2>"$OUT/mapper.err" &
sleep 3
emit "mapper.bound=$(grep -c 'reading /dev' "$OUT/mapper.err")"

# --- 2. summon the keyboard --------------------------------------------------
pad "key BTN_MODE 1"; pad "key BTN_NORTH 1"; pad "key BTN_NORTH 0"; pad "key BTN_MODE 0"
sleep 1
snap 2-osk-shown
emit "osk.shown=$(grep -c 'shift' "$OUT/screen.2-osk-shown")"
# --- R-49 diagnostics: is the console still 50 rows, and where did all five
# keyboard rows actually land? Two candidate causes, and these separate them:
# (a) `stty rows` RESIZED the console, so row 46 does not exist and the kernel
#     clamped; (b) the explicit --osk-top-row never reached the draw and the
#     automatic "as low as it fits" placement ran against a 45-row winsize.
emit "diag.stty_at_snap=$(stty size </dev/tty2 2>/dev/null | tr ' ' 'x')"
emit "diag.vcs2_bytes=$(wc -c </dev/vcs2 2>/dev/null)"
emit "diag.screen_lines=$(wc -l <"$OUT/screen.2-osk-shown")"
emit "diag.rows_with_keys=$(grep -n 'q *w *e *r *t\|a *s *d *f *g\|z *x *c *v *b\|shift\|1 *2 *3 *4 *5' "$OUT/screen.2-osk-shown" | cut -d: -f1 | tr '\n' ',')"
emit "gum.survived=$(grep -c 'pass>' "$OUT/screen.2-osk-shown")"

# Which rows does each occupy? The whole question, answered from the kernel's
# own screen buffer.
emit "row.gum=$(grep -n 'pass>' "$OUT/screen.2-osk-shown" | head -1 | cut -d: -f1)"
emit "row.osk_last=$(grep -n 'shift' "$OUT/screen.2-osk-shown" | head -1 | cut -d: -f1)"

# --- 3. type a Wi-Fi passphrase with the trackpads ---------------------------
# Right cursor -> 'h' on the home row, then type; then shift; then a digit.
pad "abs HAT1X -20000"; pad "abs HAT1Y 3000"; sleep 0.3
pad "key BTN_TR2 1"; pad "key BTN_TR2 0"; sleep 0.4
snap 3-typed-h
# The prompt line as the kernel has it, so the typed character is visible in
# the report rather than inferred. (grep -c 'pass>' proved nothing: the prompt
# is there whether or not anything was typed.)
emit "typed.prompt_line=$(grep -m1 'pass>' "$OUT/screen.3-typed-h" | tr -s ' ' | cut -c1-40)"

pad "abs HAT1X 13000"; pad "abs HAT1Y 3000"; sleep 0.3   # -> 'l' (20000 is BACKSPACE)
pad "key BTN_TR2 1"; pad "key BTN_TR2 0"; sleep 0.4
pad "abs HAT0X -30000"; pad "abs HAT0Y -30000"; sleep 0.3  # left -> shift
pad "key BTN_TL2 1"; pad "key BTN_TL2 0"; sleep 0.4
snap 4-shifted
emit "osk.shift_shown=$(grep -c 'Shift' "$OUT/screen.4-shifted")"
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
emit "mapper.errors_before_submit=$(grep -ci 'traceback' "$OUT/mapper.err")"
emit "gum.received=$(tr -d '\n' </root/osktest/typed.txt 2>/dev/null)"
emit "gum.received_len=$(tr -d '\n' </root/osktest/typed.txt 2>/dev/null | wc -c)"

# --- 4. dismiss, and check the console is left clean -------------------------
pad "key BTN_MODE 1"; pad "key BTN_NORTH 1"; pad "key BTN_NORTH 0"; pad "key BTN_MODE 0"
sleep 1
snap 6-dismissed
emit "osk.gone=$(grep -c 'shift' "$OUT/screen.6-dismissed")"
emit "mapper.alive=$(pgrep -cf deck-input-mapper)"
emit "mapper.errors=$(grep -ci 'traceback\|DISABLED' "$OUT/mapper.err")"
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
         "$pad_src" "$probe_src"; do
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

check "packages installed"          "$(field pkg.gum | grep -c .)" 1
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

if [[ $status -eq 0 ]]; then
  log "PASS — the on-screen keyboard and a real TUI share one console: gum stays above, the keyboard draws below, and what the trackpads typed reached gum through the kernel input layer"
  rm -rf "$WORK"
else
  log "FAILED — full report: $result_txt (work dir preserved: $WORK)"
fi
exit $status

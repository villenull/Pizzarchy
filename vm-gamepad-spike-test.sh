#!/usr/bin/env bash
# vm-gamepad-spike-test.sh -- T2's central question, answered in a VM:
# can a gamepad drive real installer TUIs through the kernel input layer?
#
# Usage: ./vm-gamepad-spike-test.sh [substrate.raw]
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
# Inside the guest (root, so no permission ceremony obscures the question):
#
#   virtual gamepad (uinput) --> deck-input-mapper.py --> virtual keyboard
#        ^ scripted presses          (the artifact              |
#          from the probe            under test)                v
#                                              kernel VT input --> tmux client
#                                              on VT2 --> pty --> gum /
#                                              archinstall
#
# The chain matters: synthetic KEY events from a uinput keyboard are
# delivered to the ACTIVE VIRTUAL TERMINAL, not to any pty directly. So the
# probe starts a detached tmux session, attaches a client to it ON VT2 via
# openvt -s, and only then do mapper-emitted keys reach the TUI -- exactly
# the delivery path a real installer session would use. Nothing under test
# is told a controller exists.
#
# Observability: `tmux capture-pane` reads the TUI's rendered text, so every
# navigation step is asserted against what a user would actually see, and
# the panes are saved as artifacts. Outcomes (gum's stdout, files written)
# are asserted too -- text on screen AND artifact, per PLAN.md 9.7.
#
# WHAT THIS DOES AND DOES NOT PROVE
#   Proves: the mapper's emissions drive bubbletea (gum) and archinstall's
#   curses menu -- navigation, confirm, cancel, toggle -- at the kernel
#   input layer, in a console environment with no compositor, as root, like
#   a live ISO. And that text fields are REACHABLE, which frames T4's
#   text-entry fork honestly.
#   Does not prove: the real Deck controller's event codes (P1.5 recon
#   captures those), or the Omarchy ISO's own gum screens (phase-2 spike,
#   against the built ISO).

set -uo pipefail

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BASE_DISK=${1:-$SELF_DIR/neptune-substrate.raw}

RUN_TIMEOUT=${VM_RUN_TIMEOUT_SEC:-1800}
MEM_MB=${VM_MEM_MB:-4096}
SMP=${VM_SMP:-4}

WORK=${VM_WORK_DIR:-$(mktemp -d /var/tmp/vm-gamepad-spike.XXXXXX)}

log() { printf '[vm-gamepad-spike] %s\n' "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

[[ -f $SELF_DIR/deck-input-mapper.py ]] || fail "deck-input-mapper.py not found next to this script"
if [[ ! -f $BASE_DISK ]]; then
  log "substrate image not found at $BASE_DISK -- building it"
  "$SELF_DIR/vm-neptune-image.sh" "$BASE_DISK" || fail "could not build the substrate image"
fi

for tool in qemu-system-x86_64 qemu-img mcopy sfdisk base64; do
  command -v "$tool" >/dev/null || fail "required tool '$tool' not found"
done

# shellcheck source=vm-disk-image.sh
source "$SELF_DIR/vm-disk-image.sh"

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

# The virtual pad: creates a Deck-shaped uinput gamepad, then replays press
# commands from stdin. Test-local by design -- the pad is scaffolding, the
# mapper is the artifact.
pad_src="$WORK/vm-spike-pad.py"
cat >"$pad_src" <<'PAD'
#!/usr/bin/env python3
"""Scripted virtual gamepad. Commands on stdin, one per line:
  key <BTN_NAME> <0|1>      button state
  hat <X|Y> <-1|0|1>        d-pad
  abs <X|Y> <value>         left stick raw value
  tap <BTN_NAME>            press+release with a human-ish gap
  sleep <seconds>
Capabilities mirror the linux gamepad ABI subset the Deck's controller
exposes (BTN_SOUTH/EAST/NORTH/WEST, TL/TR, START/SELECT, HAT0, ABS_X/Y)."""
import sys, time
from evdev import UInput, AbsInfo, ecodes as e

caps = {
    e.EV_KEY: [e.BTN_SOUTH, e.BTN_EAST, e.BTN_NORTH, e.BTN_WEST,
               e.BTN_TL, e.BTN_TR, e.BTN_START, e.BTN_SELECT],
    e.EV_ABS: [
        (e.ABS_X, AbsInfo(0, -32768, 32767, 16, 128, 0)),
        (e.ABS_Y, AbsInfo(0, -32768, 32767, 16, 128, 0)),
        (e.ABS_HAT0X, AbsInfo(0, -1, 1, 0, 0, 0)),
        (e.ABS_HAT0Y, AbsInfo(0, -1, 1, 0, 0, 0)),
    ],
}
ui = UInput(caps, name="Spike Virtual Pad", vendor=0x28de, product=0x1205)
print("pad-ready", flush=True)
AX = {"X": e.ABS_X, "Y": e.ABS_Y}
HAT = {"X": e.ABS_HAT0X, "Y": e.ABS_HAT0Y}
for line in sys.stdin:
    parts = line.split()
    if not parts:
        continue
    cmd = parts[0]
    if cmd == "key":
        ui.write(e.EV_KEY, getattr(e, parts[1]), int(parts[2])); ui.syn()
    elif cmd == "tap":
        ui.write(e.EV_KEY, getattr(e, parts[1]), 1); ui.syn()
        time.sleep(0.06)
        ui.write(e.EV_KEY, getattr(e, parts[1]), 0); ui.syn()
    elif cmd == "hat":
        ui.write(e.EV_ABS, HAT[parts[1]], int(parts[2])); ui.syn()
    elif cmd == "abs":
        ui.write(e.EV_ABS, AX[parts[1]], int(parts[2])); ui.syn()
    elif cmd == "sleep":
        time.sleep(float(parts[1]))
    print(f"did {line.strip()}", flush=True)
ui.close()
PAD

probe_src="$WORK/omarchy-deck-spike-probe.sh"
cat >"$probe_src" <<'PROBE'
#!/usr/bin/env bash
# In-guest probe. NOT `set -e`: a failure of the thing under test is a result
# to report, not a reason to abort before reporting it.
set -uo pipefail

RESULT_DEV=/dev/disk/by-id/virtio-vmresult
OUT=/root/spiketest
mkdir -p "$OUT"
exec >"$OUT/probe.log" 2>&1
exec {xtrace_fd}>>"$OUT/probe.trace"
BASH_XTRACEFD=$xtrace_fd
set -x

RESULTS=$OUT/results
: >"$RESULTS"
emit() { printf '%s\n' "$*" >>"$RESULTS"; }

finish() {
  {
    echo "=== T2 GAMEPAD SPIKE PROBE ==="
    cat "$RESULTS"
    echo "=== PANE ARTIFACTS ==="
    for f in "$OUT"/pane.*; do
      [[ -f $f ]] || continue
      echo "--- ${f##*/} ---"
      cat "$f"
    done
    echo "=== MAPPER LOG ==="
    cat "$OUT/mapper.log" 2>/dev/null
    echo "=== PAD LOG ==="
    cat "$OUT/pad.log" 2>/dev/null
    echo "=== PROBE LOG (tail) ==="
    tail -n 80 "$OUT/probe.log"
    echo "=== END ==="
  } >"$OUT/report.txt" 2>&1
  if [[ -b $RESULT_DEV ]]; then
    dd if="$OUT/report.txt" of="$RESULT_DEV" bs=1M conv=fsync status=none
  fi
  sync
  systemctl poweroff -i
}
trap finish EXIT

# --- 0. network + packages ---------------------------------------------------
online=0
for _ in $(seq 1 60); do
  if getent hosts geo.mirror.pkgbuild.com >/dev/null 2>&1 || getent hosts archlinux.org >/dev/null 2>&1; then
    online=1; break
  fi
  sleep 5
done
emit "network_resolved=$online"

pacman -Sy --noconfirm --needed python-evdev gum tmux archinstall >"$OUT/pacman.log" 2>&1
emit "pkgs_installed=$((1 - $?))"
emit "ver.gum=$(pacman -Q gum 2>/dev/null | cut -d' ' -f2)"
emit "ver.archinstall=$(pacman -Q archinstall 2>/dev/null | cut -d' ' -f2)"
emit "ver.python_evdev=$(pacman -Q python-evdev 2>/dev/null | cut -d' ' -f2)"

# --- 1. the input chain ------------------------------------------------------
modprobe uinput 2>/dev/null
[[ -e /dev/uinput ]]
emit "uinput_node=$((1 - $?))"

# pad first (mapper needs a device to find), commands over a fifo
mkfifo /root/padctl
python3 /root/vm-spike-pad.py </root/padctl >"$OUT/pad.log" 2>&1 &
PAD_PID=$!
exec {padfd}>/root/padctl   # hold the fifo open across individual writes
pad() { printf '%s\n' "$*" >&"$padfd"; }

for _ in $(seq 1 50); do grep -q pad-ready "$OUT/pad.log" 2>/dev/null && break; sleep 0.2; done
grep -q pad-ready "$OUT/pad.log"
emit "pad_created=$((1 - $?))"

python3 /root/deck-input-mapper.py --device "Spike Virtual Pad" --verbose >"$OUT/mapper.log" 2>&1 &
MAPPER_PID=$!
for _ in $(seq 1 50); do grep -q "reading" "$OUT/mapper.log" 2>/dev/null && break; sleep 0.2; done
grep -q "reading .*Spike Virtual Pad" "$OUT/mapper.log"
emit "mapper_attached=$((1 - $?))"

# virtual keyboard exists?
grep -rq "deck-input-mapper virtual keyboard" /proc/bus/input/devices
emit "virtual_kb_exists=$((1 - $?))"

# --- 2. tmux on a real VT ----------------------------------------------------
# Detached session first; then a client ATTACHED ON VT2, because uinput
# keyboard events go to the active VT, not to any pty.
#
# TERM=linux is load-bearing: this probe runs from a systemd unit whose
# environment has no TERM at all, and a tmux client with no usable TERM
# refuses the terminal and exits -- leaving the VT switched but clientless,
# which looks exactly like "keys vanish". Found by the first run of this
# suite doing exactly that.
tmux new-session -d -s spike -x 100 -y 30 'exec bash --norc' 2>>"$OUT/probe.log"
emit "tmux_up=$((1 - $?))"
openvt -c 2 -s -f -- env TERM=linux tmux attach -t spike
sleep 1
fgconsole 2>/dev/null | grep -qx 2
emit "vt2_active=$((1 - $?))"
tmux list-clients -t spike >"$OUT/clients.txt" 2>&1
[[ -s $OUT/clients.txt ]]
emit "tmux_client_attached=$((1 - $?))"

# Each test runs in a FRESH tmux window: no shared shell, no state carried
# between tests, no resync choreography. A failed test cannot corrupt the
# next one's meaning -- the first two runs of this suite proved that shared
# panes do exactly that.
cap() { tmux capture-pane -pt spike >"$OUT/pane.$1" 2>&1; }
pane_has() { tmux capture-pane -pt spike 2>/dev/null | grep -q "$1"; }
wait_pane() { # wait_pane <regex> <tries>
  local i
  for i in $(seq 1 "${2:-40}"); do pane_has "$1" && return 0; sleep 0.25; done
  return 1
}
fresh_window() { # fresh_window <shell command>
  tmux kill-window -t spike:9 2>/dev/null
  tmux new-window -t spike:9 -k "$1"
  tmux select-window -t spike:9
  sleep 0.5
}

# Sanity: a mapper Enter must reach the shell through the VT.
fresh_window 'exec bash --norc'
tmux send-keys -t spike "echo CHAIN-\$((6*7))" # typed via pty, NOT executed yet
pad tap BTN_SOUTH                              # Enter arrives via kernel VT
wait_pane "CHAIN-42" 20
chain_ok=$((1 - $?))
emit "chain_sanity=$chain_ok"
cap chain
if [[ $chain_ok -ne 1 ]]; then
  emit "diag.fgconsole=$(fgconsole 2>/dev/null)"
  cp /proc/bus/input/devices "$OUT/input-devices.txt" 2>/dev/null
  emit "diag.kb_handlers=$(grep -A4 'deck-input-mapper' "$OUT/input-devices.txt" 2>/dev/null | grep Handlers | tr -d ' ')"
  kill "$MAPPER_PID" "$PAD_PID" 2>/dev/null
  emit "done=1"
  exit 0
fi

# --- 3. gum choose -----------------------------------------------------------
# Readiness is always gated on RENDERED menu markers anchored at line start
# ("^> Alpha"), never on bare option text -- that would match the window's
# own echoed command line before the TUI is even up (a bug two runs of this
# suite shipped).
fresh_window 'gum choose Alpha Beta Gamma >/root/gum-single.out; echo GUM1:$?; exec bash --norc'
wait_pane "^> .*Alpha" 60
emit "gum_single_menu_up=$((1 - $?))"
pad hat Y 1; pad sleep 0.15; pad hat Y 0; pad sleep 0.1
pad hat Y 1; pad sleep 0.15; pad hat Y 0; pad sleep 0.1
cap gum-before-confirm
pad tap BTN_SOUTH
wait_pane "GUM1:0" 20
emit "gum_single_exit0=$((1 - $?))"
emit "gum_single_choice=$(tr -d '\n' </root/gum-single.out 2>/dev/null)"

# multi-select: down, toggle (Y->Space), down, toggle, confirm
fresh_window 'gum choose --no-limit One Two Three >/root/gum-multi.out; echo GUM2:$?; exec bash --norc'
wait_pane "^> .*One" 60   # --no-limit renders a bullet: "> \u2022 One"
emit "gum_multi_menu_up=$((1 - $?))"
pad hat Y 1; pad sleep 0.15; pad hat Y 0; pad sleep 0.1
pad tap BTN_WEST; pad sleep 0.1
pad hat Y 1; pad sleep 0.15; pad hat Y 0; pad sleep 0.1
pad tap BTN_WEST; pad sleep 0.1
cap gum-multi-before-confirm
pad tap BTN_SOUTH
wait_pane "GUM2:0" 20
emit "gum_multi_exit0=$((1 - $?))"
emit "gum_multi_choice=$(tr '\n' ',' </root/gum-multi.out 2>/dev/null)"

# stick navigation instead of hat: hold past threshold; engage + auto-repeat
# must advance the cursor several rows
# EIGHT items, deliberately: gum's list WRAPS, and an earlier version of this
# test used four -- engage + 3 auto-repeats = 4 moves = exactly one full
# cycle back to R1, which read as "the stick did nothing" while the mapper
# was working perfectly. The list must be longer than any plausible number
# of repeats in the hold window.
fresh_window 'gum choose R1 R2 R3 R4 R5 R6 R7 R8 >/root/gum-stick.out; echo GUM3:$?; exec bash --norc'
wait_pane "^> .*R1" 60
emit "gum_stick_menu_up=$((1 - $?))"
pad abs Y 30000; pad sleep 0.8; pad abs Y 0; pad sleep 0.2
cap gum-stick-before-confirm
pad tap BTN_SOUTH
wait_pane "GUM3:0" 20
emit "gum_stick_exit0=$((1 - $?))"
emit "gum_stick_choice=$(tr -d '\n' </root/gum-stick.out 2>/dev/null)"
# Distance, not just inequality: >= 2 rows proves the engage AND at least one
# auto-repeat fired, which is the property that makes long lists navigable.
stick_pick=$(tr -d '\n' </root/gum-stick.out 2>/dev/null)
stick_rows=$(( ${stick_pick#R} - 1 ))
emit "gum_stick_rows_moved=${stick_rows}"
emit "gum_stick_moved=$([[ -n $stick_pick && $stick_rows -ge 2 ]] && echo 1 || echo 0)"

# --- 4. archinstall's curses menu -------------------------------------------
# NO stderr redirect: archinstall draws its TUI on stderr. Redirecting it
# steals the display into a file (verified: the escape stream, title bar and
# all, ended up in archinstall.err on this suite's second run).
fresh_window 'archinstall; echo AI:$?; exec bash --norc'
# First it fetches the package database (can take a minute over NAT), THEN
# the menu renders.
if wait_pane "[Ll]anguage\|[Mm]irror\|[Dd]isk config\|[Pp]rofile" 360; then
  emit "ai_menu_rendered=1"
  sleep 2   # let the menu finish drawing before the before-hash
  cap ai-main
  # Enter opens the first item's submenu; the screen must change.
  before=$(tmux capture-pane -pt spike | sha256sum | cut -d' ' -f1)
  pad tap BTN_SOUTH; sleep 2
  after=$(tmux capture-pane -pt spike | sha256sum | cut -d' ' -f1)
  cap ai-submenu
  emit "ai_enter_changes_screen=$([[ $before != "$after" ]] && echo 1 || echo 0)"
  # Esc returns to the main menu; the screen must change again.
  pad tap BTN_EAST; sleep 2
  back=$(tmux capture-pane -pt spike | sha256sum | cut -d' ' -f1)
  cap ai-back
  emit "ai_esc_changes_screen=$([[ $after != "$back" ]] && echo 1 || echo 0)"
  # Arrow navigation changes the highlighted row (SGR attributes differ even
  # when the text layout is identical).
  b_attr=$(tmux capture-pane -pet spike | sha256sum | cut -d' ' -f1)
  pad hat Y 1; pad sleep 0.15; pad hat Y 0; sleep 1
  a_attr=$(tmux capture-pane -pet spike | sha256sum | cut -d' ' -f1)
  cap ai-after-down
  emit "ai_down_moves_selection=$([[ $b_attr != "$a_attr" ]] && echo 1 || echo 0)"
else
  emit "ai_menu_rendered=0"
  cap ai-failed
fi

kill "$MAPPER_PID" "$PAD_PID" "$WITNESS_PID" 2>/dev/null
  emit "done=1"
  exit 0
fi

# --- 3. gum choose -----------------------------------------------------------
tmux send-keys -t spike "gum choose Alpha Beta Gamma >/root/gum-single.out; echo GUM1:\$? " Enter
wait_pane "^> Alpha" 40   # the RENDERED pointer -- "Gamma" would match the echoed command line before gum is even up
pad hat Y 1; pad sleep 0.15; pad hat Y 0; pad sleep 0.1
pad hat Y 1; pad sleep 0.15; pad hat Y 0; pad sleep 0.1
cap gum-before-confirm
pad tap BTN_SOUTH
wait_pane "GUM1:0" 20
emit "gum_single_exit0=$((1 - $?))"
emit "gum_single_choice=$(tr -d '\n' </root/gum-single.out 2>/dev/null)"

resync
# multi-select: down, toggle (Y->Space), down, toggle, confirm
tmux send-keys -t spike "gum choose --no-limit One Two Three >/root/gum-multi.out; echo GUM2:\$? " Enter
wait_pane "^> " 40
pad hat Y 1; pad sleep 0.15; pad hat Y 0; pad sleep 0.1
pad tap BTN_WEST; pad sleep 0.1
pad hat Y 1; pad sleep 0.15; pad hat Y 0; pad sleep 0.1
pad tap BTN_WEST; pad sleep 0.1
cap gum-multi-before-confirm
pad tap BTN_SOUTH
wait_pane "GUM2:0" 20
emit "gum_multi_exit0=$((1 - $?))"
emit "gum_multi_choice=$(tr '\n' ',' </root/gum-multi.out 2>/dev/null)"

resync
# stick navigation instead of hat: hold past threshold long enough to repeat
tmux send-keys -t spike "gum choose R1 R2 R3 R4 >/root/gum-stick.out; echo GUM3:\$? " Enter
wait_pane "^> R1" 40
pad abs Y 30000; pad sleep 0.8; pad abs Y 0; pad sleep 0.2   # >= 1 engage + repeats
cap gum-stick-before-confirm
pad tap BTN_SOUTH
wait_pane "GUM3:0" 20
emit "gum_stick_exit0=$((1 - $?))"
emit "gum_stick_choice=$(tr -d '\n' </root/gum-stick.out 2>/dev/null)"
# Distance, not just inequality: >= 2 rows proves the engage AND at least one
# auto-repeat fired, which is the property that makes long lists navigable.
stick_pick=$(tr -d '\n' </root/gum-stick.out 2>/dev/null)
stick_rows=$(( ${stick_pick#R} - 1 ))
emit "gum_stick_rows_moved=${stick_rows}"
emit "gum_stick_moved=$([[ -n $stick_pick && $stick_rows -ge 2 ]] && echo 1 || echo 0)"

# --- 4. archinstall's curses menu -------------------------------------------
resync
tmux send-keys -t spike "archinstall 2>/root/archinstall.err; echo AI:\$?" Enter
# First it fetches the package database (can take a minute over NAT), THEN
# the menu renders. "archinstall" would match the echoed command itself.
if wait_pane "[Ll]anguage\|[Mm]irror\|[Dd]isk config\|[Pp]rofile" 360; then
  emit "ai_menu_rendered=1"
  sleep 2   # let the menu finish drawing before the before-hash
  cap ai-main
  # Enter opens the first item's submenu; the screen must change.
  before=$(tmux capture-pane -pt spike | sha256sum | cut -d' ' -f1)
  pad tap BTN_SOUTH; sleep 1.5
  after=$(tmux capture-pane -pt spike | sha256sum | cut -d' ' -f1)
  cap ai-submenu
  emit "ai_enter_changes_screen=$([[ $before != "$after" ]] && echo 1 || echo 0)"
  # Esc returns to the main menu; the screen must change again.
  pad tap BTN_EAST; sleep 1.5
  back=$(tmux capture-pane -pt spike | sha256sum | cut -d' ' -f1)
  cap ai-back
  emit "ai_esc_changes_screen=$([[ $after != "$back" ]] && echo 1 || echo 0)"
  # Arrow navigation changes the highlighted row (SGR attributes differ even
  # when the text layout is identical).
  b_attr=$(tmux capture-pane -pet spike | sha256sum | cut -d' ' -f1)
  pad hat Y 1; pad sleep 0.15; pad hat Y 0; sleep 0.7
  a_attr=$(tmux capture-pane -pet spike | sha256sum | cut -d' ' -f1)
  cap ai-after-down
  emit "ai_down_moves_selection=$([[ $b_attr != "$a_attr" ]] && echo 1 || echo 0)"
else
  emit "ai_menu_rendered=0"
  cap ai-failed
  emit "ai_err=$(head -c 400 /root/archinstall.err 2>/dev/null | tr '\n' ' ')"
fi

kill "$MAPPER_PID" "$PAD_PID" 2>/dev/null
emit "done=1"
PROBE

unit_text="[Unit]
Description=T2 gamepad spike probe
After=network-online.target
Wants=network-online.target
Before=graphical.target

[Service]
Type=oneshot
ExecStartPre=/usr/bin/cp /boot/omarchy-deck-spike-probe.sh /root/omarchy-deck-spike-probe.sh
ExecStartPre=/usr/bin/cp /boot/deck-input-mapper.py /root/deck-input-mapper.py
ExecStartPre=/usr/bin/cp /boot/vm-spike-pad.py /root/vm-spike-pad.py
ExecStart=/usr/bin/bash /root/omarchy-deck-spike-probe.sh
TimeoutStartSec=0
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console
"
dropin_text="[Unit]
Wants=omarchy-deck-spike.service
"

log "writing payload onto the guest ESP (rootless, mtools at byte offset)"
esp_offset=$(disk_image::esp_offset "$disk") || fail "could not locate the ESP on $disk"
for f in "$SELF_DIR/deck-input-mapper.py" "$pad_src" "$probe_src"; do
  MTOOLS_SKIP_CHECK=1 mcopy -o -i "${disk}@@${esp_offset}" "$f" "::/${f##*/}" ||
    fail "mcopy of ${f##*/} onto the ESP failed"
done

cred_unit="io.systemd.credential.binary:systemd.extra-unit.omarchy-deck-spike.service=$(base64 -w0 <<<"$unit_text")"
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

check "network_resolved"     "$(field network_resolved)" 1
check "pkgs_installed"       "$(field pkgs_installed)" 1
check "uinput_node"          "$(field uinput_node)" 1
check "pad_created"          "$(field pad_created)" 1
check "mapper_attached"      "$(field mapper_attached)" 1
check "virtual_kb_exists"    "$(field virtual_kb_exists)" 1
check "tmux_up"              "$(field tmux_up)" 1
check "vt2_active"           "$(field vt2_active)" 1
check "tmux_client_attached" "$(field tmux_client_attached)" 1
check "chain_sanity"         "$(field chain_sanity)" 1

check "gum_single_menu_up"   "$(field gum_single_menu_up)" 1
check "gum_single_exit0"     "$(field gum_single_exit0)" 1
check "gum_single_choice"    "$(field gum_single_choice)" "Gamma"
check "gum_multi_menu_up"    "$(field gum_multi_menu_up)" 1
check "gum_multi_exit0"      "$(field gum_multi_exit0)" 1
check "gum_multi_choice"     "$(field gum_multi_choice)" "Two,Three,"
check "gum_stick_menu_up"    "$(field gum_stick_menu_up)" 1
check "gum_stick_exit0"      "$(field gum_stick_exit0)" 1
check "gum_stick_moved"      "$(field gum_stick_moved)" 1
log "     (stick advanced $(field gum_stick_rows_moved) rows on one hold — engage + auto-repeat)"

check "ai_menu_rendered"        "$(field ai_menu_rendered)" 1
check "ai_enter_changes_screen" "$(field ai_enter_changes_screen)" 1
check "ai_esc_changes_screen"   "$(field ai_esc_changes_screen)" 1
check "ai_down_moves_selection" "$(field ai_down_moves_selection)" 1

if [[ $status -eq 0 ]]; then
  log "PASS — a gamepad drives gum (single, multi, stick-with-repeat) and archinstall's menus through the kernel input layer, with no UI-side cooperation"
  rm -rf "$WORK"
else
  log "FAILED — full report: $result_txt (work dir preserved: $WORK)"
fi
exit $status

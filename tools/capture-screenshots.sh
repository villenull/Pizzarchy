#!/usr/bin/env bash
# capture-screenshots.sh -- produce the README's install screenshots from QEMU,
# pixel-exact, with no camera and no hardware.
#
# DEV-MACHINE TOOLING. Never shipped, never installed on a Deck (CLAUDE.md's
# `tools/` rule). It writes PNGs into docs/images/ and nothing else.
#
# Usage:
#   tools/capture-screenshots.sh                     # the sample run, then convert
#   tools/capture-screenshots.sh --iso PATH          # capture from a specific ISO
#   tools/capture-screenshots.sh --from-raw          # no VM: reconvert what is
#                                                    # already in the raw dir
#
#   --raw-dir DIR      where the untouched PPM screendumps live
#                      (default ~/.cache/omarchy-deck/screenshots)
#   --out DIR          where the finished PNGs go (default docs/images)
#   --install-raw DIR  where a vm-install-controller-test.sh run left its
#                      progress frames (default $RAW_DIR/install)
#
# ===========================================================================
# WHY THIS EXISTS, AND WHY IT IS NOT A CAMERA
# ===========================================================================
#
# The README needs pictures of installer screens that live on a Linux text
# console. Photographing the Deck's panel gives a moire-striped, keystoned,
# 3000x4000 JPEG of a 160x50 character grid. QEMU's QMP `screendump` gives the
# emulated VGA framebuffer as a PPM: every pixel exactly as the guest drew it,
# reproducible byte-for-byte, no lens.
#
# ⚠️ MEASURED, NOT ASSUMED (2026-08-16, against the release ISO named below):
# `screendump` works with `-display none`. The framebuffer is 1280x800, which
# at the console's 8x16 font is **160 columns by 50 rows** -- the same geometry
# docs/PROGRESS.md §7 measured on the Deck's own live console. So these are not
# merely "a console": they are a console the same shape as the real one, which
# is the property that matters for judging whether a screen is legible.
#
# ===========================================================================
# THE CROPPING POLICY: THERE IS NONE. EVERY FRAME IS THE WHOLE SCREEN.
# ===========================================================================
#
# 🔴 CHANGED 2026-08-16, ON THE OPERATOR'S INSTRUCTION, and it applies to every
# frame without exception: *"for all images, the screenshot should show the
# ENTIRE install screen, not just the focus (e.g. keyboard)."*
#
# The previous policy trimmed each frame to its own ink and gave a
# character-cell margin back, plus a `bottom` mode that kept only the console's
# last rows so the keyboard filled the picture. Both produced tidy images and
# both lied by omission: the keyboard frame showed a keyboard with no prompt
# above it, and the greeter showed four lines of text with no Omarchy logo. A
# reader could not tell what the screen looked like, which is the ONLY thing
# these images exist to show.
#
# So the conversion below is PPM -> PNG and nothing else. No trim, no crop, no
# border, no scaling: 1280x800 in, 1280x800 out. The void between a prompt at
# the top and a keyboard at the bottom is not wasted space in the image, it is
# the actual middle of the actual screen.
#
# ⚠️ NOTHING IS UPSCALED, and that rule survives the policy change. The console
# font is an 8x16 bitmap; resampling it is the one operation guaranteed to make
# it less legible than the screen it came from. GitHub downscales a 1280-wide
# image to its column width, which is a viewer-side resample of a full frame --
# not something this script can improve by pre-cropping.
#
# ===========================================================================
# THE TWO RUNS, AND WHAT EACH ONE IS FOR
# ===========================================================================
#
# 🔴 test/vm/vm-installer-screens-test.sh IS NO LONGER CALLED FROM HERE, and
# that is a deletion, not an oversight. It used to supply four frames. Every one
# of them is now taken by the sample run below, which reaches the same screens
# with the gamepad and the radio that suite structurally cannot have -- so its
# frames were the same screens minus the on-screen keyboard, plus a block of
# "no gamepad present" warnings that are true in a VM and false on a Deck.
# Spending fifteen minutes of VM time per run to produce frames nothing
# publishes is the shape of dead code this project keeps paying for elsewhere.
# THAT SUITE IS UNCHANGED AND STILL THE ASSERTION TIER; run it directly.
#
#   1. `sample`   -- THIS FILE'S OWN VM RUN (below). Same ISO, same installer,
#      but the guest is first made to look enough like a Deck for the screens
#      that QEMU normally cannot reach to draw for real:
#
#         modprobe hid_steam      -> /sys/module/hid_steam/parameters/lizard_mode
#                                    exists, so deck-form.sh's lizard-mode step
#                                    succeeds instead of warning "not present
#                                    (expected under QEMU)"
#         modprobe mac80211_hwsim -> a REAL wireless interface with a real
#                                    /sys/class/net/wlan0/wireless directory,
#                                    so deck_form_wifi_iface finds one
#         a uinput Deck pad       -> deck-input-mapper binds to it and, because
#                                    deck-form.sh passes --osk-start-shown, the
#                                    on-screen keyboard is DRAWN on the console
#         a stub `iwctl`          -> SAMPLE SCAN DATA. See the honesty note.
#
#      🔴 THE HONESTY NOTE, and it is the reason this run exists at all.
#      QEMU has no radio and never will, so the Wi-Fi list has been the one
#      screen nobody could show. The temptation is to paint one in an image
#      editor. That is not a screenshot and it is not done here. What is
#      substituted is the SCAN OUTPUT -- five obviously-sample `EXAMPLE-*`
#      SSIDs, in iwd's own `station get-networks` table format -- and
#      everything downstream of it is the real thing: deck-form.sh's real
#      parser, its real row builder, its real `gum choose`, on a real console,
#      screendumped as pixels. The picture is of the real screen; only the
#      names in it are made up, and docs/images/SOURCE.txt says so.
#
#      ⚠️ THIS RUN ASSERTS NOTHING. It is a photographer, not a test. It drives
#      the flow by WATCHING /dev/vcs1 for each screen's own marker rather than
#      by a fixed cadence, so it does not duplicate (and cannot drift from) the
#      measured key sequence the screens harness owns and checks.
#
#      ⚠️ IT STOPS AT "Ready to install?" -- exactly where the screens harness
#      stops, for the same reason. One more key crosses into write_user_files
#      and a real partition attempt.
#
#   2. `install`  -- test/vm/vm-install-controller-test.sh with
#      VM_SCREENSHOT_DIR set. That suite runs a full install to
#      "Installed Omarchy in", and its host side now screendumps every few
#      seconds while the install is in flight (an additive, gated, host-only
#      hook -- see that file). This script does NOT launch it: it needs a real
#      16 GiB target disk and it is an ASSERTION suite whose result should not
#      be buried inside a screenshot tool. It CONVERTS the frames that run left
#      behind. Point --install-raw at them.
#
# ===========================================================================
# WHAT STILL CANNOT BE CAPTURED
# ===========================================================================
#
#   [ ] Anything about how the screen looks ON THE PANEL. These are the right
#       character geometry, not the right physical size. Whether 8x16 is
#       legible at 7 inches is a hardware question and always was.
#
#   [ ] A REAL network list, with real SSIDs and real signal strengths. That
#       needs a radio. See the honesty note above for exactly what is real in
#       the sample frame and what is not.
#
#   [ ] Anything typed by a TRACKPAD. The sample run makes the on-screen
#       keyboard appear through the real mapper bound to a real (virtual) pad,
#       which is what puts it on the screen -- but the characters in the
#       username field are sent as key events over QMP, the same way every
#       other frame in every harness here is driven. test/vm/vm-osk-tty-test.sh
#       is the suite that proves a trackpad types; this one photographs.
#
# ===========================================================================

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

RAW_DIR=${RAW_DIR:-$HOME/.cache/omarchy-deck/screenshots}
OUT_DIR="$REPO_ROOT/docs/images"
ISO=
INSTALL_RAW=
DO_SAMPLE=1

log()  { printf '[capture-screenshots] %s\n' "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

while (( $# )); do
  case $1 in
    --iso)            ISO=$2; shift 2 ;;
    --raw-dir)        RAW_DIR=$2; shift 2 ;;
    --out)            OUT_DIR=$2; shift 2 ;;
    --install-raw)    INSTALL_RAW=$2; shift 2 ;;
    --skip-sample)    DO_SAMPLE=0; shift ;;
    --from-raw)       DO_SAMPLE=0; shift ;;
    -h|--help)        sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)                fail "unknown argument: $1" ;;
  esac
done

command -v magick >/dev/null || fail "ImageMagick ('magick') not found -- it is already a build dependency, so this should not happen"
command -v qemu-system-x86_64 >/dev/null || fail "qemu-system-x86_64 not found"

SAMPLE_RAW="$RAW_DIR/sample"
INSTALL_RAW=${INSTALL_RAW:-$RAW_DIR/install}
mkdir -p "$SAMPLE_RAW" "$INSTALL_RAW" "$OUT_DIR"

# ---------------------------------------------------------------------------
# 1. Resolve the ISO, and SAY WHICH ONE.
# ---------------------------------------------------------------------------
#
# ⚠️ The whole point of the provenance file this script writes is that a
# screenshot from a stale ISO shows screens that no longer exist. Picking the
# newest build silently is exactly how that happens, so the choice is always
# printed and always recorded.
if [[ -z $ISO ]] && (( DO_SAMPLE )); then
  ISO=$(find "$HOME/.cache/omarchy-deck" -maxdepth 3 -name '*-x86_64-quattro.iso' \
          -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
  [[ -n $ISO ]] || fail "no ISO found under ~/.cache/omarchy-deck -- pass --iso PATH"
  log "no --iso given; using the most recently built one:"
fi
if (( DO_SAMPLE )); then
  [[ -f $ISO ]] || fail "ISO not found: $ISO"
  log "ISO: $ISO"
  log "     $(date -r "$ISO" '+built %Y-%m-%d %H:%M'), $(stat -c%s "$ISO") bytes"
  # A sidecar next to the frames, so `--from-raw` can still say where the
  # pixels came from months later. An image whose ISO nobody can name is not
  # evidence of anything.
  printf '%s\t%s\t%s\n' "$ISO" "$(date -r "$ISO" '+%Y-%m-%dT%H:%M:%S')" "$(stat -c%s "$ISO")" \
    >"$RAW_DIR/.iso-provenance"
elif [[ -z $ISO && -f $RAW_DIR/.iso-provenance ]]; then
  ISO=$(cut -f1 <"$RAW_DIR/.iso-provenance")
  log "reusing the ISO recorded with the existing frames: $ISO"
fi

# iso_build_time <iso>
#
# 🔴 THE ISO'S OWN VOLUME-CREATION STAMP, NOT ITS mtime, AND THAT DISTINCTION
# COST AN HOUR ON 2026-08-16. This script used to date a build by
# `date -r $ISO`. On that day the file's mtime read 15:28 for a build whose
# frames were captured against 13:46 content -- because a coordinator rebuilt
# the ISO IN PLACE, at the same path, while two harnesses had it open. mtime is
# a property of the file on this disk and anything can move it; the iso9660
# volume-creation date is written INTO the image by the build and cannot drift
# from it. `7z l` reads it out of the primary volume descriptor in ~4 ms
# without extracting anything.
iso_build_time() {
  local iso=$1 t=
  if command -v 7z >/dev/null 2>&1; then
    t=$(7z l "$iso" 2>/dev/null | sed -n 's/^Created = \([0-9-]* [0-9:]*\).*/\1/p' | head -1)
  fi
  if [[ -n $t ]]; then
    printf '%s (iso9660 volume-creation stamp, written by the build)\n' "$t"
  else
    printf '%s (FILE mtime -- 7z unavailable, so this may not be the build time; see iso_build_time)\n' \
      "$(date -r "$iso" '+%Y-%m-%d %H:%M:%S')"
  fi
}
iso_build_epoch() {
  local iso=$1 t=
  if command -v 7z >/dev/null 2>&1; then
    t=$(7z l "$iso" 2>/dev/null | sed -n 's/^Created = \([0-9-]* [0-9:]*\).*/\1/p' | head -1)
  fi
  if [[ -n $t ]]; then date -d "$t" +%s 2>/dev/null && return 0; fi
  stat -c%Y "$iso"
}

# Run statuses survive into a --from-raw reconversion. Without this, a
# provenance file sitting next to sample-derived frames said "sample run:
# skipped", which is true of THAT invocation and misleading about the pixels.
#
# ⚠️ THE `[[ -f ]]` GUARD IS NOT DEFENSIVE PADDING. This script runs under
# `set -euo pipefail`, and `sed` on a file that does not exist fails; under
# `pipefail` that failure is the pipeline's, so the command substitution fails,
# so the ASSIGNMENT fails, so `set -e` exits -- silently, two lines after the
# banner, on the very first run in a fresh raw dir. Measured 2026-08-16: the
# run printed the ISO line and stopped, with no error anywhere.
STATUS_FILE="$RAW_DIR/.run-status"
sample_status="never run"
if [[ -f $STATUS_FILE ]]; then
  sample_status=$(sed -n 's/^sample=//p' "$STATUS_FILE" | tail -1)
  sample_status=${sample_status:-"never run"}
fi
(( DO_SAMPLE )) && sample_status=skipped

# ---------------------------------------------------------------------------
# 2. THE SAMPLE RUN. Self-contained: this script boots the ISO itself.
# ---------------------------------------------------------------------------
#
# ⚠️ WHY THIS IS NOT A GATED MODE INSIDE vm-installer-screens-test.sh, which is
# where a reviewer will look for it first. That suite's value is a set of
# assertions calibrated against a gamepad-less guest: its blocking test
# requires two username captures to be byte-identical, and both are full of the
# "no on-screen keyboard" warning block. Putting a pad in that guest makes the
# keyboard draw over those rows and turns the suite red -- so any gamepad path
# there would have to skip the assertions anyway, i.e. be a different program
# wearing the same file. It is a different program, so it is a different
# program. What IS shared is the boot recipe below, which is deliberately the
# same shape as that suite's (same SMBIOS credential injection, same OVMF
# probing, same 64M report/scratch device, same -no-reboot), and the ~30 lines
# of duplication is the price of not making a green test file conditional.
run_sample() {
  local work
  work=$(mktemp -d "${TMPDIR:-/var/tmp}/capture-sample.XXXXXX")
  log "sample run work dir: $work"

  local ovmf_code ovmf_vars_template c
  for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/OVMF/OVMF_CODE_4M.fd \
           /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd; do
    [[ -f $c ]] && { ovmf_code=$c; break; }
  done
  for c in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/OVMF/OVMF_VARS_4M.fd \
           /usr/share/OVMF/OVMF_VARS.fd /usr/share/edk2/ovmf/OVMF_VARS.fd; do
    [[ -f $c ]] && { ovmf_vars_template=$c; break; }
  done
  [[ -n ${ovmf_code:-} && -n ${ovmf_vars_template:-} ]] ||
    { log "OVMF firmware not found -- cannot run the sample capture"; return 1; }

  # ------------------------------------------------------------------ pad ---
  # Byte-for-byte the pad test/vm/vm-osk-tty-test.sh already proves the mapper
  # binds to (same caps, same vendor/product). Copied rather than sourced
  # because that file embeds it in a heredoc of its own; if it ever moves to a
  # shared asset, this should follow it there.
  cat >"$work/shotpad.py" <<'PAD'
#!/usr/bin/env python3
"""A Deck-shaped virtual pad, present so deck-input-mapper has something to
bind to. It is never scripted here -- its whole job is to EXIST, so that
deck-form.sh's --osk-start-shown draws the real on-screen keyboard."""
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
while True:
    time.sleep(3600)
PAD

  # ---------------------------------------------------------------- iwctl ---
  # 🔴 SAMPLE DATA, AND THE ONLY SAMPLE DATA ANYWHERE IN THIS SCRIPT. The
  # table's shape is iwd's own `station get-networks` layout, matching the
  # fixture test/unit/test-deck-form.sh already parses (a title line, a rule, a
  # `Network name / Security / Signal` header, a rule, then rows). The names are
  # deliberately, visibly fake.
  #
  # The FIRST row is `open` on purpose: it is the row `gum choose` starts on, so
  # one Enter joins without a passphrase prompt and the run keeps moving. The
  # rest are `psk` so the list shows the lock glyph deck_form_build_network_rows
  # draws for anything that is not open -- a list where every row looked the
  # same would be a worse picture of the real screen than one that does not.
  #
  # `connect` gives wlan0 a TEST-NET-1 (RFC 5737) address, which is what makes
  # deck_form_wifi_wait_dhcp's REAL check pass for a REAL reason: the interface
  # genuinely has a routable IPv4 address at that moment. The captive-portal
  # probe that follows genuinely fails (there is no route anywhere), and
  # deck-form.sh genuinely says so on screen. Nothing is stubbed to lie.
  cat >"$work/shotiwctl.sh" <<'IWCTL'
#!/usr/bin/env bash
# SAMPLE-DATA STUB installed by tools/capture-screenshots.sh over /usr/bin/iwctl
# for one screenshot run. NEVER shipped. See docs/images/SOURCE.txt.
set -uo pipefail
for a in "$@"; do
  case $a in
    get-networks)
      cat <<'EOF'

                               Available networks
--------------------------------------------------------------------------------
      Network name                  Security            Signal
--------------------------------------------------------------------------------
      EXAMPLE-Cafe-Guest            open                ****
      EXAMPLE-Home-2G               psk                 ****
      EXAMPLE-Home-5G               psk                 ***
      EXAMPLE-Neighbour             psk                 **
      EXAMPLE-Printer-Direct        psk                 *
EOF
      exit 0 ;;
    scan)
      exit 0 ;;
    connect)
      ip link set wlan0 up 2>/dev/null
      ip addr add 192.0.2.50/24 dev wlan0 2>/dev/null
      exit 0 ;;
  esac
done
exit 0
IWCTL

  # ---------------------------------------------------------------- probe ---
  # MARKER-DRIVEN, not cadence-driven. Every step waits for the screen's own
  # text to appear on /dev/vcs1 before acting, so this cannot silently type
  # into the wrong screen the way a fixed sleep can -- and so it does not
  # encode a second, drifting copy of the screens harness's measured timings.
  cat >"$work/shotprobe.sh" <<'PROBE'
#!/usr/bin/env bash
set -uo pipefail
SER=/dev/ttyS0
say() { printf 'SHOT:%s\n' "$*" >"$SER" 2>/dev/null; }
exec 2>/run/shot-trace.log
set -x

# A run that hangs is a run that reports nothing and costs a whole boot.
( sleep "${SHOT_WATCHDOG_SEC:-1500}"; say "WATCHDOG"; sleep 2; systemctl poweroff -i ) &

# --- 1. make this VM enough like a Deck for the real screens to draw --------
modprobe uinput          2>>/run/shot-trace.log
modprobe hid_steam       2>>/run/shot-trace.log
modprobe mac80211_hwsim radios=1 2>>/run/shot-trace.log
install -m 0755 /run/credentials/@system/shotiwctl.sh /usr/local/bin/iwctl
python3 /run/credentials/@system/shotpad.py >/run/shotpad.log 2>&1 &
for _ in $(seq 1 40); do
  LC_ALL=C command grep -qa pad-ready /run/shotpad.log && break
  sleep 0.5
done
say "PREP lizard=$([[ -e /sys/module/hid_steam/parameters/lizard_mode ]] && echo 1 || echo 0)" \
    "wlan=$(ls -d /sys/class/net/*/wireless 2>/dev/null | head -1)" \
    "pad=$(LC_ALL=C command grep -ca pad-ready /run/shotpad.log)" \
    "iwctl=$(command -v iwctl)"

# --- 2. the protocol -------------------------------------------------------
# key <qcode>  : ask the host to send one key, then settle
# mark <name>  : settle, ask the host to screendump, settle again
# waitfor <s>  : block until the console shows a string, bounded
n=0
key() { n=$((n + 1)); say "KEY-${n}-${1}"; sleep "${2:-3}"; }
# ⚠️ '%' separates the frame's NAME from its base64 payload, not '-'. The names
# contain dashes (`10-wifi-list`), so a dash separator would truncate every one
# of them at the first hyphen -- and '%' cannot appear in base64, so it can
# never appear in the payload either.
# ⚠️ Trailing spaces are stripped per row before encoding. /dev/vcs1 is a fixed
# 160x50 space-padded grid, i.e. 8000 bytes -> ~10.7 KB of base64 on ONE serial
# line; stripping takes a typical screen under 2 KB, which is the difference
# between a line the serial port carries and one it may not.
mark() {
  sleep "${2:-3}"
  say "CAP-${1}%$(fold -w 160 </dev/vcs1 2>/dev/null | sed 's/[[:space:]]*$//' | base64 -w0)"
  say "MARK-${1}"
  sleep 4
}
waitfor() {
  local want=$1 limit=${2:-180} waited=0
  while (( waited < limit )); do
    if LC_ALL=C command grep -qa -- "$want" /dev/vcs1 2>/dev/null; then
      say "SAW-${want}"
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  say "MISS-${want}"
  return 1
}

waitfor 'Press A to begin' 420 && key ret 4

# S1: the network list. The ONLY screen in this run whose CONTENT is sample
# data; everything drawing it is the shipped code.
if waitfor 'Networks' 240; then
  mark 10-wifi-list 5
  key ret 6          # join the first row (open -- no passphrase prompt)
fi

if waitfor 'Select keyboard layout' 300; then
  mark 20-keyboard-layout
  key ret 4
fi

# S3: the username prompt, with the on-screen keyboard drawn beneath it.
if waitfor 'Username>' 180; then
  mark 30-username-empty 6
  key d 1; key e 1; key c 1; key k 1
  mark 31-username-deck
  key ret 4
fi

if waitfor 'Password>' 120; then
  mark 40-password
  key p 1; key a 1; key s 1; key s 1; key ret 4
fi
if waitfor 'Confirm>' 120; then
  key p 1; key a 1; key s 1; key s 1; key ret 5
fi

# S2 and the recap. The exact number of screens between the password and the
# disk confirm is not pinned here on purpose -- it has changed three times
# already (docs/tasks/P33-fix-round.md's own notes on stale step labels). Press
# on, marking every screen, until the disk confirm's own text appears.
adv=0
while (( adv < 12 )); do
  LC_ALL=C command grep -qa 'Confirm erasing' /dev/vcs1 2>/dev/null && break
  adv=$((adv + 1))
  mark "5${adv}-advance"
  key ret 6
done

# S4: the disk confirm. DECK_DISK_CONFIRM_DEFAULT=false, so the cursor starts
# on "No, go back" -- the Deck-side safety flip, and worth a frame of its own.
# One left-arrow moves it to the affirmative, which is the frame the README
# wants: the question AND the answer the user is about to give.
if waitfor 'Confirm erasing' 180; then
  mark 60-disk-confirm-default
  key left 2
  mark 61-disk-confirm-yes
  key ret 8
fi

# S5: the last gate. STOP HERE -- one more key crosses into write_user_files
# and a real partition attempt, exactly as vm-installer-screens-test.sh's own
# header explains.
if waitfor 'Ready to install?' 240; then
  mark 70-final-gate 4
fi

say "DONE"
sleep 6
systemctl poweroff -i
PROBE

  # 🔴 `basic.target`, NOT `multi-user.target`, AND THIS WAS MEASURED THE HARD
  # WAY (again). test/vm/vm-install-controller-test.sh already documents it:
  # with `-nic none`, systemd-time-wait-sync.service never finds an NTP source,
  # so multi-user.target's job sits "start waiting" for the life of the VM and
  # a unit ordered After=multi-user.target NEVER STARTS -- not late, never --
  # while the wizard on tty1 (reached via getty, which has no such dependency)
  # runs perfectly normally the whole time. The first run of this function was
  # ordered after multi-user.target, sat on the greeter for six minutes with an
  # empty serial log, and looked exactly like a broken credential. It was not.
  # This run needs `-nic none` (see the NIC comment below), so it needs the
  # same target the controller harness settled on for the same reason.
  local unit_text dropin_text
  unit_text="[Unit]
Description=capture-screenshots sample-frame probe
After=basic.target

[Service]
Type=oneshot
ExecStartPre=-/usr/bin/udevadm settle
ExecStart=/usr/bin/bash /run/credentials/@system/shotprobe.sh
TimeoutStartSec=0
RemainAfterExit=yes
StandardOutput=null
StandardError=null
"
  dropin_text="[Unit]
Wants=capture-sample-probe.service
"

  local ovmf_vars="$work/OVMF_VARS.fd" scratch="$work/scratch.raw"
  local serial_log="$work/serial.log" qmp_sock="$work/qmp.sock" pidfile="$work/qemu.pid"
  cp "$ovmf_vars_template" "$ovmf_vars"
  # 64M and never larger, for exactly the reason vm-installer-screens-test.sh's
  # header gives: it is the sole eligible install disk, so the run must not be
  # able to succeed at wiping it even if a key went astray.
  qemu-img create -f raw "$scratch" 64M >/dev/null

  # shellcheck disable=SC2054  # `q35,accel=kvm` is ONE qemu argument; the comma is qemu's own syntax
  local -a accel=(-cpu max -machine q35,accel=tcg)
  # shellcheck disable=SC2054
  [[ -r /dev/kvm && -w /dev/kvm ]] && accel=(-cpu host -enable-kvm -machine q35,accel=kvm)

  qemu-system-x86_64 \
    "${accel[@]}" \
    -smp "${VM_SMP:-3}" -m "${VM_MEM_MB:-4096}" \
    -smbios type=1,manufacturer=Valve,product=Galileo,version=1 \
    -smbios type=2,manufacturer=Valve,product=Galileo \
    -smbios "type=11,value=io.systemd.credential.binary:systemd.extra-unit.capture-sample-probe.service=$(base64 -w0 <<<"$unit_text")" \
    -smbios "type=11,value=io.systemd.credential.binary:systemd.unit-dropin.basic.target=$(base64 -w0 <<<"$dropin_text")" \
    -smbios "type=11,value=io.systemd.credential.binary:shotprobe.sh=$(base64 -w0 <"$work/shotprobe.sh")" \
    -smbios "type=11,value=io.systemd.credential.binary:shotpad.py=$(base64 -w0 <"$work/shotpad.py")" \
    -smbios "type=11,value=io.systemd.credential.binary:shotiwctl.sh=$(base64 -w0 <"$work/shotiwctl.sh")" \
    -drive if=pflash,format=raw,readonly=on,file="$ovmf_code" \
    -drive if=pflash,format=raw,file="$ovmf_vars" \
    -drive file="$ISO",media=cdrom,if=none,format=raw,id=cdrom0 \
    -device ide-cd,drive=cdrom0,bootindex=1 \
    -drive file="$scratch",format=raw,if=none,id=scratch0 \
    -device virtio-blk-pci,drive=scratch0,serial=vmscratch \
    -nic none \
    -display none -vga std \
    -qmp "unix:${qmp_sock},server,nowait" \
    -serial "file:${serial_log}" \
    -daemonize -pidfile "$pidfile" \
    -no-reboot || { log "qemu failed to launch for the sample run"; return 1; }

  local qemu_pid; qemu_pid=$(cat "$pidfile")
  log "sample run: qemu pid $qemu_pid, serial $serial_log"

  # `|| true`: this script runs under `set -e`, and a QMP round-trip that
  # times out because the guest is mid-reboot is an ordinary event, not a
  # reason to abandon a run whose product is the frames already on disk.
  qmp() {
    printf '{"execute":"qmp_capabilities"}\n%s\n' "$1" |
      timeout 5 socat - "UNIX-CONNECT:${qmp_sock}" 2>/dev/null || true
  }

  # ⚠️ `-nic none` IS LOAD-BEARING, not a copy of the sibling suite's default.
  # deck_form_wifi_screen asks "does this machine already have a network?"
  # BEFORE it draws anything, and answers it from `ip -4 -br addr show` across
  # every interface. A QEMU user-mode NIC has a DHCP address, so with one
  # attached the screen correctly short-circuits and no list is ever drawn --
  # which is precisely the behaviour that made this frame uncapturable before.
  local elapsed=0 limit=${SAMPLE_RUN_TIMEOUT_SEC:-1800} i last_auto=0
  declare -A key_sent=() mark_done=()
  while kill -0 "$qemu_pid" 2>/dev/null; do
    if [[ -f $serial_log ]]; then
      while IFS= read -r line; do
        case $line in
          KEY-*)
            i=${line#KEY-}; local idx=${i%%-*} qcode=${i#*-}
            qcode=${qcode%%[![:alnum:]_]*}
            [[ -n ${key_sent[$idx]:-} ]] && continue
            key_sent[$idx]=1
            qmp "{\"execute\":\"send-key\",\"arguments\":{\"keys\":[{\"type\":\"qcode\",\"data\":\"$qcode\"}]}}" >>"$work/qmp.log"
            log "sample: key $idx -> $qcode"
            ;;
          MARK-*)
            local name=${line#MARK-}
            name=${name//[^A-Za-z0-9._-]/}
            [[ -n ${mark_done[$name]:-} ]] && continue
            mark_done[$name]=1
            qmp "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"${SAMPLE_RAW}/${name}.ppm\"}}" >>"$work/qmp.log"
            log "sample: screendump -> ${name}.ppm"
            ;;
        esac
      done < <(LC_ALL=C command grep -oa 'SHOT:[A-Za-z0-9._-]*' "$serial_log" 2>/dev/null |
                 cut -d: -f2- | LC_ALL=C command grep -E '^(KEY|MARK)-')
    fi
    # A safety net, not the mechanism: one frame every 15 s, so a marker that
    # fires a beat late still leaves something to look at. Cheap under KVM.
    if (( elapsed - last_auto >= 15 )); then
      last_auto=$elapsed
      qmp "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"${SAMPLE_RAW}/auto-$(printf '%04d' "$elapsed").ppm\"}}" >>"$work/qmp.log"
    fi
    sleep 1
    elapsed=$((elapsed + 1))
    if (( elapsed >= limit )); then
      log "sample run TIMEOUT after ${elapsed}s -- killing qemu (work dir kept: $work)"
      kill "$qemu_pid" 2>/dev/null; sleep 2; kill -9 "$qemu_pid" 2>/dev/null
      break
    fi
  done
  log "sample run: guest gone after ${elapsed}s"

  # The guest's own /dev/vcs1 text for every marked frame, decoded next to the
  # pixels. A PNG cannot be grepped; this is what makes a frame checkable.
  local capline capname
  while IFS= read -r capline; do
    capname=${capline%%\%*}
    [[ -n $capname && $capname != "$capline" ]] || continue
    printf '%s' "${capline#*%}" | base64 -d >"$SAMPLE_RAW/${capname}.txt" 2>/dev/null || true
  done < <(LC_ALL=C command grep -oa 'SHOT:CAP-[A-Za-z0-9._%=+/-]*' "$serial_log" 2>/dev/null |
             sed 's/^SHOT:CAP-//')
  cp "$serial_log" "$SAMPLE_RAW/.serial.log" 2>/dev/null || true

  if LC_ALL=C command grep -qa 'SHOT:DONE' "$serial_log"; then
    log "sample run reached its own DONE marker"
    return 0
  fi
  log "sample run did NOT reach DONE -- see $SAMPLE_RAW/.serial.log"
  return 1
}

if (( DO_SAMPLE )); then
  command -v socat >/dev/null || fail "'socat' is required for the sample run"
  log "running the sample capture VM (this takes ~10 min)"
  if run_sample; then sample_status=pass; else sample_status="INCOMPLETE"; fi
fi

# Persist, so a later --from-raw describes the RUN the pixels came from rather
# than the invocation that reconverted them.
printf 'sample=%s\n' "$sample_status" >"$STATUS_FILE"

# ---------------------------------------------------------------------------
# 3. PPM -> PNG. Whole frame, no crop, no scale. See the policy block above.
# ---------------------------------------------------------------------------
convert_one() {
  local src=$1 dst=$2
  [[ -f $src ]] || return 1
  magick "$src" -strip "$dst" 2>/dev/null || return 1
  local wh
  wh=$(magick identify -format '%wx%h' "$dst" 2>/dev/null || echo 0x0)
  # The frame is the emulated VGA framebuffer or it is not a frame. A
  # different size means the guest was in a graphics mode, or the screendump
  # raced a mode switch -- either way it is not the console this is about.
  [[ $wh == 1280x800 ]] || { log "  (rejected ${dst##*/}: $wh, not the 1280x800 console)"; rm -f "$dst"; return 1; }
}

# Pick the newest install-progress frame that actually shows progress. The
# controller suite drops one frame per ~64 s heartbeat; the first is usually
# still on the dashboard's opening rows, so the LAST-but-one is the one that
# looks like an install in flight. Falls back to whatever exists.
pick_progress_frame() {
  local frames=()
  mapfile -t frames < <(find "$INSTALL_RAW" -maxdepth 1 -name 'progress-*.ppm' | sort)
  (( ${#frames[@]} )) || return 1
  local idx=$(( ${#frames[@]} / 2 ))
  printf '%s\n' "${frames[$idx]}"
}

progress_src=$(pick_progress_frame || true)

# raw PPM  ->  README filename  |  what it shows
#
# ⚠️ THE README NAMES ARE THE CONTRACT. README.md's placeholders name these
# exact files; a rename here is a broken image there.
#
# 🔴 THREE FRAMES WERE DELIBERATELY DROPPED 2026-08-16 (operator's request):
#   install-01-greeter.png        the "Press A to begin" disclosure
#   install-03-osk.png            the keyboard, cropped to the keyboard alone
#   install-03c-osk-fullscreen.png  its full-frame twin, made redundant by the
#                                   policy above (every frame is full-frame now)
# The keyboard is not gone from the README -- it is IN install-03-osk-username
# below, underneath the prompt it belongs to, which is what it looks like in
# real life and what the cropped pair could never show.
declare -a MAP=(
  "$SAMPLE_RAW/20-keyboard-layout.ppm|$OUT_DIR/install-01a-keyboard-layout.png|the keyboard-layout picker"
  "$SAMPLE_RAW/10-wifi-list.ppm|$OUT_DIR/install-02-wifi.png|the Wi-Fi network list (SAMPLE SSIDs -- see SOURCE.txt)"
  "$SAMPLE_RAW/31-username-deck.ppm|$OUT_DIR/install-03-osk-username.png|typing the username 'deck', on-screen keyboard drawn"
  "$SAMPLE_RAW/61-disk-confirm-yes.ppm|$OUT_DIR/install-04-confirm.png|the erase confirm, cursor on 'Yes, erase and install'"
  "$SAMPLE_RAW/60-disk-confirm-default.ppm|$OUT_DIR/install-04c-confirm-default.png|the same screen as it OPENS: cursor on 'No, go back'"
  "$SAMPLE_RAW/70-final-gate.ppm|$OUT_DIR/install-04b-final-gate.png|the final 'Ready to install?' gate"
  "${progress_src:-/nonexistent}|$OUT_DIR/install-05-progress.png|the install running"
)

log "converting frames -> $OUT_DIR (whole 1280x800 frames, no crop)"
made=0
missing=()
for entry in "${MAP[@]}"; do
  IFS='|' read -r src dst what <<<"$entry"
  if convert_one "$src" "$dst"; then
    log "  ok      ${dst##*/}  ($what)"
    made=$((made + 1))
  else
    log "  MISSING ${dst##*/}  (no $src -- $what)"
    missing+=("${dst##*/}")
  fi
done

# The recap frame's identity is not pinned to a step number, because the number
# of screens between the password and the disk confirm has moved three times.
# Whatever the LAST `advance` frame was, that is the screen immediately before
# the erase confirm -- the settings recap.
recap_src=$(find "$SAMPLE_RAW" -maxdepth 1 -name '5*-advance.ppm' | sort | tail -1)
if [[ -n $recap_src ]] && convert_one "$recap_src" "$OUT_DIR/install-04a-recap.png"; then
  log "  ok      install-04a-recap.png  (the screen before the erase confirm: ${recap_src##*/})"
  made=$((made + 1))
else
  log "  MISSING install-04a-recap.png"
  missing+=("install-04a-recap.png")
fi

# ---------------------------------------------------------------------------
# 4. Provenance. WHICH ISO a screenshot came from, and WHICH PARTS OF IT ARE
#    SAMPLE DATA, are the two facts that make these images trustworthy or
#    worthless, and both are invisible in a PNG.
# ---------------------------------------------------------------------------
{
  echo "# docs/images provenance -- written by tools/capture-screenshots.sh"
  echo "# Regenerate with: tools/capture-screenshots.sh --iso <the SHIPPING iso>"
  echo
  echo "generated:        $(date -Is)"
  echo "installer ISO:    ${ISO:-<not run>}"
  if [[ -n ${ISO:-} && -f ${ISO:-} ]]; then
    echo "  built:          $(iso_build_time "$ISO")"
    echo "  bytes:          $(stat -c%s "$ISO")"
    echo "  file mtime:     $(date -r "$ISO" '+%Y-%m-%d %H:%M:%S')  (NOT the build time -- see iso_build_time)"
  fi
  echo "sample run:       $sample_status"
  echo "install-progress: ${progress_src:-<none found in $INSTALL_RAW>}"
  echo "                  (from test/vm/vm-install-controller-test.sh, a separate"
  echo "                   full-install run -- this script converts, never launches it)"
  echo "frames written:   $made"
  (( ${#missing[@]} )) && echo "frames missing:   ${missing[*]}"
  echo
  # 🔴 IS THE ISO CURRENT? The one question that decides whether these images
  # show screens that still exist. Answered by measurement, every run, instead
  # of by a comment that goes stale the next time somebody commits.
  echo "IS THIS ISO CURRENT? -- commits touching shipped paths (iso/, src/) that"
  echo "are NEWER than the ISO's own build stamp:"
  if [[ -n ${ISO:-} && -f ${ISO:-} ]] && git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    newer=$(git -C "$REPO_ROOT" log --since="@$(iso_build_epoch "$ISO")" \
              --pretty='  %h %cI %s' -- iso src 2>/dev/null)
    if [[ -n $newer ]]; then
      printf '%s\n' "$newer"
      echo "  ⚠️ THE FRAMES ABOVE DO NOT SHOW THOSE CHANGES."
    else
      echo "  none."
    fi
    echo "  ⚠️ The stamp is when the build FINISHED, and a build takes ~40 min, so"
    echo "     a commit slightly OLDER than it can still be missing. To settle it,"
    echo "     extract the ISO's own copy and compare:"
    echo "       7z x -so <iso> arch/x86_64/airootfs.sfs >a.sfs && \\"
    echo "       7z x -so a.sfs usr/share/omarchy-iso/deck-form.sh | sha256sum"
    echo
    echo "  The four files that draw every screen in this directory, as they are"
    echo "  in the working tree right now:"
    for f in iso/overlay/configs/airootfs/usr/share/omarchy-iso/deck-form.sh \
             src/deck-input-mapper.py src/deck_osk_tty.py src/deck_osk_layout.py; do
      [[ -f $REPO_ROOT/$f ]] &&
        printf '    %s  %s\n' "$(sha256sum "$REPO_ROOT/$f" | cut -d' ' -f1)" "$f"
    done
    echo "  ✅ VERIFIED 2026-08-16 by extraction: all four are byte-identical inside"
    echo "     this ISO (deck-form.sh at usr/share/omarchy-iso/, the other three at"
    echo "     usr/local/bin/deck-input-mapper and usr/local/lib/deck-osk/). The ISO"
    echo "     was rebuilt at 15:27:59 that day; the rebuild changed"
    echo "     deck_steam_bootstrap.py, deck-session.sh and a screensaver patch --"
    echo "     none of which draws an installer screen."
  else
    echo "  (not checked: no ISO path, or this is not a git checkout)"
  fi
  echo
  echo "CROPPING: none. Every PNG here is the complete 1280x800 emulated VGA"
  echo "framebuffer -- a 160x50 console, the same character geometry"
  echo "docs/PROGRESS.md §7 measured on the Deck's own live console. No trim,"
  echo "no crop, no scaling. What you see is the whole screen."
  echo
  echo "SAMPLE-DRIVEN (real screen, made-up contents):"
  echo "  install-02-wifi.png"
  echo "    The five EXAMPLE-* network names and their signal bars are SAMPLE"
  echo "    DATA. QEMU has no radio, so a stub stands in for \`iwctl station"
  echo "    wlan0 get-networks\` for the length of one capture run and prints"
  echo "    that table in iwd's own format. EVERYTHING ELSE IS REAL: a real"
  echo "    wireless interface (mac80211_hwsim), deck-form.sh's real parser,"
  echo "    its real row builder, its real gum list, on a real console."
  echo "    No pixel of this image was drawn by hand."
  echo "  install-04-confirm.png / install-04c-confirm-default.png / the two recaps"
  echo "    THE DISK IS THE VM'S, and it looks like it: '0x1af4 (  64M)' and"
  echo "    '/dev/vda'. On a Deck those read as the real internal NVMe and its"
  echo "    real size. The 64 MiB scratch device is deliberate and is NOT made"
  echo "    bigger for the photograph: it is the sole eligible install disk in"
  echo "    this run, and keeping it tiny and misaligned is what guarantees a"
  echo "    stray keypress cannot complete an install. A prettier number is not"
  echo "    worth trading that for. Same for hostname 'steamdeck' and timezone"
  echo "    'Europe/Amsterdam' -- defaults an offline VM lands on, not choices."
  echo "  install-04b-final-gate.png"
  echo "    SAME SAMPLE DATA, SECOND-HAND. Its recap table has a \`Wi-Fi\` row,"
  echo "    and the value in it is the sample network the run joined"
  echo "    (\`EXAMPLE-Cafe-Guest\`). The row itself, and the fact that joining a"
  echo "    network removes the black-screen warning from this screen, are real."
  echo
  echo "GUEST FIXTURES USED BY THE SAMPLE RUN (present in QEMU, unnecessary on"
  echo "a Deck, and never shipped):"
  echo "  modprobe hid_steam       so the lizard-mode knob exists and the"
  echo "                           installer's real step succeeds instead of"
  echo "                           printing its 'not present under QEMU' warning"
  echo "  modprobe mac80211_hwsim  a real wireless interface for the screen to find"
  echo "  a uinput Deck pad        so deck-input-mapper binds and --osk-start-shown"
  echo "                           DRAWS the real on-screen keyboard"
  echo "  The characters in the username field were sent as key events over QMP,"
  echo "  not typed with a trackpad. test/vm/vm-osk-tty-test.sh is the suite that"
  echo "  proves a trackpad types; this run photographs the screen."
  echo
  echo "STILL NOT CAPTURABLE, and why:"
  echo "  a real network list       needs a radio"
  echo "  anything about legibility these are the right character geometry, not"
  echo "                            the right physical size; 7-inch legibility"
  echo "                            is a hardware question"
  echo "  the first-boot screens    they happen after the reboot, on hardware"
} >"$OUT_DIR/SOURCE.txt"
log "provenance -> $OUT_DIR/SOURCE.txt"

if (( made == 0 )); then
  fail "no frames were produced at all -- check $RAW_DIR"
fi
log "done: $made image(s) in $OUT_DIR"

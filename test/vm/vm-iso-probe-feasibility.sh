#!/usr/bin/env bash
# vm-iso-probe-feasibility.sh -- T4 §8 unknown U2, answered against the real ISO.
#
# Usage: ./vm-iso-probe-feasibility.sh [iso-path] [work-dir]
#
# Env vars (all optional):
#   VM_RUN_TIMEOUT_SEC   whole-run ceiling, default 900
#   VM_MEM_MB / VM_SMP   guest size, defaults 4096 / 4
#   VM_OVMF_CODE / VM_OVMF_VARS   override firmware probing
#   VM_KEEP_WORK=1       never delete the work dir
#
# ===========================================================================
# THE TWO QUESTIONS
# ===========================================================================
#
# T4's [V] verification tier (docs/tasks/T4-screen-spec.md §6) rests on two
# mechanisms that had never been run against an *archiso*-based image:
#
#   1. INJECTION. §6.3 proposes QEMU SMBIOS type-11 systemd credentials
#      (io.systemd.credential.binary:systemd.extra-unit.…) to land a probe unit
#      in a guest without rebuilding the ISO. That works against the Neptune
#      substrate (test/vm/vm-osk-tty-test.sh) -- a normal installed system.
#      Nobody had tried it against an archiso live environment, whose root is a
#      squashfs+tmpfs overlay reached through switch_root.
#
#   2. READBACK. §6.2 A1 wants /dev/vcs1 -- the kernel's own copy of tty1 --
#      rather than a terminal emulator. test/vm/vm-install-test.sh's header
#      warns that tty1's text "can be hidden behind plymouth's splash for the
#      guest's whole lifetime". plymouth IS in this ISO's package set and
#      plymouthd.conf ships; the cmdline carries `quiet splash`.
#
# This suite boots the real ISO once and measures both, plus the third thing
# both depend on: that a key press from OUTSIDE the guest reaches the wizard,
# so a screen transition can be asserted as an advance-and-vanish PAIR (§6.2
# A5) rather than as "the next marker appeared".
#
# WHAT IT INJECTS, AND HOW MANY WAYS AT ONCE
#   * SMBIOS type-11  -> systemd.extra-unit.t4-probe.service + a dropin on
#                        multi-user.target that Wants it            (execution)
#   * SMBIOS type-11  -> a plain marker credential                  (data)
#   * QEMU fw_cfg     -> a second marker credential                 (data)
#   * a vfat drive labelled DECKPROBE, built rootlessly with
#     mkfs.vfat + mcopy                                             (payload)
#
#   The unit prefers the drive's copy of the probe and falls back to the
#   credential copy, and the probe reports which one it ran from -- so one boot
#   distinguishes "credentials work" from "credentials work but are too small"
#   from "nothing works".
#
# WHAT IT DOES NOT TOUCH
#   No ISO is rebuilt, no loop mount, no sudo, no physical hardware. The guest's
#   wizard is driven only as far as the keyboard step and is never allowed to
#   partition anything: there is no target disk attached.
#
# ===========================================================================
# THE ANSWER (2026-08-11, three boots -- docs/findings/T4-harness-feasibility.md)
# ===========================================================================
#   Both mechanisms work. SMBIOS credentials carry the whole 8 KB probe
#   byte-identically; plymouth has already quit when the wizard draws, so
#   /dev/vcs1 is the screen; and QMP send-key advances the real wizard, so
#   navigation-only screens need no in-guest input plumbing at all.
#
# ⚠️ TWO SILENT READERS THIS SUITE LEARNED THE HARD WAY -- inherit both guards:
#
#   1. tty1 is 25x80 at multi-user.target and 50x160 once the DRM driver takes
#      over. A width cached once folds later captures at the wrong column, which
#      SPLITS CENTRED TEXT across two lines: run 1 reported "the greeter is not
#      in /dev/vcs1" about a greeter that was plainly there. `snap()` therefore
#      re-reads /dev/vcsa1's header on EVERY capture and records the geometry
#      beside each one. Never cache it.
#
#   2. The Omarchy logo (and the OSK) are drawn with CP437 block glyphs -- raw
#      high bytes that are invalid UTF-8. GNU grep in a UTF-8 locale will not
#      match `.` or a negated class against them: ground truth 13 non-blank
#      rows, `grep -c '[^ ]'` said 2. Phrase greps on ASCII are unaffected, which
#      is what makes it silent. Use `LC_ALL=C grep -a`, or compare bytes.

set -uo pipefail

ISO=${1:-$HOME/ISOs/omarchy-quattro-beta2.iso}
WORK=${2:-$(mktemp -d /var/tmp/vm-iso-probe.XXXXXX)}

RUN_TIMEOUT=${VM_RUN_TIMEOUT_SEC:-900}
MEM_MB=${VM_MEM_MB:-4096}
SMP=${VM_SMP:-4}

log() { printf '[vm-iso-probe] %s\n' "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

[[ -f $ISO ]] || fail "ISO not found: $ISO"
for tool in qemu-system-x86_64 qemu-img mkfs.vfat mcopy socat base64 python3; do
  command -v "$tool" >/dev/null || fail "required tool '$tool' not found"
done

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
[[ -n $OVMF_CODE && -f $OVMF_CODE ]] || fail "OVMF CODE firmware not found. Override with VM_OVMF_CODE."
[[ -n $OVMF_VARS_TEMPLATE && -f $OVMF_VARS_TEMPLATE ]] || fail "OVMF VARS firmware not found. Override with VM_OVMF_VARS."

if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  ACCEL_ARGS=(-cpu host -enable-kvm -machine "q35,accel=kvm")
else
  log "WARNING: /dev/kvm not accessible -- falling back to TCG (slow)."
  ACCEL_ARGS=(-cpu max -machine "q35,accel=tcg")
fi

mkdir -p "$WORK"
log "work dir: $WORK"
log "iso:      $ISO"

ovmf_vars="$WORK/OVMF_VARS.fd"
probe_img="$WORK/deckprobe.img"
result_img="$WORK/result.raw"
result_txt="$WORK/report.txt"
serial_log="$WORK/serial.log"
qmp_sock="$WORK/qmp.sock"
pidfile="$WORK/qemu.pid"

cp "$OVMF_VARS_TEMPLATE" "$ovmf_vars"
qemu-img create -f raw "$result_img" 64M >/dev/null

# --- the in-guest probe ------------------------------------------------------

probe_src="$WORK/probe.sh"
cat >"$probe_src" <<'PROBE'
#!/usr/bin/env bash
# In-guest probe. NOT `set -e`: a failure of the thing under test is a result to
# report, not a reason to abort before reporting it.
set -uo pipefail

SER=/dev/ttyS0
RESULT_DEV=/dev/disk/by-id/virtio-vmresult
OUT=/run/t4probe
mkdir -p "$OUT"
R=$OUT/results
: >"$R"

say()  { printf 'T4PROBE:%s\n' "$*" >"$SER" 2>/dev/null; }
emit() { printf '%s\n' "$*" >>"$R"; }

finish() {
  {
    echo "=== T4 HARNESS FEASIBILITY PROBE ==="
    cat "$R"
    echo "=== SCREEN CAPTURES (kernel's own /dev/vcs1) ==="
    for f in "$OUT"/screen.*; do
      [[ -f $f ]] || continue
      echo "--- ${f##*/} ---"
      cat "$f"
    done
    echo "=== PROBE TRACE ==="
    tail -60 "$OUT/trace.log" 2>/dev/null
  } >"$OUT/report.txt" 2>&1
  if [[ -b $RESULT_DEV ]]; then
    dd if="$OUT/report.txt" of="$RESULT_DEV" bs=1M conv=fsync status=none
  fi
  kill "${WATCHDOG_PID:-0}" 2>/dev/null
  sync
  say "DONE"
  sleep 1
  systemctl poweroff -i
}
trap finish EXIT

# ⚠️ A probe that blocks is indistinguishable from a probe that never ran, and
# both cost a whole boot. This watchdog guarantees a report: it is the only
# reason a wedged `plymouth --ping` or a hung systemctl is a data point instead
# of an empty result device.
(
  sleep "${PROBE_WATCHDOG_SEC:-480}"
  printf 'watchdog.fired=1\n' >>"$R"
  {
    echo "=== T4 HARNESS FEASIBILITY PROBE (WATCHDOG) ==="
    cat "$R"
    echo "=== SCREEN CAPTURES (kernel's own /dev/vcs1) ==="
    for f in "$OUT"/screen.*; do
      [[ -f $f ]] || continue
      echo "--- ${f##*/} ---"; cat "$f"
    done
    echo "=== PROBE TRACE ==="
    tail -60 "$OUT/trace.log" 2>/dev/null
  } >"$OUT/watchdog-report.txt" 2>&1
  [[ -b $RESULT_DEV ]] && dd if="$OUT/watchdog-report.txt" of="$RESULT_DEV" bs=1M conv=fsync status=none
  sync
  printf 'T4PROBE:WATCHDOG\n' >"$SER" 2>/dev/null
  systemctl poweroff -i
) &
WATCHDOG_PID=$!

exec 2>"$OUT/trace.log"
set -x

# ---------------------------------------------------------------------------
# 0. THE FIRST ASSERTION: did the injected unit run at all? (§6.4 lie #3)
# ---------------------------------------------------------------------------
say "UNIT-RAN"
emit "unit.ran=1"
emit "probe.self=$0"
emit "payload.drive_present=$([[ -f /run/deckprobe/probe.sh ]] && echo 1 || echo 0)"
emit "payload.cred_present=$([[ -f /run/credentials/@system/t4probe.sh ]] && echo 1 || echo 0)"
emit "payload.drive_mounted=$(grep -c ' /run/deckprobe ' /proc/mounts)"
emit "payload.drive_bytes=$(wc -c </run/deckprobe/probe.sh 2>/dev/null)"
emit "payload.cred_bytes=$(wc -c </run/credentials/@system/t4probe.sh 2>/dev/null)"
emit "payload.cred_equals_drive=$(cmp -s /run/credentials/@system/t4probe.sh /run/deckprobe/probe.sh && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
# 1. the injection mechanisms, each independently visible
# ---------------------------------------------------------------------------
emit "systemd.version=$(timeout 5 systemctl --version 2>/dev/null | head -1)"
emit "cred.dir_listing=$(ls /run/credentials/@system 2>/dev/null | tr '\n' ',')"
emit "cred.smbios_marker=$(cat /run/credentials/@system/t4probe.smbios 2>/dev/null)"
emit "cred.fwcfg_marker=$(cat /run/credentials/@system/t4probe.fwcfg 2>/dev/null)"
emit "dmi.type11_entries=$(ls /sys/firmware/dmi/entries 2>/dev/null | grep -c '^11-')"
emit "fwcfg.sysfs_present=$([[ -d /sys/firmware/qemu_fw_cfg ]] && echo 1 || echo 0)"
emit "runsystemd.system=$(ls /run/systemd/system 2>/dev/null | tr '\n' ',')"
emit "cmdline=$(tr -d '\n' </proc/cmdline)"
emit "iso.version=$(cat /run/archiso/bootmnt/arch/version 2>/dev/null || echo unknown)"

# ---------------------------------------------------------------------------
# 2. plymouth, and whether tty1 is a text console at all
# ---------------------------------------------------------------------------
emit "plymouthd.running=$(pgrep -xc plymouthd 2>/dev/null)"
timeout 5 plymouth --ping >/dev/null 2>&1; emit "plymouth.ping_rc=$?"
emit "plymouth.start=$(timeout 5 systemctl is-active plymouth-start.service 2>&1)"
emit "plymouth.quit=$(timeout 5 systemctl is-active plymouth-quit.service 2>&1)"
emit "plymouth.quit_wait=$(timeout 5 systemctl is-active plymouth-quit-wait.service 2>&1)"
emit "fgconsole=$(timeout 5 fgconsole 2>&1)"
emit "tty0.active=$(cat /sys/class/tty/tty0/active 2>&1)"
emit "console.active=$(cat /sys/class/tty/console/active 2>&1)"
emit "fbcon.rotate=$(cat /sys/class/graphics/fbcon/rotate 2>&1)"
emit "vcs.nodes=$(ls -d /dev/vcs1 /dev/vcsa1 /dev/vcsu1 2>/dev/null | tr '\n' ',')"

# KD_TEXT(0) vs KD_GRAPHICS(1) on tty1. If plymouth still owns the VT this is 1,
# and anything drawn there is invisible to a human even though /dev/vcs1 may
# still carry it.
emit "tty1.kdmode=$(python3 - <<'PY' 2>&1
import fcntl, struct
try:
    with open('/dev/tty1', 'rb') as f:
        print(struct.unpack('i', fcntl.ioctl(f, 0x4B3B, struct.pack('i', 0)))[0])
except Exception as exc:
    print('err:%s' % exc)
PY
)"

# Geometry straight out of /dev/vcsa1's 4-byte header (lines, cols, x, y) --
# authoritative, and it needs no controlling terminal.
#
# ⚠️ RE-READ IT ON EVERY SNAPSHOT. Measured 2026-08-11: this guest's tty1 is
# 25x80 at multi-user.target and 50x160 by the time the wizard draws -- the
# console grows when the DRM driver takes over from the boot framebuffer. A
# width cached once folds every later capture at the wrong column, which
# SPLITS centred text across two lines and makes a phrase grep miss a screen
# that is perfectly present. That is a false negative that looks exactly like
# "/dev/vcs1 does not work", and it cost this suite one whole boot.
vcs_geom() {
  python3 - <<'PY' 2>/dev/null || echo "0 0"
try:
    d = open('/dev/vcsa1', 'rb').read(4)
    print(d[0], d[1])
except Exception:
    print(0, 0)
PY
}
read -r VROWS VCOLS <<<"$(vcs_geom)"
emit "vcs1.rows_at_start=${VROWS:-0}"
emit "vcs1.cols_at_start=${VCOLS:-0}"
emit "vcs1.bytes_at_start=$(wc -c </dev/vcs1 2>&1)"
emit "stty.tty1_at_start=$(stty size </dev/tty1 2>&1 | tr ' ' 'x')"

snap() {
  local rows cols
  read -r rows cols <<<"$(vcs_geom)"
  [[ ${cols:-0} -gt 0 ]] || cols=0
  SNAP_ROWS=$rows SNAP_COLS=$cols
  if (( cols > 0 )); then
    fold -w "$cols" </dev/vcs1 >"$OUT/screen.$1" 2>/dev/null
  else
    cat </dev/vcs1 >"$OUT/screen.$1" 2>/dev/null
  fi
}

# ---------------------------------------------------------------------------
# 3. does /dev/vcs1 carry the WIZARD's screen?
#    Markers read out of the ISO's own configurator:
#      greeter        "Beautiful, Modern & Opinionated Linux by DHH"
#                     "Press Return to Start Install"
#      keyboard step  "Let's setup your machine..."
# ---------------------------------------------------------------------------
waited=0
found=0
while (( waited < 300 )); do
  snap now
  if LC_ALL=C grep -qaE 'Press Return to Start Install|Opinionated Linux by DHH' "$OUT/screen.now" 2>/dev/null; then
    found=1
    break
  fi
  sleep 2
  waited=$((waited + 2))
done
emit "greeter.wait_s=$waited"
emit "greeter.found=$found"
cp "$OUT/screen.now" "$OUT/screen.A-greeter" 2>/dev/null
emit "A.geom=${SNAP_ROWS}x${SNAP_COLS}"
emit "A.hint=$(LC_ALL=C grep -ac 'Press Return to Start Install' "$OUT/screen.A-greeter" 2>/dev/null)"
emit "A.tagline=$(LC_ALL=C grep -ac 'Opinionated Linux by DHH' "$OUT/screen.A-greeter" 2>/dev/null)"
emit "A.keyboard_step=$(LC_ALL=C grep -ac 'setup your machine' "$OUT/screen.A-greeter" 2>/dev/null)"
emit "A.nonblank_rows=$(LC_ALL=C grep -ac '[^ ]' "$OUT/screen.A-greeter" 2>/dev/null)"

# Give the host a moment to take its own screendump of the SAME frame, so the
# kernel's text buffer can be compared against what a viewer would see.
say "SCREENSHOT"
sleep 4

# ---------------------------------------------------------------------------
# 4. can a key from OUTSIDE the guest advance the screen? (§6.2 A5)
# ---------------------------------------------------------------------------
say "WANT-KEY-1"
sleep 10
snap B-after-return
emit "B.geom=${SNAP_ROWS}x${SNAP_COLS}"
emit "B.hint=$(LC_ALL=C grep -ac 'Press Return to Start Install' "$OUT/screen.B-after-return" 2>/dev/null)"
emit "B.keyboard_step=$(LC_ALL=C grep -ac 'setup your machine' "$OUT/screen.B-after-return" 2>/dev/null)"
emit "B.tagline=$(LC_ALL=C grep -ac 'Opinionated Linux by DHH' "$OUT/screen.B-after-return" 2>/dev/null)"
emit "B.defer_hint=$(LC_ALL=C grep -ac 'prepare this machine for another owner' "$OUT/screen.B-after-return" 2>/dev/null)"
emit "B.cursor_row=$(LC_ALL=C grep -an '>' "$OUT/screen.B-after-return" 2>/dev/null | head -1 | cut -d: -f1)"

say "WANT-KEY-2"
sleep 8
snap C-after-down
emit "C.geom=${SNAP_ROWS}x${SNAP_COLS}"
emit "C.keyboard_step=$(LC_ALL=C grep -ac 'setup your machine' "$OUT/screen.C-after-down" 2>/dev/null)"
emit "C.cursor_row=$(LC_ALL=C grep -an '>' "$OUT/screen.C-after-down" 2>/dev/null | head -1 | cut -d: -f1)"
emit "C.differs_from_B=$(cmp -s "$OUT/screen.B-after-return" "$OUT/screen.C-after-down" && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
# 5. what a [V] harness would need next, measured while we are in here
# ---------------------------------------------------------------------------
emit "proc.configurator=$(pgrep -fc configurator 2>/dev/null)"
emit "proc.gum=$(pgrep -xc gum 2>/dev/null)"
emit "proc.agetty_tty1=$(pgrep -fc 'agetty.*tty1' 2>/dev/null)"
emit "python.version=$(python3 -V 2>&1)"
python3 -c 'import evdev' >/dev/null 2>&1; emit "python.evdev_importable=$?"
# The live pacman.conf declares one offline repo, so `pacman -Sy python-evdev`
# cannot work (P15 R-9/R-10). `pacman -U` off a local file can. If the payload
# drive carries the package, prove the whole chain here: install it, import it,
# and actually create a uinput device -- which is what a scripted Deck pad needs.
if compgen -G '/run/deckprobe/python-evdev-*.pkg.tar.zst' >/dev/null; then
  pacman -U --noconfirm --needed /run/deckprobe/python-evdev-*.pkg.tar.zst >/run/t4probe/pacman-U.log 2>&1
  emit "evdev.pacman_U_rc=$?"
  python3 -c 'import evdev' >/dev/null 2>&1; emit "evdev.importable_after=$?"
  emit "evdev.module=$(python3 -c 'import evdev,sys; sys.stdout.write(evdev.__file__)' 2>&1 | tail -1)"
fi
modprobe uinput >/dev/null 2>&1; emit "uinput.node=$([[ -c /dev/uinput ]] && echo 1 || echo 0)"
emit "uinput.pad_created=$(python3 - <<'PY' 2>&1 | tail -1
try:
    from evdev import UInput, AbsInfo, ecodes as e
    AX = AbsInfo(0, -32768, 32767, 0, 0, 0)
    ui = UInput({e.EV_KEY: [e.BTN_SOUTH, e.BTN_TR2],
                 e.EV_ABS: [(e.ABS_HAT0X, AX), (e.ABS_HAT1X, AX)]},
                name="T4 Probe Virtual Deck Pad", vendor=0x28de, product=0x1205)
    print(ui.device.path)
    ui.close()
except Exception as exc:
    print('err:%s' % exc)
PY
)"
emit "hid_steam.modinfo_lizard=$(modinfo hid_steam 2>/dev/null | grep -c 'lizard_mode')"
emit "hid_steam.loaded=$([[ -d /sys/module/hid_steam ]] && echo 1 || echo 0)"
emit "hid_steam.sysfs_param=$([[ -f /sys/module/hid_steam/parameters/lizard_mode ]] && echo 1 || echo 0)"
emit "tools=$(for t in gum jq openssl tzupdate iwctl tte loadkeys openvt chvt; do command -v "$t" >/dev/null && printf '%s,' "$t"; done)"
emit "cidata.loader_present=$([[ -x /usr/local/bin/omarchy-cidata-load ]] && echo 1 || echo 0)"
emit "cloudinit.marker=$([[ -b /dev/disk/by-id/virtio-vmcloud ]] && tr -d '\0' </dev/disk/by-id/virtio-vmcloud | head -c 120)"
emit "cloudinit.status=$(timeout 10 cloud-init status 2>&1 | tr '\n' ' ' | head -c 160)"
PROBE

# --- the injected unit -------------------------------------------------------
#
# ⚠️ StandardOutput/StandardError are /dev/null on purpose. The probe shares tty1
# with the thing it is watching; a unit that logs to journal+console would
# scribble across the very screen under test. Synchronisation goes out /dev/ttyS0
# instead, which nothing in this ISO uses (the cmdline carries no console=).
unit_text="[Unit]
Description=T4 [V]-tier feasibility probe
After=multi-user.target

[Service]
Type=oneshot
ExecStartPre=-/usr/bin/udevadm settle
ExecStartPre=-/usr/bin/mkdir -p /run/deckprobe
ExecStartPre=-/usr/bin/mount -o ro /dev/disk/by-label/DECKPROBE /run/deckprobe
ExecStart=/usr/bin/bash -c 'test -f /run/deckprobe/probe.sh && exec /usr/bin/bash /run/deckprobe/probe.sh; test -f /run/credentials/@system/t4probe.sh && exec /usr/bin/bash /run/credentials/@system/t4probe.sh; printf \"unit.ran=1\\\\npayload.route=none\\\\n\" >/tmp/none.txt; dd if=/tmp/none.txt of=/dev/disk/by-id/virtio-vmresult bs=1M conv=fsync status=none; systemctl poweroff -i'
TimeoutStartSec=0
RemainAfterExit=yes
StandardOutput=null
StandardError=null
"
dropin_text="[Unit]
Wants=t4-probe.service
"

log "building the DECKPROBE payload drive (mkfs.vfat + mcopy, no root)"
truncate -s 32M "$probe_img"
mkfs.vfat -n DECKPROBE "$probe_img" >/dev/null || fail "mkfs.vfat failed"
MTOOLS_SKIP_CHECK=1 mcopy -o -i "$probe_img" "$probe_src" ::/probe.sh || fail "mcopy failed"
# Optional extra payload: any package the live environment cannot fetch (its
# pacman.conf declares one offline repo). VM_PROBE_EXTRA is a space-separated
# list of host paths copied to the drive's root.
for f in ${VM_PROBE_EXTRA:-}; do
  [[ -f $f ]] || fail "VM_PROBE_EXTRA file not found: $f"
  MTOOLS_SKIP_CHECK=1 mcopy -o -i "$probe_img" "$f" "::/${f##*/}" || fail "mcopy of $f failed"
  log "  payload: ${f##*/}"
done

cred_unit="io.systemd.credential.binary:systemd.extra-unit.t4-probe.service=$(base64 -w0 <<<"$unit_text")"
cred_dropin="io.systemd.credential.binary:systemd.unit-dropin.multi-user.target=$(base64 -w0 <<<"$dropin_text")"
cred_marker="io.systemd.credential:t4probe.smbios=smbios-cred-ok"
# Deliberately also shove the WHOLE 8 KB probe through an SMBIOS OEM string.
# §6.3's proposal is credential-only injection, so the size ceiling of that
# route is part of the answer: if this arrives intact, no payload drive is
# needed at all.
cred_script="io.systemd.credential.binary:t4probe.sh=$(base64 -w0 <"$probe_src")"
log "SMBIOS OEM string sizes: unit=${#cred_unit}B dropin=${#cred_dropin}B marker=${#cred_marker}B script=${#cred_script}B"

fwcfg_marker="$WORK/fwcfg-marker"
printf 'fwcfg-cred-ok' >"$fwcfg_marker"

# --- the other candidate trigger: cloud-init, off the cidata drive ------------
#
# `omarchy-cidata-load` COPIES eight named files and executes nothing, so the
# cidata drive on its own cannot start a probe. But cloud-init 26.1 ships in the
# live ISO with cloud-init-generator installed, and NoCloud's seed label is the
# same `cidata` -- so the drive the existing harness already builds could, in
# principle, carry both the autoinstall config AND a runcmd. VM_PROBE_INJECT
# selects which trigger this run exercises.
INJECT=${VM_PROBE_INJECT:-smbios}
inject_args=()
case $INJECT in
  smbios)
    inject_args=(
      -smbios "type=11,value=${cred_unit}"
      -smbios "type=11,value=${cred_dropin}"
      -smbios "type=11,value=${cred_marker}"
      -smbios "type=11,value=${cred_script}"
    )
    ;;
  cloudinit)
    # shellcheck disable=SC2054  # these are QEMU -drive/-device option strings, not array elements
    cidata_img="$WORK/cidata.img"
    printf 'instance-id: t4probe\nlocal-hostname: t4probe\n' >"$WORK/meta-data"
    cat >"$WORK/user-data" <<'UD'
#cloud-config
runcmd:
  - [ bash, -c, "mkdir -p /run/deckprobe; mount -o ro /dev/disk/by-label/DECKPROBE /run/deckprobe; exec bash /run/deckprobe/probe.sh" ]
UD
    truncate -s 4M "$cidata_img"
    mkfs.vfat -n CIDATA "$cidata_img" >/dev/null || fail "mkfs.vfat (cidata) failed"
    MTOOLS_SKIP_CHECK=1 mcopy -o -i "$cidata_img" "$WORK/meta-data" ::/meta-data
    MTOOLS_SKIP_CHECK=1 mcopy -o -i "$cidata_img" "$WORK/user-data" ::/user-data
    # shellcheck disable=SC2054
    inject_args=(
      -drive "file=$cidata_img,format=raw,if=none,id=cidata0"
      -device virtio-blk-pci,drive=cidata0
    )
    log "cloud-init NoCloud seed built (no user_configuration.json, so omarchy-cidata-load still declines and the wizard still runs)"
    ;;
  *) fail "VM_PROBE_INJECT must be 'smbios' or 'cloudinit'" ;;
esac
log "injection under test: $INJECT"

# --- boot --------------------------------------------------------------------

log "booting the ISO headless (timeout ${RUN_TIMEOUT}s)"
qemu-system-x86_64 \
  "${ACCEL_ARGS[@]}" \
  -smp "$SMP" -m "$MEM_MB" \
  -smbios type=1,manufacturer=Valve,product=Galileo,version=1 \
  -smbios type=2,manufacturer=Valve,product=Galileo \
  "${inject_args[@]}" \
  -fw_cfg "name=opt/io.systemd.credentials/t4probe.fwcfg,file=${fwcfg_marker}" \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$ovmf_vars" \
  -drive file="$ISO",media=cdrom,if=none,format=raw,id=cdrom0 \
  -device ide-cd,drive=cdrom0,bootindex=1 \
  -drive file="$probe_img",format=raw,if=none,id=probe0 \
  -device virtio-blk-pci,drive=probe0 \
  -drive file="$result_img",format=raw,if=none,id=result0 \
  -device virtio-blk-pci,drive=result0,serial=vmresult \
  -nic user,model=virtio-net-pci \
  -display none -vga std \
  -qmp "unix:${qmp_sock},server,nowait" \
  -serial "file:${serial_log}" \
  -daemonize -pidfile "$pidfile" \
  -no-reboot ||
  fail "qemu-system-x86_64 failed to launch"

qemu_pid=$(cat "$pidfile")
log "qemu pid $qemu_pid"

qmp() {
  printf '{"execute":"qmp_capabilities"}\n%s\n' "$1" |
    timeout 5 socat - "UNIX-CONNECT:${qmp_sock}" 2>/dev/null
}
sendkey() {
  qmp "{\"execute\":\"send-key\",\"arguments\":{\"keys\":[{\"type\":\"qcode\",\"data\":\"$1\"}]}}" >>"$WORK/qmp.log"
  log "sent key: $1"
}

# --- host side: watch the serial marker channel, answer with key presses ------

seen_screenshot=0 seen_key1=0 seen_key2=0
elapsed=0
while kill -0 "$qemu_pid" 2>/dev/null; do
  if [[ -f $serial_log ]]; then
    if (( ! seen_screenshot )) && grep -q 'T4PROBE:SCREENSHOT' "$serial_log"; then
      seen_screenshot=1
      qmp "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$WORK/screen-A.ppm\"}}" >>"$WORK/qmp.log"
      log "took a host-side screendump of the greeter frame"
    fi
    if (( ! seen_key1 )) && grep -q 'T4PROBE:WANT-KEY-1' "$serial_log"; then
      seen_key1=1
      sleep 1
      sendkey ret
    fi
    if (( ! seen_key2 )) && grep -q 'T4PROBE:WANT-KEY-2' "$serial_log"; then
      seen_key2=1
      sleep 1
      sendkey down
    fi
  fi
  sleep 2
  elapsed=$((elapsed + 2))
  if (( elapsed >= RUN_TIMEOUT )); then
    log "TIMEOUT after ${elapsed}s -- grabbing a screendump before killing"
    qmp "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$WORK/screen-timeout.ppm\"}}" >>"$WORK/qmp.log"
    kill "$qemu_pid" 2>/dev/null
    sleep 2
    kill -9 "$qemu_pid" 2>/dev/null
    break
  fi
done
log "guest gone after ${elapsed}s (serial markers seen: screenshot=$seen_screenshot key1=$seen_key1 key2=$seen_key2)"

# --- results -----------------------------------------------------------------

tr -d '\0' <"$result_img" >"$result_txt"
if [[ ! -s $result_txt ]]; then
  log "the guest wrote NOTHING to the result device."
  log "  serial log:  $serial_log"
  log "  qmp log:     $WORK/qmp.log"
  log "  work dir:    $WORK"
  fail "no report -- the injected unit did not run, or died before it could write"
fi
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
note() { log "note ${1} = $(field "$1")"; }

log "--- mechanism 1: injection -------------------------------------------"
check "the injected unit ran at all"           "$(field unit.ran)" 1
if [[ $INJECT == smbios ]]; then
  check "SMBIOS marker credential landed"      "$(field cred.smbios_marker)" "smbios-cred-ok"
else
  log "note VM_PROBE_INJECT=$INJECT -- no SMBIOS credentials were passed; cred.smbios_marker='$(field cred.smbios_marker)' is expected to be empty"
  note cloudinit.status
fi
note  probe.self
note  payload.drive_present
note  payload.cred_present
note  cred.fwcfg_marker
note  dmi.type11_entries
note  runsystemd.system
note  systemd.version

log "--- mechanism 2: reading the console ---------------------------------"
check "/dev/vcs1 carried the greeter"          "$(field greeter.found)" 1
check "tty1 is in TEXT mode, not graphics"     "$(field tty1.kdmode)" 0
note  plymouthd.running
note  plymouth.ping_rc
note  fgconsole
note  vcs1.rows_at_start
note  vcs1.cols_at_start
note  A.geom
note  B.geom
note  fbcon.rotate
note  greeter.wait_s

log "--- advance-and-vanish (A5) ------------------------------------------"
check "greeter marker present before the key"  "$(field A.tagline)" 1
check "greeter marker GONE after the key"      "$(field B.tagline)" 0
check "keyboard step appeared after the key"   "$(field B.keyboard_step)" 1
note  C.differs_from_B
note  B.cursor_row
note  C.cursor_row

log "--- what a [V] harness still needs -----------------------------------"
note  python.version
note  python.evdev_importable
note  uinput.node
note  hid_steam.modinfo_lizard
note  hid_steam.sysfs_param
note  tools
note  cloudinit.status

if [[ $status -eq 0 ]]; then
  log "PASS -- both mechanisms work against the real ISO"
  [[ ${VM_KEEP_WORK:-0} == 1 ]] || log "work dir kept anyway for the write-up: $WORK"
else
  log "FAILED -- full report: $result_txt (work dir: $WORK)"
fi
exit $status

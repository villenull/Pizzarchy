#!/usr/bin/env bash
# vm-enable-gaming-test.sh -- QEMU proof of FAST-INSTALL C6: a Gaming=No
# install turns into a Gaming Mode machine IN PLACE via the shipped desktop
# action, with no disk wipe.
#
# Takes the installed NVMe image a `vm-fast-install-test.sh` gaming=no run
# left behind, copies it (reflink when the filesystem can), boots the COPY
# with user-mode networking and the Galileo/Valve SMBIOS the Deck gates on,
# logs in on the serial getty (the rotated fbcon defeats OCR), and runs exactly what the launcher
# runs: `sudo /usr/bin/omarchy-deck-enable-gaming`. Its output and exit code
# go to the serial port. After a clean ACPI poweroff the harness mounts the
# disk and asserts the OUTCOME on artifacts (pacman db, session file, SDDM
# drop-in, readiness marker) -- never on log text.
#
# Usage: ./vm-enable-gaming-test.sh <installed-target.raw> [work-dir]
#
# Env (optional): VM_USERNAME (tester), VM_PASSWORD (tester123),
#   VM_MEM_MB (8192), VM_SMP (min(nproc,4)), VM_ENABLE_TIMEOUT_SEC (2400),
#   VM_OVMF_CODE / VM_OVMF_VARS.
#
# Scope: QEMU has no Deck HID, panel or GPU, so this proves the package
# transaction, the stage bake, the client bootstrap and the login switch --
# not that gamescope renders. That stays a physical-Deck check.
#
# Exit: 0 pass, 1 fail (work dir preserved), 2 usage/environment.

set -uo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../lib/vm-disk-image.sh
source "$REPO_ROOT/test/lib/vm-disk-image.sh"
# shellcheck source=../lib/vm-assertions.sh
source "$REPO_ROOT/test/lib/vm-assertions.sh"

SRC_DISK=${1:?"usage: $0 <installed-target.raw> [work-dir]"}
WORK=${2:-$(mktemp -d /tmp/vm-enable-gaming-test.XXXXXX)}
[[ -f $SRC_DISK ]] || { echo "vm-enable-gaming-test: disk not found: $SRC_DISK" >&2; exit 2; }

USERNAME=${VM_USERNAME:-tester}
PASSWORD=${VM_PASSWORD:-tester123}
MEM_MB=${VM_MEM_MB:-8192}
SMP=${VM_SMP:-$(( $(nproc) < 4 ? $(nproc) : 4 ))}
ENABLE_TIMEOUT=${VM_ENABLE_TIMEOUT_SEC:-2400}

log() { printf '[vm-enable-gaming-test] %s\n' "$*" >&2; }
fail() { log "FAIL: $*"; log "work dir preserved: $WORK"; exit 1; }

for c in qemu-system-x86_64 socat jq; do
  command -v "$c" >/dev/null || { log "missing tool: $c"; exit 2; }
done
OVMF_CODE=${VM_OVMF_CODE:-/usr/share/edk2/x64/OVMF_CODE.4m.fd}
OVMF_VARS_TEMPLATE=${VM_OVMF_VARS:-/usr/share/edk2/x64/OVMF_VARS.4m.fd}
[[ -f $OVMF_CODE && -f $OVMF_VARS_TEMPLATE ]] || { log "OVMF firmware not found (set VM_OVMF_CODE/VM_OVMF_VARS)"; exit 2; }
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  ACCEL_ARGS=(-cpu host -enable-kvm -machine "q35,accel=kvm")
else
  log "WARNING: no /dev/kvm -- TCG; raise VM_ENABLE_TIMEOUT_SEC"
  ACCEL_ARGS=(-cpu max -machine "q35,accel=tcg")
fi

mkdir -p "$WORK"
disk="$WORK/target.raw"
vars="$WORK/OVMF_VARS.fd"
qmp_sock="$WORK/qmp.sock"
serial_sock="$WORK/serial.sock"
pidfile="$WORK/qemu.pid"
serial_log="$WORK/serial.log"
log "work dir: $WORK"
cp --reflink=auto --sparse=always "$SRC_DISK" "$disk" || fail "could not copy $SRC_DISK"
cp "$OVMF_VARS_TEMPLATE" "$vars"
: >"$serial_log"

qmp() {
  printf '{"execute":"qmp_capabilities"}\n%s\n' "$1" |
    timeout 10 socat - "UNIX-CONNECT:${qmp_sock}" 2>/dev/null
}
# The installed system's text consoles are rotated for the Deck's portrait
# panel (fbcon=rotate:1), which defeats OCR, so the login happens on the
# serial getty instead: a socket chardev with a logfile, written through one
# persistent socat. Its stdout is discarded -- the logfile has every byte.
ser_open() {
  coproc SER { socat - "UNIX-CONNECT:${serial_sock}" >/dev/null 2>&1; }
}
ser_send() { printf '%s\r' "$1" >&"${SER[1]}" || fail "serial write failed"; }
# ser_wait <regex> <timeout-s>: wait for NEW serial output (after mark) to match.
ser_mark=0
ser_wait() {
  local re=$1 limit=$2 waited=0
  while ! tail -c +"$((ser_mark + 1))" "$serial_log" | LC_ALL=C grep -aqE "$re"; do
    sleep 2; waited=$((waited + 2))
    (( waited < limit )) || fail "serial never showed /$re/ within ${limit}s (see $serial_log)"
  done
  ser_mark=$(stat -c %s "$serial_log")
}
screenshot() {
  qmp "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$WORK/$1\"}}" >/dev/null 2>&1 || true
}
cleanup() {
  local pid
  if [[ -f $pidfile ]] && pid=$(cat "$pidfile" 2>/dev/null) && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

log "booting the installed Gaming=No disk with user networking"
qemu-system-x86_64 \
  "${ACCEL_ARGS[@]}" -smp "$SMP" -m "$MEM_MB" \
  -smbios type=1,manufacturer=Valve,product=Galileo,version=1 \
  -smbios type=2,manufacturer=Valve,product=Galileo \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$vars" \
  -drive if=none,id=tgt,format=raw,file="$disk" \
  -device nvme,drive=tgt,serial=VMFASTTARGET,bootindex=0 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -display none -vga std \
  -qmp "unix:${qmp_sock},server,nowait" \
  -chardev "socket,id=ser0,path=${serial_sock},server=on,wait=off,logfile=${serial_log}" \
  -serial chardev:ser0 \
  -daemonize -pidfile "$pidfile" -no-reboot ||
  fail "qemu failed to launch"
qemu_pid=$(cat "$pidfile")

# Boot to the serial getty (the Gaming=No greeter is on the panel meanwhile;
# keep a picture of it), then log in as the desktop user.
ser_open
ser_wait 'login:' 300
sleep 15
screenshot greeter.ppm
log "installed system up; logging in on the serial console"
ser_send "$USERNAME"
ser_wait 'Password:' 30
ser_send "$PASSWORD"
# systemd tags an interactive shell on the console with an OSC 3008
# "type=shell" context marker; Omarchy's prompt (`~ ❯`) carries no user name.
ser_wait 'type=shell' 60

# Exactly what the launcher runs (sudo + the shipped action), then the
# exit code on its own line. sudo asks for the user's password once.
ser_send "sudo /usr/bin/omarchy-deck-enable-gaming; echo ENABLE-RC=\$?"
ser_wait 'password for' 30
ser_send "$PASSWORD"
log "omarchy-deck-enable-gaming started (timeout ${ENABLE_TIMEOUT}s)"

rc=""
elapsed=0
while kill -0 "$qemu_pid" 2>/dev/null; do
  rc=$(LC_ALL=C grep -aoE 'ENABLE-RC=[0-9]+' "$serial_log" | tail -n 1 | cut -d= -f2)
  [[ -n $rc ]] && break
  sleep 10; elapsed=$((elapsed + 10))
  (( elapsed % 120 == 0 )) && log "still running (${elapsed}s): $(LC_ALL=C tail -n 1 "$serial_log" | tr -d '\r' | cut -c1-120)"
  (( elapsed < ENABLE_TIMEOUT )) || fail "action did not finish within ${ENABLE_TIMEOUT}s"
done
[[ -n $rc ]] || fail "guest exited before the action reported an exit code"
log "action finished after ~${elapsed}s with exit code $rc"
if [[ $rc != 0 ]]; then
  LC_ALL=C tail -n 60 "$serial_log" >&2
  fail "omarchy-deck-enable-gaming exited $rc"
fi

log "clean ACPI poweroff before inspecting the disk"
qmp '{"execute":"system_powerdown"}' >/dev/null
for _ in $(seq 1 60); do kill -0 "$qemu_pid" 2>/dev/null || break; sleep 2; done
kill -0 "$qemu_pid" 2>/dev/null && fail "guest ignored ACPI poweroff for 120s"

status=0
check() { "$@" || status=1; }
root_raw="$WORK/root.raw"
disk_image::root_extract "$disk" "$root_raw" || fail "could not extract the root partition"
read -r loop root_at < <(disk_image::root_mount "$root_raw") || fail "could not mount the root partition"
mnt=${root_at%/@}
check assert::packages_present "$root_at/var/lib/pacman/local" steam gamescope vulkan-radeon lib32-vulkan-radeon mangohud lib32-mangohud
for f in /usr/share/wayland-sessions/gamescope-wayland.desktop \
         /usr/lib/steam/bootstraplinux_ubuntu12_32.tar.xz \
         /var/lib/omarchy-deck/gaming-ready \
         /etc/sddm.conf.d/zz-deck-session.conf; do
  [[ -f $root_at$f ]] || { log "FAIL: missing after the action: $f"; status=1; }
done
if [[ -f $root_at/etc/sddm.conf.d/zz-deck-session.conf ]]; then
  log "SDDM drop-in: $(tr '\n' ' ' <"$root_at/etc/sddm.conf.d/zz-deck-session.conf")"
  { grep -q '^Session=gamescope-wayland' "$root_at/etc/sddm.conf.d/zz-deck-session.conf" &&
    grep -q "^User=$USERNAME\$" "$root_at/etc/sddm.conf.d/zz-deck-session.conf"; } ||
    { log "FAIL: the login target was not switched to Gaming Mode for $USERNAME"; status=1; }
fi
home="$mnt/@home/$USERNAME"
compgen -G "$home/.local/share/Steam/package/steam_client_*.installed" >/dev/null ||
  { log "FAIL: no Steam client manifest in $USERNAME's home"; status=1; }
cp "$root_at/var/log/omarchy-deck-enable-gaming.log" "$WORK/" 2>/dev/null ||
  cp "$mnt/@log/omarchy-deck-enable-gaming.log" "$WORK/" 2>/dev/null || true
disk_image::root_unmount "$loop"

trap - EXIT
cleanup
if (( status == 0 )); then
  log "PASS -- Gaming=No desktop converted in place (action ${elapsed}s). work dir: $WORK"
else
  log "FAIL -- see above. work dir preserved: $WORK"
fi
exit $status

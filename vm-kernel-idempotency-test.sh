#!/usr/bin/env bash
# T1 step 1: prove omarchy-deck-kernel.sh is idempotent by running it twice
# in a row inside a QEMU VM and diffing the end state, rather than asserting
# idempotency from reading the code.
#
# Usage: ./vm-kernel-idempotency-test.sh <installed-disk-image> [work-dir]
#
# <installed-disk-image> is an *already-installed* Omarchy Quattro disk
# (raw or qcow2) — the artifact vm-install-test.sh produces. This harness
# does not run an install; it boots a system that already has archinstall's
# Limine + UKI layout on it, which is the substrate omarchy-deck-kernel.sh
# is written against.
#
# Env vars (all optional):
#   VM_MEM_MB          default 4096
#   VM_SMP             default min(nproc,4)
#   VM_RUN_TIMEOUT_SEC default 3600
#   VM_OVMF_CODE / VM_OVMF_VARS  override firmware probing
#   VM_NEPTUNE_SERIES  passed through to the script under test
#
# Design notes, and why it looks like this:
#
# * Assertions are on *state*, not log text — same rule as vm-install-test.sh
#   and for the same reason (PLAN.md §8.1: upstream printed success while
#   doing nothing). The in-guest probe snapshots the ESP, the Limine config,
#   fstab, pacman.conf, the live mount options and the installed package set
#   after run 1 and again after run 2, and the pass condition is that those
#   two snapshots are byte-identical. UKI content is covered by sha256, so a
#   needless initramfs rebuild (which is not byte-reproducible) shows up as
#   a diff instead of passing silently.
#
# * Everything is injected without root on the host. The payload scripts are
#   written onto the guest's ESP with mtools at a byte offset — the same
#   rootless technique vm-disk-image.sh already uses to read these images —
#   and the systemd unit that runs them is delivered as an SMBIOS type-11
#   system credential (`systemd.extra-unit.*` + `systemd.unit-dropin.*`,
#   see systemd.system-credentials(7)). The guest's root filesystem is never
#   modified from the host. This matters because this dev machine has no
#   passwordless sudo, and a test harness that needs an interactive password
#   cannot run in CI.
#
# * Results come back on a raw virtio device rather than through the serial
#   console, reusing vm-install-test.sh's debug-log-drive pattern: guest
#   console output can be swallowed by plymouth, and this needs the full
#   text of both runs even when the guest never reaches a usable console.
#
# * DMI is spoofed with -smbios so the script's real Steam Deck hardware
#   gate is exercised, instead of adding a bypass flag to the script under
#   test. The gate is a safety property; a build with it disabled is not the
#   build that ships.
#
# * Networking is QEMU user-mode (-nic user): the guest has to reach Valve's
#   package mirror. Nothing about this test is offline; the *installer* is
#   what must work offline (CLAUDE.md), not this developer harness.

set -uo pipefail

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=vm-disk-image.sh
source "$SELF_DIR/vm-disk-image.sh"

BASE_DISK=${1:?"usage: $0 <installed-disk-image> [work-dir]"}
WORK=${2:-$(mktemp -d /var/tmp/vm-kernel-idem.XXXXXX)}

MEM_MB=${VM_MEM_MB:-4096}
DEFAULT_SMP=$(( $(nproc) < 4 ? $(nproc) : 4 ))
SMP=${VM_SMP:-$DEFAULT_SMP}
RUN_TIMEOUT=${VM_RUN_TIMEOUT_SEC:-3600}
NEPTUNE_SERIES=${VM_NEPTUNE_SERIES:-}

log() { printf '[vm-kernel-idem] %s\n' "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

[[ -f $BASE_DISK ]] || fail "base disk image not found: $BASE_DISK"
[[ -f $SELF_DIR/omarchy-deck-kernel.sh ]] || fail "omarchy-deck-kernel.sh not found next to this script"

for tool in qemu-system-x86_64 qemu-img mcopy sfdisk jq base64; do
  command -v "$tool" >/dev/null || fail "$tool not found"
done

# Same OVMF probing as vm-install-test.sh — paths differ across distros and
# this has to work on the Arch dev machine and on an Ubuntu CI runner.
find_ovmf() {
  local c
  for c in "$@"; do
    [[ -f $c ]] && { echo "$c"; return 0; }
  done
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
[[ -n $OVMF_CODE && -f $OVMF_CODE ]] || fail "OVMF CODE firmware not found — install edk2-ovmf (Arch) / ovmf (Debian). Override with VM_OVMF_CODE."
[[ -n $OVMF_VARS_TEMPLATE && -f $OVMF_VARS_TEMPLATE ]] || fail "OVMF VARS firmware not found. Override with VM_OVMF_VARS."

if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  ACCEL_ARGS=(-cpu host -enable-kvm -machine "q35,accel=kvm")
else
  log "WARNING: /dev/kvm not accessible — falling back to TCG. This test installs a kernel and builds an initramfs; under TCG expect it to exceed the default timeout."
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

log "copying base disk (a full copy: the test must not mutate the base image)"
case $BASE_DISK in
  *.qcow2) qemu-img convert -O raw "$BASE_DISK" "$disk" || fail "qemu-img convert failed" ;;
  *)       cp --reflink=auto --sparse=always "$BASE_DISK" "$disk" || fail "cp of base disk failed" ;;
esac

cp "$OVMF_VARS_TEMPLATE" "$ovmf_vars"
qemu-img create -f raw "$result_img" 64M >/dev/null

# --- payload -----------------------------------------------------------------

probe_src="$WORK/omarchy-deck-idem-probe.sh"
cat >"$probe_src" <<'PROBE'
#!/usr/bin/env bash
# In-guest probe. Runs omarchy-deck-kernel.sh twice, snapshots state after
# each run, and ships everything out on the result block device.
#
# Deliberately NOT `set -e`: a failure of the script under test is a result
# to report, not a reason to abort before reporting it.
set -uo pipefail

RESULT_DEV=/dev/disk/by-id/virtio-vmresult
OUT=/root/idem
mkdir -p "$OUT"
exec >"$OUT/probe.log" 2>&1
# Send xtrace to its own fd so it cannot leak into the state snapshots below
# (they redirect stderr, and a trace line in a snapshot would be noise in the
# very diff this test's verdict depends on).
exec {xtrace_fd}>>"$OUT/probe.trace"
BASH_XTRACEFD=$xtrace_fd
set -x

# Both payload files are copied to /root by the unit's ExecStartPre and run
# from there. Nothing may execute out of /boot: bash holds an open fd on the
# script it is running, which makes the ESP busy and makes the script under
# test's umount/mount cycle fail for a reason that has nothing to do with the
# system under test. (That is exactly what happened the first time; the
# "holders" diagnostic in stage_esp_permissions pointed straight at it.)
SCRIPT=/root/omarchy-deck-kernel.sh
[[ -f $SCRIPT ]] || exit 90

# Wait for outbound connectivity — the kernel comes from Valve's mirror.
online=0
for _ in $(seq 1 60); do
  if getent hosts steamdeck-packages.steamos.cloud >/dev/null 2>&1; then online=1; break; fi
  sleep 5
done

# Snapshot every piece of state either the script or a kernel install can
# touch. Sorted and content-hashed so it is order- and mtime-independent:
# the only differences that should show up between run 1 and run 2 are real
# ones. sha256 over the ESP tree is what catches a needless UKI rebuild —
# an initramfs is not byte-reproducible, so a rebuild changes the hash (and
# the hash limine-entry-tool records in its config).
snapshot() {
  local tag=$1
  {
    echo "== mount options =="
    findmnt -n -o TARGET,FSTYPE,OPTIONS --mountpoint /boot
    echo "== esp tree (type mode size path) =="
    find /boot -xdev -printf '%y %m %s %p\n' 2>/dev/null | LC_ALL=C sort
    echo "== esp file hashes =="
    find /boot -xdev -type f -print0 2>/dev/null | LC_ALL=C sort -z |
      xargs -0 -r sha256sum 2>/dev/null | LC_ALL=C sort -k2
    echo "== limine.conf =="
    cat /boot/limine.conf 2>/dev/null
    echo "== fstab =="
    cat /etc/fstab
    echo "== pacman.conf (non-comment) =="
    grep -vE '^[[:space:]]*(#|$)' /etc/pacman.conf
    echo "== installed packages =="
    pacman -Q 2>/dev/null | LC_ALL=C sort
    echo "== kernel module dirs =="
    for p in /usr/lib/modules/*/pkgbase; do
      [[ -f $p ]] && echo "${p%/pkgbase} -> $(<"$p")"
    done | LC_ALL=C sort
    echo "== limine boot menu tree =="
    limine-entry-tool --no-hooks --no-mutex --tree 5 2>&1 | sed 's/[[:space:]]*$//'
  } >"$OUT/state.$tag" 2>&1
}

snapshot before

bash "$SCRIPT" >"$OUT/run1.out" 2>&1
rc1=$?
snapshot after1

bash "$SCRIPT" >"$OUT/run2.out" 2>&1
rc2=$?
snapshot after2

diff -u "$OUT/state.after1" "$OUT/state.after2" >"$OUT/state.diff" 2>&1
diff_rc=$?

{
  echo "=== OMARCHY-DECK-KERNEL IDEMPOTENCY PROBE ==="
  echo "network_resolved=$online"
  echo "run1_exit=$rc1"
  echo "run2_exit=$rc2"
  echo "state_diff_exit=$diff_rc"
  echo "=== RUN 1 OUTPUT ==="
  cat "$OUT/run1.out"
  echo "=== RUN 2 OUTPUT ==="
  cat "$OUT/run2.out"
  echo "=== STATE DIFF (after run 1 vs after run 2) ==="
  cat "$OUT/state.diff"
  echo "=== STATE DIFF (before vs after run 1) ==="
  diff -u "$OUT/state.before" "$OUT/state.after1" 2>&1 | head -n 600
  echo "=== END ==="
} >"$OUT/report.txt" 2>&1

if [[ -b $RESULT_DEV ]]; then
  dd if="$OUT/report.txt" of="$RESULT_DEV" bs=1M conv=fsync status=none
fi
sync
systemctl poweroff -i
PROBE

unit_text="[Unit]
Description=T1 omarchy-deck-kernel idempotency probe
After=network-online.target
Wants=network-online.target
Before=graphical.target

[Service]
Type=oneshot
Environment=OMARCHY_DECK_NEPTUNE_SERIES=${NEPTUNE_SERIES}
ExecStartPre=/usr/bin/cp /boot/omarchy-deck-idem-probe.sh /root/omarchy-deck-idem-probe.sh
ExecStartPre=/usr/bin/cp /boot/omarchy-deck-kernel.sh /root/omarchy-deck-kernel.sh
ExecStart=/usr/bin/bash /root/omarchy-deck-idem-probe.sh
TimeoutStartSec=0
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console
"
dropin_text="[Unit]
Wants=omarchy-deck-idem.service
"

log "writing payload onto the guest ESP (rootless, mtools at byte offset)"
esp_offset=$(disk_image::esp_offset "$disk") || fail "could not locate the ESP on $disk"
MTOOLS_SKIP_CHECK=1 mcopy -o -i "${disk}@@${esp_offset}" \
  "$SELF_DIR/omarchy-deck-kernel.sh" "::/omarchy-deck-kernel.sh" ||
  fail "mcopy of omarchy-deck-kernel.sh onto the ESP failed"
MTOOLS_SKIP_CHECK=1 mcopy -o -i "${disk}@@${esp_offset}" \
  "$probe_src" "::/omarchy-deck-idem-probe.sh" ||
  fail "mcopy of the probe onto the ESP failed"

# Verify the payload is really on the ESP rather than trusting mcopy's exit
# code — same "verify state, don't trust the tool" rule the script under
# test follows (PLAN.md §8.1).
esp_listing=$(MTOOLS_SKIP_CHECK=1 mdir -b -i "${disk}@@${esp_offset}" "::/" 2>/dev/null)
for f in omarchy-deck-kernel.sh omarchy-deck-idem-probe.sh; do
  grep -qi -- "/$f\$" <<<"$esp_listing" || fail "payload file '$f' is not on the ESP after mcopy"
done
log "payload verified on ESP"

# systemd system credentials via SMBIOS type-11 OEM strings. The binary
# (base64) form is required because unit files contain newlines, which a
# plain OEM string cannot carry.
cred_unit="io.systemd.credential.binary:systemd.extra-unit.omarchy-deck-idem.service=$(base64 -w0 <<<"$unit_text")"
cred_dropin="io.systemd.credential.binary:systemd.unit-dropin.multi-user.target=$(base64 -w0 <<<"$dropin_text")"

# --- boot --------------------------------------------------------------------

log "booting the installed system headless (timeout ${RUN_TIMEOUT}s)"
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
[[ -s $result_txt ]] || fail "the guest wrote nothing to the result device — it never reached the probe. Check $serial_log and $WORK."
log "report: $result_txt"

get_field() { sed -n "s/^$1=//p" "$result_txt" | head -n1; }
rc1=$(get_field run1_exit)
rc2=$(get_field run2_exit)
diff_rc=$(get_field state_diff_exit)

status=0
[[ $rc1 == 0 ]] || { log "run 1 of omarchy-deck-kernel.sh exited $rc1"; status=1; }
[[ $rc2 == 0 ]] || { log "run 2 of omarchy-deck-kernel.sh exited $rc2"; status=1; }
[[ $diff_rc == 0 ]] || { log "end state after run 2 differs from end state after run 1 — NOT idempotent"; status=1; }

if [[ $status -eq 0 ]]; then
  log "PASS — two consecutive runs, both exit 0, byte-identical end state"
else
  log "FAIL — see $result_txt for both runs' output and the state diff"
fi
exit $status

#!/usr/bin/env bash
# T1 steps 4 + 6: prove omarchy-deck-kernel.sh's per-stage CLI is real --
# every stage runnable on its own, idempotent on its own, with an exit code a
# CI caller can assert on, and with no code path that can stop and wait for a
# human. Done in a VM, because "I read the code and it looks non-interactive"
# is exactly the claim this project does not accept.
#
# Usage: ./vm-kernel-stage-test.sh [substrate-image] [work-dir]
#
# The substrate image defaults to ./neptune-substrate.raw and is built by
# vm-neptune-image.sh (read its header for what it is and why it is not a full
# Omarchy Quattro install). If the file is missing this script builds it.
#
# Env vars (all optional):
#   VM_MEM_MB          default 4096
#   VM_SMP             default min(nproc,4)
#   VM_RUN_TIMEOUT_SEC default 3600
#   VM_STAGE_TIMEOUT_SEC default 900  -- per single-stage invocation, in-guest
#   VM_OVMF_CODE / VM_OVMF_VARS  override firmware probing
#   VM_NEPTUNE_SERIES  default 611; must match the image's kernel
#
# WHAT IT ASSERTS, AND WHY EACH ONE IS THERE
#
#   cli             `list-stages` prints exactly the nine stages, in full-run
#                   order. Asserted against a list written out here rather
#                   than read from the script, so a stage silently vanishing
#                   from the CLI is a test failure and not a new baseline.
#                   Plus: --help exits 0, an unknown stage and an unknown
#                   option both exit 2 (usage) and not 1 (failure) -- a CI
#                   caller has to be able to tell "you invoked me wrong" from
#                   "the boot chain is broken" without parsing text.
#
#   pass 1          Every stage invoked ALONE, in order, each under
#                   `setsid --wait timeout ...` with stdin on /dev/null: no
#                   controlling terminal, no stdin, a hard time limit. Each
#                   must exit 0. A stage that blocks on a prompt cannot pass
#                   this -- it gets killed and reports 124.
#
#   pass 2          Every stage invoked alone a second time. Each exits 0 and
#                   the end state is byte-identical to pass 1's. This is
#                   per-stage idempotency: the full-run idempotency proof in
#                   vm-kernel-idempotency-test.sh does not cover it, because
#                   a stage that is only ever reached after its predecessors
#                   can be idempotent in that sequence and not on its own.
#
#   full run        The script with NO arguments, on top of that state. Must
#                   exit 0 and change nothing. This is the regression check
#                   the CLI change needed: stage-by-stage and the full run
#                   converge on the same end state, so deck-sync.sh's loop and
#                   the pacman hook -- both of which call the no-argument form
#                   -- still get what they got before.
#
#   prereqs         The three ways to invoke a stage out of order, each of
#                   which must fail LOUDLY rather than proceed on a guess:
#                   stage-uki with no such kernel installed, stage-kernel with
#                   the Valve repos absent from pacman.conf, and stage-kernel
#                   with a pinned series the repos do not carry. Asserted on
#                   exit code AND on the message naming the stage to run
#                   first, because a non-zero exit with a misleading message
#                   is how the original "the mirror layout may have changed"
#                   failure wasted time.
#
#   nonint          The one code path that could really hang forever: sudo
#                   asking for a password. A user with password-required sudo
#                   is created in the guest, the test first proves `sudo -n`
#                   genuinely fails for them (otherwise the test proves
#                   nothing), and then runs a stage as that user with no tty
#                   and no stdin under a 60s limit. It must exit non-zero
#                   FAST with the non-interactive message -- an exit of 124
#                   means it sat at the prompt and is a failure.
#
#                   Two more stdin shapes, because CI does not always hand you
#                   /dev/null: stdin closed outright (0<&-), and stdin on a
#                   fifo whose writer never writes -- the shape that makes a
#                   stray `read` hang forever instead of seeing EOF. Both must
#                   complete normally.
#
# Everything is injected without root on the host (mtools onto the ESP at a
# byte offset + SMBIOS type-11 systemd credentials) and results come back on a
# raw virtio device -- the same techniques, for the same reasons, as
# vm-kernel-hook-test.sh and vm-kernel-idempotency-test.sh. DMI is spoofed so
# the script's real Steam Deck hardware gate is exercised rather than bypassed.

set -uo pipefail

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=vm-disk-image.sh
source "$SELF_DIR/vm-disk-image.sh"

BASE_DISK=${1:-$SELF_DIR/neptune-substrate.raw}
WORK=${2:-$(mktemp -d /var/tmp/vm-kernel-stage.XXXXXX)}

MEM_MB=${VM_MEM_MB:-4096}
DEFAULT_SMP=$(( $(nproc) < 4 ? $(nproc) : 4 ))
SMP=${VM_SMP:-$DEFAULT_SMP}
RUN_TIMEOUT=${VM_RUN_TIMEOUT_SEC:-3600}
STAGE_TIMEOUT=${VM_STAGE_TIMEOUT_SEC:-900}
SERIES=${VM_NEPTUNE_SERIES:-611}

log() { printf '[vm-kernel-stage] %s\n' "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

# The expected stage list, in full-run order. Deliberately duplicated from the
# script under test: this is the contract deck-sync.sh and any CI caller code
# against, so it changing has to be a decision, not a diff nobody sees.
EXPECTED_STAGES=(
  stage-preconditions
  stage-repos
  stage-esp-detect
  stage-firmware-swap
  stage-kernel
  stage-uki
  stage-prune
  stage-default-entry
  stage-hook
  stage-esp-permissions
)

[[ -f $SELF_DIR/omarchy-deck-kernel.sh ]] || fail "omarchy-deck-kernel.sh not found next to this script"

for tool in qemu-system-x86_64 qemu-img mcopy sfdisk base64; do
  command -v "$tool" >/dev/null || fail "$tool not found"
done

if [[ ! -f $BASE_DISK ]]; then
  log "substrate image not found at $BASE_DISK -- building it"
  IMG_NEPTUNE_SERIES=$SERIES "$SELF_DIR/vm-neptune-image.sh" "$BASE_DISK" ||
    fail "could not build the substrate image"
fi

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
  log "WARNING: /dev/kvm not accessible — falling back to TCG. This test runs every stage three times and rebuilds initramfses; under TCG expect it to exceed the default timeout."
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

probe_src="$WORK/omarchy-deck-stage-probe.sh"
cat >"$probe_src" <<'PROBE'
#!/usr/bin/env bash
# In-guest probe for the per-stage CLI. Deliberately NOT `set -e`: a failure
# of the thing under test is a result to report, not a reason to abort before
# reporting it.
set -uo pipefail

RESULT_DEV=/dev/disk/by-id/virtio-vmresult
OUT=/root/stagetest
mkdir -p "$OUT"
exec >"$OUT/probe.log" 2>&1
exec {xtrace_fd}>>"$OUT/probe.trace"
BASH_XTRACEFD=$xtrace_fd
set -x

STAGE_TIMEOUT=${STAGE_TIMEOUT_SEC:-900}
SERIES=${OMARCHY_DECK_NEPTUNE_SERIES:-611}
KP="linux-neptune-${SERIES}"

# Nothing may execute out of /boot: bash holds an open fd on the script it is
# running, which makes the ESP busy and breaks stage-esp-permissions' umount
# for a reason that has nothing to do with the system under test.
SCRIPT=/root/omarchy-deck-kernel.sh
[[ -f $SCRIPT ]] || exit 90

RESULTS=$OUT/results
: >"$RESULTS"
emit() { printf '%s\n' "$*" >>"$RESULTS"; }

online=0
for _ in $(seq 1 60); do
  if getent hosts steamdeck-packages.steamos.cloud >/dev/null 2>&1; then online=1; break; fi
  sleep 5
done
emit "network_resolved=$online"

# run_isolated <logfile> <args...> -- the invocation shape every stage run in
# this test uses. `setsid --wait` gives the run no controlling terminal, so
# sudo (which reads /dev/tty, not stdin) has nowhere to prompt; </dev/null
# gives it no stdin; `timeout` turns a hang into a reported 124 instead of a
# test that never ends. Exit status is the script's own.
run_isolated() {
  local logfile=$1
  shift
  setsid --wait timeout "$STAGE_TIMEOUT" "$@" >"$logfile" 2>&1 </dev/null
}

# Snapshot every piece of state a stage can touch. Content-hashed and sorted so
# it is order-independent; ESP file mtimes are excluded (mkinitcpio's UKI output
# is byte-reproducible, so hashes are the meaningful comparison there) but the
# two hook artifacts DO carry mtime, because stage_hook's whole claim is that a
# re-run does not rewrite them.
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
    echo "== hook artifacts (name size mtime mode) =="
    stat -c '%n %s %Y %a' /etc/pacman.d/hooks/95-omarchy-deck-kernel.hook \
      /usr/local/bin/omarchy-deck-kernel 2>&1
    sha256sum /etc/pacman.d/hooks/95-omarchy-deck-kernel.hook \
      /usr/local/bin/omarchy-deck-kernel 2>&1
    echo "== limine boot menu tree =="
    limine-entry-tool --no-hooks --no-mutex --tree 5 2>&1 | sed 's/[[:space:]]*$//'
  } >"$OUT/state.$tag" 2>&1
}

# --- 0. CLI surface (no state change) ----------------------------------------

run_isolated "$OUT/list-stages.out" bash "$SCRIPT" list-stages
emit "cli.list_stages_exit=$?"
emit "cli.list_stages=$(tr '\n' ' ' <"$OUT/list-stages.out" | sed 's/ *$//')"

run_isolated "$OUT/help.out" bash "$SCRIPT" --help
emit "cli.help_exit=$?"

run_isolated "$OUT/unknown-stage.out" bash "$SCRIPT" stage-nope
emit "cli.unknown_stage_exit=$?"
emit "cli.unknown_stage_lists=$(grep -qF 'stage-esp-permissions' "$OUT/unknown-stage.out" && echo 1 || echo 0)"

run_isolated "$OUT/unknown-opt.out" bash "$SCRIPT" --definitely-not-an-option
emit "cli.unknown_option_exit=$?"

# The task file's superseded names must not silently map onto a real stage.
run_isolated "$OUT/stale-name.out" bash "$SCRIPT" stage-bootloader
emit "cli.stale_name_exit=$?"

snapshot before

# --- 1 + 2. every stage alone, twice -----------------------------------------

mapfile -t STAGES <"$OUT/list-stages.out"

for pass in 1 2; do
  for st in "${STAGES[@]}"; do
    [[ -n $st ]] || continue
    run_isolated "$OUT/pass${pass}.${st}.out" bash "$SCRIPT" "$st"
    emit "pass${pass}.${st}.exit=$?"
  done
  snapshot "pass${pass}"
done

diff -u "$OUT/state.pass1" "$OUT/state.pass2" >"$OUT/state.pass1-vs-pass2.diff" 2>&1
emit "stage_pass_diff_exit=$?"

# --- 3. the full run, on top of stage-by-stage -------------------------------

run_isolated "$OUT/fullrun.out" bash "$SCRIPT"
emit "fullrun_exit=$?"
snapshot full

diff -u "$OUT/state.pass2" "$OUT/state.full" >"$OUT/state.pass2-vs-full.diff" 2>&1
emit "full_vs_stages_diff_exit=$?"

# --- 4. missing prerequisites must fail loudly, not guess --------------------

# 4a. stage-uki for a kernel that is not installed.
run_isolated "$OUT/prereq-uki.out" env OMARCHY_DECK_NEPTUNE_SERIES=999 bash "$SCRIPT" stage-uki
emit "prereq.uki_exit=$?"
emit "prereq.uki_names_stage_kernel=$(grep -qF 'stage-kernel' "$OUT/prereq-uki.out" && echo 1 || echo 0)"

# 4b. stage-kernel with the Valve repos removed from pacman.conf. Restored
# immediately afterwards, and the restore is verified -- a test that leaves the
# system it is measuring in a different state than it found it would poison
# every assertion after it.
cp /etc/pacman.conf "$OUT/pacman.conf.orig"
awk '
  /^\[jupiter-staging\]/ || /^\[holo-staging\]/ { skip = 1; next }
  /^\[/ { skip = 0 }
  !skip { print }
' "$OUT/pacman.conf.orig" >/etc/pacman.conf
emit "prereq.repos_stripped=$(grep -qE '^\[jupiter-staging\]' /etc/pacman.conf && echo 0 || echo 1)"

run_isolated "$OUT/prereq-repos.out" bash "$SCRIPT" stage-kernel
emit "prereq.norepos_exit=$?"
emit "prereq.norepos_names_stage_repos=$(grep -qF 'stage-repos' "$OUT/prereq-repos.out" && echo 1 || echo 0)"

# stage-firmware-swap in the same state must stay a no-op: there is nothing of
# Arch's left to displace, so it never reaches the repo requirement. A no-op
# stage that started failing because of a prerequisite it does not use would be
# a regression in the other direction.
run_isolated "$OUT/prereq-fw.out" bash "$SCRIPT" stage-firmware-swap
emit "prereq.firmware_noop_exit=$?"

cp "$OUT/pacman.conf.orig" /etc/pacman.conf
emit "prereq.repos_restored=$(cmp -s "$OUT/pacman.conf.orig" /etc/pacman.conf && echo 1 || echo 0)"

# 4c. a pinned series the repos do not carry.
run_isolated "$OUT/prereq-series.out" env OMARCHY_DECK_NEPTUNE_SERIES=999 bash "$SCRIPT" stage-kernel
emit "prereq.badseries_exit=$?"
emit "prereq.badseries_lists_available=$(grep -qF "linux-neptune-${SERIES}" "$OUT/prereq-series.out" && echo 1 || echo 0)"

# --- 5. non-interactivity, actually tested -----------------------------------

# A user whose sudo requires a password. Without this the sudo branch under
# test is never reached and the whole section would be vacuous.
useradd -m -s /bin/bash tester 2>>"$OUT/nonint-setup.log"
echo 'tester:hunter2hunter2' | chpasswd 2>>"$OUT/nonint-setup.log"
rm -f /etc/sudoers.d/tester
printf 'tester ALL=(ALL) ALL\n' >/etc/sudoers.d/nonint-tester
chmod 0440 /etc/sudoers.d/nonint-tester

# /root is 0700; give tester its own readable copy rather than loosening /root.
install -m 0755 "$SCRIPT" /tmp/omarchy-deck-kernel.sh

setsid --wait timeout 30 su - tester -c 'sudo -n true' </dev/null >>"$OUT/nonint-setup.log" 2>&1
emit "nonint.sudo_n_fails_for_tester=$([[ $? -ne 0 ]] && echo 1 || echo 0)"

# The real test: no controlling terminal, no stdin, hard 60s limit. Before the
# fix this reached a bare `sudo true`, which reads /dev/tty and would sit
# there; the pass condition is a fast, specific, non-zero exit -- 124 (killed
# by timeout) is a failure, and so is 0.
start=$(date +%s)
setsid --wait timeout 60 su - tester -c 'bash /tmp/omarchy-deck-kernel.sh stage-repos' \
  </dev/null >"$OUT/nonint-user.out" 2>&1
emit "nonint.user_exit=$?"
emit "nonint.user_seconds=$(( $(date +%s) - start ))"
emit "nonint.user_message=$(grep -qF 'non-interactive run' "$OUT/nonint-user.out" && echo 1 || echo 0)"

# stdin closed outright.
setsid --wait timeout "$STAGE_TIMEOUT" bash "$SCRIPT" stage-prune >"$OUT/nonint-closed.out" 2>&1 0<&-
emit "nonint.stdin_closed_exit=$?"

# stdin on a fifo whose writer never writes: the shape in which a stray read
# blocks forever rather than seeing EOF. stage-kernel is used because it is the
# stage that spawns pacman, so this also covers what a child inherits.
mkfifo "$OUT/blocking.fifo" 2>/dev/null
# Held open read-write by the probe itself. A read-write open of a fifo never
# blocks, and it keeps a writer alive so the child's read-only open returns
# immediately -- but nothing is ever written, so anything that tries to read
# waits forever. Deliberately not `sleep > fifo &`: that rendezvous can leave
# the probe wedged at open() with no report ever produced, which is a worse
# failure mode than the bug it is looking for.
exec {fifo_fd}<>"$OUT/blocking.fifo"
setsid --wait timeout "$STAGE_TIMEOUT" bash "$SCRIPT" stage-kernel \
  >"$OUT/nonint-fifo.out" 2>&1 <"$OUT/blocking.fifo"
emit "nonint.stdin_blocking_fifo_exit=$?"
exec {fifo_fd}>&-

# Nothing above may have disturbed the end state.
snapshot final
diff -u "$OUT/state.full" "$OUT/state.final" >"$OUT/state.full-vs-final.diff" 2>&1
emit "final_state_diff_exit=$?"

{
  echo "=== OMARCHY-DECK-KERNEL PER-STAGE CLI PROBE ==="
  cat "$RESULTS"
  echo "=== LIST-STAGES ==="
  cat "$OUT/list-stages.out"
  echo "=== UNKNOWN STAGE ==="
  cat "$OUT/unknown-stage.out"
  echo "=== PASS 1 (each stage alone) ==="
  for st in "${STAGES[@]}"; do
    [[ -n $st ]] || continue
    echo "--- $st ---"
    cat "$OUT/pass1.${st}.out"
  done
  echo "=== PASS 2 (each stage alone, again) ==="
  for st in "${STAGES[@]}"; do
    [[ -n $st ]] || continue
    echo "--- $st ---"
    cat "$OUT/pass2.${st}.out"
  done
  echo "=== STATE DIFF pass1 vs pass2 ==="
  cat "$OUT/state.pass1-vs-pass2.diff"
  echo "=== FULL RUN ==="
  cat "$OUT/fullrun.out"
  echo "=== STATE DIFF pass2 vs full run ==="
  cat "$OUT/state.pass2-vs-full.diff"
  echo "=== PREREQ: stage-uki without the kernel ==="
  cat "$OUT/prereq-uki.out"
  echo "=== PREREQ: stage-kernel without the repos ==="
  cat "$OUT/prereq-repos.out"
  echo "=== PREREQ: stage-firmware-swap without the repos (no-op) ==="
  cat "$OUT/prereq-fw.out"
  echo "=== PREREQ: stage-kernel with an unavailable series ==="
  cat "$OUT/prereq-series.out"
  echo "=== NONINT: unprivileged user, no tty, no stdin ==="
  cat "$OUT/nonint-user.out"
  echo "=== NONINT: stdin closed ==="
  cat "$OUT/nonint-closed.out"
  echo "=== NONINT: stdin on a blocking fifo ==="
  cat "$OUT/nonint-fifo.out"
  echo "=== STATE DIFF full vs final ==="
  cat "$OUT/state.full-vs-final.diff"
  echo "=== BEFORE -> PASS1 (proof the pass is not vacuous) ==="
  diff -u "$OUT/state.before" "$OUT/state.pass1" 2>&1 | head -n 400
  echo "=== JOURNAL (omarchy-deck-kernel) ==="
  journalctl -t omarchy-deck-kernel --no-pager 2>&1 | tail -n 50
  echo "=== END ==="
} >"$OUT/report.txt" 2>&1

if [[ -b $RESULT_DEV ]]; then
  dd if="$OUT/report.txt" of="$RESULT_DEV" bs=1M conv=fsync status=none
fi
sync
systemctl poweroff -i
PROBE

unit_text="[Unit]
Description=T1 omarchy-deck-kernel per-stage CLI probe
After=network-online.target
Wants=network-online.target
Before=graphical.target

[Service]
Type=oneshot
Environment=OMARCHY_DECK_NEPTUNE_SERIES=${SERIES}
Environment=STAGE_TIMEOUT_SEC=${STAGE_TIMEOUT}
ExecStartPre=/usr/bin/cp /boot/omarchy-deck-stage-probe.sh /root/omarchy-deck-stage-probe.sh
ExecStartPre=/usr/bin/cp /boot/omarchy-deck-kernel.sh /root/omarchy-deck-kernel.sh
ExecStart=/usr/bin/bash /root/omarchy-deck-stage-probe.sh
TimeoutStartSec=0
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console
"
dropin_text="[Unit]
Wants=omarchy-deck-stage.service
"

log "writing payload onto the guest ESP (rootless, mtools at byte offset)"
esp_offset=$(disk_image::esp_offset "$disk") || fail "could not locate the ESP on $disk"
MTOOLS_SKIP_CHECK=1 mcopy -o -i "${disk}@@${esp_offset}" \
  "$SELF_DIR/omarchy-deck-kernel.sh" "::/omarchy-deck-kernel.sh" ||
  fail "mcopy of omarchy-deck-kernel.sh onto the ESP failed"
MTOOLS_SKIP_CHECK=1 mcopy -o -i "${disk}@@${esp_offset}" \
  "$probe_src" "::/omarchy-deck-stage-probe.sh" ||
  fail "mcopy of the probe onto the ESP failed"

esp_listing=$(MTOOLS_SKIP_CHECK=1 mdir -b -i "${disk}@@${esp_offset}" "::/" 2>/dev/null)
for f in omarchy-deck-kernel.sh omarchy-deck-stage-probe.sh; do
  grep -qi -- "/$f\$" <<<"$esp_listing" || fail "payload file '$f' is not on the ESP after mcopy"
done
log "payload verified on ESP"

cred_unit="io.systemd.credential.binary:systemd.extra-unit.omarchy-deck-stage.service=$(base64 -w0 <<<"$unit_text")"
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
[[ -s $result_txt ]] || fail "the guest wrote nothing to the result device — it never reached the probe. Check $serial_log and $WORK."
log "report: $result_txt"

# Exact-prefix lookup rather than a regex: the keys contain dots and hyphens,
# and a regex match on those would also accept a line this test never emitted.
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
check_not() {
  local what=$1 got=$2 unwanted=$3
  if [[ $got != "$unwanted" ]]; then
    log "ok   ${what} = ${got} (not ${unwanted})"
  else
    log "FAIL ${what} = '${got}', which is exactly what must not happen"
    status=1
  fi
}

# Reported as itself: without network stage-repos cannot `pacman -Sy` and every
# later assertion fails for a reason that has nothing to do with the CLI.
check "network_resolved" "$(field network_resolved)" 1

# 0. CLI surface
check "cli.list_stages_exit"    "$(field cli.list_stages_exit)" 0
check "cli.list_stages"         "$(field cli.list_stages)" "${EXPECTED_STAGES[*]}"
check "cli.help_exit"           "$(field cli.help_exit)" 0
check "cli.unknown_stage_exit"  "$(field cli.unknown_stage_exit)" 2
check "cli.unknown_stage_lists" "$(field cli.unknown_stage_lists)" 1
check "cli.unknown_option_exit" "$(field cli.unknown_option_exit)" 2
check "cli.stale_name_exit"     "$(field cli.stale_name_exit)" 2

# 1 + 2. every stage alone, twice, each exiting 0
for pass in 1 2; do
  for st in "${EXPECTED_STAGES[@]}"; do
    check "pass${pass}.${st}.exit" "$(field "pass${pass}.${st}.exit")" 0
  done
done
check "stage_pass_diff_exit" "$(field stage_pass_diff_exit)" 0

# 3. the full run still converges on the same end state
check "fullrun_exit"              "$(field fullrun_exit)" 0
check "full_vs_stages_diff_exit"  "$(field full_vs_stages_diff_exit)" 0

# 4. missing prerequisites fail loudly and name the stage to run
check     "prereq.uki_exit"                  "$(field prereq.uki_exit)" 1
check     "prereq.uki_names_stage_kernel"    "$(field prereq.uki_names_stage_kernel)" 1
check     "prereq.repos_stripped"            "$(field prereq.repos_stripped)" 1
check     "prereq.norepos_exit"              "$(field prereq.norepos_exit)" 1
check     "prereq.norepos_names_stage_repos" "$(field prereq.norepos_names_stage_repos)" 1
check     "prereq.firmware_noop_exit"        "$(field prereq.firmware_noop_exit)" 0
check     "prereq.repos_restored"            "$(field prereq.repos_restored)" 1
check     "prereq.badseries_exit"            "$(field prereq.badseries_exit)" 1
check     "prereq.badseries_lists_available" "$(field prereq.badseries_lists_available)" 1

# 5. no prompt can block, proven rather than asserted
check     "nonint.sudo_n_fails_for_tester"   "$(field nonint.sudo_n_fails_for_tester)" 1
check_not "nonint.user_exit"                 "$(field nonint.user_exit)" 124
check_not "nonint.user_exit"                 "$(field nonint.user_exit)" 0
check     "nonint.user_message"              "$(field nonint.user_message)" 1
check     "nonint.stdin_closed_exit"         "$(field nonint.stdin_closed_exit)" 0
check     "nonint.stdin_blocking_fifo_exit"  "$(field nonint.stdin_blocking_fifo_exit)" 0
check     "final_state_diff_exit"            "$(field final_state_diff_exit)" 0

nonint_seconds=$(field nonint.user_seconds)
log "note: the unprivileged non-interactive run returned in ${nonint_seconds}s (a prompt would have burned the full 60s limit)"

if [[ $status -eq 0 ]]; then
  log "PASS — every stage runs alone and is idempotent alone, the full run converges on the same state, missing prerequisites fail loudly, and no invocation can wait for a human"
else
  log "FAIL — see $result_txt"
fi
exit $status

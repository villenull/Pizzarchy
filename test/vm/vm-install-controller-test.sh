#!/usr/bin/env bash
# vm-install-controller-test.sh -- phase 2 exit criterion 1, closed for real:
# drives the REAL Deck-forked ISO's controller-only installer past the point
# test/vm/vm-installer-screens-test.sh deliberately stopped at (S5's
# "Ready to install?" gate, docs/findings/T4-controller-only-install-first-run.md
# §7), through write_user_files, through a REAL (properly sized and aligned,
# not the screens harness's deliberately-tiny 64M) full-disk install, and
# then asserts against the RESULTING DISK IMAGE -- partition table, ESP
# UKI(s), Limine config, installed package set -- using the same
# disk-image-assertion model test/vm/vm-install-test.sh already established
# (PLAN.md §8.1: never trust log text; upstream has printed "success" while
# doing nothing before).
#
# Usage: ./vm-install-controller-test.sh <iso-path> [work-dir]
#
# Env vars (all optional):
#   VM_DISK_SIZE_GB          target disk size, default 16 (matches
#                             vm-install-test.sh's own default)
#   VM_MEM_MB / VM_SMP        guest size, defaults 4096 / 4
#   VM_RUN_TIMEOUT_SEC        whole-run ceiling, default 2700 (45 min --
#                             boot + wizard navigation + a real offline
#                             package install + finish animation)
#   VM_INSTALL_POLL_DEADLINE_SEC  the IN-GUEST ceiling for "is the real
#                             install done yet", default 2100 (35 min)
#   VM_OVMF_CODE / VM_OVMF_VARS   override firmware probing
#   VM_KEEP_WORK=1            never delete the work dir, even on success
#
# ===========================================================================
# WHY THIS IS A NEW FILE, NOT AN EXTENSION OF vm-installer-screens-test.sh
# ===========================================================================
#
# vm-installer-screens-test.sh's own header explains why IT never attaches a
# second, real-sized writable disk: its only virtio-blk device doubles as
# the report carrier AND is deliberately the sole eligible install disk, kept
# small (64M) and misaligned ON PURPOSE so a real install attempt on it fails
# FAST rather than slowly succeeding at wiping a device meant only to carry a
# report. That test's whole safety model depends on the install NEVER
# actually completing.
#
# This file inverts that on purpose: ITS whole point is to let the real
# install complete. So there is no "report device" here at all -- the guest
# reports everything over the serial line (see PROBE STREAMING below), which
# leaves the machine's only virtio-blk-pci device free to be a realistic,
# 1MiB-aligned target disk, exactly like vm-install-test.sh's own `target.qcow2`.
# `deck-form.sh`'s own `deck_form_disk_list` (RM==0 && TYPE==disk, boot medium
# excluded by exact device-path match against `get_root_disk`) then finds
# exactly one eligible disk here too -- the CD-ROM boot medium is TYPE=rom and
# never enters the list at all -- so `disk_form` auto-skips the picker exactly
# the way it did in the screens harness, and the proven step-for-step key
# sequence through S0-S5 (steps 1-28 below) is REUSED VERBATIM from
# docs/findings/T4-controller-only-install-first-run.md's measured flow, not
# re-derived. New here: step 29 (S5's OWN "y" hotkey, crossing into
# write_user_files), an unbounded POLL for the real install's completion
# (unlike the screens harness's fixed 6s cadence -- a real install's duration
# is not knowable in advance), and step 30 (accepting
# omarchy-install-dashboard's own "Reboot Now" prompt, upstream's, not
# deck-form.sh's -- see REBOOT PROMPT below).
#
# ===========================================================================
# WHY THIS DOES NOT NEED NETWORK, AND WHY THAT IS NOT AN ASSUMPTION
# ===========================================================================
#
# READ, not inferred: `iso/upstream/configs/airootfs/usr/share/omarchy-iso/
# orchestrator/phases_impl.py:190` hardcodes `arch.make_mirror_handler(offline=True)`
# for every install this orchestrator ever runs, and `_mount_offline_package_cache`
# (phases_impl.py:641) bind-mounts `/var/cache/omarchy/mirror/offline` --
# a mirror the ISO carries WITH IT -- into the target for pacman to read
# during the real install. `configurator`'s own comment
# (`.automated_script.sh:60-66`) puts a number on it: "the install reads
# ~3GB out of the offline mirror." So the real, full-disk install this file
# drives is bounded, local-I/O-only, and does not depend on this dev
# machine's network reaching anything -- consistent with S5's own on-screen
# text (already proven in docs/findings/T4-controller-only-install-first-run.md
# §7): "Without a network the install still completes." This file boots with
# `-nic none`, matching vm-install-test.sh's own precedent, specifically so a
# pass here cannot be quietly explained by "well, it could reach the
# internet" -- it can't, and it still has to finish.
#
# ===========================================================================
# THE REBOOT PROMPT -- upstream's, not deck-form.sh's, and why that matters
# ===========================================================================
#
# READ, `iso/upstream/configs/airootfs/usr/local/bin/omarchy-install-dashboard`:
# after write_user_files, `.automated_script.sh` (unconditionally, no keypress
# needed) hands off to `omarchy-install-dashboard`, which launches the real
# installer as a child, renders progress, and on success renders
# `render_finish` ("Installed Omarchy in <duration>") followed by
# `reboot_prompt()` -- a **plain upstream `gum confirm`**
# (`--default --affirmative "Reboot Now" --negative ""`), not one of
# deck-form.sh's own screens (T4-screen-spec.md's own S6/S7 gap: the
# dashboard is a SEPARATE PROCESS deck-form.sh is never sourced into --
# see that file's own "NOT built, and why" section). `--default` here means
# affirmative, so a bare Enter accepts "Reboot Now" without needing to know
# whether `y` is bound in this specific invocation (its `--show-help=false`
# means the y/n footer text that S4/S5's OWN screens print is not
# necessarily proof that THIS gum confirm call accepts `y` at all -- Enter
# submitting the already-highlighted default is the only behaviour this file
# relies on, and it is exactly the behaviour session 23 already measured
# `gum confirm --default=...=false` NOT doing, on the opposite default).
# On accept: `reboot 2>/dev/null || systemctl reboot ...` -- and this file
# boots QEMU with `-no-reboot` (same as both sibling harnesses), which
# EXITS the QEMU process instead of actually rebooting the guest. That is
# the completion signal this file waits for, exactly like
# vm-install-test.sh's own "QEMU's process exits" model.
#
# ===========================================================================
# PROBE STREAMING -- why captures go over the serial line, not a report device
# ===========================================================================
#
# A successful run ends with the GUEST triggering its own reset (see above),
# which -- because there is no report-carrying block device connected to be
# consulted first -- means anything the probe would batch up for a
# single end-of-run dump (the pattern both sibling harnesses use) could be
# lost if the reset races the dump. So the injected probe here streams every
# fact and every capture it takes OVER SERIAL, AS IT HAPPENS
# (`T4PROBE:FACT:key=value` / `T4PROBE:CAP:name:<base64>`), and the host
# reconstructs a screens::extract_section-compatible report.txt from the
# already-being-written serial.log after the guest is gone -- so a run that
# dies mid-install (a real failure, a timeout, a QEMU crash) still leaves
# every fact and capture taken up to that point on disk, in $WORK/serial.log,
# rather than losing all of it to an un-flushed final write. The report
# reconstruction reuses test/lib/vm-installer-screens.sh's OWN primitives
# (screens::field, screens::extract_section, screens::marker_present,
# screens::advance_and_vanish, screens::check/denominator) -- this file does
# not reimplement checking logic the mutation-tested library already owns.
#
# ===========================================================================

set -uo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

# shellcheck source=../lib/vm-installer-screens.sh
source "$REPO_ROOT/test/lib/vm-installer-screens.sh"
# shellcheck source=../lib/vm-disk-image.sh
source "$REPO_ROOT/test/lib/vm-disk-image.sh"
# shellcheck source=../lib/vm-assertions.sh
source "$REPO_ROOT/test/lib/vm-assertions.sh"
# shellcheck source=../lib/vm-outcome-assertions.sh
source "$REPO_ROOT/test/lib/vm-outcome-assertions.sh"

ISO=${1:?"usage: $0 <iso-path> [work-dir]"}
WORK=${2:-$(mktemp -d /var/tmp/vm-install-controller.XXXXXX)}

DISK_SIZE_GB=${VM_DISK_SIZE_GB:-16}
MEM_MB=${VM_MEM_MB:-4096}
SMP=${VM_SMP:-4}
RUN_TIMEOUT=${VM_RUN_TIMEOUT_SEC:-2700}
INSTALL_POLL_DEADLINE=${VM_INSTALL_POLL_DEADLINE_SEC:-2100}

log() { printf '[vm-install-controller] %s\n' "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

[[ -f $ISO ]] || fail "ISO not found: $ISO (do not download one -- pass an existing path as \$1)"
# `7z` is NOT optional, and the reason is the whole point of this run: the
# live-ISO half of the outcome assertions reads the ISO's own squashfs to ask
# whether the on-screen keyboard is actually in the image. A suite that
# quietly skipped that when the reader was missing would be silent about
# precisely the check that inspects the shipped artifact -- which is how
# omarchy-2026.08.15 shipped installer screens and no keyboard
# (docs/findings/P32-osk-mapper-missing-from-live-iso.md). Same reasoning
# test/unit/test-iso-build.sh records for bsdtar.
for tool in qemu-system-x86_64 qemu-img socat base64 python3 awk jq mdir mcopy udisksctl sfdisk 7z; do
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
  log "WARNING: /dev/kvm not accessible -- falling back to TCG (slow). A real install under TCG may need a much larger VM_RUN_TIMEOUT_SEC/VM_INSTALL_POLL_DEADLINE_SEC."
  ACCEL_ARGS=(-cpu max -machine "q35,accel=tcg")
fi

mkdir -p "$WORK"
log "work dir: $WORK"
log "iso:      $ISO"
log "target disk: ${DISK_SIZE_GB}G (real, 1MiB-aligned -- NOT the screens harness's deliberately tiny/misaligned report device)"

ovmf_vars="$WORK/OVMF_VARS.fd"
target_disk="$WORK/target.qcow2"
target_raw="$WORK/target.raw"
serial_log="$WORK/serial.log"
report_txt="$WORK/report.txt"
qmp_sock="$WORK/qmp.sock"
pidfile="$WORK/qemu.pid"

cp "$OVMF_VARS_TEMPLATE" "$ovmf_vars"
qemu-img create -f qcow2 "$target_disk" "${DISK_SIZE_GB}G" >/dev/null

# --- the in-guest probe -------------------------------------------------
#
# See this file's own "PROBE STREAMING" header section for why everything
# goes over $SER rather than to a report device. `say` mirrors both sibling
# harnesses' own convention (a "T4PROBE:" line prefix); `fact`/`cap` are new
# here, both still just `say` under the hood so the host's serial_log is the
# single source of truth for everything the probe ever observed.

probe_src="$WORK/probe.sh"
# Watchdog fires comfortably before the HOST's own RUN_TIMEOUT would kill the
# VM out from under it, so a hung probe still leaves a fact trail on serial
# before that happens, rather than the host just seeing silence.
probe_watchdog_sec=$((RUN_TIMEOUT > 300 ? RUN_TIMEOUT - 180 : RUN_TIMEOUT))
# First block UNQUOTED on purpose -- these two values come from the HOST's
# own env-var-configurable variables ($RUN_TIMEOUT / $INSTALL_POLL_DEADLINE)
# and must be baked in as real numbers, not re-guessed inside the guest.
cat >"$probe_src" <<PROBE_HEAD
#!/usr/bin/env bash
set -uo pipefail
readonly PROBE_WATCHDOG_SEC=${probe_watchdog_sec}
readonly PROBE_INSTALL_DEADLINE=${INSTALL_POLL_DEADLINE}
PROBE_HEAD
cat >>"$probe_src" <<'PROBE'
SER=/dev/ttyS0
say()  { printf 'T4PROBE:%s\n' "$*" >"$SER" 2>/dev/null; }
fact() { say "FACT:$*"; }
# cap <name>: snapshots /dev/vcs1 (fresh geometry every time -- never cache,
# T4-harness-feasibility.md's own §2.3 lesson, already load-bearing for the
# sibling harness this reuses the convention from) and streams it as one
# base64 line. Small (a console frame is a few KB raw, ~10KB base64) --
# deliberately called only at the handful of points this file actually needs
# evidence for, not on every poll tick (see the post-gate loop below).
cap() {
  local name=$1 cols tmp geom_rows_unused
  # shellcheck disable=SC2034  # geom_rows_unused is read for its side effect
  # on $cols only -- this probe streams captures, not geometry facts, unlike
  # the sibling screens harness's snap()
  read -r geom_rows_unused cols <<<"$(python3 - <<'PY' 2>/dev/null || echo "0 0"
try:
    d = open('/dev/vcsa1', 'rb').read(4)
    print(d[0], d[1])
except Exception:
    print(0, 0)
PY
)"
  [[ ${cols:-0} -gt 0 ]] || cols=0
  tmp=$(mktemp)
  if (( cols > 0 )); then
    fold -w "$cols" </dev/vcs1 >"$tmp" 2>/dev/null
  else
    cat </dev/vcs1 >"$tmp" 2>/dev/null
  fi
  say "CAP:${name}:$(base64 -w0 "$tmp")"
  rm -f "$tmp"
}

say "UNIT-RAN"
fact "unit.ran=1"

# --- A6-equivalent environment invariants -----------------------------------
fact "deck_form_present=$([[ -f /usr/share/omarchy-iso/deck-form.sh ]] && echo 1 || echo 0)"
fact "hid_steam.loaded=$([[ -d /sys/module/hid_steam ]] && echo 1 || echo 0)"

# --- watchdog: a probe that hangs must still leave a fact trail -------------
(
  sleep "$PROBE_WATCHDOG_SEC"
  fact "watchdog.fired=1"
  say "DONE"
  sync
  systemctl poweroff -i
) &
WATCHDOG_PID=$!
trap 'kill "$WATCHDOG_PID" 2>/dev/null' EXIT

# --- wait for the Deck greeter (same marker, same reasoning, as the sibling
# screens harness: deck-form.sh's greeter() replaces upstream's own prompt
# line entirely) ---------------------------------------------------------
waited=0
found=0
while (( waited < 300 )); do
  if LC_ALL=C command grep -qa 'Press A to begin' /dev/vcs1 2>/dev/null; then
    found=1
    break
  fi
  sleep 2
  waited=$((waited + 2))
done
fact "greeter.wait_s=$waited"
fact "greeter.found=$found"
cap 00-greeter

# --- steps 1-28: REUSED VERBATIM from
# docs/findings/T4-controller-only-install-first-run.md's measured flow /
# test/vm/vm-installer-screens-test.sh's own STEPS array -- same qcodes, same
# order, same 6s cadence. Only a subset is captured+streamed here (enough to
# prove real navigation happened); the exhaustive per-character/guard
# battery already lives in, and passed in, that sibling suite -- this file's
# job starts where that one deliberately stopped (S5's gate), not to
# re-litigate S0-S5.
STEPS="01-kb-us:ret 02-kb-uk:down 03-username-empty:ret \
04-username-empty-2:ret 05-username-empty-3:ret 06-username-empty-4:ret \
07-username-d:d 08-username-de:e 09-username-dec:c 10-username-deck:k \
11-password-empty:ret 12-password-1:p 13-password-2:a 14-password-3:s 15-password-4:s \
16-confirm-empty:ret 17-confirm-1:p 18-confirm-2:a 19-confirm-3:s 20-confirm-4:s \
21-fullname:ret 22-email:ret 23-hostname:ret 24-timezone-list:ret \
25-summary:ret 26-disk-confirm:ret 27-disk-confirm-holds:ret 28-deck-summary:y"
STREAM_CAPTURES="03-username-empty 10-username-deck 11-password-empty 25-summary 26-disk-confirm 27-disk-confirm-holds 28-deck-summary"

i=0
for step in $STEPS; do
  i=$((i + 1))
  name=${step%%:*}
  # "-GO" suffix: load-bearing anchor against CRLF line endings on
  # /dev/ttyS0, same reasoning as the sibling harness's identical comment.
  say "WANT-KEY-${i}-GO"
  sleep 6
  for want in $STREAM_CAPTURES; do
    [[ $want == "$name" ]] && cap "$name"
  done
done
fact "steps.sent=$i"

# --- step 29 (NEW): S5's own "y" ("Install") hotkey, crossing
# deck_final_summary's gate into write_user_files -- the point every
# previous run of this project's harnesses has deliberately stopped short
# of. -------------------------------------------------------------------
i=$((i + 1))
say "WANT-KEY-${i}-GO"
sleep 3
cap 29-post-install-start
fact "steps.sent=$i"

# --- the real install: unbounded poll, not a fixed sleep -- a real
# offline package install's duration is not knowable in advance the way a
# scripted gum prompt's redraw is. Heartbeats keep serial.log a useful
# forensic trail even for a run that never reaches a terminal state. --------
DEADLINE=$PROBE_INSTALL_DEADLINE
POLL_INTERVAL=8
HEARTBEAT_INTERVAL=60
waited=0
last_heartbeat=0
outcome=timeout
while (( waited < DEADLINE )); do
  if LC_ALL=C command grep -qa 'Installed Omarchy in' /dev/vcs1 2>/dev/null; then
    outcome=success
    cap 30-finish
    break
  fi
  if LC_ALL=C command grep -qa 'Omarchy installation stopped' /dev/vcs1 2>/dev/null; then
    outcome=failure
    cap 30-failure
    break
  fi
  if (( waited - last_heartbeat >= HEARTBEAT_INTERVAL )); then
    fact "install.heartbeat_waited_s=$waited"
    last_heartbeat=$waited
  fi
  sleep "$POLL_INTERVAL"
  waited=$((waited + POLL_INTERVAL))
done
fact "install.outcome=$outcome"
fact "install.waited_s=$waited"

if [[ $outcome == success ]]; then
  # step 30: accept omarchy-install-dashboard's OWN "Reboot Now" prompt
  # (plain upstream gum confirm, --default true -- see this file's own
  # header "REBOOT PROMPT" section for why Enter, not 'y', is sent here).
  i=$((i + 1))
  say "WANT-KEY-${i}-GO"
  fact "steps.sent=$i"
  sleep 3
  cap 31-post-reboot-accept
  # The guest's own `reboot`/`systemctl reboot` fires from here; with
  # -no-reboot on the host side that ends the QEMU process. Nothing further
  # to do -- do not race it with more work.
elif [[ $outcome == failure ]]; then
  # ⚠️ SAME DISCIPLINE AS THE SIBLING SCREENS HARNESS: interactive() is true
  # here (this is the wizard path, not cidata), so upstream's failure_menu's
  # default cursor is "Upload log for support" -- this file sends NO further
  # key once a failure is observed, on purpose. The run stops here; the host
  # script's own RUN_TIMEOUT eventually reclaims the VM.
  fact "failure.no_further_key_sent=1"
fi

say "DONE"
sync
PROBE

# --- the injected unit -------------------------------------------------------
#
# ⚠️ MEASURED, not the sibling harness's own choice copied blind: this probe
# is ordered After=basic.target, NOT After=multi-user.target like
# vm-installer-screens-test.sh's probe. A real run of THIS file (offline,
# -nic none, on purpose -- see this file's own header) found that
# multi-user.target never reaches "active" at all when there is no network
# device of any kind: systemd-time-wait-sync.service blocks on it forever
# (no NTP source ever answers), and with no route to it multi-user.target's
# own job sits "start waiting" indefinitely (confirmed live via a root shell
# on tty2: `systemctl list-jobs` showed job 2 (multi-user.target) and job
# 67 (systemd-time-wait-sync.service, "start running") both stuck; `systemd-
# analyze critical-chain` answered "Bootup is not yet finished"). A unit
# ordered After=multi-user.target in that state NEVER STARTS -- not
# "delayed", genuinely never, for the life of the VM -- while the Deck
# wizard on tty1 runs completely normally the entire time (it is reached via
# getty, which has no such dependency). The sibling harness never hits this
# because it boots with `-nic user,model=virtio-net-pci`; this file boots
# `-nic none` specifically to prove the install needs no network at all
# (see the header), so it needs a probe that does not accidentally depend on
# network-gated boot completion either. basic.target has no such dependency
# (sysinit/paths/slices/sockets/timers only) and is reached early on every
# boot this project's harnesses have ever measured; the probe's own greeter-
# wait loop already tolerates starting "too early" (it polls for up to 300s),
# so there is no corresponding risk of starting too soon.
unit_text="[Unit]
Description=T4 install-controller probe
After=basic.target

[Service]
Type=oneshot
ExecStartPre=-/usr/bin/udevadm settle
ExecStart=/usr/bin/bash /run/credentials/@system/t4installprobe.sh
TimeoutStartSec=0
RemainAfterExit=yes
StandardOutput=null
StandardError=null
"
dropin_text="[Unit]
Wants=t4-install-controller-probe.service
"

cred_unit="io.systemd.credential.binary:systemd.extra-unit.t4-install-controller-probe.service=$(base64 -w0 <<<"$unit_text")"
cred_dropin="io.systemd.credential.binary:systemd.unit-dropin.basic.target=$(base64 -w0 <<<"$dropin_text")"
cred_script="io.systemd.credential.binary:t4installprobe.sh=$(base64 -w0 <"$probe_src")"

# ---------------------------------------------------------------------------
# THE NIC, AND WHY IT IS NORMALLY ABSENT (see this file's header for the long
# form: a pass here cannot be quietly explained by "well, it could reach the
# internet"). Default stays `-nic none` -- do not change that default.
#
# VM_NIC=user opts INTO a NAT'd virtio NIC for the one question the offline run
# structurally cannot answer: whether `deck_pkgs` actually FETCHES AND INSTALLS
# steam. That step is online by design (T5-fork-plan.md §4.1: steam is fetched,
# not bundled, and the installer's own S0 screen says so), so offline it can
# only ever report `skipped-no-network` -- which proves the degradation is
# loud, and proves nothing about the happy path. Both runs are needed; neither
# replaces the other.
#
# ⚠️ With a NIC present, multi-user.target is reachable again, so the
# `After=basic.target` reasoning ~line 400 stays correct but stops being
# load-bearing. Do not "simplify" the probe on the strength of a networked run.
VM_NIC=${VM_NIC:-none}
case $VM_NIC in
  none) VM_NIC_ARGS=(-nic none) ;;
  # shellcheck disable=SC2054  # the commas are qemu's own -nic syntax, one arg
  user) VM_NIC_ARGS=(-nic user,model=virtio-net-pci) ;;
  *) fail "VM_NIC must be 'none' (default, offline) or 'user' (NAT'd virtio); got '$VM_NIC'" ;;
esac

log "booting the ISO headless (timeout ${RUN_TIMEOUT}s, install poll deadline ${INSTALL_POLL_DEADLINE}s), VM_NIC=${VM_NIC} (${VM_NIC_ARGS[*]}; default is offline on purpose -- see this file's header)"
qemu-system-x86_64 \
  "${ACCEL_ARGS[@]}" \
  -smp "$SMP" -m "$MEM_MB" \
  -smbios type=1,manufacturer=Valve,product=Galileo,version=1 \
  -smbios type=2,manufacturer=Valve,product=Galileo \
  -smbios "type=11,value=${cred_unit}" \
  -smbios "type=11,value=${cred_dropin}" \
  -smbios "type=11,value=${cred_script}" \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$ovmf_vars" \
  -drive file="$ISO",media=cdrom,if=none,format=raw,id=cdrom0 \
  -device ide-cd,drive=cdrom0,bootindex=1 \
  -drive file="$target_disk",format=qcow2,if=none,id=target0 \
  -device virtio-blk-pci,drive=target0,serial=vmtarget \
  "${VM_NIC_ARGS[@]}" \
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
  local qcode=$1
  qmp "{\"execute\":\"send-key\",\"arguments\":{\"keys\":[{\"type\":\"qcode\",\"data\":\"$qcode\"}]}}" >>"$WORK/qmp.log"
}

# Steps 1-28: identical to the proven sibling harness (see the probe's own
# comment for why). Step 29: NEW, S5's "y". Step 30 (the reboot-accept key)
# is NOT in this fixed list -- it is only requested by the guest if the
# install actually succeeds, so it is watched for separately below.
STEPS="01-kb-us:ret 02-kb-uk:down 03-username-empty:ret \
04-username-empty-2:ret 05-username-empty-3:ret 06-username-empty-4:ret \
07-username-d:d 08-username-de:e 09-username-dec:c 10-username-deck:k \
11-password-empty:ret 12-password-1:p 13-password-2:a 14-password-3:s 15-password-4:s \
16-confirm-empty:ret 17-confirm-1:p 18-confirm-2:a 19-confirm-3:s 20-confirm-4:s \
21-fullname:ret 22-email:ret 23-hostname:ret 24-timezone-list:ret \
25-summary:ret 26-disk-confirm:ret 27-disk-confirm-holds:ret 28-deck-summary:y \
29-post-install-start:y"

nsteps=0
for step in $STEPS; do nsteps=$((nsteps + 1)); done
reboot_accept_idx=$((nsteps + 1))  # step 30: not in STEPS, watched separately below

declare -a seen
for ((n = 1; n <= reboot_accept_idx; n++)); do seen[n]=0; done

elapsed=0
while kill -0 "$qemu_pid" 2>/dev/null; do
  if [[ -f $serial_log ]]; then
    i=0
    for step in $STEPS; do
      i=$((i + 1))
      if [[ ${seen[i]} -eq 0 ]] && grep -q "T4PROBE:WANT-KEY-${i}-GO" "$serial_log"; then
        seen[i]=1
        qcode=${step##*:}
        sleep 1
        sendkey "$qcode"
        log "step ${i}/${nsteps} (${step%%:*}): sent '${qcode}'"
      fi
    done
    # step 30: only requested (and only sent) if the guest's own probe saw
    # the install succeed. If it never appears, no key is sent -- matching
    # this project's "no key into a failure/upload menu" discipline.
    if [[ ${seen[reboot_accept_idx]} -eq 0 ]] && grep -q "T4PROBE:WANT-KEY-${reboot_accept_idx}-GO" "$serial_log"; then
      seen[reboot_accept_idx]=1
      sleep 1
      sendkey ret
      log "step ${reboot_accept_idx}/${reboot_accept_idx} (accept-reboot-now): sent 'ret'"
    fi
  fi
  sleep 2
  elapsed=$((elapsed + 2))
  if (( elapsed >= RUN_TIMEOUT )); then
    log "TIMEOUT after ${elapsed}s -- killing qemu (work dir preserved for evidence)"
    kill "$qemu_pid" 2>/dev/null
    sleep 2
    kill -9 "$qemu_pid" 2>/dev/null
    break
  fi
done
log "guest gone after ${elapsed}s"

# ===========================================================================
# RECONSTRUCT a screens::extract_section-compatible report from serial.log
# ===========================================================================
#
# FACT:key=value  -> key=value               (screens::field-compatible)
# CAP:name:b64    -> --- screen.name ---\n<content>\n   (screens::extract_section-compatible)
#
# Built from whatever made it into serial.log even if the guest vanished
# mid-run (a real failure, a timeout, an abrupt reset) -- see this file's own
# "PROBE STREAMING" header section for why that is the point of this design.
#
# ⚠️ NOT hardcoded: `unit.ran=1` below is the guest probe's OWN first FACT
# line (emitted right after `say "UNIT-RAN"`, before anything else), read
# back from serial.log like every other fact. Synthesizing it here instead
# would make screens::require_report's liveness guard (§6.4 lie #3: "the
# probe never ran, so every later check trivially has nothing to disagree
# with") vacuous -- exactly the failure mode that guard exists to catch.
{
  LC_ALL=C command grep -oP '(?<=T4PROBE:FACT:).*' "$serial_log" 2>/dev/null | tr -d '\r'
} >"$report_txt.facts" 2>/dev/null || true

: >"$report_txt"
if [[ -s $report_txt.facts ]]; then
  cat "$report_txt.facts" >>"$report_txt"
fi
while IFS= read -r line; do
  cap_body=${line#T4PROBE:CAP:}
  cap_name=${cap_body%%:*}
  cap_b64=${cap_body#*:}
  [[ -n $cap_name && -n $cap_b64 ]] || continue
  {
    printf -- '--- screen.%s ---\n' "$cap_name"
    base64 -d <<<"$cap_b64" 2>/dev/null
    printf '\n'
  } >>"$report_txt"
done < <(LC_ALL=C command grep -a 'T4PROBE:CAP:' "$serial_log" 2>/dev/null | tr -d '\r')

log "reconstructed report: $report_txt"

# ===========================================================================
# CHECKING -- reuses test/lib/vm-installer-screens.sh's own mutation-tested
# primitives for the navigation half, and test/lib/vm-disk-image.sh /
# vm-assertions.sh (already proven end-to-end against a real ISO, T0 session 2,
# docs/PROGRESS.md's own roadmap table) for the disk-image half.
# ===========================================================================

screens::require_report "$report_txt" ||
  fail "the guest's report failed the liveness check -- see $report_txt, $serial_log, $WORK/qmp.log"

extract() { screens::extract_section "$report_txt" "$1" "$WORK/x.$1"; printf '%s' "$WORK/x.$1"; }
assert() {
  local what=$1; shift
  if "$@"; then screens::check "$what" ok ok; else screens::check "$what" FAIL ok; fi
}
refute() {
  local what=$1; shift
  if "$@"; then screens::check "$what" FAIL ok; else screens::check "$what" ok ok; fi
}

log "--- environment invariants -----------------------------------------"
screens::check "the injected unit ran"  "$(screens::field "$report_txt" unit.ran)" 1
screens::check "greeter appeared"       "$(screens::field "$report_txt" greeter.found)" 1
screens::check "deck-form.sh is present (this is the Deck-forked ISO)" "$(screens::field "$report_txt" deck_form_present)" 1

log "--- navigation reached S5's gate (steps 1-28, reused verbatim) -----"
assert "S0 -> username field (basic navigation sanity)" \
  screens::marker_present "$(extract 03-username-empty)" "Username>"
assert "username 'deck' typed (live echo, guard 2)" \
  screens::marker_present "$(extract 10-username-deck)" "deck"
assert "summary confirmed -> disk-confirm gate" \
  screens::marker_present "$(extract 26-disk-confirm)" "Yes, erase and install"
assert "disk-confirm 'y' -> S5 deck_final_summary (\"Ready to install?\")" \
  screens::advance_and_vanish "$(extract 27-disk-confirm-holds)" "$(extract 28-deck-summary)" \
  "Ready to install?" "Confirm erasing"

log "--- NEW: crossing S5's gate into write_user_files (step 29) --------"
refute "S5's own 'y' ('Install') hotkey crosses the gate -- 'Ready to install?' is gone" \
  screens::marker_present "$(extract 29-post-install-start)" "Ready to install?"
# named as a positive fact too, so a failure report reads either way
screens::check "post-gate capture is not blank (rows=$(screens::nonblank_rows "$(extract 29-post-install-start)"))" \
  "$(test "$(screens::nonblank_rows "$(extract 29-post-install-start)")" -gt 0 && echo yes)" yes

log "--- the real install's outcome --------------------------------------"
outcome=$(screens::field "$report_txt" install.outcome 2>/dev/null || echo "<missing>")
waited=$(screens::field "$report_txt" install.waited_s 2>/dev/null || echo "?")
log "install.outcome=$outcome (waited ${waited}s of a ${INSTALL_POLL_DEADLINE}s in-guest deadline)"
screens::check "the real install reached a terminal state (success or failure, not a timeout)" \
  "$([[ $outcome == success || $outcome == failure ]] && echo yes || echo no)" yes
screens::check "the real install SUCCEEDED (not: reached the failure menu)" "$outcome" success

if [[ $outcome == success ]]; then
  assert "post-install: the finish screen said 'Installed Omarchy in ...'" \
    screens::marker_present "$(extract 30-finish)" "Installed Omarchy in"
fi

# ===========================================================================
# THE DISK-IMAGE ASSERTIONS -- the actual "did a bootable install result"
# proof. Only meaningful if the install actually reported success above;
# gated so a failed/timed-out run does not spend minutes converting and
# inspecting a disk image that was never going to pass.
# ===========================================================================

disk_checks_run=0
if [[ $outcome == success ]]; then
  log "--- disk-image assertions (vm-install-test.sh's own model) ---------"
  disk_checks_run=1

  log "converting qcow2 -> raw for rootless offline inspection"
  if qemu-img convert -O raw "$target_disk" "$target_raw"; then
    assert "partition table: exactly one ESP + one root partition" \
      assert::partition_table "$target_raw"

    uki_dir="$WORK/extracted-ukis"
    disk_image::esp_extract_ukis "$target_raw" "$uki_dir"
    uki_count=$(find "$uki_dir" -maxdepth 1 -iname '*.efi' 2>/dev/null | wc -l)
    # ⚠️ Deliberately NOT an exact-name check. docs/PROGRESS.md's own
    # hard-won fact: "The UKI filename prefix is not the machine-id -- it is
    # CUSTOM_UKI_NAME from /etc/default/limine ... Discover it, never
    # construct it." Guessing a name here would be exactly the guessing this
    # project's own findings warn against.
    screens::check "at least one UKI (*.efi) exists under /EFI/Linux on the ESP (found $uki_count)" \
      "$([[ $uki_count -gt 0 ]] && echo yes || echo no)" yes

    uki_names=()
    if [[ $uki_count -gt 0 ]]; then
      while IFS= read -r -d '' f; do uki_names+=("$(basename "$f")"); done \
        < <(find "$uki_dir" -maxdepth 1 -iname '*.efi' -print0 | sort -z)
      log "discovered UKI(s): ${uki_names[*]}"

      limine_conf="$WORK/limine.conf"
      if disk_image::esp_find_limine_config "$target_raw" "$limine_conf" >"$WORK/limine-config-path.txt"; then
        log "Limine config found at: $(cat "$WORK/limine-config-path.txt")"
        assert "Limine config references the actual UKI(s) written to the ESP" \
          assert::limine_config_entries "$limine_conf" "${uki_names[@]}"
      else
        screens::check "a Limine config exists on the ESP (candidate paths, docs/PROGRESS.md's own five-way probe)" FAIL ok
      fi
    fi

    root_raw="$WORK/root.raw"
    if disk_image::root_extract "$target_raw" "$root_raw" &&
      read -r root_loop root_at < <(disk_image::root_mount "$root_raw"); then
      assert "installed package set includes base-devel/git/omarchy-keyring/omarchy-settings/omarchy" \
        assert::packages_present "$root_at/var/lib/pacman/local" \
          base-devel git omarchy-keyring omarchy-settings omarchy

      if [[ -f "$root_at/etc/hostname" ]]; then
        installed_hostname=$(tr -d '\n' <"$root_at/etc/hostname")
        log "installed /etc/hostname: '$installed_hostname'"
        screens::check "/etc/hostname was written (non-empty)" \
          "$([[ -n $installed_hostname ]] && echo yes || echo no)" yes
      else
        screens::check "/etc/hostname exists on the installed root" FAIL ok
      fi

      # Deck's own encryption-off contract (T4-screen-spec.md §2.2 item 1,
      # already proven at the JSON-artefact level in
      # docs/findings/T4-controller-only-install-first-run.md §6): a REAL
      # installed disk should carry no LUKS crypttab entry either. This is a
      # level deeper than that finding could reach (it stopped before
      # write_user_files ever ran).
      if [[ -f "$root_at/etc/crypttab" ]]; then
        crypttab_entries=$(LC_ALL=C command grep -vc '^[[:space:]]*#\|^[[:space:]]*$' "$root_at/etc/crypttab" 2>/dev/null || echo 0)
      else
        crypttab_entries=0
      fi
      screens::check "no LUKS crypttab entries on the installed disk (Deck's encryption-off contract, proven at the disk level)" \
        "$crypttab_entries" 0

      # ===================================================================
      # OUTCOME assertions -- "can this machine do its job", not "did our
      # steps run". Everything above this line is a fact about work THIS
      # PROJECT did: a partition table we wrote, a UKI our hook built, a
      # hostname our installer set. All of it was green on 2026-08-15
      # (18/18) against an install that had no Steam, no Neptune kernel, no
      # session shims and no on-screen keyboard -- a machine that showed a
      # black panel on real hardware for two full boots.
      # docs/findings/P32-steam-never-installed.md §"the measurement failure".
      #
      # test/lib/vm-outcome-assertions.sh owns the checks; the same library
      # is what test/vm/vm-outcome-assert.sh runs standalone against an
      # already-installed image, so there is one implementation and the fast
      # entry point cannot drift from the one that runs after a real install.
      # ===================================================================
      log "--- outcome assertions: can the installed machine do its job? ---"
      outcome::check_installed_root "$root_at" "$REPO_ROOT" ${uki_names[@]+"${uki_names[@]}"}

      disk_image::root_unmount "$root_loop"
    else
      screens::check "root partition extracted and mounted for package/hostname/encryption checks" FAIL ok
    fi
  else
    screens::check "qemu-img convert (qcow2 -> raw) succeeded" FAIL ok
  fi
else
  log "--- disk-image assertions SKIPPED: outcome was '$outcome', not 'success' ---"
fi

# ===========================================================================
# OUTCOME assertions, live-ISO half -- and DELIBERATELY NOT GATED on the
# install succeeding.
#
# These are questions about the image that was booted, not about what the
# install produced: is the on-screen keyboard in the live root, is it
# executable there (archiso's --no-preserve=mode discards the host's bit), is
# the library it imports at module scope actually installed. An install that
# FAILED needs those answers most of all -- the P32 mapper bug's whole
# signature is text screens that come up with no way to type on a machine that
# has no keyboard, which looks like a hang, not like a missing file.
# ===========================================================================
log "--- outcome assertions: does the LIVE ISO carry what its screens need? ---"
outcome::check_live_iso "$ISO" "$REPO_ROOT"

log "======================================================================="
screens::denominator
log "======================================================================="

if [[ $SCREENS_CHECKS_PASSED -eq $SCREENS_CHECKS_TOTAL && $SCREENS_CHECKS_TOTAL -gt 0 && $outcome == success && $disk_checks_run -eq 1 ]]; then
  log "PASS -- a controller-only run drove the Deck-forked ISO's real installer past S5's gate, through a REAL full-disk install (outcome=success); the resulting disk image has a valid partition table, at least one UKI, a Limine config referencing it, and the expected package set; and the OUTCOME assertions hold -- Steam, the DSP firmware, the Neptune kernel, gamescope and omarchy-deck are installed, stock linux is not, the session shims and the target-side mapper are on disk, and the live ISO carries an executable on-screen keyboard with python-evdev behind it. Phase 2 exit criterion 1 evidence."
  [[ ${VM_KEEP_WORK:-0} == 1 ]] || rm -rf "$WORK"
  exit 0
else
  log "FAILED (or incomplete) -- outcome=$outcome, disk_checks_run=$disk_checks_run. Full report: $report_txt (work dir kept: $WORK, serial log: $serial_log)"
  exit 1
fi

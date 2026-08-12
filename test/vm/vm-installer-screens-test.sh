#!/usr/bin/env bash
# vm-installer-screens-test.sh -- T4's [V]-tier harness
# (docs/tasks/T4-screen-spec.md §6.3), driving the REAL, unmodified Omarchy
# ISO in QEMU. Not T4's screens -- those don't exist yet, are out of this
# session's scope, and are gated on U6 (docs/tasks/T4-screen-spec.md §8).
# This is the machinery that will drive them once they land, proven against
# what the ISO actually contains today: upstream's own `configurator` wizard.
#
# Usage: ./vm-installer-screens-test.sh [iso-path] [work-dir]
#   default iso-path: ~/ISOs/omarchy-2026.08.10-x86_64-quattro.iso
#
# Env vars (all optional):
#   VM_RUN_TIMEOUT_SEC   whole-run ceiling, default 900
#   VM_MEM_MB / VM_SMP   guest size, defaults 4096 / 4
#   VM_OVMF_CODE / VM_OVMF_VARS   override firmware probing
#   VM_KEEP_WORK=1       never delete the work dir, even on success
#
# ===========================================================================
# WHY THIS DRIVES UPSTREAM'S WIZARD, NOT DECK SCREENS
# ===========================================================================
#
# T4's screens (deck-form.sh, wrapping configurator per the spec's §1
# decision) are another agent's deliverable this session, gated on U6, and
# explicitly out of this task's scope ("Write no installer screens"). The ISO
# this harness is told to drive -- the EXISTING, unmodified build at
# ~/ISOs/omarchy-2026.08.10-x86_64-quattro.iso -- therefore contains none of
# them. What it DOES contain is the exact wizard T4's screens will wrap:
# same prompts, same artefact files, same failure paths. Every primitive and
# every guard this suite proves (§6.2, §6.4) is proven against that same
# machinery, because deck-form.sh redefines the prompt FUNCTIONS but changes
# nothing about how a screen is driven or read -- the console is still tty1,
# the artefacts are still user_configuration.json/user_credentials.json, and
# a blocking screen still blocks the same way. When the Deck-forked ISO
# exists, pointing $1 at it and swapping the marker strings in this file for
# Deck-branded ones (§4's S0/S1/S3/S8 text) is the whole migration.
#
# This run therefore explicitly reports (and asserts) that
# /usr/share/omarchy-iso/deck-form.sh is ABSENT in the image under test --
# so a reader can never mistake "this suite is green" for "S1's Wi-Fi/OSK
# screen, or S8's Deck-branded failure menu, has been proven." They haven't.
# Those need the forked ISO and are noted as unmet in this session's report.
#
# ===========================================================================
# THE MEASURED FLOW (RUN, this session, four exploratory boots before this
# script was written -- see docs/findings/T4-harness-build.md)
# ===========================================================================
#
#   greeter --ret--> keyboard list (cursor: US)
#           --down-> keyboard list (cursor: UK)
#           --ret--> username (empty)
#           --ret x3 (BLOCKING NEGATIVE TEST: must NOT advance)
#           --d,e,c,k--> "deck" (LIVE ECHO, guard 2)
#           --ret--> password (empty, masked)
#           --p,a,s,s--> (masked; password fields never echo -- measured)
#           --ret--> confirm (empty, masked)
#           --p,a,s,s--> (masked)
#           --ret--> full name (empty; "hit return to skip")
#           --ret--> email address (skip)
#           --ret--> hostname (skip -> default "omarchy")
#           --ret--> timezone list (geo-guessed default pre-selected)
#           --ret--> SUMMARY TABLE (Username/Password/Hostname/Timezone/Keyboard)
#           --ret--> disk picker (single eligible disk auto-shown)
#           --ret--> disk overwrite confirm ("Yes, install" is upstream's
#                    OWN default cursor position -- confirms
#                    T4-screen-spec.md §2.2 item 1's inference, by
#                    measurement, that skipping encryption needs Ctrl+C)
#           --ret--> STOP. write_user_files has now run (user_configuration.json
#                    and user_credentials.json exist and are read back and
#                    checked, A2/A3) and a real (but deliberately tiny,
#                    misaligned) partition attempt has failed fast, landing
#                    on the failure menu. No further key is sent.
#
# ⚠️ TWO FINDINGS FROM THAT MEASUREMENT, NEITHER IN THE SPEC, BOTH LOAD-BEARING
# FOR THIS HARNESS'S OWN SAFETY:
#
#   1. THE RESULT DEVICE GETS AUTO-SELECTED AS THE INSTALL DISK. This suite's
#      only virtio-blk device -- the one used to get the report back out, the
#      SAME pattern vm-iso-probe-feasibility.sh and vm-osk-tty-test.sh use --
#      is the lone "eligible disk" upstream's disk_form finds, and driving the
#      flow to the confirm step makes it try to partition it for real.
#      Deliberate, not a bug: kept small (64M) on purpose, so the REAL
#      install attempt fails FAST ("Partition is misaligned") rather than
#      slowly succeeding at wiping a device meant only to carry a report.
#      This is exactly T4-screen-spec.md §3 item 5's warning made concrete:
#      "the microSD must be excluded ... by RM, not by name" -- a scratch
#      virtio-blk device proves the same class of bug the spec worried about
#      a physical SD card would cause. NEVER attach a second, real-sized
#      writable disk to this harness; there would be nothing to stop a
#      successful (and destructive, inside the guest, to that image file)
#      install from running to completion.
#   2. THE FAILURE MENU'S DEFAULT CURSOR IS "Upload log for support", NOT
#      "Retry" or "Power off". A controller-only user's very first "confirm"
#      press after ANY failure uploads the install log to logs.omarchy.org
#      by default -- worse than T4-screen-spec.md §4 S8's own documented
#      concerns (Esc->"Drop to shell", an unquittable `less`). THIS SUITE
#      THEREFORE SENDS NO KEY ONCE THE FAILURE MENU APPEARS. Capturing that
#      one frame is the intended stopping point, not a truncation -- sending
#      one more `ret` here would make an automated CI run silently exfiltrate
#      data to a third party on every invocation. Recorded properly in
#      docs/findings/T4-harness-build.md for whoever builds S8 for real.
#
# ===========================================================================
# §6.4'S FIVE GUARDS -- WHICH ARE ACTUALLY EXERCISED HERE, AND HOW
# ===========================================================================
#
#   #1 (asserting on an unchanged screen) -- screens::advance_and_vanish at
#      EVERY transition below: the outgoing marker must be gone, the
#      incoming marker must be new. Not "the next marker appeared" alone.
#   #2 (a silent input path) -- the username field's LIVE ECHO is read back
#      after each of d/e/c/k and must contain the growing string. QMP
#      send-key reports success at the protocol level regardless of whether
#      the guest's console received anything, so "QMP said ok" is
#      deliberately NOT treated as proof by itself -- only the echoed text is.
#   #3 (a vacuous pass) -- screens::require_report is the FIRST thing this
#      script does with the retrieved report; a missing/empty report, or one
#      missing its own "unit.ran=1" liveness line, is a hard fail before any
#      other check runs. The denominator (checked/total) is always printed.
#   #4 (a guard nobody has seen fail) -- the username field gets THREE
#      submit attempts while empty, and the screen must be byte-identical
#      before and after (screens::assert_blocking_held on a checksum of the
#      folded capture) -- not just "still shows Username>", which a header
#      alone would satisfy even on a half-broken repaint.
#   #5 (testing the wrong world) -- stated once, here: QEMU has no hid_steam
#      and no Deck firmware (confirmed absent this session: see the
#      environment-invariants block below), so QMP send-key exercises only
#      the lizard-mode-EQUIVALENT navigation path (Enter/Esc/arrows), never
#      the real Deck HID. screens::capability_scope_label("qmp-sendkey") is
#      printed into the report so this is a fact in the artefact, not just a
#      comment a reader could skip.
#
# ===========================================================================

set -uo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

# shellcheck source=../lib/vm-installer-screens.sh
source "$REPO_ROOT/test/lib/vm-installer-screens.sh"

ISO=${1:-$HOME/ISOs/omarchy-2026.08.10-x86_64-quattro.iso}
WORK=${2:-$(mktemp -d /var/tmp/vm-installer-screens.XXXXXX)}

RUN_TIMEOUT=${VM_RUN_TIMEOUT_SEC:-900}
MEM_MB=${VM_MEM_MB:-4096}
SMP=${VM_SMP:-4}

log() { printf '[vm-installer-screens] %s\n' "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

[[ -f $ISO ]] || fail "ISO not found: $ISO (do not download one -- pass an existing path as \$1)"
for tool in qemu-system-x86_64 qemu-img socat base64 python3 awk; do
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
result_img="$WORK/result.raw"
result_txt="$WORK/report.txt"
serial_log="$WORK/serial.log"
qmp_sock="$WORK/qmp.sock"
pidfile="$WORK/qemu.pid"

cp "$OVMF_VARS_TEMPLATE" "$ovmf_vars"
qemu-img create -f raw "$result_img" 64M >/dev/null

# --- the in-guest probe -------------------------------------------------
#
# Deliberately thin: it captures /dev/vcs1 on cue and reads back two
# artefact files at the end. All the CHECKING (advance-and-vanish, the
# blocking assertion, artefact pairing, the denominator) happens on the
# HOST, against the retrieved report, using test/lib/vm-installer-screens.sh
# -- the same functions test/unit/test-installer-harness-primitives.sh
# mutation-tests. That split is deliberate: the guest side is as small as
# possible (less to go wrong inside a one-shot systemd unit sharing tty1
# with the thing it's watching), and the logic worth trusting lives where
# it can be unit-tested without a VM at all.

probe_src="$WORK/probe.sh"
cat >"$probe_src" <<'PROBE'
#!/usr/bin/env bash
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
  # ⚠️ stdout only -- NOT 2>&1. set -x is active for the whole script
  # (traced to trace.log separately); folding stderr in here as well would
  # interleave "+ echo ..." trace lines into the report between real
  # content, which is exactly the kind of self-inflicted parsing hazard
  # this harness's own primitives (screens::extract_section) are written
  # to be immune to -- but there's no reason to create the hazard at all.
  {
    echo "=== T4 [V]-TIER INSTALLER-SCREENS PROBE ==="
    cat "$R"
    echo "=== SCREEN CAPTURES (kernel's own /dev/vcs1) ==="
    for f in "$OUT"/screen.*; do
      [[ -f $f ]] || continue
      echo "--- screen.${f##*/screen.} ---"
      cat "$f"
      # ⚠️ LOAD-BEARING, found by running this exact script: /dev/vcs1
      # captures are a fixed rows*cols byte grid with NO trailing newline.
      # Without this, the NEXT header line lands glued onto the end of
      # THIS capture's last (space-padded) row instead of starting its own
      # line -- which silently defeats screens::extract_section's exact
      # `$0 == "--- screen.NAME ---"` line match for every section but the
      # first. Reproduced: run 1 of this suite had 28 captures collapse
      # into one 234KB blob under a single header.
      printf '\n'
    done
  } >"$OUT/report.txt"
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

# A probe that blocks is indistinguishable from one that never ran, and both
# cost a whole boot (§6.4 lie #3). This guarantees a report either way.
(
  sleep "${PROBE_WATCHDOG_SEC:-700}"
  printf 'watchdog.fired=1\n' >>"$R"
  {
    echo "=== T4 [V]-TIER INSTALLER-SCREENS PROBE (WATCHDOG) ==="
    cat "$R"
    echo "=== SCREEN CAPTURES (kernel's own /dev/vcs1) ==="
    for f in "$OUT"/screen.*; do
      [[ -f $f ]] || continue
      echo "--- screen.${f##*/screen.} ---"; cat "$f"; printf '\n'
    done
  } >"$OUT/watchdog-report.txt"
  [[ -b $RESULT_DEV ]] && dd if="$OUT/watchdog-report.txt" of="$RESULT_DEV" bs=1M conv=fsync status=none
  sync
  printf 'T4PROBE:WATCHDOG\n' >"$SER" 2>/dev/null
  systemctl poweroff -i
) &
WATCHDOG_PID=$!

exec 2>"$OUT/trace.log"
set -x

# --- geometry, re-read fresh on EVERY capture (never cache -- §2.3) --------
vcs_geom() {
  python3 - <<'PY' 2>/dev/null || echo "0 0"
try:
    d = open('/dev/vcsa1', 'rb').read(4)
    print(d[0], d[1])
except Exception:
    print(0, 0)
PY
}
snap() {
  local rows cols
  read -r rows cols <<<"$(vcs_geom)"
  [[ ${cols:-0} -gt 0 ]] || cols=0
  if (( cols > 0 )); then
    fold -w "$cols" </dev/vcs1 >"$OUT/screen.$1" 2>/dev/null
  else
    cat </dev/vcs1 >"$OUT/screen.$1" 2>/dev/null
  fi
  emit "geom.$1=${rows}x${cols}"
}

say "UNIT-RAN"
emit "unit.ran=1"
emit "probe.self=$0"

# --- A6: environment invariants ---------------------------------------------
emit "iso.version=$(cat /run/archiso/bootmnt/arch/version 2>/dev/null || echo unknown)"
emit "systemd.version=$(timeout 5 systemctl --version 2>/dev/null | head -1)"
emit "fgconsole=$(timeout 5 fgconsole 2>&1)"
emit "tty1.kdmode=$(python3 - <<'PY' 2>&1
import fcntl, struct
try:
    with open('/dev/tty1', 'rb') as f:
        print(struct.unpack('i', fcntl.ioctl(f, 0x4B3B, struct.pack('i', 0)))[0])
except Exception as exc:
    print('err:%s' % exc)
PY
)"
emit "fbcon.rotate=$(cat /sys/class/graphics/fbcon/rotate 2>&1)"
# §6.4 guard 5, made a fact in the artefact rather than only a comment: QEMU
# has neither hid_steam nor Deck firmware, so this run can only ever exercise
# the lizard-mode-equivalent navigation path.
emit "hid_steam.loaded=$([[ -d /sys/module/hid_steam ]] && echo 1 || echo 0)"
emit "hid_steam.sysfs_param=$([[ -f /sys/module/hid_steam/parameters/lizard_mode ]] && echo 1 || echo 0)"
emit "tools=$(for t in gum jq openssl tzupdate iwctl loadkeys; do command -v "$t" >/dev/null && printf '%s,' "$t"; done)"
# The honesty check this whole header talks about: this ISO is stock. If a
# future run of this same script against a Deck-forked ISO ever reports 1
# here, every marker string below needs revisiting for the Deck-branded text.
emit "deck_form_present=$([[ -f /usr/share/omarchy-iso/deck-form.sh ]] && echo 1 || echo 0)"

# --- wait for the greeter ----------------------------------------------------
waited=0
found=0
while (( waited < 300 )); do
  snap 00-greeter
  if command grep -qa 'Press Return to Start Install' "$OUT/screen.00-greeter" 2>/dev/null; then
    found=1
    break
  fi
  sleep 2
  waited=$((waited + 2))
done
emit "greeter.wait_s=$waited"
emit "greeter.found=$found"

# --- the measured, named key sequence (see this file's own header) ---------
# format: <capture-name>:<qcode-to-send-first>
STEPS="01-kb-us:ret 02-kb-uk:down 03-username-empty:ret \
04-username-empty-2:ret 05-username-empty-3:ret 06-username-empty-4:ret \
07-username-d:d 08-username-de:e 09-username-dec:c 10-username-deck:k \
11-password-empty:ret 12-password-1:p 13-password-2:a 14-password-3:s 15-password-4:s \
16-confirm-empty:ret 17-confirm-1:p 18-confirm-2:a 19-confirm-3:s 20-confirm-4:s \
21-fullname:ret 22-email:ret 23-hostname:ret 24-timezone-list:ret \
25-summary:ret 26-disk-picker:ret 27-disk-confirm:ret 28-failure:ret"

i=0
for step in $STEPS; do
  i=$((i + 1))
  name=${step%%:*}
  # ⚠️ "-GO" is load-bearing, not decoration. /dev/ttyS0 lines arrive CRLF
  # ("...WANT-KEY-1\r\n"), which a host-side `grep "...WANT-KEY-${i}\$"`
  # anchor never matches (the line's real last character is \r, not the
  # digit) -- found by running this exact script, where it silently sent
  # ZERO keys for the whole run. A fixed non-digit suffix sidesteps both
  # that AND the substring collision an unanchored match would have
  # (WANT-KEY-1 is a prefix of WANT-KEY-10..19).
  say "WANT-KEY-${i}-GO"
  sleep 6
  snap "$name"
done
emit "steps.sent=$i"

# --- A2/A3: read the artefacts back, whichever way the run went ------------
# STOP HERE. No key is sent after the failure menu appears (see header --
# its default selection uploads the install log, and this is meant to be an
# unattended, repeatable, no-side-effects run).
emit "cfg.exists=$([[ -f /root/user_configuration.json ]] && echo 1 || echo 0)"
emit "creds.exists=$([[ -f /root/user_credentials.json ]] && echo 1 || echo 0)"
if [[ -f /root/user_configuration.json ]]; then
  emit "cfg.content_b64=$(base64 -w0 /root/user_configuration.json)"
fi
if [[ -f /root/user_credentials.json ]]; then
  emit "creds.content_b64=$(base64 -w0 /root/user_credentials.json)"
fi
PROBE

# --- the injected unit -------------------------------------------------------
unit_text="[Unit]
Description=T4 [V]-tier installer-screens probe
After=multi-user.target

[Service]
Type=oneshot
ExecStartPre=-/usr/bin/udevadm settle
ExecStart=/usr/bin/bash /run/credentials/@system/t4screens.sh
TimeoutStartSec=0
RemainAfterExit=yes
StandardOutput=null
StandardError=null
"
dropin_text="[Unit]
Wants=t4-installer-screens-probe.service
"

cred_unit="io.systemd.credential.binary:systemd.extra-unit.t4-installer-screens-probe.service=$(base64 -w0 <<<"$unit_text")"
cred_dropin="io.systemd.credential.binary:systemd.unit-dropin.multi-user.target=$(base64 -w0 <<<"$dropin_text")"
# Proven this session (docs/findings/T4-harness-feasibility.md): SMBIOS
# type-11 carries the WHOLE probe byte-identically, no payload drive needed
# for anything script-sized.
cred_script="io.systemd.credential.binary:t4screens.sh=$(base64 -w0 <"$probe_src")"

log "booting the ISO headless (timeout ${RUN_TIMEOUT}s)"
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
  local qcode=$1
  qmp "{\"execute\":\"send-key\",\"arguments\":{\"keys\":[{\"type\":\"qcode\",\"data\":\"$qcode\"}]}}" >>"$WORK/qmp.log"
}

# STEPS must be identical to the guest's copy -- kept in exact sync by being
# spelled the same way here (see this file's own header for what each step
# proves). i is the WANT-KEY index the guest waits for; qcode is what the
# host answers with.
STEPS="01-kb-us:ret 02-kb-uk:down 03-username-empty:ret \
04-username-empty-2:ret 05-username-empty-3:ret 06-username-empty-4:ret \
07-username-d:d 08-username-de:e 09-username-dec:c 10-username-deck:k \
11-password-empty:ret 12-password-1:p 13-password-2:a 14-password-3:s 15-password-4:s \
16-confirm-empty:ret 17-confirm-1:p 18-confirm-2:a 19-confirm-3:s 20-confirm-4:s \
21-fullname:ret 22-email:ret 23-hostname:ret 24-timezone-list:ret \
25-summary:ret 26-disk-picker:ret 27-disk-confirm:ret 28-failure:ret"

nsteps=0
for step in $STEPS; do nsteps=$((nsteps + 1)); done

declare -a seen
for ((n = 1; n <= nsteps; n++)); do seen[n]=0; done

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
  fi
  sleep 2
  elapsed=$((elapsed + 2))
  if (( elapsed >= RUN_TIMEOUT )); then
    log "TIMEOUT after ${elapsed}s"
    kill "$qemu_pid" 2>/dev/null
    sleep 2
    kill -9 "$qemu_pid" 2>/dev/null
    break
  fi
done
log "guest gone after ${elapsed}s"

# --- pull the report back ----------------------------------------------------
tr -d '\0' <"$result_img" >"$result_txt"

# ===========================================================================
# CHECKING -- everything from here on is screens:: primitives, mutation-
# tested in test/unit/test-installer-harness-primitives.sh, run here against
# a REAL report for the first time.
# ===========================================================================

# guard 3, first: a missing/empty report, or one that never says the
# injected unit ran, is a hard fail before anything else is trusted.
screens::require_report "$result_txt" ||
  fail "the guest's report failed the liveness check -- see $result_txt, $WORK/serial.log, $WORK/qmp.log"
log "report: $result_txt"

extract() { screens::extract_section "$result_txt" "$1" "$WORK/x.$1"; printf '%s' "$WORK/x.$1"; }

# assert <what> <command...>: runs a screens:: predicate and folds its
# boolean result through screens::check, so every assertion in this file
# (not just the string-comparison ones) is counted in the same denominator
# (§6.4 guard 3) and printed the same way.
assert() {
  local what=$1; shift
  if "$@"; then
    screens::check "$what" ok ok
  else
    screens::check "$what" FAIL ok
  fi
}
# refute <what> <command...>: same, but the predicate is expected to FAIL.
refute() {
  local what=$1; shift
  if "$@"; then
    screens::check "$what" FAIL ok
  else
    screens::check "$what" ok ok
  fi
}

log "--- environment invariants (A6) --------------------------------------"
screens::check "the injected unit ran"        "$(screens::field "$result_txt" unit.ran)" 1
screens::check "greeter appeared"             "$(screens::field "$result_txt" greeter.found)" 1
screens::check "tty1 is in TEXT mode"         "$(screens::field "$result_txt" tty1.kdmode)" 0
log "note deck_form_present=$(screens::field "$result_txt" deck_form_present) -- 0 is EXPECTED: this is the stock ISO. A 1 here would mean the marker strings below are stale."
log "note hid_steam.loaded=$(screens::field "$result_txt" hid_steam.loaded) hid_steam.sysfs_param=$(screens::field "$result_txt" hid_steam.sysfs_param) -- both expected 0 in QEMU (guard 5)"
log "note fbcon.rotate=$(screens::field "$result_txt" fbcon.rotate) -- [H]-only assertion per T4-screen-spec.md §2.5/§6.2 A6; QEMU has no linux-t2 panel-orientation quirk"
log "note scope: $(screens::capability_scope_label qmp-sendkey)"

log "--- guard 1 (advance-and-vanish) at every transition ------------------"
assert "S0->kb-list advance-and-vanish" \
  screens::advance_and_vanish "$(extract 00-greeter)" "$(extract 01-kb-us)" \
  "Select keyboard layout" "Press Return to Start Install"

assert "kb-list cursor starts on English (US)" \
  screens::marker_present "$(extract 01-kb-us)" "> English (US)"
assert "down-arrow moves the cursor to English (UK)" \
  screens::marker_present "$(extract 02-kb-uk)" "> English (UK)"

assert "kb-list->username advance-and-vanish" \
  screens::advance_and_vanish "$(extract 02-kb-uk)" "$(extract 03-username-empty)" \
  "Username>" "Select keyboard layout"

log "--- guard 4 (a guard nobody has seen fail): the blocking negative test -"
# ⚠️ MEASURED 2026-08-11 AND RE-MEASURED 2026-08-12, bit-identical both
# times (docs/findings/T4-harness-first-run.md): upstream's FIRST rejection
# of an empty username does not leave the screen untouched. It repaints the
# prompt block one row higher and drops its own intro line
# ("Let's setup your user account..."). The wizard does NOT advance -- the
# block holds -- but a raw byte hash of the capture, which is what this
# suite originally used, called that a broken block. That was a wrong
# EXPECTATION in this harness, not a defect in the wizard.
#
# The fix keeps the guard's strength rather than relaxing it to "Username>
# is still there" (which the file header rightly calls too weak). Both
# claims below are pinned exactly:
#
#   attempt 1 -- the ONLY difference from the pre-submit screen is the loss
#     of that one intro line. Proven by removing exactly that line from the
#     BEFORE capture and requiring the content identities to match. Any
#     other character moving anywhere still fails.
#   attempts 2 and 3 -- full byte-for-byte identity of the raw capture,
#     unchanged and unweakened, against attempt 1's settled screen.
#
# If upstream ever stops dropping the intro line, attempt 1 fails loudly and
# this comment is the thing to re-measure. It is a pin, not a tolerance.
USERNAME_INTRO="Let's setup your user account"

# Guard against the vacuous shape: an identity comparison over two BLANK
# screens would "hold" while proving nothing (§6.4 lie #3 applied to guard
# 4). Every capture in this comparison must have real content first.
for cap in 03-username-empty 04-username-empty-2 05-username-empty-3 06-username-empty-4; do
  rows=$(screens::nonblank_rows "$(extract "$cap")")
  assert "blocking-test capture $cap is not a blank screen (rows=$rows)" \
    test "$rows" -gt 0
done

# attempt 1: the pinned, one-line delta
before_capture=$(extract 03-username-empty)
before_less_intro="$WORK/x.03-username-empty.less-intro"
LC_ALL=C command grep -av -- "$USERNAME_INTRO" "$before_capture" >"$before_less_intro"
assert "the intro line was actually present to begin with (else the pin below proves nothing)" \
  screens::marker_present "$before_capture" "$USERNAME_INTRO"
assert "empty-username attempt 1: screen did not advance; ONLY the intro line changed" \
  screens::assert_blocking_held \
    "$(screens::content_digest "$before_less_intro")" \
    "$(screens::content_digest "$(extract 04-username-empty-2)")"

# attempts 2 and 3: full raw byte identity against the settled screen
settled_sum=$(sha256sum "$(extract 04-username-empty-2)" | cut -d' ' -f1)
sum3=$(sha256sum "$(extract 05-username-empty-3)" | cut -d' ' -f1)
sum4=$(sha256sum "$(extract 06-username-empty-4)" | cut -d' ' -f1)
assert "empty-username attempt 2 changed NOTHING (byte-for-byte)" \
  screens::assert_blocking_held "$settled_sum" "$sum3"
assert "empty-username attempt 3 changed NOTHING -- the block genuinely holds" \
  screens::assert_blocking_held "$settled_sum" "$sum4"

# and the guard's actual PURPOSE, asserted directly rather than inferred
# from identity alone: after three empty submits the wizard is still on the
# username prompt and the next screen has not appeared.
for cap in 04-username-empty-2 05-username-empty-3 06-username-empty-4; do
  assert "after empty submit ($cap) the username prompt is still the live screen" \
    screens::marker_present "$(extract "$cap")" "Username>"
  refute "after empty submit ($cap) the wizard did NOT reach the password step" \
    screens::marker_present "$(extract "$cap")" "Password>"
done

log "--- guard 2 (silent input path): live echo, character by character ---"
for pair in "07-username-d:d" "08-username-de:de" "09-username-dec:dec" "10-username-deck:deck"; do
  cap=${pair%%:*}; want=${pair##*:}
  echoed=$(cat "$(extract "$cap")")
  assert "live echo after typing '$want'" \
    screens::assert_input_path_live 1 "$echoed" "Username> $want"
done

assert "username 'deck' submitted -> password step" \
  screens::advance_and_vanish "$(extract 10-username-deck)" "$(extract 11-password-empty)" \
  "Password>" "Username> deck"

log "--- password/confirm fields are masked (measured, not assumed) --------"
# Positive control for guard 2 above: THESE fields must NOT echo, so a
# regression that started echoing a password would be caught too.
for cap in 12-password-1 13-password-2 14-password-3 15-password-4; do
  refute "password field ($cap) does NOT echo the typed character" \
    screens::marker_present "$(extract "$cap")" "pass"
done

assert "password submitted -> confirm step" \
  screens::advance_and_vanish "$(extract 15-password-4)" "$(extract 16-confirm-empty)" \
  "Confirm>" "Password>"

assert "confirm submitted -> full name step" \
  screens::advance_and_vanish "$(extract 20-confirm-4)" "$(extract 21-fullname)" \
  "Full name>" "Confirm>"
assert "full name skipped -> email step" \
  screens::advance_and_vanish "$(extract 21-fullname)" "$(extract 22-email)" \
  "Email address>" "Full name>"
assert "email skipped -> hostname step" \
  screens::advance_and_vanish "$(extract 22-email)" "$(extract 23-hostname)" \
  "Hostname>" "Email address>"
assert "hostname skipped (default 'omarchy') -> timezone list" \
  screens::advance_and_vanish "$(extract 23-hostname)" "$(extract 24-timezone-list)" \
  "Timezone" "Hostname>"

# "Timezone" alone collides with the summary table's OWN row label -- use a
# marker unique to the scrollable LIST screen instead (an entry that is
# never the one selected value shown later).
assert "timezone accepted -> SUMMARY screen (S5-equivalent)" \
  screens::advance_and_vanish "$(extract 24-timezone-list)" "$(extract 25-summary)" \
  "Keyboard" "America/Merida"

log "--- A2/A3: the summary screen shown vs. the artefact written (S5's own warning) ---"
# ⚠️ This line used to be an inline, LOCALE-DEPENDENT grep, and it was the
# only piece of checking logic in this file that never went through the
# unit-tested library. It returned "" on a screen that plainly read
# "Username | deck", because the column separator is the raw byte 0xB3 and
# `.` does not match it in a UTF-8 locale (§6.4 lie #7). The pairing check
# below then blamed the WIZARD. Two full runs, 35/40 both times. The lesson
# is structural, not textual: checking logic lives in the library where it
# is unit- and mutation-tested. See docs/findings/T4-harness-first-run.md.
summary_username=$(screens::table_value "$(extract 25-summary)" "Username")
screens::check "summary table shows the typed username" "$summary_username" "deck"

# The same table, read the same way, for the other rows the artefact also
# carries -- so the S5 pairing check below is not a single-field spot check.
summary_hostname=$(screens::table_value "$(extract 25-summary)" "Hostname")
summary_timezone=$(screens::table_value "$(extract 25-summary)" "Timezone")
summary_keyboard=$(screens::table_value "$(extract 25-summary)" "Keyboard")
screens::check "summary table shows the hostname" "$summary_hostname" "omarchy"
screens::check "summary table shows the timezone" "$summary_timezone" "America/Mexico_City"
screens::check "summary table shows the keyboard layout" "$summary_keyboard" "uk"

assert "summary confirmed -> disk picker" \
  screens::advance_and_vanish "$(extract 25-summary)" "$(extract 26-disk-picker)" \
  "Select install disk" "Keyboard"
assert "disk selected -> overwrite confirm" \
  screens::advance_and_vanish "$(extract 26-disk-picker)" "$(extract 27-disk-confirm)" \
  "Confirm overwriting" "Select install disk"

log "--- the disk-confirm default cursor (measured, feeds T4 §2.2 item 1) --"
assert "overwrite confirm offers 'Yes, install'" \
  screens::marker_present "$(extract 27-disk-confirm)" "Yes, install"

assert "'Yes, install' confirmed -> write_user_files ran, install attempted" \
  screens::advance_and_vanish "$(extract 27-disk-confirm)" "$(extract 28-failure)" \
  "Omarchy installation stopped" "Confirm overwriting"
assert "failure menu's default item is 'Upload log for support' (measured; this is why we stop here)" \
  screens::marker_present "$(extract 28-failure)" "Upload log for support"

log "--- A2/A3: the artefact files, and the pairing check (S5's own warning) ---"
screens::check "user_configuration.json exists"  "$(screens::field "$result_txt" cfg.exists)" 1
screens::check "user_credentials.json exists"    "$(screens::field "$result_txt" creds.exists)" 1

cfg_b64=$(screens::field "$result_txt" cfg.content_b64 2>/dev/null || echo)
creds_b64=$(screens::field "$result_txt" creds.content_b64 2>/dev/null || echo)
if [[ -n $cfg_b64 && -n $creds_b64 ]]; then
  cfg_json="$WORK/user_configuration.json"
  creds_json="$WORK/user_credentials.json"
  base64 -d <<<"$cfg_b64" >"$cfg_json"
  base64 -d <<<"$creds_b64" >"$creds_json"

  if command -v jq >/dev/null; then
    written_username=$(jq -r '.users[0].username' "$creds_json")
    assert "username: SUMMARY SCREEN and ARTEFACT agree" \
      screens::assert_pair "username" "$summary_username" "$written_username"
    screens::check "artefact username is 'deck'" "$written_username" "deck"
    # S5's warning applies to every row of that table, not just the one.
    assert "hostname: SUMMARY SCREEN and ARTEFACT agree" \
      screens::assert_pair "hostname" "$summary_hostname" "$(jq -r '.hostname' "$cfg_json")"
    assert "timezone: SUMMARY SCREEN and ARTEFACT agree" \
      screens::assert_pair "timezone" "$summary_timezone" "$(jq -r '.timezone' "$cfg_json")"
    assert "keyboard: SUMMARY SCREEN and ARTEFACT agree" \
      screens::assert_pair "keyboard" "$summary_keyboard" "$(jq -r '.locale_config.kb_layout' "$cfg_json")"
    screens::check "artefact hostname is 'omarchy' (skipped, upstream default)" "$(jq -r '.hostname' "$cfg_json")" "omarchy"
    screens::check "artefact timezone is the geo-guessed default" "$(jq -r '.timezone' "$cfg_json")" "America/Mexico_City"
    screens::check "artefact keyboard layout is 'uk' (the down-arrow selection)" "$(jq -r '.locale_config.kb_layout' "$cfg_json")" "uk"
    enc_prefix=$(jq -r '.users[0].enc_password' "$creds_json" | cut -c1-3)
    # shellcheck disable=SC2016 # the literal '$6$' is the expected SHA-512 crypt prefix, not an expansion
    screens::check "root/user password is a SHA-512 crypt string (\$6\$...)" "$enc_prefix" '$6$'
    # ⚠️ MEASURED, not assumed: mashing Enter through every prompt leaves
    # disk encryption ON. Confirms T4-screen-spec.md §2.2 item 1's
    # (READ-only, at spec-writing time) claim that turning it OFF needs
    # Ctrl+C -- there is no other prompt for it in this flow.
    enc_type=$(jq -r '.disk_config.disk_encryption.encryption_type // "none"' "$cfg_json")
    screens::check "disk encryption defaults ON without Ctrl+C (confirms T4 spec §2.2 item 1 by measurement)" "$enc_type" "luks"
  else
    log "note jq not available on this host -- skipping artefact FIELD checks (existence already proven above)"
  fi
else
  log "note artefact content was not captured in this report (cfg.exists/creds.exists above already state whether the files existed)"
fi

log "======================================================================="
screens::denominator
log "======================================================================="

if [[ $SCREENS_CHECKS_PASSED -eq $SCREENS_CHECKS_TOTAL && $SCREENS_CHECKS_TOTAL -gt 0 ]]; then
  log "PASS -- the [V]-tier harness drove upstream's real wizard end to end, S0-through-S5-equivalent, with every §6.4 guard exercised"
  [[ ${VM_KEEP_WORK:-0} == 1 ]] || rm -rf "$WORK"
  exit 0
else
  log "FAILED -- full report: $result_txt (work dir kept: $WORK)"
  exit 1
fi

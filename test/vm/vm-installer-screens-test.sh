#!/usr/bin/env bash
# vm-installer-screens-test.sh -- T4's [V]-tier harness
# (docs/tasks/T4-screen-spec.md §6.3), driving the REAL Deck-forked Omarchy
# ISO in QEMU.
#
# Usage: ./vm-installer-screens-test.sh [iso-path] [work-dir]
#   default iso-path: ~/ISOs/omarchy-2026.08.10-x86_64-quattro.iso
#   (that default is upstream's own unmodified build, kept only because it
#   still boots and is harmless as a default; every real run of this suite
#   passes the Deck-forked ISO explicitly as $1.)
#
# Env vars (all optional):
#   VM_RUN_TIMEOUT_SEC   whole-run ceiling, default 900
#   VM_MEM_MB / VM_SMP   guest size, defaults 4096 / 4
#   VM_OVMF_CODE / VM_OVMF_VARS   override firmware probing
#   VM_KEEP_WORK=1       never delete the work dir, even on success
#
# ===========================================================================
# MIGRATION HISTORY -- this suite used to drive upstream's UNMODIFIED wizard
# ===========================================================================
#
# Until 2026-08-12 no Deck-forked ISO existed, so this suite drove upstream's
# own `configurator` (marker strings unmodified, `deck_form_present` asserted
# ABSENT) and said so loudly in its own header, per this file's original
# comment: "When the Deck-forked ISO exists, pointing $1 at it and swapping
# the marker strings in this file for Deck-branded ones ... is the whole
# migration." `iso/bin/build` ran for real that day
# (~/.cache/omarchy-deck/iso-build-2/release/omarchy-2026.08.13-x86_64-quattro.iso)
# and this is that migration, done against the real artefact -- see
# docs/findings/T4-controller-only-install-first-run.md for the full run.
#
# ⚠️ THE MIGRATION WAS NOT "SWAP THE MARKERS AND DONE" -- MEASUREMENT FOUND A
# REAL BUG THE SPEC DID NOT PREDICT. `deck-form.sh`'s own header claims S2
# (timezone), and the identity/hostname halves of S3, are overridden
# (`omarchy_prompt_timezone`, `omarchy_prompt_identity`, `omarchy_prompt_hostname`).
# **Measured on the real ISO, they are not.** `/dev/vcs1` shows upstream's own
# unmodified "Full name>", "Hostname>" and flat scrollable "Timezone" list --
# byte-identical in shape to what this suite already expected from the
# UNMODIFIED wizard, because that is genuinely what ran. Only `greeter` (S0),
# `omarchy_prompt_username`/`omarchy_prompt_password` (S3's username/password
# half), `disk_form` and `confirm_disk_overwrite` (S4) are confirmed
# overridden -- their `deck-form.sh`-specific text and the
# `[deck-form] WARNING: ...` lines from `deck_form_text_prompt` are on
# screen. This is precisely the failure mode T4-screen-spec.md §7's guard G1
# exists to catch ("An override that misspells a name is a screen that
# silently reverts to upstream's -- the exact failure class this project
# keeps hitting") and G1 either was not run against this build or did not
# catch this. See the findings doc for the full evidence and a follow-up
# flag. THE PRACTICAL CONSEQUENCE FOR THIS FILE: the marker strings for S2 and
# the identity/hostname half of S3, below, are deliberately left as
# upstream's own text -- not because this suite failed to migrate them, but
# because migrating them to Deck-branded text would make this suite pass
# while asserting something false about the real ISO.
#
# `deck_form_present` is now asserted **present** (1), not absent -- the one
# part of the original migration note that *was* that simple.
#
# ===========================================================================
# THE MEASURED FLOW, RE-MEASURED AGAINST THE DECK-FORKED ISO 2026-08-12
# (docs/findings/T4-controller-only-install-first-run.md)
# ===========================================================================
#
#   greeter (Deck disclosure text, "Press A to begin") --ret-->
#           (S1 Wi-Fi runs HERE, inline, before any capture below: no wlan0
#           in QEMU, so it self-resolves to "No Wi-Fi hardware found --
#           continuing offline" with no keypress -- confirmed by the flow
#           reaching the keyboard list on the very next capture, well inside
#           one 6s step window)
#           keyboard list (cursor: US, upstream's own picker, unoverridden)
#           --down-> keyboard list (cursor: UK)
#           --ret--> username (empty) -- deck-form.sh's OWN prompt: the
#                    `[deck-form] WARNING: mapper not found ...` line is on
#                    screen, proving this field IS the override, degraded
#                    (as designed) because /usr/local/bin/deck-input-mapper
#                    does not exist on this build (see findings doc)
#           --ret x3 (BLOCKING NEGATIVE TEST: must NOT advance)
#           --d,e,c,k--> "deck" (LIVE ECHO, guard 2)
#           --ret--> password (empty, masked) -- also deck-form.sh's prompt
#           --p,a,s,s--> (masked; password fields never echo -- measured)
#           --ret--> confirm (empty, masked)
#           --p,a,s,s--> (masked)
#           --ret--> full name (empty; "hit return to skip") -- UPSTREAM'S
#                    OWN, unoverridden (see MIGRATION HISTORY above)
#           --ret--> email address (skip) -- upstream's own
#           --ret--> hostname (skip -> default "omarchy") -- upstream's own
#           --ret--> timezone list (flat, geo-guessed default pre-selected)
#                    -- upstream's own, NOT deck-form.sh's two-level Area/City
#           --ret--> SUMMARY TABLE (Username/Password/Hostname/Timezone/
#                    Keyboard) -- upstream's own `user_step` recap, default
#                    cursor "Yes"
#           --ret--> disk_form auto-skips the picker (one eligible disk, the
#                    result device) straight into confirm_disk_overwrite --
#                    THIS ONE IS deck-form.sh's OWN: "Everything on ... will
#                    be erased. There is no recovery." / "This install is not
#                    encrypted, so the Deck can start without anyone typing a
#                    passphrase." / "Yes, erase and install" · "No, go back"
#           --ret--> 🔴 DOES NOT ADVANCE. Measured, not assumed:
#                    `DECK_DISK_CONFIRM_DEFAULT=false` in deck-form.sh means
#                    the cursor starts on "No, go back" -- the OPPOSITE of
#                    upstream's own confirm (which defaults affirmative and
#                    is why the ORIGINAL, pre-migration version of this file
#                    could reach the failure menu with a bare `ret`). Sending
#                    `ret` here declines, `disk_form` re-autoselects the same
#                    sole disk, and the SAME confirm screen redraws --
#                    verified byte-identical (sha256) across three
#                    consecutive `ret`s in the run that found this. This is
#                    the Deck-side safety flip T4-screen-spec.md §2.2 item 1
#                    asked for, PROVEN rather than inferred.
#           --y--> (the widget's own advertised hotkey, "y Yes, erase and
#                    install", read directly off screen -- not guessed) STOP.
#                    write_user_files has now run (user_configuration.json
#                    and user_credentials.json exist and are read back and
#                    checked, A2/A3) and a real (but deliberately tiny,
#                    misaligned) partition attempt has failed fast, landing
#                    on the failure menu -- upstream's own, unoverridden (S8
#                    is dead code in deck-form.sh today, see its own header).
#                    No further key is sent.
#
# ⚠️ TWO FINDINGS FROM THE ORIGINAL (pre-migration) MEASUREMENT, NEITHER IN
# THE SPEC, BOTH STILL LOAD-BEARING FOR THIS HARNESS'S OWN SAFETY:
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
# The honesty check this whole header talks about, now inverted post-
# migration (see MIGRATION HISTORY): this is meant to be the Deck-forked ISO,
# so a 0 here means $1 was pointed at the wrong image, or the overlay never
# landed in this build -- every marker string below assumes Deck-branded S0
# text and would be silently checking the wrong thing.
emit "deck_form_present=$([[ -f /usr/share/omarchy-iso/deck-form.sh ]] && echo 1 || echo 0)"

# --- wait for the greeter ----------------------------------------------------
# ⚠️ MIGRATED marker: deck-form.sh's `greeter()` override replaces upstream's
# "Press Return to Start Install" prompt line entirely with the Deck
# disclosure text (DECK_S0_LINES) ending in "Press A to begin" -- MEASURED,
# not the spec's guess: /dev/vcs1 on the real ISO never contains upstream's
# string at all (docs/findings/T4-controller-only-install-first-run.md).
waited=0
found=0
while (( waited < 300 )); do
  snap 00-greeter
  if LC_ALL=C command grep -qa 'Press A to begin' "$OUT/screen.00-greeter" 2>/dev/null; then
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
25-summary:ret 26-disk-confirm:ret 27-disk-confirm-holds:ret 28-deck-summary:y"

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
# T4-screen-spec.md §4 S4's own [V] item: "/root/user_encrypt_installation.txt
# is 'false'" -- a second, independent artefact for the same encryption-off
# fact the JSON's missing disk_encryption block already argues, written by a
# different upstream code path (write_user_files's own plain-text side
# output, not the archinstall JSON).
emit "encflag.exists=$([[ -f /root/user_encrypt_installation.txt ]] && echo 1 || echo 0)"
if [[ -f /root/user_encrypt_installation.txt ]]; then
  emit "encflag.content=$(cat /root/user_encrypt_installation.txt 2>/dev/null | tr -d '\n')"
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
# ⚠️ Step 26's `ret` DECLINES the disk-confirm screen on purpose (deck-form.sh
# flips its default to "No, go back" -- see the header's MEASURED FLOW) and
# step 27 repeats `ret` to prove the decline holds (the screen must NOT
# advance). Step 28 sends `y`, the widget's own advertised hotkey for "Yes,
# erase and install", to actually cross the confirm gate. This is the ONLY
# place in this file a qcode is a letter for a reason other than typing text
# into a field -- it is a keyboard shortcut gum itself prints on screen.
STEPS="01-kb-us:ret 02-kb-uk:down 03-username-empty:ret \
04-username-empty-2:ret 05-username-empty-3:ret 06-username-empty-4:ret \
07-username-d:d 08-username-de:e 09-username-dec:c 10-username-deck:k \
11-password-empty:ret 12-password-1:p 13-password-2:a 14-password-3:s 15-password-4:s \
16-confirm-empty:ret 17-confirm-1:p 18-confirm-2:a 19-confirm-3:s 20-confirm-4:s \
21-fullname:ret 22-email:ret 23-hostname:ret 24-timezone-list:ret \
25-summary:ret 26-disk-confirm:ret 27-disk-confirm-holds:ret 28-deck-summary:y"

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
# ⚠️ MIGRATED assertion (was "expect 0, this is stock upstream"): this suite
# now points at the Deck-forked ISO on purpose, so deck-form.sh must be
# present. A 0 here means $1 is the wrong image and every marker below is
# checking the wrong wizard.
screens::check "deck-form.sh is present (this is the Deck-forked ISO)" "$(screens::field "$result_txt" deck_form_present)" 1
log "note hid_steam.loaded=$(screens::field "$result_txt" hid_steam.loaded) hid_steam.sysfs_param=$(screens::field "$result_txt" hid_steam.sysfs_param) -- both expected 0 in QEMU (guard 5)"
log "note fbcon.rotate=$(screens::field "$result_txt" fbcon.rotate) -- [H]-only assertion per T4-screen-spec.md §2.5/§6.2 A6; QEMU has no linux-t2 panel-orientation quirk"
log "note scope: $(screens::capability_scope_label qmp-sendkey)"

log "--- S0's own Deck-branded disclosure text (T4-screen-spec.md §4 S0 [V]) --"
# ⚠️ MIGRATED markers: upstream's greeter has no such lines at all; these are
# deck-form.sh's DECK_S0_LINES, asserted on the function's own output too in
# test/unit/test-deck-form.sh -- this is the [V]-tier half of that same claim,
# proven on /dev/vcs1 rather than on the shell function in isolation.
assert "S0 discloses the erase warning" \
  screens::marker_present "$(extract 00-greeter)" "This installs Omarchy on your Steam Deck and erases the internal drive."
assert "S0 discloses the proprietary-firmware dependency" \
  screens::marker_present "$(extract 00-greeter)" "It includes proprietary firmware from AMD and Valve"
assert "S0 discloses that Steam/DSP firmware download during setup" \
  screens::marker_present "$(extract 00-greeter)" "Steam and the audio DSP firmware are downloaded from Valve during setup."

log "--- guard 1 (advance-and-vanish) at every transition ------------------"
assert "S0->kb-list advance-and-vanish" \
  screens::advance_and_vanish "$(extract 00-greeter)" "$(extract 01-kb-us)" \
  "Select keyboard layout" "Press A to begin"

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
#
# 🔴 MEASURED AGAINST THE DECK-FORKED ISO, 2026-08-12: this pin now FAILS,
# and deliberately is NOT relaxed to make it pass -- the failure is real,
# newly-discovered product behaviour, not a stale harness expectation this
# time. `omarchy_prompt_username`'s deck-form.sh override calls
# `deck_form_text_prompt`, which prints `[deck-form] WARNING: ...` lines to
# the SAME console on every retry (mapper-not-found, lizard-mode-absent, and
# the validation message) and, unlike upstream's own `notice()`/`clear_logo`
# path, never clears them. Measured row counts across the four blocking
# captures: 16, 22, 28, 34 -- growing by a fixed 6 rows on every attempt,
# not settling the way upstream's does. The three assertions below are LEFT
# FAILING on purpose: weakening them would hide a real, reproducible defect
# (unbounded console growth on repeated invalid input -- on real hardware,
# with the OSK actually drawn, this would eventually scroll the keyboard off
# the visible console). See docs/findings/T4-controller-only-install-first-run.md.
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

# ⚠️ MIGRATED: upstream's own recap ("Does this look right?", default "Yes")
# accepts on the bare `ret` that landed us on 26-disk-confirm, and disk_form
# (deck-form.sh's override) auto-skips the picker entirely -- the sole
# eligible disk is this harness's own result device, same hazard the
# original header already warns about. So the very NEXT screen is already
# deck-form.sh's OWN confirm_disk_overwrite, not upstream's picker or its
# "Confirm overwriting" text -- there is no picker screen to assert here on
# this ISO with this device topology. Confirmed by three consecutive raw
# captures being byte-for-byte identical in the run that found this
# (docs/findings/T4-controller-only-install-first-run.md).
assert "summary confirmed -> Deck's disk-overwrite confirm (picker auto-skipped, one eligible disk)" \
  screens::advance_and_vanish "$(extract 25-summary)" "$(extract 26-disk-confirm)" \
  "will be erased. There is no recovery." "Keyboard"

log "--- the disk-confirm default cursor, Deck's SAFETY FLIP (T4 §2.2 item 1) --"
assert "overwrite confirm offers Deck's own text: 'Yes, erase and install'" \
  screens::marker_present "$(extract 26-disk-confirm)" "Yes, erase and install"
assert "overwrite confirm offers Deck's own text: 'No, go back'" \
  screens::marker_present "$(extract 26-disk-confirm)" "No, go back"
assert "overwrite confirm states the install is unencrypted (no passphrase to type -- no keyboard exists)" \
  screens::marker_present "$(extract 26-disk-confirm)" "This install is not encrypted"

log "--- guard 4 again, on S4 this time: the disk-confirm default must ACTUALLY decline --"
# ⚠️ MEASURED, not inferred: DECK_DISK_CONFIRM_DEFAULT=false in deck-form.sh
# means the cursor starts on "No, go back" -- the OPPOSITE of upstream's own
# confirm_disk_overwrite (affirmative default), which is exactly why the
# PRE-migration version of this file could reach the failure menu on a bare
# `ret`. A guard nobody has seen fail is not a guard (§6.4 lie #4) -- so this
# sends `ret` AGAIN here and requires the screen to hold, using the same
# content_digest identity guard 4 already uses for S3's blocking test, before
# ever trying the affirmative path.
assert "disk-confirm blocking test capture is not a blank screen" \
  test "$(screens::nonblank_rows "$(extract 26-disk-confirm)")" -gt 0
assert "disk-confirm blocking test capture 2 is not a blank screen" \
  test "$(screens::nonblank_rows "$(extract 27-disk-confirm-holds)")" -gt 0
assert "pressing Enter on disk-confirm does NOT start the install (default is 'No, go back')" \
  screens::assert_blocking_held \
    "$(screens::content_digest "$(extract 26-disk-confirm)")" \
    "$(screens::content_digest "$(extract 27-disk-confirm-holds)")"
assert "after the held Enter, disk-confirm is still the live screen" \
  screens::marker_present "$(extract 27-disk-confirm-holds)" "Confirm erasing"
refute "after the held Enter, the install did NOT start (no failure text yet)" \
  screens::marker_present "$(extract 27-disk-confirm-holds)" "Omarchy installation stopped"

log "--- crossing the confirm gate with gum's own advertised hotkey ---"
# ⚠️ CORRECTED after a real run found this wrong. This assertion used to
# expect 'y' to land straight on the failure menu (the pre-migration flow's
# shape, where confirm_disk_overwrite -> write_user_files directly). It does
# not: deck-form.sh's OWN `deck_final_summary` (S5, T4-screen-spec.md §1.2
# patch P1 hunk 2 -- "deck_final_summary || abort", placed immediately
# before write_user_files) sits between the disk-confirm gate and the actual
# install attempt, and 'y' on 26/27's screen lands there instead --
# CONFIRMED PRESENT AND WIRED UP: its own Field/Value table (Encryption,
# Desktop, Boot rows deck-form.sh's summary_rows adds beyond upstream's own
# recap), the S5/§5 offline-Wi-Fi consequence sentence, and a SECOND "Ready
# to install?" gate with the SAME hotkey convention. This is genuinely new
# information this run discovered, not a harness bug -- see
# docs/findings/T4-controller-only-install-first-run.md.
assert "'y' crosses the disk-confirm gate -> deck-form.sh's OWN S5 final summary (deck_final_summary)" \
  screens::advance_and_vanish "$(extract 27-disk-confirm-holds)" "$(extract 28-deck-summary)" \
  "Ready to install?" "Confirm erasing"
assert "S5 final summary shows Encryption: Off" \
  screens::marker_present "$(extract 28-deck-summary)" "Off"
assert "S5 final summary shows Desktop: Omarchy" \
  screens::marker_present "$(extract 28-deck-summary)" "Omarchy"
assert "S5 final summary shows Boot: Gaming Mode" \
  screens::marker_present "$(extract 28-deck-summary)" "Gaming Mode"
assert "S5 final summary offers 'Install'" \
  screens::marker_present "$(extract 28-deck-summary)" "Install"
assert "S5 final summary offers 'Go back'" \
  screens::marker_present "$(extract 28-deck-summary)" "Go back"

# 🔴 DELIBERATE STOPPING POINT for this run, same discipline as the
# pre-migration file's own stop at the failure menu -- except this time the
# reason is scope, not safety: crossing THIS gate too (another `y`) would
# reach write_user_files and a real (tiny, misaligned, fails-fast) partition
# attempt, one step further than this run went. That is a legitimate next
# step for a follow-up run, not a hole in this one -- see the findings doc's
# "what a follow-up run should do differently" section. No key is sent after
# this capture.
log "--- A2/A3: the artefact files -- NOT YET WRITTEN, and that is the correct, expected state here ---"
# write_user_files runs AFTER deck_final_summary's own "Ready to install?"
# gate, which this run deliberately does not cross (see above) -- so a 0
# here is not a failure of the harness, it is proof the run stopped exactly
# where it says it stopped, and did not silently claim more than it drove.
screens::check "user_configuration.json does not exist yet (write_user_files has not run)" "$(screens::field "$result_txt" cfg.exists)" 0
screens::check "user_credentials.json does not exist yet (write_user_files has not run)" "$(screens::field "$result_txt" creds.exists)" 0
screens::check "user_encrypt_installation.txt does not exist yet (write_user_files has not run)" "$(screens::field "$result_txt" encflag.exists)" 0

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
    # ⚠️ MIGRATED and INVERTED from the pre-fork measurement. Against
    # upstream's UNMODIFIED wizard, mashing Enter through every prompt left
    # disk encryption ON (Ctrl+C is the only toggle, and there is no Ctrl on
    # a Deck -- T4-screen-spec.md §2.2 item 1). deck-form.sh's
    # confirm_disk_overwrite exists specifically to make that impossible:
    # deck_form_disk_encryption_mode() returns the unconditional constant
    # "false" on every path, including decline. An unlockable LUKS Deck is a
    # brick for this project's own intended user (docs/PROGRESS.md §5.12) --
    # so THIS check now asserts the opposite of what it asserted pre-fork,
    # and a regression back to "luks" here is exactly the defect §2.2 item 1
    # first found.
    enc_type=$(jq -r '.disk_config.disk_encryption.encryption_type // "none"' "$cfg_json")
    screens::check "disk encryption is OFF (Deck's constant, T4 spec §3 deviation 4 -- no Ctrl key exists to turn it on, and an encrypted Deck has no way to type the LUKS passphrase)" "$enc_type" "none"
    screens::check "no disk_encryption block was written at all (not merely empty)" \
      "$(jq 'has("disk_config") and (.disk_config | has("disk_encryption"))' "$cfg_json")" "false"
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
  log "PASS -- the [V]-tier harness drove the Deck-forked ISO's real installer end to end (S0 through the disk-confirm gate and into the failure menu), with every §6.4 guard exercised. NOTE: S2/S3's identity+hostname fields ran upstream's OWN unoverridden prompts, not deck-form.sh's -- see this file's MIGRATION HISTORY header and docs/findings/T4-controller-only-install-first-run.md"
  [[ ${VM_KEEP_WORK:-0} == 1 ]] || rm -rf "$WORK"
  exit 0
else
  log "FAILED -- full report: $result_txt (work dir kept: $WORK)"
  exit 1
fi

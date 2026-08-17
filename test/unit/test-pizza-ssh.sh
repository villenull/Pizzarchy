#!/usr/bin/env bash
# Unit tests for src/pizza-ssh. No Deck, no VM, no root, no network.
#
# ⚠️ WHAT THIS SUITE IS FOR. docs/PROGRESS.md §5.36 records an evening lost to
# SSH setup, and the causes were not exotic: `systemctl is-active` says
# `inactive` for a unit that does not exist, so "never installed" and "not
# started" were indistinguishable; ufw `default deny` produced a timeout that
# masked a missing daemon; `&&` chaining ate the failures. Those are all
# BEHAVIOURS, and they are what is asserted here — the four `status` verdicts
# are checked on their EXIT CODES, not on their wording.
#
# ⚠️ AND WHAT IT DELIBERATELY DOES NOT DO. This repo has been bitten five times
# by tests that pin values they do not own. So: no assertion here names a
# literal address, a username, or a sentence of prose. The subnet tests feed an
# address in through a stub and assert the DERIVED network that comes out; the
# connect-line test computes the expected `user@addr` from the same stubs the
# script reads. If someone rewords every message in the script, this suite
# should stay green; if someone opens the port to 0.0.0.0/0, it must not.
#
# Everything the script shells out to is stubbed on a sanitised PATH, so
# "ufw is not installed" is tested by genuinely not having a ufw on PATH
# rather than by a flag.

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$REPO_ROOT/src/pizza-ssh"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2; exit 1; }

[[ -f $SCRIPT ]] || fail "src/pizza-ssh exists"
[[ -x $SCRIPT ]] || fail "src/pizza-ssh is executable" "chmod +x it"
pass "src/pizza-ssh exists and is executable"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The exit codes are the contract with the dispatcher, so read them from the
# script rather than restating them here. A renumbering must break the script's
# own header, not silently drift away from this suite.
readonly EX_FAIL=1
readonly EX_USAGE=2
readonly EX_FW_CLOSED=3
readonly EX_NOT_RUNNING=4
readonly EX_NOT_INSTALLED=5

for pair in \
  "EX_FAIL=$EX_FAIL" "EX_USAGE=$EX_USAGE" "EX_FIREWALL_CLOSED=$EX_FW_CLOSED" \
  "EX_NOT_RUNNING=$EX_NOT_RUNNING" "EX_NOT_INSTALLED=$EX_NOT_INSTALLED"
do
  grep -qx "readonly ${pair}" "$SCRIPT" ||
    fail "the script's exit codes match this suite's expectations" \
         "expected a line 'readonly ${pair}' in $SCRIPT"
done
pass "exit-code constants in the script agree with this suite (5 checked)"

# ---------------------------------------------------------------------------
# a sanitised PATH
#
# Only the utilities the script legitimately needs. Nothing else is reachable,
# so a scenario that omits the `ufw` stub really has no ufw — which is the
# point: absence is tested by absence.
# ---------------------------------------------------------------------------

base_bin="$work/base-bin"
mkdir -p "$base_bin"
# bash and env are here because the stubs are themselves `#!/usr/bin/env bash`
# scripts: with a sanitised PATH they have to be able to find their own shell.
for util in bash env awk sed grep sort cut cat getent head tr mv rm; do
  real=$(command -v "$util") || fail "the host provides $util (needed to run the script under test)"
  ln -sf "$real" "$base_bin/$util"
done

# ---------------------------------------------------------------------------
# scenario construction
#
# Each scenario is a directory holding stub binaries and their state. The stubs
# keep real state (a rules list, a units list) rather than replaying canned
# output, so idempotency is a property the stubs can actually witness.
# ---------------------------------------------------------------------------

new_scenario() {
  local name=$1
  local dir="$work/$name"
  mkdir -p "$dir/bin" "$dir/state" "$dir/home"
  : >"$dir/state/ufw-rules"       # one rule per line: TO|ACTION|FROM|COMMENT
  : >"$dir/state/ufw-log"         # every ufw invocation, one per line
  : >"$dir/state/systemctl-log"
  : >"$dir/state/units"           # unit names that exist at all
  : >"$dir/state/active"
  : >"$dir/state/enabled"
  printf 'active\n' >"$dir/state/ufw-active"
  printf 'yes\n'    >"$dir/state/password-auth"
  printf '22\n'     >"$dir/state/sshd-ports"
  printf '%s\n' "$dir"
}

# --- id / getent: who the script thinks you are ----------------------------
stub_identity() {
  local dir=$1 user=$2
  printf '%s\n' "$user" >"$dir/state/user"
  cat >"$dir/bin/id" <<EOF
#!/usr/bin/env bash
[[ \$* == *-un* ]] && { cat "$dir/state/user"; exit 0; }
exit 1
EOF
  cat >"$dir/bin/getent" <<EOF
#!/usr/bin/env bash
# getent passwd <user>
[[ \$1 == passwd ]] || exit 2
u=\$2
[[ -e "$dir/state/nohome" ]] && exit 2
printf '%s:x:1000:1000::%s/%s:/bin/bash\n' "\$u" "$dir/home" "\$u"
EOF
  mkdir -p "$dir/home/$user/.ssh"
  chmod +x "$dir/bin/id" "$dir/bin/getent"
}

# --- sudo: present, and non-interactive unless told otherwise ---------------
stub_sudo() {
  local dir=$1
  cat >"$dir/bin/sudo" <<EOF
#!/usr/bin/env bash
if [[ \$1 == -n ]]; then
  shift
  if [[ -e "$dir/state/sudo-needs-password" ]]; then
    printf 'sudo: a password is required\n' >&2
    exit 1
  fi
fi
exec "\$@"
EOF
  chmod +x "$dir/bin/sudo"
}

# --- ip: one interface, one address ----------------------------------------
# addr may be empty (no address at all) and iface may be empty (no route).
stub_ip() {
  local dir=$1 iface=$2 cidr=$3
  printf '%s\n' "$iface" >"$dir/state/iface"
  printf '%s\n' "$cidr"  >"$dir/state/cidr"
  cat >"$dir/bin/ip" <<EOF
#!/usr/bin/env bash
iface=\$(cat "$dir/state/iface")
cidr=\$(cat "$dir/state/cidr")
args="\$*"
if [[ \$args == *"route show default"* ]]; then
  [[ -n \$iface && -n \$cidr ]] || exit 0
  printf 'default via 10.0.0.1 dev %s proto dhcp src %s metric 600\n' "\$iface" "\${cidr%%/*}"
  exit 0
fi
if [[ \$args == *"addr show"* ]]; then
  [[ -n \$iface && -n \$cidr ]] || exit 0
  printf '2: %s    inet %s brd 0.0.0.0 scope global dynamic noprefixroute %s\\\\       valid_lft 1sec preferred_lft 1sec\n' \\
    "\$iface" "\$cidr" "\$iface"
  exit 0
fi
exit 0
EOF
  chmod +x "$dir/bin/ip"
}

# --- systemctl: real state, and the §5.36 trap faithfully reproduced --------
stub_systemctl() {
  local dir=$1
  cat >"$dir/bin/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$dir/state/systemctl-log"
verb=\$1; shift
unit=''
for a in "\$@"; do [[ \$a == *.service || \$a == *.socket ]] && unit=\$a; done
exists() { grep -qxF "\$1" "$dir/state/units"; }
case \$verb in
  list-unit-files)
    exists "\$unit" || exit 1
    printf '%s enabled disabled\n' "\$unit"; exit 0 ;;
  is-active)
    # ⚠️ THE §5.36 TRAP, ON PURPOSE: a unit that does not exist reports
    # 'inactive', exactly as the real systemctl does (verified on the Deck,
    # rc 4). The script must not be able to tell them apart this way.
    if grep -qxF "\$unit" "$dir/state/active"; then printf 'active\n'; exit 0; fi
    printf 'inactive\n'; exists "\$unit" || exit 4; exit 3 ;;
  is-enabled)
    exists "\$unit" || { printf 'not-found\n'; exit 4; }
    if grep -qxF "\$unit" "$dir/state/enabled"; then printf 'enabled\n'; exit 0; fi
    printf 'disabled\n'; exit 1 ;;
  enable)
    exists "\$unit" || { printf 'Failed: no such unit\n' >&2; exit 1; }
    [[ -e "$dir/state/enable-fails" ]] && { printf 'Failed\n' >&2; exit 1; }
    grep -qxF "\$unit" "$dir/state/enabled" || printf '%s\n' "\$unit" >>"$dir/state/enabled"
    # enable-noop: report success without actually starting, to prove the
    # script verifies observed state rather than trusting an exit code.
    [[ -e "$dir/state/enable-noop" ]] && exit 0
    grep -qxF "\$unit" "$dir/state/active" || printf '%s\n' "\$unit" >>"$dir/state/active"
    exit 0 ;;
  disable)
    exists "\$unit" || { printf 'Failed: no such unit\n' >&2; exit 1; }
    grep -vxF "\$unit" "$dir/state/enabled" >"$dir/state/enabled.t" || true
    mv "$dir/state/enabled.t" "$dir/state/enabled"
    grep -vxF "\$unit" "$dir/state/active" >"$dir/state/active.t" || true
    mv "$dir/state/active.t" "$dir/state/active"
    exit 0 ;;
esac
exit 0
EOF
  chmod +x "$dir/bin/systemctl"
}

unit_add()    { printf '%s\n' "$2" >>"$1/state/units"; }
unit_start()  { printf '%s\n' "$2" >>"$1/state/active"; printf '%s\n' "$2" >>"$1/state/enabled"; }

# --- sshd: the binary, and its resolved config ------------------------------
stub_sshd() {
  local dir=$1
  cat >"$dir/bin/sshd" <<EOF
#!/usr/bin/env bash
if [[ \$1 == -T ]]; then
  [[ -e "$dir/state/sshd-T-fails" ]] && { printf 'sshd: no hostkeys available\n' >&2; exit 1; }
  while read -r p; do printf 'port %s\n' "\$p"; done <"$dir/state/sshd-ports"
  printf 'passwordauthentication %s\n' "\$(cat "$dir/state/password-auth")"
  exit 0
fi
exit 0
EOF
  chmod +x "$dir/bin/sshd"
}

# --- ufw: a real little rule table ------------------------------------------
stub_ufw() {
  local dir=$1
  cat >"$dir/bin/ufw" <<'OUTER'
#!/usr/bin/env bash
STATE=__STATE__
printf '%s\n' "$*" >>"$STATE/ufw-log"

args=()
for a in "$@"; do [[ $a == --force ]] || args+=("$a"); done
set -- "${args[@]}"

case ${1:-} in
  status)
    printf 'Status: %s\n\n' "$(cat "$STATE/ufw-active")"
    printf '     To                         Action      From\n'
    printf '     --                         ------      ----\n'
    n=0
    while IFS='|' read -r to action from comment; do
      [[ -n $to ]] || continue
      n=$((n + 1))
      if [[ -n $comment ]]; then
        printf '[%2d] %-26s %-11s %-26s # %s\n' "$n" "$to" "$action" "$from" "$comment"
      else
        printf '[%2d] %-26s %-11s %s\n' "$n" "$to" "$action" "$from"
      fi
    done <"$STATE/ufw-rules"
    exit 0 ;;
  allow)
    [[ -e "$STATE/ufw-allow-fails" ]] && { printf 'ERROR\n' >&2; exit 1; }
    # allow from SUBNET to any port PORT proto tcp comment TAG
    from=''; port=''; comment=''
    while (( $# )); do
      case $1 in
        from)    from=$2;    shift 2 ;;
        port)    port=$2;    shift 2 ;;
        comment) comment=$2; shift 2 ;;
        *)       shift ;;
      esac
    done
    line="${port}/tcp|ALLOW IN|${from}|${comment}"
    # real ufw skips an identical existing rule
    grep -qxF "$line" "$STATE/ufw-rules" && exit 0
    [[ -e "$STATE/ufw-allow-silently-drops" ]] && exit 0
    printf '%s\n' "$line" >>"$STATE/ufw-rules"
    exit 0 ;;
  delete)
    num=$2
    awk -v n="$num" 'NR != n' "$STATE/ufw-rules" >"$STATE/ufw-rules.t"
    mv "$STATE/ufw-rules.t" "$STATE/ufw-rules"
    exit 0 ;;
  --version) printf 'ufw 0.36.2\n'; exit 0 ;;
esac
exit 0
OUTER
  sed -i "s|__STATE__|$dir/state|" "$dir/bin/ufw"
  chmod +x "$dir/bin/ufw"
}

ufw_add_rule() { printf '%s\n' "$2" >>"$1/state/ufw-rules"; }

# A fully-populated, healthy scenario: openssh installed, ufw present+active,
# one interface with an address, sudo works without a password.
full_scenario() {
  local name=$1 user=${2:-tester} cidr=${3:-192.168.100.25/24} dir
  dir=$(new_scenario "$name")
  stub_identity  "$dir" "$user"
  stub_sudo      "$dir"
  stub_ip        "$dir" wlan0 "$cidr"
  stub_systemctl "$dir"
  stub_sshd      "$dir"
  stub_ufw       "$dir"
  unit_add "$dir" sshd.service
  printf '%s\n' "$dir"
}

# Run the script inside a scenario. Never inherits the host PATH.
run_in() {
  local dir=$1; shift
  PATH="$dir/bin:$base_bin" \
  SUDO_USER='' \
  HOME=/nonexistent/deliberately \
    bash "$SCRIPT" "$@"
}

# ---------------------------------------------------------------------------
# 1. usage
# ---------------------------------------------------------------------------

d=$(full_scenario usage)
rc=0; out=$(run_in "$d" bogus-subcommand 2>&1) || rc=$?
(( rc == EX_USAGE )) || fail "an unknown subcommand is a usage error" "rc=$rc: $out"
pass "an unknown subcommand exits $EX_USAGE"

rc=0; out=$(run_in "$d" status extra 2>&1) || rc=$?
(( rc == EX_USAGE )) || fail "too many arguments is a usage error" "rc=$rc: $out"
pass "too many arguments exits $EX_USAGE"

rc=0; out=$(run_in "$d" --help 2>&1) || rc=$?
(( rc == 0 )) || fail "--help succeeds" "rc=$rc: $out"
pass "--help exits 0"

# ---------------------------------------------------------------------------
# 2. the four distinct status answers
#
# ⚠️ THE POINT OF THE WHOLE FILE. §5.36 lost an evening because these four
# states were reported identically. They are asserted on exit code, so
# rewording the script cannot make this pass or fail.
# ---------------------------------------------------------------------------

# (a) sshd not installed. Note the scenario still has a ufw and an address:
#     the answer must come from the absence of sshd, not from anything else.
d=$(new_scenario status-not-installed)
stub_identity "$d" tester; stub_sudo "$d"; stub_ip "$d" wlan0 192.168.100.25/24
stub_systemctl "$d"; stub_ufw "$d"          # deliberately NO stub_sshd, no unit
rc=0; out=$(run_in "$d" status 2>&1) || rc=$?
(( rc == EX_NOT_INSTALLED )) || fail "status distinguishes 'sshd not installed'" "rc=$rc: $out"
pass "status: sshd not installed => exit $EX_NOT_INSTALLED"

# ⚠️ and it must NOT have reached that answer via is-active, which lies.
grep -q 'is-active' "$d/state/systemctl-log" &&
  fail "status must not decide 'not installed' from is-active (it prints 'inactive' for missing units)" \
       "$(cat "$d/state/systemctl-log")"
pass "status did not consult is-active to decide installedness (§5.36's trap avoided)"

# (b) installed but not running.
d=$(full_scenario status-not-running)
rc=0; out=$(run_in "$d" status 2>&1) || rc=$?
(( rc == EX_NOT_RUNNING )) || fail "status distinguishes 'installed but not running'" "rc=$rc: $out"
pass "status: installed but stopped => exit $EX_NOT_RUNNING"

[[ $rc != "$EX_NOT_INSTALLED" ]] ||
  fail "'not running' and 'not installed' must not share an exit code"
pass "'not running' and 'not installed' are different answers"

# (c) running, but the firewall is closed.
d=$(full_scenario status-fw-closed)
unit_start "$d" sshd.service
rc=0; out=$(run_in "$d" status 2>&1) || rc=$?
(( rc == EX_FW_CLOSED )) || fail "status distinguishes 'running but firewall closed'" "rc=$rc: $out"
pass "status: running, ufw active with no rule => exit $EX_FW_CLOSED"

# (d) reachable.
d=$(full_scenario status-reachable)
unit_start "$d" sshd.service
ufw_add_rule "$d" '22/tcp|ALLOW IN|192.168.100.0/24|pizza-ssh'
rc=0; out=$(run_in "$d" status) || rc=$?
(( rc == 0 )) || fail "status reports reachable as exit 0" "rc=$rc: $out"
pass "status: running + rule present => exit 0"

# The connect line, computed from the same stubs the script read. Asserting the
# SHAPE and the DERIVED values, not a literal the test does not own.
expect_user=$(cat "$d/state/user")
expect_addr=$(cut -d/ -f1 <"$d/state/cidr")
grep -qF "ssh ${expect_user}@${expect_addr}" <<<"$out" ||
  fail "status prints the literal connect line with the real user and address" \
       "expected to find 'ssh ${expect_user}@${expect_addr}' in:
$out"
pass "status prints a ready-to-type 'ssh user@address' built from the live user and address"

# ---------------------------------------------------------------------------
# 3. subnet derivation
#
# The rule must be scoped to the network the address is actually on. Read back
# from the ufw stub's log, which is what the firewall really received.
# ---------------------------------------------------------------------------

check_subnet() {
  local label=$1 cidr=$2 expect=$3 dir rc out
  dir=$(full_scenario "subnet-${label}" tester "$cidr")
  rc=0; out=$(run_in "$dir" on 2>&1) || rc=$?
  (( rc == 0 )) || fail "pizza ssh on succeeds for $cidr" "rc=$rc: $out"
  grep -q "allow from ${expect} to any port" "$dir/state/ufw-log" ||
    fail "the ufw rule for $cidr is scoped to $expect" \
         "ufw received:
$(cat "$dir/state/ufw-log")"
  pass "address $cidr derives subnet $expect"
}

check_subnet a 192.168.100.25/24 192.168.100.0/24
check_subnet b 10.4.7.99/22      10.4.4.0/22
check_subnet c 172.20.13.5/16    172.20.0.0/16
check_subnet d 192.168.1.130/25  192.168.1.128/25

# ⚠️ THE ONE THAT MATTERS MOST: the port must never be opened to everyone.
for label in a b c d; do
  grep -qE '0\.0\.0\.0/0|to any port [0-9]+ proto tcp$' "$work/subnet-${label}/state/ufw-log" &&
    grep -q '0\.0\.0\.0/0' "$work/subnet-${label}/state/ufw-log" &&
    fail "no rule may be world-open" "$(cat "$work/subnet-${label}/state/ufw-log")"
done
pass "no derivation produced a rule allowing 0.0.0.0/0"

# ---------------------------------------------------------------------------
# 4. no address is a loud refusal, never a world-open fallback
# ---------------------------------------------------------------------------

refuses_without_address() {
  local label=$1 iface=$2 cidr=$3 dir rc out
  dir=$(full_scenario "noaddr-${label}")
  stub_ip "$dir" "$iface" "$cidr"
  rc=0; out=$(run_in "$dir" on 2>&1) || rc=$?
  (( rc != 0 )) || fail "pizza ssh on refuses when the subnet cannot be derived ($label)" "$out"
  grep -q 'allow' "$dir/state/ufw-log" &&
    fail "a refused run must not have touched the firewall ($label)" \
         "$(cat "$dir/state/ufw-log")"
  grep -q 'enable' "$dir/state/systemctl-log" &&
    fail "a refused run must not have started sshd ($label)" \
         "$(cat "$dir/state/systemctl-log")"
  pass "no usable address ($label): refuses loudly, changes nothing"
}

refuses_without_address no-interface ''      ''
refuses_without_address link-local   wlan0   169.254.7.9/16
refuses_without_address host-route   wlan0   10.1.2.3/32
refuses_without_address absurd-mask  wlan0   10.1.2.3/4

# ---------------------------------------------------------------------------
# 5. idempotency
# ---------------------------------------------------------------------------

d=$(full_scenario idem-on)
rc=0; out=$(run_in "$d" on 2>&1) || rc=$?
(( rc == 0 )) || fail "first 'on' succeeds" "rc=$rc: $out"
first_rules=$(cat "$d/state/ufw-rules")
rc=0; out=$(run_in "$d" on 2>&1) || rc=$?
(( rc == 0 )) || fail "second 'on' succeeds (idempotent)" "rc=$rc: $out"
second_rules=$(cat "$d/state/ufw-rules")
[[ $first_rules == "$second_rules" ]] ||
  fail "running 'on' twice leaves the same firewall state" "first:
$first_rules
second:
$second_rules"
(( $(grep -c . <<<"$second_rules") == 1 )) ||
  fail "'on' twice must not accumulate rules" "$second_rules"
pass "'pizza ssh' twice is the same as once (one rule, identical state)"

d=$(full_scenario idem-off)
unit_start "$d" sshd.service
ufw_add_rule "$d" '22/tcp|ALLOW IN|192.168.100.0/24|pizza-ssh'
rc=0; out=$(run_in "$d" off 2>&1) || rc=$?
(( rc == 0 )) || fail "first 'off' succeeds" "rc=$rc: $out"
[[ -s $d/state/ufw-rules ]] && fail "'off' removes our rule" "$(cat "$d/state/ufw-rules")"
rc=0; out=$(run_in "$d" off 2>&1) || rc=$?
(( rc == 0 )) || fail "'off' twice must not error" "rc=$rc: $out"
pass "'pizza ssh off' twice succeeds and leaves no rule"

# on -> off -> on returns to the same place.
d=$(full_scenario cycle)
run_in "$d" on >/dev/null 2>&1
after_first=$(cat "$d/state/ufw-rules")
run_in "$d" off >/dev/null 2>&1
run_in "$d" on >/dev/null 2>&1
[[ $(cat "$d/state/ufw-rules") == "$after_first" ]] ||
  fail "on/off/on returns to the same firewall state" "$(cat "$d/state/ufw-rules")"
pass "on -> off -> on is a round trip"

# Moving to a different network must REPLACE the rule, not add a second one —
# otherwise the café's subnet stays permitted after you get home.
d=$(full_scenario roaming)
run_in "$d" on >/dev/null 2>&1
printf '10.9.0.5/24\n' >"$d/state/cidr"
run_in "$d" on >/dev/null 2>&1
(( $(grep -c . "$d/state/ufw-rules") == 1 )) ||
  fail "changing network replaces the rule rather than adding one" "$(cat "$d/state/ufw-rules")"
grep -q '10\.9\.0\.0/24' "$d/state/ufw-rules" ||
  fail "the surviving rule is for the CURRENT network" "$(cat "$d/state/ufw-rules")"
grep -q '192\.168\.100\.0/24' "$d/state/ufw-rules" &&
  fail "the previous network must no longer be permitted" "$(cat "$d/state/ufw-rules")"
pass "moving networks replaces the rule; the old subnet is no longer allowed"

# ---------------------------------------------------------------------------
# 6. sshd absent
# ---------------------------------------------------------------------------

d=$(new_scenario on-no-sshd)
stub_identity "$d" tester; stub_sudo "$d"; stub_ip "$d" wlan0 192.168.100.25/24
stub_systemctl "$d"; stub_ufw "$d"
rc=0; out=$(run_in "$d" on 2>&1) || rc=$?
(( rc == EX_NOT_INSTALLED )) || fail "'on' with no openssh exits $EX_NOT_INSTALLED" "rc=$rc: $out"
grep -q 'allow' "$d/state/ufw-log" &&
  fail "'on' must not open a port for a daemon that does not exist" "$(cat "$d/state/ufw-log")"
pass "'on' with openssh absent: refuses, and opens no port (the §5.36 masking bug, prevented)"

grep -qiE 'pacman -S|install it yourself' <<<"$out" ||
  fail "'on' with openssh absent tells the user how to install it themselves" "$out"
grep -qiE '\bpacman -S openssh\b' <<<"$out" ||
  fail "the suggested package is named" "$out"
pass "'on' with openssh absent names the package but installs nothing"

# ...and it really installs nothing. CLAUDE.md forbids auto-installing packages
# (and emphatically an AUR helper). Match pacman/yay/paru as a COMMAND at the
# start of a statement — the strings inside printf/say above are advice for the
# user to run, which is the whole point.
offending=$(grep -nE '(^|[;&|]|\bthen\b|\bdo\b|\brun_priv\b)[[:space:]]*(sudo[[:space:]]+)?(pacman|yay|paru|pamac)[[:space:]]' \
              "$SCRIPT" || true)
[[ -z $offending ]] ||
  fail "the script must never RUN a package manager (CLAUDE.md: no auto-install, no AUR helper)" \
       "$offending"
pass "the script contains no package-manager invocation (advice strings only)"

# 'off' with no openssh is a no-op that succeeds — it is the command a worried
# user runs when they are not sure what state they are in.
d=$(new_scenario off-no-sshd)
stub_identity "$d" tester; stub_sudo "$d"; stub_ip "$d" wlan0 192.168.100.25/24
stub_systemctl "$d"; stub_ufw "$d"
rc=0; out=$(run_in "$d" off 2>&1) || rc=$?
(( rc == 0 )) || fail "'off' succeeds when openssh is not installed" "rc=$rc: $out"
pass "'off' with openssh absent succeeds (nothing to turn off)"

# ---------------------------------------------------------------------------
# 7. ufw absent
# ---------------------------------------------------------------------------

d=$(new_scenario no-ufw)
stub_identity "$d" tester; stub_sudo "$d"; stub_ip "$d" wlan0 192.168.100.25/24
stub_systemctl "$d"; stub_sshd "$d"; unit_add "$d" sshd.service   # no stub_ufw
rc=0; out=$(run_in "$d" on 2>&1) || rc=$?
(( rc == 0 )) || fail "'on' still works with no ufw installed" "rc=$rc: $out"
grep -qi 'warning' <<<"$out" ||
  fail "'on' with no ufw warns that the LAN-only restriction is not in effect" "$out"
pass "'on' with ufw absent: succeeds, and says loudly that nothing is filtering"

rc=0; out=$(run_in "$d" off 2>&1) || rc=$?
(( rc == 0 )) || fail "'off' works with no ufw installed" "rc=$rc: $out"
pass "'off' with ufw absent succeeds"

d=$(new_scenario no-ufw-status)
stub_identity "$d" tester; stub_sudo "$d"; stub_ip "$d" wlan0 192.168.100.25/24
stub_systemctl "$d"; stub_sshd "$d"; unit_add "$d" sshd.service
unit_start "$d" sshd.service
rc=0; out=$(run_in "$d" status 2>&1) || rc=$?
(( rc == 0 )) || fail "status with no ufw and a running sshd reports reachable" "rc=$rc: $out"
pass "status with ufw absent + sshd running => reachable (exit 0)"

# ufw present but INACTIVE is its own thing: the rule is stored, nothing is
# enforced, and the user must be told rather than reassured.
d=$(full_scenario ufw-inactive)
printf 'inactive\n' >"$d/state/ufw-active"
rc=0; out=$(run_in "$d" on 2>&1) || rc=$?
(( rc == 0 )) || fail "'on' succeeds with ufw inactive" "rc=$rc: $out"
grep -qi 'warning' <<<"$out" ||
  fail "'on' with ufw inactive warns that the restriction is not enforced" "$out"
pass "'on' with ufw inactive: succeeds, warns that nothing is enforced"

# ---------------------------------------------------------------------------
# 8. failures are never swallowed
# ---------------------------------------------------------------------------

# systemctl reports success but the unit does not come up.
d=$(full_scenario enable-noop)
: >"$d/state/enable-noop"
rc=0; out=$(run_in "$d" on 2>&1) || rc=$?
(( rc != 0 )) || fail "'on' must fail when sshd does not actually become active" "$out"
grep -q 'allow' "$d/state/ufw-log" &&
  fail "a port must not be opened for a daemon that failed to start" \
       "$(cat "$d/state/ufw-log")"
pass "systemctl exit 0 without an active unit is caught, and no port is opened"

# ufw accepts the rule and does not store it.
d=$(full_scenario ufw-lies)
: >"$d/state/ufw-allow-silently-drops"
rc=0; out=$(run_in "$d" on 2>&1) || rc=$?
(( rc != 0 )) || fail "'on' must fail when the rule does not appear in ufw status" "$out"
pass "a rule that is accepted but not stored is caught by reading the firewall back"

# ufw refuses the rule outright.
d=$(full_scenario ufw-allow-fails)
: >"$d/state/ufw-allow-fails"
rc=0; out=$(run_in "$d" on 2>&1) || rc=$?
(( rc != 0 )) || fail "'on' must fail when ufw refuses the rule" "$out"
pass "a firewall command that fails is reported, not printed over with 'SSH is on'"

# The firewall cannot be read at all (sudo needs a password, non-interactive).
d=$(full_scenario fw-unknown)
unit_start "$d" sshd.service
: >"$d/state/sudo-needs-password"
rc=0; out=$(run_in "$d" status 2>&1) || rc=$?
(( rc == EX_FAIL )) ||
  fail "status must not guess when the firewall is unreadable" "rc=$rc: $out"
(( rc != EX_FW_CLOSED )) ||
  fail "'unreadable' must not be reported as 'closed'"
pass "status: firewall unreadable => its own answer (exit $EX_FAIL), not 'closed'"

# ---------------------------------------------------------------------------
# 9. the password warning, and the key preference
# ---------------------------------------------------------------------------

d=$(full_scenario no-key)
out=$(run_in "$d" on 2>&1) || fail "'on' succeeds with no key installed"
grep -qi 'password' <<<"$out" ||
  fail "with no key installed, 'on' must warn about the password" "$out"
grep -qi 'warning' <<<"$out" ||
  fail "the no-key password warning is a WARNING, not a footnote" "$out"
pass "no key installed => a blunt password warning"

d=$(full_scenario with-key)
printf 'ssh-ed25519 AAAAC3Nz fake@test\n' >"$d/home/tester/.ssh/authorized_keys"
out=$(run_in "$d" on 2>&1) || fail "'on' succeeds with a key installed"
grep -qi 'key' <<<"$out" ||
  fail "with a key installed, 'on' says so" "$out"
grep -qF "$d/home/tester/.ssh/authorized_keys" <<<"$out" ||
  fail "the key file is named by its resolved path, not by '~'" "$out"
pass "an installed key is detected and its resolved path is printed"

# ⚠️ TODAY'S BUG, ASSERTED. `~` and $HOME follow whichever shell you are in;
# the operator read root's authorized_keys and concluded there was no key.
# HOME is set to a bogus path by run_in(), so if the script consulted it, this
# fails.
grep -q '/nonexistent/deliberately' <<<"$out" &&
  fail "the script must resolve the home directory from passwd, not from \$HOME" "$out"
pass "the home directory comes from the passwd database, not \$HOME (the wrong-shell bug)"

# The username printed is the one the system reports, not a hardcoded 'deck'.
d=$(full_scenario odd-user someoneelse)
out=$(run_in "$d" on 2>&1) || fail "'on' succeeds for an arbitrary username"
grep -qF "ssh someoneelse@" <<<"$out" ||
  fail "the connect line uses the real username, not a hardcoded one" "$out"
grep -qF 'ssh deck@' <<<"$out" &&
  fail "the username must not be hardcoded to 'deck'" "$out"
pass "the connect line carries whatever username the system reports"

# The stale-host-key remedy is offered, because that was half of today's
# twenty minutes and it has to be run on the OTHER machine.
grep -qi 'ssh-keygen -R' <<<"$out" ||
  fail "'on' tells the user how to clear a stale host key on the other machine" "$out"
pass "'on' prints the stale-host-key remedy (ssh-keygen -R)"

# And the whole reason the feature exists: getting the install record off.
grep -qF 'omarchy-deck-install.json' <<<"$out" ||
  fail "'on' shows how to copy the install record off the device" "$out"
pass "'on' shows how to copy /var/log/omarchy-deck-install.json off the device"

# ---------------------------------------------------------------------------
# 10. the port is derived, not assumed
# ---------------------------------------------------------------------------

d=$(full_scenario odd-port)
printf '2222\n' >"$d/state/sshd-ports"
out=$(run_in "$d" on 2>&1) || fail "'on' succeeds with a non-default sshd port"
grep -q 'port 2222' "$d/state/ufw-log" ||
  fail "the firewall rule uses the port sshd is configured for" \
       "$(cat "$d/state/ufw-log")"
grep -q 'port 22 ' "$d/state/ufw-log" &&
  fail "a non-default port must not also open 22" "$(cat "$d/state/ufw-log")"
pass "the opened port is read from sshd's own config, not assumed to be 22"

# If sshd's config cannot be read, fall back to 22 and SAY SO.
d=$(full_scenario port-unreadable)
: >"$d/state/sshd-T-fails"
out=$(run_in "$d" on 2>&1) || fail "'on' still succeeds when sshd -T fails"
grep -q 'port 22 ' "$d/state/ufw-log" ||
  fail "an unreadable sshd config falls back to port 22" "$(cat "$d/state/ufw-log")"
grep -qi 'warning' <<<"$out" ||
  fail "an assumed port is announced as an assumption" "$out"
pass "an unreadable sshd config falls back to 22 and says it is a guess"

# ---------------------------------------------------------------------------
# 11. 'off' does not lie about foreign rules
# ---------------------------------------------------------------------------

d=$(full_scenario foreign-rule)
unit_start "$d" sshd.service
ufw_add_rule "$d" '22/tcp|ALLOW IN|Anywhere|'
rc=0; out=$(run_in "$d" off 2>&1) || rc=$?
(( rc == 0 )) || fail "'off' succeeds with a foreign SSH rule present" "rc=$rc: $out"
grep -qi 'warning' <<<"$out" ||
  fail "'off' warns that a rule it did not create still mentions the SSH port" "$out"
(( $(grep -c . "$d/state/ufw-rules") == 1 )) ||
  fail "'off' must not delete rules it did not create" "$(cat "$d/state/ufw-rules")"
pass "'off' leaves foreign SSH rules alone but says they are still there"

# ---------------------------------------------------------------------------
# 11b. 'on' does not CLAIM lan-only when it is not
#
# 🔴 CAUGHT ON HARDWARE, NOT HERE. `on` printed "allowed from
# 192.168.100.0/24 only" on a Deck that also carried two hand-added
# `22/tcp ALLOW IN Anywhere` rules. `off` had this check; `on` asserted the
# restriction without ever looking. The words are reassuring in the one
# direction that costs something: the operator takes the Deck onto a café
# network believing the port is LAN-scoped.
#
# Asserted as "must not say 'only'" plus "must warn", not on the exact
# sentence -- the wording is not this file's to own.
# ---------------------------------------------------------------------------

d=$(full_scenario on-foreign-rule)
ufw_add_rule "$d" '22/tcp|ALLOW IN|Anywhere|'
rc=0; out=$(run_in "$d" on 2>&1) || rc=$?
(( rc == 0 )) || fail "'on' succeeds with a foreign SSH rule present" "rc=$rc: $out"
grep -qi 'warning' <<<"$out" ||
  fail "'on' must warn that a foreign rule defeats the LAN-only restriction" "$out"
grep -qiE '\bonly\.' <<<"$out" &&
  fail "'on' must NOT claim the port is allowed from the local subnet 'only' while a broader rule stands" "$out"
pass "'on' refuses to claim LAN-only while a foreign rule could widen it"

# The positive control: with NO foreign rule, it may and must say 'only'.
# Without this, deleting the claim entirely would also pass the check above.
d=$(full_scenario on-clean)
rc=0; out=$(run_in "$d" on 2>&1) || rc=$?
(( rc == 0 )) || fail "'on' succeeds on a clean firewall" "rc=$rc: $out"
grep -qiE '\bonly\.' <<<"$out" ||
  fail "'on' must still state the LAN-only restriction when it genuinely holds" "$out"
pass "'on' still claims LAN-only when nothing contradicts it"

# ---------------------------------------------------------------------------
# 12. the installer must not call this
#
# "off by default, always" is a property of the whole tree, not of this file,
# so it is asserted against the tree.
# ---------------------------------------------------------------------------

# ⚠️ Scoped to the INSTALL PATH, not to the whole tree. src/pizza is the
# dispatcher, and dispatching to us is its entire job — asserting against it
# would be asserting against the feature. What must never happen is the
# installer, the ISO overlay, or any unit/autostart reaching for this at all.
install_path=()
[[ -f $REPO_ROOT/src/deck-session.sh ]] && install_path+=("$REPO_ROOT/src/deck-session.sh")
[[ -d $REPO_ROOT/iso/overlay ]]        && install_path+=("$REPO_ROOT/iso/overlay")
[[ -d $REPO_ROOT/src/iso-patches ]]    && install_path+=("$REPO_ROOT/src/iso-patches")
[[ -d $REPO_ROOT/src/omarchy-deck-patches ]] && install_path+=("$REPO_ROOT/src/omarchy-deck-patches")
(( ${#install_path[@]} > 0 )) ||
  fail "the install path exists to be checked" \
       "neither deck-session.sh nor iso/overlay was found; this check is vacuous"

# 🔴 THIS ASSERTED "NO MENTION" AND THAT WAS THE WRONG PROPERTY, twice over.
#
# It went red on 2026-08-16 for two references that are both correct:
#   * deck-dashboard.sh's install tips TELL THE USER THE COMMAND EXISTS. A tip
#     is documentation. Naming a command is the opposite of running it.
#   * deck-session.sh's stage-pizza has to COPY src/pizza-ssh onto the target.
#     Shipping a script is not enabling a service.
#
# "Off by default" is a claim about what RUNS, not about what the word count of
# the tree is. So this now forbids the two things that would actually make it
# false: invoking the command with an enabling verb, and reaching around it to
# enable sshd or open the firewall directly. A grep for the mere name could
# only ever be satisfied by never shipping the feature at all.
enabling=$(grep -rIn -E \
  -e '(pizza-ssh|pizza[[:space:]]+ssh)([[:space:]]+(on|start|enable))?[[:space:]]*($|[;&|)])' \
  "${install_path[@]}" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' |
  grep -E '(pizza-ssh|pizza[[:space:]]+ssh)[[:space:]]+(on|start|enable)' || true)
[[ -z $enabling ]] ||
  fail "the installer must never RUN pizza ssh with an enabling verb (off by default, always)" \
       "$enabling"

# The reach-around: enabling SSH without going through this script at all.
reachable=$(grep -rIn -E \
  -e 'systemctl[^|;]*enable[^|;]*sshd' \
  -e 'ufw[[:space:]]+allow[^|;]*(22|ssh)' \
  "${install_path[@]}" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
[[ -z $reachable ]] ||
  fail "the installer must never enable sshd or open port 22 by any route" "$reachable"
pass "the install path ships pizza-ssh but never runs it, and never opens SSH itself"

# Nor may this script enable itself at boot.
grep -qE 'systemctl[^\n]*enable[^\n]*pizza' "$SCRIPT" &&
  fail "pizza-ssh must not install a unit or enable itself at boot"
pass "pizza-ssh installs no unit and enables nothing at boot"

printf '\nall pizza-ssh tests passed\n'

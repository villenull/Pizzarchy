#!/usr/bin/env bash
# omarchy-deck-wifi-first-boot -- say something, on the installed system, when
# the Wi-Fi credentials joined in the installer did not turn into a working
# network.
#
# SHIPPED AS: /usr/share/omarchy-iso/deck/deck-wifi-first-boot.sh in the ISO;
# copied by `configure_deck` (../orchestrator/deck_wifi.py) onto the target as
# /usr/local/bin/omarchy-deck-wifi-first-boot, driven by
# omarchy-deck-wifi-first-boot.service.
#
# WHY IT EXISTS
#
# docs/tasks/T5-fork-plan.md §4.1 requirement (iii): the install is allowed to
# come out degraded, it is NOT allowed to come out degraded and quiet. There
# are two ways to reach a Deck with no network, and this file is the only
# thing that can tell them apart on the machine itself:
#
#   carried=no   the user skipped Wi-Fi, had no radio, or iwd failed. Nothing
#                to retry -- there are no credentials. Say so, in the one place
#                a user without a keyboard can act on it.
#   carried=yes  a profile WAS written to
#                /etc/NetworkManager/system-connections/ and the machine still
#                is not connected. This is the interesting one: NetworkManager
#                ignores a keyfile it dislikes (wrong mode, wrong contents)
#                without logging anything a user would find, so without this
#                unit that failure is completely invisible.
#
# 🔴 IT EXITS NON-ZERO WHEN THERE IS NO NETWORK, AND THAT IS THE POINT.
# The Deck has no terminal in normal use; a failed unit is the channel that
# survives a reboot, so `systemctl --failed` is non-empty and the state is
# discoverable without knowing to look for it. Same reasoning as
# src/omarchy-deck-patches/omarchy-deck-patch-check.service.
#
# 🔴 IT DISABLES ITSELF ONCE THE MACHINE HAS A NETWORK, by removing its own
# multi-user.target.wants symlink. A unit that re-ran forever would be a nag,
# and worse, its permanent presence in `systemctl --failed` would train people
# to ignore the one channel this file has.
#
# ⚠️ THE STATE FILE IS PARSED, NEVER SOURCED. It carries an SSID, which is
# attacker-controlled text; `source` would execute it as shell. configure_deck
# already sanitises what it writes there -- this parser is the second line of
# defence, not the only one, and it re-strips control bytes for that reason.
# Same rule the installer's own /root/deck-wifi-outcome carries.

set -euo pipefail

readonly PROG=omarchy-deck-wifi-first-boot

# Test seams. Empty in production; the unit suite points them at a temp tree.
ROOT=${DECK_WIFI_ROOT:-}
SYSFS_NET=${DECK_WIFI_SYSFS_NET:-$ROOT/sys/class/net}
STATE_FILE=${DECK_WIFI_STATE_FILE:-$ROOT/var/lib/omarchy-deck/wifi-carry}
STATUS_FILE=${DECK_WIFI_STATUS_FILE:-$ROOT/var/lib/omarchy-deck/wifi-status}
WANTS_LINK=${DECK_WIFI_WANTS_LINK:-$ROOT/etc/systemd/system/multi-user.target.wants/omarchy-deck-wifi-first-boot.service}
WAIT_SECS=${DECK_WIFI_WAIT_SECS:-45}
POLL_SECS=${DECK_WIFI_POLL_SECS:-3}

log()  { printf '[%s] %s\n' "$PROG" "$*"; }
warn() { printf '[%s] %s\n' "$PROG" "$*" >&2; }

# strip_controls <text> -- delete control bytes and DEL, keep everything else.
# Identical treatment to deck_form_sanitize_ssid in src/deck-form.sh and
# sanitize_text in ../orchestrator/deck_configure.py: an SSID may legitimately
# be UTF-8, so the answer is to delete the bytes that could repaint a console
# or forge a
# line, not to reduce the name to ASCII and report a network that is not the
# one the user joined.
strip_controls() {
  LC_ALL=C printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177'
}

# read_state -- parse key=value, FIRST WINS.
#
# First-wins for the same reason configure_deck's parser uses it: if an SSID
# ever carried a newline, the forged line lands after the real one, and a
# last-wins parser would believe the forgery. Lines without '=' are ignored.
carried=no
status=missing
ssid=
seen_carried=0
seen_status=0
seen_ssid=0

read_state() {
  local line key value
  [[ -r $STATE_FILE ]] || {
    warn "no state file at $STATE_FILE -- configure_deck did not run, or did not finish"
    return 0
  }
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line == *=* ]] || continue
    key=${line%%=*}
    value=${line#*=}
    value=$(strip_controls "$value")
    # ⚠️ `if`, not `[[ ... ]] && x=y`. Under `set -e` an && list whose LAST
    # command is the failing test terminates the script, so the guard-and-assign
    # idiom would make a state file that omits a key kill this unit outright.
    # ⚠️ The `seen_*` flags are what make first-wins actually first-wins. A
    # sentinel test (`[[ $carried == no ]]`) would let a forged second
    # `carried=yes` line through whenever the genuine first one said `no` --
    # i.e. exactly in the case the forgery would be aimed at.
    case $key in
      carried)
        if [[ $seen_carried == 0 ]]; then
          seen_carried=1
          if [[ -n $value ]]; then carried=$value; fi
        fi
        ;;
      status)
        if [[ $seen_status == 0 ]]; then
          seen_status=1
          if [[ -n $value ]]; then status=$value; fi
        fi
        ;;
      ssid)
        if [[ $seen_ssid == 0 ]]; then
          seen_ssid=1
          ssid=$value
        fi
        ;;
      *) ;;
    esac
  done <"$STATE_FILE"
  return 0
}

# has_wireless -- is there a radio at all?
#
# Read from sysfs rather than from nmcli: it needs no daemon, no D-Bus and no
# NetworkManager, so "there is no wireless hardware" cannot be confused with
# "NetworkManager is not up yet". Every wireless interface has a `wireless`
# directory (or a `phy80211` link) under /sys/class/net/<iface>/.
has_wireless() {
  local iface
  [[ -d $SYSFS_NET ]] || return 1
  for iface in "$SYSFS_NET"/*; do
    if [[ -e $iface/wireless || -e $iface/phy80211 ]]; then
      return 0
    fi
  done
  return 1
}

# connected -- does NetworkManager report a usable connection?
#
# `nmcli -t -f STATE general` prints exactly one word-ish line: `connected`,
# `connected (site only)`, `connecting`, `disconnected`, `asleep`. Matching the
# `connected` prefix accepts the site-only case deliberately: a LAN with no
# route to the internet is still a network the user can fix things from, and
# treating it as failure would fire this notice on a perfectly working Deck.
connected() {
  local state
  state=$(nmcli -t -f STATE general 2>/dev/null) || return 1
  [[ $state == connected* ]]
}

write_status() {
  local verdict=$1 message=$2 dir
  dir=$(dirname -- "$STATUS_FILE")
  mkdir -p "$dir"
  {
    printf 'verdict=%s\n' "$verdict"
    printf 'carried=%s\n' "$carried"
    printf 'status=%s\n' "$status"
    printf 'ssid=%s\n' "$ssid"
    printf 'checked_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')"
    printf 'message=%s\n' "$message"
  } >"$STATUS_FILE"
  chmod 0644 "$STATUS_FILE"
}

# Disable for future boots. Removing the .wants symlink is enough and needs no
# running systemd, which keeps this script testable and keeps it working if it
# is ever run by hand.
self_disable() {
  [[ -e $WANTS_LINK || -L $WANTS_LINK ]] || return 0
  rm -f "$WANTS_LINK"
  log "disabled for future boots (removed $WANTS_LINK)"
}

notify() {
  local message=$1
  command -v omarchy-notification-send >/dev/null 2>&1 || {
    log "omarchy-notification-send is not available; the journal and $STATUS_FILE carry this"
    return 0
  }
  # Never fatal: the notification is an extra channel, not the channel.
  omarchy-notification-send "Wi-Fi" "$message" || warn "omarchy-notification-send failed"
}

main() {
  read_state

  if ! has_wireless; then
    # Nothing to retry and nothing to warn about repeatedly: this machine has
    # no radio (every QEMU run, and any Deck whose driver failed to load -- the
    # latter is a kernel problem this unit cannot help with). Report it once
    # and stand down, so a permanently failed unit does not devalue the signal.
    log "no wireless interface under $SYSFS_NET -- nothing to retry"
    write_status ok "No wireless hardware was found on this system."
    self_disable
    return 0
  fi

  if ! command -v nmcli >/dev/null 2>&1; then
    warn "nmcli is not installed -- cannot tell whether this Deck has a network"
    write_status unknown "nmcli is missing; NetworkManager may not be installed."
    return 1
  fi

  local waited=0
  while :; do
    if connected; then
      log "NetworkManager reports a connection${ssid:+ (installer network: $ssid)}"
      write_status ok "Connected."
      self_disable
      return 0
    fi
    if ((waited >= WAIT_SECS)); then
      break
    fi
    sleep "$POLL_SECS"
    waited=$((waited + POLL_SECS))
  done

  local message
  if [[ $carried == yes ]]; then
    # The invisible failure this unit was written for.
    message="The Wi-Fi network${ssid:+ \"$ssid\"} set up during installation is not connected. Open Desktop Mode and pick a network."
  else
    message="No Wi-Fi was set up during installation (${status}). Open Desktop Mode and pick a network."
  fi
  warn "$message"
  write_status degraded "$message"
  notify "$message"
  return 1
}

main "$@"

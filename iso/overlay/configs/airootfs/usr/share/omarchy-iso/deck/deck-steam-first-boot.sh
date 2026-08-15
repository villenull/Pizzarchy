#!/usr/bin/env bash
# omarchy-deck-steam-first-boot -- say something, on the installed system, when
# the packages the installer was supposed to fetch are not there.
#
# SHIPPED AS: /usr/share/omarchy-iso/deck/deck-steam-first-boot.sh in the ISO;
# copied by `configure_deck` (../orchestrator/deck_pkgs.py) onto the target as
# /usr/local/bin/omarchy-deck-steam-first-boot, driven by
# omarchy-deck-steam-first-boot.service.
#
# WHY IT EXISTS
#
# docs/findings/P32-steam-never-installed.md. An ISO shipped with no consumer
# for deck-fetch.packages, the installed Deck had no Steam, gamescope started
# with nothing to display, and the panel stayed black through two complete
# boots. The install's own record said eleven steps, all green; the QEMU suite
# said 18/18. NOTHING ANYWHERE ASKED WHETHER STEAM WAS ON THE MACHINE.
#
# This file asks, on the machine, at every boot, until the answer is yes. It is
# the last of the three channels docs/tasks/T5-fork-plan.md §4.1 requires --
# (i) say it on screen during the install, (ii) record it in
# /var/log/omarchy-deck-install.json, (iii) leave a first-boot unit that tells
# the user -- and it is the only one that survives to a running system.
#
# 🔴 IT CHECKS THE OUTCOME, NOT THE STEP. The state file deck_pkgs.py writes is
# read for CONTEXT (what was expected, why it failed) and is never trusted for
# the verdict: a `status=installed` line proves only that pacman exited 0 at
# install time, which is exactly the class of evidence that was already green
# on a Deck with a black screen. The verdict comes from `pacman -Qq` against
# this machine's own database, plus the bootstrap tarball on this machine's own
# disk.
#
# 🔴 IT EXITS NON-ZERO WHEN SOMETHING IS MISSING, AND THAT IS THE POINT.
# The Deck has no terminal in normal use; a failed unit is the channel that
# survives a reboot, so `systemctl --failed` is non-empty and the state is
# discoverable without knowing to look for it. Same reasoning as
# omarchy-deck-wifi-first-boot.service and
# src/omarchy-deck-patches/omarchy-deck-patch-check.service.
#
# 🔴 IT DISABLES ITSELF once every expected package is present, by removing its
# own multi-user.target.wants symlink. A unit that re-ran forever would be a
# nag, and worse, its permanent presence in `systemctl --failed` would train
# people to ignore the one channel this file has. It does NOT disable itself on
# a bad verdict -- that is what makes it retry, so a user who installs Steam by
# hand on Tuesday gets a clean `systemctl --failed` on Wednesday without having
# to know this unit exists.
#
# ⚠️ IT DOES NOT INSTALL ANYTHING. Reporting and repairing are different jobs:
# a root pacman transaction fired automatically at every boot, over whatever
# network happens to be there, on a device the user is holding, is not
# something this project is going to do silently. The message names the exact
# command instead.
#
# ⚠️ THE STATE FILE IS PARSED, NEVER SOURCED. It carries pacman's error tail,
# which is not our text; `source` would execute it as shell. deck_pkgs.py
# already sanitises what it writes there -- this parser is the second line of
# defence, not the only one, and it re-strips control bytes for that reason.
# Same rule as the Wi-Fi notice beside it.

set -euo pipefail

readonly PROG=omarchy-deck-steam-first-boot

# Test seams. Empty in production; the unit suite points them at a temp tree.
ROOT=${DECK_PKGS_ROOT:-}
STATE_FILE=${DECK_PKGS_STATE_FILE:-$ROOT/var/lib/omarchy-deck/fetch-packages}
STATUS_FILE=${DECK_PKGS_STATUS_FILE:-$ROOT/var/lib/omarchy-deck/fetch-status}
BOOTSTRAP=${DECK_PKGS_BOOTSTRAP:-$ROOT/usr/lib/steam/bootstraplinux_ubuntu12_32.tar.xz}
WANTS_LINK=${DECK_PKGS_WANTS_LINK:-$ROOT/etc/systemd/system/multi-user.target.wants/omarchy-deck-steam-first-boot.service}

# The package whose absence is a black screen rather than a missing feature.
# Named here as well as in the state file because the bootstrap tarball check
# is specific to it -- every other entry is answered by `pacman -Qq` alone.
readonly STEAM_PACKAGE=steam

log()  { printf '[%s] %s\n' "$PROG" "$*"; }
warn() { printf '[%s] %s\n' "$PROG" "$*" >&2; }

# strip_controls <text> -- delete control bytes and DEL, keep everything else.
# Identical treatment to deck_form_sanitize_ssid in src/deck-form.sh and
# sanitize_text in ../orchestrator/deck_configure.py: delete the bytes that
# could repaint a root console or forge a line, keep the rest.
strip_controls() {
  LC_ALL=C printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177'
}

# read_state -- parse key=value, FIRST WINS.
#
# First-wins for the same reason configure_deck's parser uses it: a value
# carrying a newline puts its forged line AFTER the real one, and a last-wins
# parser would believe the forgery. Lines without '=' are ignored.
state_status=missing
expected=
recorded_installed=
wifi_status=unknown
recorded_error=
seen_status=0
seen_expected=0
seen_installed=0
seen_wifi=0
seen_error=0

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
    # sentinel test would let a forged second line through whenever the genuine
    # first one happened to be empty -- i.e. exactly where a forgery would aim.
    case $key in
      status)
        if [[ $seen_status == 0 ]]; then
          seen_status=1
          if [[ -n $value ]]; then state_status=$value; fi
        fi
        ;;
      expected)
        if [[ $seen_expected == 0 ]]; then
          seen_expected=1
          expected=$value
        fi
        ;;
      installed)
        if [[ $seen_installed == 0 ]]; then
          seen_installed=1
          recorded_installed=$value
        fi
        ;;
      wifi_status)
        if [[ $seen_wifi == 0 ]]; then
          seen_wifi=1
          if [[ -n $value ]]; then wifi_status=$value; fi
        fi
        ;;
      error)
        if [[ $seen_error == 0 ]]; then
          seen_error=1
          recorded_error=$value
        fi
        ;;
      *) ;;
    esac
  done <"$STATE_FILE"
  return 0
}

# package_installed <name> -- ask THIS machine's pacman database.
#
# `pacman -Qq` and not a file test, because "is this package installed" is a
# question pacman owns; and not the state file, because the state file records
# what the installer believed.
package_installed() {
  pacman -Qq "$1" >/dev/null 2>&1
}

# missing_packages -- echo the space-separated subset of $expected that this
# machine does not have. Empty output means everything is present.
missing_packages() {
  local name out=
  # shellcheck disable=SC2086
  # Unquoted ON PURPOSE: $expected is a space-separated list and word splitting
  # is how it is read. Globbing cannot bite -- deck_pkgs.py rejects any entry
  # containing a character outside pacman's own name set before it is written,
  # so `*` and `?` cannot reach this line.
  for name in $expected; do
    if ! package_installed "$name"; then
      out="${out:+$out }$name"
    fi
  done
  printf '%s' "$out"
}

# classify <missing> <bootstrap> -- THE DECISION, and the only place it is made.
#
#   missing    space-separated names this machine does not have ("" = none)
#   bootstrap  yes | no | n/a  (n/a when steam was never expected here)
#
# Echoes exactly one of: ok | missing | no-bootstrap
#
# Split out as a function of its two inputs so the branches exist once and the
# suite can reach every one of them by controlling only the fake machine's
# pacman and its files -- no boot, no systemd, no network. `no-bootstrap` is a
# distinct verdict from `missing` on purpose: they read identically to a user
# (Gaming Mode does not start) and they need completely different fixes
# (install the package vs. a package that is installed and broken).
classify() {
  local missing=$1 bootstrap=$2
  if [[ -n $missing ]]; then
    printf 'missing'
    return 0
  fi
  if [[ $bootstrap == no ]]; then
    printf 'no-bootstrap'
    return 0
  fi
  printf 'ok'
}

# verdict_message <verdict> <missing> -- what a human is told.
verdict_message() {
  local verdict=$1 missing=$2
  case $verdict in
    ok)
      printf 'Everything the installer was asked to download is installed.'
      ;;
    missing)
      if [[ $state_status == skipped-no-network ]]; then
        printf 'The installer could not download %s because this Deck had no network during setup (Wi-Fi: %s). Connect to a network and run: sudo pacman -S --needed %s' \
          "$missing" "$wifi_status" "$missing"
      else
        printf 'The installer did not install %s (recorded status: %s). Without Steam, Gaming Mode has nothing to show and the screen stays black. Connect to a network and run: sudo pacman -S --needed %s' \
          "$missing" "$state_status" "$missing"
      fi
      ;;
    no-bootstrap)
      printf 'Steam is installed but its bootstrap archive %s is missing, so steam-launcher cannot start and Gaming Mode will not appear. Reinstall it with: sudo pacman -S steam' \
        "$BOOTSTRAP"
      ;;
    *)
      printf 'Unrecognised verdict %s.' "$verdict"
      ;;
  esac
}

write_status() {
  local verdict=$1 message=$2 missing=$3 reason=${4:-$1} dir
  dir=$(dirname -- "$STATUS_FILE")
  mkdir -p "$dir"
  {
    printf 'verdict=%s\n' "$verdict"
    # `verdict` is the coarse answer (ok / degraded / unknown) and `reason` is
    # classify()'s own word. They are separate because they are read by
    # different people: a human wants "is this Deck alright", and whoever has
    # to fix it needs to know that `missing` and `no-bootstrap` look identical
    # on screen and need completely different repairs.
    printf 'reason=%s\n' "$reason"
    printf 'expected=%s\n' "$expected"
    printf 'missing=%s\n' "$missing"
    # What the INSTALLER believed it installed, kept beside what is actually
    # here. A name in both `install_recorded` and `missing` is a much stronger
    # signal than a plain absence: it means the package was installed and then
    # went away, which no amount of re-reading the install log would show.
    printf 'install_recorded=%s\n' "$recorded_installed"
    printf 'install_status=%s\n' "$state_status"
    printf 'wifi_status=%s\n' "$wifi_status"
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
  # Never fatal: the notification is an extra channel, not the channel. On a
  # Deck that boots straight into Gaming Mode there may be no notification
  # daemon listening at all, which is exactly why the failed unit and the
  # status file are the primary reports.
  omarchy-notification-send "Steam" "$message" || warn "omarchy-notification-send failed"
}

main() {
  read_state

  if [[ -z $expected ]]; then
    # Nothing was ever asked for. Not an error and not something to repeat: a
    # build where deck-fetch.packages was legitimately empty, or a state file
    # from a configure_deck that got no further than writing it.
    log "no packages expected (state file lists none) -- nothing to check"
    write_status ok "No downloaded packages were expected on this system." "" none-expected
    self_disable
    return 0
  fi

  if ! command -v pacman >/dev/null 2>&1; then
    # An Arch system without pacman is not a state this script can reason
    # about, and claiming "ok" would be the silent green this whole file
    # exists to prevent.
    warn "pacman is not on PATH -- cannot tell whether $expected is installed"
    write_status unknown "pacman is missing; this system's package state cannot be read." "" no-pacman
    return 1
  fi

  local missing bootstrap verdict message
  missing=$(missing_packages)

  bootstrap=n/a
  case " $expected " in
    *" $STEAM_PACKAGE "*)
      if [[ -f $BOOTSTRAP ]]; then bootstrap=yes; else bootstrap=no; fi
      ;;
  esac
  # A steam that is not installed has no bootstrap tarball either, and
  # reporting both would send the reader after the wrong one. `missing` wins in
  # classify(); this keeps the recorded facts consistent with that.
  case " $missing " in
    *" $STEAM_PACKAGE "*) bootstrap=n/a ;;
  esac

  verdict=$(classify "$missing" "$bootstrap")
  message=$(verdict_message "$verdict" "$missing")

  if [[ $verdict == ok ]]; then
    log "$message"
    write_status ok "$message" "" "$verdict"
    self_disable
    return 0
  fi

  warn "$message"
  write_status degraded "$message" "$missing" "$verdict"
  notify "$message"
  if [[ -n $recorded_error ]]; then
    warn "the installer recorded: $recorded_error"
  fi
  return 1
}

main "$@"

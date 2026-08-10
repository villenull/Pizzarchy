#!/usr/bin/env bash
#
# deck-session.sh -- two-way Gaming Mode <-> Desktop Mode session switching
# for a Steam Deck running Omarchy. T3's session layer.
#
# ===========================================================================
# WHAT UPSTREAM ALREADY DOES -- verified by reading what the installed
# packages actually ship (jupiter-staging/gamescope 3.16.25-3, Valve's build).
# ===========================================================================
#
# Valve's gamescope package already ships the ENTIRE SteamOS Gaming Mode
# session. This is worth stating because PLAN.md 6.4 says to fork
# 28allday/Super-Shift-S-Omarchy-Deck-Mode "because it solves the hard part",
# and that is no longer true:
#
#   /usr/share/wayland-sessions/gamescope-wayland.desktop  the session entry
#   /usr/bin/start-gamescope-session                       the entry point
#   /usr/lib/steamos/gamescope-session                     the real launcher
#   /usr/lib/systemd/user/gamescope-session.target         the unit graph
#   ... plus steam-launcher, ibus-gamescope, steam-notif-daemon,
#       gamescope-mangoapp and galileo-mura-setup (OLED mura correction).
#
# The closest prior art (28allday/deckshift) pulls ChimeraOS's
# gamescope-session from the AUR to get this -- necessarily, because DeckShift
# targets generic PCs with no access to Valve's repos. On Deck hardware with
# jupiter-staging configured, none of that is needed. DeckShift is also
# unlicensed, so this project cannot ship or vendor it at all.
#
# So this script does NOT build a session and does NOT fork one. It supplies
# the one thing Valve does not ship outside SteamOS: the mechanism for
# switching between that session and the Omarchy desktop, in both directions.
#
# ===========================================================================
# THE GAP THIS CLOSES
# ===========================================================================
#
# Steam's "Power -> Switch to Desktop" in Gaming Mode shells out to
# `steamos-session-select desktop`. That binary lives in SteamOS's
# steamos-customizations and is in NO repo configured here (verified with
# `pacman -F` against core/extra/multilib/omarchy/jupiter-staging/
# holo-staging). Without it, Steam's own affordance silently does nothing --
# which is PLAN.md 8.1's failure mode, in the one place a controller-only
# user has no way to work around.
#
# So: install a `steamos-session-select` that behaves the way Steam expects,
# plus a matching path back from the desktop.
#
# Steam needs a SECOND thing, found later and by measurement rather than
# reasoning: it drives a set of privileged helpers out of
# /usr/bin/steamos-polkit-helpers/, by ABSOLUTE path. That whole tree belongs
# to SteamOS and is absent here, so each call returns 127. Only one of them is
# handled in this script (steamos-update, whose absence blocks Steam's
# first-run setup behind a false network error); the rest -- brightness via
# steamos-priv-write, timezone, fan control -- are a larger open question, not
# a detail. See PROGRESS.md 5.15.
#
# Note the two families resolve DIFFERENTLY, but BOTH land in /usr/bin:
#   steamos-session-select        via PATH, and that PATH is only
#                                 "/usr/bin:/bin" inside Steam's runtime
#   steamos-polkit-helpers/*      by absolute path, /usr/bin/steamos-polkit-helpers/
#
# So /usr/local/bin -- the conventional home for exactly this kind of local
# shim -- is unreachable for anything Steam invokes. Both stages verify
# reachability, not just existence, because the difference is invisible from a
# shell where /usr/local/bin is on PATH.
#
# ===========================================================================
# SECURITY TRADEOFF -- read before extending
# ===========================================================================
#
# Switching sessions means restarting the display manager, which is root-only.
# Steam invokes the hook as the unprivileged desktop user, so something has to
# bridge that.
#
# This uses a sudoers drop-in granting NOPASSWD on exactly one absolute path
# (${SELECT_BIN}) and nothing else. That is a real privilege grant and is
# deliberately narrow: the target is root-owned 0755, so a user who could
# rewrite it would already need root. The drop-in is validated with
# `visudo -c` before installation -- a malformed sudoers file breaks sudo
# for every user on the machine, so it is never written unvalidated.
#
# polkit would be the more conventional mechanism. It is not used here
# because the action would still amount to "this user may restart the display
# manager", and a sudoers line saying exactly that is far easier to audit
# than a polkit rule plus a helper. Revisit if this ships as a package.
#
set -euo pipefail

readonly PROG=deck-session

# The two session names, as SDDM knows them: the basename of the .desktop in
# a wayland-sessions directory, without the extension. Discovered rather than
# assumed -- see stage_preconditions.
readonly GAMING_SESSION=gamescope-wayland
DESKTOP_SESSION=""   # resolved at runtime; Omarchy's own entry

readonly SELECT_BIN=/usr/local/bin/deck-session-select

# /usr/bin, NOT /usr/local/bin. Steam's runtime narrows PATH to exactly
# "/usr/bin:/bin" -- read from the running Steam process's own environ, with
# SYSTEM_PATH unset so the ${PATH} fallback in its command template applies.
# The shim spent P1.5 in /usr/local/bin, where it existed, worked when invoked
# by hand, and was invisible to the one caller that matters.
readonly STEAM_SHIM=/usr/bin/steamos-session-select
readonly STEAM_SHIM_LEGACY=/usr/local/bin/steamos-session-select

# What Steam's runtime actually offers. Used to prove the shim is reachable
# rather than merely present.
readonly STEAM_RUNTIME_PATH=/usr/bin:/bin
readonly SUDOERS_FILE=/etc/sudoers.d/99-deck-session-select
readonly RETURN_DESKTOP_FILE=/usr/share/applications/deck-return-to-gaming.desktop
readonly STATE_FILE=/var/lib/deck-session/next-session

# Steam resolves its privileged helpers by ABSOLUTE path, not through PATH --
# measured from Steam's own logs on this hardware, not inferred:
#
#   PATH="${SYSTEM_PATH-${PATH}}"  /usr/bin/steamos-polkit-helpers/steamos-update check
#
# so anything installed here has to live at that exact path. /usr/local/bin is
# not an option for these the way it is for steamos-session-select (which Steam
# *does* invoke through PATH). Nothing in this project may assume the two
# families resolve the same way.
readonly POLKIT_HELPER_DIR=/usr/bin/steamos-polkit-helpers
readonly UPDATE_STUB="${POLKIT_HELPER_DIR}/steamos-update"

# Named once so the stub, its --help and this script's own output cannot drift
# into telling a user three different things about how to update the machine.
readonly REAL_UPDATE_HINT='sudo pacman -Syu'

# --- Display rotation (PROGRESS.md 5.11) ----------------------------------
#
# The Deck's panel scans out 800x1280 PORTRAIT and is mounted rotated, so every
# surface that does not rotate itself renders sideways. fbcon/rotate is 0 on
# both stock Arch and Neptune, so no kernel this project ships corrects it and
# the fix is per-surface, in userspace. Gaming Mode is exempt: gamescope
# applies its own transform.
#
# transform 3 (270 deg) and NOT 1: both were applied on this hardware and
# looked at, and 1 renders upside down. R-19 recorded transform,1 by inference.
readonly PANEL_OUTPUT=eDP-1
readonly PANEL_TRANSFORM=3
readonly PANEL_SCALE=1.25

# Omarchy's greeter config is package-owned (omarchy-settings-dev), so editing
# it in place would be undone by the next upgrade. Ship our own beside it and
# repoint SDDM instead.
readonly GREETER_LUA=/usr/local/share/deck-session/greeter-hyprland.lua
readonly UPSTREAM_GREETER_LUA=/usr/share/sddm/hyprland.lua

# Ours must sort AFTER Omarchy's 10-wayland.conf (which sets CompositorCommand)
# to win, and is deliberately a different file from SDDM_DROPIN because
# deck-session-select rewrites that one on every switch -- a CompositorCommand
# living there would vanish the first time anyone changed session.
readonly SDDM_GREETER_DROPIN=/etc/sddm.conf.d/zy-deck-greeter.conf

# A systemd drop-in, NOT an sddm.conf one -- this is about the unit's restart
# policy, not about SDDM's own settings.
readonly SDDM_UNIT_DROPIN=/etc/systemd/system/sddm.service.d/50-deck-switch-resilience.conf

# Our greeter config is a self-contained MIRROR of upstream's settings plus the
# monitor transform -- not an include, because Hyprland's Lua parser offers no
# documented way to source another file and a greeter that fails to parse is a
# device with no graphical way in. The cost of copying is drift, so the stage
# checks this hash and warns when upstream's file changes. Update both together.
readonly UPSTREAM_GREETER_SHA256=353fe59d7d46b21946cdc48000eef7b131e9e577c1d6117f07c3137cdbf0fe67

# Every file this script installs carries this line, so a re-run recognises
# its own output (the idempotency requirement) and refuses to clobber someone
# else's. Keyed on a marker rather than on file type, because a symlink test
# would not survive the first time we install a real script.
#
# The COMMENT PREFIX varies by file type and the bare text is what we match on.
# This is not fussiness: the marker was originally '#'-only, and embedding it in
# a Lua config put a '#' on line 2, where Lua only accepts one on line 1. That
# is a syntax error, so Hyprland discarded the entire greeter config and fell
# back to defaults -- rotated -- without logging anything. Add a new prefix here
# rather than reusing one that happens to be nearby.
readonly INSTALL_MARKER_TEXT="installed-by: ${PROG}.sh"
readonly INSTALL_MARKER="# ${INSTALL_MARKER_TEXT}"        # shell, ini/sddm.conf
readonly INSTALL_MARKER_LUA="-- ${INSTALL_MARKER_TEXT}"   # lua (hyprland config)

# BUG FIX (was 95-deck-session.conf): SDDM reads /etc/sddm.conf.d/*.conf in
# lexical order and LATER files win. The previous name carried a comment
# claiming it "sorts after Omarchy's autologin.conf" -- it does not, because
# '9' < 'a', so autologin.conf overrode it on every machine. The bug was in a
# comment asserting an ordering nobody checked, and it went undetected because
# Gaming Mode had never been booted, so the code path was never exercised.
#
# 'zz-' sorts after any plausible neighbour. Confirmed empirically rather than
# reasoned: DeckShift's own zz- drop-in was observed winning over
# autologin.conf on this hardware.
readonly SDDM_DROPIN=/etc/sddm.conf.d/zz-deck-session.conf

readonly -a INSTALL_STAGES=(
  stage-preconditions
  stage-session-select
  stage-steam-hook
  stage-update-stub
  stage-greeter-rotation
  stage-sddm-resilience
  stage-return-icon
)

log()  { printf '[%s] %s\n' "$PROG" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$PROG" "$*" >&2; }
fail() { printf '[%s] ERROR: %s\n' "$PROG" "$*" >&2; exit 1; }
usage_error() { printf '[%s] usage: %s\n' "$PROG" "$*" >&2; exit 2; }

SUDO=""
INTERACTIVE=1
[[ -t 0 ]] || INTERACTIVE=0

# ---------------------------------------------------------------------------

stage_preconditions() {
  local tool
  for tool in systemctl install findmnt; do
    command -v "$tool" >/dev/null 2>&1 ||
      fail "required tool '$tool' not found"
  done

  if [[ $EUID -eq 0 ]]; then
    SUDO=""
  else
    command -v sudo >/dev/null 2>&1 || fail "not root and sudo not found"
    SUDO="sudo"
    if ! $SUDO -n true 2>/dev/null; then
      # The fallback reads its password from /dev/tty, so redirecting stdin
      # does not disarm it. Only reach it when there is a human present.
      [[ $INTERACTIVE -eq 1 ]] ||
        fail "sudo needs a password and this is a non-interactive run. Re-run as root, or configure NOPASSWD, or run with a terminal attached."
      $SUDO true || fail "sudo escalation failed -- re-run as root"
    fi
  fi

  # Deck hardware gate. Same reasoning as omarchy-deck-kernel.sh: only OLED
  # (Galileo) is verified hardware, but refusing to run on an LCD (Jupiter)
  # is worse than running untested, and nothing downstream claims LCD support.
  local product="" vendor=""
  [[ -r /sys/class/dmi/id/product_name ]] && product=$(</sys/class/dmi/id/product_name)
  [[ -r /sys/class/dmi/id/sys_vendor ]]   && vendor=$(</sys/class/dmi/id/sys_vendor)
  if ! [[ ${product,,} =~ (steam\ deck|jupiter|galileo) || ${vendor,,} == *valve* ]]; then
    fail "not Steam Deck hardware (product='${product:-?}' vendor='${vendor:-?}'). Refusing to rewrite session configuration."
  fi
  log "hardware: ${vendor:-unknown} ${product:-unknown}"

  # SDDM is the switching mechanism. Without it there is nothing to restart.
  systemctl list-unit-files sddm.service --no-pager 2>/dev/null | grep -q sddm ||
    fail "sddm.service not found. This script switches sessions by restarting the display manager and supports SDDM only (which is what Omarchy installs)."

  # The Gaming Mode session must already exist -- we do not build one.
  # Checked by *file*, not by package, so a differently-packaged gamescope
  # still satisfies it.
  local found="" d
  for d in /usr/share/wayland-sessions /usr/local/share/wayland-sessions; do
    [[ -f "$d/${GAMING_SESSION}.desktop" ]] && { found="$d/${GAMING_SESSION}.desktop"; break; }
  done
  [[ -n $found ]] ||
    fail "no ${GAMING_SESSION}.desktop in any wayland-sessions directory. Install gamescope from jupiter-staging (it ships the whole SteamOS session), then re-run."
  log "gaming session: ${found}"

  # The launcher the session entry points at has to exist too -- a dangling
  # Exec= is exactly the silent failure this project exists to prevent.
  command -v start-gamescope-session >/dev/null 2>&1 ||
    fail "${found} exists but start-gamescope-session is not on PATH -- the gamescope install is incomplete. Do not switch sessions until this resolves."

  # Resolve the desktop session by discovery. Omarchy ships its own entry in
  # /usr/local/share, which is why this is not hardcoded.
  local cand
  for d in /usr/local/share/wayland-sessions /usr/share/wayland-sessions; do
    for cand in omarchy hyprland-uwsm hyprland; do
      if [[ -f "$d/${cand}.desktop" ]]; then DESKTOP_SESSION=$cand; break 2; fi
    done
  done
  [[ -n $DESKTOP_SESSION ]] ||
    fail "found no desktop session (.desktop for omarchy/hyprland-uwsm/hyprland) in any wayland-sessions directory"
  log "desktop session: ${DESKTOP_SESSION}"

  # DeckShift is deliberately not supported alongside this. Both install a
  # steamos-session-select and both write an SDDM drop-in; whichever ran last
  # wins, which is not a state anyone can reason about. Warn rather than fail
  # so this stage stays a pure probe.
  if [[ -e /usr/local/bin/switch-to-gaming || -e /usr/local/bin/gaming-session-switch ]]; then
    warn "DeckShift appears to be installed (/usr/local/bin/switch-to-gaming). This project ships its own session layer and does not use it -- see PROGRESS.md 2.4. Remove DeckShift before relying on these stages, or the two will fight over SDDM's session and Steam's hook."
  fi

  # mangoapp is only Wants= in the unit graph, so its absence is not fatal --
  # but the session exports STEAM_USE_MANGOAPP=1, so the performance overlay
  # would be silently dead. Warn, do not fail.
  command -v mangoapp >/dev/null 2>&1 ||
    warn "mangoapp not found (install mangohud) -- Gaming Mode's performance overlay will not work, though the session will still start"

  log "stage-preconditions: ok"
}

# ---------------------------------------------------------------------------

# Refuse to overwrite a file this script did not write.
#
# If a package ever lands one of these paths for real -- SteamOS's own
# customizations, or a future jupiter-* package -- its version is the
# authoritative one and quietly replacing it with ours would be the wrong
# outcome, in a place nobody would think to look. Fail loudly instead and let
# a human decide.
assert_ours_or_absent() {
  local path=$1 whose=$2
  # Matched on the bare text, so a file using any comment prefix is recognised.
  if $SUDO test -e "$path" && ! $SUDO grep -qF -- "$INSTALL_MARKER_TEXT" "$path" 2>/dev/null; then
    fail "${path} exists but was not written by ${PROG}.sh -- ${whose} owns it. Inspect it rather than overwriting it."
  fi
}

# Prove the NOPASSWD grant actually works.
#
# BUG FIX: the previous version probed with a warm sudo credential cache, so
# it passed whether or not the sudoers rule had parsed -- a check that only
# passes because of ambient state is worse than no check. Clear the cache
# first, and be honest about the case where the answer is unprovable.
verify_nopasswd() {
  local bin=$1 user=$2
  [[ $EUID -ne 0 ]] || return 0   # already root; nothing to prove

  # -K removes the cached timestamp entirely, so the probe below cannot
  # succeed on a credential someone else established.
  sudo -K 2>/dev/null || true

  # `sudo -n -l <cmd>` asks "may I run this without a password" WITHOUT
  # running it -- safer than invoking the target just to read its error text.
  if ! sudo -n -l "$bin" >/dev/null 2>&1; then
    fail "installed ${SUDOERS_FILE} but '${bin}' is still not invokable passwordless. Inspect that file; sudo would not confirm the grant."
  fi

  # Honesty check. If this user already has blanket NOPASSWD, the probe above
  # would have passed no matter what we wrote, so it proves nothing about our
  # drop-in. Say that rather than claiming a verified grant.
  if sudo -n -l /usr/bin/true >/dev/null 2>&1; then
    warn "this user already has broad passwordless sudo, so the check above does NOT prove ${SUDOERS_FILE} is what granted access. The grant is installed but unverified."
  else
    log "verified: ${user} can invoke it without a password, via ${SUDOERS_FILE}"
  fi

  # Re-establish credentials the probe just cleared, so later stages in the
  # same run do not hit an unexpected prompt.
  if [[ $INTERACTIVE -eq 1 ]]; then
    sudo -v 2>/dev/null || true
  fi
}

stage_session_select() {
  log "installing ${SELECT_BIN}"

  # Resolved here, not at switch time, and baked into the generated shim.
  # SDDM's [Autologin] needs BOTH User= and Session=; with Session= alone it
  # ignores the block entirely and shows the greeter (found on hardware,
  # P1.5 phase F -- docs/findings/P15-live-iso-recon.md R-16). Deriving the
  # user inside the shim from $SUDO_USER would write User=root whenever the
  # shim is reached from a root context, i.e. a root graphical autologin.
  # The autologin user is a property of the machine, so decide it at install.
  local invoking_user=${SUDO_USER:-${USER:-$(id -un)}}
  [[ -n $invoking_user && $invoking_user != root ]] ||
    fail "cannot determine the unprivileged user to autologin (got '${invoking_user}'). Re-run as that user with sudo, not as root directly."

  local tmp
  tmp=$(mktemp) || fail "mktemp failed"

  cat >"$tmp" <<EOF
#!/usr/bin/env bash
# deck-session-select -- switch the Deck between Gaming Mode and the desktop.
# Installed by ${PROG}.sh. Runs as root (see the sudoers drop-in).
#
# Usage: deck-session-select {gamescope|desktop} [--no-restart]
set -euo pipefail

GAMING_SESSION=${GAMING_SESSION}
DESKTOP_SESSION=${DESKTOP_SESSION}
SDDM_DROPIN=${SDDM_DROPIN}
STATE_FILE=${STATE_FILE}

die() { printf 'deck-session-select: %s\n' "\$*" >&2; exit 1; }

[[ \$EUID -eq 0 ]] || die "must run as root (invoke via sudo)"

restart=1
target=""
while [[ \$# -gt 0 ]]; do
  case \$1 in
    gamescope|gaming|gamescope-wayland) target=\$GAMING_SESSION ;;
    desktop|plasma|omarchy)             target=\$DESKTOP_SESSION ;;
    --no-restart)                       restart=0 ;;
    *) die "unknown argument '\$1' (expected: gamescope | desktop [--no-restart])" ;;
  esac
  shift
done
[[ -n \$target ]] || die "no session specified (expected: gamescope | desktop)"

# Verify the target session actually exists before committing to it. Writing
# a Session= that SDDM cannot resolve produces a login loop with no desktop
# and, under autologin, no session picker to escape with.
found=""
for d in /usr/local/share/wayland-sessions /usr/share/wayland-sessions; do
  [[ -f "\$d/\${target}.desktop" ]] && { found="\$d/\${target}.desktop"; break; }
done
[[ -n \$found ]] || die "target session '\${target}' has no .desktop in any wayland-sessions directory -- refusing to write a config that cannot log in"

install -d -m 0755 "\$(dirname "\$STATE_FILE")"
printf '%s\n' "\$target" >"\$STATE_FILE"

# Autologin Session= is the switch. The drop-in is named to sort LAST in
# /etc/sddm.conf.d, so it wins over any other autologin config without
# editing a file we do not own. See the SDDM_DROPIN comment in ${PROG}.sh --
# an earlier name sorted *before* autologin.conf and silently never applied.
#
# User= is required, not optional: SDDM applies [Autologin] only when BOTH
# User= and Session= are present. An earlier version wrote Session= alone on
# the assumption that Omarchy supplied User= from its own autologin.conf --
# Omarchy 4.0 ships no such file, so autologin never fired and every switch
# landed on the greeter instead (P1.5 phase F, R-16).
install -d -m 0755 "\$(dirname "\$SDDM_DROPIN")"
cat >"\$SDDM_DROPIN" <<INNER
# Written by deck-session-select. Do not edit by hand -- rewritten on every
# session switch. Named to sort last in /etc/sddm.conf.d so Session= wins.
[Autologin]
User=${invoking_user}
Session=\${target}
INNER

# Verify the write landed rather than trusting the redirect. Both keys are
# checked: Session= alone is the exact silent failure this stage exists to
# avoid, so a drop-in missing User= must be treated as a failed write.
grep -q "^Session=\${target}\$" "\$SDDM_DROPIN" ||
  die "wrote \$SDDM_DROPIN but Session=\${target} is not there on re-read"
grep -q "^User=${invoking_user}\$" "\$SDDM_DROPIN" ||
  die "wrote \$SDDM_DROPIN but User=${invoking_user} is not there on re-read -- SDDM ignores [Autologin] without it"

printf 'deck-session-select: next session is %s (%s)\n' "\$target" "\$found"

if [[ \$restart -eq 1 ]]; then
  printf 'deck-session-select: restarting sddm\n'
  # Restart, not stop+start: a single atomic transaction avoids the window
  # where no display manager is running.
  systemctl restart sddm
fi
EOF

  $SUDO install -m 0755 -o root -g root "$tmp" "$SELECT_BIN" ||
    fail "could not install ${SELECT_BIN}"
  rm -f "$tmp"
  $SUDO test -x "$SELECT_BIN" || fail "${SELECT_BIN} is not executable after install"

  # --- sudoers drop-in, validated before installation ---
  # invoking_user is resolved and guarded at the top of this stage, where the
  # autologin drop-in needs it too.
  log "granting ${invoking_user} NOPASSWD on ${SELECT_BIN} only"
  tmp=$(mktemp) || fail "mktemp failed"
  cat >"$tmp" <<EOF
# Installed by ${PROG}.sh. Lets the desktop user switch between Gaming Mode
# and the desktop, which requires restarting the display manager.
#
# Scoped to exactly one root-owned 0755 binary and nothing else. See the
# SECURITY TRADEOFF note in ${PROG}.sh before widening this.
${invoking_user} ALL=(root) NOPASSWD: ${SELECT_BIN}
EOF

  # A malformed sudoers file breaks sudo for everyone. Never install one
  # unvalidated -- check the candidate file itself, before it is in place.
  $SUDO visudo -c -f "$tmp" >/dev/null ||
    fail "generated sudoers snippet failed validation -- refusing to install it. Candidate left at ${tmp}"

  $SUDO install -m 0440 -o root -g root "$tmp" "$SUDOERS_FILE" ||
    fail "could not install ${SUDOERS_FILE}"
  rm -f "$tmp"

  verify_nopasswd "$SELECT_BIN" "$invoking_user"

  log "stage-session-select: ok"
}

# ---------------------------------------------------------------------------

stage_steam_hook() {
  # Steam's Power -> Switch to Desktop runs `steamos-session-select desktop`.
  # Providing it under that exact name is what makes Steam's own affordance
  # work, which matters because it is the controller-reachable one.
  #
  assert_ours_or_absent "$STEAM_SHIM" "something else (DeckShift? SteamOS's steamos-customizations?)"

  # Steam invokes this unprivileged, so the shim escalates on its own via the
  # narrowly-scoped sudoers grant from stage-session-select. A plain symlink
  # would not work: sudo has to be in the call path.
  log "installing Steam's Switch-to-Desktop hook: ${STEAM_SHIM}"
  local wrapper
  wrapper=$(mktemp) || fail "mktemp failed"
  cat >"$wrapper" <<EOF
#!/usr/bin/env bash
# steamos-session-select -- compatibility shim so Steam's "Switch to Desktop"
# works. Steam calls this unprivileged; the real work needs root.
${INSTALL_MARKER}
set -euo pipefail
exec sudo -n ${SELECT_BIN} "\$@"
EOF
  $SUDO install -m 0755 -o root -g root "$wrapper" "$STEAM_SHIM" ||
    fail "could not install ${STEAM_SHIM}"
  rm -f "$wrapper"

  # MIGRATION. The shim used to live in /usr/local/bin, where Steam cannot see
  # it. Remove our old copy so exactly one exists and nobody debugging this
  # later has to work out which is live.
  if $SUDO test -e "$STEAM_SHIM_LEGACY"; then
    if $SUDO grep -qF -- "$INSTALL_MARKER_TEXT" "$STEAM_SHIM_LEGACY" 2>/dev/null; then
      log "removing our old, Steam-unreachable copy: ${STEAM_SHIM_LEGACY}"
      $SUDO rm -f "$STEAM_SHIM_LEGACY" ||
        fail "could not remove ${STEAM_SHIM_LEGACY}"
    else
      warn "${STEAM_SHIM_LEGACY} exists and is not ours, so it is left alone. Be aware Steam cannot reach /usr/local/bin at all (its runtime PATH is ${STEAM_RUNTIME_PATH}), so whichever tool installed that file is probably broken in the same way this project was."
    fi
  fi

  # Verify Steam could FIND it, which is a different question from whether it
  # exists. Resolved against Steam's own PATH with a scrubbed environment, so a
  # /usr/local/bin on the operator's interactive PATH cannot make this pass.
  local resolved
  resolved=$(env -i PATH="$STEAM_RUNTIME_PATH" sh -c 'command -v steamos-session-select' 2>/dev/null) || resolved=""
  [[ -n $resolved ]] ||
    fail "installed ${STEAM_SHIM} but 'steamos-session-select' does not resolve on Steam's runtime PATH (${STEAM_RUNTIME_PATH}). Steam's Switch to Desktop would silently do nothing."
  log "verified: Steam can resolve it on PATH=${STEAM_RUNTIME_PATH} -> ${resolved}"

  log "stage-steam-hook: ok"
}

# ---------------------------------------------------------------------------

stage_update_stub() {
  # Steam's first run in Gaming Mode reports "unable to download the required
  # updates -- please check your network connection (2)". The network is fine;
  # the error is a lie. What actually happens, from Steam's own logs:
  #
  #   YieldingCheckForUpdateOS: Command '... /usr/bin/steamos-polkit-helpers/steamos-update check ...' returned: 127
  #   YieldingApplyUpdateOS: applying OS update
  #   steamos-update returned: 127
  #   YieldingApplyUpdateOS: OS update result: 2
  #
  # 127 is "command not found": the whole ${POLKIT_HELPER_DIR} tree is absent,
  # because it belongs to SteamOS and this device is Arch + Omarchy. Steam
  # renders that as a network error and, during OOBE, will not proceed past it.
  #
  # No configured repo provides this binary. jupiter-hw-support ships six other
  # helpers but not this one, and steamos-customizations-jupiter ships none at
  # all (it is GRUB machinery, which the Limine-only constraint forbids anyway).
  # So there is nothing to install and the choice is between a stub and leaving
  # a false error on the first screen a user ever sees. Operator chose the stub
  # -- see PROGRESS.md 5.14.
  #
  # It is deliberately NOT a step toward a real updater. This device genuinely
  # cannot self-update the way SteamOS does (no RAUC, no A/B rootfs), and the
  # stub says so in its header, in --help, and in the journal.
  assert_ours_or_absent "$UPDATE_STUB" "a real SteamOS updater"

  log "installing the steamos-update stub: ${UPDATE_STUB}"
  $SUDO install -d -m 0755 -o root -g root "$POLKIT_HELPER_DIR" ||
    fail "could not create ${POLKIT_HELPER_DIR}"

  local tmp
  tmp=$(mktemp) || fail "mktemp failed"
  cat >"$tmp" <<EOF
#!/usr/bin/env bash
#
# steamos-update -- A STUB. IT UPDATES NOTHING.
${INSTALL_MARKER}
#
# WHY THIS EXISTS
#   Steam's Gaming Mode checks for OS updates by running this exact absolute
#   path. On SteamOS it is a real updater backed by RAUC and an A/B rootfs.
#   This device is not SteamOS -- it is Arch + Omarchy, updated with pacman --
#   so the path was missing, Steam got exit 127, and it told the user "unable
#   to download the required updates: check your network connection". That
#   message is alarming and false, and during first-run setup Steam will not
#   move past it.
#
# WHAT IT DOES
#   Answers "already up to date" and exits. It does not download, stage,
#   verify or apply anything, and it is not a partial implementation of
#   something that will.
#
# TO ACTUALLY UPDATE THIS SYSTEM
#   ${REAL_UPDATE_HINT}   (from Desktop Mode)
#
set -euo pipefail

# An unrecognised verb must not be answered silently -- this project exists
# partly because upstream tooling reported success while doing nothing. Steam
# discards our stderr, so the journal is the only place a human can find it.
note() {
  printf 'steamos-update (stub): %s\n' "\$1" >&2
  command -v logger >/dev/null 2>&1 && logger -t steamos-update-stub -- "\$1"
  return 0
}

case \${1-} in
  check)
    # 7 is SteamOS's "already up to date". Exit 0 would tell Steam an update
    # IS available, and it would immediately call us again to apply it --
    # ending in the same failure dialog by a longer route.
    exit 7
    ;;
  --supports-duplicate-detection)
    # A capability probe. We download nothing, so we cannot detect a duplicate
    # download; claiming the capability would invite Steam to depend on
    # behaviour that does not exist. Non-zero means "not supported", which is
    # what Steam already observed while this path was missing, so this keeps
    # it on the code path it has been using all along.
    exit 1
    ;;
  ""|apply)
    # The apply path -- 7 here too, and emphatically NOT 0.
    #
    # Exit 0 means "an update was applied", and Steam responds by REBOOTING to
    # finish it. Measured on hardware, not guessed:
    #
    #   YieldingApplyUpdateOS: applying OS update
    #   steamos-update returned: 0
    #   YieldingApplyUpdateOS: OS update result: 1
    #
    # followed straight away by systemd-reboot. During first-run setup Steam
    # calls apply DIRECTLY without checking first, so exit 0 rebooted the Deck
    # on every OOBE pass: a boot loop, caused by the stub meant to quiet a
    # cosmetic error. 7 says "nothing to apply", which leaves Steam with
    # nothing to finish and no reason to reboot.
    note "nothing to apply; this OS is updated with '${REAL_UPDATE_HINT}'"
    exit 7
    ;;
  -h|--help|help)
    cat <<'USAGE'
steamos-update (STUB) -- reports "up to date" and does nothing else.

This is NOT the real SteamOS updater. It exists so Steam's Gaming Mode stops
reporting a network error for a missing SteamOS binary. This device is Arch +
Omarchy; its OS does not update the way SteamOS's does.

  check                            exit 7 (already up to date)
  --supports-duplicate-detection   exit 1 (not supported)
  (no argument) | apply            exit 7 (nothing to apply). NOT 0 -- Steam
                                   reads 0 as "applied" and reboots.

To really update this system, from Desktop Mode:  ${REAL_UPDATE_HINT}
USAGE
    exit 0
    ;;
  *)
    # Answer as "up to date" rather than erroring: an unanticipated verb from
    # a future Steam client should not resurrect the first-run dialog. The
    # journal line above is how this stops being silent.
    note "unrecognised argument '\$1' -- answering 'up to date'. If Steam now depends on this verb, the stub needs extending."
    exit 7
    ;;
esac
EOF
  $SUDO install -m 0755 -o root -g root "$tmp" "$UPDATE_STUB" ||
    fail "could not install ${UPDATE_STUB}"
  rm -f "$tmp"

  # Verify by running it, not by trusting the write. `check` answering 7 is the
  # single behaviour Steam's first-run flow depends on.
  local rc=0
  "$UPDATE_STUB" check >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 7 ]] ||
    fail "${UPDATE_STUB} installed but 'check' exited ${rc}, not 7. Steam reads 7 as 'up to date'; anything else puts the first-run update dialog back."

  rc=0
  "$UPDATE_STUB" --supports-duplicate-detection >/dev/null 2>&1 || rc=$?
  [[ $rc -ne 0 ]] ||
    fail "${UPDATE_STUB} claims duplicate-detection support (exit 0). It does not implement it; that would make Steam depend on behaviour that is not there."

  # The apply path must NOT exit 0. This assertion is the whole reason it is
  # here: an earlier version of this stub exited 0, Steam read that as "update
  # applied", and rebooted the Deck to finish it -- once per OOBE pass.
  rc=0
  "$UPDATE_STUB" >/dev/null 2>&1 || rc=$?
  [[ $rc -ne 0 ]] ||
    fail "${UPDATE_STUB} exits 0 on the apply path. Steam reads 0 as 'an OS update was applied' and REBOOTS the device to complete it, on every first-run pass. It must report 'nothing to apply' (7) instead."

  log "verified: 'check' exits 7 (up to date), capability probe declines,"
  log "          apply exits ${rc} (non-zero, so Steam will not reboot)"
  log "stage-update-stub: ok"
  log "NOTE: this stub updates nothing. Real updates: ${REAL_UPDATE_HINT}"
}

# ---------------------------------------------------------------------------

stage_greeter_rotation() {
  # The SDDM greeter is one of the three surfaces that render sideways. It is
  # fixed the same way the desktop is -- a compositor transform -- because the
  # greeter IS a Hyprland instance: Omarchy drives it with
  #
  #   CompositorCommand=start-hyprland -- --config /usr/share/sddm/hyprland.lua
  #
  # so the greeter reads a Hyprland Lua config and hl.monitor() applies there
  # exactly as it does in the user's session.
  #
  # NOT fixed here, and not fixable this way:
  #   - the Limine boot menu, which renders before any compositor exists. It is
  #     the first thing a user sees and still has no known fix (R-19).
  #   - the console/TTY, which needs fbcon=rotate:1 on the kernel cmdline. That
  #     touches the boot chain and is held for separate operator approval.
  [[ -f $UPSTREAM_GREETER_LUA ]] ||
    fail "${UPSTREAM_GREETER_LUA} not found -- Omarchy's greeter config has moved, so mirroring it here would be guesswork. Re-check CompositorCommand in /etc/sddm.conf.d/ before continuing."

  # Drift check. Ours is a copy, so upstream changing its greeter settings is
  # something a human has to notice; a silent divergence would show up months
  # later as a greeter that lost a setting nobody remembers.
  local actual
  actual=$(sha256sum "$UPSTREAM_GREETER_LUA" | awk '{print $1}')
  if [[ $actual != "$UPSTREAM_GREETER_SHA256" ]]; then
    warn "${UPSTREAM_GREETER_LUA} has changed since ${GREETER_LUA} was mirrored from it (expected ${UPSTREAM_GREETER_SHA256:0:12}…, got ${actual:0:12}…). Diff the two and re-mirror, then update UPSTREAM_GREETER_SHA256. Proceeding: the transform below is still correct, but any NEW upstream greeter setting is not being carried over."
  fi

  log "installing the greeter compositor config: ${GREETER_LUA}"
  $SUDO install -d -m 0755 -o root -g root "$(dirname "$GREETER_LUA")" ||
    fail "could not create $(dirname "$GREETER_LUA")"

  local tmp
  tmp=$(mktemp) || fail "mktemp failed"
  cat >"$tmp" <<EOF
-- Hyprland config for the SDDM Wayland greeter on a Steam Deck.
${INSTALL_MARKER_LUA}
--
-- A MIRROR of ${UPSTREAM_GREETER_LUA} (Omarchy's own greeter config, package
-- owned by omarchy-settings-dev) plus the panel transform. Editing upstream's
-- file directly would be reverted by the next package upgrade, so SDDM is
-- repointed here instead -- see ${SDDM_GREETER_DROPIN}.
--
-- If upstream's greeter config gains a setting, it must be copied down here by
-- hand. stage-greeter-rotation warns when its hash changes.
hl.config({
  misc = {
    disable_hyprland_logo = true,
    disable_splash_rendering = true,
    force_default_wallpaper = 0,
  },

  animations = {
    enabled = false,
  },
})

-- The whole reason this file exists. transform = ${PANEL_TRANSFORM} (270 deg), confirmed by
-- looking at the hardware; ${PANEL_OUTPUT} scans out portrait and is mounted rotated.
-- transform = 1 renders upside down.
hl.monitor({ output = "${PANEL_OUTPUT}", mode = "preferred", position = "auto", scale = ${PANEL_SCALE}, transform = ${PANEL_TRANSFORM} })
EOF
  # Prove it PARSES before installing it. Hyprland does not fail loudly on a
  # broken Lua config: it discards the file, falls back to built-in defaults,
  # and logs nothing beyond "loading lua mgr". The greeter then comes up
  # rotated and unstyled, looking like the transform simply did not work. This
  # check exists because that is exactly what happened -- a '#' comment on
  # line 2, legal in shell, a syntax error in Lua.
  if command -v luac >/dev/null 2>&1; then
    local luaerr
    if ! luaerr=$(luac -p "$tmp" 2>&1); then
      rm -f "$tmp"
      fail "the greeter config this stage generates is not valid Lua: ${luaerr}. Refusing to install it -- Hyprland would silently ignore it and the greeter would render rotated with no error anywhere."
    fi
    log "verified: generated greeter config is valid Lua"
  else
    warn "luac not found, so the generated greeter config was NOT syntax-checked. A Lua syntax error here is silent: Hyprland discards the config and falls back to defaults. Install the 'lua' package to enable this check."
  fi

  $SUDO install -m 0644 -o root -g root "$tmp" "$GREETER_LUA" ||
    fail "could not install ${GREETER_LUA}"
  rm -f "$tmp"

  log "pointing SDDM's greeter compositor at it: ${SDDM_GREETER_DROPIN}"
  tmp=$(mktemp) || fail "mktemp failed"
  cat >"$tmp" <<EOF
# Written by ${PROG}.sh. Repoints SDDM's Wayland greeter compositor at a config
# that rotates the Deck's panel (PROGRESS.md 5.11).
${INSTALL_MARKER}
#
# Named 'zy-' so it sorts AFTER Omarchy's 10-wayland.conf and wins the
# CompositorCommand key, and so it stays clear of 'zz-deck-session.conf', which
# deck-session-select rewrites on every session switch.
[General]
DisplayServer=wayland

[Wayland]
CompositorCommand=start-hyprland -- --config ${GREETER_LUA}
EOF
  $SUDO install -m 0644 -o root -g root "$tmp" "$SDDM_GREETER_DROPIN" ||
    fail "could not install ${SDDM_GREETER_DROPIN}"
  rm -f "$tmp"

  # Verify the override actually wins. SDDM takes the LAST value for a key
  # across /etc/sddm.conf.d/*.conf in lexical order, so asserting our file
  # exists proves nothing about which value the greeter will use.
  local winner
  winner=$(cat /etc/sddm.conf.d/*.conf 2>/dev/null | grep '^CompositorCommand=' | tail -1)
  [[ $winner == "CompositorCommand=start-hyprland -- --config ${GREETER_LUA}" ]] ||
    fail "installed ${SDDM_GREETER_DROPIN} but the last CompositorCommand across /etc/sddm.conf.d is '${winner}'. Something sorts after 'zy-' and overrides it; the greeter would still render rotated."
  log "verified: ours is the winning CompositorCommand"

  log "stage-greeter-rotation: ok"
  log "NOTE: autologin means the greeter is normally skipped, so this is not"
  log "      exercised on a normal boot. To see it, disable the [Autologin]"
  log "      section and restart sddm."
}

# ---------------------------------------------------------------------------

stage_sddm_resilience() {
  # Observed on hardware, switching Gaming Mode -> Desktop through Steam's own
  # menu item: the switch left the Deck with NO graphical session at all, and
  # recovering needed `systemctl reset-failed sddm` over SSH -- which is exactly
  # what a controller-only user does not have.
  #
  # The mechanism, from sddm's shipped unit:
  #
  #   StartLimitIntervalSec=30    StartLimitBurst=2    RestartSec=100ms
  #
  # Switching restarts SDDM while gamescope still holds VT1. SDDM's first
  # display attempt raced that teardown and died with HELPER_TTY_ERROR; systemd
  # retried 100ms later, far too soon for the VT to have settled, so that failed
  # too; two failures inside 30s exhausted the burst and the unit latched to
  # `failed` permanently. A transient, self-healing condition was converted into
  # a black screen by a rate limit.
  #
  # RestartSec is the more important half: at 100ms the retry is guaranteed to
  # land before the VT is free, so the limit gets spent on attempts that could
  # never have worked.
  #
  # TRADEOFF, deliberate: disabling the rate limit means a genuinely broken SDDM
  # config retries forever instead of stopping. On a device with no keyboard,
  # a loop that can still recover beats a black screen that cannot -- and a
  # permanently broken config is a dev-time failure, which the journal shows
  # either way.
  log "installing SDDM restart resilience: ${SDDM_UNIT_DROPIN}"
  $SUDO install -d -m 0755 -o root -g root "$(dirname "$SDDM_UNIT_DROPIN")" ||
    fail "could not create $(dirname "$SDDM_UNIT_DROPIN")"

  local tmp
  tmp=$(mktemp) || fail "mktemp failed"
  cat >"$tmp" <<EOF
# Written by ${PROG}.sh -- see stage-sddm-resilience.
${INSTALL_MARKER}
#
# Session switching restarts SDDM while the outgoing compositor still holds
# VT1. Upstream's StartLimitIntervalSec=30 / StartLimitBurst=2 / RestartSec=100ms
# turns that transient race into a PERMANENT failure: the Deck ends up with no
# graphical session and needs 'systemctl reset-failed sddm' from a shell.
[Unit]
# 0 disables rate limiting. See the tradeoff note in stage-sddm-resilience.
StartLimitIntervalSec=0

[Service]
# Give the outgoing session time to release the VT before retrying. 100ms did
# not, and every retry inside that window is wasted.
RestartSec=3
EOF
  $SUDO install -m 0644 -o root -g root "$tmp" "$SDDM_UNIT_DROPIN" ||
    fail "could not install ${SDDM_UNIT_DROPIN}"
  rm -f "$tmp"

  $SUDO systemctl daemon-reload || fail "systemctl daemon-reload failed"

  # Verify the values systemd ACTUALLY resolved. A drop-in in the right place
  # with a typo'd directive is silently ignored, so reading the file back would
  # prove nothing.
  local limit restart_usec
  limit=$(systemctl show sddm -p StartLimitIntervalUSec --value 2>/dev/null)
  restart_usec=$(systemctl show sddm -p RestartUSec --value 2>/dev/null)
  [[ $limit == "0" || $limit == "infinity" ]] ||
    fail "installed ${SDDM_UNIT_DROPIN} but systemd still reports StartLimitIntervalUSec=${limit}. The drop-in was not applied; a failed switch would still leave the Deck with no session."
  [[ $restart_usec == "3s" ]] ||
    warn "RestartSec resolved to '${restart_usec}', not 3s. The rate limit is lifted so a switch can still recover, but retries may again land before the VT is free."

  log "verified: StartLimitIntervalUSec=${limit}, RestartUSec=${restart_usec}"
  log "stage-sddm-resilience: ok"
}

# ---------------------------------------------------------------------------

stage_return_icon() {
  # A .desktop entry is the shell-agnostic half of "return to Gaming Mode":
  # every launcher on every shell reads /usr/share/applications, so this works
  # identically on Omarchy 3.x (waybar-era) and on 4.0's Quickshell rewrite.
  #
  # PINNING it to a bar/dock IS shell-specific and is deliberately NOT done
  # here -- see TASK-T3 step 6.
  log "installing ${RETURN_DESKTOP_FILE}"
  local tmp
  tmp=$(mktemp) || fail "mktemp failed"
  cat >"$tmp" <<EOF
[Desktop Entry]
Type=Application
Name=Return to Gaming Mode
Comment=Switch back to the Steam Big Picture session
Exec=${STEAM_SHIM} gamescope
Icon=steamicon
Terminal=false
Categories=Game;
Keywords=steam;gaming;gamescope;deck;
EOF
  $SUDO install -m 0644 -o root -g root "$tmp" "$RETURN_DESKTOP_FILE" ||
    fail "could not install ${RETURN_DESKTOP_FILE}"
  rm -f "$tmp"
  log "stage-return-icon: ok"
  log "NOTE: pinning this to a bar/dock is shell-specific and is not done here"
}

# ---------------------------------------------------------------------------

stage_default_session() {
  # Deliberately NOT in INSTALL_STAGES. Flipping the default is the one
  # irreversible-feeling step: autologin is enabled, so SDDM shows no session
  # picker, and a Gaming Mode that fails to start leaves no graphical way
  # back. Run it explicitly, only after both directions are proven to work.
  log "setting the default session to Gaming Mode (${GAMING_SESSION})"
  $SUDO "$SELECT_BIN" gamescope --no-restart ||
    fail "could not set the default session"
  log "default session set. It takes effect on the next login or reboot."
  log "To undo: sudo ${SELECT_BIN} desktop --no-restart"
  log "If Gaming Mode fails to start, Ctrl+Alt+F2 reaches a TTY."
}

# ---------------------------------------------------------------------------

run_stage() {
  local stage=$1
  local fn=${stage//-/_}
  declare -F "$fn" >/dev/null || usage_error "unknown stage '${stage}'"
  # Every stage needs the probes; they install nothing and write nothing.
  [[ $stage == stage-preconditions ]] || stage_preconditions
  "$fn"
}

main() {
  case ${1:-} in
    "")
      stage_preconditions
      local s
      for s in "${INSTALL_STAGES[@]:1}"; do "${s//-/_}"; done
      log "done. Both switch directions are installed but NOT yet the default."
      log "Test first:  ${STEAM_SHIM} gamescope     (switches now, ends this session)"
      log "Then, once proven: ./${PROG}.sh stage-default-session"
      ;;
    list-stages) printf '%s\n' "${INSTALL_STAGES[@]}" stage-default-session ;;
    -h|--help|help)
      cat <<EOF
${PROG}.sh -- two-way Gaming Mode <-> Desktop session switching for a Deck

  ${PROG}.sh                        install everything except the default flip
  ${PROG}.sh <stage>                run one stage
  ${PROG}.sh list-stages            stage names, for CI
  ${PROG}.sh stage-default-session  make Gaming Mode the default (do this last)

After installing:
  steamos-session-select gamescope  switch to Gaming Mode now
  steamos-session-select desktop    switch to the desktop now

Stages also cover two Gaming Mode / display defects (PROGRESS.md 5.11, 5.14):
  stage-update-stub        a steamos-update stub, so Steam's first run stops
                           reporting a false network error
  stage-greeter-rotation   rotates the SDDM greeter for the Deck's panel.
                           The user's desktop needs a matching transform in
                           ~/.config/hypr/monitors.lua; the Limine menu and
                           the TTY are NOT covered here.

Exit codes: 0 success, 1 stage failure, 2 usage error.
EOF
      ;;
    *) run_stage "$1" ;;
  esac
}

main "$@"

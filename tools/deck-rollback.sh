#!/usr/bin/env bash
# Roll the Deck's root filesystem back to a snapshot taken by
# deck-snapshot.sh. Wraps `snapper rollback`, matching deck-snapshot.sh's
# reasoning (Omarchy's installer already sets up Snapper+Limine sync;
# don't hand-roll it).
#
# `snapper rollback <N>` does not revert the live system in place — it
# creates a *new* default subvolume from snapshot N and needs a reboot to
# take effect. This script does not reboot the Deck on its own: rebooting
# physical hardware is exactly the kind of write CLAUDE.md/START-HERE.md
# say to confirm explicitly, so it prints the required manual step
# instead of running it, unless DECK_ROLLBACK_AUTO_REBOOT=1 is set.
#
# Usage: ./deck-rollback.sh <snapshot-number>
#
# Same env vars as deck-sync.sh (DECK_HOST/DECK_USER/DECK_SSH_PORT), plus:
#   DECK_ROLLBACK_AUTO_REBOOT=1   reboot immediately after rollback
#                                 instead of just printing the instruction
#
# NOT YET RUN AGAINST REAL HARDWARE — see deck-sync.sh's header for why.

set -euo pipefail

SNAPSHOT=${1:?"usage: $0 <snapshot-number>  (see deck-snapshot.sh's output)"}
[[ $SNAPSHOT =~ ^[0-9]+$ ]] || { echo "deck-rollback: '$SNAPSHOT' is not a snapshot number" >&2; exit 2; }

DECK_HOST=${DECK_HOST:-steamdeck}
DECK_USER=${DECK_USER:-deck}
DECK_SSH_PORT=${DECK_SSH_PORT:-22}
SSH_TARGET="${DECK_USER}@${DECK_HOST}"
ssh_() { ssh -p "$DECK_SSH_PORT" -o BatchMode=yes -o ConnectTimeout=10 "$SSH_TARGET" "$@"; }

log() { printf '[deck-rollback] %s\n' "$*" >&2; }

log "rolling back to snapshot #$SNAPSHOT"
ssh_ "sudo snapper -c root rollback $SNAPSHOT" ||
  { log "rollback failed — does snapshot #$SNAPSHOT exist? (sudo snapper -c root list)"; exit 1; }

if [[ ${DECK_ROLLBACK_AUTO_REBOOT:-} == 1 ]]; then
  log "DECK_ROLLBACK_AUTO_REBOOT=1: rebooting now"
  ssh_ "sudo reboot" || true
else
  log "rollback staged. It takes effect on next boot — reboot the Deck to complete it"
  log "(set DECK_ROLLBACK_AUTO_REBOOT=1 to have this script reboot it for you)"
fi

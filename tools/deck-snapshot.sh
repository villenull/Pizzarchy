#!/usr/bin/env bash
# Snapshot the Deck's root filesystem before a risky experiment, so a
# corrupted system is a ~1 minute `deck-rollback.sh` away instead of a
# full reinstall (PLAN.md §9.4).
#
# Wraps Snapper rather than hand-rolling raw btrfs subvolume management:
# Omarchy's own installer already sets up a "root" Snapper config
# (confirmed by reading omarchy-iso's orchestrator/phases_impl.py,
# session 1 research — it hard-fails the install if
# /etc/snapper/configs/root is missing) with Limine-sync integration
# (limine-snapper-sync keeps boot entries in sync with snapshots), so
# PLAN.md §9.4's "may give this to you nearly free" hope is confirmed:
# no need to hand-roll this.
#
# Usage: ./deck-snapshot.sh [description]
# Prints the new snapshot number on success (use it with deck-rollback.sh).
#
# Same env vars as deck-sync.sh (DECK_HOST/DECK_USER/DECK_SSH_PORT).
# NOT YET RUN AGAINST REAL HARDWARE — see deck-sync.sh's header for why.

set -euo pipefail

DESCRIPTION=${1:-"deck-snapshot.sh $(date -u +%Y-%m-%dT%H:%M:%SZ)"}

DECK_HOST=${DECK_HOST:-steamdeck}
DECK_USER=${DECK_USER:-deck}
DECK_SSH_PORT=${DECK_SSH_PORT:-22}
SSH_TARGET="${DECK_USER}@${DECK_HOST}"
ssh_() { ssh -p "$DECK_SSH_PORT" -o BatchMode=yes -o ConnectTimeout=10 "$SSH_TARGET" "$@"; }

log() { printf '[deck-snapshot] %s\n' "$*" >&2; }

number=$(ssh_ "sudo snapper -c root create --type single --print-number --description $(printf '%q' "$DESCRIPTION")") ||
  { log "snapshot creation failed — is the 'root' Snapper config present? (should be, from install)"; exit 1; }

[[ $number =~ ^[0-9]+$ ]] || { log "unexpected output from snapper create: '$number'"; exit 1; }

log "created snapshot #$number: $DESCRIPTION"
echo "$number"

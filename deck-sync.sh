#!/usr/bin/env bash
# Iterate on Deck-side scripts without reinstalling: rsync changed *.sh
# files over SSH, run one named stage remotely, stream back journalctl
# covering that run. Target loop time: ~30s, versus a full reinstall
# (PLAN.md §9.4) — the single biggest win for T3's hardware work.
#
# Usage: ./deck-sync.sh <stage-script-name> [local-source-dir]
#
# Env vars:
#   DECK_HOST        default: steamdeck (add an SSH config alias, or
#                    override with the Deck's actual hostname/IP)
#   DECK_USER        default: deck
#   DECK_SSH_PORT    default: 22
#   DECK_REMOTE_DIR  default: omarchy-deck-sync (relative to $HOME on
#                    the Deck)
#
# NOT YET RUN AGAINST REAL HARDWARE — no Deck reachable from this dev
# environment. Per TASK-T0-test-infrastructure.md §4 ("deck-sync.sh
# written (untested against real hardware is OK here — flag it for the
# operator)"), this is expected for T0 §1's block; verify on first real
# use and fix whatever's wrong rather than trusting this comment.
#
# Idempotency is the *stage script's* responsibility (CLAUDE.md: "every
# install stage independently re-runnable and idempotent") — this wrapper
# doesn't and can't enforce that, it just runs whatever stage you name.

set -euo pipefail

STAGE=${1:?"usage: $0 <stage-script-name> [local-source-dir]"}
SRC_DIR=${2:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}

DECK_HOST=${DECK_HOST:-steamdeck}
DECK_USER=${DECK_USER:-deck}
DECK_SSH_PORT=${DECK_SSH_PORT:-22}
DECK_REMOTE_DIR=${DECK_REMOTE_DIR:-omarchy-deck-sync}

SSH_TARGET="${DECK_USER}@${DECK_HOST}"
ssh_() { ssh -p "$DECK_SSH_PORT" -o BatchMode=yes -o ConnectTimeout=10 "$SSH_TARGET" "$@"; }

log() { printf '[deck-sync] %s\n' "$*" >&2; }

[[ -d $SRC_DIR ]] || { log "source dir not found: $SRC_DIR"; exit 2; }
[[ -f "$SRC_DIR/$STAGE" ]] || { log "stage script not found: $SRC_DIR/$STAGE"; exit 2; }

log "syncing *.sh from $SRC_DIR -> ${SSH_TARGET}:~/${DECK_REMOTE_DIR}/"
rsync -az --delete \
  -e "ssh -p $DECK_SSH_PORT -o BatchMode=yes -o ConnectTimeout=10" \
  --include='*.sh' --include='*/' --exclude='*' \
  "$SRC_DIR"/ "${SSH_TARGET}:${DECK_REMOTE_DIR}/" || {
  log "rsync failed — is sshd enabled on the Deck and DECK_HOST/DECK_USER correct?"
  exit 1
}

log "recording remote timestamp so journalctl only shows this run"
since=$(ssh_ 'date "+%Y-%m-%d %H:%M:%S"') || { log "could not reach $SSH_TARGET over SSH"; exit 1; }

log "running stage '$STAGE' remotely"
status=0
ssh_ "chmod +x '${DECK_REMOTE_DIR}/${STAGE}' && '${DECK_REMOTE_DIR}/${STAGE}'" || status=$?

if [[ $status -eq 0 ]]; then
  log "stage '$STAGE' exited 0"
else
  log "stage '$STAGE' FAILED (exit $status)"
fi

log "journalctl since stage start (--since '$since'):"
ssh_ "journalctl --no-pager --since '$since'" || log "journalctl fetch failed (non-fatal; stage result above is authoritative)"

exit "$status"

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
#   DECK_STAGE_ARGS  default: none — arguments to pass to the stage script
#                    remotely, split on whitespace (so no argument may
#                    itself contain a space). Added for TASK-T1 step 6:
#                    omarchy-deck-kernel.sh now runs one stage at a time
#                    (`./omarchy-deck-kernel.sh list-stages` names them),
#                    and this is how the loop reaches a single one:
#
#                      DECK_STAGE_ARGS=stage-uki \
#                        ./deck-sync.sh omarchy-deck-kernel.sh
#
#                    Kept as an env var rather than a third positional
#                    argument so the existing two-positional interface,
#                    and every existing invocation, are untouched.
#
# HARDWARE-VALIDATED 2026-08-10 (P1.5): drove all ten stages of
# omarchy-deck-kernel.sh and all session stages of deck-session.sh over SSH
# against the real Deck, including the stock→Neptune conversion. The
# `ssh steamdeck` alias in the dev machine's ~/.ssh/config matches the
# DECK_HOST/DECK_USER defaults below, so no env vars are needed there.
# (This block previously claimed the script had never run against hardware;
# that stopped being true in P1.5 — see PROGRESS.md §5.4.)
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
DECK_STAGE_ARGS=${DECK_STAGE_ARGS:-}

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

# Quote each argument for the *remote* shell with printf %q — the same
# technique deck-snapshot.sh already uses to pass a description through ssh.
remote_args=""
if [[ -n $DECK_STAGE_ARGS ]]; then
  for arg in $DECK_STAGE_ARGS; do
    remote_args+=" $(printf '%q' "$arg")"
  done
fi

log "running stage '$STAGE'${remote_args:+ (args:${remote_args})} remotely"
status=0
ssh_ "chmod +x '${DECK_REMOTE_DIR}/${STAGE}' && '${DECK_REMOTE_DIR}/${STAGE}'${remote_args}" || status=$?

if [[ $status -eq 0 ]]; then
  log "stage '$STAGE' exited 0"
else
  log "stage '$STAGE' FAILED (exit $status)"
fi

log "journalctl since stage start (--since '$since'):"
ssh_ "journalctl --no-pager --since '$since'" || log "journalctl fetch failed (non-fatal; stage result above is authoritative)"

exit "$status"

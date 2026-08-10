#!/usr/bin/env bash
# Library: prefer an override copy of an installer script over the ISO's
# own baked-in copy, if one is present.
#
# TASK-T0-test-infrastructure.md §3: most iteration touches scripts, not
# the base image. Once the ISO exists (T5), the common case for testing a
# script change should be "copy a few KB onto the Ventoy data partition's
# override directory, reboot the same ISO" instead of "rebuild and re-copy
# a multi-GB image." This is that logic, written and unit-tested now
# against fixtures, ahead of the ISO it will eventually run inside — the
# ISO's actual mount layout isn't nailed down yet (T5), so the search-path
# list below is deliberately a parameter, not a hardcoded assumption.
#
# Not meant to be run directly — source it.

set -uo pipefail

# Default places to look for an override root, in probe order. A fixed
# glob over /run/media (where udisks/most live distros auto-mount
# removable media, including a Ventoy data partition) plus an explicit
# env var escape hatch for testing and for whatever T5 settles on as the
# ISO's real mount point.
script_loader::default_search_paths() {
  local -a paths=()
  [[ -n ${OMARCHY_DECK_OVERRIDE_ROOT:-} ]] && paths+=("$OMARCHY_DECK_OVERRIDE_ROOT")
  local d
  for d in /run/media/*/omarchy-deck /media/*/omarchy-deck; do
    [[ -d $d ]] && paths+=("$d")
  done
  printf '%s\n' "${paths[@]}"
}

# script_loader::find_override_root [candidate...]
# First existing directory from the candidate list (default:
# script_loader::default_search_paths). Fails (empty stdout, exit 1) if
# none exist — "no override present" is the expected common case, not an
# error, so callers should treat failure here as "use the baked-in copy."
# shellcheck disable=SC2120 # the no-args call (falling back to default_search_paths) is the common case, not a mistake
script_loader::find_override_root() {
  local -a candidates=("$@")
  if [[ ${#candidates[@]} -eq 0 ]]; then
    mapfile -t candidates < <(script_loader::default_search_paths)
  fi
  local c
  for c in "${candidates[@]}"; do
    [[ -n $c && -d $c ]] && { echo "$c"; return 0; }
  done
  return 1
}

# script_loader::resolve <script-name> <baked-in-dir> [override-root]
# Prints the path to actually run/source for <script-name>. Prefers
# <override-root>/<script-name> if it exists AND is a regular, readable
# file (a directory or dangling symlink there is a misconfigured override,
# not a valid one — fall through rather than trying to execute it).
# Fails loudly if the script exists in neither place: PLAN.md §8.1 is
# exactly the failure mode of a missing script being silently skipped.
script_loader::resolve() {
  local name=$1 baked_in_dir=$2 override_root=${3:-}
  if [[ -z $override_root ]]; then
    # shellcheck disable=SC2119 # intentionally no args: fall back to script_loader::default_search_paths
    override_root=$(script_loader::find_override_root) || override_root=""
  fi
  if [[ -n $override_root && -f "$override_root/$name" && -r "$override_root/$name" ]]; then
    echo "$override_root/$name"
    return 0
  fi
  if [[ -f "$baked_in_dir/$name" ]]; then
    echo "$baked_in_dir/$name"
    return 0
  fi
  echo "script_loader::resolve: '$name' not found in override root ('${override_root:-<none>}') or baked-in dir ('$baked_in_dir')" >&2
  return 1
}

#!/usr/bin/env bash
# Unit tests for vm-script-loader.sh, run against hand-built fixture
# directory trees (no ISO, no VM needed).

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

# shellcheck source=../lib/vm-script-loader.sh
source "$REPO_ROOT/test/lib/vm-script-loader.sh"

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

baked=$(mktemp -d "$work/baked.XXXXXX")
override=$(mktemp -d "$work/override.XXXXXX")

echo "baked version" >"$baked/deck-fixup.sh"
echo "override version" >"$override/deck-fixup.sh"

# --- find_override_root -------------------------------------------------

found=$(script_loader::find_override_root "$work/does-not-exist" "$override") ||
  fail "find_override_root finds the second, existing candidate"
[[ $found == "$override" ]] || fail "find_override_root returns the right candidate" "got $found"
pass "find_override_root skips missing candidates and returns the first real one"

if script_loader::find_override_root "$work/nope1" "$work/nope2" 2>/dev/null; then
  fail "find_override_root fails when no candidate exists"
fi
pass "find_override_root fails (not silently) when nothing is present — the common no-override case"

# --- resolve: override present, valid ------------------------------------

resolved=$(script_loader::resolve deck-fixup.sh "$baked" "$override")
[[ $resolved == "$override/deck-fixup.sh" ]] || fail "resolve prefers the override when present" "got $resolved"
[[ $(cat "$resolved") == "override version" ]] || fail "resolved path actually points at the override content"
pass "resolve prefers a present, valid override over the baked-in copy"

# --- resolve: no override root given/found -> falls back to baked-in ---

resolved=$(script_loader::resolve deck-fixup.sh "$baked" "$work/no-such-override")
[[ $resolved == "$baked/deck-fixup.sh" ]] || fail "resolve falls back to baked-in when the override root doesn't exist" "got $resolved"
pass "resolve falls back to the baked-in copy when the override root doesn't exist"

# --- resolve: override root exists but doesn't have this script --------

sparse_override=$(mktemp -d "$work/sparse.XXXXXX")
resolved=$(script_loader::resolve deck-fixup.sh "$baked" "$sparse_override")
[[ $resolved == "$baked/deck-fixup.sh" ]] || fail "resolve falls back to baked-in when the override root exists but lacks this script"
pass "resolve falls back to baked-in per-script, not all-or-nothing per-root"

# --- resolve: override entry is a directory, not a file (misconfigured) -

mkdir -p "$override/not-a-script.sh"
echo "baked" >"$baked/not-a-script.sh"
resolved=$(script_loader::resolve not-a-script.sh "$baked" "$override")
[[ $resolved == "$baked/not-a-script.sh" ]] ||
  fail "resolve refuses to treat a directory as a valid override and falls back to baked-in" "got $resolved"
pass "resolve doesn't try to use a directory where a script file is expected"

# --- resolve: script missing from both -> fails loudly ------------------

if script_loader::resolve totally-missing.sh "$baked" "$override" 2>/dev/null; then
  fail "resolve fails loudly when the script exists in neither location"
fi
pass "resolve fails loudly (PLAN.md §8.1's failure class) when a script is missing everywhere, rather than silently continuing"

# --- default_search_paths honors the env var escape hatch --------------

# The env var must reach the subshell that runs resolve; prefixing the
# assignment itself would be a no-op (an env prefix needs a command).
resolved=$(OMARCHY_DECK_OVERRIDE_ROOT="$override" script_loader::resolve deck-fixup.sh "$baked")
[[ $resolved == "$override/deck-fixup.sh" ]] ||
  fail "resolve (with no explicit override-root arg) honors OMARCHY_DECK_OVERRIDE_ROOT" "got $resolved"
pass "resolve falls back to OMARCHY_DECK_OVERRIDE_ROOT / default search paths when no override-root arg is given"

echo "all vm-script-loader.sh tests passed"

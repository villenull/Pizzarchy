#!/usr/bin/env bash
#
# iso-payload-audit.sh -- refuse to ship a payload that grants blanket
# passwordless root.
#
# PROGRESS.md 5.17 and operator decision 7 (PROGRESS.md 5.25): the dev Deck
# keeps /etc/sudoers.d/99-deck-testing on purpose -- the iterate-in-place SSH
# loop needs it and 5.17 proved no narrower grant is achievable -- and the ISO
# must REFUSE to carry it. docs/tasks/T5-iso-and-payload.md is explicit that
# this has to be a check that FAILS THE BUILD, not a comment.
#
# This is the build-time half. The runtime half is
# `src/deck-session.sh stage-audit-privileges`, which audits a LIVE machine via
# sudo. Same question, different input: that one reads /etc/sudoers.d on a
# running system, this one reads a payload tree and package archives offline,
# inside a build container with no sudo and no target. The PREDICATE is shared
# by sourcing, not copied -- see "why source" below.
#
# Usage:
#   tools/iso-payload-audit.sh <root> [<root>...]
#
# Each <root> is a directory. Anything under it that looks like a sudoers file
# is inspected:
#
#   * any regular file under a `sudoers.d/` directory, at any depth
#     (catches configs/airootfs/etc/sudoers.d/, a staged /etc/skel, an
#     unpacked package, our own src/ tree, an airootfs work dir);
#   * any file named `sudoers` under an `etc/` directory;
#   * any `*.pkg.tar.*` package archive -- listed with bsdtar, and any
#     etc/sudoers{,.d/*} member extracted and inspected. A drop-in that
#     arrives inside a package is exactly as shipped as one on disk.
#
# Exit codes: 0 clean, 1 the payload would ship unrestricted root, 2 usage.
#
# ---------------------------------------------------------------------------
# Two deliberate anti-"passes for the wrong reason" choices
# ---------------------------------------------------------------------------
#
# 1. It refuses to be vacuous. A root that does not exist is an ERROR, not
#    zero findings; package archives with no bsdtar to read them are an ERROR,
#    not a skip; a bsdtar that fails mid-scan is an ERROR, not an empty member
#    list; and the summary always prints what was actually inspected, so a
#    green run that scanned nothing is visible rather than reassuring. This
#    project's recurring failure mode is a check that passes because it looked
#    at the wrong thing (PROGRESS.md 7: "an evdev node can be enumerated and
#    permanently silent"; deck-session.sh's `dconf read -d`).
#
# 2. Blanket and passwordless stay SEPARATE predicates. `deck ALL=(ALL) ALL`
#    is blanket but password-protected -- it is the ordinary admin grant every
#    Arch/Omarchy install ships, and failing on it is the false positive that
#    teaches people to ignore the check. stage_audit_privileges' first version
#    did exactly that (PROGRESS.md 5.17). The hazard is blanket AND
#    passwordless.
#
# ---------------------------------------------------------------------------
# Why source deck-session.sh rather than reimplement the predicate
# ---------------------------------------------------------------------------
#
# Two implementations of "is this line dangerous?" can drift, and the one that
# drifts is the one nobody runs. deck-session.sh's tail guard documents that
# sourcing defines its functions and runs nothing; test/unit/test-deck-session.sh
# already relies on that. Sourcing inherits `set -euo pipefail` and every
# readonly constant, so source once.
#
# If either predicate ever disappears or is renamed, this script fails loudly
# below rather than quietly auditing nothing -- the same posture
# UPSTREAM_GREETER_SHA256 takes in deck-session.sh.

set -euo pipefail

AUDIT_PROG=iso-payload-audit
audit_log()  { printf '[%s] %s\n' "$AUDIT_PROG" "$*"; }
audit_warn() { printf '[%s] WARNING: %s\n' "$AUDIT_PROG" "$*" >&2; }
audit_fail() { printf '[%s] ERROR: %s\n' "$AUDIT_PROG" "$*" >&2; exit 1; }
audit_usage() { printf '[%s] usage: %s\n' "$AUDIT_PROG" "$*" >&2; exit 2; }

AUDIT_REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# Sourced for its two sudoers predicates only. It defines a great deal more;
# nothing else here is used, and nothing is executed by the source itself.
# shellcheck source=../src/deck-session.sh
source "$AUDIT_REPO_ROOT/src/deck-session.sh"

for _audit_fn in sudoers_line_is_blanket sudoers_line_is_nopasswd; do
  declare -F "$_audit_fn" >/dev/null ||
    audit_fail "src/deck-session.sh no longer defines ${_audit_fn}(). This audit shares that predicate deliberately (PROGRESS.md 5.17) and will not guess at a replacement -- re-point it at the renamed function before shipping anything."
done
unset _audit_fn

# ---------------------------------------------------------------------------

# Inspect one already-materialised sudoers file. Appends to the two global
# report arrays. Returns 0 always -- the verdict is the arrays, not the status,
# so one bad file does not abort the scan and hide the rest.
audit_file() {
  local path=$1 label=$2 line
  AUDIT_FILES_SEEN=$((AUDIT_FILES_SEEN + 1))
  # `|| [[ -n $line ]]` so a final line with no trailing newline is still read.
  while IFS= read -r line || [[ -n $line ]]; do
    sudoers_line_is_blanket "$line" || continue
    if sudoers_line_is_nopasswd "$line"; then
      AUDIT_PASSWORDLESS+=("${label}: ${line}")
    else
      AUDIT_WITH_PASSWORD+=("${label}: ${line}")
    fi
  done <"$path"
}

# Does this path look like a sudoers file? Matches a file under any
# `sudoers.d/` directory at any depth, and `etc/sudoers` itself. Deliberately
# not anchored at /etc: a payload tree is rooted anywhere
# (configs/airootfs/etc/sudoers.d, pkg/etc/sudoers.d, a staged skel).
audit_path_is_sudoers() {
  local p=$1
  [[ $p == */sudoers.d/* ]] && return 0
  [[ $p == */etc/sudoers ]] && return 0
  return 1
}

# Package archives are part of the payload. A drop-in inside a .pkg.tar.zst
# lands on the installed system exactly like one baked into airootfs, and a
# tree-only scan would miss it entirely -- which would be a check passing for
# the wrong reason on the most likely delivery route for OUR own package.
audit_package() {
  local pkg=$1 listing member extract_dir m
  AUDIT_PACKAGES_SEEN=$((AUDIT_PACKAGES_SEEN + 1))

  # Captured, not piped into the loop: a failing bsdtar inside a process
  # substitution would merely produce an empty member list and this function
  # would report the package clean. Take the status first.
  listing=$(bsdtar tf "$pkg") ||
    audit_fail "could not list ${pkg}. A package archive that cannot be read has NOT been audited; refusing to call this payload clean."

  local -a members=()
  while IFS= read -r member; do
    [[ -n $member ]] || continue
    # Directory entries list with a trailing slash; only files carry content.
    [[ $member == */ ]] && continue
    # Archive members have no leading slash; prefix one so the same matcher
    # works for archive members and on-disk paths.
    audit_path_is_sudoers "/$member" || continue
    members+=("$member")
  done <<<"$listing"

  [[ ${#members[@]} -gt 0 ]] || return 0

  extract_dir=$(mktemp -d) || audit_fail "mktemp -d failed"
  if ! bsdtar -xf "$pkg" -C "$extract_dir" "${members[@]}"; then
    rm -rf "$extract_dir"
    audit_fail "could not extract sudoers members from ${pkg}"
  fi
  for m in "${members[@]}"; do
    if [[ ! -f "$extract_dir/$m" ]]; then
      rm -rf "$extract_dir"
      audit_fail "extracted ${pkg} but ${m} is not there -- refusing to report a clean audit on an incomplete extraction"
    fi
    audit_file "$extract_dir/$m" "$(basename -- "$pkg")!${m}"
  done
  rm -rf "$extract_dir"
}

audit_root() {
  local root=$1 f
  [[ -e $root ]] ||
    audit_fail "payload root does not exist: ${root}. An absent tree is not a clean tree -- point this at the real payload or drop the argument."
  [[ -d $root ]] ||
    audit_fail "payload root is not a directory: ${root}"

  AUDIT_ROOTS_SEEN=$((AUDIT_ROOTS_SEEN + 1))

  while IFS= read -r -d '' f; do
    if [[ $f == *.pkg.tar.* && $f != *.sig ]]; then
      command -v bsdtar >/dev/null 2>&1 ||
        audit_fail "found package archives under ${root} but bsdtar is not installed. Skipping them would report a clean payload without having read the most likely place a sudoers drop-in ships. Install libarchive (bsdtar) and re-run."
      audit_package "$f"
      continue
    fi
    audit_path_is_sudoers "$f" || continue
    audit_file "$f" "${f#"$root"/}"
  done < <(find "$root" -type f -print0)
}

# ---------------------------------------------------------------------------

audit_main() {
  case ${1:-} in
    -h|--help|help)
      printf '%s\n' \
        "usage: ${0} <payload-root> [<payload-root>...]" \
        "" \
        "Fails (exit 1) if any sudoers file in the payload grants blanket root" \
        "without a password. Reads directory trees and *.pkg.tar.* archives." \
        "See the header of this file and PROGRESS.md 5.17 for why it exists."
      return 0
      ;;
  esac

  [[ $# -gt 0 ]] ||
    audit_usage "${0} <payload-root> [<payload-root>...]   (at least one root; an audit with nothing to audit is not a pass)"

  AUDIT_ROOTS_SEEN=0
  AUDIT_FILES_SEEN=0
  AUDIT_PACKAGES_SEEN=0
  AUDIT_PASSWORDLESS=()
  AUDIT_WITH_PASSWORD=()

  local root
  for root in "$@"; do
    audit_root "$root"
  done

  # Always state the denominator. A run that inspected nothing is the failure
  # this project keeps meeting; printing it is what makes it visible.
  audit_log "inspected ${AUDIT_FILES_SEEN} sudoers file(s) across ${AUDIT_ROOTS_SEEN} root(s) and ${AUDIT_PACKAGES_SEEN} package archive(s)"

  local b
  for b in "${AUDIT_WITH_PASSWORD[@]}"; do
    audit_log "blanket grant, password required (normal, not a failure): ${b}"
  done

  if [[ ${#AUDIT_PASSWORDLESS[@]} -eq 0 ]]; then
    audit_log "no PASSWORDLESS blanket grants in the payload"
    return 0
  fi

  for b in "${AUDIT_PASSWORDLESS[@]}"; do
    audit_warn "PASSWORDLESS BLANKET ROOT: ${b}"
  done
  audit_fail "${#AUDIT_PASSWORDLESS[@]} sudoers grant(s) in this payload give unrestricted root with NO password. On the dev Deck that file is deliberate (PROGRESS.md 5.17); an ISO that ships one is not a product. Remove it from the payload -- do not weaken this check."
}

# Sourcing defines the functions and runs nothing, so the unit suite can call
# audit_file / audit_path_is_sudoers directly. Executing behaves as normal.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  audit_main "$@"
fi

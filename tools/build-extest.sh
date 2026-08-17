#!/usr/bin/env bash
# Build extest (github.com/Supreeeme/extest) at the pinned SHA, both targets:
#   - x86_64  -> for dev-machine probes (test/xtest-extest.py, R-54)
#   - i686    -> for preloading into Steam, whose input process is 32-bit
#
# Why this exists: R-54 (docs/findings/P20-steam-xtest-closure.md, addendum)
# proved extest's XTEST->uinput translation reaches Wayland-native clients on
# Hyprland -- the mechanism Steam needs for Desktop Mode input. The remaining
# question is Steam itself driving it, which is T10's Deck spike. The session
# scratchpad where the first build happened is ephemeral; this script is the
# durable way to reproduce both artifacts.
#
# License: MIT (checked below, loudly). That matters because CLAUDE.md forbids
# depending on anything unlicensed or AUR-only -- extest is neither, provided
# we build and (if ever shipped) vendor it ourselves at a pinned SHA.
#
# Toolchain: Arch's rust ships std for x86_64 only. The i686 build needs a
# rustup-managed target. To keep the system untouched, this script uses (and if
# missing, installs) a CONTAINED toolchain under $EXTEST_TOOLCHAIN_DIR -- no
# ~/.rustup, no ~/.cargo, no PATH changes.
set -euo pipefail

EXTEST_REPO=${EXTEST_REPO:-https://github.com/Supreeeme/extest}
# The SHA R-54's measurement was taken at. Bumping this means re-running the
# R-54 probe, not just rebuilding.
#
# 🔴 IT IS NOT "v1.0.4", AND THIS FILE USED TO SAY IT WAS. Checked against
# upstream 2026-08-16: the only tags that exist are 1.0, 1.0.1, 1.0.2 and
# 1.0.3, and the newest release is 1.0.3 (2026-05-25). Tag 1.0.3 dereferences
# to 0d06867, which is this commit's PARENT. cb77cd4 is the tip of `main`, its
# subject is "Bump version to 1.0.4", and that commit changes nothing but the
# version string in Cargo.toml.
#
# So the accurate description is: **untagged upstream HEAD whose Cargo.toml
# self-declares 1.0.4.** Pinning it is fine -- a SHA is immutable -- but
# calling it a release upstream never cut is the kind of provenance claim this
# project is supposed to catch, and it was in a licence-gating script.
EXTEST_PIN=${EXTEST_PIN:-cb77cd4f80f83393a24bae17dd975e14fa6eb1b2}
WORK=${EXTEST_WORK_DIR:-"${TMPDIR:-/tmp}/extest-build-$USER"}
TOOLCHAIN=${EXTEST_TOOLCHAIN_DIR:-"$WORK/toolchain"}

# ⚠️ NOTHING CONSUMES THIS OUTPUT, AND THAT IS CURRENT AS OF 2026-08-17.
# extest was one of two candidate fixes for "Steam in Desktop Mode kills every
# input" (docs/tasks/T13). It LOST to the hidraw sandbox, which restores the
# trackpads, the mapper, our chords and the OSK rather than a bare pointer --
# so no install stage reads this directory and the ISO carries none of it.
# The build is kept because the approach is the fallback if the sandbox ever
# breaks, and because the mechanism is proven (T10 measured extest moving the
# desktop pointer on this hardware).
#
# So this still writes to ~/ISOs, deliberately: an output nothing ships does
# not belong under src/. If extest is ever revived, the branch
# worktree-agent-ab547d84d5eee3442 has the full install path, and moving this
# default to $REPO_ROOT/src/extest is the first line of it.
OUT=${EXTEST_OUT_DIR:-"$HOME/ISOs/extest-${EXTEST_PIN:0:7}"}

log() { printf '[build-extest] %s\n' "$*" >&2; }

# --- source, pinned ----------------------------------------------------------
mkdir -p "$WORK"
if [[ ! -d "$WORK/extest/.git" ]]; then
    log "cloning $EXTEST_REPO"
    git clone "$EXTEST_REPO" "$WORK/extest"
fi
git -C "$WORK/extest" fetch --quiet origin
git -C "$WORK/extest" checkout --quiet "$EXTEST_PIN"
log "checked out $EXTEST_PIN"

# The licence gate. If upstream ever changes it, this build must stop, loudly.
if ! head -1 "$WORK/extest/LICENSE" | grep -q "MIT License"; then
    log "FATAL: LICENSE is no longer MIT. Do not build, do not ship. Read it."
    exit 1
fi
log "license: MIT (verified)"

# --- toolchain, contained ----------------------------------------------------
export RUSTUP_HOME="$TOOLCHAIN/rustup" CARGO_HOME="$TOOLCHAIN/cargo"
CARGO="$CARGO_HOME/bin/cargo"
if [[ ! -x $CARGO ]]; then
    log "installing contained rustup toolchain into $TOOLCHAIN (one-time, ~2 min)"
    curl -fsSL https://sh.rustup.rs |
        sh -s -- -y --profile minimal --default-toolchain stable --no-modify-path
fi
"$CARGO_HOME/bin/rustup" target add i686-unknown-linux-gnu >/dev/null 2>&1 ||
    "$CARGO_HOME/bin/rustup" target add i686-unknown-linux-gnu

# i686 linking needs the 32-bit C runtime. Steam already dragged it in on any
# machine that has Steam; fail with the fix rather than a linker spew.
if [[ ! -e /usr/lib32/libc.so.6 ]]; then
    log "FATAL: no 32-bit glibc (/usr/lib32/libc.so.6). Install lib32-glibc"
    log "       lib32-gcc-libs (multilib) and re-run."
    exit 1
fi

# --- build both --------------------------------------------------------------
cd "$WORK/extest"
log "building x86_64 (dev-machine probes)"
"$CARGO" build --release --target x86_64-unknown-linux-gnu
log "building i686 (for preloading into Steam)"
"$CARGO" build --release --target i686-unknown-linux-gnu

mkdir -p "$OUT"
install -m 0644 target/x86_64-unknown-linux-gnu/release/libextest.so "$OUT/libextest-x86_64.so"
install -m 0644 target/i686-unknown-linux-gnu/release/libextest.so "$OUT/libextest-i686.so"

# --- the licence bundle, WITHOUT WHICH THIS MUST NOT SHIP --------------------
#
# 🔴 THIS SCRIPT USED TO GATE ON THE LICENCE AND THEN NOT COPY IT. It checked
# that upstream's LICENSE still said "MIT License" and emitted two .so files
# beside nothing at all. A compiled .so IS a copy under MIT, and MIT's one
# operative condition is:
#
#   "The above copyright notice and this permission notice shall be included in
#    all copies or substantial portions of the Software."
#
# So the artifacts this script produced could not lawfully be redistributed,
# and the ISO redistributes what it carries. That is CLAUDE.md's "don't depend
# on anything unlicensed" pointed at our own output -- the same objection that
# dropped 28allday/deckshift (docs/PROGRESS.md §2.4).
#
# The fix is HERE rather than at an install stage, because there is no install
# stage -- the artifacts are produced by this script and by nothing else, so
# this is the only place that can guarantee the notices travel with the .so.
install -m 0644 LICENSE "$OUT/LICENSE"
log "licence: copied upstream LICENSE (MIT, Copyright (c) 2023 Supreeeme)"

# The dependency notices. extest is Rust and statically links its crates into
# the .so, so their notices travel with it too -- and they are per copyright
# holder, not covered by extest's own. Audited against the committed Cargo.lock
# on 2026-08-16: everything linked is MIT, Apache-2.0 or ISC, nothing is
# copyleft, so there is no source-offer obligation -- only attribution.
#
# `cargo vendor` is used rather than a licence-scanning plugin because it needs
# nothing that is not already here: it downloads each locked crate WITH its own
# licence files, which is exactly the text that has to be carried.
#
# ⚠️ libloading is ISC, not MIT. It is permissive and its notice requirement is
# the same shape, but a bundle that assumes "everything is MIT" would drop it.
log "collecting dependency licence notices with cargo vendor"
VENDOR="$WORK/vendor"
rm -rf "$VENDOR"
"$CARGO" vendor --versioned-dirs "$VENDOR" >/dev/null

{
  printf 'THIRD-PARTY LICENCES\n'
  printf '====================\n\n'
  printf 'Notices for every crate statically linked into libextest.so.\n'
  printf 'extest itself: see LICENSE beside this file.\n'
  printf 'Source pin: %s at %s\n' "$EXTEST_REPO" "$EXTEST_PIN"
  printf 'Generated by tools/build-extest.sh from the committed Cargo.lock.\n\n'
  found_any=0
  for crate_dir in "$VENDOR"/*/; do
    [[ -d $crate_dir ]] || continue
    crate=$(basename -- "$crate_dir")
    for lic in "$crate_dir"LICENSE* "$crate_dir"LICENCE* "$crate_dir"COPYING*; do
      [[ -f $lic ]] || continue
      found_any=1
      printf -- '--------------------------------------------------------------\n'
      printf '%s -- %s\n' "$crate" "$(basename -- "$lic")"
      printf -- '--------------------------------------------------------------\n'
      cat -- "$lic"
      printf '\n'
    done
  done
  [[ $found_any -eq 1 ]] || {
    log "FATAL: cargo vendor produced no licence files at all. Do not ship."
    exit 1
  }
} >"$OUT/THIRD-PARTY-LICENSES"

# The bundle must not be a header with nothing under it -- the positive control
# on the loop above. A 1 KiB file here would mean the vendor tree was empty and
# every crate notice was silently missed.
bundle_bytes=$(wc -c <"$OUT/THIRD-PARTY-LICENSES")
[[ $bundle_bytes -gt 4096 ]] || {
    log "FATAL: THIRD-PARTY-LICENSES is only ${bundle_bytes} bytes, which cannot"
    log "       contain ~20 crates' notices. The vendor step found nothing. Do not ship."
    exit 1
}
log "licence: THIRD-PARTY-LICENSES written (${bundle_bytes} bytes)"

log "artifacts:"
file "$OUT"/libextest-*.so >&2
ls -l "$OUT/LICENSE" "$OUT/THIRD-PARTY-LICENSES" >&2
log "done. NOTHING SHIPS THESE -- see the OUT= comment; extest lost to the"
log "      hidraw sandbox in docs/tasks/T13. Keep the two licence files with"
log "      the .so files if you copy them anywhere."
log "Deck spike history: docs/tasks/T10-steam-extest-spike.md"

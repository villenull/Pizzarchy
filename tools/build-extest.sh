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
# v1.0.4 -- the SHA R-54's measurement was taken at. Bumping this means
# re-running the R-54 probe, not just rebuilding.
EXTEST_PIN=${EXTEST_PIN:-cb77cd4f80f83393a24bae17dd975e14fa6eb1b2}
WORK=${EXTEST_WORK_DIR:-"${TMPDIR:-/tmp}/extest-build-$USER"}
TOOLCHAIN=${EXTEST_TOOLCHAIN_DIR:-"$WORK/toolchain"}
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

log "artifacts:"
file "$OUT"/libextest-*.so >&2
log "done. Deck spike: docs/tasks/T10-steam-extest-spike.md"

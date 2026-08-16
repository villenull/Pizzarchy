#!/usr/bin/env bash
# capture-screenshots.sh -- produce the README's install screenshots from QEMU,
# pixel-exact, with no camera and no hardware.
#
# DEV-MACHINE TOOLING. Never shipped, never installed on a Deck (CLAUDE.md's
# `tools/` rule). It writes PNGs into docs/images/ and nothing else.
#
# Usage:
#   tools/capture-screenshots.sh                     # both VM runs, then convert
#   tools/capture-screenshots.sh --iso PATH          # capture from a specific ISO
#   tools/capture-screenshots.sh --skip-osk          # installer screens only
#   tools/capture-screenshots.sh --from-raw          # no VMs: reconvert what is
#                                                    # already in the raw dir
#
#   --substrate PATH   the neptune substrate for the OSK run
#                      (default test/images/neptune-substrate.raw)
#   --raw-dir DIR      where the untouched PPM screendumps live
#                      (default ~/.cache/omarchy-deck/screenshots)
#   --out DIR          where the finished PNGs go (default docs/images)
#
# ===========================================================================
# WHY THIS EXISTS, AND WHY IT IS NOT A CAMERA
# ===========================================================================
#
# The README needs pictures of installer screens that live on a Linux text
# console. Photographing the Deck's panel gives a moire-striped, keystoned,
# 3000x4000 JPEG of a 160x50 character grid. QEMU's QMP `screendump` gives the
# emulated VGA framebuffer as a PPM: every pixel exactly as the guest drew it,
# reproducible byte-for-byte, no lens.
#
# ⚠️ MEASURED, NOT ASSUMED (2026-08-16, against the release ISO named below):
# `screendump` works with `-display none`. The framebuffer is 1280x800, which
# at the console's 8x16 font is **160 columns by 50 rows** -- the same geometry
# docs/PROGRESS.md §7 measured on the Deck's own live console. So these are not
# merely "a console": they are a console the same shape as the real one, which
# is the property that matters for judging whether a screen is legible.
#
# ===========================================================================
# WHAT THIS CAN AND CANNOT CAPTURE -- read before believing a missing file is a
# bug in this script
# ===========================================================================
#
#   [x] S0 greeter, keyboard picker, deck-form's own text prompts, the summary,
#       the disk-overwrite confirm and the final "Ready to install?" gate.
#       All from test/vm/vm-installer-screens-test.sh, which already drives
#       that exact flow with a measured, named key sequence.
#
#   [x] The on-screen keyboard. QEMU has no gamepad, so in the installer run
#       the mapper never binds and the keyboard is never drawn -- there is
#       nothing on that framebuffer to capture. test/vm/vm-osk-tty-test.sh
#       builds a Deck-shaped pad out of `uinput` INSIDE the guest, binds the
#       real mapper to it, draws the real keyboard on a real console, and
#       `chvt`s to that console -- so a screendump, which copies the FOREGROUND
#       VT's framebuffer, catches it. That is why the keyboard comes from a
#       different suite and not from the installer one.
#
#   [ ] The Wi-Fi network list. STRUCTURALLY UNAVAILABLE in QEMU: there is no
#       wlan0, so deck-form.sh's S1 takes `deck_form_offline_note` and no list
#       is ever drawn. Nothing in this script can fake that without fabricating
#       SSIDs, which is not a screenshot. It needs hardware.
#
#   [ ] The install-progress screen. The installer suite stops at the final
#       "Ready to install?" gate on purpose (its own header explains why: one
#       more key starts a real partition attempt). Reaching progress means a
#       full install run -- test/vm/vm-install-test.sh's territory, not this
#       one's.
#
# ===========================================================================

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

RAW_DIR=${RAW_DIR:-$HOME/.cache/omarchy-deck/screenshots}
OUT_DIR="$REPO_ROOT/docs/images"
ISO=
SUBSTRATE="$REPO_ROOT/test/images/neptune-substrate.raw"
DO_INSTALLER=1
DO_OSK=1

log()  { printf '[capture-screenshots] %s\n' "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

while (( $# )); do
  case $1 in
    --iso)            ISO=$2; shift 2 ;;
    --substrate)      SUBSTRATE=$2; shift 2 ;;
    --raw-dir)        RAW_DIR=$2; shift 2 ;;
    --out)            OUT_DIR=$2; shift 2 ;;
    --skip-installer) DO_INSTALLER=0; shift ;;
    --skip-osk)       DO_OSK=0; shift ;;
    --from-raw)       DO_INSTALLER=0; DO_OSK=0; shift ;;
    -h|--help)        sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)                fail "unknown argument: $1" ;;
  esac
done

command -v magick >/dev/null || fail "ImageMagick ('magick') not found -- it is already a build dependency, so this should not happen"
command -v qemu-system-x86_64 >/dev/null || fail "qemu-system-x86_64 not found"

INSTALLER_RAW="$RAW_DIR/installer"
OSK_RAW="$RAW_DIR/osk"
mkdir -p "$INSTALLER_RAW" "$OSK_RAW" "$OUT_DIR"

# ---------------------------------------------------------------------------
# 1. Resolve the ISO, and SAY WHICH ONE.
# ---------------------------------------------------------------------------
#
# ⚠️ The whole point of the provenance file this script writes is that a
# screenshot from a stale ISO shows screens that no longer exist. Picking the
# newest build silently is exactly how that happens, so the choice is always
# printed and always recorded.
if [[ -z $ISO && $DO_INSTALLER == 1 ]]; then
  ISO=$(find "$HOME/.cache/omarchy-deck" -maxdepth 3 -name '*-x86_64-quattro.iso' \
          -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
  [[ -n $ISO ]] || fail "no ISO found under ~/.cache/omarchy-deck -- pass --iso PATH"
  log "no --iso given; using the most recently built one:"
fi
if [[ $DO_INSTALLER == 1 ]]; then
  [[ -f $ISO ]] || fail "ISO not found: $ISO"
  log "ISO: $ISO"
  log "     $(date -r "$ISO" '+built %Y-%m-%d %H:%M'), $(stat -c%s "$ISO") bytes"
  # A sidecar next to the frames, so `--from-raw` can still say where the
  # pixels came from months later. An image whose ISO nobody can name is not
  # evidence of anything.
  printf '%s\t%s\t%s\n' "$ISO" "$(date -r "$ISO" '+%Y-%m-%dT%H:%M:%S')" "$(stat -c%s "$ISO")" \
    >"$INSTALLER_RAW/.iso-provenance"
elif [[ -z $ISO && -f $INSTALLER_RAW/.iso-provenance ]]; then
  ISO=$(cut -f1 <"$INSTALLER_RAW/.iso-provenance")
  log "reusing the ISO recorded with the existing frames: $ISO"
fi

# ---------------------------------------------------------------------------
# 2. Drive the VMs. The FLOW is not reimplemented here -- the two suites own it
#    and this only sets VM_SCREENSHOT_DIR, which is inert for every other
#    caller. Reimplementing the key sequence in a second place is the copy-vs-
#    source hazard that produced the dead reserved-username check
#    (docs/tasks/P33-fix-round.md §5.34 D1); it is not repeated here.
# ---------------------------------------------------------------------------
installer_status=skipped
osk_status=skipped

if [[ $DO_INSTALLER == 1 ]]; then
  log "running test/vm/vm-installer-screens-test.sh (this takes ~10 min)"
  # ⚠️ NOT swallowed. The suite's own assertions may fail for reasons that have
  # nothing to do with screenshots; that is information, and this script exits
  # non-zero at the end if it happened -- after processing whatever frames were
  # captured, because the frames are the product.
  if VM_SCREENSHOT_DIR="$INSTALLER_RAW" "$REPO_ROOT/test/vm/vm-installer-screens-test.sh" "$ISO"; then
    installer_status=pass
  else
    installer_status="FAILED(exit $?)"
    log "⚠️  the installer suite FAILED -- see its own output above. Frames captured before"
    log "    the failure are still processed below, but treat them with suspicion."
  fi
fi

if [[ $DO_OSK == 1 ]]; then
  [[ -f $SUBSTRATE ]] || fail "substrate image not found: $SUBSTRATE (build it with test/images/vm-neptune-image.sh)"
  log "running test/vm/vm-osk-tty-test.sh (this takes ~10 min)"
  if VM_SCREENSHOT_DIR="$OSK_RAW" "$REPO_ROOT/test/vm/vm-osk-tty-test.sh" "$SUBSTRATE"; then
    osk_status=pass
  else
    osk_status="FAILED(exit $?)"
    log "⚠️  the OSK suite FAILED -- see its own output above."
  fi
fi

# ---------------------------------------------------------------------------
# 3. PPM -> README-ready PNG.
# ---------------------------------------------------------------------------
#
# A raw screendump is a 1280x800 console of which a greeter uses five rows; the
# rest is background, and at GitHub's rendered width the text would be a smear
# in the top-left corner. So each frame is trimmed to its own content and given
# a margin back -- character-cell sized (16 px = one row, two columns), so the
# result still looks like a console rather than a cropped photograph.
#
# ⚠️ NOTHING IS UPSCALED. The console font is an 8x16 bitmap; resampling it is
# the one operation guaranteed to make it less legible than the screen it came
# from. GitHub downscales a 1280-wide image to its column width, and trimming
# is what keeps most of these well under that.
#
# TWO CROP MODES, because the keyboard frames are shaped differently from the
# rest. On a 50-row console the prompt sits at the top and the keyboard at the
# bottom, with ~35 genuinely empty rows between them -- real, and exactly what
# the Deck shows, but as a README image it is 90% void. `bottom` keeps the
# console's last rows (the keyboard) and lets the trim do the rest. The full
# frame is ALSO published for anything cropped that way, so the crop hides
# nothing: see install-03c-osk-fullscreen.png.
convert_one() {
  local src=$1 dst=$2 mode=${3:-full} bg
  [[ -f $src ]] || return 1
  bg=$(magick "$src" -format '%[pixel:p{0,0}]' info:)
  local pre=()
  # 224 px is 14 rows of the 8x16 console -- headroom over the 10 the keyboard
  # currently needs, with the trim below removing whatever is not used. It is a
  # ceiling, not a measurement of the keyboard's height.
  [[ $mode == bottom ]] && pre=(-gravity South -crop 1280x224+0+0 +repage)
  magick "$src" \
    "${pre[@]}" \
    -bordercolor "$bg" -border 1 \
    -trim +repage \
    -bordercolor "$bg" -border 24x16 \
    -strip \
    "$dst" 2>/dev/null
  # A frame that trims to nothing means the screen was blank there -- a real
  # result (the keyboard was not drawn), not a conversion to publish.
  local h
  h=$(magick identify -format '%h' "$dst" 2>/dev/null || echo 0)
  if (( h < 64 )); then
    rm -f "$dst"
    return 1
  fi
}

# name-in-raw-dir  ->  README filename
#
# ⚠️ THE README NAMES ARE THE CONTRACT. README.md's placeholders name these
# exact files; a rename here is a broken image there.
#
# 🔴 THE LEFT-HAND NAMES ARE THE HARNESS'S STEP LABELS, AND SOME OF THEM ARE
# STALE. They were measured against the 2026-08-12 ISO and deck-form.sh has
# taken over more screens since. Measured against the 2026-08-16 release ISO,
# on the run that produced these images:
#
#   00-greeter        S0 disclosure + "Press A to begin"      -- name correct
#   01-kb-us          the keyboard picker, cursor on US       -- name correct
#   23-hostname       "Where are you?" + the Field/Value recap + "Does this
#                     look right?".  Upstream's separate Full name / Email /
#                     Hostname prompts NO LONGER EXIST on this ISO, so the
#                     flow is three steps ahead of the label.
#   24..27            ALL FOUR are deck-form's disk-overwrite confirm,
#                     byte-identical (24 and 25 are labelled timezone-list and
#                     summary, and are neither).
#   28-deck-summary   deck_final_summary's "Ready to install?" gate -- correct.
#
# The mapping below therefore follows the MEASURED CONTENT, not the label. If
# somebody re-baselines the harness's STEPS list, re-measure this table rather
# than trusting either it or the labels. The same drift is why the installer
# suite is currently red against this ISO (51/62) -- see the report the run
# leaves in its work dir.
declare -a MAP=(
  "$INSTALLER_RAW/00-greeter.ppm|$OUT_DIR/install-01-greeter.png|S0 greeter|full"
  "$INSTALLER_RAW/26-disk-confirm.ppm|$OUT_DIR/install-04-confirm.png|disk-overwrite confirm|full"
  "$OSK_RAW/3-typed-h.ppm|$OUT_DIR/install-03-osk.png|on-screen keyboard, one character typed|bottom"
  "$OSK_RAW/3-typed-h.ppm|$OUT_DIR/install-03c-osk-fullscreen.png|the same frame, whole console|full"
  "$INSTALLER_RAW/01-kb-us.ppm|$OUT_DIR/install-01a-keyboard-layout.png|keyboard picker|full"
  "$INSTALLER_RAW/23-hostname.ppm|$OUT_DIR/install-04a-recap.png|settings recap (label is stale)|full"
  "$INSTALLER_RAW/28-deck-summary.ppm|$OUT_DIR/install-04b-final-gate.png|final Ready-to-install gate|full"
)
# ⚠️ NOT IN THE MAP, DELIBERATELY: the username/password prompts
# (03-username-empty .. 10-username-deck). They are real, but in QEMU three
# quarters of each frame is deck-form's own honest warning block -- "no gamepad
# present", "the on-screen keyboard's helper exited without ever reporting
# bound" -- which is TRUE in a VM and false on a Deck. Shipping that as "this is
# what typing your username looks like" would advertise a defect the hardware
# does not have. The keyboard shots from the OSK suite show the same prompt
# shape without the lie.

log "converting frames -> $OUT_DIR"
made=0
missing=()
for entry in "${MAP[@]}"; do
  IFS='|' read -r src dst what mode <<<"$entry"
  if convert_one "$src" "$dst" "$mode"; then
    log "  ok      ${dst##*/}  ($what, $(magick identify -format '%wx%h' "$dst"))"
    made=$((made + 1))
  else
    log "  MISSING ${dst##*/}  (no $src -- $what)"
    missing+=("${src##*/}")
  fi
done

# ---------------------------------------------------------------------------
# 4. Provenance. WHICH ISO a screenshot came from is the single fact that makes
#    it trustworthy or worthless, and it is invisible in a PNG.
# ---------------------------------------------------------------------------
{
  echo "# docs/images provenance -- written by tools/capture-screenshots.sh"
  echo "# Regenerate with: tools/capture-screenshots.sh --iso <the SHIPPING iso>"
  echo
  echo "generated:        $(date -Is)"
  echo "installer ISO:    ${ISO:-<not run>}"
  if [[ -n ${ISO:-} && -f ${ISO:-} ]]; then
    echo "  built:          $(date -r "$ISO" '+%Y-%m-%d %H:%M:%S')"
    echo "  bytes:          $(stat -c%s "$ISO")"
  fi
  echo "OSK substrate:    $SUBSTRATE"
  echo "  ⚠️ the keyboard frames do NOT come from the ISO. vm-osk-tty-test.sh"
  echo "     copies src/deck-input-mapper.py and src/deck_osk_*.py onto the"
  echo "     substrate at run time, so they show the WORKING TREE's keyboard."
  echo "     Same code the ISO carries, different carrier -- say so if it matters."
  echo "installer suite:  $installer_status"
  echo "OSK suite:        $osk_status"
  echo "frames written:   $made"
  (( ${#missing[@]} )) && echo "frames missing:   ${missing[*]}"
  echo
  echo "NOT capturable in QEMU, and why:"
  echo "  install-02-wifi     no wlan0 in a VM, so S1 never draws a network list"
  echo "  install-05-progress the screens suite stops at the final gate by design"
} >"$OUT_DIR/SOURCE.txt"
log "provenance -> $OUT_DIR/SOURCE.txt"

if [[ $installer_status == FAILED* || $osk_status == FAILED* ]]; then
  fail "a VM suite failed (installer=$installer_status osk=$osk_status). Images above were still written; do not ship them without explaining the failure."
fi
if (( made == 0 )); then
  fail "no frames were produced at all -- check $RAW_DIR"
fi
log "done: $made image(s) in $OUT_DIR"

#!/usr/bin/env python3
"""Unit tests for patch 0030-screensaver-font-fits-panel — the screensaver
terminal font size, and the arithmetic that picked it.

No VM, no root, no network, no hardware. Run directly:

    python3 test/unit/test-screensaver-fit.py

WHAT THIS SUITE IS ACTUALLY FOR
===============================

The defect (operator, from hardware, 2026-08-16): *"the screensaver in desktop
mode appears clipped. as if it were meant for a bigger screen so then the O and
Y of omarchy can't be seen."*

A test that only asserted `size=14` appears in a file would be a step
assertion — exactly the class `docs/findings/P32-steam-never-installed.md`
indicts. The number is not the product; the INEQUALITY is:

    columns_available(size) >= art_columns

So this suite re-derives the column count from first principles (§1), proves the
model reproduces the bug at upstream's 18 (§2), proves the shipped size clears
the art with margin under pessimistic rounding (§3), and only then checks that
the patch and its .meta actually carry that size (§4-§5). If upstream widens the
logo art, or someone "tidies" the size back up, §3 goes red with the reason.

§6 cross-checks the model's inputs against the pinned runtime checkout when it
is present on this machine — the art width, the pre-image the patch expects, and
the fact that the terminal is foot. It is a bonus, not the basis: the constants
below were measured and are stated so the suite still means something on a box
that has never built an ISO.

⚠️ WHAT THIS SUITE CANNOT DO. It has never seen a panel. It proves the art fits
the terminal *by construction*; it does not prove ttfx then centres it, that
foot resolves the font family it is asked for, or that the operator's
~/.config/omarchy/branding/screensaver.txt is still upstream's logo. Those are
the operator's to check, and the report says so.
"""

from __future__ import annotations

import math
import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
PATCH_DIR = REPO_ROOT / "src" / "omarchy-deck-patches" / "patches"
PKG_DIR = REPO_ROOT / "iso" / "overlay" / "configs" / "deck" / "pkgbuilds" / "omarchy-deck"
STEM = "0030-screensaver-font-fits-panel"
PATCH = PATCH_DIR / f"{STEM}.patch"
META = PATCH_DIR / f"{STEM}.meta"

# The pinned upstream checkout, if this machine has one. Optional by design —
# see the docstring. iso/RUNTIME names the pin these paths are expected to hold.
RUNTIME_CANDIDATES = (
    pathlib.Path.home() / ".cache" / "omarchy-deck" / "iso-build" / "runtime-src",
    pathlib.Path.home() / ".cache" / "omarchy-deck" / "p32-build" / "runtime-src",
)

FAILURES = 0
CHECKS = 0


def check(what: str, got, want) -> None:
    global FAILURES, CHECKS
    CHECKS += 1
    if got == want:
        print(f"ok   {what}")
    else:
        print(f"FAIL {what}: got {got!r}, want {want!r}")
        FAILURES += 1


def check_true(what: str, got) -> None:
    check(what, bool(got), True)


def note(what: str) -> None:
    print(f"--   {what}")


# ---------------------------------------------------------------------------
# §1 The model: how many columns does a screensaver terminal have?
# ---------------------------------------------------------------------------
#
# Every constant here is a measurement, and each says where it came from.

# Omarchy's logo.txt, which omarchy-upgrade-to-quattro:1972 copies to
# ~/.config/omarchy/branding/screensaver.txt and which omarchy-screensaver feeds
# to ttfx. Widest line, in characters, at basecamp/omarchy@f0020448ca87.
# The "O" occupies columns 0-9 and the "Y" columns 70-80.
ART_COLUMNS = 81

# `omarchy-transcode-ascii --width` defaults to 80 (its line 28), so custom
# branding made the documented way lands at most this wide. A size that fits the
# logo but not this would still ship a latent bug.
TRANSCODE_DEFAULT_COLUMNS = 80

# eDP-1 on the OLED Deck: 800x1280 physical, transform 3, scale 1.25
# (docs/PROGRESS.md §5.37). A fullscreen window — and
# default/hypr/apps/system.lua makes this one fullscreen — is handed
# 1280/1.25 = 1024 logical px across.
PANEL_LOGICAL_WIDTH_PX = 1024

# JetBrainsMono Nerd Font: 1000 units/em, 600-unit advance on space and on every
# block glyph the art uses (U+2588/U+2584/U+2580), read from
# JetBrainsMonoNerdFont-Regular.ttf with fontTools.
FONT_ADVANCE_EM = 0.6

# Points to pixels at the 96 dpi base every toolkit here uses.
PX_PER_PT = 96 / 72


def columns_for_size(size_pt: float, *, cell_slack_px: int = 0) -> int:
    """Terminal columns for a fullscreen screensaver terminal at `size_pt`.

    🔴 THE SCALE FACTOR CANCELS AND THAT IS THE POINT. foot renders into a
    buffer of logical_width * scale device px, and scales the font by the same
    factor, so the column count depends only on the LOGICAL width. The answer is
    therefore the same whether foot takes Hyprland's fractional scale (1.25) or
    falls back to integer scaling (2) — which is what makes a pinned size safe
    on a fractionally-scaled panel.

    `cell_slack_px` models the rounding foot/fcft/FreeType does at an integer
    pixel size: pass 1 to ask "and if every cell came out a pixel wider?".
    """
    cell_px = FONT_ADVANCE_EM * size_pt * PX_PER_PT + cell_slack_px
    return math.floor(PANEL_LOGICAL_WIDTH_PX / cell_px)


print("\n§1 the column model")
check("a 1024-logical-px panel at size 18 gives 71 columns", columns_for_size(18), 71)
check("…at 16, 80 columns", columns_for_size(16), 80)
check("…at 15, 85 columns", columns_for_size(15), 85)
check("…at 14, 91 columns", columns_for_size(14), 91)
# Sanity: the model is monotonic. A bug that inverted it would make every other
# check in this file pass for the wrong reason.
check_true(
    "the model is monotonic in size",
    all(columns_for_size(p) >= columns_for_size(p + 1) for p in range(8, 30)),
)


# ---------------------------------------------------------------------------
# §2 The model reproduces the reported defect
# ---------------------------------------------------------------------------
#
# If it did not, the diagnosis would be wrong and the fix would be a guess.

print("\n§2 the model reproduces the bug at upstream's size")
UPSTREAM_SIZE = 18
lost = ART_COLUMNS - columns_for_size(UPSTREAM_SIZE)
check_true(f"upstream's size={UPSTREAM_SIZE} cannot fit the art", columns_for_size(UPSTREAM_SIZE) < ART_COLUMNS)
check("…it is short by 10 columns", lost, 10)
# ttfx is launched with `--anchor-canvas c --anchor-text c`, so the overflow is
# split between the two ends: half the O and half the Y, which is the symptom
# the operator described and no other hypothesis produces.
check("…5 columns off each end, which is half the O and half the Y", lost // 2, 5)

# 🔴 AND THE HYPOTHESIS THIS RULES OUT. omarchy-screensaver's own
# `wait_for_terminal_resize` comment warns that ttfx measures the terminal once
# at startup and that an 80x24 pty paints into a corner. If that race were the
# cause, the art would lose ONE column, not ten — so the race cannot produce
# the reported symptom, whatever else it may do.
RACE_FALLBACK_COLUMNS = 80  # foot's initial-window-size-chars default
check(
    "the 80x24 startup race would clip 1 column, not 10 — so it is not this bug",
    ART_COLUMNS - RACE_FALLBACK_COLUMNS,
    1,
)


# ---------------------------------------------------------------------------
# §3 The shipped size clears the art, with margin, under pessimistic rounding
# ---------------------------------------------------------------------------


def patched_size(patch_text: str) -> float:
    """The font size the patch's + line installs."""
    m = re.search(r"^\+font=.*:size=([0-9]+(?:\.[0-9]+)?)$", patch_text, re.M)
    assert m, "the patch does not add a font= line with a size"
    return float(m.group(1))


check_true("the patch file exists", PATCH.is_file())
check_true("the meta file exists", META.is_file())
PATCH_TEXT = PATCH.read_text(encoding="utf-8")
META_TEXT = META.read_text(encoding="utf-8")

SIZE = patched_size(PATCH_TEXT)

print("\n§3 the shipped size fits")
note(f"shipped size={SIZE:g} -> {columns_for_size(SIZE)} columns, art needs {ART_COLUMNS}")
check_true(
    f"size={SIZE:g} fits Omarchy's {ART_COLUMNS}-column logo",
    columns_for_size(SIZE) >= ART_COLUMNS,
)
check_true(
    f"…and omarchy-transcode-ascii's default --width {TRANSCODE_DEFAULT_COLUMNS}",
    columns_for_size(SIZE) >= TRANSCODE_DEFAULT_COLUMNS,
)
# The margin is what stops this being a knife edge. foot derives the cell width
# through fcft/FreeType at an integer pixel size; one pixel of rounding at
# size=15 moves the cell from 15 to 16 px and the column count from 85 to 80 —
# back under the art. The shipped size has to survive that.
check_true(
    "…and still fits if every cell rounds up a pixel",
    columns_for_size(SIZE, cell_slack_px=1) >= ART_COLUMNS,
)
check_true(
    "…leaving at least 5 columns of margin at nominal cell width",
    columns_for_size(SIZE) - ART_COLUMNS >= 5,
)
# Vertical: the art is 11 lines. Anything that fits horizontally on this panel
# fits vertically by a wide margin, but an unstated assumption is still an
# assumption, so it is stated.
ART_LINES = 11
PANEL_LOGICAL_HEIGHT_PX = 640  # 800 device px / scale 1.25
# JetBrainsMono hhea: ascent 1020, descent -300, lineGap 0 -> 1.32 em line box.
rows = math.floor(PANEL_LOGICAL_HEIGHT_PX / (1.32 * SIZE * PX_PER_PT))
check_true(f"…and the {ART_LINES}-line art fits vertically ({rows} rows)", rows >= ART_LINES)


# ---------------------------------------------------------------------------
# §4 The patch says what it means, and targets what it claims
# ---------------------------------------------------------------------------

print("\n§4 the patch")
check(
    "it removes exactly the size the pin ships",
    re.findall(r"^-font=.*:size=([0-9]+(?:\.[0-9]+)?)$", PATCH_TEXT, re.M),
    [str(UPSTREAM_SIZE)],
)
check(
    "it targets default/foot/screensaver.ini",
    re.findall(r"^\+\+\+ b/(.*)$", PATCH_TEXT, re.M),
    ["default/foot/screensaver.ini"],
)
# One hunk, one line. A patch that touched more of a 7-line config would be
# doing something this suite has not reasoned about.
check("it is a single hunk", len(re.findall(r"^@@ ", PATCH_TEXT, re.M)), 1)
check("…starting at line 1", bool(re.search(r"^@@ -1,", PATCH_TEXT, re.M)), True)
check("…changing one line", len(re.findall(r"^[+-][^+-]", PATCH_TEXT, re.M)), 2)
# The applier splits `git apply` rejects from silence; a patch with no context
# lines would apply anywhere and defeat that.
check_true("…with context lines, so upstream moving it is a reject", "\n [main]\n" in PATCH_TEXT)


# ---------------------------------------------------------------------------
# §5 The .meta's post-conditions actually discriminate
# ---------------------------------------------------------------------------
#
# The applier runs each `assert_count: <file>|<ERE>|<n>` with `grep -oE` and
# compares the match count. A post-condition that matched everything, or
# nothing, would pass while asserting nothing — so each one is exercised against
# a post-image that should satisfy it and one that should not.

print("\n§5 the meta's post-conditions")


def meta_asserts(text: str) -> list[tuple[str, str, int]]:
    out = []
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("assert_count:"):
            continue
        value = line.split(":", 1)[1].strip()
        # Split on the FIRST and LAST pipe, exactly as the applier does, so an
        # ERE containing alternation survives.
        f, rest = value.split("|", 1)
        re_src, want = rest.rsplit("|", 1)
        out.append((f, re_src, int(want)))
    return out


ASSERTS = meta_asserts(META_TEXT)
check("the meta declares 2 post-conditions", len(ASSERTS), 2)
check_true(
    "…all against the patch's own target",
    all(f == "default/foot/screensaver.ini" for f, _, _ in ASSERTS),
)
check_true("the meta declares a target:", "\ntarget: default/foot/screensaver.ini\n" in META_TEXT)
check_true("…a description:", "\ndescription: " in META_TEXT)
check_true("…and a requirement:", "\nrequirement: " in META_TEXT)


def grep_o_count(re_src: str, text: str) -> int:
    """`grep -oE` semantics: count matches, one per line, non-overlapping."""
    rx = re.compile(re_src, re.M)
    return sum(1 for _ in rx.finditer(text))


GOOD = (
    "[main]\n"
    f"font=JetBrainsMono Nerd Font:size={SIZE:g}\n"
    "pad=0x0\n\n[colors-dark]\nbackground=000000\nforeground=ffffff\n"
)
BAD_UPSTREAM = GOOD.replace(f"size={SIZE:g}", f"size={UPSTREAM_SIZE}")
BAD_DOUBLED = GOOD + f"font=JetBrainsMono Nerd Font:size={SIZE:g}\n"

for i, (_, re_src, want) in enumerate(ASSERTS):
    check(f"post-condition {i} holds on the patched file", grep_o_count(re_src, GOOD), want)
check_true(
    "…and at least one FAILS on an unpatched file (so they discriminate)",
    any(grep_o_count(r, BAD_UPSTREAM) != w for _, r, w in ASSERTS),
)
check_true(
    "…and at least one fails if the line were appended twice",
    any(grep_o_count(r, BAD_DOUBLED) != w for _, r, w in ASSERTS),
)
# The "nothing at 16 or above" guard is the one that keeps meaning something
# after an upstream retune, so it is exercised at every size it must reject.
RANGE_GUARD = [(r, w) for _, r, w in ASSERTS if w == 0]
check("there is a zero-count range guard", len(RANGE_GUARD), 1)
if RANGE_GUARD:
    guard_re = RANGE_GUARD[0][0]
    too_big = [16, 17, 18, 20, 24, 36, 100]
    ok_small = [8, 9, 10, 12, 14, 15]
    check_true(
        "…it rejects every size that cannot fit the art",
        all(
            grep_o_count(guard_re, GOOD.replace(f"size={SIZE:g}", f"size={s}")) == 1
            for s in too_big
        ),
    )
    check_true(
        "…and accepts every size that can",
        all(
            grep_o_count(guard_re, GOOD.replace(f"size={SIZE:g}", f"size={s}")) == 0
            for s in ok_small
        ),
    )
    # Cross-check the guard against the model rather than against a literal:
    # its boundary must be the first size that stops fitting.
    check_true(
        "…and its boundary is exactly where the art stops fitting",
        all(columns_for_size(s) < ART_COLUMNS for s in too_big)
        and all(columns_for_size(s) >= ART_COLUMNS for s in ok_small),
    )


# ---------------------------------------------------------------------------
# §6 Cross-check the constants against the pinned checkout, when present
# ---------------------------------------------------------------------------
#
# Optional: this is the only part that needs a runtime checkout on disk. When it
# is missing the suite says so out loud rather than pretending it ran — a
# post-condition that did not run must never count as one that passed.

print("\n§6 cross-check against the pinned runtime checkout")
runtime = next((p for p in RUNTIME_CANDIDATES if (p / "logo.txt").is_file()), None)
if runtime is None:
    note("no pinned checkout on this machine; §6 SKIPPED (build guard 6.6 covers the patch)")
    note(f"looked in: {', '.join(str(p) for p in RUNTIME_CANDIDATES)}")
else:
    note(f"using {runtime}")
    art = (runtime / "logo.txt").read_text(encoding="utf-8").split("\n")
    check("upstream's logo.txt is as wide as ART_COLUMNS says", max(len(x) for x in art), ART_COLUMNS)
    check("…and as tall as ART_LINES says", len(art), ART_LINES)

    ini = runtime / "default" / "foot" / "screensaver.ini"
    check_true("the pin still has default/foot/screensaver.ini", ini.is_file())
    if ini.is_file():
        check_true(
            "…still at the size the patch removes",
            f"size={UPSTREAM_SIZE}\n" in ini.read_text(encoding="utf-8"),
        )
        check_true("…and still with pad=0x0, which the model assumes", "pad=0x0" in ini.read_text(encoding="utf-8"))

    # The terminal is foot and that is why this patch touches foot's config.
    term_list = runtime / "default" / "xdg-terminal-exec" / "hyprland-xdg-terminals.list"
    if term_list.is_file():
        entries = [
            x.strip()
            for x in term_list.read_text(encoding="utf-8").splitlines()
            if x.strip() and not x.strip().startswith("#")
        ]
        check("xdg-terminal-exec resolves to foot and nothing else", entries, ["foot.desktop"])
    else:
        note("no hyprland-xdg-terminals.list in the pin; terminal choice not cross-checked here")

    pkgs = runtime / "install" / "omarchy-base.packages"
    if pkgs.is_file():
        names = [x.strip() for x in pkgs.read_text(encoding="utf-8").splitlines()]
        check_true("…and foot is the terminal actually installed", "foot" in names)
        check_true(
            "…while alacritty/ghostty/kitty are not, which is why they are unpatched",
            not ({"alacritty", "ghostty", "kitty"} & set(names)),
        )


# ---------------------------------------------------------------------------
# §7 The patch reaches the package
# ---------------------------------------------------------------------------
#
# `docs/findings/P32-steam-never-installed.md` again: a payload nothing ships is
# indistinguishable from no payload. test-omarchy-deck-package.sh owns the
# byte-identity rule repo-wide; these checks are the local, fast version so this
# patch cannot land half-wired.

print("\n§7 the patch reaches the package")
for suffix in (".patch", ".meta"):
    canonical, packaged = PATCH_DIR / f"{STEM}{suffix}", PKG_DIR / f"{STEM}{suffix}"
    check_true(f"the packaged copy of {STEM}{suffix} exists", packaged.is_file())
    if packaged.is_file():
        check_true(
            f"…and is byte-identical to src/omarchy-deck-patches/patches/{STEM}{suffix}",
            packaged.read_bytes() == canonical.read_bytes(),
        )

PKGBUILD = (PKG_DIR / "PKGBUILD").read_text(encoding="utf-8")
for suffix in (".patch", ".meta"):
    check_true(f"PKGBUILD's source=() lists {STEM}{suffix}", f"'{STEM}{suffix}'" in PKGBUILD)
    check_true(
        f"…and package() installs it into the applier's patch dir",
        f'"$pkgdir/$_patchdir/{STEM}{suffix}"' in PKGBUILD,
    )
# makepkg fails on a sha256sums=() shorter than source=(); a mismatch here is a
# container build failure ~40 minutes into an ISO. Anchored to the start of a
# line: this PKGBUILD's own comments quote `source=()` and would otherwise be
# what gets counted.
def array_len(name: str) -> int:
    m = re.search(rf"^{name}=\((.*?)\)", PKGBUILD, re.S | re.M)
    assert m, f"no {name}=() array in the PKGBUILD"
    return len(re.findall(r"'[^']+'", m.group(1)))


check("source=() and sha256sums=() are the same length", array_len("sha256sums"), array_len("source"))
check_true("…and both grew for this patch", array_len("source") >= 11)


# ---------------------------------------------------------------------------
print(f"\n{CHECKS - FAILURES}/{CHECKS} checks passed")
if FAILURES:
    print(f"{FAILURES} FAILED")
sys.exit(1 if FAILURES else 0)

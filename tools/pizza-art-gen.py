#!/usr/bin/env python3
"""Generate src/pizza-art/*.txt -- the pizza fastfetch logos.

Dev-machine tooling; never shipped. Run it from the repo root:

    python3 tools/pizza-art-gen.py src/pizza-art

It is deterministic (its own value noise, no `random`), so a re-run reproduces
the committed files byte for byte. Nothing depends on this script at build or
install time -- the art is committed, and swapping it is a one-file change.
The contract every output must satisfy is asserted by test/unit/test-pizza.sh.

Pure ASCII output. Colour is expressed only as fastfetch's $1..$9 placeholders,
never as raw ANSI. Geometry is computed, not hand-drawn, so every row is exactly
the same display width and the notch edges line up by construction.

Two shapes. `build()` makes a SQUARE pizza with the top-left quadrant cut out;
`build_round()` makes a ROUND one with a single 1/8 wedge gone, which is what
ships. Both put crust on the OUTER perimeter only -- the cut faces are a
cross-section, so they show sauce, not crust. That is what makes it read as "a
slice was taken out" rather than "an L-shaped pizza" or "a pac-man".
"""
import math
import sys

# Deterministic value noise -- no random module, so a regenerate is byte-stable.
def noise(x, y, salt=0):
    h = (x * 374761393 + y * 668265263 + salt * 2246822519) & 0xFFFFFFFF
    h = (h ^ (h >> 13)) * 1274126177 & 0xFFFFFFFF
    h = h ^ (h >> 16)
    return (h & 0xFFFF) / 65535.0


def render(ch, col, w, h):
    """Emit rows with $N inserted only where the colour changes."""
    out = []
    for y in range(h):
        row, cur = [], None
        for x in range(w):
            if ch[y][x] == " ":
                row.append(" ")
                continue
            if col[y][x] != cur:
                row.append("$%d" % col[y][x])
                cur = col[y][x]
            row.append(ch[y][x])
        out.append("".join(row).rstrip())
    return "\n".join(out) + "\n"


def build(w, h, crust, rim, cheese, pep, cut, spots,
          crust_depth, rim_depth, cut_depth, salt):
    nx, ny = w // 2, h // 2          # the bite: cols < nx AND rows < ny
    ch = [[" "] * w for _ in range(h)]
    col = [[0] * w for _ in range(h)]

    for y in range(h):
        for x in range(w):
            if x < nx and y < ny:
                continue

            # Horizontal distances are halved: a terminal cell is about twice
            # as tall as it is wide, so two columns cover the same ground as
            # one row. Without this the crust is four columns thick on the
            # sides and one row thick top and bottom.
            d_out = min(y + 0.5, (h - 1 - y) + 0.5,
                        (x + 0.5) * 0.5, ((w - 1 - x) + 0.5) * 0.5)

            # Distance to the cut, which is the corner path
            # (0,ny) -> (nx,ny) -> (nx,0). Only the two segments, not the
            # whole notch rectangle.
            if y < ny:
                d_cut = (x - nx + 0.5) * 0.5
            elif x < nx:
                d_cut = (y - ny + 0.5)
            else:
                d_cut = math.hypot((x - nx + 0.5) * 0.5, (y - ny + 0.5))

            n = noise(x, y, salt)

            if d_out < crust_depth:
                pool, colour = crust, 1
            elif d_out < crust_depth + rim_depth:
                pool, colour = rim, 2
            elif d_cut < cut_depth:
                pool, colour = cut, 3
            else:
                pool, colour = None, None
                for (px, py, pr) in spots:
                    r = math.hypot((x - px) * 0.5, (y - py) * 1.0)
                    if r <= pr:
                        pool = pep
                        colour = 3
                        idx = min(len(pep) - 1, int((r / pr) * len(pep)))
                        ch[y][x] = pep[idx]
                        col[y][x] = 3
                        break
                if pool is not None:
                    continue
                pool = cheese
                colour = 2 if n < 0.68 else 4

            ch[y][x] = pool[int(n * len(pool)) % len(pool)]
            col[y][x] = colour
    return render(ch, col, w, h)


def build_round(w, h, R, wedge_mid_deg, wedge_deg,
                crust, rim, cheese, pep, cut, spots,
                crust_depth, rim_depth, cut_depth, salt):
    """A disc with ONE wedge removed. x is halved throughout: a terminal cell
    is about twice as tall as it is wide, so two columns cover one row's
    ground. Without it the 'circle' is an ellipse and the crust is four
    columns thick at the sides and one row thick top and bottom."""
    cx, cy = (w - 1) / 2.0, (h - 1) / 2.0
    a0 = math.radians(wedge_mid_deg - wedge_deg / 2.0)
    a1 = math.radians(wedge_mid_deg + wedge_deg / 2.0)
    ch = [[" "] * w for _ in range(h)]
    col = [[0] * w for _ in range(h)]

    for y in range(h):
        for x in range(w):
            X = (x - cx) * 0.5
            Y = -(y - cy)
            r = math.hypot(X, Y)
            if r > R:
                continue
            th = math.atan2(Y, X) % (2 * math.pi)
            lo, hi = a0 % (2 * math.pi), a1 % (2 * math.pi)
            inside = lo <= th <= hi if lo <= hi else (th >= lo or th <= hi)
            if inside:
                continue                      # the missing slice

            d_out = R - r                     # into the pie from the rim
            # distance to whichever cut face is nearer; the apex is the centre
            d_cut = r
            for a in (a0, a1):
                ux, uy = math.cos(a), math.sin(a)
                if X * ux + Y * uy >= 0:
                    d_cut = min(d_cut, abs(X * uy - Y * ux))
            n = noise(x, y, salt)

            if d_out < crust_depth:
                pool, colour = crust, 1
            elif d_out < crust_depth + rim_depth:
                pool, colour = rim, 2
            elif d_cut < cut_depth:
                pool, colour = cut, 3
            else:
                hit = False
                for (px, py, pr) in spots:
                    rr = math.hypot((x - px) * 0.5, (y - py) * 1.0)
                    if rr <= pr:
                        idx = min(len(pep) - 1, int((rr / pr) * len(pep)))
                        ch[y][x] = pep[idx]
                        col[y][x] = 3
                        hit = True
                        break
                if hit:
                    continue
                pool = cheese
                colour = 2 if n < 0.68 else 4
            ch[y][x] = pool[int(n * len(pool)) % len(pool)]
            col[y][x] = colour
    return render(ch, col, w, h)


CANDIDATES = {}

# --- ROUND: the shipping pizza. A disc with one 1/8 wedge gone -------------
#
# Operator, 2026-08-16, after comparing all three squares on the panel: they
# picked the "gradient" TEXTURE and then asked for "the pizza circular. and the
# slice not be a whole quarter. rather just a normal 1/8th slice". So this is
# gradient's texture unchanged; only the geometry moved. The squares stay as
# alternates.
CANDIDATES["round"] = build_round(
    w=48, h=22, R=10.5, wedge_mid_deg=135, wedge_deg=45,
    crust="%#%##%#%", rim="=+=*+-+=", cheese="...:..-...:.",
    pep="%%##*=-", cut="-=--=-",
    spots=[(33, 5, 2.6), (40, 11, 2.4), (12, 15, 2.4),
           (24, 17, 2.4), (20, 8, 2.4), (30, 13, 2.4)],
    crust_depth=1.1, rim_depth=0.9, cut_depth=0.9, salt=19,
)

# --- A: "slab" -- fat crust, calm cheese, four fat pepperoni ---------------
CANDIDATES["slab"] = build(
    w=44, h=20,
    crust="#%##%###%#",
    rim="*+*=++=*",
    cheese="..::-.:..-.",
    pep="##%%*+",
    cut="=+=-+=",
    spots=[(32, 5, 3.2), (10, 14, 3.2), (27, 15, 2.8), (39, 12, 2.2)],
    crust_depth=1.5, rim_depth=1.1, cut_depth=1.0, salt=7,
)

# --- B: "gradient" -- thin crust, airy CachyOS-style dither, five pepperoni -
CANDIDATES["gradient"] = build(
    w=46, h=21,
    crust="%#%##%#%",
    rim="=+=*+-+=",
    cheese="...:..-...:.",
    pep="%%##*=-",
    cut="-=--=-",
    spots=[(34, 5, 2.8), (42, 9, 2.0), (9, 14, 2.6),
           (23, 16, 2.8), (37, 15, 2.4)],
    crust_depth=1.1, rim_depth=0.9, cut_depth=0.9, salt=19,
)

# --- C: "bold" -- widest, thickest crust, big pepperoni, high contrast -----
CANDIDATES["bold"] = build(
    w=48, h=22,
    crust="##%###%##%#%",
    rim="*+**=+*+",
    cheese=":.-:..:-.:.",
    pep="###%%*+",
    cut="++=+*=",
    spots=[(36, 6, 3.4), (11, 15, 3.4), (29, 17, 3.0), (43, 13, 2.4)],
    crust_depth=2.0, rim_depth=1.3, cut_depth=1.2, salt=3,
)


if __name__ == "__main__":
    # "round" is the ACTIVE logo and ships as pizza.txt, which is the one name
    # deck-session.sh's PIZZA_ART_NAME knows. The others ship beside it as
    # alternates so a Deck can be re-pizza'd with one `cp`.
    FILENAMES = {
        "round": "pizza.txt",
        "slab": "pizza-alt-slab.txt",
        "gradient": "pizza-alt-gradient.txt",
        "bold": "pizza-alt-bold.txt",
    }
    for name, text in CANDIDATES.items():
        path = sys.argv[1].rstrip("/") + "/" + FILENAMES[name]
        with open(path, "w", encoding="ascii") as fh:
            fh.write(text)
        print("wrote", path)

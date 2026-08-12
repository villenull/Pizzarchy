# T8 — reference metrics: Valve's keyboard vs ours, in numbers

> ## 🔴 TWO CORRECTIONS, 2026-08-12 — read before using §2's ratios
>
> Found by the layout agent re-deriving from the pixels instead of trusting the
> table below. Both are now encoded in `src/deck_osk_layout.py` and asserted in
> `test/unit/test-deck-osk-layout.py`.
>
> **1. §2's "× unit" column is fill ÷ fill — it drops the inter-key gap.**
> Laying a row out with `1.75 / 1.40 / 2.09 / 8.53` **overshoots every wide key
> by 2–4px**. The correct *pitch* ratios, re-derived by rescanning each row for
> runs of non-gap `#23262E` and reading fill starts/ends directly, are:
>
> ```
> 0.52  1.03  1.71  1.36  1.69  2.01  1.20  8.08
> ```
>
> Rebuilding the reference from these reproduces every fill width in §2's
> **pixel** table to within **1.32px at 1280** (worst case the 725px space bar,
> 0.18%). ➡️ **Use `Key.units`, which carries the corrected values. Do not
> re-derive from the ratio column.** §2's *pixel* table remains correct and is
> what the tests assert against.
>
> **2. Each row is normalised to the full width on its own.** §2 scanned only
> row 1. All five rows span exactly `x=5..1273`, but a unit key is **85px in
> row 1 and 86–87px in rows 2–4** — the fixed keys are fixed and the unit keys
> absorb the remainder. So `row_units` is **row-specific** (14.02–14.23) where
> `width` is not. ➡️ **A renderer must scale PER ROW**, or it reintroduces a
> ragged right edge.
>
> ⚠️ Neither correction weakens the document — the palette, the pixel tables and
> the geometry are sound. What was wrong was a *derived* column, and it was
> wrong in the direction that looks plausible.


**Session 2026-08-12.** §9g of `docs/tasks/T8-onscreen-keyboard.md` describes
Valve's keyboard in prose. This document replaces the prose with pixel
measurements, so a renderer agent has hex values and geometry instead of
adjectives.

**Method:** Python 3, Pillow 12.3.0 + numpy 2.5.1 (both already present, no
install needed). All screenshots are `grim` captures at the Deck's native
**1280×800**, `RGB` (no alpha channel in the file). Every number below was
read from actual pixel coordinates in these files — the coordinates are
printed so anyone can reopen the same PNGs and re-derive the same numbers.
Source files (NOT vendored into this repo — see
`docs/findings/P16-redistribution-and-trademark.md`):

```
/tmp/claude-1000/-home-huyke-Pizzarchy/5dcd4ff1-5b47-4a97-91cb-4c1fa47d1050/scratchpad/shots/
  01-idle.png            Valve, idle, every badge visible
  state-03-t4s.png       Valve, Shift active
  state-08-t14s.png      Valve, Caps latched
  state-13-t24s.png      Valve, left pad touched, cursor on 'd'
  state-18-t34s.png      Valve, right pad touched, cursor on 'u'
  ours-01-t0s.png        ours, before summon (no keyboard on screen)
  ours-03-t4s.png        ours, cursor on 'r' (cyan) and 'k' (orange)
  ours-13-t24s.png       ours, cursor state
```

⚠️ **Every fill colour reported below was sampled at 2+ points per key,
away from any glyph**, and matched exactly (no gradient) unless a section
says otherwise. Where I only eyeballed something (no pixel measurement
backs it), the line says **ESTIMATED**, per the task's rule not to blur the
two.

---

## 0. Two corrections to §9g before the numbers — the pixels disagree with the prose

1. **🔴 Keys have square corners, not rounded ones.** Scanned every key
   corner in `01-idle.png` (e.g. `q`'s top-left corner, region
   x[90,105]×y[500,514]) at single-pixel resolution: the fill color changes
   in a **hard, one-pixel step** from border-colour to key-fill-colour, in
   both x and y independently, with no intermediate blend. A rounded corner
   would show 2–4px of graduated colour on the diagonal; there is none, at
   the key level *or* the outer keyboard-panel level (checked the panel's
   own top-left corner too, x[0,12]×y[425,437] — same hard edges). Valve's
   keys are **rectangles**. §9d's "Dark rounded keys" is wrong on "rounded."
   **Ours (`ours-03-t4s.png`) really is rounded** — its key-edge pixels show
   a genuine 2–3px antialiased gradient (four intermediate shades:
   `(31,30,35)→(56,56,68)→(70,70,85)→(43,43,53)` fill) — so on this specific
   point, matching Valve exactly means **removing** our rounding, not adding
   any.
2. **🔴 Shift-active glyphs are NOT larger than the dual-legend's small
   glyph — same size, recentred.** §9g says the shifted-only face is
   "larger, centred." Measured on three keys (`!`, `@`, `&`), comparing the
   small unshifted legend's glyph bbox to the same character's bbox when
   Shift is held:
   | Key | Unshifted small legend (idle) | Same glyph, Shift active |
   |---|---|---|
   | `!` (key "1") | 3×14 px, y-center 452 (region x[51,136]) | 3×14 px, y-center 471 |
   | `@` (key "2") | 16×16 px, y-center 454 | 18×17 px, y-center 473 |
   | `&` (key "7") | 13×14 px, y-center 452 | 13×14 px, y-center 470 |

   Width/height match within 1–2px antialiasing noise on every key tested.
   **What changes is the vertical position**, not the size: the glyph moves
   from sitting high in the key (y-center ≈452, key spans y430–502, so
   ~32% down) to sitting at the key's vertical middle (y-center ≈470–473,
   ~61–65% down — close to the 466 geometric centre). Report this to the
   renderer as **"reposition to centre, do not scale up."**

---

## 1. Palette (hex)

All sampled from `01-idle.png` unless noted; cross-checked for flatness
(multiple points per region, no variation found unless stated).

| Element | RGB | Hex | Notes |
|---|---|---|---|
| Letter/digit/punctuation key fill | `(14,20,27)` | `#0E141B` | Flat. Sampled on `q`, `a`, digits, `{`, `:;` — identical everywhere. **Digits share this colour with letters** — they are not a third "action" tone. |
| **Action key fill** (Tab, Backspace, Caps, Shift×2, Enter) | `(0,0,0)` | `#000000` | Pure black, flat. |
| Row5 utility keys — **mixed, not one rule** (§2 below) | see §2 | — | Space and Move are `#0E141B` (grey); smiley, arrows×2, Paste are `#000000` (black). Measured, not inferred — see caveat in §2. |
| Inter-key / inter-row gap ("border") | `(35,38,46)` | `#23262E` | Same value in every gap sampled (44+ samples across all 5 rows) — this is also the colour that shows through where a key is absent, so it is very likely the panel's own background paint, with keys drawn as solid rects on top, not the gap being "no paint." |
| Active-modifier fill (Shift held, either key; Caps latched) | `(26,159,255)` | `#1A9FFF` | Identical value for Shift-left, Shift-right, and Caps-latched (`state-03`, `state-08`). |
| Cursor key face (the "white key") | `(255,255,255)` | `#FFFFFF` | Pure white, flat, sampled at 3 corners of the `d` key in `state-13`. |
| Cursor dot — fill | `(140,207,255)` | `#8CCFFF` | Light blue, **not** the same blue as the modifier highlight. |
| Cursor dot — ring around the fill | `(127,127,127)` | `#7F7F7F` | A ~3px mid-grey ring outlines the dot before the blue starts (see §4) — this is a real separate ring colour, not antialiasing: pure white→pure blue antialiasing would interpolate toward `~(197,231,255)`, and the measured value `(127,127,127)` is nowhere near that curve. |
| Text (all white-legend text: letters, "Backspace", "Enter", etc.) | `(255,255,255)` | `#FFFFFF` | Core pixels; edges antialias down toward the fill colour as expected. |
| Small (unshifted) dual-legend glyph | ~`(180–235,·,·)` light grey-white, not pure white | — | Core pixels topped out around `(235,235,243)`-ish brightness in spot checks — **this line is a rough read, not a clean flat sample**, because the glyph is thin (a few px) and mixes with antialiasing at every sample point. Treat the *size* numbers in §0/§3 as solid; treat this colour line as approximate. |
| Badge fill (`Ⓧ`, `Ⓨ`, `L2`, `R2`, `L3`) | `(255,255,255)` | `#FFFFFF` | Pure white circles/rounded-rects. |
| Badge glyph/text (the "X", "Y", "L2", "R2", "L3" characters) | near-black | — | Rendered on the white badge, dark enough to read as black at a glance; not separately isolated from antialiasing, so no clean hex — **ESTIMATED as `#000000`-ish, not pixel-confirmed to the same rigor as the badge fill.** |
| Active-state top indicator stripe | `(121,160,247)` | `#79A0F7` | 🆕 **Not mentioned in §9g at all.** A solid 3px-tall bar spans the full screen width (`x[0,1279]`, `y=427–429`) directly above the keyboard, **present in every "in-use" state I checked** (`state-03` Shift, `state-08` Caps, `state-13` left-pad-touch, `state-18` right-pad-touch) and **absent in the idle screenshot** (`01-idle.png`, where y427-429 instead shows varied browser content) and **absent in `burst-01-t0s.png`** (t=0 of the burst sequence). Reads as a "keyboard is actively being driven" indicator independent of any single key's highlight. ⚠️ **The gating condition is observed, not proven** — I have it correlated with "Shift/Caps active" and with "a pad is touched," which covers 4/4 non-idle frames checked, but I did not test every state combination, so don't treat "any interaction" as a certainty, just the best-fitting rule from the evidence. |

### Background / translucency

The keyboard is **opaque**, not translucent. The gap colour `#23262E` is
bit-for-bit identical whether the pixels behind it (in the desktop layer)
are warm browser-toolbar tones or saturated game-thumbnail colours — an
alpha-blended panel would shift hue with what's underneath. Checked across
row1 (over a purple browser dropdown) and row4 gaps (over colourful game
art): same `(35,38,46)` in both.

---

## 2. Geometry

All from `01-idle.png`. Screen = 1280×800.

### Keyboard bounding box

- Top edge: **y = 430** (top of the `#23262E` border strip; key fill starts at y=436, i.e. a ~6px top inset)
- Bottom edge: **y = 788** (row5 fill ends 784, border to 788, then desktop content resumes — confirmed by cropping y700–800 and seeing game-thumbnail art directly below)
- **Height = 358px → 358/800 = 0.4475 of screen height** (44.75%)
- Left/right edges: fill starts at x=5, ends at x=1274, i.e. ~5–6px inset each side out of 1280 — negligible, keyboard is effectively full-width.

### Rows

All 5 rows measured (via column scans at x=142, which crosses all 5 rows):

| Row | Fill y-range | Fill height |
|---|---|---|
| 1 (digits) | 436–502 | 66px |
| 2 (qwerty) | 507–573 | 66px |
| 3 (asdf) | 577–643 | 66px |
| 4 (zxcv) | 648–714 | 66px |
| 5 (space) | 718–784 | 66px |

**All 5 rows are exactly 66px tall.** Inter-row gap alternates 4–5px (502→507=5, 573→577=4, 643→648=5, 714→718=4) — almost certainly one true non-integer gap value (~4.5px) that rounds differently frame to frame at this resolution.

- **Row height / screen height = 66/800 = 0.0825**

### Columns (unit key width)

Measured via full-row scans (row1 at y=495, row2 at y=568, row3 at y=638, row4 at y=709). A "unit" key (one digit, one letter, one punctuation key) is consistently **85–87px fill width**, with inter-key gap alternating **4–5px**, same pattern as the row gaps. Example, row1 (`x` = fill-start,fill-end):

```
~`  :  x[5,47]    (42px  — HALF width, see below)
1   :  x[51,136]  (85px)
2   :  x[141,226] (85px)
3   :  x[230,315] (85px)
4   :  x[320,405] (85px)
5   :  x[409,494] (85px)
6   :  x[499,584] (85px)
7   :  x[588,673] (85px)
8   :  x[678,763] (85px)
9   :  x[767,852] (85px)
0   :  x[857,942] (85px)
-   :  x[946,1031](85px)
=   :  x[1036,1121](85px)
Backspace: x[1125,1274] (149px)
```

- **`~\`` is a half-width key** (42px vs 85px standard) — not the same width as the digits.
- **Unit key width / screen width = 85/1280 = 0.0664**
- Gap / screen width ≈ 4.5/1280 ≈ 0.0035

### Multi-unit key spans (fill width in px, and as a multiple of the 85px unit)

| Key | Fill width | × unit (85px) | Fill colour |
|---|---|---|---|
| `~\`` | 42px | 0.49× | grey `#0E141B` |
| Tab | 89px | 1.05× (~1 unit) | **black** |
| Backspace | 149px | 1.75× | black |
| Caps | 119px | 1.40× | black |
| Enter | 149px | 1.75× | black |
| Shift (either) | 178px | 2.09× | black |
| Smiley (row5 leftmost) | 104px | 1.22× | **black** |
| Space | 725px | 8.53× | grey `#0E141B` |
| Each arrow key (`◀/▲`, `▶/▼`) | 104px | 1.22× | black |
| Paste | 104px | 1.22× | black |
| Move | 104px | 1.22× | **grey `#0E141B`** |

⚠️ **The fill-colour column is the real finding here, and it does not
reduce to "action keys are black, everything else is grey."** Space and
Move are visibly the same dark-grey as ordinary letter keys despite being
special-function keys; Paste and the arrows are black despite being (in the
case of Paste) not a "commit/modifier" key in any sense that matches Tab/
Backspace/Shift/Enter's role. I checked this twice (row5 at y=779 near the
bottom edge, and again at y=750 mid-row, in case corner effects were
contaminating the first pass) and got the same colours both times, so it's
real, but **the grouping rule that produces it is not established** — report
the per-key colour, not a rule.

### Corner radius

**Measured as zero.** See §0.1 above — hard single-pixel transitions at
every key corner and at the panel's own outer corner, no rounding
detectable at native resolution.

---

## 3. Legend typography

(See also §0.2 for the "same size, recentred" correction to §9g.)

- **Dual-legend layout (idle/unshifted state):** shifted glyph sits high in
  the key (bbox y-center ≈ 452, key spans y430–502 → ~32% from the top),
  base glyph sits low and large (e.g. digit "1" bbox `x[89,97] y[473,489]`,
  9×17px, y-center 481 → ~69% from the top).
- **Base glyph size:** digit "1" → 9×17px; digit "2" → 12×17px. Roughly
  consistent ~17px cap-height across digits.
- **Small shifted-legend glyph size:** `!` → 3×14px, `@` → 16×16px, `&` →
  13×14px. Height ratio to the base glyph is **~0.82–0.94×** depending on
  the character's natural proportions (thin punctuation reads smaller by
  width, not by the intended point size) — call it **~85% of the base
  glyph's point size, measured**, not a clean single ratio because glyph
  shapes differ.
- **Shift-active state:** same small glyph, recentred to the key's
  vertical middle (y-center 470–473 vs the key's true centre 466 — within
  a few px, likely baseline vs optical centring). **Not enlarged** — see §0.2.
- **Caps-latched state:** dual legend is **unchanged** from idle — both
  small shifted glyph and large base glyph stay exactly where they are;
  only the letters switch to uppercase and the Caps key turns blue. This
  matches §9g's prose (this part of §9g was correct).

---

## 4. The cursor

Measured on `state-13-t24s.png` (cursor on `d`, left pad) and cross-checked
on `state-18-t34s.png` (cursor on `u`, right pad) to rule out the "grey ring"
being an artifact of the specific letter underneath.

- **Key face:** goes fully white (`#FFFFFF`, §1), replacing whatever the
  key's normal fill was — confirmed on a letter key (`d`, normally
  `#0E141B`).
- **The dot:**
  - Fill: `#8CCFFF` (`140,207,255`), diameter **≈24–25px** (bbox 24×25 on
    `d`, 25×23 on `u` — small key-to-key jitter, likely sub-pixel
    positioning + antialiasing, not a real size difference).
  - A **~3px mid-grey ring** (`#7F7F7F`) surrounds the fill before the
    white key face resumes — confirmed on `u`, where the dot sits away
    from the letter glyph (profile at y=561: white → grey `127,127,127`
    ×3px → blend → blue fill ×25px → blend → grey ×2px → key-fill-dark).
    Total outer diameter including the ring ≈ **29–31px**.
  - Ring colour is **not** a white/blue antialiasing artifact — see the
    math note in §1.
- **Position relative to the key:** the dot is **not centred** — it sits
  wherever the raw pad reading places the thumb within the key's hit-test
  box, continuously. On `d` (state-13) the dot sits toward the
  **upper-right** of the key face; on `u` (state-18) it sits toward the
  **lower-right**. This is expected for an absolute-position cursor and
  is the one part of §9g's cursor description that reads correctly:
  "the thumb's precise position on that key."

---

## 5. Badge geometry

All bboxes are **white-pixel bounding boxes** (thresh=200), sampled from
`01-idle.png` (idle = every badge visible) in a crop tight enough to
exclude adjacent text — the crop bounds are given so this is reproducible.

| Badge | Key | Crop used | bbox (x, y) | Size |
|---|---|---|---|---|
| `Ⓧ` (circle) | Backspace | `(1130,455)-(1163,495)` | x[1136,1161] y[468,493] | **26×26px**, circular |
| `Ⓨ` (circle) | Space, left edge | `(115,740)-(175,778)` | x[124,149] y[746,771] | **26×26px**, circular |
| `L2` (rounded rect) | Shift (both) | `(100,670)-(183,715)` | x[144,173] y[679,704] | **30×26px** |
| `R2` (rounded rect) | Enter | `(1125,595)-(1175,635)` | x[1134,1163] y[609,634] | **30×26px** |
| `L3` (rounded shape + triangle icon) | Caps | `(60,595)-(124,635)` | x[85,114] y[608,632] | **30×25px** (icon+text combined bbox — the small triangle above "L3" is fused into this box, not separated out) |

**Two distinct badge shapes, confirmed visually at 4× zoom** (see crops in
scratchpad, not reproduced here per the no-vendoring rule):
- Face buttons (`Ⓧ`, `Ⓨ`) → **circle**, 26×26px.
- Triggers/stick (`L2`, `R2`, `L3`) → **rounded rectangle**, ~30×26px,
  and the `L2`/`R2` badges have a visibly asymmetric corner treatment (one
  corner reads as more sharply cut than the others in the zoomed crop —
  **ESTIMATED as an intentional "shoulder-button" notch shape from the
  screenshot, not confirmed by a corner-by-corner pixel trace** — a
  renderer can reasonably just use a plain rounded rect and not lose much).
  `L3` additionally carries a small upward-pointing triangle glyph above
  the rounded-rect body (a stick-click indicator) — also not separately
  measured.

**Position within the key** (badge centre, offset from the key's own top-left fill corner):

| Badge | Key fill origin | Badge centre | Offset from key left | Offset from key top |
|---|---|---|---|---|
| `Ⓧ` | (1125,436) | (1148.5, 480.5) | 23.5px | 44.5px (of 66px row height → 67%) |
| `Ⓨ` | (113,718) | (136.5, 758.5) | 23.5px | 40.5px (of 66px → 61%) |

Both badges sit **~23.5px from the key's left edge**, essentially
identical, and both sit in the **lower half** of the 66px row rather than
dead-centre (67% and 61% down respectively) — consistent with the badge
baseline-aligning with adjacent label text rather than being geometrically
centred in the key box.

---

## 6. Direct diff — ours vs Valve's

Measured on `ours-03-t4s.png` (our keyboard, cursor on `r` and `k`).
⚠️ **`ours-01-t0s.png` has no keyboard on screen at all** (t=0, pre-summon —
it's a plain Chromium New Tab page) — don't use it as an "ours idle" sample,
it isn't one.

| Metric | Valve (measured) | Ours (measured) | Gap |
|---|---|---|---|
| Keyboard height / screen height | 0.4475 (358/800) | ≈0.411 (329/800, top y≈468, bottom y≈797) | Ours is slightly shorter |
| Row height | 66px flat, all 5 rows | ≈57px flat, all 5 rows (470–527, 537–594, …) | Ours rows ~14% shorter |
| Unit key width | 85px | ≈58–62px (varies 58–63px across columns, not as uniform as Valve's) | Ours narrower and less consistent |
| Inter-key gap | 4–5px | ≈6–8px normally | Ours gaps are wider even where no intentional split exists |
| **Gap between "halves"** | **0** — one continuous grid, confirmed: scanning row1 across the full width in `01-idle.png` shows the *only* wide gap is the half-unit `~\`` key, every other transition is the standard 4–5px | **≈62px** between key "5" (fill ends x=735) and key "6" (fill starts x=797) in `ours-03-t4s.png` — a full extra key-width of dead space | This is the gap the operator called out; now quantified: **≈62px at 1280-wide, ≈10× the normal inter-key gap** |
| Corner radius | 0 (hard edges, measured) | Visibly rounded — 2-3px antialiased gradient through 4 intermediate shades at every key edge | Ours needs rounding **removed**, not added, to match |
| Key fill (letters) | `#0E141B` | `#2B2B35` | Different — ours is a lighter, more saturated dark grey |
| Border/gap fill | `#23262E` | `#1F1E23` | Close but not identical |
| Active-modifier / cursor colour | Both cursors and Shift/Caps share **one** blue family (`#1A9FFF` modifier, `#8CCFFF` dot) and cursor is **white key + blue dot**, not a coloured key | **Ours uses two different solid colours per cursor** — left cursor `#61C7EB` (cyan-ish), right cursor `#FAB84C` (orange) — the *whole key face* is tinted that colour, no white face, no small dot, no shared colour between the two cursors | Structurally different cursor model: Valve = 1 face treatment (white) + a positioned dot; ours = 2 distinct colour-coded full-key highlights. To match Valve, ours needs to drop the dual-colour scheme and adopt white-face-plus-dot for **both** cursors. |
| Dual legend on digit row | Present, matches §3 | Present in `ours-03` (visible `!`, `@`, `#`, `$`… above digits) | Structurally matches; exact size/position not diffed pixel-for-pixel here — lower priority than the colour and gap gaps above |
| Action-key fill vs letter-key fill distinction | Yes — black vs `#0E141B`, see §2 | Not checked in this pass — ours' "back"/"enter"/"tab"/"shift" keys appeared black in the screenshot but weren't colour-sampled | **Open** — worth a follow-up sample if this doc is extended |

---

## Summary for a renderer agent

**Palette:**
```
key fill (letters/digits/punct) : #0E141B
key fill (action: Tab/Back/Caps/Shift/Enter) : #000000
gap / panel background          : #23262E
active modifier (Shift/Caps)    : #1A9FFF
cursor key face                 : #FFFFFF (full white, replaces fill)
cursor dot fill                 : #8CCFFF, ~24-25px diameter
cursor dot ring                 : #7F7F7F, ~3px thick, ~29-31px outer diameter
text                            : #FFFFFF
badge fill                      : #FFFFFF, badge glyph ~black (not rigorously sampled)
active-in-use top stripe        : #79A0F7, 3px tall, full width, above the keyboard
```

**Geometry (fractions of a 1280×800 screen, so they scale):**
```
keyboard height   : 0.4475 of screen height
row height        : 66px flat  (0.0825 of screen height)
unit key width    : 85px       (0.0664 of screen width)
inter-key gap      : ~4-5px
corner radius      : 0 (square corners, measured, not estimated)
half-width key (~`) : 42px (0.49x unit)
Tab                : 89px  (~1.0x unit)
Backspace / Enter  : 149px (1.75x unit)
Caps               : 119px (1.40x unit)
Shift (each)       : 178px (2.09x unit)
Space              : 725px (8.53x unit)
smiley/arrow/Paste/Move : 104px (1.22x unit) each
NO gap between left/right halves — one continuous grid
```

**Cursor model:** one white key face + one positioned dot (not a
coloured-key highlight), same treatment for both cursors, dot placed at
the raw thumb position within the key (not snapped to key centre).

**Biggest gaps vs ours, in priority order:** (1) the ~62px half-split gap
that shouldn't exist at all, (2) the two-colour tinted-key cursor model vs
Valve's white-face-plus-dot, (3) rounded corners that should be square,
(4) row/key sizing is ~10-15% smaller than Valve's proportionally.

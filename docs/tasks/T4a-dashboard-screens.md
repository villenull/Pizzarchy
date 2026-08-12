# T4a — S6/S7 (and S8) need a third patch, not an overlay file

**Status:** specified 2026-08-12, **not started**. Resolves the "⚠️ decide in
T4a" row in `docs/tasks/T4-screen-spec.md` §7.
**Depends on:** none to *write* this spec; T5's overlay/patch machinery
(`iso/overlay/patches/`, `bin/build`'s `git apply` step) to *land* it.
**Owner of `iso/`:** not this task. This file specifies the patch; applying it
is `iso/`'s owner's call, same division T4-screen-spec.md §7 already draws
between "the two hunks" (P1/P2) and the files that carry them.

---

## 0. The verdict, first

**S6 and S7 cannot be built as a `deck-form.sh`-style additive overlay file.**
`omarchy-install-dashboard` has **zero `source` statements** — not one, checked
by grep against the pinned tree, `grep -n '^source\|^\. \|source /'` returns
nothing. There is no seam. Building `render_finish`/`tips`/`failure_menu`
overrides in a new file and not patching anything to load it would be exactly
the failure mode `docs/tasks/T4-screen-spec.md` §6.4 exists to catch: a
function defined under a name nothing in the process that owns it ever
resolves against, silently never appearing on the real ISO.

**The fix is a third patch** — one hunk, one `source` line — mirroring
`docs/tasks/T4-screen-spec.md` §1.2 patch P1 hunk 1 exactly, placed at the
one point in `omarchy-install-dashboard` where it is valid: after every
function the file defines, before the file's own flow runs.

This session did not write that patch (`iso/` is off-limits to it — other
agents own it) or the file it would source. What follows is the spec for both,
precise enough to apply without re-deriving anything.

---

## 1. What was verified this session, against the pinned tree

`iso/upstream` pinned at `a12bfea7a86c5615ddced04cef0360a35294f4db` — unchanged
from the SHA `docs/tasks/T4-screen-spec.md` cites; no drift to account for.

1. **`omarchy-install-dashboard` is a separate process, not a function
   `configurator` calls into.** `.automated_script.sh` runs them
   sequentially as two different executables:
   ```
   ./configurator                                   # exits, process gone
   ...
   /usr/local/bin/omarchy-install-dashboard \
     "$OMARCHY_INSTALL_LOG_FILE" /run/omarchy-install/state.json -- \
     /usr/local/bin/omarchy-iso-install --config ... --creds ...
   ```
   (`iso/upstream/configs/airootfs/root/.automated_script.sh`, the block
   starting `if /usr/local/bin/omarchy-cidata-load; then ... else
   ./configurator; fi`, through the closing `--defer-provisioning-file`.)
   `deck-form.sh`'s P1 source line lands inside `configurator`'s own process
   image. It has no reach into a process `configurator` has already exited
   before this one even starts.
2. **`omarchy-install-dashboard` sources nothing.** Confirmed by grep, not by
   reading and hoping: `grep -n '^source\|^\. \|source /'
   configs/airootfs/usr/local/bin/omarchy-install-dashboard` returns zero
   lines. Contrast `configurator`, which has exactly one
   (`source "$SETUP_FORM"`, line 25) — the seam P1 already uses.
3. **The three functions/data S6/S7 need to change all live inside this one
   file, defined in this order:** `tips=(...)` (lines 56–75, a plain array
   assignment, not a function), `render_finish` (lines 451–480),
   `failure_menu` (lines 609–661). The file's own main flow — the part that
   actually calls them — begins at line 689 (`[[ -e $TTY_PATH ]] || exit 2`)
   and runs straight through to EOF (line 771). Everything from line 1 to
   688 is either a top-level constant/computation or a function definition;
   nothing in that span is *called*.

That last fact is what makes a single-line patch sufficient: bash keeps the
**last** definition of a name, exactly as P1 already relies on for
`configurator`. A `source` line placed anywhere after line 687
(`launch_child`'s closing `}`, the last function definition in the file) and
before line 689 lands after upstream's own `tips`/`render_finish`/
`failure_menu` are defined and before any of them is read or called —
the identical placement rule P1 hunk 1 uses ("after every function ... is
defined and before the flow runs"), just anchored to a different file's
different set of function boundaries.

⚠️ **Order matters and was checked, not assumed.** Sourcing *before* line 451
(where upstream defines its own `render_finish`) would have our override
executed first, and upstream's own definition — which runs unconditionally as
the script continues past it — would silently clobber ours back to stock.
The seam has exactly one valid placement: after the last function
definition, before the main flow. This session located it by reading the
file end-to-end, not by pattern-matching "near the top" the way `deck-form.sh`
places its own source line.

---

## 2. The patch itself

`iso/overlay/patches/omarchy-install-dashboard.patch` (name for whoever's
overlay-patch numbering scheme owns it — T5's `overlay/patches/` convention),
one hunk:

```diff
--- a/configs/airootfs/usr/local/bin/omarchy-install-dashboard
+++ b/configs/airootfs/usr/local/bin/omarchy-install-dashboard
@@ -685,6 +685,11 @@ launch_child() {
   child_pid=$!
   child_pgid=$child_pid
 }
 
+# Deck overlay: redefines `tips`, `render_finish` and `failure_menu` for a
+# device with no keyboard. Placed here deliberately -- after every function
+# this file defines, before any of them is called (see
+# docs/tasks/T4a-dashboard-screens.md §1 for why nowhere else works).
+source /usr/share/omarchy-iso/deck-dashboard.sh
+
 [[ -e $TTY_PATH ]] || exit 2
 printf '%s' "$HIDE_CURSOR" >"$TTY_PATH"
```

**Patch budget:** `docs/tasks/T5-fork-plan.md` §1 sets **≤ 4 patch files** for
the whole ISO overlay, "a fifth should have to argue for itself." T4 already
spends two (`configurator.patch` P1, the shared `build-iso.patch` P2). This
is a **third**, and it argues for itself the same way P1 does: the source
line must land inside upstream's own process image, so it cannot be an
additive file. One hunk, same shape as P1 hunk 1, not a new pattern.

**Why not a full-file replacement instead** (`docs/tasks/T4-screen-spec.md`
§7's other named option)? Rejected for the same reason §1.3 rejects
"Replace" for `configurator`: `omarchy-install-dashboard`'s progress-bar math
(`install_progress`, lines 275–383) is ~110 lines of tuned constants (band
edges, `tau` shape constants, the per-mille clamp logic) that would have to be
copied and kept in lockstep with upstream by hand. A one-line patch that
overrides three named things costs one hunk and zero re-derivation; a full
replacement costs both a bigger patch (it would *be* the file, diffed against
nothing) and a standing obligation to notice every future tuning change
upstream makes to the 85% of this file T4 has no opinion about.

**Source-safety applies here too, and for the same reason `deck-form.sh`
gives.** `omarchy-install-dashboard` line 8 is `set -euo pipefail`, already
in effect when the sourced overlay's top-level statements run. The overlay
file must not itself `set -e`/`exit`/`set -u`-violate at its top level for
the identical reason `deck-form.sh`'s own header spells out at length: a
sourced file's top-level statements run in the *sourcing* process, before any
screen exists to show a symptom on. `-u`/`pipefail` only, loud-failure
discipline per function, matching `deck-form.sh`'s own convention exactly.

---

## 3. What the sourced overlay (`deck-dashboard.sh`) should contain

Not committed by this session — nothing would load it without §2's patch, and
a file of functions nothing calls is the exact defect this task exists to
avoid reintroducing. Specified here precisely enough to build without
re-deriving the design.

### S6 — `tips` override

Replace upstream's 18-entry array (`docs/tasks/T4-screen-spec.md` §4 S6:
"every one names a keyboard shortcut") with Deck-relevant content. Draft set,
each checked by eye against `CONTENT_WIDTH` (≈ 81 cols, `LOGO_WIDTH`-derived,
`omarchy-install-dashboard` lines 124–144) and containing no `Super`:

```bash
tips=(
  "Steam and Gaming Mode are always one button press away"
  "The STEAM + X chord opens the on-screen keyboard in Desktop Mode"
  "The STEAM button opens the Omarchy menu for apps, settings, and more"
  "Use the QAM (... button) for quick settings and volume"
  "Both trackpads act as a mouse in Desktop Mode -- R2 clicks, L2 right-clicks"
  "A controller works everywhere in Desktop Mode, not just in games"
  "Keep the system fresh with Update in the Omarchy menu"
  "Switch themes from Style > Theme in the Omarchy menu"
  "Press the STEAM button, then Power, to switch between Gaming and Desktop Mode"
)
```
[U]-testable exactly as `docs/tasks/T4-screen-spec.md` §4 S6 specifies once
this array is real: no entry contains `Super`, and no entry exceeds
`CONTENT_WIDTH`. **⚠️ Open item, not resolved here:** whether STEAM/QAM chords
survive into Desktop Mode at all is a `src/deck-input-mapper.py`/
`deck-session.sh` question this task does not own; the tips text above must
be checked against whatever that layer actually ships before it becomes real,
not copied on faith.

### S7 — `render_finish` override

`docs/tasks/T4-screen-spec.md` §4 S7: "Add one line: `Your Deck will start in
Gaming Mode.`" Upstream's own `render_finish` (lines 451–480) is otherwise
"good" per the spec — reuse its structure, insert one `center` call:

```bash
render_finish() {
  local duration effect_canvas_width
  duration="$(install_duration || true)"
  duration="${duration:-Complete}"
  effect_canvas_width="$(term_cols)"
  (( effect_canvas_width > 1 )) && effect_canvas_width=$((effect_canvas_width - 1))

  {
    printf '%s%s' "$SHOW_CURSOR" "$CLEAR"
    blank_line
    render_logo
    blank_line
    center "Installed Omarchy in ${duration}" "$CONTENT_WIDTH"
    center "Your Deck will start in Gaming Mode." "$CONTENT_WIDTH"
    blank_line
  } >"$TTY_PATH"

  # ... the tte laser-etch block, unchanged from upstream lines 467-479 ...
}
```
`reboot_prompt` (lines 482–501) needs **no override** — a single-button `gum
confirm` already takes Enter (A in lizard mode), matching §4 S7's own "Works
as-is."  `[V]`-only per the spec's own verified-by rows (duration/render
timing is not meaningfully unit-testable); the "no `Super`"-style [U] check
does not apply here since this screen has one added literal line, not an
array.

### 3.1 A note on `functions this file must still call upstream's own version
of`

`center`, `blank_line`, `render_logo`, `install_duration`, `term_cols`,
`CLEAR`/`SHOW_CURSOR`/`CONTENT_WIDTH` etc. are **not** redefined — the
override reuses upstream's own helpers exactly the way `deck-form.sh`'s
`confirm_disk_overwrite` reuses `clear_logo`/`say`/`gum` rather than
reimplementing them. This is the same "override only the screen, not
machinery upstream already got right" rule `deck-form.sh`'s own header states
for S4.

---

## 4. The finding that widens this task: S8 has the identical defect, today

**`src/deck-form.sh` already defines a `failure_menu`, and it is dead code on
the real ISO, right now.** Verified this session:

- `omarchy-install-dashboard` defines its own `failure_menu` (lines 609–661)
  — the one `docs/tasks/T4-screen-spec.md` §4 S8 is actually about (its own
  citations are `view_failure_log` line 575 and `failure_menu`'s `gum choose`
  fallback, both read from *this* file).
- `configurator` — the process `deck-form.sh` is actually sourced into —
  **defines no function named `failure_menu` at all.** `grep -n
  'failure_menu' configs/airootfs/root/configurator` returns nothing.
- `grep -rn failure_menu src/ test/` finds exactly one definition in the
  whole repo: `src/deck-form.sh:777`, sourced into the process that never
  calls it.

So `deck-form.sh`'s own header claim — "5. S8 Failure -- the menu contents
and the cancel-fallback decision layer ..., plus a real `failure_menu` loop
and log pager wired to them" — describes code that **cannot run on the real
ISO today**: it defines a function named `failure_menu` inside
`configurator`'s process, and nothing in `configurator`'s own flow, nor
anything downstream, ever invokes a function by that name. It is exactly the
silent-no-op class `docs/tasks/T4-screen-spec.md` §6.4 and this project's own
`CLAUDE.md` "already diagnosed" list exist to catch, and neither
`test-deck-form.sh`'s own contract check (which only greps `configurator` for
`$password`/`$hostname`/`$full_name`/`$email_address`, not for callers of
`failure_menu`) nor anything else in the suite currently catches it.

**This task's `deck-dashboard.sh` (§3 above) is where S8's logic belongs,
once §2's patch lands** — `failure_menu`'s real name collision is with
*this* file's function, not `configurator`'s. `deck-form.sh`'s
`deck_form_failure_menu_items`/`deck_form_failure_action_for`/
`deck_form_show_log`/`failure_menu` are the right *logic* (already
[U]-tested and, per this task's own file-ownership boundary, not this
session's to move) — they are just sourced into the wrong process. Moving
them is a `src/deck-form.sh` edit and therefore explicitly out of this
session's file ownership ("do NOT edit `src/deck-form.sh`"); flagged here,
and separately, for whoever does own that file next.

**Do not read this as "S8 was wasted work."** The decision layer
(`deck_form_failure_action_for`, the menu array, the log-pager fallback) is
real, tested, and portable — moving it to `deck-dashboard.sh` once §2 lands
is a relocation, not a rewrite. What is wrong is only *where it is sourced*,
which is the same class of mistake — and the same fix shape — as the
`user_password`/`hostname_value` naming bug `deck-form.sh`'s own header
already documents finding and fixing for S3.

---

## 5. Done when

- [ ] The patch in §2 is written, lands in `iso/overlay/patches/`, and
      `bin/build`'s `git apply --3way` step (or the guard T5-fork-plan.md §6.6
      proposes) applies it cleanly against the pinned `iso/upstream` tree.
- [ ] `deck-dashboard.sh` exists (S6 tips, S7 line, and — per §4 — S8's
      relocated logic), installed to `/usr/share/omarchy-iso/deck-dashboard.sh`
      by whichever build step installs `deck-form.sh` to the sibling path
      (T5's install step, per `deck-form.sh`'s own header).
- [ ] A G1-style build guard (`docs/tasks/T4-screen-spec.md` §7's own G1,
      widened): after the overlay is applied, assert
      `omarchy-install-dashboard` contains the `source
      .../deck-dashboard.sh` line, **and** that every function name
      `deck-dashboard.sh` defines (`tips` is data, not a name to check the
      same way, but `render_finish`/`failure_menu` are) actually exists as a
      function name in the **patched** `omarchy-install-dashboard` before
      the source line — i.e. the same "grep the names out of the overlay,
      assert each exists in the file it patches" check T4-screen-spec.md §7
      already specifies for `deck-form.sh`/`configurator`, run a second time
      against this pair. This is the exact guard that would have caught §4's
      `failure_menu` defect on day one if it had existed for `deck-form.sh`
      too — worth widening there, not just adding here.
- [ ] `[U]` the tips array: no entry contains `Super`; no entry exceeds
      `CONTENT_WIDTH` (`docs/tasks/T4-screen-spec.md` §4 S6's own row).
- [ ] `[V]` `test/vm/vm-installer-screens-test.sh` (once it exists, per
      T4-screen-spec.md §6.3) drives a run to completion and asserts, on
      `/dev/vcs1`: the tips carousel never shows a keyboard-shortcut string
      across a full 8s-per-tip cycle; `render_finish`'s frame carries "Your
      Deck will start in Gaming Mode."; `OMARCHY_UI_AUTO_REBOOT=no` stops on
      that screen (T4-screen-spec.md §4 S7's own row).
  - `[V]` S8 (once relocated, §4 above): `/dev/vcs1` never shows a bare
      shell prompt across a forced-failure run driven to `Power off`, with
      the pad only — `docs/tasks/T4-screen-spec.md` §4 S8's own ⭐ row,
      unblocked by this relocation.
- [ ] `src/deck-form.sh`'s own dead `failure_menu` (and its
      `deck_form_failure_menu_items`/`deck_form_failure_action_for`/
      `deck_form_show_log` collaborators) is either moved into
      `deck-dashboard.sh` or explicitly retired from `deck-form.sh` with a
      note explaining why, so nobody reads its header's "S8 ... built" claim
      as true of the shipped ISO again.

---

## 6. What this session read, and did not do

**Read, this session, against the pinned tree
(`a12bfea7a86c5615ddced04cef0360a35294f4db`):**
`configs/airootfs/root/.automated_script.sh` (the `configurator`/dashboard
handoff), `configs/airootfs/usr/local/bin/omarchy-install-dashboard` in full
(771 lines), `configs/airootfs/root/configurator` (grepped for
`failure_menu`, `^source`), `builder/build-iso.sh` (the `setup-form.sh`
vendoring block, to confirm `omarchy-install-dashboard` is a *native*
`omarchy-iso` file — not vendored from `basecamp/omarchy` the way
`setup-form.sh` is, so this patch's maintenance class matches P1's, not a
vendored-file's). Also `src/deck-form.sh` and `test/unit/test-deck-form.sh`
in full, to establish conventions and locate the S8 defect in §4.

**Not done, and why:** no `iso/` file written (out of this session's file
ownership; other agents own it) — including no patch actually applied and no
`deck-dashboard.sh` actually committed, per this task's own explicit
instruction that a file of functions nothing calls is the defect to avoid,
not a deliverable to produce anyway. No `src/deck-form.sh` edit (explicitly
forbidden this session; the S8 relocation in §4 is flagged, not performed).
No VM run, no ISO build, no Deck touched.

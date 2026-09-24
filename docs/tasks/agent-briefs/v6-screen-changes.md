# Task: v6 installer screen changes (code + tests only, NO build)

Repo /home/villenull/Projects/Pizzarchy, branch `hw-feedback-1`. Read `CLAUDE.md`
and `docs/findings/HW-INSTALL-FEEDBACK-2026-09-24.md` — implement items **9, 10,
11, 14, 15, 16a, 17** exactly as written there (16a is the authoritative B map;
item 6's read-only walk and item 16 are superseded by it).

⚠️ Another agent is building an ISO and running QEMU from this repo right now.
Do NOT run `iso/bin/build`, docker, or anything under `test/vm/`. Do not edit
`iso/bin/build` or `docs/findings/FAST-INSTALL-RESULTS.md`. Never run git
stash/reset/checkout/clean or `git add -A`/`.`; stage your files by path; do not
switch branches. No Deck/USB/publishing/push.

Files: `iso/overlay/configs/airootfs/usr/share/omarchy-iso/deck-form.sh`, suite
`test/unit/test-deck-form.sh`, spec `docs/tasks/T4-screen-spec.md`. Controller:
A = Enter, B = Esc.

Items, in brief (the feedback file has the operator's wording):
- 9: Steam download screen, before the download has a size: show a clear
  "Waiting for the base install to finish" style line instead of a `[????…]` bar.
- 10: the Steam download screen clears+redraws the whole screen every refresh,
  which flashes on the Deck's console. Draw the chrome once and update only the
  changing lines in place (cursor save/restore or move-up + clear-line), and
  make sure a B press there causes no redraw either.
- 11: the speed shows `0.00 MB/s` for the whole download while the MB count
  climbs. Find the real cause in `deck_form_steam_rate` / its caller (units,
  integer division, timestamps equal, parse) with a failing-first test built
  from real progress lines (e.g. 203.9 MB of 484.7 MB, then a later sample), and
  fix it. Smooth the rate over several samples and show time left.
- 14: the two welcome lines must start at the logo's left edge like other
  screens (likely: `deck_form_s0_text` uses bare printf instead of `say`). The
  unit tests assert on that function's output — keep them meaningful.
- 15: wipe confirm prompt exactly `Press A to wipe and install NOW, B to go back`.
- 16a: implement the B map. Remove the read-only walk (`deck_form_readonly_*`,
  `deck_form_choice_answer` if unused) and its wiring in `keyboard_form`; B on
  keyboard layout = no-op with NO visible redraw (if upstream's picker exits on
  Esc, re-invoke it without clear_logo/redraw, or otherwise make Esc inert —
  investigate how `omarchy_prompt_keyboard`/gum behaves). B on Install Steam? =
  back to Install pre-installs? (operator correction — NOT a no-op). B on the Wi-Fi network list = back to Install Steam? (same effect as
  its existing Back row). B on the Steam download screen = no-op.
- 17: the round trip Steam=Yes → Wi-Fi → B → Install Steam? → No must continue
  as a normal Steam=No install (keyboard layout next; `gaming` rewritten to no;
  the background install must not wait for network or fetch Steam — check how
  the existing gaming-back path talks to the early stage, e.g. the choices dir
  and network-ready marker, and prove it). Choosing Yes again returns to Wi-Fi.
  Pre-installs must never be reopenable once locked — add a test.
- 18 (NEW, required for 16a/17 to be safe): move the moment the choices are
  written + `locked` (`deck_form_run_choice_screens` → `deck_form_choices_lock`)
  to when the user LEAVES the pre-installs / Install Steam? / Wi-Fi group:
  Steam=No answered, or Wi-Fi connected with Steam=Yes. Until then nothing is
  written, so B freely moves pre-installs ⇄ Install Steam? ⇄ Wi-Fi. Check every
  consumer of the choices/lock (the early stage / orchestrator `deck_choices.py`
  waits on `locked`; the Wi-Fi network-ready marker; the Steam download screen;
  `deck_form_steam_may_drop_gaming`) still works with the later lock, and that
  the cidata/QEMU path (which writes the files itself in `.automated_script.sh`)
  is unaffected. Tests: the full round trip Yes → Wi-Fi → B → Steam → B →
  pre-installs → change answer → Steam No → keyboard, with the final locked
  files matching the last answers; and once locked, nothing reopens pre-installs.
- While there: confirm what B on the account screens (username/password/name/
  email/timezone) actually does today — the operator was told "back to the
  start of the account screens". If it instead ends the install, report it (do
  not change it without saying so in the report).

Failing-first unit tests for every behaviour change. Then:
```
shellcheck iso/overlay/configs/airootfs/usr/share/omarchy-iso/deck-form.sh
export PATH=/var/tmp/pizzarchy-vm-tools/usr/bin:$PATH
for f in test/unit/test-*.sh; do bash "$f" >/dev/null 2>&1 || echo "FAIL $f"; done
for f in test/unit/*.py; do python3 "$f" >/dev/null 2>&1 || echo "FAIL $f"; done
```
All green; commit your files by path with a message ending in
`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

Finish: report (per item: what changed, root cause for 11, failing-first proof;
the account-screen B finding; test tails; commit hash; anything unsure) to
/tmp/claude-1000/-home-villenull-Projects-Pizzarchy/73222426-a56c-4989-b96c-c00fcf5a26f0/scratchpad/report-muse-v6code.md
then ONLY THEN create
/tmp/claude-1000/-home-villenull-Projects-Pizzarchy/73222426-a56c-4989-b96c-c00fcf5a26f0/scratchpad/DONE-muse-v6code

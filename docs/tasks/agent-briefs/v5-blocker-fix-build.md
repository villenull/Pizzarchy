# Task: fix the interactive-install blocker (+2 screen items), then build v5 and QEMU it

Repo /home/villenull/Projects/Pizzarchy, branch `hw-feedback-1` (HEAD 1b3b495).
Read `CLAUDE.md`, the top HANDOFF block of `docs/START-HERE.md` (including bullet 6:
launch long jobs with `setsid nohup <cmd> > log 2>&1 < /dev/null &`, never plain
nohup), and `docs/findings/HW-INSTALL-FEEDBACK-2026-09-24.md` (items 7 and 8 at
the bottom). No Deck, no USB writes, no publishing/push. Never run git
stash/reset/checkout/clean or `git add -A`/`.`; stage your files by path.

## 1. BLOCKER (fix first, failing-first test)

On the Deck, v4, interactive install, pre-installs=No, Steam=No: pressing Install
on the summary immediately fails with
`ERROR: cidata drive carries no 'preinstalls' file (want yes/no); refusing an unanswered variant`
(and the same for 'gaming').

Cause (orchestrator's reading, confirm it): `iso/overlay/patches/deck-install-invocation.patch`
adds a block to `configs/airootfs/root/.automated_script.sh`, AFTER the
`if omarchy-cidata-load … else ./configurator fi` branch, guarded only by
`[[ -f /root/user_configuration.json ]]`. The interactive configurator's own
`write_user_files` ALSO writes `/root/user_configuration.json`, so on a real
interactive install the cidata-only block runs, finds no `/root/preinstalls`,
and exits 1. QEMU always takes the cidata branch, which is why no VM run ever hit
it.

Fix: gate the block on the cidata branch actually having been taken (e.g. a
variable set inside the `if omarchy-cidata-load` branch), not on the file's
presence. On the interactive path the form has already started the early stage
and written/locked `/run/omarchy-deck/choices/` itself — the block must do
nothing there. Keep the patch applying cleanly on the pinned `iso/upstream`
(the build applies it; check how `test/unit/test-iso-build.sh` / other suites
verify patches apply). Add a unit test that runs the patched block's logic for
BOTH paths: cidata (unchanged behaviour, including its loud errors) and
interactive (configurator wrote user_configuration.json, no /root/preinstalls)
→ must not error and must not call `omarchy-deck-early start` again. The test
must fail on the current patch. Then grep the patched `.automated_script.sh` and
the other patches for any OTHER logic that assumes "user_configuration.json
exists ⇒ cidata" and fix/report it.

## 2. Screen items 7 and 8 (deck-form.sh + test/unit/test-deck-form.sh)

7. With Install Steam? = No, never show the "No network was found" note (find it:
   grep the form for that text / `deck_form_offline_note` / S5 summary). Keep it
   exactly as is for Steam = Yes.
8. The pre-reboot notice `DECK_S5_REBOOT_LINES`: with Steam = No show ONLY
   "When the install finishes the Deck reboots on its own." With Steam = Yes keep
   the full block unchanged.
Failing-first tests for both, both branches.

## 3. Verify, commit
```
shellcheck iso/overlay/configs/airootfs/usr/share/omarchy-iso/deck-form.sh iso/bin/build
export PATH=/var/tmp/pizzarchy-vm-tools/usr/bin:$PATH
for f in test/unit/test-*.sh; do bash "$f" >/dev/null 2>&1 || echo "FAIL $f"; done
for f in test/unit/*.py; do python3 "$f" >/dev/null 2>&1 || echo "FAIL $f"; done
```
All green, then commit (your files by path) with a message ending in
`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## 4. Build v5 and QEMU
Exactly like the "## v4" section of `docs/findings/FAST-INSTALL-RESULTS.md`, but
launched with `setsid nohup … < /dev/null &`: log `~/.cache/omarchy-deck/build-v5.log`,
ISO `pizzarchy-omarchy-4.0.4-fast-install-2026-09-24-v5-x86_64.iso` in
`~/.cache/omarchy-deck/release-2026.09.24-v5/` with `SHA256SUMS`. A build counts
only with all guards green and no FATAL/ERROR. Then in PARALLEL (separate
workdirs, `VM_FAST_REBOOT_CHECK=1`, `PATH=/var/tmp/pizzarchy-vm-tools/usr/bin:$PATH`):
No/No NVMe (`VM_NET=none`) and No/Yes NVMe (`VM_GAMING=yes VM_NET=user`) —
this proves the cidata path still works after the gating change. Add a "## v5"
section to FAST-INSTALL-RESULTS.md (what changed, file/size/sha256, results,
and a plain note that QEMU still cannot exercise the interactive path — the
new unit test is what covers it) and commit that file.

Finish: write the report (each fix + failing-first proof, test tails, commit
hashes, ISO path/size/sha256, both VM results, anything unsure) to
/tmp/claude-1000/-home-villenull-Projects-Pizzarchy/73222426-a56c-4989-b96c-c00fcf5a26f0/scratchpad/report-muse-v5.md
then ONLY THEN create
/tmp/claude-1000/-home-villenull-Projects-Pizzarchy/73222426-a56c-4989-b96c-c00fcf5a26f0/scratchpad/DONE-muse-v5

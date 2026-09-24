# Task: build the v6 ISO and QEMU it

Repo /home/villenull/Projects/Pizzarchy, branch `hw-feedback-1` (HEAD contains
2716be0, the v6 screen changes). Read `CLAUDE.md`, the top HANDOFF block of
`docs/START-HERE.md` (bullet 6: launch long jobs with
`setsid nohup <cmd> > log 2>&1 < /dev/null &`, never plain nohup), and the
"## v5" section of `docs/findings/FAST-INSTALL-RESULTS.md` — do exactly what v5
did, named v6.

Rules: no Deck, no USB/block-device writes, no publishing/push. Never run git
stash/reset/checkout/clean or `git add -A`/`.`; stage only files you changed, by
path; don't switch branches. Do not change code — if something fails, report the
log tail and your diagnosis.

1. Build: `iso/bin/build`, log `~/.cache/omarchy-deck/build-v6.log`, same
   scratch as v5. Counts only with all guards green and no FATAL line. If it
   dies, report the FATAL/ERROR lines (the build now names its failure) and
   retry once.
2. `pizzarchy-omarchy-4.0.4-fast-install-2026-09-24-v6-x86_64.iso` in
   `~/.cache/omarchy-deck/release-2026.09.24-v6/` + `SHA256SUMS` (generate it
   from inside that dir).
3. QEMU in PARALLEL, separate workdirs, `VM_FAST_REBOOT_CHECK=1`,
   `PATH=/var/tmp/pizzarchy-vm-tools/usr/bin:$PATH`: No/No NVMe (`VM_NET=none`)
   and No/Yes NVMe (`VM_GAMING=yes VM_NET=user`). Note: the wipe-confirm text
   now says "NOW" and the Steam screen no longer full-clears — if a harness
   matches on those, report it.
4. Add "## v6" to FAST-INSTALL-RESULTS.md (changes = 2716be0: items
   9,10,11,14,15,16a,17,18 of docs/findings/HW-INSTALL-FEEDBACK-2026-09-24.md;
   file/size/sha256; both results; note that QEMU cannot exercise the
   interactive screens) and commit that file only, trailer
   `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

Finish: report (ISO path/size/sha256, build attempts, both VM results with
evidence, commit hash, surprises) to `~/.cache/omarchy-deck/agents/report-v6-build.md`,
then ONLY THEN `touch ~/.cache/omarchy-deck/agents/DONE-v6-build`.

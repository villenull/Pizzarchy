# START HERE — handoff (updated 2026-09-24, evening)

If you are picking up this project (human, or an orchestrator agent such as Meta
Muse 1.3), read this file first. It is the live state: rules, how to run
sub-agents, what is done, and what is next. The long project history and
build/test setup live in `docs/START-HERE.md`; read its top HANDOFF block after
this one.

You are the **orchestrator** for the Omarchy Deck installer (Pizzarchy). The
operator is testing the installer live on their Steam Deck OLED and sends
feedback. Your job: turn feedback into decisions, hand ALL work to sub-agents,
review what they return, commit and push, and keep this file (repo-root `START-HERE.md`) current.

## 0. Rules (operator's instructions — do not deviate)

1. **You never do the work yourself.** No code, no tests, no builds. You write a
   brief, launch a sub-agent, review its report, verify, commit/push, update the
   status table below (§3). Trivial reads needed to write a brief or check a result
   are fine.
2. **Model = whatever the operator names.** Voice dictation garbles names
   ("MetaMuse", "Luna 6"), so resolve against the live list first:
   `paseo provider models opencode` / `paseo provider models codex`.
   Default: `opencode-go/muse-spark-1.3-contributor` (Meta Muse / Muse Spark 1.3).
3. **Launch every sub-agent in its CLI inside a Paseo terminal** in the ONE
   Pizzarchy workspace (`wks_fca38d45f8337c61`), on branch `hw-feedback-1`.
   Never use git worktrees (Paseo turns them into a separate workspace).
4. **No limit on parallel agents** — split independent work. Machine: 8 cores,
   30 GB RAM. Only ONE ISO build at a time (they share a build dir).
5. **Always approve sub-agent permission prompts.**
6. **Close agents when finished** (`paseo terminal kill <name>`).
7. **Log every decision immediately** in
   `docs/findings/HW-INSTALL-FEEDBACK-2026-09-24.md` and the status table (§3),
   then commit + push. **Every fix that lands: verify, commit, push at once.**
   Assume the session can end at any moment.
8. **Never** touch the physical Deck, publish anything public, or write the USB
   stick without the operator asking. The operator HAS asked for the USB
   routine in §4.

## 1. How to run a sub-agent (proven recipe)

1. Write the brief to a file under `docs/tasks/agent-briefs/<name>.md` (commit
   it). Every brief must say:
   - repo `/home/villenull/Projects/Pizzarchy`, branch `hw-feedback-1`;
   - read `CLAUDE.md` first;
   - shared tree: never `git stash/reset/checkout/clean`, never
     `git add -A`/`.`, stage own files by path, don't switch branches;
   - long jobs (builds, VM runs): `setsid nohup <cmd> > log 2>&1 < /dev/null &`
     and poll the log — plain `nohup` gets killed silently by the agent's own
     tool timeout (proven; `docs/START-HERE.md` HANDOFF bullet 6);
   - VM runs need `PATH=/var/tmp/pizzarchy-vm-tools/usr/bin:$PATH` (mtools);
   - no Deck, no USB writes, no push;
   - failing-first unit tests; run `shellcheck` + the full sweep
     (`for f in test/unit/test-*.sh; do bash "$f" >/dev/null 2>&1 || echo "FAIL $f"; done`
     and the same for `test/unit/*.py`); commit own files with trailer
     `Co-Authored-By: <your model> <noreply@anthropic.com>` or as the operator prefers;
   - finish by writing a report to `~/.cache/omarchy-deck/agents/report-<name>.md`
     and ONLY THEN `touch ~/.cache/omarchy-deck/agents/DONE-<name>`.
2. `paseo terminal create --workspace wks_fca38d45f8337c61 --cwd /home/villenull/Projects/Pizzarchy --name <name>`
3. `paseo terminal send-keys <name> -l 'opencode -m opencode-go/muse-spark-1.3-contributor --prompt "Read and carry out /home/villenull/Projects/Pizzarchy/docs/tasks/agent-briefs/<name>.md exactly."'`
   then, as a separate command, `paseo terminal send-keys <name> Enter`.
   (Codex: `codex -m <model> -C /home/villenull/Projects/Pizzarchy "<prompt>"`.)
4. Watch: poll every ~15 s for the DONE file, and
   `paseo terminal capture <name> | grep 'Permission required'` → if present,
   `paseo terminal send-keys <name> Enter` (the highlighted option is "Allow once").
5. On DONE: read the report, re-run shellcheck + the unit sweep yourself, review
   the diff (`git show <hash>`), then update §3, commit, `git push`, and
   `paseo terminal kill <name>`.

## 2. Where things are

| What | Where |
|---|---|
| Branch (pushed) | `hw-feedback-1` on `origin` (github.com/villenull/Pizzarchy) |
| All operator feedback + decisions | `docs/findings/HW-INSTALL-FEEDBACK-2026-09-24.md` |
| Build/QEMU results per ISO | `docs/findings/FAST-INSTALL-RESULTS.md` (## v3, v4, v5 …) |
| ISOs | `~/.cache/omarchy-deck/release-2026.09.24-vN/…-vN-x86_64.iso` + `SHA256SUMS` |
| Previous ISO | v5: `~/.cache/omarchy-deck/release-2026.09.24-v5/pizzarchy-omarchy-4.0.4-fast-install-2026-09-24-v5-x86_64.iso`, sha256 `1cf7411e43162fb26c8a182a2bfb85b0e1f9fcc7c41427fbc5b0a4c688c06753`, QEMU no/no + no/yes PASS |
| Latest ISO | **v6** (ON THE STICK since 2026-09-24 18:29, readback-verified; v5 deleted): `~/.cache/omarchy-deck/release-2026.09.24-v6/pizzarchy-omarchy-4.0.4-fast-install-2026-09-24-v6-x86_64.iso`, sha256 `b94ea1188cbbc26f7e10961dc57d98578adf8a8083ad62c8ffcc20ffa1fd092b`, QEMU no/no + no/yes PASS (cee3b15) |
| Build + QEMU brief template | `docs/tasks/agent-briefs/v5-blocker-fix-build.md` §4 |
| Ventoy USB stick | label `Ventoy`, mounts at `/run/media/villenull/Ventoy` (exFAT, user-writable, no password) |

## 3. Status table — UPDATE THIS AS THINGS LAND

Item numbers match the feedback file.

| # | Item | Status |
|---|---|---|
| 1–6, blocker | welcome text, drive colour, wipe confirm, no 2nd drive prompt, log on failure, Yes defaults, partition MiB rounding | ✅ in v3+ (60cf667) |
| review | held-A drain, render error, stty/boot-medium warnings | ✅ in v4+ (4315c95) |
| build | ISO build fails loudly (signals, docker, SIGPIPE) | ✅ 1b3b495 |
| Install blocker | interactive install died on "cidata drive carries no 'preinstalls'" | ✅ in v5 (d76bab6) — **not yet verified on the Deck** |
| 7 | Steam=No: no "No network was found" | ✅ in v5 |
| 8 | Steam=No: reboot notice is one line | ✅ in v5 |
| 9 | Steam download: waiting text instead of `[????]` | ✅ code in 2716be0 (reviewed, tests green) — ships in v6 |
| 10 | Steam download: no full-screen flash | ✅ code in 2716be0 (reviewed, tests green) — ships in v6 |
| 11 | Steam download: speed stuck at 0.00 MB/s; show time left | ✅ code in 2716be0 (reviewed, tests green) — ships in v6 |
| 12 | logo off-centre | ❌ not a bug (photo angle) |
| 13 | download screen blocks the form | ✅ decided: keep blocking, no change |
| 14 | welcome lines aligned to logo's left edge | ✅ code in 2716be0 (reviewed, tests green) — ships in v6 |
| 15 | wipe confirm text `Press A to wipe and install NOW, B to go back` | ✅ code in 2716be0 (reviewed, tests green) — ships in v6 |
| 16a | B map (see feedback file row 16a; B on Install Steam? = back to pre-installs) | ✅ code in 2716be0 (reviewed, tests green) — ships in v6 |
| 17 | Steam Yes → Wi-Fi → B → Steam No continues as a no-Steam install | ✅ code in 2716be0 (reviewed, tests green) — ships in v6 |
| 18 | choices locked only when leaving pre-installs/Steam/Wi-Fi group | ✅ code in 2716be0 (reviewed, tests green) — ships in v6 |
| — | operator's hardware checks on v4: Wi-Fi from ISO ✅, Steam download ✅, account screens ✅, summary ✅, microSD drive listing ✅ | recorded |

## 4. Next steps, in order

0. ✅ DONE 18:29 — v6 on the stick, verified, v5 deleted. NOW: operator tests v6 on the Deck (step 4); log every result/request in the feedback file.

1. ✅ DONE 2026-09-24 16:54 (v5 verified on stick, all older ISOs deleted). Routine for the next ISO — **ISO onto the USB stick** (as soon as the operator plugs it in; check
   `lsblk -o NAME,LABEL,MOUNTPOINTS | grep -i ventoy`): copy to
   `<name>.part`, `sync -f`, rename, `sync -f`, verify
   `dd if=<file> iflag=direct bs=4M status=none | sha256sum` == the sha above,
   THEN delete every other `.iso` on the stick (operator approved deleting all old
   ones, including the 09-20 ISO), then
   `udisksctl unmount -b /dev/sdX1 && udisksctl power-off -b /dev/sdX`.
2. ✅ DONE (2716be0 reviewed). Was: **When `muse-v6code` finishes** (`~/.cache/…` or the scratchpad DONE file —
   this one was launched before the path convention: its report is
   `/tmp/claude-1000/-home-villenull-Projects-Pizzarchy/73222426-a56c-4989-b96c-c00fcf5a26f0/scratchpad/report-muse-v6code.md`):
   review per §1.5, especially its finding on what B does on the account
   screens; update §3; commit + push.
3. ✅ DONE (v6 built + QEMU PASS, cee3b15). Was: RUNNING (agent terminal `v6-build`, brief `agent-briefs/v6-build-qemu.md`, report/DONE in `~/.cache/omarchy-deck/agents/`). **Build v6 + QEMU** with a new brief modelled on
   `agent-briefs/v5-blocker-fix-build.md` §4 (name `…-v6-…`, dir
   `release-2026.09.24-v6`, no/no + no/yes in parallel, add `## v6` to
   FAST-INSTALL-RESULTS.md). Then step-1 routine to put v6 on the stick
   (delete v5).
4. **Operator's Deck tests** (v5 or later): full install + first boot with
   Steam=No (login screen; type password with the on-screen keyboard), then
   Steam=Yes (boots to Gaming Mode; Switch to Desktop works), then hardware
   (audio, brightness, Bluetooth, controller, trackpads). Record every result
   and every new request in the feedback file; turn requests into briefs.

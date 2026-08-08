# Continue here

Session handoff note. Written right before the local project folder gets
renamed `Pizza-Omarchy` → `Pizzarchy` and this session is cleared. Read
this first, then `PROGRESS.md` (full detail on everything below), then
`START-HERE.md` if you need the overall work program.

## What just happened

- Project is now on GitHub: **https://github.com/villenull/Pizzarchy**
  (private repo, owner `villenull`).
- `main` currently holds only the original planning-docs baseline commit
  (`3c44891`) — deliberately minimal, so nothing landed on `main` outside
  a reviewable PR.
- All real work (T0 §1–6, fully built and tested) is on branch
  `worktree-pizza-omarchy-bootstrap`, open as a **draft PR**:
  **https://github.com/villenull/Pizzarchy/pull/1**
- **T0 §1's "done when" criterion is met**: `vm-install-test.sh` ran
  end-to-end against a real, unmodified-upstream `omarchy-iso` build and
  passed — partition table, package set, and enabled units all verified
  against a real, successful, fully-offline install (942/943 packages,
  all 12 phases `ok`). Getting there surfaced and fixed two real bugs in
  this project's own harness code (not upstream bugs) — full story in
  `PROGRESS.md`'s "Findings" section.
- The operator (you) is about to:
  1. Rename the local directory `Pizza-Omarchy` → `Pizzarchy`.
  2. Run `git worktree repair` from the new location (worktrees store
     absolute paths internally — this fixes them up after the rename).
  3. Clear this session.

## Immediate next steps for the next session

1. **Confirm the rename landed cleanly.** `git worktree list` from the
   repo root should show valid paths under `Pizzarchy/`, not stale
   `Pizza-Omarchy/` ones. If anything looks broken, `git worktree repair`
   again before doing anything else.
2. **Decide what to do with PR #1.** It's a draft — nothing has been
   reviewed or merged yet. Either merge it to `main` (bringing all of T0
   in) or keep iterating on the branch first; this wasn't decided this
   session, it's the operator's call.
3. **CI has never run.** `.github/workflows/ci.yml` exists and is
   unit-tested locally (shellcheck + all `test-*.sh` pass), but this is
   the first time a remote has ever existed for this repo — the workflow
   has not been verified against a real GitHub Actions run. Push
   triggers it automatically; check the Actions tab after any push.
   One thing to watch for: this session found Docker's default bridge
   network throttled to ~2 KB/s on the local dev machine (root-caused,
   fixed locally with `--network host` — see `PROGRESS.md`). If T5's ISO
   build ever runs in CI, check whether GitHub-hosted runners hit the
   same class of issue; untested.
4. **Otherwise, proceed to block 3 (R1 research questions)** per
   `SESSIONS.md`'s block table — T0 is functionally done, just not
   merged/CI-verified yet, and that doesn't block R1 from starting.

## Don't re-litigate

These were already resolved this session — don't re-investigate from
scratch, just read `PROGRESS.md`'s "Findings" section if you need the
detail:

- Docker bridge-network throughput issue on this host → use
  `--network host` for any Docker-based build tooling here.
- `vm-cidata.sh`'s archinstall config needs an `obj_id` per partition
  (already fixed, has a regression test).
- Root-partition package/unit inspection uses a real rootless kernel
  mount (`udisksctl loop-setup` + `mount`), not `btrfs restore` — the
  latter silently truncates on zstd-compressed data and was replaced for
  exactly that reason.
- `docker`/`kvm`/`disk` group membership is confirmed working on this
  machine.

## Still outstanding (unrelated to this session's work)

- Ventoy setup on the physical test USB (T0 §2) — documented in
  `FINDING-testing-usb.md`, not yet executed.
- `PLAN.md` §4/§5 architecture: the `OMARCHY_INSTALLER_REPO` fork hook it
  assumes doesn't exist upstream. Needs an operator decision before T5
  locks in a replacement approach — see `PROGRESS.md`'s "Findings" for
  the two candidate approaches.
- Scope decision flagged in `PROGRESS.md`: v0 (T0+T1+T3 as a post-install
  script) vs. v1 (full ISO) — recommended v0 first, not yet confirmed by
  the operator.

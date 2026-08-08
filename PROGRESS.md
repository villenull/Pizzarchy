# Progress

> Claude Code: keep this current as you work, not just at session end.
> This is the first thing the next session reads.

## Status summary

Bootstrapped. `PLAN.md` and `SESSIONS.md` read in full (session 1). Git
repo initialized, planning docs committed as baseline (`3c44891`). Local
toolchain checked (see below). Block 1 (T0 §1, QEMU install harness):
harness + libraries + unit tests written and passing; full end-to-end run
against a real ISO not yet verified (environment gap, see below).

### T0 §1 deliverables (session 1)

Flat files (per `CLAUDE.md`'s no-subdirectories rule — the task file's
`./test/vm-install-test.sh` example path was not followed literally;
everything lives at the repo root with a `vm-`/`test-vm-` prefix instead):

- `vm-disk-image.sh` — rootless GPT partition-table reading and partition
  extraction from a raw disk image file (`sfdisk --json` + `dd`, no loop
  device/root needed — verified interactively before relying on it).
- `vm-assertions.sh` — the actual done-when checks: partition table, UKI
  files present, Limine config contains expected entries (probes the same
  5 candidate paths as Omarchy's own `limine-snapper.sh`, PLAN.md §8.2),
  package set installed, systemd units enabled. Deliberately split into an
  "extraction" half (reads the disk) and a "checking" half (pure logic),
  so checking logic is unit-testable without a real install.
- `vm-cidata.sh` — builds the `cidata` autoinstall drive (FAT-labeled, not
  ISO9660 — no `xorriso`/`genisoimage`/`mkisofs` on this machine) from the
  archinstall-schema JSON found by session-1 research.
- `vm-install-test.sh` — orchestrates all three: boot ISO headless in
  QEMU with the cidata drive attached, wait for guest poweroff (bounded by
  `VM_INSTALL_TIMEOUT_SEC`), convert the qcow2 disk to raw, run the
  assertions, exit non-zero with a preserved work dir on any failure.
- `test-vm-disk-image.sh`, `test-vm-assertions.sh`, `test-vm-cidata.sh` —
  31 assertions total, all passing, all against real hand-built fixture
  images (GPT+FAT32+btrfs via `parted`/`mkfs.vfat`/`mkfs.btrfs` directly on
  regular files — no loop device, no root). Every check has a confirmed-
  failing negative case (e.g. missing ESP, wrong UKI name, unmet package,
  disabled unit) — satisfies the "verify a test can fail" failure mode at
  the unit level. Caught one real bug while writing these (ESP fixture
  needed an actual `mkfs.vfat` before mtools could write to it — parted
  alone only writes the partition table entry).

**Known gap — not yet run end-to-end against a real ISO.** See the
"KNOWN GAP" comment at the top of `vm-install-test.sh` for the full
detail. Two independent blockers:
1. This dev machine has no Docker (upstream's ISO build needs it), no
   `kvm` group membership, and no passwordless sudo — see "Local
   dev-machine limitations" below. Can't build or KVM-accelerate a real
   install here to test against.
2. Even with an ISO: unmodified upstream `omarchy-iso` doesn't
   auto-poweroff after a non-interactive cidata install (only
   `OMARCHY_UI_INTERACTIVE=no` is automatic; `OMARCHY_UI_AUTO_REBOOT` /
   `OMARCHY_UI_FAILURE_ACTION` aren't, so `omarchy-install-dashboard`
   leaves an interactive confirm-and-reboot prompt at the end). This
   harness's completion signal (QEMU process exit) needs T5's eventual
   Deck ISO fork to add one line to `.automated_script.sh`'s cidata
   branch (`export OMARCHY_UI_AUTO_REBOOT=no OMARCHY_UI_FAILURE_ACTION=exit`
   + `systemctl poweroff` after the dashboard returns, non-interactive
   only). Until then, running this against stock upstream will correctly
   time out rather than hang or false-pass — that's honest behavior, not
   a bug, but it means the "exits non-zero on a deliberately broken
   build" done-when criterion is unverified end-to-end, only at the unit
   level.
Note: at the time this was written, `shellcheck` was not installed via
pacman locally — a rootless static v0.11.0 binary was fetched from
GitHub releases directly into the job's scratch dir to unblock T0 §6
(see below) rather than waiting. That binary isn't on `PATH` outside this
session; the operator should still get `shellcheck` installed properly
(`sudo pacman -S shellcheck`) for normal day-to-day use — CI installs its
own copy via `apt-get` regardless.

### T0 §2–6 deliverables (session 1, continued — operator granted
permission to install missing packages themselves rather than blocking on
them; proceeded without waiting since none of §2–6 turned out to need
them)

- **§2 `FINDING-testing-usb.md`** — Ventoy one-time-setup + day-to-day
  workflow, written from `PLAN.md` §9.3's reasoning. Not executed (no
  physical USB access from this environment) — flagged as such in the doc
  itself.
- **§3 `vm-script-loader.sh` + `test-vm-script-loader.sh`** — script-
  override resolution (prefer an override copy of an installer script over
  the ISO's baked-in one, if present). The ISO's real mount layout isn't
  decided yet (T5), so the override-root search path is a parameter
  (`OMARCHY_DECK_OVERRIDE_ROOT` env var + a `/run/media/*/omarchy-deck`
  glob default), not a hardcoded assumption — expect to revise once T5
  lands. 8 unit tests, all passing, each failure mode covered (missing
  override, override missing this one script, override entry is a
  directory not a file, script missing everywhere → fails loudly).
- **§4 `deck-sync.sh`, `deck-snapshot.sh`, `deck-rollback.sh`** — SSH
  iterate-in-place loop + btrfs snapshot/rollback, all parameterized via
  `DECK_HOST`/`DECK_USER`/`DECK_SSH_PORT` env vars (defaults:
  `deck@steamdeck`). **Not run against real hardware** — no Deck reachable
  from this environment, and the task file explicitly allows this
  ("untested against real hardware is OK here — flag it for the
  operator"). Only local, SSH-independent argument-validation was
  exercised (missing args, bad snapshot number, missing stage file — all
  fail fast with the right exit code before attempting a connection).
  **Confirmed before writing these** (per PLAN.md §9.4's own suggestion
  to check first): Omarchy's installer already sets up a Snapper config
  at `/etc/snapper/configs/root` with Limine-sync integration (found in
  `omarchy-iso`'s `orchestrator/phases_impl.py` — it hard-fails the
  install if that path is missing). So `deck-snapshot.sh`/
  `deck-rollback.sh` wrap `snapper create`/`snapper rollback` rather than
  hand-rolling raw btrfs subvolume management. Note `snapper rollback`
  doesn't take effect until reboot — `deck-rollback.sh` prints that
  instruction rather than auto-rebooting the physical Deck, unless
  `DECK_ROLLBACK_AUTO_REBOOT=1` is explicitly set (rebooting physical
  hardware unprompted isn't something to default to).
- **§5 `.github/workflows/ci.yml`** — the one exception to the
  no-subdirectories rule (GitHub-mandated path). Two jobs: `lint-and-
  unit-test` (every push — shellcheck + `bash -n` + all `test-vm-*.sh`
  suites, all of which are rootless and need no special CI privileges)
  and `iso-install-test` (tags only — build the ISO, run
  `vm-install-test.sh`). The ISO-build step is a documented placeholder
  (`exit 1` with a TODO(T5) message) since no build entry point exists
  yet. **Not verified against a real GitHub Actions run** — no remote
  configured for this repo (see "Blocked on human"), so only YAML
  validity (via `js-yaml`) and the job logic by inspection were checked,
  not an actual green run.
  - Fixed while writing this: GitHub-hosted runners have no `/dev/kvm`
    (confirmed absent from upstream `omarchy-iso`'s own CI for the same
    reason). `vm-install-test.sh` now detects `/dev/kvm` and falls back
    to TCG software emulation with a loud warning instead of hard-
    requiring KVM.
  - Also fixed: `vm-install-test.sh` had hardcoded Arch's OVMF firmware
    path (`/usr/share/edk2/x64/...`), which doesn't exist on Debian/
    Ubuntu CI runners. Now probes several known distro paths, overridable
    via `VM_OVMF_CODE`/`VM_OVMF_VARS`.
- **§6 shellcheck baseline** — ran the fetched shellcheck v0.11.0 against
  every `*.sh` in the repo, including `omarchy-deck-kernel.sh` (T1's
  draft, never executed — came back clean with zero findings on the first
  run). Found and fixed 7 real findings across the new files (one
  genuine variable-name collision across sourced files, a couple of
  QEMU-arg/glob patterns shellcheck couldn't distinguish from mistakes —
  quoted or suppressed with an inline justification comment rather than
  silently ignored). **Repo is now shellcheck-clean** (verified: `shellcheck
  *.sh` exits 0, no output).

### Local toolchain check (2026-08-07)

| Tool | Status |
|---|---|
| `qemu-system-x86_64` | present, 11.0.2 |
| `edk2-ovmf` (UEFI firmware for QEMU) | present, 202605-1 |
| `git` | present, 2.55.0 |
| `archiso` (`mkarchiso`) | **missing** |
| `shellcheck` | **missing** |
| `ventoy-bin` | **missing** |

`archiso` and `shellcheck` are needed for T0 §1/§6; `ventoy-bin` is needed
for the human-executed USB setup (T0 §2, already slated for
"Blocked on human"). Not installed per `CLAUDE.md` — added to "Blocked on
human" below instead.

## Task status

| Task | Status | Notes |
|---|---|---|
| T0 Test infrastructure | **§1–6 all built; two verification gaps remain** | §1 harness unit-tested (31 assertions) but not run end-to-end against a real ISO; §2–6 done (Ventoy doc, override loader + 8 tests, deck-sync/snapshot/rollback untested against hardware, CI workflow untested against a real Actions run, shellcheck clean repo-wide). See T0 §1/§2–6 deliverables above for exact gaps. |
| R1 Research questions | not started | Can run parallel; 10.4 is highest stakes |
| T1 Kernel and boot | not started | Opus. Draft script exists, unexecuted |
| T2 Gamepad input spike | not started | Opus. Determines T4's entire scope |
| T3 Gaming Mode | not started | Needs T0's deck-sync.sh to be efficient |
| T4 Installer UI | not started | Blocked on T2's finding |
| T5 ISO and payload | not started | Blocked on R1 10.1 and 10.4 |
| T6 Integration and release | not started | Blocked on Quattro stable |

## Findings

Nothing confirmed yet. `PLAN.md` §8 and §10 contain **hypotheses**, not
findings — as each is confirmed or killed, record it here with evidence.

### ⚠️ Foundational assumption in PLAN.md §4/§5/§10.2 is wrong

`OMARCHY_INSTALLER_REPO` / `OMARCHY_INSTALLER_REF` — the env-var hook pair
PLAN.md's architecture diagram (§4) and repo plan (§5) assume connects
`omarchy-deck-iso` to a forked installer repo — **does not exist** in
`omacom-io/omarchy-iso`. Confirmed by full-repo grep (session 1, subagent
research): zero occurrences of `OMARCHY_INSTALLER_REPO`;
`OMARCHY_INSTALLER_REF` appears exactly once (in a `--quattro` flag
handler) and is never read — looks vestigial.

What the repo actually does: Omarchy installs as a **pacman package**
(`omarchy`/`omarchy-dev`) pulled from a custom repo baked into the ISO's
offline mirror — not a git-cloned installer repo chain-launched at
install time. The real extension points are:
- The `[omarchy]` repo `Server=` URL in `configs/pacman-online-*.conf`
  (or the offline equivalent) — point it at a Deck-specific package repo.
- `bin/omarchy-iso-make --local-source <omarchy-checkout> <pkgs-checkout>`
  — mounts a local checkout into the build container and builds
  `omarchy*` packages from source instead of pulling published ones.
- In-target, `omarchy-setup-system`/`omarchy-finalize-user` (run via
  `arch-chroot` after pacstrap) ship **inside** the `omarchy`/`omarchy-dev`
  package itself — they're basecamp/omarchy's own scripts, not something
  omarchy-iso separately clones.

**This changes the shape of the three/four-repo architecture in PLAN.md
§4–§5** — there's no clean "fork omarchy-iso, point it at a forked
installer repo via env var" path. The Deck-specific installer logic likely
needs to become its own pacman package (built via `--local-source`) or a
pacman-repo-server-swap, not a git-repo swap. **This needs operator input
before T5 locks in an approach** — flagging per `START-HERE.md` §3's
"foundational assumption is wrong" escalation rule, not silently working
around it. R1 10.2 should be re-scoped around this finding rather than the
original hypothesis.

### Useful finding: `cidata` autoinstall mechanism (for T0 §1)

`omacom-io/omarchy-iso` already ships an unattended-install path that's a
better fit for T0's QEMU harness than upstream's own OCR-based
`bin/omarchy-iso-test`: a second virtio drive labeled `cidata` (cloud-init
NoCloud convention) carrying `user_configuration.json` +
`user_credentials.json` (required pair; optional: `user_full_name.txt`,
`user_email_address.txt`, `user_encrypt_installation.txt`,
`authorized_keys`, `tailscale_authkey`). `omarchy-cidata-load` copies these
to `/root` and the orchestrator (`orchestrator/main.py`) skips the `gum`
wizard entirely. Building `test/vm-install-test.sh` around this instead of
keystroke/OCR injection. Exact JSON schema for the two required files is
being confirmed against `archinstall_adapter.py` before hand-authoring a
fixture (session 1, in progress) — do not guess the schema; a wrong guess
here reproduces the exact "prints success, does nothing" failure class
this project exists to prevent (§8.1).

### Local dev-machine limitations affecting T0 §1

**Update (session 2): Docker, `kvm`, and `disk` group membership are now
confirmed working** (`docker run hello-world` succeeds, `/dev/kvm` is
accessible, `groups` shows `kvm disk docker` alongside the existing `video
input wheel`). Passwordless `sudo` is still not set up, but turned out to
only matter for one non-essential line in upstream's build script (see
below) — not a real blocker.

**New finding (session 2): building the real `omarchy-iso` ISO from this
environment is currently bottlenecked by very low network throughput**,
not by tooling/permissions. Four build attempts via unmodified upstream
`bin/omarchy-iso-make` (cloned to session scratch space, not this repo):

1. Attempt 1: failed on one file (`hyprland...zst.sig`) from
   `stable-mirror.omarchy.org`, "Operation too slow. Less than 1 bytes/sec".
2. Attempt 2: failed on several large packages from the same mirror
   (llvm-libs, perl, qt6-declarative, qt6-base, python), same error,
   *plus* two outright 404s from Arch's own `fastly.mirror.pkgbuild.com`/
   `geo.mirror.pkgbuild.com` for `mesa`/`systemd` (stale-mirror sync lag —
   a known, unrelated Arch mirror issue).
3. Attempt 3: same failure, same package cluster — 3/3 identical pattern
   pointed at contention from `ParallelDownloads = 5` in
   `configs/pacman-online-stable.conf`, so that was dropped to `1` in the
   scratch clone (not this repo) for attempt 4.
4. Attempt 4: no download-abort errors, but *even the unrelated nodejs.org
   tarball* crawled at ~1.6–3.2 KB/s sustained (measured directly) — at
   that rate the ~3GB package set would take days. This points at the
   session's actual network egress bandwidth right now, not mirror
   throttling or download parallelism. Killed rather than let it run
   indefinitely.

Two harmless deviations made in the scratch clone only (never touched
this repo): commented out `sudo rm -rf /var/cache/pacman/pkg/*` in
`bin/omarchy-iso-make` (host-side cache tidy, not required for a correct
build, and needs sudo this non-tty background session can't provide), and
set `ParallelDownloads = 1` in `configs/pacman-online-stable.conf`.

Also applied — and this one **is** relevant to T5 later, not just this
scratch test — the one-line completion-detection patch to
`configs/airootfs/root/.automated_script.sh` that `vm-install-test.sh`'s
own "KNOWN GAP" comment already anticipated, with one correction: reading
the actual dashboard source (`omarchy-install-dashboard`) shows
non-interactive installs never actually hang on a prompt (both the reboot
confirm and the failure menu already short-circuit when
`OMARCHY_UI_INTERACTIVE=no`) — the real gap is narrower: on success the
dashboard calls an in-guest `reboot` (into the freshly-installed disk)
rather than powering off, so QEMU's process never exits either way. Patch:
export `OMARCHY_UI_AUTO_REBOOT=no OMARCHY_UI_FAILURE_ACTION=exit` in the
cidata branch, capture the dashboard's exit status without tripping
`set -e`, then explicitly `poweroff` when non-interactive regardless of
outcome. The `vm-install-test.sh` comment block should be corrected to
match this more precise finding next time it's touched.

- Net effect: this session can write and unit-test the harness logic
  (fixture-based, using rootless tools like `mtools` for FAT/ESP reads),
  and tooling/permissions are no longer the blocker — but **T0 §1's "done
  when" criterion (run against a real build, confirm failure detection)
  is still not verified**, now purely because this session's network
  couldn't sustain an ISO build. Retry when network conditions allow, or
  build on a connection known to have real bandwidth. Added to "Blocked on
  human" below.

Carried over from the operator's manual install session (already validated
on real hardware, treat as fact):

- Neptune kernel installs and boots on OLED Deck via jupiter-staging /
  holo-staging repos
- Limine + UKI works; the neptune kernel needs a manually added boot entry
- `mount -o remount` does NOT re-apply fmask/dmask on vfat
- Omarchy's installer aborts on a `yay` / `yay-bin` conflict
- Omarchy's `limine-snapper.sh` fails when `/boot` is mounted 0077
- `cs35l41-dsp1-*` firmware warnings appear on OLED; audio impact unverified

## Blocked on human

- Ventoy setup on the test USB (T0 step 2)
- **Resolved (session 2): operator confirmed `docker`, `kvm`, `disk`
  group membership** (`docker run hello-world` succeeds, `/dev/kvm`
  accessible, `groups` includes `kvm disk docker`). Not yet confirmed:
  `ventoy-bin` from the AUR, and shellcheck still uses the session-scratch
  static-binary workaround (not blocking, just not switched over).
- **New (session 2): T0 §1's real end-to-end run is now blocked on network
  bandwidth, not tooling.** Building unmodified upstream `omarchy-iso`
  (needed since this project's own ISO doesn't exist until T5) failed 4/4
  times from this session's network — see "Local dev-machine limitations"
  above for the detailed pattern (mirror timeouts at `ParallelDownloads=5`,
  then ~2 KB/s sustained even to nodejs.org at `ParallelDownloads=1`).
  Retry `cd <scratch clone> && ./bin/omarchy-iso-make` (or a fresh clone —
  scratch space, not this repo) from a connection with real throughput,
  then `./vm-install-test.sh <built-iso>`. The one-line completion-detection
  patch this needs is documented above and should be re-applied (or moved
  into this repo's own fork once T5 exists).
- **PLAN.md §4/§5 architecture needs revisiting**: the
  `OMARCHY_INSTALLER_REPO` hook it assumes doesn't exist upstream (see
  Findings above). Needs a decision before T5 on the replacement approach
  (pacman-repo-server-swap vs. `--local-source` package build).
- Any write to the physical Deck
- Any public action (repos, upstream issues, outreach)
- **Scope decision: v0 vs v1 first** (see `PLAN.md` §3.1). Recommended is
  v0 = T0+T1+T3 as a post-install script, ISO deferred to v1.
- **Do not wipe the operator's existing Deck install.** It is a working
  Omarchy + Neptune + Limine system and is the single most valuable test
  asset in the project — it's the known-good baseline for T3's
  iterate-in-place loop. Snapshot it before any destructive test.

## Open questions

See `PLAN.md` §10 — six documented questions with hypotheses, worked in R1.

## Next session should start with

T0 §1–6 are all built (see deliverables above). Before starting block 3
(R1 research, per `SESSIONS.md`'s block table):

1. Check whether the operator's package/permission installs landed
   (`which docker shellcheck mkarchiso; groups` — as of this write-up,
   none had yet). If they have: run `./vm-install-test.sh` against a real
   built ISO for the first time (needs an ISO — none exists until T5, so
   this may mean building upstream's own unmodified `omarchy-iso` first
   just to exercise the harness, separate from this project's own fork
   work) and push/verify the CI workflow on an actual GitHub Actions run
   once a remote exists.
2. Otherwise, proceed to block 3 (R1 research questions) — T0 isn't fully
   hardware/CI-verified but isn't blocking further work either.

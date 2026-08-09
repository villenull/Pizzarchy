# Progress

> Claude Code: keep this current as you work, not just at session end.
> This is the first thing the next session reads.

## Status summary

Bootstrapped. `PLAN.md` and `SESSIONS.md` read in full (session 1). Git
repo initialized, planning docs committed as baseline (`3c44891`). Local
toolchain checked (see below). Block 1 (T0 §1, QEMU install harness):
harness + libraries + unit tests written and passing.

**Session 2: T0 §1's "done when" criterion is now met.** `vm-install-test.sh`
ran end-to-end against a real, unmodified-upstream `omarchy-iso` build and
got a clean **PASS** — partition table, package set (5/5 expected
packages), and enabled systemd units all verified against a real,
successful, fully-offline install (942/943 packages, all 12 install
phases `ok`). Getting there surfaced and fixed two real bugs in this
project's own harness code (not upstream bugs) — see "Findings" below:
`vm-cidata.sh` was missing a JSON key archinstall requires (`obj_id`,
`KeyError` at install time), and the package/unit assertion path used
`btrfs restore` in a way that silently stopped mid-tree-walk on
zstd-compressed extents, so it could report "package not found" against
partitions that actually installed fine — replaced with a real rootless
kernel mount (`udisksctl loop-setup` + `mount`), which is also just a
better approach generally. Task #4 ("verify harness can actually fail")
is done: it caught two real bugs before this ever touches hardware.

**Session 4: T1 steps 1–2 done** (review/harden `omarchy-deck-kernel.sh` +
generalize the kernel version). The draft script had never run anywhere; it
does now, and it took a near-total rewrite to get there — four of its design
premises were false against the packages Valve ships today and against a real
Omarchy Quattro install. `shellcheck` clean; **idempotency proven, not
asserted**: two consecutive runs in a QEMU VM, both exit 0, byte-identical
end state, via a new `vm-kernel-idempotency-test.sh`. Six VM iterations were
needed and each of the first five failed on a *different* real bug — see
"T1 — omarchy-deck-kernel.sh review" under Findings. Steps 3–6 (pacman hook,
CI flags, §8.5 upstream repro, stage split) are untouched.

**Session 5: T1 step 3 done** (the pacman hook). The headline is what the
investigation found *before* anything was written: upstream's
`limine-mkinitcpio-hook` already covers UKI generation on install/upgrade
**and** entry+file cleanup on remove, so most of what step 3 was scoped to
build already exists and works. The hook that shipped is therefore a
*verifier*, not a generator, closing three narrower gaps upstream really
does have — all three of them silent-failure gaps. Verified in a VM: 33
assertions, all passing, including forced reinstalls, a fabricated missing
UKI, a fabricated stale entry, and a package removal. Needed a new substrate
image builder (`vm-neptune-image.sh`) because the session-2 installed disk
no longer exists on this machine. See "T1 step 3 — the pacman hook" under
Findings. Steps 4–6 still untouched.

**Session 6: T1 steps 4 + 6 done — T1 is now complete.**
`omarchy-deck-kernel.sh` runs one stage at a time
(`./omarchy-deck-kernel.sh stage-uki`), lists them for CI
(`list-stages`), and cannot stop and wait for a human. The whole thing is
one CLI change rather than two features: once a stage is individually
invokable, "CI-testable" is mostly "that invocation never prompts and its
exit code means something". Verified in QEMU by a new
`vm-kernel-stage-test.sh` — **45 assertions, all passing**, including every
stage run alone twice with the end state byte-identical, a no-argument full
run on top of that changing nothing, and the one genuinely hang-prone code
path (sudo asking for a password) proven to fail in 0s instead of blocking.
Both existing suites re-run green as regressions. See "T1 steps 4 + 6"
under Findings.

**Session 7: T1 ran on the physical Deck for the first time — and the first
hardware run found a bug six VM suites could not.** All nine stages plus
`reconcile` now exit 0 on the operator's OLED Deck (Valve Galileo), but
`stage-uki` failed on the first attempt: `limine_entry_count()` counted the
UKI basename as a *substring* of the whole Limine config, so
`limine-snapper-sync`'s snapshot-rollback entries — whose paths embed the
same basename under `limine_history/` — were miscounted as duplicate boot
entries. The trigger is **the safety snapshot that `TASK-hardware-validation.md`
step 2 mandates**: before it there were zero snapshot entries and the check
passed. Fixed by anchoring the count to real `path:` lines under the ESP's
`/EFI/Linux/`. See "T1 — first physical hardware run" under Findings.
**Not yet rebooted** — the boot chain is verified but unbooted, by choice.

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
| T1 Kernel and boot | **all six steps done** | Script rewritten and now actually executes: shellcheck clean, idempotency proven in a VM (`vm-kernel-idempotency-test.sh`, run twice, byte-identical end state), kernel version reduced to one documented constant (`NEPTUNE_SERIES_DEFAULT=611`) with glob-keyed entry regeneration. Pacman hook done and VM-verified (`vm-kernel-hook-test.sh`, 33 assertions): fires on install/upgrade/remove of `linux-neptune-*`, verifies rather than duplicates upstream's UKI machinery, repairs a missing UKI, prunes stale entries, and does not duplicate entries on repeat reinstalls. §8.5 reproduced and documented (`FINDING-esp-permissions.md` + upstream issue draft). Steps 4+6 done and VM-verified (`vm-kernel-stage-test.sh`, 45 assertions): nine independently runnable stages, each idempotent alone, exit codes 0/1/2, and no invocation can block on a prompt. **Session 7: run on the physical Deck for the first time** — all nine stages plus `reconcile` exit 0 on Valve Galileo (OLED), after the run exposed and fixed a real bug (`limine_entry_count` miscounting `limine-snapper-sync` snapshot entries, which both failed `stage-uki` and silently defeated idempotency inside the pacman hook). Remaining hardware gaps: the stock→Neptune *conversion* path (the Deck was already converted by hand, so `stage-firmware-swap` and `stage-esp-permissions` ran only as no-ops), and nothing has been rebooted to verify the boot chain end-to-end. |
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

**Network bottleneck (session 2) — root-caused and fixed.** Building the
real `omarchy-iso` ISO from this environment first looked bandwidth-
starved: four build attempts via unmodified upstream `bin/omarchy-iso-make`
(cloned to session scratch space, not this repo) failed — three on mirror
timeouts ("Operation too slow. Less than 1 bytes/sec" from
`stable-mirror.omarchy.org`, worsening across `ParallelDownloads=5` → `1`),
the fourth crawling at ~2 KB/s even to an unrelated host (nodejs.org). The
user's own speed test showed 600 Mbps, which didn't match. Root cause,
confirmed by direct comparison: **Docker's default bridge network on this
host silently throttles throughput** (`docker run --network host` measured
62 MB/s against the same URL that crawled at 2 KB/s through the bridge —
matches both the host's own 54 MB/s direct-curl result and the ISP speed
test). MTU and IPv6 were checked and ruled out first. Fix: add
`--network host` to the build's `docker run` invocation (scratch clone
only — see below). This is worth remembering for *any* Docker-based
tooling on this host, not just ISO builds.

Three deviations made in the scratch clone only (never touched this
repo's own files): `--network host` added to `DOCKER_ARGS` in
`bin/omarchy-iso-make` (the actual fix); `sudo rm -rf
/var/cache/pacman/pkg/*` commented out (host-side cache tidy, not required
for a correct build, needs sudo this non-tty background session can't
provide); `ParallelDownloads` in `configs/pacman-online-stable.conf` was
dropped to `1` then restored to the stock `5` once `--network host`
proved to be the real fix.

Also applied — and this one **is** relevant to T5 later, not just this
scratch test — two patches to `configs/airootfs/root/.automated_script.sh`:

1. The completion-detection fix `vm-install-test.sh`'s "KNOWN GAP" comment
   already anticipated, corrected on closer reading of the actual
   dashboard source (`omarchy-install-dashboard`): non-interactive installs
   never actually hang on a prompt (reboot confirm and failure menu both
   already short-circuit on `OMARCHY_UI_INTERACTIVE=no`) — the real gap is
   narrower: on success the dashboard calls an in-guest `reboot` (into the
   freshly-installed disk) rather than powering off, so QEMU's process
   never exits either way. Fix: export `OMARCHY_UI_AUTO_REBOOT=no
   OMARCHY_UI_FAILURE_ACTION=exit` in the cidata branch, capture the
   dashboard's exit status without tripping `set -e`, then explicitly
   `poweroff` when non-interactive regardless of outcome.
2. A debug-log capture: the real install log
   (`/var/log/omarchy-install.log`) only ever exists in the guest's tmpfs,
   and tty1's actual text can be hidden behind plymouth's splash for the
   guest's *entire* lifetime (confirmed — a QMP screendump loop sampling
   every ~15s for 90s+ showed a frozen "OMARCHY" splash the whole time;
   pressing Esc, plymouth's own "show details" toggle, revealed unrelated
   systemd boot-log text, not the real tty1 content). Fix, now a permanent
   part of `vm-install-test.sh` itself (not scratch-only — see below): an
   extra small virtio-blk drive (`serial=vmdebuglog`,
   `/dev/disk/by-id/virtio-vmdebuglog` in-guest), which the ISO fork writes
   the install log + orchestrator `state.json` onto right before its
   poweroff. `vm-install-test.sh` dumps its content to
   `$WORK/install-debug.log` after every run. This is what made the two
   real bugs below findable at all.

**Two real bugs in this project's own harness, found via the first actual
end-to-end run — this is exactly what task #4 ("verify harness can
actually fail") was for:**

1. `vm-cidata.sh`'s `cidata::render_config` didn't include an `obj_id` key
   per partition. archinstall's `DiskLayoutConfiguration.parse_arg`
   (`archinstall/lib/models/device.py:185`) does `partition['obj_id']`
   unconditionally — no default, straight `KeyError` — so every install
   attempt failed after 0.1s, before ever touching the disk
   ("Preparing live environment" phase). Fixed: generate a UUID
   (`/proc/sys/kernel/random/uuid`) per partition. Added a regression test
   in `test-vm-cidata.sh` (existing tests didn't check for this key at
   all, so this could have silently regressed indefinitely without one).
2. `vm-assertions.sh`'s `disk_image::root_restore_matching` used `btrfs
   restore` (the userspace recovery tool) to inspect the installed root
   partition without a real mount. It looked correct in unit tests against
   small hand-built fixtures, but on a real install it errors on
   zstd-compressed extents ("zstd frame incomplete") — and, worse, **stops
   walking the rest of the tree after that error instead of failing
   loudly**, so it never reached `/etc` or `/var/lib/pacman/local` at all.
   This is PLAN.md §8.1's exact failure class (a tool that looks like it
   worked while doing nothing) — reproduced in this project's own tooling,
   not just upstream's. Fixed: replaced with a real rootless kernel mount
   (`udisksctl loop-setup` + `mount` — confirmed working with no sudo/
   polkit prompt on this dev machine, same technique already used
   elsewhere this session for read-only ISO/squashfs inspection). New
   `disk_image::root_mount`/`disk_image::root_unmount` in
   `vm-disk-image.sh`; `vm-install-test.sh` updated to use them.

**Net result: T0 §1's "done when" criterion is met.** `vm-install-test.sh`
run against a real, unmodified-upstream `omarchy-iso` build, with both
fixes applied, produced a clean PASS: partition table valid, all 5
expected packages present, both spot-checked systemd units
(`NetworkManager.service`, `limine-snapper-sync.service`) enabled — against
a real install that put 942/943 packages on disk across all 12 phases,
fully offline (`network_config.type: iso`, confirmed via
`offline downloading...` in the captured log — no network device was even
attached to the test VM, `-nic none`, matching CLAUDE.md's offline
constraint).

Carried over from the operator's manual install session (already validated
on real hardware, treat as fact):

- Neptune kernel installs and boots on OLED Deck via jupiter-staging /
  holo-staging repos
- Limine + UKI works; the neptune kernel needs a manually added boot entry
- `mount -o remount` does NOT re-apply fmask/dmask on vfat
- Omarchy's installer aborts on a `yay` / `yay-bin` conflict
- Omarchy's `limine-snapper.sh` fails when `/boot` is mounted 0077
- `cs35l41-dsp1-*` firmware warnings appear on OLED; audio impact unverified

### R1 — six research questions resolved (session 3)

Full detail in `FINDING-R1-10.1.md` through `FINDING-R1-10.6.md`, worked by
three parallel agents. Headline results (full hypotheses/results now also in
`PLAN.md` §10 inline):

- **§10.1 offline mirror — CONFIRMED, signing caveat KILLED.** No re-sign
  step needed; `omarchy-iso` already carries an unsigned third-party repo the
  same way Valve's would work. New risk: ISO size grows ~1:1 with the mirror
  (stored uncompressed by design), and the build's package-count self-check
  (600–2000) will need its upper bound widened.
- **§10.2 hooks vs. fork — PARTIAL, right conclusion via a different
  mechanism.** `post-update.d/` hooks are real in Quattro but unprivileged
  and silently swallow failures — wrong tool. Found upstream's actual
  sanctioned pattern instead: `install/hardware/pacman.sh` +
  `intel/ptl-kernel.sh`, a working in-tree template for exactly this
  hardware-gated kernel-swap-plus-repo problem, usable as-is for T1.
  Recommended architecture: fork `omarchy-iso` (build-time) + a
  Deck-specific pacman package (install-time) + one `pre-refresh-pacman.d/`
  hook (durability, since `omarchy refresh pacman` silently wipes
  `/etc/pacman.conf`).
- **§10.3 gamepad mapping — PARTIAL.** Both designs prepared concretely;
  genuinely needs a hardware session to decide, not attempted here.
- **§10.4 Steam offline — CONFIRMED. ⚠️ Contradicted a CLAUDE.md hard
  constraint; operator decision made.** Tested for real in a network-isolated
  QEMU VM: cold launch with no network fails fatally in under a second; even
  with the 2.5 GB client pre-populated (also tested), Steam reaches its login
  screen but then requires network to actually log in — the offline
  limitation is over-determined, not a single fixable gap. Operator chose to
  accept the reframing: **`CLAUDE.md`'s offline constraint is now worded**
  "fully offline install through first boot into Gaming Mode; Steam signs in
  on first launch like a factory-reset Deck," `PLAN.md` §6.1a item 7 (Wi-Fi
  screen) is promoted, and T5 gains a required item (detect no-network/
  no-client and show a Wi-Fi screen before Steam gets the display).
  **Decided: no pre-populated client** — ship only the plain launcher, rely
  on the Wi-Fi screen. See below.
- **§10.5 Secure Boot/BIOS — CONFIRMED (resolved session 3).** Operator
  verified on their own Deck: boot order already defaults to Limine, Secure
  Boot was never touched during their original install and it worked, and
  the BIOS exposes no Secure Boot toggle at all. No pre-install BIOS step
  needed.
- **§10.6 upstream collaboration — PARTIAL, staged, on hold.** Outreach
  message to `28allday` and five `deckarchy` bug reports drafted
  (`DRAFT-outreach-28allday.md`, `DRAFT-upstream-bugs-deckarchy.md`);
  operator has decided to hold entirely — nothing sent or posted, no
  timeline to revisit.

### T1 — `omarchy-deck-kernel.sh` review (session 4)

The draft encoded a manual install done on an older package set. Verified
against a real Omarchy Quattro disk image (session 2's `vm-test-work6`) and
against `jupiter-staging`'s current packages. **Four of its premises were
false**, each a hard failure or a wrong boot entry:

- **PLAN.md §8.3's preset bug is now moot — CONFIRMED OBSOLETE.** Valve's
  kernel packages ship no `/etc/mkinitcpio.d/*.preset` and no
  `/boot/vmlinuz-*` at all. Unpacked `linux-neptune-611-6.11.11.valve29-1`
  and `linux-neptune-618-6.18.39.valve1-1`: each contains exactly
  `usr/lib/modules/<kver>/{pkgbase,vmlinuz}`. There is no preset left to be
  wrong, so the draft's `[[ -f $KERNEL_PRESET ]]` check and its whole
  `default_uki` patching stage were dead ends.
- **Omarchy Quattro builds UKIs with `limine-mkinitcpio-hook`, not presets.**
  Its pacman hook enumerates `/usr/lib/modules/*/pkgbase` and produces
  `$ESP/EFI/Linux/<prefix>_<pkgbase>.efi`, then registers it with
  `limine-entry-tool --add-uki`. Installing the kernel is most of the job;
  the script's real work is *verifying that machinery ran* and failing loudly
  when it did not.
- **The stock Limine config has no `/Arch Linux (linux)` entry.** It is a
  nested tree written by `limine-entry-tool` (`/+Omarchy` → `//linux`) and
  the `path:` line carries a blake2b hash of the UKI. The draft's `awk`
  cmdline extraction matched nothing, and its `tee -a` would have appended a
  flat, hash-less entry outside the OS branch that `limine-entry-tool` would
  later clobber. Both are gone.
- **The UKI filename prefix is not the machine-id.**
  `limine-mkinitcpio-install` uses `CUSTOM_UKI_NAME` from
  `/etc/default/limine` when set; Quattro sets it to `omarchy`, so the real
  files are `omarchy_linux.efi` / `omarchy_linux-neptune-611.efi`. The script
  now *discovers* the UKI path instead of constructing it.

**PLAN.md §8.2 — CONFIRMED, with a correction.** The config is at
`$ESP/limine.conf` (the fifth of the five candidates, so the five-way probe
was right to exist). `limine-common-functions` hardcodes
`LIMINE_CONFIG_PATH="${ESP_PATH}/limine.conf"`.

**PLAN.md §8.5 — REPRODUCED on a stock Omarchy Quattro install.** Its
`/etc/fstab` mounts `/boot` `fmask=0077,dmask=0077` with no Deck packages
involved, which is the evidence T1 step 5 needs to argue this is a generic
Omarchy-on-archinstall problem rather than Deck-specific.

**Two new upstream bugs, found by running it (not by reading it):**

1. **`linux-firmware-neptune` collides with Arch's split `linux-firmware`.**
   Arch split `linux-firmware` into per-vendor subpackages with the old name
   kept as a metapackage. Valve's package still declares
   `conflicts`/`replaces` against only `linux-firmware` and
   `linux-firmware-whence`, so pacman removes those two and then dies in the
   file-conflict check against the other ten
   (`/usr/lib/firmware/... exists in filesystem (owned by
   linux-firmware-other)`). The script now removes the ten explicitly rather
   than using `--overwrite`, because overwriting would leave the Arch
   packages owning those paths and the next `pacman -Syu` would silently
   restore Arch's firmware over Valve's.
2. **`pacman --noconfirm` answers *No* to a conflict question.** The prompt
   is `Remove linux-firmware? [y/N]`, so plain `--noconfirm` aborts the whole
   transaction with "unresolvable package conflicts". Fixed with `--ask=4`
   (`ALPM_QUESTION_CONFLICT_PKG` only — not a blanket yes). Same shape as
   PLAN.md §8.4's yay/yay-bin conflict.

**Also learned:** `limine-snapper-sync.service` holds the ESP open, so the
§8.5 `umount`/`mount` cycle needs it stopped and restarted (the script does,
with restart guaranteed on every exit path). And the first "target is busy"
turned out to be the *test harness's own probe script* running out of
`/boot` — bash holds an open fd on the script it is executing. The holder
diagnostic added to `stage_esp_permissions` is what identified both.

**Kernel-version churn, measured (PLAN.md §11).** `jupiter-staging` ships
series `60, 61, 65, 68, 611, 615, 616, 618, 72`. **The suffix is not
orderable** — as integers `618 > 72`, as text `"68" > "618"`, and neither is
right because 72 is 7.2.x and newest. "Latest" is also currently
`7.2.0.rc3.valve.beta1`, a release candidate. That kills "track latest" on
evidence and is why the script pins, via a single documented
`NEPTUNE_SERIES_DEFAULT=611` constant (override:
`OMARCHY_DECK_NEPTUNE_SERIES`), validates the pin against the live repos, and
keys every regeneration/prune path on the `linux-neptune-*` glob.

**Idempotency evidence.** `vm-kernel-idempotency-test.sh` boots session 2's
installed disk image, runs the script twice, and diffs snapshots of the ESP
tree (with per-file sha256), the Limine config, `/etc/fstab`,
`/etc/pacman.conf`, the live mount options and the full package set. Result:
`run1_exit=0 run2_exit=0 state_diff_exit=0`. The before/after diff is
substantive — new `omarchy_linux-neptune-611.efi` (38.5 MB), new
`//linux-neptune-611` Limine entry, `/boot` options `0077` → `0133/0022` —
so the pass is not vacuous. The harness injects rootlessly (mtools onto the
ESP + SMBIOS type-11 systemd credentials); it never needs sudo on the host,
so it can run in CI.

### T1 step 3 — the pacman hook (session 5)

**The finding that mattered most: upstream already does most of this.**
`limine-mkinitcpio-hook` 1.36.0-1 (read directly — it is installed on this
dev machine and on the operator's Deck) ships three ALPM hooks, and between
them they cover both directions:

- **Install/Upgrade** — `/etc/pacman.d/hooks/90-mkinitcpio-install.hook`.
  Note the path: the package drops it into `/etc`, where it *shadows*
  mkinitcpio's own same-named hook in `/usr/share/libalpm/hooks` (pacman
  de-duplicates hooks by filename, `/etc` wins). Triggers `Type=Path`,
  `Operation=Install|Upgrade`, `Target=usr/lib/modules/*/pkgbase`, plus a
  second trigger on `usr/lib/firmware/*` and friends that forces a rebuild of
  *every* installed kernel. It runs `limine-mkinitcpio-install`, which builds
  `$ESP/EFI/Linux/<prefix>_<pkgbase>.efi` and calls
  `limine-entry-tool --add-uki`. A plain `pacman -S linux-neptune-611`
  reinstall counts as an Upgrade (libalpm classifies a reinstall as an
  upgrade because the package is already in the local db) — **confirmed in
  the VM**, the hook fires on a reinstall.
- **Remove** — `60-limine-mkinitcpio-remove-pre.hook` (PreTransaction,
  records the pkgbase names into `/var/lib/limine/removed_kernels.list`) and
  `90-limine-mkinitcpio-remove-post.hook` (PostTransaction, runs
  `limine-mkinitcpio-remove post`). It deregisters the entry **and deletes
  the UKI file** — `limine-entry-tool --remove-all` removes files unless
  `--keep-files` is passed. So the suspected gap ("does anything clean up
  after `pacman -Rns linux-neptune-611`?") **does not exist**. Confirmed in
  the VM: the removal test shows `Removed unused Limine boot entry:
  linux-neptune-611` coming from upstream's hook, before this project's hook
  runs at all.

**So the hook that shipped verifies rather than generates.** It closes three
real gaps, all of the same shape — upstream can fail while reporting success:

1. `limine-mkinitcpio-install`'s per-kernel error paths are all
   `error_msg …; continue`, and the guard before them is a bare
   `pacman -Qqo … || continue`. It can build nothing and still exit 0, while
   the Limine entry keeps pointing at the previous UKI whose modules
   directory the upgrade just deleted. **This was hit for real while building
   the test harness** (a broken `pacman.conf` in the chroot made every
   `pacman -Q` fail; the script skipped the only kernel and exited 0 having
   built nothing) — it is not a theoretical concern.
2. Its whole-run failure (`initialize_header || exit 1`, e.g. the ESP not
   mounted) happens PostTransaction, so it cannot roll back: the kernel lands
   with no UKI behind one terse pacman error line.
3. `limine-mkinitcpio-remove`'s `post_remove` never checks whether
   `limine-entry-tool` succeeded and then deletes `removed_kernels.list`
   unconditionally, so a failed removal is forgotten permanently.

**The firmware conflict cannot be hooked at all.** `--ask=4` exists because
libalpm asks `Remove linux-firmware? [y/N]` during transaction *preparation*,
before any hook — including PreTransaction hooks — runs. Nothing catches it
and nothing can. In practice it only bites on the first swap (which
`stage_kernel` owns); afterwards there is nothing left to conflict with. It
recurs only if something drags Arch's `linux-firmware` back in as a
dependency, and the fix for that is a `conflicts` entry on the Deck pacman
package (T5), not a hook. Recorded here so T5 does not rediscover it.

**Shape of the hook.** `/etc/pacman.d/hooks/95-omarchy-deck-kernel.hook`
(`95-` so it sorts after every upstream hook, both the `90-` install one and
the `90-` remove-post one), `Type=Package`,
`Operation=Install|Upgrade|Remove`, `Target=linux-neptune-*` and
`linux-firmware-neptune`, `When=PostTransaction`,
`Exec=/usr/local/bin/omarchy-deck-kernel reconcile`. `stage_hook` installs
both files with a content compare so a re-run writes nothing. The same
basename under `/usr/share/libalpm/hooks` will supersede it cleanly when the
Deck logic becomes its own package. The whole rationale is written into the
hook file itself, not just here — the person asking "why does this exist" is
reading the hook.

**VM evidence.** `vm-kernel-hook-test.sh`, 33 assertions, all passing:
install run leaves a working hook; a forced reinstall fires upstream's hook
*and* this one, really regenerates the UKI, and leaves exactly one Limine
entry; a second reinstall still leaves exactly one (the "must not duplicate"
requirement, tested rather than argued); deleting the UKI behind Limine's
back and running the hook's own command repairs it; a fabricated stale
`linux-neptune-999` entry is pruned; `pacman -Rdd` leaves no UKI and no
entry. Also asserted: on a healthy reinstall this project's hook does **not**
rebuild — it only verifies — which is the evidence that it is not duplicating
upstream's work. `vm-kernel-idempotency-test.sh` was re-run after adding
`stage_hook` to `main()` and still passes (`hook: … already current` on run 2).

**New harness: `vm-neptune-image.sh`.** Session 2's installed Quattro disk
image is gone from this machine (`/var/tmp` was cleared), and rebuilding it
means an ISO build plus a full unattended install. This builds a purpose-made
substrate instead — limine + limine-mkinitcpio-hook from Omarchy's own repo,
`ENABLE_UKI=yes` + `CUSTOM_UKI_NAME="omarchy"`, a vfat ESP mounted
`fmask=0077,dmask=0077`, and a real `linux-neptune-611` from the Valve repos —
in a privileged `archlinux/archlinux` container, in about six minutes,
without root on the host. It is explicitly **not** a claim to be a Quattro
install; it reproduces the four properties the boot chain depends on. Two
things it cost to get right, both worth not rediscovering:

- **Docker gives the container a tmpfs `/dev` with no udev**, so `losetup -P`
  publishes partitions under `/sys/block` but nothing creates `/dev/loopNpM`.
  The nodes have to be `mknod`'d from sysfs by hand.
- **`genfstab -U` silently emitted `/dev/loop0p1` for the ESP**, because it
  resolves UUIDs through `/dev/disk/by-uuid`, which udev never populated. The
  guest then booted (root comes from the kernel cmdline, not fstab), waited
  90 s for a device that cannot exist in a VM, failed `/boot`, and dropped to
  an emergency shell — which from the outside looked exactly like a hung
  test: disk churn, then silence, for two full runs. fstab is now written by
  hand from `blkid`, and the builder refuses to ship an fstab containing a
  `/dev/` path. Also: put `console=ttyS0` **last** in the kernel cmdline, or
  systemd's boot output goes to a VGA framebuffer no harness is capturing. A
  QEMU monitor `screendump` is what finally showed the emergency shell.

**Correction to a session-4 claim: mkinitcpio's UKI output IS
byte-reproducible.** `omarchy-deck-kernel.sh` and
`vm-kernel-idempotency-test.sh` both asserted the opposite in comments, and
the hook test's first run failed on an assertion built on it — a reinstall
that demonstrably rebuilt the UKI (`mkinitcpio` ran, `UKI stored in …`,
`Updated: /boot/limine.conf`) produced a byte-identical file, same sha256.
Consequences: the idempotency test's sha256 snapshot does *not* catch a
needless rebuild (it does catch one whose inputs changed), and the "skip when
current" rule in `reconcile_uki` is justified by cost and boot-chain blast
radius, not by reproducibility. Both comments corrected in place; proving a
regeneration happened now uses an mtime sentinel.

### T1 steps 4 + 6 — CI-testable, one stage at a time (session 6)

Done together because they are one CLI design, not two features: once a stage
can be invoked on its own, "CI-testable" is mostly "that invocation never
prompts and its exit code means something".

**The interface, and why this one.** A positional subcommand selects a stage,
which is the convention the rest of this repo already uses — `deck-sync.sh`,
`deck-snapshot.sh` and `deck-rollback.sh` all take positional arguments and
take *configuration* from environment variables, and the script already had
`install` / `reconcile` positionally from step 3. So:

```
omarchy-deck-kernel.sh                  full run (unchanged)
omarchy-deck-kernel.sh stage-kernel     one stage
omarchy-deck-kernel.sh list-stages      the nine names, for harnesses
omarchy-deck-kernel.sh reconcile        what the pacman hook runs (unchanged)
```

Both existing callers keep working untouched: `deck-sync.sh`'s loop and the
hook's `Exec=` line both use the no-argument and `reconcile` forms. `deck-sync.sh`
gained an optional `DECK_STAGE_ARGS` env var (not a third positional, so no
existing invocation changes) so the iterate-in-place loop can reach one stage:
`DECK_STAGE_ARGS=stage-uki ./deck-sync.sh omarchy-deck-kernel.sh`. Verified
against a stubbed `ssh`/`rsync` on `PATH` — still no Deck reachable from this
dev environment — and the remote command string with `DECK_STAGE_ARGS` unset
is byte-identical to the one it built before, which is the property that
mattered.

**The stage names are not the task file's.** `TASK-T1` step 6 named five
(`stage-repos`, `stage-kernel`, `stage-uki`, `stage-bootloader`,
`stage-permissions`); the script has evolved to nine. The two that no longer
map are deliberately **not** accepted as aliases, because both would be lies:
`stage-bootloader` (this script does not write boot entries — `limine-entry-tool`
does, from `stage-uki`) and `stage-permissions` (it is specifically the ESP's
mount options, `stage-esp-permissions`). An unknown name is a usage error that
lists the real ones.

**`INSTALL_STAGES` is the single source of truth** — the full run iterates it,
`list-stages` prints it, single-stage dispatch validates against it, and the
function name is derived from the stage name rather than tabulated. A stage
cannot be individually runnable but missing from the full run, or vice versa.

**Prerequisites, and the honest way to handle them.** Two stages
(`stage-preconditions`, `stage-esp-detect`) set the `SUDO` / `ESP_PATH` /
`LIMINE_CONFIG` every other stage reads. They are pure probes — they install
nothing, write nothing, unmount nothing — so a single-stage run executes them
first. The alternative is a stage that guesses where the ESP is, which is
`PLAN.md` §8.3 again. Prerequisites a probe *cannot* satisfy now fail loudly
and name the stage to run:

- `stage-kernel` / `stage-firmware-swap` check the Valve repos are configured
  and have a usable db. Previously an unconfigured repo made `pacman -Sl`
  print nothing and the script reported *"the Valve repos returned no
  linux-neptune-\* packages at all — the mirror layout may have changed"*,
  sending the reader to Valve's mirror to debug a missing line in their own
  `pacman.conf`.
- `stage-uki` checked this already but called it an "internal error", which it
  no longer is — it is now a reachable user path.
- `stage-firmware-swap` checks the repos **before** removing anything, because
  its whole job is to leave the system with no firmware for the few seconds
  until `stage-kernel` installs Valve's; discovering *then* that the
  replacement's repo was never configured would be the worst possible moment.
  Run alone it now says so out loud.

**Exit codes: 0 success, 1 stage failure, 2 usage error.** The 2-means-usage
split is what `deck-sync.sh` and `deck-rollback.sh` already do, and it is the
one a CI caller needs — "you invoked me wrong" must be distinguishable from
"the boot chain is broken" without parsing output.

**Non-interactivity: one real hazard, found by auditing rather than assuming.**
Every `pacman` call was already `--noconfirm` (plus the `--ask=4` conflict
fix from steps 1–2), there is no `read` anywhere, and `limine-entry-tool` /
`limine-mkinitcpio` were read directly — they prompt nowhere and their only
lock is a `flock` with a 10s timeout. The one genuine hang was **this
script's own sudo check**: `$SUDO -n true || $SUDO true`. The fallback reads
its password from `/dev/tty`, so redirecting stdin does not disarm it, and a
CI job holding a controlling terminal would sit at the prompt until it timed
out with no clue why. It is now reached only in interactive mode; otherwise
the missing credential is a fast, specific failure naming the two fixes.

Interactivity is **auto-detected** (stdin not a terminal ⇒ non-interactive)
rather than opt-in, deliberately: a harness that forgets a flag would silently
get the prompting build, which is the exact class of defect this project
exists to avoid. `--non-interactive` / `--interactive` /
`OMARCHY_DECK_NONINTERACTIVE` override it. In non-interactive mode stdin is
redirected from `/dev/null` for the whole run, so any child that tries to read
a prompt sees EOF immediately instead of blocking on an inherited pipe.

**VM evidence — `vm-kernel-stage-test.sh`, 45 assertions, all passing** (45s
of guest time on the `vm-neptune-image.sh` substrate). Every stage invoked
alone, in order, each under `setsid --wait timeout … </dev/null` — no
controlling terminal, no stdin, a hard time limit, so a stage that blocks
gets killed and reports 124 rather than hanging the suite. Then every stage
alone *again*, with the two end states byte-identical (per-stage idempotency,
which full-run idempotency does not imply: a stage only ever reached after its
predecessors can be idempotent in that sequence and not on its own). Then the
no-argument full run on top, exiting 0 and changing nothing — the regression
check that stage-by-stage and the full run converge on the same state. The
pass is not vacuous: the before/after diff shows `/boot` going
`fmask=0077,dmask=0077` → `0133/0022`, `/etc/fstab` rewritten, and
`steamdeck-dsp` plus its dependency tree installed.

**Regression evidence.** Both existing suites re-run green against the same
substrate after the CLI change: `vm-kernel-hook-test.sh` 33/33 (the hook still
fires on install/upgrade/remove, still only verifies on a healthy reinstall,
still repairs a missing UKI and prunes a stale entry) and
`vm-kernel-idempotency-test.sh` PASS (`run1_exit=0 run2_exit=0
state_diff_exit=0`). Nothing in step 3's hook logic or step 5's ESP
permissions work was touched — the hook's `Exec=` line is unchanged and still
calls `reconcile`, which is why `hook_script_matches=1` still holds.

The non-interactive assertions are the ones worth having built: a user with
password-required sudo is created in the guest, the test **first proves
`sudo -n` genuinely fails for them** (otherwise the section would be vacuous),
and then runs a stage as that user with no tty and no stdin under a 60s limit.
It returns in **0s** with the non-interactive message — 124 would have meant it
sat at the prompt. Two more stdin shapes pass too: stdin closed outright
(`0<&-`), and stdin on a fifo whose writer never writes, which is the shape
that makes a stray read hang forever rather than see EOF.

### T1 — first physical hardware run (session 7)

The first time any of this project's code touched the real Deck. Nine stages
plus `reconcile`, run one at a time, against a snapper snapshot taken first
(`root`, snapshot **1**). Hardware: `Valve` / `Galileo` — OLED, the only
verified model.

**The environment is not what the task file assumed, and that is itself a
finding.** The operator's Deck runs **Omarchy 3.8.4 installed from git**
(`~/.local/share/omarchy`, `omarchy-version-branch` → `master`), **not**
Quattro: no `/usr/share/omarchy`, no `/etc/omarchy.conf`, and neither
`omarchy` nor `omarchy-dev` is an installed package. That resolves the
session-4 open item ("confirming `omarchy` vs `omarchy-dev` — likely just
the wrong package name"): it was neither. There is no Omarchy package at
all on a 3.x git install.

**It ran anyway, and the reason matters for T5.** `omarchy-deck-kernel.sh`
gates on *mechanism*, never on version — `stage_preconditions` checks tools,
sudo, Deck DMI and `command -v limine-entry-tool`, and no executable line in
the script references `/usr/share/omarchy`, `/etc/omarchy.conf` or the
`omarchy` package. The UKI prefix is *discovered* from `/etc/default/limine`
rather than assumed. On this machine that file already carries the
Quattro-shaped values the script was written for (`ENABLE_UKI=yes`,
`CUSTOM_UKI_NAME="omarchy"`, `ESP_PATH="/boot"`). **So the boot-chain work
requires Quattro's *mechanism* (`limine-mkinitcpio-hook`), not Quattro's
*packaging*.** A 3.x install that has had `omarchy update` pull in the
boot-chain machinery is a supported substrate.

**The bug this found — `limine_entry_count()` substring miscount.**
`reconcile_uki` asserts each UKI is referenced exactly once in the Limine
config. The counter behind it was `grep -cF` on the bare basename.
`limine-snapper-sync` writes a Snapshots submenu whose entries boot a
snapshot's copy of the same UKI, at a path that *contains* that basename:

```
path: boot():/EFI/Linux/omarchy_linux-neptune-611.efi#<hash>                              ← the real entry
path: boot():/<machine-id>/limine_history/omarchy_linux-neptune-611.efi_sha256_<h>#<hash>  ← a snapshot entry
```

Count 2, not 1 → `stage-uki` exits 1 with "expected exactly 1 Limine entry
… found 2". The boot chain was *correct*; the check was wrong.

**The second-order bug is the worse one.** `reconcile_uki`'s up-to-date test
also requires the count to be exactly 1. With any snapshot present that is
never true, so the UKI is **rebuilt on every run** — and this code is what
the pacman hook executes, meaning a pointless boot-chain write on every
kernel transaction. The idempotency proven in session 4 (`run1_exit=0
run2_exit=0 state_diff_exit=0`) was real in the VM and silently false on any
real machine with a snapshot. Observed directly: the failing run rebuilt
*both* UKIs; after the fix the same stage logs "UKI up to date … registered
once" and writes nothing.

**Why six VM suites missed it.** `vm-neptune-image.sh` builds a substrate
with limine + `limine-mkinitcpio-hook`, but nothing in
`vm-kernel-idempotency-test.sh`, `vm-kernel-hook-test.sh` or
`vm-kernel-stage-test.sh` ever creates a snapper snapshot, so
`limine-snapper-sync` never generated a Snapshots submenu and the second
reference never existed. The gap is in the *substrate*, not the assertions —
worth closing before trusting the next idempotency claim.

**The fix.** `limine_entry_count()` now counts only `path:` lines pointing
into the ESP's own `/EFI/Linux/`, with the basename terminated by the
`#<hash>` suffix, whitespace, or end of line; `limine_history/` paths fail
that anchor. Verified against the real config: old counter 2, new counter 1,
for both `omarchy_linux-neptune-611.efi` and `omarchy_linux.efi`.
`shellcheck` clean.

**Results — all nine stages, plus the hook's own entry point:**

| Stage | Exit | Effect on this machine |
|---|---|---|
| `stage-preconditions` | 0 | no-op; detected `Valve Galileo` |
| `stage-repos` | 0 | **added** `jupiter-staging` + `holo-staging` (they were absent) |
| `stage-esp-detect` | 0 | no-op; `/boot` on `/dev/nvme0n1p1` |
| `stage-firmware-swap` | 0 | no-op — "no Arch linux-firmware packages left to displace" |
| `stage-kernel` | 0 | no-op; all four packages already current |
| `stage-uki` | **1 → 0** | failed on the bug above; after the fix, skips cleanly |
| `stage-prune` | 0 | no-op; 1 Neptune UKI, 1 installed Neptune kernel |
| `stage-hook` | 0 | **installed** the hook + `/usr/local/bin/omarchy-deck-kernel` |
| `stage-esp-permissions` | 0 | no-op; already `fmask=0133,dmask=0022`, fstab untouched |

`/usr/local/bin/omarchy-deck-kernel reconcile` (what the pacman hook runs)
also exits 0 and **writes nothing** — `md5sum` of all four UKIs and
`limine.conf` identical before and after. The "idempotent by construction,
the healthy path writes nothing" claim now holds on hardware, not only in
QEMU.

**⚠️ Scope limit — this was a reconcile run, not a conversion run.** The
Deck was already in most of T1's end state before the script ran: per
`/var/log/pacman.log`, `linux-neptune-611`, `-headers`,
`linux-firmware-neptune` and `steamdeck-dsp` were installed **by hand on
2026-08-03**, Arch's `linux-firmware` removed the same day, and `/boot` was
already mounted `0133/0022`. So seven of nine stages were exercised only on
their no-op path. **Still unvalidated on hardware: the stock→Neptune
conversion itself** — in particular `stage-firmware-swap` actually removing
Arch's split `linux-firmware-*` and `stage-esp-permissions` actually doing
the `umount`/`mount` cycle on a live ESP. Those remain VM-only evidence.

**Not rebooted.** Every boot artifact is byte-identical to the bytes this
machine is currently running, and the script wrote nothing to the ESP, so
the reboot validates less than the task file assumed. One pre-existing
oddity noted for whoever does reboot: `/boot/limine.conf` has
`default_entry: 2`, which with the current entry order may select stock Arch
(`linux` 7.1.4) rather than Neptune — unchanged by this run, but select the
Neptune entry explicitly at the menu rather than accepting the default.

**Incidental.** `shellcheck` is now installed via pacman on the Deck,
retiring the session-1 scratch-binary workaround noted above. Also: this
session drove `sudo` through a `pinentry` `SUDO_ASKPASS` helper, because the
harness has no TTY and `sudo` reads passwords from `/dev/tty` — the same
constraint session 6 hardened the script against. Worth knowing for any
future on-Deck agent session.

## Blocked on human

- Ventoy setup on the test USB (T0 step 2)
- **Resolved (session 2): operator confirmed `docker`, `kvm`, `disk`
  group membership** (`docker run hello-world` succeeds, `/dev/kvm`
  accessible, `groups` includes `kvm disk docker`). Not yet confirmed:
  `ventoy-bin` from the AUR, and shellcheck still uses the session-scratch
  static-binary workaround (not blocking, just not switched over) — though
  shellcheck itself appeared on `$PATH` partway through session 2, so it
  may already be installed; re-check with `which shellcheck` next session.
- **Resolved (session 2): T0 §1's real end-to-end run.** Was blocked on a
  Docker bridge-network throughput issue (root-caused and fixed with
  `--network host`, see "Local dev-machine limitations" above), then on
  two real bugs in this project's own harness (`obj_id` missing from
  `vm-cidata.sh`'s JSON, `btrfs restore` silently truncating its tree walk
  in `vm-assertions.sh`), both now fixed and covered. `vm-install-test.sh`
  now passes cleanly against a real ISO end to end.
- **Resolved (R1, session 3): PLAN.md §4/§5 architecture.** R1 §10.1/§10.2
  found the concrete replacement — fork `omarchy-iso` for build-time changes,
  ship Deck logic as its own pacman package for install-time work (modeled on
  upstream's own `install/hardware/pacman.sh` + `intel/ptl-kernel.sh`
  precedents), plus one `pre-refresh-pacman.d/` hook for durability. See
  `FINDING-R1-10.1.md` and `FINDING-R1-10.2.md`. No longer blocked; ready to
  inform T5.
- **New (T1, session 4): moving the Neptune kernel pin needs a hardware
  session.** The script pins `linux-neptune-611` because that is what was
  validated live on the operator's OLED Deck; `618` (6.18.39.valve1) is the
  newest non-RC series. Bumping is a one-line change to
  `NEPTUNE_SERIES_DEFAULT`, but it should not ship without a boot test on
  hardware. **Still open after session 7:** replacing Arch's split
  `linux-firmware-*` with Valve's `linux-firmware-neptune` remains
  unvalidated *by the script* on hardware — the operator had already done
  that swap by hand on 2026-08-03, so `stage-firmware-swap` was only ever
  exercised on its no-op path. Wi-Fi/BT/audio do work on the resulting
  system, which is real evidence for the end state but not for the
  transition. Same for `stage-esp-permissions`' `umount`/`mount` cycle: the
  ESP was already `0133/0022`, so the stage early-returned.
- **Resolved (session 4): T1's scope-decision precondition, checked against
  the operator's real Deck.** The rewritten `omarchy-deck-kernel.sh` only
  supports systems where `limine-entry-tool` is present (provided by the
  `limine-mkinitcpio-hook` package) — the agent flagged this as needing
  revisiting if the operator's Deck (installed via archinstall + Omarchy
  manually, not the Quattro ISO) predates that mechanism. Operator ran
  read-only checks on the real Deck (`pacman -Qi limine-mkinitcpio-hook`,
  `ls /etc/mkinitcpio.d/`, `ls /usr/lib/modules/*/pkgbase`): the package
  **is** installed (v1.36.0-1, explicitly installed 2026-08-03 — likely via
  a recent `omarchy update` pulling in Quattro's boot-chain machinery even
  though the original install predates it), so the script's actual gate
  (`command -v limine-entry-tool`) passes. Two `.preset` files
  (`linux-neptune-611.preset`, `linux.preset`) are still present in
  `/etc/mkinitcpio.d/` as leftover cruft from before the hook existed — the
  script never reads that path, so they're harmless. `pkgbase` for
  `6.11.11-valve29-1-neptune-611-...` confirms the operator's Deck is
  already on the same `linux-neptune-611` series the script pinned to.
  **Resolved (session 7):** the script has now been run on the physical
  Deck — all nine stages exit 0 (after fixing a bug the run exposed), see
  "T1 — first physical hardware run" under Findings. The `omarchy` vs
  `omarchy-dev` question is also answered, and the answer was neither: the
  Deck runs **Omarchy 3.8.4 installed from git**, so no Omarchy pacman
  package exists at all. The script does not care — it gates on
  `limine-entry-tool`, not on Omarchy's packaging.
- Any write to the physical Deck
- Any public action (repos, upstream issues, outreach) — **now includes two
  concrete staged drafts awaiting approval**: `DRAFT-outreach-28allday.md`
  and `DRAFT-upstream-bugs-deckarchy.md` (five bug reports), from R1 §10.6.
  Nothing has been sent; sending each is a separate explicit action.
- **Scope decision: v0 vs v1 first** (see `PLAN.md` §3.1). Recommended is
  v0 = T0+T1+T3 as a post-install script, ISO deferred to v1.
- **Do not wipe the operator's existing Deck install.** It is a working
  Omarchy + Neptune + Limine system and is the single most valuable test
  asset in the project — it's the known-good baseline for T3's
  iterate-in-place loop. Snapshot it before any destructive test.
- **New (R1 §10.3): gamepad-mapping design needs a hardware session.** Both
  candidate designs (background Steam vs. systemd-user-service mapper) are
  prepared concretely in `FINDING-R1-10.3.md` with a head-to-head test plan;
  neither can be decided without the physical Deck.
- **Resolved (session 3): Secure Boot / BIOS state.** Operator checked their
  own Deck: boot order already defaults to Limine, and Secure Boot was never
  touched during the original Omarchy install (direct evidence of factory
  state) — the BIOS's `Security` tab exposes no Secure Boot toggle at all.
  No pre-install BIOS step needed. See `FINDING-R1-10.5.md`. Photos taken
  during verification were reviewed and deleted locally at operator's
  request, not committed.
- **On hold, indefinitely: R1 §10.6 drafts.** Operator has decided to hold
  entirely on sending/filing the `28allday` outreach message and the five
  `deckarchy` bug reports — not now, not with edits, just holding. Drafts
  remain staged (`DRAFT-outreach-28allday.md`,
  `DRAFT-upstream-bugs-deckarchy.md`) for if/when this changes.
- **Resolved (session 3): pre-populated Steam client — decided against.**
  Operator confirmed: don't bundle it. Ship only the plain 20 MB `steam`
  launcher package in the offline mirror (legitimate, distro-standard
  redistribution); rely entirely on T5's pre-Steam network-check/Wi-Fi
  screen to handle the offline case. This makes that Wi-Fi screen a
  **required, load-bearing T5 item**, not optional polish — with no
  pre-populated client, it's the only thing between a Wi-Fi-less first boot
  and a bare Steam crash dialog with no keyboard to dismiss it. See
  `FINDING-R1-10.4.md` and `PLAN.md` §6.1a item 7 / §10.4.

## Open questions

`PLAN.md` §10's six questions are now all resolved by R1 (session 3) — see
`FINDING-R1-10.1.md` through `FINDING-R1-10.6.md`, and the "Findings" section
above for the headline results. Only §10.3 (gamepad mapping design) remains
blocked on a hardware session — tracked in "Blocked on human" above.
Everything else under §10.4/§10.5 is now fully decided.

## Next session should start with

T0 §1–6 are all built and **T0 §1's real end-to-end run is now verified**
(session 2 — see "Status summary" and "Findings" above). Before starting
block 3 (R1 research, per `SESSIONS.md`'s block table):

1. Push/verify the CI workflow (`.github/workflows/ci.yml`) on an actual
   GitHub Actions run once a remote exists — not yet done, no remote is
   configured for this repo. Worth noting: the CI runner's Docker networking
   should be checked for the same bridge-throughput issue found this
   session if T5's ISO build ever runs there (see "Local dev-machine
   limitations" above) — GitHub-hosted runners may or may not have the
   same problem; hasn't been tested.
2. If T5 (ISO build) work starts: the two `.automated_script.sh` patches
   from session 2 (completion-detection poweroff, debug-log capture drive)
   need to land in this project's own fork, not just the scratch clone
   they were verified against. The debug-log drive's host side
   (`vm-install-test.sh`) is already permanent; only the guest-side
   `.automated_script.sh` write needs porting.
3. Otherwise, proceed to block 3 (R1 research questions) — T0 isn't fully
   hardware/CI-verified but isn't blocking further work either.

**Added after session 7 (hardware run):**

4. **Close the VM substrate gap that hid the `limine_entry_count` bug.**
   `vm-neptune-image.sh` produces a system with no snapper snapshot, so
   `limine-snapper-sync` never writes the Snapshots submenu, so no test
   could ever see a second reference to a UKI basename. Create a snapshot in
   the substrate (or in the idempotency/hook/stage suites) and re-run all
   three — otherwise the next "idempotency proven" claim carries the same
   blind spot. This is the highest-value follow-up from session 7.
5. **The reboot verification is still outstanding** (`TASK-hardware-validation.md`
   step 5). Boot chain is verified but unbooted. Select the Neptune entry
   explicitly at the Limine menu — `default_entry: 2` may point at stock
   Arch. Rollback target if needed: `sudo snapper -c root rollback 1`.

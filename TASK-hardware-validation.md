# TASK — First physical-hardware validation (Neptune kernel + boot chain)

**Read this whole file before running anything.** You are a Claude Code
instance running directly on the operator's Steam Deck — the actual
physical target device this whole project is for. This is the **first
time** any of this project's code has touched real hardware. Everything
referenced below has been tested in QEMU (extensively — see
`PROGRESS.md`'s Findings section for T0/R1/T1) but never on a real Deck.
Read `CLAUDE.md` in this directory first — its hard constraints apply in
full, especially: never silently swallow a failure, this is the single
most valuable test asset in the project (a working Omarchy+Neptune+Limine
install), and anything destructive needs a real rollback path in place
*before* you touch anything.

The operator is physically present and driving this interactively — you
don't need to seek remote approval for each step the way a background
agent would, but you must still **stop and report** rather than push
through when something fails or looks unexpected, per every "fail loudly"
instruction in this codebase.

## Context

This repo (`villenull/Pizzarchy`, branch `main` has everything) builds a
Steam Deck installer for Omarchy Quattro. T0 (test harness) and R1 (six
research questions) are done. T1 (kernel/firmware/boot chain automation,
`omarchy-deck-kernel.sh`) is done and heavily VM-tested — idempotency
proven, a pacman hook verified, all nine stages individually runnable and
CI-tested for non-interactivity — but **zero physical hardware runs**.
That's what this task is for: run it for real, once, carefully, with a
snapshot to fall back on.

This Deck's install predates the project (archinstall + Omarchy, not the
eventual Quattro ISO) — a prior session already confirmed the one load-
bearing precondition (`limine-mkinitcpio-hook` present) holds here, see
`PROGRESS.md`'s "T1's scope-decision precondition" entry. Re-confirm below
anyway rather than trusting that note blindly — state may have changed.

## Step 0 — Identify the environment (read-only, do this first)

```
cat /etc/os-release
pacman -Q omarchy 2>&1
pacman -Q omarchy-dev 2>&1
omarchy-version-branch 2>&1
cat /etc/omarchy.conf 2>/dev/null
uname -r
pacman -Qi limine-mkinitcpio-hook 2>&1
```

Report what these show. **If this turns out to be genuinely Omarchy 3.x**
(not Quattro/4.x) rather than just missing the `omarchy-dev` package name,
**stop here and report back before proceeding** — T1's entire rewrite
(see `PROGRESS.md`'s "T1 steps 1-2"/"T1 step 3" Findings entries) assumed
Quattro-specific mechanisms (`limine-mkinitcpio-hook`, package-based
`OMARCHY_PATH=/usr/share/omarchy`, etc.). If those don't actually hold
here, running the later stages could behave unpredictably. Don't guess —
ask the operator how to proceed if version signals are inconsistent.

## Step 1 — Get the repo and confirm the script

```
git clone https://github.com/villenull/Pizzarchy.git
cd Pizzarchy
shellcheck omarchy-deck-kernel.sh   # should be clean; if not, stop and report
./omarchy-deck-kernel.sh list-stages
```

Expect exactly these nine, in this order: `stage-preconditions`,
`stage-repos`, `stage-esp-detect`, `stage-firmware-swap`, `stage-kernel`,
`stage-uki`, `stage-prune`, `stage-hook`, `stage-esp-permissions`. If the
list differs from this, the repo state doesn't match what this task
document assumes — stop and report rather than improvising.

## Step 2 — Safety net: snapshot before touching anything

**Non-negotiable, do not skip.**

```
sudo snapper -c root create --type single --print-number --description "before first physical Neptune kernel run"
```

This should print a snapshot number. **Write it down / report it clearly
— this is the rollback target for the rest of this task.** If this
command fails for any reason (e.g. "is the 'root' Snapper config
present?"), stop and report — do not proceed to Step 3 without a working
snapshot. (Omarchy's installer sets this Snapper config up by default, so
failure here would itself be a notable finding, not just an obstacle to
work around.)

## Step 3 — Run each stage individually, checking in between

Run these **one at a time**, reading the output of each before moving to
the next. Each should exit 0. If any stage exits non-zero, **stop —
do not run the next stage** — report the exact output and wait for
direction (rollback via Step 6 is always available).

```
sudo ./omarchy-deck-kernel.sh stage-preconditions
sudo ./omarchy-deck-kernel.sh stage-repos
sudo ./omarchy-deck-kernel.sh stage-esp-detect
sudo ./omarchy-deck-kernel.sh stage-firmware-swap
sudo ./omarchy-deck-kernel.sh stage-kernel
sudo ./omarchy-deck-kernel.sh stage-uki
sudo ./omarchy-deck-kernel.sh stage-prune
sudo ./omarchy-deck-kernel.sh stage-hook
sudo ./omarchy-deck-kernel.sh stage-esp-permissions
```

Two stages are worth extra attention while reading their output, since
they're the most invasive (per `PROGRESS.md`'s T1 findings):
- `stage-firmware-swap` removes Arch's split `linux-firmware-*` packages
  and installs Valve's `linux-firmware-neptune`. This is the one most
  likely to have a genuine real-hardware surprise (Wi-Fi/BT/audio
  firmware is device-specific in a way the VM can't validate).
- `stage-esp-permissions` loosens the ESP mount permissions — a
  documented, deliberate security tradeoff (see `FINDING-esp-permissions.md`),
  not a bug, but worth knowing it's a real access-control change.

## Step 4 — STOP. Do not reboot without the operator's explicit go-ahead.

Rebooting into the new boot entry is the one action in this whole task
that's genuinely hard to undo quickly if something's wrong with the boot
chain. Once all nine stages above pass cleanly, **summarize the results
and explicitly ask the operator to confirm before rebooting.** Don't
reboot automatically just because the stages succeeded.

## Step 5 — After operator confirms: reboot and verify

Reboot, select the Neptune entry from the Limine menu, and once back at a
login/desktop:

```
uname -r
```

Should contain `neptune-611`. Report whether it booted cleanly, how long
it took, and anything that looked different from a normal boot.

Per `CLAUDE.md`'s testing-tier guidance, this is also the point to spot-
check the things that can *only* be tested on physical hardware: does
audio still work, do the trackpads/gyro respond normally, does Wi-Fi/BT
still connect. Don't do a deep test pass — just confirm nothing obviously
broke. (The `cs35l41-dsp1-*` firmware warning noted elsewhere in
`PROGRESS.md` is already known/expected on OLED — not a new finding if
you see it again.)

## Step 6 — Rollback path (if anything in Steps 3-5 goes wrong)

```
sudo snapper -c root rollback <snapshot-number-from-step-2>
```

This creates a new default subvolume from the snapshot but does **not**
auto-reboot — you'd still need to reboot manually for it to take effect.
If the system won't boot at all to run this command, that's a real
escalation — stop and get the operator involved directly rather than
attempting further fixes blind.

## Step 7 — Gamepad-mapping hardware test (R1 §10.3)

Once the kernel/boot validation above is done (or if the operator wants
to interleave — their call, they're driving), this is the other thing
that's been blocked on hardware access all project. Read
`FINDING-R1-10.3.md` in full first — it has two fully-prepared candidate
designs and an explicit test plan written for exactly this moment:

- **Design (a)**: background Steam (`steam -silent` in Hyprland autostart)
  inheriting Steam Input's desktop controller layout + on-screen keyboard
  for free.
- **Design (b)**: the T2-spike-style custom mapper as a systemd `--user`
  service (draft unit already written in the finding doc), needing a
  `/dev/uinput` permission fix and `wvkbd`/`squeekboard` for the OSK.

Follow the finding doc's "What a hardware test session needs to do to
decide" section exactly — it lists the specific things to check for each
design (OSK focus detection, RAM/battery cost, `hyprland-session.target`
scoping, `/dev/uinput` access without root, etc.). When done, **update
`FINDING-R1-10.3.md` in place** with the actual decision and evidence —
it currently says PARTIAL/prepared-but-undecided, and this is the session
that resolves it. Don't leave it as scaffolding once you have real data.

## When you're done with any/all of the above

Update `PROGRESS.md`'s Findings and "Blocked on human" sections with what
actually happened — this session has no memory of prior conversations
about this project, so the only way this work is visible to whoever picks
this up next (human or another Claude session) is if it's written into
the repo's own docs, not left in this chat. Commit and push to a new
branch (don't push directly to `main`) so it can go through a PR like
everything else in this project's history.

## Escalate to the operator immediately, don't work around, if:

- Step 0 shows an inconsistent/unexpected OS version.
- Any stage in Step 3 fails.
- The Deck doesn't boot cleanly in Step 5.
- Anything asks you to modify TDP, fan curves, or charge limits — hard
  no, not in scope for this task, ask first regardless of context.

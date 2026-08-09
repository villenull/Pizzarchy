# Finding: ESP permissions tradeoff (PLAN.md §8.5 / TASK-T1 step 5)

**Status: workaround shipped and in active use in `omarchy-deck-kernel.sh`
(`stage_esp_permissions`); upstream issue drafted but not filed; tradeoff
recorded here per TASK-T1 step 5's explicit "don't bury it" requirement.**

## The bug

Under a default `archinstall` + Limine + UKI setup, `/boot` (the ESP) is
mounted `fmask=0077,dmask=0077` — root-only. Omarchy's own
`limine-snapper.sh` checks for its config with a plain `[[ -f
<limine.conf> ]]` as the invoking (non-root) user. That stat fails under
`0077` even though the file exists, so the script reports `Error: Limine
config not found` — a permissions problem that presents as a missing-file
problem.

## Reproduction (already done — not re-run here)

**REPRODUCED on a stock Omarchy Quattro install with zero Deck packages
involved.** `/etc/fstab` ships `fmask=0077,dmask=0077` on `/boot` purely
from archinstall's own Limine+UKI defaults — no Steam Deck-specific
tooling, no `omarchy-deck-kernel.sh`, nothing from this project. See
`PROGRESS.md`, Findings section, the paragraph beginning "**PLAN.md §8.5 —
REPRODUCED on a stock Omarchy Quattro install.**"

This is the evidence TASK-T1 step 5's first bullet asked for: it confirms
the bug is a generic Omarchy-on-archinstall interaction, not a Deck
peculiarity, and is exactly what makes it appropriate to file against
`basecamp/omarchy` rather than treat as something only this project needs
to work around.

This is also the same root cause `DRAFT-upstream-bugs-deckarchy.md`'s "Bug
5 of 5" describes from the `limine-snapper.sh` angle (drafted before the
isolation reproduction had run, so it hedged on target repo). It is now
confirmed and superseded by the fuller draft below.

## Why Deck's install needs a workaround right now

This project's installer needs `/boot`/the ESP to be user-readable so that
Omarchy's own boot/snapshot tooling (`limine-snapper.sh`, invoked as a
normal user in normal operation) works out of the box on every Deck this
project sets up. Waiting for an upstream fix isn't an option for shipping
now, so `omarchy-deck-kernel.sh`'s `stage_esp_permissions` stage rewrites
the ESP's `/etc/fstab` line to `fmask=0133,dmask=0022` (root read/write,
everyone else read) and does a full `umount`/`mount` cycle to apply it —
`mount -o remount` does **not** re-apply `fmask`/`dmask` on vfat, which
cost real debugging time to discover (see the script's header comment and
`PROGRESS.md`).

## The tradeoff — stated plainly, not buried

**This is a security-relevant global loosening applied to fix one
script's permission assumption.** Before the change, only root can read
the ESP (including the UKIs, which are bootable executables — archinstall
hardens this deliberately). After the change, every local user on the
machine can read the entire ESP tree. That is a strictly larger attack/
readability surface than archinstall's own chosen default, and it exists
solely because `limine-snapper.sh` does its existence check as an
unprivileged user instead of escalating for that one check.

On a single-user Steam Deck this is a small practical risk in absolute
terms (the primary threat model most users care about is physical device
theft with the OS already unlocked, where ESP readability is not the
binding constraint) — but "small in this specific case" is not the same
as "correct fix," and this project should not quietly rely on that
assessment without writing it down. Hence this file.

## The cleaner fix (what should happen upstream instead)

Elevate the specific existence/read check in `limine-snapper.sh` (run it
with sudo/root, or via whatever mechanism Omarchy's own tooling typically
uses to escalate for privileged operations) rather than requiring the ESP
to be globally readable. That fixes the actual bug — a script making an
unwarranted assumption about its own privilege level — without touching
archinstall's mount defaults at all. It also produces a more honest error
message: a permissions failure during an elevated check reads as a
permissions failure, instead of masquerading as a missing file.

## Draft upstream issue

`DRAFT-upstream-esp-permissions-omarchy.md` — full title, reproduction
steps, expected/actual behavior, and suggested scope for a report against
`basecamp/omarchy`. **Staged only — not filed, not sent, requires explicit
operator approval**, same convention as this project's other `DRAFT-*.md`
files. It supersedes `DRAFT-upstream-bugs-deckarchy.md`'s "Bug 5 of 5",
which drafted the same bug against the wrong candidate repo before the
isolation reproduction had run.

## What to do if/when upstream fixes this

Once `basecamp/omarchy` ships an elevated-check fix, `stage_esp_permissions`
in `omarchy-deck-kernel.sh` should be revisited: the `fmask=0133,dmask=0022`
loosening can potentially be dropped (reverting to archinstall's default
`0077`, or something tighter than `0133`/`0022`) once nothing in the stock
Omarchy toolchain needs unprivileged ESP reads anymore. Until then, this
workaround stays, and this file is the record of why, so a future session
doesn't have to rediscover the reasoning from script comments alone.

## Where this is also documented

`omarchy-deck-kernel.sh` already carries a "SECURITY TRADEOFF — deliberately
visible, not buried" comment block directly above `stage_esp_permissions`
(search the file for `SECURITY TRADEOFF`), which states the same tradeoff
inline at the point of use and points back at "TASK-T1 step 5." This file
is the fuller writeup that comment references — no script edit was needed
for this task, since that in-script documentation already exists and
already satisfies the "don't bury it" requirement at the code level.

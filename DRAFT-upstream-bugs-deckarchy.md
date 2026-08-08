# DRAFT — upstream bug reports for aorumbayev/deckarchy

**STATUS: DRAFT ONLY. Not filed. No `gh` commands run, no network calls
made. Requires explicit operator approval before posting anywhere** — per
project hard rule against publishing/posting without approval.

Five reports below, one per hypothesis in PLAN.md §8. Each was hit firsthand
during a real Deck install session per PROGRESS.md/PLAN.md — these are
real bugs with high-confidence root-cause hypotheses, not speculation, but
they still need to be filed as reports (not "here's your fix," since PLAN.md
§8's implied fixes for #1/#3/#4 explicitly say the correct home for those
fixes is *this* project's vendored installer, not upstream deckarchy) except
where noted.

---

## Bug 1 of 5: `linux-neptune.sh` silently reports success while doing nothing when run via `curl | bash`

**Title:** `linux-neptune.sh` silently no-ops and exits 0 when piped from curl (missing `common-script.sh`)

**Hypothesis / description:** The script layer appears derived from Chris
Titus Tech's `linutil` (same `common-script.sh` + per-tool-script structure;
helper names like `checkEnv`, `checkEscalationTool`, `checkAURHelper`,
`checkCurrentDirectoryWritable`; `$ESCALATION_TOOL`/`$PACKAGER`/`$RC`
variable conventions), which is designed to run from a git clone, not a curl
pipe. The README's `curl -sSL .../linux-neptune.sh | bash` one-liner breaks
this assumption: `common-script.sh` isn't present in the pipe's working
directory, so every call into it fails with "command not found," but the
script has no `set -e` (or equivalent), so it keeps running and prints its
normal success-looking output ("Steam Deck detected", "Adding
jupiter-staging…", "Installing Neptune kernel…") before exiting 0 — with
nothing actually installed.

**Reproduction steps:**
1. On a fresh Steam Deck (or Arch install) with network access, run the
   README's documented one-liner: `curl -sSL <linux-neptune.sh URL> | bash`.
2. Observe the output looks like a successful run.
3. Check whether the kernel/firmware packages were actually installed
   (e.g. `pacman -Q linux-neptune-611`) — they will not be.
4. Diff `common-script.sh` against linutil's file of the same name to
   confirm the inheritance (near-identical expected).

**Expected behavior:** Either the documented curl-pipe usage works
end-to-end, or it fails loudly (non-zero exit, clear error) instead of
printing fake success.

**Actual behavior:** Exits 0, prints success-looking log lines, installs
nothing.

**Suggested scope for the report:** Flag the silent-failure behavior and the
likely `linutil` inheritance as root cause; note that the safest fix is
either (a) documenting that the script must be run from a git clone, not
piped, or (b) adding `set -euo pipefail` so the missing-file failure is loud
instead of silent. (This project's own fix vendors the needed logic directly
per PLAN.md §8.1 — the report doesn't need to propose that, just needs to
flag the silent-failure hazard clearly since that's the part that's
genuinely dangerous for any user of the upstream script as documented.)

---

## Bug 2 of 5: No Limine support in bootloader detection

**Title:** Bootloader detection doesn't recognize Limine, fails with "No supported bootloader detected (GRUB or systemd-boot)"

**Hypothesis / description:** The bootloader-detection code appears to
predate Limine's arrival as a mainstream option — archinstall only gained
Limine support relatively recently, and Omarchy's adoption of it as the
preferred bootloader is newer still. Likely an unimplemented feature rather
than a broken check.

**Reproduction steps:**
1. Install Arch (or Omarchy Quattro) using archinstall's Limine bootloader
   option.
2. Run deckarchy's kernel-install script.
3. Observe the bootloader-detection step fails with "No supported
   bootloader detected (GRUB or systemd-boot). Manually configure your
   bootloader to use linux-neptune."

**Expected behavior:** Limine is recognized as a valid bootloader and the
script either configures it automatically or gives Limine-specific manual
instructions.

**Actual behavior:** Treated as unsupported; user is told to manually
configure with no Limine-specific guidance.

**Suggested scope for the report:** Ask for Limine detection to be added.
Worth noting in the report that Limine's config location is not stable
across versions/setups — Omarchy's own `limine-snapper.sh` probes five
candidate paths (`/boot/EFI/arch-limine/`, `/boot/EFI/BOOT/`,
`/boot/EFI/limine/`, `/boot/limine/`, `/boot/limine.conf`) — so any
detection logic added upstream should probe the same candidate list rather
than hardcoding one path, since a single hardcoded path was found to be
wrong in a real session (`/boot/EFI/BOOT/limine.conf` on that particular
install).

---

## Bug 3 of 5: `linux-neptune-611.preset` ships `default_uki` commented out and pointing at the wrong ESP path for a Limine+UKI archinstall setup

**Title:** `linux-neptune-611` mkinitcpio preset's commented-out `default_uki` uses an `/efi/...` path incompatible with archinstall's Limine+UKI layout (where the ESP is `/boot`)

**Hypothesis / description:** This looks like it is **not actually a
deckarchy-authored bug** — it's inherited unmodified from Arch's own stock
`linux.preset` template, which ships
`#default_uki="/efi/EFI/Linux/arch-linux.efi"` commented out by default. That
path reflects the Arch wiki's convention of mounting the ESP at `/efi` when
`/boot` is a separate non-ESP partition. On an archinstall Limine+UKI setup,
the ESP *is* `/boot`, so the inherited default is wrong for that
configuration, and Valve's `linux-neptune-611` package simply carries the
upstream Arch template forward without adjusting it for how archinstall's
Limine+UKI mode actually lays out partitions. Uncommenting the line as-is
fails with `ERROR: Invalid option -U -- '/efi/EFI/Linux/…' must be
writable`.

**Reproduction steps:**
1. Install Arch via archinstall using the Limine bootloader + UKI option
   (ESP mounted at `/boot`).
2. Install `linux-neptune-611` via deckarchy or manually.
3. Inspect `/etc/mkinitcpio.d/linux-neptune-611.preset` — `default_uki` is
   commented out, pointing at `/efi/EFI/Linux/...`.
4. Uncomment it and run `mkinitcpio -p linux-neptune-611` — observe the
   "must be writable" error since `/efi` doesn't exist/isn't the real ESP
   in this layout.
5. Compare against `/etc/mkinitcpio.d/linux.preset` on the same machine to
   confirm the identical commented-out `/efi` pattern is inherited stock
   Arch behavior, not deckarchy-specific.

**Expected behavior:** A UKI is produced at a path matching the actual ESP
mount point, or the preset/README calls out that this must be adjusted
manually for non-`/efi` ESP layouts.

**Actual behavior:** No UKI is produced by default; the naive fix (just
uncommenting) fails outright because the path assumes a different partition
layout than archinstall's Limine+UKI mode produces.

**Suggested scope for the report:** Given this traces to stock Arch's
template rather than deckarchy's own code, frame the report as informational
— flag it so deckarchy's docs can warn Limine+UKI users explicitly, since
the failure mode (silently no bootable entry) is severe for exactly the
audience deckarchy targets. Also flag the version-pinned fragility: the
preset filename, UKI filename, and any Limine entry `path:` all change on a
future `linux-neptune-612`, so a hardcoded per-version fix is not durable —
worth a report note even though the actual mitigation lives in this
project's own installer (a pacman hook keyed on a `linux-neptune*` glob, not
a hardcoded version, per PLAN.md §11).

---

## Bug 4 of 5: `yay-bin` vs `yay` package conflict breaks Omarchy's installer when both scripts run in sequence

**Title:** deckarchy's `checkAURHelper` auto-installs `yay-bin`, which conflicts with Omarchy's own `yay` dependency and aborts Omarchy's installer

**Hypothesis / description:** Same `linutil` inheritance as Bug 1 —
`checkAURHelper` installs an AUR helper as a side effect of what's meant to
be an environment check, and prefers `yay-bin` (prebuilt binary, faster to
install) over building `yay` from source. Omarchy's own installer pins
source `yay`. Since both packages `provide yay`, pacman refuses to have both
installed, and Omarchy's `packaging/base.sh` aborts with a transaction
conflict if deckarchy's script already installed `yay-bin` first.

**Reproduction steps:**
1. Run deckarchy's kernel-install script first (which invokes
   `checkAURHelper`, installing `yay-bin` if no AUR helper is present).
2. Then run Omarchy Quattro's installer, which attempts to install `yay`.
3. Observe: `yay-12.6.0-1 and yay-bin-13.0.1-1 are in conflict` →
   `error: failed to prepare transaction` → Omarchy's `packaging/base.sh`
   aborts.

**Expected behavior:** Either deckarchy doesn't auto-install an AUR helper
as a side effect of an environment check, or it detects/respects a
downstream installer's AUR-helper preference instead of installing its own
default.

**Actual behavior:** Silent side-effect install of `yay-bin` that later
breaks an unrelated installer (Omarchy's) with a package conflict, with no
indication at deckarchy's own install time that this will cause a problem
downstream.

**Suggested scope for the report:** Ask that `checkAURHelper`'s
side-effect install either be made opt-in/skippable, or that it check for
(and prefer) an already-configured downstream preference rather than
defaulting to `yay-bin`. Note in the report that this project's own
mitigation is simply not running deckarchy's AUR-helper check at all and
letting Omarchy own that step (PLAN.md §8.4/CLAUDE.md hard constraint) —
useful context for maintainers on why sequencing matters here, but the ask
upstream is about the auto-install-as-side-effect pattern itself, since any
other downstream installer pinning a different AUR helper would hit the
same conflict.

---

## Bug 5 of 5: ESP mounted with `fmask=0077,dmask=0077` blocks user-space reads needed by Omarchy's own `limine-snapper.sh`

**Title:** Default `fmask=0077,dmask=0077` ESP mount on archinstall Limine+UKI setups breaks Omarchy's `limine-snapper.sh` config detection (likely not deckarchy-specific — reproduces on stock archinstall + Omarchy)

**Hypothesis / description:** This looks like a collision between two
independently reasonable defaults rather than a bug in either project alone:
archinstall deliberately hardens the ESP to `0077` on UKI setups (UKIs are
bootable executables, and there's a defensible security argument against
making them world-readable), while Omarchy's `limine-snapper.sh` reasonably
assumes it can `[[ -f ... ]]`-test its config file as the invoking
(non-root) user. Under the `0077` mask, that stat fails for a normal user
even though the file exists at a path the script explicitly checks
(`limine-snapper.sh` probes `/boot/EFI/arch-limine/`, `/boot/EFI/BOOT/`,
`/boot/EFI/limine/`, `/boot/limine/`, `/boot/limine.conf`), producing
`Error: Limine config not found` despite the file being present.

**Reproduction steps:**
1. Fresh archinstall with Limine bootloader + UKI mode (produces the
   default `fmask=0077,dmask=0077` ESP mount).
2. Install Omarchy on top.
3. Run (or trigger indirectly via a snapshot/rollback flow) Omarchy's
   `limine-snapper.sh` as a normal user.
4. Observe `Error: Limine config not found` even though
   `ls -la /boot/EFI/BOOT/limine.conf` (as root) confirms the file exists.
5. **Isolation step for the report:** reproduce this on a stock archinstall
   + Omarchy system with **no Deck packages involved at all**, to confirm
   this is a generic Omarchy-on-archinstall issue rather than
   Deck/deckarchy-specific — if it reproduces there too, this bug report
   arguably belongs against `basecamp/omarchy` (or its snapper tooling)
   rather than `aorumbayev/deckarchy`, and should be filed there instead, or
   in addition.

**Expected behavior:** `limine-snapper.sh` finds and reads its config
regardless of the ESP's fmask/dmask, e.g. by running its existence/read
check with elevated privileges rather than assuming user-space
readability.

**Actual behavior:** Silently reports the config as missing when it's
actually a permissions problem, which is misleading for debugging (looks
like a missing-file bug, not a permissions bug).

**Suggested scope for the report:** File against whichever repo the
isolation step (step 5 above) points to — most likely `basecamp/omarchy`
rather than `deckarchy`, since the mechanism described here isn't
Deck-specific. Recommend the fix run the existence check with elevated
privileges rather than requiring a global ESP permission loosening, and
flag as a secondary note: `mount -o remount` does **not** re-apply
`fmask`/`dmask` on vfat — a full `umount`/`mount` cycle (or reboot) is
required to change this after the fact, which is a non-obvious trap worth
mentioning for anyone else debugging the same symptom.

---

## Notes for whoever reviews before filing

- Bug 5's actual target repo depends on the isolation reproduction step
  (stock archinstall + Omarchy, no Deck packages) — that hasn't been
  re-verified as part of this drafting pass; confirm before filing which
  repo it belongs against.
- None of these reports propose deckarchy adopt this project's forked
  fixes — PLAN.md is explicit that bugs 1/3/4's actual fixes belong in this
  project's own vendored installer, not upstream. The reports above ask
  upstream to fix the *silent-failure* and *side-effect* behaviors, which
  is a narrower and more upstream-appropriate ask.
- No GitHub issue numbers, links, or filing has occurred — these are text
  only, staged for operator review.

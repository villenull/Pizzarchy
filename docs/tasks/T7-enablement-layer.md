# T7 — The Deck enablement layer (phase 4)

**Objective.** Turn what this project learned making *one* distro Deck-ready
into a reusable layer, so making the *next* one Deck-ready is roughly a day of
Claude-assisted porting plus a hardware validation pass — instead of the sixteen
sessions the first one took.

**Why now and not earlier.** Extracting an abstraction from one example is
guessing. Extracting it from one *finished, released, soak-proven* example is
engineering. Phase 3 has to land first, and the interface below must be derived
from what actually turned out to be distro-specific — which we now know
precisely — rather than from what looks like it ought to be.

---

## What "a day" can and cannot buy — read before committing to the target

Being honest about the goal, because the number shapes the design:

| | Realistic in ~a day? |
|---|---|
| Write a new distro profile against a stable interface | ✅ yes — target ~200 lines, not ~1600 |
| First boot, kernel + firmware, session switch working | ✅ plausible for a close relative (another Arch derivative); a stretch for a different package manager and init/boot chain |
| Conformance suite green | 🟡 only if the suite is genuinely mechanical |
| **Confidently shippable** | ❌ **no.** §5.18 appeared on soak cycle 4, §5.16 needed a journal read across two boots, and three of this project's own *checks* were wrong about themselves. Soak time is wall-clock and cannot be compressed by better abstractions |

**So the target is: a day to "ported and conformance-green", not a day to
"released".** Anything claiming the latter is the silent-success failure this
project exists to prevent. Say so in the porting guide.

The single biggest accelerator is not code — it is **`docs/PROGRESS.md` §7's 38
facts**, each of which cost real time. A new distro that does not re-derive them
starts most of the way up the curve.

---

## Steps

### P4.1 — Write the "Deck-ready" contract

A capability checklist, derived from what we now know rather than invented. Each
row must be **observable**, and each must say whether a machine or a human
decides it. Draft rows, from this project's own findings:

| Capability | Oracle | Who verifies |
|---|---|---|
| Live ISO drives the radio | `ath11k` binds, scan, WPA2, DHCP (§5.1, R-0/R-6) | machine |
| Installer navigable without a keyboard | incl. Wi-Fi passphrase entry (§5.9, T4) | human |
| Neptune-class kernel + firmware | `uname -r`, `ath11k/QCA2066/` present | machine |
| Boot entry survives a kernel update | `LoaderEntrySelected` after reboot (R-13) | machine |
| Audio, incl. Deck speaker tuning | sinks/sources enumerate; DSP topology present | machine + human |
| Gaming Mode session exists and starts | `gamescope-wayland.desktop`, `start-gamescope-session` | machine |
| Two-way session switch | 20-cycle soak, `NRestarts` flat, no `start-limit-hit` | machine |
| Steam's privileged helpers answer | brightness and timezone actually change (§5.15) | machine |
| Rotation on all four surfaces | Limine menu, TTY, greeter, desktop (§5.11) | **human — all four** |
| Controller drives the desktop | mapper binds by capability, virtual kbd appears | machine + human |
| Recovery path documented and exercised | `docs/RECOVERY.md` | human |
| No blanket passwordless root in the image | `stage-audit-privileges` (§5.17) | machine |

### P4.2 — Extract the portable core

Move what does not care about the distro into a neutral library, and **prove the
extraction by making Omarchy consume it** — the existing 62 assertions and the
soak must still pass, unchanged. If they need changing, the extraction is wrong.

Portable today, measured:

- The five `render_*` bodies — `steamos-priv-write`, `steamos-set-timezone`, the
  `steamos-update` stub, Steam's shim, the sddm restart helper. Plain bash, no
  package manager. **`deck-input-mapper.py` is 0% distro-specific.**
- The session-switch *policy*: write autologin config → hand the restart to a
  transient unit → stop → wait for the user manager to drain → start. The
  algorithm is portable; only the unit and config paths are not.
- `test/hw-probe.sh`, the soak script, `sudoers_line_is_blanket`.
- `docs/RECOVERY.md`, and §7's facts.

### P4.3 — Define the profile interface

Derive the hook set **empirically** from what is distro-specific in the current
code (26% of `omarchy-deck-kernel.sh`, 13% of `deck-session.sh`), not by
guessing. Expected shape:

```
pkg_install <logical-name>...     logical -> distro package names
kernel_provide                    obtain a Deck-capable kernel + firmware
boot_set_default <entry>          Limine / GRUB / systemd-boot
initramfs_rebuild                 mkinitcpio / dracut
dm_unit                           sddm.service / gdm.service / greetd
dm_autologin_write <user> <sess>  the DM's own config idiom
session_target                    the WantedBy target for --user units
session_entry_paths               where wayland-sessions live
```

⚠️ **`session_target` is a worked example of why this must be empirical.**
Ours is `wayland-session@hyprland.desktop.target` — a **runtime template
instance** with no file on disk, so `list-unit-files` reports it missing while
it is active. A profile author will get this wrong; the interface docs must say
how to check.

### P4.4 — Generalise the conformance suite

One runner that answers "is this distro Deck-ready?" mechanically and prints the
P4.1 matrix. Most of it already exists and only needs de-hardcoding:
`test/hw-probe.sh`, the 20-cycle soak, `stage-audit-privileges`, the unit suite.

**Requirement, learned the hard way:** every check must distinguish *"I looked
and found nothing"* from *"I looked in the wrong place."* Three of this
project's own checks failed exactly that way — `pgrep -x gamescope` matching a
comm that does not exist, `list-unit-files` on a runtime template, and a release
gate failing on the ordinary admin sudo grant. **A conformance suite that can be
green for the wrong reason is worse than none.** Mutation-test it.

### P4.5 — Write the porting guide and the traps document

The guide is the runbook. The traps document is the higher-value half — the
meta-lessons that generalise beyond any one distro:

- `comm` is truncated to 15 chars, so `pgrep -x` needs measured names.
- `After=` a target you are `WantedBy` creates an ordering cycle, and systemd
  resolves it by *deleting your start job* — silently.
- `StartLimit*` belong in `[Unit]`; in `[Service]` they are ignored with a log
  line nobody reads.
- Steam **falls back** when a helper is missing (`sudo tee`, then `chmod a+w`),
  so absence can look like health on a permissive test rig.
- Reading `/dev/input/event*` blocks until an event arrives.
- `uaccess` vs group membership: check by *opening* the device, not by reading
  permission bits.
- A soak that passes suspiciously fast is measuring the wrong thing.

### P4.6 — Prove it on a second distro

**The only real test of the ~1-day claim.** Pick a distro that is *not* an Arch
derivative, so the interface is exercised rather than flattered — Fedora-based
is the honest hard case. **Measure the actual elapsed time and write it down**,
including where the interface leaked. Feed that back into P4.3 before claiming
the layer works.

### P4.7 — Consider upstreaming

The `steamos-*` helper implementations are the most reusable artefact this
project has and are absent from every non-SteamOS distro. Upstreaming them —
to Bazzite, ChimeraOS, or as a standalone package — is **public action and needs
operator approval** (`docs/START-HERE.md` §3).

---

## Done when

- [ ] The P4.1 contract exists, and every row names its oracle and its verifier
- [ ] Omarchy runs on the extracted core with the existing suite **unchanged**
- [ ] A profile is under ~250 lines and the interface is documented
- [ ] `deck-conformance` prints the matrix and is mutation-tested
- [ ] The porting guide and traps document exist
- [ ] **A second, non-Arch distro is ported, with its real elapsed time recorded**

## Failure modes to watch for

- **Abstracting from one example.** If P4.2 needs the tests changed, the seam is
  wrong. Stop and re-derive.
- **A conformance suite that is green for the wrong reason.** See P4.4.
- **Claiming "a day" for shippable.** It buys ported-and-green. Soak time is
  wall-clock.
- **Redistribution.** This layer is *code*, not images — deliberately. Shipping
  distro images reopens `steamdeck-dsp` (`Proprietary`, no licence text) at
  scale; see `docs/findings/P16-redistribution-and-trademark.md`.

## Escalate if

- The interface needs a hook that cannot be expressed without a package manager
  — that is a sign the boundary is in the wrong place.
- A second distro takes materially longer than a day *after* P4.1–P4.5 are done.
  The claim, not the effort, is what should change.

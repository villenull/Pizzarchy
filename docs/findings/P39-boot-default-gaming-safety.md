# P39 — is the boot-default-gaming escape hatch reachable without a keyboard?

Written 2026-08-17, to answer the precondition `docs/KNOWN-ISSUES.md`
2026.08.17 §2 put on moving `stage-boot-default-gaming` into the install path.

Every claim is labelled **MEASURED** (something was run and the output read),
**READ** (found in a repo file — the path is given), or **INFERRED**.

---

## 0. The short answer

**No. The escape hatch needs a keyboard, and this device has none.** Five
independent confirmations, below. The project's own recovery page has said so
in plain words since it was written.

So the stage could not simply be moved into the install list. What was shipped
instead is a re-assert that **bounds itself**: after two consecutive boots that
reached no usable session, it sets the *desktop* as the default and disarms.
Nobody has to find a keyboard, know the override file exists, or read a
journal.

---

## 1. The escape hatch is not keyboard-free

The hatch is `sudo touch /etc/deck-session/no-boot-default-gaming`, at a TTY.
Each step of getting there fails:

| Step | Verdict | Evidence |
| --- | --- | --- |
| Press Ctrl+Alt+F2 with Deck buttons | **impossible** | **MEASURED.** `src/deck-input-mapper.py`'s uinput device declares 62 keys and *none* of `KEY_LEFTCTRL`, `KEY_LEFTALT`, `KEY_F1..F12`. The kernel silently drops undeclared keys (`src/deck-input-mapper.py:1000`). No `chvt`/`VT_ACTIVATE` anywhere in the mapper. |
| …assuming the mapper is even running | **it is not** | **READ.** `src/deck-session.sh:802` — `MAPPER_WANTED_BY=wayland-session@hyprland.desktop.target`, and the unit's own comment (`src/deck-session.sh:4373-4376`) says it starts "for the Hyprland session and NOT for gamescope". Desktop Mode only: never Gaming Mode, never a TTY, never the greeter. |
| Draw the on-screen keyboard on the console | **unreachable** | **READ.** `src/deck_osk_tty.py` *is* installed to `/usr/local/lib/deck-osk` (`src/deck-session.sh:771,777`) but has no `__main__` and no argparse; the only driver is `--osk-backend=tty`, which only the live ISO's `deck-form.sh` passes. Installed systems get `--osk-backend=layer` (`src/deck-session.sh:792`). The file says this about itself at `src/deck_osk_tty.py:213-217`. |
| Land on a shell instead of a login prompt | **no** | **READ.** The installer deletes the target's getty autologin drop-in: `iso/upstream/configs/airootfs/usr/share/omarchy-iso/orchestrator/phases_impl.py:1447-1448`. A TTY is a username+password prompt. |
| Pick a different session at a greeter | **there is no greeter** | **READ, from a hardware measurement.** Autologin carries `Relogin=true` (`src/deck-session.sh:2025-2041`), added deliberately after soak cycle 4 measured a dead session dropping to "a password prompt with no keyboard to answer it". A session that dies is retried, for ever. |

The project's own words, `docs/RECOVERY.md:186-187`: reaching a terminal
"needs a USB or Bluetooth keyboard, as the on-screen keyboard is not available
on a TTY".

## 2. Nothing earlier intercepts either

- **Limine.** **READ**, `iso/upstream/manifests/fresh-4.json` (a captured
  manifest of a real fresh install): `/boot/limine.conf` ships `#timeout: 3` —
  *commented out* — and the cmdline is `quiet splash loglevel=0`. Nothing in
  this repo sets `timeout:` at all. Whether the menu is displayed, for how
  long, and whether it responds to anything but a keyboard is **unmeasured**.
  This project has three recorded cases of a confidently-written boot-chain
  value being wrong; do not build a recovery story on it without hardware.
- **The Deck's firmware boot manager** (volume rocker + Power) *is* reachable
  with built-in controls on a machine that will not boot — **READ**,
  `docs/RECOVERY.md:71-74`, `docs/findings/R1-10.5.md:10`. But it is a UEFI
  **boot-device chooser**. It cannot select a session. Its only use here is
  reimaging to SteamOS, which is a floor, not an escape.
  ⚠️ **Side finding, on the recovery path:** `docs/RECOVERY.md` says **Volume
  Down** + Power in four places; `docs/findings/R1-10.5.md:10` (operator-
  verified) says **Vol+**. One of them is wrong. Not mine to fix — flagging it.
- **Kernel cmdline.** **MEASURED** (repo-wide grep): the project *writes*
  cmdline parameters but nothing in `src/` ever *reads* `/proc/cmdline` at
  runtime. There is no existing switch to hang this on.

## 3. What the risk actually is — and what it is not

The re-assert does **not** create a boot loop. It widens the door into one that
already exists.

**INFERRED, from two READ facts.** `Relogin=true` (above) plus
`StartLimitIntervalSec=0` from `stage_sddm_resilience` (`src/deck-session.sh:4104-4133`)
mean that for *anyone whose default session is Gaming Mode*, a Gaming Mode that
will not start is already an unbounded retry with no keyboard-free exit. Both
decisions are right on their own terms and neither was reversed.

What the re-assert removes is the **one** case that used to escape: a user
sitting in a working Desktop Mode whose Gaming Mode broke underneath them — a
Mesa or gamescope update is the ordinary way that happens. Before, a reboot
kept them in the desktop. After, it does not.

That case is not exotic, and it is the reason "Gaming Mode is proven now" was
not accepted as sufficient.

## 4. Can "failed to reach a usable Gaming Mode" be detected? Partly. Honestly:

**No probe on this machine can answer "is Gaming Mode *usable*".** A gamescope
that is up with a wedged Steam behind it is indistinguishable from a healthy
one from outside the session — and `docs/KNOWN-ISSUES.md` §3 documents a ~10 s
version of exactly that black screen. **A permanent version of it is scored a
success by what shipped.** That is the residual risk, stated rather than
papered over.

What *is* answerable, and what the shipped helper asks:

> did this boot reach a graphical session whose compositor was still the same
> process 15 s later, **or** end in an orderly shutdown?

- The compositor half uses `pgrep -x 'Hyprland|start-hyprland|gamescope-wl|start-gamescope|uwsm'`
  — **the same list `render_restart_helper` uses**, and it is MEASURED, not
  guessed: an earlier version of that list said `gamescope`, which never
  matches, because the kernel truncates `comm` at 15 characters
  (`src/deck-session.sh:2226-2238`). **Two samples, and the pid must survive
  the gap** — one sample cannot tell a running compositor from one being
  started for the ninth time by autologin, and that restart loop is the exact
  state being bounded.
- The orderly-shutdown half is `ExecStop` on the same unit. **INFERRED, and it
  is the load-bearing asymmetry:** a user who reaches a menu and asks the
  machine to reboot was in control of it; a Deck being held down for ten
  seconds cannot produce that record. Without this half, a user who boots and
  shuts down again inside 60 s is scored a failure — twice in a row and a
  *healthy* Deck gets sent to the desktop.

Both halves are unions, not intersections, so a false *failure* needs both to
miss. Two consecutive failures are required before anything changes.

## 5. Why the failure direction is safe

**Every failure mode of the new machinery degrades to today's shipped
behaviour**, and that is the property that made it shippable before any Deck
has booted with it:

| If this breaks | Result |
| --- | --- |
| the helper is missing or unparseable | the unit fails loudly, sddm still starts, the default is unchanged — today's behaviour |
| the liveness unit never runs, or its probe never matches | two boots later the helper writes `desktop` — which is where an installed Deck lands today |
| the state file cannot be written | the re-assert still runs, unbounded, and says so in the journal |
| the boot id is unreadable | the helper refuses and writes *neither* default |
| the ordering is wrong | the re-assert is a no-op; the Deck boots to the last-used mode — today's bug |

The one genuinely new bad outcome is a **false give-up**: a healthy Deck sent
to Desktop Mode. It is recoverable in one press — `stage-return-icon` and
`stage-menu-row` both put "Return to Gaming Mode" in front of the user — and
the helper writes the user a plain-language explanation, plus the one command
that re-arms it, into `~/.local/state/deck-session/first-boot.log`, which opens
in a text editor with no terminal and no SSH.

## 6. What is still unverified

**No Deck has booted with any of this.** `docs/RECOVERY.md:222-225` already said
that of the unit alone, and it is still true of the bound. In particular these
are untested on hardware and cannot be tested without reboots:

1. that systemd really orders the re-assert before `sddm` on the target;
2. that `ExecStop` runs on a normal reboot and the stamp lands before `/var`
   goes away;
3. that a real gamescope session produces a `comm` in the measured list at
   +45 s and +60 s;
4. that graphical.target does not wait on the liveness unit's sleeps.

The operator's reboot test plan covers all four.

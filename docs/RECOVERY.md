# Returning your Steam Deck to stock SteamOS

**This is the undo button. Read it before you install anything from this
project.**

This project **erases your Steam Deck** and replaces SteamOS with Arch +
Omarchy. That is reversible — Valve publishes an official recovery image that
restores the device to factory SteamOS — but you should know how before you
start, not after something goes wrong.

> 🔑 **Stuck on a lock screen with nothing to type into?** You almost certainly
> do **not** need this page. Skip to
> [Locked out of the screen](#locked-out-of-the-screen-with-nothing-to-type-into)
> — it is one command, and nothing is lost.

> ⚠️ **Status: drafted from Valve's published instructions, NOT yet exercised by
> this project.** `docs/ROADMAP.md` P3.1 performs a real factory reset and will
> replace this with a first-hand account. Until then, treat Valve's own page as
> authoritative and this as orientation. Recovery has never been a blocker for
> the project only because we have never needed it.

## What you need

- A **USB drive or microSD card of at least 16 GB.** The image is over 8 GB
  once written, and the process reformats the drive completely.
- **Another computer** to download and write the image.
- A way to connect the drive: a USB-C hub/dock, a USB-C drive, or the Deck's
  microSD slot.

## Steps

**1. Download the recovery image** from Valve's official Steam Deck recovery
page — [help.steampowered.com](https://help.steampowered.com/en/faqs/view/1B71-EDF2-EB6D-2BB3).
That is the only supported source. Do not use a mirror.

**2. Write it to the drive.**
- **Windows:** Valve recommends [Rufus](https://rufus.ie). Extract the archive
  first if needed, choose your drive as *Device*, *Disk or ISO Image* under
  *Boot selection*, select the image, then Start.
- **Linux/macOS:** Balena Etcher, or `dd` if you are confident.
  ⚠️ `dd` writes to whatever you point it at. Confirm the target device twice —
  getting it wrong destroys the wrong disk.

**3. Power the Deck off completely.** Not sleep — hold Power and choose
Shut Down, or hold Power for ~10 seconds.

**4. Boot the recovery drive.** With the Deck off, **hold Volume Down, then
press and hold Power.** Release both when you hear the boot chime. The boot
manager appears; choose your USB/microSD drive.

**5. Choose a recovery option.** Valve's recovery environment offers several,
from least to most destructive. **To undo this project you want the full
reimage** — the one that repartitions the drive and reinstalls SteamOS, since
this project has replaced the partition layout entirely. The gentler options
(reinstalling SteamOS while keeping user data, or resetting Steam's
configuration) assume a SteamOS install is still present and will not help here.

**6. Let it finish, then let SteamOS update.** After reimaging, the Deck boots
into first-time setup exactly like a new device. Expect it to download a large
SteamOS update on first connection.

## Honest caveats

- **The exact option names in the recovery menu are not reproduced here.** They
  have changed between recovery image revisions, and quoting a stale label is
  worse than describing the intent. Pick the option that reimages the whole
  device.
- **This restores SteamOS, not your data.** Anything on the Deck — games, saves
  not synced to Steam Cloud, screenshots, files in `/home` — is gone the moment
  this project's installer runs. Copy anything you care about off first.
- **A Deck that will not boot at all** still reaches the boot manager with the
  Volume Down + Power combination, because that is firmware-level and does not
  depend on anything this project installs. That is the reason this path is a
  genuine floor rather than a hope.
- **BIOS/firmware is untouched** by this project, so recovery does not need to
  repair it.

## Locked out of the screen, with nothing to type into

**This is not a reason to reinstall anything.** A locked Deck looks
catastrophic and usually is not.

**What you see:** artwork, the words *"Running on tty 2"* (or another number),
possibly a message beginning *"Oopsie daisy, it looks like you locked your
screen but the lockscreen app died"* — and **no password field at all**. There
is nothing to type into, so a keyboard would not help even if you had one.

**Why it happens:** Omarchy locks the session when the device sleeps, so
**pressing the power button can lock it**. If the program that draws the lock
screen is not running or has died, the compositor keeps the lock but nothing
renders a way out of it.

🔴 **CORRECTED 2026-08-11 — the command previously printed here DID NOT WORK,
in two independent ways. It was tried on a Steam Deck for the first time on that
date, against a real lock, and failed both times.**

**1. Over SSH, `hyprctl` has no idea which compositor to talk to.** It exits with
`HYPRLAND_INSTANCE_SIGNATURE not set! (is hyprland running?)`. You must resolve
the instance first:

```bash
ssh steamdeck 'export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t /run/user/1000/hypr/ | head -1); hyprctl eval "hl.clear_crashed_lockscreen()"'
```

⚠️ **If it still says `HYPRLAND_INSTANCE_SIGNATURE not set!` *with* the export**,
the directory was empty and the export quietly set an empty string. That means
no Hyprland is running as uid 1000 — run `ls /run/user/*/hypr/` to find out
which user, if any, has one. It does **not** mean the command is wrong.

> 🔧 **Do not "simplify" this to `hyprctl dispatch` with a bareword argument.**
> On Hyprland 0.56.2 — what the Deck runs — `dispatch` parses its argument as
> **Lua**, so the old space-separated string form is a **parse error**, not an
> unknown-command error. It fails with `')' expected near ...` on stderr and
> otherwise looks like it did nothing. `eval` is the Lua entry point, and it is
> the form measured to work here.
> (`docs/PROGRESS.md` §5.30b, `docs/findings/T10-steam-extest-results.md` §3.)

**2. Even then it REFUSES on a healthy lock**, with:

> `hl.clear_crashed_lockscreen: session is locked with a client, refusing to unlock`

It clears a **crashed** lock screen. It does **not** clear a working one — and a
working one is what you get from the power button, which is the case this page
exists for. ⚠️ **There is no unlock IPC either:** Omarchy's shell exposes
`lock`, `isLocked`, `status`, `preview` and `hidePreview`, and nothing that
releases a lock.

### What actually gets you out, in order

1. **Type your password.** ✅ Since 2026-08-11 the on-screen keyboard renders
   **above** the lock screen and is usable there — press **STEAM+X**, type with
   the trackpads, submit. Verified on the panel (`docs/PROGRESS.md` §5.24).
   ⚠️ If the panel is black, press **QAM** or the **power button**; measured
   2026-08-11, a trackpad touch and the face buttons do **not** wake it.
2. **Attach a USB keyboard** and type the password. Unglamorous and reliable.
3. **Hold Power for about ten seconds** to force a shutdown, then power on
   normally. You lose whatever was unsaved and nothing else.

⚠️ **Killing the lock client is a last resort, not a shortcut.** It converts a
healthy lock into a crashed one, after which the command above does work — but
on Omarchy the lock client is the **whole shell** (`quickshell -n -p
/usr/share/omarchy/shell`), which is **not a systemd unit** (measured: its parent
is the session, not the user manager), so nothing restarts it for you and you
lose the bar and background until you start it by hand.

**If you cannot reach it over SSH**, hold Power for about ten seconds to force
a shutdown, then power on normally. You lose whatever was unsaved, and nothing
else — this does not damage the install and is not a reason to reimage.

> **Provenance, and the lesson.** The original text here was measured in a
> **nested Hyprland on a development machine**, where the lock client genuinely
> had crashed — so the command worked, honestly, in the case it was tested in.
> It was then written up as the answer to "my screen is locked", a *different*
> case, and shipped untested against a real Deck for two sessions.
>
> ⚠️ **A recovery procedure nobody has executed is a hypothesis.** This one
> failed at the first real attempt, twice over, and it is the page someone reads
> when their handheld is unusable. Everything above was run against an actual
> locked Deck on 2026-08-11.
>
> Remaining caveats, unchanged and still true: `hl.clear_crashed_lockscreen()`
> is **Hyprland's name on Hyprland's schedule** and can be renamed upstream; and
> **SSH has to be reachable**, which on a stock install of this project it may
> not be. The ten-second power hold is the floor that needs nothing.
>
> *(Being fixed at the source: the lock-on-sleep behaviour is scheduled to be
> turned off, and the on-screen keyboard taught to draw above a lock screen, so
> this state stops being reachable — `docs/PROGRESS.md` §5.24.)*

## Every reboot goes straight back to Gaming Mode, and Gaming Mode is broken

This is deliberate, and it is undoable in one command.

If `deck-session.sh stage-boot-default-gaming` has been run, a systemd unit
re-asserts Gaming Mode as the default session **before the display manager
starts, on every boot** — so Desktop Mode is a one-shot session, exactly as it
is on stock SteamOS. Steam's own Power → *Switch to Desktop* still works and
still lasts until you reboot.

The cost of that: if Gaming Mode itself will not start, rebooting does not get
you out of it. Autologin means there is no session picker to choose anything
else from.

### Getting out

Reach a terminal with **Ctrl+Alt+F2** — this needs a USB or Bluetooth keyboard,
as the on-screen keyboard is not available on a TTY — then run **one** of:

```bash
sudo touch /etc/deck-session/no-boot-default-gaming
```

The unit checks for that file with `ConditionPathExists=!` and skips itself
while it exists. Nothing is uninstalled, and `systemctl status
deck-boot-default-gaming.service` says out loud that a condition skipped it.
Delete the file to re-arm it.

```bash
sudo systemctl disable deck-boot-default-gaming.service
```

The permanent form. `systemctl enable` puts it back.

Either way, then choose the session you want for the next boot:

```bash
sudo /usr/local/bin/deck-session-select desktop --no-restart
```

### How to tell whether it ran

`systemctl status deck-boot-default-gaming.service`:

- **active (exited)** — it ran and rewrote the default session.
- **inactive**, "Condition check resulted in … being skipped" — the marker file
  above is in place.
- **failed** — it ran and could not set the session; the likeliest cause is that
  the Gaming Mode session is not installed. The Deck still boots. Nothing
  depends on this unit, so a failure is loud (`systemctl --failed` is non-empty
  from then on) and never fatal.

> ⚠️ **Status: not yet exercised on hardware.** The unit's ordering, its
> condition, its escape hatch and the failure behaviour above are asserted by
> `test/unit/test-deck-session*.sh` against a rendered unit and a stubbed
> systemd. No Deck has booted with this unit installed.

## If you are mid-install and it went wrong

The installer wipes and repartitions early. If it failed after that point, the
Deck may not boot into anything. That is expected and recoverable: the recovery
drive boots from firmware regardless of the disk's state. Follow the steps
above.

---

*Not affiliated with, endorsed by, or sponsored by Valve. Steam Deck and SteamOS
are trademarks of Valve Corporation.*

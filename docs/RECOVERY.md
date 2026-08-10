# Returning your Steam Deck to stock SteamOS

**This is the undo button. Read it before you install anything from this
project.**

This project **erases your Steam Deck** and replaces SteamOS with Arch +
Omarchy. That is reversible — Valve publishes an official recovery image that
restores the device to factory SteamOS — but you should know how before you
start, not after something goes wrong.

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

## If you are mid-install and it went wrong

The installer wipes and repartitions early. If it failed after that point, the
Deck may not boot into anything. That is expected and recoverable: the recovery
drive boots from firmware regardless of the disk's state. Follow the steps
above.

---

*Not affiliated with, endorsed by, or sponsored by Valve. Steam Deck and SteamOS
are trademarks of Valve Corporation.*

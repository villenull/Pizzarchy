"""Run Valve's own client bootstrap inside the target, at install time.

SHIPPED AS ``/usr/share/omarchy-iso/orchestrator/deck_steam_bootstrap.py``. The
``steam_bootstrap`` step registered in ``deck_configure.deck_steps``.

🔴 WHY THIS FILE EXISTS: THE BLACK FIRST BOOT IS STEAM INSTALLING ITSELF
========================================================================

``docs/PROGRESS.md`` §5.35, read off the installed Deck's own
``~/.local/share/Steam/logs/bootstrap_log.txt``:

===========  ==========================================================
15:08:15     ``steam -gamepadui`` starts, ``Downloading Update...``
15:09:51     ``Extracting package...``          <- 95 s of downloading
15:10:14     ``Update complete, launching...``  <- 23 s of extracting
15:10:18     the new client starts
===========  ==========================================================

**2m03s of black panel** on a handheld that has just said it finished
installing. The boot chain is not slow -- ``systemd-analyze`` says 39.168 s with
``plymouth-quit`` at 659 ms -- so none of that window is ours to shorten. It is
Valve's updater fetching ~491 MiB and unpacking a ~2.5 GiB client, and the
packaged ``bootstraplinux_ubuntu12_32.tar.xz`` deliberately does not contain it.

This step does that work during the install, in the target, as the target user,
so the first boot has an already-installed client and goes straight to
``Verifying installation... -> Verification complete -> launch``.

🔴 WHAT THIS IS *NOT*: IT IS NOT THE PRE-WARM, AND HERE IS THE DIFFERENCE
=========================================================================

A previous step (``deck_steam_prewarm.py``, removed in ``ac93758``)
pre-*downloaded* the 491 MiB of package files and left the extract and the
relaunch to first boot -- about 30 s of the 123. It was removed because it hung
an install past its own 20-minute budget and reported nothing while it did.

Both of its failures are treated as requirements here, not as risks:

* **The bound is external and it is not a library timeout.** The child is
  started with ``start_new_session=True``, so its pid *is* its process-group id,
  and every exit path ends in ``os.killpg``. Nothing in this module waits on
  Valve's binary to decide to stop. See THE BOUND below -- and note the
  measurement that a naive kill is not enough.
* **A stall is caught in ~2 minutes, not in 10.** The whole-step budget is the
  outer wall; what actually fires on a wedged CDN is the *no-progress*
  watchdog, which watches the updater's own log and the bytes on disk.
* **The installer says what is happening**, every ``PROGRESS_INTERVAL_SECS``,
  with Valve's own percentage.

And the payoff is different in kind: the pre-warm could only ever remove the
download. This removes the whole 2m03s. Measured on a fully bootstrapped home
(dev machine, 2026-08-16): a subsequent ``steam -gamepadui`` reached
``Verification complete`` in **1.5 s**.

MEASURED, NOT INFERRED (dev machine, 2026-08-16, Arch, ``steam 1.0.0.87``)
==========================================================================

Every claim below was produced by running ``/usr/lib/steam/steam`` against
throwaway ``$HOME``\\ s and reading ``bootstrap_log.txt`` back.

1. **It runs FULLY HEADLESS and exits by itself.** Under ``env -i`` -- no
   ``DISPLAY``, no ``WAYLAND_DISPLAY``, no ``DBUS_SESSION_BUS_ADDRESS``, no
   ``XDG_RUNTIME_DIR`` -- a cold run took **86 s** end to end (64 s download,
   8 s extract, 6 s install, then the new client verified and shut down) and
   **exited 0** with **no process left in its group**.

2. **It runs in a namespace with no session, no D-Bus, a private ``/tmp`` and a
   private ``/run``.** Repeated under ``bwrap --unshare-pid --unshare-ipc
   --unshare-uts --dev --proc --tmpfs /tmp --tmpfs /run``: same outcome, 17 s
   with the packages already present, marker written, no survivors. That is the
   closest an unprivileged dev machine gets to ``arch-chroot``; what it does NOT
   prove is listed under WHAT IS STILL UNVERIFIED.

3. 🔴 **THE EXIT CODE IS WORTHLESS.** The same ``--tmpfs /run`` run *without*
   ``/run/systemd/resolve`` bound -- i.e. with DNS broken -- logged
   ``Download failed: http error 0`` and ``Error: Steam needs to be online to
   update.`` and then **exited 0**. This is the same message §5.35 photographed
   on hardware. So this module asserts the **outcome** (an
   ``*.installed`` manifest in ``package/``), exactly as ``deck_pkgs.py`` does
   and for exactly the reason ``docs/findings/P32-steam-never-installed.md``
   gives: a zero exit was already green on a Deck that could not reach Gaming
   Mode.

4. 🔴 **THE UPDATE BRANCH IS CHOSEN BY THE COMMAND LINE, NOT BY THE HARDWARE.**
   Against one already-installed home, only the flags changed::

       (none)        -> client-update.steamstatic.com/steam_client_ubuntu12
       -gamepadui    -> .../steam_client_steamdeck_stable_ubuntu12
       -steamdeck    -> .../steam_client_steamdeck_stable_ubuntu12
       -steamos3     -> .../steam_client_steamdeck_stable_ubuntu12

   and against a *fresh* home ``-gamepadui`` alone chose the **default** branch.
   The difference is ``package/beta``: ``-steamdeck`` writes it
   (``Client beta changed from '' to 'steamdeck_stable'``), and from then on
   every launch -- including a plain ``-gamepadui`` -- follows it. §5.35's
   hardware log names ``steam_client_steamdeck_stable_ubuntu12``, so that is the
   branch the Deck's first boot wants.

   Hence ``BOOTSTRAP_ARGS`` below passes ``-steamdeck``: it makes the branch
   **deterministic and self-consistent** rather than hoping install time and
   first boot agree. ⚠️ This is a real difference from the pre-warm, which
   refused to write a ``beta`` file. The argument has changed with the
   measurement: we are not writing a branch name into a user's home by hand, we
   are running Valve's binary with the flag a Steam Deck is meant to run with,
   and ``steam.sh``'s own ``has_beta_optin`` lists ``steamdeck_stable`` among
   its **stable** names, so this is not a beta opt-in.

   And if it is ever wrong, it is wrong cheaply: the two manifests were
   **byte-identical** on 2026-08-16 (both sha256 ``8c85379c...``, version
   1785799196), so a first boot that asked for the other branch would find every
   package file already in ``package/`` and only extract -- ~17 s instead of
   2m03s.

5. **A killed run is recoverable, and that is the floor.** Killed with SIGKILL
   during ``Installing update...``: no ``.installed`` marker was written, and
   the next run rebuilt the client in 17 s. Killed mid-*download*: the whole
   files already in ``package/`` survive and the next run fetches only what is
   missing. The marker is written last, so a half-done install is never
   mistaken for a done one.

6. 🔴 **THE ENVIRONMENT MUST BE BUILT, NOT INHERITED.** One run leaked
   ``XDG_DATA_HOME`` from the surrounding shell and Valve's launcher resolved
   ``~/.steam/root`` to a *completely different* Steam directory -- it updated
   the wrong installation and left the throwaway home empty. So ``child_env``
   below starts from ``{}``, never from ``os.environ``. ⚠️ This is deliberately
   **unlike** ``deck_session_bake.chroot_env``, which copies the process
   environment; that module runs a shell script that needs PATH and nothing
   else, this one runs a program that reads a dozen XDG variables.

7. ⚠️ **THE RELAUNCHED CLIENT SEGFAULTS, AFTER THE WORK IS DONE, AND VALVE
   GETS A MINIDUMP.** Timed on the last end-to-end run: ``Update complete,
   launching...`` at 13:37:14, the new (Aug 3) client starts at 13:37:15 with no
   display to draw on, shuts down, and ``steam.sh`` reports
   ``Segmentation fault (core dumped)`` at 13:37:16; its crash handler uploads a
   minidump to ``crash.steampowered.com``. The whole run still **exits 0**, and
   the ``.installed`` manifest was written *before* any of it.

   Recorded rather than hidden, because it is a real side effect of this step:
   one crash report to Valve per install, about Valve's own client, from Valve's
   own reporter. ``-nocrashdialog`` is passed so nothing tries to draw; no
   environment variable that suppresses the upload was found in the binary's
   strings, and racing Valve's own relaunch to kill it first is not something
   that could be made deterministic, so it is not claimed.

8. **``XDG_CURRENT_DESKTOP=gamescope`` is a safety belt, and it is Valve's
   own.** ``bin_steam.sh``:49 and ``steam.sh``:121 both return early from
   ``show_message`` when it is set, instead of reaching for ``zenity`` and then
   ``xterm``. On a machine with no display server that is the difference
   between an error line and a hung dialog.

🔴 WHY ``arch-chroot`` CANNOT RUN THIS AT ALL -- THE HARDWARE FAILURE, EXPLAINED
================================================================================

The first hardware install to carry this step **failed**, and the record said
only::

    exit_code: 71
    output:    bin_steam.sh[1]: Setting up Steam content in /home/deck/...

71 appears **exactly once** in Valve's entire client tree: ``steam.sh``:511,
which runs ``steam-runtime-check-requirements`` and exits with its status when
that status is 71. Reproduced verbatim on the dev machine, 2026-08-16, with the
real binary out of the real bootstrap tarball::

    chroot <tree> setpriv --reuid=1000 ... -- steam-runtime-check-requirements
    -> CHECK_REQ_EXIT=71
    -> "Steam now requires user namespaces to be enabled."

And the A/B that names the cause, same kernel, same namespace, same uid, same
binary, one difference::

    outside a chroot, uid 1000:  bwrap --bind / / true   -> 0
    INSIDE  a chroot, uid 1000:  bwrap --bind / / true   -> 1
        "bwrap: No permissions to create a new namespace"
    inside  a chroot, as root:   bwrap --bind / / true   -> 0   (root needs none)

    inside a chroot, uid 1000:   unshare -U true -> "Operation not permitted"

🔴 **This is a kernel rule, not a configuration.** ``create_user_ns()`` refuses
outright when ``current_chrooted()`` -- a process whose root directory is not
the root of its mount namespace may never create a user namespace, on any
kernel, with any sysctl. Valve's launcher hard-gates on a working user
namespace. Therefore **no unprivileged process inside any ``chroot`` can ever
run Valve's launcher**, and ``arch-chroot`` is a ``chroot``. Nothing about the
Deck, the live ISO, DNS or the 32-bit loader was involved: the target had all
of them and the run never reached the network.

Two candidates were tested and disproved rather than assumed: DNS (the run
never got as far as a download -- ``package_bytes`` was 0 and the phase was
``none``), and the 32-bit path (``check_requirements`` runs a **64-bit** binary
and dies before the 32-bit updater is ever executed; the loader check below
stays, because it is still the right check for a different failure).

WHAT REPLACED IT: A PRIVATE MOUNT NAMESPACE AND ``pivot_root``
--------------------------------------------------------------

``ENTER_SCRIPT`` below does what ``arch-chroot`` does -- ``/proc``, ``/sys``,
``/dev``, ``/run``, ``/tmp`` and the live ``/etc/resolv.conf`` -- and then
enters the target with ``pivot_root`` instead of ``chroot``, inside
``unshare --mount --pid --fork``. After a ``pivot_root`` the target IS the root
of the mount namespace, so ``current_chrooted()`` is false and the user
namespace is allowed.

⚠️ It bind-mounts the target onto itself first, and that line is load-bearing
rather than idiomatic. Measured 2026-08-16: ``pivot_root`` onto a mount the
namespace **inherited** failed with ``Invalid argument``, and onto the same path
after ``mount --rbind "$t" "$t"`` it succeeded. Container runtimes do the same
thing for the same reason. ``--rbind`` and not ``--bind``, so a target with a
separate ``/boot`` or ``/home`` keeps them.

Measured end to end on the dev machine, 2026-08-16:

* ``chroot``-shaped entry, uid 1000: ``bwrap`` refused, ``check-requirements``
  exited **71** -- the hardware failure, reproduced off hardware.
* ``pivot_root``-shaped entry, uid 1000: ``bwrap`` **ok**, and a full
  ``/usr/bin/steam -steamdeck -gamepadui`` run logged
  ``steam.sh[1]: Steam client's requirements are satisfied``, reached
  ``Verification complete`` and **exited 0**.

⚠️ ``steam.sh[1]`` -- pid 1. That is the tell that the hardware record was in a
pid namespace too (``arch-chroot`` forks into one), and it is why this module
keeps ``--pid --fork``: killing a namespace's init kills everything in it, which
is a stronger guarantee than the ``/proc`` sweep ever gave.

⚠️ **AND IT COSTS THE SWEEP ITS SIGHT -- SAID HERE RATHER THAN LEFT TO BE
DISCOVERED.** ``processes_rooted_in`` reads ``/proc/<pid>/root`` and matches it
against the target. Measured 2026-08-16: for a process that has ``pivot_root``\
ed into a mount held only in its own namespace, that link reads ``/`` from
outside, not ``/mnt``. So the sweep will now normally report **nothing**, and
``stragglers: []`` in the record means "none seen", not "none possible". What
replaces it is not weaker: every descendant is inside one pid namespace whose
init is our direct child, ``--kill-child`` ties that init's life to
``unshare``'s, and ``stop_process_group`` ends in ``SIGKILL`` to the group --
which an ancestor namespace can always deliver. The sweep is kept because it
still catches anything that somehow escaped into the installer's own view, and
because deleting a check to make a report look clean is the wrong direction.

⚠️ Two side effects of dropping ``arch-chroot``, both deliberate:

* **The mounts are ours now, and they are private.** They live in the
  namespace, so they disappear when it does -- there is no teardown to get
  wrong and no mount left on the target for the installer's final ``umount``
  to trip over.
* **DNS is ours now.** ``arch-chroot`` bind-mounts the live
  ``/etc/resolv.conf`` over the target's, which is what made ``deck_pkgs``'
  ``pacman -Sy`` resolve. ``ENTER_SCRIPT`` does the same thing, following one
  level of symlink exactly as ``arch-chroot`` does, and **says so on stderr**
  when it cannot -- which lands in the record's ``output``.

🔴 AND THE DIAGNOSTIC WAS SWALLOWED TWICE -- FIXED HERE
=======================================================

The message that would have named the cause in one line was thrown away by two
mechanisms stacked:

1. ``show_message`` returns early because we set
   ``XDG_CURRENT_DESKTOP=gamescope`` (measurement 8). It still calls ``log_e``
   first, so the text survives -- but only on stderr.
2. By then ``steam.sh`` has re-opened stderr through ``srt-logger`` into
   ``~/.local/share/Steam/logs/console-linux.txt`` (its ``maybe_open_log``, run
   *before* ``check_requirements``). So our captured stdout keeps exactly one
   line, the one printed before the logger existed -- which is precisely the
   single line the hardware record carried.

``CLAUDE.md`` forbids swallowing a failure, so ``console-linux.txt`` is now read
and recorded: ``launcher_log`` carries its tail and ``launcher_errors`` carries
the lines that name a problem. On the failing install those fields would have
read ``Error: Steam now requires user namespaces to be enabled.`` and this
would have been a five-minute diagnosis instead of a session.

THE BOUND -- WHY A STALL IS IMPOSSIBLE, NOT MERELY BUDGETED
===========================================================

Five mechanisms, in the order they fire:

1. **No-progress watchdog (``STALL_SECS``).** Every poll reads the updater's own
   log length and the total bytes in ``package/``. If neither has moved for
   ``STALL_SECS``, the run is over. The longest legitimately quiet interval
   measured was 8 s (the extract), so this is an order of magnitude of slack.
2. 🔴 **Throughput projection (``THROUGHPUT_CHECK_SECS``).** After two minutes,
   Valve's own ``X of Y KB`` counter is extrapolated over the whole run so far;
   if the download cannot land inside the budget, the run stops **now**. This is
   the pre-warm's actual complaint -- twenty minutes of a progress bar stuck at
   70% -- answered directly: a hopeless connection costs two minutes of evidence
   rather than the whole wall, and the bytes that did arrive are kept.
3. **Whole-step budget (``BUDGET_SECS``).** The outer wall, for anything the two
   above do not catch.
4. **Success stop.** Once the ``.installed`` marker is on disk the work this
   step exists for is done; the child gets ``MARKER_GRACE_SECS`` to shut down on
   its own and is then stopped. We never wait on Valve's process to exit.
5. **``os.killpg`` on every path, then a straggler sweep of the target.**

🔴 The sweep is not defensive tidiness, it is a measurement. After killing only
the direct child, ``srt-logger`` (Valve's log rotator, from the Steam runtime)
was **still running**. Inside ``arch-chroot`` a survivor holds the target's bind
mounts open and can make the installer's final ``umount`` fail -- which would be
this step producing a *worse* outcome than not running at all, the one thing it
is not allowed to do. ``killpg`` on the session did clear it in the measured
runs; the ``/proc``-based sweep exists so that "did clear it" is checked rather
than assumed, and reported when it does not.

``critical=False``, AND THE FLOOR IS TODAY'S BEHAVIOUR
======================================================

Registry entry::

    DeckStep("steam_bootstrap", deck_steam_bootstrap.steam_bootstrap_step, critical=False)

Every failure mode here costs the user **exactly what they have today**: a first
boot that downloads and unpacks Steam on a black screen. There is no state this
step can leave behind that is worse than the state it found:

* a partial ``package/`` is a smaller download for first boot (measured);
* a partial extract has no marker, so first boot redoes it (measured);
* a run that never started leaves the home untouched.

⚠️ ``critical=False`` is not "failures are tolerated". As in ``deck_pkgs.py``,
nothing is swallowed: every outcome is a field in
``/var/log/omarchy-deck-install.json`` and an ``error()`` line in the install
log. ``critical`` governs only an *unexpected* exception escaping this module.

ORDERING -- BEFORE ``steam_seed``, AFTER ``pkgs``
=================================================

* **After ``pkgs``**, because that step is what puts ``steam`` and its
  ``lib32-*`` dependencies on the target. Without them there is no bootstrap
  tarball and no 32-bit loader, and this step records ``skipped-no-steam``.
* 🔴 **Before ``steam_seed``.** Running the real client **writes**
  ``~/.steam/registry.vdf`` -- measured: a fresh run created one containing
  ``HKLM\\...\\SteamPID`` and ``ClientLauncherType``. It was also measured to
  **merge**: a pre-existing file carrying ``HKCU\\...\\CompletedOOBEStage1`` and
  ``language`` survived both a cold bootstrap and a warm re-run intact. So the
  two orders are not equally safe but neither is fatal -- and this one is
  chosen because it makes ``steam_seed`` the **last** writer, so if this step is
  killed while the updater is saving that file, the seed rewrites it whole.

OWNERSHIP
=========

The child runs as the target user (``setpriv --reuid/--regid``), so everything
it creates is theirs by construction rather than by a ``chown`` afterwards --
which is why this module has no ``chown`` at all, unlike the pre-warm it
replaces. That is asserted, not assumed: ``root_owned_under`` walks the tree it
produced (bounded) and any root-owned path is recorded and reported.

``setpriv`` and not ``sudo``, following ``src/deck-session.sh``:4628's measured
precedent verbatim: inside a chroot there is no PAM stack that has been started,
no tty and no audit socket, and ``sudo``'s failure mode there is a write that
silently does not happen.

WHAT IS STILL UNVERIFIED
========================

* ⚠️ **``ENTER_SCRIPT`` as root, on the live ISO.** The dev machine has no
  root, so the sequence was measured inside a user namespace (which grants the
  same capabilities over the same syscalls) rather than as real uid 0. What was
  measured there is the part that decides: ``pivot_root`` succeeds, the user
  namespace is then allowed, ``check_requirements`` passes, and a run against an
  already-bootstrapped home completed and exited 0. What is **not** measured is
  the resolv.conf branch against a real freshly-pacstrapped ``/etc/resolv.conf``,
  and ``mount -t proc`` as real root. Both fail loudly (``set -eu``, stderr into
  the record's ``output``) rather than quietly.
* ⚠️ **A COLD 491 MiB download through ``ENTER_SCRIPT``**, and the reason is
  worth writing down so nobody re-runs it: inside that same user namespace a
  cold bootstrap wedges after ``CProcessEnvironmentManager is ready`` and never
  writes ``bootstrap_log.txt``. Measured **with the entry script and without
  it** -- a plain ``setpriv``/``env -i`` run in the same namespace wedges
  identically, while the same command outside the namespace downloads 493 MiB
  and exits 0. So it is the unprivileged uid mapping, not this module, and the
  entry script is neither exonerated nor implicated by a cold run here. On a
  real installer the child is a real uid 1000 under real root, which is the
  shape that worked.
* **Hardware.** The 2026-08-16 install ran this step and it failed for the
  reason above; the fix has not yet run on the Deck. The acceptance is
  unchanged: a first boot that reaches Gaming Mode in seconds, and the record's
  ``installed_manifest`` field naming ``steam_client_steamdeck_stable_ubuntu12``.
* **How long it takes on the operator's connection.** 491 MiB is 491 MiB
  wherever the wait is placed; this step moves it behind a progress line instead
  of behind a black screen, and gives up rather than hanging. On the dev
  machine's link the whole thing was 86 s.
"""

from __future__ import annotations

import os
import re
import shutil
import signal
import subprocess
import time
from pathlib import Path

from .deck_configure import record_result, sanitize_text
from .ui import error, info

# --- the live side ----------------------------------------------------------

LIVE_ROOT = Path("/")

# --- what has to be on the target before this can run -----------------------

# 🔴 Deliberately duplicated from deck_pkgs.STEAM_BOOTSTRAP_REL rather than
# imported, following the rule deck_pkgs and deck_patches already follow for
# `summarize_output`: neither module imports the other, and a step that reached
# into a sibling for a constant would make the registry's import order
# load-bearing. test/unit/test-deck-steam-bootstrap.py asserts the two strings
# are equal, so the duplication cannot drift silently.
STEAM_BOOTSTRAP_REL = "usr/lib/steam/bootstraplinux_ubuntu12_32.tar.xz"

# Valve's launcher, as the chroot sees it. `/usr/bin/steam` is a two-line shim
# that execs `/usr/lib/steam/steam` (bin_steam.sh), which creates ~/.steam, its
# symlinks and the bootstrap, then runs steam.sh and the updater. We invoke the
# entry point the installed system itself uses rather than the inner binary --
# the same "run the real thing, do not reimplement it" rule as
# deck_session_bake.py decision 1.
STEAM_LAUNCHER_REL = "usr/bin/steam"
STEAM_LAUNCHER_ABS = "/" + STEAM_LAUNCHER_REL

# ⚠️ THE 32-BIT QUESTION, ANSWERED. `ubuntu12_32/steam` is an
# `ELF 32-bit LSB pie executable, Intel i386` whose entire dependency set is
# `linux-gate.so.1`, `libdl`, `librt`, `libm`, `libpthread`, `libc` and the
# loader below -- i.e. `lib32-glibc` and nothing else (`ldd`, 2026-08-16). And
# `lib32-glibc` is a HARD dependency of Arch's `steam` package, so a target that
# passed the `pkgs` step has it. This path is checked anyway, because "the
# dependency implies it" is exactly the kind of inference §5.38 punished.
LOADER_32_REL = "usr/lib/ld-linux.so.2"

# `setpriv` (util-linux, in base) is how we become the target user inside the
# chroot. src/deck-session.sh:4628 argues the choice at length and this module
# does not restate it: no PAM stack has been started in there, there is no tty
# and no audit socket, and `sudo`'s failure mode is a write that does not
# happen.
SETPRIV_REL = "usr/bin/setpriv"

# --- what has to be on the LIVE side before this can run --------------------

# 🔴 The two tools that replace `arch-chroot`. Both are util-linux, which is in
# `base`, so on any sane ISO they are there -- and they are checked anyway,
# because §5.38's lesson is that "the package provides it" is not a measurement
# of the machine. Checked on the LIVE root, unlike everything above: they run
# before the pivot, from the installer's own filesystem.
UNSHARE_REL = "usr/bin/unshare"
PIVOT_ROOT_REL = "usr/bin/pivot_root"
LIVE_TOOL_RELS = (UNSHARE_REL, PIVOT_ROOT_REL)

# --- the target user's side -------------------------------------------------

STEAM_DIR_REL = ".local/share/Steam"
PACKAGE_DIR_REL = f"{STEAM_DIR_REL}/package"
LOG_REL = f"{STEAM_DIR_REL}/logs/bootstrap_log.txt"
# Where the log lands before ~/.steam/steam exists -- seen when the data link is
# missing. Watched as well so the first seconds of a broken run are still
# legible.
FALLBACK_LOG_REL = "Steam/logs/bootstrap_log.txt"

# 🔴 THE LAUNCHER'S OWN LOG, AND THE REASON THIS MODULE READS IT.
# `bootstrap_log.txt` is written by Valve's *updater*. Everything `steam.sh`
# itself says -- including every `show_message` and therefore every reason it
# refuses to start -- goes to stderr, which `steam.sh` has already redirected
# into this file via `srt-logger` before it does any of its checks. The
# 2026-08-16 hardware failure died in `steam.sh`, so `bootstrap_log.txt` was
# empty and the whole diagnosis was in here, unread. See the module docstring.
LAUNCHER_LOG_REL = f"{STEAM_DIR_REL}/logs/console-linux.txt"
FALLBACK_LAUNCHER_LOG_REL = "Steam/logs/console-linux.txt"

# 🔴 THE OUTCOME ASSERTION. Written by the updater only after `Update complete`,
# so its presence means the client is genuinely installed and its absence means
# the work was not finished -- which is the whole reason measurement 3 above
# does not let this module trust an exit code.
INSTALLED_MARKER_GLOB = "steam_client_*.installed"

# The branch marker `-steamdeck` writes. Recorded, never written by us.
BETA_FILE_REL = f"{PACKAGE_DIR_REL}/beta"

# --- how the child is invoked -----------------------------------------------

# `-steamdeck` pins the branch (measurement 4). `-gamepadui` is what §5.35
# measured the Deck's own first boot using, so the run is as close to the real
# one as an install-time run can be. `-nocrashdialog` and `-noassert` keep a
# headless assertion from trying to draw anything.
BOOTSTRAP_ARGS = ("-steamdeck", "-gamepadui", "-nocrashdialog", "-noassert")

# 🔴 Built, never inherited -- measurement 6. A leaked XDG_DATA_HOME sent one
# run at an entirely different Steam installation.
BASE_ENV = {
    "PATH": "/usr/bin:/bin",
    "TERM": "dumb",
    # Valve's own headless escape hatch: bin_steam.sh:49 / steam.sh:121 return
    # from show_message() without reaching for zenity or xterm when this is set.
    "XDG_CURRENT_DESKTOP": "gamescope",
}

# --- bounds -----------------------------------------------------------------
#
# Bounds, not deadlines: they exist so that a wedged CDN cannot hang an
# installer on a device with no terminal and no keyboard. Read THE BOUND in the
# module docstring before changing any of them.

# The outer wall for the whole child run. 491 MiB inside 10 minutes is
# ~0.8 MiB/s; slower than that and first boot finishes the job from whatever
# landed. Measured cold run on the dev machine's link: 86 s.
BUDGET_SECS = 600
# No new bytes in package/ and no new log output for this long: stop. The
# longest legitimately quiet interval measured was 8 s (`Extracting package...`
# to `Installing update...`).
STALL_SECS = 150
# 🔴 GIVE UP EARLY ON A CONNECTION THAT CANNOT FINISH, rather than spending the
# whole budget proving it. After this long, Valve's own `X of Y KB` counter is
# extrapolated; if the download cannot land inside the budget the run stops
# now, keeping whatever arrived. This is the pre-warm's actual complaint --
# twenty minutes of a progress bar at 70% -- answered directly: the wait is
# bounded by ~2 minutes of evidence, not by the wall.
THROUGHPUT_CHECK_SECS = 120
# How long the child gets to shut down on its own once the marker exists.
MARKER_GRACE_SECS = 30
# Between SIGTERM to the group and SIGKILL to the group.
TERM_GRACE_SECS = 5
POLL_SECS = 2.0
PROGRESS_INTERVAL_SECS = 20.0

# Measured: a fully bootstrapped home is 2.5 GiB, of which ~0.5 GiB is the
# package cache. Refusing on a nearly full filesystem is the point -- filling
# the target's root during an install would be far worse than a slow first boot.
MIN_FREE_BYTES = 4 * 1024 * 1024 * 1024

# Caps on the ownership walk, so a pathological tree cannot turn a check into a
# hang of its own.
MAX_OWNERSHIP_ENTRIES = 50_000
MAX_ROOT_OWNED_REPORTED = 5

# Caps on anything that reaches the world-readable install record.
MAX_LINE_CHARS = 300
MAX_OUTPUT_LINES = 12
MAX_WARNINGS = 20

# Where the child's stdout/stderr goes, on the LIVE root. Not into the target:
# it is installer scaffolding, and the part worth keeping is copied into the
# install record, which is on the target and survives the reboot. A fixed name
# rather than a random one so a re-run overwrites instead of accumulating, and
# so an operator watching an install can `tail -f` it.
LIVE_OUTPUT_REL = "tmp/omarchy-deck-steam-bootstrap.out"

# Valve's own progress line, e.g. `Downloading update (72,551 of 502,420 KB)...`
PROGRESS_RE = re.compile(r"Downloading update \(([\d,]+) of ([\d,]+) KB\)")
# The phase lines worth repeating to a human, longest-first so `_phase` reports
# the furthest one reached.
PHASE_LINES = (
    "Update complete",
    "Installing update...",
    "Extracting package...",
    "Downloading update",
    "Verifying installation...",
)

# 🔴 Lines out of `console-linux.txt` worth lifting into the record verbatim.
# Deliberately broad and deliberately capped: the point is that the NEXT
# failure arrives with its own explanation attached rather than as a bare exit
# code, and a support reader can only act on Valve's own words. `Error:` is
# `show_message`'s own prefix (steam.sh:105-119), which is what carried
# "Steam now requires user namespaces to be enabled." off the failing install.
NOTABLE_LOG_RE = re.compile(
    r"(Error:|Warning:|requirements|user namespaces|Couldn't|Cannot |Failed |"
    r"not writable|Permission denied|No such file|internal error)",
    re.IGNORECASE,
)
MAX_NOTABLE_LINES = 8

# deck_wifi's vocabulary (S1's, via src/deck-form.sh). Used ONLY to classify a
# failure, never to skip the attempt -- deck_pkgs.py decision 2's reason: a Deck
# on a dock's ethernet legitimately records `skipped`.
NO_NETWORK_WIFI_STATUSES = ("skipped", "no-hardware", "iwd-failed")

# The record's `status` vocabulary. No overlap, and each one is something an
# operator can act on:
#   installed            the client is bootstrapped; first boot has nothing to do
#   already-installed    it was already bootstrapped, so this run did nothing
#   incomplete           the run ended without a marker: first boot finishes the
#                        job, faster than it would have if bytes landed
#   skipped-deferred     defer_provisioning: no account, so no home to bootstrap
#   skipped-no-steam     the target has no Steam bootstrap tarball
#   skipped-no-multilib  the target cannot execute a 32-bit binary
#   skipped-no-container the live ISO has no unshare/pivot_root, so the target
#                        cannot be entered in a way Valve's launcher can run in
#   skipped-no-space     not enough free space on the target
#   failed               the child could not be started at all
#   error                written by deck_configure's registry on an unforeseen
#                        exception
STATUS_INSTALLED = "installed"
STATUS_ALREADY = "already-installed"
STATUS_INCOMPLETE = "incomplete"
STATUS_DEFERRED = "skipped-deferred"
STATUS_NO_STEAM = "skipped-no-steam"
STATUS_NO_MULTILIB = "skipped-no-multilib"
STATUS_NO_CONTAINER = "skipped-no-container"
STATUS_NO_SPACE = "skipped-no-space"
STATUS_FAILED = "failed"

# Why the run stopped. Separate from `status` on purpose: "the marker is there"
# and "we stopped because the budget expired" are independent facts, and a
# support reader needs both.
STOP_EXITED = "child-exited"
STOP_MARKER = "marker-present"
STOP_STALLED = "no-progress"
STOP_BUDGET = "budget-expired"
STOP_TOO_SLOW = "too-slow-to-finish"


class DeckSteamBootstrapError(Exception):
    """A step-level failure. Non-critical: the install continues and the user
    pays only the first boot this step exists to shorten."""


# ---------------------------------------------------------------------------
# The command and the environment -- their own functions, so the suite can
# assert WHERE and HOW this runs with no chroot, no root and no network
# ---------------------------------------------------------------------------


def child_env(home: str, user: str) -> dict:
    """The environment the updater sees. Built from ``BASE_ENV``, never from
    ``os.environ`` -- measurement 6 in the module docstring."""
    env = dict(BASE_ENV)
    env["HOME"] = home
    env["USER"] = user
    env["LOGNAME"] = user
    return env


# 🔴 THE ENTRY, AND WHY IT IS NOT `arch-chroot`. Read "WHY arch-chroot CANNOT
# RUN THIS AT ALL" in the module docstring first: the kernel refuses
# `unshare(CLONE_NEWUSER)` to any chrooted process, Valve's launcher hard-gates
# on a working user namespace, and that is the whole of the 2026-08-16 exit 71.
#
# `set -eu` and no `|| true` on anything load-bearing: CLAUDE.md's "never
# silently swallow a failure". A failed mount aborts with mount(8)'s own
# message on stderr, which `spawn()` has pointed at a file, which the record
# copies into `output`. The one thing that is allowed to continue is the
# resolv.conf bind, and it prints why.
ENTER_SCRIPT = r"""
set -eu
t=$1
shift

# 🔴 The target, bind-mounted onto itself. This is the container runtimes' own
# first move and it is not decoration: `pivot_root` needs its new root to be a
# mount it is allowed to pivot onto, and a mount this namespace *inherited* can
# be refused (EINVAL) where one it *created* is not. Measured: pivoting onto an
# inherited mount failed, onto a freshly made one succeeded. Recursive, so a
# target with a separate /boot or /home keeps them.
mount --rbind "$t" "$t"

# What arch-chroot provides. `-t proc`, not a bind of the live /proc: this run
# has its own pid namespace (--pid --fork), and a bind would show it the
# installer's process table instead of its own.
mount -t proc proc "$t/proc"
mount --rbind /sys "$t/sys"
mount --rbind /dev "$t/dev"
mount --rbind /run "$t/run"
mount -t tmpfs -o mode=1777,nosuid,nodev tmp "$t/tmp"

# DNS. arch-chroot binds the live resolv.conf over the target's and that is
# what makes pacman resolve in deck_pkgs; without it Valve's updater reaches
# nothing and reports "Steam needs to be online to update." One level of
# symlink, exactly as arch-chroot handles it. Never fatal, always explained.
if [ -e /etc/resolv.conf ]; then
	rc="$t/etc/resolv.conf"
	if [ -L "$rc" ]; then
		link=$(readlink "$rc")
		case "$link" in
		/*) rc="$t$link" ;;
		*) rc="$t/etc/$link" ;;
		esac
	fi
	if [ ! -f "$rc" ]; then
		mkdir -p "$(dirname "$rc")" 2>/dev/null || true
		: >"$rc" 2>/dev/null || true
	fi
	if ! mount --bind /etc/resolv.conf "$rc" 2>/dev/null; then
		echo "deck-steam-bootstrap: could not bind /etc/resolv.conf onto $rc --" \
			"Valve's updater may not be able to resolve its CDN" >&2
	fi
else
	echo "deck-steam-bootstrap: the live system has no /etc/resolv.conf --" \
		"Valve's updater may not be able to resolve its CDN" >&2
fi

# 🔴 pivot_root, not chroot. After this the target IS the root of this mount
# namespace, so the kernel's current_chrooted() test is false and an
# unprivileged user namespace is allowed. `pivot_root . .` is the container
# runtimes' form and needs no scratch directory in the target; the old root
# ends up stacked at the same point and is detached immediately.
cd "$t"
pivot_root . .
umount -l .
cd /
exec "$@"
"""


def bootstrap_command(target, uid: int, gid: int, home: str, user: str) -> list[str]:
    """The exact argv this step runs.

    Inside the target for ``deck_patches.chroot_command``'s reasons: the
    launcher, the 32-bit loader, the bootstrap tarball and the user's home are
    all in there, and every absolute path the updater writes into ``~/.steam/*``
    has to be a path the *installed* system will resolve. Run from the live side
    it would bootstrap the ISO.

    🔴 But **not** via ``arch-chroot``, and that is not a preference: a chroot
    makes Valve's launcher fail, measured, with the exit code the first hardware
    install recorded. ``ENTER_SCRIPT`` under ``unshare --mount --pid --fork``
    reproduces ``arch-chroot``'s mounts and then enters with ``pivot_root``.

    ``env -i`` inside as well as a built environment out here: ``unshare``
    passes its own environment through, so without it the installer's variables
    would reach the updater.
    """
    return [
        "unshare",
        "--mount",
        "--pid",
        "--fork",
        # 🔴 `--kill-child` is the pid namespace's answer to the straggler
        # problem, and it is not optional here. Inside a pid namespace the
        # process we exec becomes pid 1, and pid_namespaces(7) says an unhandled
        # SIGTERM is IGNORED by a namespace's init even when it comes from an
        # ancestor -- so `stop_process_group`'s polite first signal would do
        # nothing on its own. This makes `unshare`'s own death (which SIGTERM
        # does cause) SIGKILL the namespace's init, and killing a namespace's
        # init kills everything in it. `stop_process_group`'s SIGKILL is still
        # the backstop; this just means the first signal is not a no-op.
        "--kill-child",
        "--propagation",
        "private",
        "--",
        "/bin/sh",
        "-c",
        ENTER_SCRIPT,
        "deck-steam-bootstrap",
        str(target),
        "setpriv",
        f"--reuid={uid}",
        f"--regid={gid}",
        "--clear-groups",
        "--",
        "env",
        "-i",
        *[f"{key}={value}" for key, value in sorted(child_env(home, user).items())],
        STEAM_LAUNCHER_ABS,
        *BOOTSTRAP_ARGS,
    ]


# ---------------------------------------------------------------------------
# Reading the target's state -- pure, so the suite drives every branch
# ---------------------------------------------------------------------------


def installed_markers(package_dir: Path) -> list[str]:
    """The ``steam_client_*.installed`` files in ``package/``, sorted.

    🔴 This is the outcome assertion. Measurement 3: the updater exits 0 after
    printing ``Error: Steam needs to be online to update.``, so the only honest
    question is whether the manifest it claims to have installed is on disk.
    """
    try:
        return sorted(p.name for p in package_dir.glob(INSTALLED_MARKER_GLOB) if p.is_file())
    except OSError:
        return []


def package_bytes(package_dir: Path) -> int:
    """Total bytes of ``package/``. Half of the no-progress watchdog's signal;
    the other half is the log. Errors read as zero rather than raising -- the
    directory legitimately does not exist until the updater makes it."""
    total = 0
    try:
        for entry in package_dir.iterdir():
            try:
                if entry.is_file():
                    total += entry.stat().st_size
            except OSError:
                continue
    except OSError:
        return 0
    return total


def read_log_tail(home_on_target: Path, limit: int = 64 * 1024) -> str:
    """The tail of Valve's own bootstrap log, from whichever path it is using.

    Two paths because the log moves: until ``~/.steam/steam`` exists it lands
    under ``~/Steam/logs`` (seen when a run started with no data link). Reading
    only the canonical one would make the first seconds of a broken run
    invisible, which is the opposite of what this module is for.
    """
    for rel in (LOG_REL, FALLBACK_LOG_REL):
        path = home_on_target / rel
        try:
            size = path.stat().st_size
            with open(path, "rb") as handle:
                if size > limit:
                    handle.seek(size - limit)
                return handle.read().decode("utf-8", "replace")
        except OSError:
            continue
    return ""


def read_launcher_log_tail(home_on_target: Path, limit: int = 64 * 1024) -> str:
    """The tail of ``console-linux.txt`` -- ``steam.sh``'s own output.

    🔴 This is the file the 2026-08-16 hardware failure was hiding in. Valve's
    launcher redirects its stderr into it through ``srt-logger`` *before* it
    runs any of its checks, so from that moment on everything it says about why
    it will not start goes here and nowhere else. Reading only the updater's
    ``bootstrap_log.txt`` leaves a failure that never reached the updater
    looking like a bare exit code, which is exactly what happened.
    """
    for rel in (LAUNCHER_LOG_REL, FALLBACK_LAUNCHER_LOG_REL):
        path = home_on_target / rel
        try:
            size = path.stat().st_size
            with open(path, "rb") as handle:
                if size > limit:
                    handle.seek(size - limit)
                return handle.read().decode("utf-8", "replace")
        except OSError:
            continue
    return ""


def launcher_log_size(home_on_target: Path) -> int:
    """Bytes in ``console-linux.txt``, for the no-progress watchdog.

    Part of the progress signature as well as of the record: ``steam.sh`` spends
    its first seconds updating the Steam runtime and writing *here*, before
    ``package/`` or ``bootstrap_log.txt`` exist at all. Without this the
    watchdog is blind to a run that is working but has not reached the updater.
    """
    for rel in (LAUNCHER_LOG_REL, FALLBACK_LAUNCHER_LOG_REL):
        try:
            return (home_on_target / rel).stat().st_size
        except OSError:
            continue
    return 0


def notable_lines(text: str) -> list[str]:
    """The lines of a log that name a problem, newest last, capped.

    Not a summary and not a diagnosis: a filter, so that the one line Valve
    printed about why it refused to start reaches
    ``/var/log/omarchy-deck-install.json`` instead of being 4 000 lines above
    whatever the tail happened to catch.
    """
    hits = [
        line.strip()
        for line in (text or "").splitlines()
        if line.strip() and NOTABLE_LOG_RE.search(line)
    ]
    return [sanitize_text(line, limit=MAX_LINE_CHARS) for line in hits[-MAX_NOTABLE_LINES:]]


def log_size(home_on_target: Path) -> int:
    """Bytes in Valve's bootstrap log, from whichever path it is using.

    🔴 The *file's* size, not the length of the tail this module reads. The tail
    is capped, so once the log passes that cap its length stops changing and
    would silently stop being a progress signal -- a watchdog that quietly
    blinds itself is worse than no watchdog.
    """
    for rel in (LOG_REL, FALLBACK_LOG_REL):
        try:
            return (home_on_target / rel).stat().st_size
        except OSError:
            continue
    return 0


def progress_line(log_text: str) -> str | None:
    """A one-line human summary of where the updater has got to, or ``None``.

    Valve's own numbers, not ours: a percentage this module computed would be a
    second opinion about a process we do not control.
    """
    if not log_text:
        return None
    matches = PROGRESS_RE.findall(log_text)
    phase = _phase(log_text)
    if matches:
        done, total = matches[-1]
        try:
            pct = 100.0 * int(done.replace(",", "")) / max(1, int(total.replace(",", "")))
        except ValueError:
            pct = 0.0
        if phase and phase != "Downloading update":
            return f"{phase} (downloaded {done} of {total} KB)"
        return f"downloading Steam's client update: {done} of {total} KB ({pct:.0f}%)"
    return phase


def projected_download_secs(log_text: str, elapsed: float) -> float | None:
    """How much longer the download needs, from Valve's own counter.

    ``None`` when there is nothing to extrapolate from -- no progress line yet,
    or the download is already complete. Deliberately extrapolates from the
    *whole* run rather than from a window: a burst of speed at the start should
    not be allowed to argue that a slow connection will finish.
    """
    matches = PROGRESS_RE.findall(log_text or "")
    if not matches or elapsed <= 0:
        return None
    try:
        done = int(matches[-1][0].replace(",", ""))
        total = int(matches[-1][1].replace(",", ""))
    except ValueError:
        return None
    if done <= 0 or done >= total:
        return None
    return (total - done) * (elapsed / done)


def _phase(log_text: str) -> str | None:
    for phase in PHASE_LINES:
        if phase in log_text:
            return phase
    return None


def root_owned_under(root: Path) -> tuple[list[str], int, str | None]:
    """(root-owned paths, entries walked, warning).

    The child runs as the user, so this should always come back empty; it is
    checked because "it runs as the user therefore the files are the user's" is
    an inference, and this project has paid for inferences. Bounded so a huge or
    pathological tree cannot turn a check into a hang.
    """
    found: list[str] = []
    seen = 0
    warning: str | None = None
    try:
        for dirpath, dirnames, filenames in os.walk(root, onerror=None):
            for name in list(dirnames) + list(filenames):
                seen += 1
                if seen > MAX_OWNERSHIP_ENTRIES:
                    warning = (
                        f"stopped the ownership check after {MAX_OWNERSHIP_ENTRIES} entries; "
                        "what was checked was clean"
                    )
                    return found, seen, warning
                path = Path(dirpath) / name
                try:
                    if path.lstat().st_uid == 0:
                        if len(found) < MAX_ROOT_OWNED_REPORTED:
                            found.append(str(path))
                except OSError:
                    continue
    except OSError as exc:
        warning = f"could not walk {root} to check ownership: {exc}"
    return found, seen, warning


def read_wifi_status(live_root=LIVE_ROOT) -> str:
    """What the installer's Wi-Fi screen recorded. Classification only.

    Same shape and same defence as ``deck_pkgs.read_wifi_status``: this step
    must not be able to fail because the *reporting* half of a sibling module
    did, and ``unknown`` classifies a failure as the louder outcome.
    """
    try:
        from . import deck_wifi

        fields, _ = deck_wifi.read_outcome(live_root)
        return fields.get("status", "missing") or "missing"
    except Exception:  # noqa: BLE001 -- deliberate, see the docstring
        return "unknown"


# ---------------------------------------------------------------------------
# Stopping it -- the part the pre-warm did not have
# ---------------------------------------------------------------------------


def stop_process_group(proc, pgid: int) -> None:
    """SIGTERM the whole group, then SIGKILL it. Never waits indefinitely.

    The group, not the process: ``bin_steam.sh`` -> ``steam.sh`` -> the updater
    -> ``-child-update-ui`` -> ``srt-logger`` is five processes, and killing
    only the one we spawned demonstrably leaves ``srt-logger`` behind (see THE
    BOUND). ``start_new_session=True`` at spawn time is what makes ``pgid``
    equal to ``proc.pid`` and therefore knowable at all -- reading it back out
    of ``ps`` after the fact is a race this module lost once while it was being
    written.
    """
    for sig, grace in ((signal.SIGTERM, TERM_GRACE_SECS), (signal.SIGKILL, TERM_GRACE_SECS)):
        if proc.poll() is not None and not _group_alive(pgid):
            return
        try:
            os.killpg(pgid, sig)
        except (ProcessLookupError, PermissionError):
            pass
        try:
            proc.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            continue
        except Exception:  # noqa: BLE001 -- a reaped child raises on some paths
            pass


def _group_alive(pgid: int) -> bool:
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def processes_rooted_in(target, proc_root=Path("/proc")) -> list[int]:
    """PIDs whose filesystem root is inside ``target``.

    🔴 The point is the installer's final ``umount``. A survivor inside the
    chroot holds the target's bind mounts open, and this step is not allowed to
    make anything worse than not running. Our own pid and pid 1 are never
    included; anything unreadable is skipped, because a process that disappeared
    between listdir and readlink is the normal case, not an error.
    """
    target = os.path.realpath(str(target)).rstrip("/") or "/"
    if target == "/":
        # A target of "/" would match every process on the machine. Refuse.
        return []
    mine = os.getpid()
    found: list[int] = []
    try:
        names = os.listdir(proc_root)
    except OSError:
        return []
    for name in names:
        if not name.isdigit():
            continue
        pid = int(name)
        if pid in (1, mine):
            continue
        try:
            root = os.readlink(proc_root / name / "root")
        except OSError:
            continue
        if root == target or root.startswith(target + "/"):
            found.append(pid)
    return sorted(found)


def sweep_target(target) -> list[int]:
    """Kill anything still rooted inside the target. Returns what it killed."""
    victims = processes_rooted_in(target)
    for pid in victims:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            continue
    return victims


# ---------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------


def spawn(argv: list[str], output_path: Path | None = None):
    """Start the child in its own session. The single seam the suite replaces.

    ``start_new_session=True`` is not a detail: ``subprocess`` calls
    ``setsid()`` in the *child* between fork and exec, so ``proc.pid`` IS the
    process-group id, deterministically. That is what makes ``os.killpg``
    correct without asking ``ps`` anything -- and reading the pgid back out of
    ``ps`` afterwards is a race this module lost once while it was being
    written, so it is not an option.

    Output goes to a **file**, not to a pipe and not to ``/dev/null``. A pipe
    nobody drains would let the child block on a full buffer -- a hang this
    module would have caused itself. ``/dev/null`` would throw away the one
    diagnosis available when the launcher dies before it writes a
    ``bootstrap_log.txt`` at all (a missing 32-bit loader prints to stderr and
    nothing else).
    """
    if output_path is None:
        stream = subprocess.DEVNULL
        handle = None
    else:
        handle = open(output_path, "wb")
        stream = handle
    try:
        return subprocess.Popen(  # noqa: S603
            argv,
            stdout=stream,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
    finally:
        if handle is not None:
            handle.close()


def run_bootstrap(
    argv: list[str],
    home_on_target: Path,
    record: dict,
    *,
    budget_secs: int = BUDGET_SECS,
    stall_secs: int = STALL_SECS,
    output_path: Path | None = None,
    spawner=None,
    clock=time.monotonic,
    sleeper=time.sleep,
    emit=info,
) -> str:
    """Run the child under every bound, filling ``record``. Returns the reason
    it stopped (one of the ``STOP_*`` constants).

    The loop never waits on the child: it polls, and *it* decides when the run
    is over. ``spawner``/``clock``/``sleeper``/``emit`` are injected so the
    suite can drive a stall, a budget expiry and a success without a subprocess
    and without wall-clock time.
    """
    if spawner is None:
        spawner = spawn

    package_dir = home_on_target / PACKAGE_DIR_REL
    proc = spawner(argv, output_path)
    pgid = proc.pid  # start_new_session=True makes this exact -- see spawn()
    record["pid"] = pgid

    started = clock()
    deadline = started + budget_secs
    last_change = started
    last_report = started
    last_signature = (0, 0, 0)
    marker_since: float | None = None
    projection_checked = False
    reason = STOP_EXITED

    try:
        while True:
            if proc.poll() is not None:
                reason = STOP_EXITED
                record["exit_code"] = proc.returncode
                break

            now = clock()
            log_text = read_log_tail(home_on_target)
            # Three signals, not two: `steam.sh` writes console-linux.txt for
            # seconds before `package/` or bootstrap_log.txt exist, and a
            # watchdog that cannot see that is blind exactly while the runtime
            # is being set up.
            signature = (
                package_bytes(package_dir),
                log_size(home_on_target),
                launcher_log_size(home_on_target),
            )
            if signature != last_signature:
                last_signature = signature
                last_change = now

            markers = installed_markers(package_dir)
            if markers:
                if marker_since is None:
                    marker_since = now
                    emit(
                        "Steam client installed on the target "
                        f"({', '.join(markers)}); letting it finish"
                    )
                elif now - marker_since >= MARKER_GRACE_SECS:
                    reason = STOP_MARKER
                    break

            if now - last_report >= PROGRESS_INTERVAL_SECS:
                last_report = now
                line = progress_line(log_text)
                emit(
                    "Steam client bootstrap: "
                    + (line or "starting")
                    + f" ({int(now - started)}s of {budget_secs}s)"
                )

            if now - last_change >= stall_secs:
                reason = STOP_STALLED
                break
            if now >= deadline:
                reason = STOP_BUDGET
                break

            elapsed = now - started
            if elapsed >= THROUGHPUT_CHECK_SECS and not projection_checked:
                projection_checked = True
                remaining = projected_download_secs(log_text, elapsed)
                if remaining is not None:
                    record["projected_download_secs"] = int(remaining)
                    if elapsed + remaining > budget_secs:
                        emit(
                            "Steam's client update cannot finish inside this installer's "
                            f"budget on this connection (about {int(remaining / 60)} more "
                            "minutes). Stopping; the first boot will finish the download."
                        )
                        reason = STOP_TOO_SLOW
                        break

            sleeper(POLL_SECS)
    finally:
        stop_process_group(proc, pgid)

    record["seconds"] = int(clock() - started)
    record["stopped_because"] = reason
    if output_path is not None:
        record["output"] = summarize_output(_read_tail(output_path)) or None
    return reason


def _read_tail(path: Path, limit: int = 16 * 1024) -> str:
    try:
        size = path.stat().st_size
        with open(path, "rb") as handle:
            if size > limit:
                handle.seek(size - limit)
            return handle.read().decode("utf-8", "replace")
    except OSError:
        return ""


def summarize_output(text: str) -> str:
    """The last few non-blank lines, sanitised and joined with ' | '.

    Copied from ``deck_pkgs.summarize_output`` on purpose -- the two modules do
    not import each other, and two support logs that read differently for no
    reason are two things to learn. Joined rather than newline-separated because
    ``sanitize_text`` deletes control bytes and raw concatenation would glue two
    messages into one word.
    """
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if not lines:
        return ""
    return " | ".join(sanitize_text(line, limit=MAX_LINE_CHARS) for line in lines[-MAX_OUTPUT_LINES:])


# ---------------------------------------------------------------------------
# The step
# ---------------------------------------------------------------------------


def bootstrap_steam(ctx, live_root=LIVE_ROOT, *, runner=None, budget_secs: int = BUDGET_SECS) -> dict:
    """Bootstrap Steam's client into the target user's home. Returns the record.

    ``runner`` is injectable for the same reason ``deck_pkgs.fetch_packages``'s
    is, and defaulted to ``None`` rather than to the function object for the
    same reason: a default argument binds at *definition* time, so replacing the
    module attribute would silently keep calling the real one.
    """
    if runner is None:
        runner = run_bootstrap
    target = Path(ctx.target)

    record: dict = {
        "status": None,
        "user": None,
        "home": None,
        "command": None,
        "installed_manifest": None,
        "markers_before": [],
        "markers_after": [],
        "beta": None,
        "package_bytes": 0,
        "seconds": 0,
        "exit_code": None,
        "stopped_because": None,
        "projected_download_secs": None,
        "pid": None,
        "wifi_status": None,
        "root_owned": [],
        "stragglers": [],
        "phase": None,
        "output": None,
        # 🔴 The two fields the 2026-08-16 failure needed and did not have.
        "launcher_log": None,
        "launcher_errors": [],
        "error": None,
        "warnings": [],
    }
    warnings: list[str] = record["warnings"]

    try:
        _bootstrap(ctx, target, live_root, record, warnings, runner, budget_secs)
    except (DeckSteamBootstrapError, OSError) as exc:
        record["status"] = STATUS_FAILED
        record["error"] = sanitize_text(f"{type(exc).__name__}: {exc}", limit=400)

    if record["error"]:
        error(f"Steam client bootstrap: {record['error']}")
    for warning in warnings[:MAX_WARNINGS]:
        error(f"Steam client bootstrap: {warning}")
    if len(warnings) > MAX_WARNINGS:
        # Truncated, and it SAYS it was truncated. A cap that quietly drops the
        # tail is the silent-failure shape CLAUDE.md bans; the record keeps them
        # all either way.
        error(
            f"Steam client bootstrap: {len(warnings) - MAX_WARNINGS} further warning(s) are "
            "in the install record and were not printed"
        )
    return record


def _bootstrap(ctx, target: Path, live_root, record: dict, warnings: list[str], runner, budget_secs: int) -> None:
    from . import deck_user

    # --- who it is for ------------------------------------------------------
    try:
        user, user_warnings = deck_user.resolve_target_user(ctx)
    except deck_user.DeckUserDeferred as exc:
        # No account exists yet by design, so there is no home to bootstrap
        # into and no uid to run as. Bootstrapping into /etc/skel would mean
        # copying 2.5 GiB at useradd time on a machine trying to reach a
        # desktop -- strictly worse than the black screen this step removes.
        record["status"] = STATUS_DEFERRED
        record["error"] = sanitize_text(
            f"no Steam client bootstrap on a defer_provisioning install: {exc}. "
            "First boot downloads and unpacks the client as it does today (~2 minutes).",
            limit=400,
        )
        return
    except deck_user.DeckUserError as exc:
        record["status"] = STATUS_FAILED
        record["error"] = sanitize_text(f"{type(exc).__name__}: {exc}", limit=400)
        return

    warnings.extend(user_warnings)
    record["user"] = sanitize_text(user.name)
    record["home"] = user.home
    home_on_target = user.home_on(target)
    package_dir = home_on_target / PACKAGE_DIR_REL

    # --- can this target run it at all? -------------------------------------
    if not (target / STEAM_BOOTSTRAP_REL).is_file():
        # deck_pkgs fetches `steam` online and records its own outcome. With no
        # bootstrap tarball there is no client to bootstrap, and its first-boot
        # notice already tells the machine's owner about the real problem.
        record["status"] = STATUS_NO_STEAM
        record["error"] = sanitize_text(
            f"/{STEAM_BOOTSTRAP_REL} is not on the target, so there is no Steam client to "
            "bootstrap. See the 'pkgs' section of this record.",
            limit=400,
        )
        return

    missing_tools = [
        rel
        for rel in (STEAM_LAUNCHER_REL, LOADER_32_REL, SETPRIV_REL)
        if not (target / rel).exists()
    ]
    if missing_tools:
        # 🔴 The 32-bit loader is the one that matters and it is checked, not
        # assumed: `lib32-glibc` is a hard dependency of `steam`, but §5.38's
        # lesson is that a dependency graph is not a measurement of the machine.
        record["status"] = STATUS_NO_MULTILIB
        record["error"] = sanitize_text(
            "the target is missing " + ", ".join("/" + rel for rel in missing_tools)
            + " -- Valve's updater is a 32-bit i386 binary and cannot be executed there. "
            "First boot behaves as it does today.",
            limit=400,
        )
        return

    missing_live = [
        rel for rel in LIVE_TOOL_RELS if not (Path(live_root) / rel).exists()
    ]
    if missing_live:
        # 🔴 Not a nicety. `chroot` is the one way of entering the target that
        # provably cannot work here (see the docstring), so if the live system
        # cannot do the pivot there is nothing to fall back to -- and saying
        # that is better than running a command that is known to exit 71.
        record["status"] = STATUS_NO_CONTAINER
        record["error"] = sanitize_text(
            "the live system is missing " + ", ".join("/" + rel for rel in missing_live)
            + " -- Valve's launcher refuses to start inside a chroot (it needs a user "
            "namespace, which the kernel denies to any chrooted process), and without "
            "these the target cannot be entered any other way. First boot behaves as it "
            "does today.",
            limit=400,
        )
        return

    record["wifi_status"] = read_wifi_status(live_root)

    # --- the idempotent path ------------------------------------------------
    record["markers_before"] = installed_markers(package_dir)
    if record["markers_before"]:
        # CLAUDE.md requires re-runnable scripts, and the SSH iterate-in-place
        # loop depends on a re-run being a genuine no-op: no network, no
        # subprocess, no 491 MiB.
        record["status"] = STATUS_ALREADY
        record["markers_after"] = record["markers_before"]
        record["installed_manifest"] = record["markers_before"][0]
        record["package_bytes"] = package_bytes(package_dir)
        record["beta"] = _read_beta(target, user)
        info(
            f"Steam's client is already bootstrapped in {user.name}'s home "
            f"({', '.join(record['markers_before'])}); nothing to download"
        )
        return

    # --- room for it --------------------------------------------------------
    if not home_on_target.is_dir():
        record["status"] = STATUS_FAILED
        record["error"] = sanitize_text(
            f"{user.name}'s home {user.home} does not exist on the target, so there is "
            "nowhere to bootstrap Steam into.",
            limit=400,
        )
        return
    try:
        free = shutil.disk_usage(home_on_target).free
    except OSError as exc:
        free = None
        warnings.append(f"could not measure free space on the target: {exc}")
    if free is not None and free < MIN_FREE_BYTES:
        record["status"] = STATUS_NO_SPACE
        record["error"] = sanitize_text(
            f"the target has {free} bytes free and an installed Steam client is about "
            f"{MIN_FREE_BYTES} with headroom. Skipped rather than filling the disk; first "
            "boot behaves as it does today.",
            limit=400,
        )
        return

    # --- run it -------------------------------------------------------------
    argv = bootstrap_command(target, user.uid, user.gid, user.home, user.name)
    # The entry script is ~2 KB of shell and comments; spelling it out here
    # would bury the part of the record a human reads (who it ran as, with what
    # flags, against what target) under it. The script itself is in this file,
    # under one name, which is where a reader should go for it.
    record["command"] = " ".join(
        "<ENTER_SCRIPT>" if part == ENTER_SCRIPT else part for part in argv
    )

    info(
        f"Installing Steam's client update into {user.name}'s home now, so the first boot "
        "does not spend two minutes on a black screen doing it. This needs the internet "
        f"(the Wi-Fi screen recorded status={record['wifi_status']}) and about 500 MiB; "
        f"it gives up after {budget_secs}s and lets the first boot finish instead."
    )

    output_path = Path(live_root) / LIVE_OUTPUT_REL
    try:
        output_path.parent.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        warnings.append(f"could not create {output_path.parent}: {exc}")
        output_path = None

    reason = runner(argv, home_on_target, record, budget_secs=budget_secs, output_path=output_path)

    # 🔴 The sweep, and it runs whatever happened. A survivor inside the chroot
    # holds the target's bind mounts open.
    stragglers = sweep_target(target)
    record["stragglers"] = stragglers
    if stragglers:
        warnings.append(
            f"{len(stragglers)} process(es) were still running inside the target after the "
            f"bootstrap and were killed (pids {', '.join(str(p) for p in stragglers)}). "
            "They would have held the target's mounts open."
        )

    # --- what actually happened --------------------------------------------
    record["markers_after"] = installed_markers(package_dir)
    record["package_bytes"] = package_bytes(package_dir)
    record["beta"] = _read_beta(target, user)
    record["phase"] = sanitize_text(_phase(read_log_tail(home_on_target)) or "", limit=MAX_LINE_CHARS) or None

    # 🔴 THE DIAGNOSTIC, KEPT. Everything `steam.sh` says about why it refused
    # to start is in console-linux.txt and nowhere else -- see the module
    # docstring. Recorded whatever happened, because a run that "worked" and a
    # run that did not are read out of the same file.
    launcher_text = read_launcher_log_tail(home_on_target)
    record["launcher_log"] = summarize_output(launcher_text) or None
    record["launcher_errors"] = notable_lines(launcher_text)

    owned, _, own_warning = root_owned_under(home_on_target / STEAM_DIR_REL)
    record["root_owned"] = [sanitize_text(p, limit=MAX_LINE_CHARS) for p in owned]
    if own_warning:
        warnings.append(own_warning)
    if owned:
        warnings.append(
            "root owns "
            + ", ".join(record["root_owned"])
            + f" inside {user.name}'s home. The client was supposed to be written as "
            "them; Steam may not be able to update itself."
        )

    if record["markers_after"]:
        # 🔴 THE OUTCOME ASSERTION, and measurement 3 is why it is not the exit
        # code: the updater exits 0 after 'Steam needs to be online to update.'
        record["status"] = STATUS_INSTALLED
        record["installed_manifest"] = record["markers_after"][0]
        info(
            f"Steam's client is installed in {user.name}'s home "
            f"({record['installed_manifest']}, {record['package_bytes'] // (1024 * 1024)} MiB "
            f"cached, {record['seconds']}s). First boot should reach Gaming Mode in seconds."
        )
        return

    record["status"] = STATUS_INCOMPLETE

    # 🔴 And they are PRINTED, not merely filed. The record survives to the
    # booted machine, but an operator watching an install sees only what
    # `error()` writes -- and "exit 71" on its own is what cost this project a
    # session. `error` itself is left exactly as it was: its closing sentence is
    # the degradation promise and nothing may push it out of a 400-char field.
    for line in record["launcher_errors"]:
        warnings.append("Valve's launcher said: " + line)

    record["error"] = sanitize_text(
        _incomplete_reason(reason, record)
        + " Nothing was made worse: Steam downloads only what is missing, so the first boot "
        "finishes the job -- faster than it would have if any bytes landed, and no slower "
        "than today if none did.",
        limit=400,
    )


def _incomplete_reason(reason: str, record: dict) -> str:
    cached = record["package_bytes"] // (1024 * 1024)
    if reason == STOP_BUDGET:
        return (
            f"the {record['seconds']}s budget expired with {cached} MiB of Steam's client "
            f"cached and no installed manifest (last phase: {record['phase'] or 'none'})."
        )
    if reason == STOP_STALLED:
        return (
            f"Steam's updater stopped making progress for {STALL_SECS}s and was stopped, "
            f"with {cached} MiB cached (last phase: {record['phase'] or 'none'})."
        )
    if reason == STOP_TOO_SLOW:
        return (
            f"this connection needed about {(record.get('projected_download_secs') or 0) // 60} "
            "more minutes for Steam's client update, more than this step's budget, so it "
            f"was stopped after {record['seconds']}s with {cached} MiB cached."
        )
    if reason == STOP_MARKER:
        # Defensive: we only stop for the marker when it exists, so reaching
        # here means it vanished between the check and the re-read.
        return (
            "the installed manifest was present during the run and is not on disk now, "
            f"with {cached} MiB cached."
        )
    return (
        f"Steam's updater exited {record['exit_code']} without installing a client, with "
        f"{cached} MiB cached (last phase: {record['phase'] or 'none'}). "
        f"The installer's Wi-Fi screen recorded status={record['wifi_status']}."
        + (
            " That vocabulary means this machine had no network."
            if record["wifi_status"] in NO_NETWORK_WIFI_STATUSES
            else ""
        )
    )


def _read_beta(target: Path, user) -> str | None:
    """Which update branch the target's client is pinned to, if any.

    Recorded, never written by us: it is what ``-steamdeck`` makes Valve's
    updater write, and it is the fact that decides whether first boot's
    ``-gamepadui`` asks for the manifest this step installed.
    """
    try:
        text = (user.home_on(target) / BETA_FILE_REL).read_text(errors="replace").strip()
    except OSError:
        return None
    return sanitize_text(text) or None


def steam_bootstrap_step(ctx) -> None:
    """``DeckStep`` entry point. Records under the ``steam_bootstrap`` key
    whichever way it went, so an assertion over
    ``/var/log/omarchy-deck-install.json`` can ask whether the machine this
    install produced still has a two-minute black first boot ahead of it."""
    record_result(ctx.target, "steam_bootstrap", bootstrap_steam(ctx, LIVE_ROOT))

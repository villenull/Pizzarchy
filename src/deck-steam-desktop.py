#!/usr/bin/env python3
"""deck-steam-desktop -- start the Steam client in Desktop Mode WITHOUT letting
it take the Deck's controller away from the kernel.

Installed as /usr/local/bin/deck-steam-desktop by `deck-session.sh
stage-steam-desktop-launcher`, and reached only through the desktop entry that
same stage writes into the user's ~/.local/share/applications (and /etc/skel).
Gaming Mode never reads a .desktop file to start Steam -- it starts
steam-launcher.service with an absolute ExecStart -- so nothing here is on
Gaming Mode's path. That is the whole of the safety argument; see the stage.

---------------------------------------------------------------------------
THE DEFECT THIS EXISTS FOR
---------------------------------------------------------------------------

MEASURED on the operator's Deck 2026-08-16 (docs/findings/
P39-steam-desktop-window-and-input.md, Defect 2):

  * Steam holds no /dev/input/event* descriptor at all. Its ONE relevant fd is
    /dev/hidraw2 -- the "client" HID child hid-steam creates so userspace can
    talk to the controller.
  * The moment that node is opened, `hid-steam` UNREGISTERS ITS OWN INPUT
    DEVICES. With Steam resident, /sys/bus/hid/devices/0003:28DE:1205.0003/input
    does not exist; with Steam closed it does. This is upstream kernel
    behaviour, by design (see the driver's client-detection patch series), and
    it is why the native "Steam Deck" pad -- the only node carrying trackpad
    axes -- disappears when Steam starts.
  * lizard_mode=Y does NOT paper over it. Matched pair, operator moving the
    right trackpad in both windows: Steam resident -> 0 bytes on
    /dev/input/event5 in 20 s; Steam closed -> 49,320 bytes in 3 s.
  * When Steam EXITS, the kernel re-creates the pad and the mapper re-binds.

So the desktop pointer dies because a file gets opened. If that open never
happens, the kernel keeps its input devices, deck-input-mapper keeps the pad it
already knows how to drive, and there is no defect to recover from.

---------------------------------------------------------------------------
HOW IT STOPS THE OPEN, AND WHY IT IS NOT A STEAM SETTING
---------------------------------------------------------------------------

There is no Steam setting to use. Two families were looked for and both are
worse than useless here:

  * `controller_blacklist` in <Steam>/config/config.vdf is real and documented
    (the "hide device" button writes it). It is ALSO in the same
    ~/.local/share/Steam that GAMING MODE reads. There is exactly one config
    directory for both sessions, so any config-file answer applies to Gaming
    Mode too -- which is the one thing this project may not break. It is
    additionally unknown whether a blacklisted device is merely ignored or
    genuinely not opened; being ignored would leave the pad just as destroyed.
  * The SDL_JOYSTICK_HIDAPI_* hints govern SDL's own HIDAPI drivers, which is
    the layer GAMES see. On SteamOS that driver is already disabled and Steam
    still owns the controller, so the hints are the wrong layer for the client.
    They cost nothing to set, so this script sets them anyway (see ENV_HINTS)
    -- but nothing here depends on them working.

What is used instead is the one mechanism that cannot be argued with: a
private mount namespace in which the controller's hidraw nodes are replaced by
a file nobody can open. open() then fails with EACCES before hidraw_open() is
ever reached, so the kernel has no reason to unregister anything.

MEASURED on the dev machine 2026-08-16, with both controls, before any of this
was written: binding a mode-000 file over a character device inside a
user+mount namespace makes open() fail for the wrapped process tree, leaves a
device that was NOT bound readable (positive control), and leaves the host's
own view of the node untouched (negative control).

The namespace is created by this process, with no privilege and no setuid
helper: unshare(CLONE_NEWUSER|CLONE_NEWNS) grants a full capability set inside
the new user namespace, and the capabilities survive because the mounts happen
BEFORE execve. (`unshare(1) --map-current-user` cannot do this: it execs, and
execve of an ordinary binary as a non-root uid clears the set. Measured.)

Deliberately NOT bubblewrap, even though bwrap does exactly this and was the
first thing tried: bwrap is a package the target may not have, and it sets
PR_SET_NO_NEW_PRIVS, which silently disarms every setuid binary in the tree
(pkexec, among others). This does neither.

---------------------------------------------------------------------------
WHAT IS LOST -- SAY THIS OUT LOUD, IT IS NOT SMALL
---------------------------------------------------------------------------

With Steam denied the controller in Desktop Mode:

  * Steam's UI is not gamepad-navigable there. It IS pointer-navigable, with
    the pointer deck-input-mapper drives from the trackpads -- which is the
    whole point, and is more than exists today (today there is no pointer).
  * Steam Input is unavailable in Desktop Mode: no per-game layouts, no gyro,
    no back buttons, no radial menus, and the controller configurator will not
    see the Deck's own controller.
  * 🔴 A GAME LAUNCHED FROM THE DESKTOP GETS NO GAMEPAD. Children inherit the
    mount namespace, so a game cannot open the hidraw either; and the native
    evdev pad is EVIOCGRAB'd by deck-input-mapper (`--grab`, load-bearing --
    see render_input_mapper_unit's comment). Today, Steam's virtual X360 pad
    covers that case. This trades it away.

The trade is deliberate and it is the operator's to overrule: Gaming Mode is
where games are played and nothing here touches it, whereas Desktop Mode
currently has NO usable input at all once Steam is open. If playing games from
Desktop Mode matters more than a desktop pointer, set
DECK_STEAM_DESKTOP_BLOCK=off (below) and the defect comes back with it.

---------------------------------------------------------------------------
FAIL-SAFE, WHICH IS THE PROPERTY THAT MATTERS MOST
---------------------------------------------------------------------------

Every failure path here ends in `exec /usr/bin/steam`, i.e. exactly today's
shipped behaviour, and says why on stderr. No kernel, no hardware, no
persistent state and nothing global is touched: the only thing that ever
changes is one process tree's view of /dev.

  * no controller hidraw found          -> plain Steam
  * unshare/mount refused by the kernel -> plain Steam
  * the block did not take (verified by
    opening a blocked node afterwards)  -> plain Steam's behaviour, loudly
  * DECK_STEAM_DESKTOP_BLOCK=off        -> plain Steam
  * launched from a gamescope session   -> plain Steam, untouched

And when the block DOES take, a Steam that then misbehaves still leaves a
working desktop pointer, because the pad is exactly where it was.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import errno
import os
import shutil
import stat
import subprocess
import sys

PROG = "deck-steam-desktop"

# The Deck's built-in controller. Both hidraw children of this HID device are
# blocked -- the client node (the one whose open destroys the input devices)
# and the raw one -- because which is which is decided by enumeration order and
# this project has been burned by node numbering before (PROGRESS.md 5.9:
# event5/event4/event11 on the live ISO are event6/event5/event7 installed).
# Blocking both costs nothing: no other program in the desktop session speaks
# HID to this controller.
CONTROLLER_VID = 0x28DE
CONTROLLER_PID = 0x1205

STEAM_BIN = "/usr/bin/steam"
SYSFS_HIDRAW = "/sys/class/hidraw"
DEV_ROOT = "/dev"

# The operator-facing switch, and the escape hatch named in the docstring.
# 'hidraw' (default) blocks; 'off' launches Steam exactly as the stock desktop
# entry would. Anything else is refused loudly rather than guessed at, because
# a typo that silently means "off" is a fix that quietly stops existing.
BLOCK_ENV = "DECK_STEAM_DESKTOP_BLOCK"
BLOCK_MODES = ("hidraw", "off")

# Cheap and non-load-bearing: ask Steam's bundled SDL not to drive the Deck
# through its own HIDAPI drivers either. If Steam honours them, one more way to
# reach the same open is closed; if it ignores them (the likelier case -- see
# the docstring), the mount namespace has already closed it. Nothing in this
# file's behaviour depends on these.
ENV_HINTS = {
    "SDL_JOYSTICK_HIDAPI_STEAMDECK": "0",
    "SDL_JOYSTICK_HIDAPI_STEAM": "0",
}

CLONE_NEWNS = 0x00020000
CLONE_NEWUSER = 0x10000000
MS_BIND = 0x1000
MS_REC = 0x4000
MS_SLAVE = 0x80000


def note(message: str) -> None:
    """One line to stderr. Desktop-entry stderr lands in the journal under the
    launching unit, which is where a controller-only user's helper has to leave
    evidence -- there is no terminal to print to."""
    print(f"{PROG}: {message}", file=sys.stderr, flush=True)


def fell_back(message: str) -> None:
    """A fallback the USER has to be told about, not only the journal.

    "Fail safe AND loud" is the requirement, and stderr alone is not loud on a
    device with no terminal: it goes to the journal, which a controller-only
    user cannot read. Omarchy ships mako, so a notification is the one channel
    that reaches somebody holding the Deck. Best effort in every direction --
    a missing notify-send, a hung notification daemon or a session with no bus
    must never delay or fail a Steam launch.
    """
    note(message)
    if not shutil.which("notify-send"):
        return
    try:
        subprocess.run(
            [
                "notify-send",
                "--app-name=Steam",
                "--urgency=critical",
                "Steam has taken the controller",
                "The trackpads will not move the desktop pointer until Steam is "
                "closed. Quitting Steam brings the pointer back by itself.",
            ],
            timeout=5,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:  # noqa: BLE001 -- a notification may never break a launch
        pass


# ---------------------------------------------------------------------------
# Finding the controller's hidraw nodes
# ---------------------------------------------------------------------------


def parse_hid_id(uevent_text: str) -> tuple[int, int, int] | None:
    """(bus, vid, pid) out of a HID device's uevent, or None.

    The line is HID_ID=0003:000028DE:00001205 -- bus, vendor, product, zero
    padded, uppercase. Parsed rather than pattern-matched on the whole file so
    a device with no HID_ID at all (which is normal for non-HID uevents) is a
    None rather than a crash.
    """
    for line in uevent_text.splitlines():
        if not line.startswith("HID_ID="):
            continue
        fields = line.split("=", 1)[1].split(":")
        if len(fields) != 3:
            return None
        try:
            return tuple(int(field, 16) for field in fields)  # type: ignore[return-value]
        except ValueError:
            return None
    return None


def hidraw_nodes(
    vid: int = CONTROLLER_VID,
    pid: int = CONTROLLER_PID,
    sysfs: str = SYSFS_HIDRAW,
    dev_root: str = DEV_ROOT,
) -> list[str]:
    """Every /dev/hidrawN whose HID parent is vid:pid, sorted.

    Resolved from sysfs at every launch and NEVER hardcoded: the measurement
    that found this defect saw the client node at hidraw2, and that number is a
    property of enumeration order, not of the hardware.

    The device path is taken from the node's own DEVNAME when the kernel offers
    one, and falls back to the sysfs directory name -- which is the same string
    on every kernel this has been seen on, but the uevent is the authority.
    """
    found: list[str] = []
    try:
        entries = sorted(os.listdir(sysfs))
    except OSError:
        return found

    for entry in entries:
        parent = os.path.join(sysfs, entry, "device", "uevent")
        try:
            with open(parent, encoding="utf-8", errors="replace") as handle:
                hid_id = parse_hid_id(handle.read())
        except OSError:
            continue
        if hid_id is None or hid_id[1] != vid or hid_id[2] != pid:
            continue

        name = entry
        try:
            with open(os.path.join(sysfs, entry, "uevent"), encoding="utf-8") as handle:
                for line in handle:
                    if line.startswith("DEVNAME="):
                        name = line.split("=", 1)[1].strip().split("/")[-1]
                        break
        except OSError:
            pass

        node = os.path.join(dev_root, name)
        if node not in found:
            found.append(node)
    return found


# ---------------------------------------------------------------------------
# Session guard
# ---------------------------------------------------------------------------


def is_gamescope_session(env) -> bool:
    """Is this a Gaming Mode session?

    Belt and braces only. A .desktop entry cannot be how Gaming Mode starts
    Steam -- steam-launcher.service names its binary absolutely -- so this
    should never fire. It exists because the cost of being wrong about that is
    a Gaming Mode with no controller, and the cost of the check is nothing.

    GAMESCOPE_WAYLAND_DISPLAY is the variable gamescope publishes into the
    session environment; deck-session.sh's own splash unit reads the same file
    (%t/gamescope-environment) for it.
    """
    if env.get("GAMESCOPE_WAYLAND_DISPLAY"):
        return True
    both = f"{env.get('XDG_CURRENT_DESKTOP', '')}:{env.get('XDG_SESSION_DESKTOP', '')}"
    return "gamescope" in both.lower()


# ---------------------------------------------------------------------------
# The block itself
# ---------------------------------------------------------------------------


def make_blocker(directory: str) -> str:
    """A file that the calling user cannot open, to bind over the nodes.

    Mode 000 and owned by US. That combination is the measured one: DAC applies
    the owner class first, so mode 000 denies the owner too, and a file we own
    sidesteps every question about mounting something whose uid is not mapped
    into our new user namespace.

    It lives in the runtime directory, not on disk, so there is no installed
    artefact to go stale and nothing survives a reboot.
    """
    path = os.path.join(directory, f"{PROG}.blocked")
    # Re-created every launch, and unlinked first: an existing mode-000 file
    # cannot be reopened for writing, not even by its owner, so a plain open
    # would fail on the second launch. Idempotency here means "works the same
    # every time", which is not the same as "leave what is there".
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    handle = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o000)
    try:
        os.write(
            handle,
            b"deck-steam-desktop: bound over the Steam Deck controller's hidraw\n"
            b"nodes so the Steam client cannot open them. Nothing reads this file.\n",
        )
    finally:
        os.close(handle)
    os.chmod(path, 0o000)
    return path


def _libc():
    name = ctypes.util.find_library("c") or "libc.so.6"
    return ctypes.CDLL(name, use_errno=True)


def _check(rc: int, what: str) -> None:
    if rc != 0:
        code = ctypes.get_errno()
        raise OSError(code, f"{what}: {os.strerror(code)}")


def enter_namespace() -> None:
    """A private user+mount namespace owned by this process.

    Order is load-bearing three times over:

      1. CLONE_NEWUSER and CLONE_NEWNS in ONE unshare, so the new mount
         namespace is owned by the new user namespace and our capabilities in
         the latter authorise mounts in the former.
      2. uid_map/gid_map written before any mount. setgroups must be denied
         first or writing gid_map is refused; the single-line identity mapping
         is the one an unprivileged process is always allowed to write.
      3. MS_REC|MS_SLAVE on "/" BEFORE binding anything. systemd mounts "/"
         shared; without this the bind would PROPAGATE BACK TO THE HOST and
         take the controller away from everything on the machine, which is the
         precise opposite of this file's purpose. MS_SLAVE rather than
         MS_PRIVATE so mounts still propagate INWARD -- an SD card or USB
         drive mounted after Steam started is still visible to it.
    """
    libc = _libc()

    # 🔴 READ THE IDS BEFORE THE unshare, AND THIS IS NOT A STYLE CHOICE.
    # MEASURED on the dev machine while writing this file: between
    # unshare(CLONE_NEWUSER) and the uid_map write, the process's own uid is
    # UNMAPPED, so os.geteuid() returns the overflow uid (65534). Writing
    # "65534 65534 1" is not the "map your own id" case the kernel allows
    # unprivileged, and the write fails with EPERM -- after the namespace
    # already exists. The first version of this function did exactly that.
    uid, gid = os.geteuid(), os.getegid()

    _check(libc.unshare(CLONE_NEWUSER | CLONE_NEWNS), "unshare(CLONE_NEWUSER|CLONE_NEWNS)")

    with open("/proc/self/setgroups", "w", encoding="ascii") as handle:
        handle.write("deny")
    with open("/proc/self/uid_map", "w", encoding="ascii") as handle:
        handle.write(f"{uid} {uid} 1")
    with open("/proc/self/gid_map", "w", encoding="ascii") as handle:
        handle.write(f"{gid} {gid} 1")

    _check(
        libc.mount(None, b"/", None, MS_REC | MS_SLAVE, None),
        "mount(MS_REC|MS_SLAVE) on /",
    )


def bind_over(source: str, target: str) -> None:
    """Bind `source` over `target`. Requires enter_namespace() to have run."""
    libc = _libc()
    _check(
        libc.mount(
            source.encode(), target.encode(), None, MS_BIND, None
        ),
        f"mount --bind {source} {target}",
    )


class _CapHeader(ctypes.Structure):
    _fields_ = [("version", ctypes.c_uint32), ("pid", ctypes.c_int)]


class _CapData(ctypes.Structure):
    _fields_ = [
        ("effective", ctypes.c_uint32),
        ("permitted", ctypes.c_uint32),
        ("inheritable", ctypes.c_uint32),
    ]


_LINUX_CAPABILITY_VERSION_3 = 0x20080522


def drop_capabilities() -> bool:
    """Give up every capability in the new user namespace. Returns success.

    🔴 THIS IS WHAT MAKES THE SELF-CHECK MEAN ANYTHING, and the first version of
    this file did not have it. Creating a user namespace grants a FULL
    capability set inside it, CAP_DAC_OVERRIDE included -- so the process that
    just laid the mode-000 file over the node can still open it, and the
    verification below reported "not blocked" for a block that was working
    perfectly. MEASURED on the dev machine: same bind, open succeeds with the
    capabilities and fails without them.

    execve() would drop them anyway (an ordinary binary run by a non-root uid
    keeps nothing), so this changes no outcome for Steam. It changes whether
    what this process reports about its own work is true.
    """
    try:
        libc = _libc()
        header = _CapHeader(_LINUX_CAPABILITY_VERSION_3, 0)
        data = (_CapData * 2)()
        return libc.capset(ctypes.byref(header), ctypes.byref(data)) == 0
    except (OSError, AttributeError):
        return False


def is_open_denied(path: str) -> bool:
    """Can this process NOT open `path`? The direct observable, read back.

    A block that silently did not take is worse than no block: it looks fixed
    and behaves exactly like the defect. So the wrapper proves its own work by
    trying the thing it claims to have prevented.
    """
    try:
        handle = os.open(path, os.O_RDONLY)
    except OSError as exc:
        return exc.errno in (errno.EACCES, errno.EPERM)
    os.close(handle)
    return False


def block_nodes(nodes: list[str], blocker_dir: str) -> tuple[list[str], bool]:
    """Put `nodes` out of reach of this process tree.

    Returns (blocked nodes, capabilities were dropped). The second half is what
    tells the caller whether the read-back below proves anything -- see
    drop_capabilities.

    Raises OSError if the namespace could not be created at all -- the caller
    turns that into "launch Steam the old way", never into a failure.
    """
    enter_namespace()
    blocker = make_blocker(blocker_dir)
    blocked: list[str] = []
    for node in nodes:
        try:
            bind_over(blocker, node)
        except OSError as exc:
            note(f"could not cover {node} ({exc}); it stays open to Steam")
            continue
        blocked.append(node)
    return blocked, drop_capabilities()


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------


def runtime_dir(env) -> str:
    """Where the blocker file goes. XDG_RUNTIME_DIR when it is a directory we
    own, /tmp otherwise -- the file is mode 000 and its name is fixed, so the
    fallback is only ever used by a session that has no runtime dir at all."""
    candidate = env.get("XDG_RUNTIME_DIR", "")
    if candidate:
        try:
            info = os.stat(candidate)
            if stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid():
                return candidate
        except OSError:
            pass
    return "/tmp"


def describe(nodes: list[str], mode: str, env) -> list[str]:
    """The --check report. Pure, so the unit suite can assert on it."""
    lines = [
        f"mode: {mode} (set {BLOCK_ENV}=off to launch Steam untouched)",
        f"gamescope session: {'yes' if is_gamescope_session(env) else 'no'}",
        f"controller hidraw nodes: {', '.join(nodes) if nodes else 'NONE FOUND'}",
        f"steam: {STEAM_BIN}",
    ]
    if not nodes:
        lines.append(
            "with no node to cover there is nothing to block, so Steam would be "
            "launched exactly as the stock desktop entry launches it"
        )
    return lines


def launch(steam: str, args: list[str], env) -> int:
    """exec Steam. Only returns if exec failed.

    The hints go into os.environ rather than into `env`, because `env` is a
    read-only view for the caller's decisions (the unit suite passes a plain
    dict) and execv inherits the process environment, not that view. A hint
    the caller already set is left alone.
    """
    for key, value in ENV_HINTS.items():
        os.environ.setdefault(key, value)
    try:
        os.execv(steam, [steam, *args])
    except OSError as exc:
        note(f"could not exec {steam}: {exc}")
        return 127
    return 0  # unreachable


def main(argv: list[str] | None = None, env=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    env = os.environ if env is None else env

    check_only = "--check" in argv
    if check_only:
        argv = [arg for arg in argv if arg != "--check"]

    mode = env.get(BLOCK_ENV, "hidraw").strip().lower() or "hidraw"
    if mode not in BLOCK_MODES:
        note(
            f"{BLOCK_ENV}={mode!r} is not one of {'/'.join(BLOCK_MODES)}; "
            "treating it as 'hidraw'. Fix the value rather than relying on this."
        )
        mode = "hidraw"

    nodes = hidraw_nodes()

    if check_only:
        for line in describe(nodes, mode, env):
            print(line)
        return 0

    if is_gamescope_session(env):
        note("this is a gamescope session -- launching Steam untouched")
        return launch(STEAM_BIN, argv, env)

    if mode == "off":
        note(f"{BLOCK_ENV}=off -- launching Steam untouched (the desktop pointer will die)")
        return launch(STEAM_BIN, argv, env)

    if not nodes:
        fell_back(
            f"found no hidraw node for {CONTROLLER_VID:04x}:{CONTROLLER_PID:04x}; "
            "nothing to block, launching Steam untouched"
        )
        return launch(STEAM_BIN, argv, env)

    try:
        blocked, capped = block_nodes(nodes, runtime_dir(env))
    except OSError as exc:
        fell_back(
            f"could not create the private namespace ({exc}); launching Steam "
            "untouched. The desktop pointer will die when Steam starts, and "
            "come back when it exits."
        )
        return launch(STEAM_BIN, argv, env)

    # Read the work back, on the nodes that matter. `all()` over an empty list
    # is True, so the emptiness is checked separately -- a block that covered
    # nothing must not report success.
    if not blocked:
        fell_back(
            "covered none of the controller's hidraw nodes; Steam will claim "
            "the controller exactly as it does without this wrapper"
        )
    elif not capped:
        # Honesty, not paranoia: with capabilities still held, is_open_denied()
        # answers about a process that can override the file mode, not about
        # Steam. Say the block is in place and say the check could not be made.
        note(
            f"covered {', '.join(blocked)}, but could not drop capabilities, so "
            "the block was NOT verified from inside. Steam still loses them at "
            "exec, so the block should hold."
        )
    elif all(is_open_denied(node) for node in blocked):
        note(f"covered {', '.join(blocked)}; Steam cannot claim the controller in this session")
    else:
        fell_back(
            "🔴 THE BLOCK DID NOT TAKE -- the controller's hidraw is still "
            "openable in this namespace. Steam is being launched anyway, and "
            "will behave exactly as it does without this wrapper: the desktop "
            "pointer dies until Steam exits."
        )

    return launch(STEAM_BIN, argv, env)


if __name__ == "__main__":
    sys.exit(main())

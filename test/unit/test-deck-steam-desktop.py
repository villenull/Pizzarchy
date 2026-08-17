#!/usr/bin/env python3
"""Unit tests for src/deck-steam-desktop.py -- the Desktop-Mode Steam launcher
that keeps the Steam client from claiming the Deck's controller.

Needs no Deck, no root and no VM. The namespace cases DO need a kernel that
lets an unprivileged process create a user namespace, which is every kernel
this project targets; if that is unavailable they SKIP loudly rather than pass
quietly (a namespace test that passes on a kernel where namespaces do not work
is worth nothing).

WHAT IS ACTUALLY EXERCISED, and why each case exists:

  1. HID matching -- the node list is derived from sysfs at every launch, never
     hardcoded. PROGRESS.md 5.9 is the reason: node numbers move between the
     live ISO and an installed system, and the measurement that found this
     defect saw the client node at hidraw2 on one particular boot.
  2. The session guard -- a gamescope session must launch Steam untouched.
  3. The block, end to end, in a real namespace, with THREE controls:
       positive: a device NOT covered stays openable inside the namespace
       positive: the covered node WAS openable before the block
       negative: the host's view of the covered node is unchanged afterwards
  4. Capability dropping, which is what makes case 3's read-back mean anything.
     Its own positive control: with capabilities retained, the same block reads
     back as "not blocked" -- the artefact this test was written after hitting.
  5. Every fallback path ends in launching Steam anyway. This is the property
     the whole design rests on: worst case is today's behaviour, never a Deck
     that cannot start Steam.
"""

from __future__ import annotations

import importlib.util
import os
import pathlib
import subprocess
import sys
import tempfile
import textwrap

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = REPO_ROOT / "src" / "deck-steam-desktop.py"

failures = 0


def ok(name: str) -> None:
    print(f"ok - {name}")


def bad(name: str, detail: str = "") -> None:
    global failures
    failures += 1
    print(f"not ok - {name}")
    if detail:
        print(detail, file=sys.stderr)


def check(cond: bool, name: str, detail: str = "") -> None:
    ok(name) if cond else bad(name, detail)


def load():
    spec = importlib.util.spec_from_file_location("deck_steam_desktop", SOURCE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


mod = load()

work = tempfile.mkdtemp(prefix="deck-steam-desktop-test.")


# ===========================================================================
# 1. Finding the controller's hidraw nodes
# ===========================================================================

sysfs = os.path.join(work, "sys")
dev = os.path.join(work, "dev")
os.makedirs(dev)

FIXTURE = (
    # (sysfs name, HID_ID, DEVNAME)   -- two Deck children and one impostor
    ("hidraw0", "0003:00001234:00005678", "hidraw0"),
    ("hidraw2", "0003:000028DE:00001205", "hidraw2"),
    ("hidraw3", "0003:000028DE:00001205", "hidraw3"),
)
for name, hid_id, devname in FIXTURE:
    node_dir = os.path.join(sysfs, name, "device")
    os.makedirs(node_dir)
    pathlib.Path(node_dir, "uevent").write_text(f"HID_NAME=thing\nHID_ID={hid_id}\n")
    pathlib.Path(sysfs, name, "uevent").write_text(f"MAJOR=239\nDEVNAME={devname}\n")
    pathlib.Path(dev, devname).write_text("device\n")

# A directory with no HID parent at all, which is normal in /sys/class/hidraw
# for devices being torn down. It must be skipped, not crashed on.
os.makedirs(os.path.join(sysfs, "hidraw9"))

found = mod.hidraw_nodes(sysfs=sysfs, dev_root=dev)
check(
    found == [os.path.join(dev, "hidraw2"), os.path.join(dev, "hidraw3")],
    "both of the controller's hidraw children are found, and nothing else is",
    f"got {found}",
)

# The negative control for the case above: a suite that matched everything
# would pass it too. Ask for a vendor that is not there and get nothing.
check(
    mod.hidraw_nodes(vid=0xDEAD, pid=0xBEEF, sysfs=sysfs, dev_root=dev) == [],
    "a vendor/product that is not present matches nothing (the match is real)",
)

check(
    mod.parse_hid_id("HID_ID=0003:000028DE:00001205\n") == (3, 0x28DE, 0x1205),
    "HID_ID is parsed as hex bus/vendor/product",
)
check(
    mod.parse_hid_id("DRIVER=hid-generic\n") is None
    and mod.parse_hid_id("HID_ID=nonsense\n") is None,
    "a uevent with no usable HID_ID yields None rather than raising",
)

# The constants must be the Deck's controller. A typo here is a wrapper that
# blocks nothing and reports success.
check(
    (mod.CONTROLLER_VID, mod.CONTROLLER_PID) == (0x28DE, 0x1205),
    "the vendor/product pair is Valve's 28de:1205, the ID in every measurement",
)


# ===========================================================================
# 2. The session guard
# ===========================================================================

check(
    mod.is_gamescope_session({"GAMESCOPE_WAYLAND_DISPLAY": "gamescope-0"}),
    "a session publishing GAMESCOPE_WAYLAND_DISPLAY is recognised as Gaming Mode",
)
check(
    mod.is_gamescope_session({"XDG_CURRENT_DESKTOP": "gamescope"}),
    "XDG_CURRENT_DESKTOP=gamescope is recognised as Gaming Mode",
)
check(
    not mod.is_gamescope_session({"XDG_CURRENT_DESKTOP": "Hyprland"}),
    "the Hyprland desktop session is NOT mistaken for Gaming Mode",
    "if this ever inverts, the desktop launch would stop blocking and the "
    "defect returns silently",
)


# ===========================================================================
# 3 + 4. The block itself, in a real namespace
# ===========================================================================

CHILD = textwrap.dedent(
    """
    import importlib.util, json, sys
    spec = importlib.util.spec_from_file_location("m", {source!r})
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    {patch}

    nodes = m.hidraw_nodes(sysfs={sysfs!r}, dev_root={dev!r})
    result = {{"nodes": nodes}}

    # POSITIVE CONTROL, inside the namespace-to-be: everything is openable now.
    result["open_before"] = [not m.is_open_denied(n) for n in nodes]

    blocked, capped = m.block_nodes(nodes, {work!r})
    result["blocked"] = blocked
    result["capped"] = capped
    result["denied"] = [m.is_open_denied(n) for n in blocked]
    result["control_other_device"] = m.is_open_denied({dev!r} + "/hidraw0")
    print("RESULT " + json.dumps(result))
    """
)


def run_child(drop_caps: bool):
    """Run the block in a child process. drop_caps=False patches out the
    capability drop, which is the positive control for case 4."""
    body = CHILD.format(
        source=str(SOURCE),
        sysfs=sysfs,
        dev=dev,
        work=work,
        patch="" if drop_caps else "m.drop_capabilities = lambda: False",
    )
    return subprocess.run(
        [sys.executable, "-c", body], capture_output=True, text=True, timeout=60
    )


def parse(proc):
    for line in proc.stdout.splitlines():
        if line.startswith("RESULT "):
            import json

            return json.loads(line[len("RESULT ") :])
    return None


proc = run_child(drop_caps=True)
data = parse(proc)

if data is None and "unshare" in proc.stderr:
    print("# SKIP - this kernel refuses unprivileged user namespaces")
    print(f"# {proc.stderr.strip().splitlines()[-1] if proc.stderr else ''}")
elif data is None:
    bad(
        "the namespace child produced a result",
        f"rc={proc.returncode}\nstdout={proc.stdout}\nstderr={proc.stderr}",
    )
else:
    check(
        all(data["open_before"]) and len(data["open_before"]) == 2,
        "POSITIVE CONTROL: both nodes were openable before the block",
        f"got {data['open_before']}",
    )
    check(
        sorted(data["blocked"]) == sorted(data["nodes"]) and len(data["blocked"]) == 2,
        "every controller node is covered",
        f"got {data['blocked']}",
    )
    check(
        data["capped"] is True,
        "capabilities are dropped before the block is read back",
        "without this the read-back is made by a process holding "
        "CAP_DAC_OVERRIDE, and answers about the wrong thing entirely",
    )
    check(
        data["denied"] == [True, True],
        "every covered node is UNOPENABLE afterwards -- the whole mechanism",
        f"got {data['denied']}",
    )
    check(
        data["control_other_device"] is False,
        "POSITIVE CONTROL: a hidraw device that is NOT the controller stays openable",
        "an over-broad block would take every third-party controller away from "
        "Steam too, which is not what this is for",
    )

    # NEGATIVE CONTROL, from out here: nothing escaped the namespace. This is
    # the property that makes the whole approach safe for Gaming Mode -- if a
    # bind ever propagated to the host, it would follow the device, not the
    # session.
    host_ok = True
    for name in ("hidraw0", "hidraw2", "hidraw3"):
        try:
            with open(os.path.join(dev, name), encoding="utf-8") as handle:
                handle.read()
        except OSError:
            host_ok = False
    check(
        host_ok,
        "NEGATIVE CONTROL: the host's view of every node is untouched after the child exits",
        "a bind that propagated out of the namespace would deny the device to "
        "the whole machine, Gaming Mode included",
    )

    # POSITIVE CONTROL FOR CASE 4, i.e. proof the capability drop is load
    # bearing rather than decorative: with it patched out, the identical block
    # reads back as NOT blocked.
    proc_nocap = run_child(drop_caps=False)
    data_nocap = parse(proc_nocap)
    if data_nocap is None:
        bad(
            "the no-capability-drop control produced a result",
            f"rc={proc_nocap.returncode}\nstderr={proc_nocap.stderr}",
        )
    else:
        check(
            data_nocap["denied"] == [False, False],
            "CONTROL: without dropping capabilities the same block reads back as open",
            "if this ever reports True, drop_capabilities() is no longer what "
            "makes the verification honest and case 4 has stopped testing anything",
        )


# ===========================================================================
# 5. Every path launches Steam
# ===========================================================================
#
# main() ends in execv, so these run it in a child with STEAM_BIN pointed at a
# script that reports it ran. Anything that leaves Steam unlaunched is the one
# failure this design may not have: the user asked to open Steam.

marker = os.path.join(work, "steam-ran")
fake_steam = os.path.join(work, "fake-steam")
pathlib.Path(fake_steam).write_text(
    "#!/usr/bin/env bash\nprintf '%s\\n' \"$@\" >>" + f'"{marker}"\n'
)
os.chmod(fake_steam, 0o755)

LAUNCH_CHILD = textwrap.dedent(
    """
    import importlib.util, sys
    spec = importlib.util.spec_from_file_location("m", {source!r})
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    m.STEAM_BIN = {steam!r}
    {patch}
    sys.exit(m.main({argv!r}, {env!r}))
    """
)


def launch_case(name: str, env: dict, patch: str = "", argv=None) -> bool:
    if os.path.exists(marker):
        os.unlink(marker)
    body = LAUNCH_CHILD.format(
        source=str(SOURCE), steam=fake_steam, patch=patch, argv=argv or [], env=env
    )
    subprocess.run([sys.executable, "-c", body], capture_output=True, text=True, timeout=60)
    return os.path.exists(marker)


check(
    launch_case("gamescope", {"GAMESCOPE_WAYLAND_DISPLAY": "gamescope-0"}),
    "a gamescope session still launches Steam (untouched)",
)
check(
    launch_case("off", {"DECK_STEAM_DESKTOP_BLOCK": "off"}),
    "DECK_STEAM_DESKTOP_BLOCK=off still launches Steam",
)
check(
    launch_case("no nodes", {}, patch="m.hidraw_nodes = lambda *a, **k: []"),
    "a machine with no controller hidraw node still launches Steam",
)
check(
    launch_case(
        "namespace refused",
        {},
        patch=(
            "m.hidraw_nodes = lambda *a, **k: ['/dev/null']\n"
            "def boom(*a, **k):\n"
            "    raise OSError(1, 'refused')\n"
            "m.block_nodes = boom"
        ),
    ),
    "a kernel that refuses the namespace still launches Steam",
    "this is the fail-safe the whole design rests on: worst case is today's "
    "behaviour, never a Deck that cannot start Steam",
)
check(
    launch_case(
        "block did not take",
        {},
        patch=(
            "m.hidraw_nodes = lambda *a, **k: ['/dev/null']\n"
            "m.block_nodes = lambda *a, **k: (['/dev/null'], True)\n"
            "m.is_open_denied = lambda p: False"
        ),
    ),
    "a block that silently did not take still launches Steam",
)
check(
    launch_case("args", {"DECK_STEAM_DESKTOP_BLOCK": "off"}, argv=["steam://open/games"])
    and "steam://open/games" in pathlib.Path(marker).read_text(),
    "arguments (steam:// URLs from the desktop entry's %U) reach Steam",
)

# An unrecognised mode must be refused loudly and treated as blocking, not
# silently as 'off'. A typo that means "stop fixing the bug" is the silent
# failure this project exists to prevent.
check(
    mod.BLOCK_MODES == ("hidraw", "off"),
    "the only two modes are the blocking one and the documented escape hatch",
)


# ===========================================================================
# 6. --check reports without touching anything
# ===========================================================================

report = mod.describe([], "hidraw", {})
check(
    any("NONE FOUND" in line for line in report),
    "--check says so when no controller node was found",
)
check(
    any(mod.BLOCK_ENV in line for line in report),
    "--check names the environment variable that turns the block off",
)

proc = subprocess.run(
    [sys.executable, str(SOURCE), "--check"], capture_output=True, text=True, timeout=60
)
check(
    proc.returncode == 0 and "mode:" in proc.stdout,
    "--check runs on this machine, exits 0 and launches nothing",
    proc.stdout + proc.stderr,
)
check(
    not os.path.exists(os.path.join(mod.runtime_dir(os.environ), "deck-steam-desktop.blocked")),
    "--check leaves no blocker file behind",
)


print()
if failures:
    print(f"{failures} check(s) failed")
    sys.exit(1)
print("all deck-steam-desktop tests passed")

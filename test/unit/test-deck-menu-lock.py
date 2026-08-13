#!/usr/bin/env python3
"""Unit tests for `configure_deck`'s `menu_lock_row` step — T5 §5.6's third lock
producer, the `system.lock` row in Omarchy's own menu (`deck_menu_lock.py`).

No VM, no root, no network, no chroot, no Quickshell, no ISO build, and nothing
against the Deck:

    python3 test-deck-menu-lock.py

WHAT THIS SUITE IS ACTUALLY FOR
===============================

The step's whole claim is *"the Lock row is no longer reachable"*, and that claim
is only worth as much as the algorithm used to check it. So this suite never
asks "did we write the row we meant to write". It runs the **product's own
merge and the product's own visibility rule** — `deck_menu_lock`'s
transcriptions of `MenuModel.js` — over the file the step actually wrote, and
asserts the row comes out invisible and inert.

Five traps:

1. 🔴 **A file that parses but leaves the row reachable.** The obvious way to get
   this wrong is to write a row that keeps its `action`, or to "disable" it with
   a `when:` guard. §4 drives both through the real verifier and requires it to
   refuse.

2. 🔴 **`when:` hides nothing until a subprocess says so.** `isVisible` hides a
   row on an *explicit* `false` only, and `Menu.qml`'s own comment says a row
   whose `when:` went unanswered SHOWS. §3 demonstrates that with empty guard
   results rather than asserting a claim about it, because that is the state the
   menu is in on the first open of every session.

3. 🔴 **One bad byte drops EVERY custom row, silently.** `parseMenuJsonc` catches
   its own parse error and returns `[]`; the `FileView` sets
   `printErrors: false`. That takes our override *and* `src/deck-session.sh`'s
   return-to-Gaming-Mode row with it. §2 models the swallow; §5 proves the step
   refuses to install a file that would hit it, and §6 proves the two blocks
   coexist.

4. 🔴 **`/etc/skel` is TOO LATE** for the user this image creates (§3 trap (a)):
   `useradd` ran in phase 3 of 14. Both surfaces are written and **the user's
   copy is the one verified** — §7 deletes the user's copy and requires the
   verification to go red.

5. 🔴 **Wrecking the rest of the menu.** An override that took out the `System`
   submenu, or the Gaming Mode row, would "pass" a check aimed only at
   `system.lock`. §4 asserts the neighbours are still visible.

⚠️ The transcriptions of `MenuModel.js` are **read from the pinned runtime by a
human, not machine-generated**. §1 re-checks the load-bearing expressions against
that checkout when it is available (`OMARCHY_DECK_RUNTIME_SRC`, or the usual
cache path), and says loudly which checks did not run when it is not.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import pathlib
import shutil
import stat
import sys
import tempfile

# ⚠️ Before importing anything under test — see the note in the sibling suites.
sys.dont_write_bytecode = True

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
OVERLAY_ORCH = (
    REPO_ROOT / "iso/overlay/configs/airootfs/usr/share/omarchy-iso/orchestrator"
)
UPSTREAM_ORCH = (
    REPO_ROOT / "iso/upstream/configs/airootfs/usr/share/omarchy-iso/orchestrator"
)
# The reference implementation of "validate what you write into this file".
DECK_SESSION_SH = REPO_ROOT / "src/deck-session.sh"
RUNTIME_SRC = pathlib.Path(
    os.environ.get(
        "OMARCHY_DECK_RUNTIME_SRC",
        os.path.expanduser("~/.cache/omarchy-deck/iso-build/runtime-src"),
    )
)

FAILURES = 0
CHECKS = 0
NOT_RUN: list[str] = []


def check(what: str, got, want) -> None:
    global FAILURES, CHECKS
    CHECKS += 1
    if got == want:
        print(f"ok   {what}")
    else:
        print(f"FAIL {what}: got {got!r}, want {want!r}")
        FAILURES += 1


def check_true(what: str, got) -> None:
    check(what, bool(got), True)


def check_raises(what: str, fn, exc_types) -> None:
    global FAILURES, CHECKS
    CHECKS += 1
    try:
        fn()
    except exc_types:
        print(f"ok   {what}")
        return
    except Exception as exc:  # noqa: BLE001
        print(f"FAIL {what}: raised {type(exc).__name__}: {exc}, wanted {exc_types}")
        FAILURES += 1
        return
    print(f"FAIL {what}: did not raise")
    FAILURES += 1


def check_contains(what: str, haystack: pathlib.Path, needle: str) -> None:
    """A drift check against a file outside this repo. Fails loudly on absence."""
    global FAILURES, CHECKS
    CHECKS += 1
    if not haystack.is_file():
        print(f"FAIL {what}: {haystack} is not a file")
        FAILURES += 1
        return
    if needle in haystack.read_text(errors="replace"):
        print(f"ok   {what}")
    else:
        print(f"FAIL {what}: {needle!r} no longer appears in {haystack.name}")
        FAILURES += 1


# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

WORK = pathlib.Path(tempfile.mkdtemp(prefix="deck-menulock-test-"))

PHASES_IMPL_STUB = '''
"""Stub."""


def __getattr__(name):
    def phase(ctx):
        raise AssertionError(f"stub phase {name} should not run")

    phase.__name__ = name
    return phase
'''


def build_package() -> pathlib.Path:
    root = pathlib.Path(tempfile.mkdtemp(prefix="orch-", dir=WORK))
    pkg = root / "orchestrator"
    pkg.mkdir()
    (pkg / "__init__.py").write_text("")
    for name in ("ui.py", "context.py"):
        shutil.copyfile(UPSTREAM_ORCH / name, pkg / name)
    for module in sorted(OVERLAY_ORCH.glob("deck_*.py")):
        shutil.copyfile(module, pkg / module.name)
    (pkg / "phases_impl.py").write_text(PHASES_IMPL_STUB)
    return root


PKG_ROOT = build_package()
sys.path.insert(0, str(PKG_ROOT))

from orchestrator import deck_configure, deck_menu_lock as dml  # noqa: E402
from orchestrator.context import InstallContext  # noqa: E402

print(f"# modules loaded from {PKG_ROOT}")

TEST_UID = os.getuid()
TEST_GID = os.getgid()

# Omarchy's default menu, transcribed from the pinned runtime's
# default/omarchy/omarchy-menu.jsonc. Trimmed to the System submenu and enough
# of the root to make "the rest of the menu still works" mean something —
# including the whole-line // comments the real file is full of, because
# stripJsonc's behaviour on them is load-bearing.
DEFAULT_MENU = """\
{
  "system": {"icon":"","label":"System","aliases":["power-menu"]},

  // System
  "system.screensaver": {"icon":"\\uf1eb","label":"Screensaver","action":"omarchy-launch-screensaver force"},
  "system.lock": {"icon":"\\uf023","label":"Lock","action":"omarchy-system-lock"},
  "system.suspend": {"icon":"\\uf186","label":"Suspend","when":"! omarchy-toggle-enabled suspend-off","action":"systemctl suspend"},
  "system.reboot": {"icon":"\\uf021","label":"Reboot","action":"omarchy-system-reboot"},
  "system.shutdown": {"icon":"\\uf011","label":"Shutdown","action":"omarchy-system-shutdown"}
}
"""

# The shipped user-extension template: all comments, parses to {}. This is what
# a stock Omarchy leaves at the path we splice into, which is why the step
# splices rather than refusing on "not ours".
SHIPPED_EXTENSION = """\
{
  // Extend the Quickshell Omarchy menu with JSONC.
  //
  // Reuse an existing id to override/extend it.
  // "personal.notes": {"icon":"x","label":"Notes","action":"true"},
}
"""

# src/deck-session.sh's own marker-delimited block, in the same file. Two
# splices, one file: neither may eat the other.
GAMING_BLOCK = """\
// >>> deck-session.sh: return to Gaming Mode >>>
// installed-by: deck-session.sh
"gaming": {"icon": "G", "label": "Gaming Mode", "action": "deck-session-select gamescope"},
// <<< deck-session.sh: return to Gaming Mode <<<
"""


def tmpdir(name: str) -> pathlib.Path:
    d = WORK / name
    d.mkdir(parents=True, exist_ok=True)
    return d


def mode_of(path: pathlib.Path) -> str:
    return f"{stat.S_IMODE(os.lstat(path).st_mode):04o}"


def make_ctx(target, username="deck", defer=False) -> InstallContext:
    return InstallContext(
        config_path=pathlib.Path("/dev/null"),
        creds_path=pathlib.Path("/dev/null"),
        full_name="Test User",
        email="t@example.invalid",
        encrypt=False,
        authorized_keys_path=None,
        tailscale_authkey_path=None,
        user_configuration={},
        user_credentials={"users": [] if defer else [{"username": username}]},
        arch_config_path=pathlib.Path("/dev/null"),
        omarchy_install={},
        defer_provisioning=defer,
        target=pathlib.Path(target),
    )


def make_target(
    name: str,
    *,
    username: str = "deck",
    home: str | None = None,
    make_home: bool = True,
    defaults: str | None = DEFAULT_MENU,
    existing: str | None = None,
) -> pathlib.Path:
    target = tmpdir(name) / "mnt"
    home = home if home is not None else f"/home/{username}"
    (target / "etc").mkdir(parents=True, exist_ok=True)
    (target / "etc/passwd").write_text(
        "root:x:0:0::/root:/bin/bash\n"
        f"{username}:x:{TEST_UID}:{TEST_GID}::{home}:/bin/bash\n"
    )
    if make_home:
        (target / home.lstrip("/")).mkdir(parents=True, exist_ok=True)
    if defaults is not None:
        path = target / dml.MENU_DEFAULTS_REL
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(defaults)
    if existing is not None:
        path = target / home.lstrip("/") / dml.MENU_EXT_REL
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(existing)
    return target


def quiet(fn, *args, **kwargs):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        result = fn(*args, **kwargs)
    return result, buf.getvalue()


def merged_model(target, home="/home/deck"):
    """The model Quickshell would build from what is on this target."""
    defaults = dml.parse_menu_jsonc((target / dml.MENU_DEFAULTS_REL).read_text())
    user = dml.parse_menu_jsonc((target / home.lstrip("/") / dml.MENU_EXT_REL).read_text())
    return dml.merge_menu_sources(defaults, user)


# ---------------------------------------------------------------------------

print("## 1. drift — the runtime facts this module's mechanism depends on")

if RUNTIME_SRC.is_dir():
    menu_model = RUNTIME_SRC / "shell/plugins/menu/MenuModel.js"
    menu_qml = RUNTIME_SRC / "shell/plugins/menu/Menu.qml"
    menu_jsonc = RUNTIME_SRC / "default/omarchy/omarchy-menu.jsonc"
    check_contains(
        "🔴 parseMenuJsonc still SWALLOWS the parse error and returns []",
        menu_model,
        "catch (e) {\n    return []",
    )
    check_contains(
        "🔴 the user FileView still sets printErrors: false, so nothing reports it",
        menu_qml,
        "printErrors: false",
    )
    check_contains(
        "the user extension is still at ~/.config/omarchy/extensions/omarchy-menu.jsonc",
        menu_qml,
        'Quickshell.env("HOME") + "/' + dml.MENU_EXT_REL + '"',
    )
    check_contains(
        "🔴 kind is still derived from `action` — which is why clearing it disarms the row",
        menu_model,
        'var kind = value.action ? "action" : (value.target ? "link" : "menu")',
    )
    check_contains(
        "🔴 mergeMenuSources still keeps an overridden id in its ORIGINAL position",
        menu_model,
        "if (!nextItems[entry.id]) nextOrder.push(entry.id)",
    )
    check_contains(
        "🔴 isVisible still hides on an EXPLICIT false only — which is why `when:` was rejected",
        menu_model,
        "if (entry.when && whenResults && whenResults[entry.id] === false) return false",
    )
    check_contains(
        "…and still hides a childless menu, synchronously, with no guard involved",
        menu_model,
        'if (entry.kind !== "menu" && entry.kind !== "link") return true',
    )
    check_contains(
        "stripJsonc still strips WHOLE-LINE // comments only",
        menu_model,
        'replace(/^\\s*\\/\\/[^\\n]*(\\n|$)/gm, "")',
    )
    check_contains(
        f"the row being overridden is still '{dml.LOCK_ROW_ID}'",
        menu_jsonc,
        f'"{dml.LOCK_ROW_ID}"',
    )
    check_contains(
        f"…and it still runs '{dml.LOCK_ROW_ACTION}'",
        menu_jsonc,
        f'"action":"{dml.LOCK_ROW_ACTION}"',
    )
else:
    NOT_RUN.append(
        f"§1's ten drift checks against the pinned runtime: {RUNTIME_SRC} is not a directory. "
        "Set OMARCHY_DECK_RUNTIME_SRC to a checkout of the pin in iso/RUNTIME to run them."
    )
    print(f"NOTE §1 SKIPPED — no runtime checkout at {RUNTIME_SRC}")

check_true(
    "our markers are NOT src/deck-session.sh's — both blocks live in this one file",
    dml.MENU_BEGIN not in DECK_SESSION_SH.read_text()
    and "deck-session.sh: return to Gaming Mode" not in dml.MENU_BEGIN,
)


print("\n## 2. the transcriptions, including the silent swallow")

check("stripJsonc removes a whole-line // comment", dml.strip_jsonc('{\n  // x\n  "a": 1\n}').strip(),
      '{\n  "a": 1\n}')
check("…and a trailing comma before }", dml.strip_jsonc('{"a": 1,}'), '{"a": 1}')
check(
    "🔴 …but NOT a comment after a value on the same line, which is why the row "
    "we emit is strict single-line JSON",
    dml.parse_menu_jsonc('{"a": {"label":"A"} // nope\n}'),
    [],
)
check(
    "🔴 parseMenuJsonc returns ZERO rows for a malformed file — silently, exactly "
    "as the shell does",
    dml.parse_menu_jsonc('{"a": '),
    [],
)
check("…and for a JSON array", dml.parse_menu_jsonc("[1,2]"), [])
check("an `items` wrapper is honoured", [i["id"] for i in dml.parse_menu_jsonc('{"items":{"a":{}}}')], ["a"])

item = dml.normalize_item("system.lock", {"label": "Lock", "action": "omarchy-system-lock"})
check("normalizeItem derives kind=action from an action", item["kind"], "action")
check("…and the parent from the dotted id", item["parent"], "system")
item = dml.normalize_item("system.lock", {"label": "Lock"})
check("🔴 …and kind=menu when there is no action and no target", item["kind"], "menu")
check("…with action cleared to the empty string, not absent", item["action"], "")
check(
    "🔴 every field is present on a normalized entry — that completeness is what "
    "makes an override CLEAR a field rather than inherit it",
    sorted(item),
    sorted(dml.normalize_item("x", {"action": "a", "target": "t", "when": "w", "checked": "c",
                                    "aliases": ["z"], "provider": "p", "icon": "i", "iconFont": "f",
                                    "title": "T", "description": "d", "label": "L"})),
)

defaults = dml.parse_menu_jsonc(DEFAULT_MENU)
user = dml.parse_menu_jsonc('{"system.lock": {"label": "gone"}}')
items, order = dml.merge_menu_sources(defaults, user)
check("mergeMenuSources overrides by id", items["system.lock"]["label"], "gone")
check("🔴 …clearing the action", items["system.lock"]["action"], "")
check("🔴 …and KEEPING its original position", order.index("system.lock"),
      [i["id"] for i in defaults].index("system.lock") + 1)  # +1: a synthetic root is prepended
check("…without adding a row", len(order), len(defaults) + 1)


print("\n## 3. 🔴 why `when:` was rejected — demonstrated, not asserted in prose")

guarded = dml.parse_menu_jsonc('{"system.lock": {"label":"Lock","action":"omarchy-system-lock","when":"false"}}')
items, order = dml.merge_menu_sources(defaults, guarded)
check(
    "🔴 a `when:`-guarded Lock row is VISIBLE with no guard results — the state "
    "the menu is in on the first open of every session, and after any guard "
    "batch that was killed",
    dml.is_visible(items, order, {}, items["system.lock"]),
    True,
)
check("…and it still carries its action", items["system.lock"]["action"], "omarchy-system-lock")
check(
    "…it only hides once a bash subprocess has answered `false`",
    dml.is_visible(items, order, {"system.lock": False}, items["system.lock"]),
    False,
)
inert = dml.parse_menu_jsonc('{"system.lock": {"label":"x"}}')
items, order = dml.merge_menu_sources(defaults, inert)
check(
    "🔴 the childless-menu override is invisible with NO guard results at all — "
    "structural, synchronous, in the model itself",
    dml.is_visible(items, order, {}, items["system.lock"]),
    False,
)


print("\n## 4. the step, end to end")

target = make_target("step")
record, out = quiet(dml.configure_menu_lock_row, make_ctx(target))
check("the step reports overridden", record["status"], "overridden")
check("…naming the row", record["row"], "system.lock")
check("…and the action it neutralised", record["neutralised_action"], "omarchy-system-lock")
check("…for the resolved user", record["user"], "deck")
check("…writing the user's copy", record["user_path"], "/home/deck/" + dml.MENU_EXT_REL)
check("…and skel's", record["skel"], "/" + dml.MENU_EXT_SKEL_REL)
check("…having merged against the real defaults", record["merged_against_defaults"], True)
check_true("…over the whole menu", record["merged_rows"] >= len(dml.parse_menu_jsonc(DEFAULT_MENU)))
check_true("no warnings on the happy path", not record["warnings"])

user_file = target / "home/deck" / dml.MENU_EXT_REL
skel_file = target / dml.MENU_EXT_SKEL_REL
check("the user's file exists", user_file.is_file(), True)
check("…0644", mode_of(user_file), "0644")
check("skel's file exists too", skel_file.is_file(), True)

items, order = merged_model(target)
check("🔴 the merged Lock row runs nothing", items["system.lock"]["action"], "")
check("🔴 …is a childless menu", items["system.lock"]["kind"], "menu")
check("🔴 …and is invisible with no guard results", dml.is_visible(items, order, {}, items["system.lock"]), False)
check(
    "🔴 …while the rest of the System submenu is untouched and visible",
    [i for i in ("system.reboot", "system.shutdown", "system.screensaver")
     if not dml.is_visible(items, order, {}, items[i])],
    [],
)
check(
    "…and the System submenu itself is still reachable",
    dml.is_visible(items, order, {}, items["system"]),
    True,
)
check_true(
    "the file says, in English, that this device can no longer be locked and how "
    "to undo it",
    "TO GET Lock BACK" in user_file.read_text()
    and "ten seconds" in user_file.read_text(),
)

# Idempotent, which the SSH iterate-in-place loop requires (CLAUDE.md).
first = user_file.read_text()
record2, _ = quiet(dml.configure_menu_lock_row, make_ctx(target))
check("a second run is byte-identical", user_file.read_text(), first)
check("…and says it replaced its own block rather than appending one",
      record2["replaced_existing_block"], True)

# 🔴 The mutation this exists for: a file that PARSES and leaves the row live.
reachable = tmpdir("reachable") / "menu.jsonc"
reachable.write_text('{"system.lock": {"label":"Lock","action":"omarchy-system-lock"}}\n')
check_raises(
    "🔴 a file that parses but leaves system.lock RUNNING something is refused",
    lambda: dml.verify(target, reachable, "reachable", dml.parse_menu_jsonc(DEFAULT_MENU)),
    dml.DeckMenuLockError,
)
reachable.write_text('{"system.lock": {"label":"Lock","target":"system"}}\n')
check_raises(
    "…and so is one repointed at a link, which is visible and followable",
    lambda: dml.verify(target, reachable, "reachable", dml.parse_menu_jsonc(DEFAULT_MENU)),
    dml.DeckMenuLockError,
)
reachable.write_text('{"system.lock": {"label":"Lock","action":"omarchy-system-lock","when":"false"}}\n')
check_raises(
    "🔴 …and so is the `when:` form, which shows until a subprocess says otherwise",
    lambda: dml.verify(target, reachable, "reachable", dml.parse_menu_jsonc(DEFAULT_MENU)),
    dml.DeckMenuLockError,
)


print("\n## 4b. 🔴 a SECOND system.lock further down the file — a later key wins")

# The one case where writing both surfaces and verifying the wrong one is
# invisible: skel is pristine and the USER's file already carries somebody
# else's override. Our block is spliced in at the top; `json.loads` keeps the
# LAST duplicate key; so the row is live again and only a check that reads the
# USER's copy can see it.
target = make_target(
    "duplicate-key",
    existing='{\n"system.lock": {"label":"Lock","action":"omarchy-system-lock"},\n}\n',
)
record, out = quiet(dml.configure_menu_lock_row, make_ctx(target))
check(
    "🔴 the step FAILS rather than reporting a row it did not actually neutralise",
    record["status"],
    "failed",
)
check_true(
    "…naming the cause: a later duplicate key outranks our block",
    "later duplicate key wins" in record["error"],
)
check(
    "🔴 …and skel's copy is perfect, which is precisely why the verification must "
    "read the USER's — a check pointed at skel passes here",
    dml.verify(target, target / dml.MENU_EXT_SKEL_REL, "skel", dml.parse_menu_jsonc(DEFAULT_MENU))["kind"],
    "menu",
)


print("\n## 5. a file that Quickshell would silently discard")

target = make_target("broken", existing='{"a": ')
record, out = quiet(dml.configure_menu_lock_row, make_ctx(target))
check("an unparsable existing extension is a recorded failure", record["status"], "failed")
check_true(
    "…and the message says every row in that file is ALREADY being discarded, "
    "not just ours",
    "silently discarded" in record["error"],
)
check(
    "🔴 …and the user's file was not overwritten: it was already broken and that "
    "is evidence, not something to destroy",
    (target / "home/deck" / dml.MENU_EXT_REL).read_text(),
    '{"a": ',
)

target = make_target("not-object", existing="[1,2]\n")
record, _ = quiet(dml.configure_menu_lock_row, make_ctx(target))
check("an extension that is not an object is refused", record["status"], "failed")

target = make_target("orphan-marker", existing="{\n" + dml.MENU_BEGIN + '\n"x": {},\n}\n')
record, _ = quiet(dml.configure_menu_lock_row, make_ctx(target))
check("a start marker with no end marker is refused rather than guessed at", record["status"], "failed")


print("\n## 6. coexisting with src/deck-session.sh's block in the same file")

target = make_target("coexist", existing="{\n" + GAMING_BLOCK + "}\n")
record, _ = quiet(dml.configure_menu_lock_row, make_ctx(target))
check("the step succeeds over an existing deck-session.sh block", record["status"], "overridden")
items, order = merged_model(target)
check(
    "🔴 the return-to-Gaming-Mode row SURVIVED our splice — it is the one "
    "affordance CLAUDE.md's controller-only rule cannot let fail",
    items["gaming"]["action"],
    "deck-session-select gamescope",
)
check("…and is visible", dml.is_visible(items, order, {}, items["gaming"]), True)
check("…while Lock is not", dml.is_visible(items, order, {}, items["system.lock"]), False)
check_true("…and both marker pairs are still in the file",
           "deck-session.sh: return to Gaming Mode" in (target / "home/deck" / dml.MENU_EXT_REL).read_text())

target = make_target("shipped-template", existing=SHIPPED_EXTENSION)
record, _ = quiet(dml.configure_menu_lock_row, make_ctx(target))
check("the shipped all-comments template is spliced into, not refused", record["status"], "overridden")
check_true(
    "…and its schema documentation is preserved",
    "Extend the Quickshell Omarchy menu with JSONC" in (target / "home/deck" / dml.MENU_EXT_REL).read_text(),
)

target = make_target("no-file")
record, _ = quiet(dml.configure_menu_lock_row, make_ctx(target))
check("an absent extension file is created", record["status"], "overridden")
check_true("…and parses", dml.parse_menu_jsonc((target / "home/deck" / dml.MENU_EXT_REL).read_text()))


print("\n## 7. 🔴 /etc/skel is TOO LATE for the user this image already created")

target = make_target("skel-trap")
quiet(dml.configure_menu_lock_row, make_ctx(target))
user_file = target / "home/deck" / dml.MENU_EXT_REL
check("both surfaces were written", [user_file.is_file(), (target / dml.MENU_EXT_SKEL_REL).is_file()],
      [True, True])
user_file.unlink()
check_raises(
    "🔴 the verification reads the USER's copy — remove it and the check goes red "
    "even though skel's is perfect",
    lambda: dml.verify(target, user_file, "the user's copy",
                       dml.parse_menu_jsonc(DEFAULT_MENU)),
    dml.DeckMenuLockError,
)
check_true(
    "…and skel's copy is still there and still verifies, so the red above really "
    "is 'the user did not get it' and not 'nothing was written'",
    dml.verify(target, target / dml.MENU_EXT_SKEL_REL, "skel", dml.parse_menu_jsonc(DEFAULT_MENU)),
)
try:
    dml.verify(target, user_file, "the user's copy", dml.parse_menu_jsonc(DEFAULT_MENU))
except dml.DeckMenuLockError as exc:
    check_true("…with a message that names the trap by its cause", "TOO LATE" in str(exc)
               and "phase 3 of 14" in str(exc))

# A home that is not /home/<name>: useradd honours -d, and deck_user reads
# /etc/passwd for exactly this reason.
target = make_target("odd-home", home="/var/lib/kiosk")
record, _ = quiet(dml.configure_menu_lock_row, make_ctx(target))
check("a non-standard home is honoured, not composed", record["user_path"],
      "/var/lib/kiosk/" + dml.MENU_EXT_REL)
check("…and the file is there", (target / "var/lib/kiosk" / dml.MENU_EXT_REL).is_file(), True)
check("…and /home/deck was never created", (target / "home/deck").exists(), False)


print("\n## 8. the cases that are not failures")

target = make_target("deferred")
record, _ = quiet(dml.configure_menu_lock_row, make_ctx(target, defer=True))
check(
    "🔴 a defer_provisioning install is 'skel-only', a distinct status — the "
    "account does not exist yet, so skel is exactly right rather than too late",
    record["status"],
    "skel-only",
)
check("…skel was written", (target / dml.MENU_EXT_SKEL_REL).is_file(), True)
check("…and no home was invented", (target / "home/deck" / dml.MENU_EXT_REL).exists(), False)
check_true("…and the reason is recorded", any("first boot" in w for w in record["warnings"]))

target = make_target("no-defaults", defaults=None)
record, _ = quiet(dml.configure_menu_lock_row, make_ctx(target))
check("a target with no default menu still gets the override", record["status"], "overridden")
check("…recorded as unmerged", record["merged_against_defaults"], False)
check_true("…and reported, never silently skipped",
           any("could not be checked against the menu it overrides" in w for w in record["warnings"]))

target = make_target("renamed", defaults=DEFAULT_MENU.replace("system.lock", "system.screenlock"))
record, _ = quiet(dml.configure_menu_lock_row, make_ctx(target))
check("an upstream rename does not fail the step", record["status"], "overridden")
check_true(
    "🔴 …but is reported: a lock producer may be live under another id and this "
    "step is then defending against nothing",
    any("renamed it" in w for w in record["warnings"]),
)

target = make_target("changed-action", defaults=DEFAULT_MENU.replace("omarchy-system-lock", "omarchy-shell lock lock"))
record, _ = quiet(dml.configure_menu_lock_row, make_ctx(target))
check("an upstream action change does not fail the step", record["status"], "overridden")
check_true("…but is reported", any("Upstream changed it" in w for w in record["warnings"]))

target = make_target("no-user", username="deck")
(target / "etc/passwd").write_text("root:x:0:0::/root:/bin/bash\n")
record, _ = quiet(dml.configure_menu_lock_row, make_ctx(target))
check("an account the installer names but never created is a failure", record["status"], "failed")
check("…and nothing was written for nobody", (target / dml.MENU_EXT_SKEL_REL).exists(), False)


print("\n## 9. the step entry point, the shared document, and the registry")

target = make_target("registry")
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    deck_configure.record_result(target, "wifi", {"status": "skipped"})
    dml.menu_lock_row_step(make_ctx(target))
log_path = target / deck_configure.DECK_INSTALL_LOG_REL
doc = json.loads(log_path.read_text())
check("the outcome lands under 'menu_lock_row'", doc["menu_lock_row"]["status"], "overridden")
check("…without clobbering another step's key", doc["wifi"]["status"], "skipped")
check("…and the log stays 0644", mode_of(log_path), "0644")
check_true(
    "🔴 the record names the affordance that was removed, so the decision is "
    "visible in the support artefact rather than only in a comment",
    doc["menu_lock_row"]["neutralised_action"] == "omarchy-system-lock",
)

target = make_target("registry-fail", existing='{"a": ')
raised = None
buf = io.StringIO()
try:
    with contextlib.redirect_stdout(buf):
        dml.menu_lock_row_step(make_ctx(target))
except Exception as exc:  # noqa: BLE001
    raised = exc
check("🔴 the step does not raise on failure: critical=False, the record is the report", raised, None)
check(
    "…and the failure is recorded",
    json.loads((target / deck_configure.DECK_INSTALL_LOG_REL).read_text())["menu_lock_row"]["status"],
    "failed",
)
check_true("…loudly, on the console the install log captures", "Deck menu lock row" in buf.getvalue())

names = [s.name for s in deck_configure.deck_steps()]
check("the menu_lock_row step is registered", "menu_lock_row" in names, True)
step = [s for s in deck_configure.deck_steps() if s.name == "menu_lock_row"][0]
check("…bound to menu_lock_row_step", step.fn, dml.menu_lock_row_step)
check(
    "🔴 …and non-critical: a locked Deck is a ten-second power hold from the "
    "autologin deck_autologin guarantees; a greeter has no escape at all",
    step.critical,
    False,
)
check(
    "🔴 exactly one step in the whole registry is still critical",
    [s.name for s in deck_configure.deck_steps() if s.critical],
    ["autologin"],
)


print()
for note in NOT_RUN:
    print(f"NOT RUN: {note}")
print(f"{CHECKS - FAILURES}/{CHECKS} checks passed")
if FAILURES:
    print(f"{FAILURES} FAILURES")
shutil.rmtree(WORK, ignore_errors=True)
sys.exit(1 if FAILURES else 0)

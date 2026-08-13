"""The third lock producer: the ``Lock`` row in Omarchy's own menu.

SHIPPED AS ``/usr/share/omarchy-iso/orchestrator/deck_menu_lock.py``. The
``menu_lock_row`` step registered in ``deck_configure.deck_steps``.
``docs/tasks/T5-fork-plan.md`` §5.6, ``docs/PROGRESS.md`` §5.24.

THE PRODUCER
============

``docs/PROGRESS.md`` §5.24 names three ways this handheld can be put behind a
password prompt it has no keyboard to answer. Two are handled elsewhere:

============================  ==========================================
producer                      where it is handled
============================  ==========================================
``idle.lock`` timeout          ``deck_session_settings.idle_policy_step``
``omarchy-sleep-lock.service`` masked; ``src/``, another slice
🔴 ``system.lock`` menu row    **here**
============================  ==========================================

The row is Omarchy's, at ``default/omarchy/omarchy-menu.jsonc``:
``"system.lock": {"icon": "…", "label": "Lock", "action": "omarchy-system-lock"}``
**(READ,** the pinned runtime**)**. It sits in the ``System`` submenu -- the same
menu our own "return to Gaming Mode" row lives in -- two presses from the root.

🔴 THE DECISION, AND THE TRADE-OFF STATED RATHER THAN MADE INVISIBLY
====================================================================

**This step makes the Lock row unreachable and inert.** That is the removal of a
security affordance from somebody's computer, and it is not a decision that
should be discoverable only by noticing the row is gone. So:

*Why:* on a fresh install from this ISO, choosing Lock produces a screen with no
way back. There is no physical keyboard; ``lizard_mode`` is ``Y`` after every
boot (``docs/PROGRESS.md`` §5.21) so the trackpad emits no letters; our own
on-screen keyboard renders **beneath** an ``ext-session-lock`` surface unless
Hyprland has been told otherwise, and **nothing in this ISO bakes that rule in
yet** (§5.6's ``above_lock = 2`` lives in a per-user ``input.lua`` that no step
writes). There is also no ``unlock`` IPC -- ``qs ipc show`` gives the lock target
``lock``, ``isLocked``, ``status``, ``preview``, ``hidePreview`` and nothing that
releases it (``docs/PROGRESS.md`` §5.24a) -- and the documented recovery in
``docs/RECOVERY.md`` was found not to work at all. The only escape is a
ten-second power hold.

*What is lost:* anyone who picks the Deck up gets the desktop. This is the same
trade-off §5.6 already makes explicit for the sleep-lock unit -- **a suspended
Deck resumes unlocked, deliberately, because it has no keyboard** -- and it is
recorded here so that the two halves of one decision are not argued in two
places with different reasoning.

*What keeps it honest:*

1. **Upstream's file is not edited.** The row is overridden from
   ``~/.config/omarchy/extensions/omarchy-menu.jsonc``, the documented user
   extension point, which the owner of the machine owns.
2. **The override is marker-delimited and says so in plain English**, with the
   instruction for getting Lock back on the line above it. Everything outside
   the markers is preserved byte for byte.
3. **It is recorded** in ``/var/log/omarchy-deck-install.json`` under
   ``menu_lock_row``, beside every other thing this phase did.

⚠️ **Owed, and not in this slice:** ``docs/RECOVERY.md`` and §5.6 should carry
the same sentence. This slice does not own ``docs/``.

🔴 WHY IT IS AN OVERRIDE AND NOT A DELETION, AND WHY NOT ``when:``
==================================================================

**Deletion is not available.** ``MenuModel.js``'s ``mergeMenuSources`` walks the
defaults and then the user file and merges per id; there is no syntax that
removes a default row. The default file itself is package-owned
(``/usr/share/omarchy/default/omarchy/…``) and an edit there is reverted by the
next ``omarchy-dev`` upgrade -- that is T12's applier's territory, not
``configure_deck``'s, and this module owns no part of ``/usr/share/omarchy``.

**``when:`` was considered and rejected, on upstream's own evidence.**
``Menu.qml``'s guard block says it outright **(READ)**: *"a row whose ``when:``
went unanswered shows"*, and *"a batch that was killed rather than finished has
only told us about the rows it reached"*. ``isVisible`` hides a row only on an
**explicit** ``false``:

    if (entry.when && whenResults && whenResults[entry.id] === false) return false

``whenResults`` starts empty, is filled by a ``bash -lc`` subprocess that runs
per reload, and is discarded when that subprocess is killed or exits non-zero.
So a ``when:``-hidden Lock row is **live on the first open of every session** and
after any failed guard batch -- and it would still carry its ``action``. For a
row whose whole problem is that pressing it strands the device, "hidden almost
always" is not a fix.

**What is used instead is structural.** ``normalizeItem`` derives
``kind = value.action ? "action" : (value.target ? "link" : "menu")``, and
``mergeMenuSources`` merges the *normalized* entries -- which carry every field,
including the empty ones -- so redeclaring the id **clears** ``action``. The row
becomes ``kind: "menu"`` with no children, and ``isVisible`` returns false for a
childless menu **without consulting any guard, synchronously, in the model
itself**. Pressing it, in the impossible case it were drawn, opens an empty
submenu and runs nothing.

⚠️ ``mergeMenuSources`` keeps an overridden id **in its original position**
(``if (!nextItems[entry.id]) nextOrder.push(entry.id)`` -- the id is already
there, so no new slot is taken). Nothing else in the menu moves.

🔴 A MALFORMED FILE SILENTLY DROPS *EVERY* CUSTOM ROW
=====================================================

``parseMenuJsonc`` catches the JSON error and returns ``[]``; the ``FileView``
that loads the user file sets ``printErrors: false`` **(READ,** both**)**. So one
bad byte in this file removes our Lock override **and** ``src/deck-session.sh``'s
"return to Gaming Mode" row -- the one affordance ``CLAUDE.md``'s controller-only
rule cannot let fail -- and reports nothing, anywhere. Therefore: what this step
writes is **parsed back the way Quickshell parses it**, merged against the
target's own default menu with a transcription of ``mergeMenuSources``, and the
resulting row is asserted invisible. Exactly what ``stage_menu_row`` does, for
exactly the same reason.

``stripJsonc`` strips **whole-line** ``//`` comments only, plus trailing commas.
A comment after a value on the same line breaks the parse, so the row itself is
emitted as strict, single-line JSON.

🔴 ``/etc/skel`` IS TOO LATE FOR THE USER THIS IMAGE CREATES
============================================================

``docs/tasks/T5-fork-plan.md`` §3 trap (a). ``useradd`` ran in phase 3 of 14.
Both surfaces are written; **the created user's copy is the one verified.**

``critical=False``, AND THE COUNTER-ARGUMENT FIRST
==================================================

*Against, and it is the strongest counter-argument in this registry after
``deck_autologin``'s:* §5.6 exists so that "a fresh install from our ISO must
not be lockable into a password prompt nobody can answer". If this step fails,
that sentence is false, and the outcome -- a device whose owner cannot get back
into it -- is the same *class* as the greeter that made ``deck_autologin``
``critical=True``.

*For ``critical=False``, and this is what won:*

1. **The failure is escapable and the greeter is not.** A locked Deck is a
   ten-second power hold away from a reboot that autologins straight into Gaming
   Mode -- because ``deck_autologin`` is ``critical=True`` and guarantees it. A
   Deck at an SDDM password prompt has no such escape at any hold length. That
   difference is the line, and it is the reason exactly one step in this
   registry is critical.
2. **This producer needs a deliberate press.** The other two fire unattended --
   five idle minutes, or the power button. Nothing reaches this row without a
   human choosing a row labelled "Lock". A failure here is a hazard the user can
   avoid; the other two were hazards they could not.
3. **Every input is upstream-owned and drifting.** The id ``system.lock``, the
   extension path, ``stripJsonc``'s exact behaviour and ``isVisible``'s rules are
   all Omarchy's, read out of a *pinned* runtime that has already moved under
   this project once. ``deck_patches.py``'s argument 3: a rule that turns
   "upstream renamed a menu id" into "the installer refuses to produce a
   machine" fails the ISO at the most expensive possible moment, for a row.
4. **Succeeding here does not make the Deck safe anyway.** ``above_lock = 2`` is
   what makes *any* lock answerable, and no step bakes it in. The same argument
   ``deck_session_settings`` makes for the idle timeout: this step is one of
   three, and one of three is not a guarantee.

⚠️ 🔴 **The weakness in argument 1, written down rather than glossed.** The escape
is a hard power cut on a Btrfs system mid-write. It is a real escape and it is
not a graceful one, and it is the entire distance between this step and
``critical=True``.
"""

from __future__ import annotations

import json
import os
import re
from pathlib import Path

from .deck_configure import record_result, sanitize_text
from .deck_user import DeckUserDeferred, DeckUserError, resolve_target_user
from .ui import error, info

# ---------------------------------------------------------------------------
# Where the two menu files live
# ---------------------------------------------------------------------------

# Menu.qml: Quickshell.env("HOME") + "/.config/omarchy/extensions/omarchy-menu.jsonc"
MENU_EXT_REL = ".config/omarchy/extensions/omarchy-menu.jsonc"
MENU_EXT_SKEL_REL = f"etc/skel/{MENU_EXT_REL}"
# Menu.qml: omarchyPath + "/default/omarchy/omarchy-menu.jsonc"
MENU_DEFAULTS_REL = "usr/share/omarchy/default/omarchy/omarchy-menu.jsonc"
MENU_EXT_MODE = 0o644

# The id being overridden, and the action it carries upstream. The action is
# recorded so the record says WHAT was neutralised, and so a future upstream
# rename shows up as "the row we found ran something else" rather than as
# silence.
LOCK_ROW_ID = "system.lock"
LOCK_ROW_ACTION = "omarchy-system-lock"
LOCK_ROW_LABEL = "Lock (disabled: this device has no keyboard)"

# Our own markers. DIFFERENT from src/deck-session.sh's
# "// >>> deck-session.sh: return to Gaming Mode >>>" pair, deliberately: both
# blocks live in this one file, both splices preserve everything outside their
# own markers, and sharing a marker would make each one eat the other.
MENU_BEGIN = "// >>> omarchy-deck: the Lock row is disabled on this handheld >>>"
MENU_END = "// <<< omarchy-deck: the Lock row is disabled on this handheld <<<"

MAX_MENU_BYTES = 1024 * 1024


class DeckMenuLockError(Exception):
    """The Lock row could not be neutralised. Non-critical: see the docstring."""


# ---------------------------------------------------------------------------
# MenuModel.js, transcribed
#
# 🔴 Transcribed rather than approximated. The whole value of the verification
# below is that it runs the PRODUCT'S OWN algorithm over the file we wrote; a
# reimplementation that merely agrees with our intentions would pass whatever we
# wrote. test/unit/test-deck-menu-lock.py checks these against the pinned
# runtime's JavaScript where it can, and against fixtures taken from it where it
# cannot.
# ---------------------------------------------------------------------------

_COMMENT_RE = re.compile(r"^\s*//[^\n]*(\n|$)", re.M)
_TRAILING_RE = re.compile(r",(\s*[}\]])")


def strip_jsonc(raw: str) -> str:
    """``stripJsonc``. **Whole-line ``//`` comments only**, plus trailing commas."""
    return _TRAILING_RE.sub(r"\1", _COMMENT_RE.sub("", raw or ""))


def normalize_aliases(value) -> list:
    if isinstance(value, list):
        return [v for v in value if v]
    if isinstance(value, str) and value:
        return [value]
    return []


def normalize_item(item_id: str, raw) -> dict:
    """``normalizeItem``. Every field is present, including the empty ones.

    🔴 That completeness is the mechanism this whole module turns on: because a
    normalized entry always carries ``action``, merging one on top of another
    **clears** the action rather than inheriting it.
    """
    value = raw or {}
    parent = value.get("parent")
    if parent is None:
        parent = item_id.rsplit(".", 1)[0] if "." in item_id else "root"
    if item_id == "root":
        parent = ""
    kind = "action" if value.get("action") else ("link" if value.get("target") else "menu")
    return {
        "id": item_id,
        "parent": parent,
        "kind": kind,
        "icon": value.get("icon") or "",
        "iconFont": value.get("iconFont") or "",
        "label": value.get("label") or item_id,
        "title": value.get("title") or "",
        "target": value.get("target") or "",
        "description": value.get("description") or "",
        "action": value.get("action") or "",
        "provider": value.get("provider") or "",
        "aliases": normalize_aliases(value.get("aliases")),
        "when": value.get("when") or "",
        "checked": value.get("checked") or "",
    }


def parse_menu_jsonc(raw: str) -> list[dict]:
    """``parseMenuJsonc``. 🔴 **Returns [] on a parse error, silently.**

    Faithful to the swallow, on purpose. A transcription that raised would be a
    more useful function and a less honest model of what the shell does, and
    what the shell does is the thing this step has to defend against.
    """
    stripped = strip_jsonc(raw)
    if not stripped.strip():
        return []
    try:
        parsed = json.loads(stripped)
    except ValueError:
        return []
    if not isinstance(parsed, dict):
        return []
    source = parsed["items"] if isinstance(parsed.get("items"), dict) else parsed
    out = []
    for item_id, entry in source.items():
        if not isinstance(entry, dict):
            continue
        out.append(normalize_item(item_id, entry))
    return out


def merge_menu_sources(default_items, user_items) -> tuple[dict, list[str]]:
    """``mergeMenuSources``. User rows merged on top, **positions preserved**."""
    next_items: dict = {}
    next_order: list[str] = []
    for src in (default_items or [], user_items or []):
        for entry in src:
            if not entry or not entry.get("id"):
                continue
            item_id = entry["id"]
            if item_id not in next_items:
                next_order.append(item_id)
            merged = dict(next_items.get(item_id, {}))
            merged.update(entry)
            merged["id"] = item_id
            next_items[item_id] = merged
    if "root" not in next_items:
        next_items["root"] = normalize_item("root", {"label": "Go"})
        next_order.insert(0, "root")
    for i, item_id in enumerate(next_order):
        next_items[item_id]["order"] = i
    return next_items, next_order


def is_visible(items, item_order, when_results, entry, depth: int = 0) -> bool:
    """``isVisible``.

    🔴 Note the first branch: a row hides on an **explicit** ``False`` only. An
    empty ``when_results`` -- the state the menu is in before its guard
    subprocess has answered, and after any guard batch that was killed -- shows
    every ``when:``-guarded row. That is the measured reason this module does not
    use ``when:``, and the transcription keeps the behaviour so the test can
    demonstrate it rather than assert a claim about it.
    """
    if not entry:
        return False
    if entry.get("when") and when_results and when_results.get(entry["id"]) is False:
        return False
    if entry.get("kind") not in ("menu", "link"):
        return True
    if entry.get("provider"):
        return True
    if depth >= 32:
        return False
    target = entry["target"] if entry.get("kind") == "link" else entry["id"]
    for item_id in item_order:
        child = items.get(item_id)
        if child and child.get("parent") == target and is_visible(
            items, item_order, when_results, child, depth + 1
        ):
            return True
    return False


# ---------------------------------------------------------------------------
# What gets written
# ---------------------------------------------------------------------------


def render_block() -> list[str]:
    """The marker-delimited block, as lines.

    The row is strict single-line JSON with a trailing comma: ``stripJsonc``
    removes the comma when our block is the only content in the object and it
    separates entries when it is not, which is what lets the block be spliced in
    at a fixed position whether the rest of the file is empty or full. Same
    shape, and the same reasoning, as ``render_menu_row_block`` in
    ``src/deck-session.sh``.
    """
    return [
        MENU_BEGIN,
        "// installed-by: configure_deck (omarchy-deck ISO). docs/PROGRESS.md 5.24.",
        "//",
        "// SECURITY, STATED PLAINLY: this Deck can no longer be locked from the",
        "// menu. That is deliberate. It has no keyboard; the trackpad emits no",
        "// letters until lizard mode is turned off, which resets on every boot;",
        "// and there is no unlock IPC. A lock screen this device cannot answer is",
        "// escapable only by holding the power button for ten seconds. The same",
        "// trade-off is why a suspended Deck resumes unlocked.",
        "//",
        "// TO GET Lock BACK: delete these lines. Nothing else has to change --",
        "// Omarchy's own row is untouched in",
        "// /usr/share/omarchy/default/omarchy/omarchy-menu.jsonc and comes back",
        "// the moment this override is gone.",
        "//",
        "// HOW IT WORKS: MenuModel.js merges this file on top of the defaults by",
        "// id, and normalizeItem gives every entry an 'action' -- so redeclaring",
        "// the id with no action CLEARS it. The row becomes a submenu with no",
        "// children, and isVisible() hides a childless submenu in the model",
        "// itself. No 'when:' guard: Menu.qml's own comment says a row whose",
        "// when: went unanswered SHOWS, so a guarded row would be live on the",
        "// first open of every session.",
        # Strict, single-line JSON: stripJsonc only removes WHOLE-LINE '//'
        # comments, so a comment after a value on this line breaks the parse and
        # takes every row in the file with it. No "action", no "target", no
        # "when" -- that absence IS the mechanism.
        f'"{LOCK_ROW_ID}": {json.dumps({"label": LOCK_ROW_LABEL})},',
        MENU_END,
    ]


def splice(raw: str, block: list[str]) -> tuple[str, bool]:
    """``(new text, replaced an existing block)``. A splice, not a rewrite.

    This file is a documented, user-facing extension point that already exists
    on a stock Omarchy (the shipped template is all comments and parses to
    ``{}``), and ``src/deck-session.sh`` splices its own marker-delimited block
    into the very same file. So every byte outside our own markers is preserved,
    and no JSONC merger is invented: the block is inserted as text immediately
    after the object's opening brace, and the RESULT is parsed afterwards.

    It refuses on the three cases where a splice cannot be honest -- the same
    three ``splice_menu_row`` refuses on.
    """
    if strip_jsonc(raw).strip():
        try:
            existing = json.loads(strip_jsonc(raw))
        except ValueError as exc:
            raise DeckMenuLockError(
                f"the existing menu extension is not valid JSONC ({exc}). Quickshell does not "
                "report this -- parseMenuJsonc catches the error and returns an empty list, and "
                "the FileView sets printErrors: false -- so EVERY row in that file is already "
                "being silently discarded, not just ours"
            ) from exc
        if not isinstance(existing, dict):
            raise DeckMenuLockError(
                f"the existing menu extension parses as {type(existing).__name__}, not a JSON "
                "object of menu ids"
            )

    kept: list[str] = []
    skipping = False
    replaced = False
    for line in raw.splitlines():
        bare = line.strip()
        if bare == MENU_BEGIN:
            skipping, replaced = True, True
            continue
        if skipping:
            if bare == MENU_END:
                skipping = False
            continue
        kept.append(line)
    if skipping:
        raise DeckMenuLockError(
            "the menu extension carries our start marker with no end marker. Refusing to guess "
            "where the old block ended -- remove it by hand and re-run"
        )

    opener = None
    for i, line in enumerate(kept):
        bare = line.strip()
        if not bare or bare.startswith("//"):
            continue
        if not bare.startswith("{"):
            raise DeckMenuLockError(
                f"the menu extension does not open with a JSON object (first content line is "
                f"{sanitize_text(line)!r})"
            )
        opener = (i, line.index("{"))
        break

    out: list[str] = []
    if opener is None:
        # An absent file, or one that is nothing but comments. Whatever was
        # there is comments, and it is kept above the object we open.
        out.extend(kept)
        out.append("{")
        out.extend(block)
        out.append("}")
    else:
        i, col = opener
        out.extend(kept[:i])
        out.append(kept[i][: col + 1])
        out.extend(block)
        rest = kept[i][col + 1 :]
        if rest.strip():
            out.append(rest)
        out.extend(kept[i + 1 :])

    return "\n".join(out).rstrip("\n") + "\n", replaced


def read_defaults(target) -> tuple[list[dict], list[str]]:
    """Omarchy's own menu, parsed the way the shell parses it. Plus warnings."""
    warnings: list[str] = []
    path = Path(target) / MENU_DEFAULTS_REL
    if not path.is_file():
        warnings.append(
            f"/{MENU_DEFAULTS_REL} is not on the target, so the override could not be checked "
            "against the menu it overrides. The override itself is still correct -- an id with no "
            "default behind it simply adds nothing visible -- but the merge was not exercised"
        )
        return [], warnings
    data = path.read_bytes()
    if len(data) > MAX_MENU_BYTES:
        raise DeckMenuLockError(f"/{MENU_DEFAULTS_REL} is {len(data)} bytes; refusing to parse it")
    items = parse_menu_jsonc(data.decode("utf-8", "replace"))
    if not items:
        warnings.append(
            f"/{MENU_DEFAULTS_REL} parsed to ZERO rows. parseMenuJsonc swallows its own error, so "
            "this is what Quickshell sees too: the whole default menu is being discarded"
        )
        return [], warnings
    found = [i for i in items if i["id"] == LOCK_ROW_ID]
    if not found:
        warnings.append(
            f"the default menu has no '{LOCK_ROW_ID}' row at all. Either upstream renamed it -- in "
            "which case a producer of an unanswerable lock screen is live under another id and "
            "this step is defending against nothing -- or it was already removed"
        )
    elif found[0]["action"] != LOCK_ROW_ACTION:
        warnings.append(
            f"the default '{LOCK_ROW_ID}' row runs '{sanitize_text(found[0]['action'])}', not "
            f"'{LOCK_ROW_ACTION}'. Upstream changed it; the override still clears the action, but "
            "what it is clearing is no longer what this module documents"
        )
    return items, warnings


def verify(target, path: Path, label: str, defaults: list[dict]) -> dict:
    """Read the file back the way Quickshell reads it, and prove the row is dead.

    🔴 The caller points this at the **created user's** copy. §3 trap (a): a
    check that reads only ``/etc/skel`` is the canonical passes-for-the-wrong-
    reason failure for this task.
    """
    if not path.is_file():
        raise DeckMenuLockError(
            f"{label} was not written ({path} does not exist). /etc/skel alone is TOO LATE for "
            "the account this image already created -- it is copied at useradd time, which was "
            "phase 3 of 14"
        )
    raw = path.read_text(errors="replace")
    user_items = parse_menu_jsonc(raw)
    if not user_items:
        raise DeckMenuLockError(
            f"{label} parses to ZERO rows through parseMenuJsonc. That is the silent failure this "
            "step exists to avoid: the shell would discard every custom row in the file -- ours "
            "and src/deck-session.sh's return-to-Gaming-Mode row alike -- and report nothing"
        )
    ours = [i for i in user_items if i["id"] == LOCK_ROW_ID]
    if not ours:
        raise DeckMenuLockError(f"{label} parses but carries no '{LOCK_ROW_ID}' row")

    # 🔴 The check that matters: the PRODUCT'S merge, over the target's own
    # defaults, and then the product's own visibility rule.
    items, order = merge_menu_sources(defaults, user_items)
    merged = items.get(LOCK_ROW_ID)
    if merged is None:
        raise DeckMenuLockError(f"'{LOCK_ROW_ID}' vanished from the merged model entirely")
    if merged.get("action"):
        raise DeckMenuLockError(
            f"after merging, '{LOCK_ROW_ID}' still runs "
            f"'{sanitize_text(merged['action'])}'. The override did not clear the action, so the "
            "row is still a live lock producer. ⚠️ The likeliest cause is a SECOND "
            f"'{LOCK_ROW_ID}' declaration further down this file: our block is spliced in at the "
            "top and a later duplicate key wins in JSON, so somebody else's override -- or an "
            "earlier hand edit -- silently outranks it"
        )
    if merged.get("target"):
        raise DeckMenuLockError(
            f"after merging, '{LOCK_ROW_ID}' is a link to '{sanitize_text(merged['target'])}'; a "
            "link is visible and followable"
        )
    if merged.get("kind") != "menu":
        raise DeckMenuLockError(
            f"after merging, '{LOCK_ROW_ID}' has kind '{merged.get('kind')}', not 'menu'. Only a "
            "childless menu is hidden by isVisible without asking a shell guard"
        )
    # Empty guard results on purpose: this is the state the menu is in on the
    # first open of every session, and a row that is only hidden once a bash
    # subprocess has answered is not hidden.
    if is_visible(items, order, {}, merged):
        raise DeckMenuLockError(
            f"isVisible() still shows '{LOCK_ROW_ID}' with NO guard results -- which is the state "
            "the menu is in on the first open of every session. The row is reachable"
        )
    return {"kind": merged.get("kind"), "order": merged.get("order"), "rows": len(order)}


def install(target, rel: str, owner=None) -> bool:
    """Splice the block into one file. Returns True if a previous block was replaced."""
    path = Path(target) / rel
    raw = ""
    if path.exists() and not path.is_symlink():
        data = path.read_bytes()
        if len(data) > MAX_MENU_BYTES:
            raise DeckMenuLockError(f"/{rel} is {len(data)} bytes; refusing to parse it")
        raw = data.decode("utf-8", "replace")
    elif path.is_symlink():
        path.unlink()

    text, replaced = splice(raw, render_block())

    created: list[Path] = []
    parent = path.parent
    while not parent.exists():
        created.append(parent)
        parent = parent.parent
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    os.chmod(path, MENU_EXT_MODE)

    if owner is not None:
        # Every directory this step created, plus the file. A root-owned
        # ~/.config/omarchy is a home the desktop cannot write to.
        for directory in created:
            _chown(directory, owner)
        _chown(path, owner)
    return replaced


def _chown(path: Path, owner) -> None:
    try:
        os.chown(path, owner.uid, owner.gid)
    except OSError as exc:
        raise DeckMenuLockError(f"could not chown {path} to uid {owner.uid}: {exc}") from exc


def configure_menu_lock_row(ctx) -> dict:
    """Neutralise the Lock row on both surfaces; return the record."""
    target = Path(ctx.target)
    record: dict = {
        "status": None,
        "row": LOCK_ROW_ID,
        "neutralised_action": LOCK_ROW_ACTION,
        "skel": None,
        "user": None,
        "user_path": None,
        "merged_against_defaults": None,
        "merged_rows": None,
        "replaced_existing_block": None,
        "error": None,
        "warnings": [],
    }
    warnings: list[str] = record["warnings"]

    owner = None
    deferred = False
    try:
        user, user_warnings = resolve_target_user(ctx)
        owner = user
        warnings.extend(user_warnings)
        record["user"] = sanitize_text(user.name)
    except DeckUserDeferred as exc:
        # The one case where skel alone is right rather than too late: the
        # account does not exist yet, and omarchy-provision-owner's useradd will
        # copy skel when it creates one at first boot.
        deferred = True
        warnings.append(f"{exc}; writing /etc/skel only, which is what a later useradd copies")
    except DeckUserError as exc:
        record["status"] = "failed"
        record["error"] = sanitize_text(f"{type(exc).__name__}: {exc}", limit=400)
        error(f"Deck menu lock row: {record['error']}")
        return record

    try:
        defaults, default_warnings = read_defaults(target)
        warnings.extend(default_warnings)
        record["merged_against_defaults"] = bool(defaults)

        # Skel first: it is the cheap one and it needs no account.
        install(target, MENU_EXT_SKEL_REL)
        record["skel"] = "/" + MENU_EXT_SKEL_REL
        verify(target, target / MENU_EXT_SKEL_REL, f"/{MENU_EXT_SKEL_REL}", defaults)

        if deferred:
            record["status"] = "skel-only"
            info(
                f"Deck menu lock row: '{LOCK_ROW_ID}' neutralised in /{MENU_EXT_SKEL_REL} only "
                "(deferred provisioning creates the account at first boot)"
            )
            for warning in warnings:
                error(f"Deck menu lock row: {warning}")
            return record

        user_rel = owner.home.lstrip("/") + "/" + MENU_EXT_REL
        record["replaced_existing_block"] = install(target, user_rel, owner=owner)
        record["user_path"] = "/" + user_rel
        proof = verify(target, target / user_rel, f"{owner.name}'s /{user_rel}", defaults)
        record["merged_rows"] = proof["rows"]
    except (DeckMenuLockError, OSError) as exc:
        record["status"] = "failed"
        record["error"] = sanitize_text(f"{type(exc).__name__}: {exc}", limit=400)
        error(f"Deck menu lock row: {record['error']}")
        for warning in warnings:
            error(f"Deck menu lock row: {warning}")
        return record

    record["status"] = "overridden"
    info(
        f"Deck menu lock row: '{LOCK_ROW_ID}' overridden to an inert, invisible row in "
        f"{record['user_path']} (and /etc/skel); proved invisible through the shell's own merge "
        f"over {record['merged_rows']} rows, with NO guard results. This device can no longer be "
        "locked from the menu -- deliberately; it has no keyboard"
    )
    for warning in warnings:
        error(f"Deck menu lock row: {warning}")
    return record


def menu_lock_row_step(ctx) -> None:
    """``DeckStep`` entry point. Records under ``menu_lock_row``."""
    record_result(ctx.target, "menu_lock_row", configure_menu_lock_row(ctx))

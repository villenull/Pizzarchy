"""P34. Answer Steam's first-run wizard from what the installer already knows.

SHIPPED AS ``/usr/share/omarchy-iso/orchestrator/deck_steam_seed.py``, a module
inside the upstream orchestrator package, hence the relative imports.
``test/unit/test-deck-steam-seed.py`` builds the package shape around it.

WHAT WAS OBSERVED, AND WHAT IS ACTUALLY WRONG WITH IT
=====================================================

On the first hardware boot (2026-08-16) the user is walked through Steam's own
out-of-box experience: **choose a language**, then **choose a region**, then a
client update that fails, then a restart, then a login prompt. The operator:
"it works but just super weird and unintuitive for an install."

The redundancy is real but it is NOT the one it looks like, and the difference
decides the whole design:

* **Region IS a duplicate.** Screen S2 of our own installer
  (``deck-form.sh``'s ``omarchy_prompt_timezone``) asks for an IANA timezone
  and ``phases_impl.py`` writes it with ``installer.set_timezone()``. Steam's
  page then asks the same question -- and answers it the same way: its
  ``SetCurrentTimeZoneID`` calls ``SteamClient.Settings.SetTimeZone``, i.e. it
  sets the *system* timezone we have already set. **There is nothing to seed
  for the timezone. The system value is already correct; the question just
  needs not to be asked.**

* **Language is NOT a duplicate.** Our installer never asks for one.
  ``iso/upstream/.../root/configurator`` hard-codes ``"sys_lang":
  "en_US.UTF-8"`` (lines 780 and 1166 -- READ). The only user-supplied
  linguistic answer anywhere in the install is ``locale_config.kb_layout``,
  which is a **console keymap**, not a language. Any claim that we can simply
  "carry the language over" is false, and this module does not make it.

WHY THE ONE LEVER IS ALL-OR-NOTHING
===================================

Measured by reading the shipped client (Steam ``steamui/chunk~2dcc5aaf7.js``,
the copy in ``~/.local/share/Steam`` on the dev machine, 2026-08-16):

* OOBE stage 1's page list is ``Stage1 -> Language -> Timezone -> [Network] ->
  Update``. Both the Language page (``Sd``) and the Timezone page (``Ud``)
  render with a literal ``skipPage: !1``. **Neither page can be skipped by
  having the answer already.** They are unconditional.
* The only gate is stage completion:
  ``GetOOBEStage1Complete() = GetClientSetting("oobe_completed") &&
  !IsDeckFactoryImage()``, and ``GetRouteForNextOOBEStep`` sends a client with
  stage 1 complete past the whole of stage 1.

So removing the duplicated *region* question requires answering the *language*
question on the user's behalf. That is the trade this module makes, and it only
makes it when it can defend the answer -- see the confidence rule below.

WHAT IS SEEDED, AND THE EVIDENCE FOR EVERY KEY
==============================================

``~/.steam/registry.vdf``, a text KeyValues document. ``steam.sh`` line 693
defines ``STEAMCONFIG="${HOME%/}/.steam"`` and line 582 treats
``$STEAMCONFIG/registry.vdf`` as *the* registry; a real one written by the
shipped client was read on the dev machine and is reproduced in the suite.

``HKCU\\Software\\Valve\\Steam\\CompletedOOBEStage1`` = ``"1"``
    The backing store for the ``oobe_completed`` client setting. Two
    independent measurements: (i) the string ``CompletedOOBEStage1`` is in
    ``steamui.so`` among the other ``HKCU\\Software\\Valve\\Steam`` key names;
    (ii) the dev machine's real ``registry.vdf`` carries it set to ``"1"``,
    which is what ``OnCMLogon() -> SetOOBEComplete() -> set
    oobe_completed(true)`` writes on a first successful login. The settings
    schema in ``steamui.so`` gives ``oobe_completed`` no config-file path of
    its own (unlike its neighbours, which name theirs inline), i.e. it is a
    ``k_EClientSettingStore_CustomFunc`` setting -- and the custom function's
    key is the one in the file.

``HKCU\\Software\\Valve\\Steam\\language`` = e.g. ``"english"``
``HKCU\\Software\\Valve\\Steamsteamglobal\\language`` = the same
    The dev machine's real registry carries both, with the same value. The
    second is realm-scoped: ``steamglobal`` is the public Steam realm
    (``&realm=steamglobal`` in ``steamclient.so``), and the subkey name is
    ``"Steam" + realm``. Writing both mirrors exactly what a running client
    produces; if the client only consults one, the other is inert.

The 31 legal short names are not invented either: they are the keys of the
OOBE welcome-text table in the shipped ``steamui/2561.js``
(``english``, ``latam``, ``koreana``, ``schinese``...). ``STEAM_LANGUAGES``
below is that list, and a derived value that is not in it is never written.

WHAT IS **NOT** SEEDED, AND WHY
===============================

* **Timezone.** See above: ``installer.set_timezone()`` already did it, and
  Steam's page writes the system value rather than a Steam-side one. A "Steam
  region" key does not exist to be written; ``config/config.vdf`` on a
  logged-in client has no country/region field at all (grepped, 2026-08-16).
* **Stage 2.** ``oobe_stage_2_completed``'s registry key could not be
  established -- ``steamui.so`` holds a bare ``CompletedOOBE`` next to
  ``CompletedOOBEStage1``, which is *probably* the legacy single-OOBE key
  reused for stage 2, but "probably" is not a measurement and this module does
  not write key names it cannot name evidence for. It does not need to: every
  stage-2 page is conditional (``skipPage: !n`` on Underscan, ``!n ||
  s.length<2`` on AudioDevice, ``c`` on HardwareUpdater, ``pair_type == ZP`` on
  PairSteamController), so on a Deck with an internal panel, one audio device
  and no dongle the stage self-completes without drawing anything. That is
  consistent with what the operator saw: nothing between the update failure and
  the login prompt.
* **The login prompt.** It is not part of the OOBE and cannot be seeded away.
  ``BHasOOBEModeRouteBlock`` *blocks* the login route until OOBE is complete;
  completing OOBE unblocks it. A Steam account cannot be logged into from
  local config, and this module does not pretend otherwise.

THE CONFIDENCE RULE (the "a keymap is not a language" trap)
===========================================================

The derivation is keymap -> BCP 47 language tags -> Steam short name, and the
middle step is **read off the target**, not invented:
``/usr/share/systemd/kbd-model-map`` (shipped by ``systemd``, present on the
target) documents its own sixth column as "a comma-separated list of RFC 4646 /
BCP 47 language tags the row matches". ``la-latin1`` is ``es-419,es-MX,...``;
``jp106`` is ``ja-JP,ja``; ``us`` is ``en-US,en``.

Only the last hop -- language tag to Steam's own spelling -- is a table in this
file, and it is small, total and checkable (``BCP47_TO_STEAM``).

**A row whose tags do not all resolve to one Steam language yields nothing.**
``be-latin1`` is ``fr-BE,nl-BE`` (French or Dutch -- a coin flip); ``ie`` is
``en-IE,ga-IE,ga`` (Irish is not a Steam language). Both are ambiguous, both
seed nothing, and both therefore get **today's behaviour: the wizard appears**.
The same is true of a keymap with no row at all (``colemak``, ``neo``) and of
one whose row has no tags and whose X layout has none either.

🔴 **No confident language means no OOBE seed either.** Marking the wizard done
while silently imposing English on a user we know nothing about would remove
their only chance to choose. The two writes stand or fall together.

DEGRADATION, WHICH IS THE POINT
===============================

``critical=False``. Every failure path in here ends with the registry file
either untouched or absent, which is precisely the state the first hardware
boot was in -- the wizard appears and the install is otherwise unharmed. An
existing ``registry.vdf`` that does not parse is **reported and left alone**,
never rewritten: a client that already has state is worth more than a skipped
wizard. Existing values are never overwritten, only absent ones filled in.

⚠️ **UNVERIFIED ON HARDWARE.** P34 has no Deck access (sshd is gone after the
reinstall). Everything above is read off the shipped Steam client and off real
config files; nothing here has been observed suppressing the wizard on a Deck.
The one command that settles it, on the installed machine:

    jq .steam_seed /var/log/omarchy-deck-install.json &&
      grep -E '"(CompletedOOBEStage1|language)"' ~/.steam/registry.vdf

⚠️ **File ownership within ``~/.steam`` is shared with P34's Steam pre-warm
step** (``deck_steam_prewarm.py``). This module writes exactly one path,
``<home>/.steam/registry.vdf`` (plus the ``/etc/skel`` copy of it), and creates
``<home>/.steam`` if absent. It touches nothing under ``~/.local/share/Steam``.
"""

from __future__ import annotations

import os
from pathlib import Path

from .deck_configure import record_result, sanitize_text
from .deck_user import DeckUserDeferred, DeckUserError, resolve_target_user
from .ui import error, info

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

# Home-relative. `steam.sh`:693 -- STEAMCONFIG="${HOME%/}/.steam"; :582 treats
# "$STEAMCONFIG/registry.vdf" as the registry. `bin_steam.sh`:165 only creates
# ~/.steam when it is missing and never removes anything inside it, so a file
# placed here before Steam's first run survives the bootstrap.
REGISTRY_REL = ".steam/registry.vdf"

# The deferred-provisioning surface. `omarchy-provision-owner` creates the
# account at first boot and useradd copies /etc/skel then. Written on every
# install, not only deferred ones, for `deck_monitors.py`'s reason: it is the
# cheap surface and it needs no account.
SKEL_REGISTRY_REL = f"etc/skel/{REGISTRY_REL}"

# systemd's console-keymap table, and the only non-invented keymap -> language
# mapping available. Read from the TARGET first: it is the system the seed is
# for, and the ISO's systemd may not be the installed one.
KBD_MODEL_MAP_REL = "usr/share/systemd/kbd-model-map"
LIVE_ROOT = Path("/")

REGISTRY_MODE = 0o644
DOT_STEAM_MODE = 0o755

# A registry.vdf a Steam has been living in for years is a few tens of KiB.
# The cap is here because this is a root process reading a file into memory.
MAX_REGISTRY_BYTES = 4 * 1024 * 1024
MAX_MODEL_MAP_BYTES = 4 * 1024 * 1024

# ---------------------------------------------------------------------------
# The keys
# ---------------------------------------------------------------------------

REGISTRY_ROOT_KEY = "Registry"
HKCU_PATH = ("HKCU", "Software", "Valve")
STEAM_KEY = "Steam"
# "Steam" + the public realm name. `steamclient.so` carries "&realm=steamglobal";
# the dev machine's real registry.vdf carries a sibling "Steamsteamglobal" node
# whose only child is `language`, with the same value as Steam's.
STEAM_REALM_KEY = "Steamsteamglobal"

OOBE_STAGE1_KEY = "CompletedOOBEStage1"
OOBE_STAGE1_VALUE = "1"
LANGUAGE_KEY = "language"

# The keys of the OOBE welcome-text table in the shipped steamui/2561.js. Not a
# remembered list: extracted from the client, 2026-08-16. A derived language
# outside this set is a bug in the table below, and is never written.
STEAM_LANGUAGES = frozenset(
    {
        "arabic",
        "brazilian",
        "bulgarian",
        "czech",
        "danish",
        "dutch",
        "english",
        "finnish",
        "french",
        "german",
        "greek",
        "hungarian",
        "indonesian",
        "italian",
        "japanese",
        "koreana",
        "latam",
        "malay",
        "norwegian",
        "polish",
        "portuguese",
        "romanian",
        "russian",
        "schinese",
        "spanish",
        "swedish",
        "tchinese",
        "thai",
        "turkish",
        "ukrainian",
        "vietnamese",
    }
)

# BCP 47 primary subtag -> Steam short name, for the tags that appear in
# kbd-model-map. Deliberately partial: a subtag that is not here (he, hr, sl,
# sr, sk, lt, lv, et, is, mk, be, kk, ka, km, tg, ga, fa, ...) has no Steam
# language, and the correct answer for it is to seed nothing.
#
# nb/nn/no all collapse to `norwegian` -- Steam ships one Norwegian, and the
# `no` keymap's tags are `nb-NO,nn-NO,no`, which would otherwise read as three
# disagreeing answers.
BCP47_TO_STEAM = {
    "ar": "arabic",
    "bg": "bulgarian",
    "cs": "czech",
    "da": "danish",
    "de": "german",
    "el": "greek",
    "en": "english",
    "fi": "finnish",
    "fr": "french",
    "hu": "hungarian",
    "id": "indonesian",
    "it": "italian",
    "ja": "japanese",
    "ko": "koreana",
    "ms": "malay",
    "nb": "norwegian",
    "nl": "dutch",
    "nn": "norwegian",
    "no": "norwegian",
    "pl": "polish",
    "ro": "romanian",
    "ru": "russian",
    "sv": "swedish",
    "th": "thai",
    "tr": "turkish",
    "uk": "ukrainian",
    "vi": "vietnamese",
}

# Three languages where Steam splits by region and the tag carries the split.
# `la-latin1` is es-419/es-MX/... (latam); `es` is es-ES (spain). `br-abnt2` is
# pt-BR; `pt-latin1` is pt-PT. Chinese has no console keymap in kbd-model-map,
# but the rule is written down rather than left to a future guess.
SPANISH_SPAIN_REGIONS = frozenset({"ES"})
PORTUGUESE_BRAZIL_REGIONS = frozenset({"BR"})
CHINESE_TRADITIONAL_REGIONS = frozenset({"TW", "HK", "MO", "HANT"})


class DeckSteamSeedError(Exception):
    """The Steam seed could not be established or written."""


# ---------------------------------------------------------------------------
# VDF (Valve KeyValues) -- text form only
#
# 🔴 VDF is not JSON and this parser does not pretend otherwise. Two rules make
# it safe to round-trip a file we did not write:
#
#   1. **String contents are kept RAW.** `\\`, `\"` and friends are never
#      decoded, so they are never re-encoded either, and an existing document
#      comes back byte-identical whether or not Steam's own reader processes
#      escapes (the two interpretations disagree about `\s`, and a decode/encode
#      pair would have to pick one). Values this module *inserts* are checked to
#      contain no quote or backslash at all, so nothing needs escaping.
#   2. **Anything unexpected raises.** Unquoted tokens, conditionals, a stray
#      brace -- all refusals, not best-effort repairs, because the fallback
#      (leave the file alone) is a correct outcome and a mangled registry is not.
#
# Pairs are a LIST, not a dict: KeyValues permits duplicate keys, and a dict
# would silently drop one on the way out.
# ---------------------------------------------------------------------------


def _tokenize(text: str):
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch in " \t\r\n":
            i += 1
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            nl = text.find("\n", i)
            i = n if nl < 0 else nl + 1
            continue
        if ch in "{}":
            yield ch, None
            i += 1
            continue
        if ch != '"':
            raise DeckSteamSeedError(
                f"unquoted token starting with {ch!r} at offset {i}; this is not the "
                "shape Steam writes and the file will not be modified"
            )
        j = i + 1
        parts: list[str] = []
        while True:
            if j >= n:
                raise DeckSteamSeedError("unterminated quoted string")
            c = text[j]
            if c == "\\":
                if j + 1 >= n:
                    raise DeckSteamSeedError("trailing backslash inside a quoted string")
                parts.append(text[j : j + 2])
                j += 2
                continue
            if c == '"':
                break
            if c == "\n":
                raise DeckSteamSeedError("newline inside a quoted string")
            parts.append(c)
            j += 1
        yield "str", "".join(parts)
        i = j + 1


def parse_vdf(text: str) -> list:
    """Text KeyValues -> ``[(key, str | list), ...]``. Raises on anything odd."""
    toks = list(_tokenize(text))
    pos = 0

    def pairs(depth: int) -> list:
        nonlocal pos
        out: list = []
        while pos < len(toks):
            kind, value = toks[pos]
            if kind == "}":
                if depth == 0:
                    raise DeckSteamSeedError("a '}' with no matching '{'")
                return out
            if kind != "str":
                raise DeckSteamSeedError("expected a key, found '{'")
            key = value
            pos += 1
            if pos >= len(toks):
                raise DeckSteamSeedError(f"key {key!r} has no value")
            kind2, value2 = toks[pos]
            if kind2 == "str":
                out.append((key, value2))
                pos += 1
            elif kind2 == "{":
                pos += 1
                child = pairs(depth + 1)
                if pos >= len(toks) or toks[pos][0] != "}":
                    raise DeckSteamSeedError(f"subkey {key!r} is never closed")
                pos += 1
                out.append((key, child))
            else:
                raise DeckSteamSeedError(f"key {key!r} is followed by '}}'")
        if depth != 0:
            raise DeckSteamSeedError("end of file inside a subkey")
        return out

    doc = pairs(0)
    if pos != len(toks):
        raise DeckSteamSeedError("trailing '}' after the document")
    return doc


def render_vdf(doc: list) -> str:
    """``[(key, str | list), ...]`` -> text, in the shape Steam itself writes:
    tab indentation, two tabs between a key and its value, one trailing
    newline per line."""
    out: list[str] = []

    def emit(pairs: list, depth: int) -> None:
        pad = "\t" * depth
        for key, value in pairs:
            if isinstance(value, list):
                out.append(f'{pad}"{key}"\n{pad}{{\n')
                emit(value, depth + 1)
                out.append(f"{pad}}}\n")
            else:
                out.append(f'{pad}"{key}"\t\t"{value}"\n')

    emit(doc, 0)
    return "".join(out)


def _find_child(pairs: list, key: str):
    """KeyValues key lookup is case-insensitive; so is this."""
    lowered = key.lower()
    for index, (name, value) in enumerate(pairs):
        if name.lower() == lowered:
            return index, value
    return None, None


def ensure_subkey(pairs: list, key: str) -> list:
    index, value = _find_child(pairs, key)
    if index is None:
        child: list = []
        pairs.append((key, child))
        return child
    if not isinstance(value, list):
        raise DeckSteamSeedError(
            f"{key!r} already exists as a value, not a subkey; refusing to restructure "
            "someone else's registry"
        )
    return value


def set_if_absent(pairs: list, key: str, value: str) -> bool:
    """Fill in a leaf only when it is missing or empty. Returns whether it wrote.

    Never an overwrite: an existing value is a decision Steam or the user
    already made, and this step's whole justification is that it is answering a
    question nobody has answered yet.
    """
    if '"' in value or "\\" in value:
        raise DeckSteamSeedError(f"refusing to write {key!r}: the value needs escaping")
    index, existing = _find_child(pairs, key)
    if index is not None:
        if isinstance(existing, list):
            raise DeckSteamSeedError(f"{key!r} already exists as a subkey")
        if existing != "":
            return False
        pairs[index] = (pairs[index][0], value)
        return True
    pairs.append((key, value))
    return True


def read_leaf(doc: list, path: tuple[str, ...], key: str) -> str | None:
    pairs: list | None = doc
    for step in path:
        if pairs is None:
            return None
        _, child = _find_child(pairs, step)
        pairs = child if isinstance(child, list) else None
    if pairs is None:
        return None
    _, value = _find_child(pairs, key)
    return value if isinstance(value, str) else None


# ---------------------------------------------------------------------------
# keymap -> Steam language
# ---------------------------------------------------------------------------


def parse_kbd_model_map(text: str) -> list[tuple[str, str, list[str]]]:
    """``[(console keymap, x layout, [bcp47 tags]), ...]``.

    The file's own header documents the columns; the sixth is the tag list, and
    ``-`` (or a short row) means "no tags apply". Malformed rows are skipped
    rather than raising, for ``deck_user.parse_passwd``'s reason: one bad line
    in a file we did not write must not cost us the rest of it.
    """
    rows: list[tuple[str, str, list[str]]] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) < 2:
            continue
        keymap, xlayout = fields[0], fields[1]
        tags: list[str] = []
        if len(fields) >= 6 and fields[5] != "-":
            tags = [t for t in fields[5].split(",") if t and t != "-"]
        rows.append((keymap, xlayout, tags))
    return rows


def _steam_language_for_tag(tag: str) -> str | None:
    """One BCP 47 tag -> a Steam short name, or None.

    Region matters for exactly the three languages Steam splits, and the split
    is taken from the tag rather than assumed.
    """
    parts = [p for p in tag.replace("_", "-").split("-") if p]
    if not parts:
        return None
    primary = parts[0].lower()
    subtags = {p.upper() for p in parts[1:]}

    if primary == "es":
        return "spanish" if not subtags or subtags & SPANISH_SPAIN_REGIONS else "latam"
    if primary == "pt":
        return "brazilian" if subtags & PORTUGUESE_BRAZIL_REGIONS else "portuguese"
    if primary == "zh":
        return "tchinese" if subtags & CHINESE_TRADITIONAL_REGIONS else "schinese"
    return BCP47_TO_STEAM.get(primary)


def steam_language_for_keymap(keymap: str, rows) -> tuple[str | None, str]:
    """``(steam language | None, reason)`` for a console keymap.

    Two lookups, in order:

    1. the keymap's own row's tags;
    2. failing that, the tags of every row sharing its X layout -- ``de-latin1``
       has no tags of its own but its layout ``de`` does, via the plain ``de``
       row. Same X layout means the same language; this is the only inference
       in the chain and it is a small one.

    A tag set is only accepted when **every** tag resolves and they all resolve
    to the **same** Steam language. ``be-latin1`` (fr-BE, nl-BE) and ``ie``
    (en-IE, ga-IE, ga) are therefore refusals, by design.
    """
    if not keymap:
        return None, "the install names no keyboard layout"

    wanted = keymap.lower()
    own = [row for row in rows if row[0].lower() == wanted]
    if not own:
        return None, f"'{sanitize_text(keymap)}' has no row in {KBD_MODEL_MAP_REL}"

    xlayout = own[0][1]
    tags = [t for row in own for t in row[2]]
    source = "its own row"
    if not tags:
        tags = [t for row in rows if row[1] == xlayout for t in row[2]]
        source = f"the '{xlayout}' X layout it shares"
    if not tags:
        return None, (
            f"neither '{sanitize_text(keymap)}' nor the '{sanitize_text(xlayout)}' X layout "
            f"carries a BCP 47 tag in {KBD_MODEL_MAP_REL}"
        )

    resolved = [_steam_language_for_tag(t) for t in tags]
    if any(r is None for r in resolved):
        unknown = sorted({t for t, r in zip(tags, resolved) if r is None})
        return None, (
            f"'{sanitize_text(keymap)}' maps to {','.join(tags)} via {source}, and "
            f"{','.join(unknown)} is not a language Steam ships -- ambiguous, so nothing "
            "is seeded and Steam asks"
        )
    distinct = sorted(set(resolved))
    if len(distinct) != 1:
        return None, (
            f"'{sanitize_text(keymap)}' maps to {','.join(tags)} via {source}, which is "
            f"{' or '.join(distinct)} -- ambiguous, so nothing is seeded and Steam asks"
        )

    language = distinct[0]
    if language not in STEAM_LANGUAGES:
        # Unreachable unless BCP47_TO_STEAM drifts from the client's own list.
        # Loud rather than silent: a language Steam does not know would be
        # written into its registry and quietly ignored.
        return None, (
            f"'{sanitize_text(language)}' is not one of the {len(STEAM_LANGUAGES)} short names "
            "the shipped Steam client offers"
        )
    return language, f"'{sanitize_text(keymap)}' -> {','.join(tags)} via {source} -> {language}"


def read_model_map(target, live_root=LIVE_ROOT) -> tuple[list, str]:
    """The target's copy, else the live ISO's. Returns ``(rows, where)``."""
    candidates = [
        (Path(target) / KBD_MODEL_MAP_REL, f"target:/{KBD_MODEL_MAP_REL}"),
        (Path(live_root) / KBD_MODEL_MAP_REL, f"live:/{KBD_MODEL_MAP_REL}"),
    ]
    for path, where in candidates:
        try:
            data = path.read_bytes()
        except OSError:
            continue
        if len(data) > MAX_MODEL_MAP_BYTES:
            raise DeckSteamSeedError(f"{path} is {len(data)} bytes; refusing to parse it")
        rows = parse_kbd_model_map(data.decode("utf-8", "replace"))
        if rows:
            return rows, where
    raise DeckSteamSeedError(
        f"/{KBD_MODEL_MAP_REL} is missing or empty on both the target and the live ISO, "
        "so a keyboard layout cannot be turned into a language"
    )


def keymap_from_ctx(ctx) -> str:
    """The user's pick, from where the configurator actually puts it.

    ``iso/upstream/.../root/configurator``:833 writes
    ``"locale_config": {"kb_layout": "$keyboard", ...}`` and
    ``InstallContext.user_configuration`` is that document verbatim.
    ``deck-form.sh`` deliberately leaves this value alone ("the user's pick
    still reaches archinstall, byte for byte") and overrides only the LIVE
    console keymap, so this is the preference and not the mechanism.
    """
    config = getattr(ctx, "user_configuration", None)
    if not isinstance(config, dict):
        return ""
    locale = config.get("locale_config")
    if not isinstance(locale, dict):
        return ""
    value = locale.get("kb_layout")
    return value.strip() if isinstance(value, str) else ""


# ---------------------------------------------------------------------------
# The write
# ---------------------------------------------------------------------------


def build_registry(existing: list | None, language: str) -> tuple[list, list[str]]:
    """Merge the seed into ``existing`` (or a fresh document). Returns
    ``(doc, keys actually written)``."""
    doc = existing if existing is not None else []
    root = ensure_subkey(doc, REGISTRY_ROOT_KEY)
    node = root
    for step in HKCU_PATH:
        node = ensure_subkey(node, step)

    written: list[str] = []
    steam = ensure_subkey(node, STEAM_KEY)
    if set_if_absent(steam, LANGUAGE_KEY, language):
        written.append(f"{STEAM_KEY}/{LANGUAGE_KEY}")
    if set_if_absent(steam, OOBE_STAGE1_KEY, OOBE_STAGE1_VALUE):
        written.append(f"{STEAM_KEY}/{OOBE_STAGE1_KEY}")

    realm = ensure_subkey(node, STEAM_REALM_KEY)
    if set_if_absent(realm, LANGUAGE_KEY, language):
        written.append(f"{STEAM_REALM_KEY}/{LANGUAGE_KEY}")

    return doc, written


def install(target, rel: str, language: str, owner=None) -> dict:
    """Write one ``registry.vdf``. Returns facts for the record.

    Staged next to the file and moved with ``os.replace`` so a reader -- Steam,
    on a machine where this somehow races a first launch -- never sees a
    half-written registry.
    """
    path = Path(target) / rel
    warnings: list[str] = []

    if path.is_symlink():
        # Writing through would put the seed somewhere that is not this user's
        # registry. Refused rather than replaced: the fallback is the wizard.
        raise DeckSteamSeedError(
            f"/{rel} is a symlink; refusing to write through it. Steam will ask its "
            "first-run questions, which is the behaviour without this step"
        )

    existing = None
    if path.exists():
        if not path.is_file():
            raise DeckSteamSeedError(f"/{rel} exists and is not a regular file")
        data = path.read_bytes()
        if len(data) > MAX_REGISTRY_BYTES:
            raise DeckSteamSeedError(f"/{rel} is {len(data)} bytes; refusing to parse it")
        existing = parse_vdf(data.decode("utf-8", "replace"))

    doc, written = build_registry(existing, language)
    text = render_vdf(doc)

    created: list[Path] = []
    parent = path.parent
    while not parent.exists():
        created.append(parent)
        parent = parent.parent
    path.parent.mkdir(parents=True, exist_ok=True)
    for directory in created:
        os.chmod(directory, DOT_STEAM_MODE)

    tmp = path.with_name(f".{path.name}.deck-tmp")
    try:
        tmp.write_text(text)
        os.chmod(tmp, REGISTRY_MODE)
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            tmp.unlink(missing_ok=True)

    if owner is not None:
        # A root-owned ~/.steam is a directory Steam's own bootstrap cannot
        # write into, which would be a worse outcome than the wizard.
        for directory in created:
            _chown(directory, owner)
        _chown(path, owner)

    return {"path": "/" + rel, "written": written, "warnings": warnings}


def _chown(path: Path, owner) -> None:
    try:
        os.chown(path, owner.uid, owner.gid)
    except OSError as exc:
        raise DeckSteamSeedError(f"could not chown {path} to uid {owner.uid}: {exc}") from exc


def verify(path: Path, label: str) -> str:
    """Read the file back through the same parser and require the invariant.

    The readback exists because every other check in this module inspects what
    it is about to write. This one inspects what is on the disk.

    🔴 The invariant is **"the wizard is marked done AND a language is set"**,
    NOT "the language is the one we derived". Those differ, and the difference
    is the whole of ``set_if_absent``: a registry that already carried
    ``language`` keeps it, and demanding our own value back would turn correct
    restraint into a reported failure. Returns whichever language is on the
    disk, so the install record can say what Steam will actually use.
    """
    try:
        doc = parse_vdf(path.read_text(encoding="utf-8", errors="replace"))
    except OSError as exc:
        raise DeckSteamSeedError(f"{label} could not be read back: {exc}") from exc

    steam_path = (REGISTRY_ROOT_KEY, *HKCU_PATH, STEAM_KEY)
    got_lang = read_leaf(doc, steam_path, LANGUAGE_KEY)
    got_oobe = read_leaf(doc, steam_path, OOBE_STAGE1_KEY)
    if got_oobe != OOBE_STAGE1_VALUE:
        raise DeckSteamSeedError(
            f"{label} reads back {OOBE_STAGE1_KEY}={got_oobe!r}, not {OOBE_STAGE1_VALUE!r}"
        )
    if not got_lang:
        # Skipping the wizard with no language at all is the outcome this
        # module exists to avoid: Steam would fall back to English with the
        # question already marked answered.
        raise DeckSteamSeedError(
            f"{label} reads back {OOBE_STAGE1_KEY}={OOBE_STAGE1_VALUE} but no {LANGUAGE_KEY}"
        )
    return got_lang


# ---------------------------------------------------------------------------
# The step
# ---------------------------------------------------------------------------


def seed_steam(ctx, live_root=LIVE_ROOT) -> dict:
    """Do the work; return the install record. Never raises."""
    target = Path(ctx.target)
    record: dict = {
        "status": None,
        "keymap": None,
        "language": None,
        # What Steam will actually use, read back off the disk. Differs from
        # `language` exactly when the registry already carried one.
        "language_on_disk": None,
        "mapping": None,
        "model_map": None,
        "oobe_key": f"{OOBE_STAGE1_KEY}={OOBE_STAGE1_VALUE}",
        "skel": None,
        "user": None,
        "user_path": None,
        "written": None,
        "error": None,
        "warnings": [],
    }
    warnings: list[str] = record["warnings"]

    # 1. The answer we already have. No answer -> no seed, and say why.
    keymap = keymap_from_ctx(ctx)
    record["keymap"] = sanitize_text(keymap) if keymap else None
    try:
        rows, where = read_model_map(target, live_root)
        record["model_map"] = where
        language, reason = steam_language_for_keymap(keymap, rows)
    except (DeckSteamSeedError, OSError) as exc:
        record["status"] = "failed"
        record["error"] = sanitize_text(f"{type(exc).__name__}: {exc}", limit=400)
        error(f"Deck Steam seed: {record['error']}")
        return record

    record["mapping"] = sanitize_text(reason, limit=400)
    if language is None:
        # 🔴 The designed degradation, not a failure: Steam asks its questions,
        # exactly as it does today, and nothing on the machine is touched.
        record["status"] = "skipped"
        info(f"Deck Steam seed: not seeding -- {reason}")
        return record
    record["language"] = language

    # 2. Who owns the home. Deferred provisioning has no account yet.
    owner = None
    deferred = False
    try:
        user, user_warnings = resolve_target_user(ctx)
        owner = user
        warnings.extend(user_warnings)
        record["user"] = sanitize_text(user.name)
    except DeckUserDeferred as exc:
        deferred = True
        warnings.append(f"{exc}; writing /etc/skel only, which is what a later useradd copies")
    except DeckUserError as exc:
        record["status"] = "failed"
        record["error"] = sanitize_text(f"{type(exc).__name__}: {exc}", limit=400)
        error(f"Deck Steam seed: {record['error']}")
        _report(warnings)
        return record

    # 3. Write. Skel first: cheapest, needs no account.
    written: list[str] = []
    try:
        facts = install(target, SKEL_REGISTRY_REL, language)
        warnings.extend(facts["warnings"])
        record["skel"] = facts["path"]
        written.extend(f"skel:{k}" for k in facts["written"])
        on_disk = verify(target / SKEL_REGISTRY_REL, f"/{SKEL_REGISTRY_REL}")

        if not deferred:
            user_rel = owner.home.lstrip("/") + "/" + REGISTRY_REL
            facts = install(target, user_rel, language, owner=owner)
            warnings.extend(facts["warnings"])
            record["user_path"] = facts["path"]
            written.extend(f"user:{k}" for k in facts["written"])
            on_disk = verify(target / user_rel, f"{owner.name}'s /{user_rel}")
        record["language_on_disk"] = sanitize_text(on_disk)
        if on_disk != language:
            warnings.append(
                f"the registry already carried {LANGUAGE_KEY}={sanitize_text(on_disk)}; it was kept "
                f"rather than replaced with the derived {language}"
            )
    except (DeckSteamSeedError, OSError) as exc:
        record["status"] = "failed"
        record["written"] = written
        record["error"] = sanitize_text(f"{type(exc).__name__}: {exc}", limit=400)
        error(f"Deck Steam seed: {record['error']}")
        _report(warnings)
        return record

    record["written"] = written
    record["status"] = "skel-only" if deferred else "seeded"
    where_written = record["user_path"] or record["skel"]
    info(
        f"Deck Steam seed: {LANGUAGE_KEY}={record['language_on_disk']} and {OOBE_STAGE1_KEY}=1 in "
        f"{where_written}"
        + ("" if deferred else " (and /etc/skel)")
        + f" -- {record['mapping']}. This skips OOBE stage 1 (language, region, network, "
        "update); it does NOT skip the Steam login, which is not part of the OOBE"
    )
    _report(warnings)
    return record


def _report(warnings: list[str]) -> None:
    for warning in warnings:
        error(f"Deck Steam seed: {warning}")


def steam_seed_step(ctx) -> None:
    """``DeckStep`` entry point. Records under ``steam_seed``.

    No re-raise: ``critical=False``, and the record is the report. A failure
    here leaves Steam exactly as the first hardware boot found it.
    """
    record_result(ctx.target, "steam_seed", seed_steam(ctx))

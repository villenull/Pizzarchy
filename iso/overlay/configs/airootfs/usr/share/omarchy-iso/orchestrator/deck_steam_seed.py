"""P34, corrected in P33. Answer Steam's first-run wizard from what the
installer already knows.

SHIPPED AS ``/usr/share/omarchy-iso/orchestrator/deck_steam_seed.py``, a module
inside the upstream orchestrator package, hence the relative imports.
``test/unit/test-deck-steam-seed.py`` builds the package shape around it.

🔴 THE DEFECT THIS FILE SHIPPED, AND THE CORRECTION
===================================================

The first version derived Steam's language from the **console keymap**. This
docstring named the trap in advance -- *"a keymap is not a language"* -- and the
module walked into it anyway, because a keymap was the only linguistic answer it
could see.

Measured on hardware, 2026-08-16. The operator picked **English** as the system
language and a **Spanish (Latin American) keyboard** -- an entirely ordinary
combination. The seed read the keyboard, so Steam came up in Spanish:

    "we successfully skipped the Steam language and region input which is
    great. BUT Steam chose Spanish as my language even though I had selected
    English as my language in the Omarchy setup. I believe this is because I
    chose English as language but Spanish LatAm as my keyboard."

They are right. The keymap -> BCP 47 -> Steam-language chain is **deleted**,
including the ``/usr/share/systemd/kbd-model-map`` reading it rested on and the
hand-written tag table at its far end. Nothing in this module reads a keymap.

The language now comes from the **system locale**, which is the only value in
the install that claims to be a language at all. What survives from the old
design is its *shape*, which was the good part: an input this module cannot
resolve with confidence seeds **nothing**, including the OOBE flag, so the user
keeps their choice.

WHAT WAS OBSERVED IN THE FIRST PLACE
====================================

On the first hardware boot the user is walked through Steam's own out-of-box
experience: **choose a language**, then **choose a region**, then a client
update that fails, then a restart, then a login prompt. The operator: "it works
but just super weird and unintuitive for an install."

* **Region IS a duplicate.** Screen S2 of our own installer
  (``deck-form.sh``'s ``omarchy_prompt_timezone``) asks for an IANA timezone
  and ``phases_impl.py`` writes it with ``installer.set_timezone()``. Steam's
  page then asks the same question -- and answers it the same way: its
  ``SetCurrentTimeZoneID`` calls ``SteamClient.Settings.SetTimeZone``, i.e. it
  sets the *system* timezone we have already set. **There is nothing to seed
  for the timezone. The system value is already correct; the question just
  needs not to be asked.**

* **Language is answerable after all**, just not from the keyboard. It travels
  the same route the keymap did: ``iso/upstream/.../root/configurator``:832-836
  and :1221-1225 write ``"locale_config": {"kb_layout": ..., "sys_enc":
  "UTF-8", "sys_lang": "en_US.UTF-8"}``, ``InstallContext.from_env`` parses that
  document verbatim into ``ctx.user_configuration`` (``context.py``:50, :112),
  and archinstall turns ``sys_lang`` into the target's ``/etc/locale.conf``.
  ``sys_lang`` is the system's language; ``kb_layout`` never was.

  Today ``sys_lang`` is a **constant**, so in practice this module now seeds
  ``english`` on every standard install -- which is both what the system is and
  what the operator expected. It is not written as a constant because the value
  is not one: the configurator is upstream's file, an autoinstall config
  (``OMARCHY_INSTALL_CONFIG``) is a user-supplied document, and a locale this
  module cannot resolve has to degrade rather than guess.

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

Nor is the **mapping** to them invented. ``LANGUAGE_CODE_TO_STEAM`` below is a
verbatim transcription of the ``Map`` in the shipped ``steamui/library.js``
(webpack module ``51579``), which is the client's own language-code table --
``["en","english"], ["es-419","latam"], ["pt-br","brazilian"],
["zh-tw","tchinese"], ["nb","norwegian"]`` and so on. The same file pairs the
same short names against the same codes a second time, in the ``Qt``/``Jt``
enum switches; the two agree. Read 2026-08-16 off ``~/.local/share/Steam`` on
the dev machine.

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

THE DERIVATION, AND THE CONFIDENCE RULE IT KEEPS
================================================

``en_US.UTF-8`` -> language ``en``, territory ``US`` -> the client's own table
-> ``english``. Three lookups, in order, and none of them is a guess:

1. the full ``language-territory`` code, lowercased (``pt_BR`` -> ``pt-br`` ->
   ``brazilian``; ``zh_TW`` -> ``zh-tw`` -> ``tchinese``);
2. the two region rules the client's table implies but cannot express, because
   the codes it splits on are CLDR groupings rather than territories --
   **Spanish** (``es-419`` is Latin America, so ``es_MX``/``es_AR``/``es_CO``
   -> ``latam`` while ``es_ES`` -> ``spanish``) and **Chinese** (``zh_HK`` and
   ``zh_MO`` are Traditional, i.e. ``tchinese``);
3. the bare language code (``en`` -> ``english``, ``de_CH`` -> ``de`` ->
   ``german``, ``nl_BE`` -> ``nl`` -> ``dutch``).

🔴 Note what step 3 does to the case that defeated the keymap version:
``be-latin1`` was ``fr-BE,nl-BE`` and unanswerable, but ``nl_BE.UTF-8`` is
Dutch and answerable. A locale carries the answer the keyboard never did.

**A locale the client's own table does not contain yields nothing.** ``he_IL``
(Hebrew), ``sr_RS`` (Serbian), ``ga_IE`` (Irish) and ``nn_NO`` (Nynorsk -- the
client lists ``nb`` and ``no`` but not ``nn``) are all refusals, as are ``C``,
``POSIX`` and ``C.UTF-8``, which are not languages. Every refusal gets
**today's behaviour: the wizard appears** and the user picks.

🔴 **No confident language means no OOBE seed either.** Marking the wizard done
while silently imposing English on a user whose locale we could not read would
remove their only chance to choose. The two writes stand or fall together.

WHY THE LANGUAGE IS WRITTEN AT ALL, RATHER THAN JUST THE FLAG
=============================================================

``CompletedOOBEStage1`` is the only gate, so setting it alone *would* skip the
wizard and Steam would fall back to a default of its own. The client's own
string-to-enum function defaults to ``english`` (``er(e, t=bt)``, ``bt`` = 0 =
``english``, ``steamui/library.js``), so on an ``en_US`` system flag-only would
very probably land on English too. This module writes the language anyway, for
three reasons:

* "very probably" is an inference about somebody else's fallback, and the
  defect above is exactly what inference costs here. The written value is a
  fact under our control and is read back off the disk (``verify``).
* It is the operator's verification surface. ``grep language
  ~/.steam/registry.vdf`` has something to read; a flag-only seed leaves
  nothing to check but the absence of a wizard.
* It generalises. The moment ``sys_lang`` stops being a constant -- an
  autoinstall config, or upstream adding a language question -- flag-only
  silently gives every non-English install an English Steam, which is this
  defect again with a different cause.

DEGRADATION, WHICH IS THE POINT
===============================

``critical=False``. Every failure path in here ends with the registry file
either untouched or absent, which is precisely the state the first hardware
boot was in -- the wizard appears and the install is otherwise unharmed. An
existing ``registry.vdf`` that does not parse is **reported and left alone**,
never rewritten: a client that already has state is worth more than a skipped
wizard. Existing values are never overwritten, only absent ones filled in.

⚠️ **THE LANGUAGE FIX IS UNVERIFIED ON HARDWARE.** The *defect* is verified --
the operator watched Steam come up in Spanish. The correction is read off the
shipped Steam client and off real config files, and has not been observed
producing an English Steam on a Deck. The one command that settles it, on the
installed machine:

    jq .steam_seed /var/log/omarchy-deck-install.json &&
      grep -E '"(CompletedOOBEStage1|language)"' ~/.steam/registry.vdf

``language_on_disk`` in that record is the value Steam will actually use; the
``grep`` is the same fact read straight off the file rather than out of our own
report of it.

⚠️ **ORDERING AGAINST ANY STEP THAT RUNS THE REAL STEAM CLIENT.** This module
must run **before** one, not after. It never overwrites an existing value, so a
client that has already written ``language`` (or, worse, a
``CompletedOOBEStage1`` that is not ``"1"``) wins and the wizard comes back --
loudly, via ``verify``, but it comes back. Run first and the client reads our
seed instead, and carries it forward when it rewrites the file.
``bin_steam.sh``:165 only creates ``~/.steam`` when it is missing and never
removes anything inside it, so the seed survives a bootstrap that runs after it.

⚠️ **File ownership within ``~/.steam`` is shared with the Steam pre-warm /
bootstrap steps.** This module writes exactly one path,
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

# The installed system's language, as archinstall writes it from `sys_lang`.
# Only consulted when the install config does not carry a locale itself; the
# config is the primary source and this is the same value one hop later.
LOCALE_CONF_REL = "etc/locale.conf"

REGISTRY_MODE = 0o644
DOT_STEAM_MODE = 0o755

# A registry.vdf a Steam has been living in for years is a few tens of KiB.
# The cap is here because this is a root process reading a file into memory.
MAX_REGISTRY_BYTES = 4 * 1024 * 1024
MAX_LOCALE_CONF_BYTES = 64 * 1024

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

# 🔴 NOT a hand-written table. This is the `Map` in the shipped
# `steamui/library.js` (webpack module 51579), transcribed key for key, read
# 2026-08-16 off ~/.local/share/Steam on the dev machine. The client uses it to
# turn a language code into its own short name; we use it for exactly that and
# nothing else.
#
# The previous version of this module derived a language from the console
# keymap through a table written here from memory-of-a-standard. That is the
# defect the docstring opens with. A code that is not a key of this map has no
# Steam language as far as the client is concerned, and the correct answer is
# to seed nothing -- `nn` (Nynorsk) is the notable one: the client lists `nb`
# and `no`, not `nn`, and this module does not add it.
LANGUAGE_CODE_TO_STEAM = {
    "en": "english",
    "de": "german",
    "fr": "french",
    "it": "italian",
    "ko": "koreana",
    "es-419": "latam",
    "es": "spanish",
    "zh": "schinese",
    "zh-cn": "schinese",
    "zh-tw": "tchinese",
    "ru": "russian",
    "ar": "arabic",
    "th": "thai",
    "ja": "japanese",
    "pt-br": "brazilian",
    "pt": "portuguese",
    "pl": "polish",
    "da": "danish",
    "nl": "dutch",
    "fi": "finnish",
    "nb": "norwegian",
    "no": "norwegian",
    "sv": "swedish",
    "hu": "hungarian",
    "cs": "czech",
    "ro": "romanian",
    "tr": "turkish",
    "bg": "bulgarian",
    "el": "greek",
    "uk": "ukrainian",
    "vn": "vietnamese",
    "vi": "vietnamese",
    "id": "indonesian",
    "ms": "malay",
}

# The two splits the map above encodes as CLDR groupings rather than as
# territories, so a glibc locale cannot hit them by string match alone.
#
# `es-419` is UN M.49 region 419, "Latin America and the Caribbean". Every
# Spanish locale outside Spain falls in it -- es_MX, es_AR, es_CO, es_CL, es_PE,
# es_VE, es_US... -- so the rule is stated the short way round: Spain is
# `spanish`, the rest is `latam`. 🔴 This is the operator's own case
# (Spanish LatAm) and the reason the split is not left to the bare `es` key.
SPANISH_SPAIN_REGIONS = frozenset({"ES"})

# `zh-tw` is the map's Traditional entry. Hong Kong and Macau write Traditional
# too and have their own locales (zh_HK, zh_MO); zh_CN and zh_SG are Simplified
# and reach `schinese` through the bare `zh` key the client itself provides.
CHINESE_TRADITIONAL_REGIONS = frozenset({"TW", "HK", "MO"})


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
# system locale -> Steam language
#
# 🔴 There is deliberately no keymap in this section, and no reader for
# /usr/share/systemd/kbd-model-map. Both were here, both produced a Spanish
# Steam on an English system, and both are gone. See the docstring.
# ---------------------------------------------------------------------------


def parse_locale(value: str) -> tuple[str, str] | None:
    """``"es_MX.UTF-8@euro"`` -> ``("es", "MX")``. ``None`` if it is not a
    language at all.

    glibc's locale name is ``language[_TERRITORY][.codeset][@modifier]``. The
    codeset and the modifier say nothing about which language Steam should
    render, so both are dropped. ``C``, ``POSIX`` and ``C.UTF-8`` are the
    portable locales rather than languages and are rejected here, not later.
    """
    if not isinstance(value, str):
        return None
    text = value.strip()
    for sep in ("@", "."):
        head, _, _tail = text.partition(sep)
        text = head
    if not text:
        return None
    parts = [p for p in text.replace("-", "_").split("_") if p]
    if not parts:
        return None
    language = parts[0].lower()
    if language in ("c", "posix"):
        return None
    if not language.isalpha() or not 2 <= len(language) <= 3:
        return None
    territory = parts[1].upper() if len(parts) > 1 else ""
    if territory and not territory.isalnum():
        territory = ""
    return language, territory


def steam_language_for_locale(locale: str) -> tuple[str | None, str]:
    """``(steam language | None, reason)`` for a system locale.

    Three lookups, in the order the docstring sets out: the full
    ``language-territory`` code, then the two region splits the client's map
    encodes as CLDR groupings, then the bare language code. A locale that none
    of the three resolves seeds **nothing**, which is the wizard appearing.
    """
    if not locale:
        return None, "the install names no system locale"

    parsed = parse_locale(locale)
    if parsed is None:
        return None, (
            f"'{sanitize_text(locale)}' is not a language locale, so nothing is seeded "
            "and Steam asks"
        )
    language, territory = parsed
    shown = f"{language}_{territory}" if territory else language

    code = f"{language}-{territory.lower()}" if territory else language
    steam = LANGUAGE_CODE_TO_STEAM.get(code)
    how = f"'{code}' in the client's own language map"

    if steam is None and language == "es":
        # es_ES is Spain; every other Spanish territory is UN M.49 region 419.
        steam = "spanish" if territory in SPANISH_SPAIN_REGIONS else "latam"
        how = "the es-419 / es split in the client's own language map"
    if steam is None and language == "zh" and territory in CHINESE_TRADITIONAL_REGIONS:
        steam = "tchinese"
        how = "the zh-tw / zh split in the client's own language map"
    if steam is None:
        steam = LANGUAGE_CODE_TO_STEAM.get(language)
        how = f"'{language}' in the client's own language map"

    if steam is None:
        return None, (
            f"'{sanitize_text(shown)}' is not a language the shipped Steam client offers "
            "-- nothing is seeded and Steam asks"
        )
    if steam not in STEAM_LANGUAGES:
        # Unreachable while the transcription matches the client: every value in
        # LANGUAGE_CODE_TO_STEAM is one of the 31, and the suite proves it
        # against the shipped file. The guard is for the drift -- the client's
        # `IsValidLanguage` set is 32, and the extra one (`sc_schinese`, the
        # Steam China client's) is NOT an OOBE choice. Loud rather than silent:
        # a language the wizard does not offer would be written into the
        # registry and quietly ignored.
        return None, (
            f"'{sanitize_text(steam)}' is not one of the {len(STEAM_LANGUAGES)} short names "
            "the shipped Steam client's first-run wizard offers"
        )
    return steam, f"'{sanitize_text(shown)}' -> {steam}, via {how}"


def locale_from_ctx(ctx) -> str:
    """The system language, from where the configurator actually puts it.

    ``iso/upstream/.../root/configurator``:832-836 writes ``"locale_config":
    {"kb_layout": ..., "sys_enc": "UTF-8", "sys_lang": "en_US.UTF-8"}`` and
    ``InstallContext.user_configuration`` (``context.py``:50, :112) is that
    document verbatim. ``sys_lang`` is what archinstall's
    ``minimal_installation(locale_config=...)`` turns into the target's
    ``/etc/locale.conf``, i.e. it *is* the installed system's language.

    🔴 Its sibling ``kb_layout`` is a console keymap and is NOT read here. That
    substitution is the defect this module shipped.
    """
    config = getattr(ctx, "user_configuration", None)
    if not isinstance(config, dict):
        return ""
    locale = config.get("locale_config")
    if not isinstance(locale, dict):
        return ""
    value = locale.get("sys_lang")
    return value.strip() if isinstance(value, str) else ""


def read_locale_conf(target) -> str:
    """``LANG=`` from the target's ``/etc/locale.conf``, or ``""``.

    The fallback for a config document that carries no ``sys_lang`` of its own
    (an autoinstall JSON, a future upstream shape). Same value one hop later:
    archinstall wrote this file *from* ``sys_lang``. Absent or unreadable is a
    normal answer, not a failure -- the caller degrades to seeding nothing.
    """
    path = Path(target) / LOCALE_CONF_REL
    try:
        data = path.read_bytes()
    except OSError:
        return ""
    if len(data) > MAX_LOCALE_CONF_BYTES:
        raise DeckSteamSeedError(f"/{LOCALE_CONF_REL} is {len(data)} bytes; refusing to parse it")
    for raw in data.decode("utf-8", "replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if sep and key.strip() == "LANG":
            return value.strip().strip('"').strip("'")
    return ""


def resolve_locale(ctx, target) -> tuple[str, str]:
    """``(locale, where it came from)``. Empty locale means neither had one."""
    locale = locale_from_ctx(ctx)
    if locale:
        return locale, "config:locale_config.sys_lang"
    locale = read_locale_conf(target)
    if locale:
        return locale, f"target:/{LOCALE_CONF_REL}"
    return "", "nowhere"


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


def seed_steam(ctx) -> dict:
    """Do the work; return the install record. Never raises."""
    target = Path(ctx.target)
    record: dict = {
        "status": None,
        "locale": None,
        "locale_source": None,
        "language": None,
        # What Steam will actually use, read back off the disk. Differs from
        # `language` exactly when the registry already carried one.
        "language_on_disk": None,
        "mapping": None,
        "oobe_key": f"{OOBE_STAGE1_KEY}={OOBE_STAGE1_VALUE}",
        "skel": None,
        "user": None,
        "user_path": None,
        "written": None,
        "error": None,
        "warnings": [],
    }
    warnings: list[str] = record["warnings"]

    # 1. The system's own language. No answer -> no seed, and say why.
    try:
        locale, where = resolve_locale(ctx, target)
        record["locale"] = sanitize_text(locale) if locale else None
        record["locale_source"] = where
        language, reason = steam_language_for_locale(locale)
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

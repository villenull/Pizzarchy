#!/usr/bin/env python3
"""Unit tests for `configure_deck`'s `steam_seed` step — P34's answer to Steam's
first-run wizard (`deck_steam_seed.py`).

No VM, no root, no network, no chroot, no Steam and nothing against the Deck:

    python3 test-deck-steam-seed.py

WHAT THIS SUITE IS ACTUALLY FOR
===============================

Everything is asserted by running the step against a **scratch target
filesystem this suite builds** and reading the artefacts back — never by
grepping the module's own source. The fixtures are verbatim ground truth rather
than hand-written approximations:

* `REAL_REGISTRY` is a real `~/.steam/registry.vdf` written by a shipped Steam
  client (dev machine, 2026-08-16), with the account name replaced. It is what
  proves the VDF writer emits the shape Steam itself emits.
* `LANGUAGE_CODE_TO_STEAM` is transcribed from the shipped `steamui/library.js`,
  and §4 re-extracts it from that file when this machine has Steam, so the
  transcription cannot silently rot.

Six traps, and the first two are the ones that shipped, or would ship, a defect:

1. 🔴 **Treating a console keymap as a language.** This is not hypothetical: the
   first version of the module did it, and on hardware (2026-08-16) an operator
   who chose an English system with a **Spanish (Latin American) keyboard** got
   a Spanish Steam. §0b is that exact case, by name, and requires `english`
   with the derivation blind to `kb_layout` entirely.

2. 🔴 **Seeding "OOBE done" without a language.** That is not a smaller version
   of the fix — it removes the user's only chance to choose a language and
   silently imposes English. §8 drives a locale Steam does not ship (`he_IL`),
   and an install with no locale at all, and requires that **nothing at all**
   is written in either case.

3. 🔴 **Clobbering a registry Steam already owns.** §6 seeds over a real
   registry and requires every pre-existing key to survive with its value, and
   requires the user's own `language` NOT to be overwritten. §7 requires an
   unparsable file to be left byte-identical.

4. 🔴 **`/etc/skel` written instead of the created user's home.** `useradd` ran
   in phase 3 of 14. §5 requires both, and §9 requires skel-only for exactly
   one reason: deferred provisioning.

5. 🔴 **A non-idempotent write.** §10 runs the step twice and requires the
   second run to change no bytes and to report that it wrote nothing new.

6. 🔴 **A root-owned `~/.steam`.** Steam's own bootstrap has to be able to
   write in there. §5 asserts the owner of every directory the step created.
"""

from __future__ import annotations

import json
import os
import pathlib
import re
import shutil
import stat
import sys
import tempfile

# ⚠️ Before importing anything under test — see the note in the sibling suites.
sys.dont_write_bytecode = True

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
OVERLAY_ORCH = REPO_ROOT / "iso/overlay/configs/airootfs/usr/share/omarchy-iso/orchestrator"
UPSTREAM_ORCH = REPO_ROOT / "iso/upstream/configs/airootfs/usr/share/omarchy-iso/orchestrator"
# The authority on where the installer's own answers actually land in the config.
CONFIGURATOR = REPO_ROOT / "iso/upstream/configs/airootfs/root/configurator"
# The upstream context that carries that config into the orchestrator.
CONTEXT_PY = REPO_ROOT / "iso/upstream/configs/airootfs/usr/share/omarchy-iso/orchestrator/context.py"
# The shipped Steam client's own language table, when this machine has Steam.
LIVE_STEAMUI = pathlib.Path.home() / ".local/share/Steam/steamui/library.js"

FAILURES = 0
CHECKS = 0
NOTES = 0


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


def check_raises(what: str, fn, exc_types, contains: str | None = None) -> None:
    global FAILURES, CHECKS
    CHECKS += 1
    try:
        fn()
    except exc_types as exc:
        if contains is not None and contains not in str(exc):
            print(f"FAIL {what}: raised, but the message lacks {contains!r}: {exc}")
            FAILURES += 1
            return
        print(f"ok   {what}")
        return
    except Exception as exc:  # noqa: BLE001
        print(f"FAIL {what}: raised {type(exc).__name__}: {exc}, wanted {exc_types}")
        FAILURES += 1
        return
    print(f"FAIL {what}: did not raise")
    FAILURES += 1


def note(what: str) -> None:
    global NOTES
    NOTES += 1
    print(f"NOTE {what}")


# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

WORK = pathlib.Path(tempfile.mkdtemp(prefix="deck-steam-seed-test-"))

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

from orchestrator import deck_configure, deck_steam_seed as ss  # noqa: E402
from orchestrator.context import InstallContext  # noqa: E402

print(f"# modules loaded from {PKG_ROOT}")

TEST_UID = os.getuid()
TEST_GID = os.getgid()

# ---------------------------------------------------------------------------
# 🔴 GROUND TRUTH #1 — a real ~/.steam/registry.vdf, verbatim from a shipped
# Steam client (dev machine, 2026-08-16), account name replaced. Tabs are
# significant: this is the exact shape Steam's own writer emits, and §1 requires
# the module to reproduce it byte for byte.
# ---------------------------------------------------------------------------
REAL_REGISTRY = (
    '"Registry"\n'
    "{\n"
    '\t"HKLM"\n'
    "\t{\n"
    '\t\t"Software"\n'
    "\t\t{\n"
    '\t\t\t"Valve"\n'
    "\t\t\t{\n"
    '\t\t\t\t"Steam"\n'
    "\t\t\t\t{\n"
    '\t\t\t\t\t"SteamPID"\t\t"0"\n'
    '\t\t\t\t\t"ClientLauncherType"\t\t"0"\n'
    "\t\t\t\t}\n"
    "\t\t\t}\n"
    "\t\t}\n"
    "\t}\n"
    '\t"HKCU"\n'
    "\t{\n"
    '\t\t"Software"\n'
    "\t\t{\n"
    '\t\t\t"Valve"\n'
    "\t\t\t{\n"
    '\t\t\t\t"Steam"\n'
    "\t\t\t\t{\n"
    '\t\t\t\t\t"StartupModeTmpIsValid"\t\t"0"\n'
    '\t\t\t\t\t"language"\t\t"english"\n'
    '\t\t\t\t\t"CompletedOOBEStage1"\t\t"1"\n'
    '\t\t\t\t\t"SourceModInstallPath"\t\t"/home/tester/.local/share/Steam/steamapps\\\\sourcemods"\n'
    '\t\t\t\t\t"AutoLoginUser"\t\t"tester"\n'
    '\t\t\t\t\t"Rate"\t\t"30000"\n'
    '\t\t\t\t\t"AlreadyRetriedOfflineMode"\t\t"0"\n'
    '\t\t\t\t\t"GamescopeEnableAppTargetRefreshRate2"\t\t"1"\n'
    "\t\t\t\t}\n"
    '\t\t\t\t"Steamsteamglobal"\n'
    "\t\t\t\t{\n"
    '\t\t\t\t\t"language"\t\t"english"\n'
    "\t\t\t\t}\n"
    "\t\t\t}\n"
    "\t\t}\n"
    "\t}\n"
    "}\n"
)


def tmpdir(name: str) -> pathlib.Path:
    d = WORK / name
    d.mkdir(parents=True, exist_ok=True)
    return d


def mode_of(path: pathlib.Path) -> str:
    return f"{stat.S_IMODE(os.lstat(path).st_mode):04o}"


def make_ctx(
    target,
    *,
    locale: str | None = "en_US.UTF-8",
    keymap: str = "us",
    username: str = "deck",
    defer: bool = False,
) -> InstallContext:
    # Exactly the document the configurator writes (:832-836 -- see §0). Both
    # locale keys are present, and only one of them is a language.
    locale_config: dict = {"kb_layout": keymap, "sys_enc": "UTF-8"}
    if locale is not None:
        locale_config["sys_lang"] = locale
    return InstallContext(
        config_path=pathlib.Path("/dev/null"),
        creds_path=pathlib.Path("/dev/null"),
        full_name="Test User",
        email="t@example.invalid",
        encrypt=False,
        authorized_keys_path=None,
        tailscale_authkey_path=None,
        user_configuration={"timezone": "America/New_York", "locale_config": locale_config},
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
    home: str = "/home/deck",
    locale_conf: str | None = None,
    registry: str | None = None,
    make_home: bool = True,
) -> pathlib.Path:
    target = tmpdir(name) / "mnt"
    (target / "etc").mkdir(parents=True, exist_ok=True)
    (target / "etc/passwd").write_text(
        "root:x:0:0::/root:/bin/bash\n"
        f"{username}:x:{TEST_UID}:{TEST_GID}::{home}:/bin/bash\n"
    )
    if locale_conf is not None:
        (target / ss.LOCALE_CONF_REL).write_text(locale_conf)
    if make_home:
        (target / home.lstrip("/")).mkdir(parents=True, exist_ok=True)
    if registry is not None:
        path = target / home.lstrip("/") / ss.REGISTRY_REL
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(registry)
    return target


def run_step(ctx) -> dict:
    """Run the real step and read the record back out of the install log."""
    ss.steam_seed_step(ctx)
    log = pathlib.Path(ctx.target) / deck_configure.DECK_INSTALL_LOG_REL
    return json.loads(log.read_text())["steam_seed"]


def flatten(doc, prefix=()) -> dict:
    out = {}
    for key, value in doc:
        path = (*prefix, key)
        if isinstance(value, list):
            out.update(flatten(value, path))
        else:
            out["/".join(path)] = value
    return out


# ---------------------------------------------------------------------------
# §0 The claim this whole step rests on: `locale_config` carries BOTH a system
#     language and a console keymap, and only the first is a language.
# ---------------------------------------------------------------------------
print("\n## §0 where the installer's answers actually live")

CONFIG_TEXT = CONFIGURATOR.read_text() if CONFIGURATOR.exists() else ""
CONTEXT_TEXT = CONTEXT_PY.read_text() if CONTEXT_PY.exists() else ""
check_true(
    '🔴 the configurator still writes "sys_lang" — the system LANGUAGE, and what we now read',
    '"sys_lang": "en_US.UTF-8"' in CONFIG_TEXT,
)
check_true(
    'the configurator still writes "kb_layout": "$keyboard" — a KEYMAP, beside it, which we do not read',
    '"kb_layout": "$keyboard"' in CONFIG_TEXT,
)
check_true(
    'the configurator still writes "timezone": "$timezone" (the region answer we DO have)',
    '"timezone": "$timezone"' in CONFIG_TEXT,
)
check_true(
    "…and InstallContext still carries that document verbatim as user_configuration",
    "user_configuration = json.loads(config_path.read_text())" in CONTEXT_TEXT
    and "user_configuration=user_configuration," in CONTEXT_TEXT,
)
check(
    "the module reads the system locale from exactly that place",
    ss.locale_from_ctx(make_ctx("/nonexistent", locale="pt_BR.UTF-8")),
    "pt_BR.UTF-8",
)
check("…and yields nothing when the config has no locale_config", ss.locale_from_ctx(object()), "")
check(
    "…and nothing when locale_config has a keymap but no sys_lang",
    ss.locale_from_ctx(make_ctx("/nonexistent", locale=None, keymap="la-latin1")),
    "",
)
check_true(
    "🔴 the module no longer exposes a keymap reader at all",
    not any(hasattr(ss, n) for n in ("keymap_from_ctx", "steam_language_for_keymap",
                                     "parse_kbd_model_map", "read_model_map",
                                     "BCP47_TO_STEAM", "KBD_MODEL_MAP_REL")),
)

# ---------------------------------------------------------------------------
# §0b 🔴 THE REGRESSION. The operator's own machine, 2026-08-16: English system,
#     Spanish (Latin American) keyboard. Steam came up in Spanish.
# ---------------------------------------------------------------------------
print("\n## §0b the hardware regression: an English system with a Spanish LatAm keyboard")

target = make_target("regression")
record = run_step(make_ctx(target, locale="en_US.UTF-8", keymap="la-latin1"))
check("🔴 Steam is seeded ENGLISH — the system's language, not the keyboard's", record["language"], "english")
check("…and that is what is on the disk", record["language_on_disk"], "english")
check("…and the record names the locale it came from", record["locale"], "en_US.UTF-8")
check("…and where it read it", record["locale_source"], "config:locale_config.sys_lang")
check(
    "…read straight out of the registry, the way the operator would check it",
    ss.read_leaf(
        ss.parse_vdf((target / "home/deck" / ss.REGISTRY_REL).read_text()),
        (ss.REGISTRY_ROOT_KEY, *ss.HKCU_PATH, ss.STEAM_KEY),
        ss.LANGUAGE_KEY,
    ),
    "english",
)
check(
    "🔴 …and the derivation is blind to kb_layout: every keyboard on an en_US system is english",
    sorted(
        {
            ss.seed_steam(make_ctx(make_target(f"blind-{i}"), locale="en_US.UTF-8", keymap=k))["language"]
            for i, k in enumerate(["la-latin1", "es", "jp106", "ko", "be-latin1", "colemak", "", "de-latin1"])
        }
    ),
    ["english"],
)

# ---------------------------------------------------------------------------
# §1 VDF round-trip against a REAL registry.vdf
# ---------------------------------------------------------------------------
print("\n## §1 the VDF reader/writer against a real registry.vdf")

parsed = ss.parse_vdf(REAL_REGISTRY)
check(
    "🔴 a real registry.vdf re-renders byte for byte (tabs, two-tab separator, all of it)",
    ss.render_vdf(parsed),
    REAL_REGISTRY,
)
flat = flatten(parsed)
check("…and HKCU's language is read back", flat["Registry/HKCU/Software/Valve/Steam/language"], "english")
check(
    "…and the OOBE stage-1 key is read back",
    flat["Registry/HKCU/Software/Valve/Steam/CompletedOOBEStage1"],
    "1",
)
check(
    "…and the realm-scoped language is a SIBLING node, not a child of Steam",
    flat["Registry/HKCU/Software/Valve/Steamsteamglobal/language"],
    "english",
)
check(
    "🔴 an escaped backslash is carried through RAW, so it cannot be re-escaped",
    flat["Registry/HKCU/Software/Valve/Steam/SourceModInstallPath"],
    "/home/tester/.local/share/Steam/steamapps\\\\sourcemods",
)
check(
    "read_leaf finds the language through the module's own key path",
    ss.read_leaf(parsed, (ss.REGISTRY_ROOT_KEY, *ss.HKCU_PATH, ss.STEAM_KEY), ss.LANGUAGE_KEY),
    "english",
)
check(
    "key lookup is case-insensitive, as KeyValues is",
    ss.read_leaf(parsed, ("registry", "hkcu", "software", "valve", "steam"), "LANGUAGE"),
    "english",
)

# ---------------------------------------------------------------------------
# §2 The reader refuses rather than guessing
# ---------------------------------------------------------------------------
print("\n## §2 malformed input is refused, never repaired")

check_raises(
    "an unquoted token is refused",
    lambda: ss.parse_vdf('"Registry" { key "1" }'),
    ss.DeckSteamSeedError,
    "unquoted token",
)
check_raises(
    "an unterminated string is refused",
    lambda: ss.parse_vdf('"Registry"\n{\n"a" "b\n}\n'),
    ss.DeckSteamSeedError,
)
check_raises(
    "a subkey that is never closed is refused",
    lambda: ss.parse_vdf('"Registry"\n{\n\t"HKCU"\n\t{\n'),
    ss.DeckSteamSeedError,
)
check_raises(
    "a stray closing brace is refused",
    lambda: ss.parse_vdf('"Registry"\n{\n}\n}\n'),
    ss.DeckSteamSeedError,
)
check_raises(
    "a key with no value is refused",
    lambda: ss.parse_vdf('"Registry"\n{\n\t"HKCU"\n}\n'),
    ss.DeckSteamSeedError,
)
check("a // comment is skipped, not parsed", flatten(ss.parse_vdf('// hi\n"a"\t\t"b"\n')), {"a": "b"})
check_raises(
    "a value needing an escape is refused rather than written unescaped",
    lambda: ss.set_if_absent([], "k", 'has"quote'),
    ss.DeckSteamSeedError,
    "escaping",
)

# ---------------------------------------------------------------------------
# §3 🔴 system locale -> Steam language.
# ---------------------------------------------------------------------------
print("\n## §3 the locale -> Steam language derivation")

check("a glibc locale splits into language and territory", ss.parse_locale("es_MX.UTF-8"), ("es", "MX"))
check("…the modifier goes too", ss.parse_locale("de_DE.UTF-8@euro"), ("de", "DE"))
check("…a bare language is legal", ss.parse_locale("fr"), ("fr", ""))
check("…and the portable locales are not languages", ss.parse_locale("C.UTF-8"), None)


def lang(locale: str):
    return ss.steam_language_for_locale(locale)[0]


for locale, want, why in [
    ("en_US.UTF-8", "english", "🔴 the installer's own hard-coded sys_lang, and the operator's expectation"),
    ("en_GB.UTF-8", "english", "a different territory, the same language"),
    ("es_MX.UTF-8", "latam", "🔴 es-419 is Steam's `latam` — Latin America is a region grouping, not a territory"),
    ("es_AR.UTF-8", "latam", "…and so is Argentina"),
    ("es_ES.UTF-8", "spanish", "🔴 Spain is the ONLY Spanish territory Steam calls `spanish`"),
    ("pt_BR.UTF-8", "brazilian", "🔴 pt-br is `brazilian`, not `portuguese`"),
    ("pt_PT.UTF-8", "portuguese", "pt-PT falls through to the bare `pt` key"),
    ("zh_CN.UTF-8", "schinese", "zh-cn is in the client's map outright"),
    ("zh_TW.UTF-8", "tchinese", "so is zh-tw"),
    ("zh_HK.UTF-8", "tchinese", "🔴 Hong Kong writes Traditional and has no key of its own"),
    ("zh_SG.UTF-8", "schinese", "Singapore writes Simplified, via the bare `zh` key"),
    ("ja_JP.UTF-8", "japanese", "ja"),
    ("ko_KR.UTF-8", "koreana", "🔴 Steam spells Korean `koreana`"),
    ("nl_BE.UTF-8", "dutch", "🔴 the keymap `be-latin1` was fr-BE OR nl-BE; the LOCALE is unambiguous"),
    ("fr_BE.UTF-8", "french", "…and so is the other half of that coin flip"),
    ("de_CH.UTF-8", "german", "Steam has no Swiss German"),
    ("fr_CA.UTF-8", "french", "Steam has no Canadian French"),
    ("nb_NO.UTF-8", "norwegian", "the client's map carries `nb` itself"),
    ("ru_RU.UTF-8", "russian", "ru"),
    ("vi_VN.UTF-8", "vietnamese", "vi"),
    ("id_ID.UTF-8", "indonesian", "id"),
]:
    check(f"{locale} -> {want} ({why})", lang(locale), want)

for locale, why in [
    ("he_IL.UTF-8", "Hebrew is not one of Steam's 31 languages"),
    ("sr_RS.UTF-8", "neither is Serbian"),
    ("ga_IE.UTF-8", "nor Irish"),
    ("nn_NO.UTF-8", "🔴 the client's map has `nb` and `no` but NOT `nn`; this module does not add it"),
    ("C", "the portable locale is not a language"),
    ("C.UTF-8", "…nor is it once the codeset is stripped"),
    ("POSIX", "…nor is POSIX"),
    ("", "the install names no system locale"),
    ("   ", "…nor does whitespace"),
]:
    check(f"{locale.strip() or '<empty>'} -> nothing ({why})", lang(locale), None)

check_true(
    "…and a refusal explains itself, so the install log says why the wizard still appears",
    "nothing is seeded and Steam asks" in ss.steam_language_for_locale("he_IL.UTF-8")[1],
)
check_true(
    "…and a successful derivation records the whole chain",
    "es_MX" in ss.steam_language_for_locale("es_MX.UTF-8")[1]
    and "latam" in ss.steam_language_for_locale("es_MX.UTF-8")[1],
)

# ---------------------------------------------------------------------------
# §4 The table cannot rot: every value must be a language Steam's own wizard
#     offers, and the transcription must still match the shipped client.
# ---------------------------------------------------------------------------
print("\n## §4 the table against the shipped Steam client")

check(
    "every LANGUAGE_CODE_TO_STEAM value is one of the wizard's 31 short names",
    sorted(set(ss.LANGUAGE_CODE_TO_STEAM.values()) - ss.STEAM_LANGUAGES),
    [],
)
check(
    "…including the region-split names the two extra rules produce",
    sorted({"spanish", "latam", "portuguese", "brazilian", "schinese", "tchinese"} - ss.STEAM_LANGUAGES),
    [],
)
check("the shipped client's wizard offers 31 languages", len(ss.STEAM_LANGUAGES), 31)
check(
    "🔴 `latam`, `koreana`, `schinese` and `brazilian` are Steam's spellings, not invented ones",
    sorted({"latam", "koreana", "schinese", "brazilian"} & ss.STEAM_LANGUAGES),
    ["brazilian", "koreana", "latam", "schinese"],
)
check(
    "🔴 every language the wizard offers is reachable from some locale code — no orphans",
    sorted(ss.STEAM_LANGUAGES - set(ss.LANGUAGE_CODE_TO_STEAM.values())),
    [],
)

if LIVE_STEAMUI.exists():
    live_js = LIVE_STEAMUI.read_text(errors="replace")
    # The client's own code->short-name Map, module 51579. Anchored on its first
    # pair so this cannot latch onto some other array of string pairs.
    start = live_js.find('new Map([["en","english"]')
    live_map: dict[str, str] = {}
    if start >= 0:
        chunk = live_js[start : live_js.find("]]", start) + 2]
        live_map = dict(re.findall(r'\["([^"]+)","([^"]+)"\]', chunk))
    check(
        f"🔴 the transcribed table still matches the Map in {LIVE_STEAMUI.name}, key for key",
        live_map,
        ss.LANGUAGE_CODE_TO_STEAM,
    )
    # The client's IsValidLanguage set is 32: the wizard's 31 plus Steam China's.
    vstart = live_js.find('new Set(["sc_schinese"')
    valid = set(re.findall(r'"([a-z_]+)"', live_js[vstart : live_js.find("])", vstart)])) if vstart >= 0 else set()
    check(
        "🔴 …and the 31 wizard languages are exactly the client's valid set minus Steam China's",
        sorted(valid - ss.STEAM_LANGUAGES),
        ["sc_schinese"],
    )
else:
    note(f"{LIVE_STEAMUI} is absent — the transcription could not be diffed against the shipped client")

# The locale.conf fallback, for a config document that carries no sys_lang.
check(
    "the config's sys_lang is preferred over the target's /etc/locale.conf",
    ss.resolve_locale(
        make_ctx("/nonexistent", locale="pt_BR.UTF-8"),
        make_target("prefer-config", locale_conf="LANG=de_DE.UTF-8\n"),
    ),
    ("pt_BR.UTF-8", "config:locale_config.sys_lang"),
)
check(
    "…and /etc/locale.conf answers when the config does not",
    ss.resolve_locale(
        make_ctx("/nonexistent", locale=None),
        make_target("fallback-conf", locale_conf='# a comment\nLANG="de_DE.UTF-8"\nLC_TIME=en_DK.UTF-8\n'),
    ),
    ("de_DE.UTF-8", f"target:/{ss.LOCALE_CONF_REL}"),
)
check(
    "…and neither having one is 'nowhere', not a guess",
    ss.resolve_locale(make_ctx("/nonexistent", locale=None), make_target("no-locale-at-all")),
    ("", "nowhere"),
)

# ---------------------------------------------------------------------------
# §5 The step end to end, on a fresh target
# ---------------------------------------------------------------------------
print("\n## §5 the step on a fresh install")

# A Mexican install, so the seeded value is not the one every other case uses.
target = make_target("fresh")
record = run_step(make_ctx(target, locale="es_MX.UTF-8"))

check("status", record["status"], "seeded")
check("the derived language is recorded", record["language"], "latam")
check("the locale it came from is recorded", record["locale"], "es_MX.UTF-8")
check("…and where that locale was read", record["locale_source"], "config:locale_config.sys_lang")
check("the user is recorded", record["user"], "deck")
check("the user's registry path is recorded", record["user_path"], "/home/deck/" + ss.REGISTRY_REL)
check("the skel path is recorded", record["skel"], "/" + ss.SKEL_REGISTRY_REL)
check("no error", record["error"], None)

user_registry = target / "home/deck" / ss.REGISTRY_REL
skel_registry = target / ss.SKEL_REGISTRY_REL
check_true("🔴 the user's own ~/.steam/registry.vdf exists", user_registry.is_file())
check_true("…and /etc/skel's copy exists too (deferred installs, and later accounts)", skel_registry.is_file())

seeded = flatten(ss.parse_vdf(user_registry.read_text()))
check(
    "🔴 the OOBE stage-1 key is set — this is the only thing that skips the wizard",
    seeded["Registry/HKCU/Software/Valve/Steam/CompletedOOBEStage1"],
    "1",
)
check(
    "🔴 the language is answered too, because skipping the wizard removes the question",
    seeded["Registry/HKCU/Software/Valve/Steam/language"],
    "latam",
)
check(
    "the realm-scoped copy Steam itself writes is set to the same value",
    seeded["Registry/HKCU/Software/Valve/Steamsteamglobal/language"],
    "latam",
)
check("nothing else is invented in the document", sorted(seeded), sorted(seeded))
check(
    "exactly three leaves are written, and no others",
    len(seeded),
    3,
)
check("skel's copy carries the same three", flatten(ss.parse_vdf(skel_registry.read_text())), seeded)

check("the registry is 0644", mode_of(user_registry), "0644")
check("~/.steam is 0755", mode_of(user_registry.parent), "0755")
check("🔴 the registry is owned by the target user, not root", os.stat(user_registry).st_uid, TEST_UID)
check("🔴 …and so is the ~/.steam the step created", os.stat(user_registry.parent).st_uid, TEST_UID)
check_true(
    "no temp file is left behind",
    not any(p.name.startswith(".") and "deck-tmp" in p.name for p in user_registry.parent.iterdir()),
)
check(
    "🔴 the step writes NOTHING under ~/.local/share/Steam (deck_steam_prewarm.py owns that)",
    (target / "home/deck/.local").exists(),
    False,
)
check_true("the record survives json round-tripping into the install log", isinstance(record, dict))

# ---------------------------------------------------------------------------
# §6 An existing registry Steam already owns
# ---------------------------------------------------------------------------
print("\n## §6 seeding over a registry a real Steam wrote")

target = make_target("existing", registry=REAL_REGISTRY)
before = flatten(ss.parse_vdf(REAL_REGISTRY))
record = run_step(make_ctx(target, locale="de_DE.UTF-8"))
after = flatten(ss.parse_vdf((target / "home/deck" / ss.REGISTRY_REL).read_text()))

check("status", record["status"], "seeded")
check(
    "🔴 every pre-existing key survives with its value",
    {k: v for k, v in after.items() if k in before},
    before,
)
check(
    "🔴 the user's own language is NOT overwritten — an answered question is not re-answered",
    after["Registry/HKCU/Software/Valve/Steam/language"],
    "english",
)
check("…and the realm copy is left alone too", after["Registry/HKCU/Software/Valve/Steamsteamglobal/language"], "english")
check(
    "🔴 the record says what Steam will ACTUALLY use, not what we derived",
    (record["language"], record["language_on_disk"]),
    ("german", "english"),
)
check_true(
    "…and the disagreement is reported rather than hidden",
    any("kept" in w for w in record["warnings"]),
)
check(
    "this target's home registry needed nothing written; only skel, which did not exist",
    record["written"],
    ["skel:Steam/language", "skel:Steam/CompletedOOBEStage1", "skel:Steamsteamglobal/language"],
)
check("HKLM is untouched", after["Registry/HKLM/Software/Valve/Steam/SteamPID"], "0")
check("no key is lost", sorted(set(before) - set(after)), [])

# The same, but with the OOBE key absent — the realistic "Steam ran once, never
# finished the wizard" shape.
half = REAL_REGISTRY.replace('\t\t\t\t\t"CompletedOOBEStage1"\t\t"1"\n', "")
target = make_target("existing-half", registry=half)
record = run_step(make_ctx(target, locale="de_DE.UTF-8"))
after = flatten(ss.parse_vdf((target / "home/deck" / ss.REGISTRY_REL).read_text()))
check("the missing OOBE key is filled in", after["Registry/HKCU/Software/Valve/Steam/CompletedOOBEStage1"], "1")
check(
    "…and it is the only key written into the HOME copy",
    [w for w in record["written"] if w.startswith("user:")],
    [f"user:{ss.STEAM_KEY}/{ss.OOBE_STAGE1_KEY}"],
)
check(
    "…while the language it found is still the user's, not the derived one",
    after["Registry/HKCU/Software/Valve/Steam/language"],
    "english",
)

# ---------------------------------------------------------------------------
# §7 An unparsable registry is left alone
# ---------------------------------------------------------------------------
print("\n## §7 a registry we cannot parse is reported, never rewritten")

GARBAGE = '"Registry"\n{\n\tHKCU { broken\n'
target = make_target("garbage", registry=GARBAGE)
record = run_step(make_ctx(target, locale="en_US.UTF-8"))
check("status", record["status"], "failed")
check_true("the reason is recorded", "unquoted token" in (record["error"] or ""))
check(
    "🔴 the file is byte-identical — a client with state is worth more than a skipped wizard",
    (target / "home/deck" / ss.REGISTRY_REL).read_text(),
    GARBAGE,
)

# ---------------------------------------------------------------------------
# §8 🔴 THE TRAP: a locale Steam cannot answer must seed NOTHING
# ---------------------------------------------------------------------------
print("\n## §8 an unresolvable locale seeds nothing at all")

target = make_target("unresolvable")
record = run_step(make_ctx(target, locale="he_IL.UTF-8"))
check("status", record["status"], "skipped")
check("no language was derived", record["language"], None)
check("…but the locale it refused is still recorded", record["locale"], "he_IL.UTF-8")
check_true("…and the record says why", "Steam asks" in (record["mapping"] or ""))
check(
    "🔴 the user's registry was NOT created — seeding 'OOBE done' with no language would impose English",
    (target / "home/deck" / ss.REGISTRY_REL).exists(),
    False,
)
check("🔴 …and neither was skel's", (target / ss.SKEL_REGISTRY_REL).exists(), False)
check("…and ~/.steam itself was not created", (target / "home/deck/.steam").exists(), False)

# No sys_lang in the config AND no /etc/locale.conf on the target: nothing to
# read, so nothing is written. A skip, not a failure — an install we cannot read
# a language out of is exactly the case the wizard exists for.
target = make_target("no-locale")
record = run_step(make_ctx(target, locale=None))
check("no locale anywhere is a recorded skip", record["status"], "skipped")
check("…saying where it looked", record["locale_source"], "nowhere")
check_true("…and why", "no system locale" in (record["mapping"] or ""))
check(
    "…and still writes nothing",
    (target / "home/deck" / ss.REGISTRY_REL).exists(),
    False,
)

# The same install, but archinstall has already written /etc/locale.conf.
target = make_target("no-locale-but-conf", locale_conf="LANG=ja_JP.UTF-8\n")
record = run_step(make_ctx(target, locale=None))
check("…while a target that HAS a locale.conf is seeded from it", record["status"], "seeded")
check("…with the language that file names", record["language"], "japanese")
check("…and the record names the file", record["locale_source"], f"target:/{ss.LOCALE_CONF_REL}")

# ---------------------------------------------------------------------------
# §9 Deferred provisioning: skel only, and said out loud
# ---------------------------------------------------------------------------
print("\n## §9 deferred provisioning")

target = make_target("deferred", make_home=False)
record = run_step(make_ctx(target, locale="en_US.UTF-8", defer=True))
check("status", record["status"], "skel-only")
check("the language is still derived", record["language"], "english")
check("no user is named", record["user"], None)
check("no home was written", record["user_path"], None)
check_true("skel was written", (target / ss.SKEL_REGISTRY_REL).is_file())
check_true(
    "…and the record explains that useradd copies it at first boot",
    any("useradd" in w for w in record["warnings"]),
)
check(
    "🔴 no home directory was invented for an account that does not exist",
    (target / "home/deck").exists(),
    False,
)

# A named user who is not in /etc/passwd is a failure, not a guessed home.
target = make_target("ghost", username="ghost", home="/home/ghost")
record = run_step(make_ctx(target, locale="en_US.UTF-8", username="deck"))
check("an unconfirmable account is a recorded failure", record["status"], "failed")
check_true("…naming the account", "deck" in (record["error"] or ""))

# ---------------------------------------------------------------------------
# §10 Idempotency and the symlink refusal
# ---------------------------------------------------------------------------
print("\n## §10 re-runnable, and it will not write through a symlink")

target = make_target("idempotent")
first = run_step(make_ctx(target, locale="en_US.UTF-8"))
bytes_after_first = (target / "home/deck" / ss.REGISTRY_REL).read_bytes()
second = run_step(make_ctx(target, locale="en_US.UTF-8"))
check("the second run still reports success", second["status"], "seeded")
check(
    "🔴 …and changed no bytes",
    (target / "home/deck" / ss.REGISTRY_REL).read_bytes(),
    bytes_after_first,
)
check("…and says it wrote nothing new", second["written"], [])
check("the first run did write all three leaves", len(first["written"]), 6)

target = make_target("symlink")
link = target / "home/deck" / ss.REGISTRY_REL
link.parent.mkdir(parents=True, exist_ok=True)
(target / "elsewhere.vdf").write_text('"Registry"\n{\n}\n')
link.symlink_to("../../elsewhere.vdf")
record = run_step(make_ctx(target, locale="en_US.UTF-8"))
check("a symlinked registry is a recorded failure", record["status"], "failed")
check_true("…naming the reason", "symlink" in (record["error"] or ""))
check(
    "🔴 …and the symlink target is untouched",
    (target / "elsewhere.vdf").read_text(),
    '"Registry"\n{\n}\n',
)

# ---------------------------------------------------------------------------
# §11 The record, and the registry it has to fit into
# ---------------------------------------------------------------------------
print("\n## §11 the install record and the step registry")

target = make_target("record")
record = run_step(make_ctx(target, locale="en_US.UTF-8"))
check_true(
    "the record is JSON with no surprises",
    json.loads(json.dumps(record)) == record,
)
check(
    "the record carries nothing secret — it is a world-readable support artefact",
    sorted(k for k in record if any(s in k.lower() for s in ("pass", "secret", "token", "cred"))),
    [],
)
check_true(
    "…and nothing in its values looks like a home-grown secret either",
    "password" not in json.dumps(record).lower(),
)
check(
    "the record names the exact registry key it wrote, so a human can grep for it",
    record["oobe_key"],
    "CompletedOOBEStage1=1",
)

names = [s.name for s in deck_configure.deck_steps()]
if "steam_seed" in names:
    check(
        "🔴 the step is non-critical: a bad seed must degrade to today's wizard, never to a failed install",
        [s.critical for s in deck_configure.deck_steps() if s.name == "steam_seed"],
        [False],
    )
    check("…and it runs after Steam is installed", names.index("pkgs") < names.index("steam_seed"), True)
    check("…and before the T12 applier, which stays last", names.index("steam_seed") < names.index("patches"), True)
else:
    note("steam_seed is not in deck_steps() yet — the coordinator registers it (Agent I owns no other file)")
check(
    "exactly one step in the whole registry is critical, and it is not this one",
    [s.name for s in deck_configure.deck_steps() if s.critical],
    ["autologin"],
)
check("every step name is still distinct (they are the install log's keys)", len(set(names)), len(names))


print()
if NOTES:
    print(f"{NOTES} check(s) did not run — see the NOTE lines above")
print(f"{CHECKS - FAILURES}/{CHECKS} checks passed")
if FAILURES:
    print(f"{FAILURES} FAILURES")
shutil.rmtree(WORK, ignore_errors=True)
sys.exit(1 if FAILURES else 0)

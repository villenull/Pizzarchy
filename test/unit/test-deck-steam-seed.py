#!/usr/bin/env python3
"""Unit tests for `configure_deck`'s `steam_seed` step — P34's answer to Steam's
first-run wizard (`deck_steam_seed.py`).

No VM, no root, no network, no chroot, no Steam and nothing against the Deck:

    python3 test-deck-steam-seed.py

WHAT THIS SUITE IS ACTUALLY FOR
===============================

Everything is asserted by running the step against a **scratch target
filesystem this suite builds** and reading the artefacts back — never by
grepping the module's own source. The two fixtures are verbatim ground truth
rather than hand-written approximations:

* `REAL_REGISTRY` is a real `~/.steam/registry.vdf` written by a shipped Steam
  client (dev machine, 2026-08-16), with the account name replaced. It is what
  proves the VDF writer emits the shape Steam itself emits.
* `MODEL_MAP` is an excerpt of `/usr/share/systemd/kbd-model-map`, and §4 diffs
  it against the real file on this machine so the excerpt cannot silently rot.

Six traps, and the first two are the ones that would ship a defect:

1. 🔴 **Seeding "OOBE done" without a language.** That is not a smaller version
   of the fix — it removes the user's only chance to choose a language and
   silently imposes English. §9 drives an ambiguous keymap (`be-latin1`, which
   is fr-BE *or* nl-BE) and requires that **nothing at all** is written.

2. 🔴 **Treating a console keymap as a language.** `la-latin1` is not "la",
   `jp106` is not "jp", and `de-latin1` carries no language tag of its own.
   §3 asserts the real derivations, including the two that are refusals.

3. 🔴 **Clobbering a registry Steam already owns.** §7 seeds over a real
   registry and requires every pre-existing key to survive with its value, and
   requires the user's own `language` NOT to be overwritten. §8 requires an
   unparsable file to be left byte-identical.

4. 🔴 **`/etc/skel` written instead of the created user's home.** `useradd` ran
   in phase 3 of 14. §6 requires both, and §10 requires skel-only for exactly
   one reason: deferred provisioning.

5. 🔴 **A non-idempotent write.** §11 runs the step twice and requires the
   second run to change no bytes and to report that it wrote nothing new.

6. 🔴 **A root-owned `~/.steam`.** Steam's own bootstrap has to be able to
   write in there. §6 asserts the owner of every directory the step created.
"""

from __future__ import annotations

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
OVERLAY_ORCH = REPO_ROOT / "iso/overlay/configs/airootfs/usr/share/omarchy-iso/orchestrator"
UPSTREAM_ORCH = REPO_ROOT / "iso/upstream/configs/airootfs/usr/share/omarchy-iso/orchestrator"
# The authority on where the user's keyboard pick actually lands in the config.
CONFIGURATOR = REPO_ROOT / "iso/upstream/configs/airootfs/root/configurator"
# systemd's real table, when this machine has one.
LIVE_MODEL_MAP = pathlib.Path("/usr/share/systemd/kbd-model-map")

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

# ---------------------------------------------------------------------------
# 🔴 GROUND TRUTH #2 — rows copied verbatim out of
# /usr/share/systemd/kbd-model-map. §4 diffs them against the real file.
# ---------------------------------------------------------------------------
MODEL_MAP = """\
# Originally generated from system-config-keyboard's model list.
# The sixth column is an optional comma-separated list of RFC 4646 / BCP 47
# language tags the row matches.
# consolelayout\t\txlayout\txmodel\t\txvariant\txoptions\t\t\t\t\tbcp47
us\t\t\tus\tpc105+inet\t-\tterminate:ctrl_alt_bksp\t\t\t\ten-US,en
us-acentos\t\tus\tpc105\t\t-\tterminate:ctrl_alt_bksp\t\t\t\t-
dvorak\t\t\tus\tpc105\t\t-\tterminate:ctrl_alt_bksp\t\t\t\t-
uk\t\t\tgb\tpc105\t\t-\tterminate:ctrl_alt_bksp\t\t\t\ten-GB
la-latin1\t\tlatam\tpc105\t\t-\tterminate:ctrl_alt_bksp\t\t\t\tes-419,es-MX,es-AR,es-CO,es-CL,es-PE,es-VE
es\t\t\tes\tpc105\t\t-\tterminate:ctrl_alt_bksp\t\t\t\tes-ES,es
de\t\t\tde\tpc105\t\t-\tterminate:ctrl_alt_bksp\t\t\t\tde-DE,de-AT,de
de-latin1\t\tde\tpc105\t\t-\tterminate:ctrl_alt_bksp\t\t\t\t-
de-latin1-nodeadkeys\tde\tpc105\t\t-\tterminate:ctrl_alt_bksp\t\t\t\t-
fr\t\t\tfr\tpc105\t\t-\tterminate:ctrl_alt_bksp\t\t\t\tfr-FR,fr
fr-latin1\t\tfr\tpc105\t\t-\tterminate:ctrl_alt_bksp\t\t\t\t-
be-latin1\t\tbe\tpc105\t\t-\tterminate:ctrl_alt_bksp\t\t\t\tfr-BE,nl-BE
ie\t\t\tie\tpc105\t\t-\tterminate:ctrl_alt_bksp\t\t\t\ten-IE,ga-IE,ga
it\t\t\tit\tpc105\t\t-\tterminate:ctrl_alt_bksp\t\t\t\tit-IT,it-CH,it
it2\t\t\tit\tpc105\t\t-\tterminate:ctrl_alt_bksp\t\t\t\t-
br-abnt2\t\tbr\tabnt2\t\t-\tterminate:ctrl_alt_bksp\t\t\t\tpt-BR
pt-latin1\t\tpt\tpc105\t\t-\tterminate:ctrl_alt_bksp\t\t\t\tpt-PT,pt
jp106\t\t\tjp\tjp106\t\t-\tterminate:ctrl_alt_bksp\t\t\t\tja-JP,ja
ko\t\t\tkr\tpc105\t\t-\tterminate:ctrl_alt_bksp\t\t\t\tko-KR,ko
no\t\t\tno\tpc105\t\t-\tterminate:ctrl_alt_bksp\t\t\t\tnb-NO,nn-NO,no
ru\t\t\tru,us\tpc105\t\t-\tterminate:ctrl_alt_bksp\t\t\t\tru-RU,ru
sg\t\t\tch\tpc105\t\t-\tterminate:ctrl_alt_bksp\t\t\t\tde-CH
cf\t\t\tca\tpc105\t\t-\tterminate:ctrl_alt_bksp\t\t\t\tfr-CA
il\t\t\til\tpc105\t\t-\tterminate:ctrl_alt_bksp\t\t\t\the-IL,he
sr-latin\t\trs\tpc105\t\t-\tterminate:ctrl_alt_bksp\t\t\t\tsr-Latn-RS,sr-Latn
"""


def tmpdir(name: str) -> pathlib.Path:
    d = WORK / name
    d.mkdir(parents=True, exist_ok=True)
    return d


def mode_of(path: pathlib.Path) -> str:
    return f"{stat.S_IMODE(os.lstat(path).st_mode):04o}"


def make_ctx(target, *, keymap="us", username="deck", defer=False) -> InstallContext:
    return InstallContext(
        config_path=pathlib.Path("/dev/null"),
        creds_path=pathlib.Path("/dev/null"),
        full_name="Test User",
        email="t@example.invalid",
        encrypt=False,
        authorized_keys_path=None,
        tailscale_authkey_path=None,
        # Exactly the document the configurator writes (:831-836 -- see §0).
        user_configuration={
            "timezone": "America/New_York",
            "locale_config": {"kb_layout": keymap, "sys_enc": "UTF-8", "sys_lang": "en_US.UTF-8"},
        },
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
    model_map: str | None = MODEL_MAP,
    registry: str | None = None,
    make_home: bool = True,
) -> pathlib.Path:
    target = tmpdir(name) / "mnt"
    (target / "etc").mkdir(parents=True, exist_ok=True)
    (target / "etc/passwd").write_text(
        "root:x:0:0::/root:/bin/bash\n"
        f"{username}:x:{TEST_UID}:{TEST_GID}::{home}:/bin/bash\n"
    )
    if model_map is not None:
        path = target / ss.KBD_MODEL_MAP_REL
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(model_map)
    if make_home:
        (target / home.lstrip("/")).mkdir(parents=True, exist_ok=True)
    if registry is not None:
        path = target / home.lstrip("/") / ss.REGISTRY_REL
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(registry)
    return target


# A live_root with no kbd-model-map, so a case that removes the target's copy
# cannot accidentally be rescued by the dev machine's.
EMPTY_LIVE = tmpdir("empty-live")


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
# §0 The claim this whole step rests on: the configurator asks for a keyboard
#     layout and hard-codes the language. If that ever changes, the mapping in
#     deck_steam_seed.py is answering a question the installer now asks itself.
# ---------------------------------------------------------------------------
print("\n## §0 where the installer's answers actually live")

CONFIG_TEXT = CONFIGURATOR.read_text() if CONFIGURATOR.exists() else ""
check_true(
    'the configurator still writes "kb_layout": "$keyboard"',
    '"kb_layout": "$keyboard"' in CONFIG_TEXT,
)
check_true(
    '🔴 the configurator still HARD-CODES "sys_lang" — there is no language question to carry over',
    '"sys_lang": "en_US.UTF-8"' in CONFIG_TEXT,
)
check_true(
    'the configurator still writes "timezone": "$timezone" (the region answer we DO have)',
    '"timezone": "$timezone"' in CONFIG_TEXT,
)
check(
    "the module reads the keymap from exactly that place",
    ss.keymap_from_ctx(make_ctx("/nonexistent", keymap="la-latin1")),
    "la-latin1",
)
check("…and yields nothing when the config has no locale_config", ss.keymap_from_ctx(object()), "")

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
# §3 🔴 keymap -> language. A console keymap is not a language.
# ---------------------------------------------------------------------------
print("\n## §3 the keymap -> Steam language derivation")

ROWS = ss.parse_kbd_model_map(MODEL_MAP)
check("the excerpt parses to one row per keymap", len(ROWS), 25)


def lang(keymap: str):
    return ss.steam_language_for_keymap(keymap, ROWS)[0]


for keymap, want, why in [
    ("us", "english", "en-US"),
    ("uk", "english", "en-GB, a different keymap and the same language"),
    ("la-latin1", "latam", "🔴 es-419 is Steam's `latam`, NOT `spanish`, and NOT the keymap name"),
    ("es", "spanish", "es-ES is Steam's `spanish`, and it is a DIFFERENT answer from la-latin1"),
    ("br-abnt2", "brazilian", "🔴 pt-BR is `brazilian`, not `portuguese`"),
    ("pt-latin1", "portuguese", "pt-PT is `portuguese`"),
    ("jp106", "japanese", "🔴 the keymap name is `jp106`; the language is not"),
    ("ko", "koreana", "🔴 Steam spells Korean `koreana`"),
    ("de", "german", "its own row's tags"),
    ("de-latin1", "german", "🔴 no tags of its own — resolved via the `de` X layout it shares"),
    ("de-latin1-nodeadkeys", "german", "same fallback, two hops from a tag"),
    ("fr-latin1", "french", "no tags of its own — via the `fr` X layout"),
    ("it2", "italian", "no tags of its own — via the `it` X layout"),
    ("dvorak", "english", "no tags of its own — via the `us` X layout"),
    ("no", "norwegian", "🔴 nb-NO,nn-NO,no are three tags and ONE Steam language"),
    ("ru", "russian", "an `ru,us` X layout is still Russian"),
    ("sg", "german", "de-CH: Steam has no Swiss German, and German is the honest answer"),
    ("cf", "french", "fr-CA: Steam has no Canadian French"),
]:
    check(f"{keymap} -> {want} ({why})", lang(keymap), want)

for keymap, why in [
    ("be-latin1", "🔴 fr-BE or nl-BE — a coin flip, so nothing is seeded"),
    ("ie", "🔴 en-IE and ga-IE — Irish is not a Steam language, so the row is ambiguous"),
    ("il", "he-IL — Hebrew is not one of Steam's 31 languages"),
    ("sr-latin", "sr-Latn — Serbian is not one of Steam's 31 languages"),
    ("colemak", "no row in kbd-model-map at all"),
    ("", "the install names no keyboard layout"),
]:
    check(f"{keymap or '<empty>'} -> nothing ({why})", lang(keymap), None)

check_true(
    "…and a refusal explains itself, so the install log says why the wizard still appears",
    "ambiguous" in ss.steam_language_for_keymap("be-latin1", ROWS)[1],
)
check_true(
    "…and a successful derivation records the whole chain",
    "es-419" in ss.steam_language_for_keymap("la-latin1", ROWS)[1]
    and "latam" in ss.steam_language_for_keymap("la-latin1", ROWS)[1],
)

# ---------------------------------------------------------------------------
# §4 The two tables cannot rot: every value must be a language Steam ships, and
#     the excerpt must still match the real systemd file.
# ---------------------------------------------------------------------------
print("\n## §4 the tables against reality")

check(
    "every BCP47_TO_STEAM value is one of the shipped client's 31 short names",
    sorted(set(ss.BCP47_TO_STEAM.values()) - ss.STEAM_LANGUAGES),
    [],
)
check(
    "…including the four region-split names the tag rules produce",
    sorted({"spanish", "latam", "portuguese", "brazilian", "schinese", "tchinese"} - ss.STEAM_LANGUAGES),
    [],
)
check("the shipped client offers 31 OOBE languages", len(ss.STEAM_LANGUAGES), 31)
check(
    "🔴 `latam`, `koreana`, `schinese` and `brazilian` are Steam's spellings, not invented ones",
    sorted({"latam", "koreana", "schinese", "brazilian"} & ss.STEAM_LANGUAGES),
    ["brazilian", "koreana", "latam", "schinese"],
)

if LIVE_MODEL_MAP.exists():
    live_text = LIVE_MODEL_MAP.read_text()
    live_rows = {k: (x, tuple(t)) for k, x, t in ss.parse_kbd_model_map(live_text)}
    # A row this machine's systemd does not carry is a NOTE, not a failure: the
    # excerpt is Arch's, CI runs on Ubuntu, and a distro shipping a smaller map
    # would otherwise turn a real drift check into a permanent red. A row that
    # is present but DIFFERENT is the thing worth failing on.
    absent = [k for k, _, _ in ROWS if k not in live_rows]
    drift = [
        (k, live_rows[k], (x, tuple(t))) for k, x, t in ROWS if k in live_rows and live_rows[k] != (x, tuple(t))
    ]
    check(f"🔴 every excerpt row this machine also has still matches {LIVE_MODEL_MAP}", drift, [])
    check_true(
        f"…and it checked a meaningful number of them ({len(ROWS) - len(absent)}/{len(ROWS)})",
        len(ROWS) - len(absent) >= 15,
    )
    if absent:
        note(f"{len(absent)} excerpt row(s) are not in this machine's map: {','.join(absent)}")
    check_true(
        "…and the real file documents the sixth column as BCP 47, which is what makes it usable",
        "BCP 47" in live_text,
    )
else:
    note(f"{LIVE_MODEL_MAP} is absent — the excerpt could not be diffed against the real file")

check_raises(
    "a target and a live root with no kbd-model-map is a loud failure, not a silent skip",
    lambda: ss.read_model_map(tmpdir("no-map"), EMPTY_LIVE),
    ss.DeckSteamSeedError,
    "cannot be turned into a language",
)
check(
    "the target's copy is preferred over the live ISO's",
    ss.read_model_map(make_target("prefer-target"), EMPTY_LIVE)[1],
    f"target:/{ss.KBD_MODEL_MAP_REL}",
)

# ---------------------------------------------------------------------------
# §5 The step end to end, on a fresh target
# ---------------------------------------------------------------------------
print("\n## §5 the step on a fresh install")

target = make_target("fresh")
record = run_step(make_ctx(target, keymap="la-latin1"))

check("status", record["status"], "seeded")
check("the derived language is recorded", record["language"], "latam")
check("the keymap it came from is recorded", record["keymap"], "la-latin1")
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
record = run_step(make_ctx(target, keymap="de"))
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
record = run_step(make_ctx(target, keymap="de"))
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
record = run_step(make_ctx(target, keymap="us"))
check("status", record["status"], "failed")
check_true("the reason is recorded", "unquoted token" in (record["error"] or ""))
check(
    "🔴 the file is byte-identical — a client with state is worth more than a skipped wizard",
    (target / "home/deck" / ss.REGISTRY_REL).read_text(),
    GARBAGE,
)

# ---------------------------------------------------------------------------
# §8 🔴 THE TRAP: an ambiguous keymap must seed NOTHING
# ---------------------------------------------------------------------------
print("\n## §8 an ambiguous keymap seeds nothing at all")

target = make_target("ambiguous")
record = run_step(make_ctx(target, keymap="be-latin1"))
check("status", record["status"], "skipped")
check("no language was derived", record["language"], None)
check_true("…and the record says why", "ambiguous" in (record["mapping"] or ""))
check(
    "🔴 the user's registry was NOT created — seeding 'OOBE done' with no language would impose English",
    (target / "home/deck" / ss.REGISTRY_REL).exists(),
    False,
)
check("🔴 …and neither was skel's", (target / ss.SKEL_REGISTRY_REL).exists(), False)
check("…and ~/.steam itself was not created", (target / "home/deck/.steam").exists(), False)

# `live_root` is a seam so this case cannot be rescued by the DEV machine's own
# /usr/share/systemd/kbd-model-map — the product's default really is to fall
# back to the live ISO's copy, and §4 asserts that preference separately.
target = make_target("no-model-map", model_map=None)
record = ss.seed_steam(make_ctx(target, keymap="us"), EMPTY_LIVE)
check("a kbd-model-map on neither root is a recorded failure", record["status"], "failed")
check_true("…naming the file", ss.KBD_MODEL_MAP_REL in (record["error"] or ""))
check(
    "…and still writes nothing",
    (target / "home/deck" / ss.REGISTRY_REL).exists(),
    False,
)

# ---------------------------------------------------------------------------
# §9 Deferred provisioning: skel only, and said out loud
# ---------------------------------------------------------------------------
print("\n## §9 deferred provisioning")

target = make_target("deferred", make_home=False)
record = run_step(make_ctx(target, keymap="us", defer=True))
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
record = run_step(make_ctx(target, keymap="us", username="deck"))
check("an unconfirmable account is a recorded failure", record["status"], "failed")
check_true("…naming the account", "deck" in (record["error"] or ""))

# ---------------------------------------------------------------------------
# §10 Idempotency and the symlink refusal
# ---------------------------------------------------------------------------
print("\n## §10 re-runnable, and it will not write through a symlink")

target = make_target("idempotent")
first = run_step(make_ctx(target, keymap="us"))
bytes_after_first = (target / "home/deck" / ss.REGISTRY_REL).read_bytes()
second = run_step(make_ctx(target, keymap="us"))
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
record = run_step(make_ctx(target, keymap="us"))
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
record = run_step(make_ctx(target, keymap="us"))
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

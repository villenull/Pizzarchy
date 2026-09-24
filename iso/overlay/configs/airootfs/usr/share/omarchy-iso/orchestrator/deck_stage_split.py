"""Early/late split of the Deck install for FAST-INSTALL (C2-C4).

``OMARCHY_INSTALL_STAGE`` selects the slice: ``early`` restores the common
minimal image then applies only the requested variant delta, ``late``
provisions the user and finishes, and ``full`` (default) keeps today's
single-pass behaviour untouched.

Variant answers (C2) live in ``deck_choices``: ``preinstalls`` and ``gaming``
(each exactly ``yes``/``no``), plus ``locked`` written last by the form.
The early worker restores the common image FIRST and only then waits for
``locked`` -- the restore never blocks on the form. ``preinstalls`` is
immutable after the lock; ``gaming`` may still flip yes→no (Wi-Fi B returns
to the gaming choice, and the form deletes the network-ready marker on that
reversal) until online work starts, so every gaming-gated phase re-reads it.
Once online work starts the answers are frozen.

Why the early phase is in this exact order
------------------------------------------
All pacman mutations finish before the Limine/UKI finalizer (PR #145 forbids
package mutation concurrent with or after the UKI build). So early runs:
restore -> system -> identity-free deck -> CHOICES GATE (locked) ->
preinstalls offline delta -> NETWORK GATE (gaming=yes only; a Wi-Fi B
reversal can still change gaming to no) -> gaming offline delta from the
FINAL choice -> Steam launcher (online, only if gaming=yes) -> provisioning
-> UKI -> keyring join -> Valve client fetch (only if gaming=yes).
Gaming=no never touches the network and never fetches Steam: it cannot stall
on a dead network or leave a half-fetched Steam stack on a desktop-only
machine. Gaming=yes without connectivity blocks at the network gate (the
form holds the network screen); a fetch that still fails is a FAILED
install, never a quiet black Gaming screen -- the marker check below is the
enforcement.

Coverage (C4: each deck step exactly one classification, with its reason)
-------------------------------------------------------------------------
See ``STEP_CLASSIFICATION``: ``early`` steps run in the early slice,
``late`` steps in the late slice, ``early-pkgs`` is the Steam-launcher fetch
phase, and ``replaced`` steps are superseded by the staged Steam APIs
(``early_steam_fetch_only`` / ``late_steam``). Optional variant package
deltas are orchestrator-level phases, not registry steps, so they are not in
this table. ``test-deck-variants.py`` asserts this table covers the registry
exactly.
"""

from __future__ import annotations

import os
from collections.abc import Callable
from pathlib import Path


STAGE_ENV_VAR = "OMARCHY_INSTALL_STAGE"
STAGE_EARLY = "early"
STAGE_LATE = "late"
STAGE_FULL = "full"
STAGES = (STAGE_EARLY, STAGE_LATE, STAGE_FULL)

# step name -> (slice, reason). Slice is one of "early", "late",
# "early-pkgs", "replaced".
STEP_CLASSIFICATION: dict[str, tuple[str, str]] = {
    "wifi": ("early", "never reads the account; carries the live NM profile into the target"),
    "pkgs": ("early-pkgs", "Steam launcher pacman transaction; gaming=yes only, after the network gate, before the UKI build"),
    "steam_bootstrap": ("replaced", "superseded by early_steam_fetch_only into the staging home (gaming=yes only)"),
    "steam_seed": ("replaced", "superseded by late_steam, which re-runs the seed last after the rename (gaming=yes only)"),
    "autologin": ("late", "needs the created account (User= drop-in + SDDM state); critical=True; gaming=yes only"),
    "session_dconf": ("early", "resolves the user via deck_user; skel-only record with no account yet"),
    "idle_policy": ("early", "same skel-only degradation as session_dconf"),
    "mask_sleep_lock": ("early", "same skel-only degradation as session_dconf"),
    "limine_rotation": ("early", "boot-chain file, no account involved; must precede limine-update"),
    "tty_rotation": ("early", "console config, no account involved"),
    "desktop_rotation": ("early", "same skel-only degradation as session_dconf"),
    "lock_wake_dpms": ("early", "same skel-only degradation as session_dconf"),
    "menu_lock_row": ("early", "same skel-only degradation as session_dconf"),
    "session_bake": ("late", "writes per-user files into the real home; DeckUserDeferred with no account; desktop-only verb when gaming=no"),
    "patches": ("early", "target files, no account involved; must precede the UKI build"),
}

EARLY_DECK_STEPS = tuple(
    name for name, (slice_, _) in STEP_CLASSIFICATION.items() if slice_ == "early"
)
LATE_DECK_STEPS = tuple(
    name for name, (slice_, _) in STEP_CLASSIFICATION.items() if slice_ == "late"
)

# Live run-state directory. Overridable so the unit suite never touches /run.
DECK_RUN_DIR_ENV = "OMARCHY_DECK_RUN_DIR"
DECK_RUN_DIR_DEFAULT = "/run/omarchy-deck"
NETWORK_WAIT_SECS_ENV = "OMARCHY_DECK_NETWORK_WAIT_SECS"
NETWORK_WAIT_DEFAULT_SECS = 1800
NETWORK_POLL_SECS = 5


def stage_name() -> str:
    """The requested slice. Unknown values fail loudly, never default."""
    raw = os.environ.get(STAGE_ENV_VAR, STAGE_FULL).strip().lower()
    if raw not in STAGES:
        raise RuntimeError(
            f"{STAGE_ENV_VAR}={raw!r} is not one of "
            f"{', '.join(STAGES)}; refusing to guess which half of the install to run"
        )
    return raw


def _require(obj, name: str):
    """Attribute upstream renamed or removed under us: say which, loudly."""
    try:
        return getattr(obj, name)
    except AttributeError as exc:
        raise RuntimeError(
            f"orchestrator module {obj.__name__} has no {name!r}; "
            "upstream renamed a phase entry point this split depends on"
        ) from exc


def _run_dir() -> Path:
    return Path(os.environ.get(DECK_RUN_DIR_ENV, DECK_RUN_DIR_DEFAULT))


def _by_name(full) -> dict:
    return {name: fn for name, fn in full}


def _deck_step_map() -> dict[str, Callable]:
    """Registry name -> step fn, read live so a renamed step fails loudly."""
    from . import deck_configure

    return {step.name: step.fn for step in deck_configure.deck_steps()}


def early_phases(ctx, phases_impl, full) -> list:
    """Phases that run while the form is up, in dependency order.

    ``full`` is upstream's complete list (post-PR145 names); selection is by
    display name so a rewording fails loudly via the required set below.
    ``phases_impl`` resolves the parallel-fan members this slice needs
    individually (the fan itself must never run in the split flow: it would
    create the user early and finalize boot concurrently with pacman).
    """
    _ = ctx
    required = {
        "Preparing live environment",
        "Preparing install target",
        "Installing Arch + Omarchy",
        "Configuring hibernation",
        "Configuring system",
        "Staging provisioning",
    }
    by_name = _by_name(full)
    missing = sorted(required - set(by_name))
    if missing:
        raise RuntimeError(
            "early stage needs upstream phases that are not in build_phases: "
            + ", ".join(missing)
        )
    deck_steps = _deck_step_map()
    return [
        ("Preparing live environment", by_name["Preparing live environment"]),
        ("Preparing install target", by_name["Preparing install target"]),
        ("Installing Arch + Omarchy", by_name["Installing Arch + Omarchy"]),
        ("Configuring hibernation", by_name["Configuring hibernation"]),
        ("Configuring system", by_name["Configuring system"]),
        ("Configuring Steam Deck (early, identity-free)", _early_deck_fn(deck_steps)),
        ("Waiting for installer choices (preinstalls/gaming locked)", _choices_gate_fn()),
        ("Installing optional preinstalls offline", _variant_delta_fn("preinstalls")),
        ("Waiting for network (gaming=yes only)", _network_gate_fn()),
        ("Installing optional gaming packages offline", _variant_delta_fn("gaming")),
        ("Installing Steam launcher (gaming=yes only)", _pkgs_fetch_fn()),
        ("Staging provisioning", by_name["Staging provisioning"]),
        ("Finalizing Limine boot", _limine_fn(phases_impl)),
        ("Joining target keyring init", _keyring_join_fn(phases_impl)),
        ("Fetching Steam client (staging, gaming=yes only)", _steam_fetch_fn()),
    ]


def late_phases(ctx, phases_impl, full) -> list:
    """Phases that run after the S5 confirm, in dependency order.

    Never re-runs the restore, the pacman transactions, or the Limine/UKI
    build (RootImage: the UKI needs the archinstall Installer object and
    identity changes do not affect it; re-running it would also waste the
    seconds this design exists to save). Never re-runs genfstab (early
    already wrote it; appending duplicates).

    The late Deck slice runs AFTER "Configuring login": upstream deletes
    sddm.conf.d/autologin.conf on unencrypted installs there, and the gaming
    autologin drop-in (zz-deck-session.conf, sorts last) must be the final
    writer or the Deck boots to a controller-inaccessible login. Gaming=no
    instead writes the password greeter (Qt Virtual Keyboard) after login.
    """
    # PR #145 folds these steps into "Finalizing boot and user setup". The
    # split must resolve the fan members directly: running the full fan in
    # either half would race package mutation or recreate the user/UKI.
    required_names = {"Finalizing boot and user setup", "Validating boot setup", "Creating factory snapshot"}
    by_name = _by_name(full)
    missing = sorted(required_names - set(by_name))
    if missing:
        raise RuntimeError(
            "late stage needs upstream phases that are not in build_phases: "
            + ", ".join(missing)
        )
    _ = ctx
    user_finalizer = _require(phases_impl, "run_chroot_finalizer")
    configure_login = _require(phases_impl, "configure_login")
    configure_ssh = _require(phases_impl, "configure_ssh_access")
    configure_tailscale = _require(phases_impl, "configure_tailscale")
    configure_dns = _require(phases_impl, "configure_dns_resolver")
    return [
        ("Asserting Deck kernel (linux-omarchy, no stock linux)", _kernel_assert_fn()),
        ("Applying identity (user, hostname, timezone, keymap, Wi-Fi)", _identity_fn()),
        ("Creating user (uid 1000, offline)", _create_user_fn()),
        ("Recording installer variant (gaming/preinstalls)", _variant_record_fn()),
        ("Relocating Steam staging home (gaming=yes only)", _late_steam_fn()),
        ("Finalizing user", _keep_target_pacman_conf(user_finalizer)),
        ("Configuring login", configure_login),
        ("Configuring Steam Deck (late, user-dependent)", _late_deck_fn()),
        ("Configuring SSH access", configure_ssh),
        ("Configuring Tailscale", configure_tailscale),
        ("Configuring DNS resolver", configure_dns),
        ("Clearing provisioning state (disarm first-boot OOBE)", _clear_provisioning_fn()),
        ("Validating boot setup", by_name["Validating boot setup"]),
        ("Syncing disks", _sync_fn()),
        ("Creating factory snapshot", by_name["Creating factory snapshot"]),
    ]


def _keep_target_pacman_conf(user_finalizer) -> Callable:
    """Run upstream's user finalizer without letting it leave the INSTALLER's
    pacman.conf on the target.

    run_chroot_finalizer goes through phases_impl._prepare_target_setup, which
    copies the live ISO's offline-only /etc/pacman.conf ([offline], file://
    on the installer's mirror) into the target so the chroot can install
    offline. In upstream's single pass that happens once, BEFORE
    omarchy-setup-system writes the real configuration. The late stage is a
    separate process, so it copies again AFTER -- and nothing rewrites it:
    QEMU installs came out with a system whose only repo is a mirror that
    vanishes with the USB stick (the in-place Gaming opt-in failed on
    "Could not open file /var/cache/omarchy/mirror/offline/offline.db").
    The finalizer keeps its offline config while it runs; the target's own
    file is restored byte for byte afterwards and read back."""

    def finalize_user(ctx) -> None:
        conf = Path(ctx.target) / "etc/pacman.conf"
        try:
            before = conf.read_bytes()
        except OSError as exc:
            raise RuntimeError(f"cannot read the target's /etc/pacman.conf before user finalization: {exc}") from exc
        try:
            user_finalizer(ctx)
        finally:
            conf.write_bytes(before)
        if conf.read_bytes() != before:
            raise RuntimeError("the target's /etc/pacman.conf did not read back as restored after user finalization")

    return finalize_user


def select_phases(ctx, phases_impl, full) -> list:
    """The phase list for the requested stage.

    ``full`` is upstream's list, built by the caller; it is returned
    untouched (same objects, same order) when the stage is ``full``.
    ``early``/``late`` return the slice. Unknown stages fail loudly.
    """
    stage = stage_name()
    if stage == STAGE_FULL:
        return list(full)
    if stage == STAGE_EARLY:
        return early_phases(ctx, phases_impl, full)
    return late_phases(ctx, phases_impl, full)


def _early_deck_fn(deck_steps: dict[str, Callable]) -> Callable:
    missing = [name for name in EARLY_DECK_STEPS if name not in deck_steps]
    if missing:
        raise RuntimeError(
            "early Deck slice needs steps missing from deck_configure.deck_steps: "
            + ", ".join(missing)
        )
    fns = [deck_steps[name] for name in EARLY_DECK_STEPS]

    def configure_deck_early(ctx) -> None:
        from . import deck_configure

        failures: list[str] = []
        for name, fn in zip(EARLY_DECK_STEPS, fns, strict=True):
            try:
                fn(ctx)
            except Exception as exc:  # noqa: BLE001 -- per-step report, like configure_deck
                detail = deck_configure.sanitize_text(f"{type(exc).__name__}: {exc}")
                record_result(ctx.target, name, {"status": "error", "error": detail})
                if _step_is_critical(name):
                    failures.append(name)
        if failures:
            raise RuntimeError(
                "required Deck configuration steps failed: " + ", ".join(failures)
            )

    configure_deck_early.__name__ = "configure_deck_early"
    return configure_deck_early


def _late_deck_fn() -> Callable:
    """User-dependent Deck work, branched on the frozen gaming answer.

    Gaming=yes runs the late registry steps (autologin + full session bake)
    and applies the preinstalls-no marker/removal when preinstalls=no.
    Gaming=no skips autologin and Steam entirely, bakes the desktop-only
    stage subset, writes the password greeter, and applies the preinstalls-no
    state all the same. Desktop login must remain safe on every failure here:
    nothing raises except a failed critical step (autologin, gaming=yes).
    """

    def configure_deck_late(ctx) -> None:
        from . import deck_choices
        from . import deck_configure
        from . import deck_install_identity as identity
        from . import deck_variant_packages as variants

        steps = _deck_step_map()
        missing = [name for name in LATE_DECK_STEPS if name not in steps]
        if missing:
            raise RuntimeError(
                "late Deck slice needs steps missing from deck_configure.deck_steps: "
                + ", ".join(missing)
            )
        preinstalls, gaming = deck_choices.read_choices()
        failures: list[str] = []
        if gaming:
            for name in LATE_DECK_STEPS:
                try:
                    steps[name](ctx)
                except Exception as exc:  # noqa: BLE001 -- report shape matches configure_deck
                    detail = deck_configure.sanitize_text(f"{type(exc).__name__}: {exc}")
                    record_result(ctx.target, name, {"status": "error", "error": detail})
                    if _step_is_critical(name):
                        failures.append(name)
            if failures:
                raise RuntimeError(
                    "required Deck configuration steps failed: " + ", ".join(failures)
                )
        else:
            # Desktop-only: no autologin, no Steam session switch. Bake the
            # desktop subset (mapper/lizard/OSK/greeter/power), point SDDM at
            # the Omarchy desktop session with no autologin, and prove the
            # session file exists -- a desktop greeter naming a missing
            # session is a login loop with no controller escape. The
            # registry step takes no flag (it is shared with gaming=yes);
            # call the underlying baker with desktop_only instead.
            from . import deck_session_bake as _bake_mod

            bake_record = _bake_mod.bake_session(ctx, desktop_only=True)
            deck_configure_record(ctx.target, "session_bake", bake_record)
            if bake_record.get("status") != "baked":
                raise RuntimeError(
                    "desktop-only session bake reported status="
                    f"{bake_record.get('status')}: "
                    f"{bake_record.get('error') or 'see session_bake record'}"
                )
            _assert_desktop_session(ctx.target)
            identity.configure_desktop_greeter(ctx.target, ctx.username)
        if not preinstalls:
            # preinstalls=no on EITHER gaming path: wrappers were generated by
            # provision-user, so remove them with the canonical tools; the
            # marker (written next) is what surfaces Install > Preinstalls.
            # preinstalls=yes needs no removal -- the delta installed the 13.
            removal = variants.apply_preinstalls_removal(ctx.target, ctx.username)
            deck_configure_record(ctx.target, "preinstalls_removal", removal)
            if removal.get("status") != "ok":
                raise RuntimeError(
                    "preinstalls=no removal reported status="
                    f"{removal.get('status')}: "
                    f"{removal.get('error') or 'see preinstalls_removal record'}"
                )
        identity.apply_preinstalls_choice(ctx.target, _final_home(ctx), preinstalls)

    configure_deck_late.__name__ = "configure_deck_late"
    return configure_deck_late


def _final_home(ctx) -> str:
    return f"/home/{ctx.username}"


def _assert_desktop_session(target) -> None:
    """The Omarchy desktop session must exist where SDDM reads it.

    Runs after the desktop bake and before the greeter is written: a greeter
    naming a missing session is a login loop with no controller escape, and
    the desktop bake's ``--skip-session-probes`` must never be the thing that
    "proves" the session exists.
    """
    from . import deck_install_identity as _identity

    target = Path(target)
    found = _identity._find_desktop_session(target)
    if found is None:
        raise RuntimeError(
            "no Omarchy desktop session file (omarchy.desktop in "
            + " or ".join("/" + d for d in _identity.DESKTOP_SESSION_DIRS)
            + ") on the target; refusing a desktop greeter with no session"
        )


def _step_is_critical(name: str) -> bool:
    from . import deck_configure

    for step in deck_configure.deck_steps():
        if step.name == name:
            return bool(step.critical)
    raise RuntimeError(
        f"Deck step {name!r} vanished from deck_configure.deck_steps between "
        "selection and execution; refusing to guess whether it is critical"
    )


def record_result(target, key: str, value) -> Path:
    from . import deck_configure

    return deck_configure.record_result(target, key, value)


def deck_configure_record(target, key: str, value) -> Path:
    from . import deck_configure

    return deck_configure.record_result(target, key, value)


def _choices_gate_fn() -> Callable:
    """Wait for the form's locked answers after the common restore.

    The restore never blocks on the form; this gate does. ``preinstalls``
    is immutable from here on; ``gaming`` is returned as answered now but is
    re-read at every later gaming gate (it may still flip yes→no until
    online work starts).
    """

    def wait_for_choices(ctx) -> None:
        from . import deck_choices
        from .ui import info

        preinstalls, gaming = deck_choices.wait_locked()
        deck_configure_record(
            ctx.target,
            "variant_choices",
            {"preinstalls": "yes" if preinstalls else "no", "gaming": "yes" if gaming else "no"},
        )
        info(
            "Installer variant locked: preinstalls="
            + ("yes" if preinstalls else "no")
            + " gaming="
            + ("yes" if gaming else "no")
        )

    wait_for_choices.__name__ = "wait_for_choices"
    return wait_for_choices


def _variant_delta_fn(kind: str) -> Callable:
    """Install one offline variant delta before UKI finalization.

    Preinstalls are fixed when choices lock. Gaming packages must wait until
    after the Wi-Fi screen: B can reverse gaming yes→no while network is
    pending, and a reversed install must not retain Gaming Mode packages.
    """
    if kind not in ("preinstalls", "gaming"):
        raise ValueError(f"unknown variant delta: {kind}")

    def install_variant_delta(ctx) -> None:
        from . import deck_choices
        from . import deck_variant_packages as variants

        preinstalls, gaming = deck_choices.read_choices()
        record = variants.install_variant_delta(
            ctx.target,
            preinstalls if kind == "preinstalls" else False,
            gaming if kind == "gaming" else False,
        )
        key = "variant_delta" if kind == "preinstalls" else "gaming_delta"
        deck_configure_record(ctx.target, key, record)
        if record.get("status") != "ok":
            raise RuntimeError(
                f"{kind} package delta reported status={record.get('status')}: "
                f"{record.get('error') or f'see {key} record'}"
            )

    install_variant_delta.__name__ = f"install_{kind}_delta"
    return install_variant_delta


def _network_gate_fn() -> Callable:
    """Wait for the form's network signal -- gaming=yes only.

    Gaming=no returns immediately: nothing online follows, so waiting would
    stall a desktop-only install on a network it will never use. Gaming=yes
    blocks until ``network-ready`` (the form holds its network screen until
    connected or B-back, and deletes the marker on a yes→no reversal, which
    this loop observes by re-reading the gaming answer). ``early/skip-online``
    releases the wait when late is already waiting; the fetch then classifies
    the dead network itself and gaming=yes fails loudly there. Expiry raises:
    gaming=yes promised working Gaming Mode, and proceeding offline would
    silently produce the black screen the contract bans.
    """

    def wait_for_network(ctx) -> None:
        import time

        from . import deck_choices
        from .ui import info

        _ = ctx
        if not deck_choices.read_gaming():
            info("Network gate skipped (gaming=no -- fully offline install)")
            return
        run_dir = _run_dir()
        ready = run_dir / "network-ready"
        skip = run_dir / "early" / "skip-online"
        try:
            budget = int(
                os.environ.get(NETWORK_WAIT_SECS_ENV, str(NETWORK_WAIT_DEFAULT_SECS))
            )
        except ValueError as exc:
            raise RuntimeError(
                f"{NETWORK_WAIT_SECS_ENV} is not an integer; refusing to guess the network wait"
            ) from exc
        waited = 0
        while waited < budget:
            if not deck_choices.read_gaming():
                # The user flipped gaming yes→no at the Wi-Fi screen; the
                # form deleted network-ready. The desktop-only path needs no
                # network -- stop waiting instead of stalling on a marker that
                # will never come.
                info("Gaming choice flipped to no while waiting; continuing offline")
                return
            if ready.exists() or skip.exists():
                info(
                    "Network gate open (network-ready)"
                    if ready.exists()
                    else "Network gate released by late stage (skip-online)"
                )
                return
            time.sleep(NETWORK_POLL_SECS)
            waited += NETWORK_POLL_SECS
        raise RuntimeError(
            f"gaming=yes but no network signal after {budget}s; refusing to "
            "produce a Gaming Mode install without Steam"
        )

    wait_for_network.__name__ = "wait_for_network"
    return wait_for_network


def _pkgs_fetch_fn() -> Callable:
    """Install the Steam launcher online -- gaming=yes only, fail loudly.

    Gaming=yes promised working Gaming Mode: ``skipped-no-network`` and any
    other non-installed outcome fails the install (with a retry path at S5/
    late) instead of quietly shipping a machine whose Gaming Mode is a black
    screen. Gaming=no skips the transaction entirely and records why. The
    legacy full path keeps the old critical=False registry step untouched.
    """

    def install_steam_package(ctx) -> None:
        from . import deck_choices
        from . import deck_pkgs
        from .ui import info

        if not deck_choices.read_gaming():
            record = {"status": "skipped-no-gaming", "error": None, "warnings": []}
            deck_configure_record(ctx.target, "pkgs", record)
            info("Steam launcher fetch skipped (gaming=no)")
            return
        if not deck_choices.read_gaming():
            raise RuntimeError("gaming answer changed mid-fetch; refusing to continue")
        record = deck_pkgs.fetch_packages(ctx.target)
        deck_configure_record(ctx.target, "pkgs", record)
        status = record.get("status")
        # deck_pkgs statuses: installed | skipped-no-network | failed.
        # Gaming=yes requires the network by contract: every non-installed
        # outcome fails loudly here.
        if status != "installed":
            raise RuntimeError(
                f"Steam launcher fetch reported status={status}: "
                f"{record.get('error') or 'see pkgs record'}"
            )

    install_steam_package.__name__ = "install_steam_package"
    return install_steam_package


def _limine_fn(phases_impl) -> Callable:
    return _require(phases_impl, "finalize_limine_boot")


def _keyring_join_fn(phases_impl) -> Callable:
    def join_target_keyring(ctx) -> None:
        join = getattr(phases_impl, "_join_target_keyring_init", None)
        if join is None:
            raise RuntimeError(
                "orchestrator phases_impl has no _join_target_keyring_init; "
                "upstream renamed the keyring join this stage depends on"
            )
        join(ctx)

    join_target_keyring.__name__ = "join_target_keyring"
    return join_target_keyring


def _late_steam_fn() -> Callable:
    """Relocate the staging home -- gaming=yes only, fail loudly.

    Gaming=yes requires the client manifest after the fetch: a missing
    staging tree or a failed relocation fails the install instead of
    shipping a Gaming Mode that downloads on first boot. Gaming=no records
    ``skipped-no-gaming`` without touching Steam at all.
    """

    def relocate_steam_home(ctx) -> None:
        from . import deck_choices
        from . import deck_steam_bootstrap as steam
        from .ui import info

        if not deck_choices.read_gaming():
            deck_configure_record(
                ctx.target,
                "steam_relocate",
                {"status": "skipped-no-gaming", "error": None, "warnings": []},
            )
            info("Steam staging-home relocation skipped (gaming=no)")
            return
        final_home = f"/home/{ctx.username}"
        record = steam.late_steam(
            ctx.target, steam.STAGING_HOME_ABS, final_home, ctx.username, ctx
        )
        deck_configure_record(ctx.target, "steam_relocate", record)
        status = record.get("status")
        if status not in (steam.LATE_STATUS_RELOCATED, steam.LATE_STATUS_NO_STAGING):
            raise RuntimeError(
                f"Steam staging-home relocation reported status={status}: "
                f"{record.get('error') or 'see steam_relocate record'}"
            )
        if status == steam.LATE_STATUS_NO_STAGING:
            raise RuntimeError(
                "gaming=yes but the early stage produced no Steam staging home; "
                "refusing to ship Gaming Mode without its client"
            )

    relocate_steam_home.__name__ = "relocate_steam_home"
    return relocate_steam_home


def _steam_fetch_fn() -> Callable:
    """Bootstrap Valve's client into the staging home -- gaming=yes only.

    The outcome assertion is the installed manifest, exactly as the legacy
    step does: gaming=yes with no manifest after the fetch fails loudly.
    Gaming=no records ``skipped-no-gaming`` and writes the shared steam
    state as skipped so S5 shows the choice honestly instead of "unknown".
    """

    def fetch_steam_client(ctx) -> None:
        from . import deck_choices
        from . import deck_steam_bootstrap as steam
        from .ui import info

        if not deck_choices.read_gaming():
            deck_configure_record(
                ctx.target,
                "steam_bootstrap",
                {"status": "skipped-no-gaming", "error": None, "warnings": []},
            )
            steam.write_steam_state(
                steam.LIVE_ROOT, steam.STEAM_STATE_SKIPPED, "gaming=no -- desktop-only install"
            )
            info("Steam client fetch skipped (gaming=no)")
            return
        record = steam.early_steam_fetch_only(
            ctx.target,
            steam.STAGING_HOME_ABS,
            steam.STAGING_UID,
            steam.STAGING_GID,
        )
        deck_configure_record(ctx.target, "steam_bootstrap", record)
        status = record.get("status")
        markers = record.get("markers_after") or []
        if status not in (steam.STATUS_INSTALLED, steam.STATUS_ALREADY) or not markers:
            raise RuntimeError(
                f"gaming=yes but the Steam client fetch ended with status={status} "
                f"and markers={markers or 'none'}: "
                f"{record.get('error') or 'see steam_bootstrap record'}"
            )

    fetch_steam_client.__name__ = "fetch_steam_client"
    return fetch_steam_client


def _kernel_assert_fn() -> Callable:
    def assert_deck_kernel(ctx) -> None:
        from . import deck_install_identity as identity

        identity.assert_deck_kernel(ctx.target)

    assert_deck_kernel.__name__ = "assert_deck_kernel"
    return assert_deck_kernel


def _identity_fn() -> Callable:
    def apply_identity(ctx) -> None:
        from . import deck_install_identity as identity

        identity.apply_identity(ctx)

    apply_identity.__name__ = "apply_identity"
    return apply_identity


def _create_user_fn() -> Callable:
    def create_user(ctx) -> None:
        from . import deck_install_identity as identity

        identity.create_user(ctx)

    create_user.__name__ = "create_user"
    return create_user


def _variant_record_fn() -> Callable:
    """Write the variant marker + install record for late and the desktop.

    ``/var/lib/omarchy-deck/variant`` (``gaming=``/``preinstalls=`` lines)
    is what Steam's ``omarchy-deck-enable-gaming`` gates on when present;
    ``gaming_choice`` in the install record carries the same facts for QEMU
    assertions. Written before any gaming-conditional late work so a later
    failure still leaves the variant legible.
    """

    def record_variant(ctx) -> None:
        from . import deck_choices
        from . import deck_install_identity as identity

        preinstalls, gaming = deck_choices.read_choices()
        identity.write_variant_marker(ctx.target, preinstalls, gaming)
        deck_configure_record(
            ctx.target,
            "gaming_choice",
            {"gaming": "yes" if gaming else "no", "preinstalls": "yes" if preinstalls else "no"},
        )

    record_variant.__name__ = "record_variant"
    return record_variant


def _clear_provisioning_fn() -> Callable:
    def clear_provisioning_state(ctx) -> None:
        # Late always installs with a real user, so first-boot provisioning
        # must never fire: remove the pending marker AND the OOBE service
        # enablement unconditionally. A stale enablement without the marker
        # (or vice versa) is the user-less brick Main named; leaving either
        # behind because "the binary exists" would be exactly that.
        pending = Path(ctx.target) / "var/lib/omarchy/provisioning/pending"
        try:
            pending.unlink(missing_ok=True)
        except OSError as exc:
            raise RuntimeError(f"could not clear first-boot provisioning state: {exc}") from exc
        wants = (
            Path(ctx.target)
            / "etc/systemd/system/multi-user.target.wants/omarchy-provision-owner.service"
        )
        unit = Path(ctx.target) / "etc/systemd/system/omarchy-provision-owner.service"
        try:
            wants.unlink(missing_ok=True)
            if unit.is_symlink() or unit.is_file():
                unit.unlink()
        except OSError as exc:
            raise RuntimeError(f"could not disarm first-boot provisioning: {exc}") from exc

    clear_provisioning_state.__name__ = "clear_provisioning_state"
    return clear_provisioning_state


def _sync_fn() -> Callable:
    def sync_disks(ctx) -> None:
        import subprocess

        _ = ctx
        subprocess.run(["sync"], check=True)

    sync_disks.__name__ = "sync_disks"
    return sync_disks

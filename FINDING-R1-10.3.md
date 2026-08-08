# FINDING R1 §10.3 — Should the gamepad→input mapping layer ship permanently?

**Result: PARTIAL.** Both candidate designs prepared concretely from
documentation/research. **Not decided** — this requires physical Deck
hardware and must not be attempted here (per operator instruction and
CLAUDE.md's testing-tier rule: session switching and gamescope behavior are
physical-Deck-only test items).

## Hypothesis (PLAN.md §10.3)

Ship the mapping layer, scoped to Desktop Mode only, but the specific design
is open between two options:

- **(a)** Run Steam in the background during the Omarchy desktop session and
  inherit its desktop controller layout + on-screen keyboard (OSK) for free.
- **(b)** Ship the custom mapper (the T2 `uinput`/`evdev` daemon) as a
  systemd user service, active only in the desktop session.

## Design (a): background Steam, prepared for testing

**Mechanism.** In stock SteamOS Desktop Mode, the Steam client itself is
running (not just Gaming Mode's gamescope session), and Steam Input applies
a built-in **"Desktop" controller configuration template** whenever no game
has input focus. This is what gives stock Desktop Mode trackpad-as-mouse and
an automatic on-screen keyboard on text-field focus — it isn't a separate
subsystem, it's Steam Input's default desktop layout, active as long as the
Steam client process is alive and a controller is attached.

**How to reproduce this in an Omarchy/Hyprland session:**
- Add `steam -silent` (suppresses the main Steam window, keeps the client
  and Steam Input running in the background/tray) to Hyprland's autostart
  (Omarchy's `~/.config/hypr/autostart.conf` convention, or a `.desktop`
  autostart file).
- Steam Input's desktop layout is controlled by the per-user
  `~/.steam/steam/config/config.vdf` + the controller's "Desktop Controller
  Layout" — no extra config should be needed since Deck's controller has
  Steam Input enabled by default for the Deck controller type.
- The OSK is Steam's own `steamwebhelper`-based keyboard; it triggers on
  detected text-field focus.

**Known unknowns that require hardware:**
1. Whether `-silent` still initializes the desktop Steam Input layout when
   launched from a non-gamescope compositor (Hyprland) rather than SteamOS's
   own Plasma desktop session — this codepath may assume gamescope/Plasma
   session context.
2. Whether the OSK correctly detects focus in native Wayland apps vs
   XWayland apps under Hyprland (Steam's OSK has known Wayland-focus quirks
   outside SteamOS's own compositor).
3. Battery/RAM cost of a backgrounded full Steam client during every desktop
   session, and whether it interferes with Gaming Mode's own Steam instance
   on session switch (single Steam client, two sessions — needs verifying
   there's no lock-file/singleton conflict).
4. Whether it conflicts with the T2 install-time mapper if that process is
   still running when Desktop Mode starts.

**Trade-off as designed:** less code, more SteamOS-faithful, but depends on
undocumented Steam Input internals behaving the same outside gamescope, and
carries the overhead/complexity of running the full Steam client during
every desktop session.

## Design (b): custom mapper as a systemd user service, prepared for testing

**Mechanism.** Adapt the T2 spike's mapper (`uinput`-created virtual
keyboard/mouse device, fed by `python-evdev` reading the Deck controller) as
a long-running systemd `--user` service, started only by the Hyprland/Desktop
session's own systemd target — never by Gaming Mode's gamescope session —
so scoping is enforced by *which target starts it*, not a runtime check.

**Draft unit** (`~/.config/systemd/user/deck-input-mapper.service`):

```ini
[Unit]
Description=Deck gamepad-to-desktop input mapper (Desktop Mode only)
PartOf=graphical-session.target
After=graphical-session.target

[Service]
Type=simple
ExecStart=%h/.local/bin/deck-input-mapper
Restart=on-failure

[Install]
WantedBy=hyprland-session.target
```

- `WantedBy=hyprland-session.target` (not the generic
  `graphical-session.target`) is the actual scoping mechanism: Omarchy
  launches Hyprland via `uwsm`, which exposes a Hyprland-specific systemd
  target distinct from whatever starts the gamescope Gaming Mode session.
  **Needs hardware confirmation** that `hyprland-session.target` (or
  whatever uwsm names it on this Quattro build) exists and is *not* also
  reached from the gamescope session.
- `/dev/uinput` access: default permissions are root-only. Needs either a
  udev rule granting the `input` group write access plus
  `SupplementaryGroups=input` on the unit, or an equivalent polkit rule.
  This permission wiring is untested and should be the first thing a
  hardware session validates — if it doesn't work non-root, design (b)'s
  "doesn't require Steam running" advantage is undercut by needing a
  privileged helper instead.
- **OSK is not free here** — design (b) doesn't inherit Steam's built-in
  keyboard. Reuse `wvkbd` or `squeekboard`, both of which support the
  `wlr-input-method` Wayland protocol that wlroots compositors (Hyprland
  included) implement, so focus-triggered popup should be possible without
  bespoke integration — but this is unverified and is the biggest open
  question for design (b).

**Trade-off as designed:** more predictable, doesn't require the Steam
client running, but is more code to own (mapper + OSK + udev rule +
wlr-input-method wiring), and duplicates behavior Steam already provides
for free in design (a).

## What a hardware test session needs to do to decide

1. Boot into Omarchy Desktop Mode on the Deck.
2. **Test (a):** add `steam -silent` to Hyprland autostart, reboot into
   Desktop Mode, and check: controller-as-trackpad works, OSK appears on
   text-field focus in both a native Wayland app and an XWayland app,
   measure idle RAM/battery delta with Steam backgrounded, and confirm no
   conflict switching back to Gaming Mode's own Steam instance.
3. **Test (b):** install the T2 mapper as the systemd user service above,
   confirm it starts only in the Hyprland session and never under
   gamescope, confirm `/dev/uinput` access works without running as root,
   wire up `wvkbd`/`squeekboard` via `wlr-input-method` and test
   focus-triggered popup.
4. Compare on: reliability, input latency, resource/battery cost, code
   surface to maintain long-term, and whether either breaks Gaming Mode
   session switching.
5. Record the decision by superseding this file with a resolved finding —
   this file should be treated as scaffolding for that session, not a final
   answer.

Both designs above are prepared so this comparison can start immediately on
hardware rather than needing setup work first. No physical Deck access was
used or attempted to produce this finding.

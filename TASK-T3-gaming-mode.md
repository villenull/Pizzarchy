# T3 — Gaming Mode, Desktop Mode, and hardware parity

**Model: Sonnet for the session/switch mechanics. Opus for TDP/fan/sysfs
logic specifically** — bad hardware-control code risks the operator's only
device.

**Status: in progress.** The session layer exists (`deck-session.sh`); Gaming
Mode has booted once on the Deck. Hardware parity is untouched.

## Objective

A Deck that boots into Gaming Mode by default, with all hardware working as
it does on stock SteamOS, and a two-way switch to an Omarchy desktop that's
reachable by controller alone.

## Prerequisites

- T0 done — `deck-sync.sh` is where this task's iteration speed comes from
- T1 done — Neptune kernel booting

## ⚠️ The starting point in `PLAN.md` §6.4 is obsolete — read this instead

`PLAN.md` §6.4 and §5 say to fork `28allday/Super-Shift-S-Omarchy-Deck-Mode`
because "it solves the hard part." **Three things changed:**

1. **That repo was renamed twice and is superseded** by `28allday/deckshift`.
2. **Both are unlicensed** — no right to fork, modify or redistribute. The
   instruction is not legally executable as written.
3. **The hard part is already solved by Valve.** `jupiter-staging/gamescope`
   ships the *entire* SteamOS Gaming Mode session — `gamescope-session.target`
   and its whole unit graph, `start-gamescope-session`,
   `/usr/lib/steamos/gamescope-session`, the `gamescope-wayland.desktop`
   session entry, plus `steam-launcher`, `ibus-gamescope`,
   `steam-notif-daemon`, `gamescope-mangoapp` and **`galileo-mura-setup`**
   (OLED mura correction — Deck-specific and not obtainable elsewhere).

**So this project does not build a session and does not fork one.** It builds
the *switch*. See `PROGRESS.md` §4 and `FINDING-deckshift-hybrid.md`.

Read DeckShift as a reference design if useful. Do not vendor it.

## Steps

### 1. ✅ The switch layer — `deck-session.sh`

Done, with two bugs from its first version fixed (`PROGRESS.md` §4.2). Four
stages, idempotent, independently runnable:

| Stage | What it does |
|---|---|
| `stage-preconditions` | Deck DMI gate, SDDM present, Valve's session present, desktop session discovered |
| `stage-session-select` | `/usr/local/bin/deck-session-select` + a narrowly-scoped sudoers grant |
| `stage-steam-hook` | `/usr/local/bin/steamos-session-select` — **the one piece in no configured repo** |
| `stage-return-icon` | `/usr/share/applications/deck-return-to-gaming.desktop` |

`stage-default-session` exists but is **deliberately outside** the default run:
flipping the default is the one step that, if Gaming Mode fails to start, leaves
no graphical way back under autologin. Run it only once both directions are
proven.

**Why `steamos-session-select` matters:** Steam's "Power → Switch to Desktop"
shells out to it *by name*. It lives in SteamOS's `steamos-customizations`,
which is in no repo configured here (verified with `pacman -F` across all six).
Without it, Steam's own affordance **silently does nothing** — `PLAN.md` §8.1's
failure mode, in the one place a controller-only user cannot work around it.

### 2. ~~Remove DeckShift from the test Deck~~ — superseded by the rebuild

The Deck currently runs a DeckShift hybrid (hand-edit at
`/usr/local/bin/gamescope-session-nm-wrapper:163`, plus five other modified
files — inventory in `FINDING-deckshift-hybrid.md`). **The phase-1 rebuild
(`ROADMAP.md` P1.5) wipes all of it** — no manual unwind, and the `/tmp`
backups stop mattering (`PROGRESS.md` §2.5).

Until that session runs, treat the Deck's current session config as
known-contaminated: findings gathered on it about session switching do not
transfer to the clean install.

### 3. Prove both directions on hardware — the actual gate

Only one of these has any evidence, and that evidence was gathered with the
DeckShift hybrid in place, so it does not transfer.

- [ ] `steamos-session-select gamescope` reaches Gaming Mode
- [ ] Controller input works **in** Gaming Mode
- [ ] Audio works in Gaming Mode
- [ ] Steam's Power menu lists "Switch to Desktop" **and it functions** —
      this is the controller-only path out, and the one that exercises the shim
- [ ] The desktop-side return icon works
- [ ] Both directions survive a reboot in each state

**Do not record "the button was present" as "the button works."** That
distinction already cost this project a false pass once.

### 4. Desktop-mode input mapper (R1 §10.3 design (b))

Ship the `uinput`/`evdev` mapper as a systemd `--user` service. All
preconditions are hardware-proven (`FINDING-R1-10.3.md`). Two traps already
found and corrected there:

- `WantedBy=` must be `wayland-session@hyprland.desktop.target`. The obvious
  `hyprland-session.target` **does not exist**, and a unit wanted by a
  nonexistent target enables without error and never starts.
- **The install must add the user to the `input` group.** `uaccess` does not
  cover `/dev/uinput`, and `SupplementaryGroups=` is not permitted in a
  `--user` unit.

Use `squeekboard` (Arch `extra`) for the OSK, not `wvkbd` (AUR-only).

Shares an implementation with T2's mapper — build once, scope twice.

### 5. Deck hardware tuning — Opus, and hardware-safety-sensitive

Work `PLAN.md` §6.5's parity table. Iterate with `deck-sync.sh` — **never
reinstall to test these**.

| Item | Notes |
|---|---|
| TDP / CPU governor | Via jupiter-staging sysfs. **Ask before running on hardware.** |
| Fan curve | Same caution. A bad fan curve is a thermal risk. |
| GPU (RDNA2) | Confirm gamescope build flags, RADV working |
| Wi-Fi | OLED radio differs from LCD. See also `PROGRESS.md` §5.1 — the *live ISO* case is separate and unverified |
| Bluetooth | Controller + audio pairing with no manual setup |
| Speakers / haptics | `cs35l41-dsp1-*` warnings **no longer appear** on current firmware — treat a reappearance as a real finding |
| Trackpads / gyro | Both sessions. Gyro-as-mouse in desktop specifically. |
| Battery | Accurate %, charge limit option |
| Display | Refresh rate, HDR (OLED). Valve's session already handles HDR/VRR |
| Buttons | Steam/QAM/Power in both sessions |

Record pass/fail plus the fix in `FINDING-hardware-parity.md`. That doc is the
LCD-support roadmap later.

### 6. Shell integration — Omarchy 4.0

Deferred until there is a 4.0 test target (`PROGRESS.md` §2.3, §6). Two items,
and only these two are version-sensitive:

- Pinning the return icon to Quattro's Quickshell bar/dock
- The Gaming Mode → Desktop trigger's placement in Steam's Quick Access Menu

Everything above is shell-agnostic by design — the return icon is a plain
`.desktop` file, which every launcher on every shell reads.

## Done when

- [ ] Fresh boot lands in Gaming Mode without intervention
- [ ] Steam → Power → Switch to Desktop reaches Omarchy, controller only
- [ ] An icon in Omarchy returns to Gaming Mode, controller only
- [ ] Both directions survive a reboot in each state
- [ ] DeckShift is gone from the test Deck and nothing regressed
- [ ] Input mapper running in the desktop session, OSK popping on focus
- [ ] Every row in the parity table has a recorded result
- [ ] `FINDING-hardware-parity.md` complete for OLED, LCD rows marked untested

## Failure modes to watch for

- **Testing by reinstalling.** All of this is post-install config.
- **Claiming LCD support.** You have no LCD to test on. Say so.
- **Session-switch black screens.** Check `journalctl --user -u 'gamescope-session*'`
  and `journalctl -b -1` first. `Ctrl+Alt+F2` reaches a TTY.
- **Recording "present" as "works."** See step 3.

## Escalate if

- Anything requires writing to the Deck (most of this does — batch the
  requests and describe exactly what will run)
- TDP/fan work is about to touch hardware — always ask, every time

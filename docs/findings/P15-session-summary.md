# P1.5 session summary — 2026-08-10

One session, six phases, on the physical OLED Deck. **Phase 1 of the project
is now complete.** This is the short version; the evidence is in
`P15-live-iso-recon.md` (findings R-0 … R-19) and `P15-recon-raw/`.

---

## 1. What the hardware is

| Role | What |
|---|---|
| **Test device** | One **OLED Steam Deck** — DMI `Valve Galileo`, 512 GB NVMe, **QCA2066** Wi-Fi, BIOS F7G0114. The only verified hardware; LCD untested and unclaimed |
| **Dev machine** | `fbi-pc`, Arch/Omarchy, wired `192.168.100.14`. shellcheck + unit tests + QEMU suites |
| **Deck link** | `ssh steamdeck` → `192.168.100.25`, Wi-Fi, key-based, passwordless sudo |
| **Boot media** | One Kingston 115 GB stick: Ventoy 1.1.17 + the 6.4 GB Omarchy 4.0 ISO (sha256-verified on the stick) |

Two deviations from the runbook, agreed with the operator: **a single USB
stick** (recovery image downloaded but not flashed — reflash on demand) and
**Wi-Fi instead of Ethernet** for SSH, which worked from the live ISO onward.

## 2. What the Deck runs now

Package-based **Omarchy 4.0.0.r1617.g6d7826d** + **Neptune
6.11.11-valve29-1-neptune-611**, unencrypted, btrfs, Limine, booting
unattended into the desktop, with both session-switch directions working and
**zero DeckShift**. Snapshots: **#1** pre-Neptune, **#2** post-conversion,
**#3** complete.

## 3. Phases run

| Phase | Result |
|---|---|
| **B** live-ISO recon | §5.1 answered **yes**; rotation, input, model, offline mirror recorded. Deck untouched at checkpoint α |
| **C** wipe + install | Installed 4.0. **Caught the encryption default before rebooting**, re-ran the installer non-interactively with it off |
| **D** SSH + snapshots | `steamdeck` alias, NOPASSWD sudo, baseline snapshot. `deck-sync.sh` proven on hardware |
| **E** Neptune conversion | All ten stages exit 0; **checkpoint β passed** — unattended boot into Neptune |
| **F** session layer | Both directions proven; **found and fixed an autologin bug**; boots to Gaming Mode unattended |

## 4. Closed

| Issue | Outcome |
|---|---|
| **§5.1** live-ISO Wi-Fi — *the project's top unknown* | **YES.** Driver binds, scan, WPA2, DHCP. Retires T5's "bake firmware into the live image" work |
| **§5.2** stock→Neptune conversion | **Validated.** Seven of ten stages ran their real path for the first time; `LoaderEntrySelected` read from firmware after an unattended boot |
| **§5.3** test Deck ≠ target OS | **Resolved.** 3.8.4-from-git and the DeckShift hand-edits are gone |
| **§5.4** both T0 gaps | Ventoy executed; `deck-sync.sh` drove all 15 stages over SSH |

**Every phase-1 exit criterion is met.**

## 5. Opened — and this matters more than the closures

| # | Issue | Why it matters |
|---|---|---|
| **§5.10** | Steam's own **"Switch to Desktop" menu item unproven** | The half of the core promise a *user* touches. Our shim works; Steam's UI never offered the item |
| **§5.11** | **Rotation**: Limine menu, greeter and desktop all 90° off; only Gaming Mode correct | No kernel we ship corrects the panel. The Limine menu has **no known fix** and is seen first |
| **§5.12** | Installer **defaults to full-disk encryption** | Inherited, the ISO ships a device its owner cannot boot without a keyboard |
| **§5.13** | 🐞 `stage-repos` lets **Arch shadow Valve's packages** | `pacman -S gamescope` gets the bare compositor, not the SteamOS session. Conversion "succeeds" while Gaming Mode is unreachable |
| **§5.14** | `steamos-update` **exists in no reachable repo** | Gaming Mode greets users with a wrong "check your network" error |
| **§5.9** | **Lizard mode leaves the gamepad node silent** | `deck-input-mapper.py` selects by `BTN_SOUTH` — the dead node. Would block forever, succeeding silently |

### Four of these would have shipped as defects

§5.9, §5.12, §5.13 and §5.14 were all invisible to every cheaper test tier.
The T2 spike *structurally* could not have found §5.9 — it drove a virtual
uinput pad, which has no Valve firmware to divert the events. This is the
clearest argument the project has produced for why P1.5 had to happen on
hardware before phase 2, not after.

## 6. Code changed

- **`src/deck-session.sh` — autologin bug fixed.** The drop-in wrote
  `Session=` with no `User=`; SDDM applies `[Autologin]` only when both are
  present, so every switch landed on the greeter. The user is now resolved at
  **install** time (resolving it at switch time from `$SUDO_USER` could write
  `User=root` — a root graphical autologin), and both keys are verified on
  re-read. Proven on hardware in both directions.
- **`src/omarchy-deck-kernel.sh` — untouched.** §5.13 is real but its fix is a
  judgement call with wide blast radius; recorded, not guessed at.

## 7. Deliberately not done

- **§5.13 unfixed** — needs an overlap audit (`mesa`, `vulkan-radeon`,
  `lib32-vulkan-radeon`) before choosing between "Valve's repos first" and
  "explicit repo prefixes".
- **Rotation unfixed** — operator accepted it short-term; it is P2.4/T5 work.
- **Steam not signed in** — so §5.10 and §5.14 stay open.
- **Recovery USB not flashed** — single-stick deviation, accepted.

## 8. Housekeeping for the next session

- Passwordless sudo on the Deck is a **test-device posture**. It also *masks*
  `deck-session.sh`'s own sudoers verification, which reported honestly that it
  could not prove its narrow grant works. Revisit before shipping.
- A `pgrep -f <pattern>` in a shell whose own command line contains
  `<pattern>` matches itself and loops forever. Bit this session three times.
- Commit messages and `docs/PROGRESS.md` §7 carry the rest.

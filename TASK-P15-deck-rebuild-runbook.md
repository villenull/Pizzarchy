# P1.4–P1.5 — Deck recon + rebuild session runbook

**One session on the physical Deck that closes five open items at once**
(`ROADMAP.md` phase 1): the live-ISO Wi-Fi question (§5.1, top unknown),
live-environment recon (rotation, input), the 3.8.4→4.0 test-asset gap, the
first real hardware run of the stock→Neptune **conversion** path, and the
DeckShift hand-edit contamination (wiped, not unwound).

**Roles:** the agent drives everything reachable over SSH and captures its own
camera frames; the operator does only what needs hands — plugging, pressing
buttons at boot, and reading the one screen that exists before any comms
channel does. The phone-photo loop is the fallback of last resort, not the
plan.

---

## 1. The comms architecture — how the agent sees the Deck

Three channels, best-first. Set up A and B **before** touching the Deck.

### A. SSH — the primary channel (terminal-level, full control)

Once a shell on the Deck is reachable from the dev machine, the agent runs
every command itself: recon, the installer prep, `omarchy-deck-kernel.sh`,
`deck-session.sh`, journal reads, reboots. The operator watches.

- **Wired beats wireless here.** The whole point of the live-ISO phase is
  that Wi-Fi may NOT work (stock kernel, stock firmware). A USB-C→Ethernet
  adapter gives the live environment a network that works regardless of the
  Wi-Fi answer — USB Ethernet drivers are in every stock kernel.

- **Topology: put the Deck on the router, NOT directly into the PC.**
  Confirmed on this dev machine (2026-08-10):

  ```
  enp8s0   UP    192.168.100.14/24   <- the PC's ONLY working NIC, and its
                                        default route via 192.168.100.1
  wlan0    DOWN  (no carrier)
  ```

  A direct Deck→PC cable would occupy that single NIC, so **the PC loses
  internet and so does the Deck**. That breaks phase E outright: `stage-repos`
  and `stage-kernel` pull several hundred MB (`linux-neptune-*`, headers,
  `linux-firmware-neptune`, `steamdeck-dsp`) from Valve's mirror.

  Instead: plug the Deck's USB-Ethernet adapter into a free port on the same
  router/switch. Both land on `192.168.100.0/24` with DHCP, the PC keeps its
  internet, the Deck gets one, and SSH is zero-config. **This is a known-good
  configuration, not a guess** — the Deck previously ran at
  `192.168.100.26` on `enp4s0f3u1u3` (a USB-Ethernet adapter) on this exact
  network. A cheap 5-port switch covers a router with no free port.

- **Fallback, only if a second port is impossible:** bring `wlan0` up on the
  PC for internet, static-IP the direct link (`ip addr add 10.42.0.1/24 dev
  enp8s0` / `10.42.0.2/24` on the Deck), and NAT the Deck through the PC
  (`iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE`; `ip_forward` is
  already 1 here). Works, but three moving parts instead of zero.

- **USB-C device-mode networking (Deck as USB gadget): not supported
  reliably — don't burn session time on it.** The adapter path is cheap and
  certain.

- The dev machine's public key is at `~/.ssh/id_ed25519.pub`; the agent
  stages an `authorized_keys` line so password entry happens at most once.

### B. Camera — for everything SSH cannot see

BIOS boot picker, the Limine menu, a black screen, the installer before
networking is up. **The agent captures frames itself** from the dev machine —
no phone involved:

```
ffmpeg -f v4l2 -i /dev/video0 -frames:v 1 -y /tmp/deck-shot.jpg
```

…then reads the image. Any of these works, best-first:

1. **HDMI capture stick** (~$15 USB dongle) on the dock's HDMI out —
   pixel-perfect, sees firmware screens, and stays useful for all of phase 2
   (gamescope, session switching). If one is obtainable before the session,
   it is worth it.
2. **Any USB webcam** pointed at the Deck's screen on a stand. Kill glare
   (angle it slightly), max screen brightness.
3. **A phone as webcam** feeding the PC (most phones do USB/IP webcam now) —
   same effect, still no manual photo loop.

`ffmpeg` and `v4l2-ctl` are already installed on the dev machine.

### C. The operator's eyes + keyboard — the bootstrap channel

Physically at the Deck, this chat open on the PC next to it. **Do the whole
session at the desk with the Deck docked beside the PC** — never in another
room. Needed for: the boot-device picker (Vol− + Power), typing the 3–4
commands that bring SSH up in the live ISO, and confirming what a camera
frame can't resolve.

### Troubleshooting protocol

- Every step below has an **expect** line. Matches → continue without
  asking. Doesn't match → stop, capture (SSH output or camera frame), assess.
- The agent batches physical requests ("plug X, then press Y, then tell me
  when the menu shows") rather than one press at a time.
- Worst case at any point: Valve recovery image → stock SteamOS. Approved,
  rehearsed below, and no state on the Deck is worth protecting once phase
  A's checklist is done.

---

## 2. Operator prep — before the session day

Hardware to have on hand:

- [ ] **USB keyboard** (US layout if possible — a mismatched layout silently
      corrupted commands during the original manual install, `-O` → `-0`)
- [ ] **USB-C→Ethernet adapter** (already owned — the Deck ran on one at
      `192.168.100.26`) plus a USB-C hub/dock so the keyboard fits too
- [ ] **A free port on the router/switch** that `enp8s0` uses, or a cheap
      5-port switch. ⚠️ Do **not** cable the Deck straight into the PC —
      see §1A
- [ ] **USB stick #1 (8 GB+): Ventoy** — becomes the ISO carrier
- [ ] **USB stick #2 (8 GB+): Valve recovery image** — the safety floor.
      Prepared BEFORE anything is wiped, not after something goes wrong.
- [ ] Optional but valuable: **HDMI capture stick or webcam** (§1B)
- [ ] **Anything personal off the Deck.** The wipe is total. Check
      `~/Documents`, browser profiles, game saves not in Steam cloud, SSH
      keys, anything in `~` worth keeping.
- [ ] Deck charged / on dock power.

Agent-side prep (done from the dev machine, before the session):

- [ ] Obtain the **Omarchy 4.0 beta ISO** — download if published, else
      build with `omarchy-iso` (a local build already works here; remember
      `--network host` for Docker on this machine)
- [ ] Download **Ventoy** release tarball + the **Valve recovery image**
- [ ] Stage the `authorized_keys` line and a paste-ready command block for
      the live-ISO SSH bring-up
- [ ] `sha256sum` both images; record in the session notes

USB prep (operator runs the two destructive commands, agent stages them and
confirms the device node from `lsblk` first — **wrong device node = wrong
disk wiped**):

```
sudo ./Ventoy2Disk.sh -i /dev/sdX        # stick #1 — then copy the ISO onto its data partition
```

```
bzcat steamdeck-recovery-*.img.bz2 | sudo dd of=/dev/sdY bs=4M status=progress conv=fsync   # stick #2
```

---

## 3. The session, phase by phase

### Phase B — live-ISO recon (nothing is written to the Deck yet)

1. Ventoy USB + keyboard + Ethernet in the dock. Hold **Vol− + Power** →
   boot picker → the USB. Pick the Omarchy ISO in Ventoy's menu.
   *Expect:* the ISO reaches a live environment (console or installer).
   **Whatever appears, camera-frame it — orientation is recon item #1.**
2. Operator, on the Deck keyboard (switch to a TTY with Ctrl+Alt+F2 if an
   installer UI is in the way; agent dictates exact keystrokes live):
   ```
   passwd                      # set any root password, used once
   systemctl start sshd
   ip -br addr                 # read out / camera-frame the ethernet IP
   ```
   *Expect:* the wired interface has a DHCP address within seconds.
3. **Agent takes over via `ssh root@<ip>`.** Recon checklist, all read-only:
   - **Wi-Fi (§5.1):** now *expected to work* — the ISO was inspected and
     ships `ath11k` firmware including a **`nfa765`** variant (QCNFA765, the
     OLED Deck's module), `board-2.bin`, the driver, and `iwd`. Confirm the
     binding: `dmesg | grep -i ath11k` (look for firmware load + a device
     name), `ip -br link` (does `wlan0` appear), `rfkill list`, then
     `iwctl station wlan0 scan` / `get-networks` and associate.
     **If it fails, capture the full `dmesg | grep -iE "ath11k|firmware"`** —
     the blobs are present, so a failure means a binding/PCI-ID problem, a
     materially different finding from "firmware missing".
   - **Rotation:** `cat /sys/class/graphics/fbcon/rotate`, camera frame of
     the physical screen, orientation of the installer UI if one started.
   - **Input:** `cat /proc/bus/input/devices` — what the controller looks
     like to the live kernel; `ls /dev/input/`. **This feeds the T2 mapper
     directly** (`FINDING-T2-gamepad-spike.md`): the spike used a virtual pad
     modelling the Linux gamepad ABI, so the Deck's real button codes and
     extra nodes (trackpads, IMU, back paddles) are what the mapping tables
     may need adjusting for. Save the whole file.
   - **Try the mapper for real, right there:** copy `deck-input-mapper.py`
     and `python-evdev` in, run it, and drive the live installer with the
     controller. That is the first end-to-end controller-drives-installer
     test on real hardware, and the ISO already ships `python3`.
   - **Environment:** `uname -r`, ISO version stamp, disk layout as the
     installer sees it (`lsblk`).
   - Save everything to the dev machine (`ssh … > recon/…`).
4. **Checkpoint α — the §5.1 verdict gets recorded now**, whatever it is.
   A "no" changes T5's design (firmware into the live image) but does NOT
   abort this session — the install proceeds over Ethernet.

### Phase C — wipe + install Omarchy 4.0

5. **Operator confirms the wipe out loud in chat. Nothing before this point
   has modified the Deck.** Then run the installer (keyboard, operator
   driving, agent watching via camera/SSH as available). Choices: wipe the
   internal NVMe, btrfs, Limine, a user for daily driving — agent dictates
   each screen live; deviations from the expected flow are themselves recon.
   *Expect:* installer completes and asks to reboot.
6. First boot into installed Omarchy 4.0. *Expect:* SDDM/desktop reachable.
   Record boot orientation + anything visually broken (camera).

### Phase D — SSH back-up, permanently this time

7. Operator (or agent via a TTY command dictation) on the installed system:
   ```
   sudo systemctl enable --now sshd
   mkdir -p ~/.ssh && echo '<staged pubkey line>' >> ~/.ssh/authorized_keys
   ip -br addr
   ```
8. Agent, dev machine: `~/.ssh/config` Host alias (`steamdeck` → the IP), so
   `deck-sync.sh` works with its defaults; verify `ssh steamdeck true`.
   **This also closes T0's last gap: `deck-sync.sh` runs against real
   hardware for the first time.** Sudo strategy on the Deck for the SSH
   loop: a NOPASSWD drop-in for the test user (it is a test device; note it
   in the session record; revisit before anything ships).
9. Baseline snapshot: `sudo snapper -c root create -d "fresh 4.0 baseline"`.
   Record the number. *(Omarchy's installer sets the snapper config up; its
   absence is itself a finding — record and continue without snapshots.)*

### Phase E — the real stock→Neptune conversion (T1's last gap)

10. `git clone` the repo onto the Deck (or `deck-sync.sh` it over).
    `shellcheck` clean, `list-stages` shows ten.
11. Agent runs, over SSH, one stage at a time, reading each result:
    `stage-preconditions → stage-repos → stage-esp-detect →
    stage-firmware-swap → stage-kernel → stage-uki → stage-prune →
    stage-default-entry → stage-hook → stage-esp-permissions`.
    **This time seven of ten run their REAL paths** — the firmware swap
    actually removes Arch's split firmware, the ESP permission cycle
    actually remounts, `stage-default-entry` writes the path form on a
    machine that never had it. Any non-zero exit: **stop, keep the shell,
    diagnose live** — this is exactly the situation the SSH loop exists for.
12. **Checkpoint β — reboot with hands off.** Menu times out, no key
    pressed. *Expect:* `uname -r` contains `neptune-611`;
    `bootctl status | grep LoaderEntrySelected` shows the entry path;
    `reconcile` exits 0 and writes nothing; Wi-Fi/BT/audio device nodes
    present on the Neptune kernel.
13. Post-reboot: `sudo snapper -c root create -d "neptune converted"`.

### Phase F — session layer (starts T3 §3's hardware column)

14. `./deck-session.sh` (installs everything except the default flip), then
    prove the directions:
    - `steamos-session-select gamescope` → *Expect:* Gaming Mode. Camera
      frame + controller input + audio check.
    - Steam → Power → **Switch to Desktop** → *Expect:* back to Omarchy.
      This exercises the shim — the controller-only path out.
    - Only after both work: `./deck-session.sh stage-default-session`,
      reboot, *Expect:* boots to Gaming Mode unattended.
15. Final snapshot + `PROGRESS.md` updates + commit from the Deck clone or
    the dev machine.

### Abort ladder (any phase)

- Stage failure with a live shell → diagnose in place; snapshots exist from
  step 9/13; `snapper rollback` + reboot recovers phases E–F.
- Unbootable + no shell → boot the Ventoy USB again; chroot from the live
  env over SSH; worst case reinstall (phase C is ~20 min).
- Truly bricked-looking → recovery USB → stock SteamOS → decide fresh.
  **This outcome is acceptable by decision** (`PROGRESS.md` §2.5); it costs
  the session, not the project.

---

## 4. What this session must leave behind

- [ ] §5.1 answered with evidence (Wi-Fi in the live ISO: yes/no + logs)
- [ ] Rotation + input recon recorded (feeds T4/T5)
- [ ] Deck on package-based Omarchy 4.0 + Neptune, booting it unattended
- [ ] The conversion path validated on hardware — T1's last checkbox
- [ ] `deck-sync.sh` proven against real hardware — T0's last gap
- [ ] Both session-switch directions proven without DeckShift
- [ ] `PROGRESS.md` §5.1/§5.2/§5.3/§5.4 + T3 status updated, committed, PR'd

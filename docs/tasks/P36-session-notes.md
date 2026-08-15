# P3.6 — session notes: bringing the Deck to Omarchy 4.0.0 stable

> **Prepared 2026-08-15 (session 27, dev machine) for the hardware session that
> has not happened yet.** This is the companion to
> `docs/tasks/P36-deck-stable-update-runbook.md`: the runbook is *what to do*,
> this is *what is true going in* plus blanks to fill as you go. Fill it in
> during the session, not after — this project has been burned by reconstructed
> notes before.
>
> **Model: Opus.** Boot chain + the one physical device (`CLAUDE.md`).

---

## 1. State going in — all verified 2026-08-15 on the dev machine

| Thing | State | Confidence |
|---|---|---|
| `main` | `4f8959c`, clean, pushed, in sync with origin | verified |
| Unit suites | **19/20** sh + **13/13** py + shellcheck green | verified |
| Last red | `test-vm-probe-integrity.sh` — a scanner that cannot classify a heredoc, **not** a product defect | verified |
| Our ISO | `omarchy-2026.08.15-x86_64-quattro.iso`, 6.38 GiB, sha256 `e9fbd8ed…68c5`, all 8 guards green | verified |
| ISO install | **18/18 in QEMU**, `install.outcome=success`, `autologin: gaming` | verified |
| **The Deck itself** | **still on the beta-2 pin** `4.0.0.r1617.g6d7826d-1`, channel edge | ⚠️ **last measured 2026-08-11 (session 20). RE-CHECK at session start — 4 days stale.** |
| Deck reachability | `ssh steamdeck` → `192.168.100.25`, user `deck` | ⚠️ unverified today |

**Nothing in this project has run on the Deck since 2026-08-11.** Everything
since — the 4.0.0 stable rebase, the new ISO, the gamescope fix — is dev-machine
and QEMU only.

## 2. The USB stick — what is on it right now

`/dev/sdb`, Kingston DataTraveler 3.0, 115.5 G, **Ventoy** (`sdb1` exfat
`Ventoy` + `sdb2` vfat `VTOYEFI`).

```
omarchy-2026.08.10-x86_64-quattro.iso    6,390,581,248 B   the OLD beta-2 ISO (P1.4)
omarchy-2026.08.15-x86_64-quattro.iso    6,854,164,480 B   NEW — 4.0.0 stable  ← use this one
```

🔴 **BOTH ISOs ARE ON THE STICK AND THE NAMES DIFFER BY ONE CHARACTER**
(`08.10` vs `08.15`). Ventoy's menu will list both. On a Deck screen, at arm's
length, that is a genuinely easy misread — and picking the old one silently
tests the *beta* build and invalidates the whole session. **Read the date twice
before pressing A.** The old ISO was deliberately kept as a fallback; say so if
you delete it.

⚠️ **The Valve recovery image is NOT on this stick.** It is on the dev machine at
`~/ISOs/steamdeck-recovery-4.img.bz2` (2.65 GB compressed, sha256 file beside
it). P1.4's "single-stick deviation" means the documented safety floor —
*recover to stock SteamOS* — **is not physically present during the session**.
For an in-place `omarchy-update` (what P3.6 does) the real floor is the snapper
snapshot, so this is acceptable; **for P3.1's factory reset it is not**, and that
stick has to be made first.

## 3. What makes this update different from every previous one

Not a routine `omarchy-update`. Two things bite specifically here — both
measured, both in the runbook:

1. **It is a package REPLACEMENT, not an upgrade.** `omarchy-dev` declares
   `provides=omarchy` **and** `conflicts=omarchy`, so moving edge→stable makes
   pacman *remove* `omarchy-dev` and install `omarchy` in one transaction. That
   is a conflict prompt.
2. **Five stable migrations call `sudo`, and Omarchy's grant is NOT NOPASSWD**
   (`%wheel ALL=(ALL:ALL) ALL`). Headless, they prompt into a void or hang.

**⇒ Use `ssh -t` and prime sudo (`sudo -v`) immediately before. Never
fire-and-forget over a plain pipe.** Detail:
`docs/findings/T9-stable-delta-classification.md` (§"SSH-abort").

## 4. What NOT to re-derive (already measured — trust these, or re-measure loudly)

- The boot chain is **safe** across this delta: `omarchy-defaults.conf` is
  byte-identical at both refs, and migration `1786482992` only rebuilds the UKI
  from unchanged on-disk drop-ins — it *preserves* `fbcon=rotate:1`.
- **No migration** touches idle 150 s/86400 s, transform 3, `lizard_mode`, or
  backlight perms.
- The **Desktop Mode menu row survives** the JSONC command-palette rewrite.
- Both **T12 runtime patches still apply** to stable's `Service.qml` (38/38).
- The `tzupdate` sudoers comment is **already correct** — do not "fix" it.

## 5. Fill in during the session

### 5.1 Pre-flight (before touching anything)
- [ ] `git rev-list --left-right --count origin/main...main` → `____` (want `0 0`)
- [ ] `ssh steamdeck 'omarchy-version; omarchy-version-channel; uname -r'`
      → version `____________` channel `________` kernel `____________`
- [ ] Does it match the expected beta-2 pin `4.0.0.r1617.g6d7826d-1`? `___`
      *(If it does NOT, stop and find out what moved it — nobody should have.)*
- [ ] snapper snapshot taken, number **#____**, description recorded

### 5.2 The update
- [ ] `omarchy-channel-set stable` → `omarchy-version-channel` now reads `______`
- [ ] `omarchy-update` run under `ssh -t` with sudo primed
- [ ] The `omarchy-dev` → `omarchy` conflict prompt appeared? `___` answered `___`
- [ ] Any migration prompted for sudo? which: `________________________`
- [ ] Any migration FAILED or aborted? `________________________`
- [ ] `omarchy-version` → `________` (want **`4.0.0`**, not `4.0.0.rN.gSHA`)
- [ ] `pacman -Q omarchy omarchy-settings` → `____________________`
- [ ] `pacman -Q omarchy-dev` → expect "was not found": `___`

### 5.3 Our layer, re-run against the moved substrate
- [ ] every `deck-session.sh` stage re-ran; any that failed: `______________`
      *(a stage failing here is a REAL finding — it is the first true test of the
      idempotence claim against a moved substrate)*
- [ ] `stage-audit-privileges` passed? `___`

### 5.4 Load-bearing settings (use `dconf read -d`, never `gsettings get`)
- [ ] `screen-keyboard-enabled` → `______`
- [ ] `input-sources` → `______`
- [ ] `idle.lock` still **86400** → `______`  *(0 locks INSTANTLY; it does not disable)*
- [ ] `fbcon=rotate:1` still on `/proc/cmdline` → `___`
- [ ] backlight node still `0644` (666 ⇒ a Steam helper broke) → `______`
- [ ] `lizard_mode` → `______`

### 5.5 Soak + eyes on the screen
- [ ] session switch, **≥5 cycles**, zero `start-limit-hit` → `___`
- [ ] OSK on STEAM+X, characters land, layer surface never steals focus → `___`
- [ ] both trackpad cursors incl. **diagonals** → `___`
- [ ] Steam Power → Switch to Desktop, **and back** → `___`
- [ ] Desktop Mode row still in the Omarchy menu → `___`
- [ ] Bluetooth still behaves (migration `1786380259` touched `main.conf`) → `___`
- [ ] power-button lock still dismissable (the stranded-lock mitigation) → `___`

### 5.6 Close
- [ ] post-update snapper snapshot taken
- [ ] `docs/PROGRESS.md` §1.1 pin + a §5.32 outcome written
- [ ] `docs/ROADMAP.md` P3.6 ticked to fully closed
- [ ] committed + pushed

## 6. Honesty gate

**Do not write "the Deck is on 4.0.0 stable"** unless `omarchy-version` printed
`4.0.0` *and* `pacman -Q omarchy` succeeded *and* `omarchy-dev` is gone. Anything
less is the silent-inaccuracy failure `CLAUDE.md` exists to prevent — and this
file's own §1 shows how fast a "verified" fact goes stale (4 days).

## 7. If it goes wrong

- **Update half-applied / system odd** → roll back to snapshot §5.1, via the
  Limine Snapshots submenu.
- **sddm latched `failed`** (two fast failures latch it permanently) →
  `systemctl reset-failed sddm`. The latch itself is a finding — record it.
- **No SSH and unusable screen** → hold **Power ~10 s**. A reboot restores
  `lizard_mode=Y`, so the firmware gives pointer + arrows back.
- **Genuinely bricked** → Valve recovery image, which is **on the dev machine,
  not on the stick** (§2). Budget the time to write a stick first.

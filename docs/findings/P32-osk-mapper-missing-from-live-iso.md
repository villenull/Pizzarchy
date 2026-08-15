# P3.2 — the on-screen keyboard mapper is not in the live ISO (P1 blocker)

> **Found 2026-08-15 (session 28) on the FIRST real-hardware boot of the
> stable ISO** (`omarchy-2026.08.15-x86_64-quattro.iso`, sha256 `e9fbd8ed…68c5`),
> on the OLED Deck. Operator hit it on the Wi-Fi password screen. This is a
> **P1**: it defeats the project's central constraint — *"No keyboard or
> terminal for a standard install"* (`CLAUDE.md`). Deferred to after the P3.2
> hardware pass by operator decision; that pass is being completed with a USB
> keyboard attached, which is itself the proof the bug exists.

## One-line statement

The live ISO ships the installer **screens** (`deck-form.sh`) but not the
**binary that draws their on-screen keyboard** (`deck-input-mapper`), nor its
`python-evdev` runtime dependency. Every text-entry screen therefore comes up
with no way to type, and the form correctly (loudly) degrades to "attach a
keyboard / choose Skip."

## What the operator saw

On the Wi-Fi password screen:

```
[deck-form] WARNING: mapper not found at /usr/local/bin/deck-input-mapper --
            this prompt runs WITHOUT the on-screen keyboard
[deck-form] WARNING: the on-screen keyboard did not start -- there is no way
            to type here. Choose 'Skip' on the network list to continue
            without Wi-Fi.
Password for [FBI Mesh) 420] Wi-Fi password    enter  submit
```

The degradation is behaving **exactly as designed** — the no-silent-failure
rule is intact, the warnings are precise, and there is a documented escape
(Skip). The bug is that the escape should never have been the only option: the
OSK the screen is built around is not present.

## Root cause (mechanism, verified in source)

1. `deck-form.sh` raises its OSK by launching the mapper itself:
   - `iso/overlay/configs/airootfs/usr/share/omarchy-iso/deck-form.sh:202`
     `readonly DECK_MAPPER_BIN=/usr/local/bin/deck-input-mapper`
   - `:228` `readonly -a DECK_MAPPER_ARGS=(--osk-backend=tty --osk-start-shown)`
   - `:420` `if [[ -x $mapper_bin ]]; then "$mapper_bin" … &` … else `:429`
     `deck_form_warn "mapper not found at $mapper_bin …"`.
2. **Nothing puts that binary in the live filesystem.** The overlay tree
   `iso/overlay/configs/airootfs/usr/local/` is **empty** (no `bin/`). `iso/bin/build`
   never copies `src/deck-input-mapper.py` into the airootfs. There is no
   `.packages` line pulling it and no service installing it.
3. The mapper is a Python program that `from evdev import …`
   (`src/deck-input-mapper.py:90`). **`python-evdev` is not in the live ISO's
   package set** either — so even dropping the script in would not be enough.
4. Where the mapper *does* get installed is the **target**, by
   `src/deck-session.sh` → `/usr/local/bin/deck-input-mapper`
   (`src/deck-session.sh:457`), i.e. onto the machine **after** it is installed.
   That is the Desktop-Mode navigation path (T3), not the live installer path
   (T4). The two were never wired to the same provider.

## Blast radius — NOT just Wi-Fi

The Wi-Fi passphrase is one caller of `deck_form_text_prompt`. The **account
username and password** screens go through the identical path:
`keyboard_form` → `user_form` → `omarchy_prompt_username` /
`omarchy_prompt_password` (`deck-form.sh:526-527`), all wrapped in
`deck_form_text_prompt` (`:394`), which is the function that launches the
mapper. So with no mapper:

- **Wi-Fi password** — cannot type ⇒ Skip ⇒ (likely) no network install.
- **Account username** — cannot type.
- **Account password** — cannot type, **and the field is masked**, so on a
  keymap mismatch the failure would be invisible (the very §5.20a hazard the
  keymap-pinning code was written to prevent).
- **Hostname** — cannot type (falls back to whatever default the body sets).

⇒ **A stock, keyboard-free install cannot be completed on real hardware with
this ISO.** The QEMU harness never caught it because its virtio NIC means the
Wi-Fi screen is skipped and — more importantly — the harness was driving the
form's functions directly, not booting the live image and pressing buttons at
the tty. This is squarely the "only hardware exercises it" class (`CLAUDE.md`
Testing).

## The false-confidence claim this overturns

`docs/PROGRESS.md` T4 row (§ top table) states:

> "`--osk-start-shown` + the mapper's `bound` readiness marker exist now, so
> S1's Wi-Fi passphrase prompt **no longer degrades by construction**."

That is true of the **protocol** (the flag and the `deck-input-mapper: bound`
marker do exist in `deck-form.sh`) but false of the **artifact**: the binary the
protocol speaks to is absent from the image, so on hardware it degrades by
construction. Corrected in place when this finding landed.

## The fix (deferred — do NOT do it mid-P3.2)

Ship the mapper and its dependency into the live ISO. In outline (to be
designed properly, then unit-guarded before rebuild):

1. **Place the binary at `/usr/local/bin/deck-input-mapper`** in the live
   airootfs. Two candidate routes, pick one deliberately:
   - copy `src/deck-input-mapper.py` into
     `iso/overlay/configs/airootfs/usr/local/bin/deck-input-mapper` (chmod +x)
     as part of `iso/bin/build`, the way `deck-form.sh` is already shipped from
     the overlay; **or**
   - carry it in the `omarchy-deck` package and install that package into the
     live set. (`deck-form.sh` is shipped by overlay copy, so route 1 is the
     smaller, matching move.)
2. **Add `python-evdev` to the live ISO package set** (the airootfs/live
   packages list, not the target install list) — the mapper imports `evdev`.
3. **A build guard** in the class of 6.4a: assert that
   `[[ -x airootfs/usr/local/bin/deck-input-mapper ]]` in the overlaid tree
   **and** that the live package set contains `python-evdev`, so this can never
   silently regress again. The whole point of the guard family is to catch
   exactly this "the screen references a thing the image does not carry" gap.
4. **Then a real live-boot check** — not just a rebuilt-ISO unit run — because
   this bug proves the unit/QEMU tiers structurally cannot see a missing
   live-tty OSK. Minimum: boot the ISO in QEMU far enough to reach S1/S3 with
   the mapper present and confirm `deck-input-mapper: bound` is emitted and the
   OSK draws. Ideally re-confirm on the Deck.

## Field workaround used this session

Attach a USB keyboard (USB-C hub) and type into the existing `gum` prompts —
they are ordinary tty prompts and accept a real keyboard fine. This completes a
full networked install so the rest of the P3.2 matrix (kernel, boot, session
switch, trackpads, gyro, audio DSP, gamescope) can be exercised tonight. It
does **not** validate the controller-only path — that stays open until the fix
above ships and is re-verified.

## Status

- [x] Root-caused, mechanism verified in source
- [x] Blast radius established (all text-entry screens, not just Wi-Fi)
- [x] PROGRESS T4 false-confidence claim corrected
- [ ] **P1 fix** — ship mapper + `python-evdev` into the live ISO, guard it,
      re-verify by live boot. **Deferred until after the P3.2 hardware pass.**

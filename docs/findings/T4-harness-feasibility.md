# T4 — is the [V] tier real? (unknown U2, settled)

**Session 22, 2026-08-11.** Everything marked **(RUN)** was executed against
`~/ISOs/omarchy-quattro-beta2.iso` on this dev machine: **four QEMU boots**, no
ISO rebuild, no `sudo`, no loop mount, no hardware. Harness:
`test/vm/vm-iso-probe-feasibility.sh` (new).

`docs/tasks/T4-screen-spec.md` §8 U2 asked two questions and made them blocking:
*"Test this first, before writing any screen."* Both are answered, plus a third
the tier cannot work without.

| Mechanism | Verdict |
|---|---|
| **1a. Injection — SMBIOS type-11 systemd credentials** | ✅ **works, unchanged, against archiso.** It carries the whole probe, not just a unit: an **11,180-byte** OEM string arrived byte-identical |
| **1b. Injection — the `cidata` drive** | ⚠️ **works, with a caveat that disqualifies it here.** `omarchy-cidata-load` executes nothing; a probe needs cloud-init's NoCloud seed on the same drive — and cloud-init prints onto the tty under test (**measured**) |
| **2. Reading tty1 back from `/dev/vcs1`** | ✅ **works. Plymouth does not hide tty1** — it has already quit, and tty1 is `KD_TEXT`, when the wizard draws |
| **3. Driving the screen (not in U2; the tier is useless without it)** | ✅ QMP `send-key` advances the real wizard; advance-and-vanish is assertable with **no in-guest input plumbing at all** |

**T4's [V] tier is viable as designed.** §6.3's proposal survives contact with a
real archiso image. Four amendments follow (§6), all small; **one is mandatory**
and is the thing that nearly made this investigation report the opposite answer.

A whole run now costs **42 s of guest time** (run 2, boot → greeter → two key
presses → poweroff).

---

## 0. What was run, and what was only reasoned

**RUN.** Four boots of the real ISO through **its own GRUB under OVMF** — the
product's boot path, not a `-kernel`/`-initrd` shortcut:

| Run | Injection | Outcome | Work dir |
|---|---|---|---|
| 1 | SMBIOS ×4 + payload drive | injection ✅; console read **falsely negative** — §2.3 | `/var/tmp/t4probe-run1` |
| 2 | same, geometry bug fixed, `python-evdev` on the payload drive | **all green in 42 s** | `/var/tmp/t4probe-run2` |
| 3 | **no SMBIOS at all** — cloud-init NoCloud seed on a `CIDATA` drive | probe ran; cloud-init printed on tty1 | `/var/tmp/t4probe-run3` |
| 4 | run 2 again, against the harness **as committed** (greps hardened after run 3) | green; `A.nonblank_rows` 2 → **12**, confirming §2.4 | `/var/tmp/t4probe-run4` |

The harness in the repo is the one run 4 passed. A suite edited after its last
green run is an unverified suite.

Plus offline extraction with `bsdtar` (boot configs) and `7z` (the squashfs) —
no mount, no root, the recipe `docs/findings/T9-iso-comparison.md` already
established.

**REASONED, not run:**

- That the same conclusions hold for the *forked* ISO T5 will build. Nothing
  measured here depends on Omarchy's own files except the greeter's marker
  strings, but the fork is not built yet.
- Anything about the Deck's own console. This guest's tty1 is 50×160 of
  `bochs-drm`. **U3 is still open and still needs hardware** — but §2.3 changes
  what U3 has to answer.
- That `pacman -U`-ing `python-evdev` from a payload drive is acceptable
  *practice*. It is measured to **work** (§4.2); whether the [V] suite should do
  it, versus building the fork with patch P2 and testing that, is a judgement for
  T4a.

---

## 1. Mechanism 1 — injection

### 1.1 What the `cidata` drive actually does (source, not inference)

`usr/local/bin/omarchy-cidata-load`, read out of the ISO's own squashfs:

```
udevadm settle
device = /dev/disk/by-label/{cidata,CIDATA}          # either case
mount -o ro $device /run/cidata
rm -f /root/{user_configuration.json,user_credentials.json,defer-provisioning,
             user_full_name.txt,user_email_address.txt,
             user_encrypt_installation.txt,authorized_keys,tailscale_authkey}
if user_configuration.json AND (user_credentials.json OR defer-provisioning):
    cp those files -> /root ; loaded=0
umount ; exit $loaded
```

**It copies eight named files and executes nothing.** `.automated_script.sh` then
does `if omarchy-cidata-load; then export OMARCHY_UI_INTERACTIVE=no; else
./configurator; fi`. So the drive's purpose is to **replace the wizard** — the
exact opposite of what a screen test needs.

Two consequences worth recording in the spec:

1. **A `cidata` drive and the screens are mutually exclusive.** Any drive that
   satisfies the pair skips every screen under test. `vm-install-test.sh`'s use of
   it is right *for that suite* and unusable for T4's.
2. **A `cidata`-labelled drive that lacks `user_configuration.json` is harmless**
   — the loader mounts it, declines, unmounts, and the wizard runs **(RUN**, runs
   1–3: `probe.self=/run/deckprobe/probe.sh` and the greeter appeared anyway**)**.
   So one drive can carry test payload without arming the autoinstall. The label
   is arbitrary; runs 1–2 used `DECKPROBE`.

⚠️ **archiso's own `script=` kernel-parameter hook is gone.** Upstream archiso's
`.automated_script.sh` downloads and runs a script named by `script=` on the
cmdline. Omarchy **replaced that file wholesale** — it is 100 lines of
Omarchy-specific setup with no `script_cmdline`. Do not reach for it.

### 1.2 SMBIOS type-11 credentials: work, and are larger than needed (RUN)

Run 1, four injections at once, all landed:

```
unit.ran=1
cred.dir_listing=systemd.extra-unit.t4-probe.service,
                 systemd.unit-dropin.multi-user.target,
                 t4probe.fwcfg,t4probe.sh,t4probe.smbios,
cred.smbios_marker=smbios-cred-ok       # -smbios type=11, plain string
cred.fwcfg_marker=fwcfg-cred-ok         # -fw_cfg opt/io.systemd.credentials/…
payload.cred_bytes=8353                 # the WHOLE probe, delivered by SMBIOS
payload.cred_equals_drive=1             # byte-identical to the drive's copy
dmi.type11_entries=1
systemd.version=systemd 261 (261.2-1-arch)
```

- The **`systemd.extra-unit.<name>` + `systemd.unit-dropin.multi-user.target`**
  pattern `vm-osk-tty-test.sh` uses against the Neptune substrate works verbatim
  against archiso, whose root is a squashfs+tmpfs overlay reached through
  `switch_root`. systemd 261 in the live ISO; the feature needs ≥ 254.
- **An 11,180-byte OEM string carrying a base64'd 8 KB script arrived intact**,
  and run 2 repeated it at 15,232 B / 11,394 bytes of script
  (`payload.cred_equals_drive=1` both times).
  §6.3's "the probe is injected, not shipped" therefore needs **no payload drive
  at all** for anything script-sized. A drive is still the right answer for
  packages (§4.2).
- **QEMU `fw_cfg` credentials also work** (`/sys/firmware/qemu_fw_cfg` present,
  marker landed) — a second route with no size ceiling, and the one to reach for
  if a credential ever outgrows SMBIOS.

⚠️ Not where the spec might look: system credentials land in
`/run/credentials/@system/`, and **`ls /run/systemd/system` was empty** — the
generated unit is not visible as a file. Assert that the unit *ran*, never that a
file exists.

### 1.3 The unit that works

```ini
[Unit]
Description=…
After=multi-user.target                 # so the wizard is already up

[Service]
Type=oneshot
ExecStartPre=-/usr/bin/udevadm settle
ExecStartPre=-/usr/bin/mkdir -p /run/deckprobe
ExecStartPre=-/usr/bin/mount -o ro /dev/disk/by-label/DECKPROBE /run/deckprobe
ExecStart=/usr/bin/bash /run/credentials/@system/<probe>.sh
TimeoutStartSec=0
RemainAfterExit=yes
StandardOutput=null
StandardError=null
```

⚠️ **`StandardOutput=null` is load-bearing, not tidiness.** The probe shares tty1
with the thing it is watching. `journal+console` writes to `/dev/console` →
`tty0` → `tty1`, so a probe that logs scribbles across the screen it is
asserting on. (Run 3 shows exactly that failure, from cloud-init — §2.4.)
Host↔guest synchronisation goes out **`/dev/ttyS0`** instead: the live cmdline
carries no `console=`, so the serial port is unused and free. The host greps
`-serial file:…` for markers and answers with QMP — which removes every fixed
sleep from the harness.

⚠️ **`$` and `%` are systemd specifiers.** An `ExecStart=/usr/bin/bash -c '…'`
that uses a shell variable needs `$$`; the working line in the harness avoids
variables entirely.

---

## 2. Mechanism 2 — reading the console

### 2.1 Plymouth does not hide tty1 (RUN)

The warning in `vm-install-test.sh`'s header does not apply to the wizard's
screens. Measured with the greeter on screen:

```
plymouthd.running=0     plymouth.ping_rc=1     (no daemon; the socket is gone)
plymouth.quit=active    plymouth.quit_wait=active
tty1.kdmode=0           (KD_TEXT — nothing holds the VT in graphics mode)
fgconsole=1             tty0.active=tty1       console.active=tty0
vcs.nodes=/dev/vcs1,/dev/vcsa1,/dev/vcsu1
```

The ordering that guarantees this is upstream's, not ours:
`plymouth-quit.service` and `plymouth-quit-wait.service` sit in the plymouth
package's own `multi-user.target.wants`, and systemd's `getty@.service` is
`After=plymouth-quit-wait.service`. **The agetty that runs the wizard cannot
start until the splash has gone.** So `plymouth.enable=0` is not needed, and
neither is a `plymouth quit` in the probe — §6.3 item 3 collapses to a one-line
assertion.

A host-side QMP `screendump` of the same moment shows the greeter on the
framebuffer, upright, no splash: `/var/tmp/t4probe-run1/live-peek.png`.

### 2.2 `/dev/vcs1` carries the wizard exactly (RUN)

The kernel's own copy of tty1, folded at the console's true width, **is** the
screen — logo, tagline, hint, the `gum choose` list, and gum's `>` cursor:

```
19|                                    ÜÜÜ
20|                            ÜÛÛÛÛÛÜ    ÜÛÛÛÛÛÛÛÛÛÛÛÜ    ÜÛÛÛÛÛÛÛ   …
…
30|                             Beautiful, Modern & Opinionated Linux by DHH
32|                                    Press Return to Start Install
```

and after one host-sent Return:

```
13|                Let's setup your machine...
14|                Press Ctrl+C to prepare this machine for another owner.
16|                Select keyboard layout
17|                > English (US)
18|                  English (UK)
…
30|                 navigate  enter submit
```

A1, A4 and A5 satisfied from one buffer: the marker is there, the previous
screen's marker is gone, and gum's selection is legible **as text**.

### 2.3 🔴 The trap that cost a boot — and that the [V] harness must not inherit

**tty1 is 25×80 at `multi-user.target` and 50×160 by the time the wizard draws.**
The console grows when the DRM driver takes over from the boot framebuffer.

Run 1 read the geometry from `/dev/vcsa1` once, at probe start, and folded every
later capture at 80 columns. Centred text — the tagline, the hint — was therefore
**split across two output lines**, and a phrase `grep` missed a screen that was
perfectly present:

```
run 1:  greeter.found=0   vcs1.rows=25  vcs1.cols=80  vcs1.bytes=2000
        B.cursor_row=33   ← 33 lines out of a "25-row" screen: the buffer had grown
run 2:  greeter.found=1   greeter.wait_s=4   A.geom=50x160   B.geom=50x160
```

The left-aligned `Let's setup your machine...` matched anyway, because it fits
inside the first 80 columns. **So the suite half-passed, in the direction that
reads as "the console reader is broken".** That is §6.4's lie #1 in a new coat:
an assertion failing for a reason unrelated to the thing under test — and it
would have been reported as "U2: /dev/vcs1 unavailable, the [V] tier is dead".

Guards, both cheap, both now in the harness:

- **Re-read `/dev/vcsa1`'s 4-byte header (`rows, cols, x, y`) on every single
  capture.** Never cache it. (`snap()` in `vm-iso-probe-feasibility.sh`.)
- **Record the geometry beside every capture** and print it in the report, so a
  width change is visible rather than inferred.
- Prefer **left-aligned** markers where a screen has one: everything
  `step()`/`say()` draws is padded to `PADDING_LEFT`, so §4's six screens are
  mostly safe; the greeter and the `tte` frame are the centred ones.

### 2.4 🔴 The second trap: the logo is not ASCII, and grep quietly agrees

The Omarchy logo is drawn with CP437 block glyphs. In a `/dev/vcs1` dump those
are raw high bytes (0xDB/0xDC/0xDF) that are **invalid UTF-8**, and GNU grep in a
UTF-8 locale will not match `.` or a negated class against them. Measured on run
2's own capture:

| | rows matched |
|---|---|
| ground truth (`python`, any non-space) | **13** |
| rows with printable ASCII | 3 |
| in-guest `grep -c '[^ ]'` | **2** |
| in-guest `LC_ALL=C grep -ac '[^ ]'` (run 4, after the fix) | **12** ✅ |

Phrase greps against ASCII text were unaffected — which is why runs 2 and 3
passed. But **any assertion about how much of the screen is painted will silently
under-count**, and that is exactly the shape of assertion the OSK screens need
("the keyboard occupies five rows"). `vm-osk-tty-test.sh` gets away with it
because it greps for the ASCII word `shift`.

→ Use `LC_ALL=C grep -a`, or do the comparison on bytes in Python. State it in
the harness header.

### 2.5 The `cidata` drive *can* run a probe — via cloud-init — and shouldn't (RUN)

Run 3 removed **every** SMBIOS credential (`dmi.type11_entries=0`,
`cred.smbios_marker=` empty) and attached only a `CIDATA`-labelled vfat carrying
a cloud-init NoCloud seed (`meta-data` + `user-data` with a `runcmd`). Result:

```
unit.ran=1                       probe.self=/run/deckprobe/probe.sh
cloudinit.status=status: running     (it is `status: disabled` with no seed)
greeter.found=1                  A.geom=50x160    vcs1.rows_at_start=50
```

So: **it works.** cloud-init 26.1 and `cloud-init-generator` ship in the live
ISO, NoCloud's seed label is the same `cidata`, and its `runcmd` mounted the
payload drive and executed the probe. It even has one accidental virtue — it runs
at `cloud-final`, by which time the console has already grown to 50×160 and the
greeter is already up (`greeter.wait_s=0`).

**Use SMBIOS anyway.** Two measured reasons:

1. **cloud-init prints on the tty under test.** Its units are
   `StandardOutput=journal+console`. Run 3's own capture of the greeter frame
   carries the line
   `[ 43.308754] cloud-init[656]: Cloud-init v. 26.1 running 'modules:final' at …`
   — landed on the greeter, on the screen the tier asserts on. It happened to hit
   a blank row this time. That is luck, not a property.
2. **It overloads the one drive that already means something.** The seed has to
   live on a drive labelled `cidata`, which is the same label
   `omarchy-cidata-load` reads to decide whether to skip the wizard entirely. One
   drive, two unrelated meanings, and the failure mode is "the screens under test
   never ran".

**If `cidata` beat the spec's SMBIOS proposal I would say so plainly. It does
not — it ties on capability and loses on isolation.** SMBIOS needs nothing
arranged in the guest, delivers 11 KB, and touches no console.

---

## 3. The third leg: driving the wizard from outside (RUN)

Not in U2, but the tier is worthless without it — and it turns out to need no
guest software whatsoever. QMP `send-key` on the default PS/2 keyboard drives the
real wizard:

| Host action | `/dev/vcs1` before | after |
|---|---|---|
| `send-key ret` | `Press Return to Start Install` (`A.hint=1`, `A.tagline=1`) | **gone** (`B.hint=0`, `B.tagline=0`); `Let's setup your machine...` + `Select keyboard layout` (`B.keyboard_step=1`) |
| `send-key down` | `> English (US)` (`B.cursor_row=17`) | `> English (UK)` (`C.cursor_row=18`) |

So **every navigation-only screen in §4 (S0, S2, S4, S5, S7, S8) can be driven
with zero in-guest input plumbing** — no `python-evdev`, no mapper, no uinput,
nothing to go silently dead (§6.4 lie #2 disappears for those screens). That is a
much cheaper tier than §6.3 assumed, and it is the right vehicle for the
**blocking-screen negative tests** (S3, S4), which are about what a screen does
with a key, not about how the key was produced.

The virtual Deck pad is still needed for exactly one thing: S1/S3's text entry
through the OSK, which is the trackpad path. §4's ⭐ acceptance test keeps its
pad; nothing else has to.

---

## 4. The cheapest working recipe

### 4.1 Boot line (the parts that matter)

```sh
qemu-system-x86_64 -cpu host -enable-kvm -machine q35,accel=kvm -smp 4 -m 6144 \
  -smbios type=1,manufacturer=Valve,product=Galileo,version=1 \
  -smbios "type=11,value=io.systemd.credential.binary:systemd.extra-unit.t4-probe.service=$(base64 -w0 <<<"$unit")" \
  -smbios "type=11,value=io.systemd.credential.binary:systemd.unit-dropin.multi-user.target=$(base64 -w0 <<<"$dropin")" \
  -smbios "type=11,value=io.systemd.credential.binary:t4probe.sh=$(base64 -w0 <probe.sh)" \
  -drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE \
  -drive if=pflash,format=raw,file=$OVMF_VARS \
  -drive file=$ISO,media=cdrom,if=none,format=raw,id=cdrom0 \
  -device ide-cd,drive=cdrom0,bootindex=1 \
  -drive file=payload.img,format=raw,if=none,id=probe0 -device virtio-blk-pci,drive=probe0 \
  -drive file=result.raw,format=raw,if=none,id=result0 \
  -device virtio-blk-pci,drive=result0,serial=vmresult \
  -nic user,model=virtio-net-pci -display none -vga std \
  -qmp unix:qmp.sock,server,nowait -serial file:serial.log -daemonize -pidfile qemu.pid -no-reboot
```

- The ISO boots through **its own GRUB under OVMF**. No cmdline control is
  needed, because none of this uses the cmdline.
- `payload.img` is `truncate` + `mkfs.vfat -n LABEL` + `mcopy`. **No root.**
- Results come back on a raw virtio device the guest `dd`s to and the host reads
  with `tr -d '\0'` — `vm-osk-tty-test.sh`'s existing shape, unchanged.
- ⚠️ **Attach no target disk.** The wizard's disk screen then has nothing
  destructive to offer, which is what a screen test wants.
  `vm-install-test.sh` attaches one because it is testing the install.
- ⚠️ **Give the probe a watchdog.** A probe that blocks is indistinguishable from
  a probe that never ran, and both cost a whole boot. The harness spawns a
  background timer that dumps whatever results exist and powers off.

### 4.2 Getting `python-evdev` in without rebuilding (RUN, run 2)

The live `pacman.conf` declares one offline repo, so `pacman -Sy python-evdev`
cannot work (P15 R-9/R-10). `pacman -U` off a **local file** can, and the ABI
matches by a coincidence worth writing down: the live ISO carries **python
3.14.6-1** — the same build this dev machine has — so
`/var/cache/pacman/pkg/python-evdev-1.9.3-1-x86_64.pkg.tar.zst` drops straight
in off the payload drive:

```
python.version=Python 3.14.6           # live ISO
python.evdev_importable=1              # i.e. FAILS before the install
evdev.pacman_U_rc=0                    # pacman -U from the drive, fully offline
evdev.importable_after=0               # i.e. succeeds
uinput.node=1                          # modprobe uinput works
uinput.pad_created=/dev/input/event5   # a Deck-shaped UInput pad, in the live ISO
```

⚠️ This is a **harness** convenience. The shipped ISO still needs T4's patch P2
(`python-evdev` into `arch_packages`); a package a probe `pacman -U`'d is not a
package the release carries, and `tools/iso-payload-audit.sh` should keep saying
so. A [V] run that installs it is testing the *mapper*, not the *image*.

---

## 5. Measured on the way, for tasks that were waiting

| Measured | Field | Bears on |
|---|---|---|
| `hid-steam.ko.zst` **is in the live ISO** (`.../7.1.6-arch1-Watanare-T2-1-t2/kernel/drivers/hid/`) and **`modinfo` declares the `lizard_mode` parameter** | `hid_steam.modinfo_lizard=1` | **U6, half-answered.** The parameter exists in `linux-t2`'s build, so the sysfs knob will exist on the Deck once the module binds. QEMU cannot finish it: `hid_steam.loaded=0`, `sysfs_param=0` — no Deck HID to bind to. One line on the next hardware session |
| tty1 goes **25×80 → 50×160** during boot | §2.3 | **U3** is still open, but its answer must be "it changes" — a single recorded number would be a lie |
| `fbcon.rotate=0` in QEMU | `fbcon.rotate=0` | §6.2 **A6 is [H]-only.** The `1` the spec wants is `linux-t2`'s panel-orientation quirk firing on real hardware; in QEMU `0` is correct. Gate the assertion, don't run it everywhere |
| `gum jq openssl tzupdate iwctl tte loadkeys openvt chvt` present; `python-evdev` absent | `tools=…` | §2.4's table, confirmed on the built image rather than from `build-iso.sh` |
| live ISO carries systemd **261.2-1**, python **3.14.6-1**, cloud-init **26.1**, gum **0.17.0**, iwd **3.12**, plymouth **26.134.222-2**, kernel **linux-t2 7.1.6-1** | | version floor for anything that assumes a systemd feature |
| live cmdline: `… archisobasedir=arch archisosearchuuid=2026-08-10-13-35-06-00 quiet splash xe.enable_panel_replay=0 initramfs_async=0` (beta2; the 08-10 build is `…15-24-25-00`) | `cmdline=` | needed by anyone who *does* want `-kernel`/`-initrd` direct boot |
| `getty@tty1.service.d/autologin.conf` autologins **root** with `agetty --noclear`; `/root/.zlogin` runs `.automated_script.sh` | | why tty1 is the screen, and why nothing else may write to it |

---

## 6. Verdict, and the amendments to §6

**Viable as designed.** `docs/tasks/T4-screen-spec.md` §9's first checkbox — *"U2
… answered — before any screen is written"* — can be ticked for U2. Screen work
is unblocked. (U6 is still half-open and still hardware-gated.)

1. **§6.3 item 2 — keep it; drop the "(INFERRED)".** SMBIOS credential injection
   works against archiso and carries the whole probe. Keep the "the unit ran"
   first assertion anyway: it is cheap and it is the only thing standing between
   a broken injection and a vacuous pass.
2. **§6.3 item 3 — plymouth needs no handling.** Replace *"the probe must
   `plymouth quit` … and assert that tty1 is the active console"* with two
   assertions it already implies: `tty1.kdmode == 0` and `fgconsole == 1`. Do
   **not** add `plymouth.enable=0` — it would require cmdline control the harness
   does not otherwise need, and would test a boot the product never performs.
3. 🔴 **§6.2 A6 and §6.4 — add the two silent readers.** A6 gains *"the console
   width, re-read at every capture"*, and `fbcon/rotate == 1` is gated to **[H]**.
   §6.4's table gains rows **6** (a cached console width splits centred text and
   makes a present screen look absent — §2.3) and **7** (grep silently refuses to
   match the non-UTF-8 glyphs the logo and the OSK are drawn with — §2.4). Both
   have now already happened once, which is the bar that table sets.
4. **§6.3 item 4 — the pad is needed far less often than assumed.** QMP
   `send-key` drives every navigation-only screen and both blocking-screen
   negative tests. Extract the P17-shaped pad to `test/lib/` as planned, but spend
   it only on S1/S3's text entry.

And one correction to §1.3 while it is in view: the spec calls "feed" (cidata)
*"a test tier"*. It is a tier for `vm-install-test.sh`'s question, not for T4's —
the mechanism's whole purpose is to **skip** the screens. Worth a sentence so
nobody reaches for it when writing `vm-installer-screens-test.sh`.

---

## 7. Reproduce

```sh
# the answer, both mechanisms, one boot (~42 s of guest time under KVM)
VM_MEM_MB=6144 \
VM_PROBE_EXTRA=/var/cache/pacman/pkg/python-evdev-1.9.3-1-x86_64.pkg.tar.zst \
  ./test/vm/vm-iso-probe-feasibility.sh ~/ISOs/omarchy-quattro-beta2.iso /var/tmp/t4probe

# the cidata/cloud-init route instead of SMBIOS (expect the SMBIOS check to fail:
# that run deliberately passes no credentials)
VM_PROBE_INJECT=cloudinit ./test/vm/vm-iso-probe-feasibility.sh

# offline: read anything out of the ISO without root
bsdtar -xf ~/ISOs/omarchy-quattro-beta2.iso -C . boot/grub/grub.cfg arch/x86_64/airootfs.sfs
7z x -y -o./x arch/x86_64/airootfs.sfs root/.automated_script.sh \
      usr/local/bin/omarchy-cidata-load etc/plymouth/plymouthd.conf \
      'etc/systemd/system/getty@tty1.service.d/autologin.conf'

# re-fold a captured /dev/vcs1 dump at the right width (what run 1 got wrong)
python3 -c "raw=''.join(open('screen.A-greeter',encoding='latin-1').read().split('\n'));
print('\n'.join(raw[i:i+160] for i in range(0,len(raw),160)))"
```

Artefacts kept: `/var/tmp/t4probe-run{1,2,3}/` — reports, serial logs, and
`run1/live-peek.png`, a host-side screendump of the greeter frame.

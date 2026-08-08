# FINDING R1 10.4 — Will `steam` actually work offline on first boot?

**Result: CONFIRMED.** Arch's `steam` package is a ~20 MB bootstrap. On its
first launch with no network it fails fatally in under one second with
`Steam needs to be online to update.` and exits. No Steam client is installed.

And the mitigation does not rescue the claim: pre-populating the 2.5 GB client
(also tested, phases 3–4) makes Steam *start* offline and reach its login
screen instead of dying — but login itself needs network
(`LogonFailure No Connection`), so Gaming Mode is still not usable offline
under any packaging strategy.

> ⚠️ **This contradicts a hard constraint in `CLAUDE.md`** ("Fully offline
> install — the whole flow through first boot into Gaming Mode, not just the
> base OS"). Per `START-HERE.md` §3 this is a foundational-assumption failure
> and needs an operator decision, not a workaround. See
> "What this changes" and "Decision needed from the operator" below.

---

## Hypothesis (from `PLAN.md` §10.4)

> **no — and this is the most likely goal-threatening surprise in the plan.**
> Arch's `steam` package is a bootstrap that downloads the real client from
> Valve on first launch. A "fully offline install" can therefore still produce
> a device that **boots to Gaming Mode and immediately needs internet** before
> Steam is usable.

## What I did

A real, network-isolated QEMU VM — not reasoning, not log-reading.

Scratch dir (outside this repo, per the project rule): `~/scratch-r1/steamvm`.

1. **Base image.** Official Arch Linux cloud image
   (`geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2`,
   557 MB), resized to 24 GB. Driven by a hand-built NoCloud `cidata` vfat
   seed (same FAT-label technique as this repo's `vm-cidata.sh`, since there
   is no `xorriso`/`genisoimage` on this host).
2. **Phase 1 — networked install.** `-nic user`. Enabled `multilib`, full
   `pacman -Syu`, then installed `steam` plus `xorg-server-xvfb` (Steam needs
   an X display; the VM has no GPU and the question under test is network
   behaviour, not rendering). **Steam was deliberately never launched in this
   phase**, so that the offline boot would be its genuine *first* launch —
   exactly matching a fully-offline ISO install. Captured `pacman -Qi/-Ql
   steam`, `/usr/bin/steam`, and a filesystem-wide search for a bootstrap
   tarball. Powered off.
3. **Phase 2 — the actual test.** Rebooted the same disk with **`-nic none`**
   (no network device present in the machine at all, matching how
   `vm-install-test.sh` does its offline install test), `cloud-init` disabled.
   Verified isolation from inside the guest, then launched
   `/usr/bin/steam` as an unprivileged user under `xvfb-run` with a hard
   300 s `timeout`, and copied every log off the VM on a vfat results disk.
4. **Phases 3 and 4 — the mitigation test.** See "Can a pre-populated client
   launch offline?" below.

Supporting (non-VM) evidence was cross-checked against Arch's `steam`
PKGBUILD and Valve's own `steam-launcher` source tarball
(`repo.steampowered.com/steam/archive/beta/steam_1.0.0.87.tar.gz`).

## Evidence

### 1. The distro package contains no Steam client

```
Name          : steam
Version       : 1.0.0.87-1
Licenses      : LicenseRef-steam-subscriber-agreement
Installed Size: 19.53 MiB
```

`pacman -Ql steam` is 11 files. `/usr/bin/steam` is two lines
(`exec /usr/lib/steam/steam "$@"`). The only substantial payload is
`/usr/lib/steam/bootstraplinux_ubuntu12_32.tar.xz` (20,285,684 bytes).

Valve's own `README` in the `steam-launcher` source says it plainly:

> "This package contains a launching script that **downloads and runs the
> Steam client program** as the current user."

The bootstrap tarball has 166 entries: `steam.sh`, `ubuntu12_32/steam` (the
10 MB *updater* binary), and the scout steam-runtime. It does **not** contain
`steamui.so`, `steamclient.so`, or any of the actual client.

`strings` on the updater binary shows the baked-in download hosts:
`client-update.steamstatic.com`, `cdn.beta.steampowered.com`, alongside
`Downloading manifest: http%s://%s%s`, `DownloadManifest - exhausted list of
download hosts`, and `Updating Steam...`.

### 2. Offline first launch — proof the VM was isolated

From inside the guest during phase 2 (`network-state.txt`):

```
== ip addr ==
1: lo    inet 127.0.0.1/8 scope host lo
1: lo    inet6 ::1/128 scope host noprefixroute
== ip route ==            (empty)
curl https://steamcdn-a.akamaihd.net/... -> curl: (6) Could not resolve host
curl https://media.steampowered.com/... -> curl: (6) Could not resolve host
```

Only loopback. No route table. And `/home/deck` before the launch contained
only `.bash_logout`, `.bash_profile`, `.bashrc`, `.ssh` — Steam had never run.

### 3. What Steam actually did (verbatim, `bootstrap_log.txt`)

```
[05:41:39] Startup - updater built Jun 24 2026 23:24:37
[05:41:39] Using the following download hosts for Public, Realm steamglobal
[05:41:39] 1. https://client-update.steamstatic.com, /, ... source = 'baked in'
[05:41:39] Verifying installation...
[05:41:39] Unable to read and verify install manifest
           /home/deck/.local/share/Steam/package/steam_client_ubuntu12.installed
[05:41:39] Downloading Update...
[05:41:39] Checking for available update...
[05:41:39] Downloading manifest: https://client-update.steamstatic.com/steam_client_ubuntu12
[05:41:39] Download failed: http error 0 (client-update.steamstatic.com/steam_client_ubuntu12)
[05:41:39] DownloadManifest - exhausted list of download hosts
[05:41:39] Failed to load manifest
[05:41:39] Error: Steam needs to be online to update.  Please confirm your
           network connection and try again.
[05:41:39] Shutdown
```

and from the update UI (`updateui_child.txt`):

```
[05:41:39] Fatal error: Steam needs to be online to update.  Please confirm
           your network connection and try again.
```

**Timing: the entire run took under one second** (`05:41:39` start to
`05:41:40` crash-handler). It does not hang; it does not partially start; it
fails immediately and fatally. `ps aux | grep steam` after the run: nothing
left running.

### 4. State left behind — no client

The bootstrap *was* unpacked from the local tarball (that part is offline-safe):

```
/home/deck/.local/share/Steam:
  bootstrap.tar.xz  20285684
  clientui/  linux32/  logs/  package/  steam.sh  ubuntu12_32/
```

but:

```
+ find /home/deck -name steamui.so -o -name steamclient.so
        (no output)
+ ls -la /home/deck/.local/share/Steam/package
  steam_client_metrics.bin   145 bytes
```

There is no client. `package/` contains only a metrics file — the install
manifest `steam_client_ubuntu12.installed` was never obtained.

Amusing corroboration of the isolation: the crash reporter also failed —
`Finished uploading minidump: success = no ... error: Could not resolve
hostname`.

### 5. Can a pre-populated client launch offline? (phases 3 and 4)

The obvious mitigation is "ship the client already downloaded". I tested
whether that even works, because if it doesn't, the option is dead on
technical grounds and the licensing question below is moot.

**Phase 3 (network back on):** launched Steam once and let it complete its
bootstrap. It downloaded ~420 MB of package archives and installed a
**2.5 GB** client:

```
2.5G    /home/deck/.local/share/Steam
/home/deck/.local/share/Steam/ubuntu12_32/steamui.so      (39 MB)
/home/deck/.local/share/Steam/ubuntu12_32/steamclient.so
/home/deck/.local/share/Steam/package/steam_client_ubuntu12.installed
```

**Phase 4 (`-nic none` again, client now pre-populated):** same isolation
check (loopback only, empty route table). Result — **technically it works**:

```
[06:13:30] Checking for update on startup
[06:13:30] Downloading manifest: https://client-update.steamstatic.com/steam_client_ubuntu12
[06:13:30] Download failed: http error 0
[06:13:30] DownloadManifest - exhausted list of download hosts
[06:13:30] Error: Download failed: http error 0
[06:13:30] Verifying installation...
[06:13:30] Verifying all executable checksums
[06:13:34] Verification complete            <-- and it launches anyway
```

The manifest download still fails, but **once a client is installed the
failure is no longer fatal.** The bootstrapper falls through to a checksum
verify and starts the client. Contrast with phase 2, where the same failure
produced `Fatal error … Shutdown` in under a second.

The client then came fully up — `steamui`, `webhelper`/CEF, the runtime
launcher — and reached the login screen:

```
steamui_login.txt:
[06:13:51] Client version: 1785799196
[06:13:51] [ None ] SetLoginState: WaitingForCredentials - OK
[06:13:54] [ WaitingForCredentials ] Received logon failure response   (x6)

console_log.txt:
[06:13:54] LogonFailure No Connection                                  (x6)

connection_log.txt:
[06:16:39] [Logged Off] StartAutoReconnect() will start in 235.0 seconds (attempt 6)
```

Steam stayed alive for the entire 240 s window (`steam exit=124` — killed by
`timeout`, not by itself), sitting on the login screen retrying with a backoff.
That is **exactly what a factory-reset Deck with no Wi-Fi does.**

**Conclusion of the mitigation test:** pre-populating the client converts the
first-boot experience from *"fatal error, Steam exits, black screen"* into
*"Steam's normal login screen saying it can't connect"*. It does **not** make
Gaming Mode usable offline — login still requires network. So it is a UX
improvement, not a fix for the offline claim, and it costs 2.5 GB of image
plus the licensing exposure below.


## Redistribution / licensing

Checked because the obvious mitigation is "ship a pre-populated client in the
ISO".

- Arch's package is licensed `LicenseRef-steam-subscriber-agreement`, and
  Valve's `steam-launcher` `debian/copyright` puts **all** of `Files: *` under
  `steam_subscriber_agreement`.
- The shipped `steam_subscriber_agreement.txt` (312 lines, checked with grep)
  contains **no** occurrence of "redistribut". What it does contain is a
  personal-use, non-transferable grant:
  > "Valve hereby grants, and you accept, a non-exclusive license and right,
  > to use the Content and Services for your **personal, non-commercial use**"
  > … "you may not sell, grant a security interest in or **transfer**
  > reproductions of the Content and Services to other parties in any way"
  > … "you may not, in whole or in part, copy, … reproduce, publish,
  > **distribute** …"
- Older Valve packaging carried a separate "Limited Redistribution License"
  in a `steam_install_agreement.txt` permitting redistribution of Steam *in
  its entirety* provided files with `bootstrap` in the name are unmodified.
  **That file is not present in the current 1.0.0.87 source tarball** — only
  `steam_subscriber_agreement.txt` is.
- The strongest practical signal: **every Linux distro that packages Steam
  ships only the launcher + bootstrap, never the client.** Arch, Debian and
  Valve's own `.deb` all stop at the 20 MB bootstrap. If redistributing the
  client were clearly permitted, someone would already be doing it.

**Assessment:** redistributing the launcher + bootstrap (i.e. just including
Arch's `steam` package in the offline mirror) is on the same footing as any
distro repo and is fine. Redistributing a **pre-populated Steam client** in a
public ISO is *not* clearly permitted by any document I could find, and the
absence of a redistribution clause plus the universal distro practice both cut
against it. **This needs operator/legal judgement, not an engineering
decision.** I did not find a document that authorises it.

## What this changes about the plan

1. **The headline "fully offline" claim must be qualified.** The *install* is
   genuinely fully offline — session 2 already proved that end to end (942/943
   packages from the ISO's offline mirror, `-nic none`). What is **not**
   offline is Steam's first launch. The device installs offline, boots offline,
   reaches Gaming Mode offline — and then Steam fails with
   "Steam needs to be online to update."
2. **`CLAUDE.md`'s hard constraint as written cannot be met.** "Fully offline
   install — the whole flow **through first boot into Gaming Mode**" is false
   if "into Gaming Mode" means a *usable* Gaming Mode. It is true if it means
   "the installer completes and the system boots to the Gaming Mode session".
   That wording needs an operator decision, not a quiet reinterpretation.
3. **Note this is over-determined — and phase 4 proved it.** Even with the
   client fully pre-populated, Steam reaches `WaitingForCredentials` and then
   `LogonFailure No Connection`. Login requires network. A never-signed-in
   Deck cannot reach a *usable* Gaming Mode without internet under **any**
   packaging strategy. So the honest framing already written in `PLAN.md`
   §10.4 — *"installs fully offline; Steam signs in on first launch like any
   new Deck"* — is the correct one, and it is correct for two independent
   reasons, not one. No amount of ISO engineering removes the second one.
4. **The Wi-Fi screen (`PLAN.md` §6.1a item 7) is promoted.** It stays
   skippable for the *install*, but it is now the documented path to a usable
   Gaming Mode and should say so on screen. A user who skips it must be told,
   in the installer, that Steam will need Wi-Fi on first launch — otherwise
   the first-boot experience is an undismissable fatal error dialog with no
   keyboard attached.
5. **T5 (ISO and payload) gets a new required item:** the first-boot Gaming
   Mode session must degrade gracefully. Today the failure is a Steam-owned
   modal error inside a gamescope session on a device with no keyboard. T5
   needs to detect "no network + no Steam client installed" *before* handing
   the display to Steam, and show a controller-navigable "connect to Wi-Fi"
   screen instead.
6. **T5 should still bundle the `steam` package in the offline mirror.** It is
   a legitimate 20 MB redistribution and it removes one download from the
   first-boot path. It just does not remove the network requirement.
7. **Marketing copy is now decided** and should be written as
   *"Installs completely offline. Steam signs in on first launch, exactly like
   a factory-reset Deck."* — do not claim more.

## Decision needed from the operator

1. Is the `CLAUDE.md` "fully offline … through first boot into Gaming Mode"
   constraint **reworded** to "fully offline install; Steam needs network on
   first launch", or is it treated as a real blocker that changes scope?
2. Do we attempt to ship a pre-populated Steam client in the ISO at all?
   Phase 4 shows it **works technically** and meaningfully improves first
   boot (login screen instead of fatal error), at a cost of 2.5 GB and a
   redistribution I found no document authorising — and which no Linux distro
   performs. My recommendation is **no**, and to solve the same UX problem
   with item 5 below instead (our own pre-Steam network check), which costs
   nothing and carries no licensing exposure. But the redistribution question
   is a legal call, not mine.
3. Given (1), confirm that T5 should build the "no network → controller-
   navigable Wi-Fi screen before Steam gets the display" path.

## Reproduction

Everything is in `~/scratch-r1/steamvm` (outside this repo):
`disk.qcow2` (the installed VM), `results.img` (a vfat disk with every log
quoted above), `phase1.sh`…`phase4.sh`, `phase2-console.log`, and
`qmpkeys.py` (drives the guest console over QMP `send-key`, needed because
the VM has no network in phase 2/4). Re-run phase 2 with:

```
qemu-system-x86_64 -enable-kvm -m 4096 -smp 4 -machine q35 -cpu host \
  -drive file=disk.qcow2,if=none,format=qcow2,id=os \
  -device virtio-blk-pci,drive=os,bootindex=1 \
  -drive file=results.img,if=none,format=raw,id=res \
  -device virtio-blk-pci,drive=res,serial=r1results \
  -nic none -display none -serial file:console.log
```

### Two harness notes worth keeping (both cost time here)

- **Boot order.** Attaching the `cidata` seed as a plain `if=virtio` drive
  made QEMU try to boot *it* first; the VM sat dead with an empty serial log
  and an untouched disk. Fix: give the OS disk an explicit
  `-device virtio-blk-pci,drive=os,bootindex=1`. This is worth mirroring in
  `vm-install-test.sh` if it ever grows a second data drive.
- **A `Type=oneshot` unit with both `After=multi-user.target` and
  `WantedBy=multi-user.target` never runs** — it sits as a pending job
  (`Active: inactive (dead) / Job: 260`) and blocks the target forever. The
  offline phase was ultimately driven from the guest console over QMP
  `send-key` instead. Don't use that unit pattern in T5's ISO work.

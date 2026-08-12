# T5 — the `omarchy-iso` fork: strategy, fork point, and the bake-in list

**Written 2026-08-11 (session 19), after operator decision §5.25 #8 made the ISO
build the next major piece.** This is the plan; `docs/tasks/T5-iso-and-payload.md`
remains the requirements list and is unchanged by this file except where noted.

**Model: Opus for §1–§4 and the boot-chain rows of §5. Sonnet for §7's slices.**

Everything below marked **(READ)** was read this session from the actual source —
`gh api` against `omacom-io/omarchy-iso` and `basecamp/omarchy`, or a file in this
repo. Everything marked **(INFERRED)** is reasoning over those reads and has not
been run. The distinction is kept deliberately, because §5's whole point is that
this project's recurring failure is a check that passes for the wrong reason.

---

## 0. The one finding that should change what you do first

🔴 **A fork taken at `a12bfea` and built today produces a broken ISO, and it
would fail two-thirds of the way through an install.** This is not a prediction;
all three halves were measured this session.

| Fact | Value | How it was established |
|---|---|---|
| Our fork point calls | `/usr/bin/omarchy-setup-system` | `phases_impl.py` @ `a12bfea`, `run_system_finalizer` **(READ)** |
| Our pinned runtime ships | `bin/omarchy-setup-system` | `basecamp/omarchy` tree @ `6d7826d` **(READ)** |
| **The `edge` channel serves TODAY** | **`omarchy-dev-4.0.0.r1652.g1c9dfc5-1`** | `https://pkgs.omarchy.org/edge/x86_64/omarchy.db`, fetched and unpacked **(READ)** |
| …and `1c9dfc5` ships | `bin/omarchy-apply-system` **only** | `basecamp/omarchy` tree @ `1c9dfc5` **(READ)** |

`basecamp/omarchy` commit **`536fcd5c`** ("Move install-time plumbing out of the
setup namespace", 2026-08-10T21:14:57Z) did the rename; `omarchy-iso` commit
**`d6cd2d30`** ("Call the renamed omarchy-apply-system finalizer",
2026-08-10T21:15:24Z) followed it **27 seconds later**. `1c9dfc5` is 18 commits
past the rename; `6d7826d` is 18 commits before it.

**The consequence, and it is the load-bearing sentence of this document:**

> The fork point does **not** pin the product. `builder/build-iso.sh` downloads
> `$OMARCHY_RUNTIME_PACKAGE` from `pacman-online-$OMARCHY_MIRROR.conf` at build
> time **(READ, lines 149-157)**, and `edge` is a rolling channel with no history.
> The git ref and the package channel are two independent pins, and **they are
> already out of agreement.** `docs/PROGRESS.md` §3.10 gotcha 1 said "ref and
> mirror must agree" and meant `quattro`-vs-`stable`; the sharper form is that
> **`omarchy-iso@<sha>` and `omarchy-dev@<sha>` are one coupled pair**, and only
> one of them is expressible in git.

Where it fails, if you build it anyway: the fifth phase, `"Configuring system"` →
`run_system_finalizer` → `arch-chroot … /usr/bin/omarchy-setup-system` → ENOENT,
after partitioning, LUKS, pacstrap and ~1200 packages. **(INFERRED** from the
call site and the phase list; nobody has run it.**)**

---

## 1. Fork strategy — **thin overlay on a vendored pinned tree, not a hard fork**

**Recommendation: a `overlay/` directory of patches and additive files in THIS
repo, applied to an upstream checkout pinned by SHA, with `omarchy-iso` vendored
as a git submodule. Not a GitHub fork, not a long-lived divergent branch.**

### The shape

```
iso/
  UPSTREAM                 one line: omacom-io/omarchy-iso@<sha>   (the git pin)
  RUNTIME                  one line: basecamp/omarchy@<sha>        (the package pin)
  upstream/                git submodule, checked out at UPSTREAM's sha
  overlay/
    configs/airootfs/...   additive files, copied over the checkout
    patches/*.patch        the few edits that must modify upstream files
  bin/build                one command; the T5 "done when" entry point
```

`bin/build` does, in order: verify the submodule is exactly at `UPSTREAM`
(refuse otherwise); `rsync` `overlay/` over a scratch copy of it; `git apply
--3way` the patches, failing loudly on any reject; run the guards in §6; then
`omarchy-iso-make`'s work with the three §3.10 fixes.

### Why this and not a hard fork

1. **Upstream moves several times a day, and the moves matter.** Four commits
   landed on `quattro` between our fork point and its HEAD in nine hours
   **(READ)**, and one of them was a breaking rename. A hard fork's rebases would
   be a permanent tax; an overlay makes each upgrade an explicit, reviewable
   `UPSTREAM` bump with a patch-apply step that fails loudly on conflict — which
   is exactly the signal we want and exactly what a fork's merge commit hides.
2. **The measured diff is tiny.** Everything in §5 lands in: one new
   orchestrator module, one line in `main.py`'s phase list **(READ:
   `build_phases`, 14 phases)**, ~10 lines in `builder/build-iso.sh`, one new
   `configs/pacman-online-*.conf` stanza, and a handful of additive files. That
   is patch-shaped, not fork-shaped.
3. **Phase 4 wants a portable Deck-enablement layer** (`docs/PROGRESS.md` §5.19,
   `docs/tasks/T7-enablement-layer.md`). An overlay forces the discipline that
   makes that possible: anything that could live in the `omarchy-deck` *package*
   must not be a patch to the builder. Concretely — **patches are only allowed
   for build-time behaviour; everything install-time goes in the package.** With
   a hard fork there is no pressure to keep that line, and the layer stops being
   extractable. Track it: today's target is **≤ 4 patch files**, and a fifth
   should have to argue for itself.
4. **Licence and provenance.** `omarchy-iso` is MIT **(READ:** repo metadata**)**,
   so vendoring is unencumbered; the submodule records the exact upstream commit
   without us republishing their tree.

### What this costs, stated honestly

A submodule plus a patch stack is more moving parts than a fork, and
`git apply` conflicts are less pleasant than merge conflicts. Accepted, because
the alternative loses the property in point 3, and because the conflict is the
*point*: an upstream change that touches a line we patched must stop the build.

---

## 2. Fork point — **`omacom-io/omarchy-iso@a12bfea7a86c`, paired with
`basecamp/omarchy@6d7826d`, and the pair pinned by BUILD, not by channel**

### Why `a12bfea` and not HEAD

- It is what our ISO *and* Omarchy's published beta 2 were both cut from —
  established by content-diff, not by a stamp (`docs/findings/T9-iso-comparison.md`
  §3). Everything measured in P15/P17/P18/T9 is measured against this tree. A
  different fork point silently invalidates that evidence base.
- Operator decision §5.25 #6 is **"wait for 4.0 stable rather than moving to
  edge now."** Taking `d6cd2d30` would be moving, quietly, on the ISO side only.
- It is self-consistent with `6d7826d`: `omarchy-setup-system` on both sides
  **(READ)**.

### Which finalizer name our fork must use — **`omarchy-setup-system`, and it
must stop being a name at all**

At `a12bfea` + `6d7826d` the answer is `omarchy-setup-system`, so **the fork
needs no change to `run_system_finalizer`**. That is the correct answer *today*
and it will be wrong the moment the runtime pin moves. So the fork ships a guard
instead of a decision (§6.4).

### 🔴 The pin that does not exist yet, and must

`OMARCHY_MIRROR=edge` is not a pin. It resolved to `r1617.g6d7826d` on
2026-08-10 and resolves to `r1652.g1c9dfc5` today **(READ)**. Three ways to
close it, in preference order:

| # | Mechanism | Verdict |
|---|---|---|
| **A** | **`omarchy-iso-make --local-source <omarchy-checkout> <pkgs-checkout>`** — builds `omarchy-dev`, `omarchy-settings-dev`, `omarchy-nvim` from pinned git checkouts straight into the offline mirror, and `build-iso.sh` then *excludes* them from the network `-Syw` **(READ, lines 101-104, 205-213, 246-266)** | ✅ **Adopt.** It is upstream's own supported path, it needs `basecamp/omarchy@6d7826d` + `omacom-io/omarchy-pkgs` (both exist, both public), and it makes `RUNTIME` a real pin |
| B | Freeze a local copy of the whole offline mirror and build from `file://` | Rejected for now: ~6 GB of packages to store and re-host, and it freezes *Arch* too, which we do not want |
| C | Accept the channel and move `UPSTREAM` to whatever ISO commit matches it | Rejected: it makes the product's most important input untrackable, and it silently contradicts operator decision #6 |

⚠️ **A pins only the three `omarchy-*` packages.** Arch's `core`/`extra`/
`multilib` still roll through `mirror.omarchy.org`. That is the same posture as
any archiso build and is fine — but it means "reproducible" in §5's "Build
reproducibly" means *"same inputs by declaration"*, not *bit-identical*. Say so
in the T5 done-when list rather than implying more.

---

## 3. Where the fork's changes go — the seams, all read this session

Six seams, and knowing them is most of what makes the rest cheap.

| # | Seam | What it is for | Evidence |
|---|---|---|---|
| S1 | `builder/build-iso.sh` after the runtime package is unpacked (line ~157) — append to `base_pkg_lists` **before** the shipped copy is made | Adds our packages to the mirror download, the shipped `omarchy-base.packages`, **and** the `expected-packages` denominator in one place. Appending later would desync the three | **(READ,** lines 149-168, 191-200, 299-309**)** |
| S2 | `configs/pacman-online-edge.conf` | Where the offline mirror is downloaded *from*. Valve's repos go here, shaped exactly like the existing `[arch-mact2]` block (`SigLevel = Never`) | **(READ)** |
| S3 | `main.py`'s `build_phases` list — one new phase, `("Configuring Steam Deck", configure_deck)`, **after** `run_system_finalizer` and **before** `finalize_limine_boot` | The only place a target-side change survives. `omarchy-setup-system` runs `install/post-install/pacman.sh`, which **overwrites `/etc/pacman.conf` wholesale** and then sources `install/hardware/pacman.sh` — so anything written before it is destroyed | **(READ:** `build_phases`; omarchy `install/post-install/pacman.sh`**)** |
| S4 | The `omarchy-deck` **pacman package**, built by us, dropped in the offline mirror | Everything install-time. `docs/PROGRESS.md` §3.1's architecture, unchanged | — |
| S5 | `/etc/skel` on the target | Omarchy 4.0's own documented seam for per-user config: `omarchy-provision-user --help` says *"For shipped configs see /etc/skel (new users)"* **(READ)** | **(READ)** |
| S6 | `~/.config/omarchy/hooks/pre-refresh-pacman.d/` | The only supported way to survive `omarchy refresh pacman`, which copies the channel template over `/etc/pacman.conf` **(READ:** `bin/omarchy-refresh-pacman`**)** | **(READ)** |

### 🐞 Two traps inside those seams, both new this session

**(a) `/etc/skel` is too late for the user the ISO creates.** `useradd` happens
inside `arch_install_system` **(READ:** the phase docstring**)**, which is phase 3
of 14 — before S3's phase. So a `configure_deck` that writes only `/etc/skel`
produces a Deck whose *first and only* user still comes up rotated. **Every
`/etc/skel` row in §5 must write both places**, and its verification must read
the created user's home, not skel. A check that reads only `/etc/skel` is the
canonical passes-for-the-wrong-reason failure for this task.

**(b) `omarchy-hook` swallows hook failures.** `bash "$hook" || echo "Hook
failed: $hook"` **(READ:** `bin/omarchy-hook`**)** — a failing
`pre-refresh-pacman` hook prints a line and `omarchy-refresh-pacman` proceeds to
`pacman -Syyuu` with the Valve repos gone. It is also strictly per-user
(`$HOME/.config/omarchy/hooks/`), with no system-wide directory, and it skips
`*.sample`. So S6 alone is not a guarantee: the repos need a second, asserting
check (an ALPM `PostTransaction` hook on `pacman`, or a `deck-session.sh`
precondition) that *notices* their absence. This is precisely `CLAUDE.md`'s
"never silently swallow a failure", inherited.

---

## 4. The two decisions asked for

### 4.1 Bundle vs fetch for `steamdeck-dsp` — **FETCH, but the honest version is
"fetch, in a phase that fails loudly when it cannot"**

`steamdeck-dsp` is `Licenses: Proprietary` with no licence text shipped
(`docs/findings/P16-redistribution-and-trademark.md` §1). Bundling it into the
offline mirror redistributes it; fetching it from Valve's own mirror at install
time does not. §2.2 retired the offline constraint and §5.1 proved the live ISO
associates to Wi-Fi on the OLED Deck, so fetching is available.

**But this is a bigger change than P16 assumed, and P16 could not have known it.**
Upstream's install is **entirely offline by construction**: the live
`/etc/pacman.conf` is `[offline] file:///var/cache/omarchy/mirror/offline/` and
nothing else **(READ)**, `build-iso.sh` copies that same file into the target
**(READ,** line 346**)**, and its own comment says *"The install is entirely
offline and the live environment needs no Wi-Fi driver"* **(READ,** line 131**)**.
So "fetch" is not "leave it out of the mirror" — it is *"`configure_deck` brings
the network up, points the target at a network `pacman.conf`, and installs a
named set."*

Which gives the clean split:

| Package | Route | Why |
|---|---|---|
| `linux-neptune-*` + headers, `linux-firmware-neptune` | **Bundle** (S1+S2) | GPL-2.0; redistributable with a source offer, and the machine must boot before it can fetch anything |
| `jupiter-staging/gamescope`, `mangohud`, `lib32-mangohud`, `lib32-vulkan-radeon` | **Bundle** | MIT / stock Arch. Nothing to fetch for |
| **`steamdeck-dsp`** | **Fetch**, in `configure_deck`, after the repos are configured | Proprietary, no grant |
| `steam` | **Fetch** | Steam Subscriber Agreement; installers normally fetch it, and it is huge |

⚠️ **The failure mode this creates, and the rule that goes with it:** an install
with no network now yields a Deck that boots, has a desktop, has Gaming Mode's
session — and has tinny speakers and no Steam. That is a *degradation*, which is
the shape `CLAUDE.md` forbids being silent about. So `configure_deck`'s fetch
step must (i) state on screen that it needs the network, (ii) record the outcome
in `/var/log/omarchy-deck-install.json`, and (iii) leave a first-boot unit that
retries and *tells the user* — not a silent skip. **The offline install must
still succeed**; it is the silence that is banned, not the degradation.

### 4.2 Fork strategy — decided in §1. Overlay + submodule, ≤ 4 patch files.

---

## 5. The bake-in list — six items, each with a place and a check

Rules for this table, and they are the reason it exists:

- **"Where" names a file in the build, not a concept.**
- **"Verified by" must be able to FAIL.** A row whose verification is "we set
  it" is not finished. Every row below is verified by reading the artefact back
  through the same path the *product* reads it, on a surface where the value
  could have been absent.
- Three tiers of check, and each row says which it has:
  **[B]** build-time (fails `bin/build`) ·
  **[V]** QEMU install assertion (`test/vm/vm-install-test.sh`, after a real install) ·
  **[H]** hardware, eyes on the panel (T6 release gate).

---

### 5.1 Boot to Gaming Mode by default

**Source:** `docs/PROGRESS.md` §5.23 item 1 + §5.25 #4. The product's promise is
"boots to Gaming Mode like stock SteamOS"; today only a hand-run
`stage-default-session` delivers it.

**Where:** `configure_deck` (S3) writes, on the target:
`/etc/sddm.conf.d/zz-deck-session.conf` with `[Autologin] User=<ctx.username>` +
`Session=gamescope-wayland`, and `/var/lib/sddm/state.conf` with the same
`Session=`. The name `zz-…` is not cosmetic — `src/deck-session.sh:361-371`
records the bug where an earlier `95-…` sorted *before* `autologin.conf` and
never applied. Reuse the exact same filename and content the stage writes, so
image and stage cannot disagree.

> 🔴 **This row is coupled to 5.5, and nobody had noticed.**
> `configure_login` writes `autologin.conf` **only** `if ctx.encrypt and not
> ctx.defer_provisioning` **(READ,** `phases_impl.py:1417-1427`**)** — encrypted
> installs get autologin because the LUKS prompt is treated as the auth
> boundary. **Turning encryption off therefore deletes autologin**, and a
> keyboard-less Deck lands on an SDDM password prompt: exactly §5.18's failure,
> re-created by our own change. Whatever `configure_deck` does, it must
> *guarantee* an autologin drop-in exists in the unencrypted case. Do 5.1 and
> 5.5 in the same slice or neither.

**Verified by:**
- **[V]** after a QEMU install, `Session=gamescope-wayland` is present in
  `/etc/sddm.conf.d/zz-deck-session.conf` **and** `zz-…` sorts last among
  `/etc/sddm.conf.d/*.conf` — assert the *ordering*, not just the content, since
  that is the defect that actually shipped once.
- **[V]** an autologin `User=` exists **with encryption off** (the coupling above).
- **[H]** T6: power on, and the Deck reaches Gaming Mode with nobody typing.

---

### 5.2 Both rotations (three surfaces)

**Source:** `docs/PROGRESS.md` §5.11, T5 task file's rotation table, §5.25 #5.

| Surface | Value | Where in the build |
|---|---|---|
| Omarchy desktop | `transform 3`, `scale 1.25` in `monitors.lua` | `configure_deck` writes `/etc/skel/.config/hypr/monitors.lua` **and** `~<user>/.config/hypr/monitors.lua` (trap 3a). `omarchy` ships `config/hypr/monitors.lua` **(READ)**, so the path is real |
| Limine menu | `interface_rotation: 270` | ⚠️ **The template, not `/boot/limine.conf`.** `omarchy-refresh-limine` does `mv /boot/limine.conf aside; cp $OMARCHY_PATH/default/limine/limine.conf /boot/limine.conf` **(READ)**, and that template has no `interface_rotation` **(READ,** the whole 20-line file**)**. So `configure_deck` must patch `/usr/share/omarchy/default/limine/limine.conf` **and** `/boot/limine.conf`, before `finalize_limine_boot` runs `limine-update` |
| TTY | `fbcon=rotate:1` on the kernel cmdline | `/etc/kernel/cmdline` + `/etc/default/limine`, both written by `_write_limine_defaults` **(READ,** lines 534-564**)**. Boot-chain change — **operator-approved 2026-08-11** (§5.25 #5) |

⚠️ **The template is a packaged file** — `omarchy-dev` owns
`/usr/share/omarchy/default/limine/`, so the next runtime upgrade reverts our
patch. It needs an ALPM `PostTransaction` hook in the `omarchy-deck` package,
triggered on `omarchy-dev`/`omarchy-settings-dev`, that re-applies it. That hook
is the same *shape* as the one `docs/PLAN.md` §11 already calls for, and is
Opus-routed work.

**Verified by:**
- **[B]** the built ISO's `omarchy-deck` package contains the rotation values —
  grep the package, not the source tree.
- **[V]** after install: `interface_rotation: 270` present in **both**
  `/boot/limine.conf` and `/usr/share/omarchy/default/limine/limine.conf`;
  `fbcon=rotate:1` in `/etc/kernel/cmdline`; `transform` = 3 in the **created
  user's** `monitors.lua` (not skel's).
- **[V]** the *destruction* test, which is the only one that proves the fix:
  run `omarchy refresh limine` in the installed target, then re-assert
  `interface_rotation`. Without this the row passes for the wrong reason —
  §5.11's entire point is that a hand edit survives kernel updates but not that
  command.
- **[H]** 🔴 T6, mandatory: **`270` has never been seen on a screen.** §5.11's
  history is a recorded transform that turned out upside down. Look at the panel.

---

### 5.3 The three load-bearing session settings

**Source:** `docs/PROGRESS.md` §5.20 (the two GSettings), R-38 (the idle policy),
`src/deck-session.sh:167-207` for the exact constants.

| Setting | Value | Where |
|---|---|---|
| `org.gnome.desktop.a11y.applications screen-keyboard-enabled` | `true` | `/etc/dconf/db/local.d/50-deck-desktop` **+ `/etc/dconf/profile/user` containing `user-db:user` and `system-db:local`** — without the profile the site db is never read at all and every default is inert (`src/deck-session.sh:1911-1932`) **+ `dconf update`** to compile it |
| `org.gnome.desktop.input-sources sources` | `[('xkb','us')]` | same file |
| Omarchy idle | `{"screensaver": 150, "lock": 86400}` in `.config/omarchy/shell.json` | `/etc/skel/.config/omarchy/shell.json` **and** the created user's copy, **seeded from `/usr/share/omarchy/config/omarchy/shell.json` and patched as JSON** — a user `shell.json` *replaces* Omarchy's defaults rather than merging, so an idle-only file silently strips the bar (`src/deck-session.sh:1991-2001`) |
| **The OSK's XKB layout** — `hl.device({ name = "deck-input-mapper-virtual-keyboard", kb_layout = "us", … })` | per-device `us` | the created user's `~/.config/hypr/input.lua`, spliced between `-- >>> deck-session.sh: on-screen keyboard XKB layout >>>` markers by `install_osk_kb_layout_rule` |

🆕 **The fourth setting, added 2026-08-12 (`docs/PROGRESS.md` §5.20).** The OSK
draws a US layout and emits raw **keycodes** through the mapper's uinput device;
which *character* that becomes is decided by the XKB keymap the compositor has
bound to that device. The installer writes the user's chosen layout into
`/etc/vconsole.conf`, Omarchy's `default/hypr/input.lua` reads `kb_layout`
straight out of it, and on the test Deck (`XKBLAYOUT=latam`) the OSK's `;` key
types `ñ`. **Any install where the user picks a non-`us` keyboard reproduces
this**, so it is a bake-in item and not a test-Deck artefact.

⚠️ **PER DEVICE. Not `input.kb_layout`.** Operator decision 2026-08-12:
physical keyboards and the rest of the desktop keep the chosen layout; only our
virtual keyboard is pinned. A session-wide fix is explicitly rejected.

⚠️ **The rule is declared for the suffixed aliases too** (`…-1`, `…-2`, `…-3`).
Our uinput device declares keys *and* relative axes, so Hyprland binds it twice
and appends a counter to whichever copy loses the race for the bare name —
measured: keyboard bare, pointer `-1`, and nothing promises that order.

⚠️ **This is the same file that carries the OSK's `above_lock = 2` layer rule**
(5.6). Both live in one user's `~/.config/hypr/input.lua`, both are absent from
a built image, and whatever bakes one in must not clobber the other. The splice
is marker-delimited and preserves everything outside its own block precisely
because of that.

**Verified by:**
- **[V]** after a QEMU install, `~/.config/hypr/input.lua` on the target
  contains the block and still parses (`luac -p`).
- **[H]** T6, and it is the only tier that can settle it: with the mapper
  running, `hyprctl -j devices` must show `deck-input-mapper-virtual-keyboard`
  at `"layout": "us"` **while every other keyboard keeps the session layout** —
  the second half is what distinguishes the fix from the thing the operator
  refused. `stage-desktop-settings` asserts both automatically when it runs
  against a live compositor.

⚠️ **`lock: 0` locks INSTANTLY.** There is no off sentinel. Disabling means a
large value, and past ~24.8 days it overflows a QML int32 timer. `86400` is the
chosen constant; do not "simplify" it to `0` or `-1`.

⚠️ These belong on the **installed system only**. §2.6 is explicit: they do
**not** go in the live ISO, where squeekboard does not exist and there is no
`libwayland` at all (`docs/findings/T9-iso-comparison.md` §5a). The installer's
keyboard is T8's, drawn by us.

**Verified by:**
- **[V]** `dconf read -d <key>` in the installed target — **`-d`, not a plain
  read.** A plain `dconf read`/`gsettings get` returns the *user's* value and
  would pass while the site default was missing. This is the single most
  copy-pasteable mistake in the whole table (`src/deck-session.sh:1948-1963`).
- **[V]** the shell.json check asserts *both* the idle values **and** that the
  file still has > 1 top-level key — i.e. that the bar was not stripped.
- **[V]** assert `lock` is a large number **and not `0`**, as its own case.
- **[H]** T6: focus a text field in Desktop Mode and see the keyboard.

---

### 5.4 EXCLUDE `/etc/sudoers.d/99-deck-testing`

**Source:** `docs/PROGRESS.md` §5.17 + operator decision §5.25 #7 — the test Deck
**keeps** it, the ISO must **refuse** to carry it, and it must FAIL THE BUILD.

**Where:** ✅ **Started in-tree this session** — `tools/iso-payload-audit.sh`,
with 16 assertions in `test/unit/test-iso-payload-audit.sh`. `bin/build` calls it
on: the overlay tree, the assembled `airootfs` work dir, our `omarchy-deck`
package, and the offline mirror directory. It:

- shares the predicate with `stage-audit-privileges` **by sourcing**, not
  copying, and fails loudly if either function is renamed;
- keeps *blanket* and *passwordless* separate, so the ordinary
  `deck ALL=(ALL) ALL` is reported and tolerated (the false positive that gets a
  release check ignored — §5.17);
- reads **inside `.pkg.tar.*` archives**, because that is the most likely route
  by which our own drop-in would ship;
- **refuses to pass vacuously**: a missing root, an unreadable archive, a missing
  `bsdtar`, or no arguments are all errors, and the summary always prints the
  denominator it inspected.

**Verified by:**
- **[B]** `bin/build` runs it and a non-zero exit stops the build.
- **[B]** the unit suite proves the *negative* case: a fixture payload containing
  the exact `99-deck-testing` line exits 1 and names the file. A guard nobody has
  seen fail is not a guard.
- **[V]** after a QEMU install, `/etc/sudoers.d/` on the target contains no
  passwordless blanket grant.

---

### 5.5 Encryption OFF by default

**Source:** `docs/PROGRESS.md` §5.12; `root/configurator` line 601
`local mode="encrypted"` and line 895 for the second disk path
(`docs/findings/T9-iso-comparison.md` §5b **(READ)**).

**Where:** a patch to `overlay/patches/` flipping both `mode=` defaults and the
affirmative strings, so the *hidden-behind-Ctrl+C* path becomes encryption
rather than the reverse. Do **not** try to do this from the config file: the
default is what a controller-only user gets by pressing A, and that is the whole
requirement.

⚠️ **This is the one place where "just change the default" is not enough** — see
5.1's coupling box. Flipping it without adding an unconditional autologin
drop-in swaps an unanswerable LUKS prompt for an unanswerable SDDM prompt.

⚠️ TPM2 auto-unlock stays a follow-on, not a release blocker (§5.12). Do not let
it re-enter scope here.

**Verified by:**
- **[B]** grep the patched `configurator` for `mode="unencrypted"` at both sites
  — cheap, and it catches a patch that applied to only one of them.
- **[V]** an automated QEMU install driven through the *interactive* path (not a
  cidata autoinstall, which bypasses the default) produces a target with **no
  `/etc/crypttab` LUKS entry and no `cryptdevice=` on the cmdline**. Assert the
  absence on the installed artefact, not the configurator's output file.
- **[V]** and the *positive* half: `/etc/sddm.conf.d/` still yields an autologin.

---

### 5.6 🔴 The lock producers

**Source:** `docs/PROGRESS.md` §5.24, `docs/findings/T9-lock-service-mitigation.md`
§1.4 and §5, operator decision §5.25 #1. A fresh install from our ISO must not be
lockable into a password prompt nobody can answer.

Three producers **(READ,** all four unit/script files**)**; the idle one is
already covered by 5.3.

| Producer | Fix | Where |
|---|---|---|
| Idle timeout | `idle.lock = 86400` | 5.3 |
| 🔴 `omarchy-sleep-lock.service` — `systemd-inhibit` on logind's `PrepareForSleep`. **Press the power button and it locks.** Enabled unconditionally by `install/user/first-run/enable-user-units.sh` **(READ)** | **mask it** | `configure_deck` writes the mask symlink for the created user **and** into `/etc/skel/.config/systemd/user/` — ⚠️ the enabling happens at **first run**, in the live session, *after* our phase, so masking must be in place before then. A `--global` mask under `/etc/systemd/user/` is the version that cannot lose the race |
| 🔴 `system.lock` in `omarchy-menu.jsonc:32` — deliberate, but still unanswerable | **`above_lock = 2`** for our OSK | `hl.layer_rule({ match = { namespace = "deck-osk" }, above_lock = 2 })` in `/etc/skel/.config/hypr/input.lua` + the created user's, beside the rotation |

⚠️ State the security trade-off in the code comment **and** in `docs/RECOVERY.md`:
**a suspended Deck resumes unlocked, deliberately, because it has no keyboard.**

⚠️ `above_lock` is a **Hyprland** name on Hyprland's release schedule — and this
delta already showed upstream renaming things under us. Assert the rule took;
do not assume it.

⚠️ **`input.lua` REPLACES upstream's `default/hypr/input.lua` wholesale** —
Hyprland does not merge a user override with the shipped default, so a file
carrying only this rule silently drops `kb_layout`, the non-Latin-layout
handling, `numlock_by_default` and the touchpad block. The stage that writes it
must mirror the whole upstream file (`docs/findings/T9-lock-wake-and-blank-timing.md`
§5.1 has the transcription, `luac -p`-clean, plus §5.24a row 1's two `misc`
lines) and must not clobber 5.3's marker-delimited OSK-layout block.

#### 🔴 The text this must bake in, comment included

The rule is not the whole item. Hyprland answers a **Lua syntax error by
discarding the entire file**, silently, with `hyprctl configerrors` still clean
— so the file needs a parse sentinel, and the sentinel needs a probe that can
actually fail. Both go in:

```lua
-- docs/PROGRESS.md §5.24: draws deck-osk above a lock surface AND makes it
-- hit-testable there. Hardware-verified 2026-08-11.
hl.layer_rule({ match = { namespace = "deck-osk" }, above_lock = 2 })

-- Deliberately the LAST statement. A Lua syntax error ANYWHERE above makes
-- Hyprland discard this whole file without logging a reason, taking the rule
-- above with it -- and that rule is what makes the lock screen answerable on a
-- device with no physical keyboard. Verify the file loaded with an ASSERTION:
--
--   hyprctl eval 'if DECK_INPUT_LUA_LOADED == nil then error("input.lua was discarded") end'
--
-- exit 0 = loaded, exit 7 = discarded (the message is printed). Over SSH,
-- export HYPRLAND_INSTANCE_SIGNATURE first or it never runs at all (R-46).
DECK_INPUT_LUA_LOADED = true
```

🔴 **Do NOT transcribe the comment currently on the operator's Deck.** That file
tells the reader to verify with a bare Lua `return` of the sentinel and says *"A
nil result means this file was discarded"* — **measured false 2026-08-12**:
`hyprctl eval` prints `ok` and exits **0** for every expression that does not
raise, a name that has never existed included (`return DECK_NOPE` → `ok`, exit
0). It reports its own status, never the value. Only a Lua `error()` surfaces.
That readback has never been able to fail, and it has already been cited once as
proof that a config change had loaded when it was not proof
(`docs/PROGRESS.md` §5.30c). `verify_osk_kb_layout` in `src/deck-session.sh` is
the reference implementation of the working shape — copy it rather than
inventing a variant, and `test/unit/test-hyprctl-syntax.sh` scanner 3 fails the
build if the readback form is written down anywhere in this repo again.

**Verified by:**
- **[V]** after install: `systemctl --user is-enabled omarchy-sleep-lock.service`
  reports `masked` **for the created user** — and separately, that
  `enable-user-units.sh` running afterwards does not un-mask it. The second
  assertion is the one that matters; the first can pass while the race is lost.
- **[B]** the exact rule string **and** the sentinel assignment are present in
  the file we wrote, and the file passes `luac -p` (unit-testable without
  hardware).
- **[V]** the file **loaded**, asserted against a live compositor in the QEMU
  target, not merely written:
  `hyprctl eval 'if DECK_INPUT_LUA_LOADED == nil then error("input.lua was discarded") end'`
  — exit 7 fails the row.
  ⚠️ **`hyprctl configerrors` being empty is NOT this check.** It is empty in
  exactly the case that matters: a discarded file produces no config errors
  because none of it was ever parsed into config. An earlier version of this row
  used it, which made the row unable to fail.
- **[H]** 🔴 T6, and it is the item with the least evidence behind it: press the
  power button, suspend, resume — **no lock screen**. Then choose "Lock" from the
  menu and confirm the OSK is *visible and hit-testable* over the lock surface.
  `docs/findings/T9-lock-service-mitigation.md` §6 lists this as unverified #4;
  §5.24 has since verified it in pixels on the operator's Deck, but never from a
  built image.

---

## 6. Build-time guards — the three inherited, plus two new

`docs/PROGRESS.md` §3.10's three are inheritance, not trivia. All three
confirmed in source this session.

**6.1 Ref and mirror must agree.** `omarchy-iso-make` defaults are
`OMARCHY_ISO_REF=quattro` / `OMARCHY_MIRROR=stable` **(READ,** lines 111-112**)**,
which disagree. Note also that `--quattro` sets `OMARCHY_INSTALLER_REF` — a
variable **nothing reads** **(READ,** line 44**)**; it works only because the
default ref is already `quattro`. `bin/build` sets both explicitly and refuses to
run with either unset. *(This is also why our ISO stamped
`/root/omarchy_iso_ref = quattro` where upstream's beta 2 says `edge`
— `docs/findings/T9-iso-comparison.md` §2 called it cosmetic and it is, but the
cause is this bug.)*

**6.2 Keep the questionless-installer guard.** `build-iso.sh:174-186` **(READ)**
exits 1 with *"this ISO would boot into an installer with no questions to ask"*
when the runtime ships no `setup-form.sh`. **Do not weaken it.** It is the
discipline `docs/PLAN.md` §8.1 wishes more tooling had. Our fork adds guards in
the same shape — including the two below and `resolve_expected_packages`'
existing *"pacman -S --print aborts if any target is missing, so this almost
certainly means pacstrap would fail the same way"* **(READ,** lines 328-334**)**,
which is free coverage for S1's package additions.

**6.3 Do not inherit the pacman-cache `rm -rf`.** `bin/omarchy-iso-make:103` is
literally `sudo rm -rf /var/cache/pacman/pkg/*`, and line 137 bind-mounts the
host's cache **read-write** into a privileged container **(READ)**. On this dev
machine that cache holds 2700+ packages. `bin/build` points the container at a
scratch dir under `iso/.cache/` instead — same rebuild speed, no blast radius.

**6.4 🆕 The runtime/finalizer coupling guard — the one §0 says we need.**
After the runtime package is downloaded or built, extract it and assert that
**every `/usr/bin/omarchy-*` the orchestrator shells out to actually exists in
it**. Derive the list by grepping our patched `phases_impl.py` for
`/usr/bin/omarchy-` rather than hard-coding it, so the guard cannot go stale
against our own edits. Fail with the two versions named. Cost: one `bsdtar` and
a grep. It converts the §0 failure from "dies at phase 5 of an install" into
"the build refuses, and says why".

**6.5 🆕 The payload audit.** §5.4. Already written.

---

## 6a. 🆕 The THIRD pin — `iso/PKGS`, decided 2026-08-12

T5b wired `--local-source`, and doing so exposed an input this plan never
counted: **`omacom-io/omarchy-pkgs`**, the PKGBUILD recipes that decide what
actually lands in `/usr/bin`. §2 treats the build as two pinned inputs; it is
**three**.

That is not bookkeeping. `docs/findings/T5a-parity.md` failed on exactly this
class of problem — an ISO whose runtime shipped `omarchy-apply-system` and no
`omarchy-setup-system`, the binary its own installer shells out to, so it dies
at phase 5 of 14 after partitioning and ~1200 packages.

**Operator decision 2026-08-12: pin to `ae07234a016c`** (2026-08-10 14:42) —
the last `omarchy-pkgs` commit before our known-good reference ISO was cut at
15:24 the same day.

⚠️ **This is dated proximity, not evidence.** Nothing inside the ISO records
which `omarchy-pkgs` commit built it; the image carries the *runtime's* version
string (`omarchy-dev-4.0.0.r1667.g4727bad`), not a recipe SHA. The pin is the
best available inference and should be re-checked if a build behaves oddly.

🔴 **A FOURTH input is still unpinned and cannot be pinned here.**
`omarchy-nvim`'s PKGBUILD fetches `LazyVim/starter` from `heads/main.tar.gz`
**at build time**. So even with all three pins in place, two builds a week apart
can differ. Nobody had counted this either. It is upstream's PKGBUILD, so the
options are to accept it, patch it in our overlay, or drop the package — a
decision this plan does not yet make.

---

## 7. Slices — what the next sessions actually do

Each is independently landable and independently testable. Sizes are relative,
not hours.

| # | Slice | Depends on | Model | Size |
|---|---|---|---|---|
| **T5a** | `iso/` skeleton: submodule at `a12bfea`, `UPSTREAM`/`RUNTIME` pin files, `bin/build` that applies an empty overlay and produces a byte-comparable ISO. **Guards 6.1 + 6.3 land here.** Prove parity against `~/ISOs/omarchy-2026.08.10-…iso` before changing anything | — | Sonnet | M |
| **T5b** | Guard 6.4 (runtime/finalizer coupling) + wire `--local-source` so `RUNTIME` is a real pin | T5a | Opus | S |
| **T5c** | S1 + S2: Valve repos into `pacman-online-edge.conf`, Deck packages into the mirror, `lib32-vulkan-radeon` pinned. Assert a dry run shows **zero** NVIDIA packages (§3.8) | T5a | Sonnet | M |
| **T5d** | The `omarchy-deck` package + `configure_deck` phase (S3/S4) — the skeleton only, with 5.4's audit wired into `bin/build` | T5c | Sonnet | M |
| **T5e** | Bake-ins **5.1 + 5.5 together** (they are coupled), then **5.3**, then **5.6** | T5d | Opus for 5.1/5.5/5.6 | L |
| **T5f** | Bake-in **5.2** (three surfaces + the ALPM re-apply hook + the `omarchy refresh limine` destruction test) | T5d | Opus (boot chain) | M |
| **T5g** | Script-override loader mount layout (T5 step 3), size number (step 4), CI job (step 5) | T5c | Sonnet/Haiku | S |

**Do not start T5c before T5a proves parity.** An overlay whose base build was
never shown to reproduce the known-good ISO cannot attribute any later failure.

### 🔴 Outcome, 2026-08-11 — T5a's first artifact: parity NOT proven. **Swap T5b and T5c.**

`docs/findings/T5a-parity.md` measured the 2026-08-12 build against
`~/ISOs/omarchy-2026.08.10-…iso`. Split verdict:

- **Pipeline ✅ proven.** The ISO9660 layouts differ by exactly one filename —
  the build-timestamp `.uuid`. Every `omarchy-iso@a12bfea`-sourced file is
  byte-identical, including `root/configurator`. No orphan paths, no
  `__pycache__` artefact, 56/56 offline-package changes are *upgrades* (so the
  guard-6.3 persisted cache is not serving stale packages), and two runs five
  hours apart are identical. **Driving `builder/build-iso.sh` instead of
  `omarchy-iso-make` changed nothing in the artifact.**
- **Product 🔴 broken.** `iso/RUNTIME` says `6d7826d`; the ISO bundles
  `omarchy-dev-4.0.0.r1667.g4727bad` — 50 commits later, past the
  `536fcd5c` rename. §0's **(INFERRED)** prediction is now **MEASURED**: the
  shipped orchestrator calls `/usr/bin/omarchy-setup-system`, and that package
  contains **zero** paths matching `setup-system` (no file, no symlink, no
  `.INSTALL` shim). This ISO cannot finish an install.

**So: T5b first, T5c after.** T5b needs only the pipeline, which is proven, and
its whole content is the fix. T5c stays blocked because (a) `[V]`-tier
verification is unreachable through a base that dies at phase 5, and (b) its
"zero NVIDIA packages" assertion would be measured against a mirror whose
composition drifts daily — the runtime's `omarchy-base.packages` gained
`libvips` + `zbar` (and 4 resolved packages) inside this one comparison.

Two notes for T5b: **guard 6.4 now has a real failing case** to test against
(the check above, run by hand, fires on today's artifact); and `--local-source`
*builds* the runtime rather than downloading it, so the re-parity check must
compare the **version string and file list**, never the archive checksum.
`docs/findings/T5a-parity.md` §7 states the exact re-measurement that closes T5a.

### 🟢 Outcome, 2026-08-12 — T5a is CLOSED. Parity proven. **T5c is unblocked.**

The four-test re-measurement ran against T5b's pinned build
(`8ac3502a…`, runtime `4.0.0.r1617.g6d7826d-1`) — `docs/findings/T5a-parity.md`
**Appendix A**. **P1, P2, P3 and P4 all pass.** Every difference from
`~/ISOs/omarchy-2026.08.10-…iso` is temporal; **none is attributable to our
build path.** Headline numbers, all MEASURED:

- **P1** the ISO9660 diff is still one filename, the build-timestamp `.uuid`;
  20 of 21 upstream-sourced files byte-identical and the 21st (`os-release`)
  differs in `IMAGE_VERSION` alone. Zero paths of our own in a 645-line rootfs
  path diff.
- **P2** all four pins equal, `BUILD_ID="4.0.0.r1617.g6d7826d"` in both.
- **P3** offline mirror **1244 / 1244, zero exclusive either way**, 64 upgrades
  and 0 downgrades, zero Omarchy-authored version changes, boot chain
  byte-identical. Sharper than the bar asked: of **1180** packages present at
  the same version in both images, **1177 are byte-identical** — the only 3 that
  differ are exactly the three `--local-source` builds.
- **P4** all 3 orchestrator-called binaries present; `apply-system` absent.

So the two reasons this section gave for blocking T5c are gone: the base build
*does* reproduce the reference, and `omarchy-base.packages` is now
**byte-identical** to it (`expected-packages` = `934` in both), so T5c's
denominator no longer drifts.

**⚠️ Two constraints T5c inherits.** (1) `iso/PKGS` pins only the three
locally-built packages' *sources*; the other ~1241 offline packages still come
from rolling `edge`, so write §7's NVIDIA check as a **shape** assertion ("no
package matching `nvidia*` resolves into the mirror"), never a count or a
version. (2) `omarchy-nvim` clones plugin git HEADs at build time, so its
payload under `etc/skel/.local/share/nvim/` drifts per build even at a pinned
PKGBUILD — **no slice may assert byte-stability across rebuilds.** Neither
touches the boot chain, the orchestrator or `/usr/bin`.

🔴 Unchanged and still INFERRED: **nobody has booted this ISO.** That an install
now runs past phase 5 is an argument from ingredients, not an execution. `[V]`
tier (`test/vm/`) still owes that.

---

## 8. The single riskiest unknown that remains

🔴 **Nothing in this plan has been run, and the two bake-ins with the most
user-visible consequence — 5.6's lock fix and 5.2's `interface_rotation: 270` —
have never been seen on a screen by anyone, including upstream.**

Concretely: `above_lock = 2` was read out of Hyprland's `Renderer.cpp` and
`ViewHitTester.cpp` and has never been rendered
(`docs/findings/T9-lock-service-mitigation.md` §6 #4); `270` is a hypothesis
whose predecessor value turned out upside down (§5.11); and upstream's own lock
tests are 13 regexes over QML text against a fake `hyprctl` (§5.24). So the
release gate for both is **eyes on the panel**, and there is no cheaper tier
that can substitute.

The second-riskiest is narrower but likelier to bite first: **`edge` is a moving
target and has already moved past our pin.** Guard 6.4 makes that loud instead of
silent, but it does not make it stop happening — and if 4.0 stable lands this
week (operator decision #6 is to wait for it), the `RUNTIME` pin moves and every
row in §5 needs re-checking against the new runtime. Budget for that, and put
guard 6.4 in **before** the bake-ins, not after.

---

## 9. What this session read, and what it only reasoned about

**Read from source (`gh api`, or the file in this repo):** `bin/omarchy-iso-make`,
`builder/build-iso.sh`, `builder/build-omarchy-packages.sh`,
`builder/prune-offline-mirror.sh`, `configs/pacman-online-edge.conf`,
`configs/pacman-offline.conf`, `configs/profiledef.sh`,
`configs/airootfs/root/.automated_script.sh`, `root/configurator` (encryption
sites), `orchestrator/phases.py`, `orchestrator/main.py` (phase list),
`orchestrator/phases_impl.py` (limine writers, `configure_login`,
`_runtime_package_list`, `_early_packages`, `run_system_finalizer`), all four
commits past `a12bfea` with their diffs, `basecamp/omarchy@6d7826d` and
`@1c9dfc5` trees, `bin/omarchy-refresh-pacman`, `bin/omarchy-refresh-limine`,
`bin/omarchy-hook`, `bin/omarchy-provision-user`, `default/limine/limine.conf`,
`install/hardware/all.sh`, `install/hardware/pacman.sh`,
`install/post-install/pacman.sh`, `install/user/first-run/enable-user-units.sh`,
`config/omarchy/hooks/pre-refresh-pacman.d/add-custom-repo.sample`, **and the
live `edge` repo database** (`pkgs.omarchy.org/edge/x86_64/omarchy.db`, 37 KB).

**Inferred, not run:** the exact phase at which a mismatched finalizer aborts;
that `configure_deck` placed between `run_system_finalizer` and
`finalize_limine_boot` survives `install/post-install/pacman.sh`'s overwrite (the
ordering is read, the outcome is not); that a `--global` mask beats
`enable-user-units.sh`'s first-run enable; every "verified by" row, all of which
are specifications, not results.

**Not done, per this task's constraints:** no ISO built, none downloaded, no
Deck touched, no `ssh`. Nothing committed.

---

## 10. Implementation notes — what building the Wi-Fi carry-over found in §3/§4.1

**Written 2026-08-12, after implementing `configure_deck`'s first step
(`src/deck_configure.py`, `src/deck_wifi.py`, `src/deck-wifi-first-boot.sh`,
`src/omarchy-deck-wifi-first-boot.service`, staged patch
`src/iso-patches/configure-deck-phase.patch`, suite
`test/unit/test-deck-configure-wifi.py`).** Everything here is a correction or
an addition to this plan, not a restatement of it.

**1. 🔴 §5's bake-in list has six items and none of them is the Wi-Fi
credentials.** T4's U1 is the highest-cost open unknown in
`docs/tasks/T4-screen-spec.md` §8, its mitigation is explicitly *"`configure_deck`
writes the connection itself"*, and it appears nowhere in the table that decides
what `configure_deck` does. It is now measured (U1's row, updated): upstream
carries nothing across, and archinstall's `type: iso` handler enables **iwd** on
a target where Omarchy enables **NetworkManager**. Treat §5 as five-and-a-half
items, not six, until this one has a row with a [V] check of its own.

**2. §4.1's requirements (ii) and (iii) are not properties of the
`steamdeck-dsp` fetch.** They read as if they were — "`configure_deck`'s fetch
step must…" — but they are the contract for *any* step that can come out
degraded, and the Wi-Fi step needed them before the fetch step exists. Two
consequences that had to be built rather than assumed:

- (ii)'s `/var/log/omarchy-deck-install.json` has **several writers**. It is a
  merge target keyed by step name (`deck_configure.record_result`), written
  through a temp file and `os.replace`, with a pre-existing non-object moved to
  `.corrupt` rather than destroyed. A step that opened it for writing would
  erase whichever step ran before it.
- (iii)'s first-boot unit is installed **unconditionally**, not only when the
  step failed. §4.1 imagines the unit as the retry for a known failure; the case
  it does not imagine is the one that matters most here — a keyfile copied
  perfectly that NetworkManager then declines to load, which is invisible from
  inside the installer. The unit disables itself the first time the machine has
  a network, so unconditional does not mean permanent.

**3. "Retries and tells the user" is under-specified for a step with nothing to
retry.** When no credentials were captured there is nothing to re-attempt; the
honest behaviour is to *say so*, on the installed system, and keep saying so
until it stops being true. The unit therefore exits non-zero when the machine
has no network (a FAILED unit is the channel that survives a reboot on a device
with no terminal — the same reasoning
`src/omarchy-deck-patches/omarchy-deck-patch-check.service` already carries) and
exits 0 with a stand-down when there is no wireless hardware at all, so it does
not become a permanently failed unit in every QEMU run and train people to
ignore it.

**4. §3's S3 is a phase, but §7 assumes it is a function.** Five separate slices
(T5e's 5.1/5.5/5.6, T5f's 5.2, T12's applier, this one) all land inside the one
`build_phases` entry, in different sessions. `configure_deck` is therefore a
registry of `DeckStep(name, fn, critical)` — append a step, touch nothing that
works. `critical` has **no default**: §4.1's "the offline install must still
succeed" makes non-critical the common answer, which is exactly why it must be
stated per step rather than inherited. **T12's `omarchy-deck-apply-patches` call
is a step to register, not code to add to an existing one.**

**5. The patch is not the whole change, and promoting it alone breaks every
install.** `main.py`'s patched `build_phases` does
`from .deck_configure import configure_deck`, which is evaluated *before* any
phase runs — a loud, early failure, deliberately, but it means the additive
overlay files must land in the same commit as the patch.
`src/iso-patches/README.md` now carries that four-row list.

**6. Where the phase sits, exactly.** Immediately after
`("Configuring system", run_system_finalizer)` and therefore before
`stage_provisioning_state` and `finalize_limine_boot`. §9 lists "that
`configure_deck` placed between `run_system_finalizer` and
`finalize_limine_boot` survives `install/post-install/pacman.sh`'s overwrite" as
**(INFERRED)**, and it still is: the ordering is now asserted by a unit test
that executes the patched `build_phases`, but nobody has run an install.

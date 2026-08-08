# FINDING R1 §10.2 — Is there a lighter integration point than forking `basecamp/omarchy`?

**Result: PARTIAL — hypothesis right for the wrong reasons.**

- The `~/.config/omarchy/hooks/<name>.d/` mechanism **exists in Quattro and
  works** — CONFIRMED, and it is broader than PLAN.md knew (six hook types, not
  one).
- But `post-update.d/` is **not** the right hook for us, and no user-level hook
  is sufficient on its own. Deck integration needs privileged, install-time,
  hardware-gated work that runs before first login.
- The `~/.local/share/omarchy` claim is **half wrong**: it is *not* a
  pacman-owned symlink and does not exist at all on a fresh Quattro install.
  The practical conclusion PLAN.md drew from it (don't integrate by git
  checkout) is still correct, for a different reason.
- **The real sanctioned extension point is one PLAN.md never considered:**
  `install/hardware/` + a `pre-refresh-pacman.d/` hook, mirroring exactly what
  upstream already does for Apple T2 Macs and Dell XPS Panther Lake.

## Hypothesis (PLAN.md §10.2)

> Yes — use hooks, don't fork. (a) `omarchy-iso` exposes
> `OMARCHY_INSTALLER_REPO`/`OMARCHY_INSTALLER_REF`… (b) a recent changelog adds
> `~/.config/omarchy/hooks/post-update.d/` directory-style hooks… (c) Quattro
> turns `~/.local/share/omarchy` into a pacman-owned symlink.

Signal (a) was already killed in `PROGRESS.md` ("Foundational assumption in
PLAN.md §4/§5/§10.2 is wrong"). This finding builds on that and resolves (b)
and (c).

## What I did

Cloned `basecamp/omarchy` (default branch `quattro`, HEAD `007d6fc`,
`version` = **`4.0.0.alpha`** — confirmed Quattro-era, not 3.x) and
`omacom-io/omarchy-pkgs` to `/tmp/pizzarchy-r1-scratch/`, outside this
worktree. Read the hook runner, the update pipeline, the `omarchy-dev`
PKGBUILD, `install/hardware/`, `docs/file-layout.md`, `docs/update-process.md`,
and the Quattro upgrader. Cross-checked against `omarchy-iso`'s
`manifests/fresh-4.json` — a captured manifest of a real fresh Quattro install.

Paths are relative to the `basecamp/omarchy` checkout unless noted.

## (b) The hook mechanism — CONFIRMED, in Quattro, and larger than described

`bin/omarchy-hook` (28 lines, whole file is the mechanism):

```bash
HOOK_PATH="$HOME/.config/omarchy/hooks/$1"      # :14
HOOK_DIR="$HOOK_PATH.d"                          # :15
if [[ -f $HOOK_PATH ]]; then bash "$HOOK_PATH" "$@" || echo "Hook failed: $HOOK_PATH"; fi   # :18-20
if [[ -d $HOOK_DIR ]]; then
  for hook in "$HOOK_DIR"/*; do
    [[ -f $hook ]] || continue
    [[ $hook == *.sample ]] && continue          # :25
    bash "$hook" "$@" || echo "Hook failed: $hook"
  done
fi                                                # :22-27
```

`bin/omarchy-hook-install:18-29` is the sanctioned installer
(`omarchy hook install <type> <file>` → `cp` + `chmod 755`). Six hook types
ship, documented at `default/agents/skills/omarchy/hooks.md:6-20`:

```
~/.config/omarchy/hooks/
├── battery-low.d/          # Low battery (percentage in $1)
├── font-set.d/             # After font change (font name in $1)
├── post-boot.d/            # After the desktop starts
├── post-update.d/          # During `omarchy update`, after packages and migrations
├── pre-refresh-pacman.d/   # Before `omarchy refresh pacman` re-syncs packages
└── theme-set.d/            # After theme change (theme slug in $1)
```

Each has a `.sample` under `config/omarchy/hooks/<type>.d/` (seeded to users via
`/etc/skel`). Upstream uses the mechanism itself — `bin/omarchy-first-run:70-73`
installs two `post-update` hooks (Voxtype, fingerprint), and there are tests:
`test/shell.d/voxtype-invitation-test.sh:8`,
`test/shell.d/fingerprint-invitation-test.sh:15`. `bin/omarchy-update:37` calls
`omarchy-hook post-update` in the blessed pipeline. The Quattro upgrader even
writes a self-deleting `post-boot.d` hook
(`bin/omarchy-upgrade-to-quattro:963-977`).

**Caveats that matter for us:**
- Hooks are **per-user, unprivileged, `$HOME`-scoped**. `bin/omarchy-hook:19,26`
  swallow failures (`|| echo "Hook failed"`) — a hook that fails does **not**
  fail the update. That directly conflicts with this project's "never silently
  swallow a failure" constraint (`CLAUDE.md`): any Deck hook must do its own
  loud reporting, because the runner will not.
- `post-update.d/` runs only on `omarchy update`. Nothing Deck-critical can
  live there, because it never runs on a fresh install before first boot into
  Gaming Mode.

### The hook that actually matters for us: `pre-refresh-pacman.d/`

PLAN.md fixated on `post-update.d/`. The load-bearing one is
`pre-refresh-pacman.d/`. `bin/omarchy-refresh-pacman` **clobbers the target's
`/etc/pacman.conf` wholesale** on every channel refresh:

```bash
sudo cp -f "$OMARCHY_PATH/default/pacman/pacman-$channel.conf" /etc/pacman.conf   # :19
sudo cp -f "$OMARCHY_PATH/default/pacman/mirrorlist-$channel" /etc/pacman.d/mirrorlist  # :20
# Allow user customization of /etc/pacman.conf before the upgrade runs
omarchy-hook pre-refresh-pacman                                                    # :23
sudo env OMARCHY_UPDATE_PACMAN=1 pacman -Syyuu --noconfirm                         # :26
```

…and the shipped sample for that hook is literally
`config/omarchy/hooks/pre-refresh-pacman.d/add-custom-repo.sample`, whose own
header says:

> This hook is called by `omarchy refresh pacman` AFTER the channel template is
> copied to `/etc/pacman.conf` and BEFORE `pacman -Syyuu` runs. Use it to layer
> customizations onto the freshly-written pacman.conf … common cases are adding
> a custom repository (e.g. CachyOS, Chaotic-AUR, an internal company repo)…
> The hook runs as the invoking user with a warm sudo cache.

Its recommended shape is: keep repo entries in `/etc/pacman.d/custom-repos.conf`
and `sed` an `Include =` line above `[core]`. **This is the answer to "how do
Valve's `jupiter-staging`/`holo-staging` repos survive an Omarchy channel
refresh"** — a question PLAN.md §10.1 didn't know it needed to ask. Without it,
the Deck's repo config silently disappears the first time a user runs
`omarchy refresh pacman`, and the neptune kernel stops receiving updates.

## (c) `~/.local/share/omarchy` — claim is HALF WRONG, conclusion still holds

**It is not a pacman-owned symlink.** `omarchy-pkgs/pkgbuilds/omarchy-dev/PKGBUILD`
has **no `.install` scriptlet** (directory contains only `PKGBUILD` and
`.omarchy/`) and its `package()` (`:94-148`) installs exclusively to
`/usr/bin`, `/usr/share/omarchy/{bin,install,themes,migrations,shell,version}`,
`/usr/share/libalpm/hooks/`, and `/etc/skel/.local/state/omarchy/migrations`.
It never touches `~/.local/share`.

**On a fresh Quattro install the path does not exist at all.** Grepping
`omarchy-iso/manifests/fresh-4.json` — a captured file manifest of a real fresh
install — for `.local/share/omarchy` returns **zero** hits.

The symlink is purely an **upgrade compatibility shim** for 3.x users, created
by `bin/omarchy-upgrade-to-quattro` (`legacy_root="$TARGET_HOME/.local/share/omarchy"`
at `:878`; the `ln -sfn /usr/share/omarchy "$legacy_root"` logic at `:982-1006`),
with a stated rationale at `:982-987`: "Existing terminals still have
`OMARCHY_PATH=$HOME/.local/share/omarchy` … Make that stale path resolve to the
package-backed tree." It even backs the old git checkout up to
`~/.local/share/omarchy.omarchy-upgrade-to-quattro.*.bak` (`:1951`) and the
overlay variant self-destructs via a `post-boot.d` hook (`:963-977`).

**The correct statement is stronger than PLAN.md's:** in Quattro,
`OMARCHY_PATH` defaults to `/usr/share/omarchy` everywhere
(`bin/omarchy-setup-hardware:55`, `bin/omarchy-version-branch:6`,
`install/config/snapper.sh:3`, `migrations/*.sh:3`), sourced from
`/etc/omarchy.conf` via `default/bash/env-bootstrap` (`docs/file-layout.md:138-155`).
Omarchy is package-backed, full stop. Git-checkout integration isn't "broken by
a symlink" — **there is no checkout to integrate with.** PLAN.md's conclusion
survives; its stated reason does not.

There *is* a sanctioned local-checkout escape hatch: `bin/omarchy-dev-link`
writes `/etc/omarchy.conf` to repoint `OMARCHY_PATH`. But its own help text
(`:22-31`) says it "intentionally does not rewrite the running Hyprland,
systemd, shell, or app-launcher environment" and covers **only**
`$OMARCHY_PATH`-resolved trees — "files installed at fixed system paths
(`/etc/`, `/usr/lib/systemd/`, udev rule bodies, `/etc/skel` after user
creation, `/usr/share/plymouth`) are NOT covered." Deck work is overwhelmingly
udev rules, systemd units, and `/etc` drop-ins. **`omarchy-dev-link` is a
developer inner-loop tool, not a shipping integration mechanism.** Do not build
on it.

## Reconciling with the pacman-package finding — the actual sanctioned path

Upstream already solves *precisely our problem shape* — "this specific hardware
needs an out-of-tree kernel and an unsigned third-party repo" — twice, in-tree,
and neither solution is a hook or a fork. Both live in `install/hardware/`,
which ships inside the `omarchy` package and is driven by
`bin/omarchy-setup-hardware` (invoked by `omarchy-setup-system` during ISO
finalization, and re-runnable: `bin/omarchy-setup-hardware:14-16`,
`:60-61` sources `install/hardware/all.sh`).

**Precedent 1 — third-party unsigned repo, hardware-gated.**
`install/hardware/pacman.sh` (whole file, 12 lines):

```bash
# Hardware-specific pacman repository extensions that must survive the final
# pacman.conf restore.
if lspci -nn | grep "106b:180[12]" >/dev/null; then
  if ! grep -q '^\[arch-mact2\]' /etc/pacman.conf; then
    cat >> /etc/pacman.conf <<'EOF'

[arch-mact2]
Server = https://github.com/NoaHimesaka1873/arch-mact2-mirror/releases/download/release
SigLevel = Never
EOF
  fi
fi
```

That is our Valve-repo block, verbatim in shape, `SigLevel = Never` and all.

**Precedent 2 — kernel swap + Limine boot order, hardware-gated.**
`install/hardware/intel/ptl-kernel.sh` (whole file, 25 lines): `omarchy-hw-match
"XPS" && omarchy-hw-intel-ptl` → `omarchy-pkg-add linux-ptl linux-ptl-headers`
→ `pacman -Rdd --noconfirm linux linux-headers` → write
`/etc/limine-entry-tool.d/zz-dell-xps-panther-lake.conf` with
`BOOT_ORDER="linux-ptl*, *fallback, Snapshots"`. The `zz-` prefix is
load-bearing and commented (`:18-19`): drop-ins are read in order, last
`BOOT_ORDER` wins.

`linux-ptl` is itself a package in `omacom-io/omarchy-pkgs/pkgbuilds/`, right
alongside `xpadneo-dkms`, `makima-bin`, `asdcontrol`, `retroarch-joypad-autoconfig-git`,
`umu-launcher`, `heroic-games-launcher-bin` — several of which are directly
relevant to T2/T3.

`install/hardware/all.sh` is a **flat, hardcoded list of 46 `run_logged` calls**
(`:1-46`) — it does **not** glob a directory. So we cannot drop a file in;
adding a Deck entry means adding a line to that file, i.e. an upstream PR or a
patch carried in our own `omarchy` package build.

### Recommended architecture for T5 (three layers, all sanctioned)

1. **Build-time — fork `omarchy-iso` only** (per `FINDING-R1-10.1.md`): Valve
   repos into `configs/pacman-online-*.conf`, Deck packages into the offline
   mirror. Small, mechanical, mirrors the `arch-mact2` precedent.
2. **Install-time — ship Deck logic as its own pacman package** (e.g.
   `omarchy-deck`), built into the offline mirror. Model it on
   `omarchy-pkgs/pkgbuilds/omarchy-dev/PKGBUILD`. It owns the privileged,
   hardware-gated, `/etc`-and-systemd work that hooks cannot do: the
   `linux-neptune-611` swap and `/etc/limine-entry-tool.d/zz-steamdeck.conf`
   (copy `ptl-kernel.sh`), the Valve repo block (copy `pacman.sh`), udev rules,
   gamescope-session units, TDP/fan services. It runs via a
   `/usr/share/libalpm/` hook or is invoked from the chroot phase — either way,
   **it does not require forking `basecamp/omarchy`.**
3. **Durability — one `pre-refresh-pacman.d/` hook**, seeded by the
   `omarchy-deck` package into `/etc/skel/.config/omarchy/hooks/pre-refresh-pacman.d/`
   (so new users get it) and installed for the install user via
   `omarchy-hook-install`. Its only job: re-`Include` `/etc/pacman.d/valve-repos.conf`
   after `omarchy-refresh-pacman:19` clobbers `/etc/pacman.conf`. Follow
   `add-custom-repo.sample`'s exact recipe. **Add explicit failure reporting** —
   `omarchy-hook` swallows non-zero exits.

Optionally, `post-boot.d/` for anything needing a live graphical session (the
Gaming Mode switcher icon, §6.1a follow-ups).

**Upstreaming is the real long-term play:** a `install/hardware/steamdeck.sh` +
one line in `all.sh` + a `[jupiter-staging]` block in `pacman.sh` would put the
Deck on exactly the footing the T2 Mac and XPS PTL already occupy. Worth
proposing to `basecamp/omarchy` once T1/T3 prove out — it's the difference
between maintaining a fork forever and maintaining one ISO profile.

## What this changes / what to fix in PLAN.md

- §10.2's hypothesis is **directionally right, mechanically wrong**. Don't fork
  `basecamp/omarchy`; but don't build on `post-update.d/` either. The load-bearing
  hook is `pre-refresh-pacman.d/`, and the load-bearing *mechanism* is a pacman
  package plus the `install/hardware/` pattern.
- Strike the "pacman-owned symlink" claim. Replace with: "Quattro is
  package-backed; `OMARCHY_PATH=/usr/share/omarchy`; `~/.local/share/omarchy`
  exists only as a 3.x upgrade shim and not at all on fresh installs."
- **New risk, not in PLAN.md:** `omarchy refresh pacman` silently discards any
  `/etc/pacman.conf` customization. Any Deck design that writes to
  `/etc/pacman.conf` directly (including upstream's own `install/hardware/pacman.sh`
  approach) is one `omarchy refresh pacman` away from losing the Valve repos.
  Belt and braces: write the repo block **and** the `pre-refresh-pacman.d/` hook.
- **New constraint, not in PLAN.md:** `bin/omarchy-update:22-51` runs everything
  through `omarchy-update-lock`, and the `omarchy` package installs an ALPM
  pre-transaction guard (`/usr/share/libalpm/hooks/00-omarchy-update-guard.hook`
  → `omarchy-update-pacman-guard`, `docs/update-process.md:66-90`) that
  **aborts bare `pacman -Syu`** unless `OMARCHY_UPDATE_PACMAN=1` is set. Any
  Deck script that shells out to pacman for a system upgrade must set that env
  var or it will be killed by the guard. This affects T1 and T3 directly.
- T1 gets a concrete template it didn't have: `install/hardware/intel/ptl-kernel.sh`
  is a working, upstream, Limine-native kernel-swap-and-boot-order script.
  Read it before writing `omarchy-deck-kernel.sh`'s successor.

## Reproduction

```
git clone --depth 100 https://github.com/basecamp/omarchy.git      # HEAD 007d6fc, branch quattro, version 4.0.0.alpha
git clone --depth 30  https://github.com/omacom-io/omarchy-pkgs.git
git clone --depth 50  https://github.com/omacom-io/omarchy-iso.git # for manifests/fresh-4.json
```
Scratch checkouts used for this finding live at `/tmp/pizzarchy-r1-scratch/`
(outside the repo, disposable).

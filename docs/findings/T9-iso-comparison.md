# ISO comparison: upstream "beta 2" vs our local build

Task P2.9a / P2.9c step 3a of `docs/tasks/T9-beta2-rebase.md`. Performed 2026-08-11.

| | A — upstream beta 2 | B — our local build |
|---|---|---|
| file | `/home/huyke/ISOs/omarchy-quattro-beta2.iso` | `/home/huyke/ISOs/omarchy-2026.08.10-x86_64-quattro.iso` |
| sha256 | `8dda10349c216d5d758c6d57d26e011c8a4ae4be88ed55e5ad09727345f71b4a` | `fbc874221353d6602f926c11c61b87fb2e6f14dc330995e85d99c12b528df03b` |
| size | 6,390,581,248 | 6,390,581,248 (identical) |
| `arch/version` | `2026.08.10` | `2026.08.10` |
| squashfs build time | **2026-08-10 13:35:06 UTC** | **2026-08-10 15:24:25 UTC** |
| `airootfs.sfs` sha512 | `440de6b0…a6fdc720` | `30fa51c6…787a0a0c` |
| airootfs entries | 104,184 | 104,175 |

Both are archiso, same layout, `airootfs.sfs` = SquashFS 4.0 / **ZSTD** / 1 MiB clusters.

**Upstream beta 2 was built ~1h49m BEFORE our local build**, despite being published
later (Last-Modified 13:44:37 UTC — i.e. 9 minutes after its squashfs was sealed).
This direction matters: every version difference below has *our* image carrying the
**newer** Arch package, not the older one.

---

## 1. `omarchy-dev` / `omarchy-settings-dev` version — THE PIN

**Identical in both images.**

| package | beta 2 | ours |
|---|---|---|
| `omarchy-dev` | `4.0.0.r1617.g6d7826d-1` | `4.0.0.r1617.g6d7826d-1` |
| `omarchy-settings-dev` | `4.0.0.r1617.g6d7826d-1` | `4.0.0.r1617.g6d7826d-1` |
| `omarchy-nvim` | `2026.8.1-1` | `2026.8.1-1` |
| `omarchy-keyring` | `20251027-1` | `20251027-1` |

**The pin is `basecamp/omarchy` commit `6d7826d`** (1617 commits past the `4.0.0` tag).
Corroborated three independent ways:

- `var/cache/omarchy/mirror/offline/omarchy-dev-4.0.0.r1617.g6d7826d-1-any.pkg.tar.zst`
  (the bundled offline repo — this is the copy the installer actually installs)
- the `offline.db` repo database entry `omarchy-dev-4.0.0.r1617.g6d7826d-1`
- `/etc/os-release` in the live rootfs: `BUILD_ID="4.0.0.r1617.g6d7826d"`,
  `VERSION_ID="4.0.0.r1617.g6d7826d"`, `IMAGE_VERSION=2026.08.10`

Note `omarchy-dev` is **not** in the live environment's `arch/pkglist.x86_64.txt` —
only `omarchy-settings-dev` and `omarchy-keyring` are. `omarchy-dev` ships only in the
offline repo, for installation onto the target.

`usr/share/omarchy-iso/package-targets` (byte-identical in both) selects the dev
packages explicitly:

```
OMARCHY_RUNTIME_PACKAGE=omarchy-dev
OMARCHY_SETTINGS_PACKAGE=omarchy-settings-dev
OMARCHY_NVIM_PACKAGE=omarchy-nvim
```

## 2. Package channel

**Both are `edge`.** One difference, and it is the *only* content difference in the
whole rootfs that is not an Arch package bump:

| stamp file | beta 2 | ours |
|---|---|---|
| `/root/omarchy_mirror` | `edge` | `edge` |
| `/root/omarchy_iso_ref` | `edge` | **`quattro`** |

These are two different things:

- **`/root/omarchy_mirror` = the package channel.** Read by
  `phases_impl.py:_read_omarchy_mirror()` (default `stable` if the file is absent) and
  exported into the chroot as `OMARCHY_MIRROR`. Both images say `edge`, which selects
  `usr/share/omarchy/default/pacman/pacman-edge.conf` →
  `[omarchy] Server = https://pkgs.omarchy.org/edge/$arch`, and
  `mirrorlist-edge` → `Server = https://mirror.omarchy.org/$repo/os/$arch`.
- **`/root/omarchy_iso_ref` = the omarchy-iso *git ref name*** the image was built from
  (`phases_impl.py:_iso_ref()`, default `stable`), exported as `OMARCHY_ISO_REF`.
  It is a branch name, **not a commit sha**. Upstream published from a branch/ref
  labelled `edge`; our builder recorded `quattro`. Cosmetic/provenance only — it does
  not change any package source.

The three channel configs carried in both images, for reference:

| file | `[omarchy]` Server | Arch mirrorlist |
|---|---|---|
| `pacman-edge.conf` | `https://pkgs.omarchy.org/edge/$arch` | `mirrorlist-edge` → `https://mirror.omarchy.org/$repo/os/$arch` |
| `pacman-rc.conf` | `https://pkgs.omarchy.org/edge/$arch` (yes — rc points at edge) | `mirrorlist-rc` → `https://rc-mirror.omarchy.org/$repo/os/$arch` |
| `pacman-stable.conf` | `https://pkgs.omarchy.org/stable/$arch` | `mirrorlist-stable` → `https://stable-mirror.omarchy.org/$repo/os/$arch` |

The **live** environment's own `/etc/pacman.conf` (identical in both) has exactly one
repo and no network source at all:

```
[offline]
SigLevel = Never
Server = file:///var/cache/omarchy/mirror/offline/
```

## 3. Which omarchy-iso builder commit produced upstream's image

**No commit sha is recorded anywhere inside either ISO.** `/root/omarchy_iso_ref` holds
a ref *name* (`edge` / `quattro`), there is no `.git`, no version/build stamp file, and
`grub.cfg`/`syslinux.cfg` carry no build identifier. So this was answered by
**content-diffing the airootfs against GitHub blobs**, not from a stamp.

**Verdict: upstream beta 2 was built from `omarchy-iso` commit `a12bfea7a86c`** — the
same commit as our build. Bracketed from both sides:

- **Lower bound.** `a12bfea` ("Stop the live installer crashing the kernel on pre-T2
  Macs", 2026-08-10T11:49:50Z) added exactly one file,
  `configs/airootfs/etc/modprobe.d/blacklist-applesmc.conf`. That file **is present in
  beta 2** and its sha256 matches the GitHub blob at `a12bfea` exactly (`693d768ebb1e…`).
  So beta 2 ≥ `a12bfea`.
- **Upper bound.** Every later commit touches a file that is **byte-identical** across
  GitHub@`a12bfea`, beta 2, and our image:

  | commit | date (UTC) | touches | sha256[0:16] at a12bfea / beta2 / ours |
  |---|---|---|---|
  | `e5f2b466efec` | 08-10 16:19:44 | `root/configurator` | `f845fa39206fbc59` — all three equal |
  | `e5f2b466` `a6a442b9` `be618cc7` | 08-10 16:19–20:51 | `usr/local/bin/omarchy-install-dashboard` | `2301139ec931f151` — all three equal |
  | `d6cd2d30a658` | 08-10 21:15:24 | `orchestrator/phases_impl.py` | `f5a99f4587186235` — all three equal |

  So beta 2 contains **none** of `e5f2b466` / `a6a442b9` / `be618cc7` / `d6cd2d30`.
- **Timeline corroborates.** beta 2's squashfs was sealed 2026-08-10 13:35:06 UTC, which
  falls between `a12bfea` (11:49:50 UTC) and `e5f2b466` (16:19:44 UTC).

Additionally, **all 20 installer/config files compared are byte-identical** between the
two images (sha256): the entire `orchestrator/` package (`main.py`, `phases.py`,
`phases_impl.py`, `context.py`, `ui.py`, `keyboard.py`, `archinstall_adapter.py`,
`__init__.py`), `setup-form.sh`, `package-targets`, `expected-packages`,
`omarchy-base.packages`, `omarchy-other.packages`, `omarchy-iso-install`,
`omarchy-install-dashboard`, `root/configurator`, `root/.zlogin`,
`root/.automated_script.sh`, `/etc/pacman.conf`, `/etc/os-release`.

(`setup-form.sh` and the `*.packages` lists do **not** exist in the omarchy-iso repo at
`a12bfea` — commit `8858ac25` "Source the setup form from the Omarchy runtime (#104)"
moved them into the `omarchy-dev` package. They match between images anyway, which
follows from both carrying the same `omarchy-dev` build.)

## 4. Package manifest diff — THE ANSWER THAT MATTERS

Two manifests exist per image and both were diffed.

### 4a. Bundled offline repo — `var/cache/omarchy/mirror/offline/`

**1244 packages in each. No package exists in only one image. 7 differ in version.**
Cross-checked twice: once from the `.pkg.tar.zst` filenames, once from the
`offline.db.tar.gz` repo database entries — the two agree exactly.

| package | beta 2 | ours | what it is |
|---|---|---|---|
| `arch-install-scripts` | `31-1` | `31-2` | Arch rebuild |
| `bolt` | `0.9.11-1` | `0.9.11-2` | Arch rebuild |
| `expac` | `10-12` | `10-13` | Arch rebuild |
| `libnvme` | `1.16.2-1` | `1.16.2-2` | Arch rebuild |
| `python-typing-inspection` | `0.4.2-2` | `0.4.3-1` | Arch point release |
| `tpm2-tools` | `5.7-1` | `5.7-2` | Arch rebuild |
| `v4l2loopback-dkms` | `0.15.4-1` | `0.15.4-2` | Arch rebuild |

All 7 are **stock Arch [core]/[extra] packages**. Six of the seven are pure `pkgrel`
bumps (same upstream version, rebuilt); only `python-typing-inspection` crosses a
version boundary (0.4.2 → 0.4.3, a pydantic helper library). **Zero** Omarchy-authored
or boot-chain packages differ.

**omarchy-\* and limine\* rows, spelled out — identical in both images:**

| package | beta 2 | ours |
|---|---|---|
| `limine` | `12.5.2-1` | `12.5.2-1` |
| `limine-mkinitcpio-hook` | `1.37.1-1` | `1.37.1-1` |
| `limine-snapper-sync` | `1.31.0-1` | `1.31.0-1` |
| `omarchy-dev` | `4.0.0.r1617.g6d7826d-1` | `4.0.0.r1617.g6d7826d-1` |
| `omarchy-keyring` | `20251027-1` | `20251027-1` |
| `omarchy-nvim` | `2026.8.1-1` | `2026.8.1-1` |
| `omarchy-settings-dev` | `4.0.0.r1617.g6d7826d-1` | `4.0.0.r1617.g6d7826d-1` |

### 4b. Live environment — `arch/pkglist.x86_64.txt`

**483 packages in each. No package exists in only one. 5 differ in version** — a subset
of the 7 above (`expac` and `v4l2loopback-dkms` ship only in the offline repo for the
target, they are not installed in the live ISO):

```
arch-install-scripts       31-1      →  31-2
bolt                       0.9.11-1  →  0.9.11-2
libnvme                    1.16.2-1  →  1.16.2-2
python-typing-inspection   0.4.2-2   →  0.4.3-1
tpm2-tools                 5.7-1     →  5.7-2
```

omarchy rows in the live pkglist, identical in both: `omarchy-keyring 20251027-1`,
`omarchy-settings-dev 4.0.0.r1617.g6d7826d-1`. No `limine*` in the live env.

### 4c. Whole-rootfs file-set diff (sanity check)

Diffing all 104k airootfs paths, the entire difference is accounted for by the above
plus one build artefact:

- the 7 package bumps and their `var/lib/pacman/local/<pkg>-<ver>/{desc,files,mtree}`
  and `typing_inspection-0.4.x.dist-info/` directories;
- **beta 2 has `usr/share/omarchy-iso/orchestrator/__pycache__/` (9 `.pyc` files); ours
  does not.** This is exactly the 104,184 vs 104,175 delta. The `.py` sources are
  byte-identical, so this is a build-environment artefact (upstream's build imported or
  byte-compiled the orchestrator; ours did not), not an input difference.

**VERDICT: the two images have the same inputs.** Same `omarchy-dev`/`omarchy-settings-dev`
commit `6d7826d`, same omarchy-iso commit `a12bfea`, same `edge` channel, same 1244-package
offline repo modulo 7 stock-Arch rebuild bumps that our (later) build picked up from the
Arch mirror. Nothing Omarchy-authored, nothing in the boot chain, and nothing structural
differs. Our local build is a faithful reproduction of upstream beta 2.

## 5. Re-confirmed facts

### (a) No Wayland compositor in the live environment — **CONFIRMED, on both images**

Searched the full 104k-path airootfs listings for compositor binaries at
`{,usr/,usr/local/}bin/{hyprland,Hyprland,sway,weston,labwc,river,wayfire,cage,gamescope,niri,mutter,kwin_wayland,Xwayland}`:

- **beta 2: no match. ours: no match.**
- Stronger: **`libwayland-{client,server,cursor,egl}.so*` is absent from both live
  rootfses.** There is not even a Wayland *client* library, let alone a compositor.

The only `hyprland` strings in the live rootfs are non-executable and target the
*installed* system, not the live one:
`usr/lib/python3.14/site-packages/archinstall/default_profiles/desktops/hyprland.py`
(an archinstall profile), `etc/skel/.config/hypr/hyprland.lua` +
`etc/skel/.config/hyprland-preview-share-picker/` (skeleton config from
`omarchy-settings-dev`), and `usr/{local,share/omarchy/default}/share/wayland-sessions/omarchy.desktop`
(a session file for the target's display manager).

The compositor is present only as a *package to be installed onto the target*:
`hyprland-0.56.2-1`, `wayland-1.26.0-1`, `wayland-protocols-1.49-1`,
`xorg-xwayland-24.1.13-1` in the offline repo. (No `gamescope`, no `sway`, no `niri`
package at all.)

**The project's premise holds: the installer TUI runs on a bare VT with no Wayland
stack, which is why Omarchy Deck must draw its own on-screen keyboard.**

### (b) Installer defaults to full-disk encryption — **CONFIRMED, on both images**

`root/configurator` is byte-identical between the two images and to
GitHub@`a12bfea` (`f845fa39206fbc59`). Line 601:

```sh
  local mode="encrypted" affirmative confirm_status
```

with the surrounding comment at lines 598-600:

> Default to encrypted and hide the unencrypted path behind Ctrl+C

A second `local mode="encrypted"` at line 895 covers the other disk path. The
unencrypted branch is reachable only by pressing Ctrl+C at the confirm screen
(`affirmative="Yes, install without encryption"`, line 614). One documented exception
exists: line 519-520 — an install that has to share Windows' ESP is forced unencrypted;
giving Omarchy its own Linux ESP "keeps LUKS on the table".

Encryption is LUKS2 (`cryptsetup luksFormat --type luks2`, line 698), the mapper name is
`omarchy_root`, and `phases_impl.py` writes `crypttab` + `cryptdevice=UUID=…:omarchy_root`
to the kernel cmdline. Encrypted installs also get SDDM autologin, because the LUKS
prompt is treated as the auth boundary (`configure_login`, `phases_impl.py`).

---

## Reproduction — exact commands

Environment: no `xorriso` / `isoinfo` / `unsquashfs` / `osirrox`; `sudo` needs a
password so no loop-mount and no package installs. Tools used: **`bsdtar`** (ISO9660)
and **`7-Zip 26.02`** (`7z`, which reads ZSTD SquashFS 4.0 — this is what replaces
`unsquashfs`). Plus `gh` for the GitHub blob comparisons.

```bash
S=/tmp/claude-1000/-home-huyke-Pizzarchy/9dd19616-6ed9-419d-8bdf-2d4156904eba/scratchpad
A=/home/huyke/ISOs/omarchy-quattro-beta2.iso
B=/home/huyke/ISOs/omarchy-2026.08.10-x86_64-quattro.iso
cd "$S"

# --- ISO level: structure, live pkglist, version, airootfs checksum -----------
bsdtar tf "$A" | grep -v '^boot/syslinux/'
7z l "$A" | grep -v -E 'syslinux|memtest'        # sizes + build timestamps
mkdir -p meta/beta2 meta/ours
bsdtar -xf "$A" -C meta/beta2 arch/pkglist.x86_64.txt arch/version arch/grubenv
bsdtar -xf "$B" -C meta/ours  arch/pkglist.x86_64.txt arch/version arch/grubenv
diff <(sort meta/beta2/arch/pkglist.x86_64.txt) <(sort meta/ours/arch/pkglist.x86_64.txt)
grep -iE 'omarchy|limine' meta/beta2/arch/pkglist.x86_64.txt
bsdtar -xOf "$A" arch/x86_64/airootfs.sha512
bsdtar -xOf "$B" arch/x86_64/airootfs.sha512

# --- pull out each airootfs.sfs (5.65 GiB each; ~12 GiB peak in tmpfs) --------
bsdtar -xf "$A" -C . arch/x86_64/airootfs.sfs && mv arch/x86_64/airootfs.sfs beta2.sfs && rm -rf arch
bsdtar -xf "$B" -C . arch/x86_64/airootfs.sfs && mv arch/x86_64/airootfs.sfs ours.sfs  && rm -rf arch
7z l beta2.sfs | head -20        # -> SquashFS 4.0 / Method = ZSTD / Created =

# --- full path listings (7z reads the squashfs directly; no mount needed) -----
7z l -ba -slt beta2.sfs | grep '^Path = ' | sed 's/^Path = //' > beta2-paths.txt
7z l -ba -slt ours.sfs  | grep '^Path = ' | sed 's/^Path = //' > ours-paths.txt

# --- Q4: offline-repo manifest, two independent ways -------------------------
for s in beta2 ours; do
  grep '^var/cache/omarchy/mirror/offline/.*\.pkg\.tar\.zst$' $s-paths.txt \
    | sed 's|.*/||' | sort > $s-offline-pkgs.txt
done
diff beta2-offline-pkgs.txt ours-offline-pkgs.txt
grep -iE '^(omarchy|limine)' beta2-offline-pkgs.txt

for s in beta2 ours; do 7z x -y -o./x/$s $s.sfs \
  'var/cache/omarchy/mirror/offline/offline.db.tar.gz' >/dev/null; done
for s in beta2 ours; do                      # repo .db is a gzip tarball
  tar tzf x/$s/var/cache/omarchy/mirror/offline/offline.db.tar.gz \
    | grep '/$' | sed 's|/$||' | sort > $s-db-entries.txt
done
diff beta2-db-entries.txt ours-db-entries.txt

# whole-rootfs sanity diff
diff <(sort beta2-paths.txt) <(sort ours-paths.txt)

# --- Q1/Q2/Q3: targeted extraction of metadata + installer -------------------
for s in beta2 ours; do 7z x -y -o./x/$s $s.sfs \
  'root/omarchy_iso_ref' 'root/omarchy_mirror' 'root/configurator' 'root/.zlogin' \
  'root/.automated_script.sh' 'etc/pacman.conf' 'etc/os-release' \
  'etc/modprobe.d/blacklist-applesmc.conf' 'usr/share/omarchy/default/pacman/*' \
  'usr/share/omarchy-iso/*' 'usr/local/bin/omarchy-iso-install' \
  'usr/local/bin/omarchy-install-dashboard' >/dev/null; done

cat x/beta2/root/omarchy_iso_ref x/beta2/root/omarchy_mirror     # edge / edge
cat x/ours/root/omarchy_iso_ref  x/ours/root/omarchy_mirror      # quattro / edge
grep -E 'BUILD_ID|VERSION_ID|IMAGE_VERSION' x/beta2/etc/os-release
grep -E '^\[|^Server|^Include' x/beta2/etc/pacman.conf
for f in x/beta2/usr/share/omarchy/default/pacman/pacman-*.conf \
         x/beta2/usr/share/omarchy/default/pacman/mirrorlist-*; do
  echo "### $f"; grep -E '^\[|^Server|^Include' "$f"; done
cat x/beta2/usr/share/omarchy-iso/package-targets

# byte-compare every installer file between the two images
for f in usr/share/omarchy-iso/orchestrator/*.py usr/share/omarchy-iso/setup-form.sh \
         usr/share/omarchy-iso/package-targets usr/share/omarchy-iso/*.packages \
         usr/local/bin/omarchy-iso-install usr/local/bin/omarchy-install-dashboard \
         root/configurator root/.zlogin root/.automated_script.sh \
         etc/pacman.conf etc/os-release; do
  a=$(sha256sum "x/beta2/$f" | cut -c1-12); b=$(sha256sum "x/ours/$f" | cut -c1-12)
  [ "$a" = "$b" ] && echo "SAME  $f" || echo "DIFF  $f  $a $b"; done

# --- Q3: pin the omarchy-iso commit against GitHub ---------------------------
for c in a12bfea e5f2b466 a6a442b9 be618cc7 d6cd2d30; do
  gh api "repos/omacom-io/omarchy-iso/commits/$c" \
    --jq '.sha[0:12]+"  "+.commit.committer.date+"  "+(.commit.message|split("\n")[0])'
  gh api "repos/omacom-io/omarchy-iso/commits/$c" --jq '.files[] | .status+"  "+.filename'
done
gh api "repos/omacom-io/omarchy-iso/commits?sha=quattro&since=2026-08-09T00:00:00Z&until=2026-08-11T00:00:00Z&per_page=100" \
  --jq '.[] | .sha[0:12]+"  "+.commit.committer.date+"  "+(.commit.message|split("\n")[0])'

# compare in-ISO copies to the GitHub blob at a12bfea
for p in configs/airootfs/root/configurator:root/configurator \
         configs/airootfs/usr/local/bin/omarchy-install-dashboard:usr/local/bin/omarchy-install-dashboard \
         configs/airootfs/usr/share/omarchy-iso/orchestrator/phases_impl.py:usr/share/omarchy-iso/orchestrator/phases_impl.py \
         configs/airootfs/etc/modprobe.d/blacklist-applesmc.conf:etc/modprobe.d/blacklist-applesmc.conf; do
  gh=${p%%:*}; loc=${p##*:}
  up=$(gh api "repos/omacom-io/omarchy-iso/contents/$gh?ref=a12bfea" --jq '.content' \
       | base64 -d | sha256sum | cut -c1-16)
  echo "$(basename $gh)  a12bfea=$up beta2=$(sha256sum x/beta2/$loc | cut -c1-16) ours=$(sha256sum x/ours/$loc | cut -c1-16)"
done

# --- Q5a: no Wayland compositor in the live env ------------------------------
for s in beta2 ours; do
  grep -nE '(^|/)(usr/bin|bin|usr/local/bin)/(hyprland|Hyprland|sway|weston|labwc|river|wayfire|cage|gamescope|niri|mutter|kwin_wayland|Xwayland)$' $s-paths.txt || echo "$s: NONE"
  grep -E 'libwayland-(client|server|cursor|egl)\.so' $s-paths.txt || echo "$s: no libwayland"
done

# --- Q5b: full-disk encryption is the default --------------------------------
grep -n 'local mode="encrypted"' x/beta2/root/configurator x/ours/root/configurator
grep -n -B4 -A30 'Default to encrypted' x/beta2/root/configurator

# --- cleanup (the two .sfs are 5.65 GiB each) --------------------------------
rm -f "$S"/beta2.sfs "$S"/ours.sfs
```

### Notes for a future session

- `7z` (7-Zip ≥ 24) is the drop-in replacement for `unsquashfs` here: it lists and
  extracts ZSTD SquashFS without root. `bsdtar` handles the ISO9660 layer but **cannot**
  read squashfs.
- Both `.sfs` files must be materialised on disk — squashfs needs random access, so
  piping `bsdtar -xO … | 7z` does not work. Peak scratch usage ~12 GiB; the scratchpad
  is tmpfs (16 GiB) so extract one at a time if RAM is tight.
- Everything in questions 1, 2 and 4 comes from the offline repo and a handful of small
  files. Nothing here required unpacking a root filesystem wholesale.
- Not answerable with the tooling available, and not attempted: verifying the
  *signatures* on the bundled `.pkg.tar.zst.sig` files (would need `gpg` plus the
  `omarchy-keyring` trust store), and confirming the beta 2 ISO's own provenance
  signature. If that ever matters, `pacman-key`/`gpgv` against
  `omarchy-keyring-20251027-1` would answer it.

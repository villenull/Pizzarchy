# T5a parity: does `iso/bin/build`'s first artifact reproduce the known-good ISO?

Task T5a's exit condition, `docs/tasks/T5-fork-plan.md` §7: *"Prove parity against
`~/ISOs/omarchy-2026.08.10-…iso` before changing anything"* and *"Do not start T5c
before T5a proves parity."* Performed 2026-08-11 (session 21). Method inherited
from `docs/findings/T9-iso-comparison.md` — unpack both images with `bsdtar` +
`7z`, diff the manifests and the pins. No new technique was invented.

---

## 0. Verdict

🔴 **Parity is NOT proven. The build PIPELINE is proven; the build's PRODUCT is
not, and is in fact broken in a way the reference is not.**

The one-sentence version:

> Every byte that `iso/bin/build` is responsible for matches the reference
> exactly, but the runtime package it downloaded is 50 commits newer than
> `iso/RUNTIME` claims, and that newer runtime **does not contain the binary
> this ISO's installer shells out to** — so the artifact would abort roughly
> two-thirds of the way through an install.

This is the failure `docs/tasks/T5-fork-plan.md` §0 predicted and marked
**(INFERRED)**. It is now **MEASURED**, on a real artifact.

**May T5c start? No.** May T5b start? Yes — see §7.

---

## 1. The bar

The slice table says "byte-comparable". **That word is wrong and should be
retired.** Three reasons, the first two of which were measurable before any
comparison was run:

1. `mkarchiso` stamps the build time into the image. The ISO9660 tree carries a
   file literally named `boot/<YYYY-MM-DD-HH-MM-SS>-00.uuid`, and the SquashFS
   superblock carries a creation timestamp. Two builds one second apart cannot
   be byte-identical.
2. `builder/build-iso.sh` composes the offline mirror with `pacman -Syw` against
   `mirror.omarchy.org` and `pkgs.omarchy.org/edge` **(READ,** upstream
   `builder/build-iso.sh` lines ~136-215**)**. Both are rolling. `T5-fork-plan`
   §2 already conceded this: *"'reproducible' means 'same inputs by
   declaration', not bit-identical."*
3. Byte-identity would not be the property we care about anyway. What T5c needs
   is *attribution*: if a later slice's ISO misbehaves, was it our overlay?
   That question is answered by structure and inputs, not by a hash.

**The defensible bar, four tests.** P1–P3 are T9's bar restated; **P4 is new**,
and it is guard 6.4 of `T5-fork-plan.md` §6 executed by hand for the first time.

| | Test | Fails when |
|---|---|---|
| **P1** | **Structural.** Every file sourced from `omarchy-iso@UPSTREAM` is byte-identical between the two images; the ISO9660 layout is identical modulo the build-timestamp UUID; no path exists in one and not the other except as the payload of a package that changed version | our build path did something upstream's does not |
| **P2** | **Inputs.** T9's four pins agree: `omarchy-dev` version · `basecamp/omarchy` commit · mirror channel · `omarchy-iso` ref | a declared pin did not hold |
| **P3** | **Manifest.** No package exclusive to either image; every version difference is a roll-*forward* of a stock Arch package; nothing Omarchy-authored and nothing in the boot chain differs | the package graph changed shape, or a stale cache served an older build |
| **P4** | **Coherence.** Every `/usr/bin/omarchy-*` the shipped orchestrator shells out to exists in the shipped runtime package | the ISO/runtime pair is internally inconsistent — i.e. the ISO cannot finish an install |

P1–P3 compare the two images. **P4 is a property of one image alone**, and it is
the one that decides this. An image can pass P1–P3 handsomely and still be
useless; the reference passes P4, the new build does not.

---

## 2. The two artifacts

| | A — reference (known-good) | B — first `iso/bin/build` output |
|---|---|---|
| file | `/home/huyke/ISOs/omarchy-2026.08.10-x86_64-quattro.iso` | `~/.cache/omarchy-deck/iso-build/release/omarchy-2026.08.12-x86_64-quattro.iso` |
| sha256 | `fbc87422…` (T9) | `c9703bc51623a881e66674a730f00e7d1565ce858aedb9cc25dab74e8707acbf` — **re-measured here, matches the value handed to this task** |
| size | 6,390,581,248 | 6,396,903,424 |
| `arch/version` | `2026.08.10` | `2026.08.12` |
| squashfs sealed | 2026-08-10 15:24:25 UTC | 2026-08-12 04:53:25 UTC |
| gap | — | **1 d 13 h 29 m** |
| `airootfs.sfs` sha512 | `30fa51c6…787a0a0c` | `2f4ac337…e29dda4` |
| `.sfs` bytes | 6,064,652,288 | 6,070,005,760 |
| airootfs paths | 104,175 | 104,195 (**+20**) |

Both: archiso, `SquashFS 4.0 / ZSTD / 1 MiB clusters /
DUPLICATES_REMOVED EXPORTABLE COMPRESSOR_OPTIONS` — identical format string.

---

## 3. P1 — structural: **PASS, and emphatically**

### 3a. ISO9660 layout: one file differs, and it is the clock

```
$ diff ref-iso-paths.txt new-iso-paths.txt
14c14
< boot/2026-08-10-15-24-25-00.uuid
---
> boot/2026-08-12-04-53-25-00.uuid
```

That is the **entire** difference across the ISO tree. Same `boot/grub/`, same
`boot/syslinux/`, same `EFI/`, same `arch/` — every other entry matches by name.

### 3b. Every `omarchy-iso@a12bfea`-sourced file is byte-identical

21 files compared by sha256. 18 `SAME`. The 3 that differ are **not** upstream
builder files — all three are written *from the runtime package* by
`build-iso.sh`, so they move when the runtime moves:

| file | result | provenance |
|---|---|---|
| the whole `orchestrator/` package (8 `.py`) | **SAME** | `omarchy-iso@a12bfea` |
| `package-targets`, `setup-form.sh`, `omarchy-other.packages` | **SAME** | a12bfea / runtime |
| `omarchy-iso-install`, `omarchy-install-dashboard` | **SAME** | a12bfea |
| `root/configurator`, `root/.zlogin`, `root/.automated_script.sh` | **SAME** | a12bfea |
| `etc/pacman.conf`, `etc/modprobe.d/blacklist-applesmc.conf` | **SAME** | a12bfea |
| `omarchy-base.packages` | DIFF | copied from the runtime package |
| `expected-packages` | DIFF | `934` → `939`, derived from the above |
| `etc/os-release` | DIFF | stamps the runtime version |

`root/configurator` being byte-identical matters on its own: it is the file
`T5-fork-plan.md` §5.5 will patch, and it has not moved under us.

### 3c. No `__pycache__` artifact

T9 found upstream's published beta 2 carried
`usr/share/omarchy-iso/orchestrator/__pycache__/` (9 `.pyc`) where our 08-10
local build did not. **Neither of the images compared here has it** — our new
build reproduces the reference's behaviour, not beta 2's. `usr/share/omarchy-iso/`
holds exactly the same 14 entries in both.

### 3d. The whole-rootfs path diff is 100 % package payload

269 paths only in A, 289 only in B. Every one falls into
`var/cache/omarchy/mirror/`, `var/lib/pacman/local/<pkg>-<ver>/`, or a versioned
payload directory of a package that changed version — e.g.
`usr/lib/cmake/expat-2.8.2/` → `expat-2.8.3/`, `libffi.so.8.4.1` →
`8.5.0`, `platformdirs-4.11.1.dist-info` → `4.11.2.dist-info`,
`usr/lib/firmware/intel-ucode/` gaining three microcode blobs. **Zero paths of
our own. Zero orphans.** The overlay is empty and the artifact proves it.

### 3e. `omarchy-iso-make` was not called, and it did not matter

`iso/bin/build` deliberately drives `builder/build-iso.sh` itself rather than
`bin/omarchy-iso-make`, to avoid guard 6.3's `sudo rm -rf /var/cache/pacman/pkg/*`.
Three independent checks that this divergence did not change the artifact:

1. **3a + 3b above** — the build-side output is byte-for-byte what upstream's
   own path produces.
2. **No cache staleness.** Guard 6.3's scratch pacman cache *persists* across
   runs, where `omarchy-iso-make` wipes the host's every time. A persisted cache
   could in principle bake in a stale package. It did not: of the 56 version
   differences in the offline mirror, `vercmp` reports **56 upgrades and 0
   downgrades**. Not one package in the new image is older than the reference's.
3. **Repeatability.** The 08-11 build (`1bfff64e…`, squashfs sealed 2026-08-11
   23:45:22 UTC) and the 08-12 build, five hours apart through the same script,
   produce an **identical 483-package live manifest** and an identical ISO layout
   apart from the same one timestamp UUID.

The stamps `/root/omarchy_mirror` = `edge` and `/root/omarchy_iso_ref` =
`quattro` are identical in both images, so guard 6.1 held. (Note the reference
also says `quattro` — upstream's published beta 2 is the one that says `edge`;
T9 §2.)

---

## 4. P2 — inputs: **FAIL, on the pin that matters most**

| pin | reference | new build | |
|---|---|---|---|
| mirror channel (`/root/omarchy_mirror`) | `edge` | `edge` | ✅ |
| `omarchy-iso` ref (`/root/omarchy_iso_ref`) | `quattro` | `quattro` | ✅ |
| `omarchy-iso` commit | `a12bfea` | `a12bfea` (submodule verified by `bin/build`; corroborated by §3b's byte-identity) | ✅ |
| **`basecamp/omarchy` commit** | **`6d7826d`** (r1617) | **`4727bad`** (r1667) | 🔴 |
| **`omarchy-dev` / `omarchy-settings-dev`** | `4.0.0.r1617.g6d7826d-1` | `4.0.0.r1667.g4727bad-1` | 🔴 |

Corroborated three ways in the new image, as T9 did: the bundled
`omarchy-dev-4.0.0.r1667.g4727bad-1-any.pkg.tar.zst`, the `offline.db` entry,
and `/etc/os-release` (`BUILD_ID="4.0.0.r1667.g4727bad"`,
`IMAGE_VERSION=2026.08.12`).

**`iso/RUNTIME` says `basecamp/omarchy@6d7826d`. The artifact says `4727bad`.**
The file is a comment, not a pin — `iso/bin/build` prints it and says so
("*runtime pin (not yet enforced by this slice — T5b wires `--local-source`*"),
and `build-iso.sh` resolves the runtime with
`pacman --config /configs/pacman-online-edge.conf -Syw omarchy-dev`, i.e.
whatever `edge` serves at the instant of the build. This is `T5-fork-plan.md`
§2's *"`OMARCHY_MIRROR=edge` is not a pin"*, confirmed on an artifact.

**How fast it drifts — three measured points:**

| when (UTC) | `edge` served | source |
|---|---|---|
| 2026-08-10 15:24 | `r1617.g6d7826d` | the reference ISO |
| 2026-08-11 (daytime) | `r1652.g1c9dfc5` | `T5-fork-plan.md` §0, read from `omarchy.db` |
| 2026-08-11 23:45 **and** 2026-08-12 04:53 | `r1667.g4727bad` | **both** of our builds |

50 commits in 38 hours. **No rebuild, at any hour, can reproduce the
reference's runtime.** Only `--local-source` (T5b) can.

---

## 5. P3 — manifest: **FAIL, narrowly, and the failure is downstream of P2**

### 5a. Offline repo — `var/cache/omarchy/mirror/offline/`

**1244 packages (A) vs 1248 (B). 0 exclusive to A, 4 exclusive to B, 56 changed
version, 0 downgrades.** Cross-checked twice, as T9 did — once from the
`.pkg.tar.zst` filenames, once from the `offline.db.tar.gz` repo-database
entries. The two agree exactly, in both images.

The 4 exclusives:

| package | why it appeared |
|---|---|
| `libvips` | **newly declared** in the runtime's `omarchy-base.packages` |
| `cfitsio`, `libcgif`, `libimagequant` | its transitive dependencies |

`omarchy-base.packages` gained exactly two lines between `6d7826d` and
`4727bad`: `libvips` and `zbar`. (`zbar` was already in the mirror as somebody
else's dependency, so it adds no exclusive row.) `expected-packages` moved
`934` → `939` accordingly — the two agree, which means S1's three-way coupling
(`T5-fork-plan.md` §3) is intact.

**This is not our overlay.** The overlay is empty; the list came out of the
runtime package. It is P2's failure showing up in the manifest.

Of the 56 version changes, **54 are stock Arch roll-forwards** (`gcc` 16.1→16.2
and its 12 companion libs, `glibc`, `linux` 7.1.6→7.1.8, `openssh` 10.4→10.5,
`intel-ucode`, `expat`, `libffi`, `tailscale`, `electron43`, `obsidian`, …).
**2 are Omarchy-authored**: `omarchy-dev` and `omarchy-settings-dev`, both
`r1617.g6d7826d` → `r1667.g4727bad`.

**The boot chain is untouched** — spelled out because `CLAUDE.md` makes it a
hard constraint:

| package | A | B |
|---|---|---|
| `limine` | `12.5.2-1` | `12.5.2-1` |
| `limine-mkinitcpio-hook` | `1.37.1-1` | `1.37.1-1` |
| `limine-snapper-sync` | `1.31.0-1` | `1.31.0-1` |

### 5b. Live environment — `arch/pkglist.x86_64.txt`

**483 in each. 0 exclusive either way. 34 changed version**, of which exactly
one is Omarchy-authored (`omarchy-settings-dev`, the same bump). Everything else
is a stock Arch roll-forward.

### 5c. Boot chain, checked directly

The live ISO boots itself via GRUB (UEFI) + syslinux (BIOS) — that is archiso's
own boot menu and is identical in both images (§3a). What `CLAUDE.md` constrains
is the **installed** system, and there:

- the orchestrator has **174 `limine` references** and **zero** `grub` /
  `systemd-boot` / `bootctl` references (grep, new image);
- `phases_impl.py` is byte-identical to the reference (§3b), so
  `_write_limine_defaults`, `finalize_limine_boot` and `validate_boot` are
  literally the same code;
- the offline mirror ships the identical bootloader set in both — `limine*` as
  above, plus `grub 2:2.14-1`, `refind 0.14.2-3`, `efibootmgr 18-4`,
  `systemd 261.2-1` (all archinstall dependencies, all present in the reference
  too, none used).

**No regression. Limine only, unchanged.**

---

## 6. P4 — coherence: 🔴 **FAIL, and this is the verdict**

`T5-fork-plan.md` §0 predicted this and labelled it **(INFERRED)** —
*"nobody has run it."* Here it is, on the artifact:

**Measured, in the new ISO:**

```
$ grep -rhoE '/usr/bin/omarchy-[a-z-]+' usr/share/omarchy-iso/
/usr/bin/omarchy-hibernation-setup
/usr/bin/omarchy-provision-user
/usr/bin/omarchy-setup-system          ← run_system_finalizer, phases_impl.py:1140,1142
```

**Measured, in the runtime package that same ISO bundles**
(`omarchy-dev-4.0.0.r1667.g4727bad-1-any.pkg.tar.zst`):

```
usr/bin/omarchy-apply-system            ← the rename landed
usr/bin/omarchy-hibernation-setup
usr/bin/omarchy-provision-user
```

- **Zero** paths in that package match `setup-system`. Not a file, not a symlink.
- It ships **no `.INSTALL` scriptlet**, so nothing creates a compatibility link
  at install time.
- `usr/share/omarchy/bin/` mirrors `usr/bin/` symlink-for-symlink — and it too
  has `omarchy-apply-system`, never `omarchy-setup-system`.

**In the reference ISO the same package ships `usr/bin/omarchy-setup-system`**
and the pair is coherent.

**The failure mode, and it is loud, not silent.**
`run_system_finalizer` builds
`["/usr/bin/omarchy-setup-system", "--install-user", <user>, "--first-install"]`
and hands it to `_run_target_setup_command`, which runs
`arch-chroot <target> env … <cmd>` under `subprocess.run(…, check=True)`
**(READ,** `phases_impl.py:1119-1120**)**. A missing binary gives exit 127 →
`CalledProcessError` → the phase aborts. So `CLAUDE.md`'s "never silently
swallow a failure" is *satisfied* — upstream fails properly. But it fails at
phase 5 of 14 ("Configuring system"), **after** partitioning, LUKS, pacstrap and
~1200 packages. On a Deck, that is a long walk to a dead end.

**This image cannot complete an install.** It is therefore not a parity witness
for anything, and no later slice can be attributed against it.

---

## 7. What this means for the slice order

### Parity FAILED. But precisely *which half* failed matters.

| | status |
|---|---|
| The **pipeline** — submodule pinning, guard 6.1, guard 6.3's cache redirection, the empty-overlay rsync, the hand-driven Docker call in place of `omarchy-iso-make` | ✅ **proven.** P1 passes at the level of "one filename differs, and it is a clock". Repeatable across two runs. No staleness, no orphan files, no boot-chain drift |
| The **product** — the ISO the pipeline emitted on 2026-08-12 | 🔴 **fails P2, P3 and P4.** It bundles a runtime 50 commits past `iso/RUNTIME`, and that runtime is missing the binary its own installer invokes |

### 🔴 T5c: **NO. Not yet.**

Three reasons, in descending order of force:

1. **The rule's own justification applies verbatim.** *"An overlay whose base
   build was never shown to reproduce the known-good ISO cannot attribute any
   later failure."* This base build does not reproduce it, and worse, cannot
   finish an install — so every `[V]`-tier assertion in T5d/T5e/T5f is
   unreachable through it, and a T5c-era failure would be indistinguishable
   from the P4 breakage.
2. **T5c's own check has a moving denominator.** T5c must *"assert a dry run
   shows zero NVIDIA packages"* against the mirror it composes. That mirror's
   contents are a function of the runtime's `omarchy-base.packages`, which
   changed by two lines and four resolved packages **in this very comparison**.
   An assertion over an input set that drifts daily is the shape of check
   `T5-fork-plan.md` §5 exists to forbid: it passes, and it means nothing.
3. **Ordering cost is near zero.** T5b is sized **S**, depends only on T5a's
   pipeline (which is proven), and its entire content is the fix. §8 already
   says *"put guard 6.4 in **before** the bake-ins, not after."*

### ✅ T5b: **YES, start now.** T5a's pipeline is proven and that is all T5b needs.

Two notes for whoever writes T5b:

- **Guard 6.4 is not hypothetical any more.** Its predicate — every
  `/usr/bin/omarchy-*` grepped out of the patched `phases_impl.py` must exist in
  the runtime package — was executed by hand in §6 above and **fires on today's
  artifact**. It has a real failing case to be tested against, which
  `T5-fork-plan.md` §5.4 rightly demands ("a guard nobody has seen fail is not
  a guard").
- **`--local-source` changes what the re-measurement can assert.** It *builds*
  `omarchy-dev` from a pinned checkout instead of downloading the published
  `.pkg.tar.zst`, so the archive will not hash-match the reference's even at the
  same commit (different build time, different `pkgrel` provenance). Re-run
  §4/§5's comparisons against the **version string** (`4.0.0.r1617.g6d7826d`)
  and the package's **file list**, never the archive checksum.

### The re-measurement that would close T5a

After T5b lands, rebuild and re-run §9's commands. **Parity is proven when:**

- **P1** unchanged from §3 — one differing filename, the timestamp UUID;
- **P2** all four pins equal, i.e. `BUILD_ID="4.0.0.r1617.g6d7826d"`;
- **P3** zero packages exclusive to either image, and every version difference
  is a stock Arch roll-forward with nothing Omarchy-authored and no `limine*`
  row moving;
- **P4** the coherence check passes on the new image alone.

That is achievable — it is exactly T9's result, which the reference already
demonstrated is reachable — and it is the honest bar. "Byte-comparable" is not.

---

## 8. Measured vs inferred

**MEASURED**, on the artifacts, this session:

- both ISOs' sha256, size, `arch/version`, `airootfs.sha512`, squashfs
  superblock format and creation time;
- the full ISO9660 path listing of all three of our/reference images, diffed;
- both airootfs path listings (104,175 / 104,195), diffed and categorized;
- the offline-repo manifest by **two** independent routes (filenames and
  `offline.db.tar.gz` entries), which agree, in both images;
- `vercmp` on all 56 changed offline packages → 56 up, 0 down;
- the live `pkglist.x86_64.txt` (483 / 483 / 34 changed / 0 exclusive);
- sha256 of 21 installer/config files across both images;
- both `/root/omarchy_mirror`, `/root/omarchy_iso_ref`, `/etc/os-release`,
  `/etc/pacman.conf`, `package-targets`, `omarchy-base.packages`,
  `expected-packages`;
- **the contents of both bundled `omarchy-dev` packages**, `bsdtar`-listed —
  this is the P4 result;
- the 08-11 build's runtime version and live manifest, for the repeatability
  and drift-rate claims.

**READ from source** (not measured on an artifact): `iso/bin/build`;
upstream `builder/build-iso.sh` lines ~95-215; `phases_impl.py`'s
`run_system_finalizer` and `_run_target_setup_command`.

**INFERRED, and flagged as such:**

- **That an install from this ISO would in fact abort at phase 5.** The
  ingredients are measured (the call site exists; the binary does not; the
  runner uses `check=True`), but **nobody has run this ISO.** The conclusion is
  as strong as a static argument gets and is still not an execution.
- That `cfitsio`/`libcgif`/`libimagequant` are present *because* `libvips`
  depends on them. Their arrival alongside `libvips`'s declaration is measured;
  the dependency edges were not re-derived from the `.PKGINFO`s.
- That the 54 non-Omarchy version changes are pure Arch-mirror motion. Their
  names and directions are measured; that none was influenced by our build path
  rests on §3e's three checks, not on auditing each package.

**Not attempted:** signature verification of the bundled `.pkg.tar.zst.sig`
files (needs `gpg` + the `omarchy-keyring` trust store) — same gap T9 recorded.

---

## 9. Reproduction — exact commands

Tools: `bsdtar` (ISO9660), `7-Zip 26.02` (ZSTD SquashFS, no root needed),
`vercmp` (from pacman). No `unsquashfs`, no loop-mount, no `sudo`.

⚠️ **The session scratchpad is tmpfs with a quota and cannot hold these.** The
first attempt died with `Write failed: Disk quota exceeded` at ~5 GiB. Two
`.sfs` files are ~11.3 GiB; use a disk-backed scratch dir outside the repo.

```bash
BIG=~/.cache/omarchy-deck/t5a-parity-scratch     # NOT the tmpfs scratchpad
mkdir -p "$BIG" && cd "$BIG"
N=~/.cache/omarchy-deck/iso-build/release/omarchy-2026.08.12-x86_64-quattro.iso
R=~/ISOs/omarchy-2026.08.10-x86_64-quattro.iso

# --- ISO level -------------------------------------------------------------
for p in new:$N ref:$R; do k=${p%%:*}; f=${p#*:}
  echo "$k $(stat -c%s "$f") $(bsdtar -xOf "$f" arch/version) \
$(bsdtar -xOf "$f" arch/x86_64/airootfs.sha512)"
  bsdtar tf "$f" | sort > $k-iso-paths.txt
  bsdtar -xOf "$f" arch/pkglist.x86_64.txt | sort > $k.pkglist
done
diff ref-iso-paths.txt new-iso-paths.txt          # -> the .uuid line only
diff ref.pkglist new.pkglist

# --- materialise both squashfs (needs random access; piping does NOT work) --
bsdtar -xf "$N" -C . arch/x86_64/airootfs.sfs && mv arch/x86_64/airootfs.sfs new.sfs && rm -rf arch
bsdtar -xf "$R" -C . arch/x86_64/airootfs.sfs && mv arch/x86_64/airootfs.sfs ref.sfs && rm -rf arch
7z l new.sfs | sed -n '/^Path/,/^Charact/p'       # format + Created timestamp
for s in new ref; do
  7z l -ba -slt $s.sfs | grep '^Path = ' | sed 's/^Path = //' | sort > $s-paths.txt &
done; wait
diff ref-paths.txt new-paths.txt > pathdiff.txt   # 3d

# --- P3: offline manifest, two independent ways ----------------------------
for s in new ref; do
  grep '^var/cache/omarchy/mirror/offline/.*\.pkg\.tar\.zst$' $s-paths.txt \
    | sed 's|.*/||' | sort > $s-offline-pkgs.txt
  sed -E 's/^(.*)-([^-]+)-([^-]+)-([^-]+)\.pkg\.tar\.zst$/\1\t\2-\3/' \
    $s-offline-pkgs.txt > $s.map
  7z x -y -o./db/$s $s.sfs 'var/cache/omarchy/mirror/offline/offline.db.tar.gz' >/dev/null
  tar tzf db/$s/var/cache/omarchy/mirror/offline/offline.db.tar.gz \
    | grep '/$' | sed 's|/$||' | sort > $s-db-entries.txt
done
# NB: gawk reserves `or` -- do not name a counter that (it is a syntax error).
awk -F'\t' 'NR==FNR{r[$1]=$2;next}{n[$1]=$2}
END{c=0;a=0;b=0
    for(k in r){if(!(k in n)){print "ONLY-REF "k" "r[k];a++} else if(r[k]!=n[k])c++}
    for(k in n) if(!(k in r)){print "ONLY-NEW "k" "n[k];b++}
    print "changed="c" only-ref="a" only-new="b}' ref.map new.map
# direction of every change -- catches a stale cache serving an older package
awk -F'\t' 'NR==FNR{r[$1]=$2;next}{if(($1 in r)&&r[$1]!=$2)print $1,r[$1],$2}' \
  ref.map new.map | while read -r n rv nv; do
    [ "$(vercmp "$nv" "$rv")" -lt 0 ] && echo "DOWNGRADE $n $rv -> $nv"; done

# --- P1/P2: metadata + byte-compare the installer --------------------------
for s in new ref; do 7z x -y -o./x/$s $s.sfs \
  'root/omarchy_iso_ref' 'root/omarchy_mirror' 'root/configurator' 'root/.zlogin' \
  'root/.automated_script.sh' 'etc/pacman.conf' 'etc/os-release' \
  'etc/modprobe.d/blacklist-applesmc.conf' 'usr/share/omarchy-iso/*' \
  'usr/local/bin/omarchy-iso-install' 'usr/local/bin/omarchy-install-dashboard' \
  >/dev/null; done
for s in new ref; do echo "$s $(cat x/$s/root/omarchy_iso_ref) $(cat x/$s/root/omarchy_mirror)"
  grep -E 'BUILD_ID|IMAGE_VERSION' x/$s/etc/os-release; done
for f in usr/share/omarchy-iso/orchestrator/*.py usr/share/omarchy-iso/setup-form.sh \
         usr/share/omarchy-iso/package-targets usr/share/omarchy-iso/*.packages \
         usr/share/omarchy-iso/expected-packages usr/local/bin/omarchy-iso-install \
         usr/local/bin/omarchy-install-dashboard root/configurator root/.zlogin \
         root/.automated_script.sh etc/pacman.conf etc/os-release; do
  a=$(sha256sum "x/ref/$f" | cut -c1-12); b=$(sha256sum "x/new/$f" | cut -c1-12)
  [ "$a" = "$b" ] && echo "SAME  $f" || echo "DIFF  $f  $a $b"; done
diff <(sort x/ref/usr/share/omarchy-iso/omarchy-base.packages) \
     <(sort x/new/usr/share/omarchy-iso/omarchy-base.packages)

# --- P4: THE COHERENCE CHECK (this is guard 6.4, by hand) ------------------
grep -rhoE '/usr/bin/omarchy-[a-z-]+' x/new/usr/share/omarchy-iso/ | sort -u
7z x -y -o./pkg new.sfs \
  'var/cache/omarchy/mirror/offline/omarchy-dev-*.pkg.tar.zst' >/dev/null
f=$(ls pkg/var/cache/omarchy/mirror/offline/*.pkg.tar.zst)
bsdtar tf "$f" | grep -E '^usr/(bin|share/omarchy/bin)/omarchy-'   # compare the two sets
bsdtar tf "$f" | grep -c 'setup-system'                            # -> 0
bsdtar -xOf "$f" .INSTALL 2>/dev/null || echo "no .INSTALL scriptlet"

# --- boot chain ------------------------------------------------------------
for s in ref new; do grep -iE '^(limine|grub|systemd-boot|refind|efibootmgr)-' \
  $s-offline-pkgs.txt; done
grep -rniE 'grub|systemd-boot|bootctl' x/new/usr/share/omarchy-iso/orchestrator/*.py \
  | grep -v grubenv || echo "NONE"

# --- CLEAN UP: ~12 GiB ------------------------------------------------------
cd ~ && rm -rf "$BIG"
```

### Notes for a future session

- **Do not use the tmpfs scratchpad for `.sfs` extraction.** It quota-fails
  silently-ish partway through a 5.65 GiB write; `bsdtar` does report it, but
  the half-written file looks plausible. Disk-backed scratch, always.
- `7z` remains the `unsquashfs` replacement (T9's note holds). `bsdtar` reads
  ISO9660 and `.pkg.tar.zst` but **cannot** read squashfs.
- The whole of §4, §5 and §6 — the parts that decided the verdict — come from
  the offline mirror, one package archive, and about eight small files. Nothing
  here needed a root filesystem unpacked wholesale.
- Peak disk: ~12 GiB for the two `.sfs`, plus ~1 GiB of extractions.

---

## ✅ RESOLVED 2026-08-12 by T5b's `--local-source` — the decisive gate is open

The failure above was **the runtime drifting off its pin**, and pinning it fixes
it. A build with T5b's `--local-source` wiring, and `iso/PKGS` pinned to
`omacom-io/omarchy-pkgs@ae07234a016c` (operator decision, same day), produced:

```
runtime pin OK: basecamp/omarchy@6d7826d635d0ba57a6a7b0e8a29d04411da77ced
guard 6.4a OK: all 3 orchestrator-called binaries exist in 6d7826d's bin/ (408 candidates)
guard 6.4b: omarchy-dev 4.0.0.r1617.g6d7826d-1 built from basecamp/omarchy@6d7826d
guard 6.4b OK: all 3 orchestrator-called binaries are present in the packages this ISO carries
build complete: omarchy-2026.08.12-x86_64-quattro.iso   5.9G
```

**Verified independently of the guard**, by reading the built package rather
than trusting the log:

| | Runtime | `omarchy-setup-system` | `omarchy-apply-system` |
|---|---|---|---|
| Reference ISO (known-good) | `4.0.0.r1617.g6d7826d-1` | present | — |
| The broken unpinned build (above) | `4.0.0.r1667.g4727bad` | **absent** | present |
| **This build** | **`4.0.0.r1617.g6d7826d-1`** | **present** | **0 matches** |

The version string carries the pinned commit, which is T5b's own strongest
check (§3 of its report): `--local-source` silently failing to apply would
otherwise be invisible in a green log.

### ⚠️ What this does and does not settle

✅ **The P4 coherence test passes** — the ISO no longer bundles a runtime
missing the binary its own installer shells out to, so it can no longer die at
phase 5 of 14. **That was the blocker, and it is open.**

🟡 **Full parity under §7's four tests has NOT been re-measured.** P1/P2/P3
(structural, inputs, manifest) still need a run. ⚠️ And per T5b's own caveat,
that re-measurement **must compare the version string and file list, never the
archive checksum** — `--local-source` *builds* the runtime rather than
downloading it, so a byte-comparison is meaningless by construction.

🔴 **Nobody has booted this ISO.** That an install now completes past phase 5
is an inference from the ingredients, exactly as the failure was. The [V] tier
(`test/vm/`) is where that gets settled.

---

# APPENDIX A — the four-test re-measurement, 2026-08-12 (session 22)

§7 above defined the re-measurement that closes T5a and said only P4 had been
run. This appendix runs **all four** against the pinned build, using §9's method
unchanged — `bsdtar` + `7z`, manifests and pins, no new technique.

## A0. Verdict

🟢 **Parity is proven under §7's bar. T5c may start.**

> Every difference between the pinned build and the reference is temporal —
> a clock, a build date, or a package that moved on `edge` between 2026-08-10
> and 2026-08-12. **Not one difference is attributable to our build path.**
> P1, P2, P3 and P4 all pass.

The three reasons §7 gave for blocking T5c are each discharged below (A7).

## A1. The artifacts

| | A — reference (known-good) | B — the pinned build |
|---|---|---|
| file | `/home/huyke/ISOs/omarchy-2026.08.10-x86_64-quattro.iso` | `~/.cache/omarchy-deck/iso-build/release/omarchy-2026.08.12-x86_64-quattro.iso` |
| sha256 | (T9) | `8ac3502afad238592734b460de86fb8c3f60eaf89890b3f40d2991d2ffa351ea` — **re-measured, matches the value handed to this task** |
| size | 6,390,581,248 | 6,273,040,384 (**−117,540,864**, fully accounted for in A4c) |
| `arch/version` | `2026.08.10` | `2026.08.12` |
| squashfs sealed | 2026-08-10 15:24:25 UTC | 2026-08-12 14:53:23 UTC |
| `.sfs` bytes | 6,064,652,288 | 5,946,249,216 |
| airootfs paths | 104,175 | 104,210 (**+35**) |
| uncompressed total | 7,232,678,753 | 7,115,680,566 |

Both: `SquashFS 4.0 / ZSTD / 1 MiB clusters / DUPLICATES_REMOVED EXPORTABLE
COMPRESSOR_OPTIONS` — identical format string. **(MEASURED)**

⚠️ This is **not** the artifact §2–§6 measured. That one
(`c9703bc5…`, runtime `r1667.g4727bad`) is retained beside it as
`omarchy-2026.08.12-…iso.t5a-superseded`. Do not confuse them.

## A2. P1 — structural: ✅ **PASS**

### A2a. ISO9660 layout — one file differs, and it is the clock

```
$ diff ref-iso-paths.txt new-iso-paths.txt
14c14
< boot/2026-08-10-15-24-25-00.uuid
---
> boot/2026-08-12-14-53-23-00.uuid
```

The **entire** ISO tree difference, exactly as §3a found. **TEMPORAL.**
**(MEASURED)**

### A2b. Upstream-sourced files — 20 of 21 byte-identical, and the 21st is a date

| file | result |
|---|---|
| all 8 `orchestrator/*.py` (incl. `phases_impl.py`) | **SAME** |
| `omarchy-base.packages`, `omarchy-other.packages` | **SAME** ← *moved in §3b; pinned now* |
| `expected-packages` (`934` = `934`) | **SAME** ← *moved in §3b; pinned now* |
| `package-targets`, `setup-form.sh` | **SAME** |
| `omarchy-iso-install`, `omarchy-install-dashboard` | **SAME** |
| `root/configurator`, `root/.zlogin`, `root/.automated_script.sh` | **SAME** |
| `etc/pacman.conf`, `etc/modprobe.d/blacklist-applesmc.conf` | **SAME** |
| `etc/os-release` | **DIFF** |

`os-release`'s complete diff is one line:

```
< IMAGE_VERSION=2026.08.10
---
> IMAGE_VERSION=2026.08.12
```

`BUILD_ID` is **identical**. **TEMPORAL.** This is strictly better than §3b,
which had three DIFFs — `omarchy-base.packages` and `expected-packages` are now
byte-identical because the runtime that writes them is pinned. **(MEASURED)**

`root/configurator` byte-identical again: the file §5.5 will patch has still not
moved under us.

### A2c. `usr/share/omarchy-iso/` — 15 paths, tree identical, no `__pycache__`

`diff` of the subtree path lists is empty in both directions; `__pycache__`
count is `0` in both. Reproduces §3c. **(MEASURED)**

### A2d. Rootfs path diff — 100 % package payload, zero paths of our own

305 only in A, 340 only in B. 286 / 283 of those sit inside
`var/cache/omarchy/mirror/` or `var/lib/pacman/local/<pkg>-<ver>/`. The
remaining **19 / 57** were read individually and every one is the versioned
payload of a package in A4's changed list:

`expat-2.8.2/`→`2.8.3/` · `libffi.so.8.4.1`→`8.5.0` · `libp11-kit.so.0.4.10`→`0.4.11` ·
`libsgutils2-1.48`→`1.49` · `libtorrent-rasterbar.so.2.1.0`→`2.1.1` ·
`platformdirs-4.11.1.dist-info`→`4.11.2` · `pip-26.1.2-…whl`→`26.2.1` ·
`cloudinit/sources/azure/certs.py` (cloud-init 26.1→26.2) ·
`etc/tpm2-tss/**` + `libtss2-tcti-null*` (tpm2-tss 4.1.3→4.2.0) ·
`etc/tunables.conf*` (glibc) · 3 `intel-ucode` blobs · `70-openssh-restart-sshd.hook` ·
`scsi/sg_nvme.h`,`sg_snt.h`,`scsi-rescan.8.gz` (sg3_utils).

**Zero paths of our own. Zero orphans.** The overlay is 2 `.gitkeep` files and
the artifact proves it. **TEMPORAL.** **(MEASURED)**

## A3. P2 — inputs: ✅ **PASS, all four pins**

| pin | reference | pinned build | |
|---|---|---|---|
| mirror channel (`/root/omarchy_mirror`) | `edge` | `edge` | ✅ |
| `omarchy-iso` ref (`/root/omarchy_iso_ref`) | `quattro` | `quattro` | ✅ |
| `omarchy-iso` commit | `a12bfea` | `a12bfea` (submodule at `a12bfea7a86c…`; corroborated by A2b) | ✅ |
| **`basecamp/omarchy` commit** | **`6d7826d`** (r1617) | **`6d7826d`** (r1617) | ✅ |

`/etc/os-release` reads `BUILD_ID="4.0.0.r1617.g6d7826d"` in **both**.
Corroborated the same three ways T9 and §4 used: the bundled
`omarchy-dev-4.0.0.r1617.g6d7826d-1-any.pkg.tar.zst`, the `offline.db` entry,
and `os-release`. **This is the pin that failed in §4. It holds.** **(MEASURED)**

**A fifth input now exists and has no counterpart in the reference.**
`iso/PKGS` → `omacom-io/omarchy-pkgs@ae07234a016c`; the build's checkout is at
`ae07234a016cbc47e26a21b9bba99dc33a17272b` and the runtime checkout at
`6d7826d635d0ba57a6a7b0e8a29d04411da77ced`. **(MEASURED)** The reference ISO
predates the pin and cannot be compared against it — it is *declared*, not
*corroborated*. See A5 for what it does and does not cover.

## A4. P3 — manifest: ✅ **PASS**

### A4a. Offline repo — the headline number

**1244 packages (A) vs 1244 (B). 0 exclusive to A, 0 exclusive to B, 64 changed
version, 0 downgrades** (`vercmp` on all 64). Cross-checked by the two
independent routes §5a used — `.pkg.tar.zst` filenames and `offline.db.tar.gz`
entries — which agree with `diff` = 0 lines **in both images**. **(MEASURED)**

§5a's four exclusives (`libvips` + 3 deps) are **gone**, because
`omarchy-base.packages` is now byte-identical to the reference's (A2b). That
confirms the §5a reading: they were the runtime's declaration moving, not our
overlay.

**Zero Omarchy-authored version changes.** All four omarchy packages match by
name *and* version in both images:

```
omarchy-dev-4.0.0.r1617.g6d7826d-1     omarchy-keyring-20251027-1
omarchy-nvim-2026.8.1-1                omarchy-settings-dev-4.0.0.r1617.g6d7826d-1
```

**The boot chain is byte-for-byte untouched** — identical rows in both:

| | A | B |
|---|---|---|
| `limine` | `12.5.2-1` | `12.5.2-1` |
| `limine-mkinitcpio-hook` | `1.37.1-1` | `1.37.1-1` |
| `limine-snapper-sync` | `1.31.0-1` | `1.31.0-1` |
| `grub` / `refind` / `efibootmgr` / `systemd` | `2:2.14-1` / `0.14.2-3` / `18-4` / `261.2-1` | identical |

Orchestrator: **133 lines** referencing `limine`, **zero** `grub` /
`systemd-boot` / `bootctl`. Moot anyway — `phases_impl.py` is byte-identical to
the reference's (A2b), so it is literally the same code. **(MEASURED)**

### A4b. 🆕 Content check, stronger than §7 asked for

§7's P3 bar is about names and versions. The repo database carries a
`%SHA256SUM%` per package, which lets the same 1244 rows be compared **by
content** for free:

- **1180 filenames present in both images** (same name *and* version);
- **1177 of them are byte-identical**;
- the only 3 same-name-different-bytes packages are
  `omarchy-dev`, `omarchy-settings-dev`, `omarchy-nvim` — **exactly** the three
  that `builder/build-omarchy-packages.sh` builds from source under
  `--local-source` **(READ,** its `packages=()` array**)**.

Nothing else in the image differs by a byte at the same version. **(MEASURED)**
This is the sharpest available answer to "did our build path change anything":
of 1180 comparable packages, it changed the 3 it is designed to change.

### A4c. The 118 MB size drop — accounted for, and it is upstream's

66 packages changed size; summed delta **−118,801,216 bytes**, i.e. the entire
ISO shrink lives in the offline mirror. Three packages are 119.9 MB of it:

| package | ref | new | Δ |
|---|---|---|---|
| `nvidia-580xx-utils` | `580.173.02-1` | `580.173.02-1.1` | −87,210,098 |
| `lib32-nvidia-580xx-utils` | `580.173.02-1` | `580.173.02-1.1` | −26,697,614 |
| `nvidia-580xx-dkms` | `580.173.02-1` | `580.173.02-1.1` | −6,025,773 |

A `pkgrel` bump, so it is one of the 64 and `vercmp` scores it an upgrade. Its
`.PKGINFO` differs from the reference's in `pkgver` and `builddate` **only**;
`builddate` = **2026-08-12 11:05 UTC**, nearly four hours *before* our container
started (our locally-built packages stamp **14:51 UTC**). NVIDIA is **not** in
`build-omarchy-packages.sh`'s `packages` array, so it was downloaded, not built.
**Upstream repackaged it that morning. TEMPORAL.** **(MEASURED)**

### A4d. Live environment — `arch/pkglist.x86_64.txt`

**483 in each. 0 exclusive either way. 38 changed version, 0 downgrades, and
zero Omarchy-authored rows** — `omarchy-settings-dev 4.0.0.r1617.g6d7826d-1` and
`omarchy-keyring 20251027-1` are identical in both. In §5b that
`omarchy-settings-dev` row was the one that moved; it no longer does. The
boot-chain rows in the live manifest `diff` clean. **(MEASURED)**

The 38 are stock Arch roll-forwards: `gcc` 16.1→16.2 and its 12 companion libs,
`glibc`, `binutils`, `openssh` 10.4→10.5, `python` 3.14.6→3.14.7, `perl`,
`tpm2-tss` 4.1.3→4.2.0, `intel-ucode`, `expat`, `libffi`, `cloud-init`,
`fontconfig`, `nspr`, `sg3_utils`, `hyperv` 7.1.7→7.1.8, … **TEMPORAL.**

## A5. 🔴 The `--local-source` trap, judged package by package

§7 warned that `--local-source` *builds* the runtime, so **archive checksums are
meaningless by construction**. They are (A4b: all 3 differ). Here is the
comparison that is *not* meaningless — **version string and file list**:

| package | files ref → new | file-list diff | `.PKGINFO` diff | class |
|---|---|---|---|---|
| `omarchy-dev` | 1573 → 1573 | **IDENTICAL** | `builddate` **only** (2026-08-10 13:23 → 2026-08-12 14:51 UTC) | **TEMPORAL** |
| `omarchy-settings-dev` | 622 → 622 | **IDENTICAL** | `builddate` **only** (2026-08-10 13:23 → 2026-08-12 14:51 UTC) | **TEMPORAL** |
| `omarchy-nvim` | 9803 → 9808 | 101 paths — see below | `builddate` + `size` | **TEMPORAL**, with a caveat |

For the two packages that decide the install, **a source build at the pinned
commit reproduces upstream's published package file-for-file, and the only
recorded difference in the whole archive is the second it was built.** That is
as close to parity as `--local-source` can get, and it is the answer to §7's
question. **(MEASURED)**

### ⚠️ `omarchy-nvim` is a genuinely unpinned input — record it, it is not a blocker

Its 101 differing paths break down as **96 under
`etc/skel/.local/share/nvim/lazy/*/.git/objects/pack/`** — content-addressed
pack filenames, which are non-deterministic per clone — plus **5 real new plugin
files**: `conform.nvim`'s `djangofmt.lua` and `luafmt.lua`,
`nvim-lspconfig`'s `pkl.lua` and `tsc.lua`, and a treesitter `scala/indents.scm`.

The cause **(READ,** the PKGBUILD path**;** corroborated by the pack-name churn**)**:
`omarchy-nvim` clones Neovim plugins from their git HEADs at build time. Pinning
`iso/PKGS` pins the *PKGBUILD*, not what the PKGBUILD fetches. The reference's
copy was built upstream on **2026-08-02**; ours on **2026-08-12** — ten days of
plugin upstream movement. **TEMPORAL**, not structural.

**Why it does not block T5c:** every affected path is under
`etc/skel/.local/share/nvim/`. It touches nothing in the boot chain, the
orchestrator, the installer, or `/usr/bin`. **But it means byte-stability across
rebuilds is not a property this ISO has, and no later slice may assert it.**

## A6. P4 — coherence: ✅ **PASS**, re-verified independently of the guard

Guard 6.4 passing in the build log is not evidence; §6's check was re-run by
hand on the artifact:

```
called by the shipped orchestrator (new image, and identical in ref):
  /usr/bin/omarchy-hibernation-setup
  /usr/bin/omarchy-provision-user
  /usr/bin/omarchy-setup-system
present in the bundled omarchy-dev-4.0.0.r1617.g6d7826d-1:
  all three ✅   ·   'setup-system' matches: 2 (usr/bin + usr/share/omarchy/bin)
                 ·   'apply-system'  matches: 0
```

The pair is internally consistent. The phase-5-of-14 abort of §6 is gone.
**(MEASURED)** 🔴 Still **INFERRED**, and unchanged from §6: that an install now
*completes*. Nobody has booted this ISO. That is the `[V]` tier's job.

## A7. Verdict for the slice order — 🟢 **T5c: YES, it may start**

§7 gave three reasons to block. Each is now discharged **(MEASURED** except
where noted**)**:

| §7's reason | status |
|---|---|
| 1. "This base build does not reproduce the reference, and cannot finish an install" | ✅ **discharged.** P1/P2/P3/P4 all pass; every difference is temporal. The attribution property T5c needs — *if a later ISO misbehaves, was it our overlay?* — now holds: the overlay's contribution to this artifact is measurably **nothing** |
| 2. "T5c's `zero NVIDIA packages` check has a moving denominator — `omarchy-base.packages` changed by two lines mid-comparison" | ✅ **discharged.** `omarchy-base.packages` is now **byte-identical** to the reference's (A2b), and `expected-packages` reads `934` in both. The denominator that moved is pinned |
| 3. "Ordering cost is near zero; do T5b first" | ✅ **spent.** T5b has landed; this appendix measures its output |

**⚠️ One caveat T5c must carry, not a blocker.** `iso/PKGS` pins the *sources of
the three locally-built packages*. The other ~1241 offline packages — NVIDIA
included — still come from rolling `edge` and moved 64 rows in two days (A4a).
So T5c's assertion should be written as a **shape** assertion ("no package
matching `nvidia*` resolves into the mirror") and never as a count or a version,
or it becomes the passes-and-means-nothing check §5 exists to forbid.

### Retired

**"Byte-comparable" stays retired** (§1's argument is unaffected). The bar that
replaced it — four tests, temporal-vs-structural classification — has now been
run twice: once on a failing artifact, once on a passing one. It discriminated
correctly both times, which is the only real evidence that a bar is a good one.

## A8. Measured vs inferred

**MEASURED**, on the two artifacts, this session: both sha256/size/`arch/version`
/`airootfs.sha512`/squashfs superblock; both full ISO9660 path listings, diffed;
both airootfs path listings (104,175 / 104,210), diffed and every out-of-bucket
path classified by hand; the offline manifest by two independent routes, agreeing,
in both images; `vercmp` on all 64 changed offline packages → 0 downgrades;
**per-package `%SHA256SUM%` for all 1244 rows** (A4b); per-package uncompressed
sizes and the full delta accounting (A4c); the live `pkglist.x86_64.txt`
(483/483/38/0); sha256 of 21 installer/config files; both `/root/omarchy_mirror`,
`/root/omarchy_iso_ref`, `/etc/os-release`, `omarchy-base.packages`,
`expected-packages`; `bsdtar` file lists **and `.PKGINFO`** of
`omarchy-{dev,settings-dev,nvim}` and `nvidia-580xx-utils` in both images; the
runtime/pkgs checkout HEADs; the submodule HEAD; P4 by hand.

**READ from source** (not measured on an artifact): `builder/build-omarchy-packages.sh`'s
`packages=()` array; T5b's `iso/bin/build` guard-6.4 wiring; `iso/PKGS`, `iso/RUNTIME`.

**INFERRED, flagged:**

- **That an install from this ISO completes.** Nobody booted it. A6.
- That `omarchy-nvim`'s churn is plugin-HEAD cloning. The pack-name churn and
  the 5 new plugin files are measured; the PKGBUILD's fetch behaviour was read,
  not executed.
- That the 64 non-Omarchy version changes are pure mirror motion. Names,
  directions and (for NVIDIA) build dates are measured; each package was not
  individually audited.
- **Repeatability was NOT re-tested.** §3e's claim rested on two runs five hours
  apart. Only one pinned build exists. Given A5, a second run would *not* be
  identical — `omarchy-nvim` would drift again. Do not assert rebuild stability.

**Not attempted:** signature verification of the bundled `.pkg.tar.zst.sig`
files — same gap T9 and §8 recorded.

## A9. Reproduction — the deltas from §9

§9's script runs unchanged and produces A2–A4a and A6. Three additions:

```bash
# A4b -- per-package content check from the repo DB (1244 rows, cheap)
for s in ref new; do
  rm -rf dbx/$s; mkdir -p dbx/$s
  tar xzf db/$s/var/cache/omarchy/mirror/offline/offline.db.tar.gz -C dbx/$s
  for d in dbx/$s/*/desc; do
    awk '/^%FILENAME%/{getline fn} /^%SHA256SUM%/{getline sh} END{if(fn!="")print fn"\t"sh}' "$d"
  done | sort > $s-sha.txt
done
join -t$'\t' ref-sha.txt new-sha.txt | awk -F'\t' '$2!=$3{print $1}'   # -> the 3 local builds

# A4c -- where the size went
for s in ref new; do 7z l -ba -slt $s.sfs \
  | awk '/^Path = /{p=substr($0,8)} /^Size = /{sz=substr($0,8); if(sz!="")print sz"\t"p}' > $s-sizes.txt; done
# ...then join on pkgname and sort the deltas

# A5 -- the ONLY valid comparison for a --local-source package
for p in omarchy-dev omarchy-settings-dev omarchy-nvim; do
  diff <(bsdtar tf "$REFPKG" | sort) <(bsdtar tf "$NEWPKG" | sort)      # file list, NOT checksum
  diff <(bsdtar -xOf "$REFPKG" .PKGINFO) <(bsdtar -xOf "$NEWPKG" .PKGINFO)
done
```

⚠️ `7z l -slt` on squashfs exposes **no CRC field** — that is why A4b goes
through the pacman repo DB rather than the image. Peak disk ~12 GiB; scratch was
`~/.cache/omarchy-deck/t5a-parity-scratch` (disk-backed, **never** the tmpfs
scratchpad) and was removed afterwards.

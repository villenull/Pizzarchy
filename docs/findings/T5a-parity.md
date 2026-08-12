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

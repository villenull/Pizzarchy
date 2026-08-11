# Upstream coupling inventory — every place this repo depends on something Omarchy (or its ISO builder, or Valve, or the Limine/SDDM/Steam machinery around them) owns

**Produced 2026-08-11 for P2.9b (`docs/tasks/T9-beta2-rebase.md`).** Every row cites a
file:line that was read. Rows are grouped by area; the `kind` column is one of
**binary / path / package / format / behaviour**. Paths are repo-root-relative.

The fourth column is the point of the document. `❌ nothing would notice` means: no
unit suite, no VM suite, no stage self-verification, and no CI step observes this. If
upstream moves it, everything stays green and the product breaks on a screen.

---

## 0. Read this first — the silent-breakage surface

The `❌ nothing would notice` rows, ranked by how much of the product they take with
them. Full evidence in the tables below.

| # | What | Where | Why it is silent |
|---|---|---|---|
| 1 | **`deck-session.sh` has NO integration test at all.** Its unit suite `source`s the file and exercises only `render_*` text and two pure predicates | `test/unit/test-deck-session.sh:92`; no file under `test/vm/` references it (grep) | The nine install stages *do* self-verify at runtime, but nothing runs them off-Deck. Every path/binary/format below that lives in a stage is verified **only when a human runs the stage on the Deck** |
| 2 | `/sys/module/hid_steam/parameters/lizard_mode=N` — the precondition that makes STEAM+X, Space and the whole mapper input layer work | Named in comments only: `src/deck-input-mapper.py:70,216`; `src/deck_osk_wayland.py:30`; `src/deck-session.sh` does not touch it | **No code in the repo reads, sets or persists it**, and it is a module parameter that resets to `Y` on reboot. Nothing anywhere fails |
| 3 | squeekboard's DBus interface `sm.puri.OSK0` / method `SetVisible` | `src/deck-input-mapper.py:263-266`, invoked at `:957` | `subprocess.Popen(..., stdout=DEVNULL, stderr=DEVNULL)` and only `OSError` is caught. A renamed bus name or method exits non-zero into a discarded pipe |
| 4 | Hyprland's Lua greeter API — `hl.config({...})` and `hl.monitor({output,mode,position,scale,transform})` | `src/deck-session.sh:1542-1557` | `luac -p` at `:1565-1571` checks **syntax only**. A changed `hl.*` signature is valid Lua, Hyprland discards the config silently (the documented failure at `:1560-1564`), and autologin means the greeter is normally never seen (`:1610-1612`) |
| 5 | `start-hyprland -- --config <file>` as SDDM's `CompositorCommand` | `src/deck-session.sh:1594` | The verification at `:1604-1606` only proves **our** string sorts last. It never checks `start-hyprland` exists or still accepts `-- --config` |
| 6 | `wayland-session@hyprland.desktop.target` (uwsm's runtime target) as the mapper unit's `WantedBy` | `src/deck-session.sh:239`, checked at `:1847-1851` | The check is a **`warn`, not a `fail`**, and its own message says warning is normal over SSH — which is how the stage is always run. A renamed target enables cleanly and never starts |
| 7 | Steam still calling `/usr/bin/steamos-session-select` (via PATH) and `/usr/bin/steamos-polkit-helpers/{steamos-update,steamos-set-timezone,steamos-priv-write}` (absolute), with the argv shapes read from Steam's logs | `src/deck-session.sh:147,251-254,956,1133,1312-1314` | Our side of the contract is pinned hard by `test/unit/test-deck-session.sh` (exit codes, argument validation). **Steam's side is not observable at all** — if a Steam client changes a path or an argv, everything still passes |
| 8 | `test/images/vm-neptune-image.sh` pulls limine + `limine-mkinitcpio-hook` from **`pkgs.omarchy.org/stable`**, unpinned | `test/images/vm-neptune-image.sh:88`, pacstrap at `:186-189` | The header claims "same version stream as Quattro's" (`:34`). Nothing enforces it: no version pin, no assertion. Per `docs/findings/T9-beta2-delta.md:89-92`, `stable` is ~606 commits behind `quattro`. **Every VM suite can pass against a limine stack the product will never run** |
| 9 | The ESP fstab option string copied verbatim from a real Quattro `/etc/fstab` | `test/images/vm-neptune-image.sh:214` | Only `fmask=0077` is asserted (`:216`). `codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro` are unasserted and drift invisibly |
| 10 | `default_entry: 2` as "the way real installs ship it" | `test/images/vm-neptune-image.sh:383-390` | The assertion at `:389` checks **our own plant**, not upstream's shape. If installs stop shipping a positional index, `stage-default-entry` keeps being tested against a state no real machine has |
| 11 | `BOOT_ORDER="*, *fallback, Snapshots"` in `/etc/default/limine`, "same order the operator's real Deck ships" | `test/images/vm-neptune-image.sh:279` | Written, never asserted, and never re-measured against a real Deck |
| 12 | `/etc/sudoers.d/omarchy-tzupdate`'s content, quoted verbatim in a comment | `src/deck-session.sh:1157-1159` | Comment text. **Already stale** — `docs/findings/T9-beta2-delta.md:146-149` records upstream dropping the `tzupdate` half on 2026-08-11 |
| 13 | `~/.config/omarchy/extensions/omarchy-menu.jsonc` schema for the Desktop Mode menu row | `src/deck-session.sh:2043-2047` | Documented in a comment; nothing installs it, nothing checks it. `T9-beta2-delta.md:199-200` records both `omarchy-menu.jsonc` and `bin/omarchy-menu` changed |
| 14 | `~/.config/hypr/monitors.lua` as the desktop rotation surface | `src/deck-session.sh:2050,2219` | Referenced only in comments and `--help` text. No stage writes it, no test reads it |
| 15 | `mangoapp` presence | `src/deck-session.sh:470-471` | `warn`, not `fail`, by design — but that means its disappearance is invisible in any log nobody reads |
| 16 | `luac` presence gating the only Lua check that exists | `src/deck-session.sh:1565,1573` | If `lua` is not installed the stage **warns and installs the config anyway**, so the silent-Lua-failure guard silently disappears |
| 17 | Steam's `/dev/uinput` ACL coming from `steam-jupiter-stable`'s `60-steam-input.rules` (uaccess), not the `input` group | `src/deck-session.sh:1735-1741` | The probe at `:1740` is a `warn`. If Valve drops the uaccess tag, the mapper loses its virtual keyboard and the stage still reports ok |
| 18 | `omarchy-cidata-load` doing a plain `mount -o ro` (which is why a FAT image works where ISO9660 is expected) | `test/lib/vm-cidata.sh:135-137` | Assumption about upstream's loader. Nothing verifies it; `vm-install-test.sh` has never been run end to end against a real ISO (`test/vm/vm-install-test.sh:51-56`) |
| 19 | Two independent copies of Limine's five config-path candidates | `src/omarchy-deck-kernel.sh:260-266` and `test/lib/vm-assertions.sh:24-30` | Nothing keeps them in sync. Upstream adding a sixth location breaks the script and the assertion library separately |
| 20 | `udisksctl` human-readable output (`"... as /dev/loopN"`, `"... at <path>"`) | `test/lib/vm-disk-image.sh:109,120` | Parsed with regex. A wording change makes root-partition extraction fail in a way that reads as "the install produced no root filesystem" |

---

## 1. Boot chain — `src/omarchy-deck-kernel.sh`

| What we depend on | Our file:line | Kind | How we'd notice |
|---|---|---|---|
| `limine-entry-tool` exists on PATH | `src/omarchy-deck-kernel.sh:338` | binary | `stage-preconditions` fails loudly with the fix in the message |
| `limine-mkinitcpio` exists on PATH | `src/omarchy-deck-kernel.sh:340` | binary | `stage-preconditions` fails loudly |
| `limine-entry-tool --add-uki <pkgbase> <uki> --comment <text>` argv | `src/omarchy-deck-kernel.sh:944-946` | format | `fail()` at `:946`; also exercised in QEMU by `test/vm/vm-kernel-hook-test.sh:282` |
| `limine-entry-tool --remove-uki <pkgbase>` argv | `src/omarchy-deck-kernel.sh:1010` | format | `fail()` at `:1011`, then a post-check that the config no longer references it at `:1016` |
| `limine-entry-tool --no-hooks --no-mutex --tree 5` (diagnostics only) | `test/vm/vm-kernel-stage-test.sh:261`, `test/vm/vm-kernel-idempotency-test.sh:205` | format | ❌ nothing would notice — output is dumped into a log, never asserted on |
| `limine-mkinitcpio` builds `$ESP/EFI/Linux/<prefix>_<pkgbase>.efi` | `src/omarchy-deck-kernel.sh:934-938` | behaviour | `fail()` at `:938` if no matching file appears — the explicit §8.1 guard |
| UKI filename prefix = `CUSTOM_UKI_NAME` from `/etc/default/limine`, else machine-id | `src/omarchy-deck-kernel.sh:668-676,685` | behaviour | Discovered by glob, never constructed. `find_uki_for` returns 1 and callers fail loudly |
| `/etc/default/limine` `ESP_PATH=` is authoritative | `src/omarchy-deck-kernel.sh:457-461` | path/format | Parsed with `sed`; falls through to `/boot /efi /boot/efi` at `:463`, then fails at `:472` if none is a vfat ESP |
| Limine config lives at one of five ESP-relative paths | `src/omarchy-deck-kernel.sh:260-266`, probed `:482-489` | path | Fails loudly at `:488`. ⚠️ duplicated in `test/lib/vm-assertions.sh:24-30` with no sync mechanism |
| Limine config grammar: `path:` lines, `#<blake2b>` suffix, `/EFI/Linux/` anchor | `src/omarchy-deck-kernel.sh:715-720` | format | `reconcile_uki`'s post-condition at `:951-955` requires exactly 1 reference; `test/vm/vm-kernel-hook-test.sh:208-211` re-implements the same regex and asserts counts |
| `limine-snapper-sync` writes `<machine-id>/limine_history/<same-basename>` paths | `src/omarchy-deck-kernel.sh:702-714` | format | The substrate builder asserts the shape exists (`test/images/vm-neptune-image.sh:379-381`); the count anchor is then exercised by the hook/idempotency suites |
| Nested menu tree (`/+Omarchy` → `//linux`) parsed for `default_entry` path form | `src/omarchy-deck-kernel.sh:757-787` | format | `apply_default_entry` fails at `:842` if no entry resolves; `test/vm/vm-default-entry-test.sh:504` asserts `neptune_menu_path_rc == 0` and boots to check `LoaderEntrySelected` |
| `default_entry:` accepts an entry path, not just an index | `src/omarchy-deck-kernel.sh:734-743`, written at `:797-833` | behaviour | `test/vm/vm-default-entry-test.sh` boots a non-first entry and reads the EFI variable — the strongest verification in the repo |
| Nothing upstream owns `default_entry:` | `src/omarchy-deck-kernel.sh:724-731` | behaviour | ❌ nothing would notice if upstream *starts* owning it — our write would just be clobbered on the next `limine-update` |
| `/usr/lib/modules/*/pkgbase` is the kernel enumeration source | `src/omarchy-deck-kernel.sh:511-519,523-532` | path | `stage-kernel` fails at `:644` if pacman claims success and no pkgbase names the package |
| `/usr/lib/modules/<kver>/vmlinuz` exists | `src/omarchy-deck-kernel.sh:646-647` | path | `fail()` naming PLAN.md §11 |
| Valve repo names `jupiter-staging`, `holo-staging` | `src/omarchy-deck-kernel.sh:253` | package | `stage-repos` verifies a usable db per repo at `:401-404`; `require_valve_repos` re-checks per stage at `:419-427` |
| Valve mirror URL `steamdeck-packages.steamos.cloud/archlinux-mirror/$repo/os/$arch` | `src/omarchy-deck-kernel.sh:255` | path | `pacman -Sy` failure at `:396`; VM suites pre-check DNS (`test/vm/vm-kernel-hook-test.sh:187`) |
| Packages `linux-neptune-611`, `-headers`, `linux-firmware-neptune`, `steamdeck-dsp` | `src/omarchy-deck-kernel.sh:634-638` | package | Availability checked against the repo listing at `:610-615`; presence re-verified in the local db at `:650-653` |
| Pinned series 611 must exist upstream | `src/omarchy-deck-kernel.sh:238,244` | package | Loud failure listing what *is* available at `:615` — never a silent fallback |
| `pacman -Sl <repo>` two-column output format | `src/omarchy-deck-kernel.sh:504` | format | An empty result is caught at `:606`; a *column reorder* would silently yield no series → also caught at `:606`, though with a misleading message |
| Arch's split `linux-firmware-*` subpackages vs Valve's `conflicts`/`replaces` on `linux-firmware` only | `src/omarchy-deck-kernel.sh:536-554` | behaviour | Re-derived at runtime from `pacman -Qq` (`:551`), and `--ask=4` at `:634` pre-answers the conflict. `test/vm/vm-kernel-idempotency-test.sh` is where it was found |
| `--ask=4` == `ALPM_QUESTION_CONFLICT_PKG` | `src/omarchy-deck-kernel.sh:619-633` | behaviour | ❌ nothing would notice a renumbering — pacman would just re-prompt and `--noconfirm` would abort with "unresolvable package conflicts", which reads as a mirror problem |
| Upstream hooks `90-mkinitcpio-install.hook`, `60-/90-limine-mkinitcpio-remove-*.hook`, `/usr/share/libalpm/scripts/limine-mkinitcpio-install`, `/var/lib/limine/removed_kernels.list` | `src/omarchy-deck-kernel.sh:1086-1132` (verbatim in the installed hook) | path/behaviour | ❌ nothing would notice — this is documentation baked into the artifact. Our hook is defensive by design, so it keeps working; the *comment* silently becomes wrong |
| pacman de-duplicates hooks by filename, `/etc` beating `/usr/share/libalpm/hooks` | `src/omarchy-deck-kernel.sh:269-275` | behaviour | ❌ nothing would notice — relied on for the future packaged handover (T5) |
| ALPM hook file format (`[Trigger]`/`[Action]`, `Exec=`) | `src/omarchy-deck-kernel.sh:1161-1172` | format | `stage-hook` parses `Exec=` back out of the installed file and checks the target is executable (`:1237-1244`) — a broken hook would break every future transaction |
| archinstall hardens the ESP to `fmask=0077,dmask=0077` | `src/omarchy-deck-kernel.sh:1250-1272` | behaviour | `stage-esp-permissions` tests the **symptom** (can a non-root user read the config, `:1277-1291`) rather than fstab text |
| `mount -o remount` does not re-apply fmask/dmask on vfat | `src/omarchy-deck-kernel.sh:1264-1266,1424` | behaviour | Post-check at `:1428-1433` re-reads the live options *and* re-tests readability |
| `limine-snapper-sync.service` / `limine-snapper-watcher.service` unit names | `src/omarchy-deck-kernel.sh:1325` | path | If renamed, the umount stays busy and `fail()` at `:1350` fires — loud, but blames the wrong thing |
| `/sys/class/dmi/id/{product_name,sys_vendor}` values `Jupiter`/`Galileo`/`Valve` | `src/omarchy-deck-kernel.sh:330-334` | path/format | Hard gate; refuses to touch the boot chain |
| Omarchy's own `limine-snapper.sh` probes the same five config paths (the reason ours does) | `src/omarchy-deck-kernel.sh:257-259` | behaviour | ❌ nothing would notice if upstream's list changes — ours is a static copy |

---

## 2. Session layer — `src/deck-session.sh`

> Structural note: **no VM suite runs this file.** `test/unit/test-deck-session.sh:92`
> sources it and tests `render_*` output plus `assert_ours_or_absent` /
> `sudoers_line_is_*`. Everything marked "stage self-verifies" below therefore only
> verifies **when the stage is run on the Deck**.

| What we depend on | Our file:line | Kind | How we'd notice |
|---|---|---|---|
| `sddm.service` exists and is the display manager | `src/deck-session.sh:421-422` | binary/behaviour | `stage-preconditions` fails loudly |
| SDDM reads `/etc/sddm.conf.d/*.conf` in lexical order, later wins | `src/deck-session.sh:351-361,296` | behaviour | Partially: `stage-greeter-rotation` verifies the *winning* `CompositorCommand` at `:1604-1606`. The `zz-` autologin drop-in's precedence is **not** verified anywhere |
| SDDM applies `[Autologin]` only when both `User=` and `Session=` are present | `src/deck-session.sh:594-597`, written `:599-622` | behaviour | The generated shim greps all three keys back at `:628-633`; `test/unit/test-deck-session.sh` pins the shim's shape |
| SDDM ships `Relogin=false` in `/usr/lib/sddm/sddm.conf.d/default.conf` | `src/deck-session.sh:605-621` | path/behaviour | We override it unconditionally, so a changed default is harmless — but ❌ nothing would notice if the key were renamed |
| sddm unit ships `TimeoutStopSec=5`, `StartLimitIntervalSec=30`, `StartLimitBurst=2`, `RestartSec=100ms`, `KillMode=control-group` | `src/deck-session.sh:1625,308-312,644-646` | behaviour | `stage-sddm-resilience` reads back what **systemd resolved** (`:1688-1700`) and fails on the two that matter |
| `systemctl show sddm -p StartLimitIntervalUSec/RestartUSec/TimeoutStopUSec --value` output format (`0`/`infinity`/`3s`/`30s`) | `src/deck-session.sh:1688-1700` | format | A unit-format change makes the stage fail loudly (`:1692`, `:1697`) — correct direction |
| `gamescope-wayland.desktop` in a wayland-sessions dir (Valve's build, not Arch's) | `src/deck-session.sh:137,428-439` | path | Fails loudly with the `pacman -S jupiter-staging/gamescope` fix; checking the **file** (not the package version) is deliberate — see `:431-437` |
| `start-gamescope-session` on PATH | `src/deck-session.sh:444-445` | binary | Fails loudly |
| Desktop session entry named `omarchy` / `hyprland-uwsm` / `hyprland` | `src/deck-session.sh:450-456` | path | Fails loudly if none exists |
| `/usr/local/share/wayland-sessions` searched before `/usr/share` (Omarchy ships its entry there) | `src/deck-session.sh:450,580` | path | Discovery, so a move between the two is absorbed |
| Steam's `Power → Switch to Desktop` passes **`plasma`**, not `desktop` | `src/deck-session.sh:37-41`, dispatch `:568` | behaviour | ❌ nothing would notice a change — the shim accepts `desktop\|plasma\|omarchy`, and a fourth word would just `die` inside Steam with stderr discarded |
| Steam's runtime PATH is exactly `/usr/bin:/bin` | `src/deck-session.sh:142-152` | behaviour | `stage-steam-hook` resolves the name under `env -i PATH=…` at `:917-920` — proves reachability, not that Steam's PATH is still that |
| Steam invokes polkit helpers by absolute path `/usr/bin/steamos-polkit-helpers/` | `src/deck-session.sh:242-254` | path | ❌ nothing would notice — see §0 row 7 |
| `steamos-update check` → 7, `apply` → non-zero, `--supports-duplicate-detection` → non-zero | `src/deck-session.sh:1065-1122`, stage checks `:993-1008` | format/behaviour | Stage runs the installed stub and asserts all three; `test/unit/test-deck-session.sh:164,188` pins the same protocol rootless |
| `steamos-set-timezone <Area/City>` — one positional | `src/deck-session.sh:1133`, helper `:1242` | format | Stage runs it against the machine's current zone (`:1192-1199`) and asserts a traversal is refused (`:1205-1207`); unit suite asserts **which guard** fired (`:352,386`) |
| `steamos-priv-write "<path>" "<value>"` — two positionals, and Steam sends an empty value for `/dev/drm_dp_aux0` | `src/deck-session.sh:1312-1314`, whitelist `:1444-1455` | format | Stage exercises the real backlight write and both refusals (`:1360-1386`) |
| `/sys/class/backlight/amdgpu_bl0/brightness` and `/sys/class/leds/*/led_brightness_multiplier` node names | `src/deck-session.sh:1360,1444-1446` | path | Stage warns (not fails) if the backlight node is absent (`:1371`); a **renamed LED node** is ❌ unnoticed — the helper would just refuse it into a discarded stderr |
| `timedatectl` at `/usr/bin/timedatectl`, subcommand `set-timezone` | `src/deck-session.sh:266,1139,1279,1289` | binary/format | `command -v` gate at `:1139`; behaviour proven at `:1192-1199` |
| `timedatectl show -p Timezone --value` output | `src/deck-session.sh:1192,1196` | format | Failure to read is a `fail` |
| `org.freedesktop.timedate1.set-timezone` defaults to `auth_admin_keep` | `src/deck-session.sh:1174-1177,1228-1232` | behaviour | ❌ nothing would notice — it is the *rationale* for using sudoers. If polkit relaxed it, our grant is merely redundant |
| `/etc/sudoers.d/omarchy-tzupdate` content (`%wheel … tzupdate, timedatectl set-timezone *`) | `src/deck-session.sh:1157-1159` | path/format | ❌ nothing would notice — comment only, **already stale** (`docs/findings/T9-beta2-delta.md:146-149`) |
| `visudo -c -f` validates a candidate file | `src/deck-session.sh:703,1183,1352` | binary | Refuses to install an invalid drop-in |
| `sudo -n -l <cmd>` semantics for proving a grant | `src/deck-session.sh:509-520` | behaviour | Deliberately honest: warns at `:517` that a blanket grant makes the probe meaningless |
| `/usr/share/sddm/hyprland.lua` exists and its sha256 is `353fe59d…` | `src/deck-session.sh:290,334,1513,1520-1523` | path/format | Missing file = hard fail (`:1513`). **Changed content = `warn` only** (`:1522`) — the drift detector is real but non-blocking |
| Hyprland Lua greeter API `hl.config` / `hl.monitor` | `src/deck-session.sh:1542-1557` | format | ❌ nothing would notice — see §0 row 4 |
| Hyprland silently discards a Lua config it cannot parse | `src/deck-session.sh:1560-1564` | behaviour | `luac -p` guard at `:1565-1571`, itself conditional on `luac` being installed (`:1573`) |
| Omarchy's `10-wayland.conf` sets `CompositorCommand` and sorts before `zy-` | `src/deck-session.sh:296,1587` | path/behaviour | `:1604-1606` verifies ours wins — the one ordering claim in this file that is actually tested |
| `start-hyprland -- --config <file>` argv | `src/deck-session.sh:1594` | format | ❌ nothing would notice — see §0 row 5 |
| Panel output name `eDP-1`, transform `3`, scale `1.25` | `src/deck-session.sh:282-284` | format | ❌ nothing would notice — written into the greeter Lua; only a human looking at the greeter sees a wrong transform |
| comm names `Hyprland`, `start-hyprland`, `gamescope-wl`, `start-gamescope`, `uwsm` (15-char `TASK_COMM_LEN` truncation) | `src/deck-session.sh:794-809,840` | format | `test/unit/test-deck-session.sh:659-682` asserts the pgrep line exists and is `-u`/`-x` scoped. ❌ **whether the names are still correct** is unverifiable off-hardware; the file itself says to re-measure (`:809`) |
| `loginctl show-seat seat0 -p Sessions --value` returning empty when no sessions | `src/deck-session.sh:837` | format | `test/unit/test-deck-session.sh:652` asserts the seat check and the process check both exist and reject independently (`:695`) |
| `systemctl --machine=<user>@.host --user list-units --state=deactivating --no-legend` | `src/deck-session.sh:827-828` | format | Query failure is explicitly surfaced at `:859-861` (`USER_MANAGER_QUERY_OK`), and `test/unit/test-deck-session.sh:713` asserts the function is actually *called* |
| `steam-launcher.service` is `PartOf=graphical-session.target` with `TimeoutStopSec=60` | `src/deck-session.sh:319-327,812-818` | behaviour | Asked generically (any deactivating unit) rather than by name — deliberate insulation. ❌ a change to *60s* would silently make `VT_SETTLE_MAX=600` too short |
| `wayland-session@hyprland.desktop.target` is uwsm's real target (and `hyprland-session.target` does not exist) | `src/deck-session.sh:236-239,1842-1851` | path | ❌ nothing would notice — see §0 row 6 |
| `systemctl --global enable` for a `/etc/systemd/user` unit | `src/deck-session.sh:232,1853-1854` | behaviour | Fails loudly if the enable call fails |
| `/dev/uinput` ACL from `steam-jupiter-stable`'s `60-steam-input.rules` (uaccess, **not** the `input` group) | `src/deck-session.sh:1735-1741` | path/behaviour | ❌ `warn` only — see §0 row 17 |
| `python-evdev` importable (Arch `[extra]`, not AUR) | `src/deck-session.sh:1728-1732` | package | Checked by **import**, not `pacman -Q`; hard fail |
| `dconf` binary; site-database mechanism (`/etc/dconf/profile/user`, `/etc/dconf/db/local.d/`, `dconf update`) | `src/deck-session.sh:167-169,1887,1897-1927` | binary/path | Hard fails throughout; refuses to reorder an existing profile at `:1903` |
| `dconf read -d` ignores the user database (`gsettings get` does not) | `src/deck-session.sh:1929-1944` | behaviour | The whole reason the check is written that way; verified for both keys at `:1939,:1942` |
| GSettings keys `org.gnome.desktop.a11y.applications screen-keyboard-enabled` and `org.gnome.desktop.input-sources sources` | `src/deck-session.sh:174,178,1871-1878` | format | Stage asserts the **site default** value (`:1939-1943`); `test/unit/test-deck-session.sh:899-903` asserts the keyfile groups. ❌ whether squeekboard still *reads* them is unverified |
| `/usr/share/omarchy/config/omarchy/shell.json` exists to seed from | `src/deck-session.sh:195,1977-1981` | path | Hard fail at `:1978` if absent — good, this is a canonical Omarchy path |
| `~/.config/omarchy/shell.json` replaces (does not merge with) shipped defaults | `src/deck-session.sh:1972-1975` | behaviour | Post-check counts top-level keys at `:2014-2015` so a rewrite that strips the bar fails |
| `shell.json` schema: `idle.screensaver`, `idle.lock` in seconds | `src/deck-session.sh:194-197,1996-1997` | format | Re-read and compared at `:2004-2013`. ❌ a **renamed key** would be written, read back, and pass — the check reads back what it wrote |
| `lock: 0` fires immediately (`IdleModel.secondsFromConfig` accepts 0); QML `Timer.interval` is a 32-bit int (~24.8 d ceiling) | `src/deck-session.sh:188-197` | behaviour | ❌ nothing would notice — Quickshell internals, and `T9-beta2-delta.md:186-197` records `shell/plugins/lock/Service.qml` changed |
| Omarchy re-reads `shell.json` live (`FileView watchChanges`) | `src/deck-session.sh:2019` | behaviour | ❌ nothing would notice |
| `~/.config/omarchy/extensions/omarchy-menu.jsonc` extension schema | `src/deck-session.sh:2043-2047` | format | ❌ nothing would notice — see §0 row 13 |
| `~/.config/hypr/monitors.lua` as the desktop rotation surface | `src/deck-session.sh:2050,2219` | path | ❌ nothing would notice — see §0 row 14 |
| `/usr/share/applications` is read by every shell (the return-to-Gaming entry) | `src/deck-session.sh:154,2026-2029,2051-2066` | path/format | ❌ nothing would notice — the file is installed and never validated (no `desktop-file-validate`), and `Icon=input-gaming` resolving is asserted only in a comment (`:2031-2039`) |
| `omarchy-settings-dev` owns the greeter config and the tzupdate sudoers file | `src/deck-session.sh:263,286,1156,1536` | package | ❌ nothing would notice a package rename — used only in prose and in `assert_ours_or_absent` messages |
| DeckShift's `/usr/local/bin/switch-to-gaming` conflict | `src/deck-session.sh:463-465` | path | `warn` by design (keeps the stage a pure probe) |
| `mangoapp` on PATH | `src/deck-session.sh:470-471` | binary | ❌ `warn` only |
| `steamos-customizations-jupiter` ships **no** polkit helpers; `steamos-session-select` is in no configured repo | `src/deck-session.sh:43-48,965-968` | package | ❌ nothing would notice if a repo started shipping them — `assert_ours_or_absent` (`:485-491`) would then **fail loudly** on the next run, which is the intended behaviour but only on the Deck |

---

## 3. Input / OSK layer — `src/deck-input-mapper.py`, `src/deck_osk_*.py`

| What we depend on | Our file:line | Kind | How we'd notice |
|---|---|---|---|
| `/sys/module/hid_steam/parameters/lizard_mode=N` | comments only: `src/deck-input-mapper.py:70,216`; `src/deck_osk_wayland.py:30` | behaviour | ❌ nothing would notice — see §0 row 2. Not read, not set, not persisted anywhere in the repo |
| `hid-steam` reports d-pad as `BTN_DPAD_*` and trackpads as `ABS_HAT0*`/`ABS_HAT1*`, triggers as `ABS_HAT2X/Y` | `src/deck-input-mapper.py` translation core (unit-tested from `:270` onward); measured map in `docs/START-HERE.md:136-143` | behaviour | `test/unit/test-deck-input-mapper.py` (106 assertions) pins the translation. ❌ a **firmware change to the evdev map** would leave the suite green — it tests our translation of an assumed device model, which is exactly the failure `docs/START-HERE.md:66-70` records |
| Device selected by capability `BTN_SOUTH`, never by name or event number | `src/deck-session.sh:1713-1717`; `src/deck-input-mapper.py:599` | behaviour | Deliberate insulation against node renumbering between ISO and installed system |
| `/dev/uinput` writable, and a uinput device emits only declared keycodes | `src/deck-input-mapper.py:32-34,60-63,245`; `src/deck_osk_layout.py:191` | behaviour | `test/osk-tty-e2e.py` drives it end to end but is **excluded from CI on purpose** (`docs/START-HERE.md:297-305`) — it must be run by hand |
| squeekboard DBus `sm.puri.OSK0` / `SetVisible b <bool>` | `src/deck-input-mapper.py:263-266`, called `:957` | format | ❌ nothing would notice — see §0 row 3 |
| `busctl` on PATH | `src/deck-input-mapper.py:264` | binary | ❌ nothing would notice — `Popen` output discarded, only `OSError` caught (`:958`) |
| OSK modules found at `<script dir>/../lib/deck-osk` (must equal `deck-session.sh`'s `OSK_LIB_DIR`) | `src/deck-input-mapper.py:75-80`; `src/deck-session.sh:208` | path | `test/unit/test-osk-install-layout.sh:28-40` derives both from the sources and asserts they agree — and `:102-110` proves the pass was not a `src/` fallback |
| A missing layout core is loud but **not** fatal | `src/deck-input-mapper.py:69-73,106-110` | behaviour | `test/unit/test-osk-install-layout.sh:108-120` asserts both the loud message and that `--list` still works |
| `gtk4-layer-shell` (`libgtk4-layer-shell.so`) must be `LD_PRELOAD`ed before PyGObject loads GTK | `src/deck_osk_wayland.py:51-83` | package/behaviour | Self-re-exec at `:70-83` with an explicit message at `:76-79`; import failure message at `:253-255`. ❌ an soname bump is unnoticed until runtime |
| `Gtk 4.0` + `Gtk4LayerShell 1.0` typelib versions | `src/deck_osk_wayland.py:248-250` | package/format | Caught at import with a `pacman -S` hint (`:253-255`); ❌ no test loads GTK |
| Layer-shell namespace `deck-osk`, `KeyboardMode.NONE` | `src/deck_osk_wayland.py:268-274` | format | ❌ nothing would notice |
| Wayland `zwp_input_method_manager_v2` + `wl_seat` (v1), and one-input-method-per-seat | `src/deck_osk_focus.py:71-72,242,255-266` | format/behaviour | Hand-rolled protocol; the seat-occupied case is detected and reported at `:263-266` and exits non-zero. `test/unit/test-deck-osk-focus.py` (37 assertions) covers the wire format |
| `WAYLAND_DISPLAY` / `XDG_RUNTIME_DIR` | `src/deck_osk_focus.py:139-144` | path | Explicit `RuntimeError` at `:144` |
| fcitx5 (shipped by Omarchy) occupies the input-method seat | `src/deck_osk_focus.py:186,256-266` | behaviour | Reported, not fought — but ❌ whether Omarchy still ships fcitx5 is unverified anywhere |
| `squeekboard` package installed as the fallback keyboard | `src/deck-input-mapper.py:921-947`; `src/deck-session.sh:220-229` | package | ❌ nothing would notice its removal until STEAM+X does nothing |
| `MAPPER_OSK_BACKEND=layer` is a backend the mapper accepts | `src/deck-session.sh:229` | format | `test/unit/test-osk-install-layout.sh:175-188` cross-checks the constant against the mapper's own accepted choices |

---

## 4. `test/images/vm-neptune-image.sh` — the substrate's hard-coded model of a Quattro system

> This is the file the task singled out, and rightly. It reproduces upstream by
> **construction**, so anything it hard-codes is a claim about upstream that the VM
> suites then treat as ground truth.

**Every bare `:N` in this table's second column means
`test/images/vm-neptune-image.sh:N`.**

| Upstream property it hard-codes | Line | Kind | How we'd notice |
|---|---|---|---|
| Package source `https://pkgs.omarchy.org/stable/$arch` | `:88` (`IMG_OMARCHY_SERVER` default) | package | ❌ nothing would notice — see §0 row 8. **The single highest-value row in this table** |
| `[omarchy] SigLevel = Optional TrustAll` | `:130-135` | format | Build fails if the repo is unreachable; ❌ a signing-policy change is unnoticed |
| pacstrap set `base linux mkinitcpio limine limine-mkinitcpio-hook efibootmgr btrfs-progs snapper limine-snapper-sync …` with **no version pins** | `:186-189` | package | `die` at `:190` on failure. ❌ version drift is invisible — the header's "same version stream as Quattro's" claim (`:34`) is unenforced |
| ESP = 1024 MB, GPT type `C12A7328-F81F-11D2-BA4B-00A0C93EC93B`, at `/boot` | `:84,145-149,183` | format | Verified from the host at `:438-441` (partition table readable) and `:445-451` (ESP holds the Neptune UKI) |
| ESP mounted `fmask=0077,dmask=0077` (archinstall's UKI hardening) | `:183`, fstab `:214` | behaviour | Asserted — but **only `fmask=0077`** (`:216`) |
| Full ESP fstab option string `rw,relatime,fmask=0077,dmask=0077,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro`, "copied from a real Omarchy Quattro /etc/fstab" | `:211-214` | format | ❌ nothing would notice — see §0 row 9 |
| fstab must use UUIDs, not device paths | `:218-220` | format | Asserted with a `die` — a hard-won fix, see `:203-210` |
| `/etc/default/limine`: `TARGET_OS_NAME="Omarchy"`, `ESP_PATH="/boot"`, `ENABLE_UKI=yes`, `CUSTOM_UKI_NAME="omarchy"`, `ENABLE_LIMINE_FALLBACK=yes`, `FIND_BOOTLOADERS=no` | `:259-280` | format | UKI naming is asserted downstream (`:331`, `:356`); the rest are set-and-forget |
| `BOOT_ORDER="*, *fallback, Snapshots"` — "same order the operator's real Deck ships" | `:279` | format | ❌ nothing would notice — see §0 row 11 |
| `KERNEL_CMDLINE[default]` array-append syntax | `:264-269` | format | Build fails at `:319` (`limine-mkinitcpio`) if the syntax stops being honoured |
| Guest pacman.conf must carry an `Architecture` line or `limine-mkinitcpio-install` silently skips every kernel | `:282-295` | behaviour | Asserted twice: `:294` and the `pacman -Qqo` probe at `:314-315`. This is the substrate's best guard |
| `limine-mkinitcpio-install` gates its kernel loop on `pacman -Qqo … \|\| continue` and still exits 0 | `:286-291,311-315` | behaviour | Probed at `:314`. ❌ if the gating changes, the probe becomes vacuous and nothing says so |
| `limine-mkinitcpio-hook` only builds UKIs when `/sys/firmware/efi` exists | `:70-73,125-128` | behaviour | `die` at `:128` if the tmpfs trick fails; ❌ if upstream drops the check, the workaround is silently pointless |
| UKI filenames `omarchy_linux.efi` and `omarchy_<KERNEL_PKG>.efi` | `:331,356` | format | Asserted with `die` at `:332` and `:357` — the build fails loudly if the prefix convention moves |
| Limine config at `/boot/limine.conf` (**one** location, unlike the script's five-candidate probe) | `:330,333,358,379,384-390` | path | Asserted at `:330`; ❌ if upstream moves it, the substrate build fails with a message about the UKI rather than the config path |
| Fallback loader at `/boot/EFI/BOOT/BOOTX64.EFI` | `:335-336` | path | Asserted with `die` |
| `limine-install --no-efi-register --fallback` argv | `:317` | format | `die` at `:318` |
| `snapper --no-dbus -c root create-config /` + `create --description` + `list --columns number` | `:364-369` | format | Each has a `die`; snapshot count asserted at `:369` |
| `limine-snapper-sync` writes a Snapshots submenu whose `limine_history/` paths embed the same UKI basenames | `:361-381` | behaviour | Asserted with `die` at `:379-381`, dumping the whole config. **This is the property whose absence hid a real hardware bug** (`:44-53`) |
| `default_entry: 2` — "a positional index, the way real installs ship it" | `:56-58,383-390` | format | ❌ nothing would notice — see §0 row 10 |
| Valve repos appended **after** Arch's, `SigLevel = Never` | `:297-308` | package | Mirrors `omarchy-deck-kernel.sh:372-406` by hand; ❌ nothing keeps the two copies in sync |
| Firmware swap re-implemented inline (same regex as `colliding_arch_firmware`) | `:341-350` vs `src/omarchy-deck-kernel.sh:550-554` | behaviour | ❌ nothing would notice divergence — two copies of one upstream fact |
| `mkinitcpio.conf` HOOKS list, no `autodetect` | `:251-257` | format | Deliberate; build fails at `:319` if invalid |
| Neptune series default 611 | `:85` | package | Must be moved in lockstep with `src/omarchy-deck-kernel.sh:238`. ❌ nothing cross-checks them (VM suites pass `IMG_NEPTUNE_SERIES` explicitly, e.g. `test/vm/vm-kernel-hook-test.sh:99`) |
| Plain btrfs root, **no** `@` subvolume layout | `:173-175` | behaviour | Divergence from `test/lib/vm-cidata.sh:82-85` (`@`,`@home`,`@log`,`@pkg`) is deliberate but undocumented in the assertion layer — `disk_image::root_mount` requires `@` (`test/lib/vm-disk-image.sh:121`) and so cannot read this image |
| `archlinux/archlinux:latest` container image | `:86` | package | ❌ nothing would notice — an untagged upstream image is itself a moving dependency |

---

## 5. Install-time harness — `test/lib/*`, `test/vm/vm-install-test.sh`

| What we depend on | Our file:line | Kind | How we'd notice |
|---|---|---|---|
| `omarchy-iso`'s `cidata` autoinstall mechanism (label `CIDATA`, `user_configuration.json`, `user_credentials.json` at the image root) | `test/lib/vm-cidata.sh:2-13,144-149` | behaviour/path | ❌ nothing would notice — `vm-install-test.sh` has never been run against a real ISO (`test/vm/vm-install-test.sh:51-56`) |
| `omarchy-cidata-load` does a plain `mount -o ro`, so any filesystem with a by-label symlink works | `test/lib/vm-cidata.sh:132-137` | behaviour | ❌ nothing would notice — see §0 row 18 |
| archinstall config schema, `"version": "3.0.9"` | `test/lib/vm-cidata.sh:48-113` | format | ❌ nothing would notice until an install run — and there has never been one |
| Omarchy's own `omarchy_install` key inside that JSON (`mode`, `target_mount`, `boot.esp_mount`, `boot.esp_path=/EFI/limine`, `boot.efi_binary=limine_x64.efi`, `storage.kernel`) | `test/lib/vm-cidata.sh:54-64` | format | ❌ nothing would notice |
| Omarchy strips `omarchy_install` before handing the rest to `archinstall.lib.args.ArchConfigHandler` | `test/lib/vm-cidata.sh:5-12` | behaviour | ❌ nothing would notice |
| Mirror `https://mirror.omarchy.org/$repo/os/$arch` | `test/lib/vm-cidata.sh:108` | path | ❌ nothing would notice |
| Package set `base-devel git omarchy-keyring omarchy-settings omarchy` | `test/lib/vm-cidata.sh:110`; `test/vm/vm-install-test.sh:83` | package | Asserted post-install by `assert::packages_present` (`test/vm/vm-install-test.sh:263`) — **if the install test ever runs** |
| `openssl passwd -6` matches the configurator's own `write_user_files` hashing | `test/lib/vm-cidata.sh:116-129` | behaviour | ❌ nothing would notice |
| btrfs subvolume layout `@`/`@home`/`@log`/`@pkg`, and `@` specifically as the root | `test/lib/vm-cidata.sh:82-85`; `test/lib/vm-disk-image.sh:98-100,121` | format | `disk_image::root_mount` fails loudly at `:124` if `@` is absent — but only against images **this project's own cidata config** built (`:100`) |
| pacman local db layout `var/lib/pacman/local/<name>-<ver>/desc` | `test/lib/vm-assertions.sh:149-165` | format | `test/unit/test-vm-assertions.sh` covers the checking half with fixtures; a real layout change would be caught only by the install test |
| systemd enables units via `*.wants/` / `*.requires/` symlinks | `test/lib/vm-assertions.sh:168-184` | behaviour | Same as above |
| Limine config candidates (second copy) | `test/lib/vm-assertions.sh:24-30` | path | ❌ nothing would notice divergence from `src/omarchy-deck-kernel.sh:260-266` |
| Limine config matched by loose substring, "since the grammar isn't pinned to one Limine version" | `test/lib/vm-assertions.sh:115-133` | format | Deliberately loose — so ❌ a grammar change would not fail this assertion either |
| `udisksctl loop-setup/mount` output wording | `test/lib/vm-disk-image.sh:105-127` | format | ❌ nothing would notice — see §0 row 20 |
| `omarchy-install-dashboard` honours `OMARCHY_UI_INTERACTIVE=no` and reboots (rather than powering off) on success | `test/vm/vm-install-test.sh:31-50` | behaviour | ❌ nothing would notice — it is the documented reason the harness times out against a stock ISO |
| Guest install log at `/var/log/omarchy-install.log` (tmpfs) | `test/vm/vm-install-test.sh:162` | path | ❌ nothing would notice |
| `configs/airootfs/root/.automated_script.sh`'s cidata branch is the fork point for T5 | `test/vm/vm-install-test.sh:44-50` | path | ❌ nothing would notice — and `T9-beta2-delta.md:120-131` records the ISO builder's installer screens moved and its finalizer was renamed |
| `archinstall` and `gum` TUIs drivable by a virtual gamepad | `test/vm/vm-gamepad-spike-test.sh:228,371,450` | behaviour | The spike suite asserts it end to end (`:611`) — but pulls both packages unpinned at `:228`, recording versions only as telemetry (`:230-232`) |
| OVMF firmware path candidates across distros | `test/vm/vm-install-test.sh:106-117` | path | Probed, with overrides and a loud failure |

---

## 6. Dev tooling — `tools/`, `.github/`

| What we depend on | Our file:line | Kind | How we'd notice |
|---|---|---|---|
| Omarchy's installer creates a `root` snapper config (hard-fails the install without `/etc/snapper/configs/root`) | `tools/deck-snapshot.sh:6-13` | behaviour | Snapshot creation fails with that exact hint at `:34` |
| `snapper -c root create --type single --print-number --description <x>` prints a bare number | `tools/deck-snapshot.sh:33-36` | format | Asserted with a numeric regex at `:36` — one of the few output formats actually validated |
| `snapper -c root rollback <N>` stages a rollback that takes effect on next boot | `tools/deck-rollback.sh:36-37,42-46` | behaviour | ❌ nothing would notice a semantic change — only the exit code is checked, and the "takes effect on next boot" claim is printed, never verified |
| `limine-snapper-sync` keeps boot entries in step with snapshots | `tools/deck-snapshot.sh:10-12` | behaviour | ❌ nothing would notice |
| SSH to `steamdeck` as `deck` with passwordless sudo (i.e. `/etc/sudoers.d/99-deck-testing`, which must never ship) | `tools/deck-sync.sh:47-54,84`; audit at `src/deck-session.sh:2119-2156` | behaviour | `stage-audit-privileges` **fails** on any passwordless blanket grant (`:2156`); `test/unit/test-deck-session.sh:843,854` pins the predicate's true/false cases |
| `omarchy-deck-kernel.sh list-stages` / positional-stage CLI as the sync loop's contract | `tools/deck-sync.sh:19-24,84` | format | `INSTALL_STAGES` is the single source of truth (`src/omarchy-deck-kernel.sh:1442-1473`); unknown stages are a usage error at `:1509` |
| shellcheck + `bash -n` + `py_compile` over every tracked `*.sh`/`*.py` | `.github/workflows/ci.yml:45-68` | behaviour | This is the only always-on gate; catches syntax, nothing semantic |
| CI runs `test/unit/test-*.py` and `test/unit/test-*.sh` — **two** globs | `.github/workflows/ci.yml:70-93` | behaviour | Both are present here; note `docs/START-HERE.md:278-295` records the documentation of these globs having been wrong |
| GitHub-hosted runners have no `/dev/kvm` (as in upstream `omarchy-iso`'s own CI) | `.github/workflows/ci.yml:16-26,105-111` | behaviour | Detected and degraded to TCG at `test/vm/vm-install-test.sh:127-132` |
| The ISO-build job has **no build entry point** and exits 1 | `.github/workflows/ci.yml:118-123` | behaviour | Deliberate placeholder, tag-gated. Means the entire install-test tier is dark in CI |
| `python3-evdev` from apt in CI | `.github/workflows/ci.yml:43` | package | ❌ nothing would notice a version skew against Arch's `python-evdev` |

---

## 7. Counts

Counted mechanically over the tables in §1–§6 (§0 re-states rows from those tables
and is not counted again).

| Kind | Rows |
|---|---|
| behaviour | 51 |
| format | 46 |
| path | 32 |
| package | 16 |
| binary | 9 |
| **Total** | **154** |

*(Rows with a compound kind — e.g. `path/behaviour`, of which there are 17 — are
counted under their first listed kind.)*

**`❌ nothing would notice`: 66 rows of 154 (43%)**, of which the 20 highest-impact
are ranked in §0.

---

## 8. Two structural observations, not rows

1. **Duplicated upstream facts with no sync mechanism.** Limine's five config paths
   (`src/omarchy-deck-kernel.sh:260-266` ↔ `test/lib/vm-assertions.sh:24-30`); the
   Valve repo/mirror block (`src/omarchy-deck-kernel.sh:253-255` ↔
   `test/images/vm-neptune-image.sh:299-308`); the firmware-collision regex
   (`src/omarchy-deck-kernel.sh:550-554` ↔ `test/images/vm-neptune-image.sh:346`);
   the Neptune series pin (`src/omarchy-deck-kernel.sh:238` ↔
   `test/images/vm-neptune-image.sh:85`). Each is a place where the *test* can keep
   passing after the *product* has been fixed, or vice versa.

2. **The coverage is inverted relative to the risk.** The boot chain — the part
   `docs/findings/T9-beta2-delta.md:223-232` says upstream did *not* touch — has
   five QEMU suites and the repo's only real boot-and-read-an-EFI-variable proof.
   The session/desktop layer — which is where every one of the delta's 🔴/🟠 rows
   lands (`T9-beta2-delta.md:141-221`) — has one rootless unit suite that never
   executes an install stage.

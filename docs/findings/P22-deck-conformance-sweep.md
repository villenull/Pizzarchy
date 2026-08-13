# P22 — read-only conformance sweep of the physical Deck

**Date:** 2026-08-12 · **Host:** `ssh steamdeck` · **Mode:** READ-ONLY
**Hardware:** Valve `Galileo` (Steam Deck OLED), BIOS `F7G0114`
**Kernel:** `6.11.11-valve29-1-neptune-611-g2dcfaf4df7ac`
**Omarchy:** `omarchy-dev 4.0.0.r1617.g6d7826d-1` (version file: `4.0.0.alpha`)
**systemd:** 261.2-1 · **limine:** 12.5.2-1 · **sddm:** 0.21.0-7

## 0. How to read this file

Every row is **MEASURED** (the command and its real output are quoted) or
**INFERRED** (derived from measured data, and said so). Nothing here is
recalled from another document. Where the Deck disagrees with something the
tree records, the disagreement is called out in §9 and **the Deck wins**.

**Nothing was written, started, stopped, enabled, masked or installed.** See
§10 for how that is known.

**On absence claims:** per the brief, every "X is not present" below is paired
with a control showing the same method finding something that *is* present.
Those controls are inline, marked `POSITIVE CONTROL`.

---

## 1. 🔴 The power-button nodes and their udev tags

### 1.1 The tag census — MEASURED

`man logind.conf` on this machine, quoted verbatim, is the reason this matters:

> Only input devices with the "power-switch" udev tag will be watched for
> key/lid switch events.

Every `/dev/input/event*` node and its `CURRENT_TAGS`
(`udevadm info -q property` per node, name from `/sys/class/input/*/device/name`):

```
NODE      NAME                                   TAGS
event0    Power Button                           :power-switch:
event1    Lid Switch                             :power-switch:
event2    Power Button                           :power-switch:
event3    Video Bus                              :power-switch:
event4    AT Translated Set 2 keyboard           :power-switch:
event5    Valve Software Steam Controller        :seat:uaccess:
event6    Valve Software Steam Controller        :seat:uaccess:power-switch:
event7    Steam Deck                             :uaccess:seat:
event8    Steam Deck Motion Sensors              :seat:uaccess:
event9    HD-Audio Generic HDMI/DP,pcm=3         :power-switch:
event10   FTS3528:00 2808:1015                   
event11   PC Speaker                             
event12   HD-Audio Generic HDMI/DP,pcm=7         :power-switch:
event13   HD-Audio Generic HDMI/DP,pcm=8         :power-switch:
event14   HD-Audio Generic HDMI/DP,pcm=9         :power-switch:
event15   FTS3528:00 2808:1015 UNKNOWN           
event16   sof-nau8821-max Headset Jack           :power-switch:
event17   deck-input-mapper virtual keyboard     :power-switch:
```

`POSITIVE CONTROL` — the same one-liner returns **empty** tags for `event10`,
`event11` and `event15`, and returns `:seat:uaccess:` (a *different*
non-empty value) for `event5`/`event7`/`event8`. So the census was reading real
per-node values, not printing a constant.

**✅ The precondition T13 §2.2 assumed is CONFIRMED.** `event2` (ACPI
`LNXPWRBN`) and `event4` (AT keyboard) both carry `power-switch`, so logind
watches both. `event0` carries it too.

### 1.2 Why every node carries the tag — MEASURED

There is no Deck-specific tagging rule anywhere. `/etc/udev/rules.d/` is
**empty**:

```
$ sudo ls -la /etc/udev/rules.d/
total 0
drwxr-xr-x 1 root root  0 Jul 23 11:43 .
drwxr-xr-x 1 root root 66 Aug 10 11:20 ..
```

`POSITIVE CONTROL` — the same `grep -rn "power-switch"` across
`/usr/lib/udev/rules.d/` **and** `/etc/udev/rules.d/` found two hits, both in
the stock systemd file, so the grep was looking in both directories:

```
/usr/lib/udev/rules.d/70-power-switch.rules:12: SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_SWITCH}=="1", TAG+="power-switch"
/usr/lib/udev/rules.d/70-power-switch.rules:13: SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_KEY}=="1", TAG+="power-switch"
```

So the tag is a blanket consequence of `ID_INPUT_KEY=1` / `ID_INPUT_SWITCH=1`.
Nothing filters it. **INFERRED from the two rules above:** any future input
device that looks like a keyboard gets watched by logind automatically.

### 1.3 The exact attributes a udev rule can key on — MEASURED

`udevadm info /dev/input/event{0,2,4}`, properties that matter:

| | `event0` | `event2` | `event4` |
|---|---|---|---|
| `DEVPATH` | `/devices/LNXSYSTM:00/LNXSYBUS:00/PNP0C0C:00/input/input0/event0` | `/devices/LNXSYSTM:00/LNXPWRBN:00/input/input2/event2` | `/devices/platform/i8042/serio0/input/input4/event4` |
| `ID_PATH` | `acpi-PNP0C0C:00` | `acpi-LNXPWRBN:00` | `platform-i8042-serio-0` |
| `ID_PATH_TAG` | `acpi-PNP0C0C_00` | `acpi-LNXPWRBN_00` | `platform-i8042-serio-0` |
| `ID_INPUT_KEY` | `1` | `1` | `1` |
| `ID_BUS` | `acpi` | `acpi` | `i8042` |
| `LIBINPUT_DEVICE_GROUP` | `19/0/1:PNP0C0C/button` | `19/0/1:LNXPWRBN/button` | `11/1/1:isa0060/serio0` |
| `DEVLINKS` | *(none)* | *(none)* | `/dev/input/by-path/platform-i8042-serio-0-event-kbd` |

`udevadm info --attribute-walk`, the parent chain (this is what `KERNELS=` /
`SUBSYSTEMS=` / `ATTRS{}` can match):

**`event2` — the node to drop:**

```
looking at device '/devices/LNXSYSTM:00/LNXPWRBN:00/input/input2/event2':
    KERNEL=="event2"
    SUBSYSTEM=="input"
  parent '/devices/LNXSYSTM:00/LNXPWRBN:00/input/input2':
    KERNELS=="input2"
    SUBSYSTEMS=="input"
    ATTRS{name}=="Power Button"
    ATTRS{phys}=="LNXPWRBN/button/input0"
    ATTRS{capabilities/key}=="8000 10000000000000 0"
    ATTRS{id/bustype}=="0019"
  parent '/devices/LNXSYSTM:00/LNXPWRBN:00':
    KERNELS=="LNXPWRBN:00"
    SUBSYSTEMS=="acpi"
    DRIVERS=="button"
    ATTRS{hid}=="LNXPWRBN"
    ATTRS{power/wakeup}=="enabled"
```

**`event0` — the silent ACPI twin:**

```
  parent '/devices/LNXSYSTM:00/LNXSYBUS:00/PNP0C0C:00/input/input0':
    ATTRS{name}=="Power Button"
    ATTRS{phys}=="PNP0C0C/button/input0"
    ATTRS{capabilities/key}=="8000 10000000000000 0"
  parent '/devices/LNXSYSTM:00/LNXSYBUS:00/PNP0C0C:00':
    KERNELS=="PNP0C0C:00"
    SUBSYSTEMS=="acpi"
    DRIVERS=="button"
    ATTRS{hid}=="PNP0C0C"
    ATTRS{path}=="\_SB_.PWRB"
    ATTRS{power/wakeup}=="enabled"
```

⚠️ **`ATTRS{name}=="Power Button"` matches BOTH `event0` and `event2`** — their
`name` and `capabilities/key` are byte-identical; only `phys`, `hid` and the
devpath separate them. `event4`'s name is `"AT Translated Set 2 keyboard"`, so
a name match cannot hit it by accident.

### 1.4 Which nodes can *physically* emit `KEY_POWER` — MEASURED + decoded

`ATTRS{capabilities/key}` decoded (bitmask parsed with a script; longs are
printed most-significant-first, `KEY_POWER=116`, `KEY_SLEEP=142`,
`KEY_WAKEUP=143`, `KEY_SUSPEND=205`):

| node | `capabilities/key` | advertises |
|---|---|---|
| `event0`, `event2` | `8000 10000000000000 0` | **KEY_POWER, KEY_WAKEUP** |
| `event4` | `402000000 3803078f800d001 feffffdfffefffff fffffffffffffffe` | **KEY_POWER, KEY_SLEEP, KEY_WAKEUP** |
| `event3` Video Bus | `3e000b00000000 0 0 0` | none of the four |
| `event6` Steam Controller kbd | `e080ffdf01cfffff fffffffffffffffe` | none of the four |
| `event16` Headset Jack | `40 0 0 … 0` | none of the four |
| **`event17` our mapper's uinput kbd** | `30000 0 0 778000000000 23fffffdffffffe` | **none of the four** |

`POSITIVE CONTROL` for the decoder: the same script, same code table, returned
a **non-empty** answer for `event0/2/4` and an **empty** answer for
`event3/6/16/17` in one run — so "none" is a decoded result, not a silent
failure.

🟢 **New, and load-bearing: `deck-input-mapper`'s virtual keyboard (`event17`)
is tagged `power-switch` but advertises no power/sleep key.** So our own input
layer cannot accidentally trigger logind's power handling. That was never
checked before and it is the kind of thing that would have been discovered the
hard way.

🔴 **`event4` is the ONLY node that advertises `KEY_SLEEP`**, and
`HandleSuspendKey=suspend` is live (§2.3). Anything that synthesises
`KEY_SLEEP` on the AT keyboard suspends the machine.

### 1.5 The rule the fix should use — RECOMMENDATION (not applied)

Given §1.1–§1.4, the rule must (a) sort after `70-power-switch.rules`, (b) match
the ACPI node(s) and not `event4`, (c) use `TAG-=`, which `man udev` on this
machine documents as *"Remove the value from a key that holds a list of
entries"*, **Added in version 217** — and this is systemd 261, so it is
supported.

Proposed `/etc/udev/rules.d/71-deck-power-button.rules`:

```udev
# Drop the ACPI power-button notify nodes from logind's watch list, leaving the
# AT-keyboard node (event4) as the single source of KEY_POWER. Measured
# 2026-08-12: one physical press produces KEY_POWER on BOTH event4 (a real key
# that tracks the hold) and event2 (ACPI LNXPWRBN, an instantaneous notify
# ~130-200 ms later), so logind would act twice. See docs/findings/T13 §2.2.
SUBSYSTEM=="input", KERNEL=="event*", SUBSYSTEMS=="acpi", KERNELS=="LNXPWRBN:00", TAG-="power-switch"
SUBSYSTEM=="input", KERNEL=="event*", SUBSYSTEMS=="acpi", KERNELS=="PNP0C0C:00",  TAG-="power-switch"
```

Notes for the implementer:

- The second line (`PNP0C0C:00`) is **defence, not necessity** — `event0` was
  measured silent (T13 §2.2). Dropping it costs nothing and removes a node that
  advertises `KEY_POWER` and could start emitting after a BIOS change.
- `KERNELS==`/`SUBSYSTEMS==` on the ACPI parent is preferred over
  `ENV{ID_PATH}=="acpi-LNXPWRBN:00"` because `ID_PATH` is set by
  `60-persistent-input.rules`/`persistent-storage` ordering and is a derived
  value; the `hid`/`KERNELS` pair comes straight from ACPI.
- `ATTRS{phys}=="LNXPWRBN/button/input0"` is an equally good discriminator if a
  single-key match is wanted.
- ⚠️ **It does not take effect without a re-trigger or reboot.** Tags are
  evaluated at device-add time. `udevadm control --reload && udevadm trigger
  --subsystem-match=input --action=change` is a **write action** and was not
  run — see §11.

---

## 2. logind's live policy — MEASURED, and it changes the shape of the T13 fix

### 2.1 The drop-ins on disk

```
$ ls -la /etc/systemd/logind.conf.d/
-rw-r--r-- 1 root root  30 Aug 10 07:20 10-ignore-power-button.conf
-rw-r--r-- 1 root root 558 Aug 10 07:20 20-inhibit-delay.conf

$ cat /etc/systemd/logind.conf.d/10-ignore-power-button.conf
[Login]
HandlePowerKey=ignore
```

Both are dated `Aug 10 07:20` — **the Omarchy package's own timestamp**, not a
project edit (compare `/etc/sudoers.d/99-deck-*`, all dated Aug 10–11 later in
the day). `10-ignore-power-button.conf` is **upstream Omarchy's**, not ours.

### 2.2 What logind is running with, right now — MEASURED over D-Bus

Not the file, the live object. `busctl get-property org.freedesktop.login1
/org/freedesktop/login1 org.freedesktop.login1.Manager <prop>`:

| property | value |
|---|---|
| `HandlePowerKey` | `s "ignore"` |
| `HandlePowerKeyLongPress` | `s "ignore"` |
| `HandleLidSwitch` | `s "suspend"` |
| `HandleSuspendKey` | `s "suspend"` |
| `IdleAction` | `s "ignore"` |
| `InhibitDelayMaxUSec` | `t 15000000` (15 s) |
| `BlockInhibited` | `s ""` |
| `DelayInhibited` | `s "sleep"` |

`POSITIVE CONTROL` — the same `busctl` invocation returned eight *different*
values including a numeric `t` and an empty string, so it was reading the object
rather than erroring uniformly.

### 2.3 🔴 Three consequences the tree does not record

1. **`HandlePowerKey=ignore` is ALREADY in force.** The double-node problem is
   therefore **latent, not active**: today logind does nothing at all with
   `KEY_POWER`, from either node. It becomes active the instant T13's fix sets
   `HandlePowerKey=suspend`. T13 §2.2's ordering (*"drop the ACPI node … and
   **only then** set `HandlePowerKey=`"*) is exactly right, and this measurement
   is the reason it is right.
2. **The file we must override is Omarchy's, not ours.** Any project drop-in has
   to sort after `10-ignore-power-button.conf` and will be silently reverted in
   meaning if upstream renames theirs. This is an upstream-patch-seam item
   (`docs/findings/T12-upstream-patch-seam.md` territory), not a config edit.
3. 🔴 **`HandleLidSwitch=suspend` is LIVE and is a second, unowned consumer.**
   T13 §5.2 row D describes the lid path as `Lid Switch → omarchy-system-lid-close
   → lock`. That is only *half* the story: **logind independently suspends on lid
   close**, with no override anywhere (the value is the systemd default —
   confirmed against the live man page: *"HandleLidSwitch= defaults to
   'suspend'"*). The Deck has a real `Lid Switch` node, `event1`, tagged
   `power-switch`. Its current state is readable:

   ```
   $ cat /proc/acpi/button/lid/LID/state
   state:      open
   ```

   `POSITIVE CONTROL` — the same path listing printed `LID`, so the glob resolved
   to a real directory rather than matching nothing.

   **This also settles T13 open question 6, in the read-only half:** the lid node
   exists, exposes state, and reads `open`. Whether it can *transition* on a
   handheld still needs a press-free observation window and is not settled here.
   `journalctl -b | grep -i lid` this boot returns 13 lines, **all of them
   either `Invalid PBLK length` ACPI noise or the one-time `input: Lid Switch as
   /devices/…` registration** — no state changes. `POSITIVE CONTROL`: the same
   journal grepped for `systemd` this boot returns **675** lines, so the journal
   query was reading a populated boot.

### 2.4 Inhibitors — T13 open question 2, ANSWERED for Desktop Mode

```
$ systemd-inhibit --list
WHO            UID USER PID  COMM           WHAT  WHY                                       MODE
NetworkManager 0   root 736  NetworkManager sleep NetworkManager needs to turn off networks delay
UPower         0   root 1134 upowerd        sleep Pause device polling                      delay

2 inhibitors listed.
```

**Nothing holds `handle-power-key`.** `BlockInhibited=""` corroborates it from a
second, independent source. `POSITIVE CONTROL` — the command listed two real
inhibitors with a non-empty `DelayInhibited="sleep"`, so "no handle-power-key"
is an observed absence in a working query.

⚠️ **Scope limit, stated loudly: this is Desktop Mode only.** The Deck is
currently in the Omarchy session and **Steam/gamescope are not running** (§5.2).
T13 §3.2's hole is about *Gaming Mode*, where Steam is resident. This sweep
cannot answer it without a session switch, which is a write action. It stays
open. See §11.

---

## 3. The lock producers (`docs/PROGRESS.md` §5.24) — MEASURED

### 3.1 `omarchy-sleep-lock.service`

```
$ systemctl is-enabled omarchy-sleep-lock.service        # SYSTEM manager
not-found                                    (exit 4)
$ systemctl --user is-enabled omarchy-sleep-lock.service
masked                                       (exit 1)

$ systemctl --user status omarchy-sleep-lock.service
○ omarchy-sleep-lock.service
     Loaded: masked (Reason: Unit omarchy-sleep-lock.service is masked.)
     Active: inactive (dead)

$ systemctl --user show omarchy-sleep-lock.service -p LoadState -p UnitFileState -p ActiveState -p SubState -p FragmentPath
LoadState=masked
ActiveState=inactive
SubState=dead
FragmentPath=/home/deck/.config/systemd/user/omarchy-sleep-lock.service
UnitFileState=masked
```

**It is a USER unit, masked at the USER level, and — this is the finding — the
mask lives in the operator's home directory:**

```
$ ls -la /etc/systemd/user/omarchy-sleep-lock.service /etc/systemd/system/omarchy-sleep-lock.service
ls: cannot access '/etc/systemd/user/omarchy-sleep-lock.service': No such file or directory
ls: cannot access '/etc/systemd/system/omarchy-sleep-lock.service': No such file or directory

$ ls -la ~/.config/systemd/user/omarchy-sleep-lock.service
lrwxrwxrwx 1 deck deck 9 Aug 11 17:54 /home/deck/.config/systemd/user/omarchy-sleep-lock.service -> /dev/null
```

`POSITIVE CONTROL` for the `/etc` absence — the *same* `ls` in the *same*
command found the real symlink under `~/.config`, so the tool was working and
the two `/etc` paths genuinely do not exist.

🔴 **This is fragile in three specific ways, none of them recorded:**

1. It is **per-user state in `$HOME`**, dated `Aug 11 17:54` — a hand mask, as
   `docs/START-HERE.md` says. A fresh install, a second user, or a wiped home
   loses it. `src/` still contains no mask (unchanged since T13 §5.2 recorded it).
2. **The unit's preset is `enabled`:**

   ```
   $ systemctl --user list-unit-files 'omarchy*'
   UNIT FILE                                STATE    PRESET
   omarchy-fcitx5.service                   enabled  enabled
   omarchy-migrate-notify.service           enabled  enabled
   omarchy-recover-internal-monitor.service enabled  enabled
   omarchy-sleep-lock.service               masked   enabled
   omarchy-tailscale-receive.service        disabled enabled
   omarchy-update-user-notify.service       alias    -
   ```

   `POSITIVE CONTROL` — five other units in three *different* states
   (`enabled`, `disabled`, `alias`) in the same listing, so `masked` is a real
   per-unit value. `systemctl --user list-unit-files --state=masked` returns
   **exactly one** unit, this one. So the masked set on this machine is a
   set of size one, measured two ways.
3. **The enablement symlink is still in place underneath the mask:**

   ```
   $ ls -la ~/.config/systemd/user/graphical-session.target.wants/
   omarchy-sleep-lock.service -> /usr/lib/systemd/user/omarchy-sleep-lock.service
   ```

   Unmask and it starts on the next graphical session, with no further action.
   The upstream unit file is present and intact at
   `/usr/lib/systemd/user/omarchy-sleep-lock.service` (587 bytes, root-owned,
   `ExecStart=/usr/bin/omarchy-system-sleep-monitor`,
   `WantedBy=graphical-session.target`).

### 3.2 `shell.json`'s idle block — MEASURED

```
$ jq .idle ~/.config/omarchy/shell.json
{
  "screensaver": 150,
  "lock": 86400
}
```

✅ Matches what `src/deck-session.sh` intends and what T13 §5.2 row A records.
File is `/home/deck/.config/omarchy/shell.json`, mtime `Aug 12 13:32`. A
sibling `shell.json.pre-session17` backup exists alongside it.

⚠️ There is **no** `/usr/share/omarchy/default/omarchy/shell.json` to compare
against — `jq` and `cat` both reported `No such file or directory`.
`POSITIVE CONTROL`: the same `jq` invocation on the user's file two lines
earlier returned the parsed `idle` object, so `jq` was working.

### 3.3 The two dconf keys — MEASURED **with `dconf read -d`**, as required

`dconf read -d` reads the **default** (site/system database) value only. A plain
`dconf read` resolves through the whole profile and returns a *user* value when
one exists — so a plain read cannot distinguish "the site default is installed"
from "this user happens to have set it". Both forms are reported here precisely
so the difference is visible.

```
$ cat /etc/dconf/profile/user
user-db:user
system-db:local

$ dconf read -d /org/gnome/desktop/a11y/applications/screen-keyboard-enabled
true
$ dconf read    /org/gnome/desktop/a11y/applications/screen-keyboard-enabled
true

$ dconf read -d /org/gnome/desktop/input-sources/sources
[('xkb', 'us')]
$ dconf read    /org/gnome/desktop/input-sources/sources
[('xkb', 'us')]
```

✅ **Both keys are present as site defaults, and no user-level value is
shadowing either** (the `-d` and plain reads agree for both).

`NEGATIVE CONTROL` — `dconf read -d /org/gnome/desktop/this-key-does-not-exist`
returns **empty**, so a present value is distinguishable from an absent one.
`POSITIVE CONTROL` — `dconf dump /org/gnome/desktop/` lists both keys plus six
unrelated `interface` keys, so the database is readable and populated.

Backing store, both correct:

```
$ cat /etc/dconf/db/local.d/50-deck-desktop
# installed-by: deck-session.sh
[org/gnome/desktop/a11y/applications]
screen-keyboard-enabled=true
[org/gnome/desktop/input-sources]
sources=[('xkb','us')]

$ ls -la /etc/dconf/db/
-rw-r--r-- 1 root root 428 Aug 12 13:32 local          <- compiled, newer than nothing stale
drwxr-xr-x 1 root root  30 Aug 12 13:32 local.d
```

The compiled `local` DB and the keyfile share the same mtime, so `dconf update`
was run after the last edit.

---

## 4. §5.17 — `/etc/sudoers.d` on the live device

⚠️ First, a methodology note that cost a round trip: `/etc/sudoers.d` is
`drwxr-x--- root root`, so **a `for f in /etc/sudoers.d/*` loop run as `deck`
silently produces the literal glob**, and `cat` reports one missing file rather
than ten. The listing below was re-taken under `sudo bash`.

```
$ sudo ls -la /etc/sudoers.d/
-r--r----- 1 root root  19 Aug 10 11:20 03_deck
-r--r----- 1 root root 818 Aug 11 17:39 99-deck-lizard-mode
-r--r----- 1 root root 578 Aug 10 14:15 99-deck-priv-write
-r--r----- 1 root root 349 Aug 10 15:38 99-deck-session-select
-r--r----- 1 root root 482 Aug 10 14:15 99-deck-set-timezone
-r--r----- 1 root root  29 Aug 10 14:22 99-deck-testing
-r--r----- 1 root root  44 Apr 30 03:49 asdcontrol
-r--r----- 1 root root  47 Aug 10 07:20 omarchy-asdcontrol
-r--r----- 1 root root  25 Aug 10 07:20 omarchy-passwd-tries
-r--r----- 1 root root  83 Aug 10 07:20 omarchy-tzupdate
```

Every grant, `sudo grep -rn NOPASSWD /etc/sudoers /etc/sudoers.d/`:

| file | rule | verdict |
|---|---|---|
| `99-deck-testing` | `deck ALL=(ALL) NOPASSWD: ALL` | 🔴 **STILL PRESENT.** §5.17 is open, unchanged |
| `asdcontrol` | `ALL ALL=(ALL) NOPASSWD: /usr/bin/asdcontrol` | 🟠 **`ALL` users, not `%wheel`.** Dated `Apr 30`, i.e. **not ours** — shipped by the `asdcontrol` package. Broadest *principal* on the box after `99-deck-testing` |
| `omarchy-asdcontrol` | `%wheel ALL=(ALL) NOPASSWD: /usr/bin/asdcontrol` | Omarchy's; duplicate of the above, narrower principal |
| `omarchy-tzupdate` | `%wheel ALL=(root) NOPASSWD: /usr/bin/tzupdate, /usr/bin/timedatectl set-timezone *` | Omarchy's |
| `99-deck-set-timezone` | `deck ALL=(root) NOPASSWD: /usr/bin/timedatectl set-timezone *` | ours; scoped |
| `99-deck-priv-write` | `deck ALL=(root) NOPASSWD: /usr/bin/steamos-polkit-helpers/steamos-priv-write` | ours; scoped, documented |
| `99-deck-session-select` | `deck ALL=(root) NOPASSWD: /usr/local/bin/deck-session-select` | ours; scoped |
| `99-deck-lizard-mode` | `deck ALL=(root) NOPASSWD: /usr/local/sbin/deck-lizard-mode on\|off` | ours; scoped to two argv values |
| `03_deck` | `deck ALL=(ALL) ALL` | SteamOS-era; **password required**, not a NOPASSWD grant |
| `omarchy-passwd-tries` | `Defaults passwd_tries=10` | not a grant |
| `/etc/sudoers:128` | `# %wheel ALL=(ALL:ALL) NOPASSWD: ALL` | **commented out** |

`POSITIVE CONTROL` for the "commented out" claim — the same grep pattern run for
`^root` on the same file returned `122:root ALL=(ALL:ALL) ALL`, an *active*
line, so the tool distinguishes live rules from comments.

**Headline:** `99-deck-testing` is the only blanket passwordless-root grant, it
is **ours**, and it is **still there**. The `asdcontrol` package file granting
`ALL` users passwordless access to one binary is a **new** observation not in
§5.17 and worth an audit row of its own — it is not ours to remove, but it is
ours to know about, and `tools/iso-payload-audit.sh` (build side) will never
see it because it arrives with a package.

---

## 5. Default session and boot state — MEASURED

### 5.1 SDDM configuration

`/etc/sddm.conf` does not exist; everything is in `/etc/sddm.conf.d/`, five
files, read in filename order:

| file | key content |
|---|---|
| `10-theme.conf` | `[Theme] Current=omarchy` |
| `10-wayland.conf` | `DisplayServer=wayland`; `CompositorCommand=start-hyprland -- --config /usr/share/sddm/hyprland.lua` |
| `99-omarchy-login.conf` | `Current=omarchy`; `RememberLastUser=true`; `RememberLastSession=true` |
| `zy-deck-greeter.conf` | overrides `CompositorCommand=start-hyprland -- --config /usr/local/share/deck-session/greeter-hyprland.lua` |
| `zz-deck-session.conf` | `[Autologin] User=deck` · **`Session=omarchy`** · `Relogin=true` |

✅ Sort order works as designed: `zy-` beats `10-wayland.conf` for
`CompositorCommand`, `zz-` sorts last for `Session=`.

⚠️ `99-omarchy-login.conf` sets `RememberLastSession=true` while
`zz-deck-session.conf` sets an explicit `Session=`. **INFERRED:** an explicit
`[Autologin] Session=` wins over the remembered session for the autologin path,
so the two do not currently conflict — but this is an untested interaction and
worth one line in the session-switch tests.

`Session=omarchy` resolves to a **project-installed** desktop file, not an
Omarchy one:

```
$ ls /usr/local/share/wayland-sessions/    -> omarchy.desktop  (only file)
$ ls /usr/share/wayland-sessions/          -> gamescope-wayland.desktop
                                              hyprland-uwsm.desktop
                                              hyprland.desktop
$ cat /usr/local/share/wayland-sessions/omarchy.desktop
[Desktop Entry]
Name=Omarchy (Hyprland uwsm)
Exec=uwsm start -g -1 -e -D Hyprland hyprland.desktop
TryExec=uwsm
Type=Application
```

### 5.2 What this boot actually landed in

```
$ journalctl -b -u sddm | tail
Aug 12 17:52:17 sddm[864]: Reading from "/usr/local/share/wayland-sessions/omarchy.desktop"
Aug 12 17:52:17 sddm[864]: Session "/usr/local/share/wayland-sessions/omarchy.desktop" selected,
                            command: "uwsm start -g -1 -e -D Hyprland hyprland.desktop" for VT 1
Aug 12 17:52:17 sddm[864]: Authentication for user "deck" successful
Aug 12 17:52:17 sddm[864]: Session started true
```

✅ **Autologin fired, no greeter password prompt, landed in Desktop Mode.**
Uptime at sweep time: `up 35 min`, boot `Aug 12 17:52`. `journalctl --list-boots`
shows this as boot `0` with four prior boots today.

Running compositor stack (`pgrep -a`), which confirms Desktop and **not** Gaming:

```
 864 /usr/bin/sddm
 872 sddm-helper … --start uwsm start -g -1 -e -D Hyprland hyprland.desktop --user deck --autologin
 964 python3 /usr/local/bin/deck-input-mapper --osk-backend=layer
1031 /usr/bin/start-hyprland
1036 Hyprland --watchdog-fd 4
1117 quickshell -n -p /usr/share/omarchy/shell
1327 /usr/lib/xdg-desktop-portal-hyprland
```

**No `gamescope` and no `steam` process.** `POSITIVE CONTROL` — the same
`pgrep -a -f` pattern (which included `gamescope|steam` as alternatives) matched
seven other processes, so the pattern was live and the absence is real.

`deck-input-mapper.service`: `LoadState=loaded ActiveState=active
SubState=running UnitFileState=enabled
FragmentPath=/etc/systemd/user/deck-input-mapper.service`.

### 5.3 Failed units

```
$ systemctl --failed
0 loaded units listed.
$ systemctl --user --failed
0 loaded units listed.
```

`POSITIVE CONTROL` — `systemctl list-units` in the same command reported
**194 loaded units**, so the manager was answering and "0 failed" is a real
zero, not an empty error.

### 5.4 Sessions

```
$ loginctl list-sessions
      1 1000 deck seat0 872 user    tty1   <- the graphical session
      2 1000 deck -     904 manager
     28 1000 deck -    9576 user           <- this SSH session (Remote=yes)
```

Session 1: `Type=wayland Class=user Active=yes State=active
IdleHint=no **LockedHint=no**`. The Deck is **not locked**, confirmed from
logind rather than from a screenshot.

---

## 6. 🔴 §5.11 — the four rotation surfaces, as they are on disk today

| # | surface | value on disk | source |
|---|---|---|---|
| 1 | Limine menu | **`interface_rotation: 90`** | `/boot/limine.conf:13` |
| 2 | TTY / fbcon | **`fbcon=rotate:1`** | `/proc/cmdline` **and** every `cmdline:` line in `/boot/limine.conf` |
| 3 | SDDM greeter | **`transform = 3`** | `/usr/local/share/deck-session/greeter-hyprland.lua` |
| 4 | Desktop | **`transform = 3`** | `~/.config/hypr/monitors.lua` |

All four also carry `scale = 1.25` on `eDP-1` for surfaces 3 and 4.

`POSITIVE CONTROL` for the cmdline read — `grep -o "mem_sleep_default=[a-z0-9]*"
/proc/cmdline` returned **nothing** (correctly: it is absent) while
`grep -o "fbcon=rotate:[0-9]" /proc/cmdline` on the same file returned
`fbcon=rotate:1`. Same file, same tool, one hit and one miss — so the absence in
§7.3 is a measured absence.

**Both rotation values now carry an in-file record of having been looked at,
and the two disagree with each other in the obvious way — correctly:**

- `/boot/limine.conf:10-12`: *"MEASURED 2026-08-11: 270 renders the menu UPSIDE
  DOWN; 90 is correct."*
- `monitors.lua`: *"transform = 3 (270 deg), NOT 1. Both were applied on this
  hardware and looked at: 1 renders the desktop UPSIDE DOWN."*

Limine's `interface_rotation` and Hyprland's `transform` use **opposite sign
conventions**, so `90` and `3` (=270°) describing the same physical panel is
internally consistent, not a contradiction. Worth stating explicitly, because it
looks like a bug at a glance and someone will "fix" it.

🔴 **The one live contradiction: the shipped `monitors.lua` comment is now
FALSE.** It is rendered by **`src/deck-session.sh:530`** (and reaches the Deck as
`~/.config/hypr/monitors.lua`, where it was read). It says:

> *"No kernel this project ships corrects the panel: **fbcon/rotate is 0 on both
> stock Arch and Neptune**, so the fix has to come from userspace, per surface."*

The live cmdline is `fbcon=rotate:1`, on **both** kernel entries in
`limine.conf` and on every snapshot entry. Surface 2 **is** corrected in the
kernel cmdline, by us. The comment describes the pre-fix world and reads as a
present-tense fact. **The Deck wins; the comment must be corrected.**

The same false claim is repeated in `docs/findings/T9-delta-classification.md:109`
— *"This renders on the Deck's **unrotated** VT (fbcon/rotate is 0 —
`src/deck-session.sh:272-278`)"* — and that cross-reference has **also drifted**:
`src/deck-session.sh:272-278` is now the XKB-layout block, not the rotation
comment. Both need fixing, and the OOBE-centering conclusion built on top of
"unrotated VT" needs re-deriving against a VT that **is** rotated.

⚠️ **Not settled by this sweep:** whether `fbcon=rotate:1` is the *right*
value. That needs eyes on a TTY, which is a hardware row. Given the project has
twice recorded an inverted rotation as fact, and given that surfaces 3 and 4
both needed 270° rather than 90°, **`fbcon=rotate:1` (90° CW) deserves an
explicit look before release.** It is the only one of the four with no
"MEASURED / looked at" annotation next to it.

---

## 7. 🔴 `/sys/power/mem_sleep` — the T13 §4.2 "s2idle" claim is WRONG on this hardware

### 7.1 The measurement

```
$ cat /sys/power/mem_sleep
s2idle [deep]

$ cat /sys/power/state
freeze mem disk

$ cat /sys/power/disk
[platform] shutdown reboot suspend test_resume
```

**`deep` is selected.** The brackets mark the active choice.

### 7.2 🟢 And here is *why* — the explanation, found

```
$ sudo dmesg | grep -B4 -A4 "Steam Deck quirk"
[    0.269733] ACPI: PM: Registering ACPI NVS region [mem 0x7af7f000-0x7cf7efff] (33554432 bytes)
[    0.269733] PM: Steam Deck quirk - no s2idle allowed!
[    0.269733] clocksource: jiffies: mask: 0xffffffff …
```

**Valve's `linux-neptune` kernel carries an explicit quirk that forbids s2idle
on this machine.** This is not a configuration choice we or Omarchy made — it is
compiled into the kernel this project ships, and it fires at 0.27 s of boot,
before any userspace exists.

`POSITIVE CONTROL` — the same `dmesg | grep -i quirk` returns **4** lines
(the PM one plus three USB/xHCI quirk lines), so the grep was reading a
populated ring buffer.

⚠️ **Note the first grep failed and would have produced a false negative.** The
brief's suggested `dmesg | grep -i "ACPI: (supports"` returned **nothing**,
because the real line is `ACPI: PM: (supports S0 S3 S4 S5)` — with `PM:`
inserted. A broader pattern found it:

```
[    0.313295] ACPI: PM: (supports S0 S3 S4 S5)
```

So the FADT advertises **S3**, and `deep` = S3.

### 7.3 What is *not* forcing it

- No `mem_sleep_default=` on the kernel cmdline — measured absent, with the
  positive control in §6.
- `/etc/systemd/sleep.conf.d/` **does not exist**, and the effective
  configuration is empty:

  ```
  $ sudo systemd-analyze cat-config systemd/sleep.conf   # comments stripped
  [Sleep]
  ```

  `POSITIVE CONTROL` — the same `systemd-analyze cat-config
  systemd/logind.conf` in an adjacent command returned three populated
  `[Login]` stanzas, so the tool renders content when content exists.

  **INFERRED:** with `sleep.conf` at defaults, `SuspendState=` is systemd's
  built-in `mem standby freeze`, so `systemctl suspend` writes `mem` →
  `/sys/power/mem_sleep`'s selected `deep` → **S3**.

### 7.4 Why this matters to the whole sleep design

`docs/findings/T13-power-button-and-sleep.md` §4.2 and §8 q5 record suspend as
**s2idle**, INFERRED from Valve's SteamOS source. **On this hardware it is
`deep`/S3, and the kernel refuses s2idle by name.** Consequences:

1. **T13 §8 q4 ("does the panel wake by itself from s2idle") is asking about a
   state this machine cannot enter.** The question must be re-asked about S3.
   It does not become easier — S3 tears down more, not less.
2. **"The session is never torn down" (T13 §4.2) is a claim about s2idle** and
   does not automatically transfer to S3. Whether Hyprland/quickshell survive an
   S3 cycle is now an **open hardware row**, not an inherited fact.
3. The `resume=/dev/nvme0n1p2 resume_offset=1919597` on the cmdline means a
   hibernate image target is configured; `/sys/power/disk` offers `platform`.
   **INFERRED, flagged:** `mkinitcpio.conf` `HOOKS=(base systemd autodetect
   microcode modconf kms keyboard sd-vconsole block filesystems fsck)` has **no
   `resume` hook** — which is correct for a `systemd`-hook initrd (resume is
   handled by `systemd-hibernate-resume-generator`), but it is the kind of thing
   that reads as a bug and should be recorded once rather than rediscovered.

---

## 8. T13 §8 open questions — status after this sweep

| # | question | status now |
|---|---|---|
| 1 | Which edges produce `KEY_POWER`, from which node | ✅ answered 2026-08-12 by capture (T13 §2.2). This sweep **confirms the udev precondition** (§1.1) and adds the capability decode (§1.4) |
| 2 | Does anything hold a `handle-power-key` inhibitor | 🟡 **answered for Desktop Mode: NO** (§2.4). **Still open for Gaming Mode** — Steam is not running (§5.2) |
| 3 | systemd's long-press duration | 🔴 **still open, and the local manual does not state it.** `man logind.conf` documents `HandlePowerKeyLongPress=` and its default (`ignore`) but contains **no** match for `long press`, `long-press`, `5s` or `five second` as a duration. `POSITIVE CONTROL`: the same man page has **283** non-empty lines, so it was read. The value is a systemd source constant and must be cited from source, not guessed |
| 4 | Does the panel wake by itself from s2idle | 🔄 **question invalidated** — this machine cannot do s2idle (§7.2). Re-ask for S3. Hardware only |
| 5 | s2idle or deep | ✅ **ANSWERED: `deep` (S3), forced by a Valve kernel quirk** (§7) |
| 6 | Does `Lid Switch` ever assert on a handheld | 🟡 **partly**: the node exists, exposes `/proc/acpi/button/lid/LID/state`, reads `open`, and produced **no** state-change lines this boot (§2.3). Whether it can transition is unproven. 🔴 **Upgraded in severity**: `HandleLidSwitch=suspend` is live, so a spurious assert **suspends**, not merely locks |
| 7 | What SteamOS does | ✅ already answered in T13 §4.1 — **but its "suspend is s2idle" half is contradicted for our kernel** (§7.4) |

---

## 9. 🔴 Where the live device contradicts the tree

Ordered by how much damage the stale version could do.

1. **T13 §4.2 / §8 q5 — "Suspend is s2idle."**
   **The Deck says `s2idle [deep]` and the kernel logs `PM: Steam Deck quirk -
   no s2idle allowed!`.** The whole sleep design's assumptions about what
   survives a suspend rest on this. §7.
2. **T13 §5.2 row D — the lid path is described as ending in a *lock*.**
   **logind independently ends it in a *suspend*** (`HandleLidSwitch=suspend`,
   live, unoverridden). Two consumers, one described. §2.3.
3. **"fbcon/rotate is 0 on both stock Arch and Neptune" —
   `src/deck-session.sh:530` and `docs/findings/T9-delta-classification.md:109`.**
   **The live cmdline is `fbcon=rotate:1`**, on every boot entry. It is a
   present-tense statement of a fact that we ourselves changed, and T9's
   OOBE-centering conclusion is built on top of it. §6.
4. **T13 §5.2 row B calls `omarchy-sleep-lock` "masked BY HAND" without saying
   *where*.** It is masked **in `/home/deck/.config/systemd/user/`**, with the
   `graphical-session.target.wants` enablement symlink still underneath it and
   `PRESET=enabled`. That is three separate ways for the mask to evaporate, and
   the tree records none of them. §3.1.
5. **T13 §2.2's fix is written as "set `HandlePowerKey=`".** On this device
   `HandlePowerKey=ignore` is **already set by an Omarchy-owned drop-in**
   (`/etc/systemd/logind.conf.d/10-ignore-power-button.conf`). The fix is an
   *override of upstream*, with an upgrade seam, not a fresh setting. §2.1–2.3.
6. **`CLAUDE.md:38` — "The test Deck runs 3.8.4".** Live:
   `omarchy-dev 4.0.0.r1617.g6d7826d-1`, version file `4.0.0.alpha`. Already
   corrected in `docs/PROGRESS.md:337` and `:1557`; **`CLAUDE.md` is the stale
   copy**, and it is the file auto-loaded into every session.
7. **§5.17 is still open, and it has a neighbour.** `99-deck-testing`
   (`deck ALL=(ALL) NOPASSWD: ALL`) is present. Additionally
   `/etc/sudoers.d/asdcontrol` grants **`ALL` users** passwordless
   `/usr/bin/asdcontrol` — package-shipped, dated Apr 30, not previously
   recorded anywhere in this repo. §4.

**Everything the tree records that this sweep CONFIRMED unchanged:** `idle.lock
= 86400` and `idle.screensaver = 150`; both dconf site defaults present and
unshadowed; `Session=omarchy` with `Relogin=true`; the four rotation values;
`InhibitDelayMaxSec=15`; zero failed units; `deck-input-mapper` active.

---

## 10. Leave-no-trace — how it is known

- **No file was created on the Deck.** No `/tmp` file was written at any point;
  every command was a pipeline over `ssh`. `ls -la /tmp` at the end of the sweep
  shows only `.ICE-unix`, `.X0-lock`, `.X11-unix`, `.XIM-unix`, `.font-unix`,
  `checkup-db-1000`, the SDDM auth socket, and six
  `systemd-private-*` service directories — all dated `Aug 12 17:52`, i.e. **boot
  time**, before this session began.
- **No unit was started, stopped, enabled, disabled, masked or unmasked.** Only
  `systemctl show`, `status`, `is-enabled`, `is-active`, `list-unit-files`,
  `list-units`, `--failed`, and `systemd-analyze cat-config` were used. `systemctl
  --failed` reports 0 both before and after; `omarchy-sleep-lock` is still
  `masked` with its symlink mtime unchanged at `Aug 11 17:54`.
- **No package operation.** `pacman` was invoked exactly once, as `pacman -Q`
  (query only). `evtest` and `libinput` remain absent and were **not** installed;
  the capability question was answered by decoding
  `ATTRS{capabilities/key}` instead (§1.4).
- **No udev rule was applied and no re-trigger was run.** `udevadm` was used only
  with `info` (`-q property`, `--attribute-walk`). `udevadm test`,
  `udevadm control --reload` and `udevadm trigger` were **deliberately not run**
  — see §11.
- **Nothing touched the compositor, the session, or the lock.** No `hyprctl`, no
  `omarchy-*` command of any kind, no `loginctl` verb other than `list-sessions`
  and `show-session`. `LockedHint=no` and the session leader PID `872` are
  unchanged from boot.
- **Nothing touched TDP, fan, thermals or charge limits.** The only
  power-related sysfs read was `/sys/class/power_supply/*/type` (returns
  `Mains`, `Battery`) and `/sys/power/{mem_sleep,state,disk}` — all reads.
- **No reboot, no suspend.** Uptime advanced monotonically across the sweep
  (`up 35 min` at the mid-point); boot ID `4d5ec9e779c344cb955d823604c1590b`
  from `Aug 12 17:52:08` throughout.
- `sudo` was used for reads only: `cat` of root-owned files, `ls`, `grep`,
  `dmesg`, `systemd-analyze cat-config`.

---

## 11. Refused — proposals for an operator-supervised session

Each of these would have answered something real. None is read-only, so none was
run.

| # | what | why it was refused | what it would settle |
|---|---|---|---|
| 1 | `udevadm control --reload && udevadm trigger --subsystem-match=input --action=change` after installing `71-deck-power-button.rules` | Re-tags live input devices; a mistake mid-flight can drop `power-switch` from **everything** or re-add it to the ACPI node. Also re-runs `uaccess` on the controller nodes the mapper is reading | Proves the §1.5 rule actually removes the tag, on hardware, without a reboot |
| 2 | `udevadm test /sys/class/input/event2` | Documented as debugging-only; it re-runs the rule chain and its side effects are not guaranteed to be nil. Not obviously read-only ⇒ not run, per the brief | Same as 1, but offline — the cheap first step before 1 |
| 3 | Switch to Gaming Mode (`deck-session-select`) and re-run `systemd-inhibit --list` | Restarts the display manager | **T13 §8 q2** — the only remaining blocker on defect 2. Whether Steam holds a `handle-power-key` inhibitor |
| 4 | `systemctl suspend` and observe resume | Suspends a device the operator cannot see or rescue | Whether Hyprland/quickshell survive **S3** (newly open per §7.4); whether the panel wakes with the lock producer masked; the real `PrepareForSleep` timing |
| 5 | Close/assert the lid switch, or `evemu-play` an `SW_LID` event | Would suspend the machine (`HandleLidSwitch=suspend`) | **T13 §8 q6** — whether the lid path is reachable at all on a handheld |
| 6 | `systemctl --user unmask omarchy-sleep-lock.service` (even briefly) | Re-arms the lock-on-suspend producer on a device with no keyboard | Nothing worth the risk. Listed only to record that it was considered and rejected |
| 7 | A `python-evdev` capture with the operator pressing the power button | Read-only in itself, but **requires the operator's hands and eyes**, which the brief says are unavailable | Whether `event2` goes silent once the udev rule is in place — the acceptance test for the fix |
| 8 | Looking at a TTY (`chvt`) to check `fbcon=rotate:1` | `chvt` moves the active console away from the session | §6's one unverified rotation surface |

---

## 12. What to do next, shortest path

1. **Correct the fbcon claim in `src/deck-session.sh:530` and
   `docs/findings/T9-delta-classification.md:109`** — pure doc fix, no hardware.
   ⚠️ `src/` is owned by other agents this session; hand it over, do not race it.
   §9.3.
2. **Correct `CLAUDE.md:38`'s 3.8.4 claim** — it is auto-loaded every session and
   it is wrong. §9.6.
3. **Amend T13 §4.2/§8 q5 to `deep`/S3, and re-open §8 q4** with the quirk line
   quoted. §7.
4. **Move the `omarchy-sleep-lock` mask out of `$HOME` and into `src/`** — it is
   currently one `rm -rf ~/.config` from being gone, on a device where the
   failure mode is an unanswerable password prompt. §3.1.
5. **Add `HandleLidSwitch=` to whatever drop-in the T13 fix installs**, at the
   same time as `HandlePowerKey=`. They are the same file and the same risk. §2.3.
6. Then, in one supervised hardware session, items 3 → 1 → 7 from §11, in that
   order.

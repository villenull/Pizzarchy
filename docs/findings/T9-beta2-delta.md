# T9 — upstream delta, 4.0 beta 1 → beta 2 (seed)

**Measured 2026-08-11 (session 19), from the dev machine only.** No Deck, no
ISO build, no VM. Everything here came from `gh api`, `curl` against
`pkgs.omarchy.org`, and `grep` over this repo — cheap, repeatable, and worth
re-running at pin time rather than trusting.

> ⚠️ **This is a seed, not the finished delta.** Its head is *today's*
> `quattro`, which is not yet known to be what upstream calls "beta 2"
> (see §1). `docs/tasks/T9-beta2-rebase.md` step 2 owns finishing it against
> the recorded pin.

---

## 1. What "beta 2" is — ✅ RESOLVED: a published ISO, unlisted, no checksum

**Beta 2 is an ISO at a direct URL.** Found 2026-08-11 by probing
`iso.omarchy.org` after the operator pointed at an r/omarchy thread (which
neither WebFetch nor the in-app browser can open — **reddit.com is blocked by
policy on both surfaces**, so the post itself was never read).

| Artifact | Bytes | Last-Modified (UTC) | ETag |
|---|---|---|---|
| `https://iso.omarchy.org/omarchy-quattro-beta2.iso` | **6,390,581,248** (5.95 GiB) | **2026-08-10 13:44:37** | `e55e5c58ffe6ab2371b16640b6c07f7f-1219` |
| `https://iso.omarchy.org/omarchy-quattro-beta1.iso` | 6,371,614,720 (5.93 GiB) | 2026-08-05 21:12:44 | `ff788ec390ac3c2d4dc424535d95d3aa-1216` |
| `https://iso.omarchy.org/omarchy-3.8.4.iso` | 7,957,577,728 (7.41 GiB) | 2026-07-21 00:21:41 | `c372d94af51e9e9cd3c7e585b8cb5a6e-1518` |

Beta 1's timestamp matches dhh's alpha→beta announcement *and* the `stable`
channel db rebuild (2026-08-05 23:01) to within two hours. The naming pattern is
`omarchy-quattro-beta{N}.iso`; **`beta3`, `rc1` and a bare `omarchy-quattro.iso`
all 404** as of this measurement.

⚠️ **Three things about that ISO worth knowing before planning around it.**

1. **It is unlisted.** `omarchy.org`'s download link still points at
   `omarchy-3.8.4.iso`; the beta ISOs are reachable only by direct URL.
   `iso.omarchy.org/` itself redirects to `omarchy.org`.
2. **No published checksum.** `omarchy-quattro-beta2.iso.sha256` and
   `.sha256` both 404. The ETag is an **S3 multipart hash** (1219 parts) — not
   an MD5 of the file, so it is not a usable integrity check without knowing the
   part size. **We can record our own sha256 after download; we cannot verify
   against upstream's.** For a 6 GB image that boots as root, say so plainly
   rather than implying it was verified.
3. 🔥 **It was cut ~2h14m after we built our own ISO.** Ours came from
   `omarchy-iso` **`a12bfea`** at 2026-08-10 11:30 UTC; beta 2 is stamped 13:44
   UTC the same day, and `omarchy-iso`'s next commits are 16:19 and 20:51 UTC —
   **after** it. So beta 2 was cut at or very near the same builder commit we
   already used. The two images are close relatives, hours apart.

### ⚠️ The consequence that changes the plan: beta 2 ≠ today's `edge`

`quattro` HEAD is now **~24 hours and ~30 commits ahead of beta 2**, and `edge`
tracks HEAD within minutes. **A plain `omarchy-update` on the Deck does not
bring it to beta 2 — it overshoots into whatever edge holds that hour.** If the
goal is "run what users run", the pin is beta 2's snapshot and the update must
be pinned to it. If the goal is "run what upstream is about to ship", it is edge
HEAD and it moves daily. **These are different targets; T9 step 1 must state
which one was chosen and why.**

---

### What beta 2 is *not* — the negatives still hold and are still useful

**No tag, no release, no channel carries the name.** What was checked, and what
it returned:

| Checked | Result |
|---|---|
| `basecamp/omarchy` GitHub **releases** | newest is `v3.8.4` (2026-07-21). **No 4.0 release at all** |
| `basecamp/omarchy` **tags** | newest is `v3.8.4`. No `v4.0.0-beta*` |
| `basecamp/omarchy` `version` file on `quattro` | **`4.0.0.alpha`** — never bumped for beta 1 either |
| `omacom-io/omarchy-iso` releases | **none published** |
| `omarchy.net` | names only "v3.0 — Hyprland edition" |
| `pkgs.omarchy.org` channels | exactly two respond 200: **`edge`** and **`stable`**. `beta`, `beta2`, `rc`, `quattro`, `testing`, `preview`, `nightly` all 404 |

So beta 2 is **not** a tag, a GitHub release, or a channel. The two candidates
that *did* move are:

- **`quattro` HEAD** — `1c9dfc5` (2026-08-11 12:30 UTC), *"Greet the first login
  with a keybindings toast again"*
- **the `edge` package channel** — `omarchy.db` last-modified 2026-08-11 12:41
  UTC, carrying `omarchy-dev-4.0.0.r1652.g1c9dfc5-1` and
  `omarchy-settings-dev-4.0.0.r1652.g1c9dfc5-1`

`r1652.g1c9dfc5` is a git-describe of `quattro` HEAD exactly. **`edge` tracks
`quattro` HEAD and was rebuilt today**, 11 minutes after the last commit.

For contrast, `stable` carries `omarchy-dev-4.0.0.r1046.gd570d99-1` — a
2026-07-13 commit, **606 commits behind** `quattro` — with its db last modified
2026-08-05 23:01 UTC, which lines up with dhh's public alpha→beta announcement
(~Aug 5–6). If beta 2 means "the `stable` channel was promoted again", **it had
not happened as of this measurement.**

⚠️ **Consequence for the pin:** a version string cannot identify this build.
Two installs both calling themselves `4.0.0` can be 600 commits apart. **Pin
the SHA.**

*(That paragraph was written before the ISO was found, and it survives because
its conclusion held: **the `stable` channel was not promoted for beta 2** — its
db has not moved since 2026-08-05. So beta 2 is an ISO, not a channel event,
and a machine tracking `edge` is already past it. ⚠️ **Which channel each beta
ISO actually carries is unverified** — it can only be read from inside the
image, which is T9 step 3a's job. Do not assume it from the timestamps.)*

**Two open calls for the operator**, both recorded in `docs/PROGRESS.md` §6:
approval to download the 6 GB ISO (no upstream checksum to verify it against),
and whether to rebase now or wait — the thread that surfaced beta 2 is titled
*"Omarchy Quattro will be shipping this week."*

---

## 2. Baseline and head of this seed

| | SHA | Date | Note |
|---|---|---|---|
| **Baseline** | `354c2f0` | 2026-08-10 ~12:00 UTC | last `quattro` commit before the P1.5 Deck install; the closest available proxy for what the Deck actually runs |
| **Head** | `1c9dfc5` | 2026-08-11 12:30 UTC | `quattro` HEAD at measurement |
| Ahead by | **37 commits** | | 45 counted from 2026-08-10T00:00Z |

`omacom-io/omarchy-iso`: our ISO was built at **`a12bfea`** (2026-08-10 11:30
UTC, §3.10). HEAD is **`d6cd2d3`**, **4 commits ahead, 4 files changed** — all
dated 2026-08-10, **nothing on 2026-08-11**:

- `d6cd2d3` Call the renamed `omarchy-apply-system` finalizer
- `be618cc` Send the installer off with laseretch again
- `a6a442b` Center the installer logo in a locale without a charset
- `e5f2b46` Center the installer screens and move the effects to ttfx

⚠️ **The installer's screens moved and its finalizer was renamed.** Both are
squarely T4/T5 territory, and the second means an ISO built from `a12bfea`
against a *newer* runtime calls a binary that no longer exists.

---

## 3. Changed upstream files, by seam

37 commits touched 60 non-test files. Rows below are the ones that reach
something this project depends on. **Unclassified rows are the work item** —
T9 step 2 must mark each *no impact · re-verify · breaks us* with a reason.

### 3.1 🔴 `etc/sudoers.d/omarchy-tzupdate` — changed, and we quote it verbatim

Commit *"Fix command injection in theme install, drop tzupdate NOPASSWD
(#6694)"* (2026-08-11 10:31 UTC):

```diff
-%wheel ALL=(root) NOPASSWD: /usr/bin/tzupdate, /usr/bin/timedatectl set-timezone *
+%wheel ALL=(root) NOPASSWD: /usr/bin/timedatectl set-timezone *
```

**Impact on us: documentation, not function.** `src/deck-session.sh` (~line
1157) quotes the *old* line in a comment explaining why we install our own
narrow grant anyway. The half we depend on — `timedatectl set-timezone *` —
survived, and our grant is independent of it regardless.

**But the comment's argument was that a package-owned file on a beta distro can
change underneath us, and it changed four days later.** Update the quote; keep
the reasoning and record that it was borne out. This is the cheapest possible
demonstration of why T9 exists.

### 3.2 🔴 Three `bin/omarchy-apply-*` renames

`omarchy-apply-hardware`, `omarchy-apply-lock`, `omarchy-apply-system` are all
marked *renamed* upstream, and `omarchy-iso` HEAD exists to *"Call the renamed
`omarchy-apply-system` finalizer"*.

**Our `src/` references none of them** (grepped: zero hits). The exposure is in
**T5's fork of the ISO builder**, which will inherit whichever name it forks at,
and in any doc that names the old ones.

### 3.3 🟠 `migrations/*.sh` — four new, root, machine-wide, run on update

They execute during `omarchy-update`. Read before updating the Deck:

| Migration | Does what | Why we care |
|---|---|---|
| `1786380259` | Remembers Bluetooth on/off through the rfkill soft block; **rewrites `/etc/bluetooth/main.conf`**, takes `sudo`, notes that `/dev/rfkill` is only writable from an active graphical seat so *"an update over SSH would otherwise abort here"* | We drive the Deck **over SSH**, and BT pairing is an open parity row (P2.2) |
| `1786386460` | `omarchy-pkg-add libvips` | T5 payload + ISO size |
| `1786391100` | Broadcom Wi-Fi WPA handshake in software, gated on Apple DMI | Deck-irrelevant; confirms migrations *do* branch on hardware |
| `1786447584` | `omarchy-pkg-add zbar` (QR scanning) | T5 payload + ISO size |

⚠️ **A migration is upstream code running as root against our staged state.**
Nothing stops one from resetting a setting §5.20 calls load-bearing. The
mitigation is ordering: read them, update, then re-verify with `dconf read -d`.

### 3.4 🟠 Quickshell / the shell itself

`shell/shell.qml`, `shell/services/PluginRegistry.qml`, `shell/plugins/bar/Bar.qml`,
`shell/plugins/agents/Panel.qml`, `shell/plugins/panels/bluetooth/Panel.qml`,
new `shell/plugins/bar/widgets/KeyboardLayout*`, and — **the one to look at
first** — `shell/plugins/lock/Service.qml`.

Our idle policy (screensaver 150 s, **lock 86400 s**) is a deliberate
neutering of exactly that service, it lives in a per-user `shell.json`, and
⚠️ `lock: 0` locks *instantly* rather than disabling. A changed lock service is
the most plausible way the Deck quietly starts locking itself again with no
keyboard to unlock it.

Also `default/omarchy/omarchy-menu.jsonc` and `bin/omarchy-menu` changed —
that is P2.4's extension seam (`~/.config/omarchy/extensions/omarchy-menu.jsonc`).

### 3.5 🟡 Hyprland config and session

`default/hypr/bindings/applications.lua`, `default/hypr/bindings/utilities.lua`,
plus new `bin/omarchy-hyprland-monitor-modeless`,
`bin/omarchy-hyprland-session-locked`, and edits to
`omarchy-hyprland-monitor-clamshell` / `-monitor-watch` / `-reload-guard`.

Our rotation is a separate file (`~/.config/hypr/monitors.lua`, transform **3**)
so the bindings are low risk — but **monitor-watch and the clamshell/modeless
recovery paths now react to displays coming up with no mode**, and the Deck's
internal panel is the only display. Worth one look, not a rewrite.

### 3.6 🟡 Install-time surfaces

`install/omarchy-base.packages` (payload delta for T5), `install/hardware/all.sh`,
`install/hardware/bluetooth.sh`, `install/config/lockscreen-pam.sh`,
`install/user/first-run/{welcome,wifi}.sh`.

`first-run/wifi.sh` is directly adjacent to T4's Wi-Fi screen; `lockscreen-pam.sh`
is adjacent to §5.20's lock policy.

### 3.7 ⚪ No signal found in the boot chain

Nothing in the 37 commits touches Limine, `limine-mkinitcpio-hook`, snapper
config, the ESP layout or `mkinitcpio`. **`src/omarchy-deck-kernel.sh` looks
untouched by this delta** — which is what T1's design predicted (it gates on the
UKI *mechanism*, never on Omarchy's packaging).

⚠️ Do not promote this to a fact without checking the pinned SHA range and the
*package* versions (`limine`, `limine-mkinitcpio-hook`) in the channel, which
move independently of the `quattro` branch.

---

## 4. Method — reproduce before trusting

```bash
gh api "repos/basecamp/omarchy/compare/354c2f0...quattro" -q '.files[] | "\(.status)\t\(.filename)"'
curl -sS -o edge.db https://pkgs.omarchy.org/edge/x86_64/omarchy.db
tar tf edge.db | grep -E '^omarchy-(dev|settings-dev)-'
```

Substitute the recorded baseline and pin from `docs/PROGRESS.md` §1.1. The
`compare` endpoint caps at 300 files — if a future range exceeds that, page it
rather than silently truncating, which is the same class of mistake as the
`comm` truncation in `docs/tasks/T7-enablement-layer.md`'s traps list.

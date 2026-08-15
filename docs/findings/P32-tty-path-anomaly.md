# P3.2 — the TTY `PATH` anomaly: `/usr/bin` missing from a real console login

> **Verdict: UNREPRODUCED.** Investigated 2026-08-15 (session 28), read-only,
> against the same physical Deck and the *same installed software* that produced
> the anomaly — nothing on the device had been updated in between. Every attempt
> to re-create it produced a correct `PATH`. The leading hypothesis (a mise
> `hook-env` PATH-reconstruction bug) is **actively contradicted** by measurement.
> No ISO change is recommended.

## The observation being investigated

The operator, logged into a real console (Ctrl+Alt+F2 → `agetty`/`login`, user
`deck`, bash) on the freshly installed Deck, photographed this `PATH`:

```
/home/deck/.local/share/mise/installs/node/26.7.0/bin:/usr/local/sbin:/usr/local/bin:/home/deck/.local/share/mise/shims:/home/deck/.local/bin:/usr/bin/vendor_perl:/usr/bin/core_perl
```

`systemctl` and friends were `command not found`; `/usr/bin/systemctl` worked.
Compared with the same machine's correct login `PATH`, exactly two entries are
absent: **`/usr/bin`** and **`/usr/bin/site_perl`**.

## Evidence table

| # | Claim | How established | Strength |
|---|---|---|---|
| E1 | `/usr/bin` was absent from that shell's `PATH` | `systemctl` not found, `/usr/bin/systemctl` worked | **Functional proof** |
| E2 | `/usr/bin/site_perl` was absent | Reading a photograph of a 9-segment `PATH` | Transcription only — see §"The site_perl question" |
| E3 | The shell's **login-time** `PATH` was correct | `/proc/3772/environ` (exec-time snapshot) | **Direct** |
| E4 | Over SSH, `bash -lic 'echo $PATH'` was correct | measured, session 28 | Direct |
| E5 | All three `/usr/bin/*_perl` dirs exist and are owned by `perl` 5.42.2-2 | `pacman -Qo`, `ls -ld`, on device today | **Direct** |
| E6 | `perl` was installed during the original pacstrap, not later | `/var/log/pacman.log`: `[2026-08-15T17:24:12+0000] installed perl (5.42.2-2)`, i.e. 11:24 local, inside the install transaction | **Direct** |
| E7 | `/etc/profile.d/perlbin.sh` guards each dir with `[ -d ]` | read on device | Direct |
| E8 | Device mise is **2026.8.3-1**, installed at pacstrap (11:25:03 local) | `pacman -Qi mise`, `pacman.log` | Direct |
| E9 | Nothing on the device was updated between the anomaly and this investigation | `pacman.log` — one install transaction at 11:23–11:25, then only the Steam repair | **Direct** |
| E10 | A simulated console login on the device today yields the **correct** `PATH` at every prompt | reproduction attempts R1–R3 below | **Direct negative** |

E9 is what makes the negative result meaningful: this is not "we couldn't
reproduce it on a different build", it is "we couldn't reproduce it on the same
machine running the same bits".

## Where `PATH` actually comes from on this install

Verified on the device, in order:

1. `/etc/login.defs` → `ENV_PATH PATH=/usr/local/sbin:/usr/local/bin:/usr/bin`
2. `/etc/security/pam_env.conf:76` →
   `PATH DEFAULT=/usr/local/sbin:/usr/local/bin:/usr/bin:@{HOME}/.local/share/mise/shims:@{HOME}/.local/bin`
   — this is why the exec-time environ (E3) already carries the mise shims.
   Written by upstream Omarchy's `install/config/ssh-command-path.sh`.
3. `/etc/profile` → `append_path` for `/usr/local/sbin`, `/usr/local/bin`,
   `/usr/bin` (guarded, append-only).
4. `/etc/profile.d/omarchy.sh` → `default/bash/env-bootstrap` (appends shims and
   `~/.local/bin`, both `case`-guarded, append-only).
5. `/etc/profile.d/perlbin.sh` → appends `site_perl`, `vendor_perl`, `core_perl`,
   each behind `[ -d ]`.
6. `~/.bashrc` → `default/bash/rc` → `envs`, `shell`, `aliases`, `functions`,
   `init`; `init` runs `eval "$(mise activate bash)"`, which prepends the node
   install dir and registers a per-prompt `PROMPT_COMMAND` hook.

**Every one of these is append-only and guarded. `mise` is the only thing in the
chain that rewrites `PATH` wholesale, and the only thing that runs again after
the first prompt.** That is why it was the prime suspect.

## Reproduction attempts

All read-only. No device state was modified; no service restarted.

**R1 — dev machine, synthetic omarchy rc chain, mise 2026.7.10.**
`env -i` with the Deck's exact login `PATH`, `script(1)` pty, `bash -i` sourcing
a replica of `env-bootstrap` + `mise activate` + `zoxide init`, six prompts, a
`cd` out and back. `PATH` identical and correct at every prompt. **Not
reproduced.**

**R2 — the Deck itself, simulated console login, mise 2026.8.3.**

```
env -i HOME=/home/deck USER=deck LOGNAME=deck SHELL=/bin/bash TERM=linux \
  PATH='/usr/local/sbin:/usr/local/bin:/usr/bin:/home/deck/.local/share/mise/shims:/home/deck/.local/bin' \
  script -qec 'bash --login -i' /dev/null
```

Real login shell, real `/etc/profile`, real `~/.bashrc`, real pty, `TERM=linux`,
five prompts, `cd /` and back (fires mise's `chpwd` hook), plus a deliberate
`command not found` (fires mise's `command_not_found_handle` → `hook-not-found`
→ `_mise_hook`). `PATH` was the full correct nine entries at **every** prompt,
including after the not-found handler. **Not reproduced.**

**R3 — mise's PATH algebra, directly.** With a stale/short `__MISE_ORIG_PATH`
forged into the environment, and with entries appended by hand between hooks,
`mise hook-env` preserved every entry across repeated hooks. `hook-env` emits
nothing at all when it has no change to make.

**R4 — does mise repair a loss?** No. Removing `/usr/bin` by hand inside a
mise-activated interactive shell **persists for the life of that shell** —
prompt after prompt, unchanged. mise neither causes nor cures it.

**R5 — does a loss survive a new login shell?** No. `/etc/profile`'s
`append_path '/usr/bin'` re-adds it (at the *tail*), and mise does **not** strip
that re-append:

```
A (non-interactive login, damaged PATH in):  …:/usr/bin/core_perl:/usr/bin
D3 (interactive login, mise active):         …:/usr/bin/core_perl:/usr/bin
```

This is the most useful structural fact found: **the damage cannot be inherited
across a login.** Combined with E3 (login-time environ was correct), the removal
must have happened *inside that one shell*, after `/etc/profile` had run.

## The mise hypothesis is contradicted, not merely unconfirmed

The suspected mechanism — `hook-env` rebuilding `PATH` from a snapshot taken
before the profile scripts finished — is a real bug class in mise, and it is
already fixed in the version this Deck runs:

- PR **#7919** — paths appended after `mise activate` were being discarded.
- PR **#8190** — "fix(hook-env): preserve PATH reordering done after activation";
  `hook-env` previously restored the order captured in `__MISE_ORIG_PATH`,
  discarding post-activation changes. Merged 2026-02-16, released in **mise
  2026.2.15**.

The Deck runs **2026.8.3**, roughly six months of releases later, and R2–R4
confirm the fixed behaviour empirically on the device: entries added after
activation survive, and mise removes nothing it did not add.

Two further points against mise: the omarchy rc chain activates mise **last**
(`init` is the final `source` in `rc`), so there is nothing left to append after
activation for the bug to eat; and the SSH control (E4) is not the discriminator
it looked like — `bash -lic 'cmd'` never renders a prompt, so
`PROMPT_COMMAND` never fires there. R2 closed that gap by driving real prompts on
the device, and still produced a correct `PATH`.

## The site_perl question — the clue that was supposed to crack it

The brief's hope was that `site_perl` is legitimately absent (`perlbin.sh` only
adds it `[ -d ]`), which would reduce the anomaly to a single lost entry. **That
does not hold.** All three dirs exist (E5), all three ship in the same `perl`
package, and `perl` was installed inside the original pacstrap transaction (E6),
so all three existed on the very first boot. `site_perl` should have been in that
`PATH`.

So the contradiction the brief asked to chase — `vendor_perl` and `core_perl`
survive while `site_perl` does not — **survives intact and is unexplained**. No
mechanism was found that removes `/usr/bin` and `/usr/bin/site_perl` while
sparing their two immediate neighbours.

One pattern is worth recording without endorsing it. In the correct `PATH`, the
two missing entries are exactly the ones that *flank* the PAM-appended pair:

```
… /usr/local/bin  [/usr/bin]  shims  ~/.local/bin  [site_perl]  vendor_perl  core_perl
                   ^^^^^^^^^                        ^^^^^^^^^^
```

That is suggestive of an off-by-one in some list surgery. It is also two data
points, which is not a pattern.

**Honest caveat on E2.** `/usr/bin` being gone is functionally proven — a
`command not found` for `systemctl` cannot be a transcription error.
`site_perl`'s absence rests entirely on reading a photograph of a `PATH`
containing three near-identical adjacent segments
(`/usr/bin/site_perl:/usr/bin/vendor_perl:/usr/bin/core_perl`). Dropping one of
three lookalike segments while transcribing is a classic reading error. **If
`site_perl` was in fact present, the whole anomaly is "one entry, `/usr/bin`,
went missing"** — a much smaller and differently-shaped problem, and the
flanking pattern above evaporates. Re-reading the original photograph is the
single cheapest thing that could move this investigation, and should be done
before anyone builds further theory on the two-entry shape.

## Ranked hypotheses

**H1 — the shell's `PATH` was modified by something the operator ran.**
*Best fit for the evidence.* R4 shows a single stray `PATH=` assignment is never
repaired inside a live shell, and E3+R5 show the damage did not come from login
and could not have been inherited. That boot was the Steam-crash-loop diagnosis
(`steam-short-session-tracker` retrying every ~10 s); commands were being typed
and pasted on that console under pressure. A naive `PATH="${PATH/…/}"`,
a `PATH=$(… | grep -v …)` filter, or a pasted line that clobbered `PATH` all
produce exactly this class of result.
*Against:* not verifiable — `/home/deck/.bash_history` **does not exist**. Bash
writes history on clean exit, and `last` shows that boot ended in a crash
(`11:29 – crash`), so whatever was typed is gone.

**H2 — a mise `hook-env` defect.** *Contradicted* by the version history (fix
shipped 2026.2.15, device runs 2026.8.3) and by R2–R4 on the device itself.
Not impossible as a rare transient, but there is no positive evidence for it.

**H3 — a transient specific to that boot.** Steam crash-looping, gamescope
restarting, `start-limit-hit`; a `mise hook-env` subprocess misbehaving under
that churn would leave no trace. Unfalsifiable without a recurrence; recorded
only so it is not re-derived.

**H4 — partial transcription artifact.** `site_perl` was actually present; only
`/usr/bin` was lost, by H1 or H3. Cheap to test (§site_perl question).

## Impact assessment

- **Does it hit every console login? No — demonstrated.** R2 logs into the same
  machine, same software, through the same code path, and gets a correct `PATH`.
- **First boot only?** Unknown. Nothing found is first-boot-specific.
- **Only after mise touched node?** No. The node install predates every boot
  (mise config and `~/.local/share/mise` are both timestamped 11:25, inside the
  install), so *every* login on this machine has had the node dir prepended,
  including all the correct ones.
- **Blast radius if it does recur:** confined to one shell. It cannot reach the
  Gaming Mode session, the installer, or any service — those do not source the
  bash rc chain, and `/etc/profile` repairs any new login shell (R5). It is a
  usability defect on an interactive console, not a boot or install defect.
- **Whose code is it?** Not ours. Nothing in `iso/overlay/` or `src/` writes
  `/etc/profile.d`, `/etc/security/pam_env.conf`, `/etc/login.defs`, `~/.bashrc`
  or `~/.bash_profile` (grepped; zero hits). The mise activation is upstream
  Omarchy's `default/bash/init`, unconditional for any user with mise on `PATH`,
  and the PAM `PATH` line is upstream's `install/config/ssh-command-path.sh`.
  A Pizzarchy-introduced cause would have to be indirect.

## Recommendation

**Document only. Change nothing in the ISO.** Specifically:

1. **Do not "fix" this.** With no reproduction and no mechanism, any change
   would be a guess bolted onto a load-bearing path, and the two obvious guesses
   are both bad: re-asserting `PATH` from the rc chain would fight mise for
   ownership, and hard-coding `/usr/bin` back in would mask the next occurrence
   instead of surfacing it.
2. **Do not report upstream yet.** Neither mise nor Omarchy has an actionable
   report here — a single photograph, no reproduction, and a mise version that
   already carries the fix for the suspected bug class. Filing now would be
   reconstructed confidence, which is exactly what this project's records are
   supposed to punish.
3. **Re-read the photograph** for `/usr/bin/site_perl` (§site_perl question).
   It is free and it decides which hypotheses stay alive.
4. **If it recurs, capture before anything else:** `declare -p PATH`,
   `env | grep __MISE`, `history`, `/proc/$$/environ` **and the parent's**
   `/proc/$PPID/environ`, and `mise hook-env -s bash` raw output. The `environ`
   pair distinguishes H1 from everything else in one shot.
5. **Worth considering separately** (not a fix for this): that boot's shell
   history was lost to a crash, which is why H1 cannot be settled. Any future
   hardware-diagnosis session on a console should be run with history flushed
   per command, or simply transcribed.

## Status

- [x] Investigated on the same hardware, same software, read-only
- [x] Prime suspect (mise `hook-env`) tested directly and contradicted
- [x] `site_perl` theory tested and refuted — the contradiction stands open
- [ ] **Mechanism unknown.** Verdict: **UNREPRODUCED**
- [ ] Photograph re-read for `site_perl` — open, cheap, decides H4

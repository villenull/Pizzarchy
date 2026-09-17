# SSH into the Deck — from a fresh install to first command

One thing you type on the Deck, ever: `pizza ssh`. Everything else happens
on your other machine.

## 1. On the Deck (the ONLY Deck typing in this file)

Run `pizza ssh` (in a terminal via STEAM+X keyboard, or over a USB keyboard).
It enables sshd and opens port 22 to this subnet only, then prints a connect
line like:

```
ssh deck@192.168.100.25
```

That address is DHCP-assigned: it can change when the Deck rejoins the
network. If `ssh` later says `Connection timed out`, re-run `pizza ssh` and
read the new address. If it says `REMOTE HOST IDENTIFICATION HAS CHANGED`,
the Deck was reinstalled since you last connected — run `ssh-keygen -R
<address>` **on your other machine**, not on the Deck.

Turn it off when done: `pizza ssh off`.

## 2. On your other machine (everything below runs here)

### First contact: password, once

```bash
ssh deck@<address-from-step-1>
```

Password: `deck` (the install default). You type this on your real keyboard,
not the Deck. If the password was changed after install, use that instead.

### Never type it again: install your key, once

```bash
ssh-copy-id deck@<address>
```

Type the password one last time when asked. From now on `ssh deck@<address>`
logs in with no password — including after Deck reboots. The key survives
everything except a full reinstall.

### After a reinstall: two commands, both here

A fresh install wipes `authorized_keys` (and changes the host key). Still
nothing to type on the Deck beyond the `pizza ssh` in step 1:

```bash
ssh-keygen -R <new-address>
ssh-copy-id deck@<new-address>
```

The first clears the stale host key; the second reinstalls yours. This is the
whole recovery — there is no key string to type on the Deck, ever.

## 3. Rules this file guarantees

- **Nothing longer than `pizza ssh [off]` is ever typed on the Deck.**
  A 100-character key string on a trackpad keyboard is unfollowable, so the
  key travels the other way: `ssh-copy-id` runs on the machine with the real
  keyboard and pushes the key *to* the Deck.
- **`pizza ssh allow <url>` exists but is NOT this path.** It fetches a key
  over the LAN for air-gapped setups. Prefer `ssh-copy-id` — one command,
  no server to run, no URL to type.
- **Password `deck` is the bootstrap, not the posture.** After `ssh-copy-id`,
  consider `sudo pizza ssh status` on the Deck — it tells you whether
  password auth is still on and how to close it (unprivileged `pizza ssh
  status` reports `PasswordAuthentication=unknown`: reading sshd's resolved
  config needs root). The project deliberately never does that for you
  (wrong and you're locked out of a keyboard-less device).
- **If SSH is unreachable at all**, hold Power ~10 seconds to force a
  shutdown, then power on and re-run `pizza ssh`. This loses nothing but
  unsaved state. See `docs/RECOVERY.md` for what needs SSH and what doesn't.

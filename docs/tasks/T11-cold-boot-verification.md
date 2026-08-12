# T11 — verify the §5.28 fix by COLD BOOTING the Deck

> **Operator + Claude, ~15 minutes, first thing in the next Deck session.**
> This is the release blocker's only real check. It runs *before* T10
> (`docs/tasks/T10-steam-extest-spike.md`), which is a decision and can wait.

## Objective

Prove that a Deck **booted from power off** — with nothing restarted by hand —
has a working on-screen keyboard, app launcher and Omarchy menu.

## Why this shape and no other

§5.28 shipped because every check that existed passed: the service was
`active`, bound to the right node, and printed its bindings correctly. **A
mapper restarted by hand always works.** The bug lives entirely in the window
between the service starting and uwsm importing the session environment, so any
procedure that touches the mapper before pressing the buttons destroys the
evidence. Same shape as R-29.

⚠️ **Do not "just check the journal" instead.** The journal will say
`session environment resolved` whether or not the resolution happened before
the user's first press. The buttons are the oracle; the journal is the
attribution.

## Prerequisites

- The fix is in `main` (session 21) but **the Deck runs an installed copy** —
  `/usr/local/bin/deck-input-mapper`. It must be deployed first, or this test
  measures the old code and passes for the wrong reason.
- A snapshot before deploying, per the usual rule.

## Steps

### 1. Deploy the new mapper

```bash
DECK_STAGE_ARGS=stage-input-mapper ./tools/deck-sync.sh deck-session.sh src
```

⚠️ **The `src` argument is not optional.** `deck-sync.sh`'s source dir defaults
to `tools/`, which does not contain `deck-session.sh`; without it the command
fails with "stage script not found" (one of the three runbook commands session
20 found wrong as written).

Confirm the installed copy is the new one — the old one has no such string:

```bash
ssh steamdeck 'grep -c SESSION_ENV /usr/local/bin/deck-input-mapper'
```

Expect a number well above zero. **If it is 0 or the file is missing, stop** —
everything below would test the old code.

### 2. Cold boot. Actually cold.

```bash
ssh steamdeck 'sudo systemctl poweroff'
```

Wait for the Deck to be fully off, then power it on with the button. ⚠️ **A
reboot is not equivalent and neither is a session switch** — use power off, so
the boot is the same one users get.

### 3. Press the buttons FIRST, before anything else

Land on the desktop. **Do not ssh in. Do not open a terminal. Do not restart
anything.** Then, in this order:

| Press | Expected |
|---|---|
| **STEAM+X** | the on-screen keyboard appears |
| **STEAM** | the app launcher appears |
| **QAM** | the Omarchy menu appears |

Record what each one did, **including partial results** — one working and two
not is a different bug from all three failing, and worth more than a verdict.

### 4. Only now, read the journal

```bash
ssh steamdeck 'journalctl --user -u deck-input-mapper -b --no-pager | head -40'
```

Expect, in order:

- `deck-input-mapper: reading /dev/input/eventN ...`
- possibly `the session environment is not ready yet (missing ...)` — **this
  line is normal and is the bug being survived**, not a failure
- `deck-input-mapper: session environment resolved; ...`

⚠️ **`no session environment after 60s` on the desktop is a failure** even if
the buttons worked: it means something else supplied the environment and the
resolver never did.

### 5. The second cold case — the switch path

§5.28 flags this separately and it has never been tested: from Gaming Mode use
Steam's **Power → Switch to Desktop**, and press the same three buttons without
restarting anything. That path starts a fresh Hyprland through sddm, so the
same race applies.

## Done when

- All three buttons work on a cold boot, **pressed before anything else**, and
- the journal shows the resolver did it, and
- step 5 passes too, or its failure is recorded as a distinct finding.

## Failure modes

- **Buttons dead, journal says resolved.** The resolution came too late — the
  poll interval or the startup ask is wrong, not the mechanism. Capture the
  timestamps: `journalctl --user -u deck-input-mapper -b -o short-monotonic`.
- **Buttons dead, journal says nothing about the environment.** The deployed
  binary is the old one. Redo step 1.
- **`no session environment after 60s`.** The user manager did not answer.
  Compare by hand: `systemctl --user show-environment | head`.
- **Only the keyboard fails.** Then it is not §5.28 — the layer-shell overlay
  has its own failure paths and falls back to squeekboard; read the journal for
  `the layer keyboard failed`.

## Escalate if

The buttons work on a cold boot **but the journal shows the resolver never
succeeded**. That means something else is supplying the environment and the
whole diagnosis is incomplete — surface it rather than closing §5.28.

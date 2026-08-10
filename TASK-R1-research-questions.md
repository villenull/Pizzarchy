# R1 — Research questions (de-risking)

> **Status: ✅ done.** All six resolved; see `FINDING-R1-*.md` and
> `PROGRESS.md` §3. §10.6's drafts are staged and held by operator choice.

**Model: Opus, plan mode**
Can run in parallel with T0/T1. Findings can reshape T5, so do it early.

## Objective

Convert the six open questions in `PLAN.md` §10 from hypotheses into
documented findings. Each already has a stated hypothesis — your job is to
**confirm or kill it with evidence**, not to research from scratch.

## Why this matters

At least one of these (10.4, Steam requiring network on first launch) could
undercut the project's headline "fully offline" claim. Discovering that
during T5 or T6 is expensive; discovering it now is nearly free and changes
how the project is framed and marketed.

## Prerequisites

None.

## Steps

Work each question below. For each, write a short finding into
`FINDING-R1-<n>.md`: hypothesis, what you did to test it, result
(CONFIRMED / KILLED / PARTIAL), and what it changes about the plan.

### 10.1 — Can Quattro's offline mirror carry Deck packages?

- Read `omacom-io/omarchy-iso`, especially `builder/`.
- Determine how the offline pacman mirror is assembled and whether extra
  packages/repos can be added.
- **Specifically test the signing question.** Valve's repos are consumed
  with `SigLevel = Never`. Determine whether the build can carry that
  exception, needs a local re-sign step, or breaks.
- Deliverable: a concrete yes/no plus the exact mechanism, since T5 depends
  on it.

### 10.2 — Hooks vs. forking `basecamp/omarchy`

- Verify against **Quattro specifically**, not Omarchy 3.x — the shell was
  rewritten and this is exactly the kind of thing that changed.
- Check: `OMARCHY_INSTALLER_REPO` / `OMARCHY_INSTALLER_REF` env vars;
  the `~/.config/omarchy/hooks/` directory-style hook mechanism; and the
  report that Quattro makes `~/.local/share/omarchy` a pacman-owned symlink
  (which would break git-checkout-based integrations).
- Deliverable: the sanctioned extension point, or confirmation that a fork
  is genuinely required.

### 10.3 — Gamepad mapping in Desktop Mode: two candidate designs

- Design (a): run Steam in the background during the Omarchy desktop
  session and inherit its desktop controller layout + on-screen keyboard.
- Design (b): ship a custom mapper as a systemd user service scoped to the
  desktop session only.
- This one **needs hardware** to decide properly. Prepare both far enough to
  test, then hand to the operator as a single hardware session testing both
  head-to-head. Don't guess.

### 10.4 — Does Steam work offline on first boot? ⚠️ highest stakes

- **Test this early and cheaply**: install Arch's `steam` package in a VM
  with no network, launch it, observe.
- The hypothesis is that it's a bootstrap that downloads the real client
  from Valve on first launch — meaning a "fully offline install" still
  yields a device that needs internet before Gaming Mode is usable.
- Also check whether Steam's redistribution terms permit bundling a
  pre-populated client in a public ISO.
- **If confirmed, stop and surface it to the operator** before continuing.
  It changes project framing (honest version: "installs fully offline;
  Steam signs in on first launch like any new Deck") and makes the Wi-Fi
  screen in `PLAN.md` §6.1a item 7 more prominent.

### 10.5 — Secure Boot / BIOS state on Deck

- Determine whether any BIOS change is needed (Secure Boot state, boot
  order) to install from USB.
- This cannot be automated from inside an installer, so if any step is
  needed it must be documented with photos before first boot.
- Ask the operator to check their device and report; write it up.

### 10.6 — Upstream collaboration

- Draft (do not send) an outreach message to `28allday`, who maintains
  `Super-Shift-S-Omarchy-Deck-Mode` and contributes to mainline Omarchy.
- Also draft the five upstream bug reports for `aorumbayev/deckarchy` from
  `PLAN.md` §8, each with its hypothesis and reproduction.
- **Do not post anything.** Public actions require operator approval per
  `START-HERE.md` §3.

## Done when

- [ ] A finding doc exists for each of 10.1–10.6
- [ ] Each states CONFIRMED / KILLED / PARTIAL with evidence, not opinion
- [ ] 10.4 has been tested in an actual network-isolated VM, not reasoned about
- [ ] `PLAN.md` §10 updated in place to reflect findings
- [ ] `PROGRESS.md` "Findings" section updated
- [ ] Drafts for 10.6 written and staged for operator review

## Escalate if

- 10.4 confirms Steam needs network — surface immediately, don't work around
- 10.1 shows the offline mirror can't carry Valve packages without
  substantial rework — this materially changes T5's size

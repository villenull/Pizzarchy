# DRAFT — outreach message to 28allday

**STATUS: DRAFT ONLY. Not sent. Requires explicit operator approval before
posting anywhere (GitHub issue/discussion, Discord, forum, email, etc.) —
per project hard rule against publishing/posting without approval.**

Context: `28allday` maintains `Super-Shift-S-Omarchy-Deck-Mode` (the Gaming
Mode script this project's `gamescope-session-deck` is planned as a fork
of — PLAN.md §4/§5) and is also a contributor to mainline Omarchy. PLAN.md
§10.6 hypothesizes high receptivity: small repo (single-digit stars, one
fork at time of writing), likely appetite for Deck support living closer to
upstream instead of a permanent fork.

Suggested venue once approved: whatever `28allday` lists as preferred
contact on their repo (GitHub issue/discussion on
`Super-Shift-S-Omarchy-Deck-Mode` is the most likely low-key option — avoids
cold-DMing).

---

## Draft message

Subject/title (if posted as a GitHub discussion/issue): **Steam Deck +
Omarchy Quattro — comparing notes?**

Hi — I've been working on a Steam Deck–native installer for Omarchy Quattro
(offline, controller-only install flow that keeps stock SteamOS Gaming Mode
intact and adds a Desktop Mode reachable by button, not just a keybind). Your
Gaming Mode script is the closest prior art I've found, and I saw you also
contribute to mainline Omarchy, so figured it made sense to say hello before
going further rather than duplicating work quietly in a fork.

A few things that might be useful to compare notes on:
- Deck-specific perf/session-switch handling you've already solved that I'd
  otherwise reinvent.
- Whether there's appetite for some of this living closer to upstream
  Omarchy rather than needing a permanent Deck-specific fork. One thing that
  changed my read on this recently: Omarchy Quattro installs as a pacman
  package pulled from a repo baked into the ISO's offline mirror, not a
  git-cloned installer chain — which means the integration surface is likely
  lighter than a fork (a companion package + hook points) rather than
  forking `basecamp/omarchy` wholesale. That might apply to Deck support in
  general, not just what I'm building.
- Happy to share findings either way — I've hit a handful of upstream
  `deckarchy` bugs during a real install session (silently no-op curl-pipe
  install, missing Limine detection, a wrong UKI path inherited from Arch's
  stock preset, an AUR-helper conflict, and an ESP permissions issue that
  breaks Omarchy's own Limine-detection script) and plan to file those
  upstream regardless of how this conversation goes.

No pressure or ask beyond: open to comparing notes, and if there's a
lighter integration path than a fork, I'd rather find that out now than
after building one.

Thanks for the work you've already put into this — made my own investigation
much faster having a reference point.

---

## Notes for whoever reviews before sending

- Tone deliberately low-key/no-ask beyond "open to comparing notes" per
  PLAN.md §10.6's framing (open the conversation early, not a formal
  collaboration proposal).
- The pacman-package-not-git-clone point references the finding already
  recorded in `PROGRESS.md` ("Foundational assumption in PLAN.md §4/§5/§10.2
  is wrong" section) — worth double-checking that finding hasn't been
  revised further before this goes out, since it's cited as fact here.
- Fill in venue/handle specifics at send time — deliberately left generic
  above since the actual GitHub username/contact method wasn't verified as
  part of this drafting pass (no network calls were made).

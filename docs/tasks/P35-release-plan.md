# P35 — releasing this thing

**Status:** decisions taken 2026-08-16, nothing executed. Written while P34's
three agents were still running.

## Operator decisions (2026-08-16)

| question | answer |
|---|---|
| audience | **general Deck owners** — someone who wants Omarchy on a Deck without touching a terminal |
| LCD hardware | **state OLED-only, invite LCD reports** — no support claimed, and the gap becomes a contribution path |
| first artefact | **source + build instructions only** |
| internal docs | **trim before going public** |

## ⚠️ The tension in those answers, stated rather than quietly resolved

**"General Deck owners" and "source + build instructions only" point in opposite
directions.** A general Deck owner does not install Docker and run a 40-minute
build. That combination reaches enthusiasts.

Recommended resolution, **not yet approved**: treat source-only as the **first
tag**, not the release. Tag to establish the project, then solve image hosting
before announcing anywhere, and say plainly in the README meanwhile that a
prebuilt image is coming. The README must not imply a general audience it cannot
yet serve.

**The hosting problem is concrete:** GitHub caps release assets at **2 GB per
file**; the ISO is **6,485,413,888 B (6.04 GiB)**. So a hosted image needs split
archives, an external mirror, or a torrent. None is hard; none is free.

## Already true, and it changes the docs question

**The repo is already PUBLIC** (`villenull/Pizzarchy`, verified 2026-08-16).
Every internal record — including every wrong diagnosis and its correction — is
already visible. Trimming is tidying a public record, not deciding what to
expose. Nothing here is a leak; it is a lab notebook someone can already read.

Current scale: `docs/PROGRESS.md` 4,034 lines · `docs/START-HERE.md` 1,691 ·
`docs/PLAN.md` 995 · `docs/findings/` 47 files / 17,042 lines · `docs/tasks/`
25 files / 8,353 lines. **~33,000 lines of internal record.**

⚠️ **A trim is a real risk to this project's working method, not just tidying.**
`CLAUDE.md` points every session at `PROGRESS.md` §7 as the fact base, and this
round alone was saved several times by facts recorded there (the whitelist that
had already been disproved; the `hyprctl keyword` rejection; the console
geometry that caught a bad axis assumption). **Do not delete the record to make
the repo look finished.** Separate the *user-facing* surface from the
*engineering* record instead — a clean `README.md` plus a short `docs/` index,
with the notebook kept where sessions can still find it.

## Blockers before any release

1. **The ISO does not currently build a usable installer.** The console font
   regression (§5.40) is fixed in the tree but **not in any built image** — the
   only ISO that exists has prompts pushed off-screen. A rebuild is required.
2. **First-boot experience** (P34, in flight): the splash does not draw, ~2 min
   of black screen, and Steam's own setup wizard runs after ours. The operator's
   bar is explicit: *"I don't want users to think they just installed an
   unfinished product."* That bar is not met today.
3. **Flicker** on the OSK is still unresolved on hardware (§5.40).
4. **LCD detection** must actually do what the release notes claim.
5. **A README that describes a product**, not a planning repo. The current one
   opens "planning and build repo" and says "Nothing is releasable yet" — both
   correct today.

## What is genuinely ready

Verified on hardware 2026-08-16, from our own ISO: Neptune kernel boots
(`6.11.11-valve29-1-neptune-611`), Gaming Mode runs, **touch works**, **STEAM+Y
closes windows**, **power button suspends and wakes**, **brightness works**,
audio works, Wi-Fi works, Switch-to-Desktop is present, and the whole install is
completable with the controller alone apart from the font regression above.

That is a working product with a rough first ten minutes.

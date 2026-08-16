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

**The hosting problem is concrete:** GitHub caps release assets at **2 GiB per
file**; the ISO is **6,485,413,888 B (6.04 GiB)**. So a hosted image needs split
archives, an external mirror, or a torrent.

## Hosting — DECIDED 2026-08-16

**Internet Archive for the ISO, linked from a GitHub Release that carries the
checksum and the build instructions.** Free, permanent, no size limit, no egress
bill, and it auto-generates a torrent alongside direct HTTP so both exist without
running anything. The GitHub Release stays the front door: tag, notes, sha256,
build instructions, and a link out to the image.

Chosen because it needs **no new engineering** and cannot produce a surprise
bill if the project gets attention. It also does not foreclose anything — adding
a smaller image later changes nothing about where these live.

Rejected, with reasons:

* **GitHub Releases, split into ~4 parts.** Free and keeps everything in one
  place, but a general Deck owner meets `cat`/reassembly and a second checksum
  at exactly the moment they are least tolerant of friction. Wrong cost for the
  chosen audience.
* **Cloudflare R2.** Genuinely good — 10 GB free storage and **zero egress** —
  and the right answer if more control is ever wanted. Needs an account and
  setup that Archive does not, for no benefit today.
* **Torrent only.** No seeders means a dead download. A small project will not
  have them.

⚠️ **Publish the checksum in the GitHub Release, not only beside the image.**
The release is the thing under our control; the mirror is not. A user who
downloads from Archive must be able to verify against a number that lives here.

### The size lever, for later — a netinstall variant

**4.7 GB of the 6.1 GB ISO is the offline package mirror** (1,291 packages,
measured 2026-08-16). **77% of what is being hosted exists so the install works
with no network at all.**

A netinstall image would be roughly **1.4 GB** — under GitHub's 2 GiB cap, so it
could ship as a **single release asset with no external host and no splitting**,
and it would become the default download for the chosen audience.

⚠️ **This is real work, not a build flag.** The offline mirror is load-bearing:
the installer resolves against it twice (`deck-mirror.packages`' own header), it
is bind-mounted for pacstrap and unmounted before genfstab, and "fully offline"
is in the repo's own description. A netinstall path would need a supported
resolve-against-live-repos mode **and its own QEMU coverage**. Scope it properly
before promising it.

Ordering: ship the offline image on Archive first, add netinstall later if the
download friction turns out to matter.

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

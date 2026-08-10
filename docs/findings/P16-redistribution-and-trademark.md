# P16 — Redistribution and trademark check (PROGRESS.md §5.5)

**Session 16, 2026-08-10.** Flagged as "cheap to check early" in the original
plan and never checked. Two separate questions, and only one of them turns out
to have a hard blocker.

> ⚠️ **This is engineering research, not legal advice, and nobody here is a
> lawyer.** It records what the package metadata and Valve's published
> guidelines actually say. The naming decision is the operator's, and if the
> project is ever distributed at scale it deserves a real opinion.

---

## 1. Redistribution — one package is a genuine blocker

Licences of everything this project installs from Valve's repos, read from the
repo databases:

| Package | Licence | Redistributable in an ISO? |
|---|---|---|
| `linux-neptune-611` (+ headers) | `GPL-2.0-only` | ✅ yes, with source offer |
| `linux-firmware-neptune` | `GPL-2.0-only`, `GPL-2.0-or-later`, `GPL-3.0-only`, `custom` | ⚠️ mixed, but ships a full `LICENCE.*` set — the ordinary linux-firmware posture every distro ISO is already in |
| `gamescope` | `MIT` | ✅ yes |
| `jupiter-hw-support` | `MIT` | ✅ yes *(skipped anyway — §5.15)* |
| `holo-plymouth-themes` | `GPL-2.0-or-later` | ✅ yes |
| `steam-jupiter-stable` | `custom` (Steam Subscriber Agreement) | ⚠️ Steam's own terms; installers normally *fetch* it |
| **`steamdeck-dsp`** | **`Proprietary`** | ❌ **NO** |

### `steamdeck-dsp` is the problem, and we install it deliberately

`src/omarchy-deck-kernel.sh` installs it alongside the kernel. It is:

- **`Licenses: Proprietary`**, and it ships **no licence text at all** —
  `/usr/share/licenses/steamdeck-dsp/` does not exist on the Deck.
- 116 files, 721 KiB: the SOF DSP topology
  (`/usr/lib/firmware/amd/sof-tplg/sof-vangogh-nau8821-max.tplg`) plus
  WirePlumber config. This is the Deck's **speaker tuning** — the thing that
  makes audio sound correct rather than tinny.

Bundling it into an ISO would be redistributing a proprietary blob with no
grant to do so, which is precisely what `CLAUDE.md`'s "don't depend on anything
unlicensed" constraint exists to prevent.

### But the question is contingent on a T5 decision nobody has made

**Does the ISO *bundle* Valve's packages, or *configure Valve's repos and fetch
them at install time*?**

- **Bundling** = we redistribute → `steamdeck-dsp` blocks it.
- **Fetching** = the user's machine downloads from Valve's own mirror → we
  redistribute nothing, and the question evaporates.

§3.3 recorded "the offline mirror can carry Valve packages — no signing step
needed", but that was written while the ISO was meant to be fully offline.
**§2.2 retired the offline constraint**, so fetching is now permitted and is the
obvious answer.

**Recommendation: fetch, don't bundle.** It sidesteps the proprietary problem
entirely, keeps the ISO smaller, and matches how every Arch derivative handles
third-party repos. If bundling is ever revisited, `steamdeck-dsp` has to be
resolved first — and losing it means losing the Deck's speaker tuning, so
"just drop it" is not free.

---

## 2. Trademark — the logo is clearly out; the name is a judgement call

From Valve's Steam Deck brand guidelines (April 2022), which open by scoping
themselves to materials produced **"with permission under contract with Valve
Corporation"** — a contract this project does not have.

What the guidelines state plainly:

- Branding may not be used so as to imply that non-Valve materials are
  "sponsored, endorsed, licensed by, or affiliated with" Steam Deck.
- Use **only Valve-approved artwork**; the logos "must stand alone and may not
  be combined with any object", including other words and graphics.
- Valve reserves the right to object, and to approve any communication using
  the brand before distribution.
- The logo requires the ™ and a specified legal attribution.

### What follows for this project

| Item | Position |
|---|---|
| **Steam Deck logo / the "Dumpling"** | ❌ **Do not use**, anywhere — ISO, README, installer UI, repo avatar. This one is unambiguous. |
| **Valve's own button-glyph artwork** (`docs/PLAN.md` §6.1 wants Deck glyphs in the installer) | ❌ **Do not lift Valve's assets.** Draw generic glyphs instead — lettered circles for A/B/X/Y, a plain D-pad. Costs an afternoon and removes the question. |
| **The words "Steam Deck" used descriptively** ("an installer for the Steam Deck") | ⚠️ **Operator's call.** The guidelines address *branding by partners*, not descriptive use by unaffiliated projects, so they neither permit nor forbid it. Common open-source practice is descriptive use plus a visible disclaimer. |
| **"Steam Deck" in the project *name*** | ⚠️ Riskier than descriptive use — a name is where implied affiliation lives. The project is currently "Omarchy Deck", which does not contain it. **Recommend keeping it that way.** |
| **Disclaimer** | ✅ Cheap and directly answers the one explicit prohibition. Add to the README: not affiliated with, endorsed or sponsored by Valve; Steam Deck is Valve's trademark. |

### Concrete actions (none taken — all are outward-facing)

1. Add an affiliation disclaimer to the README before any public release.
2. Keep the project name free of "Steam Deck".
3. Draw our own button glyphs for T4's installer rather than using Valve's.
4. Decide fetch-vs-bundle in **T5/P2.7**; recommend fetch.

None of these were executed here — publishing and naming are operator
decisions, and `docs/START-HERE.md` §3 puts any public action behind approval.

---

## Sources

- [Steam Deck Brand Guidelines (Steamworks)](https://partner.steamgames.com/doc/steamdeck/brandguidelines)
- [Steam Deck brand guidelines PDF, 2022-04-29](https://shared.fastly.steamstatic.com/community_assets/images/steamworks_docs/english/steamDeck_guidelines_042922.pdf)
- [Steam Branding Guidelines (Steamworks)](https://partner.steamgames.com/doc/marketing/branding)
- Package licences: `jupiter-staging` / `holo-staging` repo databases, and
  `pacman -Qi` on the Deck.

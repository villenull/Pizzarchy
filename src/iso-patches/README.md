# `src/iso-patches/` — patches against the ISO *builder*, staged until T5 wires them

Patches here modify files in `omacom-io/omarchy-iso` (the ISO builder tree),
as distinct from `src/omarchy-deck-patches/`, which patches the **installed
runtime** at pacman time (T12).

## 🔴 Why they are staged here and not in `iso/overlay/patches/`

`iso/bin/build` applies **every** `overlay/patches/*.patch` it finds. Dropping
one there takes effect on the very next build — and `docs/tasks/T5-fork-plan.md`
§7 is explicit:

> **Do not start T5c before T5a proves parity.** An overlay whose base build was
> never shown to reproduce the known-good ISO cannot attribute any later failure.

**Parity is not proven yet.** `docs/findings/T5a-parity.md` found the pipeline
reproduces the reference almost exactly but the artifact is broken (it bundles a
runtime missing `omarchy-setup-system`, so it dies at phase 5 of 14), and the
`--local-source` build that should fix it has not reported. Adding overlay
content now would mean the next parity measurement compares a *patched* build
against the reference and cannot attribute a difference to either cause.

`test/unit/test-iso-build.sh` enforces the empty overlay, and it caught this
within minutes of the first patch landing.

## Moving one into place

When T5's slice is ready **and parity is proven**, `git mv` the patch into
`iso/overlay/patches/` and update `test-iso-build.sh`'s empty-overlay assertion
in the same commit — the assertion is the record of *why* the overlay was empty,
so retiring it deliberately is the point at which that reason expires.

| Patch | Applies to | Owner |
|---|---|---|
| `omarchy-install-dashboard.patch` | `configs/airootfs/usr/local/bin/omarchy-install-dashboard` | T4a — sources `deck-dashboard.sh` so S6/S7/S8 exist at all |

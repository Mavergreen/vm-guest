# 0012 — The version scheme is the family's self-upstream branch, not a deviation

Date: 2026-09-24
Status: accepted

`decisions/0007`'s deviations table says *"version scheme is not
`<upstream>-mavericks.N`"* and gives the reason: OpenCore, EDK II, QEMU and
Apple's 10.9.5 move independently, so there is no single upstream to name
in the suffix. That is correct as far as it goes, and it stops one step
short — it reads as "we do not use the family's scheme" when the more
accurate claim is "we use a branch of it the family already has a name
for." This ADR narrows that claim; it does not edit `0007`, which is the
user's product decision and stands as written.

## What changed

Nothing about the product. What changed is what was read: the
`mavergreen-conventions` skill's **Versioning** section opens by asking
whether a repository *ports an external upstream* or *is its own
upstream*. `0007` answered the first question — there is no single
external upstream — and stopped there. The skill answers the second case
itself: a self-upstream repository drops the `-mavericks` suffix and
versions itself directly, with `YYYYMMDD.N` named as the family's date
form "precisely because it is not a port". `mavericks-porthole` is the
date instance; `mavericks-magic-trackpad2` is the semver instance.
**INHERITED**, not re-measured here: `docs/superpowers/plans/2026-09-22-shipping-vmavs.md`
already read this directly from `mavericks-porthole/UPSTREAM_VERSION`
(`20260802`) and its `release.yml` `ver` step, 2026-09-22, before this ADR
existed. This ADR carries that finding forward rather than re-verifying
it against the sibling repository a second time.

`bin/vmavs` is this product's own upstream — there is no external project
whose releases it repackages — so it takes that branch rather than sitting
outside the scheme.

## Decision

**`YYYYMMDD.N`, unchanged from what `build/version.sh` already computes.**
`UPSTREAM_VERSION` holds a bare eight-digit date, hand-bumped by a human
when the tool itself has changed enough to ship. `VERSION` is
`<date>.<n>`, a gitignored build product, never committed. The git tag is
the full version, always written with the `.N`, never omitted.

Two axes, mirroring the family's `<upstream>-mavericks.N` exactly, with
our own date line standing in for the upstream release:

| Axis | Moves when | Effect |
|---|---|---|
| The **date** (`UPSTREAM_VERSION`) | A human decides the tool itself changed enough to ship — a new subcommand, a fixed stage, a portability fix. Hand-bumped; there is no Renovate datasource, because there is nothing external to track. | `N` resets to 1. |
| **`N`** | Anything else that warrants a release with the tool's own code unchanged — most importantly an ingredient bump (`INGREDIENTS.md`'s `## Declared state`). | `N+1` on the same date-line. |

The date is not the release date. It is the tool's own version line, and
`N` counts every release cut on that line, including ingredient-only
repackages — `20260922.4` can mean "the fourth release of the `20260922`
tool", cut in November because Renovate moved the OpenCore pin. That is
exactly the semantics `<upstream>-mavericks.N` has when the upstream axis
is us.

## `bin/vmavs version`: a checkout recomputes, an installed tree reads the file

A checkout (has `.git`) always calls `build/version.sh auto` rather than
trusting a `VERSION` file that might already be sitting there. This is
deliberate, not an oversight: `build/version.sh` writes `VERSION` on
**every** call it makes, so a checkout that instead trusted a pre-existing
`VERSION` file would freeze at whatever was first computed and never move
again as tags accumulate. An installed tree has no `.git` and nothing for
`build/version.sh` to query, so there `VERSION` beside `bin/vmavs` is the
only source of truth, and packaging's job is to have put it there.
Neither path may print an empty string — a version that is silently blank
is how an artifact ships labelled with nothing in front of the dot.

## Why not the family's shared scripts

`scripts/version.sh` and `resolve-version.sh` are not usable here: both
hardcode the literal `-mavericks.` in the version string they build, which
is the port shape. `mavericks-porthole` solves the same problem with
eleven lines of shell inlined in its `release.yml`. `build/version.sh` is
a committed script instead, for one reason worth stating on its own:
inline YAML cannot be tested, and this repository tests things
(`tests/version.bats`).

## Consequences

- **`INGREDIENTS.md`'s `version-scheme:` deviation narrows.** It no longer
  reads as a bare refusal ("we do not use the family's scheme") but names
  the shape actually taken — the self-upstream branch, same as
  `mavericks-porthole` — and points here for the reasoning. Scoped to
  `bin/vmavs`, `image/build-image.sh` and `vm/*.sh`: the host-side tool is
  one product across those files, and a deviation scoped to only one of
  them would quietly license the rest to drift.
- **The ingredient registry and the version scheme now meet at the same
  doctrine: a release is a declared state, not an event.**
  `INGREDIENTS.md`'s `## Declared state` section lists the inputs whose
  movement should cut a release — `vendor/sources.tsv`,
  `components/openssh/version`, `boot/config/config.plist`, and exactly
  one entry named `upstream` pointing at `UPSTREAM_VERSION` — deliberately
  a subset of the full ingredient registry, so that `bats` moving never
  cuts one.
- **This is why `INGREDIENTS.md`'s `repackage-on-ingredient-bump` section
  ("no caller declared, and a narrower reason than it used to be") no
  longer says the caller does not apply here.** The argument it used to
  make was correct for a world with no release, and a release is now a
  declared state away rather than an abstraction. See `INGREDIENTS.md`
  for the rewrite.
- **Nothing here schedules `release.yml`.** It does not exist yet — Phase C
  (release packaging and distribution) is designed but deliberately
  unscheduled, and P10 is blocked on P9, which is itself blocked on a
  decision. `build/version.sh` and this scheme are usable the moment
  `release.yml` is written; nothing about them is provisional.

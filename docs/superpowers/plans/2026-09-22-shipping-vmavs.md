# Shipping `vmavs` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn eleven working scripts into one documented command, `vmavs`, that a stranger can run — with a version it can report, a README that answers "what is this" in thirty seconds, and a release path that is structurally incapable of publishing Apple's bytes.

**Architecture:** `bin/vmavs` is a dispatcher, not a rewrite. Every subcommand in `decisions/0007` already exists as a script that works and is tested; `vmavs` gives them one name, one help, one version and one front door, and the scripts stay exactly where the suite (574 tests as of 2026-09-22), the ADRs and `NOTES.md` say they are. Two genuinely new pieces: `vmavs ssh` (twelve lines of `ssh` flags that everyone currently retypes) and `vmavs emit packer` (the one interop artifact worth having, because a single Packer template covers QEMU, VirtualBox, VMware and Proxmox and its `vagrant` post-processor makes the boxes). Versioning takes the family's **self-upstream** shape — `YYYYMMDD.N`, the same as `mavericks-porthole` — which turns out to be a smaller deviation than `decisions/0007` assumed.

**Tech Stack:** bash 3.2 (the floor `bin/bash32-check.sh` enforces), bats-core, `python3` for the Packer emitter's structural tests, `git` for the version counter. No new host dependency is introduced by this plan.

**Spec:** `docs/superpowers/specs/2026-09-17-mavericks-guest-design.md` §6, phase **P8** (added in the same pass that produced this plan). The product decision it implements is `docs/decisions/0007-what-this-project-ships.md`. Read also `INGREDIENTS.md` (what a bump does here), `docs/configuration-register.md` (the MEASURED / INHERITED / REASONED discipline this plan is held to), and the `modernmavericks-conventions` skill's **Versioning** and **Release workflow** sections.

## Global Constraints

Copied verbatim from the spec §3 and `decisions/0007`. Every task's requirements implicitly include these.

- **The OS comes from Apple only.** Firmware and bootloaders may be third-party; macOS disk images may not.
- **Never publish the guest image or a snapshot.** Not as a release asset, not as a public package, not anywhere reachable without authentication. A release path that uploads artifacts must be *incapable* of shipping Apple's bytes, not merely careful about it.
- **`./bin/run-tests.sh` green**, including `bin/tier-check.sh --strict` and `bin/bash32-check.sh`. Both are mandatory, not optional.
- **bash 3.2 only.** No `mapfile`, no `declare -A`, no `${x^^}`, no `readlink -f`. The floor binds against what Apple shipped in `/bin` on 10.9 (`decisions/0007`, Decision 3).
- **No root, no sudo. Install nothing.** Ask before touching anything outside this directory.
- **Every claim is MEASURED, INHERITED or REASONED, and says which.** Where something has never been tested, write that. `docs/configuration-register.md` explains why the three words are not interchangeable; four inherited claims in this project have already been proven wrong.
- Commit messages end with:
  `Co-Authored-By: <your model name> <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01FoKSUe9s8WEdm1b1P4epUx`

---

## Read this before Task 1: three facts that change the plan's shape

**1. `renovate.json` is not missing.** This plan was commissioned on the understanding that `renovate.json` had to be written. It already exists, tracked, at `.github/renovate.json` — 88 lines, four custom managers (OpenSSH with the `regex:` versioning that captures `-mavericks.N`, OpenCore, Lilu and VirtualSMC with the `autoReplaceStringTemplate` the twice-in-one-URL shape needs), and one `packageRules` entry turning automerge off for the boot stack *with a `description` saying why* — which is exactly what family-conventions check 4b requires. Verified by reading the file, 2026-09-22. **There is no Renovate task in this plan.** What *is* missing from release machinery is `.github/workflows/release.yml`, `UPSTREAM_VERSION`, `build/version.sh` and `release-notes/`; three of those are Task 1 and Phase C.

**2. The ordering changed mid-plan, and it changes the content, not just the sequence.** The user's words: *"After CLI exists, build VM, and then maybe we have release-worthy stuff to package."* So the work is **CLI → build VM → release packaging**. This matters because §4 of the commission asked how a shell program with forty-odd host dependencies gets installed — and `docs/superpowers/specs/2026-09-21-build-in-a-linux-vm-design.md` §9.1 states, as its headline portability number, that the host tool list shrinks **from 36 to about 7**. Designing a distribution story around a dependency list we are about to delete would bake the current list into packaging metadata. **The distribution question is therefore left open, deliberately, in Phase C**, with both candidate worlds written down and neither chosen.

**3. Another agent is concurrently implementing `--updates security` (task #40).** It owns `image/build-image.sh`, `vendor/sources.tsv`, `INGREDIENTS.md`, `image/payload/` and `media/build-installer-img.sh`. **This plan touches two of those files, in exactly two places:** Task 8 adds one line to `image/build-image.sh`, and Task 11 edits `INGREDIENTS.md`. Both tasks say so at the top and both must be rebased onto task #40's work rather than started before it. Every other task in this plan touches files outside that set.

---

## What shipping does NOT require

Written down so scope does not creep. Each of these is a real piece of work that someone could reasonably think belongs here. None of them does.

| Out | Why it is out |
|---|---|
| **P5 — interactive performance** | Deferred by the user's choice, not by sequencing: the guest is "working fine enough". `decisions/0007` also says P5 measures Product A's `run`, so P5 *wants* shipping to have happened first. |
| **P6 — the GitHub Actions runner** | An entirely separate phase with its own runner budget, snapshot round-trip risk and CPU-gating experiments. Nothing in it is needed to hand someone a command. |
| **P9 — the build VM** | Its spec exists and its direction is approved; its **design** is not adopted. It sits *between* this plan and release packaging, and it carries its own abandon thresholds (below). This plan neither implements it nor assumes it. |
| **The arm64 experiment** (`ARM64-EXPERIMENT.md`) | Research. |
| **Snow Leopard and Tiger guests** | `decisions/0007` records the want and forbids designing for it: *"do not add a 10.6 or 10.4 branch to anything until there is a 10.6 or 10.4 guest to test it against."* |
| **Emitters other than Packer** — libvirt XML, `.utm`, Proxmox config, Vagrant box, container recipe | One Packer template covers QEMU, VirtualBox, VMware and Proxmox, and its `vagrant` post-processor makes the boxes. Building four more emitters to reach the same targets is duplicated work. `emit` stays a subcommand with room for them. |
| **Product B's split to `mavericks-vm-guest-additions`** | `decisions/0007`'s exit condition is "a second guest-side component ships". None has. |
| **The 10.9 `.pkg` for the host-side tool** | `decisions/0007` Decision 3 names its blocker precisely: running our tool on 10.9 needs *a QEMU on 10.9*, which depends on `vm-host` shipping the prepackaged QEMU. `vm-host` has no git remote. |
| **The repository rename** (`mavericks-qemu-guest` → `mavericks-vm-guest`) | Moving the working directory and renaming a GitHub repo both reach outside this directory. `decisions/0007` already parks it on the user. The command is `vmavs` regardless of what the directory is called. |
| **A Homebrew tap** | Recorded as a want in Phase C. It covers neither NetBSD nor 10.9, so it adds a packaging system rather than replacing one. |

---

## File structure

| Path | Responsibility | New? |
|---|---|---|
| `UPSTREAM_VERSION` | This product's own version line: a bare `YYYYMMDD`, hand-bumped. One line, no newline drama. | **new** |
| `build/version.sh` | `build/version.sh <auto\|local>` → `FULL=`/`TAG=`/`RELEASE=`. The whole version scheme, in one testable script. | **new** |
| `bin/vmavs` | The dispatcher. Subcommand table, `help`, `version`, symlink-safe root resolution. Nothing else — every subcommand's work lives in the script that already does it. | **new** |
| `vm/ssh.sh` | `vmavs ssh`: the `ssh` flags a throwaway clone needs, with `--dry-run`. | **new** |
| `emit/packer.sh` | `vmavs emit packer`: one HCL2 template from one profile plus one manifest. | **new** |
| `lib/preconditions.sh` | Gains `vmavs_tools_for <subcommand>` — the per-subcommand tool lists `doctor` reports against. | modified |
| `lib/common.sh` | Gains `vmavs_hint` — the one-line pointer a directly-invoked script prints when a human is watching. | modified |
| `bin/preconditions.sh` | Becomes `doctor`'s implementation: per-subcommand readiness, and honest about non-Linux hosts instead of crashing on them. | modified |
| `bin/tier-check.sh` | Learns that `emit/` is part of the shipped path. | modified |
| `image/build-image.sh`, `bin/triangulate.sh`, `vm/run.sh`, `vm/clone.sh`, `vm/golden.sh`, `image/compare-images.sh` | One `vmavs_hint` call each. Otherwise untouched. | modified (1 line) |
| `README.md` | Product documentation. Currently a lab notebook. | rewritten |
| `INGREDIENTS.md` | `## Declared state`; the version-scheme deviation narrowed to what it actually is. | modified |
| `docs/decisions/0012-version-scheme.md` | Why `YYYYMMDD.N`, and why the `decisions/0007` deviation row was wider than the facts. | **new** |
| `tests/version.bats`, `tests/vmavs.bats`, `tests/doctor.bats`, `tests/emit.bats` | Tests for the above. | **new** |

`libexec/` does not appear in that table. See the next section.

---

## Two decisions the plan makes, with their reasons

### Where `vmavs` lives, and what happens to `./image/build-image.sh`

**Decision: `bin/vmavs` dispatches to the scripts where they already are. Nothing moves to `libexec/`.**

The case for `libexec/` is real — it is the conventional way to say "this is an implementation detail, not a public entry point", and it makes an installed tree obviously separable into "one thing on `PATH`" and "everything else". Three reasons it loses anyway:

1. **It buys a convention and costs a migration.** Measured, 2026-09-22, by `grep -c` across the tree: `image/build-image.sh` is named in 26 places in `NOTES.md`, 25 in `docs/`, 11 shell scripts and 6 test files; `vm/run.sh` in 30 doc places; `vm/clone.sh` in 21; `bin/triangulate.sh` in 28. Eight scripts carry roughly 150 references between them. A rename edits every one or leaves them wrong.
2. **`NOTES.md` is append-only and must keep meaning what it said.** It is the lab log — the record of what command was run on what date and what happened. A path rewrite inside it would be a falsification; a path *not* rewritten would be a dangling reference. `libexec/` creates that dilemma for 26 entries and solves nothing.
3. **The directory names are the documentation.** `boot/`, `media/`, `image/`, `vm/` are the spec's §5.1 repository layout, and they say what each script is *for*. `libexec/` flattens four meanings into one bucket whose only meaning is "not on `PATH`".

And the thing `libexec/` was actually wanted for is delivered another way: **an installed tree puts the whole checkout under a libdir and one `vmavs` in bindir.** By position, `boot/`, `image/`, `media/` and `vm/` are then already libexec, without a rename. `bin/vmavs` resolves its own root through symlinks (Task 2, Step 3) precisely so that works.

**Decision: both entry points keep working. The direct scripts stop being documented and become internal.**

The commission offered three choices — deprecation path, clean break, both supported. The honest answer is that **the direct scripts cannot be deprecated, because `vmavs` calls them.** `vmavs image` *is* `image/build-image.sh`. There is no version of this where the file stops working. So the only question actually available is whether it is *documented*, and the answer is no:

- **There are no external users to break.** `decisions/0007` states it plainly: neither repository has a git remote, there is no published name, no release and no package for anyone to depend on.
- **There are 574 internal users** (the suite, counted 2026-09-22), and they must not break. Every test invokes the scripts directly and keeps doing so.
- So: the scripts work, `vmavs` is what the docs say, and a human who types the old command gets a one-line pointer — printed only when stderr is a terminal, which is exactly what keeps the suite green (Task 8).

No removal date is set, because setting one for a command with no users would be theatre.

### The version scheme, and why the declared deviation is narrower than `decisions/0007` thought

**Decision: `YYYYMMDD.N`.** `UPSTREAM_VERSION` holds a bare eight-digit date, hand-bumped. `VERSION` is `<date>.<N>`, a gitignored build product, never committed. The git tag is the full version. N counts releases on that date-line, starting at `.1` and never omitted.

**This is not a deviation from the family. It is the family's self-upstream branch.** `decisions/0007` declared *"version scheme is not `<upstream>-mavericks.N`"* on the grounds that there is no single upstream — which is correct as far as it goes, and it stops one step short. The `modernmavericks-conventions` skill's **Versioning** section opens by asking whether a repo *ports an external upstream* or *is its own upstream*, and answers the second case itself: a self-upstream repo **drops the `-mavericks` suffix** and versions itself directly, with `YYYYMMDD.N` named as the family's date form "precisely because it is not a port". `mavericks-porthole` is the instance; `mavericks-magic-trackpad2` is the semver instance. Verified by reading `mavericks-porthole/UPSTREAM_VERSION` (`20260802`) and its `release.yml` `ver` step, 2026-09-22.

So Product A is not an exception the family tolerates; it is a shape the family already has. The deviation row in `INGREDIENTS.md` narrows accordingly (Task 11) — from "we do not use the family's scheme" to "we take the self-upstream branch of it, because the thing being versioned is our own code and not somebody else's release".

**What bumps it.** Two axes, mirroring the family's two exactly, with our date standing in for the upstream:

| Axis | Moves when | Effect |
|---|---|---|
| The **date** (`UPSTREAM_VERSION`) | A human decides the tool itself has changed enough to ship — a new subcommand, a fixed stage, a portability fix. Hand-bumped; there is no Renovate datasource, because there is nothing external to track. | N resets to 1. |
| **N** | Anything else that warrants a release with the tool unchanged — most importantly an **ingredient bump**. | N+1 on the same date-line. |

That second row is the one a reader gets wrong, so state it: **the date component is not the release date. It is the tool's own version line, and N counts every release on that line, including ingredient-only repackages.** `20260922.4` means "the fourth release of the 20260922 tool", which may have been cut in November because Renovate moved OpenCore. This is precisely the semantics of `-mavericks.N` with the upstream axis being us.

**How the ingredient-bump machinery interacts with it — and where `INGREDIENTS.md` has to change its mind.** `INGREDIENTS.md` currently argues, at length and correctly *for the world it was written in*, that `repackage-on-ingredient-bump` does not apply here: the caller's job is to ship a new artifact carrying the new ingredient, and we publish no artifact. That argument was written when there was no release at all. **Once a release exists, we do publish an artifact — the recipe — and the recipe is exactly what a moved pin changes.** Somebody who installed `vmavs` at last month's release builds last month's OpenCore. That is staleness in the only sense a published thing can have it, and the family's machinery is the fix.

So the version scheme and the ingredient registry meet at the family's release doctrine: **a release is a declared state, not an event.** `INGREDIENTS.md` gains a `## Declared state` section (Task 11) listing the inputs whose movement should cut a release — `vendor/sources.tsv`, `components/openssh/version`, `boot/config/config.plist`, and exactly one entry named `upstream` pointing at `UPSTREAM_VERSION`. An ordinary commit moves none of them and publishes nothing; a Renovate PR that moves a pin renders a different digest and cuts `N+1`.

**Three things that do not change.** The per-stage input hashes from task #36 stay exactly as they are — they answer "would my next build rebuild the firmware", which is a different question from "should a release be cut" and is asked far more often. `bin/image-staleness.sh` stays — a moved pin still silently invalidates every golden already on disk, and that remains true whether or not anything was published. And `INGREDIENTS.md`'s prose registry stays authoritative for *everything baked in*; `## Declared state` is deliberately a subset of it, because `bats` moving must never cut a release.

---

## Phase A — the front door

### Task 1: `UPSTREAM_VERSION` and `build/version.sh`

**Files:**
- Create: `UPSTREAM_VERSION`, `build/version.sh`
- Modify: `.gitignore`
- Test: `tests/version.bats`

**Interfaces:**
- Produces: `sh build/version.sh <auto|local>` writes three lines to stdout — `FULL=<date>.<n>`, `TAG=<date>.<n>`, `RELEASE=<yes|no>` — and writes `<date>.<n>` to `$MAVERICKS_ROOT/VERSION`. Task 2 (`vmavs version`) and Phase C's `release.yml` both call it.

This is first because the CLI must be able to report a version, and because it is the one piece of release machinery the build VM does not block.

The family's shared `scripts/version.sh` and `resolve-version.sh` are **not** usable here: they hardcode the literal `-mavericks.` in the version they build, which is the port shape. `mavericks-porthole` solves this with eleven lines of shell inline in `release.yml`. We write the same logic as a committed script instead, for one reason worth stating: **inline YAML cannot be tested, and this repository tests things.** Family-conventions check 7c requires `build/version.sh` to be committed and not git-ignored, which this satisfies; check 7 requires `VERSION` to be untracked, which the `.gitignore` line satisfies.

The `auto`/`local` semantics are the family's, unchanged: `auto` → `N=1`/`RELEASE=yes` for a version line with no tag yet, else the current N and `RELEASE=no`; `local` → `N=max+1`/`RELEASE=yes`, a repackage.

- [ ] **Step 1: Write the failing test**

Create `tests/version.bats`:

```bash
#!/usr/bin/env bats
#
# The version scheme: YYYYMMDD.N, the family's self-upstream shape.
# See docs/decisions/0012-version-scheme.md for why this and not
# <upstream>-mavericks.N.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # A throwaway repository, so tags can be planted without touching ours.
    DIR="$BATS_TEST_TMPDIR/vt"
    mkdir -p "$DIR/build"
    cp "$REPO/build/version.sh" "$DIR/build/"
    printf '20260922\n' > "$DIR/UPSTREAM_VERSION"
    git -C "$DIR" init -q
    git -C "$DIR" config user.email t@example.invalid
    git -C "$DIR" config user.name t
    git -C "$DIR" add -A
    git -C "$DIR" -c commit.gpgsign=false commit -qm first
}

tag() { git -C "$DIR" tag "$1"; }
ver() { ( cd "$DIR" && sh build/version.sh "$1" ); }

@test "a version line with no tag yet is .1, and it releases" {
    run ver auto
    [ "$status" -eq 0 ]
    [[ "$output" == *"FULL=20260922.1"* ]]
    [[ "$output" == *"TAG=20260922.1"* ]]
    [[ "$output" == *"RELEASE=yes"* ]]
}

@test "auto on an already-released line reports that version and does NOT release" {
    tag 20260922.1
    run ver auto
    [ "$status" -eq 0 ]
    [[ "$output" == *"FULL=20260922.1"* ]]
    [[ "$output" == *"RELEASE=no"* ]]
}

@test "local cuts the next N and releases -- this is the ingredient-bump path" {
    tag 20260922.1
    run ver local
    [ "$status" -eq 0 ]
    [[ "$output" == *"FULL=20260922.2"* ]]
    [[ "$output" == *"RELEASE=yes"* ]]
}

@test "N is compared numerically, not lexically" {
    # The bug this catches: .10 sorting before .2, so the eleventh release
    # of a day silently reuses .3. sort -V is not available on 10.9
    # (check-shell-portability.sh), so the comparison is arithmetic.
    tag 20260922.1
    tag 20260922.2
    tag 20260922.10
    run ver local
    [[ "$output" == *"FULL=20260922.11"* ]]
}

@test "tags from another date-line are not counted" {
    tag 20260801.7
    run ver auto
    [[ "$output" == *"FULL=20260922.1"* ]]
    [[ "$output" == *"RELEASE=yes"* ]]
}

@test "a tag with a non-numeric suffix is ignored rather than breaking the count" {
    tag 20260922.1
    tag 20260922.rc1
    run ver local
    [ "$status" -eq 0 ]
    [[ "$output" == *"FULL=20260922.2"* ]]
}

@test "VERSION is written, and is what FULL says" {
    run ver auto
    [ -f "$DIR/VERSION" ]
    run cat "$DIR/VERSION"
    [ "$output" = "20260922.1" ]
}

@test "an empty UPSTREAM_VERSION fails loudly and names the file" {
    # The family's rule: artifacts named with nothing in front look almost
    # right. "20260922." with no N is the same defect one axis over.
    : > "$DIR/UPSTREAM_VERSION"
    run ver auto
    [ "$status" -ne 0 ]
    [[ "$output" == *"UPSTREAM_VERSION"* ]]
}

@test "a malformed UPSTREAM_VERSION fails loudly and shows what it read" {
    printf '1.2.3\n' > "$DIR/UPSTREAM_VERSION"
    run ver auto
    [ "$status" -ne 0 ]
    [[ "$output" == *"1.2.3"* ]]
    [[ "$output" == *"YYYYMMDD"* ]]
}

@test "an unknown mode is refused rather than guessed at" {
    run ver sometimes
    [ "$status" -ne 0 ]
    [[ "$output" == *"auto"* ]]
    [[ "$output" == *"local"* ]]
}

@test "VERSION is a build product and is not committed" {
    # Family-conventions check 7. A committed VERSION drifts from the tags
    # and makes the tag==VERSION release path impossible to satisfy.
    run git -C "$REPO" ls-files VERSION
    [ -z "$output" ]
    run grep -c '^/VERSION$' "$REPO/.gitignore"
    [ "$output" = "1" ]
}

@test "UPSTREAM_VERSION in this repository is a bare eight-digit date" {
    run cat "$REPO/UPSTREAM_VERSION"
    [[ "$output" =~ ^[0-9]{8}$ ]]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/version.bats`
Expected: every test FAILs — `build/version.sh` does not exist, so `cp` in `setup` fails first.

- [ ] **Step 3: Write `UPSTREAM_VERSION` and the `.gitignore` line**

```bash
printf '20260922\n' > UPSTREAM_VERSION
printf '\n# VERSION is a build product: build/version.sh writes it, the tags\n# are the record. A committed copy drifts (family-conventions check 7).\n/VERSION\n' >> .gitignore
```

- [ ] **Step 4: Write `build/version.sh`**

```bash
#!/usr/bin/env bash
# The version scheme: YYYYMMDD.N.
#
# spec: docs/decisions/0012-version-scheme.md
#
# This product is its OWN upstream -- it is not a repackage of somebody
# else's release -- so it takes the family's self-upstream shape
# (mavericks-porthole, mavericks-magic-trackpad2) and drops the
# -mavericks suffix, which has no slot to fill. UPSTREAM_VERSION holds
# this product's own version line as a date; N counts the releases cut
# on that line, INCLUDING ingredient-only repackages. So the date is not
# the release date -- it is the version line's name.
#
# The family's shared scripts/version.sh and resolve-version.sh are not
# usable here: both hardcode the literal "-mavericks." that the port
# shape needs. mavericks-porthole inlines the equivalent logic in its
# release.yml; ours is a committed script instead, so that it can be
# tested (tests/version.bats).
set -eu

MAVERICKS_ROOT=${MAVERICKS_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
export MAVERICKS_ROOT

mode=${1:-}
case $mode in
    auto|local) ;;
    *) printf 'version.sh: usage: version.sh <auto|local>\n' >&2
       printf '  auto   this version line, releasing only if it has no tag yet\n' >&2
       printf '  local  the next N on this line, always releasing (a repackage)\n' >&2
       exit 2 ;;
esac

uv=$MAVERICKS_ROOT/UPSTREAM_VERSION
[ -f "$uv" ] || { printf 'version.sh: no %s\n' "$uv" >&2; exit 1; }

base=$(tr -d '[:space:]' < "$uv")
if [ -z "$base" ]; then
    printf 'version.sh: %s is empty -- it must hold this product'"'"'s own version line as YYYYMMDD\n' "$uv" >&2
    exit 1
fi
case $base in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
    *) printf 'version.sh: %s reads "%s"; it must be a bare YYYYMMDD date\n' "$uv" "$base" >&2
       exit 1 ;;
esac

# The highest N already tagged on this line. Arithmetic, not sort -V:
# sort -V is one of the two constructs shipyard shipped that the 10.9
# base system lacks (check-shell-portability.sh), and lexical comparison
# would put .10 before .2.
maxn=0
for t in $(git -C "$MAVERICKS_ROOT" tag --list "$base.*" 2>/dev/null); do
    n=${t##*.}
    case $n in
        ''|*[!0-9]*) continue ;;
    esac
    [ "$n" -gt "$maxn" ] && maxn=$n
done

if [ "$mode" = local ]; then
    n=$((maxn + 1)); release=yes
elif [ "$maxn" -eq 0 ]; then
    n=1; release=yes
else
    n=$maxn; release=no
fi

full="$base.$n"
printf '%s\n' "$full" > "$MAVERICKS_ROOT/VERSION"
printf 'FULL=%s\nTAG=%s\nRELEASE=%s\n' "$full" "$full" "$release"
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/version.bats`
Expected: 12 PASS.

- [ ] **Step 6: Run the whole suite**

Run: `./bin/run-tests.sh`
Expected: green, including `bin/bash32-check.sh` — `build/version.sh` uses no bash 4 construct.

- [ ] **Step 7: Commit**

```bash
git add UPSTREAM_VERSION build/version.sh .gitignore tests/version.bats
git commit -m "version: YYYYMMDD.N, the family's self-upstream shape"
```

---

### Task 2: `bin/vmavs` — the dispatcher

**Files:**
- Create: `bin/vmavs`, `tests/vmavs.bats`

**Interfaces:**
- Consumes: `build/version.sh` from Task 1.
- Produces: `bin/vmavs <subcommand> [args…]`; the shell function `vmavs_root` is not exported — every later task's subcommand is a `case` arm inside this file, added by editing `SUBCOMMANDS` and `dispatch()`.

Nothing in this task runs QEMU, fetches anything, or builds anything. It is the table, the help, the version and the root resolution, and each of those has a failure mode worth a test.

The root resolution is the part with a real portability trap. `readlink -f` is GNU; macOS 10.9 and NetBSD do not have it, and this command's whole point is running on all three. The loop below uses one-argument `readlink`, which is portable, and `cd -P`.

- [ ] **Step 1: Write the failing test**

Create `tests/vmavs.bats`:

```bash
#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    VMAVS="$REPO/bin/vmavs"
}

@test "vmavs help lists every subcommand decisions/0007 names" {
    run "$VMAVS" help
    [ "$status" -eq 0 ]
    for c in doctor fetch boot-stack media install clone run ssh emit image; do
        [[ "$output" == *"$c"* ]] || { echo "missing: $c"; false; }
    done
}

@test "no arguments is a usage error, not a silent success" {
    run "$VMAVS"
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage"* ]]
}

@test "an unknown subcommand names itself and lists the real ones" {
    run "$VMAVS" instal
    [ "$status" -eq 2 ]
    [[ "$output" == *"instal"* ]]
    [[ "$output" == *"install"* ]]
}

@test "vmavs version prints the version and nothing else on stdout" {
    run "$VMAVS" version
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [[ "${lines[0]}" =~ ^[0-9]{8}\.[0-9]+$ ]]
}

@test "vmavs --version is the same as vmavs version" {
    a=$("$VMAVS" version)
    b=$("$VMAVS" --version)
    [ "$a" = "$b" ]
}

@test "vmavs finds its repository through a symlink on PATH" {
    # This is how an installed copy works: the tree under a libdir, one
    # symlink in bindir. readlink -f would have been the obvious way to
    # resolve it and is GNU-only -- absent on 10.9 and NetBSD, the two
    # hosts this command exists to reach.
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    ln -s "$VMAVS" "$BATS_TEST_TMPDIR/bin/vmavs"
    run "$BATS_TEST_TMPDIR/bin/vmavs" version
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" =~ ^[0-9]{8}\.[0-9]+$ ]]
}

@test "vmavs finds its repository through a chain of two symlinks" {
    mkdir -p "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
    ln -s "$VMAVS" "$BATS_TEST_TMPDIR/a/vmavs"
    ln -s "$BATS_TEST_TMPDIR/a/vmavs" "$BATS_TEST_TMPDIR/b/vmavs"
    run "$BATS_TEST_TMPDIR/b/vmavs" version
    [ "$status" -eq 0 ]
}

@test "every subcommand in the table has a one-line description" {
    # A table row with no description is how a subcommand ships
    # undocumented: it appears in help as a bare word and nobody notices.
    run bash -c "'$VMAVS' help | sed -n 's/^  \([a-z-]*\) *\(.*\)/\1|\2/p'"
    while IFS='|' read -r name desc; do
        [ -n "$name" ] || continue
        [ -n "$desc" ] || { echo "no description: $name"; false; }
    done <<< "$output"
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/vmavs.bats`
Expected: all FAIL — no such file `bin/vmavs`.

- [ ] **Step 3: Write `bin/vmavs`**

```bash
#!/usr/bin/env bash
# vmavs -- run OS X 10.9 Mavericks in a VM.
#
# spec: docs/decisions/0007-what-this-project-ships.md
#
# This is a dispatcher, not an implementation. Every subcommand below is
# a stage that already existed and was already tested before this file
# did; what was missing was one name to type. The scripts stay where
# they are (docs/superpowers/plans/2026-09-22-shipping-vmavs.md explains
# why they did not move to libexec/), and an installed copy is the whole
# tree under a libdir with one symlink to this file in bindir -- which is
# what the symlink resolution below exists for.
set -euo pipefail

# platform: readlink -f is GNU. Mac OS X 10.9 and NetBSD -- two of the
# three hosts this command targets -- do not have it, so resolve the
# chain by hand with one-argument readlink, which is portable.
_src=${BASH_SOURCE[0]}
while [ -L "$_src" ]; do
    _dir=$(cd -P "$(dirname "$_src")" && pwd)
    _src=$(readlink "$_src")
    case $_src in
        /*) ;;
        *) _src=$_dir/$_src ;;
    esac
done
MQG_REPO_ROOT=$(cd -P "$(dirname "$_src")/.." && pwd)
export MQG_REPO_ROOT
unset _src _dir

# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"
# shellcheck disable=SC2034  # read by log()/warn()/die() at call time
MQG_LOG_PREFIX=vmavs

SUBCOMMANDS="\
doctor|What this host can do, subcommand by subcommand
fetch|Fetch one pinned input: esd (Apple's installer), openssh, updates
boot-stack|Build OpenCore, the guest firmware and the EFI image from pinned source
media|Build bootable installer media from Apple's InstallESD.dmg
install|Create the target disk and let Apple's installer run, unattended
clone|Make a throwaway overlay on a golden image
run|Boot a profile
ssh|Open a shell in a running guest
emit|Write an interop artifact for another tool (today: packer)
image|The whole chain: fetch, build, install, verify, record"

usage() {
    cat <<EOF
usage: vmavs <subcommand> [options]

$(printf '%s\n' "$SUBCOMMANDS" | while IFS='|' read -r s d; do
    printf '  %-11s %s\n' "$s" "$d"
done)

  version     Print this vmavs's version
  help        This

Every subcommand takes --help. Start with:

  vmavs doctor        can this machine do it?
  vmavs image         ~30 minutes, unattended, nobody watching
  vmavs run p4-linuxmedia
  vmavs ssh
EOF
}

version() {
    # An installed copy has a VERSION beside it; a checkout computes one
    # from the tags. Neither is allowed to print an empty string: a
    # version that is silently blank is how an artifact gets shipped
    # labelled with nothing in front of the dot.
    if [ -f "$MQG_REPO_ROOT/VERSION" ]; then
        v=$(tr -d '[:space:]' < "$MQG_REPO_ROOT/VERSION")
    else
        v=$(MAVERICKS_ROOT="$MQG_REPO_ROOT" sh "$MQG_REPO_ROOT/build/version.sh" auto \
            | sed -n 's/^FULL=//p')
    fi
    [ -n "$v" ] || die "cannot determine a version"
    printf '%s\n' "$v"
}

[ $# -gt 0 ] || { usage >&2; exit 2; }

cmd=$1; shift
case $cmd in
    help|-h|--help) usage; exit 0 ;;
    version|--version) version; exit 0 ;;
    *)
        if ! printf '%s\n' "$SUBCOMMANDS" | cut -d'|' -f1 | grep -qx "$cmd"; then
            printf 'vmavs: unknown subcommand: %s\n\n' "$cmd" >&2
            usage >&2
            exit 2
        fi
        die "vmavs $cmd: not wired up yet"
        ;;
esac
```

- [ ] **Step 4: Make it executable and run the tests**

```bash
chmod +x bin/vmavs
bats tests/vmavs.bats
```
Expected: 8 PASS.

- [ ] **Step 5: Run the whole suite and commit**

```bash
./bin/run-tests.sh
git add bin/vmavs tests/vmavs.bats
git commit -m "vmavs: the dispatcher, its help, its version and its root"
```

---

### Task 3: `vmavs doctor` — what this host can do, subcommand by subcommand

**Files:**
- Modify: `lib/preconditions.sh`, `bin/preconditions.sh`, `bin/vmavs`
- Test: `tests/doctor.bats`

**Interfaces:**
- Consumes: `bin/vmavs`'s `SUBCOMMANDS` table.
- Produces: `vmavs_tools_for <subcommand>` in `lib/preconditions.sh`, printing a space-separated tool list on stdout. Task 4's tests read it.

Today `bin/preconditions.sh` asks one question and gives one answer: GO or NO-GO, over a flat list of eleven tools. Two things are wrong with that as a `doctor`.

**It answers the wrong question.** A host with QEMU but no `mkfs.hfsplus` cannot build media and *can* run an image somebody else built. "NO-GO" tells that person nothing. `doctor` should print a row per subcommand.

**It crashes on two of the three supported hosts.** Measured by reading `bin/preconditions.sh`, 2026-09-22: it runs `lscpu` unconditionally, greps `/proc/cpuinfo`, and reads `/sys/module/kvm/parameters/ignore_msrs`. None of those exists on macOS or NetBSD. `decisions/0007` says this tool's hosts are Linux, macOS and NetBSD; on two of them `doctor` dies before printing anything.

The fix is *not* to add HVF and NVMM branches. **Nobody has run this project on macOS or NetBSD.** `decisions/0007`'s own rule for the Snow Leopard want applies exactly here: *a parameter with one value is honest; a parameter with one value and a second branch nobody has run is a claim we cannot support.* So `doctor` on a non-Linux host prints the tool rows it can genuinely check and says, in as many words, that this project has never probed an accelerator on this operating system.

- [ ] **Step 1: Write the failing test**

Create `tests/doctor.bats`:

```bash
#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    VMAVS="$REPO/bin/vmavs"
    # shellcheck source=/dev/null
    source "$REPO/lib/common.sh"
    # shellcheck source=/dev/null
    source "$REPO/lib/preconditions.sh"
}

@test "every subcommand in vmavs's table has a tool list" {
    # A subcommand with no list would silently report READY on a host
    # that cannot run it.
    run bash -c "'$VMAVS' help | sed -n 's/^  \([a-z-]*\)  *[A-Z].*/\1/p'"
    for c in $output; do
        case $c in version|help) continue ;; esac
        run vmavs_tools_for "$c"
        [ "$status" -eq 0 ] || { echo "no tool list: $c"; false; }
    done
}

@test "run needs a QEMU; boot-stack needs a compiler; they are not the same list" {
    run vmavs_tools_for run
    [[ "$output" == *"qemu-system-x86_64"* ]]
    [[ "$output" != *"gcc"* ]]
    run vmavs_tools_for boot-stack
    [[ "$output" == *"gcc"* ]]
}

@test "image needs the union of the stages it runs" {
    img=$(vmavs_tools_for image)
    for stage in fetch boot-stack media install; do
        for t in $(vmavs_tools_for "$stage"); do
            [[ "$img" == *"$t"* ]] || { echo "image omits $t (from $stage)"; false; }
        done
    done
}

@test "no tool list names a tool no script actually requires" {
    # docs/superpowers/specs/2026-09-21-build-in-a-linux-vm-design.md
    # section 9.1 warns about exactly this: there were three lists, they
    # disagreed, and a host stopped on `zip`. This is the fourth list;
    # it must not drift from the ones that already exist.
    known=$(cat "$REPO/boot/prereqs.sh" "$REPO/bin/triangulate.sh" "$REPO/lib/preconditions.sh")
    for c in doctor fetch boot-stack media install clone run ssh emit image; do
        for t in $(vmavs_tools_for "$c"); do
            [[ "$known" == *"$t"* ]] || { echo "$c names $t, which no other list does"; false; }
        done
    done
}

@test "doctor prints one row per subcommand with a verdict" {
    run "$VMAVS" doctor
    for c in run boot-stack media image; do
        [[ "$output" == *"$c"* ]]
    done
    [[ "$output" == *"READY"* || "$output" == *"BLOCKED"* ]]
}

@test "doctor names the missing tool, not just the failure" {
    # A stub PATH with nothing on it: every row must be BLOCKED and must
    # say what is missing. "BLOCKED" alone sends someone to read source.
    mkdir -p "$BATS_TEST_TMPDIR/empty"
    run env PATH="$BATS_TEST_TMPDIR/empty" "$VMAVS" doctor
    [[ "$output" == *"qemu-system-x86_64"* ]]
}

@test "on a host this project has never probed, doctor says so instead of guessing" {
    # No HVF branch, no NVMM branch. Nobody has run this on Darwin or
    # NetBSD; a branch nobody has run is a claim we cannot support
    # (decisions/0007, the Snow Leopard rule).
    mkdir -p "$BATS_TEST_TMPDIR/stub"
    printf '#!/bin/sh\necho Darwin\n' > "$BATS_TEST_TMPDIR/stub/uname"
    chmod +x "$BATS_TEST_TMPDIR/stub/uname"
    run env PATH="$BATS_TEST_TMPDIR/stub:$PATH" "$VMAVS" doctor
    [ "$status" -ne 0 ] || true   # a verdict either way, but never a crash
    [[ "$output" == *"never"* ]]
    [[ "$output" == *"Darwin"* ]]
    [[ "$output" != *"lscpu"* ]]
}

@test "doctor points at triangulate for the ledger-grade answer" {
    run "$VMAVS" doctor
    [[ "$output" == *"triangulate"* ]]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/doctor.bats`
Expected: FAIL — `vmavs_tools_for: command not found`.

- [ ] **Step 3: Add `vmavs_tools_for` to `lib/preconditions.sh`**

Append:

```bash
# What each subcommand needs, one list apiece.
#
# spec: docs/superpowers/plans/2026-09-22-shipping-vmavs.md Task 3
#
# One list per subcommand rather than one list for the repository: a host
# with QEMU and no mkfs.hfsplus cannot build media and CAN run an image
# somebody else built, and "NO-GO" tells that person nothing.
#
# A `case`, not an associative array: bash 3.2 is the floor and
# `declare -A` is one of the constructs this project removed to keep it.
#
# tests/doctor.bats asserts that nothing named here is unknown to
# boot/prereqs.sh or bin/triangulate.sh. That test exists because the
# build-VM spec, section 9.1, records what happened when three tool lists
# disagreed: a host stopped on `zip` 23 seconds into a build.
vmavs_tools_for() {
    case $1 in
        doctor)     printf '%s\n' "" ;;
        fetch)      printf '%s\n' "curl openssl xxd unzip" ;;
        boot-stack) printf '%s\n' "gcc make git python3 nasm iasl zip unzip mcopy mformat sgdisk" ;;
        media)      printf '%s\n' "dmg2img mkfs.hfsplus sgdisk 7z cpio qemu-system-x86_64" ;;
        install)    printf '%s\n' "qemu-system-x86_64 qemu-img ssh" ;;
        target)     printf '%s\n' "qemu-img" ;;
        clone)      printf '%s\n' "qemu-img" ;;
        run)        printf '%s\n' "qemu-system-x86_64" ;;
        ssh)        printf '%s\n' "ssh" ;;
        emit)       printf '%s\n' "python3" ;;
        image)      printf '%s\n' "curl openssl xxd unzip gcc make git python3 nasm iasl zip mcopy mformat sgdisk dmg2img mkfs.hfsplus 7z cpio qemu-system-x86_64 qemu-img ssh" ;;
        *) return 1 ;;
    esac
}

# READY/BLOCKED for one subcommand, plus what is missing. Printed as
# "<verdict>\t<subcommand>\t<detail>", the same tab shape the existing
# verdict helpers use.
vmavs_subcommand_verdict() {
    local cmd=$1 missing="" t
    for t in $(vmavs_tools_for "$cmd"); do
        command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
    done
    if [ -z "$missing" ]; then
        printf '%s\t%s\t%s\n' READY "$cmd" "-"
    else
        printf '%s\t%s\tmissing:%s\n' BLOCKED "$cmd" "$missing"
    fi
}
```

- [ ] **Step 4: Make `bin/preconditions.sh` survive a non-Linux host and print the table**

Replace the host-fact block at the top with a guarded one, and append the subcommand table:

```bash
os=$(uname -s)
if [ "$os" = Linux ]; then
    vendor=$(awk -F': *' '/^Vendor ID/ { print $2; exit }' < <(LC_ALL=C lscpu))
    if grep -qw vmx /proc/cpuinfo; then vmx=yes; else vmx=no; fi
    msrs=$(cat /sys/module/kvm/parameters/ignore_msrs 2>/dev/null || echo "unknown")
    host_verdicts=$(
        cpu_vendor_verdict "$vendor"
        vmx_verdict "$vmx"
        kvm_device_verdict /dev/kvm
        ignore_msrs_verdict "$msrs"
        ovmf_verdict "$OVMF_DIR"
    )
else
    # platform: lscpu, /proc/cpuinfo and /sys/module/kvm are Linux. This
    # project has never been run on Darwin or NetBSD, so there is no HVF
    # or NVMM branch to take -- and inventing one would be the fifth
    # inherited claim this project has had to retract. Say what is true.
    host_verdicts=$(printf '%s\t%s\t%s\n' UNKNOWN accelerator \
        "never probed on $os by this project -- see docs/test-hosts.md")
fi
```

…then print `$host_verdicts` through the existing table formatter, followed by:

```bash
echo
printf '%-8s  %-11s  %s\n' STATUS SUBCOMMAND DETAIL
printf '%-8s  %-11s  %s\n' -------- ----------- ------
for c in fetch boot-stack media install clone run ssh emit image; do
    vmavs_subcommand_verdict "$c"
done | while IFS=$'\t' read -r s n d; do
    printf '%-8s  %-11s  %s\n' "$s" "$n" "$d"
done

echo
echo "For the ledger-grade answer -- the -cpu ladder, QEMU's device list,"
echo "nested virtualization, accelerator -- run: vmavs triangulate --probe"
```

- [ ] **Step 5: Wire `doctor` into `bin/vmavs`**

Replace the `die "vmavs $cmd: not wired up yet"` line's `case` with a `dispatch`:

```bash
    doctor) exec "$MQG_REPO_ROOT/bin/preconditions.sh" "$@" ;;
```

- [ ] **Step 6: Run the tests, then the suite**

Run: `bats tests/doctor.bats && ./bin/run-tests.sh`
Expected: 8 PASS, suite green. `tests/preconditions.bats` must still pass — if it asserted the old flat output, update it in this commit and say so in the message.

- [ ] **Step 7: Commit**

```bash
git add lib/preconditions.sh bin/preconditions.sh bin/vmavs tests/doctor.bats tests/preconditions.bats
git commit -m "vmavs doctor: per-subcommand readiness, and honest about unprobed hosts"
```

---

### Task 4: the pipeline subcommands — `fetch`, `boot-stack`, `media`, `install`, `image`

**Files:**
- Modify: `bin/vmavs`
- Test: `tests/vmavs.bats`

**Interfaces:**
- Consumes: `image/build-image.sh`'s existing `--stage`, `--from` and `--describe` flags. **Nothing in `image/build-image.sh` changes**, which is what keeps this task clear of task #40.

`image/build-image.sh` has eleven stages (`esd opencore ovmf efi openssh payload media target install verify manifest`) and a `--stage STAGE` that runs exactly one. `decisions/0007`'s subcommand table maps onto them directly.

`boot-stack` is three stages and `--stage` takes one, so `vmavs boot-stack` invokes the script three times rather than adding a `--through` flag. Two reasons: adding a flag would edit a file another agent is holding, and each stage is already independently resumable and freshness-checked, so three invocations cost three freshness checks — under a second, measured by the existence of `--freshness`, which exists to answer that question "in a second rather than in fourteen minutes" (`INGREDIENTS.md`).

- [ ] **Step 1: Write the failing test** (append to `tests/vmavs.bats`)

```bash
@test "vmavs image passes its arguments through to build-image.sh" {
    run "$VMAVS" image --describe
    [ "$status" -eq 0 ]
    [[ "$output" == *"esd"* ]]
    [[ "$output" == *"manifest"* ]]
}

@test "vmavs media runs the media stage and only the media stage" {
    run "$VMAVS" media --describe
    [ "$status" -eq 0 ]
    [[ "$output" == *"media"* ]]
    # --describe touches nothing, so this asserts the plan, not a build.
    [[ "$output" != *"install"* ]]
}

@test "vmavs boot-stack covers opencore, ovmf and efi" {
    run "$VMAVS" boot-stack --describe
    [ "$status" -eq 0 ]
    [[ "$output" == *"opencore"* ]]
    [[ "$output" == *"ovmf"* ]]
    [[ "$output" == *"efi"* ]]
}

@test "vmavs fetch defaults to Apple's installer and takes a named input" {
    run "$VMAVS" fetch --describe
    [ "$status" -eq 0 ]
    [[ "$output" == *"esd"* ]]
    run "$VMAVS" fetch openssh --describe
    [ "$status" -eq 0 ]
    [[ "$output" == *"openssh"* ]]
}

@test "vmavs fetch refuses an input it does not have" {
    run "$VMAVS" fetch xcode
    [ "$status" -ne 0 ]
    [[ "$output" == *"xcode"* ]]
    [[ "$output" == *"esd"* ]]
}

@test "vmavs install covers target then install" {
    run "$VMAVS" install --describe
    [ "$status" -eq 0 ]
    [[ "$output" == *"target"* ]]
    [[ "$output" == *"install"* ]]
}

@test "every pipeline subcommand forwards --help to the script behind it" {
    for c in image media boot-stack install; do
        run "$VMAVS" "$c" --help
        [ "$status" -eq 0 ] || { echo "$c --help failed"; false; }
        [[ "$output" == *"--accel"* ]] || { echo "$c --help is not build-image's"; false; }
    done
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/vmavs.bats`
Expected: the seven new tests FAIL with "not wired up yet".

- [ ] **Step 3: Implement the arms in `bin/vmavs`**

```bash
BUILD_IMAGE=$MQG_REPO_ROOT/image/build-image.sh

# Run one or more build-image.sh stages with the caller's options after
# them. --describe and --help are pass-through and must reach the script
# without a stage being forced in front of them, or `vmavs media --help`
# would print a plan instead of a help.
stages() {
    local list=$1; shift
    case " $* " in
        *" --help "*|*" -h "*) exec "$BUILD_IMAGE" --help ;;
    esac
    local s
    for s in $list; do
        "$BUILD_IMAGE" --stage "$s" "$@"
    done
}

case $cmd in
    fetch)
        what=esd
        case ${1:-} in
            esd|openssh) what=$1; shift ;;
            updates) shift; exec "$MQG_REPO_ROOT/image/fetch-updates.sh" "$@" ;;
            -*|'') ;;
            *) die "no such input: $1 (esd, openssh, updates)" ;;
        esac
        stages "$what" "$@" ;;
    boot-stack) stages "opencore ovmf efi" "$@" ;;
    media)      stages "media" "$@" ;;
    install)    stages "target install" "$@" ;;
    image)      exec "$BUILD_IMAGE" "$@" ;;
esac
```

- [ ] **Step 4: Run the tests, then the suite, then commit**

```bash
bats tests/vmavs.bats && ./bin/run-tests.sh
git add bin/vmavs tests/vmavs.bats
git commit -m "vmavs: fetch, boot-stack, media, install, image"
```

---

### Task 5: `run`, `clone`, and a real `vmavs ssh`

**Files:**
- Create: `vm/ssh.sh`
- Modify: `bin/vmavs`
- Test: `tests/vm.bats`

**Interfaces:**
- Produces: `vm/ssh.sh [--port N] [--user U] [--key PATH] [--dry-run] [-- <ssh args>]`.

`run` and `clone` are pass-throughs to `vm/run.sh` and `vm/clone.sh` and need no new code. **A note the plan should not hide:** `decisions/0007` describes `run` as "boot a clone", and `vm/run.sh` takes a *profile*, not an image. That is a genuine mismatch between the ADR's wording and the machinery. This plan ships the machinery that exists and works, and records the gap rather than inventing a second calling convention nobody has used. `vmavs run --help` lists the profiles, as `vm/run.sh` already does.

`ssh` is the one new user-facing thing, and it is small on purpose. Its value is entirely in three flags nobody remembers and everybody needs:

- `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null` — **every clone regenerates its host keys**, so a stale `known_hosts` entry is the first thing that bites anyone who clones a golden twice. Without these, the second clone fails with a warning about a man-in-the-middle attack, which is alarming and wrong.
- `-o IdentitiesOnly=yes` — so a loaded agent with a dozen keys does not exhaust `MaxAuthTries` before reaching the one key the image authorized.

Defaults come from `image/build-image.sh`'s own defaults, read 2026-09-22: port `2222`, user `mavsuser`.

- [ ] **Step 1: Write the failing test** (append to `tests/vm.bats`)

```bash
@test "vmavs ssh --dry-run prints the command and starts nothing" {
    run "$REPO/bin/vmavs" ssh --dry-run --key /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == ssh\ * ]]
    [[ "$output" == *"-p 2222"* ]]
    [[ "$output" == *"mavsuser@127.0.0.1"* ]]
}

@test "vmavs ssh disables host key checking, because every clone has new keys" {
    run "$REPO/bin/vmavs" ssh --dry-run --key /dev/null
    [[ "$output" == *"StrictHostKeyChecking=no"* ]]
    [[ "$output" == *"UserKnownHostsFile=/dev/null"* ]]
}

@test "vmavs ssh uses only the key it was given" {
    # Without IdentitiesOnly a loaded agent offers every key it holds and
    # the server closes the connection on MaxAuthTries before reaching
    # the one the image authorized.
    run "$REPO/bin/vmavs" ssh --dry-run --key /dev/null
    [[ "$output" == *"IdentitiesOnly=yes"* ]]
}

@test "vmavs ssh honours --port, --user and --key" {
    run "$REPO/bin/vmavs" ssh --dry-run --port 2299 --user ci --key /dev/null
    [[ "$output" == *"-p 2299"* ]]
    [[ "$output" == *"ci@127.0.0.1"* ]]
}

@test "vmavs ssh passes everything after -- to ssh" {
    run "$REPO/bin/vmavs" ssh --dry-run --key /dev/null -- uname -a
    [[ "$output" == *"uname -a"* ]]
}

@test "vmavs ssh refuses a key that is not there, naming it" {
    run "$REPO/bin/vmavs" ssh --dry-run --key /nonexistent/id_ed25519
    [ "$status" -ne 0 ]
    [[ "$output" == *"/nonexistent/id_ed25519"* ]]
}

@test "vmavs run lists the profiles when given none" {
    run "$REPO/bin/vmavs" run
    [ "$status" -ne 0 ]
    [[ "$output" == *"p4-linuxmedia"* ]]
}

@test "vmavs clone reaches vm/clone.sh" {
    run "$REPO/bin/vmavs" clone
    [ "$status" -ne 0 ]
    [[ "$output" == *"usage"* || "$output" == *"golden"* ]]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/vm.bats`
Expected: the eight new tests FAIL.

- [ ] **Step 3: Write `vm/ssh.sh`**

```bash
#!/usr/bin/env bash
# Open a shell in a running guest.
#
# spec: docs/superpowers/plans/2026-09-22-shipping-vmavs.md Task 5
#
# Twelve lines of flags that everyone currently retypes. Two of them are
# load-bearing and neither is obvious:
#
#   StrictHostKeyChecking=no + UserKnownHostsFile=/dev/null -- every
#   clone of a golden regenerates its host keys, so the second clone
#   fails with a man-in-the-middle warning that is alarming and wrong.
#
#   IdentitiesOnly=yes -- a loaded agent offers every key it holds, and
#   the guest closes the connection on MaxAuthTries before reaching the
#   one key the image actually authorized.
#
# Defaults match image/build-image.sh's own (port 2222, user mavsuser).
set -euo pipefail

MQG_REPO_ROOT=${MQG_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck source=../lib/common.sh
. "$MQG_REPO_ROOT/lib/common.sh"
# shellcheck disable=SC2034
MQG_LOG_PREFIX=ssh

port=2222
user=mavsuser
key=${MQG_SSH_KEY:-}
dry=0

while [ $# -gt 0 ]; do
    case $1 in
        --port) port=$2; shift ;;
        --user) user=$2; shift ;;
        --key)  key=$2; shift ;;
        --dry-run) dry=1 ;;
        --) shift; break ;;
        -h|--help)
            cat <<EOF
usage: vmavs ssh [--port N] [--user U] [--key PATH] [--dry-run] [-- <ssh args>]

  --port N     Host port forwarded to the guest's 22 (default: $port)
  --user U     Guest account (default: $user)
  --key PATH   PRIVATE key whose public half the image authorized.
               Default: \$MQG_SSH_KEY, else the first of ~/.ssh/id_*
               that has a .pub beside it.
  --dry-run    Print the ssh command line and exit. Connects to nothing.
EOF
            exit 0 ;;
        *) die "unknown option: $1 (everything for ssh goes after --)" ;;
    esac
    shift
done

if [ -z "$key" ]; then
    for k in "$HOME"/.ssh/id_ed25519 "$HOME"/.ssh/id_rsa "$HOME"/.ssh/id_*; do
        [ -f "$k" ] && [ -f "$k.pub" ] && { key=$k; break; }
    done
fi
[ -n "$key" ] || die "no ssh key found; pass --key PATH"
[ -e "$key" ] || die "no such key: $key"

set -- ssh -p "$port" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o IdentitiesOnly=yes \
    -o LogLevel=ERROR \
    -i "$key" "$user@127.0.0.1" "$@"

if [ "$dry" = 1 ]; then printf '%s\n' "$*"; exit 0; fi
run_log "$*"
exec "$@"
```

- [ ] **Step 4: Wire the three arms into `bin/vmavs`**

```bash
    run)   exec "$MQG_REPO_ROOT/vm/run.sh" "$@" ;;
    clone) exec "$MQG_REPO_ROOT/vm/clone.sh" "$@" ;;
    ssh)   exec "$MQG_REPO_ROOT/vm/ssh.sh" "$@" ;;
```

- [ ] **Step 5: Run the tests, then the suite, then commit**

```bash
chmod +x vm/ssh.sh
bats tests/vm.bats && ./bin/run-tests.sh
git add vm/ssh.sh bin/vmavs tests/vm.bats
git commit -m "vmavs: run, clone, and an ssh that survives a re-cloned golden"
```

---

### Task 6: `vmavs emit packer`

**Files:**
- Create: `emit/packer.sh`, `tests/emit.bats`
- Modify: `bin/vmavs`, `bin/tier-check.sh`

**Interfaces:**
- Consumes: a profile from `vm/profiles/*.args` and, optionally, an image manifest.
- Produces: `emit/packer.sh [--profile NAME] [--out FILE] [--describe]` writing one HCL2 template.

**Why Packer, and why Packer is not the build.** `docs/test-hosts.md:284` already observes that `timsutton/osx-vm-templates` — this project's prior art twice over — *is* a Packer template, and that what this project builds, minus the first-boot payload, is the same shape. One template reaches QEMU, VirtualBox, VMware and Proxmox, and its `vagrant` post-processor makes the boxes, which makes this the single highest-leverage interop artifact available. It is an **emit target and not the build**, for three reasons the user has already settled: Packer's core value is `boot_command` GUI keystroke automation, which P4 engineered away entirely by using Apple's own `rc.cdrom.local` / `minstallconfig.xml` / `OSInstall.collection` hooks; adopting it would cost the stage-level input-hash freshness from task #36 and most of the manifest; and it covers two of eleven stages.

**One thing about this task has never been tested, and it must be written into the emitted file itself: no Packer has ever parsed this template.** Packer is not installed on this host and this plan installs nothing. The field *values* are MEASURED — they are the same numbers `vm/profiles/*.args` and `decisions/0009`/`0010` carry, which have full installs behind them. The field *names and nesting* are REASONED from Packer's documented schema and are the one unverified thing. `--check` exists to close that, the moment somebody with Packer runs it.

**The never-publish rule reaches here too.** The emitted template references local paths and embeds no bytes. `bin/tier-check.sh --strict` learns about `emit/` in this task, so a template that reached for `$MQG_VENDOR_DIR` would fail the suite the way a profile does.

- [ ] **Step 1: Write the failing test**

Create `tests/emit.bats`:

```bash
#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    VMAVS="$REPO/bin/vmavs"
    OUT="$BATS_TEST_TMPDIR/mavericks.pkr.hcl"
}

emit() { "$VMAVS" emit packer --profile p4-linuxmedia --out "$OUT" "$@"; }

@test "emit packer writes a template with a qemu source and a build block" {
    run emit
    [ "$status" -eq 0 ]
    [ -s "$OUT" ]
    run grep -c '^source "qemu"' "$OUT"
    [ "$output" = "1" ]
    run grep -c '^build {' "$OUT"
    [ "$output" = "1" ]
}

@test "the template carries the CPU and SMBIOS this project measured" {
    emit
    run grep -c 'Penryn' "$OUT"
    [ "$output" -ge 1 ]
    run grep -c 'iMac14,2' "$OUT"
    [ "$output" -ge 1 ]
}

@test "the template has no boot_command, and says why" {
    # P4's finding: Apple's own installer hooks drive the install, so the
    # GUI keystroke automation that is Packer's core value is not needed.
    # An empty boot_command with no explanation reads as an omission.
    run grep -c 'boot_command' "$OUT" || true
    emit
    run grep -c 'rc.cdrom.local\|minstallconfig\|Apple.s own' "$OUT"
    [ "$output" -ge 1 ]
}

@test "the template embeds no Apple bytes -- only paths and a checksum" {
    emit
    run grep -cE 'InstallESD|BaseSystem' "$OUT"
    # Naming the file as a local path is fine; carrying it is not.
    run bash -c "wc -c < '$OUT'"
    [ "$output" -lt 20000 ]
}

@test "the vagrant post-processor is present and is local-only" {
    # decisions/0007 and test-hosts.md: a box made from this can never be
    # shared, because it contains Apple's OS. The template must not point
    # at Vagrant Cloud.
    emit
    run grep -c 'post-processor "vagrant"' "$OUT"
    [ "$output" = "1" ]
    run grep -c 'vagrantcloud\|app.vagrantup.com' "$OUT" || true
    [ "$output" = "0" ]
}

@test "the template says out loud that no Packer has parsed it" {
    emit
    run grep -ci 'never been\|unverified\|packer validate' "$OUT"
    [ "$output" -ge 1 ]
}

@test "--describe prints where each field's value came from and writes nothing" {
    run "$VMAVS" emit packer --profile p4-linuxmedia --describe
    [ "$status" -eq 0 ]
    [[ "$output" == *"MEASURED"* || "$output" == *"REASONED"* ]]
    [ ! -f "$OUT" ]
}

@test "--check says plainly that it could not validate when packer is absent" {
    mkdir -p "$BATS_TEST_TMPDIR/empty"
    run env PATH="$BATS_TEST_TMPDIR/empty:$PATH" \
        "$VMAVS" emit packer --profile p4-linuxmedia --out "$OUT" --check
    # Cannot-verify is never a pass.
    [ "$status" -ne 0 ]
    [[ "$output" == *"packer"* ]]
    [[ "$output" == *"not"* ]]
}

@test "emit refuses a profile that does not exist, and lists the ones that do" {
    run "$VMAVS" emit packer --profile nonesuch --out "$OUT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"nonesuch"* ]]
    [[ "$output" == *"p4-linuxmedia"* ]]
}

@test "emit refuses a target it does not have" {
    run "$VMAVS" emit libvirt
    [ "$status" -ne 0 ]
    [[ "$output" == *"packer"* ]]
}

@test "tier-check covers emit/, so a template cannot reach into the Tier 2 quarantine" {
    run grep -c 'emit' "$REPO/bin/tier-check.sh"
    [ "$output" -ge 1 ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/emit.bats`
Expected: all FAIL.

- [ ] **Step 3: Write `emit/packer.sh`**

The script reads the named profile with `lib/profile.sh`'s existing expansion, pulls `-cpu`, `-smbios`, `-m`, `-smp`, the NIC and the machine type out of it, and writes:

```hcl
# Generated by `vmavs emit packer` -- do not edit; re-emit instead.
#
# WHAT HAS AND HAS NOT BEEN VERIFIED
#
# The VALUES below are measured: they are the same -cpu line, SMBIOS
# model, NIC and memory that docs/decisions/0009 and 0010 record, each
# with completed installs behind it.
#
# The FIELD NAMES AND NESTING have never been checked against a real
# Packer. No Packer has ever parsed this file. Run `packer validate` on
# it and write the result into NOTES.md; `vmavs emit packer --check`
# does exactly that when packer is on PATH.
#
# THIS TEMPLATE CONTAINS NO APPLE BYTES and must never be changed so that
# it does. It names local paths that YOU produced with `vmavs media`.
# A box built from it can never be shared: it contains Apple's operating
# system. There is deliberately no Vagrant Cloud box_tag here.

packer { required_plugins { qemu = { source = "github.com/hashicorp/qemu", version = "~> 1" } } }

variable "media"     { type = string  description = "Installer media image from `vmavs media`" }
variable "ovmf_code" { type = string  description = "OVMF_CODE.fd from `vmavs boot-stack`" }
variable "ovmf_vars" { type = string  description = "This VM's own OVMF_VARS.fd" }
variable "ssh_key"   { type = string  description = "Private key whose public half the image authorized" }

source "qemu" "mavericks" {
  iso_url           = var.media
  iso_checksum      = "none"          # the media is yours; `vmavs media` checksums its inputs
  disk_image        = false
  disk_size         = "61440M"
  format            = "qcow2"
  machine_type      = "q35"
  cpu_model         = "Penryn,+sse4.2"
  memory            = 4096
  cpus              = 2
  net_device        = "e1000-82545em"
  headless          = true

  # No boot_command. Packer's keystroke automation is not needed here:
  # Apple's own installer reads /etc/rc.cdrom.local,
  # Extras/minstallconfig.xml and OSInstall.collection off the media, so
  # the install is unattended without anybody typing at a GUI. That is
  # P4's central finding and it is why this is an emit target rather
  # than the build. See docs/superpowers/specs/2026-09-17-mavericks-guest-design.md.
  boot_wait         = "0s"

  communicator      = "ssh"
  ssh_username      = "mavsuser"
  ssh_private_key_file = var.ssh_key
  ssh_timeout       = "60m"

  qemuargs = [
    ["-smbios", "type=2"],
    ["-drive", "if=pflash,format=raw,readonly=on,file=${var.ovmf_code}"],
    ["-drive", "if=pflash,format=raw,file=${var.ovmf_vars}"],
    ["-device", "isa-applesmc,osk=..."],
  ]
}

build {
  sources = ["source.qemu.mavericks"]
  post-processor "vagrant" { output = "mavericks-{{.Provider}}.box" }
}
```

Values are substituted from the profile rather than hardcoded; the literal above is what `p4-linuxmedia` produces today.

- [ ] **Step 4: Teach `bin/tier-check.sh` about `emit/`**

Add `emit/` to the set of directories scanned for `$MQG_VENDOR_DIR` references, with a comment: *`emit/` writes files people hand to other tools. A template that reached into the Tier 2 quarantine would export this project's scaffolding as somebody else's dependency — which is P3's exit gate one step further out.*

- [ ] **Step 5: Wire `emit` into `bin/vmavs`**

```bash
    emit)
        target=${1:-}
        [ -n "$target" ] || die "usage: vmavs emit packer [options]"
        shift
        case $target in
            packer) exec "$MQG_REPO_ROOT/emit/packer.sh" "$@" ;;
            *) die "no such emit target: $target (today: packer). One Packer template reaches QEMU, VirtualBox, VMware and Proxmox -- see docs/test-hosts.md" ;;
        esac ;;
```

- [ ] **Step 6: Run the tests, then the suite, then commit**

```bash
chmod +x emit/packer.sh
bats tests/emit.bats && ./bin/run-tests.sh
git add emit/packer.sh bin/vmavs bin/tier-check.sh tests/emit.bats
git commit -m "vmavs emit packer: one template for four hypervisors, unparsed by any Packer"
```

- [ ] **Step 7: Record the gap in `NOTES.md`**

Append an entry saying that `emit/packer.sh` exists, what it was derived from, and that **its schema is unverified because no Packer is installed here**. `NOTES.md` is append-only and this is precisely the kind of thing it is for.

---

### Task 7: the second-tier subcommands

**Files:** Modify `bin/vmavs`; Test: `tests/vmavs.bats`

**This task is proposed rather than decided, and can be struck without affecting anything else.** `decisions/0007` names ten subcommands, and those ten are the product surface. But four more scripts have real user-facing CLIs today — `bin/triangulate.sh`, `vm/golden.sh`, `image/compare-images.sh`, and `build-image.sh --freshness` — and if `vmavs` does not reach them then `vmavs` is strictly less capable than the scripts it is replacing, which is a bad trade for a front door. They go in a second section of `vmavs help`, clearly labelled as not part of the ten.

- [ ] **Step 1: Write the failing test** (append to `tests/vmavs.bats`)

```bash
@test "the second-tier subcommands reach their scripts" {
    run "$VMAVS" triangulate --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--probe"* ]]
    run "$VMAVS" freshness
    [[ "$output" == *"stage"* || "$output" == *"would"* ]]
}

@test "help keeps the ten from decisions/0007 separate from the rest" {
    run "$VMAVS" help
    [[ "$output" == *"triangulate"* ]]
    # The ten appear above whatever divides the sections.
    ten=$(printf '%s\n' "$output" | grep -n '  image ' | cut -d: -f1)
    extra=$(printf '%s\n' "$output" | grep -n '  triangulate' | cut -d: -f1)
    [ "$ten" -lt "$extra" ]
}
```

- [ ] **Step 2–4: Implement, test, commit**

```bash
    triangulate) exec "$MQG_REPO_ROOT/bin/triangulate.sh" "$@" ;;
    golden)      exec "$MQG_REPO_ROOT/vm/golden.sh" "$@" ;;
    compare)     exec "$MQG_REPO_ROOT/image/compare-images.sh" "$@" ;;
    freshness)   exec "$BUILD_IMAGE" --freshness "$@" ;;
    staleness)   exec "$MQG_REPO_ROOT/bin/image-staleness.sh" "$@" ;;
```

```bash
bats tests/vmavs.bats && ./bin/run-tests.sh
git commit -am "vmavs: triangulate, golden, compare, freshness, staleness"
```

---

### Task 8: demote the direct entry points

> **Rebase this onto task #40 before starting.** It adds one line to `image/build-image.sh`, which that task owns.

**Files:**
- Modify: `lib/common.sh`; one line each in `image/build-image.sh`, `bin/triangulate.sh`, `vm/run.sh`, `vm/clone.sh`, `vm/golden.sh`, `image/compare-images.sh`
- Modify: `docs/*.md` and `docs/decisions/*.md` — invocations only
- Test: `tests/common.bats`

**What is deliberately *not* edited: `NOTES.md`.** It is the append-only lab log; it records what command was run on what day. Rewriting its 26 `build-image.sh` mentions would falsify the record. A note at the top of `NOTES.md` saying that entries before 2026-09-22 name the scripts directly, and that `vmavs` is now the front door, is the honest fix and it is one paragraph.

The hint prints only when a human is watching. That is what keeps the suite green: bats captures stderr through a pipe, so `[ -t 2 ]` is false and the hint is silent. `VMAVS_FORCE_HINT=1` is the only reason the hint is testable at all.

- [ ] **Step 1: Write the failing test** (append to `tests/common.bats`)

```bash
@test "vmavs_hint is silent when nobody is watching -- this is why the suite stays green" {
    run bash -c "source '$REPO/lib/common.sh'; vmavs_hint image"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "vmavs_hint names the vmavs equivalent when forced" {
    run bash -c "source '$REPO/lib/common.sh'; VMAVS_FORCE_HINT=1 vmavs_hint image"
    [[ "$output" == *"vmavs image"* ]]
}

@test "every script vmavs dispatches to calls vmavs_hint" {
    for s in image/build-image.sh bin/triangulate.sh vm/run.sh vm/clone.sh \
             vm/golden.sh image/compare-images.sh; do
        run grep -c 'vmavs_hint' "$REPO/$s"
        [ "$output" -ge 1 ] || { echo "no hint in $s"; false; }
    done
}

@test "the docs invoke vmavs, not the scripts" {
    # NOTES.md is excluded on purpose: it is the append-only lab log and
    # rewriting what was run would falsify it.
    run bash -c "grep -rn '\./image/build-image\.sh\|\./bin/triangulate\.sh' \
        '$REPO/README.md' '$REPO/docs' --include='*.md' \
        | grep -v 'docs/superpowers/plans/' | wc -l"
    [ "$output" = "0" ]
}
```

- [ ] **Step 2: Run to verify it fails.** Run: `bats tests/common.bats` — the last three FAIL.

- [ ] **Step 3: Add `vmavs_hint` to `lib/common.sh`**

```bash
# Point a human at the documented way to do what they just typed.
#
# spec: docs/superpowers/plans/2026-09-22-shipping-vmavs.md Task 8
#
# The scripts under image/, boot/, media/ and vm/ are not deprecated and
# cannot be: `vmavs image` IS image/build-image.sh. What changed is that
# they are no longer the documented interface. Typing the old command
# still works and prints this.
#
# Silent unless stderr is a terminal, which is why the suite stayed green
# when this landed -- bats captures stderr through a pipe. VMAVS_FORCE_HINT
# exists so the hint is testable despite that.
vmavs_hint() {
    [ "${VMAVS_FORCE_HINT:-0}" = 1 ] || [ -t 2 ] || return 0
    printf 'note: `vmavs %s` is the documented way to do this.\n' "$*" >&2
}
```

- [ ] **Step 4: Add one call to each script**, immediately after it sources `lib/common.sh`: `vmavs_hint image`, `vmavs_hint triangulate`, `vmavs_hint run`, `vmavs_hint clone`, `vmavs_hint golden`, `vmavs_hint compare`.

- [ ] **Step 5: Sweep the docs.** In `README.md`, `docs/*.md` and `docs/decisions/*.md`, replace *invocations* with their `vmavs` form. Leave prose that names a file as a file (`image/build-image.sh records every pin in the manifest`) alone — it is still true and still the right reference.

- [ ] **Step 6: Add the `NOTES.md` preamble note.**

- [ ] **Step 7: Run the suite and commit**

```bash
./bin/run-tests.sh
git add -A
git commit -m "vmavs is the front door; the scripts behind it stay where they are"
```

---

### Task 9: the README as product documentation

**Files:** Rewrite `README.md`; Test: `tests/release.bats`

**What someone who wants a Mavericks VM needs in thirty seconds**, in order: *what this gives me*, *the commands*, *what it costs me in time and disk*, *what it refuses to do*, and *whether my machine can run it*. Everything currently in the README — the "where things are" table, the ground rules, the provenance tiers — is true and belongs, but below that fold. It reads today as a lab notebook because the first thing it does is describe the host it was developed on.

Family-conventions note: `publish-release.yml` refuses a repo's first release while the README still carries the generated "has not been read or edited by a human" marker. This README has never had that marker, so there is nothing to remove — but it is why the README is a shipping task and not a nicety.

- [ ] **Step 1: Write the failing test** (append to `tests/release.bats`)

```bash
@test "the README leads with what the tool does, not with the host it was built on" {
    run head -12 "$REPO/README.md"
    [[ "$output" == *"vmavs"* ]]
    [[ "$output" != *"Mac mini 2018"* ]]
    [[ "$output" != *"Linux Mint"* ]]
}

@test "the README shows the four commands that get someone to a desktop" {
    run head -30 "$REPO/README.md"
    for c in doctor image run ssh; do
        [[ "$output" == *"vmavs $c"* ]] || { echo "missing: vmavs $c"; false; }
    done
}

@test "the README states the never-publish rule above the fold" {
    run head -45 "$REPO/README.md"
    [[ "$output" == *"never"* ]]
    [[ "$output" == *"Apple"* ]]
}

@test "the README carries no unread-by-a-human marker" {
    # publish-release.yml refuses a first release while that line stands.
    run grep -c 'not been read or edited by a human' "$REPO/README.md" || true
    [ "$output" = "0" ]
}
```

- [ ] **Step 2: Run to verify it fails.** Run: `bats tests/release.bats`

- [ ] **Step 3: Write the README**

```markdown
# vm-guest

Run **OS X 10.9 Mavericks** in a virtual machine — on Linux, on macOS, on
NetBSD — with an install that nobody has to sit and watch.

```sh
vmavs doctor    # can this machine do it?
vmavs image     # ~30 minutes, unattended, from Apple's own installer
vmavs run p4-linuxmedia
vmavs ssh       # a shell in the guest
```

You supply the machine and an Apple ID's worth of nothing: `vmavs` downloads
Apple's `InstallESD.dmg` from Apple, builds OpenCore and the guest's UEFI
firmware from pinned source, assembles bootable installer media without root,
lets Apple's own installer install 10.9.5 unattended, and creates your account
and authorizes your SSH key on first boot. It is resumable stage by stage, and
every image carries a manifest naming every input that went into it.

On the machine this was developed on — a 2018 Mac mini under KVM — a build
takes about 30 minutes and the image wants about 60 GB. `vmavs image
--describe` prints the plan without doing anything.

## Two rules this project does not bend

- **The operating system comes from Apple, and only from Apple.** Firmware and
  bootloaders may be third-party; macOS disk images may not. No prebuilt
  third-party macOS image is used, ever.
- **The guest image is never published.** Not as a release asset, not as a
  package, not anywhere reachable without authentication. `vmavs` ships a
  recipe; you build your own image on your own machine, from Apple's bytes,
  which never enter this repository. `bin/no-apple-bytes.sh` is the gate that
  keeps that true rather than merely intended.

Your host is Apple hardware? Then this is the case Apple's licence
contemplates: virtualizing OS X on an Apple-branded machine.

## Will it work on my machine?

`vmavs doctor` answers per subcommand — a host with QEMU and no
`mkfs.hfsplus` can `run` an image and cannot `media`. For the full answer,
`vmavs triangulate --probe` writes a report about what your host can do and
what that settles.

Known today, measured: Linux with KVM works end to end. **macOS and NetBSD
have never been run.** `decisions/0007` says they are targets; nobody has
tried. `docs/test-hosts.md` tracks what has.

## What you get, and what you don't

`docs/install-log.md` and `NOTES.md` carry the capability census. The short
version: networking, SSH and the desktop work; absolute mouse positioning
needs a kext nobody has built yet; interactive performance has not been tuned
(that is P5, deliberately deferred — see the design).

## Commands

| | |
|---|---|
| `vmavs doctor` | What this host can do, subcommand by subcommand |
| `vmavs fetch` | Fetch one pinned input: Apple's installer, OpenSSH, updates |
| `vmavs boot-stack` | Build OpenCore, the firmware and the EFI image from pinned source |
| `vmavs media` | Build bootable installer media |
| `vmavs install` | Create the target disk and let Apple's installer run |
| `vmavs clone` | A throwaway overlay on a golden image |
| `vmavs run` | Boot a profile |
| `vmavs ssh` | A shell in a running guest |
| `vmavs emit packer` | A Packer template — QEMU, VirtualBox, VMware, Proxmox |
| `vmavs image` | The whole chain |

`vmavs help` and `vmavs <command> --help`.

## Installing

Not yet packaged. Clone the repository and put `bin/vmavs` on your `PATH`;
everything else is found relative to it, including through a symlink. The
packaging question is deliberately open: see
`docs/superpowers/plans/2026-09-22-shipping-vmavs.md`, Phase C.

## For people working on this

| Path | What |
|---|---|
| `docs/superpowers/specs/` | Design documents. Start with the umbrella design. |
| `docs/superpowers/plans/` | Implementation plans. |
| `docs/decisions/` | What we chose, the evidence, and what we rejected. |
| `docs/configuration-register.md` | Every knob, and whether it was measured, inherited or reasoned. |
| `docs/prior-art.md` | Every source worth reading, and what each gives us. |
| `docs/host-profile.md` | This host, and every host-specific assumption. |
| `NOTES.md` | The append-only lab log. Every attempt, including the failures. |

**No unreproducible blobs in the shipped boot path.** Everything is Tier 0
(built from pinned source) or Tier 1 (vanilla upstream, pinned and
checksummed). `bin/tier-check.sh --strict` enforces it on every test run.

**Write down the failures.** `NOTES.md` is append-only.
```

- [ ] **Step 4: Run the tests, then the suite, then commit**

```bash
bats tests/release.bats && ./bin/run-tests.sh
git add README.md tests/release.bats
git commit -m "README: what this is, in the first thirty seconds"
```

---

## Phase B — what the family gate needs, and the build VM does not block

### Task 10: prove the release gate's building block before there is a release

**Files:** Modify `tests/release.bats`

`bin/no-apple-bytes.sh` takes an optional ref: `bin/no-apple-bytes.sh [ref]`, defaulting to the index. The release path will call it on the **tag being released**, and `tests/release.bats` today only ever calls it with no argument. So the one form the release depends on is the one form nothing exercises.

**The design decision this test locks in:** the release tarball must be `git archive` of the tag and nothing else. Because `no-apple-bytes.sh` checks exactly what `git archive` would package, an assembled-any-other-way tarball would make the check *partial* — and a gate that covers most of an artifact is the kind that reads green while the thing it guards is wrong. Phase C's `release.yml` inherits this as a constraint, not a preference.

- [ ] **Step 1: Write the failing test** (append to `tests/release.bats`)

```bash
@test "no-apple-bytes checks a named ref, which is what a release will pass it" {
    dir="$(make_repo)"
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh HEAD"
    [ "$status" -eq 0 ]
}

@test "a violation on a TAG is caught when that tag is checked" {
    # The release path checks the tag it is about to publish, not the
    # working tree. A planted .dmg at that tag must fail it.
    dir="$(make_repo)"
    printf 'not really\n' > "$dir/InstallESD.dmg"
    git -C "$dir" add -A
    git -C "$dir" -c commit.gpgsign=false commit -qm planted
    git -C "$dir" tag 20260922.1
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh 20260922.1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"InstallESD.dmg"* ]]
}

@test "a clean tag passes even when the WORKING TREE has Apple's media beside it" {
    # This is how the project is meant to work: decisions/0003 puts images
    # on local disk outside the repo. An untracked InstallESD.dmg must not
    # redden a release.
    dir="$(make_repo)"
    git -C "$dir" tag 20260922.1
    printf 'x\n' > "$dir/InstallESD.dmg"
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh 20260922.1"
    [ "$status" -eq 0 ]
}

@test "an unknown ref is a failure, never a pass" {
    # Cannot-verify is a FAILURE. A release gate that green-lights because
    # it could not find the tag is worse than no gate.
    dir="$(make_repo)"
    run bash -c "cd '$dir' && ./bin/no-apple-bytes.sh 19700101.1"
    [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run them.** Any that fail are real defects in `bin/no-apple-bytes.sh` — most likely the unknown-ref case falling through to a pass. Fix the script, not the test.

- [ ] **Step 3: Run the suite and commit**

```bash
./bin/run-tests.sh
git add bin/no-apple-bytes.sh tests/release.bats
git commit -m "no-apple-bytes: prove the ref form the release path will use"
```

---

### Task 11: `INGREDIENTS.md` — declared state, and a narrower deviation

> **Rebase this onto task #40 before starting.** That task owns `INGREDIENTS.md` and is adding the Apple-update pin rows.

**Files:** Modify `INGREDIENTS.md`; Create `docs/decisions/0012-version-scheme.md`; Modify `tests/release.bats`

Three edits, each with a reason:

**(a) Add `## Declared state`.** The family's grammar is `- <name>: <path>` or `- <name>: <path>:<KEY>`, one per line, parsed by `declared-state.sh`. Exactly one entry must be named `upstream` and **must name the very file `version.sh` reads** — ours is `UPSTREAM_VERSION`, so no `$MAVERICKS_UPSTREAM_FILE` is needed anywhere. **The grammar has a silent failure mode worth guarding against: un-bulleted prose in that section is ignored, but a dash-line containing a colon is parsed as an entry.** So no explanatory line in this section may start with a dash.

```markdown
## Declared state

A release is the realisation of a declared state, not the side effect of a
push. These are the inputs whose movement should cut one. Deliberately a
SUBSET of the registry table above: `bats` moving must never cut a release.

- upstream: UPSTREAM_VERSION
- pins: vendor/sources.tsv
- openssh: components/openssh/version
- opencore-config: boot/config/config.plist
```

**(b) Reverse `### `repackage-on-ingredient-bump`: not applicable, and why`.** Its argument — "we publish no artifact for an ingredient to get baked into" — was written when there was no release at all and was correct then. Once a release exists, we publish the **recipe**, and a moved pin is exactly what changes what the recipe builds. Rewrite it honestly: say what the old reasoning was, say what changed, and keep everything that is still true (the manifest mechanism, `image-staleness.sh`, and the fact that a bump invalidates goldens already on disk regardless of publishing).

**(c) Narrow the version-scheme deviations.** The two `version-scheme:` lines currently say we do not use the family's scheme. Replace with the accurate, narrower claim:

```markdown
- version-scheme:bin/vmavs: this product is its own upstream, not a repackage of somebody else's release, so it takes the family's SELF-UPSTREAM shape (`YYYYMMDD.N`, as `mavericks-porthole` does) rather than `<upstream>-mavericks.N`. The suffix means "our Nth repackage of someone else's thing" and there is no such thing here; `docs/decisions/0012-version-scheme.md` has the reasoning
- version-scheme:vm/*.sh: same product, same reason, scoped the same way so a deviation on one file cannot quietly license the rest to drift
```

The two `sparkle-updater:` lines stay exactly as they are; nothing about them changed.

**(d) `docs/decisions/0012-version-scheme.md`** records the finding that `decisions/0007`'s deviation row was wider than the facts — that the family already has a self-upstream branch and we are on it — and cross-references `0007` without editing it. `0007` is the user's product decision; an ADR that supersedes part of another is the family's way of moving, not an edit in place.

- [ ] **Step 1: Write the failing test** (append to `tests/release.bats`)

```bash
@test "INGREDIENTS.md declares a release state, with exactly one upstream entry" {
    run bash -c "sed -n '/^## Declared state/,/^## /p' '$REPO/INGREDIENTS.md' \
        | grep -c '^- upstream: '"
    [ "$output" = "1" ]
}

@test "the declared upstream is the file build/version.sh reads" {
    # release-state.sh exits 2 when these disagree, nightly, from its
    # first run. Catch it here instead.
    run bash -c "sed -n '/^## Declared state/,/^## /p' '$REPO/INGREDIENTS.md' \
        | sed -n 's/^- upstream: //p'"
    [ "$output" = "UPSTREAM_VERSION" ]
    [ -f "$REPO/UPSTREAM_VERSION" ]
}

@test "no prose line in the declared-state section starts with a dash and a colon" {
    # A dash-line containing a colon is parsed as an entry. If the text
    # after the colon happens to name a real file, the digest silently
    # gains an entry nobody intended -- the failure mode the whole design
    # exists to prevent.
    run bash -c "sed -n '/^## Declared state/,/^## /p' '$REPO/INGREDIENTS.md' \
        | grep '^- ' | grep -cvE '^- (upstream|pins|openssh|opencore-config): '"
    [ "$output" = "0" ]
}

@test "every declared-state path exists" {
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        [ -e "$REPO/$p" ] || { echo "declared but absent: $p"; false; }
    done < <(sed -n '/^## Declared state/,/^## /p' "$REPO/INGREDIENTS.md" \
             | sed -n 's/^- [a-z-]*: //p' | cut -d: -f1)
}

@test "the version-scheme deviation names the self-upstream shape, not a bare refusal" {
    run bash -c "sed -n '/^## Conformance deviations/,/^## /p' '$REPO/INGREDIENTS.md' \
        | grep '^- version-scheme' | grep -ci 'self-upstream'"
    [ "$output" -ge 1 ]
}

@test "every declared deviation still carries a reason" {
    run bash -c "
        sed -n '/^## Conformance deviations/,/^## /p' '$REPO/INGREDIENTS.md' \
        | grep '^- ' \
        | grep -cvE '^- [a-z][a-z0-9_-]*(:[^ :]+)?: +\\S'"
    [ "$output" = "0" ]
}
```

- [ ] **Step 2: Run to verify it fails.** Run: `bats tests/release.bats`

- [ ] **Step 3: Make the four edits (a)–(d).**

- [ ] **Step 4: Run the tests, then the suite, then commit**

```bash
bats tests/release.bats && ./bin/run-tests.sh
git add INGREDIENTS.md docs/decisions/0012-version-scheme.md tests/release.bats
git commit -m "INGREDIENTS: declare the release state; narrow the version-scheme deviation"
```

---

### Task 12: the spec, and the decision record

**Files:** Modify `docs/superpowers/specs/2026-09-17-mavericks-guest-design.md`

**This task was performed in the same pass that wrote this plan** — the spine was stale in four places and could not be left that way while a plan argued from it. It is listed here so the work is tracked rather than invisible. An executor picking up this plan should verify the edits are present and move on.

What changed:

1. **P4's row.** Removed *"Not delivered: post-10.9.5 updates (`--updates` has one value; `open-questions.md` Q1 is still open)"*. Q1 was answered 2026-09-22 — two images, `none` for the P5 baseline and `security` as the default — and is being implemented now (task #40). The row says that.
2. **P5's row.** "not started" → **deferred by choice**, with the reason: the guest is working well enough, and `decisions/0007` says P5 measures Product A's `run`, so P5 wants shipping to have happened first.
3. **P6's row.** Removed *"Also depends on the keypress defect"*. That defect was fixed 2026-09-17 (`NOTES.md:1541`: *"the keypress requirement is fixed… 99.78% of pixels lit"*), which also makes the "Not met" note in the spec's own P3 section stale. Both corrected. **This was not on the commission's list; it is a third piece of staleness found while fixing the first two.**
4. **P7's row.** "Guest integration, deferred" predates the product decision. Split per `decisions/0007`: the interop half becomes `emit` subcommands and ships in P8 (Packer only); the guest-side half (M0–M6) stays deferred and is Product B's line.
5. **Three new phases and three status words.** P8 (`vmavs`, the front door) is **next**; P9 (build in a controlled Linux VM) is **blocked on a decision**; P10 (release packaging and distribution) is **blocked on P9**. The status column now distinguishes *deferred by choice* from *not reached* from *blocked on a decision*, and a line under the table says the numbers are identities rather than an order.
6. **§5.1 repository layout** gains `bin/vmavs`, `build/version.sh`, `UPSTREAM_VERSION` and `emit/`.
7. **§1 success criteria** gains a shipping row, keyed to `decisions/0007` rather than presented as a fifth user goal — the four goals are the user's words and this criterion arrived later.

- [ ] **Step 1: Verify the seven edits are present.** `grep -n 'P8\|P9\|P10\|deferred by choice\|blocked on' docs/superpowers/specs/2026-09-17-mavericks-guest-design.md`
- [ ] **Step 2: Run the suite.** `./bin/run-tests.sh`

---

## Phase C — release packaging and distribution: designed, deliberately not scheduled

**This phase has no tasks, on purpose.** The user's ordering is CLI → build VM → release packaging, and the reason is material rather than administrative: the build-VM spec's headline number is that **the host tool list shrinks from 36 to about 7** (`2026-09-21-build-in-a-linux-vm-design.md` §9.1, stated there as *"the portability win, stated as a number"*). Choosing a distribution mechanism now would mean writing packaging metadata for a dependency list we are about to delete, and packaging metadata is exactly the kind of thing that outlives the reason it was written.

What follows is the shape, so that when P9 resolves this becomes an hour of planning rather than a re-derivation.

### The distribution question, held open

Two candidate worlds. **Neither is chosen here.**

| If the build VM is **not** adopted | If the build VM **is** adopted |
|---|---|
| ~36 executables plus a development header, on the host. Realistically: `git clone`, or a distro package with a long `Depends`. A tarball would install in seconds and then fail at `boot-stack` on a host missing `iasl`, which is the worst of both. | QEMU plus a handful. A tarball, a single pkgsrc package, or a Homebrew formula each become reasonable, because the dependency list fits on one line. |

Two things are worth saying about that table. First, **`vmavs doctor` (Task 3) is what makes either world tolerable**, because it tells someone what they can do rather than refusing to start — and it is built now, in the CLI phase, precisely so it exists before the packaging decision does. Second, **pkgsrc is the only candidate that covers all four targets from one recipe** — NetBSD natively, Linux and macOS through the bootstrap, and 10.9 itself for `decisions/0007` Decision 3. That is an argument from host coverage; the user being a pkgsrc developer is context and not the reason. Homebrew covers neither NetBSD nor 10.9, so it adds a packaging system rather than replacing one, and is recorded as a want.

**Whether pkgsrc still supports 10.9 in 2026 has not been checked.** Nobody here has verified it, and this plan does not assert it.

### The abandon thresholds P10 is conditional on

P9's own spec, §7.4, names three. If any is hit, the build VM stays an optional backend for foreign hosts and the first column of the table above is the world we are in:

| Threshold | Consequence |
|---|---|
| Cold boot stack in the VM > **1.5×** native on the same host (against 230 s and 236 s measured natively, 2026-09-21) | Too expensive for the interactive loop |
| Warm rebuild > **60 s** (against 31 s native for both stages) | Incremental development damaged |
| `--freshness` > **10 s** | The cheap-freshness assumption is refuted |

So P10 is conditional on the build VM being **adopted**, not merely attempted.

### The release workflow, specified

`.github/workflows/release.yml`, when it is written:

- **Model: deliberate publish.** Publish only from a tag or a `workflow_dispatch`, never from a push to `main`. The same column `mavericks-porthole`, `clang` and `tailscale` are in. Reason: the artifact is a recipe that builds a 60 GB image out of Apple's bytes, and nothing in CI can boot a guest to check it — CI has neither nested virtualization nor Apple's media. A build that cannot verify its own product should not publish unattended.
- **Three triggers**, the family's shape: `push: tags:['*.*']`, `pull_request: branches:[main]` (the automerge gate the shared Renovate preset's `ignoreTests: false` needs — `ci.yml` already provides a status check on PRs, so this is belt and braces), and `workflow_dispatch` with a `local_release` boolean.
- **`concurrency`** exactly as the family specifies — group keyed on `github.run_id`, `cancel-in-progress` naming `pull_request`. Check 1b enforces both halves, and either alone lets the shape back in that lost `mavericks-golang` a release thirteen seconds after the run that evicted it.
- **A `ver` step** calling `sh build/version.sh auto|local` (Task 1), with `fetch-depth: 0` — N comes from the tags — and forcing `release=no` when the ref is not `main`.
- **The artifact is `git archive` of the tag and nothing else.** This is a constraint, not a convenience: `bin/no-apple-bytes.sh` checks exactly what `git archive` would package, so a tarball assembled any other way would make the gate partial (Task 10).
- **`bin/no-apple-bytes.sh "$TAG"` runs in the release job, gating the upload.** Not only in `ci.yml`. The rule is "a release must contain no Apple bytes"; checking it on pull requests and not on the release checks the wrong artifact.
- **Release notes** from `sh "$SHIPYARD_SCRIPTS/release-notes.sh" --tag "$TAG" --version "$FULL" --product <noun> --out dist/RELEASE_NOTES.md`, with **no `--min-os`** — this product is not a 10.9 `.pkg` and the install-floor line would be false. The `--product` noun is a per-repo decision and is not made here; it depends on the rename.
- **`release-notes/README.md`** explaining that a `<full-version>.md` file is optional hand-written prose inserted after the generated title, and must not carry its own `## ` heading.
- **Declared state**: `release-state-record.sh --notes-file dist/RELEASE_NOTES.md --digest "$(release-state.sh)"` in the build job, **before** packaging — never at publish time. Plus a ten-line `reconcile.yml` caller with its own `permissions: {contents: read, actions: write}`, because a called workflow may not ask for more than its caller grants.
- **Publish** via `Mavergreen/shipyard/.github/workflows/publish-release.yml@v1`.
- **No Sparkle, no `sign_and_appcast.sh`, no `scan-for-key.yml`.** The existing `sparkle-updater:` deviations in `INGREDIENTS.md` already cover this: Sparkle is a macOS framework and this tool's primary hosts are Linux and NetBSD.

**One consequence to expect on the day `release.yml` lands:** `.github/workflows/conventions.yml` currently passes trivially, because the family gate's first act is to look for `release.yml` and exit early when there is none — its own header says so. The moment the file exists, every check fires at once. Budget for that being the interesting part of the task rather than a formality.

### Also deferred, and cheap

`comment-reasons` (family-conventions check 15) is opt-in and only applies in a repo that has one. This repository has no comment debt sweep scheduled, so the file is not added; adding it would redden the gate against every comment in a 68 KB `build-image.sh`. Worth doing, worth doing deliberately, not worth doing as part of shipping.

---

## Self-review

**Spec coverage.** `decisions/0007`'s ten subcommands: `doctor` Task 3; `fetch`, `boot-stack`, `media`, `install`, `image` Task 4; `clone`, `run`, `ssh` Task 5; `emit` Task 6. The commission's five numbered items: (1) `vmavs`'s location and the existing entry points → the two-decisions section plus Tasks 2 and 8; (2) release machinery → Task 1 (version), Task 10 (the gate), Phase C (`release.yml`, `release-notes/`); `renovate.json` needed no task and the finding is stated up front; (3) README → Task 9; (4) distribution → Phase C, held open, per the ordering change; (5) the phase spine → Task 12, done in this pass. The two binding constraints — never publish the image, Apple-only OS — appear in Global Constraints, in Task 6's emitter, in Task 10's gate and in Phase C's `git archive` constraint.

**Placeholders.** None. Every step carries the actual file content, the actual test, or the actual edit. Where something is unknown it is named as unknown: no Packer has parsed the template (Task 6), macOS and NetBSD have never been run (Task 3, README), pkgsrc's 10.9 support is unverified (Phase C).

**Type consistency.** `vmavs_tools_for` and `vmavs_subcommand_verdict` (Task 3) are used under those names in `bin/preconditions.sh` and `tests/doctor.bats`. `vmavs_hint` (Task 8) is used under that name in six scripts and in `tests/common.bats`. `build/version.sh`'s `FULL=`/`TAG=`/`RELEASE=` output (Task 1) is consumed by `bin/vmavs`'s `version()` (Task 2) and by Phase C's `ver` step. `SUBCOMMANDS` and `BUILD_IMAGE` are defined in Task 2 and extended in Tasks 3–7.

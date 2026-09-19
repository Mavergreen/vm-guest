# 0007 — What this project ships, and what it is called

Date: 2026-09-19
Status: accepted — the product decision; the repository rename is pending
the user's go-ahead

## Context

P4 finished, so for the first time there is something to ship rather than
something to get working. That makes the product question answerable, and
it needs answering before P5 measures anything or P6 releases anything —
both will bake assumptions about what the artifact *is* into places that
are expensive to change later.

This repository is one of about forty `mavericks-*` projects. The family
has conventions, held in the `modernmavericks-conventions` skill, and the
governing rule is: **match the family unless the product genuinely
differs — and when you deviate, say so.** A silent deviation reads as a
mistake; a documented one reads as a decision.

So the question is not only "what do we ship" but "how much of the family
shape applies to us".

## The family shape, and where we sit in it

Every sibling cross-builds one upstream thing into a **Mac OS X 10.9**
compatible `.pkg` with a Sparkle updater, on a modern Apple-Silicon
runner, with no 10.9 build machine anywhere.

We invert that. Our artifact *runs* Mavericks, and it runs on the host.

That looks at first like a wholesale deviation. It is not: it is a split.
Two products live here, and only one of them departs from the family.

## Decision 1 — two products

**Product A, the host-side tool.** A shell program with subcommands,
running on Linux, macOS, NetBSD — and, per Decision 3 below, eventually on
10.9 itself. Its subcommands are not a new invention; they are the stages
`image/build-image.sh` already has:

| Subcommand | Stage it already is |
|---|---|
| `doctor` | host capability probe — KVM? HVF? nvmm? QEMU version? nested virt? |
| `fetch` | `esd` — Apple's `InstallESD.dmg`, with the pinned checksum |
| `boot-stack` | `opencore`, `ovmf`, `efi` — built from pinned source, Tier 0 |
| `media` | `media` — host-native installer media, no root |
| `install` | `target`, `install` — unattended, to a golden image |
| `clone` | overlay from golden |
| `run` | boot a clone |
| `ssh` | into a running guest |
| `emit` | libvirt XML, Vagrant box, Proxmox config, `.utm`, container recipe |
| `image` | the whole chain — what `build-image.sh` is today, and what people will actually run |

Shell is the right language: the work is orchestrating `qemu`, `hdiutil`,
`mkfs`, `xar` — process-spawning glue — and it is already written. The
portability seam also already exists. `lib/privops.sh` is precisely where
the macOS-native, NetBSD-`makefs` and Linux backends diverge, and it was
parameterized for exactly this reason.

**Product B, the guest-side payload.** This one is a textbook family
citizen, and we built it in P4 without noticing what it was:
`image/payload/` emits a real flat `.pkg` that Apple's own installer
consumes. Add the USB tablet kext, a display/resolution helper, and
eventually the Actions runner agent, and it is a `.pkg` installed on 10.9
with a 10.9.5 install floor — needing no exception from the family at all.

## Decision 2 — the sibling boundary, and the rename

The sibling currently checked out as `mavericks-hypervisor` ships
**Hypervisor.framework for 10.9** — and, likely, a prepackaged QEMU
alongside it — so that modern QEMU can use hardware acceleration *on*
Mavericks. That is Mavericks as a **host**. This repository is Mavericks
as a **guest**, under HVF, KVM, NVMM, or whatever comes next.

They are orthogonal, and they stay separate repositories. Folding them
together would give one repo too many shipped products, which the family's
release, versioning and conformance machinery assumes against.

The dependency between them points one way at runtime: **we emit, it
runs.** The host project is a host target in `docs/test-hosts.md` and a
consumer of `emit`'s output. Nothing in the shipped guest stack depends on
it. (Decision 3 adds a *build-time* dependency in one direction only —
running our tool on 10.9 needs a QEMU there — which is a different thing
and does not change this one.)

### The names

| | Local worktree | Published |
|---|---|---|
| Host side | `mavericks-vm-host` | `ModernMavericks/vm-host` |
| Guest side | `mavericks-vm-guest` | `ModernMavericks/vm-guest` |

So: **`mavericks-qemu-guest` → `mavericks-vm-guest`**, publishing as
`ModernMavericks/vm-guest`.

The family's convention, confirmed against `openssh`, `golang` and
`shipyard`, is that a local `mavericks-X` publishes as
`ModernMavericks/X` — the organization name already carries "Mavericks",
so the repository name does not repeat it. That rules out the obvious
short name: `mavericks-guest` would publish as `ModernMavericks/guest`,
which says nothing. `vm-guest` survives the trip.

`qemu-guest` fails for two further reasons. It names one backend, when
P7's whole point is that the stack ports to Proxmox, libvirt, UTM,
VirtualBox, Vagrant and containerised QEMU — so the name would become
wrong precisely when the work succeeded. And it names the wrong side of
the relationship. `vm-host` / `vm-guest` reads as a pair without
explanation, and `vm-host` is the broader word, with room for the
prepackaged QEMU that `hypervisor` would have excluded.

**Neither repository has a git remote yet.** There is no published name,
no release and no package for anyone to depend on, so the rename costs
nothing today and will not be free for long.

## Decision 3 — the 10.9 target, which reverses an earlier assumption

Once `vm-host` ships, **someone will want to run the host-side tool on
Mavericks** to build and run a Mavericks guest. So Product A has a 10.9
target after all, and is a proper family citizen with a real `.pkg`
rather than the deviation it first appeared to be.

This names a dependency that was previously vague. Running our tool on
10.9 needs **a QEMU on 10.9** — not merely HVF — so it depends on
`vm-host` shipping the prepackaged QEMU, not just the framework. That is
a build-time dependency in one direction, and it is worth stating because
"once `vm-host` ships" is otherwise easy to read as a milestone that HVF
alone would satisfy.

This also yields the strongest integration test available — Mavericks
hosting Mavericks — and the strongest triangulation host, since a tool
that works there works anywhere.

Stock 10.9 ships `bash` 3.2, so the cost of keeping this option is small
and bounded: fourteen `mapfile` calls and one `declare -A`, plus a lint so
it does not regress. That work is tracked separately and is being done now
rather than later, because it is fifteen lines today and a rewrite once
the codebase has tripled.

The constraint's real shape is worth stating precisely, because it is easy
to over-apply: every shebang here is `#!/usr/bin/env bash`, so a pkgsrc or
Homebrew bash on 10.9 satisfies us regardless. **The 3.2 floor binds only
against what Apple shipped.**

## What the family gives us for free

The ingredient-pinning apparatus fits us better than it fits most
siblings. `INGREDIENTS.md` with file-based pins, a Renovate custom manager
for each, and the `repackage-on-ingredient-bump` caller is *exactly* the
Tier 0/1/2 provenance scheme from `decisions/0004`, with the family's
names on it. `vendor/sources.tsv` is already the pin file; it is simply
not wired up yet.

Doing that early rather than late matters for a specific reason: Renovate
bumping the OpenCore or EDK II pin is precisely the event that will
silently invalidate a golden image, and the family already has machinery
to make that visible.

One conformance check is ours alone and earns its keep: **a release must
contain no Apple-derived bytes.** That is the never-publish rule expressed
as a package-time gate rather than a habit. It is satisfied automatically,
because the tool fetches at runtime — which is the reason to check it
rather than a reason not to.

## Declared deviations

Per the family rule, with reasons, to be transcribed into
`INGREDIENTS.md` scoped to filename globs (an entry without a reason
fails the gate):

| Deviation | Reason |
|---|---|
| Version scheme is not `<upstream>-mavericks.N` | There is no single upstream. OpenCore, EDK II, QEMU and 10.9.5 move independently, so the scheme has no slot to fill. Product A versions on its own, and `INGREDIENTS.md` carries which ingredient moved. |
| Product A has no Sparkle updater | Sparkle is a macOS framework; Product A's primary hosts are Linux and NetBSD. Product B, which is a 10.9 `.pkg`, takes the family's Sparkle shape unchanged. |

## Consequences

- **The transitional piece, with its exit condition.** Product B stays in
  this repository for now. It **moves to `mavericks-vm-guest-additions` (publishing as `ModernMavericks/vm-guest-additions`) when a
  second guest-side component ships** — the tablet kext or the runner
  agent, whichever lands first. Stated because the family's own rule is
  that a transitional decision without an exit task is a permanent one.
- **P5 measures Product A's `run`**, so its baseline is a baseline of the
  shipped thing rather than of a scratch invocation.
- **P6 ships Product A under `--accel tcg`**, and the runner agent becomes
  Product B's second component — which is what triggers the split above.
- **P7's interop targets are `emit` subcommands**, not a separate export
  tool.
- **The rename is not done yet.** Moving the working directory and
  renaming the GitHub repository both reach outside this directory, so
  they wait for the user. Everything else in this decision stands
  independently of when that happens.

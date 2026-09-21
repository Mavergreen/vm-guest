# Ingredients

Every input baked into what this project produces: where it is pinned, its
Renovate status, and what a bump does.

An ingredient with neither a tracker nor a written reason is a silent
staleness hole, so every row below has one or the other. Where no clean
datasource exists, the row says so and says what compensates — a fragile
tracker invented to fill a cell (scraping a download page for a date) is
worse than an honest blank.

The pin registry is `vendor/sources.tsv`: name, URL, sha256. The checksum
is the identity; the URL is only how to get it.

## What a bump does here is not what it does in a sibling

**This is the one place this repository genuinely differs from the family,
and it is worth its own section.**

Every sibling ships a **built artifact**. An ingredient moves, shipyard's
`repackage-on-ingredient-bump` caller dispatches a release, the rebuilt
`.pkg` supersedes the old one, and what is published is never stale for
long.

We ship a **recipe**. Our release contains no image — it cannot, because
the image is made of Apple's operating system and this project never
publishes that (see `README.md`'s ground rules and `bin/no-apple-bytes.sh`,
which enforces it). So a bump here obsoletes nothing published.

That sounds harmless. It is not, and the real consequence is sharper than
the one the family's machinery was built for: **a bump silently invalidates
every golden image already on disk.** Renovate moves the OpenCore pin; a
nine-gigabyte golden built last week is now something no commit in this
repository can reproduce. Nothing fails. Nothing goes red. The image still
boots. It simply no longer means what its manifest says it means, and the
first symptom is someone debugging a difference between two guests that
were supposed to be the same.

### What we chose

**The manifest is the mechanism, and staleness is a question you can ask.**

1. `image/build-image.sh` records **every pin** in each image's manifest —
   one `ingredient.<name>` line apiece, plus an `ingredients` digest over
   the lot (`bin/ingredient-fingerprint.sh`).
2. `image/compare-images.sh` diffs manifests, so it now **names the
   ingredient** that differs between two images rather than reporting that
   they differ. That came for free from (1).
3. `bin/image-staleness.sh <manifest>` answers the question you actually
   have before you run a guest: *is this image still made of what the
   repository is made of?* It prints each pin that moved, on both sides.
   A manifest written before this existed reports "cannot be determined",
   which is deliberately a different answer from "fine".
4. **The pipeline asks the same question of itself, per stage.** (1)–(3)
   all judge a *finished* image; they cannot stop one being made wrong.
   `image/build-image.sh` used to skip a stage whenever its output file
   was present — so a bumped OpenCore pin left the built `.efi` sitting
   there, the stage skipped, and the image came out of stale firmware
   without a word. Each stage now records the inputs it consumed in an
   `<output>.inputs` file beside its output and reruns when that record
   stops matching, **naming what moved**: `opencore: inputs changed
   (source:opencorepkg-src)`. The listing comes from
   `bin/ingredient-fingerprint.sh --stage <name>` — the same
   list-and-digest scheme one level down, not a second one — with the
   half only the pipeline knows (checksums of earlier stages' outputs, the
   accelerator, the SSH key) passed in as `key=value`.
   `image/build-image.sh --freshness` answers "would my next build rebuild
   the firmware, and why" in a second instead of in fourteen minutes.

Chosen over a staleness **warning on `run`** — which was the other
candidate — because `run` is the hot path and the check needs the image's
manifest, not the image. A warning on every boot is a warning nobody reads
by the third one. `image-staleness.sh` is cheap to call from a wrapper, a
pipeline or a shell prompt if that turns out to be wanted; the mechanism
does not presuppose the policy.

### `repackage-on-ingredient-bump`: not applicable, and why

The family's caller **does not apply to this repository.** Recording that
explicitly rather than omitting it silently, per the skill's instruction:

- The caller's whole job is to dispatch `release.yml` so a **new artifact**
  ships with the new ingredient. We publish no artifact for an ingredient
  to get baked into. There is nothing to repackage.
- Its companion version axis, `-mavericks.N`, we do not use either — see
  the deviations block below.
- `check-ingredient-pins.sh` runs in CI anyway
  (`.github/workflows/ci.yml`). It passes trivially for a repo with no
  caller. It is wired now so that the day P6 adds `release.yml` and a
  caller becomes meaningful, the gate is already watching.

## The registry

| Ingredient | Pinned in | Renovate | On bump |
|---|---|---|---|
| **OpenSSH for the guest** (`ModernMavericks/openssh`, two product archives per release) | `components/openssh/version` (tag `<upstream>-mavericks.N`) | ✅ `github-releases` on `ModernMavericks/openssh`, with a `regex:` versioning that captures `N` — default versioning coerces `-mavericks.N` away, every release then compares equal and the pin never moves again (swift-runtime missed three toolchain releases exactly this way) | Future images install the new OpenSSH. No checksum to update: `image/fetch-openssh.sh` reads the asset names *and* their checksums out of the pinned release's own `SHA256SUMS`, so the bump is self-verifying and a renamed asset prefix cannot 404 across it |
| **OpenCore** (`acidanthera/OpenCorePkg`, built from source — Tier 0) | `vendor/sources.tsv` `opencorepkg-src` | ✅ `github-tags` on `acidanthera/OpenCorePkg`. **Automerge off** — see below | Rebuilds the boot stack; invalidates existing goldens. The `sha256` column must be re-pinned in the same commit, which `bin/verify-changed-sources.sh` enforces |
| **EDK II / audk** and its twelve submodules (Tier 0) | `vendor/sources.tsv` `audk-*` | ❌ **untrackable as pinned.** Each is a GitHub archive tarball of a bare commit with no ref beside it, so there is no `currentValue` for a `git-refs` manager to move, and a digest-only manager would rewrite the URL while leaving a checksum it cannot compute. **Compensates:** every one is checksummed, `boot/build-opencore.sh` refuses a URL naming a commit other than the one it declares, and they move only when the OpenCore pin does — `acidanthera/audk` is OpenCore's own build tree, not an independent upstream | Only ever bumped deliberately, together with OpenCore |
| **ocbuild `efibuild.sh`** (Tier 0, build script) | `vendor/sources.tsv` `ocbuild-efibuild` | ❌ **untrackable.** A `raw.githubusercontent.com` URL at a commit on `master`; there are no releases and no tags to track. It used to be `curl`ed off `master` and `eval`ed, which is what the pin replaced. **Compensates:** pinned commit + checksum, and `boot/patches/0001-*` makes `build_oc.tool` source the pinned copy rather than fetch one | Deliberate, alongside OpenCore |
| **Lilu** (SMC injection, Tier 1 release binary) | `vendor/sources.tsv` `lilu-release` | ✅ `github-releases` on `acidanthera/Lilu`, with an `autoReplaceStringTemplate` — the version appears **twice** in one URL and a manager that rewrote only the captured occurrence would leave a half-updated URL that 404s. **Automerge off** | New kext in every future image. Re-pin the checksum; re-read `boot/config/README.md`, which records how each version's 10.9 (Darwin 13) support was verified |
| **VirtualSMC** (Tier 1 release binary) | `vendor/sources.tsv` `virtualsmc-release` | ✅ as Lilu | as Lilu |
| **`boot/config/config.plist`** (OpenCore's configuration) | ours, in-tree | n/a — we author it | Changes how every future image boots. Counted as an ingredient by `bin/ingredient-fingerprint.sh` precisely because it is as much an input as OpenCore is |
| **Apple's `InstallESD.dmg`, 10.9.5** | `vendor/sources.tsv` `apple-installesd-10.9.5` | ❌ **untrackable, and deliberately so.** Apple publishes no feed, and the pin names one immutable build: 10.9.5 is 10.9.5 forever. There is no newer version of this ingredient to track. (Whether an image should carry Apple's *post*-10.9.5 updates is `docs/open-questions.md` Q1, held open behind `build-image.sh --updates`.) **Compensates:** the transfer is plain HTTP over an `osrecovery.apple.com` AssetToken handshake, so the checksum is the only integrity there is, and `media/fetch-installesd.sh` enforces it | Never bumps. **Never enters the repository, in any form** — `bin/no-apple-bytes.sh` is the gate |
| **QEMU, on the host** | not pinned | ❌ **unpinnable by us.** It is the user's, from their platform, on Linux/macOS/NetBSD alike. Pinning a QEMU would mean shipping one. **Compensates:** the version is recorded in every image manifest (`qemu` field), `bin/preconditions.sh` checks what the pipeline needs of it, and `docs/host-profile.md` records what this host has | Nothing automatic. A manifest says which QEMU produced an image |
| **The host C compiler** (builds OpenCore and OVMF — the one Tier 0 input that is not pinned) | not pinned. **Range-checked** in `lib/compiler.sh`: **gcc 13 through 14, verified only at gcc 13.3.0**, enforced by `boot/build-opencore.sh` and `boot/build-ovmf.sh` before they build | ❌ **unpinnable by us, like QEMU** — it is the host's, from its distribution. Tracking a version we do not choose would produce PRs nobody can act on. **But unlike QEMU its output is baked into shipped bytes**, which is why it is a row here and not in the build-tools row below: OpenCorePkg 1.0.7 does not compile *at all* under a C23-default gcc, and OvmfPkg compiles clean and emits a *different* `OVMF_CODE.fd`. **Compensates — five things, deliberately not a pin:** the C dialect is stated rather than inherited (`-std=gnu17`, `boot/patches/0002-*`); upstream's `-Werror` is no longer inherited either (`-Wno-error`, `boot/patches/0003-*`), because a warning a newer compiler invents in code we pin and cannot patch should not stop our build — the warnings are still printed, and our own shell and tests keep every gate they have; the range check refuses below the floor and warns above the ceiling; every image manifest carries `compiler` (which one) and `compilerrange` (whether we claimed to support it *then*); `docs/host-profile.md` G22 and `decisions/0004` carry the reasoning. **Why not pinned:** `decisions/0004` chose (b) over (c) — a container or bootstrapped GCC is the only thing that makes the same sources produce the same bytes, and it is the right answer *if these images ever have to be independently verifiable*, but P6 has not said what CI needs and it is a lot of machinery for a project that otherwise needs only a shell and a package manager | Nothing automatic — the host bumps it, not us. A host outside the range hears about it at build time instead of in a checksum diff. **The range itself moves only on evidence**: gcc 15 is outside it today because nobody has built with gcc 15, and the pending re-run is what would change that (`decisions/0004`, "Answered") |
| **`utm-bundle`, `opencore-legacy-img`** (Tier 2 reference blobs) | `vendor/sources.tsv` | ❌ **deliberately untracked.** They are de-risking scaffolding, not shipped inputs: `bin/tier-check.sh --strict` fails the suite if any profile in `vm/profiles/` references the Tier 2 quarantine, which is P3's exit gate and has been met. A blob nothing ships cannot go stale in anything | Never bumped. If one ever needed to be, that is a sign it stopped being Tier 2 |
| **shipyard** (`check-family-conventions.sh`, `check-ingredient-pins.sh`, `deviations.sh`, `templates/msc.sh`) | `@v1` in `.github/workflows/*.yml` | ✅ tracked by Renovate's native `github-actions` manager, as the family intends — `@v1` is a moving major tag | Gate behaviour changes; `build/msc.sh` must still match `$SHIPYARD_SCRIPTS/templates/msc.sh` byte for byte. **Never edit our copy** — fix the template upstream |
| **`bats`, `shellcheck`, `python3`, `dmg2img`, `sgdisk`, `mkfs.hfsplus`** | not pinned | ❌ **not ingredients.** They are build-host tools: none of their bytes reaches an image, which is exactly what separates them from the compiler row above — `gcc` is a build-host tool too, and its output ships. `bin/run-tests.sh` and `bin/preconditions.sh` check for what they need | n/a |

### Why the boot stack does not automerge

The shared Renovate policy is "if it builds and passes, it ships", and asks
a repo to state a reason wherever it restricts that. Ours:

- **A bad bump here builds fine and is wrong.** A green suite here means
  the shell is clean and the profiles are Tier 0/1 — it does not mean the
  guest boots. Nothing in CI boots a guest; nothing can, without nested
  virtualization and Apple's media.
- **The checksum arrives stale.** Renovate can move a URL in
  `vendor/sources.tsv`; it cannot compute the `sha256` beside it. The
  bump PR is therefore internally inconsistent by construction, and
  `bin/verify-changed-sources.sh` is what turns that from a half-hour
  failure in someone's build into a red PR.
- **It invalidates golden images**, per the section above — a human should
  see that happen.

## Conformance deviations

Transcribed from `docs/decisions/0007-what-this-project-ships.md`, which is
where the reasoning lives. Scoped to filename globs, each with a reason --
`deviations.sh` rejects an entry that has no reason, because an exception
without one is indistinguishable from drift.

- version-scheme:image/build-image.sh: there is no single upstream to name. OpenCore, EDK II, QEMU and Apple's 10.9.5 move independently, so `<upstream>-mavericks.N` has no slot to fill; the host-side tool versions on its own and this file carries which ingredient moved
- version-scheme:vm/*.sh: same reason -- the host-side tool is one product across these files, and a deviation scoped to only one of them would quietly license the rest to drift
- sparkle-updater:image/build-image.sh: Sparkle is a macOS framework and the host-side tool's primary hosts are Linux and NetBSD. The guest-side payload, which IS a 10.9 .pkg, takes the family's Sparkle shape unchanged
- sparkle-updater:vm/*.sh: same product, same reason, scoped the same way

## No upstream release notes

No upstream release notes: this repository has no single upstream whose
notes a release could link. Each ingredient's notes live with its own
project — `acidanthera/OpenCorePkg`, `acidanthera/Lilu`,
`acidanthera/VirtualSMC`, `ModernMavericks/openssh` — and the registry row
above names each one, which is the closest thing to "what changed" that a
product with a dozen upstreams can honestly offer.

## Provenance

`docs/decisions/0004-p3-boot-stack-provenance.md` is the tier scheme these
rows are an instance of: **Tier 0** built from pinned source, **Tier 1**
vanilla upstream binaries pinned and checksummed, **Tier 2** reference
blobs that must never reach a shipped profile. `bin/tier-check.sh --strict`
enforces the last one and runs in the suite.

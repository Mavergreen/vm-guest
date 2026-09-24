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

## Declared state

A release is the realisation of a declared state, not the side effect of a
push. These are the inputs whose movement should cut one. Deliberately a
SUBSET of the registry table above: `bats` moving must never cut a release.

- upstream: UPSTREAM_VERSION
- pins: vendor/sources.tsv
- openssh: components/openssh/version
- opencore-config: boot/config/config.plist

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

### `repackage-on-ingredient-bump`: no caller declared, and a narrower reason than it used to be

**The old argument, and why it was right for the world it was written in.**
This section used to say the family's caller does not apply here at all:
its whole job is to dispatch a release so a **new artifact** ships with the
bumped ingredient, and we publish no artifact for an ingredient to get
baked into — there was nothing to repackage. That was written when there
was no release mechanism of any kind, and for that world it was correct.

**What changed is not the product. It is what "artifact" means once a
release exists.** `docs/decisions/0012-version-scheme.md` gives the
version scheme a release actually cuts on, and once that exists, what gets
published is the **recipe** — `bin/vmavs` and everything it drives —
never the image, per `bin/no-apple-bytes.sh`. A moved pin is exactly what
changes what that recipe builds. Someone who installs `vmavs` at last
month's release runs last month's OpenCore pin from then on, silently,
which is staleness in the only sense a published recipe can have it. That
is precisely the case the family's caller exists to catch, so "does not
apply" was too broad a claim; "no caller is declared yet" is the accurate
one.

**What is still true, unchanged by any of this:**

- The manifest mechanism in the section above is the actual fix, and it
  does not depend on whether anything is published: every pin lands in
  the manifest (1), `image/compare-images.sh` names what differs between
  two images (2), and `bin/image-staleness.sh` (3) answers whether a
  built image still matches the repository — a question worth asking
  whether or not a release exists.
- **A moved pin invalidates every golden image already on disk regardless
  of publishing.** That was true before this file existed and stays true
  whether or not a release ever ships.
- **No caller exists to be declared yet, because no `release.yml` exists
  yet.** Phase C — release packaging and distribution — is designed but
  deliberately unscheduled (`docs/superpowers/plans/2026-09-22-shipping-vmavs.md`);
  P10 is blocked on P9, and P9 is itself blocked on a decision. Nothing
  here should be read as claiming a caller or a release workflow is
  wired up.
- `check-ingredient-pins.sh` runs in CI anyway
  (`.github/workflows/ci.yml`). It passes trivially for a repo declaring
  no caller. It is wired now so that the day a caller lands, the gate is
  already watching it.

The Sparkle deviation two lines below this section is untouched by any of
this — it was never an argument about publishing.

## The registry

| Ingredient | Pinned in | Renovate | On bump |
|---|---|---|---|
| **OpenSSH for the guest** (`Mavergreen/openssh`, two product archives per release) | `components/openssh/version` (tag `<upstream>-mavericks.N`) | ✅ `github-releases` on `Mavergreen/openssh`, with a `regex:` versioning that captures `N` — default versioning coerces `-mavericks.N` away, every release then compares equal and the pin never moves again (swift-runtime missed three toolchain releases exactly this way) | Future images install the new OpenSSH. No checksum to update: `image/fetch-openssh.sh` reads the asset names *and* their checksums out of the pinned release's own `SHA256SUMS`, so the bump is self-verifying and a renamed asset prefix cannot 404 across it |
| **OpenCore** (`acidanthera/OpenCorePkg`, built from source — Tier 0) | `vendor/sources.tsv` `opencorepkg-src` | ✅ `github-tags` on `acidanthera/OpenCorePkg`. **Automerge off** — see below | Rebuilds the boot stack; invalidates existing goldens. The `sha256` column must be re-pinned in the same commit, which `bin/verify-changed-sources.sh` enforces |
| **EDK II / audk** and its twelve submodules (Tier 0) | `vendor/sources.tsv` `audk-*` | ❌ **untrackable as pinned.** Each is a GitHub archive tarball of a bare commit with no ref beside it, so there is no `currentValue` for a `git-refs` manager to move, and a digest-only manager would rewrite the URL while leaving a checksum it cannot compute. **Compensates:** every one is checksummed, `boot/build-opencore.sh` refuses a URL naming a commit other than the one it declares, and they move only when the OpenCore pin does — `acidanthera/audk` is OpenCore's own build tree, not an independent upstream | Only ever bumped deliberately, together with OpenCore |
| **ocbuild `efibuild.sh`** (Tier 0, build script) | `vendor/sources.tsv` `ocbuild-efibuild` | ❌ **untrackable.** A `raw.githubusercontent.com` URL at a commit on `master`; there are no releases and no tags to track. It used to be `curl`ed off `master` and `eval`ed, which is what the pin replaced. **Compensates:** pinned commit + checksum, and `boot/patches/0001-*` makes `build_oc.tool` source the pinned copy rather than fetch one | Deliberate, alongside OpenCore |
| **Lilu** (SMC injection, Tier 1 release binary) | `vendor/sources.tsv` `lilu-release` | ✅ `github-releases` on `acidanthera/Lilu`, with an `autoReplaceStringTemplate` — the version appears **twice** in one URL and a manager that rewrote only the captured occurrence would leave a half-updated URL that 404s. **Automerge off** | New kext in every future image. Re-pin the checksum; re-read `boot/config/README.md`, which records how each version's 10.9 (Darwin 13) support was verified |
| **VirtualSMC** (Tier 1 release binary) | `vendor/sources.tsv` `virtualsmc-release` | ✅ as Lilu | as Lilu |
| **`boot/config/config.plist`** (OpenCore's configuration) | ours, in-tree | n/a — we author it | Changes how every future image boots. Counted as an ingredient by `bin/ingredient-fingerprint.sh` precisely because it is as much an input as OpenCore is |
| **Apple's `InstallESD.dmg`, 10.9.5** | `vendor/sources.tsv` `apple-installesd-10.9.5` | ❌ **untrackable, and deliberately so.** Apple publishes no feed, and the pin names one immutable build: 10.9.5 is 10.9.5 forever. There is no newer version of this ingredient to track. (Whether an image carries Apple's *post*-10.9.5 updates was `docs/open-questions.md` Q1, answered 2026-09-22; those are their own rows below.) **Compensates:** the transfer is plain HTTP over an `osrecovery.apple.com` AssetToken handshake, so the checksum is the only integrity there is, and `media/fetch-installesd.sh` enforces it | Never bumps. **Never enters the repository, in any form** — `bin/no-apple-bytes.sh` is the gate |
| **Apple's Security Update 2016-004**, the last one shipped for 10.9 (`--updates security`, the default) | `vendor/sources.tsv` `apple-secupd-2016-004` | ❌ **no datasource, and none is needed.** This is a frozen artifact from a discontinued product line: Apple shipped 10.9's last security update in 2016, stopped, and is not going to ship another. There is no newer version for a tracker to find, and no feed to read if there were. A `regex` manager scraping a CDN path for a date would be a fragile tracker invented to fill a cell, which INGREDIENTS.md's own rule says is worse than an honest blank. **Compensates:** the sha256 is the identity and `image/fetch-updates.sh` verifies it on every fetch; `bin/verify-changed-sources.sh` re-verifies any row whose URL moves; every image manifest carries the pin as an `ingredient.` line and names the package in its `updates` field. **And the thing that would actually go stale is watched by hand, not by Renovate:** the claim "2016-004 is the last one" was itself wrong in the briefs (they said 2016-001) and was corrected by asking a live guest. `docs/open-questions.md` Q1 records how, so the next person re-checks rather than inherits | Never bumps. **Never enters the repository** -- fetched at runtime, from Apple, on the user's machine; `bin/no-apple-bytes.sh` is the gate. **NEVER by `softwareupdate`**, which would reach Apple's servers during the build |
| **Safari 9.1.3** and **iTunes 12.6.2** (`--updates all`; iTunes is one softwareupdate product made of five flat packages, so six pins) | `vendor/sources.tsv` `apple-safari-9.1.3`, `apple-itunes-12.6.2-*` | ❌ **no datasource, as above, and for the same reason.** Frozen 2016/2017 artifacts for an OS that stopped receiving them. They are opt-in because they are applications rather than the operating system | Never bumps. The five iTunes pins move together or not at all -- they are one product, and `image/fetch-updates.sh` lists them in the order its own `Packages` array gives |
| **`iBooksDelta-1.0.1`, `RemoteDesktopClient-3.8.4`** -- offered to a live 10.9.5 guest by Apple, **not pinned, not installed, not findable** | **nowhere.** Deliberately, and this row is why | ❌ **untrackable AND unfetchable.** A 10.9.5 guest's own `softwareupdate -l` offered five items on 2026-09-21; three are in `index-10.9.merged-1.sucatalog` and these two are not -- not in its package URLs, and not in any of its 333 distribution files, all of which were fetched and searched. There is no URL to pin, so there is nothing for a checksum to be the identity of. **Recorded here rather than omitted**, because an ingredient with neither a tracker nor a written reason is exactly the silent staleness hole this file exists to prevent, and "we could not find it" is a reason -- "we did not mention it" is not. **Compensates:** nothing, and that is the honest answer. The guest knows what it talked to; `docs/open-questions.md` Q1 says to ask it again rather than guess | Nothing. If one is ever located, it becomes a `vendor/sources.tsv` row like its three siblings and this half of the row goes away |
| **QEMU, on the host** | not pinned | ❌ **unpinnable by us.** It is the user's, from their platform, on Linux/macOS/NetBSD alike. Pinning a QEMU would mean shipping one. **Compensates:** the version is recorded in every image manifest (`qemu` field), `bin/preconditions.sh` checks what the pipeline needs of it, and `docs/host-profile.md` records what this host has | Nothing automatic. A manifest says which QEMU produced an image |
| **The host C compiler** (builds OpenCore and OVMF — the one Tier 0 input that is not pinned) | not pinned. **Range-checked** in `lib/compiler.sh`: **gcc 13 through 16, verified at gcc 13.3.0, 14.2.0 and 16.2.1**, enforced by `boot/build-opencore.sh` and `boot/build-ovmf.sh` before they build | ❌ **unpinnable by us, like QEMU** — it is the host's, from its distribution. Tracking a version we do not choose would produce PRs nobody can act on. **But unlike QEMU its output is baked into shipped bytes**, which is why it is a row here and not in the build-tools row below: OpenCorePkg 1.0.7 does not compile *at all* under a C23-default gcc, and OvmfPkg compiles clean and emits a *different* `OVMF_CODE.fd`. **Compensates — five things, deliberately not a pin:** the C dialect is stated rather than inherited (`-std=gnu17`, `boot/patches/0002-*`); upstream's `-Werror` is no longer inherited either (`-Wno-error`, `boot/patches/0003-*`), because a warning a newer compiler invents in code we pin and cannot patch should not stop our build — the warnings are still printed, and our own shell and tests keep every gate they have; the range check refuses below the floor and warns above the ceiling; every image manifest carries `compiler` (which one) and `compilerrange` (whether we claimed to support it *then*); `docs/host-profile.md` G22 and `decisions/0004` carry the reasoning. **Why not pinned:** `decisions/0004` chose (b) over (c) — a container or bootstrapped GCC is the only thing that makes the same sources produce the same bytes, and it is the right answer *if these images ever have to be independently verifiable*, but P6 has not said what CI needs and it is a lot of machinery for a project that otherwise needs only a shell and a package manager | Nothing automatic — the host bumps it, not us. A host outside the range hears about it at build time instead of in a checksum diff. **The range itself moves only on evidence**: gcc 15 is inside it today only by interpolation between two verified neighbours and is marked as never seen; the ceiling moved 14 to 16 on 2026-09-22 on the strength of squirrel-zapper's complete run the day before (`decisions/0004`, "Answered") |
| **`utm-bundle`, `opencore-legacy-img`** (Tier 2 reference blobs) | `vendor/sources.tsv` | ❌ **deliberately untracked.** They are de-risking scaffolding, not shipped inputs: `bin/tier-check.sh --strict` fails the suite if any profile in `vm/profiles/` references the Tier 2 quarantine, which is P3's exit gate and has been met. A blob nothing ships cannot go stale in anything | Never bumped. If one ever needed to be, that is a sign it stopped being Tier 2 |
| **shipyard** (`check-family-conventions.sh`, `check-ingredient-pins.sh`, `deviations.sh`, `templates/msc.sh`) | `@v1` in `.github/workflows/*.yml` | ✅ tracked by Renovate's native `github-actions` manager, as the family intends — `@v1` is a moving major tag | Gate behaviour changes; `build/msc.sh` must still match `$SHIPYARD_SCRIPTS/templates/msc.sh` byte for byte. **Never edit our copy** — fix the template upstream |
| **`bats`, `shellcheck`, `python3`, `dmg2img`, `sgdisk`, `mkfs.hfsplus`** | not pinned | ❌ **not ingredients.** They are build-host tools: none of their bytes reaches an image, which is exactly what separates them from the compiler row above — `gcc` is a build-host tool too, and its output ships. `bin/run-tests.sh` and `bin/preconditions.sh` check for what they need | n/a |
| **`ccache`, optional, for the firmware builds** (`lib/ccache.sh`, `MQG_CCACHE=1`) | not pinned | ❌ **unpinnable by us**, like QEMU and the host compiler — it is the host's, if it is there at all, and this project installs nothing. **And it is not an ingredient — claimed.** It stands between `gcc` and its output, so unlike the row above it is *positioned* to change shipped bytes, and the claim that it does not is the whole reason it is allowed near this build. **What is measured, on the primary host, gcc 13.3.0, 2026-09-21:** two cold boot-stack builds **at the same build directory**, one straight and one through the PATH shim `lib/ccache.sh` installs, produced **identical checksums for all eight artifacts** (NOTES.md). That is evidence about the *seam* — the shim, and the compiler identity surviving it. **What is NOT measured:** ccache itself, which is not installed on this host, so nobody has yet compared a cache hit against a cold compile. **Therefore it is off by default**, exactly as `MQG_CC_CEILING` sits below the compilers nobody has built with: `MQG_CCACHE=1` turns it on, every image manifest records a `ccache` line saying whether it was used, and the stage input stamps deliberately exclude it — installing ccache must not rebuild the firmware. The cache lives under `$MQG_BUILD_DIR`, **never the repo**: the repo is NFS at 9–15 ms per file create and a ccache directory is thousands of small files | Nothing automatic; it is the host's. **A complete comparison on a host that has ccache is what moves the default** — see `lib/ccache.sh`, which names all three files to update |

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

- version-scheme:bin/vmavs: this product is its own upstream, not a repackage of somebody else's release, so it takes the family's SELF-UPSTREAM shape (`YYYYMMDD.N`, as `mavericks-porthole` does) rather than `<upstream>-mavericks.N`. The suffix means "our Nth repackage of someone else's thing" and there is no such thing here; `docs/decisions/0012-version-scheme.md` has the reasoning
- version-scheme:image/build-image.sh: same product, same reason, scoped the same way so a deviation on one file cannot quietly license the rest to drift
- version-scheme:vm/*.sh: same product, same reason, scoped the same way so a deviation on one file cannot quietly license the rest to drift
- sparkle-updater:image/build-image.sh: Sparkle is a macOS framework and the host-side tool's primary hosts are Linux and NetBSD. The guest-side payload, which IS a 10.9 .pkg, takes the family's Sparkle shape unchanged
- sparkle-updater:vm/*.sh: same product, same reason, scoped the same way

## No upstream release notes

No upstream release notes: this repository has no single upstream whose
notes a release could link. Each ingredient's notes live with its own
project — `acidanthera/OpenCorePkg`, `acidanthera/Lilu`,
`acidanthera/VirtualSMC`, `Mavergreen/openssh` — and the registry row
above names each one, which is the closest thing to "what changed" that a
product with a dozen upstreams can honestly offer.

## Provenance

`docs/decisions/0004-p3-boot-stack-provenance.md` is the tier scheme these
rows are an instance of: **Tier 0** built from pinned source, **Tier 1**
vanilla upstream binaries pinned and checksummed, **Tier 2** reference
blobs that must never reach a shipped profile. `bin/tier-check.sh --strict`
enforces the last one and runs in the suite.

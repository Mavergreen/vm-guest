# 0004 — The P3 boot stack: what it is made of, and how to rebuild it

Date: 2026-09-17
Status: accepted — this is P3's exit artifact

## Context

P3's exit criterion is that **no unreproducible blob remains in the boot
path**, and that this is enforced rather than asserted. Enforcement is
`bin/tier-check.sh --strict`, which `bin/run-tests.sh` runs on every test
run. This document is the other half: the record of what the boot path
actually contains, so the question "can we reproduce this on another host"
has an answer someone can check instead of a claim they have to trust.

P4 (the unattended pipeline) and P6 (CI on GitHub Actions) both build on
it. A pipeline that cannot rebuild the boot stack from nothing is not a
pipeline, and neither phase can start until every component is Tier 0 or a
pinned, checksummed Tier 1.

Tiers are defined in the umbrella design, §4:

- **Tier 0** — built from pinned source by our own scripts.
- **Tier 1** — vanilla upstream, version-pinned and checksummed.
- **Tier 2** — someone's custom blob. Quarantined under `$MQG_VENDOR_DIR`;
  never in a shipped profile.

## The shipped boot path

Everything `vmavs run p3-full` touches before the macOS kernel starts.
Checksums are of the artifacts this host built or fetched on 2026-09-17.

| Component | Tier | How it is obtained | Pinned to | sha256 |
|---|---|---|---|---|
| **Firmware** `OVMF_CODE.fd` | **0** | `boot/build-ovmf.sh` — `build -a X64 -b RELEASE -t GCC -p OvmfPkg/OvmfPkgX64.dsc` in the same EDK II tree `build-opencore.sh` assembles | `acidanthera/audk` `0672a009e9ca85753d240324d761341adf0291b3` | `195c4dcff2abf2f5aea08c290f057432704a250eab56b0b887ac0f8503ee58d2` |
| **Firmware** `OVMF_VARS.fd` (template) | **0** | same build; copied per-VM by `boot/make-nvram.sh`, never booted in place | same | `5d2ac383371b408398accee7ec27c8c09ea5b74a0de0ceea6513388b15be5d1e` |
| `OVMF.fd` (combined, unused) | **0** | same build; kept for a `-bios` experiment | same | `e44f708330318e8963baea94c91ed265761794e565e6a48db8821e92e4cbda17` |
| **Bootloader** `BOOTx64.efi` (= `Bootstrap.efi`) | **0** | `boot/build-opencore.sh` | OpenCorePkg tag `1.0.7` | `eb05c27990e7162011b2ef5229d3e2b8be23a8e0bfd79d77c1891cee175e0094` |
| **Bootloader** `OpenCore.efi` | **0** | same | OpenCorePkg `1.0.7` | `7b3ce1defa81257d8994961fb838cda765e6a990d7bf9d6773aa94ef9ea63819` |
| `OpenRuntime.efi` | **0** | same | OpenCorePkg `1.0.7` | `d5bece452e5c2180b7f588b40b12c2fe64663548dbbe0de01038c3db45083a5d` |
| `OpenPartitionDxe.efi` | **0** | same | OpenCorePkg `1.0.7` | `e0ee5f238725685eff2f423558b933497c5475c257f747aa281e2d88018723ea` |
| **HFS+ driver** `OpenHfsPlus.efi` | **0** | same (`Staging/OpenHfsPlus`, in the default target) | OpenCorePkg `1.0.7` | `93f491375fbd4c0541b55d64b8d4e2f01cafde4f66b7f520f943d3351a45040a` |
| **Config** `boot/config/config.plist` | **0** | ours, in this repository, derived from 1.0.7's `Sample.plist`; validated by the `ocvalidate` from the same build | this repo | `9c121fd9e3eeac8cc4a04434f310beda6dd49c6c8338d13e746cf6ca741f4c38` |
| **Kext** `Lilu.kext` | **1** | `boot/fetch-kexts.sh`, release zip pinned in `vendor/sources.tsv` | Lilu **1.7.2** release | zip `53967d7dcfaab01023a33df2e969a89522f13d6654a6a56ac4711b62dabf3ab8`; binary `ff98508b40a1eb5fb477029db8886412520f8e39965279ea331c99e3d2e3b274` |
| **Kext** `VirtualSMC.kext` | **1** | same | VirtualSMC **1.3.7** release | zip `12f1d379969f926306fa92d94ddbf33b32b31176589dc42089d864a26b31b700`; binary `865f736ae87654ee31617692167c004bb3e282bf1d7b20d8e4ca353c6599068a` |
| **EFI image** `opencore-p3.img` | **0** | `boot/build-efi-image.sh` — GPT + FAT32 via `sgdisk` and `mtools`, no loop mount and no root | assembled from the rows above | `d80d0312dca690be5ef47d882eef62b916159218b30935d5e69429b73caef76c` |

**No Tier 2 row.** That is the point of the table.

### What the Tier 0 rows are pinned *through*

"Built from source" only means something if the source is pinned, and the
OpenCore build originally had two floating inputs (`build_oc.tool` curled
`ocbuild`'s `efibuild.sh` off `master` and `eval`ed it; that script cloned
`acidanthera/audk` at `master`). Both are now pinned, every pin lives in
`vendor/sources.tsv` with a sha256, and `boot/build-opencore.sh` refuses a
`sources.tsv` URL naming a commit other than the one it expects, so the two
files cannot quietly disagree.

| Input | Pin |
|---|---|
| OpenCorePkg | release tarball for tag `1.0.7`, sha256 `98e4faf7…` |
| `ocbuild/efibuild.sh` | commit `e9ed49cb7a4f7fa2830c024a13d63de27c2e0d1a`, sha256 `4ae24614…` |
| `acidanthera/audk` (EDK II) | commit `0672a009e9ca85753d240324d761341adf0291b3`, sha256 `2c4f5754…` |
| audk's 12 submodules | the commits audk's gitlinks name; all twelve, because EDK II's `build.py` validates every `[Includes]` path in every `.dec` it parses |
| `boot/patches/0001-build_oc-source-pinned-efibuild.patch` | in this repository; replaces the `curl` with a `cat` of the pinned file |

Two artifacts, one tree: `OpenCore.efi` and `OVMF_CODE.fd` come out of the
same pinned EDK II checkout. A second tree would mean a second list of
submodule pins, i.e. a second thing that can drift.

### Reproducibility, as actually demonstrated

- **Offline.** `unshare -rn ./boot/build-opencore.sh` and
  `unshare -rn ./boot/build-ovmf.sh` both complete with no network
  namespace at all and produce byte-identical output to a networked run.
- **Re-runnable.** A warm tree rebuilds in 20 s (OpenCore) / 11 s (OVMF)
  and yields the same checksums; a cold build is 3m23s / 1m22s on 12 cores.
- **Except that `OpenCore.efi` carries the build date.** Found 2026-09-20
  while checking whether a flag change had moved any checksum. A cold
  rebuild of the same pinned sources by the same compiler on a later day
  differs from the 2026-09-17 row above in exactly **two bytes** — the `17`
  of an embedded `2026-09-17`. The other four OpenCore artifacts and all
  three OVMF images are byte-identical across days. So `OpenCore.efi`'s
  checksum in the table is "this source set, built on that date", and
  comparing it against another host's is only meaningful if both built on
  the same UTC day. Not fixed here: `SOURCE_DATE_EPOCH`-style determinism
  is a separate piece of work, and pretending the number is stable would be
  worse than writing down that it is not.
- **And except that every artifact carries the build DIRECTORY.** Found
  2026-09-21, while trying to compare a ccache build against a plain one
  and getting eight differences from a change that touches nothing. EDK II
  writes each module's debug-symbol path into the PE image it emits —
  which is why `image/build-image.sh` refuses a `MQG_BUILD_DIR` longer than
  about 120 characters — so the build directory is an **input**. Two cold
  builds of identical sources by the same compiler on the same day, at
  `…/ccache-verify/a` and `…/ccache-verify/w`, agreed on exactly one of the
  eight artifacts: `OVMF_VARS.fd`, which holds no code. The other seven all
  differed. So every checksum in the table above means "this source set,
  built on that date, **under `$HOME/.local/share/mavericks-qemu-guest/build`**",
  and a second host comparing its numbers has to match the path as well as
  the sources. Same conclusion as the build-date bullet and the same
  remedy: written down rather than papered over.
- **Not yet cross-host.** Everything above was built on one machine
  (`docs/host-profile.md` §1). The claim that it rebuilds elsewhere is a
  hypothesis until a second host tries; `docs/test-hosts.md` names which
  machines can falsify what. **This is the main thing P4 and P6 should not
  assume.**

### The compiler is not pinned — the hole in Tier 0

**Tier 0 says "built from pinned source". Every input is pinned except the
one that translates them.** We pin OpenCorePkg, `ocbuild`, `audk` and
twelve submodules by commit and checksum; we say nothing at all about the
compiler. The same pinned sources therefore do not produce the same
artifact — or, in one case, any artifact — on two different hosts.

This is not hypothetical. On `squirrel-zapper` (EndeavourOS, GCC 15-era),
2026-09-20, `bin/triangulate.sh --build` reached the `opencore` stage and
died:

```
OpenCorePkg/Library/OcAppleImg4Lib/libDER_config.h:31:17:
  error: two or more data types in declaration specifiers
   31 | typedef BOOLEAN bool;
libDER_config.h:31:1: error: useless type name in empty declaration [-Werror]
```

`bool` became a keyword in C23; GCC 15 defaults to `-std=gnu23`; EDK II
compiles with `-Werror` and sets no `-std` at all, so the dialect was
whatever the host's compiler felt like. The primary host's GCC 13.3.0
defaults to `gnu17` and builds fine, which is why two phases went by
without anyone noticing.

**What was done about it.** The *dialect* is now stated rather than
inherited — `-std=gnu17`, for OpenCorePkg through upstream's own
`$(OCPKG_BUILD_OPTIONS)` hook and for OvmfPkg through
`boot/patches/0002-ovmf-pin-the-c-dialect.patch`. That fixes the failure,
and it also fixes something quieter that the failure hid: OvmfPkg compiles
clean under C23 and produces **different firmware bytes**
(`OVMF_CODE.fd` `195c4dcf…` under gnu17, `3373692a…` under `-std=c2x`,
same tree, same compiler). A host with a newer GCC would have shipped a
firmware this document does not describe, with a green build.

**What was not done: the toolchain is still not pinned.** Pinning the
dialect is not pinning the compiler. A GCC 15 host still emits different
code than a GCC 13 host from identical sources and identical flags; so does
clang. That was left as an open question — record only (a), declare a
supported range (b), or build with a pinned toolchain (c) — and it is
answered below.

### Answered 2026-09-20: a declared range, not a pinned toolchain

**(b).** `lib/compiler.sh` declares the compilers this project has a reason
to believe in; `boot/build-opencore.sh` and `boot/build-ovmf.sh` both check
against it before they build anything.

**Why not (c).** Pinning the toolchain is the right answer *if these images
ever have to be independently verifiable* — it is the only option that makes
"the same sources produce the same bytes" true, and nothing below changes
that. But this is a real project, not a demonstration of reproducibility,
and P6 has not yet said what CI needs. A container or a bootstrapped GCC is
a large amount of machinery bought against a requirement nobody has written
down, in a project whose other Tier 0 claim is that it needs nothing but a
shell and a package manager. **(b) is the cheapest change that converts a
silent break into a clear message**, which is the specific harm this section
recorded. (c) stays available: the day P6 or an independent verifier needs
byte-identical output across hosts, the range is what says which toolchain
to pin to.

**Why not (a) alone.** Recording is what we already had, and it is
retrospective: it tells you *after* a build why two hosts disagree. It did
nothing for `squirrel-zapper`, which got a compile error out of libDER and
no explanation.

#### The range, and which parts of it are measured

The distinction below is the point of the option, and it is preserved
everywhere the range is written down (`lib/compiler.sh`, `INGREDIENTS.md`,
`docs/host-profile.md` G22) because this project has three times caught
itself repeating an inherited claim nobody had checked — the usb-tablet
kext, "DNS needs configuration", security update 2016-001 vs 2016-004. A
range that quietly implied a tested GCC 15 would be the fourth.

| GCC | Status | Evidence |
|---|---|---|
| **13.3.0** | **VERIFIED** | The primary host. Every checksum in the tables above came out of it, repeatedly, from cold trees; the four cold builds in `NOTES.md` are the dialect measurement |
| 13.x, 14.x | **EXPECTED, not verified** | Nobody has built with 14. Inside the range because it is the same series as the verified point and defaults to the same dialect (`gnu17`), which is now stated anyway |
| **15.x** | **NOT TESTED — inside the range by interpolation since 2026-09-22** | Sits between two verified points (14.2.0 and 16.2.1) and has never been seen. Inside the range because both neighbours work, which is an interpolation and not a measurement. Keeping it outside would have claimed a failure nobody observed. | The version that *motivated* this work, and still untested: nobody has run a GCC 15. Its C23 default is what broke `squirrel-zapper`, and that specific failure is fixed — but the fix was measured through a `-std=c2x` shim on GCC 13, which stands in for the *dialect* and for nothing else |
| **16.2.1** | **VERIFIED 2026-09-21 — the ceiling, raised 2026-09-22** | `squirrel-zapper`, `--full`: **all eleven stages**, media 118 s, install 1332 s, verify and manifest — a guest installed, booted without installer media and answered SSH. Both fixes this range exists for are therefore tested up here. The artifacts differ from gcc 13's (`OVMF_CODE.fd` `e3d0c6f5…` against `195c4dcf…`) and that is not a defect: this document already says the firmware is reproducible per toolchain and not across them — which made the old promotion rule ("builds and the checksums match") **unsatisfiable by construction**, and is why this ceiling sat a version below its own evidence for a day. | `squirrel-zapper`, 2026-09-20, second `--build` run. **The `opencore` stage built clean in 397 s** — a real C23-default compiler, two majors above the one that motivated the dialect fix, completing the stage that failed before. Then `ovmf` died in 26 s, on a warning GCC 16 invented in code we do not own: `variable 'Count' set but not used [-Werror=unused-but-set-variable=]` in `MdeModulePkg/Library/CustomizedDisplayLib`. **That is fixed too** (below), and the fix is **untested on that host** — the run ended there and no firmware image has ever been produced by a GCC above 14. **That run happened on 2026-09-21 and this row was not updated until 2026-09-22.** |
| below 13 | **NOT TESTED** | Never tried. Not "known to fail" |

**When a complete run above 14 lands:** if it builds and the artifact
checksums match this document's, raise `MQG_CC_CEILING` in
`lib/compiler.sh`, add the host and date to the row above, and update
`INGREDIENTS.md` and G22. All four, or the next reader inherits a number
with no evidence behind it. If it does not build, the ceiling stays where
it is and the reason goes in the same row.

**Why the ceiling did not move on 2026-09-20.** Two failures on that host
have now been diagnosed and fixed, and it is tempting to read that as
support for 15 and 16. It is not. A fix that has not been run on the host
that exposed the bug is a hypothesis, `opencore` building is half a boot
stack, and the failure mode this range exists to warn about — a green
build that emits *different bytes* — is precisely the one no compiler
above 13.3.0 has ever been checked for. The ceiling is 14 because 14 is
where the evidence stops.

### Also answered 2026-09-20: `-Werror` is upstream's, and we stop inheriting it

EDK II puts `-Werror` on every `gcc` line
(`BaseTools/Conf/tools_def.template`). **The firmware builds no longer
inherit it**: `-Wno-error` is appended through the same two seams the
dialect uses — `$(OCPKG_BUILD_OPTIONS)` for OpenCorePkg, and
`boot/patches/0003-firmware-drop-werror.patch` for `OvmfPkgX64.dsc`.

**The reason, which is not "the build was annoying".** `-Werror` is
upstream's discipline for upstream's own development, and a good one: a
warning nobody may ignore is a warning that gets fixed. We are not
upstream. We are a downstream consumer pinning one commit of
`acidanthera/audk` and one release of OpenCorePkg, compiled by whatever C
compiler the host distribution ships. **We cannot fix their warnings** —
patching upstream source to satisfy a compiler upstream never used would
be us maintaining a fork we did not intend to have, growing by a hunk per
compiler release — and **a warning we cannot act on should not stop our
build**. Upstream keeps its discipline; we stop inheriting a build failure
from it.

**It fixes a class, not a case.** A new compiler invents new warnings, and
`-Werror` converts every one of them into a build failure in code we do
not own. This was the second instance: GCC 15's C23 default (a change of
*language*, properly fixed by stating the dialect) and then GCC 16's
`-Werror=unused-but-set-variable=` — note the trailing `=`, GCC 16 gave
that warning a level argument, so it is not even spelled the way GCC 13
spells it. `-Wno-unused-but-set-variable` would have fixed that instance
and taught nothing, and GCC 17 will bring a third.

**The warnings are still printed.** `-Wno-error` cancels the promotion to
errors and nothing else. `-Wall` is untouched, every diagnostic still goes
to `ovmf-build.log` and `build.log`, and warnings becoming *invisible*
would be a regression — non-fatal is the point.

**Firmware only.** Our own shell and test code keeps every gate it has:
`shellcheck`, `bin/tier-check.sh --strict`, `bin/bash32-check.sh`. The
argument above is about C we did not write and cannot change; it does not
transfer to code we own.

**It does not change the artifacts, and that was measured rather than
assumed** — this document's whole claim is that the boot stack is
reproducible, so a flag change that moved a checksum would matter more
than the failure it fixed. Cold builds either side of the change, on the
primary host, gcc 13.3.0, 2026-09-19:

| Artifact | before | after |
|---|---|---|
| `OVMF_CODE.fd` | `195c4dcf…` | `195c4dcf…` |
| `OVMF_VARS.fd` | `5d2ac383…` | `5d2ac383…` |
| `OVMF.fd` | `e44f7083…` | `e44f7083…` |
| `BOOTx64.efi` | `eb05c279…` | `eb05c279…` |
| `OpenCore.efi` | `a6e91a7a…` | `a6e91a7a…` |
| `OpenRuntime.efi` | `d5bece45…` | `d5bece45…` |
| `OpenPartitionDxe.efi` | `e0ee5f23…` | `e0ee5f23…` |
| `OpenHfsPlus.efi` | `93f49137…` | `93f49137…` |

All eight identical, which is what `-Werror` ought to do: it decides
whether a diagnostic aborts the build, not what the compiler emits. (Both
builds are same-day, which the `OpenCore.efi` row requires — see the build
date note above.)

#### What the check does in each case

| Compiler | What happens |
|---|---|
| Inside the range | One log line, build proceeds |
| **Below the floor** | **Fails**, before the source tree is even looked for. Says what was found, what is required, and that the project has *not tested* it — which is not the same as knowing it fails |
| **Above the ceiling** | **Warns and proceeds.** Refusing would make this project refuse to build on every new distribution, which is a worse failure than the one it would prevent. The warning says that the failure mode up here is usually *not* an error — OvmfPkg compiled clean under C23 and emitted different firmware bytes — so a green build is not proof, and names the checksums to compare against |
| Cannot tell | **Warns and proceeds**, naming what it could not parse. "I cannot tell" is its own outcome: reporting it as a pass would be a claim, as a failure would block a host that is probably fine. This is the macOS case, where `gcc` is clang, and the `cc` case |

`MQG_COMPILER='<name> <version>'` replaces detection, in the shape
`MQG_PKG_MANAGER` established in `boot/prereqs.sh` and for the same reason:
a check fed by the environment cannot be tested without a seam, and
installing three GCCs to test a version comparison is not a reasonable
price. It is also the way past the floor for someone who knows better than
the file does. It moves nothing else — `--compiler` still reports the real
compiler — so an image built with the check talked out of the way has a
manifest whose two compiler lines disagree, in public.

**The manifest now records both**: `compiler` (which compiler) and
`compilerrange` (whether the project claimed to support it *at build time*,
and whether the override was in effect). The second cannot be reconstructed
later, because the range moves as evidence arrives and the image does not —
an image built above the ceiling has to carry its own "this was untested
territory", or it silently becomes a supported build the day the ceiling is
raised.

**What this does not do.** It does not make Tier 0 reproducible. The honest
statement of Tier 0 is still: **built from pinned source by an unpinned
compiler, in a stated dialect** — now with the addition that the compiler is
*range-checked and recorded*, so an out-of-range build announces itself
instead of being discovered in a checksum diff. P6 still forces the harder
question: a runner image's compiler moves without anyone choosing it, and
when it moves past 14 this check will say so rather than fail, which is a
decision P6 should make deliberately (pin the runner's compiler, or raise
the ceiling on evidence).

### Build prerequisites, which are the one host dependency left

`boot/prereqs.sh` reports rather than installs (installing is a
stop-and-ask in this project). On this host it wanted `nasm` and
`acpica-tools` (`iasl`), plus the usual `gcc`/`make`/`python3`, and
`sgdisk` and `mtools` for image assembly. **These are build-time tools, not
shipped components** — nothing in the table above is a distro package — but
they are what a second host has to satisfy, under whatever names its
package manager uses.

## What the gate does and does not catch

`bin/tier-check.sh` expands every profile in `vm/profiles/` and fails
`--strict` if the expanded text contains the resolved `$MQG_VENDOR_DIR`
path. It runs as a section of `bin/run-tests.sh`, alongside bats and
shellcheck, and unlike shellcheck it is not optional: a rule checked only
where a tool happens to be installed will be broken on the host that lacks
it.

It is a textual heuristic over configuration, and its limits are worth
stating because P3 hit one of them:

- It **will** catch `%VENDOR%`, and the resolved path spelled out
  literally, in any profile or anything a profile `@include`s.
- It will **not** catch a Tier 2 blob copied somewhere else. `p3-oc` read
  `-bios %IMAGES%/work/OVMF_CODE.fd` and passed the gate for the whole of
  P3 — while that file was byte-identical (`8a7ef535…`) to the UTM bundle's
  `OVMF.bin`, a Tier 2 blob someone had copied into `work/`. The addendum
  to `docs/decisions/0002` anticipated a *modified* copy escaping; this was
  an unmodified one, which is the same hole by an easier route. `p3-oc` is
  now retired to `vm/profiles/attic/` rather than exempted.
- It will not catch a symlink into the quarantine under another name, nor
  a path assembled so the literal string never appears in one piece.

Closing that properly means checking the *content* of every file a profile
names against the known quarantine, which cannot run on a fresh clone with
no image directory — so it would be advisory, and an advisory check is not
a gate. The honest position: **the gate stops accidents, not evasion**, and
this document is the record it cannot be.

## Consequences

- P4 can rebuild the boot stack from `vendor/sources.tsv` plus this
  repository, with no artifact carried over by hand.
- P6 inherits a firmware that is ours. There is no `/usr/share/OVMF` on
  macOS and no guarantee about it on any particular Linux runner; see the
  Tier 0 firmware reasoning in the umbrella design, §4.
- The two Tier 1 rows are the remaining upstream trust. Lilu and
  VirtualSMC are acidanthera release binaries, pinned to exact tags (never
  "latest") and checksummed. Building them from source is a future option,
  not a present need; `boot/config/README.md` records why these versions
  and how their Darwin 13 (10.9) support was verified by reading their
  `Info.plist`s rather than assuming.
- **One defect ships with this stack**: `p3-full` needs a keypress. The
  picker's default entry is the OpenCore disk itself, so left alone it
  times out into `EFI_ALREADY_STARTED` and hangs. It is a `config.plist`
  problem, and P4 and P6 both need it fixed. See `NOTES.md`.

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

Everything `./vm/run.sh p3-full` touches before the macOS kernel starts.
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
- **Not yet cross-host.** Everything above was built on one machine
  (`docs/host-profile.md` §1). The claim that it rebuilds elsewhere is a
  hypothesis until a second host tries; `docs/test-hosts.md` names which
  machines can falsify what. **This is the main thing P4 and P6 should not
  assume.**

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

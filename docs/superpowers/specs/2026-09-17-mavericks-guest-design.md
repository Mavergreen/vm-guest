# Design: OS X 10.9 Mavericks as a usable KVM guest

Date: 2026-09-17
Revised: 2026-09-22 — the phase spine, §1's success criteria and §5.1's
layout, brought up to date with `decisions/0007` (what this project ships),
`open-questions.md` Q1 (answered), and the user's ordering of the remaining
work. Three new phases: P8 `vmavs`, P9 the build VM, P10 release packaging.
Nothing in §§2–5 or §§7–10 changed.
Status: approved
Supersedes: `mavericks-qemu-brief.md`, `mavericks-kvm-perf-brief.md`,
`mavericks-kvm-integration-brief.md`, `mavericks-gha-tcg-brief.md`
(all four absorbed here and into `docs/prior-art.md`, then deleted;
recoverable at commit `a4ba4ce`)

## 1. Goals

In priority order, as stated by the user:

1. **Run Mavericks as a KVM-accelerated guest, genuinely usable for dev work.**
2. **Automate the installation process** — fully unattended, image-producing.
3. **Optimize interactive GUI performance.**
4. **Make Mavericks available as a GitHub Actions runner.**

The guest's workload is testing the user's own software against an old macOS,
and interactive GUI application work. It is not a pkgsrc bulk-build host. That
matters: GUI responsiveness is a success criterion, not a nicety, and terminal
throughput is secondary.

### Success criteria

| Goal | Done means |
|---|---|
| 1 | 10.9.x installs, completes first boot, and reboots cleanly under plain `qemu-system-x86_64 -enable-kvm`. No libvirt. Interactive use is pleasant enough to work in. |
| 2 | One command, from a clean checkout, produces a bootable SSH-reachable qcow2 with no human interaction. Run twice, the outputs are equivalent. |
| 3 | A baseline-vs-tuned measurement table, a recommended default profile, and every host-specific assumption recorded. |
| 4 | `mavericks-smoke.yml` runs green on a `macos-15` runner inside 30 minutes. |
| Shipping (`decisions/0007`) | `vmavs` is the documented entry point and reports a version; the README answers "what is this" in thirty seconds; a release exists and is structurally incapable of containing Apple's bytes; somebody who is not us can install it and reach a Mavericks desktop. |

The last row is not a fifth goal. The four above it are the user's words, in
the user's priority order. The shipping criterion arrived later, with
`decisions/0007`, once P4 meant there was something to ship rather than
something to get working — and it is tracked here rather than done as an
errand because that is how an errand becomes a phase nobody planned.

## 2. Host and available hardware

The primary host is **Apple hardware**, which settles the licensing question:
Apple's EULA permits virtualizing OS X on Apple-branded hardware. This is the
sanctioned case.

Probe results are recorded in `docs/host-profile.md`, which doubles as the
generalization ledger. Summary: `Macmini8,1`, Intel i7-8700B (Coffee Lake,
6C/12T), 62 GB RAM, 1.7 TB free, T2 chip, Linux Mint 22.3 on a `t2`-patched
kernel, VT-x present, `/dev/kvm` usable, IOMMU on with 14 groups, QEMU 8.2.2,
OVMF 4M-split only, Intel UHD 630 as the sole display device.

The user also has an **Apple Silicon Mac** (host for the GitHub Actions phase),
an **Intel Mac running macOS** (runs `get.sh` unmodified to produce the
reference installer image), and a **real Mavericks-capable Mac** (ground truth
for behavior comparisons and release sign-off).

The AMD hard-stop from the bring-up brief does not trigger.

## 3. Non-negotiables

Carried forward from the source briefs, and binding on every phase:

- **The OS comes from Apple only.** Firmware and bootloaders may be
  third-party; macOS disk images may not. No prebuilt third-party macOS image
  is used, ever, including khronokernel's `Catalina-SETUP.qcow2`.
- **Never publish the guest image or snapshot.** Not as a release asset, not
  as a public package, not anywhere reachable without authentication.
- **Adapt prior art; don't invent from scratch.** `docs/prior-art.md` is the
  register of what exists and what each source gives us.
- **If a source can't be fetched, say so.** Never guess at its contents.
- **Failures are recorded as carefully as successes.** `NOTES.md` is an
  append-only lab log: the command, what happened, the panic text, the fix.
- **Ask before** `sudo`; installing host packages; touching anything outside
  this directory; changing host kernel parameters, module options, or boot
  configuration; rebooting the host; binding devices to `vfio-pci`; creating
  GitHub secrets; pushing to any repo; contributing upstream; acquiring
  hardware.

## 4. Provenance tiers

Every binary in the boot path carries a tier. The rule exists because custom
blobs nobody can rebuild are exactly what makes a setup impossible to
generalize to another host.

- **Tier 0 — built from pinned source by our own scripts.** The target state.
- **Tier 1 — vanilla upstream, version-pinned and checksummed.** A distro
  package or an official upstream release artifact: not built by us, but
  publicly buildable from source on demand. Acceptable in the shipped path.
- **Tier 2 — someone's custom blob.** Quarantined under `$MQG_VENDOR_DIR`,
  local disk, not the repo (the repo sits on NFS; see
  `docs/decisions/0003-vm-images-on-local-btrfs.md`). Permitted only as
  de-risking scaffolding in P1 and P2. Never shipped.

**P3's exit gate is mechanically checkable: no run profile and no part of the
image pipeline references anything under `$MQG_VENDOR_DIR`.**

Per component:

| Component | Target tier | Notes |
|---|---|---|
| OVMF firmware | **0** (revised in P3; was "1, falling back to 0") | Built by `boot/build-ovmf.sh` out of the same pinned `acidanthera/audk` tree OpenCore is built from. See the note below for why the original preference was backwards. |
| OpenCore | 0 | `build-opencore.sh` fetches OpenCorePkg at a pinned release tag, builds it, and assembles `EFI/OC` against **our own `config.plist`**, checked in as diffable text. |
| HFS+ EFI driver | 0 | OVMF cannot read HFS+, so OpenCore needs one. `HfsPlus.efi` is Apple's binary extracted from Mac firmware — Tier 2 by construction, never buildable. Use `OpenHfsPlus.efi`, which OpenCorePkg builds from source, and accept that it is slower. See `docs/decisions/0002-openhfsplus-over-apple-hfsplus.md`. |
| `isa-applesmc` OSK | n/a | A constant, not a blob. This host is a real Mac, so reading the OSK off its own hardware is available as a clean path if preferred. |
| QEMU | 1 on Linux, 0 on macOS | Ubuntu's 8.2.2 here; a pinned self-built QEMU (pkgsrc preferred, not Homebrew's floating version) for the GHA phase. |

Third-party binaries are recorded in `vendor/MANIFEST.sha256`. Fetch scripts
verify against it or refuse.

### Why the firmware is Tier 0, not Tier 1 — revised after P3

This table originally read "Tier 1, falling back to Tier 0" for the
firmware: prefer the distro's `ovmf` package, self-build only if that
failed. **That preference was backwards**, and P3 is where it became
obvious. Three reasons, in increasing order of importance:

1. **Self-building is near-zero marginal cost once an EDK II tree is
   pinned.** `OvmfPkg` is part of EDK II, and the EDK II this project
   already pins for OpenCore is `acidanthera/audk`. Building the firmware
   needed no new source, no new pin and no new fetch step — one more
   `build -p OvmfPkg/OvmfPkgX64.dsc` against a tree that was already there
   and already offline. 1m22s cold, 11s warm. Weighed against that, "use
   the distro's" buys nothing.
2. **A distro package means the distro chooses the revision, and revision
   choice is the lever that mattered.** Debian's OVMF 2024.02 renders its
   own boot manager perfectly and then fails to boot macOS with OpenCore —
   and fails identically with khronokernel's reference OpenCore 0.6.6, so
   it was not our build. Ours, from audk, worked on the first try, split
   pflash and all. Had the firmware been a package, the only remaining
   moves would have been to argue with the distro or to pin an older
   package, neither of which is a build.
3. **A distro dependency quietly imports a per-host assumption into a
   project whose entire point is portability.** `/usr/share/OVMF/OVMF_CODE_4M.fd`
   is a Debian/Ubuntu fact. Arch puts it elsewhere under a different
   package name; other distros ship 2 MB or combined images; and **macOS,
   which P6 runs on, has no such package at all**. A component we build is
   the same component everywhere. This is the reason that outranks the
   other two: the generalization ledger in `docs/host-profile.md` exists to
   track exactly this kind of assumption, and this one was retired (G5)
   rather than documented.

Tier 1 remains right for things we genuinely do not build — the Lilu and
VirtualSMC release kexts — and for QEMU on Linux, where the host's own
hypervisor userspace is the thing under test rather than a component we
ship. The distinction is whether the artifact ends up *inside* the guest's
boot path. The firmware does.

The full component-by-component record, with pins and checksums, is
`docs/decisions/0004-p3-boot-stack-provenance.md`.

## 5. Architecture

### 5.1 Repository layout

```
bin/vmavs                      the command (P8). Dispatches; implements nothing
build/version.sh               the version scheme: YYYYMMDD.N (P8)
UPSTREAM_VERSION               this product's own version line, hand-bumped
docs/
  superpowers/{specs,plans}/   design docs and implementation plans
  prior-art.md                 every source, and what each one gives us
  host-profile.md              host facts; the generalization ledger
  configuration-register.md    every knob: measured, inherited or reasoned
  decisions/                   ADRs: what we chose, the evidence, what we rejected
emit/                          interop artifacts for other tools (P8: packer)
lib/common.sh                  shared shell: logging, checksums, guards
media/                         installer acquisition and assembly
boot/                          firmware and bootloader, built from source
image/                         the unified image pipeline
  payload/                     first-boot automation
vm/
  profiles/                    named QEMU flag sets, one file each
  run.sh  golden.sh  clone.sh
bench/                         benchmark suite
ci/mavericks/                  GitHub Actions phase
vendor/
  sources.tsv                  third-party artifact URLs and pinned checksums
                                (Tier 2 blobs themselves live under
                                $MQG_VENDOR_DIR, local disk, not the repo --
                                see docs/decisions/0003-vm-images-on-local-btrfs.md)
NOTES.md                       append-only lab log
```

### 5.2 The unified image pipeline

The four source briefs independently specified overlapping image work: the
bring-up brief wanted "reproducible from scripts," goal #2 wants unattended
image production, and the GHA brief separately specified a headless image with
a CI user, SSH keys, skipped Setup Assistant, and disabled sleep and software
update. **That is one pipeline, not two.**

`image/build-image.sh` is parameterized by accelerator (`kvm`/`tcg`), machine
type, CPU model, and RAM. The KVM desktop image and the GHA TCG image are the
same code with different parameters. The first-boot payload is written once in
P4 and inherited unchanged by P6.

The pipeline is idempotent and resumable, and emits a checksummed qcow2 plus a
manifest recording every input that went into it.

### 5.3 Golden images and throwaway clones

Adopted from `steelbrain/reims-vgpu`'s pattern, and — departing from the
source briefs — introduced at **P2 rather than at tuning time**. It is what
makes every later experiment cheap to run and safe to abandon, including the
install-automation iterations of P4, which will fail repeatedly.

- `vm/golden.sh promote <img> <name>` records a read-only, checksummed golden.
- `vm/clone.sh <golden>` creates a qcow2 overlay.
- Every experiment runs on a clone. Goldens are never written.
- Promotion to a new golden requires measurement **and** user approval.

### 5.4 Profiles

Each QEMU configuration is a file of flags with a provenance comment naming
what it changed and why. `vm/run.sh <profile>` runs one. Old profiles are
retained, never edited in place.

This is the mechanism that makes "change one variable at a time" verifiable
rather than aspirational: a profile diff is the experiment.

## 6. Phase spine

| Phase | Status | Delivered / next |
|---|---|---|
| P0 — Foundations | **complete** 2026-09-17 | Repo, `lib/common.sh`, fetch-and-verify, `preconditions.sh` green. |
| P1 — Known-good boot | **complete** 2026-09-17 | Installer GUI under KVM. Cost four failures worth reading in `NOTES.md`; the fix was SMBIOS, not the shipped `Kernel > Block`. |
| P2 — Manual install | **complete** 2026-09-17 | 10.9.5 installed and rebooting; golden #1 (`p2-manual-install`) promoted and verified after being cloned from. |
| P3 — Reproducible boot stack | **complete** 2026-09-17 | See below. |
| P4 — Unattended pipeline | **complete** 2026-09-18 | `image/build-image.sh`: one command, clean checkout to a bootable, SSH-reachable image, no interaction. Media built on Linux without root; the install driven by Apple's own `rc.cdrom.local` / `minstallconfig.xml` / `OSInstall.collection` hooks; the first-boot payload installed as a flat package this project builds on Linux. See `decisions/0006` for what "reproducible" means here. **Q1 was answered 2026-09-22** — two images, `--updates none` as P5's baseline and `--updates security` as the default — and is being implemented now. **Still not delivered, and deliberately:** byte-identical images. `decisions/0006` says what is claimed instead. |
| **P8 — `vmavs`, the front door** | **implemented** 2026-09-24; exit **not met** | `bin/vmavs` dispatches the ten subcommands of `decisions/0007`, plus a second tier (`triangulate`, `golden`, `compare`, `freshness`, `staleness`); `vmavs version` (`build/version.sh`, `YYYYMMDD.N`); a README that is product documentation; `emit packer`; and `bin/no-apple-bytes.sh <ref>`, the release gate, checking the tree a tag would archive rather than the index. **Still open:** no shipped command boots the image `vmavs image` builds — `decisions/0007`'s "`run` boots a clone" is unmet, so the exit below is not reached — and `emit packer`'s template passes `packer validate` (CI checks every profile's on each push) but no `packer build` has ever run from it. Plan: `docs/superpowers/plans/2026-09-22-shipping-vmavs.md`. |
| **P9 — Build in a controlled Linux VM** | **blocked on a decision** | Spec written 2026-09-21 and the *direction* approved; the *design* is not adopted and no plan exists. It carries its own abandon thresholds (§7.4: >1.5× cold, >60 s warm, >10 s freshness), so it may end as an optional backend rather than the default. Its headline number is why P10 waits for it: the host tool list goes from 36 to about 7. |
| **P10 — Release packaging and distribution** | **blocked on P9** | `release.yml`, `release-notes/`, the artifact, and how a host installs it. Deliberately not decided while the dependency list is about to change by 5×. Shape and constraints: the shipping plan, Phase C. |
| P5 — Interactive performance | **deferred by choice** | The user's call: the guest is working fine enough. Not waiting on anything — and `decisions/0007` says P5 measures Product A's `run`, so its baseline is better taken after P8 than before. Display work is now about *changing* modes, not reaching a usable one. |
| P6 — GitHub Actions runner | not reached | Nothing blocks it but order. (The keypress defect it used to wait on was fixed 2026-09-17 — `NOTES.md`, "the keypress requirement is fixed".) |
| P7 — Guest integration | **split by `decisions/0007`** | The interop half is `emit` subcommands and ships in P8, Packer only — one template reaches QEMU, VirtualBox, VMware and Proxmox. The guest-side half (M0–M6 below) stays **deferred by choice** and belongs to Product B. |

**The numbers are identities, not an order.** The order of work is **P8, P9,
P10, then P5, P6, P7**. Four status words are used and they mean different
things: *not reached* (nothing blocks it but sequence), *deferred by choice*
(the user postponed it; it waits on nothing), *blocked on a decision*
(something must be settled before it can start), and *blocked on <phase>*.
*Implemented, exit not met* is not one of them: the plan's work landed,
but the phase's own exit criterion is still false, and says which part.

### P0 — Foundations

No VM yet. Repository skeleton, `lib/common.sh`, `NOTES.md`,
`docs/host-profile.md` populated from the probe. The `vendor/` fetch-and-verify
machinery, which refuses on checksum mismatch. A `preconditions.sh` that
re-verifies CPU, `/dev/kvm`, QEMU, OVMF paths, and required packages, and
prints a go/no-go. Handling for `ignore_msrs`, which needs `sudo` and therefore
an ask.

**Exit:** `preconditions.sh` green; repo committed.

### P1 — Known-good boot

De-risk by starting from the configuration that is known to have worked, then
change one thing at a time.

- Run `get.sh` unmodified on the Intel Mac to produce
  `InstallMacOSXMavericks.dmg`; `dmg2img` it to a reference installer image.
  Record its checksum. This is installer Approach C, the path Kostarelas
  proved.
- Fetch and unpack Kostarelas's UTM bundle into `$MQG_VENDOR_DIR`. Parse its
  `config.plist` and document **every** setting in `docs/prior-art.md`:
  architecture, machine type, CPU model and flags, extra QEMU arguments,
  memory, cores, every drive with its interface and image type, NIC model,
  display device. Nobody has inspected this bundle for this work; report what
  is actually in it.
- Translate those settings into a plain `qemu-system-x86_64` command line,
  swapping TCG for `-enable-kvm` and choosing a `-cpu` KVM accepts.

**Exit:** the OpenCore picker shows the installer and the installer reaches its
GUI under KVM. The exact command line is in `NOTES.md`.

### P2 — Manual install, once, instrumented

This phase exists deliberately rather than being folded into automation: **the
click-log from installing by hand is the specification that P4 automates.**
Writing automation against a process nobody has watched is how P4 fails.

- Install to a qcow2 target by hand, recording every step.
- Keep SMP enabled for the first boot after install; Somlo reports 10.9 first
  boot fails without it.
- Reach the desktop, then reboot cleanly.
- **Census what works and what doesn't**, as a table in `NOTES.md`: sound,
  resolution changes, sleep, shutdown, networking, and the Safari/TLS
  limitations Kostarelas hit. This is the honest-limitations list the final
  report owes the user, and the earlier it exists the less it looks like an
  excuse.
- Get guest networking working, including DNS — Kostarelas needed 1.1.1.1, and
  khronokernel's `scutil` recipe does the same from the installer
  environment. For any error contacting Apple's servers, check the guest clock
  first.
- Stand up `golden.sh` and `clone.sh`; promote golden #1.

Apple's 2016 security update and Mavericks Forever's post-install hardening
script are both candidates here. **List what each would change and wait for
approval** before applying either; a hardening script that silently alters the
baseline makes every later measurement suspect.

**Exit:** the guest reboots to the desktop unattended from power-on; golden #1
exists; a throwaway clone boots; the capability census is written.

### P3 — Reproducible boot stack

De-blobbing, as its own phase and its own gate, because the image pipeline
bakes in whatever firmware it is built against and retrofitting
reproducibility afterward is a rewrite.

Swap one component at a time against P2's golden baseline, so that when a
stock component fails, it is unambiguous which one failed.

- **Firmware:** replace the bundle's OVMF with Mint's `ovmf` package. If it
  fails, log exactly how, then build EDK II from a pinned tag.
- **Bootloader:** `build-opencore.sh` — OpenCorePkg at a pinned release tag,
  our own `config.plist`, `OpenHfsPlus.efi` built from source. Measure what
  the open HFS+ driver costs at boot versus Apple's, and record it; if the cost
  is large the user can overrule the choice knowingly.
- khronokernel's `EFI-LEGACY.img` stays Tier 2, available as a fallback
  comparison only.

**Exit:** no run profile and no part of the image pipeline references
`$MQG_VENDOR_DIR`. Checked by a test, not by assertion.

#### P3 status: complete, 2026-09-17

**Met.** `vmavs run p3-full` boots 10.9.5 to the desktop with **no Tier 2
component anywhere in the boot path**: OpenCore 1.0.7 and OVMF built
offline from the same pinned `acidanthera/audk` tree, our own
`config.plist`, `OpenHfsPlus.efi`, and pinned Lilu 1.7.2 / VirtualSMC
1.3.7. `bin/tier-check.sh --strict` is now a section of
`bin/run-tests.sh`, so the rule is enforced on every test run rather than
checked by hand. Every component, pin and checksum is in
`docs/decisions/0004-p3-boot-stack-provenance.md`.

Answered on the way, each of which had been guessed at before:

- **SMBIOS alone fixed the `AppleTyMCEDriver` panic.** Our config has
  `Kernel > Block: []` and has never contained the block P1 enabled.
- **`FakeSMC-32` was redundant.** Two SMC kexts, not three.
- **EFI variables persist** over split pflash, which `-bios` had denied
  since P1.
- **`OpenHfsPlus.efi` costs 3.3 s of a 49 s boot** versus Apple's driver —
  and Apple's driver will not load on our firmware at all, because audk's
  strict PE loader rejects it. `docs/decisions/0002` has the measurement.
- **The firmware belongs in Tier 0**, for the reasons recorded in §4.

**Not met at the time, and since fixed (2026-09-17, `NOTES.md` "P4 — the
keypress requirement is fixed"): `p3-full` required a keypress.** The
paragraph below is kept as written because it is the record of what was
wrong and why; P4's unattended installs are the evidence it no longer is.
`Misc > Boot > Timeout = 5` with an empty NVRAM makes the
picker's default the OpenCore disk itself, so an unattended boot times out
into `EFI_ALREADY_STARTED` and hangs; `2` must be pressed within five
seconds. It is a `config.plist` defect, not a firmware one, and it was left
alone here because the task that found it had a different single variable
under test. The obvious next experiment is
`UEFI > Input > KeySupport = false`, which would also let the picker
remember a default — modified keys (`ctrl-2`, `ctrl-Enter`) currently reach
nothing.

**Also deliberately skipped: golden #2.** See the note at the end of
`docs/superpowers/plans/2026-09-17-p3-reproducible-boot-stack.md`.

### P4 — Unattended pipeline (goal #2)

- **Linux-native media** (installer Approach A), following
  `eprigorodov/mkosxinstallusb`: `dmg2img` plus `kpartx`/`losetup -P` to mount
  InstallESD then BaseSystem, `mkfs.hfsplus`, `rsync -aAEHW`, then replace
  `System/Installation/Packages` with the ESD's `Packages`,
  `BaseSystem.chunklist`, and `BaseSystem.dmg`. Retargeted from `/dev/sdX` to
  a loop device over a raw image file, GPT with an AF00 partition.
- **Verify it against P1's reference image.** A finished `rsync` proves
  nothing. Compare file counts, sizes, and extended attributes; check `dmesg`
  for hfsplus errors; specifically test whether HFS+-compressed files in
  BaseSystem survived, and whether the Korean localization loss noted in
  mkosxinstallusb's README occurs. Treat any "damaged package" or missing-file
  error in the installer as a likely copy problem.
- **Scripted install.** Two candidate mechanisms, timeboxed, pick one with
  evidence: (a) drive `installer -pkg OSInstall.mpkg -target` from the
  installer environment, reached over a serial console or SSH; (b) modified
  installer media that auto-runs a script at boot.
- **First-boot payload**, adapted from `timsutton/osx-vm-templates`: create the
  user, install `authorized_keys`, write `.AppleSetupDone` to skip Setup
  Assistant, disable sleep, screensaver, and software update, and set the
  clock.
- `image/build-image.sh` end to end.

**Fallback:** if both unattended-install mechanisms fail, P4 degrades to
semi-automatic and we say so plainly rather than claiming otherwise.

**Exit:** one command from a clean checkout produces a bootable, SSH-reachable
image with zero human interaction. Run twice; outputs equivalent.

**Met, 2026-09-17.** `image/build-image.sh`. Two things went differently from
the plan above, both for the better and both recorded in `NOTES.md`:

- **The scripted install is Apple's own.** Neither candidate mechanism was
  needed: `/etc/rc.install` already reads `/etc/rc.cdrom.local`,
  `Extras/minstallconfig.xml` and `OSInstall.collection`. We prepare the disk
  and Apple's installer does the rest, including the reboot.
- **The first-boot payload is installed by the installer**, as a flat package
  listed in `OSInstall.collection`, rather than injected onto a finished
  volume. Building a `.pkg` on Linux with neither `xar` nor `mkbom` turned out
  to be possible: `image/payload/mkflatpkg.py`.

"Equivalent" is defined, and checked, by `image/compare-images.sh` and
`docs/decisions/0006-image-pipeline-reproducibility.md`. Two local builds:
**321,104 installed files, zero differing paths, zero differing sizes**,
both answering SSH 780 s after the VM started. A build from a fresh `git
clone` with an empty image directory: **940 s**, and media whose content
digest matches the local one exactly.

**What P4 does not deliver**, stated here so nobody has to infer it:

- **Byte-identical images.** Deliberately not the claim; `decisions/0006`
  says what is claimed instead.
- **A byte-reproducible boot stack.** The fresh clone rebuilt OpenCore and
  OVMF from the same pinned source and got different bytes -- EDK II stamps
  its build into the firmware, and `mformat` writes a volume serial. The
  stack is *rebuildable*, which is what P3 claimed; the checksums in
  `decisions/0004` identify this host's build rather than the source.
- **An answer to `open-questions.md` Q1.** `--updates` exists with one
  value implemented, so answering it is configuration rather than a rewrite.
  **Answered 2026-09-22** — two images, `none` for P5's baseline and
  `security` as the default — and the configuration it predicted is being
  implemented now. The prediction held: no rewrite was needed.
- **Two concurrent builds on one host.** One of them wedged; see `NOTES.md`.

### P5 — Interactive performance (goal #3) — deferred by choice

**Deferred by the user, 2026-09-22, not by sequencing.** The guest is
"working fine enough", and `decisions/0007` puts P5 after shipping for an
independent reason: P5 measures Product A's `run`, so its baseline should be
a baseline of the shipped thing rather than of a scratch invocation. What
follows is the plan for when it resumes, unchanged.


Tuning, not re-bring-up. Start from the known-good command line, change one
thing at a time, every change measured and reversible.

**Baseline first** (`bench/`): cold boot to SSH-ready, timed host-side; login
to a usable desktop; cold and warm launch of Safari, TextEdit, and Terminal;
window drag/resize smoothness and Mission Control responsiveness, captured as
screen recordings or host-side frame-time estimates with the method described;
a CPU benchmark; disk throughput noting caching effects; `iperf3` network
throughput, built for 10.9 with the build logged. Plus qualitative notes:
pointer lag, tearing, redraw artifacts. Every later experiment reports against
this.

Then, one variable at a time:

- **CPU and memory.** Models beyond the bring-up choice, starting with
  `Haswell-noTSX` plus `+invtsc` as OSX-KVM uses. If 10.9 panics on a model,
  try OpenCore's `Cpuid1Data`/`Cpuid1Mask` to report a supported CPU while
  keeping newer instruction sets, logging exact settings. vCPU counts of 2, 4,
  and 6 — six physical cores are available — pinned to physical cores rather
  than SMT siblings. 4 GB versus 8 GB; hugepages on versus off. Host governor
  `performance` versus default. Confirm the guest clock stays stable with no
  TSC-related stutter.
- **Storage and network.** Raw versus qcow2; `cache=none` versus default;
  `aio=io_uring` versus `native` versus `threads`. Stay on AHCI — confirm
  rather than assume there is no 10.9 virtio block driver. Install
  `pmj/virtio-net-osx` 0.9.4 and compare `virtio-net-pci` against
  `e1000-82545em` with `iperf3`; keep e1000 as fallback until virtio survives
  a multi-hour transfer and a sleep/wake or snapshot cycle. Verify — do not
  assume — how 10.9 handles unsigned kexts, and whether `kext-dev-mode` is
  needed.
- **Reduce guest work.** One at a time:
  `NSAutomaticWindowAnimationsEnabled`, Dock `launchanim`,
  `expose-animation-duration`, `NSWindowResizeTime`, Dashboard, login items
  and agents. Spotlight indexing off **only with the user's agreement**.
  Compare 1280×800, 1440×900, 1920×1080. Deliver an apply script and a revert
  script.
- **Display device and driver.** `-vga std` across `vgamem_mb` values,
  recording which resolutions 10.9 offers and whether it sees the extra VRAM —
  Kostarelas saw about 3 MB under UTM, which could not pass the parameter;
  plain QEMU can. `-device vmware-svga` bare as a baseline. Then VMQemuVGA and
  VMsvga2 (original and the QiuMike QEMU variant, rebuilt for 10.9 if needed),
  recording whether each loads cleanly, which resolutions it offers, any 2D
  speedup, and any artifacts. `usb-tablet` versus `usb-mouse` for lag, drift,
  and absolute positioning.
- **Transport.** QEMU's local display (GTK versus SDL), QEMU's VNC server, and
  10.9's built-in Screen Sharing over the network. Report which *feels*
  fastest with whatever measurement can be justified. This is where the effort
  reclaimed from the cut passthrough phase is reinvested, and on this host it
  is where the interactive wins most plausibly are.

**Exit:** a baseline-vs-tuned table; a recommended default profile; golden #2;
every host-specific recommendation flagged as such in the generalization
ledger.

### P6 — GitHub Actions runner (goal #4)

Runs on the Apple Silicon Mac and on GitHub's arm64 macOS runners, under TCG,
because arm64 has no x86 hardware virtualization. Used **sparingly**: release
tags, a scheduled run, manual dispatch, or a PR label. Never on every push.
The aim is added assurance with as little Mavericks in the pipeline as
possible.

Runner budget, to be verified rather than assumed: 3 M1 cores, 7 GB RAM, 14 GB
SSD; jobs capped at 6 hours; `actions/cache` evicting entries unused for 7 days
against a default 10 GB per-repo quota — which is precisely the pattern that
gets evicted.

- **Pin QEMU**: build a specific release, pkgsrc preferred, recording version,
  build options, and checksum.
- **Build the image** by reusing P4's pipeline with `accel=tcg`, a fixed
  `-machine pc-q35-X.Y` never the unversioned alias, and a `-cpu` model
  matching the oldest hardware to be supported — **ask the user which**. RAM at
  most ~4 GB, the smallest that works reliably. Headless, serial console where
  possible, SSH for control.
- **Trim and compact**: remove unneeded languages and apps, zero free space,
  `qemu-img convert -c`. Compressed download plus base image plus job overlay
  plus artifacts must fit comfortably in 14 GB.
- **Multicore TCG**: `thread=single` versus `thread=multi` over at least 10
  boots each; pick one and pin it with the evidence. khronokernel measured
  17 minutes to recovery on an M1, 8 with forced multicore, warning that
  multicore can cause bugs.
- **Snapshots**: boot to idle, logged-in, SSH-ready, then `savevm ci-ready`.
  Confirm `loadvm` restores reliably across at least 10 cycles, verifying SSH,
  guest clock, and outbound slirp networking after each. Every job uses a
  throwaway overlay; the base is never written. **If the round-trip is
  unreliable, say so plainly — it decides whether the design is viable.**
- **CPU-model gating**: compile and run a binary using an instruction set the
  chosen `-cpu` does not advertise, e.g. AVX. Confirm it faults with SIGILL
  rather than silently running. If TCG runs it anyway, report that clearly; it
  changes what the smoke tests can promise.
- **Storage**: implement both `actions/cache` with a keep-alive job, and
  user-controlled authenticated HTTPS storage with credentials from a repo
  secret; recommend one with evidence. The cache key covers QEMU version and
  build, machine type, CPU model, OVMF and OpenCore checksums, installer
  checksum, and image build revision.
- **Reusable workflow** `mavericks-smoke.yml` with `on: workflow_call`, taking
  an artifact name, a smoke-test script path, and optional timeout and RAM
  overrides. Retry boot/restore once; never retry test failures. All logic
  lives in `ci/mavericks/` scripts so it runs identically on a local Mac; the
  YAML only calls them. Ship an example caller and example smoke tests.
- Fallbacks if a locally-made snapshot won't restore on a runner, in order:
  rebuild the snapshot on the runner in a dedicated job; cold boot every job,
  with the cost measured.

**Exit:** `mavericks-smoke.yml` green on `macos-15` within 30 minutes, inside
the RAM and disk limits, with `df` and memory pressure logged.

### P7 — Guest integration — split by `decisions/0007`

This phase was written as one thing and is two. `decisions/0007` separated
them and the spine now reflects that.

**The interop half ships in P8, and only as `emit`.** "Emit config for
target X" is not guest integration at all — it is a format-mapping exercise
over a machine description this project already has, because `vm/profiles/`
*is* a canonical parameterised description of a machine (`docs/test-hosts.md`).
P8 ships exactly one emitter, **Packer**, because one Packer template
reaches QEMU, VirtualBox, VMware and Proxmox and its `vagrant`
post-processor makes the boxes. libvirt XML, `.utm`, a Proxmox config and a
container recipe all reach targets that template already covers, so they
stay unwritten rather than duplicated.

**Packer is an emit target and not the build**, for three reasons.
Packer's core value is `boot_command` GUI keystroke automation, which P4
engineered away entirely by using Apple's own unattended hooks. Adopting it
would cost the stage-level input-hash freshness the pipeline now has, and
most of the manifest. And it covers two stages of eleven.

**The guest-side half stays deferred by choice**, and belongs to Product B
(`decisions/0007`, Decision 1). Recorded, not planned; it will be
re-brainstormed once P5 shows what is actually limiting. The milestone
structure and prior art are preserved in `docs/prior-art.md` so nothing is
lost:

- **M0** absolute pointer via `pmj/QemuUSBTablet-OSX` and `-device usb-tablet`
- **M1** a host↔guest channel without kexts: does stock 10.9 drive QEMU's
  `isa-serial` or `pci-serial`?
- **M2** a virtio-serial kext, only if M1 fails (approval)
- **M3** clipboard over the SPICE agent protocol, using QEMU's built-in
  `qemu-vdagent` chardev host side
- **M4** a QEMU guest agent for ping, info, graceful shutdown, exec, file
  transfer, and time resync after snapshot restore
- **M5** hardware cursor, dirty rectangles, and arbitrary modes in VMsvga2 or
  VMQemuVGA, plus resize-to-window driven by the agent's monitor-configuration
  messages
- **M6** backporting virtio-gpu to 10.9, only if M5 hits limits in QEMU's
  device (approval)

Out of scope there and here: 3D acceleration (Quartz Extreme / Core Image),
shared folders (use SMB, NFS, or sshfs), and a virtio block driver.

### P8 — `vmavs`, the front door (the product decision) — **implemented; exit met by the Go `vmavs run` + `vmavs ssh`**

Added 2026-09-22, after `decisions/0007`. The four goals at the top of this
document are about making something work. This phase is about making it
something a stranger can use, which is a different kind of work and was not
tracked anywhere — so it was about to be done as an errand.

The machinery is done. Eleven stages work, 553 tests are green, and what is
missing is a name to type. `decisions/0007` lists ten subcommands and every
one of them maps onto a stage that already exists.

- **`bin/vmavs` dispatches; nothing moves.** The scripts stay under `boot/`,
  `media/`, `image/` and `vm/`, because those directory names are what says
  what each script is for, because roughly 150 references across the docs,
  the tests and the scripts point at them, and because `NOTES.md` is
  append-only and rewriting 26 of its entries would falsify the record. An
  installed copy is the whole tree under a libdir with one `vmavs` in
  bindir, which is what `libexec/` would have bought without the rename.
- **The direct scripts keep working and stop being documented.** They cannot
  be deprecated: `vmavs image` *is* `image/build-image.sh`. There are no
  external users to break — neither repository has a git remote — and 553
  internal ones that must not be.
- **A version the command can report.** `YYYYMMDD.N`, the family's
  **self-upstream** shape (`mavericks-porthole`). `decisions/0007` declared
  a deviation from `<upstream>-mavericks.N` on the grounds that there is no
  single upstream, which is right and stops one step short: the family's
  own answer to "no single upstream" is that the product is its own
  upstream. See `docs/decisions/0012-version-scheme.md`.
- **A README that is product documentation.** It currently opens by
  describing the host it was developed on.
- **`emit packer`**, per the P7 split above.

**Exit:** `vmavs doctor`, `vmavs image`, `vmavs run` and `vmavs ssh` take
someone from a clean checkout to a shell in a Mavericks guest; the README
says so in its first thirty seconds; `./bin/run-tests.sh` green.

**Where it stands, 2026-09-24:** everything above the exit landed. The
shell `bin/vmavs run` still only boots this project's development
profiles, none of which points at the image `vmavs image` builds — that
half of the gap is unchanged. But the Go `vmavs run` + `vmavs ssh`
(`docs/superpowers/specs/2026-09-24-vmavs-in-go-design.md`, phase 1) close
it from the other side: **MEASURED on 2026-09-25, against a shell-built
image on this KVM host** (`vmavs run --image mavericks-20260922`, then
`vmavs ssh`), a clean checkout that already has a shell-built image reaches
a shell in it — `sw_vers` answers `10.9.5` within a minute, and the legacy
image (`mavericks-a`, Apple's OpenSSH 6.2) does too once
`internal/guest/ssh.go`'s legacy cipher list was fixed in the same pass.
Full detail, including the legacy-SSH root cause and fix, is in NOTES.md,
"P8 — the Go vmavs boots a built image and answers SSH". The exit's other
clauses hold as before: `emit packer`'s schema is MEASURED by `packer
validate`, which CI runs on every profile's template; no `packer build` has
run from it, so the drive mapping is still REASONED; `./bin/run-tests.sh`
stays green.

Plan: `docs/superpowers/plans/2026-09-22-shipping-vmavs.md`.

### P9 — Build in a controlled Linux VM — **blocked on a decision**

Spec: `docs/superpowers/specs/2026-09-21-build-in-a-linux-vm-design.md`. The
*direction* is the user's and is approved; the *design* is proposed and not
adopted, and no implementation plan exists.

It sits between P8 and P10 for a concrete reason. Its headline number is
that **the host tool list shrinks from 36 executables plus a development
header to about seven** (its §9.1), because everything that produces bytes
moves inside and only `target`, `install`, `verify` and `manifest` stay
outside. That number is the input to P10's distribution question, and
choosing a packaging mechanism before it is settled would bake a dependency
list we are about to delete into packaging metadata.

**Adoption is conditional, and the conditions are written down in advance**
(its §7.4): a cold boot stack more than **1.5×** native, a warm rebuild over
**60 s**, or a `--freshness` answer over **10 s** each say "keep it as an
optional backend for foreign hosts; do not make it the default". So P10 must
not assume it lands.

### P10 — Release packaging and distribution — **blocked on P9**

What a release is, and how a host gets the tool. Missing today:
`.github/workflows/release.yml`, `release-notes/`, and a decision about the
artifact. (`renovate.json`, `INGREDIENTS.md`, `build/msc.sh`,
`.claude/settings.json`, `ci.yml` and `conventions.yml` all exist.)

**The distribution question is deliberately open**, for the reason in P9
above. Two candidate worlds: with ~36 host dependencies, realistically a
`git clone` or a distro package with a long dependency list; with QEMU plus
a handful, a tarball or a single pkgsrc or Homebrew entry becomes
reasonable. pkgsrc is the only candidate that covers NetBSD, Linux, macOS
*and* eventually 10.9 from one recipe — an argument from host coverage.
Whether pkgsrc still supports 10.9 in 2026 has not been checked here.

**One constraint binds whatever is chosen, and it is structural rather than
procedural: a release must be incapable of shipping Apple's bytes.** The
artifact is `git archive` of the tag and nothing else, because
`bin/no-apple-bytes.sh` checks exactly what `git archive` would package — an
artifact assembled any other way would make that gate partial, and a gate
that covers most of a thing reads green while the thing is wrong. The gate
runs in the release job, not only in `ci.yml`: checking it on pull requests
and not on the release checks the wrong artifact.

The workflow's full shape — release model, triggers, concurrency, notes
generator, declared state — is specified in the shipping plan's Phase C so
that this becomes an hour of planning rather than a re-derivation.

## 7. Testing strategy

- **Shell logic gets real tests.** `shellcheck` plus a test harness, with TDD
  where there is genuine logic: media verification, manifest checking, profile
  composition, tier enforcement.
- **Media verification is itself a test suite** — file counts, sizes, extended
  attributes, and HFS+ compression fidelity diffed against P1's Mac-produced
  reference image.
- **The tier rule is a test**, not a promise: nothing shipped references
  `$MQG_VENDOR_DIR`.
- **The image pipeline is validated by building twice and comparing.**
- **The benchmark suite is the guest-side regression test**; golden clones
  keep experiments isolated.
- **Stability claims require repetition.** Ten-cycle runs in P6, multi-hour
  soaks for anything claimed stable. One success is not evidence.

## 8. Risks

1. **HFS+ fidelity on Linux (P4).** The brief flags dropped Korean
   localization and unverified HFS+ compression handling. Mitigated by having
   P1's reference image to diff against — the reason Approach C runs first.
2. **Unattended install on 10.9 is unproven.** Two candidate mechanisms,
   timeboxed; documented degradation to semi-automatic if both fail.
3. **OVMF mismatch (P3) — CONFIRMED, 2026-09-17.** The bundle carries a
   ~1.9 MB EDK II build passed via `-bios`, not a pflash pair; Mint ships 4 MB
   split CODE/VARS only. P1 runs on the bundle's firmware, which means EFI
   variables do not persist. P3 must find out whether a current 4 MB OVMF
   boots this configuration at all.
4. **The `t2` kernel is unusual.** Patched for Apple T2 hardware; any KVM or
   IOMMU oddity will be hard to distinguish from a guest bug.
5. **No local parity with GitHub's runners (P6).** The Apple Silicon Mac is
   faster and less constrained than 3 cores / 7 GB / 14 GB.
6. **10.9's unsigned-kext behavior is unverified** and matters in P5 for
   virtio-net, VMQemuVGA, and VMsvga2. The belief that 10.9 only warns is
   explicitly unconfirmed.
7. **OpenCore's `Kernel > Block` had no observable effect (P1).** Enabling the
   shipped block for `AppleTyMCEDriver` did not prevent the panic; changing
   SMBIOS did. P3 builds its own OpenCore and should not assume `Block` works
   until it has been demonstrated to.
8. **Absolute pointing needs a kext.** `usb-tablet` does nothing on 10.9, so
   the guest requires a pointer grab. This makes integration milestone M0
   (`pmj/QemuUSBTablet-OSX`) a concrete, already-justified win rather than a
   speculative one — worth reconsidering the decision to defer all of P7.

## 9. Stop and ask

Beyond the standing permission asks in §3, stop and report if:

- The Apple download fails or a checksum mismatches.
- An upstream artifact is unavailable — the UTM bundle, khronokernel's images,
  Somlo's Chameleon binary, DarwinKVM's Mavericks config, a Kernel Debug Kit.
- Three materially different attempts at the same step all fail.
- A phase runs to roughly twice its initial estimate.
- A phase produces no measurable improvement after its planned experiments;
  report before inventing new ones.
- P6's snapshot round-trip is unreliable, the install won't fit the runner
  limits, TCG won't enforce CPU-model gating, a storage option would require
  making the image publicly reachable, or a smoke-test job can't reliably
  finish in about 30 minutes.

## 10. What was cut

**GPU passthrough** — the perf brief's Phase 5 — is cut. See
`docs/decisions/0001-no-gpu-passthrough.md`. The effort is reinvested in P5's
display-transport comparison.

**Chameleon + SeaBIOS** (Somlo's path) is retained only as a documented
fallback if OpenCore proves unworkable under KVM, not as a planned phase.

**OpenCore's `macrecovery.py`** and **gibMacOS** are rejected as installer
sources: the former fetches only a recovery image needing internet inside the
guest, so it is not offline media; the latter's catalogs do not reach 10.9.

# Design: OS X 10.9 Mavericks as a usable KVM guest

Date: 2026-09-17
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
| OVMF firmware | 1, falling back to 0 | Mint's `ovmf` package is vanilla EDK II. Kostarelas notes his is ~5 years old and a current build was untested; if a current one fails, build EDK II ourselves at a pinned older tag. |
| OpenCore | 0 | `build-opencore.sh` fetches OpenCorePkg at a pinned release tag, builds it, and assembles `EFI/OC` against **our own `config.plist`**, checked in as diffable text. |
| HFS+ EFI driver | 0 | OVMF cannot read HFS+, so OpenCore needs one. `HfsPlus.efi` is Apple's binary extracted from Mac firmware — Tier 2 by construction, never buildable. Use `OpenHfsPlus.efi`, which OpenCorePkg builds from source, and accept that it is slower. See `docs/decisions/0002-openhfsplus-over-apple-hfsplus.md`. |
| `isa-applesmc` OSK | n/a | A constant, not a blob. This host is a real Mac, so reading the OSK off its own hardware is available as a clean path if preferred. |
| QEMU | 1 on Linux, 0 on macOS | Ubuntu's 8.2.2 here; a pinned self-built QEMU (pkgsrc preferred, not Homebrew's floating version) for the GHA phase. |

Third-party binaries are recorded in `vendor/MANIFEST.sha256`. Fetch scripts
verify against it or refuse.

## 5. Architecture

### 5.1 Repository layout

```
docs/
  superpowers/{specs,plans}/   design docs and implementation plans
  prior-art.md                 every source, and what each one gives us
  host-profile.md              host facts; the generalization ledger
  decisions/                   ADRs: what we chose, the evidence, what we rejected
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

### P5 — Interactive performance (goal #3)

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

### P7 — Guest integration (deferred)

Recorded, not planned. The user chose to defer all of it; it will be
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
3. **OVMF mismatch (P3).** Mint ships 4M split CODE/VARS only; the UTM bundle
   most likely carries a combined older image. May force building EDK II or
   sourcing a 2M package.
4. **The `t2` kernel is unusual.** Patched for Apple T2 hardware; any KVM or
   IOMMU oddity will be hard to distinguish from a guest bug.
5. **No local parity with GitHub's runners (P6).** The Apple Silicon Mac is
   faster and less constrained than 3 cores / 7 GB / 14 GB.
6. **10.9's unsigned-kext behavior is unverified** and matters in P5 for
   virtio-net, VMQemuVGA, and VMsvga2. The belief that 10.9 only warns is
   explicitly unconfirmed.

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

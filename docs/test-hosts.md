# Triangulation hosts

`docs/host-profile.md`'s generalization ledger records every assumption this
project makes about its host. **Each entry is a hypothesis, and a second host
is the only way to test one.** This file says which machines can test what,
so that a portability run has a purpose rather than being "try it somewhere
else and see".

Nothing here is scheduled. It exists so the hypotheses are attached to the
hardware that can settle them.

**Two axes, not one.** The machines below test *same software, different
hardware*. The hypervisors at the end test *same guest disk, different
virtualization stack* — a different question, and one nothing else here
asks.

## The hosts

### Mac mini 2018 (`Macmini8,1`) — Linux Mint 22.3 — **primary**

Everything so far was developed here. i7-8700B, Coffee Lake, 6C/12T, 62 GB,
T2, btrfs on NVMe, repo on NFS. See `docs/host-profile.md` for the full
profile.

Nested virtualization is available (`kvm_intel.nested = Y`) and it is
Nehalem-or-newer, so **this is currently the only host that can test the
VMware Fusion requirement** in `decisions/0005`.

### Mac Pro 1,1 — OpenMediaVault — **the Xeon counter-example**

The most informative second host, because it differs on the two axes where
our assumptions are least tested.

**Hypotheses it can settle:**

| Ledger | Claim | What this host tests |
|---|---|---|
| **G14** | SMBIOS must not be `MacPro5,1`, because `AppleTyMCEDriver` panics on a non-Xeon CPU | This *is* a Xeon, and it is now the ONLY thing still missing. The observation was re-run on the primary host on 2026-09-21 and **it reproduces** on our own boot stack (`decisions/0010`), so there is nothing stale to rule out. If `MacPro5,1` installs here, G14 is confirmed host-specific. **If it panics anyway, my explanation of P1's panic was wrong** and the real cause is something else. One command: `bin/triangulate.sh --full --cpu Conroe --smbios MacPro5,1`. |
| **G3** | The guest CPU model must be masked down from the host's | Inverts the problem: this host is *older* than the model we ask for — and as of 2026-09-21 we know how far down the mask can go. |
| **G25** | This host can provide every `-cpu` line in `lib/cpu.sh`'s table | Answered in about a second per row by `bin/triangulate.sh --probe`, with nothing installed. Woodcrest should refuse the `Penryn` rows and accept `Conroe`. |
| **G2** | Intel with VT-x | Worth confirming VT-x is present and enabled; some early Mac Pros shipped without it. |

### The CPU string: this entry was wrong for a year, and it cost us the machine

**What this section used to say**, and what was acted on: the guest asks for
`Penryn,+ssse3,+sse4.1,+sse4.2`; Mac Pro 1,1 is Woodcrest — 65 nm Core,
2006 — and **SSE4.1 arrived with Penryn in 2007**; a Woodcrest host cannot
provide it, so `-cpu Penryn,+sse4.1` should be rejected outright. Reasoned
from CPU generations, **never measured**, and read as "this host cannot run
the project".

**Half of that is still true and the conclusion was wrong.** Woodcrest
really cannot provide SSE4.1. **Mavericks does not need it.** Measured
2026-09-21 on the primary host (`docs/decisions/0009`): `-cpu Conroe` —
Conroe/Merom, SSSE3 with no SSE4.1 and no SSE4.2, which is Woodcrest's
feature set — boots this guest to SSH in 20 seconds, passes the verify
stage's checks, and hashes 64 MiB correctly. The guest's own
`machdep.cpu.features` lists `SSSE3` and no SSE4 of any kind. 10.9's floor
is SSSE3, which is what everyone always said it was; the SSE4.1 in our line
came from a UTM bundle, not from the OS.

**So this host is viable, and it is the only machine that can settle G14.**
What to run here, in order:

1. `bin/triangulate.sh --probe` — installs nothing, needs no root, and its
   `-cpu` table says which rows this machine can provide. Expect the
   `Penryn` rows refused (naming `sse4.1` as the missing feature) and
   `Conroe` accepted. That alone confirms both halves of `decisions/0009`.
2. A full pipeline run with `--cpu Conroe`. If it installs and answers SSH,
   the `Conroe` row in `lib/cpu.sh` moves from BOOTED to VERIFIED and
   becomes the sensible default for a project whose portability story is
   "hosts older than ours".
3. **G14, which is why this machine was wanted in the first place**, and
   which is now one command:

   ```
   bin/triangulate.sh --full --cpu Conroe --smbios MacPro5,1
   ```

   `--smbios` exists as of `decisions/0010`; before that the model was
   hardcoded in `boot/config/config.plist` and the experiment needed a
   tracked file edited by hand, which is why it waited three phases.

   **The control has already been run**, on the primary host, on
   2026-09-21: `MacPro5,1` panics there on our own OpenCore 1.0.7 and our
   own OVMF, with P1's backtrace, on an already-installed guest. So the
   entry is not stale and this run is worth the trip.

   What the outcomes mean:

   - **Installs and answers SSH** → `AppleTyMCEDriver` was fine on a real
     Xeon. The explanation survives, G14 is host-specific, and the report
     says CONFIRM by itself.
   - **Panics** → **my explanation was wrong.** The advice (do not ship
     `MacPro5,1`) keeps its evidence and loses its reason. The report says
     CANNOT-SAY here on purpose, because the backtrace is on the guest's
     screen and reaches no log: read the last screenshots under
     `$MQG_IMAGE_DIR/screenshots` — **2 colours is white-on-black text, not
     a blank screen** — and if `AppleTyMCEDriver` is in the backtrace, edit
     the ledger by hand.
   - **Stops in an earlier stage** → nothing about G14 either way, and the
     report names the stage.

   **Do not sit through the whole timeout.** A panicked guest never
   answers SSH, so the install stage would burn its full hour
   (`MQG_INSTALL_TIMEOUT`, 3600 s by default) before giving up — while a
   healthy install on this host takes about 1650 s. `build-image.sh` logs
   a screenshot verdict every two minutes; a `text` screen that has not
   changed by the four- or six-minute line is the panic, and the PNG
   beside it says so outright. Let the stage fail on its own if you can,
   because the recorded failure is what the report judges.

   Either result also wants a `NOTES.md` entry, including "it panicked and
   I could not read why".

**The lesson is not about SSE4.1.** A prediction from first principles sat
in this file as though it were a result, and the machine it was about was
never plugged in to check. It reads the same either way; only the italic
disclaimer said otherwise, and nobody acts on an italic disclaimer.

**What it cannot test:** nested virtualization. Woodcrest has VT-x but **no
EPT**, which arrived with Nehalem in 2008, so VMware Fusion in the guest is
very unlikely to work. Do not use this host to evaluate `decisions/0005`.

**Also not useful for P5 performance baselines** — a 2006 machine measures
its own age, not our tuning.

**Practical caveats:** OpenMediaVault is a NAS appliance distro. Debian
underneath, so the package landscape is familiar, but installing a build
toolchain may fight its management model. It is also presumably doing a job
already; disruption there costs more than on a spare machine.

### MacBook Air 2017 13" — macOS Sequoia

Apple hardware running macOS, so it is the closest thing here to the
environment the **GitHub Actions phase (P6)** targets — except that P6 needs
arm64 and this is Intel.

Its real value is as a **second macOS build host**: it can run `get.sh`
unmodified, and it can build things needing a macOS toolchain. Whether it
can run the guest itself depends on whether QEMU with the Hypervisor
framework (`-accel hvf`) works there, which is a third accelerator alongside
KVM and TCG and would test the same parameterisation P6 relies on.

### MacBook Air 2015 11" — EndeavourOS

Arch-based rather than Debian-based, which makes it the useful test of a
different assumption: everything in this project so far assumes `apt`,
Debian's `ovmf` package layout (`/usr/share/OVMF/OVMF_CODE_4M.fd`), and
Debian package names in `boot/prereqs.sh`.

**Hypotheses it can settle:**

| Ledger | Claim | What this host tests |
|---|---|---|
| ~~**G5**~~ | ~~OVMF is 4M split CODE/VARS at `/usr/share/OVMF/`~~ | **Nothing left to test: resolved in P3 by building our own firmware**, so no distro OVMF is read by anything that ships. What this host *can* still falsify is the replacement claim — that `boot/build-ovmf.sh` and `boot/build-opencore.sh` reproduce the same checksums on a different distro and toolchain. That is a stronger test than the one G5 asked for. |
| **G10** | Local filesystem is btrfs, so `cp --reflink=auto` makes golden promotion near-instant | Different filesystem, so promotion cost changes. |
| **G11** | btrfs needs `chattr +C` on the image directory | Not applicable off btrfs. |
| — | `boot/prereqs.sh` names Debian packages | It would need an Arch mapping, or to stop naming packages at all. |

2015 Broadwell: Nehalem-or-newer, so it *could* test nested virtualization,
subject to RAM (a 2015 11" Air is likely 4–8 GB, which is tight for a 4 GB
guest running its own hypervisor).

### NetBSD with nvmm — aspirational

Described by the user as "later later later". A different accelerator
entirely (`-accel nvmm`). Would test the deepest assumption: that
`-enable-kvm` and `kvm.ignore_msrs` are incidental rather than load-bearing.

Less exotic than it sounds, because the accelerator is already a parameter
in this design — P6 runs the same image pipeline under TCG.

### Mavericks itself, under `vm-host` — the recursive case

The sibling project `mavericks-vm-host` (publishing as
`Mavergreen/vm-host`) back-ports Hypervisor.framework to 10.9, and
is expected to ship a prepackaged QEMU alongside it, so that modern QEMU
gets hardware acceleration *on* Mavericks. When it ships, this host
becomes available: **Mavericks hosting Mavericks.**

Both halves are needed for this host, not just HVF — running the
host-side tool here requires a QEMU on 10.9 to run it with. See
`decisions/0007`.

It is the strongest host on this page, for a reason none of the others
can match. Every other host varies one thing — the CPU, the distribution,
the accelerator. This one varies the *era*: a 2013 operating system
running the host-side tool, with `bash` 3.2, Apple's own `hdiutil` in
place of our Linux HFS+ path, and `privops`' `macos-native` backend
instead of the QEMU microVM. A tool that runs there runs anywhere.

| Ledger | Claim | What this host tests |
|---|---|---|
| **G1** | The host-side tool needs a modern shell | Falsified by construction if it runs here. 10.9 ships `bash` 3.2; see `decisions/0007`. |
| — | `lib/privops.sh`'s backend seam is real | The `macos-native` backend has never been exercised. Here it is the *only* option — no KVM microVM to fall back to. |
| — | `boot/prereqs.sh` names Debian packages | Needs a pkgsrc mapping, or to stop naming packages at all — the same gap the EndeavourOS host exposes, from the opposite direction. |

The dependency points one way: we emit, it runs. Nothing here depends on
`vm-host` existing, and this host stays aspirational until it does.

## Suggested order, if this is ever run

1. **MacBook Air 2015 / EndeavourOS** first. Cheapest useful signal: a
   non-Debian distro breaks the packaging and OVMF-path assumptions
   immediately, and those are shallow, fixable, and certain to be wrong.
2. **Mac Pro 1,1 / OMV** second. Tests the two genuinely interesting
   hypotheses (G14 and the CPU string), and is expected to fail in an
   informative way.
3. **MacBook Air 2017 / Sequoia** when P6 starts, as a macOS build host and
   an `hvf` accelerator test.
4. **NetBSD/nvmm** last, if ever.

## What a triangulation run should produce

Not "it worked" or "it didn't", but **an updated ledger**. Every entry it
touches should end up either confirmed host-specific, demoted to portable,
or corrected. An entry nobody has tried to falsify is not knowledge.

**`bin/triangulate.sh` is the thing to run**, and it produces exactly that:
a report whose last section is markdown rows for `docs/host-profile.md`
section 4, plus `--json` for diffing hosts against each other. It installs
nothing, needs no root, writes only under `$MQG_IMAGE_DIR`, and removes
what it created — the hosts on this page belong to the user, and one of
them is a NAS that is presumably serving something.

Every run, at every level, also writes
`./triangulate-logs-<host>-<stamp>/` in the directory it was started from:
`report.txt`, `report.json`, `pipeline.log`, and any build logs salvaged
from a failed stage. That directory is the thing to send back — the ledger
rows above are in it whether the run succeeded or failed, so nobody has to
copy a terminal by hand. Its path is printed when the run starts, so
`tail -f <dir>/pipeline.log` follows a long `--build` or `--full` from
another machine, and again as the last line, so it cannot scroll past.

The report header names the **commit** and whether the working tree was
**dirty**. Some of these runs are made from a tree shared over NFS rather
than from a clone, where another host's uncommitted edit is picked up
silently and a commit can land mid-run; and a run from a shared tree does
not test the fresh clone `docs/decisions/0006` is about, while looking
exactly like one that does. A result traced to no particular code is worth
much less than one that is.

    ./bin/triangulate.sh                     # ~2 min, builds nothing
    ./bin/triangulate.sh --build             # ~10 min, no install
    ./bin/triangulate.sh --full --json-out h.json

The order above still stands: run `--probe` on everything, and spend
`--full` on the two hosts that look promising.

## Other hypervisors as targets

Raised by the user: "Besides qemu and VBox, how else do people like to run
full VM guests these days? Would be great to be able to cook for any of
those targets."

The useful split is **QEMU-family or not**, because it decides how much of
this project ports.

### QEMU underneath — the whole stack ports

OpenCore, OVMF, the device model and the profiles all apply; only the
configuration format differs.

| Target | Notes |
|---|---|
| **Proxmox VE** | The homelab default. Already in our prior art via `proxmox-mac-guest`. Our QEMU arguments map nearly line-for-line onto a Proxmox VM config. |
| **libvirt / virt-manager** | The Linux standard. The design says not to *depend* on libvirt, and that stands — but *emitting* a domain XML is a different thing entirely, and costs nothing at runtime. |
| **UTM** | macOS/iOS QEMU front-end. Closes a loop: our reference configuration *came from* a UTM bundle, so emitting a `.utm` is mostly writing a plist whose shape `docs/utm-bundle-config.md` already documents. |

### Not QEMU — only the disk ports

Each brings its own EFI and SMC emulation, so our entire boot stack is
bypassed and the macOS disk is the only artifact that crosses.

| Target | Notes |
|---|---|
| **VMware Fusion / Workstation** | Free for personal use now, real macOS guest support on Apple hardware. Already required for the user's `Mavergreen/container-tools` goal — see `decisions/0005`. |
| **VirtualBox** | Prior art exists: the perf brief's `VMQemuVGA` and `virtio-net-osx` measurements were taken under it. |
| **Parallels** | macOS host only, commercial. |

### Build tooling worth knowing

- **Packer** builds images for many of these from one template — and
  `timsutton/osx-vm-templates`, already in our prior art for its first-boot
  payload, *is* a Packer template.
- **Vagrant** still wraps VirtualBox, libvirt and VMware.

### Why this is cheaper than it sounds

**The profiles are already a canonical, parameterised description of a
machine.** Emitting libvirt XML, a Proxmox config or a `.utm` bundle from
the same source is a format-mapping exercise, not a re-derivation. The
non-QEMU family is genuinely different work, because there you swap our boot
stack for theirs and carry only the disk.

Which also sharpens the VirtualBox test: its value is proving **the macOS
disk is a portable artifact, independent of our boot machinery.** That is the
same question VMware and Parallels ask, so answering it once answers it for
the whole non-QEMU family.

### When

After P4. "Emit config for target X" is much cheaper once one command
produces the image, and pointless before then.

### Vagrant — the consumption layer, not another hypervisor

Raised by the user. Everything above is a way to *run* a VM; Vagrant is how
people *obtain and start* one, which is what makes interop concrete: "can
someone else run this?" becomes `vagrant up`.

It also closes a loop. **`timsutton/osx-vm-templates` — this project's prior
art twice over — exists to produce Vagrant boxes.** Packer builds, Vagrant
consumes. The chain it implies is the one P4 is most of the way along.

Its providers split the same QEMU-family way as everything else here:

| Provider | Our stack |
|---|---|
| `vagrant-libvirt`, `vagrant-qemu` | QEMU underneath — boot stack and all ports |
| `virtualbox` (default), `vmware_desktop`, `parallels` | only the disk crosses |

A box is a modest artifact: a tar of `metadata.json`, a `Vagrantfile`, and
the disk image. Once P4 emits a qcow2 with a known configuration, a
`vagrant-libvirt` box is closer to repackaging than to new work.

**One constraint that shapes the whole idea:** boxes are normally *shared*,
and ours never can be. Apple's licence and this project's own "never publish
the guest image" rule mean any box stays local. That rules out Vagrant Cloud
and means the box must be produced and consumed on the same trusted machine
— which is a different workflow from how Vagrant is usually taught.

### Containerised QEMU — a second consumption layer, with the same constraint

Raised by the coordinator. `dockur/macos` and `sickcodes/Docker-OSX` are the
same idea as Vagrant one layer down: QEMU inside a container, with
`/dev/kvm` passed through, so "can someone else run this?" becomes
`docker run`.

They are **QEMU underneath**, so the whole boot stack and every profile
argument carry across unchanged. The work would be a Dockerfile and an
entrypoint that expands a profile, not a re-derivation of anything.

The interesting part is what they do about the OS, because it is the same
line this project has already drawn. Both fetch Apple's installer **at
runtime, inside the container**, rather than baking it into a published
layer — `dockur/macos` downloads from Apple's servers on first start, much
as `media/fetch-installesd.sh` does. That is not a coincidence of design: a
published layer containing macOS is exactly what neither they nor we may
ship. So a container image built here would carry the machinery and fetch
the OS on the user's own machine, and the guest image would still never
leave it.

**A P7 interop emitter, not core path.** Worth recording now because it is
the second thing after Vagrant that consumes what P4 produces, and because
it independently confirms the never-publish constraint is the normal way
this is done rather than a restriction peculiar to us.

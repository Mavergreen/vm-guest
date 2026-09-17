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
| **G14** | SMBIOS must not be `MacPro5,1`, because `AppleTyMCEDriver` panics on a non-Xeon CPU | This *is* a Xeon. If `MacPro5,1` works here, G14 is confirmed host-specific. **If it panics anyway, my explanation of P1's panic was wrong** and the real cause is something else. |
| **G3** | The guest CPU model must be masked down from the host's | Inverts the problem: this host is *older* than the model we ask for. |
| **G2** | Intel with VT-x | Worth confirming VT-x is present and enabled; some early Mac Pros shipped without it. |

**The CPU string is expected to fail here, and that is the point.** The guest
asks for `Penryn,+ssse3,+sse4.1,+sse4.2`. Mac Pro 1,1 is Woodcrest — 65 nm
Core, 2006 — and **SSE4.1 arrived with Penryn in 2007**. A Woodcrest host
cannot provide it, so `-cpu Penryn,+sse4.1` should be rejected outright. Our
CPU choice only looks portable because every test so far ran on hardware
newer than it. *(Reasoned from CPU generations, not yet measured.)*

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
| **VMware Fusion / Workstation** | Free for personal use now, real macOS guest support on Apple hardware. Already required for the user's `ModernMavericks/container-tools` goal — see `decisions/0005`. |
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

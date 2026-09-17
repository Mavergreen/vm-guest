# 0005 — Nested virtualization, and portability across hosts

Date: 2026-09-17
Status: recorded as future requirements, not yet scheduled

Two requirements the user raised after P2. Neither is being built now; both
change decisions that are being made now, which is why they are written down
rather than remembered.

## 1. Nested virtualization

The user wants to test **ModernMavericks/container-tools**, which provides
Docker tooling on top of **VMware Fusion**. That makes the Mavericks guest a
hypervisor host: VMware Fusion inside our QEMU guest, with containers inside
that.

### What is already true

- **The host supports it.** `/sys/module/kvm_intel/parameters/nested` reads
  `Y` on this machine, with no configuration needed from us.
- **QEMU can expose it.** No base CPU model advertises `vmx` — `Penryn`,
  `Nehalem`, `Westmere` and `Haswell-noTSX` all report `vmx=False` — so it
  must be requested explicitly. `-cpu Penryn,+vmx` is accepted by QEMU under
  `-enable-kvm`.

### The tension this creates with P5

The guest currently runs `-cpu Penryn,+ssse3,+sse4.1,+sse4.2`, chosen because
it is what the only verified 10.9-on-QEMU configuration used.

**Penryn (2008) predates EPT.** Extended Page Tables arrived with Nehalem,
and VMware's hypervisor generally wants EPT for 64-bit guests. So supporting
Fusion may force a CPU model newer than Penryn — precisely the axis P5 was
already going to experiment along, but now with a hard requirement attached
rather than only a performance motive.

**This is unverified.** Whether Fusion 6/7-era builds on 10.9 actually
require EPT, and whether they refuse to run when they detect being
virtualized, are both open questions. VMware has historically detected
nested execution and behaved differently.

### What to do about it now

- **P5's CPU-model experiments should include `+vmx` variants**, and should
  record whether each candidate model boots 10.9 *and* satisfies Fusion —
  not just which is fastest.
- Do not lock the CPU model in P3 or P4 as though Penryn were settled.
- Before investing in it, establish the cheap fact first: does VMware Fusion
  of the right vintage even install and start on 10.9 under KVM with `+vmx`?
  That is one experiment on a clone, and it decides whether the rest matters.

## 2. Portability across hosts

The user wants to test on **different host machines**, to triangulate which
settings are genuinely portable rather than accidents of this one. Possibly
including **NetBSD with nvmm** as a host, described as a "later later later"
goal.

### Why this is already accounted for

This is exactly what `docs/host-profile.md`'s generalization ledger exists
for. It currently carries sixteen entries (G1–G16) recording every
host-specific assumption, and P1 already produced a useful split:

- **Portable:** 10.9 cannot drive QEMU's XHCI controller, so EHCI plus UHCI
  companions are needed. That is a guest-OS limitation and is true anywhere.
- **Host-specific:** the SMBIOS masking to `iMac14,2` exists because this
  host is not a Xeon. On a Xeon host `MacPro5,1` might work and the masking
  might be unnecessary.

A second host is the only way to tell those apart reliably. **Keep the ledger
honest** — every entry added now is a hypothesis a second host will test.

### What nvmm would mean

NetBSD's nvmm is a different accelerator, not KVM. QEMU supports it via
`-accel nvmm`. The parts of this project that would survive: the profile
system, the golden/clone machinery, the media build, the OpenCore
configuration. The parts that would not: `-enable-kvm`, `kvm.ignore_msrs`,
the `ich9` chipset assumptions possibly, and anything in the ledger marked
host-specific.

Worth noting that the accelerator is already a parameter in the design — P6
runs the same image pipeline under TCG — so a third accelerator is a smaller
change than it sounds.

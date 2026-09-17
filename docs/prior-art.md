# Prior art

Absorbed from the four source briefs. **Study these before inventing
anything.** If a source can't be fetched, say so in `NOTES.md` — never guess
at its contents.

Sections marked **(unverified)** record a belief from the briefs that nobody
has confirmed in this project. Confirm or refute them as you go, and edit the
marking.

## Bring-up: installing and booting 10.9 under QEMU

### Adam Kostarelas, March 2026 — primary reference
<https://adam.kostarelas.com/blog/mavericks-in-utm-on-silicon/>

The most recent *verified* 10.9 install on QEMU: through UTM on Apple Silicon,
so TCG rather than KVM. Uses OVMF plus OpenCore, with `get.sh`'s dmg as the
installer media. He converted it with `hdiutil convert -format UDTO` and booted
the raw image directly — so the target artifact is known to work.

His UTM bundle, `Mavericks-OSX-10.9-Config.utm.zip`, is linked from that page
and contains the firmware and OpenCore images that worked. A `.utm` is a
directory containing `config.plist` plus images.

**Nobody has inspected this bundle for this project.** P1 must parse its
`config.plist` and record here: architecture, machine type, CPU model and
flags, extra QEMU arguments, memory, core count, every drive with interface
and image type, NIC model, and display device.

Other findings of his: 8 GB assigned but ~2.9 GB used at idle, so 4 GB is a
reasonable starting point. Graphics very slow — about 3 MB of VRAM, with
Chess, Launchpad, and video as slideshows, and UTM unable to pass a parameter
to fix it. DNS needed pointing at 1.1.1.1. He recommends Apple's 2016 security
update and Mavericks Forever's optional post-install hardening script. He found
the modern web mostly broken in stock Safari, a TLS-era limitation.

His OVMF is about five years old: it "just worked," and a current build was
untested. **(unverified)** whether a current OVMF works.

### Mykola Grymalyuk (khronokernel), 2021 — the guide Kostarelas followed
<https://khronokernel.com/apple/silicon/2021/01/17/QEMU-AS.html>

UTM settings, CPU flags, troubleshooting. Prebuilt OpenCore images live in
`khronokernel/khronokernel.github.io` under `Binaries/OpenCore/`;
`EFI-LEGACY.img` covers 10.6–10.14. **Tier 2** — reference only.

His CPU string: `Penryn,+ssse3,+sse4.1,+sse4.2,+popcnt,+xsave,+xsaveopt,check`
plus `vendor=GenuineIntel`.

He attached EFI, installer, and target disks all over USB — worth trying if
AHCI disks don't appear in the OpenCore picker. He used vmxnet3 in UTM. If the
mouse is dead under OpenCore he suggests Ctrl+Option+arrows. His settings list
has **no applesmc device**, which suggests his OpenCore image emulates the SMC
itself — check the bundle and the OpenCore config before adding one, and
record which you rely on.

Timing under TCG on an M1: 17 minutes to macOS recovery, 8 minutes with
`-accel tcg,thread=multi`, with a warning that multicore can cause bugs.

For DNS in the installer environment, his `scutil` recipe: `d.init`,
`d.add ServerAddresses * ...`, then
`set State:/Network/Service/PRIMARY_SERVICE_ID/DNS`.

**Forbidden:** his `Catalina-SETUP.qcow2` and any other prebuilt macOS disk
image.

### Gabriel Somlo, CMU
<https://www.contrib.andrew.cmu.edu/~somlo/OSXKVM/>

Chameleon plus SeaBIOS on KVM, explicitly covering 10.9. His CPU string is
`core2duo,vendor=GenuineIntel`; input via `-usb -device usb-kbd -device
usb-mouse`. Boot via `-kernel <chameleon boot file>` plus `-smbios type=2`.

**The Chameleon binary he links may be gone.** If so, report it; don't
substitute a random build.

Two findings that bind on us regardless of boot path: **10.9's first boot
after install fails without SMP**, and `ignore_msrs` is required. He also
confirmed `pmj/virtio-net-osx` working on 10.9.

Retained only as a fallback if OpenCore proves unworkable under KVM.

### royalgraphx/DarwinKVM
OpenCore Mavericks guide under `installguides/11-Mavericks/`. Specifies
`e1000-82545em` as the NIC for 10.9. Also the first place to read for
GPU/passthrough documentation. **`docs.darwinkvm.com` serves a parked page —
read the source in the repo instead.**

### kholia/OSX-KVM
For `OpenCore-Boot-macOS.sh`, the OpenCore image tooling, and the
`isa-applesmc` OSK value. Its CPU choice is `Haswell-noTSX` plus `+invtsc`.

**Do not use its `fetch-macOS` script** — it doesn't offer 10.9.

### thenickdude/KVM-Opencore
OpenCore config details.

## Installer media

### Mavericks Forever `get.sh`
<https://mavericksforever.com/get.sh>

Authenticates to `osrecovery.apple.com`, downloads `InstallESD.dmg` over HTTP,
and verifies its SHA-256. **It will not run on Linux as-is:** it requires
`hdiutil` and exits without it, and the assembly half — merging `Packages` into
`BaseSystem` — is macOS-only.

The download portion, through the checksum verification, needs only `curl`,
`openssl`, and `xxd`, and can be lifted into a Linux script. It stops before
the first `hdiutil`.

It removes `System/Installation/Packages` before copying, which suggests that
path is a link into the ESD volume. **(unverified)** — a hypothesis worth
testing, because if true the installer may find its packages with the two
images simply attached unmerged.

Its finished partition is about 6.6 GB, GPT with an AF00 partition.

### eprigorodov/mkosxinstallusb
<https://github.com/eprigorodov/mkosxinstallusb>

Does `get.sh`'s merge with Linux tools: `dmg2img` plus `kpartx`/`losetup -P`
to mount InstallESD then BaseSystem; `mkfs.hfsplus -v "OS X Base System"`;
`rsync -aAEHW` BaseSystem across; remove `System/Installation/Packages`, then
copy in the ESD's `Packages`, `BaseSystem.chunklist`, and `BaseSystem.dmg`.

It writes to a `/dev/sdX`; we retarget it to a loop device over a raw image.

**Its README says Korean localization can be dropped.** Whether
HFS+-compressed files in BaseSystem survive the copy is **(unverified)**.
This is why a Mac-produced reference image exists to diff against.

### Rejected installer sources
- **OpenCore's `macrecovery.py`** (10.9 invocation `-b Mac-F60DEB81FF30ACF6
  -m 00000000000FNN100`) fetches only a recovery image, which needs internet
  inside the guest. Not offline media. **(unverified)** whether Mavericks
  online reinstall still works against Apple's servers at all.
- **gibMacOS** — catalogs don't reach 10.9. Beware lookalike sites;
  `corpnewt/gibMacOS` on GitHub is the only real one.

### timsutton/osx-vm-templates
First-boot automation payload: user creation, SSH, skipping Setup Assistant.
The basis for P4's payload.

## Performance

- **pmj/virtio-net-osx 0.9.4** — <https://github.com/pmj/virtio-net-osx>.
  README reports 10.7–10.9 working under QEMU/KVM; in VirtualBox it measured
  about 2× faster TCP sending and 4× faster receiving than the emulated Intel
  NIC. Somlo confirmed it on 10.9.
- **ivanagui2/VMQemuVGA** — <https://github.com/ivanagui2/VMQemuVGA>. Release
  notes claim 10.6 through 10.10. They mention only VirtualBox, despite the
  name.
- **VMsvga2** — <https://sourceforge.net/projects/vmsvga2/>. Covers 10.5+,
  abandoned in 2014 in favour of VMware's own driver.
  **QiuMike/VMsvga2ForQEMU** — <https://github.com/QiuMike/VMsvga2ForQEMU> —
  adapted it to Catalina on QEMU/KVM, showing it can work against QEMU's
  device, though far newer than 10.9.
- **Stock QEMU `vmware-svga`** implements VMware's display device minimally:
  most 2D acceleration commands missing, no 3D — per the README of
  **qemus/qemu-vmvga** (<https://github.com/qemus/qemu-vmvga>), which adds 3D
  through DXVK/Vulkan but targets Windows guests and needs
  `enable_vmware_backdoor=Y` under KVM.
- **Docker-OSX issue #867** (2025) asks for VMware's graphics driver plus
  `vmware-svga` with more VRAM; unresolved. Nobody has this working off the
  shelf.
- **steelbrain/reims-vgpu** does **not** apply — it needs macOS 11+ guests with
  Metal. Its per-guest golden snapshots with throwaway clones are the pattern
  we adopt, though.
- **adespoton/utmconfigs** — the analogous UTM config collection for other
  macOS versions; relevant to generalization.

## Guest integration (P7, deferred)

- **pmj/QemuUSBTablet-OSX** — <https://github.com/pmj/QemuUSBTablet-OSX>. A
  driver letting OS X guests use QEMU's `usb-tablet` absolute pointing device.
- **pmj/virtio-net-osx** — its README says other virtio device types would
  attach to the same `VirtioPCIDriver`. A 2018 commit, "Part 1 of driver for
  standardised PCI Virtio devices," adds virtio capability detection and
  MSI/MSI-X interrupt enumeration, and pulls in kextgizmos.
- **pmj/kextgizmos** — <https://github.com/pmj/kextgizmos>. Helpers for kext
  development.
- **QEMU's built-in SPICE agent host side** —
  <https://www.kraxel.org/blog/2021/05/qemu-cut-paste/>. QEMU 6.1+ implements
  the SPICE agent protocol as a chardev wired to QEMU's own clipboard, so
  copy/paste works without a SPICE client:
  `-chardev qemu-vdagent,id=vdagent -device
  virtserialport,chardev=vdagent,name=com.redhat.spice.0`.
- **utmapp/vd_agent** — <https://github.com/utmapp/vd_agent>. A macOS SPICE
  guest agent, clipboard only. Its build assumes Apple Silicon with Homebrew
  GLib in both architectures, so expect porting work for 10.9.
- **proxmox-mac-guest** — <https://github.com/proxmox-mac-guest/spice-vdagent>.
  Its `mac-guest-agent` (find the repo from there) is a QEMU guest agent for
  macOS running over an ISA serial port; its `spice-vdagent` uses a separate
  virtio serial port.
- **litecreator/virtio-gpu-macos** —
  <https://github.com/litecreator/virtio-gpu-macos>. An alpha `virtio-gpu`
  IOFramebuffer driver targeting 10.15+ ("untested on older versions"). Basic
  framebuffer works; cursor support partial.
- **QEMU source** — `hw/display/vmware_vga.c` for which VMware display
  commands QEMU actually implements, especially cursor ones;
  `hw/display/virtio-gpu*.c`; `ui/vdagent.c`; `qga/`.

Ground rules that apply when this phase is taken up: build kernel code on 10.9
with a period-appropriate Xcode and SDK, recording exact versions; test only on
throwaway clones; debug through QEMU's gdb stub (`-s`) with Apple's Kernel
Debug Kit for the exact 10.9.x build; never promote a kext to a golden image
without an unload/reload test and a soak test. Prefer contributing fixes
upstream over permanent forks.

## GitHub Actions

- **vmactions/anyvm** — the workflow shape to copy: boot, sync files in, run
  over SSH, sync back.
- **QEMU docs** — snapshots, TCG, qcow2 backing files.

Constraints from the GHA brief, all **(unverified)** and to be confirmed on a
real runner: arm64 macOS standard runners (`macos-14`, `macos-15`,
`macos-latest`, `macos-26`) give 3 M1 cores, 7 GB RAM, 14 GB SSD; jobs are
capped at 6 hours; `actions/cache` evicts entries not accessed in 7 days with
a default 10 GB per-repo quota.

Why arm64: Apple's license permits macOS VMs only on Apple hardware running
macOS, GitHub has said x86_64 macOS support ends in 2027, and arm64 has no x86
hardware virtualization — hence TCG.

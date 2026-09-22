# Prior art

> **Prior art has a date.** These sources are mostly 2016–2021. Two of their
> claims have already been disproven by testing here, both because the
> underlying problem was fixed upstream in the meantime:
>
> - *"OS X cannot use QEMU's `usb-tablet`"* — fixed in QEMU in **2017**, by
>   the very author whose workaround kext the briefs cite as evidence.
> - *"DNS needs pointing at 1.1.1.1"* — not needed; DNS worked untouched.
>
> So treat every "X does not work" below as **a claim with an expiry date**,
> not a constraint. Re-test before building around it. The failure mode is
> subtle: the prior art *fits the symptom*, which is exactly what makes a
> wrong diagnosis convincing.
>
> Claims from this era still awaiting re-test: that 10.9's first boot needs
> SMP (Somlo), that there is no virtio block driver for 10.9, that a current
> OVMF will not work, and that `vmxnet3`/`e1000` are the viable NICs.

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

**It also automates the whole install, and this entry used to hide that.**
`prepare_iso/prepare_iso.sh` plus `prepare_iso/support/` are where P4 Task 5's
mechanism comes from: `/etc/rc.cdrom.local`, `minstallconfig.xml` and
`OSInstall.collection`, all read by Apple's own `/etc/rc.install` inside the
installer environment. The `minstallconfig.xml` schema is upstream's, which
took it from **Greg Neagle's `createOSXInstallPkg`** (munki). P4 Task 5 was
planned as a LaunchDaemon injection before anyone read past the first line of
this entry — see the P4 Task 5 entry in `NOTES.md`.

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
  **NOT needed for this setup — correction, 2026-09-17.** An earlier note here
  claimed the opposite. `usb-tablet` works natively on 10.9 given an EHCI
  controller; the cursor-pinned-at-top-left failure that prompted the claim
  was caused by `qemu-xhci`, which 10.9 cannot drive at all. Verified by
  control experiment: a clone of golden #1 that never had the kext installed
  tracks the host pointer correctly.
  **Why it existed, and why it no longer does.** The kext is a guest-side
  workaround for a *QEMU* bug, and its own author fixed that bug upstream
  five months after writing it. Phil Dennis-Jordan's QEMU commit
  `0cd089e937f2`, 2017-01-25, "hw/usb/dev-hid: Improve guest compatibility of
  usb-tablet":

  > The boot protocol of 0x02 specifically confused OS X/macOS' HID driver
  > stack, causing it to generate additional bogus HID events with relative
  > motion in addition to the tablet's absolute coordinate events.
  >
  > Absolute pointing devices with HID Report Descriptor usage of 0x01
  > (pointing) are treated by the macOS HID driver as analog sticks, and
  > absolute coordinates are not directly translated to absolute mouse cursor
  > positions. Changing it to 0x02 (mouse) fixes the problem […] (VMWare does
  > the same thing.)

  So `bInterfaceProtocol` went to 0x00 and the report-descriptor usage to
  0x02. Any QEMU from 2.9 onward has this; ours is 8.2.2. The kext's build
  artefacts are dated September 2016 — five months *before* the fix.

  Kept here as history, not as a dependency. **Nothing in this project uses
  it, and a future reader should not re-add it.**
  - Covers 10.8 through 10.11+, with separate kexts per era. **LGPL**, with
    commercial licensing from the author.
  - The author's binaries are **code-signed**, so 10.9 accepts them without
    the unsigned-kext question this project has otherwise left unverified.
  - Building from source needs **Xcode 6.4 and the 10.9 SDK exactly**. The
    README warns that a binary built against the 10.10 SDK will not load on
    10.9.
  - **Distribution is a problem.** There are no GitHub releases; the README
    points at <http://philjordan.eu/osx-virt/>, which on 2026-09-17 refused
    connections on both HTTP and HTTPS (DNS resolves to 144.76.63.178). The
    Internet Archive was simultaneously showing "temporarily offline", so the
    archived copy could not be checked either. **Retry both before concluding
    the binary is unobtainable.**
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

---

# Dated archaeology: where `kvm.ignore_msrs` actually came from

Researched 2026-09-21, after G21 was refuted on two hosts. The entry had sat
in `docs/host-profile.md` §3 since 2026-09-17 citing "Somlo and OSX-KVM" as
its authority, and **nobody had ever read what those two sources actually
say.** They do not say what this project believed they said.

Sources were reached through `web.archive.org` replays (Somlo's host
`contrib.andrew.cmu.edu` **no longer resolves in DNS**, checked 2026-09-21),
`marc.info` (mailing lists — `lore.kernel.org` is behind an anti-bot
challenge and was unreachable), and git clones. The Wayback CDX API was
returning 504 all session, so the snapshot inventory below is from
year-targeted replays rather than a complete capture list.

## 1. Somlo never claimed `ignore_msrs` fixes anything on 10.9

**He named one MSR, one guest OS, and an expiry date.** From the revision of
his page last updated **2015-05-04** (snapshot
`web.archive.org/web/20150602182549/`), verbatim:

> "NEW: As of Yosemite (OS X 10.10), we need to tell KVM to ignore unhandled
> MSR accesses (During boot, Yosemite attempts to read from **MSR 0x199**,
> which is related to CPU frequency scaling, and is clearly not applicable to
> a VM guest)"

The instruction is **absent** from the 2015-02-26 snapshot (page last updated
2014-09-02) and present in the next revision, so it was added between
**2014-09-02 and 2015-05-04**.

By the revision last updated **2016-09-05** he had already scoped it to dead
kernels:

> "As of Yosemite (OS X 10.10), **on kernels older than 4.7**, we need to tell
> KVM to ignore unhandled MSR accesses …"

And from the **2017-05-30** revision onward the page requires "Linux kernel
≥ 4.7" and **drops the `ignore_msrs` instruction entirely.**

`MSR 0x199` is `IA32_PERF_CTL`. His own dmesg, quoted on kvm@vger
**2016-05-26** inside Radim Krčmář's reply
(<https://marc.info/?l=kvm&m=146436257129374&w=2>):

> "After setting /sys/module/kvm/parameters/ignore_msrs, all I get in dmesg
> after firing up OS X is: `vcpu0 ignored rdmsr: 0x199`"

**Three things follow, and all three bind on us:**

1. **The guest was 10.10, not 10.9.** No dated source found ties
   `ignore_msrs` to Mavericks or earlier. Our guest is 10.9.5.
2. **The symptom was not a panic.** Krčmář's patch posting, **2016-05-27**,
   describes the real mechanism: "KVM's vCPU model behaves exactly as a real
   CPU in this case by injecting a fault when MSR_IA32_PERF_CTL is called
   (which KVM does not support). However, some operating systems use this
   register during an early boot stage in which their kernel is not capable
   of handling #GP correctly, causing #DP and finally a triple fault
   effectively resetting the vCPU." That triple-fault vCPU reset is the
   "bootloop" every downstream guide cites. It is not a kernel panic and it
   does not look like one.
3. **It was fixed upstream in Linux 4.7** (released 2016-07-24), by Dmitry
   Bilunov's dummy `MSR_IA32_PERF_CTL` handler. Our kernel is 7.2.6. **The
   claim expired nine years and roughly thirty kernel releases before this
   project asked the user to `sudo` for it.**

### What Somlo's era actually was

| Page revision | QEMU | Host kernel / distro | Guest `-cpu` | SMBIOS |
|---|---|---|---|---|
| 2013-01-22 | kvm-kmod on 3.6+ | Fedora 16+ | `core2duo` | SeaBIOS patches |
| 2014-05-16 | not pinned | Fedora 20, 3.13.6 | `core2duo -machine q35` | `-smbios type=2` |
| 2015-05-04 | **2.1.0+** | Fedora 20, **3.15.3** | `core2duo` | `-smbios type=2` |
| 2016-03-21 | 2.1.0+ | Fedora 20, 3.15.3 | `core2duo,vendor=GenuineIntel` | `-smbios type=2` |
| 2017-05-30 | **2.6.0+** | **≥ 4.7**, Fedora 24 | **`Penryn -smp 4,cores=2`** | **none** |
| FINAL UPDATE 2018-10-21 | 2.6.0+ | ≥ 4.7, Fedora 26 | `Penryn -smp 4,cores=2` | none |

His **host CPU model is never stated anywhere.** He says only that he has run
"on a genuine Mac computer … exclusively since cca. 2006", and his
instructions show `kvm_intel`. Earliest page snapshot 2013-02-24; content
froze at the 2018-10-21 FINAL UPDATE, in which he says he no longer has the
cycles.

**`-cpu Penryn` is dated and attributed on his page: "Thanks Jim Burns for the
Penryn hint, which is needed instead of core2duo *as of Sierra*."** Sierra is
10.12. Our Penryn line does not come from him and is not justified by him.

## 2. The `MacPro5,1` hypothesis is refuted — Somlo used no product name at all

The live guess was that Somlo and OSX-KVM needed `ignore_msrs` because they
ran `MacPro5,1`, which would have explained why they needed a knob we do not.
**It is wrong, in both directions.**

- **Somlo:** from 2014 to 2016 his only SMBIOS argument is the bare
  `-smbios type=2` — no product name, no manufacturer. His page explains why
  it is there at all: a "Type 2 (Baseboard) entry, required for booting
  [Mountain]Lion". From 2017 onward `-smbios` disappears from his command
  lines entirely. The one full SMBIOS string he ever wrote, on qemu-devel
  **2017-04-04**, is `-smbios type=1,manufacturer='Apple Inc.',product='iMac2'`
  — and that was to coax the **Linux** `applesmc` module into loading in a
  **Linux** guest as a test, not to boot macOS.
- **kholia/OSX-KVM:** `Macmini6,2` (2017-10-01 through 2020-03-18), then
  `iMacPro1,1` (**2020-03-19**, commit `59a9825`), then `iMac19,1`
  (**2026-01-26**, commit `4c378a4`, "Support for macOS Tahoe"). **MacPro5,1
  was never its configured `SystemProductName`** — the string appears only
  inside binary Clover blobs.

So the SMBIOS explanation for why they needed the knob and we do not is dead.
The actual explanation is simpler and is above: **they were on pre-4.7
kernels running 10.10.**

## 3. kholia/OSX-KVM never gave a reason, and still has not

Its public history is squashed (45 commits, oldest 2021-02-13); the
pre-squash history survives in 2020-era forks. In the root commit of the
recoverable history — author date **2016-01-26**, commit date **2017-02-04** —
the README already says, in full:

> "Host machine may need the following tweak for this to work,
> `echo 1 > /sys/module/kvm/parameters/ignore_msrs`"

**That is the entire justification, and it has never been improved.** A GitHub
commit search for `repo:kholia/OSX-KVM ignore_msrs` returns `total_count: 0`
— no commit message in the repo's history has ever mentioned it. Current
master (`4c378a4`, 2026-01-26) still says "KVM **may** need the following
tweak on the host machine to work." Ten years, thirteen files, no reason.

Its `kvm.conf` (present since 2021-02-13) ships
`options kvm ignore_msrs=1 report_ignored_msrs=0`, and
`run-diagnostics.sh` (same date) actively nags the user if the setting is
not applied.

**This is the cargo-cult vector, and it has a name and a date.** Nicholas
Sherlock's widely-copied Proxmox guides use byte-identical wording six years
apart — 2016-10-05 (Sierra, QEMU 2.7.1) and 2022-10-25 (Ventura, Proxmox 7.2)
— saying only "run `echo 1 > /sys/module/kvm/parameters/ignore_msrs` to avoid
a bootloop during macOS boot". No MSR number, no message, no version scope.

## 4. Two maintained projects run macOS on KVM without it

- **foxlet/macOS-Simple-KVM** (2019-04-22 → 2020-07-23, 79 commits, history
  intact and unsquashed): **every blob of every commit** was grepped. Zero
  `ignore_msrs`, zero mention of MSRs at all. Targets QEMU 3.1+.
- **royalgraphx/DarwinKVM** (228 commits, 2023-06-11 → 2026-04-12): zero
  occurrences; `git log --all -S ignore_msrs` across all 228 commits returns
  nothing. It uses OpenCore's `ProvideCurrentCpuInfo=True` instead,
  documented since **2023-06-22**: "On KVM and other hypervisors it provides
  precomputed MSR 35h values to avoid some kernel panics."

**`docs.darwinkvm.com` is still a parked page, re-verified 2026-09-21**
(Cloudflare Registrar parking, HTTP 200, no redirect). Prior content could
not be checked — archive.org was offline all session.

## 5. Upstream KVM's own opinion, dated

Paolo Bonzini, **2024-12-19**, commit titled "KVM: x86: let it be known that
ignore_msrs is a bad idea", condemns precisely the configuration OSX-KVM
ships:

> "Running KVM with `ignore_msrs=1` and `report_ignored_msrs=0` is not a
> supported configuration. Lying to the guest about the existence of MSRs may
> cause the guest operating system to hang or produce errors … the user has no
> clue that the guest is being lied to."

Worth noting against our own host: `report_ignored_msrs` is `Y` here, which is
the *supported* half of that pair and is what made the measurement in
`docs/configuration-register.md` possible at all.

## 6. The lead this turned up for G14, which is not about MSRs

`kholia/OSX-KVM`'s 2026-01-26 commit — the same one that moved the SMBIOS from
`iMacPro1,1` to `iMac19,1` — also ships **`AppleMCEReporterDisabler.kext`**,
with `<key>Comment</key><string>Fix kernel panic MacPro SMBIOS</string>` and
`MinKernel 21.0.0`.

So "a `MacPro*` SMBIOS makes macOS panic in a machine-check driver" is a
**documented, named, community-known phenomenon with a remedy** — and the
remedy is neither `ignore_msrs` nor OpenCore's `Kernel > Block`, which is what
P1 tried and watched do nothing. It is a codeless kext that overrides the
driver's IOKit personality so it never matches in the first place.

`MinKernel 21.0.0` is macOS 12, so that kext is not aimed at 10.9 and nothing
here says it would load or help. **This is a lead, not a finding.** What it
does establish is that G14's observation is not peculiar to this project, and
that the class of fix known to work on the same symptom operates at the
matching layer rather than the MSR layer.

**Note also that DarwinKVM documents `MacPro5,1` as one of its two supported
SMBIOS configurations** (58 references, alongside `MacPro7,1`). Somebody is
running that model under KVM. On which macOS version, with what else set, is
not established here.

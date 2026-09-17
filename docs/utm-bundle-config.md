# Kostarelas's Mavericks UTM bundle: what is actually in it

Source: `Mavericks-OSX-10.9-Config.utm.zip`, linked from
<https://adam.kostarelas.com/blog/mavericks-in-utm-on-silicon/>
sha256 `c7990c86c2dda00b5b88c21dd8d9337552d25f9de0b7ea0bb2e24f2cea5dcab3`,
3,846 KiB, fetched 2026-09-17.

The umbrella design said nobody had inspected this bundle. This is that
inspection. It matters because this configuration is the only *verified*
10.9-on-QEMU install we have, so where it disagrees with the briefs'
guesses, it wins.

## Contents

| File | Size | What it is |
|---|---|---|
| `config.plist` | 3,902 | UTM configuration, `ConfigurationVersion: 2` |
| `Images/OVMF.bin` | 1,966,080 | EDK II firmware — **the CODE half of a 2 MB-class build** |
| `Images/efi_vars.fd` | 540,672 | EFI variable store |
| `Images/EFI-LEGACY.qcow2` | 7,274,496 | OpenCore, qcow2 of a 191 MiB image |
| `Images/disk-0.qcow2` | 589,824 | **Empty** 64 GiB target disk — 56.5 KiB used |
| `OSX10.9.png`, `screenshot.png`, `view.plist` | — | cosmetic |

`disk-0.qcow2` contains no OS. There is no third-party macOS image here, so
nothing in this bundle violates the project's "the OS comes from Apple only"
rule.

## System settings

| Setting | Value |
|---|---|
| Architecture | `x86_64` |
| Target (machine) | `q35` |
| MachineProperties | **`vmport=off`** |
| CPU | `Penryn` |
| CPUFlags | `ssse3`, `sse4.1`, `sse4.2` — **and nothing else** |
| CPUCount | 8, `ForceMulticore: true` |
| Memory | 8192 MB |
| BootUefi | true |
| RngEnabled | true |
| UseHypervisor | false (TCG — he was on Apple Silicon) |
| AddArgs | `-usbdevice keyboard` |

## Devices

| Role | Image | ImageType | InterfaceType |
|---|---|---|---|
| Firmware | `OVMF.bin` | `bios` | `none` |
| EFI vars | `efi_vars.fd` | `none` | (blank) |
| Bootloader | `EFI-LEGACY.qcow2` | `disk` | **`usb`** |
| Target | `disk-0.qcow2` | `disk` | **`ide`** |
| Installer | (none attached) | `cd` | `ide`, removable |

Display `virtio-vga-gl`. Network `usb-net`, mode shared. Sound `intel-hda`,
enabled. `InputLegacy: false`. Clipboard sharing on, `UsbRedirectMax: 3`.

His own notes credit khronokernel for `OVMF.bin` and `EFI-LEGACY.img`, and
adespoton/utmconfigs for the original UTM config. His install route was to
convert `get.sh`'s dmg to an ISO in Disk Utility and attach it to the CD
drive.

## The OpenCore image is khronokernel's, unmodified

The bundle's `EFI-LEGACY.qcow2` and khronokernel's `EFI-LEGACY.img.zip`
differ in 175,340 bytes, which looks alarming until you look at what differs:
macOS Spotlight index churn and eleven OpenCore debug logs dated 2022-02-19,
left behind because the image was mounted on a Mac.

**The `EFI/` tree itself is byte-identical**: sha256 of the sorted per-file
hashes is `829c9cadf7591064aff7fe133e5342ae…` on both sides. Same GPT disk
identifier, same partition layout.

So khronokernel's published image can be used directly. We do not depend on
Kostarelas's copy for anything but convenience.

### What the OpenCore image contains

| File | Size |
|---|---|
| `EFI/BOOT/BOOTx64.efi` | 49,156 |
| `EFI/OC/OpenCore.efi` | 806,912 |
| `EFI/OC/config.plist` | 22,082 |
| `EFI/OC/Drivers/HfsPlusLegacy.efi` | 22,912 |
| `EFI/OC/Drivers/OpenRuntime.efi` | 36,868 |
| `EFI/OC/Drivers/OpenPartitionDxe.efi` | 53,252 |
| `EFI/OC/Kexts/FakeSMC-32.kext` | 52,816 (binary) |
| `EFI/OC/Kexts/Lilu.kext` | 163,760 |
| `EFI/OC/Kexts/VirtualSMC.kext` | 105,088 |
| `EFI/OC/Tools/OpenShell.efi` | 1,208,064 |

OpenCore config highlights:

- **Kernel → Add:** `FakeSMC-32.kext`, `Lilu.kext`, `VirtualSMC.kext`, all enabled.
- **Kernel → Emulate:** `DummyPowerManagement: true`; `Cpuid1Data` and
  `Cpuid1Mask` both **empty** — no CPUID masking in use.
- **Kernel → Quirks on:** `DisableLinkeditJettison`, `PanicNoKextDump`,
  `SetApfsTrimTimeout`.
- **Booter → Quirks on:** `AllowRelocationBlock`, `AvoidRuntimeDefrag`,
  `EnableSafeModeSlide`, `EnableWriteUnprotector`, `ProvideCustomSlide`.
- **UEFI → Drivers:** `HfsPlusLegacy.efi`, `OpenRuntime.efi`, `OpenPartitionDxe.efi`.
- **PlatformInfo → Generic:** `SystemProductName: MacPro5,1`.

## Five findings that change the plan

**1. The SMC comes from injected kexts, not `-device isa-applesmc`.**
This was an explicit open question in the design, raised because
khronokernel's settings list has no applesmc device. Answer: OpenCore injects
`FakeSMC-32.kext` plus `VirtualSMC.kext` and `Lilu.kext`. So P1 needs no
`isa-applesmc` and **no OSK string at all** — `vendor/osk.txt` can be dropped
from Task 12. Record that we depend on the OpenCore image for SMC, because
P3's from-source OpenCore build must do the same thing.

**2. The firmware is a 2 MB-class OVMF and this host ships only 4 MB.**
`OVMF.bin` is 1,966,080 bytes and its strings identify an EDK II Jenkins RPM
build (`edk2-g4c7ce0d285`). Debian's `OVMF_CODE_4M.fd` is 3,653,632. CODE and
VARS must be a matched pair, so the bundle's firmware cannot be mixed with
Debian's. P1 uses the bundle's `OVMF.bin` + `efi_vars.fd` together; P3 finds
out whether a current 4 MB OVMF works at all. Design risk 3 is confirmed real,
not hypothetical.

Note `efi_vars.fd` is 540,672 bytes — exactly the size of Debian's
`OVMF_VARS_4M.fd`. Suggestive but not conclusive; do not assume they are
interchangeable.

**3. The NIC is `usb-net`, not `e1000-82545em`.**
DarwinKVM specifies `e1000-82545em` for 10.9 and the design took that as the
first thing to try. The only configuration known to work uses `usb-net`.
Try `usb-net` first; treat e1000 as the experiment.

**4. The bootloader is attached over USB, the target over IDE.**
Not both on AHCI as the design assumed. khronokernel put everything on USB;
this bundle is a hybrid. Start by copying it exactly.

**5. CPU flags are fewer than expected, and there is no `check`.**
`Penryn` plus exactly `ssse3`, `sse4.1`, `sse4.2` — no `popcnt`, `xsave`,
`xsaveopt`, and no `vendor=GenuineIntel`. khronokernel's longer string from
the briefs is *not* what this bundle uses. Also `vmport=off` in machine
properties, and `-usbdevice keyboard` as an extra argument.

## Still unknown

- **`HfsPlusLegacy.efi`'s provenance.** It is the HFS+ driver this
  configuration depends on. Whether it is Apple-derived (making it Tier 2 and
  unbuildable) or an open implementation decides how much work decision 0002
  actually is. P3 must determine this.
- Whether `UseHypervisor: false` masks any TCG-only behavior that changes
  under KVM.

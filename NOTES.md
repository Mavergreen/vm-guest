# Lab log

Append-only. Newest entries at the bottom. Every command tried, what happened,
any panic text, and what fixed it. **Failures are as valuable as successes** —
a dead end that isn't written down gets walked into twice.

Format per entry: date, phase, what was attempted, the exact command, the
outcome, and the conclusion drawn.

---

## 2026-09-17 — P0 — host probe

Probed the host before designing. Full results in `docs/host-profile.md`.

```
lscpu; ls -l /dev/kvm; id; qemu-system-x86_64 --version
ls /usr/share/OVMF/; cat /etc/os-release; free -g; df -h /home/schmonz
cat /sys/class/dmi/id/{sys_vendor,product_name,board_name}
uname -a; ls /sys/kernel/iommu_groups | wc -l; lspci -nn | grep -iE 'vga|3d|display'
```

Outcome: `Macmini8,1`, i7-8700B (Coffee Lake, 6C/12T), 62 GB RAM, 1.7 TB free,
T2 chip, Mint 22.3 on kernel `7.2.6-1-t2-noble`, VT-x present, `/dev/kvm`
usable by the user via group `kvm`, IOMMU on with 14 groups, QEMU 8.2.2,
OVMF 4M-split only, Intel UHD 630 as the sole display device.

Conclusions:

- The AMD hard-stop does not trigger. Intel with VT-x, KVM usable without
  further permission work.
- The host is Apple hardware, so virtualizing OS X here is licensed.
- No PCIe slots and one iGPU, so GPU passthrough is off the table. Recorded
  as `docs/decisions/0001-no-gpu-passthrough.md`.
- OVMF is 4M split CODE/VARS only, with no combined image. Flagged as a risk
  for P3, since the UTM bundle's firmware is most likely a combined older
  image.
- The `t2` kernel is unusual and worth remembering whenever something behaves
  oddly.

Not yet done: `kvm.ignore_msrs=1`, which needs `sudo` and therefore an ask.

---

## 2026-09-17 — P0 — preconditions

Built `lib/preconditions.sh` (fact-judging verdict functions), `bin/preconditions.sh`
(fact-gathering executable), and `tests/preconditions.bats`. Ran the check
against this host:

```
STATUS  CHECK                     DETAIL
------  -----                     ------
PASS    cpu-vendor                Intel: the documented KVM path
PASS    vmx                       VT-x present
PASS    kvm-device                /dev/kvm is writable by this user
WARN    ignore-msrs               kvm.ignore_msrs is 'N'; required by prior art. Needs sudo: ask before running 'echo 1 | sudo tee /sys/module/kvm/parameters/ignore_msrs'
PASS    ovmf                      4M split CODE/VARS found in /usr/share/OVMF
PASS    tool:qemu-system-x86_64   /usr/bin/qemu-system-x86_64
PASS    tool:qemu-img             /usr/bin/qemu-img
PASS    tool:dmg2img              /usr/bin/dmg2img
PASS    tool:kpartx               /usr/sbin/kpartx
PASS    tool:sgdisk               /usr/sbin/sgdisk
PASS    tool:rsync                /usr/bin/rsync
PASS    tool:xxd                  /usr/bin/xxd
PASS    tool:openssl              /usr/bin/openssl
PASS    tool:curl                 /usr/bin/curl
PASS    tool:unzip                /usr/bin/unzip
PASS    tool:python3              /usr/bin/python3
PASS    tool:mkfs.hfsplus         /usr/sbin/mkfs.hfsplus
PASS    tool:bats                 /usr/bin/bats

mqg: preconditions: GO
```

Conclusion: this host is a GO. Everything passes except `ignore-msrs`, which
warns rather than fails because setting it needs a `sudo` ask that hasn't
happened yet -- not a blocker for further P0/P1 work, but must be done before
first boot.

## 2026-09-17 — P0 — ignore_msrs enabled

The user applied `kvm.ignore_msrs=1` for this boot only:

```
echo 1 | sudo tee /sys/module/kvm/parameters/ignore_msrs
```

`./bin/preconditions.sh` now reports 18/18 PASS and GO, with no warnings.

Deliberately **not** persistent. Prior art (Somlo, OSX-KVM) says macOS reads
MSRs that KVM does not emulate and the guest fails early without this, but
nobody has confirmed that on a T2-patched kernel. Making it survive reboots
before we have seen it matter would be committing to a global KVM setting on
faith. If P1 shows it is genuinely required, make it persistent then and
record why here.

**It resets on reboot.** If a previously-working guest suddenly fails early,
check this first.

## 2026-09-17 — P1 — installer media imported and verified

The user ran Mavericks Forever's `get.sh` unmodified on an Intel Mac
(installer Approach C, the path Kostarelas proved). Apple's SHA-256 check
passed with no errors. They also produced an ISO, because the UTM bundle's
own notes show Kostarelas booted a CD image rather than a raw disk:

```
hdiutil convert InstallMacOSXMavericks.dmg -format UDTO -o InstallMavericks
```

Both files were copied to `~/.local/share/mavericks-qemu-guest/media/`, on
local btrfs rather than the NFS-mounted repo — QEMU reads the installer on
every boot attempt, and the performance phase will boot dozens of times.

| File | Bytes | SHA-256 |
|---|---|---|
| `InstallMavericks.iso` | 6,550,052,864 | `e3d624946082e81812b180551c15a36737d1acf75b09f01b1bf926198e637189` |
| `InstallMacOSXMavericks.dmg` | 5,844,415,233 | `dfcae16050a3bad50344db29b20aa0b20172993f1ef8b15fe6a698debd8c11ef` |

Also written to `media/SHA256SUMS`, so `sha256sum -c` can re-check them.

### The media was verified before booting anything

A finished copy proves nothing, so the ISO was inspected structurally rather
than assumed good:

- **Apple Partition Map**, not GPT or MBR — `fdisk` reads nothing, which is
  expected and not a problem. Three entries: the map itself, a 6.55 GB
  `Apple_HFS` partition named "disk image", and 3 blocks of `Apple_Free`.
- **HFS+ volume header** (`H+`) at byte 33792. Volume is `OS X Base System`.
- **`System/Library/CoreServices/boot.efi`** present, dated 2014-09-09.
- **The merge worked.** `System/Installation/` holds `BaseSystem.chunklist`,
  a 493 MB `BaseSystem.dmg`, and a `Packages` directory — the first two dated
  today, which is `get.sh` having assembled them, against 2014 dates on the
  original Apple files.
- **All 16 packages present**, including `OSInstall.mpkg`, `OSInstall.pkg`,
  `BaseSystemBinaries.pkg`, and the 3.2 GB `Essentials.pkg`.

This matters beyond a sanity check: it is the reference P4's Linux-native
media build gets diffed against. When that build produces something that will
not boot, this is how we tell whether the media or the configuration is at
fault.

### Storage note

The files initially landed in the repo, which is the NFS mount, and were
moved to local disk — 12.4 GB in 1m46s. Copy directly to
`~/.local/share/mavericks-qemu-guest/media/` next time.

## 2026-09-17 — P1 — installer GUI reached under KVM

**P1's exit criterion is met.** The Mavericks installer boots to its language
picker at 1280x720 under `-enable-kvm`. Four failures on the way, each one a
single change, all recorded because the next person needs the dead ends as
much as the destination.

Run it with `./vm/run.sh p1-reference`; it is headless with a monitor socket
at `$MQG_IMAGE_DIR/work/monitor.sock` and VNC on `:5`.

### Failure 1: no USB bus

```
qemu-system-x86_64: -device usb-storage,drive=opencore:
  No 'usb-bus' bus found for device 'usb-storage'
```

q35 provides no USB controller by default. UTM adds one implicitly, which is
why the bundle's `config.plist` never mentions it — a good example of a
setting that is invisible in the reference configuration precisely because
something else supplied it. Added `-device qemu-xhci,id=usb` and put every
USB device explicitly on `bus=usb.0`.

Also found while fixing this: `base-kvm.args` set `-machine q35` and
`p1-reference.args` set `-machine q35,vmport=off`, so the machine type was
specified twice and the last one silently won. `base-kvm` no longer sets
`-machine` at all.

### Failure 2: firmware wired as pflash, stuck at a black screen

The guest sat forever at "Guest has not initialized the display (yet)". I had
wired the bundle's firmware as a pflash CODE/VARS pair:

```
-drive if=pflash,format=raw,unit=0,readonly=on,file=OVMF_CODE.fd
-drive if=pflash,format=raw,unit=1,file=OVMF_VARS.fd
```

That was a misreading. The bundle marks `OVMF.bin` as `ImageType: bios`, which
is UTM for `-bios` — a complete firmware image, not the CODE half of a split
pair. The sizes say the same thing: 1,966,080 and 540,672 sum to no standard
flash geometry. Switching to `-bios` brought the display up immediately.

Consequence: EFI variables are not persisted between runs. That is what the
reference configuration did, and it is fine for an installer boot.

### Failure 3: kernel panic in AppleTyMCEDriver

First boot to reach the kernel. Mavericks itself panicked:

```
panic(cpu 1 caller 0xffffff800096dc43e): Kernel trap at ...
  type 13=general protection
com.apple.driver.AppleTyMCEDriver :
  __ZN16AppleTyMCEDriver47enableInterruptForCorrectableMemoryCoreRegisterEPv
Mac OS version: 13F34
Darwin Kernel Version 13.4.0 ... RELEASE_X86_64
System model name: MacPro5,1 (Mac-F221BEC8)
```

Good news buried in a panic: OVMF booted, OpenCore loaded, and the installer's
own 10.9.5 kernel started. Everything up to the kernel was already working.

`AppleTyMCEDriver` is the Xeon machine-check driver. It loads because
OpenCore's `PlatformInfo` sets SMBIOS to `MacPro5,1`, a Xeon machine, and then
faults on a CPU that is not one. It never fired for Kostarelas because he ran
under TCG on Apple Silicon — this is a genuine KVM-specific divergence from
the reference configuration, and the first thing found that the bundle could
not have told us.

### Failure 4: the shipped fix did not work

khronokernel had already anticipated this. His `config.plist` ships a
`Kernel > Block` entry for `com.apple.driver.AppleTyMCEDriver` — with
`Enabled: false`.

Flipping it to `true` (in a **derived** copy of the image, leaving the Tier 2
original untouched; `mtools` can write into the FAT partition at offset
`2048*512` without root) changed nothing. Same panic, same backtrace. This is
OpenCore 0.6.6 with `Kernel > Scheme > KernelCache: Auto`, so the block should
have applied to the prelinked kernel. Why it did not is **unresolved** — worth
knowing before P3 builds its own OpenCore and inherits the assumption that
`Block` works.

### What fixed it: SMBIOS

Changed `PlatformInfo > Generic > SystemProductName` from `MacPro5,1` to
`iMac14,2` — attacking what the driver *matches on* rather than trying to stop
it loading. The panic disappeared and the installer booted.

**Two changes from the reference are in play at once** (the enabled block and
the SMBIOS change), and only the second is known to matter. P3 should turn the
block back off and confirm SMBIOS alone is sufficient, rather than carrying a
cargo-culted setting forward.

### Boot progress after the fix

```
Creating RAM Disk for /System/Installation
hfs: mounted untitled on device disk6
Apple16X50ACPI1: Identified Serial Port on ACPI Device=COM1
ACPI_SMC_PlatformPlugin::start - waitForService(AppleIntelCPUPowerManagement) timed out
DSMOS has arrived
[IOBluetoothHCIController][start] -- completed
```

`DSMOS has arrived` is the one that matters: "Don't Steal Mac OS X" decrypted,
so the SMC emulation works. That confirms the design's conclusion that
`FakeSMC-32` + `VirtualSMC` + `Lilu` injected by OpenCore replace
`-device isa-applesmc` entirely. No OSK string is needed anywhere in this
project.

The `AppleIntelCPUPowerManagement` timeout is expected and harmless —
OpenCore sets `DummyPowerManagement`.

### Still unknown

- Why `Kernel > Block` had no effect (see Failure 4).
- Whether `iMac14,2` is the best SMBIOS choice or merely the first that
  worked. It is a 2013 Haswell iMac; the guest CPU is advertised as Penryn,
  which is an odd pairing that 10.9 evidently tolerates.
- Whether the e1000 NIC would work as DarwinKVM claims. Still on `usb-net`,
  per the bundle.

## 2026-09-17 — P1 — input: EHCI, not XHCI; usb-mouse, not usb-tablet

Two input failures after reaching the GUI, both mine, both worth recording
because neither is mentioned in any of the prior art.

### usb-tablet does not work on OS X without a third-party kext

I wired `-device usb-tablet` for absolute positioning. The guest drew a cursor
at the top-left and it never moved.

This is documented in our own prior art and I missed it:
**pmj/QemuUSBTablet-OSX exists precisely because OS X cannot drive QEMU's
usb-tablet natively.** Somlo's guide correspondingly specifies
`usb-kbd` + `usb-mouse`. A relative `usb-mouse` needs a pointer grab, which is
less pleasant than absolute positioning — making that tablet kext a concrete,
already-identified win for the deferred integration phase (M0), rather than a
speculative one.

### 10.9 cannot drive QEMU's XHCI controller

After switching to `usb-mouse`, **neither mouse nor keyboard produced any
input at all**. That ruled out the pointing device and implicated the
controller.

`qemu-xhci` is driven perfectly well by OVMF — OpenCore booted from a USB mass
storage device on it, so the firmware half worked throughout, which is exactly
what made this confusing. But once Mavericks takes over, `AppleUSBXHCI` in
10.9 cannot drive it.

Replaced it with the ICH9 EHCI + three UHCI companions, which is the chipset
layout a real Mac of the era has:

```
-device ich9-usb-ehci1,id=usb,bus=pcie.0,addr=0x1d.7,multifunction=on
-device ich9-usb-uhci1,masterbus=usb.0,firstport=0,bus=pcie.0,addr=0x1d.0,multifunction=on
-device ich9-usb-uhci2,masterbus=usb.0,firstport=2,bus=pcie.0,addr=0x1d.1
-device ich9-usb-uhci3,masterbus=usb.0,firstport=4,bus=pcie.0,addr=0x1d.2
```

All three UHCI functions are needed: EHCI only speaks high speed, and
full-speed devices get routed to a companion. `masterbus` ties them into one
logical `usb.0`, so devices still just say `bus=usb.0`.

Confirmed working: pointer moves, `AppleUSBCDCECMData` loads for the `usb-net`
NIC, and `info usb` shows keyboard and mouse at 480 Mb/s with no spurious hub.

**This is a KVM-specific finding the reference configuration could not have
given us.** UTM supplies its own USB controller implicitly, so the bundle's
`config.plist` never mentions one at all — the setting was invisible precisely
because something else was making the choice.

## 2026-09-17 — pulling the tablet driver forward, and a dead upstream

P1 established that `usb-tablet` does nothing on 10.9, so the guest needs a
relative mouse and a pointer grab. The user's call: integrate
`pmj/QemuUSBTablet-OSX` sooner rather than leaving it in the deferred
integration phase, because a better pointer improves the feedback loop for
every phase after it. That is a good trade — the cost is paid once and the
benefit compounds.

Investigated feasibility. The good news is better than expected: it is LGPL,
covers 10.8–10.11, and **the author's binaries are code-signed**, so 10.9
accepts them without the unsigned-kext question this project had flagged as
unverified.

**But both upstreams are down.** <http://philjordan.eu/osx-virt/> refuses
connections on HTTP and HTTPS (DNS resolves fine, to 144.76.63.178), and the
Internet Archive returned "Internet Archive services are temporarily offline"
at the same moment, so the archived copy could not be checked either.

Per the design's stop-and-ask rule, reporting rather than improvising. Options,
in order of cost:

1. **Retry the Archive later.** It says *temporarily* offline. Cheapest path.
2. **Build from source.** Needs Xcode 6.4 and the 10.9 SDK exactly; the README
   warns a 10.10-SDK build will not load on 10.9. The user has suitable Macs,
   but this means obtaining an old Xcode from Apple's developer downloads.
3. Look for the kext redistributed inside another VM project.

Not blocking. P2 finishes without it, and a kext would be installed on a
**clone** in any case — golden #1 stays pristine as the measurement baseline,
and a tablet-equipped image becomes golden #2.

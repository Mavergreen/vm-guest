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

## 2026-09-17 — P2 complete: golden #1 promoted

**P2's exit criteria are met.** Mavericks 10.9.5 installs, reboots cleanly,
shuts down promptly, and golden #1 exists and survives being cloned from.

### The clone premise, tested rather than assumed

Everything after this phase assumes goldens are immutable. That assumption was
tested once, here, while it is still cheap:

1. Promote `p2-manual-install` — mode 0444, SHA-256 recorded, metadata sidecar.
2. `golden.sh verify` — passes.
3. Clone it, boot the clone all the way to a desktop, shut it down.
4. `golden.sh verify` again — **still passes.**

If that had failed, every later phase would have been built on sand.

### Measured, not estimated

| What | Value |
|---|---|
| Install | 14 min (installer estimated 24) |
| Boot to desktop | 39.3 s, measured host-side on a clone |
| Installed size | 8.54 GiB of a 60 GiB virtual disk |
| Golden promotion | 19 s, nearly all of it SHA-256 — the copy is a btrfs reflink |

### Disk usage on local storage

```
golden/            8.6G
work/              8.6G   (the original install; redundant now golden exists)
media/              12G   (ISO + dmg + the tablet driver)
vendor-reference/  398M   (Tier 2 quarantine)
screenshots/       5.6M
```

`work/mavericks.qcow2` is now redundant — golden #1 is its checksummed copy.
Worth deleting once there is confidence in the golden, which would reclaim
8.6 GB.

### A sequencing mistake worth recording

I sent `system_powerdown` to the clone and then deleted its image before ACPI
shutdown had finished, so QEMU was still running against an unlinked inode.
Harmless — the golden verified before and after, and the clone was disposable
by design — but the right order is: shut down, confirm the process exited,
*then* delete. Recorded because the same mistake against a golden rather than
a clone would not be harmless.

### Still open

- **Why OpenCore's `Kernel > Block` had no effect.** The shipped block for
  `AppleTyMCEDriver` was enabled and the panic persisted; changing SMBIOS is
  what fixed it. P3 builds its own OpenCore and must not assume `Block` works.
- **Whether `iMac14,2` is the right SMBIOS** or merely the first that worked.
  It is a Haswell iMac while the guest CPU advertises Penryn, which 10.9
  evidently tolerates.
- **Whether both P1 changes are needed** — the enabled block and the SMBIOS
  change are both in play, and only the second is known to matter.
- **Sound** is absent because `intel-hda` was left out to reduce variables.
- **One resolution only**, and VRAM is not the reason.

## 2026-09-17 — P3 — building OpenCore 1.0.7 from source on Linux

The plan called this the riskiest task in P3. It was not: `build_oc.tool`
worked on this Linux host on the first attempt, with three environment
variables set and no patching. `OpenHfsPlus.efi` built as part of the default
target, so `docs/decisions/0002` stands.

### What worked

```
cd $MQG_BUILD_DIR/OpenCorePkg-1.0.7
ARCHS=X64 TOOLCHAINS=GCC TARGETS=RELEASE ./build_oc.tool
```

Wall clock **3m23s** from a cold tree on 12 cores, including cloning EDK II.
A second run over the warm tree took **20s** and produced byte-identical
artifacts, so the script is re-runnable and does not need a clean tree.

Each of the three variables was chosen, not defaulted:

| Variable | Default | Why ours |
|---|---|---|
| `ARCHS` | `(X64 IA32)` in `build_oc.tool` | The guest is 64-bit. IA32 doubles the build for nothing. |
| `TOOLCHAINS` | `(CLANGPDB GCC)` on Linux, in `efibuild.sh` | Two full builds, and there is no `clang` on this host, so CLANGPDB would have failed outright. |
| `TARGETS` | `(DEBUG RELEASE NOOPT)` | A DEBUG build logs on every boot and is slower. |

The toolchain question the plan flagged answered itself by reading rather than
guessing: `efibuild.sh` picks `('CLANGPDB' 'GCC')` on anything that is not
Darwin or Windows. Not `GCC5` — that is upstream EDK II's name; acidanthera's
`audk` fork calls it `GCC`. Guessing `GCC5` would have failed.

### Toolchain worries that did not materialise

Recorded because each one cost time to rule out and the next person should
not have to:

- **`distutils`.** Python here is 3.12, which dropped it. Current `audk`
  BaseTools does not want it. Nothing failed.
- **`mtoc`.** `efibuild.sh` only demands it on Darwin; on Linux it sets
  `valid_mtoc=true` unconditionally and moves on.
- **`make` is `/home/schmonz/bin/make`,** a `nbpkg make` shim, which looked
  like it might be BSD make. It resolves to GNU Make 4.3. Harmless.
- **Staging gating.** The plan expected `Staging/OpenHfsPlus` to need an
  explicit target. It does not: 1.0.7's `OpenCorePkg.dsc` lists
  `OpenCorePkg/Staging/OpenHfsPlus/OpenHfsPlus.inf` in `[Components]` at line
  352, right beside `AudioDxe` and `EnableGop`. `Staging/` is a source-layout
  convention in this repo, not a build-target gate. **`OpenHfsPlus.efi`
  needed nothing special at all.**
- **`docker`/`podman`.** Absent, and never reached — `build_oc.tool` does not
  touch `docker-compose.yaml` unless you invoke it that way.

### Artifacts

`$MQG_BUILD_DIR/artifacts/`, with `SHA256SUMS` beside them:

```
7b3ce1defa81257d8994961fb838cda765e6a990d7bf9d6773aa94ef9ea63819  OpenCore.efi
eb05c27990e7162011b2ef5229d3e2b8be23a8e0bfd79d77c1891cee175e0094  BOOTx64.efi
d5bece452e5c2180b7f588b40b12c2fe64663548dbbe0de01038c3db45083a5d  OpenRuntime.efi
e0ee5f238725685eff2f423558b933497c5475c257f747aa281e2d88018723ea  OpenPartitionDxe.efi
93f491375fbd4c0541b55d64b8d4e2f01cafde4f66b7f520f943d3351a45040a  OpenHfsPlus.efi
```

All five are PE32+ x86-64: `OpenCore.efi` and `BOOTx64.efi` as EFI
applications, `OpenHfsPlus`/`OpenPartitionDxe` as boot service drivers,
`OpenRuntime` as a runtime driver. That is the right shape for each.

**`BOOTx64.efi` does not exist in the build tree.** Nothing produces a file
by that name; `Bootstrap.efi` is what becomes the fallback boot path. The
plan's collection step searched for `BOOTx64.efi` by name and would have
found nothing, so `boot/build-opencore.sh` carries an explicit
`Bootstrap.efi:BOOTx64.efi` mapping instead of a filename search.

Cross-checked against `build_oc.tool`'s own `package()` output — all five
checksums match the corresponding files inside
`OpenCore-1.0.7-RELEASE.zip` (`EFI/BOOT/BOOTx64.efi`, `EFI/OC/OpenCore.efi`,
`EFI/OC/Drivers/*`), so the rename is the same one upstream performs and we
are shipping exactly what an official Linux build would.

### ocvalidate

Built, but **not** copied into `artifacts/`: it is a host ELF binary, not
firmware, and `artifacts/` is what gets written into the EFI image. It lands
at:

```
$MQG_BUILD_DIR/OpenCorePkg-1.0.7/Utilities/ocvalidate/ocvalidate
```

It announces "only compatible with OpenCore version 1.0.7", which is exactly
the property Task 4 wants — the config is checked against the schema of the
build we shipped, not whatever `ocvalidate` is lying around. The script logs
the path on every run.

### Concern: the build is *not* fully pinned

This matters for P3's exit gate, and it is a gap between what Tier 0 claims
and what actually happens.

`boot/fetch-opencorepkg.sh` pins the OpenCorePkg tarball by SHA-256. But
`build_oc.tool`'s last act is:

```
src=$(curl -LfsS https://raw.githubusercontent.com/acidanthera/ocbuild/master/efibuild.sh) && eval "$src"
```

— an unpinned fetch of a 569-line script from `master`, `eval`ed. That script
then clones **`https://github.com/acidanthera/audk` at `master`, `--depth=1`**
as the EDK II base, and on re-runs `git pull --rebase`es it.

So two of the three inputs float. What this particular build used:

| Input | Pinned? | Value today |
|---|---|---|
| OpenCorePkg 1.0.7 tarball | yes, `vendor/sources.tsv` | see that file |
| `ocbuild/efibuild.sh` | **no**, `master` | sha256 `4ae2461427bf68be18276483b58e7e295bf77b83782b80b817586a2c817cdb30` |
| `acidanthera/audk` | **no**, `master` | `0672a009e9ca85753d240324d761341adf0291b3` (2026-08-12) |

Plus 5 patches from OpenCorePkg's own `Patches/`, applied to `UDK` as commits
on top of that.

Those two values are recorded here so a future rebuild can be compared
against this one. `efibuild.sh` does honour `OFFLINE_MODE=1`, which skips
both the `audk` clone and the `git pull`, so pinning this properly later is a
matter of vendoring `audk` at a chosen commit rather than of patching
upstream. Not done here: it is a change to the provenance machinery, not to
this task, and one variable per experiment.

### What is not yet known

- Whether these binaries actually boot 10.9.5. Nothing has been booted with
  them — that is Task 5 onward, and the golden-#1 comparison is the test.
- The `OpenHfsPlus` vs Apple `HfsPlus` boot-time cost that `0002` asks P3 to
  measure. Still unmeasured; it needs a booting image first.

## 2026-09-17 — P3 — the OpenCore build is now pinned and offline

Closes the "the build is *not* fully pinned" concern from the entry above.
All three inputs are pinned by commit and by SHA-256, `build_oc.tool` no
longer `curl | eval`s anything, and **the build runs with no network at
all**. The five artifacts are byte-identical to the floating build.

### What is pinned, to what

| Input | Pin | Where |
|---|---|---|
| OpenCorePkg | tag `1.0.7` tarball | `opencorepkg-src` (unchanged) |
| `ocbuild/efibuild.sh` | `e9ed49cb7a4f7fa2830c024a13d63de27c2e0d1a` | `ocbuild-efibuild` |
| `acidanthera/audk` | `0672a009e9ca85753d240324d761341adf0291b3` | `audk-src` |
| audk's 12 submodules | the commits audk's gitlinks name | `audk-*` |

`master` of `ocbuild` resolved to `e9ed49cb` and the file at that commit
hashes to `4ae2461427bf68be18276483b58e7e295bf77b83782b80b817586a2c817cdb30`
— the same value the floating build recorded, so nothing moved under us
between the two runs.

`boot/build-opencore.sh` is the single place the commits are written down.
`boot/fetch-edk2.sh` asks it (`--show-pins`) what to download, and the build
refuses a `sources.tsv` URL that names a different commit than it expects,
so the two files cannot quietly disagree.

### How the fetch was removed

`build_oc.tool`'s last act was:

```
src=$(curl -LfsS https://raw.githubusercontent.com/acidanthera/ocbuild/master/efibuild.sh) && eval "$src" || exit 1
```

`boot/patches/0001-build_oc-source-pinned-efibuild.patch` replaces the
`curl` with a `cat "${EFIBUILD_SH}"`, keeping the `eval` exactly as upstream
has it so `efibuild.sh` still runs in `build_oc.tool`'s own shell. The patch
is applied by `boot/build-opencore.sh` at build time, guarded by a grep so a
warm tree is not patched twice, and asserted afterwards. `build_oc.tool` has
no other network call: that one line was the whole of it.

### How offline was proved

```
unshare -rn ./boot/build-opencore.sh
```

`unshare -rn` gives an unprivileged network namespace with nothing but a
down `lo` — verified separately that `curl https://example.com` fails inside
it. Three runs, all exit 0:

- **cold EDK II tree** — unpacked and patched `UDK` from the tarballs
  (2m6s build, 2m27s wall);
- **warm** — re-run over the existing tree (20s), so re-runs do not need
  the network either;
- **everything cold** — `$MQG_BUILD_DIR/OpenCorePkg-1.0.7` and
  `artifacts/` deleted first, then
  `unshare -rn sh -c './boot/fetch-opencorepkg.sh && ./boot/build-opencore.sh'`
  (2m26s wall). The fetch script downloads nothing when the pinned tarball
  is already on disk; it verifies and unpacks. This is the run that also
  proves the patch applies to a pristine `build_oc.tool`.

All three produced the same five checksums as the floating build:

```
7b3ce1defa81257d8994961fb838cda765e6a990d7bf9d6773aa94ef9ea63819  OpenCore.efi
eb05c27990e7162011b2ef5229d3e2b8be23a8e0bfd79d77c1891cee175e0094  BOOTx64.efi
d5bece452e5c2180b7f588b40b12c2fe64663548dbbe0de01038c3db45083a5d  OpenRuntime.efi
e0ee5f238725685eff2f423558b933497c5475c257f747aa281e2d88018723ea  OpenPartitionDxe.efi
93f491375fbd4c0541b55d64b8d4e2f01cafde4f66b7f520f943d3351a45040a  OpenHfsPlus.efi
```

Identical artifacts from identical commits is the result that says the
pinning describes what was actually happening, rather than changing it.

### `efibuild.sh` behaviour worth knowing later

Read it at the pinned commit before changing any of this. Four things are
not obvious and all four cost a build to find out:

- **`OFFLINE_MODE=1` does what the name says, and only that.** It skips the
  `audk` clone and the `git pull --rebase`. It does *not* skip anything else
  — and the submodule checkout and the `DISCARD_SUBMODULES` handling live
  *inside* the function it skips (`updaterepo`), so in offline mode both
  simply never happen. Whatever they would have done, you must do yourself.
- **`UDK.ready` is load-bearing before the build, not just after.** If
  `UDK/UDK.ready` is absent, efibuild's *first* act is `rm -rf UDK`. A
  pre-unpacked tree without that marker is deleted before it is used. We
  touch it (plus `patches.ready` and `submodules.ready`) during assembly.
  It also suppresses a whole-tree `find . -exec file {} ;` CRLF scan.
- **A GitHub archive leaves an empty directory at every submodule path**,
  including audk's own `OpenCorePkg` submodule. efibuild wants to put a
  symlink there pointing at the OpenCorePkg tree being built, but its
  `symlink()` silently does nothing when the target already exists as a
  directory — and then BaseTools fails to compile `ImageTool` because
  `OpenCorePkg/User/Include/UserFile.h` is not found. Upstream avoids this
  by `git rm`-ing the submodule inside the clone step. We `rm -rf` it.
- **`HASH=$(git rev-parse '@{upstream}')` runs unconditionally**, and our
  `UDK` is not a git repository, so every build prints
  `fatal: not a git repository` once. Harmless: `HASH` is only passed as
  `package`'s third argument, which OpenCorePkg's `package()` ignores.

### Why all twelve submodules, not the two that get compiled

Only two are actually built: `openssl` (OpenCorePkg.dsc links
`CryptoPkg/Library/OpensslLib`) and `brotli` (BaseTools' `BrotliCompress`;
audk lists brotli twice, at one commit). But EDK II's `build.py` validates
every `[Includes]` path of every `.dec` it parses, and `MdePkg.dec` names
`Library/MipiSysTLib/mipisyst/library/include`. Missing that directory kills
the build at meta-data processing, two seconds in. Rather than guess which
`.dec` files a future `ARCHS`/`TARGETS` change will drag in, all twelve are
pinned — which is also just what `git submodule update --init` produced.

Two tarball-vs-checkout differences were checked and are harmless, both
caused by `export-ignore` in the upstream `.gitattributes`: openssl's
archive omits `dev/` and `util/mktar.sh`, and brotli's omits
`c/common/dictionary.bin`, which nothing in BaseTools reads (`dictionary.c`
carries the data inline). Every file present in both is byte-identical, and
the artifact checksums agree.

### Residual risk

GitHub archive tarballs are not contractually byte-stable; the compression
has changed before. If `audk-*` or `opencorepkg-src` ever fails
verification without the URL changing, that is the cause, and the fix is to
re-verify the *contents* against the commit rather than to re-pin blindly.

## 2026-09-17 — P3 — our own config.plist, and the SMC kexts pinned

Two of P3's three remaining build-side tasks. The config is the substance:
it is what makes the bootloader ours rather than khronokernel's.

### The config was derived from 1.0.7's Sample.plist, not from 0.6.6

`boot/config/config.plist` starts from the `Docs/Sample.plist` in the same
source tree we build, and departs from it only where
`boot/config/README.md` says so, with a reason each time. The 0.6.6 reference config was used as evidence
— cited where adopted, cited where rejected — never as a starting point.

`ocvalidate` from that same build tree: **"No issues found"**, first run, no
edits needed. It is the 1.0.7-only binary, which is exactly why it is worth
having.

Settings the plan's table did not anticipate, each of which would have been
a boot failure or a diagnosis problem:

- **`Misc > Security > Vault` = `Optional`.** The sample ships `Secure`,
  which makes OpenCore refuse to boot without a signed `vault.plist` and
  `vault.sig`. We produce neither. This one would have been a hard stop at
  Task 7 with a confusing message.
- **`Misc > Debug > DisableWatchDog` = `true`.** Decision 0002 expects
  `OpenHfsPlus.efi` to be slower than Apple's driver by an unmeasured
  amount. The firmware watchdog reboots on a slow `boot.efi`, which would
  have turned "slow" into "reboot loop" and hidden the cause.
- **`UEFI > APFS > EnableJumpstart` = `false`.** 10.9 cannot mount APFS.
- **`Misc > Boot > HideAuxiliary` = `false`.** During bring-up an entry
  hidden behind a keystroke is indistinguishable from one OpenCore never
  found, and "picker empty" is a failure mode Task 7 has to diagnose.
- **`NVRAM > Delete` on `boot-args`.** From Task 8, when split-pflash OVMF
  restores variable *persistence*, a stale `boot-args` would otherwise
  outlive the config that set it.

And two places where we knowingly differ from the reference:

- **`Kernel > Block` is empty.** The reference ships a disabled block for
  `AppleTyMCEDriver`; P1 enabled it and nothing changed (see "Failure 4"
  above). Shipping a setting observed to do nothing would also confound
  Task 8, which exists to prove the SMBIOS change alone fixed the panic.
- **`Booter > Quirks > SetupVirtualMap` and `FixupAppleEfiImages` stay on**,
  which is 1.0.7's sample default; the 0.6.6 reference has the first off and
  did not have the second at all. If Task 7 fails inside the booter, these
  are the first two to flip, one at a time.

`SetApfsTrimTimeout` is the clearest case of a reference setting that was
copied rather than chosen: the reference sets it, and 10.9 predates APFS by
four years. Left at the sample default.

### The plan's HFS+ test could not have passed

The plan's `tests/config_plist.bats` asserts `[[ "$output" != *"HfsPlus.efi"* ]]`
against a space-joined driver list. `"OpenHfsPlus.efi"` **contains** the
substring `"HfsPlus.efi"`, so with our driver present that assertion is
always false. Written the other way round — as a guard that passes — it
would have guarded nothing. The test now compares whole driver names, and
was checked by temporarily adding `HfsPlusLegacy.efi` to the config and
watching it fail.

### Lilu 1.7.2 and VirtualSMC 1.3.7 still support 10.9

The plan flagged this as a stop-and-report: acidanthera has been dropping
old-OS support, and if the current releases could not load on Darwin 13 we
would need older pinned releases, which is a decision rather than a
workaround. Checked by reading each `Contents/Info.plist`, not by assuming:

```
Lilu 1.7.2        OSBundleLibraries_x86_64  com.apple.kpi.* = 10.0.0
VirtualSMC 1.3.7  OSBundleLibraries_x86_64  com.apple.kpi.* = 10.0.0
                                            as.vit9696.Lilu = 1.2.0
```

Darwin 10 is 10.6. **10.9 is Darwin 13**, well above the floor, so both are
fine. The non-arch-specific `OSBundleLibraries` in each declares `8.0.0`
(Darwin 8 = 10.4), which is where the `MinKernel: 8.0.0` in our
`Kernel > Add` entries comes from. Neither Mach-O carries an
`LC_VERSION_MIN_MACOSX` or `LC_BUILD_VERSION` load command, so there is no
second, stricter minimum hidden in the binary. Both are fat, x86_64 + i386.

Pinned in `vendor/sources.tsv`:

```
lilu-release        1.7.2  53967d7dcfaab01023a33df2e969a89522f13d6654a6a56ac4711b62dabf3ab8
virtualsmc-release  1.3.7  12f1d379969f926306fa92d94ddbf33b32b31176589dc42089d864a26b31b700
```

`VirtualSMC` requires Lilu ≥ 1.2.0 and Lilu 1.7.2 declares
`OSBundleCompatibleVersion 1.2.0`, so the pair is self-consistent. Lilu must
be injected first, and is.

### The two archives do not have the same shape

`Lilu-1.7.2-RELEASE.zip` has `Lilu.kext` at the top level.
`VirtualSMC-1.3.7-RELEASE.zip` has its kexts under `Kexts/`, next to
`Tools/` and `Drivers/`. So `boot/fetch-kexts.sh` searches for
`<Name>.kext` rather than assuming a path, with `-prune` so a `.dSYM`'s or
a plugin's copy of the name cannot win.

### Still pending: how few kexts we actually need

**Task 6's experiment has not been run.** The reference image ships three
SMC-related kexts — `FakeSMC-32`, `VirtualSMC` and `Lilu` — and `FakeSMC`
and `VirtualSMC` are *alternative* emulators from different projects, so at
least one is probably redundant. We ship two, because the rule is that
nothing ships without having seen a boot fail without it. Settling that
needs a bootable configuration, which is Task 7. Until then the question is
open, not answered.

## 2026-09-17 — P3 — the EFI image, assembled without root

`./boot/build-efi-image.sh` produces
`$MQG_IMAGE_DIR/work/opencore-p3.img`: a 192 MiB file, GPT, one EF00
partition of 191.0 MiB starting at LBA 2048, FAT32, built with `sgdisk`
and `mtools` and no privilege of any kind. Nothing has booted it yet —
that is Task 7.

```
::/EFI/BOOT/BOOTx64.efi
::/EFI/OC/OpenCore.efi
::/EFI/OC/config.plist
::/EFI/OC/Drivers/OpenRuntime.efi
::/EFI/OC/Drivers/OpenPartitionDxe.efi
::/EFI/OC/Drivers/OpenHfsPlus.efi
::/EFI/OC/Kexts/Lilu.kext/Contents/Info.plist
::/EFI/OC/Kexts/Lilu.kext/Contents/MacOS/Lilu
::/EFI/OC/Kexts/VirtualSMC.kext/Contents/Info.plist
::/EFI/OC/Kexts/VirtualSMC.kext/Contents/MacOS/VirtualSMC
::/EFI/OC/ACPI/  ::/EFI/OC/Tools/  ::/EFI/OC/Resources/   (empty)
```

Every file was copied back out with `mcopy -n` and compared: all ten are
byte-identical to their sources, and `ocvalidate` still passes on the
`config.plist` read out of the FAT filesystem, not just on the one in the
repo.

### `mformat` will format over the backup GPT if you let it

The one real bug found in this task, and it is invisible until it is not.

mtools is given a byte *offset* into the image (`img@@1048576`), not a
partition. Left to itself it formats from there to the end of the file —
including the 33 sectors GPT reserves at the end for the backup header and
partition table. The resulting filesystem believes it owns 96,256 sectors
where the partition table says 96,223, and a large enough write eventually
scribbles over the backup GPT.

The fix is one flag: `mformat -T "$(efi_partition_sectors "$img")"`, with
the sector count read back out of the partition table via `sgdisk -i 1`
rather than recomputed. `tests/efi.bats` compares `minfo`'s `big size`
against `sgdisk`'s `Partition size` and fails if the filesystem is larger.
Verified by removing the flag and watching that test go red.

### Sizing, checked rather than assumed

The payload is **1,658,422 bytes**: 860 KB of artifacts, 14 KB of config,
784 KB of kexts. The plan's 192 MiB is therefore about 120× what is
needed, which is fine — it matches the reference image's 191 MiB and an
EFI partition is not scarce.

What matters is not the constant but that nothing depends on it being
right by accident. `efi_fits` refuses to build when the payload plus the
same again for headroom would not fit, *before* `mcopy` gets a chance to
fail with a message about a file rather than about the image.

### Kexts are copied as trees, not as two known files

The plan's script copies `Contents/Info.plist` and `Contents/MacOS/<name>`
by name. That is correct for Lilu 1.7.2 and VirtualSMC 1.3.7 — each
release bundle contains exactly those two files, checked — but it would
silently drop anything a future release adds. `efi_copy_tree` walks the
bundle instead, creating directories parent-first, so the shape survives
the trip. Confirmed with `mdir -b -/`, above.

### `mdir` shows short names, which nearly hid a real question

`mdir` prints the 8.3 name in its columns and the long name only in a
trailing column when the two differ. A file called `d.efi` shows up as
`d        efi`, so a test asserting `*"d.efi"*` against `mdir` output is
testing nothing about long-name support. `tests/efi.bats` uses
`OpenHfsPlus.efi` for that reason: OpenCore looks up drivers by long name,
and VFAT long names are the thing that has to work.

## 2026-09-17 — P3 — our own OpenCore boots 10.9, and answers three questions

`./vm/run.sh p3-oc` — one variable changed from the P2 baseline, the
bootloader — boots Mavericks to the desktop. The boot log shows
`Lilu Kernel Extension 1.7.2`, `VirtualSMC`, and
`hfs: mounted Mavericks on device root_device`, which is **our
`OpenHfsPlus.efi` reading the HFS+ volume**. That is the component
`docs/decisions/0002` was written about, working.

Three things this settles.

### 1. SMBIOS alone was sufficient — P1's open question, closed

Our `config.plist` has `Kernel > Block: []`. It has **never** contained the
`AppleTyMCEDriver` block that khronokernel's image shipped and that P1
enabled. The guest boots with no panic.

So the block was never the fix; changing SMBIOS from `MacPro5,1` to
`iMac14,2` was. P1 left both changes in play and could not separate them.
Worth noting the shape of the near-miss: had we carried the block forward
"because the reference had it", it would have looked like part of the
solution forever.

### 2. FakeSMC-32 was redundant — Task 6's experiment, answered

The reference image ships **three** SMC-related kexts: `FakeSMC-32`,
`VirtualSMC` and `Lilu`. `FakeSMC` and `VirtualSMC` are alternative SMC
emulators from different projects, so shipping both was always suspicious.

We ship **two** — `Lilu` and `VirtualSMC` — and the guest boots. `FakeSMC-32`
was not needed. Nothing is shipped here without having seen a boot fail
without it, and this one never failed.

### 3. Screen resolution is a firmware setting, not a driver problem

**This corrects a claim made in `docs/install-log.md` after P2.**

P2 offered exactly one resolution, 1280x720, despite `vgamem_mb=64`. I
concluded that VRAM was not the constraint — correct — and that the real
work was therefore a display driver such as VMQemuVGA or VMsvga2 —
**wrong**.

This boot came up at **4096x2160** with no display driver at all. The cause
is in our config, inherited from 1.0.7's sample:

```
UEFI > Output > Resolution = Max
```

OpenCore sets the UEFI GOP framebuffer, and macOS inherits whatever
framebuffer the firmware hands it. The lever is the **bootloader's GOP
mode**, which we control, not a guest-side driver.

Two caveats, so this is not over-read:

- The framebuffer is still **fixed**. macOS gets one mode and cannot change
  it at runtime; System Preferences will still offer a single resolution. A
  display driver remains the only route to *changing* resolution from inside
  the guest, and to resize-to-window.
- `Max` is not obviously the right choice. 4096x2160 is a lot of pixels for a
  guest with no graphics acceleration, where the CPU draws everything. P5
  should treat resolution as a tunable with a real cost, and measure it,
  rather than assuming bigger is better.

**What P5 inherits:** its display phase is now about *changing* modes and
resize-to-window, not about reaching a usable resolution at all. That is a
smaller and better-defined problem than the one the design anticipated.

## 2026-09-17 — P3 Task 8 — stock OVMF does not work with OpenCore here

**Blocked, and the cause is not ours.** Recording in full because the
diagnosis took a while and the conclusion is counter-intuitive.

### What works

- `p3-oc`: our OpenCore 1.0.7 + the **reference** firmware → boots 10.9 to
  the desktop.
- Stock Debian OVMF 2024.02 **alone**, no OpenCore: renders the TianoCore
  boot manager at 1280x800. The firmware is fine.

### What does not

Stock OVMF + OpenCore → OpenCore runs, sets its resolution, renders nothing,
never boots macOS.

**And it fails identically with khronokernel's reference OpenCore 0.6.6.**
That control is what matters: it is not our build, our config, or our image
assembly. It is stock OVMF and OpenCore not getting along on this setup.

### How it was diagnosed

Bisected by adding one device at a time to a minimal OVMF boot:

| Configuration | Result |
|---|---|
| OVMF alone | 1280x800, boot manager renders |
| + ich9 USB controllers | unchanged, fine |
| + our OpenCore image | **4096x2160, black** |

The resolution change proves OpenCore executes: setting `Resolution` in our
config to `1024x768` produced a 1024x768 framebuffer, a mode OVMF would never
pick by itself.

Ruled out, each as its own experiment:

- CPU model — `Penryn` with and without flags, `Nehalem`, `Haswell-noTSX`:
  OVMF boots fine on all four.
- `usb-storage` vs `ide-hd` for the OpenCore disk.
- Booter quirks `SetupVirtualMap` and `FixupAppleEfiImages`, off individually
  and together.
- `TextRenderer` `BuiltinGraphics` vs `SystemText`.
- Verbose `boot-args` — macOS never gets far enough to print.
- The macOS disk's own ESP — fails with only the OpenCore disk attached.

### The one real lead, and why it is a dead end for now

Enabling OpenCore's own file logging (`Misc > Debug > Target = 67`) — which is
how this should have been approached an hour earlier — produced exactly two
lines:

```
OCM: Failed to start image - Already started
BS: Failed to start OpenCore image - Already started
```

`Bootstrap.efi` (shipped as `EFI/BOOT/BOOTx64.efi`) loads
`EFI/OC/OpenCore.efi` and gets `EFI_ALREADY_STARTED` back.

Shipping `OpenCore.efi` directly as `BOOTx64.efi` instead gets further — it
renders — but then fails with `OC: Failed to load configuration!`, because
OpenCore resolves `config.plist` relative to its own path and looks in
`EFI/BOOT/`. 1.0.7's `Docs/Configuration.tex` confirms the Bootstrap
arrangement we used is the intended one.

### Where this leaves P3

Everything except the firmware is done and Tier 0:

| Component | Tier | State |
|---|---|---|
| OpenCore | **0** | built offline from pinned source, boots 10.9 |
| `config.plist` | **0** | ours, `ocvalidate`-clean |
| HFS+ driver | **0** | `OpenHfsPlus.efi`, mounts the volume |
| Kexts | **1** | Lilu 1.7.2, VirtualSMC 1.3.7, pinned |
| **Firmware** | **2** | still the reference `OVMF.bin` |

The design anticipated this: *"If the stock one fails, log how, and keep the
old one pinned (with its checksum) for now."* Done.

**Also unresolved:** EFI variable persistence, which was the other reason to
want split pflash.

### Keep the file logging

`Misc > Debug > Target = 67` stays on. It is the only thing in this entire
session that produced a direct answer instead of a hypothesis, and the cost
is one file on the ESP.

## 2026-09-17 — P3 Task 9 — our own OVMF, and why Debian's was never the test

**P3's firmware gate is closed.** `./vm/run.sh p3-full` boots 10.9.5 to the
desktop on firmware we built, over split pflash, with EFI variables that
persist. Nothing in that profile is Tier 2.

### The build

`OvmfPkg` is part of EDK II, and the EDK II this project already pins is
**acidanthera/audk** — acidanthera's own fork, the one OpenCore is built
against. So the firmware did not need a new source, a new pin, or a new
fetch step. `boot/build-ovmf.sh` builds it out of the same tree
`boot/build-opencore.sh` assembles, with the same three environment choices:

```
build -a X64 -b RELEASE -t GCC -p OvmfPkg/OvmfPkgX64.dsc
```

Reusing that tree rather than unpacking a second copy is deliberate: a
second list of submodule pins is a second thing that can drift. The cost is
an ordering dependency, which the script states (`--udk-dir` /
`--udk-commit` ask `build-opencore.sh` where the tree is and which commit it
should hold, and the build refuses a tree holding any other commit).
OpenCorePkg's patches to that tree touch DuetPkg's SATA/ATA drivers and
ShellPkg; none reach OvmfPkg.

Three images, all from one build, into `$MQG_BUILD_DIR/firmware/`:

| File | Bytes | For |
|---|---|---|
| `OVMF_CODE.fd` | 3,653,632 | pflash unit 0, read-only |
| `OVMF_VARS.fd` | 540,672 | pflash unit 1 — the **template** |
| `OVMF.fd` | 4,194,304 | `-bios`, one complete image |

Sizes worth noticing: CODE + VARS = exactly 4 MiB, which is what makes the
pflash pair legal (QEMU sizes each flash device from its file). And they are
byte-for-byte the sizes of Debian's `OVMF_CODE_4M.fd` / `OVMF_VARS_4M.fd`,
so this is a drop-in replacement for the wiring Task 8 already tried.

`unshare -rn ./boot/build-ovmf.sh` produces identical checksums to a normal
run — 1m22s from clean, 11s warm. Offline, as claimed.

### Does it work where Debian's did not? Yes, immediately.

Tested in the prescribed order, one change each:

| # | Configuration | Result |
|---|---|---|
| 1 | our `OVMF.fd` alone, `-bios` | TianoCore boot manager renders at 1280x800 |
| 2 | our CODE/VARS pflash + our OpenCore, **usb-storage** | **picker renders; 10.9 boots to the desktop** |
| 3 | combined `-bios` | not needed |

There was no step 3. The split pair — the arrangement Task 8 could never get
past a black screen — worked on the first try.

Two things Task 8 blamed on other causes turn out to have been the firmware:

- **The OpenCore disk over USB.** Task 8 moved it to `ide-hd` because stock
  OVMF never read a single block from it over USB. Ours enumerates it over
  USB fine, and `p3-full` is back to `usb-storage`, matching `p3-oc`. That
  really was a firmware difference, and this is the firmware without it.
- **`Failed to start image - Already started`.** Still happens here — but
  only when you let the picker time out (see below), never on the path that
  boots macOS. It is a *symptom of re-entry*, not of a broken loader.

### What the "Already started" log actually is

With a fresh NVRAM there is no remembered default, so OpenCore's picker
defaults to entry 1, **`EFI (external)` — the OpenCore disk itself**. Let the
5-second timeout fire and OpenCore boots that entry, which is
`EFI/BOOT/BOOTx64.efi`, which is `Bootstrap.efi`, which tries to start
`OpenCore.efi` a second time and gets `EFI_ALREADY_STARTED`. Screen freezes,
and the two-line log Task 8 found is written by that second instance.

So the log Task 8 read was the *recursion*, not the original failure. Press
`2` (or arrow to Mavericks and press Enter) within the timeout and macOS
boots. This is a config wart, not a firmware one, and it is worth fixing
separately — nothing here changed `config.plist`, because this task's one
variable was the firmware.

### EFI variables persist — the other reason for split pflash

`boot/make-nvram.sh <name>` copies the pristine VARS template to
`$WORK_DIR/<name>-VARS.fd`, verifies it against the build's `SHA256SUMS`
first, refuses to clobber an existing one without `--force`, and refuses
outright to write anywhere under `$MQG_BUILD_DIR`. The template is a build
artifact; booting from it directly would invalidate its own checksum.

Measured across three power cycles of one VM:

```
pristine template  5d2ac383...   0 variables
after boot 1       792a56b2...  24 variables
after boot 3       b8ac5c96...  24 variables, different contents
```

The store goes from **empty to holding real variables**, and among them are
ones macOS itself wrote — `boot-args`, `prev-lang:kbd`, `run-efi-updater` —
alongside OVMF's `Boot0000`–`Boot0004`, `BootOrder`, and a boot entry named
`UEFI QEMU QEMU USB HARDDRIVE 1-0000:00:1d.7-1`. Guest NVRAM writes survive
a power cycle. This is the thing `-bios` has denied us since P1.

### Two things that did not work, recorded because they cost time

- **Modified keys never reach OpenCore's picker.** Plain keys work: digits
  boot an entry, arrows move the cursor and cancel the timeout. But
  `ctrl-2` and `ctrl-ret` — the picker's "set this as the default" gesture —
  do nothing at all. Most likely `UEFI > Input > KeySupport = true`, whose
  legacy keyboard shim has no BIOS data area to read modifiers from under
  OVMF. `KeySupport = false` (let OpenCore use the firmware's own
  `SimpleTextInputEx`) is the obvious next experiment and would also give
  the picker a remembered default. **Not tried here** — it is a
  `config.plist` change, i.e. a different variable.
  Consequence: the "picker remembers its selection" half of the persistence
  test is **unproven**. Variables persist; OpenCore was never able to write
  a default for them to hold.
- **10.9 ignores the ACPI power button.** `system_powerdown` over the QEMU
  monitor produces no shutdown and no dialog, so every reboot in this
  session was a hard stop. Mouse clicks via `mouse_button` over the monitor
  did not register either (the pointer moves, the click does nothing), so
  the Apple menu was not reachable from a script. A clean guest shutdown
  still needs a human at a GTK window. Worth solving before P4 automates
  anything that has to shut a guest down.

### Where P3 stands

| Component | Tier | State |
|---|---|---|
| OpenCore | **0** | built offline from pinned source |
| `config.plist` | **0** | ours, `ocvalidate`-clean |
| HFS+ driver | **0** | `OpenHfsPlus.efi` |
| **Firmware** | **0** | **`OvmfPkg` from the same pinned audk tree** |
| Kexts | 1 | Lilu 1.7.2, VirtualSMC 1.3.7, pinned |

`bin/tier-check.sh` reports `p3-full` clean. `--strict` still fails overall,
on `p1-reference`, `p1-headless`, `p1-interactive`, `p2-clone` and
`p2-notablet-abs` — the historical reference profiles, which Task 9 Step 1
retires deliberately rather than exempts.

### New: `%BUILD%` in profiles

Profiles gained a fourth placeholder. The firmware a profile boots is a
build artifact, and `MQG_BUILD_DIR` is overridable independently of
`MQG_IMAGE_DIR`; a profile spelling it `%IMAGES%/build` would boot the wrong
firmware for anyone who moved the build directory.

### Housekeeping: `run.log` went missing

`run.log` was present at the start of this session and is absent at the end.
It is gitignored ("machine-generated, append-only, noisy"), so it was never
in the repository and nothing tracked was lost — but the lab's record of
QEMU invocations before today is gone with it. The most likely cause is a
`git stash push -u` / `git stash pop` pair run around the fresh-clone check;
that could not be reproduced afterwards, so this is a suspicion rather than
a finding. It has deliberately **not** been reconstructed by hand: a
machine-generated log that someone typed is worse than an absent one.
`vm/run.sh` recreates it on the next run.

## 2026-09-17 — P3 Task 9 addendum — a failed reproduction, and a correction

The coordinator could not reproduce the `p3-full` boot above and pushed
back. They were right to. Two things came out of it: **the committed tree
does boot**, and **my explanation of the `Already started` log was wrong in
the way they suspected.** Both are recorded here because the write-up above
now reads as more confident than it earned.

### What they saw, and what it actually was

Their report: "black screen (1280x800, 2 colours) at 13s, 16s, 75s and 86s.
Never a picker." Their VM was still running when I looked at it. Screenshot:

```
20260917-210040-coord-current-state.png -> 2 distinct colours; (1280, 800)
                                           non-black pixels: 3603 (0.352%)
```

**That screen is the picker.** White text on black is exactly two colours,
and the picker occupies 0.35% of the frame. A truly black screen has *one*
colour. Counting colours in a screendump is a reasonable automation, but the
threshold has to be 1 vs 2, not "2 means blank" — and at 1280x800 a
five-line menu is easy to miss if you never look at the image.

For comparison, the desktop shot from the same series is 185,798 colours.
Anything that uses "distinct colours" as a boot-progress signal from now on
should treat **2 colours as text on screen**, not as failure.

### The committed tree boots. Reproduced from their exact state.

Not my session's leftovers: their freshly rebuilt `opencore-p3.img`
(`BOOTx64.efi` 28,672 = Bootstrap, `OpenCore.efi` 712,704 in `EFI/OC`,
`config.plist` byte-identical to HEAD), a fresh clone, a pristine NVRAM from
`make-nvram.sh --force`, and `./vm/run.sh p3-full` — the committed profile,
no hand-assembled command line:

```
rm -f  $MQG_IMAGE_DIR/work/p3-full.qcow2
./vm/clone.sh p2-manual-install p3-full
./boot/make-nvram.sh --force p3-full
./vm/run.sh p3-full &
# and, from t=0, every 0.6s for 20 iterations:
#   sendkey 2   over the profile's monitor socket
```

Kernel log at +12s, desktop at +2m30s. The **only** difference from their
sequence is the keypress.

### The keypress is the finding I under-reported

`Misc > Boot > Timeout = 5` and, with an empty NVRAM, the picker's default
is entry 1, **`EFI (external)` — the OpenCore disk itself**. Do nothing for
five seconds and OpenCore boots that, which re-enters `BOOTx64.efi`, which
fails, and the machine sits there. The picker text stays on screen, which is
why the frame still looks like a picker long after the choice was made.

So `p3-full` as committed **needs a human (or a script) to press `2` within
five seconds of the picker appearing**, or it hangs. That is a real defect
in the artifact, not a quirk of how I drove it, and the entry above should
have said so in the first paragraph instead of in passing. It is a
`config.plist` problem — the one variable this task deliberately did not
touch — so it is written down rather than fixed here.

### Correction: what `Already started` is, with evidence this time

My claim above was that the two-line log is written by a *second* OpenCore
instance. The coordinator's objection was precise: the timestamps are
`00:000` and `00:036`, so Bootstrap fails immediately, which is not a picker
timing out after five seconds.

**The conclusion I drew was right; the reasoning I gave for it was wrong,
and I had not checked it.** Here is the checked version.

1. Both lines come from **one** Bootstrap invocation, not two instances of
   anything. `OCM: Failed to start image` is `Library/OcMiscLib/ImageRunner.c:110`,
   inside `OcLoadAndRunImage`; `BS: Failed to start OpenCore image` is
   `Application/Bootstrap/Bootstrap.c:134`, immediately after that call
   returns. Inner then outer, 36ms apart. The coordinator read this
   correctly.

2. **`00:000` does not mean "0 ms into the boot".** `OcLog.c`'s `GetTiming`
   calibrates the TSC lazily on the *first log entry* and sets
   `TscStart = TscLast = AsmReadTsc()` at that moment. The first line OpenCore
   ever logs therefore always prints `00:000 00:000`, whenever in the boot it
   happens. This is the piece that makes the timestamps look damning and is
   not.

3. **In a RELEASE build a clean OpenCore boot logs nothing at all.**
   `OpenCorePkg.dsc` sets `PcdFixedDebugPrintErrorLevel|0x80000002` for
   `TARGET == RELEASE`, i.e. `DEBUG_ERROR | DEBUG_WARN` — every
   `DEBUG_INFO` call is compiled out of the binary. So a two-line log is not
   "OpenCore died after two lines"; it is "these were the only two warnings
   of the entire boot".

4. Confirmed by experiment. Same image, same profile, ESP log deleted first:

   | Run | Keypress | Screen | `opencore-*.txt` |
   |---|---|---|---|
   | success | `2` at t=0 | desktop | one file, **262,144 bytes of NULs — zero entries** |
   | control | none | picker, then hang | one file, **exactly the two lines** |

   A boot that demonstrably reaches the macOS desktop leaves an *empty* log.
   That alone disproves "two lines means Bootstrap failed at the start of the
   boot".

5. One file, not two, because **Bootstrap never calls
   `OcConfigureLogProtocol`** — its `UefiMain` only locates the filesystem
   and runs OpenCore. The log file is named once per boot, by the first
   OpenCore instance, ~3s after power-on (control run: VM started 21:05:28,
   file `opencore-2026-09-17-210531.txt`). The second Bootstrap's two
   warnings land in that already-installed protocol and are written to that
   same file.

So: OpenCore #1 starts normally and logs nothing; the picker times out into
`EFI (external)`; that starts `BOOTx64.efi` again; Bootstrap #2's
`OcLoadAndRunImage` gets `EFI_ALREADY_STARTED` for an `OpenCore.efi` that is
already running; two warnings are appended to instance #1's log with a
freshly started TSC clock. The recursion reading stands — but on this
evidence, not on the filename arithmetic I used before, which was wrong.

### What I should have done

Read the ESP log of a **successful** boot before explaining the log of a
failing one. I had the successful boots and never looked. The control run
that settles this took ninety seconds.

## 2026-09-17 — P3 — p3-full verified, and a lesson about instruments

**`./vm/run.sh p3-full` boots 10.9.5 to the desktop on a boot stack with no
Tier 2 component in it.** Verified independently: 1280x800, 185,798 colours,
99.8% of pixels lit. OpenCore 1.0.7 and OVMF both built offline from the same
pinned EDK II tree, our own `config.plist`, `OpenHfsPlus.efi` mounting the
volume.

### It is not unattended, and that matters

`Misc > Boot > Timeout = 5` with an empty NVRAM store means the picker's
default entry is `EFI (external)` — the OpenCore disk itself. Left alone, it
times out, re-enters `BOOTx64.efi`, and hangs. **A key must be pressed.**
Sending `2` to the monitor every 0.6 s from t=0 works.

This is a real constraint for later phases, not a detail: **P4's unattended
pipeline and P6's CI both need a boot that requires no keypress.** Fixing it
is a `config.plist` change — a remembered default, or hiding the auxiliary
entry — and is the next experiment rather than something to leave discovered.

### Counting colours was the wrong instrument

I spent roughly an hour concluding that stock OVMF was broken, that our
OpenCore was broken, and that `p3-full` did not boot. Every one of those
conclusions came from `vm/screenshot.sh` reporting **"2 colours"**, which I
read as "black screen".

**A screen of white-on-black text has exactly two colours. A blank screen has
one.** Every "black screen" I recorded was a correctly-rendered OpenCore
picker. The difference between "working fine" and "completely dead" was a
single integer, in the opposite direction from the intuitive reading.

What it cost: a firmware bisection, four CPU-model tests, quirk flipping,
renderer swaps, and a stop-and-ask to the user — all investigating a failure
that was not happening.

`vm/screenshot.sh` now reports **lit-pixel percentage and a verdict**
(`blank` / `text (a menu or console)` / `graphical`) instead of leaving a
colour count to be interpreted. ~0% is blank, a fraction of a percent is
text, ~100% is a drawn desktop. That says what it means.

The general lesson, which is worth more than the specific fix: **when an
instrument produces a number, make it produce the conclusion instead.** A
metric that requires interpretation will eventually be interpreted wrongly,
and the wrong interpretation is indistinguishable from evidence.

### Also corrected: the "Already started" log

Both log lines come from **one** Bootstrap call, not two instances as I
guessed. `OcLog` starts its TSC clock on first entry, so line one always
reads `00:000` whenever it happens — the timestamps I used to reject the
subagent's explanation prove nothing. And `PcdFixedDebugPrintErrorLevel`
compiles `DEBUG_INFO` out of RELEASE builds, so **a successful boot logs
nothing at all**; those two lines are what a *failed* boot leaves.

I was reading a failing boot's log without ever having looked at a
successful one's for comparison.

## 2026-09-17 — P3 complete — the gate is closed, and the HFS+ cost is measured

**P3's exit criterion is met and enforced.** `bin/tier-check.sh --strict`
now runs as a section of `bin/run-tests.sh`, beside bats and shellcheck, so
"no unreproducible blobs in the boot path" is a test rather than an
aspiration. 170 bats tests pass, shellcheck is clean, tier-check reports
Tier 2 clean, and the suite passes on a true fresh clone.

### Seven profiles retired, not exempted

`vm/profiles/attic/`, outside `PROFILE_DIR`. `profile_list` globs `*.args`
without recursing, so nothing there is scanned or runnable, and nothing had
to be deleted. `vm/profiles/attic/README.md` says what each one was.

The alternative — leaving them and teaching the gate to tolerate them —
would have inverted the point of having a gate. A rule with a standing
exemption for the things that break it is not a rule.

Five were the expected ones (`p1-reference`, `p1-headless`,
`p1-interactive`, `p2-clone`, `p2-notablet-abs`). Two more went with them:

**`p3-oc` was passing the gate while booting a Tier 2 blob.** Its firmware
line is `-bios %IMAGES%/work/OVMF_CODE.fd` — no `%VENDOR%`, so tier-check
saw nothing. That file is byte-identical to the UTM bundle's `OVMF.bin`:

```
8a7ef5356384de4e6859a070ffe6d2e1aefddfc568e9cb19b17cf9fba78b25f6  work/OVMF_CODE.fd
8a7ef5356384de4e6859a070ffe6d2e1aefddfc568e9cb19b17cf9fba78b25f6  vendor-reference/.../Images/OVMF.bin
```

The profile's own header says "the firmware still is [Tier 2], which is why
tier-check will keep flagging this profile until p3-full", and tier-check
never did flag it — for the whole of P3. `docs/decisions/0002`'s addendum
anticipated a *modified* copy escaping the quarantine; this was an
*unmodified* one, which is the same hole by an easier route.

**The gate stops accidents, not evasion**, and that is now written down in
`docs/decisions/0004` rather than left as something a reader has to infer.
Closing it properly would mean hashing every file a profile names against
the quarantine, which cannot run on a fresh clone with no image directory —
so it would be advisory, and an advisory check is not a gate.

### Measured: `OpenHfsPlus.efi` costs 3.3 s, and Apple's driver will not run

`docs/decisions/0002` has had `_to be filled in by P3._` since P1. Filled
in: **49.1 s versus 45.8 s to the Mavericks desktop.**

| Driver | Runs | Mean | Individual runs |
|---|---|---|---|
| `OpenHfsPlus.efi` (Tier 0) | 5 | **49.1 s** | 48.8, 48.9, 48.9, 49.1, 49.7 |
| `HfsPlusLegacy.efi` (Tier 2, Apple's) | 5 | **45.8 s** | 45.7, 45.7, 45.8, 45.8, 46.0 |

**+3.3 s, +7.2%.** Nine times the run-to-run spread, so it is real; and
small. The decision stands.

Method, because a number without one is a rumour:

- Ten boots, **strictly alternating**, so host drift lands on both arms.
- Each run from identical state: `rm` the overlay, `vm/clone.sh` a fresh
  one off golden #1, `boot/make-nvram.sh --force`. 10.9 ignores the ACPI
  power button, so every run ends in a hard kill, and a run that inherited
  the previous run's journal replay would not be comparable.
- **Exactly one line of the QEMU command line differs between the arms** —
  the OpenCore image. The two images differ only in which driver sits in
  `EFI/OC/Drivers/` and which one `config.plist` names. Same OpenCore
  1.0.7, same config, same kexts, same firmware, same disk.
- t=0 is the `exec` of QEMU; the end is the first 1 Hz `screendump` over
  the monitor socket with more than half the frame lit. Resolution ±1 s,
  hence five runs per arm rather than one.
- **The verdict was checked by eye, not taken from the number.** The
  threshold frame is the Finder desktop with the Dock drawn. After the
  colour-counting fiasco earlier in this phase, a boot-progress instrument
  does not get believed until someone has looked at what it is measuring.

Shipped stack, for the record: `p3-full` (our OVMF, split pflash) with
`OpenHfsPlus` measured 48.7, 48.8, 48.9, 50.0 s — the same as the reference
firmware, so our firmware costs nothing here.

### Why the comparison had to run on the reference firmware

**Apple's driver does not load on the firmware we ship.** First attempt,
`p3-full` with `HfsPlusLegacy.efi` swapped in, timed out at 300 s. The
screen said why:

```
OC: Driver HfsPlusLegacy.efi at 2 cannot be loaded - Not started!
Halting on critical error
```

`EFI_NOT_STARTED` comes back from `gBS->LoadImage` in
`Library/OcMainLib/OpenCoreUefi.c:200`, and it originates in
`UefiImageInitializeContextPreHash` — audk's strict PE loader, in
`MdeModulePkg/Core/Dxe/Image/Image.c:1237`. acidanthera's EDK II fork
replaces EDK II's tolerant image loader with one that rejects
non-conformant PE images, and Apple's extracted binary is one.
`FixupAppleEfiImages` was already `true` and does not help: it fixes images
*OpenCore* loads, not ones the firmware loads.

So the A/B ran on the reference OVMF (2021-era EDK II, which accepts the
blob), holding our OpenCore, our config and our kexts constant. The
measurement is therefore honest about the driver and silent about the
firmware, which is the right shape for the question `0002` asks.

Worth stating plainly: **acidanthera's own EDK II will not load Apple's
`HfsPlus` driver.** Overruling `0002` would now mean giving up the
self-built firmware too — trading 3.3 seconds for two unbuildable blobs
instead of one.

Reproducing the Apple-driver image, for anyone who wants to re-measure. It
lives in the quarantine, because deriving from a Tier 2 artifact does not
launder it:

```
cp --reflink=auto $MQG_IMAGE_DIR/work/opencore-p3.img \
   $MQG_VENDOR_DIR/derived/opencore-p3-applehfs.img
OFF=$MQG_VENDOR_DIR/derived/opencore-p3-applehfs.img@@1048576
mcopy -n -i $MQG_VENDOR_DIR/opencore-legacy/EFI-LEGACY.img@@1048576 \
      ::/EFI/OC/Drivers/HfsPlusLegacy.efi /tmp/HfsPlusLegacy.efi
mdel  -i "$OFF" ::/EFI/OC/Drivers/OpenHfsPlus.efi
mcopy -i "$OFF" /tmp/HfsPlusLegacy.efi ::/EFI/OC/Drivers/HfsPlusLegacy.efi
# and a config.plist whose UEFI > Drivers Path says HfsPlusLegacy.efi
```

`HfsPlusLegacy.efi` is 22,912 bytes, sha256
`5ab216689ee8b6918ef70a22928fe7bc205a39b096e8711cd5711ae95a8df7f2`.

### Golden #2 was not promoted, and that was the decision

The plan's Task 9 Step 7 said to promote `p3-full.qcow2` as golden #2.
**Skipped deliberately**, and written into the plan at the place the
instruction was, so the next reader sees a decision rather than an
oversight.

P3 changed the **boot stack**, which lives in the firmware image, the
OpenCore image and the NVRAM file — **not one byte of it is inside
`p3-full.qcow2`**. That image is golden #1 plus what a few boots wrote:
log lines, an `fseventsd` entry. Promoting it would duplicate 8.5 GB to get
a disk that differs from golden #1 only in ways nobody wants, while its
metadata claimed to represent something it does not contain. Golden #1 is
unchanged and still correct. Promote a golden when the *disk* changes —
after P4's scripted install, for instance. Not after a boot.

### Ledger: G5 struck, G15 struck

`G5` ("OVMF is 4M split CODE/VARS at `/usr/share/OVMF/`") is no longer an
assumption: we build our own firmware and `p3-full` boots
`%BUILD%/firmware/OVMF_CODE.fd`, a path we own on every host. Struck rather
than deleted, so the ledger records that it was retired by a design change
and not merely never tested. `docs/test-hosts.md` updated: the EndeavourOS
machine now has a *stronger* claim to falsify — that `build-ovmf.sh` and
`build-opencore.sh` reproduce the same checksums on another distro.

`G15` (EFI variables do not persist) went too — they persist, measured
across three power cycles.

One consequence worth noticing, because it is the same assumption in
executable form: `bin/preconditions.sh` **failed** the host when
`/usr/share/OVMF` held nothing usable. That is now a WARN. There is no
`ovmf` package on macOS at all, and P6 runs there; a go/no-go script that
says no-go over a package nothing reads is the per-host assumption we just
retired, wearing a different hat.

### What P3 did not deliver

**`p3-full` still needs a keypress**, and both P4 and P6 need that fixed.
`Misc > Boot > Timeout = 5` with an empty NVRAM makes the picker's default
the OpenCore disk itself; left alone it re-enters `BOOTx64.efi`, gets
`EFI_ALREADY_STARTED`, and hangs. It is a `config.plist` defect. The
obvious next experiment is `UEFI > Input > KeySupport = false`, which would
also let the picker remember a default — modified keys currently reach
nothing.

Recorded in the umbrella design's phase table alongside what P3 did
deliver, rather than only here, because it is a dependency and not a
footnote.

## 2026-09-17 — P4 — the keypress requirement is fixed

**`./vm/run.sh p3-full` now boots 10.9.5 to the Finder desktop with no
keypress at all.** Verified: 99.78% of pixels lit, `graphical`, Finder menu
bar present.

This was P3's one outstanding defect and a hard blocker for both remaining
phases — P4's unattended pipeline and P6's CI each need a boot no human
touches.

### The fix

`Misc > Security > ScanPolicy` was `0`, which means *scan everything*. So the
picker listed the OpenCore image itself as a bootable entry, made it the
default, timed out into it, re-entered `BOOTx64.efi` and hung.

```
ScanPolicy = 0x10203
```

That is `OC_SCAN_FILE_SYSTEM_LOCK` (0x1) + `OC_SCAN_DEVICE_LOCK` (0x2) +
`OC_SCAN_ALLOW_FS_HFS` (0x200) + `OC_SCAN_ALLOW_DEVICE_SATA` (0x10000):
**HFS+ volumes on SATA devices only.**

That is exactly the macOS disk and nothing else. The OpenCore image is FAT on
`usb-storage`, so it is excluded twice over — wrong filesystem and wrong bus.
The picker now has one entry, and the timeout boots it.

This is a better fix than hiding the entry or remembering a choice, because it
is *declarative about what we intend to boot* rather than patching over a
symptom. It also means an unexpected bootable volume appearing cannot silently
become the default.

### Two process notes

**First try was `0x10202` and OpenCore rejected it** — `OC: Invalid
ScanPolicy 10202`, halting on critical error. Setting a filesystem bit
requires the filesystem lock bit as well. **`ocvalidate` catches this in one
millisecond**, and it was already built and sitting in the build tree. Running
it before booting would have saved a 75-second cycle. It is now part of the
loop.

**Also: `HideAuxiliary = true` was tried earlier and recorded as "did not
work".** That conclusion is worthless — it was measured with the colour-count
heuristic that mistook a rendered picker for a blank screen. It may well have
worked. Noted so that nobody treats that as a tested dead end; `ScanPolicy` is
the better fix regardless, so it was not re-run.

## 2026-09-17 — P4 — the media pipeline does not need root

Probed before planning P4, because the answer decides whether building
installer media on Linux is a stop-and-ask or just work.

**It is just work.** Every step runs unprivileged:

| Step | Tool | Root? |
|---|---|---|
| Convert the dmg | `dmg2img` | no |
| Create an HFS+ filesystem | `mkfs.hfsplus <file>` | **no** — it operates on a plain file, no loop device required |
| Attach a loop device | `udisksctl loop-setup -f <file>` | **no** |
| Mount HFS+ | `udisksctl mount -b /dev/loopN` | **no** — udisks2 auto-loads the `hfsplus` module |
| Copy files | `rsync` | no |

Verified end to end: a 64 MB HFS+ image created, looped and mounted at
`/media/schmonz/P4TEST` with no password prompt, then unmounted and
detached.

The design assumed the `mkosxinstallusb` approach would need `sudo` for
`losetup` and `mount`, and listed that as an ask. It does not. This removes
the main obstacle to installer Approach A — the Linux-native media build —
and therefore to the whole point of P4, which is producing media without a
Mac in the loop.

### Two caveats to carry into the plan

**Ownership.** udisks2 mounts a filesystem owned by the invoking user. The
`mkosxinstallusb` recipe uses `rsync -aAEHW`, whose `-a` implies `-o`
(preserve owner), and preserving root-owned system files needs root. Whether
the installer actually cares is unknown — it runs as root and may rebuild
what it needs. **Test it rather than assume, and do not reach for sudo until
a boot has actually failed without it.**

**`udisksctl loop-delete` wants a polkit agent** and fails from a
non-interactive shell with "Error opening current controlling terminal". The
unmount succeeds and the loop device detaches with the backing file, so this
is cosmetic here — but a pipeline that loops many images should clean up
deliberately rather than relying on that.

## 2026-09-17 — P4 — `lib/hfs.sh`, and three corrections to the rootless probe

Task 1 of the P4 plan. The probe's headline finding holds — no step needs
root — but three of its details were wrong or incomplete, and each one would
have leaked something.

**1. `udisksctl loop-delete` is not merely cosmetic, and its exit status is
not evidence.** With `--no-user-interaction` (which the probe did not pass)
it works fine and does not want a polkit agent. But:

- On a device that is **still mounted** it returns **0 and does not detach**.
  `losetup -a` still lists it afterwards. It appears to arm a deferred
  detach that fires at unmount instead.
- After a successful unmount of such a device it returns
  `NotAuthorized` — for a device that has already gone away.

So the exit status means nothing in either direction. `hfs_detach` ignores it
and polls `losetup -n -O BACK-FILE <dev>` until the device is really gone,
warning only if it is not.

**2. The loop device does *not* detach at unmount.** The probe recorded that
it "detaches with the backing file", so cleanup could be left implicit.
Measured: after `udisksctl unmount`, `losetup -a` still lists the device.
Unmount then `loop-delete` is what frees it, in that order.

**3. Parsing `udisksctl mount`'s message is a trap.** The output here is
`Mounted /dev/loop0 at /media/schmonz/MQGTEST` — no trailing period on
udisks 2.10.1, so the sed the plan sketched strips nothing. Worse, its `.*`
is greedy: a volume named `Weird. at Name.` parses as `Name`. And two volumes
with the same name get a numeric suffix — `/media/schmonz/OS X Base System`
and `…/OS X Base System1` — which Task 3 will hit, since both BaseSystem and
the target volume are called `OS X Base System`. `hfs_mount` asks
`findmnt -n -f -o TARGET --source <dev>` instead, with the message-parse kept
only as a fallback for a namespace where findmnt cannot see udisks' mount.

### Measurements

| Thing | Result |
|---|---|
| `mkfs.hfsplus` on a 6,550,020,096-byte sparse file | 0.09 s, 21 MB actually allocated |
| `file(1)` on the result | `Apple HFS Plus version 4 data` — not `Macintosh HFS Extended`, which the plan's test expected; the test accepts all three spellings now |
| Two images mounted at once, same volume name | works; separate loop devices, separate mountpoints |
| `hfs_with_mounted` nested inside another | works, and both clean up |
| Loop devices before/after `bats tests/hfs.bats` | 0 / 0, and `/media/schmonz/` left empty |

**One caveat for Task 3.** `hfs_create` takes whole MiB, per the plan's
signature. The reference size is 6,550,020,096 bytes = 6246.09375 MiB, so
Task 3 cannot ask for a byte-exact image through that interface. Either
round up or teach `hfs_create` a byte-sized argument — a decision for the
task that actually needs it.

## 2026-09-17 — P4 — what `get.sh` actually does, and InstallESD.dmg fetched

Task 2. Read <https://mavericksforever.com/get.sh> in full first, as the plan
demanded, rather than guessing at the protocol. Fetched 2026-09-17; the
script's own header says "Last updated 2026/02/09", by Wowfunhappy with
Krackers, Jazzzny and dosdude1.

### The handshake, exactly

Apple will not hand out the installer without a token, and the token needs a
key derived from a real Mavericks-era Mac's identity.

| # | Step | Endpoint |
|---|---|---|
| 1 | Client id: 8 random bytes, uppercase hex | — |
| 2 | Server id: `curl -c -` and take the last cookie line's last field, shaped `<n>~<hex>` | `GET http://osrecovery.apple.com/` |
| 3 | Board serial `C0243070168G3M91F`, board id `Mac-3CBD00234E554E41`, boot ROM `003EE1E6AC14` — donated by dosdude1 from a broken Mac | — |
| 4 | Key: SHA-256 over client-id ‖ server-id's hex half ‖ ROM ‖ SHA-256(serial ‖ board-id) ‖ ten `0xCC` bytes, uppercase hex | — |
| 5 | Payload: POST `cid=`/`sn=`/`bid=`/`k=`, newline-separated, `Content-Type: text/plain`, `Cookie: session=<server id>`. Replies with `AU: <url>` and `AT: <token>` lines | `POST http://osrecovery.apple.com/InstallationPayload/OSInstaller` |
| 6 | Download with `Cookie: AssetToken=<AT>` | `GET http://oscdn.apple.com/content/downloads/33/62/031-10295/gho4r94w66f5v4ujm0sz7k1m0hua68i6oo/OSInstaller/InstallESD.dmg` |

All of it plain HTTP, Apple's choice. **The expected SHA-256 of
`InstallESD.dmg` is
`c861fd59e82bf777496809a0d2a9b58f66691ee56738031f55874a3fe1d7c3ff`** — and
over an unencrypted transfer that checksum is the only integrity there is,
which is why `media/fetch-installesd.sh` verifies before renaming the
`.part` into place rather than after.

`get.sh` also checks that `AU` is *that exact URL* before downloading. Worth
keeping: the same handshake serves whatever OS Apple thinks that board is
entitled to.

Everything after the checksum check in `get.sh` is `hdiutil` — attach the
ESD, convert BaseSystem.dmg to a sparseimage, resize it to **6,550,020,096
bytes**, copy `Packages`, `BaseSystem.chunklist` and `BaseSystem.dmg` in,
convert to UDZO. macOS-only, and exactly what Task 3 reimplements. Not
lifted. (That 6,550,020,096 is where the reference ISO's partition size
comes from — the same number, from the same line.)

### The real download

```
$ time ./media/fetch-installesd.sh
```

| | |
|---|---|
| Wall clock | **59.6 s** (≈ 89 MB/s) |
| Size | 5,318,660,434 bytes (5.0 GiB) |
| SHA-256 | matched on the first attempt |
| Re-run | 11 s, re-verifies and leaves the file alone — no second download |
| `dmg2img -l` | DDM, Apple partition map, one `Apple_HFS` "disk image" partition — a real UDIF, and what Task 3 expects |

No retries, no surprises. The `.part` is removed and restarted rather than
resumed with `curl -C -`: resuming into bytes nobody has ever verified turns
a bad network and a bad resume into the same 5 GB-later checksum failure.

## 2026-09-17 — P4 — installer media built on Linux, and what it cost

Task 3. `media/build-installer-img.sh` assembles bootable Mavericks
installer media from Apple's `InstallESD.dmg` with no Mac, no root and
nothing installed: `dmg2img` the ESD, mount it, `dmg2img` the
`BaseSystem.dmg` inside it, mount that too, create a GPT image with one
AF00 partition, `rsync` BaseSystem onto it, then replace the dangling
`System/Installation/Packages` symlink with the ESD's real `Packages`
directory plus `BaseSystem.dmg` and `BaseSystem.chunklist`.

### The build

```
$ time ./media/build-installer-img.sh
```

| | |
|---|---|
| Wall clock | **50 s** |
| ESD raw image | 5,465,933,824 bytes (transient) |
| BaseSystem raw image | 1,281,120,256 bytes (transient) |
| Output | `installer-linux.img`, 6,686,769,152 bytes |
| SHA-256 | `bdb26dca5e2316b41d2ce4666ceb0748afe8a6bd1a83eb3a9cb9e0686fd578eb` |
| Volume contents | 52,285 entries, 6,414,899,267 bytes — the reference's total to the byte |
| Free space left | 117,112,832 bytes |
| Loop devices before/after | 0 / 0 |

Verification is its own entry below. Three things had to be learned the
hard way first.

### 1. The reference's partition size does not fit a Linux-built copy

`get.sh`'s `hdiutil resize` asks for 6,550,020,096 bytes, and sizing the
partition at exactly that (rounded up to whole MiB, since HFS+ must fill
its partition exactly) ran out of space **17 MB into `BaseSystem.dmg`**,
with everything else already copied.

The same files cost about 153 MB of metadata and per-file slack here
against about 105 MB on the Mac — same content, bigger catalog — and
hdiutil had packed the reference down to 30 MB of free space. So the size
is now the reference rounded up **plus a 128 MiB margin**, which is
documented in the script as what it is: a measured allowance, not a guess.
The reference is still where the number comes from.

### 2. `/.file` cannot be read without root, and does not need to be

BaseSystem has one file at mode `0000` — `/.file`, the marker OS X looks
for to decide a volume has a filesystem. Root can read it; we cannot, and
rsync fails the *whole* transfer over it (exit 23). It is empty, so there
is nothing in it to read: the build excludes it from the copy and
recreates it with its mode and mtime. Any *non-empty* unreadable file
would be a different matter, so the script checks the size and refuses
rather than papering over it.

### 3. Two leaks that only a real 6 GB build exposes

- **A `die` inside a `hfs_with_mounted` body skipped every cleanup.** `die`
  calls `exit`; the first failed build left three loop devices and three
  mounts behind. The body now runs in a subshell, so an `exit` unwinds to
  the cleanup instead of past it. Tested.
- **`udisksctl loop-delete` is a silent no-op while any partition of the
  device is mounted** — and on a desktop session that partition may have
  been mounted by gvfs, not by us. `hfs_detach` now unmounts everything on
  the device first, ours or not.

### The desktop automounter races every `loop-setup`

Same session, same cause: udisks/gvfs see each new loop device and try to
mount it at the same moment we do. Whoever loses gets "already mounted",
and the user gets a modal dialog on their desktop — which an automated
pipeline has no business producing. `hfs_mount` is now idempotent: it asks
`findmnt` first, and treats an already-mounted device as the outcome it
wanted, whoever produced it. Winning the race is not something we can
arrange; being right either way is. (The systemic fix would be a udev rule
setting `UDISKS_IGNORE=1` on our loop devices. That is host configuration,
which this project does not do to people's machines.)

### Ownership: the answer is the one the plan feared

Verbatim, from the built image mounted through udisks:

```
/dev/loop0p1 /media/schmonz/OS X Base System hfsplus \
  rw,nosuid,nodev,relatime,umask=22,uid=1000,gid=1000,nls=utf8
```

`uid=1000,gid=1000`. Everything written is owned by whoever ran the build.
The reference's `root:wheel` is not reproducible unprivileged, whatever
flags rsync is given, so the build does not ask for it — `-rlptDH`, not
`-a`.

**But the mode bits do survive**, which is the half that looked most
likely to break:

```
-rwsr-xr-x 1 1000 1000 46784 Aug 24  2013 .../bin/ps
-r-sr-xr-x 1 1000 1000 31632 Aug 12  2014 .../usr/bin/login
```

setuid intact, on disk, written unprivileged. Ten of the reference's
eleven setuid/setgid/sticky entries are present and identical; the missing
one is `.Trashes`, which OS X made and we have no reason to.

Whether the installer cares about the ownership is **not settled here**.
It runs as root and may well rebuild what it needs. That is a question for
the first boot, and the point of not working around it now is that the
answer will mean something.

## 2026-09-17 — P4 — the Linux-built media matches the reference

Task 4, and the question P4 exists to answer. `media/verify-installer-img.sh`
diffs the Linux-built image against `InstallMavericks.iso` — the media a
Mac produced, and the media that actually installed the system this
project already has. Both are read with `7z l`, which understands HFS+ and
needs neither root nor a mount; the reference is an ISO with an Apple
partition map and the build is GPT, so what is compared is the contents of
the volume, never the raw layout. 2.3 s.

**Every path in the reference is in the build. 40,200 files on each side,
6,414,899,267 bytes on each side, and not one file a different size.**
Per top-level directory the counts and byte totals are identical, down to
`[HFS+ Private Data]` — the hardlinks survived `rsync -H` exactly.

Three comparison traps had to be handled before that sentence could be
true, and each would have produced a page of false differences:

- **Unicode normalization.** HFS+ stores names decomposed; 7z hands them
  back composed. Every Czech, Greek, Japanese and Korean filename on the
  volume "differs" until both sides are normalized — which is very close
  to the Korean-localization loss `mkosxinstallusb`'s README warns about,
  except that here it is an artifact of the *measurement*, not the copy.
- **HFS+ hardlinks.** 7z renders them as inode files under `[HFS+ Private
  Data]`, with different inode numbers on each image, and the link stubs
  carry a mode that is not the file's (`-r--r--r--` there, `0---------`
  here; the inode carries `-rwxr-xr-x` on both).
- **`.Trashes`**, which OS X made on the reference and we have no reason
  to.

### What is actually different

**1,144 alternate streams, 515,320 bytes, all absent from the build**:
1,139 × `com.apple.system.Security` (directory ACLs), 4 × `:rsrc`
(resource forks on the Multiple Master fonts, whose AppleDouble `._`
twins *are* copied as ordinary files), and one
`com.apple.diskimages.recentcksum`. The Linux hfsplus driver exposes no
extended attributes at all — `getfattr -d -m -` on the source returns
nothing — so there was never anything for rsync to carry. Whether an
installer environment misses its directory ACLs is a boot's question.

**Symlink modes**: Linux creates symlinks `0777`, OS X wrote them `0755`.
783 of them. Neither system consults a symlink's own permission bits.

**No HFS+ compression was lost, because there is none to lose.** Neither
image stores a single file smaller than its logical size. Whatever
`mkosxinstallusb`'s README warns about, this media is not compressed:
allocated bytes are 6,520,008,704 on the reference and 6,521,208,832 on
the build, a difference of 1.2 MB in the *other* direction from a
decompressed copy.

### The report, verbatim

```
note: 7z exited 2 listing InstallMavericks.iso; 52295 entries were read anyway
== what is being compared ==
reference: /home/schmonz/.local/share/mavericks-qemu-guest/media/InstallMavericks.iso
build:     /home/schmonz/.local/share/mavericks-qemu-guest/media/installer-linux.img

== totals ==
                files     dirs            bytes        allocated
reference       40200    12095       6414899267       6520008704
build           40200    12094       6414899267       6521208832

== per top-level directory ==
path                                        ref n      ref bytes        n          bytes
(root)                                          5           6181        5           6181
Applications                                 6235       75975463     6235       75975463
Install OS X Mavericks.app                   1162       20546612     1162       20546612
Library                                        62        6173759       62        6173759
System                                      31679     6193035390    31679     6193035390
[HFS+ Private Data]                             8         500359        8         500359
bin                                            33        1914704       33        1914704
private                                       258       15739991      258       15739991
sbin                                           58        1795711       58        1795711
usr                                           700       99211097      700       99211097

== in the reference, not in the build ==
(none)

(9 further paths differ only in how 7z and Linux describe the same
 volume -- HFS+ hardlink inodes and OS X's .Trashes -- not counted as missing)

== in the build, not in the reference ==
EXTRA    [HFS+ Private Data]/iNode173739738
EXTRA    [HFS+ Private Data]/iNode307984300
EXTRA    [HFS+ Private Data]/iNode391757844
EXTRA    [HFS+ Private Data]/iNode459841181
EXTRA    [HFS+ Private Data]/iNode508686807
EXTRA    [HFS+ Private Data]/iNode612229993
EXTRA    [HFS+ Private Data]/iNode870586201
EXTRA    [HFS+ Private Data]/iNode981485428

== required files ==
ok       System/Library/CoreServices/boot.efi  505400 bytes
ok       System/Installation/BaseSystem.dmg  493349624 bytes
ok       System/Installation/BaseSystem.chunklist  2020 bytes
ok       System/Installation/Packages/OSInstall.mpkg  728069 bytes
ok       System/Installation/Packages/OSInstall.pkg  2258 bytes
ok       System/Installation/Packages/OSUpgrade.pkg  843 bytes
ok       System/Installation/Packages/AdditionalEssentials.pkg  94434126 bytes
ok       System/Installation/Packages/AdditionalSpeechVoices.pkg  434183027 bytes
ok       System/Installation/Packages/AsianLanguagesSupport.pkg  1100808 bytes
ok       System/Installation/Packages/BaseSystemBinaries.pkg  283812163 bytes
ok       System/Installation/Packages/BaseSystemResources.pkg  2302558 bytes
ok       System/Installation/Packages/BSD.pkg  304865061 bytes
ok       System/Installation/Packages/Essentials.pkg  3218081872 bytes
ok       System/Installation/Packages/InstallableMachines.plist  2813 bytes
ok       System/Installation/Packages/JavaEssentials.pkg  2472424 bytes
ok       System/Installation/Packages/JavaTools.pkg  20715 bytes
ok       System/Installation/Packages/MediaFiles.pkg  345478239 bytes
ok       System/Installation/Packages/OxfordDictionaries.pkg  140448540 bytes
ok       System/Installation/Packages/X11redirect.pkg  581272 bytes

== sizes that differ ==
larger in the build (HFS+ compression not preserved?): 0
smaller in the build (content lost): 0
zero in the reference, present in the build (7z's hardlink rendering): 0

== HFS+ compression ==
files stored smaller than their logical size: reference 0, build 0
allocated bytes: reference 6520008704, build 6521208832 (+1200128)
Neither image stores any file compressed, so there is no HFS+
compression here for a Linux rsync to lose.

== permission bits ==
files whose mode differs: 799
  symlinks (0777 here, 0755 there; nobody reads them): 783
  hard link stubs (the inode carries the real mode): 16
  everything else: 0
setuid/setgid/sticky entries: reference 11, build 10
    only in the reference: .Trashes (d-wx-wx-wt)
(ownership is not compared: every file here is owned by whoever ran
 the build, because that is the only thing udisks will mount as)

== alternate streams (resource forks, ACLs) ==
reference 1144 streams, 515320 bytes
build     0 streams, 0 bytes
  not in the build: 1 x :com.apple.diskimages.recentcksum
  not in the build: 1139 x :com.apple.system.Security
  not in the build: 4 x :rsrc

== verdict ==
PASS: every path in the reference is in the build, and every
      required file is present at the reference's size.

== dmesg, hfsplus ===
(timestamps are seconds since boot: check them against the build,
 because this log outlives it)
[34298.474944] hfsplus: invalid secondary volume header
[34298.474949] hfsplus: unable to find HFS+ superblock
mqg: warning: the kernel logged hfsplus messages -- read them above
```

The `hfsplus` lines in that tail are at t=34298 s; the build ran at
t≈35198 s. They are from the experiment that established that an HFS+
volume must exactly fill its partition, not from the build.

### What this does and does not settle

It settles that **Linux can assemble the same bytes a Mac does**. Nothing
required is missing, nothing is truncated, nothing was silently skipped.

It does not settle that the media boots. What it cannot see: the file
ownership (uid 1000 throughout, not root), the missing directory ACLs, the
GPT-versus-APM partition map, and whether OpenCore and the Mavericks
bootloader are as happy with this volume as with the reference's. That is
the next task, and the reason the reference exists is that when a boot
fails we can tell which of the two is at fault.

### One more property of the media, found by accident

Mounting the built image changes it. Mounting it to read the mount options
for the entry above was enough: the as-built sha256 was
`bdb26dca…6fd578eb` and afterwards the same file hashed
`9f6ab64a…ab9d6fb4`. udisks will only mount HFS+ read-write, and the
kernel updates the volume header's modify time and last-mounted version on
the way in. Nothing is corrupted — but a `sha256sum -c` at the wrong
moment looks exactly like corruption, so `installer-linux.img.sha256` now
carries comment lines saying when the sum was taken and what invalidates
it. Task 5 will mount this image to inject a LaunchDaemon, so this is not
a one-off.

## 2026-09-17 — P4 — root-owned files without host root, using QEMU

**The blocker.** The Linux-built media booted — kernel loaded, our HFS+
volume mounted as root_device, launchd started — and then:

```
launchctl: Dubious ownership on file (skipping): /System/Library/LaunchDaemons
nothing found to load
```

Every file was uid 1000, so launchd refused every daemon and userland never
started. Not fixable by flags: the `hfsplus` driver's `uid=`/`gid=` mount
options **override on-disk ownership**, and udisks always mounts with the
caller's uid, so even a root `chown` through that mount would not stick.

**Why the obvious escapes do not apply.** There is no HFS+ equivalent of
NetBSD's `makefs`, `mke2fs -d`, `genext2fs` device tables or
`mksquashfs -pf` — no way to write a populated HFS+ image offline with
chosen metadata. `hfsprogs` is mkfs and fsck only. The NetBSD METALOG
approach is the right *shape* and simply has no HFS+ writer.

**The fix, prompted by the user: we already have QEMU.**

libguestfs, anylinuxfs and smolBSD all wrap the same trick — boot a small VM,
be genuinely root inside it, manipulate the filesystem, power off. This
project already depends on QEMU and already pins it, so implementing that
directly costs **no new dependency** and works anywhere QEMU does, including
macOS, where libguestfs cannot go.

`lib/privops.sh` + `lib/privops-qemu-linux.sh`: a ~1.2 MB busybox initramfs
booted with the host's own kernel, image attached as `/dev/vda`, caller's
script run as uid 0.

Verified end to end: a file seeded at 1000:1000 comes back `OWNER: 0:0`,
`DIRMODE: drwxr-xr-x 0:0`, read by a **second, independent** boot — so the
ownership is on disk, not a mount artifact.

### Four things cost an attempt each, all now documented in the backend

1. **busybox applet symlinks do not resolve** inside the initramfs, so every
   command returned `rc=127`. That looks exactly like a missing block
   device, and I chased the device for two attempts. Applets are now invoked
   as `busybox <applet>` explicitly.
2. **devtmpfs must be mounted** or `/dev/vda` does not exist.
3. **`nls_utf8.ko` must be loaded** or the mount fails with
   `hfsplus: unable to load nls for utf8`.
4. `virtio_blk`/`virtio_pci` are built into *this* kernel; a kernel with them
   as modules would need them staged, so the module list is a variable.

The pattern in all four: the symptom pointed at a layer below the fault.
Printing the actual error — rather than inferring it from a failure mode —
is what ended each one.

### The seam, per the user's request

`MQG_PRIVOPS_BACKEND` selects the technique, and `lib/privops.sh` documents
what a backend for another image-build host would do:

| Backend | Where it fits |
|---|---|
| `qemu-linux` | **Implemented.** Linux hosts, no privilege, no new packages. |
| `macos-native` | On a Mac there is no problem: `hdiutil` honours ownership and `get.sh` already builds media this way. P4 exists only for the no-Mac case. |
| `linux-sudo` | `mount -o loop` as root. Simplest, but a standing privilege on every build host. |
| `libguestfs` | Same VM trick, packaged — but Linux-only, so useless for a macOS or NetBSD build host. |
| `netbsd-makefs` | METALOG + `makefs`. Right shape, no HFS+ writer. |

## 2026-09-17 — P4 — Linux-built media reaches the installer GUI

**Answered: Linux can build working Mavericks installer media.** No Mac in
the loop anywhere — `InstallESD.dmg` fetched from Apple, assembled with
`dmg2img`/`mkfs.hfsplus`/`rsync`, ownership repaired in a QEMU microVM, and
booted under our own OpenCore and OVMF. The screen says *Install OS X* with a
Continue button.

Build: 53 s, 6,686,769,152 bytes.

### The ownership fix needed a second half

`chown -R 0:0` alone was wrong, and the spot-check caught it: **chown clears
setuid and setgid bits.** The reference media has exactly six such files:

```
4755  /bin/ps
4555  /bin/rcp
6755  /System/Library/.../Install.framework/Versions/A/Resources/runner
4555  /usr/bin/login
4555  /usr/libexec/authopen
4555  /usr/sbin/traceroute
```

`runner` is the installer's own privileged helper, so losing its `-rwsr-sr-x`
would have broken the thing we are building. The payload now records special
modes before the chown and restores them after: 6 before, 6 after.

This also settles who strips what. `rsync` **did** preserve setuid — six were
present before the chown — so the earlier verification was right, and the
chown is what removed them.

### A mistake worth recording

I ran `chown -R` before writing the code that preserves what chown destroys.
By the time the preservation logic existed, the setuid bits were already
gone, so the list it built was empty and it "worked" while restoring
nothing. Rebuilding from scratch was the only way back.

**A destructive operation should not run before the code that makes it
reversible.** The cost here was two rebuild cycles; against a golden image it
would not have been recoverable.

### Still to do for an unattended install

The installer GUI now waits for a human. Task 5's LaunchDaemon injection is
next, and the blocker that stopped it — launchd rejecting daemons on
non-root-owned media — is exactly what this fix removes.

## 2026-09-17 — P4 Task 5 — the unattended install is Apple's own, not ours

**The Linux-built media now installs Mavericks with nobody watching.**
`./vm/run.sh p4-linuxmedia` against a blank 60 GB disk: boot, partition,
install, reboot, and the installed system comes up on its own. No keypress,
no click, no mouse. **15 min 17 s** wall clock, 01:11:49Z to 01:27:06Z —
boot to the installer environment, disk prepared by ~40 s, install running
by 1 min 40 s, and Setup Assistant's "Welcome" screen on the other side of
the reboot. The installed volume is 8,363,180,032 bytes.

Where it stops is exactly where Task 6 begins: Setup Assistant. That screen
is what `.AppleSetupDone` and the first-boot payload replace, and the
click-log's Setup Assistant section is the specification for it.

Worth noting for Task 7: OpenCore picked the newly installed volume over
the still-attached installer media on the reboot, with no NVRAM entry to
remember and no help from us.

### The mechanism, and where it is written down

Task 5 was planned as a LaunchDaemon injected into the installer
environment. That would have worked and it was a reinvention: **Apple ships
an automated-install path, and it is already on our media.** Three hooks,
all read by `/private/etc/rc.install` inside the installer environment:

| Hook | Where rc.install reads it |
|---|---|
| `/etc/rc.cdrom.local` | line 39: `if [ -x /etc/rc.cdrom.local ]; then` / line 40: run it |
| `/System/Installation/Packages/Extras/minstallconfig.xml` | line 104: `MINSTALL_CONF=...`; when it exists, the OS X Installer runs with `-f ${MINSTALL_CONF}`, with `CatchExit=Minstaller`, which ends in `/sbin/reboot` |
| `/System/Installation/Packages/OSInstall.collection` | lines 107–108: used **instead of** `OSInstall.mpkg`, and it can list more packages |

**`rc.cdrom` does not source `rc.cdrom.local`. `rc.install` does.** That is
why the hook looks absent: `rc.cdrom` is the file you find first, and it
reaches `rc.install` only indirectly, via `launchctl load -D system` at its
very end. Reading only `rc.cdrom` is how this got reinvented once already.

So we write no installer invocation and no reboot: Apple's installer
installs and Apple's `rc.install` reboots. `image/autoinstall/autoinstall.sh`
prepares the disk and stops.

The prior art is `timsutton/osx-vm-templates`, which `docs/prior-art.md`
already cited — for its *first-boot payload*. Its `prepare_iso/prepare_iso.sh`
automates the entire install, and the `minstallconfig.xml` schema comes from
there (and from Greg Neagle's `createOSXInstallPkg` before that). It was not
invented here.

### OSInstall.collection must list OSInstall.mpkg TWICE

Upstream lists it twice and it reads like a copy/paste slip, so our first
version listed it once. The result:

> There was a problem with the automated installation. Check your
> install-automation file for errors, or open the Installer Log for
> additional information.

Not one byte was written to the target volume. Adding the second entry is
the **only** change between that run and the one that installed OS X to
completion. Upstream's apparent typo is load-bearing, and the reading that
fits is that the installer consumes the first entry as the OS product being
installed and installs the remainder, so a one-entry collection leaves it
nothing to do.

### Choosing the target disk, and the finding that made the size guard matter

The selection rule is **"the only disk with no partitions at all"**, with a
16 GiB floor as a secondary guard and a refusal if the count is not exactly
one. Upstream hardcodes `disk0` with a fallback to `disk1`; our layout
attaches three disks, one of which is the installer we are booted from.

What the log showed, and what nobody would have predicted from the host:
**`diskutil list` in the installer environment shows fifteen disks, not
three.** `rc.cdrom` creates twelve RAM disks (`/Volumes`, `/var/tmp`,
`/var/run`, `/System/Installation`, `/var/db`, `/var/folders`, …), each
`newfs_hfs`'d directly onto the raw device, so **each one is an
unpartitioned whole disk** exactly like a virgin target:

```
/dev/disk2
   0:                            untitled               *5.2 MB     disk2
```

Twelve of them, 524 KB to 6.3 MB. Without the size floor the script would
have found thirteen candidates and correctly refused to do anything — which
is a safe failure, and still a failure. The floor is what leaves exactly
one. It was written as belt-and-braces and it turned out to be the load
bearing half.

The media (6.7 GB) and the OpenCore image (201 MB) are both excluded by
being partitioned, not by size.

### Logs: a failed unattended install has to be readable without watching it

`/var/log` is a RAM disk here and evaporates at reboot. The first failure
put a modal dialog on screen
saying "open the Installer Log" — with no way to open it that does not
involve a human and a mouse. Driving the mouse over the QEMU monitor did not
work (relative `usb-mouse`, and the guest never tracked the moves), and
chasing it further would have been the opposite of unattended.

So `autoinstall.sh` now:

- writes its own log to `/var/tmp` and mirrors it to the target volume;
- dumps what the installer is about to read (`ls` of `Extras/`, and the two
  automation files' contents) **as the installer sees them**, which is not
  the same claim as "the files are on the media": `rc.cdrom` mounts a union
  RAM disk over `/System/Installation`, and union fall-through was worth
  verifying rather than assuming. It works;
- ships every `/var/log/*.log` to the target volume every five seconds while
  the install runs, plus an `ls -la /var/log` at handoff.

  **`/var/log/install.log` does not exist in the installer environment.**
  The first version of the shipper copied only that, and got nothing. The
  installer's own output goes to **`/var/log/system.log`** instead, which
  the widened version does capture — 90 KB of it, including
  `OSInstaller[552]: OS X Installer application started` and everything
  after. That is what "check the Installer Log" would have shown, available
  from the host without a VM running.

From the host, with no root:

```
qemu-img convert -O raw work/p4-target.qcow2 target.raw
7z x -so target.raw '1.Mavericks.hfsx' > mav.hfs
7z x -so mav.hfs 'Mavericks/.mqg-autoinstall.log'
```

### Failing without a reboot loop

If disk selection refuses, `autoinstall.sh` does **not** exit. Exiting would
leave `minstallconfig.xml` in place, so the installer would launch against a
target volume that does not exist, fail, and take the `Minstaller` branch —
`/sbin/reboot`. That is a loop that erases its own evidence every forty
seconds. Instead it prints why and sleeps: `rc.install` sources the hook
synchronously, so sleeping stops the installer from ever starting, and the
console text stays on the framebuffer where `vm/screenshot.sh` can read it.

It also means the *second* boot of finished media is safe by construction:
the target now has partitions, so there is no candidate, so nothing is
erased.

### Injection

`media/build-installer-img.sh --autoinstall` copies the three files while the
volume is already mounted for the main copy, before `fix_media_ownership`.
That ordering is the point: the chown in the privops microVM is what makes
them root-owned. Anything injected *after* it would be the one uid-1000 file
on otherwise root-owned media — the exact state that produced "Dubious
ownership on file (skipping)" and a stalled boot. `fix-ownership.sh` now
reports all three, and `rc.cdrom.local` has to come out `-rwxr-xr-x`:
`rc.install` tests it with `[ -x ]` and skips it silently otherwise.

### Two smaller things found on the way

**`p4-linuxmedia` was writing EFI variables into `p3-full`'s NVRAM.** It had
inherited p3-full's pflash line verbatim, so two VMs shared one variable
store — the thing `boot/make-nvram.sh` exists to prevent ("copy, never
share"). Running `make-nvram.sh p4-linuxmedia` produced a file nothing
pointed at. Fixed.

**`media/privops/fix-ownership.sh` failed shellcheck** (no shebang, so
SC2148), which meant `./bin/run-tests.sh` was already red before this task
started. It has a `shell=sh` directive now.

### Every boot, including the ones that changed nothing

| # | What was different | Result |
|---|---|---|
| 1 | The three hooks, `OSInstall.collection` listing `OSInstall.mpkg` once | Disk prepared correctly in ~40 s; installer refused with "There was a problem with the automated installation". Nothing written to the target |
| 2 | **No change to the automation.** Added the config dump and the log shipper, to find out *why* | Same failure, now diagnosable from the host: all three files visible to the installer with the right contents and owners. Ruled out the union mount, the paths and the ownership |
| 3 | `OSInstall.mpkg` listed twice | Full install, reboot, Setup Assistant. 15 min 17 s |
| 4 | Widened log shipping to `/var/log/*.log`, added `ls -la /var/log` | Full install again, reboot, Setup Assistant. 8,384,937,984 bytes. Captured 7 log files off the guest including the 90 KB `system.log` the installer actually writes to |

Two full unattended installs, then, on separate blank targets, both ending
at the same screen.

Attempt 2 changed no behaviour at all and was the one that mattered: it
turned "it does not work" into a list of things that had been eliminated.
Instrumenting before guessing again was cheaper than guessing, at about
four minutes a guess.

### An XML comment cost a cycle

The first attempt at adding the second `OSInstall.mpkg` entry put `--`
inside an XML comment, which is illegal, and `plistlib` rejected the file.
That was caught on the host in a second rather than in a VM in four minutes,
because both automation files are parsed by `tests/payload.bats`. Worth the
test.

## 2026-09-18 — P4 Task 6 — the first-boot payload ships as a package Linux built

**The payload is installed by Apple's installer, not injected afterwards.**
`OSInstall.collection` already lists what gets installed, so the payload
belongs there, and that is where it is: `mqg-firstboot.pkg`, a flat
installer package, built on Linux, listed in the collection beside
`OSInstall.mpkg`. That is upstream's shape — `timsutton/osx-vm-templates`'
`create_firstboot_pkg` — with the one difference that upstream can call
Apple's `pkgbuild` and we cannot.

The plan said to inject the payload onto the target volume after the
install. That would have worked and it would have been a second mechanism
to keep correct, running against a volume the installer had just finished
writing, with no installer to notice if it failed.

### Building a .pkg on Linux, with neither xar(1) nor mkbom

This host has neither, and the project installs nothing. So
`image/payload/mkflatpkg.py` writes the container itself.

**xar was not hard.** A flat package is a xar archive: a 28-byte header
('xar!', header size, version, compressed and uncompressed TOC lengths,
checksum algorithm), a zlib-compressed XML table of contents, then a heap
whose first 20 bytes are the TOC's own SHA-1 and whose remainder is the
members. The reference that settled every detail was a real Apple-signed
package already in this project's media directory —
`QemuUSBTablet-1.2.pkg` — which `7z` reads and which answered three
questions guessing would have got wrong:

- `<offset>` is relative to the start of the **heap**, not the file.
- `<length>` is the size **in the heap**; `<size>` is the **extracted**
  size. For an entry stored raw they are equal, and for a gzip'd one they
  are not.
- `Scripts` is a gzip-compressed cpio in the **odc** format (magic
  `070707`) — checked by decompressing the reference's, not assumed.

**mkbom was the problem, and the way around it was to not need one.** A
component package normally carries `PackageInfo`, `Bom`, `Payload` and
`Scripts`. The `Bom` is a binary bill of materials, `bomutils` exists
precisely because the format is not trivial, and reimplementing it blind
with a 16-minute VM boot as the only test would have been the most
expensive thing in this phase.

So the package is **payload-free**: `PackageInfo` and `Scripts` only, which
is what `pkgbuild --nopayload` produces and which needs no Bom. Everything
it installs, `postinstall` writes by hand, with the target volume in `$3`.
That is not a workaround dressed up as a design: the things this payload
has to do — create an account, enable Remote Login, disable sleep — cannot
be done by copying files onto an unbooted volume anyway. The package's real
job is to leave a LaunchDaemon behind, and a LaunchDaemon plus a script is
two files.

### The output is byte-identical for identical inputs

Fixed timestamps (epoch), fixed uid/gid, entries sorted by name, gzip with
`mtime=0`, no creation-time taken from the clock. `tests/payload.bats`
builds the package twice and compares.

This matters because the manifest records the payload's checksum, and a
checksum that changes on its own says nothing about whether the payload
changed.

### What the payload does, and the two things it does at install time

`docs/install-log.md`'s Setup Assistant section is the specification. The
click-log was written for exactly this.

At **install** time, `postinstall`:

- writes `/private/var/db/.AppleSetupDone` — **at install time on purpose**.
  Doing it at first boot is a race against loginwindow starting Setup
  Assistant, and a LaunchDaemon with `RunAtLoad` has no guarantee of
  winning it. Creating the marker before the system has ever booted removes
  the race instead of hoping.
- installs `firstboot.sh`, its conf file, the authorized key, and
  `/Library/LaunchDaemons/com.mqg.firstboot.plist`.

At **first boot**, `firstboot.sh` creates `mavsuser` (uid 501, gid 20,
member of admin — what the click-log recorded Setup Assistant producing),
installs the key at mode 600 under a 700 `.ssh`, enables Remote Login,
disables sleep and the screensaver, turns the software-update schedule off,
sets the hostname deliberately rather than letting Setup Assistant derive
`Maverickss-iMac` from a full name, enables auto-login, and then removes
its own LaunchDaemon.

**10.9 has no `timeout(1)`**, so `firstboot.sh` carries its own:
`run_with_timeout` runs the command with a watchdog beside it. Every step
goes through it and every failure is non-fatal. The step this exists for is
`softwareupdate`, a 2013 OS asking Apple's 2026 servers about updates —
but the same applies to `dscl` and `systemsetup`, which talk to daemons on
a system that has never booted before.

**It runs exactly once, two ways.** The plist has `RunAtLoad` and no
`KeepAlive`, and the script deletes the plist as its last act. There is
also a `.done` marker, so a hand re-run is harmless. A first-boot script
that keeps running silently undoes manual changes for the rest of an
image's life, and the symptom turns up long after the cause.

The SSH key is a build-time parameter, defaulting to the first of
`~/.ssh/id_*.pub`. No key is generated into an image and none is
committed; `tests/payload.bats` greps `image/payload/` for one.

### Two findings on the way

**Linux mounts a booted HFS+ volume read-only, and `-o force` does not
help.** Re-injecting a rebuilt package into media a VM had already booted
failed with "Read-only file system" from every `chown` in the privops
microVM. That reads like a permissions problem and is not one: the hfsplus
driver mounts read-only when the volume header does not say the volume was
cleanly unmounted, which is the state of any medium a VM has been powered
off on. `mount -o force` is the obvious fix and it does not work here —
`hfsplus_fill_super` tests "was not cleanly unmounted" *before* it consults
the force flag, and only the SOFTLOCK and JOURNALED branches are
overridable.

`hfs_mark_clean` in `lib/hfs.sh` is the repair: set
`kHFSVolumeUnmountedBit` and clear `kHFSBootVolumeInconsistentBit` in both
volume headers, from the host, on our own file, with no privilege. The trap
in writing it: the alternate header is at the end of the **volume**, not of
the file, and taking the end of a partitioned image finds the GPT backup
header instead. There is a test for exactly that.

The pipeline itself does not hit this — it builds media before booting it —
but anyone iterating on the payload does, every time.

**An XML comment cost a cycle again.** `--` is illegal inside an XML
comment, and the first `com.mqg.firstboot.plist` had a pair in its header
comment. `plistlib` rejected it, `tests/payload.bats` caught it in a
second, and the comment now says so.

### The boot that failed, and the one integer that caused it

The first end-to-end run installed OS X 10.9.5 to completion — 675 seconds
of `PackageKit` install time, every Apple package's receipt written — and
then put **"Install Failed"** on screen. `/private/var/log/install.log` on
the target volume, read from the host afterwards, named the cause exactly:

```
PackageKit: request=PKInstallRequest <1 packages, destination=/Volumes/Mavericks>
PackageKit: packages=("PKLeopardPackage <file://localhost/System/Installation/Packages/mqg-firstboot.pkg>")
PackageKit: Got copier error 21 extracting to ... : No such file or directory
PackageKit: Install Failed: Error Domain=PKInstallErrorDomain Code=110
  "An error occurred while extracting files from the package"
  NSUnderlyingError=... "cpio read error: bad file format" ... offset=813
```

Everything about the container was right. The xar header parsed, the TOC
decompressed, `PackageInfo` was read, the identifier `com.mqg.firstboot`
came back in the error message, and the payload-free shape was accepted
without complaint — no Bom was asked for. **The whole failure was the mode
field of the cpio headers inside `Scripts`.**

`070707` cpio's `mode` is a full `st_mode`, **file-type bits included**.
Apple's own packages write `040755` for the `.` directory and `100755` for
a script. We wrote `000755` and `000644`: correct permissions, no type. A
reader that does not know an entry is a regular file does not know to skip
its data, so it resumes parsing in the middle of the first file and
everything after is garbage — "bad file format", 813 bytes in.

The fix is one line. The reason it was not obvious is that everything
*upstream* of it worked, which made "the package format is wrong" feel
already ruled out.

Two things made the diagnosis cheap rather than another round of guessing:

- **`autoinstall.sh` already ships logs to the target volume**, so the
  answer was on disk, readable from the host with `qemu-img convert -O raw`
  and `7z`, with no VM running and no mouse. It cost about two minutes. The
  Task 5 entry describes building that shipper; this is the run it paid for.
- **The reference package.** `QemuUSBTablet-1.2.pkg` is a real Apple-signed
  flat package this project already had on disk, and a hexdump of its
  `Scripts` member shows `040755` in the fourth field. The field list alone
  does not tell you the type bits belong there; the bytes do.

`tests/payload.bats` now asserts that every cpio entry in a built package
has a type nibble, with the error message quoted in the test.

### PackageKit extracts only the script PackageInfo names

The corrected package installed, and the machine came up **past Setup
Assistant** — the marker worked — to a login window with **no account on
it**. `postinstall.log`, on the target volume:

```
target volume: /Volumes/Mavericks
not in this package: firstboot.sh
not in this package: firstboot.conf
not in this package: authorized_keys
could not install the LaunchDaemon
```

Written by the script that was itself extracted from the same archive. The
`Scripts` cpio held five files; PackageKit materialised exactly one — the
one `PackageInfo`'s `<scripts>` element names — and nothing else.

Rather than work out where the others went, the package now contains **one
file**. `build-firstboot-pkg.sh` assembles `postinstall` from the template
in `image/payload/postinstall` plus quoted heredocs carrying `firstboot.sh`,
the LaunchDaemon plist, the generated conf and the authorized key. There is
no sibling to fail to find.

Two things came out of this beyond the fix:

- `postinstall` now logs `$0`, `$PWD` and an `ls` of its own directory, so
  the next person to wonder what PackageKit extracts can read the answer
  rather than infer it.
- **`tests/payload.bats` now runs the assembled `postinstall` against a
  directory** and checks that `firstboot.sh` is byte-identical to the one
  in the repository, that the key is the key that was asked for, that the
  plist still parses, and that `.AppleSetupDone` exists. That is the check
  that used to cost a twenty-minute VM boot, and it costs a second.

Also found here: the builder was packaging its own scaffolding. Everything
in the staging directory becomes the `Scripts` archive, and the assembly
intermediates were in it. They live in a second temporary directory now.

### And then: a 2013 sshd and a 2026 ssh client

The next run did everything. `mqg-firstboot.log`, off the guest:

```
starting on 10.9.5 build 13F34
.AppleSetupDone present: yes
opendirectoryd answered after 0s
creating account mavsuser
...
group 80 (admin) now: GroupMembership: root mavsuser
createhomedir -c -u mavsuser -> created (/Users/mavsuser)
installed 1 authorized key line(s)
systemsetup -f -setremotelogin on -> Remote Login: On
setsleep: Never (computer, display, hard disk)
softwareupdate --schedule off -> Automatic check is off
account: uid=501(mavsuser) gid=20(staff) groups=...,80(admin),...,399(com.apple.access_ssh)
sshd job: 1 entries
removing the LaunchDaemon so this never runs again
```

**Six seconds**, start to finish. Every line of the click-log's Setup
Assistant section, done by a script, including the `com.apple.access_ssh`
membership that Remote Login needs.

And SSH from the host still failed, twice, for two unrelated reasons that
both belong to the fifteen years between the two OpenSSHes:

```
Unable to negotiate with 127.0.0.1 port 2222: no matching host key type
found. Their offer: ssh-rsa,ssh-dss
```

A modern client refuses SHA-1 host keys outright.
`-o HostKeyAlgorithms=+ssh-rsa,ssh-dss` re-enables them. The option that
does the same for the client's own key was renamed from
`PubkeyAcceptedKeyTypes` to `PubkeyAcceptedAlgorithms` in OpenSSH 8.5, and
an unknown `-o` is fatal, so both `image/build-image.sh` and
`image/compare-images.sh` ask which one this `ssh` has with `ssh -G`, which
parses the config and connects to nothing.

Then:

```
mavsuser@localhost: Permission denied (publickey,keyboard-interactive).
```

**The key was Ed25519. 10.9 ships OpenSSH 6.2; Ed25519 arrived in 6.5, in
January 2014, three months after Mavericks shipped.** The guest's sshd
cannot parse that line in `authorized_keys`, so a server that is otherwise
working perfectly — running, account created, user in the access group —
says nothing more useful than "Permission denied".

`build-firstboot-pkg.sh` now refuses an Ed25519 key with a message naming
both version numbers, `--generate-ssh-key` makes a 4096-bit RSA key, and
`tests/payload.bats` covers both. The check costs a second; finding it out
cost an install.

This is the same shape as the `usb-tablet` mistake recorded in
`docs/install-log.md`, in the other direction: there, a 2016 limitation had
been fixed upstream and we believed it anyway. Here, a 2026 default is
correct for 2026 and wrong for the guest. **Anything crossing the gap
between the host's software and a 2013 guest's needs its date checked in
both directions.**

### The LaunchDaemon did not remove itself, and the second guard is why that was harmless

The run that finally reached SSH also showed this, on the built image:

```
$ ls /Library/LaunchDaemons/ | grep mqg
com.mqg.firstboot.plist
```

Still there. The log's last line was `removing the LaunchDaemon so this
never runs again`, and then nothing — no `done`, no `killall loginwindow`.

The cause is the line after it: **`launchctl unload "$DAEMON"` unloads the
job that is running this script, which terminates the script**, so the `rm
-f` on the next line never ran. Removing a daemon from inside itself has an
order, and it is: delete the file, do not unload.

What made this harmless rather than the fault the header warns about is the
`.done` marker, written *before* the removal. The next boot's log reads:

```
2026-09-18T04:06:03Z mqg-firstboot: already ran (marker ... exists); doing nothing
```

Two independent guards were written because "a first-boot script that runs
on every boot silently undoes manual changes forever". One of them broke on
the first real run, and the other one held. That is the argument for having
both, made by events rather than by assertion.

`stage_verify` in `image/build-image.sh` now reports
`firstboot-daemon=removed` or `STILL-THERE`, and warns on the latter, so
this cannot regress quietly.

### There is no unprivileged clean shutdown for this guest

The pipeline has to stop the VM it started. Three ways were tried:

| Way | Result |
|---|---|
| QEMU monitor `system_powerdown` (ACPI power button) at the login window | **Nothing at all.** Tested with a screenshot either side: same login window sixty seconds later. No dialog, no shutdown. |
| the same, with a session logged in | 10.9 raises a modal "Are you sure you want to shut down?" and waits for a mouse nobody is driving |
| `shutdown -h now` over SSH | needs root, and the guest account has no password by design |

So `power_down_vm` syncs the guest, asks over ACPI anyway, waits a minute,
and then terminates QEMU. **That is a power cut**, and it is survivable by
construction rather than by hope: the target volume is journalled HFS+
(docs/install-log.md step 8), QEMU flushes and closes the qcow2 on SIGTERM,
and macOS replays the journal on the next mount. The assumption is under
standing test, because `image/compare-images.sh` boots every image again
afterwards, every time.

The obvious fix — passwordless `sudo` for the guest account — was
considered and not taken. It widens what anyone who reaches the account can
do, for the benefit of a tidier shutdown on a volume that survives the
untidy one. If a later phase needs privileged commands over SSH (P5 might),
that is the decision to revisit, with its own entry.

## 2026-09-18 — P4 Task 7 — `image/build-image.sh`, and what each stage costs

**One command, clean checkout to a bootable SSH-reachable image, nobody
watching.** That is goal #2, and this is it.

`image/build-image.sh` reimplements nothing. Every stage is a script that
already existed and was already tested; what is new is the ordering, the
skipping, the QEMU invocation, and the manifest.

| Stage | What it runs | Skipped when |
|---|---|---|
| `esd` | `media/fetch-installesd.sh` | `InstallESD.dmg` is there |
| `opencore` | `boot/fetch-*.sh`, `boot/build-opencore.sh` | `artifacts/SHA256SUMS` is there |
| `ovmf` | `boot/build-ovmf.sh` | `OVMF_CODE.fd` is there |
| `efi` | `boot/build-efi-image.sh` | the EFI image is there |
| `payload` | `image/payload/build-firstboot-pkg.sh` | never — it is milliseconds and deterministic |
| `media` | `media/build-installer-img.sh --autoinstall --firstboot-pkg` | the media is there |
| `target` | `qemu-img create`, plus this VM's own EFI variable store | the qcow2 is there |
| `install` | boots it, waits for SSH | the `installed` stamp is there |
| `verify` | asks the guest what it is, over SSH | never |
| `manifest` | writes `<name>.manifest` | never |

`--force` redoes them anyway; `--from STAGE` and `--stage STAGE` pick up
where a failure left off. A pipeline that cannot resume gets debugged an
hour at a time.

### The hardware is a parameter, because P6 is the second consumer

`--accel kvm|tcg`, `--machine`, `--cpu`, `--ram`, `--smp`, `--disk-gb`,
`--qemu`. P6 runs this same pipeline under TCG on arm64, and a second
pipeline would be a second thing to keep correct.

The QEMU command line is built by the script rather than read from
`vm/profiles/`. That is deliberate and it is the one place this duplicates
something: a profile is a flat list of arguments, which is exactly what
makes a profile diff an experiment, and exactly what makes it unable to
take parameters. `bin/tier-check.sh` still covers the profiles;
`tests/image.bats` covers this script separately, including that it never
names the Tier 2 quarantine.

### SSH: the first time this project reaches into the guest

`-netdev user,id=net0,hostfwd=tcp::2222-:22`. One line, and it changes what
"done" can mean: before it, the only way to know what the guest was doing
was to photograph its screen.

`vm/screenshot.sh` is still used, every two minutes during the install,
because it answers a different question — whether the install is *making
progress*. Its verdict line is the honest one: a colour count of 2 is
white-on-black **text**, not a blank screen, and reading that wrong cost an
hour earlier in this project.

### The manifest

`<name>.manifest` records the checksum of Apple's `InstallESD.dmg`, of the
media built from it, of the OpenCore EFI image, of the firmware, of
`config.plist`, of the payload package, the fingerprint of the authorized
key, the `--updates` selection, the hardware parameters, the QEMU version,
the git commit and whether the tree was dirty, and the checksum and size of
the qcow2 produced.

`--updates` has exactly one value implemented, `none`.
`docs/open-questions.md` Q1 names P4 as its deadline and this does not
answer it. What it does is keep it answerable: the switch, the manifest
field and the `OSInstall.collection` mechanism an answer would use are all
in place, so answering it is configuration rather than a rewrite.

### The progress report killed the thing it was reporting on

The second run died at the two-minute mark and took QEMU with it. The line:

```sh
shot=$(... vm/screenshot.sh "$name-t$elapsed" 2>&1 | head -1)
```

`head -1` closes the pipe after one line; `screenshot.sh` takes SIGPIPE;
`set -o pipefail` reports 141; and a command substitution that fails in an
**assignment** is fatal under `set -e`. The cleanup trap then killed the
VM, exactly as designed, for a failure that was nothing to do with the
install.

`sed -n 1p` instead, which reads its input to the end, plus `|| shot="(no
screenshot)"`. Progress reporting must not be able to end the thing it is
reporting on, and the belt is worth having even with the braces.

Cost: ten minutes and one install. Worth writing down because the failure
mode is invisible in the code — every piece of it is idiomatic, and the
interaction is what bites.


### Measured, on this host

Build A, from a state with the media and the target disk deleted:

| Stage | Wall clock |
|---|---|
| `esd`, `opencore`, `ovmf`, `efi`, `payload` | 0 s each (already built; the payload is milliseconds and deterministic) |
| `media` | **54 s**, plus about 100 s of `dmg2img` before it |
| `target` | 0 s |
| `install` | **817 s** -- SSH answered 780 s after the VM started |
| `verify` | 62 s (boots the image again, without the installer media) |
| `manifest` | 44 s |
| **total** | **977 s, 16 min 17 s** |

Build B, the same from scratch: **991 s**, SSH at **780 s** -- the same
number to the second.

For P6's job budget: a cold build on a machine with nothing cached adds the
OpenCore build (about 2 min 30 s, measured in P3) and the OVMF build, plus
the InstallESD download. Under TCG rather than KVM the install will be the
part that grows, and it is already 80% of the time.

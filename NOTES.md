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

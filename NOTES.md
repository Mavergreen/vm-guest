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

## 2026-09-18 — P4 Task 8 — two builds, one fresh clone, and what "the same" means

`image/compare-images.sh` is the method, `--describe` prints it, and
`docs/decisions/0006-image-pipeline-reproducibility.md` is the argument. An
unstated comparison method is not reproducible either, which is why the
method is a program.

**The claim is not byte-identity and never was.** An install writes
timestamps, a volume UUID, a machine UUID, caches built at first boot,
Spotlight indexes, random seeds and SSH host keys; a sparse qcow2 records
the order the installer happened to allocate blocks in. Two builds from
identical inputs differ in all of that, and none of it is a difference
anyone can observe from inside the guest.

What is claimed, and checked separately so a failure names itself:

1. both manifests list identical inputs, bar `name`, `built` and `image`;
2. both boot unattended, **with no installer media attached**, and accept
   SSH with the key they were built for;
3. `sw_vers`, `hw.model`, `hw.ncpu`, `hw.memsize`, the account's uid, gid
   and groups, Remote Login, sleep, auto-login, `.AppleSetupDone`, and that
   the first-boot LaunchDaemon removed itself, all match;
4. the installed file sets match — same paths, same sizes — outside the
   prefixes an install is expected to vary, which are listed in the script
   rather than buried in a pipeline.

### First comparison: 321,104 files, identical

Builds A and B, both from a deleted media and a blank target disk, 16 min
17 s and 16 min 31 s, SSH answering at **780 s in both**.

| Check | Result |
|---|---|
| boot and SSH | **SAME** — both booted with no installer media attached and accepted the key |
| identity | **SAME** — 10.9.5 13F34, `iMac14,2`, 2 cpu, 4 GiB, uid 501 gid 20 in admin and `com.apple.access_ssh`, Remote Login on, sleep never, auto-login `mavsuser`, `.AppleSetupDone` present, first-boot daemon **removed** |
| file sets | **SAME** — 321,104 files each, **zero** differing paths, **zero** differing sizes |
| manifests | **DIFFER**, in two fields, and both were defects this comparison found |

The only line that varies in the identity check is when the first-boot
payload ran, which is a clock reading.

Before the exclusion list was right, the raw comparison found exactly
**seven differing files out of 321,130** — and each one was a per-machine
identity nobody had thought to list: CrashReporter's
`AnonymousIdentifier_<UUID>.plist` (a fresh UUID in the filename),
`System.keychain` and `apsd.keychain` (8 bytes apart),
`com.apple.PowerManagement.plist`, and `ssh_host_dsa_key`. An image that
shipped identical SSH host keys would be the defect, not the variation.
They are in `EXCLUDE_PREFIXES` now, with that reasoning next to them.

**Filtering moved from collection time to comparison time** because of
this: the exclusion list is the part most likely to need changing, and
re-collecting means booting two VMs for five minutes to learn nothing new.
`inventory.raw` is what was observed; `inventory.txt` is the reading of it.

### The two manifest differences were both real defects

**`opencore` differed between two builds that used the same bootloader.**
The EFI image is attached to the VM read-write, and something in the guest
writes to it on every boot: built as `ba9eab36`, `7f4ce3aa` after one run,
`0ad83718` after the next, `11c5ca9a` after the one after that. So P3's
pinned checksum for the boot stack stopped matching the file on disk the
first time anyone booted it, and the manifest was recording a
post-run value as though it were an input.

`snapshot=on` on that drive: the guest may write, and QEMU throws the
writes away at exit. The manifest reads the `.sha256` that
`boot/build-efi-image.sh` wrote beside the image, which is the artifact as
built rather than as last run.

**`media` differs and always will.** `mkfs.hfsplus` stamps the volume's
creation date from the clock, mounting an HFS+ volume rewrites its header,
and catalog layout follows write order. So the media file's checksum
answers "is this the exact artifact I built" and cannot answer "do two
builds contain the same thing". `media/content-digest.sh` answers the
second: one SHA-256 over a sorted list of every file's own SHA-256.
`mediacontent` is in the manifest and is *not* on the expected-to-vary
list.

### The finding that mattered most: a corrupt package the checks missed

Three media builds in six put a corrupt copy of Apple's `Essentials.pkg`
on the media. 1.3 GB, the largest file there. The install ran for several
minutes and then stopped:

```
BOMCopierFatalError ... offset=13899638, sourcePath=.../Essentials.pkg
    "cpio read error: bad file format"              (build B)
    "FinishStreamCompressorQueue error (-1)"        (build D)
```

**The same offset in both.** That is not random corruption; it is the same
wrong bytes in the same place, twice.

What makes this worth writing down is the shape of the mistake in the
first fix. The check added after build B compared the ESD's copy with the
media's while **both were mounted** — and it passed, on a build whose
media was corrupt, because it read the page cache of the mount that had
just written the file. `7z t` on the same package through a *later* mount
failed. **Verification that shares a cache with the thing it verifies is
not verification.**

So the checksums are recorded from the ESD during the copy, and checked
after the volume is unmounted and the ownership pass has run, on a fresh
mount, where the bytes come off the disk. That also covers the privops
microVM, which the first version did not.

The cause is not established. The Linux hfsplus driver is the only thing
in the chain that could be writing the wrong bytes, the file that fails is
always the largest, and 128 MiB of margin left the volume 99% full — so
the margin is now 512 MiB, labelled as a guess. The verification is what
actually makes the pipeline safe either way, and it costs about ten
seconds.

**One of the failures was self-inflicted and is worth admitting**: killing
`image/build-image.sh` leaves its child scripts running, and an orphaned
`media/build-installer-img.sh` was found still rsyncing into the same
image a newer build had started writing. `build-image.sh`'s cleanup trap
kills QEMU and nothing else. Any conclusion about the failure rate has to
allow for that.

### Running the pipeline from a fresh clone found a constraint nobody had

EDK II refuses to build when the path to a debug symbol exceeds 255 bytes:

```
ERROR: Debug symbol path exceeds maximum allowed range of 255 bytes!
```

The first fresh-clone attempt put `MQG_IMAGE_DIR` under a long scratch
path, and the OpenCore build failed **ten minutes in**, after compiling
most of EDK II. Its own deepest module path
(`MdeModulePkg/Bus/Isa/Ps2MouseDxe/...`) is about 125 characters, so the
build directory has to be well short of that. `image/build-image.sh`
checks it in a millisecond now, and says which limit and why.

This is exactly what the fresh-clone test is for, and it is the kind of
thing it finds: not a bug in the code, but an assumption about the
environment that the working copy happened to satisfy.

### The boot stack is rebuildable, but not byte-for-byte

The fresh clone built its own OpenCore and its own firmware, from the same
pinned sources, and got **different bytes**:

| Artifact | This working copy | Fresh clone |
|---|---|---|
| `OVMF_CODE.fd` | `195c4dcf…` (the value `docs/decisions/0004` records) | `deee45dd…` |
| `opencore-p3.img` | `ba9eab36…` | `c54caf29…` |

This does not contradict P3 — the claim there is that the boot stack is
**rebuildable from pinned source**, and it was, on a machine that had never
seen this project, in 174 seconds. But it does mean the checksums in
`decisions/0004` identify *this host's build* rather than *the source*, and
anyone checking them on another machine will find they do not match and
will reasonably wonder what is wrong.

Two separate causes, neither surprising once looked at:

- **EDK II stamps its build into the firmware.** Build timestamps and
  absolute paths end up inside the firmware volume.
- **`mformat` writes a volume serial number** into the EFI image's FAT
  header, and `mcopy` carries file mtimes.

Both are fixable in principle (`SOURCE_DATE_EPOCH`, a fixed FAT serial),
and neither is fixed here. What P4 needs is that the manifest says which
build went into an image, and it does. Recorded as an open item rather than
repaired in passing: doing it properly means re-verifying that a
deterministic firmware still boots, which is a P3 question.

### Two macOS installs at once wedged one of them

The fresh-clone build and a local build were started together, to halve the
wall clock. The local one finished in 1147 s -- slower than its usual 977 s,
as expected. The fresh-clone one **stopped writing to its target disk
entirely** 6 minutes in, with the installer's progress bar at about 20% and
"about 19 minutes remaining" frozen there for the next 43 minutes, QEMU
still burning 23% of a core.

Run alone afterwards, the same fresh clone built cleanly in **940 s**.

**What it is not.** Memory is ruled out: the host has 62 GiB, 8 in use and
54 available, against two 4 GiB guests. Disk space is ruled out: 1.6 TiB
free. A shared path is ruled out: the two builds had separate
`MQG_IMAGE_DIR`s (`~/mqg-fresh-img` and `~/.local/share/...`), separate
monitor sockets, separate forwarded ports, separate NVRAM copies and
separate target disks; nothing under either directory is named by the
other. The privops microVM is ruled out by timing -- both media builds had
finished, minutes before either install started.

**What I think it is, labelled as a guess: I/O, not `/dev/kvm`.** The
evidence that points there is that the guest was not wedged as a whole --
the installer's progress spinner kept animating in every screenshot, so the
GUI and the scheduler were alive -- while writes to the target disk stopped
completely and never resumed. That is the shape of a storage stall, not of a
starved vCPU. Two concurrent macOS installs are close to the worst case for
this host's emulated AHCI: each is streaming several gigabytes off a 6.4 GB
raw media image and writing it into a growing sparse qcow2, all four files
on the same NVMe, with the host page cache holding 48 GiB of it. If 10.9's
AHCI driver has a timeout it does not recover from, this is where it would
be found.

**What would settle it**, and was not done because the fresh-clone result
was what the phase needed: re-run the pair with `-drive ...,cache=none` or
with the two image directories on different devices, and watch
`/proc/<pid>/io` for the stalled guest rather than the file size. If it is
I/O, the guest's read counter stops too; if it is KVM, it does not.

**For P6:** do not assume two of these can share a runner. One per host
until the above is settled.

### The fresh clone, alone: it works, in 940 seconds

`git clone` into `~/mqg-fresh-clone`, `MQG_IMAGE_DIR=~/mqg-fresh-img` with
nothing in it but Apple's `InstallESD.dmg` (reflink-copied rather than
re-downloaded from Apple, which is the one shortcut taken and is an input
the manifest pins by checksum anyway).

| Stage | Wall clock |
|---|---|
| `opencore` | **174 s** — OpenCore built from pinned source on a machine that had never seen this project |
| `ovmf` | ~170 s |
| `efi`, `payload` | seconds |
| `media` | **84 s** |
| `install` | **816 s** — SSH answered |
| `verify` | 62 s |
| `manifest` | 62 s |
| **total** (second run, everything but the install already built) | **940 s** |

`firstboot-daemon=removed`, `setupdone=yes`, `autologin=mavsuser`, the
account exactly as on the local builds. **The repository carries everything
needed.**

### And the media the fresh clone built is the same media

```
$ ./media/content-digest.sh ~/.local/share/mavericks-qemu-guest/media/installer-linux.img
439c32a2fcb05104aa8f09311e272ea7c23faf2a877492e602c3786f543a05f5  39413 files  6415404902 bytes  1 unreadable
$ ./media/content-digest.sh ~/mqg-fresh-img/media/installer-linux.img
439c32a2fcb05104aa8f09311e272ea7c23faf2a877492e602c3786f543a05f5  39413 files  6415404902 bytes  1 unreadable
```

Byte-for-byte the same content, from two working copies, on two image
directories, hours apart. The media *files* differ, as they always will.

Getting to that number found one more input the guest mutates. The first
comparison of the two digests differed in exactly 41 files, all of them
under `.Spotlight-V100/` with a different UUID in the directory name:
**macOS writes a Spotlight store onto the installer media while it boots
from it.** The installer media is attached `ide-hd` read-write, so it could.

`snapshot=on` on that drive too, beside the OpenCore one — the guest may
write, QEMU throws the writes away — and `media/content-digest.sh` prunes
`.Spotlight-V100`, `.fseventsd` and `.Trashes`, which are things a volume
accumulates rather than content of it.

That is now **three** inputs found to be mutated by the run that consumed
them: the bootloader image, the installer media, and (harmlessly) the EFI
variable store, which `boot/make-nvram.sh` already copies per VM. The
pattern is worth stating plainly: **anything handed to QEMU without
`snapshot=on` or `readonly=on` is writable, and a guest will write to more
of it than you expect.**

### The fresh-clone image against a local one, by the stated method

```
$ ./image/compare-images.sh mavericks-c mavericks-d
```

`mavericks-c` built in `~/mqg-fresh-clone` with `MQG_IMAGE_DIR=~/mqg-fresh-img`;
`mavericks-d` built in this working copy. Both at commit `61884ef`, clean.

| Check | Result |
|---|---|
| 2. boot and SSH | **SAME** — the fresh-clone image answered SSH **40 s** after the VM started, with no installer media attached, using the key it was built for |
| 3. identity | **SAME** — every line but the clock reading of when the payload ran |
| 4. installed file sets | **SAME** — 321,104 files each, **0** paths only in one, **0** differing sizes |
| 1. inputs | **DIFFER**, in `opencore` and `ovmf` only |

`mediacontent` matches exactly, which is the useful half of check 1: the two
builds' installer media contain the same thing. What differs is the boot
stack, because EDK II and `mformat` are not byte-reproducible — recorded
above, and not repaired here because making the firmware deterministic means
re-verifying that a deterministic firmware still boots, which is a P3
question rather than a P4 one.

So the two images were built with *different builds of the same source*, and
are nonetheless the same image by every behavioural test. That is a stronger
result than the one the method was designed to produce, and it is worth
being explicit that it is also a weaker guarantee: `decisions/0006` claims
"same inputs, same behaviour", and here the inputs were not quite the same.

### `./bin/run-tests.sh` from a true fresh clone

263 tests, shellcheck clean, `tier-check --strict` clean, exit 0, in a
directory cloned five minutes earlier that had never had anything built in
it. That is the check that catches "this working copy accumulated
something", and it did not fire.

---

## 2026-09-19 — P4 — bash 3.2 floor, and a lint to hold it

### Why, and what the rule is *not*

Stock OS X 10.9 ships `/bin/bash` 3.2.57 — the last GPLv2 release, frozen by
Apple in 2007. The sibling project `mavericks-vm-host` will back-port
Hypervisor.framework to 10.9 and ship a prepackaged QEMU alongside it, so
modern QEMU gets hardware acceleration there (both halves matter — see
`docs/test-hosts.md`), and the obvious next thing anyone will want is to run
*this* project's host-side CLI on a Mavericks host, to build and run a
Mavericks guest. That option costs
about fifteen lines today and a great deal more after a year of accumulated
bash 4 habits.

Worth stating plainly, because a future reader will otherwise either
over-apply this or delete it: **the floor is not "we only support bash 3.2".**
Every shebang here is `#!/usr/bin/env bash`, so a pkgsrc or Homebrew bash 5
earlier in `PATH` satisfies every script regardless of what is in `/bin`. The
rule binds against exactly one thing — *what Apple shipped* — and says a 10.9
user who has not installed a newer bash can still run these scripts. It has
nothing to say about anything but shell syntax.

### What changed

- **`mapfile` → `while IFS= read -r` fed by `< <(...)`**, the idiom already in
  `bin/tier-check.sh`, including its skip of empty lines. Every generator fed
  to one of these (`profile_expand`, `qemu_args`, `ssh_opts`, `artifact_names`,
  `_nvram_env`, `--show-pins | cut`) was checked first: none emits a blank
  line, so the skip is semantically inert and only prevents a stray blank from
  becoming an empty QEMU argument.
- **`declare -A SUB_TARBALL` → parallel arrays plus a linear `sub_tarball`
  lookup** in `boot/build-opencore.sh`. A dozen entries looked up a dozen times
  does not need a hash. Parallel arrays rather than a packed `name<TAB>path`
  string because the values are filesystem paths, and packing makes the
  delimiter one more character that must never appear in one. `show_pins()`
  right above dedupes the same list with a `seen` string and a `case`; that is
  the right shape when the answer is yes-or-no, but here the value is wanted
  back.
- **`bin/bash32-check.sh`**, wired into `bin/run-tests.sh` beside `tier-check`.
  Mandatory, not optional: it needs nothing installed, and it fails the suite
  rather than warning.

### Three surprises

**1. The survey was one short, and it was the test runner.** `bin/run-tests.sh`
used `mapfile` to collect its own shellcheck file list. Fifteen uses, not
fourteen. Worth the habit of re-grepping a handed-over list.

**2. The real bash 3.2 break was not on the list at all.** Before bash 4.4,
expanding an **empty** array under `set -u` — `"${arr[@]}"` — is an "unbound
variable" error rather than nothing. Every script here runs `set -euo
pipefail`. Three sites would have aborted on stock 10.9 bash:
`tier-check.sh`'s `names` with no profiles (it would have died *instead of*
reaching its own "nothing was checked" warning), `build-image.sh`'s `idopt`
with no ssh key, `build-installer-img.sh`'s `excludes` when every file was
readable. All three now use `${arr[@]+"${arr[@]}"}`. `boot/prereqs.sh` already
had `${missing_pkgs[*]-}`, so somebody has met this before and the lesson did
not travel. No textual check can tell which arrays can be empty, so
`bash32-check.sh` documents this as a limit instead of pretending to catch it.

**3. A lint for bash-4 syntax cannot avoid containing bash-4 syntax.** The
pattern table has to spell out the words it looks for, and the test file has to
spell out every construct it expects to be caught. Both would be the first
thing the check reported. Solved with a `bash32-allow` inline marker plus
skipping comment lines outright — the latter also keeps the comments explaining
*why* a file stopped using `mapfile` from holding the check red forever. In the
test file the marker has to sit on the `.bats` line and not inside the fixture
text, or the check would skip the fixture and the test would pass for the wrong
reason; that is why fixtures are built one line at a time through `_line`
rather than with a heredoc.

A fourth, smaller one: a comment whose first word is shellcheck's own name is
parsed as a directive, so a sentence *about* shellcheck fails the file with
SC1073.

### Why not shellcheck

Tried first. As of 0.9 there is no bash-version floor to express: `--shell`
selects a dialect (`sh`, `bash`, `dash`, `ksh`), not a version, and the SC3xxx
portability checks are all-or-nothing against `sh` — turning them on would
reject the bash 3.2 features this project does use and rightly wants. Hence a
grep-shaped check in the spirit of `bin/tier-check.sh`.

It matches **in-process** with `[[ =~ ]]` — no grep, no pipe — for the reason
`bin/tier-check.sh:57-64` records at length: `grep -q` exits the moment it
matches, SIGPIPEs the still-writing producer, and under `set -o pipefail` the
pipeline reports 141, so the `if` takes the *false* branch **because** the
match succeeded. That made an earlier gate fail open exactly when it found a
violation, and only for inputs long enough that the writer had not finished.
The test "bash32-check reports a violation late in a long file" (2000 lines of
filler, then `declare -A`) is what would catch that regression here.

### Proving the gate fires

A gate nobody has seen fire is a gate nobody knows works. All fifteen patterns
were exercised against a fixture; `tests/bash32.bats` keeps fourteen of those
checks. Then the whole thing end to end:

```
$ printf 'declare -A regression=()\n' >> vm/run.sh
$ ./bin/run-tests.sh >/dev/null 2>&1; echo $?
1
$ ./bin/bash32-check.sh
BASH4  vm/run.sh:69: bash 4.0 associative array: use parallel arrays plus a lookup, or a `case`
mqg: error: the lines above use bash features newer than 3.2 ...
$ git checkout vm/run.sh && ./bin/run-tests.sh >/dev/null 2>&1; echo $?
0
```

It fails the **suite**, not just the script — which was the requirement.

`./bin/run-tests.sh`: **277 tests** (263 + 14), shellcheck clean,
`tier-check --strict` clean, `bash32-check` clean over 51 shell files, exit 0.
The check adds about 2 s to the run; it tests each line against one combined
alternation first and only falls through to the fifteen individual patterns on
a line that matches, which took it from 4.3 s to 2.2 s.

### Still open

Nothing here was *run* under a real bash 3.2 — none was available on this host.
The check is textual and the reasoning is from the bash CHANGES file. A genuine
3.2 smoke test belongs on the first 10.9 host that exists.

## 2026-09-19 — Task 34 — the media corruption: the offset was never a clue

Three media builds in six put a corrupt `Essentials.pkg` on the media, and
the whole theory of the cause rested on one observation:

```
BOMCopierFatalError ... offset=13899638, sourcePath=.../Essentials.pkg
```

**twice at the same offset.** Bit rot does not repeat an offset, so a
repeating offset means a structure — a boundary, an extent edge, a counter
that wraps. That was the reasoning, and it is wrong, because of what the
number is.

### 13,899,638 is where Apple's `Payload` member starts

A flat package is a xar archive: a 28-byte header, a zlib-compressed table
of contents, then a heap holding the members. For `Essentials.pkg`:

| | |
|---|---|
| header size | 28 |
| compressed TOC | 809 |
| heap starts at | 28 + 809 = **837** |
| `Payload` heap offset (from the TOC) | 13,898,801 |
| `Payload` at byte | 837 + 13,898,801 = **13,899,638** |

The installer's `offset=` is the offset of the **member it was reading**,
not the position at which reading failed. It is a constant of that package
file. It repeats because `Essentials.pkg` repeats — any failure to read
that payload, from any cause, at any position in its 3.2 GB, reports
exactly 13899638.

**The same finding, again, in this project's own history.** The
`mqg-firstboot.pkg` failure recorded in the P4 Task 6 entry above reads
`offset=813`, and that entry reads it as "813 bytes into the cpio". Take
the built package apart the same way: heap at 495, `Scripts` at heap
offset 319, so `Scripts` begins at byte **814** — one byte from the
reported 813, which is what a one-byte difference in the compressed TOC
does when the cpio mode fields change. The number was the member offset
that time too. The fix made then was still the right one, for reasons that
had nothing to do with the offset.

So: **there is no evidence that the corruption ever recurred at a
particular place.** There was never a reproducing offset to explain. Every
hypothesis that started from "what is at that offset" — an HFS+ allocation
boundary, an extent edge, a 2 GiB limit, a write path that changes
strategy at a size — was answering a question the evidence never asked.

### Why it is always the largest file, and that is not a clue either

Two reasons, and neither is about size *causing* corruption:

- **It is half the media.** `Essentials.pkg` is 3,218,081,872 bytes of
  about 6.4 GB of content. Corruption landing uniformly anywhere in the
  content lands in that one file about half the time.
- **It is the only file that screams.** Its `Payload` is a single bzip2
  stream (`BZh91AY&SY`, 3,204,174,882 bytes, stored raw in the xar). One
  wrong bit anywhere in it fails the whole decompression, and the
  installer stops. A wrong byte in almost anything else on this media —
  a string in a framework, a pixel in an icon — is never noticed by
  anybody.

`Essentials.pkg` is simultaneously the biggest target and the loudest
alarm. That is enough to explain "always the largest file" without any
size-dependent code path existing at all.

### How this was established, and what else it settled

`media/verify-installer-img.sh` reads images with `7z`. For this, the
media was read with a purpose-built HFS+ reader (about 200 lines of
Python, `pread` straight into the image file) that shares no cache, no
mount and no code with the Linux `hfsplus` driver — the third independent
reader of this media, after the kernel's and 7z's.

With it, two things that were previously assumed are now measured:

- **Apple's `Essentials.pkg` is
  `a0609f3d43e7cbe293af242b02dc21d5f7182642b8e21d1ef867f06b519308e7`**,
  identical in the Mac-produced `InstallMavericks.iso` and in the media
  this project builds. That is ground truth, from a copy that never went
  through `dmg2img`, a Linux mount or an rsync.
- **The current media matches the Mac reference exactly**: 40,192 paths
  present in both images, zero SHA-256 mismatches.
- On a 512 MiB-margin build, `Essentials.pkg` occupies **one extent**
  (785,665 blocks at block 577,728). The extents overflow B-tree is
  empty — no file on this media has more than eight extents. So the
  "heavy fragmentation" half of the margin guess is not happening either,
  at least at this margin.

### What changed between the failing era and now, and what did not

The corrupt builds are 2026-09-17 and 2026-09-18. Diff the write path
across that boundary — `git diff 93e6371..HEAD -- lib/ media/` — and
`lib/hfs.sh`, `lib/privops.sh`, `lib/privops-qemu-linux.sh` and
`media/privops/fix-ownership.sh` are **unchanged**. Every byte of the
mechanism that builds and writes this volume is the same code that was
running when three builds in six came out corrupt. The only behavioural
change in `media/build-installer-img.sh` is the margin; everything else
added is verification, usage text and `--extra-pkg`.

So if the corruption happens at build time, building at 128 MiB puts the
machine back in exactly the failing configuration.

**But the margin's stated reason is false, and that can be shown without
building anything.** The comment says the largest file is "written into a
volume that 128 MiB of margin leaves 99% full". Read the allocation order
off a built volume — first `startBlock` per file, which is the order HFS+
handed out space — and `Essentials.pkg` is nowhere near the end:

| file | startBlock | position in the volume |
|---|---|---|
| AdditionalEssentials.pkg | 29,759 | 1.7% |
| AdditionalSpeechVoices.pkg | 327,173 | 18.9% |
| BSD.pkg | 433,444 | 25.1% |
| BaseSystemBinaries.pkg | 507,874 | 29.4% |
| **Essentials.pkg** | **577,728** | **33.4%** |
| MediaFiles.pkg | 1,364,004 | 78.8% |
| OxfordDictionaries.pkg | 1,448,530 | 83.7% |
| BaseSystem.dmg | 1,482,963 | 85.7% |

rsync copies `Packages/` in sorted order, so `Essentials.pkg` is the
seventh of sixteen and its last byte lands at 83.6% of a 128 MiB-margin
volume — **1.05 GiB still free**. The volume only reaches 99% about a
gigabyte of copying later, writing `MediaFiles.pkg`, `OxfordDictionaries`
and `BaseSystem.dmg`. At no margin is the largest file written into a
nearly-full volume. Free space at the moment of writing cannot be the
mechanism; only something that damages already-written blocks *later*
could be, and that is a different claim from the one recorded.

### Two host-side hypotheses disposed of by inspection

- **Mixed O_DIRECT and buffered I/O on the image file.** A loop device
  doing direct I/O on a backing file that something else reads buffered is
  a classic way to see stale bytes. Not here: `losetup -l -O DIO` on a
  udisks-created loop device reports **0**. Everything goes through the
  page cache, coherently.
- **The privops microVM not flushing before it exits.** QEMU's default for
  `-drive file=...` is `cache=writeback`, which is the *host* page cache —
  the same cache every later host read of that file uses. Data the guest
  wrote and QEMU acknowledged is visible to the host whether or not
  anything was fsynced; losing it needs a host crash, not a guest exit.
  And the guest does `sync` then `umount` before `poweroff -f`. On top of
  that, the post-unmount verification added in 82fb02d reads the media
  *after* the microVM has exited, so a microVM that lost writes would fail
  that check on every build. It does not.

### The guest could write to the media, and did

This is the one thing about the failing era that was materially different,
and it was not noticed at the time.

`snapshot=on` on the installer drive — which is what stops the guest
writing to the media file — was added on **2026-09-19** (commit 61884ef),
and for an unrelated reason: two builds from one ESD were recording
different `mediacontent` digests because the guest left a
`.Spotlight-V100` store behind. Every boot before that mounted the
installer media **read-write**.

It is still on disk. `installer-linux.img.pre-openssh`, built 2026-09-18,
carries 40 files the Mac reference does not have and the build never
wrote:

```
.Spotlight-V100/Store-V2/07A0A78F-.../store.db          102,400 bytes
.Spotlight-V100/Store-V2/07A0A78F-.../live.0.index*
.fseventsd/fseventsd-uuid
...                                     40 files, 246,075 bytes total
```

and its volume header attributes are `0x80000000` — `kHFSVolumeUnmountedBit`
clear, i.e. **the volume was never cleanly unmounted**, because the way a
build ends a VM is to kill QEMU.

So in the failing era every media image was, after it was built and
verified: mounted read-write by OS X, written to by `mds`, and then had
its power cut with the volume dirty and no journal. That is a mechanism
for corrupting a file on that volume, and it is one that operates *after*
the build's verification has passed — which is also the simplest
explanation for the thing that looked most damning at the time, a
verification that passed on media that was later found corrupt.

What it does not explain by itself is why the failures stopped on
2026-09-18, when the margin was raised and the guest kept its write access
for another day. Hence the experiments below.

### The two failures were 1.9 GB apart, and both reported the same offset

The installer logs from both failing builds survived, in this session's
scratch area, shipped off the guest by `autoinstall.sh` at the time. They
settle the question the offset could not.

**Build B**, 2026-09-17 21:32:55 → 21:33:05:

```
PackageKit: Extracting .../Essentials.pkg (destination=..., uid=0)   21:32:55
PackageKit: Install Failed ... "cpio read error: bad file format"     21:33:05
    offset=13899638
```

Ten seconds of extraction, no file named.

**Build D**, 2026-09-17 22:39:33 → 22:42:38:

```
PackageKit: Extracting .../Essentials.pkg ...                         22:39:33
PackageKit: Got copier error 2 extracting to path
            ./System/Library/LinguisticData/zh/lm.dat: No such file    22:42:38
PackageKit: Install Failed ... "FinishStreamCompressorQueue error (-1)"
    offset=13899638
```

**Three minutes and five seconds**, and this one names where it was. Find
that path in Apple's own payload — decompress the bzip2 stream and look:

| | |
|---|---|
| cpio-stream offset of `LinguisticData/zh/lm.dat` | 3,913,347,947 (3.64 GiB) |
| position in the compressed payload | 61.7% |
| byte offset in `Essentials.pkg` | about 1,989,000,000 |

Build D's stream broke about **1.99 GB** into the package. Build B's broke
after ten seconds of an extraction that took D 185 seconds to get 61.7%
through — call it three percent, about **110 MB** in.

**Two failures, roughly 1.9 GB apart in the same file, both reporting
`offset=13899638`.** There is no clearer demonstration that the number is a
constant of the package and not a measurement, and no clearer
demonstration that the corruption is in a *different place every time*.

That rules out the whole class of hypotheses the offset invited: a
boundary, an extent edge, a size limit, a write path that changes
strategy. A fault that lands 110 MB into one file and 1.99 GB into the
next copy of it is not a code path being taken; it is an event happening
somewhere.

**And it means the observed failure rate understates the event rate.**
`Essentials.pkg` is 3.2 GB of 6.4 GB of content, so an event landing
uniformly in the media's data is noticed about half the time and is
silent the other half — landing in a font, a framework resource, an icon,
where nothing ever checks. Three noticed failures in six builds is
consistent with something like one corrupting event per build, half of
them invisible. Which is why the experiment below checks **every file on
the media** against Apple's reference, not just the sixteen packages: it
is about twice as sensitive as the thing that found the bug.

### What was happening to the image file while those builds ran

The failing era's scratch directory survived too, and its timestamps are
what the corrupt-media question actually needed.

**`inject.sh`.** A hand tool, written to iterate on the first-boot package
without a twenty-minute media rebuild. It does this to
`media/installer-linux.img`:

```
hfs_with_mounted_part "$IMG" 1 doit    # loop-mount, cp three files, unmount
sync
privops_run "$IMG" .../fix-ownership.sh   # a microVM that chowns EVERY inode
```

`inject4.log` — its own live output — finished at **22:39:35** on
2026-09-17. Build D's guest had booted from that same image file at
22:37:43 and its installer began extracting `Essentials.pkg` from it at
**22:39:33**, two seconds earlier. So while a macOS guest was reading the
media, the host had loop-mounted the same file, written into it, and then
run a second QEMU that mounted it again and rewrote every catalog record
on it.

**`verify.log`**, 21:34:07 — one minute after build B's installer failed:

```
qemu-system-x86_64: terminating on signal 15 from pid 693842 (/bin/bash)
to get "write" lock
Is another process using the image [.../work/opencore-p3.img]?
```

QEMU's own image locking, refusing to start because another process had
the image open. Two VM runs overlapping, caught by the one component in
this chain that checks.

And the third instance is already written down above: an orphaned
`media/build-installer-img.sh`, left running when `image/build-image.sh`
was killed, still rsyncing into the image a newer build had started
writing.

### The conclusion, and how confident it is

**The media was corrupted by concurrent access to the image file, not by
the code that builds it.** The evidence:

1. Three separate instances of concurrent use of that file are recorded in
   the era's own logs — an orphaned builder, a hand tool mounting and
   chowning the image under a running guest, and QEMU refusing a second
   VM's write lock. None of them was rare; that was the working style.
2. The corruption lands in a different place every time — 110 MB into
   `Essentials.pkg` in one build, 1.99 GB in the next. Interleaved writers
   do that. A code path does not.
3. A verification that read back through the writing mount passed on media
   that a later mount found corrupt. Two loop devices over one backing file
   give each writer its own block-device page cache: each reads back
   exactly what it wrote, and the file on disk is a mix. That symptom is
   almost diagnostic on its own.
4. Nothing in the write path changed when the failures stopped. What
   changed was the working style: the pipeline became one command run end
   to end, the media got `snapshot=on` so the guest cannot write to it, and
   nobody hand-injects into mounted media any more.
5. **Ten builds at the failing era's exact geometry, on an idle host, one
   at a time, produced byte-perfect media every time** — see the experiment
   below. At the observed rate that is about a one-in-a-thousand
   coincidence. The build, run alone, does not do this.

**Confidence: high for the mechanism, not certain for every one of the
three builds.** Build D is documented almost to the second. Build B has
overlapping VM runs a minute away but nothing that names the media file.
The third failure is the admitted orphan. What cannot be ruled out is that
one of the three had some other cause; what can be ruled out is the whole
family of explanations the offset invited.

**The free-space margin is not the cause, and its stated reason is wrong.**
Kept at 512 MiB anyway — it costs nothing in a sparse file and nothing in
the evidence makes it load-bearing.

**Two sections below correct this one**, and they are not optional reading:
the build-D timeline does not reconcile with QEMU's own image locking, and
the "two loop devices, two page caches" explanation turns out to be
something the kernel already prevents. The conclusion survives both; the
reasoning changes.

### Every hypothesis, and what killed it

Written down including — especially including — the ones that died, because
the margin was believed for a year of commits on no evidence at all and the
only way that does not happen again is if the disproofs are as findable as
the conclusion.

| # | Hypothesis | Verdict | What settled it |
|---|---|---|---|
| 1 | The corruption recurs at a fixed offset, so something structural is at 13,899,638 | **Dead** | 13,899,638 is where Apple's `Payload` member begins in `Essentials.pkg` (28 + 809 + 13,898,801). It is a constant of the file. Confirmed twice more: the same number is reported for two failures 1.9 GB apart, and this project's own `offset=813` is where `Scripts` begins in `mqg-firstboot.pkg` |
| 2 | An HFS+ allocation-block or extent boundary | **Dead** | Needs a fixed offset; there isn't one. Also: `Essentials.pkg` is a **single extent** and the volume's extents-overflow B-tree is empty, so the multi-extent path is never entered |
| 3 | A 2 GiB or 4 GiB limit, or a write path that switches strategy by size | **Dead** | Same. And the two observed breaks are at about 110 MB and about 1.99 GB into the same file |
| 4 | Free space at write time — the 128 MiB margin | **Dead, by arithmetic and by experiment** | Ten builds at 128 MiB produced byte-perfect media, 401,920 file comparisons, zero mismatches (below). And rsync writes `Essentials.pkg` seventh of sixteen: it starts at 33.4% of the volume and ends at 83.6%, with 1.05 GiB still free at 128 MiB of margin. The volume only reaches 99% a gigabyte later, and by then the file is written. Mitigation kept anyway; it costs nothing |
| 5 | Heavy fragmentation near ENOSPC | **Dead** | Nothing on the media has more than eight extents; the largest file has one |
| 6 | It is the largest file *because* it is the largest — a size-dependent code path | **Dead** | It is the largest file because it is half the bytes on the media, so half of anything uniformly placed lands in it, and because its payload is one bzip2 stream, so it is the only file that notices a wrong bit |
| 7 | The privops microVM exits without flushing | **Dead** | QEMU's default `cache=writeback` is the host page cache, which is what every later host read uses; the guest `sync`s and `umount`s first; and the post-unmount verification would fail on every build if it were true |
| 8 | Mixed O_DIRECT and buffered access to the image file | **Dead** | `losetup -l -O DIO` reports 0 for a udisks loop device |
| 9 | `dmg2img`, or the Linux hfsplus read of its output, hands back a bad byte | **Not observed, and no longer invisible** | The media now built matches Apple's reference on all 40,192 common paths. The old check could not have seen this; `media/apple-packages.sha256` now does, and names the conversion rather than the copy |
| 10 | NFS, btrfs, the loop device, host memory | **Not supported** | The repo is on NFS but no image is; two surviving media images are byte-perfect against the Mac reference. A host-level fault at roughly one event per build would not spare them |
| 11 | **Concurrent access to the image file** | **The conclusion** | Three instances in the era's own logs; corruption in a different place each time; a read-back through the writing mount passing on corrupt media, which is what two loop devices over one backing file produce |

One idea tried and abandoned: making the finished media file mode 444, so
that anything which forgot `snapshot=on` or tried to mount it read-write
would fail loudly. udisks opens a backing file read-write to set up a loop
device at all — `Error opening (rw) file ...: Permission denied` — so a
read-only media file cannot be mounted by our own `content-digest.sh` or by
the build's own verification. The guard would have cost more than it bought.

### A correction to the build-D timeline, before anyone builds on it

The build-D timeline does not close, and saying so is worth more than the
tidier story.

`inject.sh` ends by running the privops microVM, which opens
`installer-linux.img` **read-write under QEMU**. QEMU takes an image lock
when it does that — this very project has the evidence, in `verify.log`,
of QEMU refusing to start because another process held one. So if a macOS
guest really had that same file open read-write at 22:39:2x, the microVM
in `inject4.log` should have failed with exactly that error. It did not;
the log shows it mounting `/dev/vda1` and chowning the volume normally.

Either the guest whose log is `d-install.log` did not have that file
attached at that moment, or something about the locking was different. The
surviving evidence cannot say which, and there is no VM left to ask.

So the honest statement is narrower than the paragraph above:

- **Certain**: in that era the media image was routinely used by more than
  one thing. `inject.sh` loop-mounted it and chowned every inode on it
  outside any build. `mark.sh` existed to force the volume header clean so
  that the host could mount read-write media a guest had left dirty — that
  is, to defeat the one safeguard the kernel offers against exactly this
  (`inject2.log` is the run where the safeguard fired: every `cp` failed
  with "Read-only file system"). An orphaned builder was caught rsyncing
  into an image a newer build had started. QEMU refused a write lock once,
  a minute after build B failed. Two macOS guests booted 3 minutes apart
  in the window around build D's failure.
- **Not certain**: which of those was acting on which build's media, at
  which second.

The conclusion rests on the pattern and on the two independent signatures —
corruption in a different place each time, and a read-back through the
writing mount passing on media a later mount found corrupt. It does not
rest on the 22:39:35 coincidence, which is suggestive and does not
reconcile with QEMU's locking.

### Measured today: the kernel already refuses two host-side writers

Worth doing rather than assuming, and it moves the conclusion. Two loop
devices were attached to one backing file, both partitions mounted, and
both asked to write the same 8 MiB file:

```
writer A: /dev/loop0 -> /media/schmonz/Two Writers
writer B: /dev/loop1 -> /media/schmonz/Two Writers1
.../Two Writers1/payload.bin: Read-only file system
```

**The second mount comes up read-only.** Mounting an HFS+ volume clears
`kHFSVolumeUnmountedBit`; the Linux driver mounts read-only when that bit
is clear; so the second mounter is refused write access by the same
mechanism that refuses media a VM has booted. Two host-side builders
cannot both write through the Linux driver.

So the "two loop devices, two page caches" story is **not** available as a
general explanation, and the claim above that it explains the verification
passing on corrupt media is too strong. What survives is narrower and
sharper — the ways that protection can be got round:

- **`hfs_mark_clean`, and `mark.sh` beside it.** It exists to force the
  volume header clean so the host can mount read-write a volume something
  else left dirty. Its own docstring says "use it on a volume nothing was
  writing to"; in that era it was used to make `inject.sh` work on media a
  guest had booted. That is the one tool here whose whole purpose is to
  defeat the safeguard.
- **A QEMU guest**, which is not the Linux driver and does not consult it.
  In that era the media was attached `format=raw,file=...` with no
  `snapshot=on`, so OS X mounted it read-write and wrote to it — the
  `.Spotlight-V100` store is still on the media on disk.

And it makes a simpler explanation available for the thing that started
all this. The first verification passed and a later `7z t` failed. Rather
than "the check read the page cache", the media may well have been
**correct when the build finished and corrupted afterwards** — by the boot,
or by an inject-and-mark-clean cycle in between. That fits the evidence at
least as well, and it is the reading that `snapshot=on` (2026-09-19) acts
on.

Which of the two it was cannot be settled from here. Both are forms of the
same answer: something other than the build wrote to that file.

## 2026-09-19 — the guest gets the family's OpenSSH, and the repo joins the family

Two jobs, and the first one made the second concrete: consume
`ModernMavericks/openssh` the way the family's conventions say to consume a
sibling toolchain, then wire up the rest of the checklist — `INGREDIENTS.md`,
Renovate, `build/msc.sh`, the marketplace registration, and the gates.

### The defects, and why they are gone rather than worked around

P4 found both and worked around both. Stock 10.9 is OpenSSH **6.2p2**:
Ed25519 arrived in 6.5, three months after Mavericks shipped, so a modern key
in `authorized_keys` is a line the guest's sshd cannot parse — and the only
symptom is `Permission denied (publickey)` from a server that is otherwise
working perfectly. And 6.2 offers only `ssh-rsa` and `ssh-dss` host keys,
which a 2026 client refuses outright.

`ModernMavericks/openssh` had already solved this: **OpenSSH 10.5p1**, built
for 10.9, published as two product archives per release. The sibling's README
still says 9.9p2; the tags are right and the prose is stale, which is worth
knowing before you read it.

### How it gets installed, and the elegant path that was not taken

The tempting shape is to list the OpenSSH packages in
`OSInstall.collection` beside `mqg-firstboot.pkg` and let Apple's installer
install them during the OS install. That is **unproven**, and two things
argue against assuming it:

* Our payload is a **payload-free script package** — `PackageInfo` and
  `Scripts`, no `Bom`, no `Payload` — which is precisely why `mkflatpkg.py`
  can build it on Linux. The OpenSSH packages are **real product archives**:
  `Distribution`, an embedded component `.pkg`, `Bom`, `Payload`, pre/post
  scripts. Whether the installer handles one of those from a collection
  mid-install is not something the collection's documented behaviour settles.
* Their `Distribution` declares `<allowed-os-versions min="10.9.5"/>`. Asking
  a half-installed target volume what OS version it is is a question with no
  good answer.

So the packages ride the media (`media/build-installer-img.sh --extra-pkg`,
**not** added to the collection), the payload's `postinstall` copies them to
`$CONF_DIR/pkgs` on the target volume at install time — the installer hands
it the full path of the package it is running, so `dirname "$1"` is exactly
where they are — and `firstboot.sh` runs `installer -pkg ... -target /` on
the booted system, where a product archive is an entirely ordinary thing to
install.

Measured on the guest: **nine seconds** for both packages.

```
13:09:08 run (900s limit): installer -verbose -pkg .../OpenSSH-10.5p1-mavericks.2.pkg -target /
         installer: The install was successful.
13:09:11 run (300s limit): installer -verbose -pkg .../OpenSSH-System-Replace-10.5p1-mavericks.2.pkg -target /
         installer: The install was successful.
13:09:17 openssh: OpenSSH_10.5p1, LibreSSL 4.3.2 is now the system ssh
```

### A defect in the sibling, found before it cost an install

**The System-Replace package, installed on stock 10.9, would leave the guest
with no working sshd at all.**

Its `postinstall` symlinks `/usr/libexec/sshd-keygen-wrapper` to
`/usr/local/libexec/sshd-keygen-wrapper`. The published 10.5p1-mavericks.2
payload contains no such file — checked by extracting the `Payload` cpio and
listing it; there are fourteen binaries and three config files under
`/usr/local`, and no wrapper. And 10.9's
`/System/Library/LaunchDaemons/ssh.plist` names that exact path as its
`Program`:

```xml
<key>Program</key>
<string>/usr/libexec/sshd-keygen-wrapper</string>
<key>ProgramArguments</key>
<array><string>/usr/sbin/sshd</string><string>-i</string></array>
```

A dangling symlink there means launchd cannot exec anything when a connection
arrives. Read off a running 10.9 guest, not inferred.

So `firstboot.sh` writes that file itself, **before** installing the
replacement, so the symlink lands on something real. Ours also does the
second thing a 10.9 guest needs: Apple's wrapper only ever generates
`rsa1`/`rsa`/`dsa` keys in `/etc`, and a modern sshd reads
`/usr/local/etc/ssh_host_{rsa,ecdsa,ed25519}_key`. Without an Ed25519 host
key the second P4 defect would be only half fixed.

That is a **compensation for a sibling defect**, and it says so where it
lives, with its exit condition: delete `write_sshd_keygen_wrapper` when
`ModernMavericks/openssh` ships a wrapper of its own. **The sibling should be
fixed; it is outside this directory, so it waits for the user.**

Belt and braces beside it: after the replacement, `openssh_usable()` checks
that `/usr/local/sbin/sshd` exists, that the wrapper path resolves, and that
`sshd -t` accepts `/usr/local/etc/sshd_config`. If any fails, `firstboot.sh`
restores the vanilla binaries from `/var/backups/vanilla-openssh`, which the
replacement's own `preinstall` puts there. A guest whose only interface is
SSH must not be able to lose SSH.

### What a full unattended build now reports

```
hostname=mavericks
ssh=OpenSSH_10.5p1, LibreSSL 4.3.2
hostkeys=ssh_host_ecdsa_key ssh_host_ed25519_key ssh_host_rsa_key
firstboot-daemon=removed
firstboot-ran=2026-09-19T13:47:18Z
autologin=mavsuser
```

and `image/build-image.sh` reaches it with **no** `HostKeyAlgorithms` or
`PubkeyAcceptedAlgorithms` overrides — `SSH answered after 20s`. Two
independent full installs (one on the media built at 08:47, one on a media
rebuilt at 09:45) produced the same result.

**And the first defect, tested directly rather than inferred.** An Ed25519
key generated on the host, appended to the guest's `authorized_keys`,
authenticating with no options of any kind:

```
$ ssh -i ed25519.key -p 2299 mavsuser@localhost 'echo ED25519-LOGIN-OK; ssh -V'
ED25519-LOGIN-OK
OpenSSH_10.5p1, LibreSSL 4.3.2
$ ssh-keygen -lf /usr/local/etc/ssh_host_ed25519_key.pub
256 SHA256:ZqvhSxZtHS45w0/ib91VUrS8lvB9CNfF7Qr99FNiDkk no comment (ED25519)
```

The workaround is deleted, not kept beside its fix. It survives only for `--no-openssh`, which really is an
OpenSSH 6.2 guest; `image/compare-images.sh` keeps it too, because it
compares two images it did not build and has no argument saying which is
which.

The build-time Ed25519 refusal is scoped rather than deleted, for the same
reason. `tests/payload.bats` now asserts the good behaviour and keeps the old
assertion for the stock shape.

### The race the fix uncovered

The first full run came back with the guest on OpenSSH 10.5p1 — and
`hostname=Macintosh.local`, `firstboot-daemon=STILL-THERE`, no `.done`
marker, no auto-login. A worse result than before, apparently.

It was not. The guest's own log showed `firstboot.sh` finishing normally
**one second after** the verify stage read those values.

`firstboot.sh` turns Remote Login on part-way through; the hostname,
auto-login, the `.done` marker and the removal of its own LaunchDaemon all
come afterwards. That window has always existed. It was masked by an
accident: Apple's `sshd-keygen-wrapper` generates three host keys on the
**first** connection, which takes several seconds, so `firstboot` always won
the race. Our wrapper generates host keys up front, the first connection
became instant, and the window closed to about a second.

`stage_install` now waits for the `.done` marker — bounded at 300 s and
non-fatal, because an image whose payload never finishes is a real failure
but one for the verify stage to report with the log in hand, not one to hang
the build on.

**A race being won by an accident is still a race**, and no amount of reading
the code would have found this one. It is the whole argument for running the
pipeline rather than reasoning about it.

### One self-inflicted wound worth writing down

The first proof run was killed at minute six because `image/build-image.sh`
was **edited while bash was running it**. Bash reads a script lazily and
seeks by byte offset between commands; inserting lines near the top shifts
every offset after it, and what runs next is whatever now sits at the saved
position. Nothing visibly broke, and that is the problem — the result would
have been untrustworthy. Rule: while a long build is running, that script is
read-only.

### `vendor/sources.tsv` is now wired up

`decisions/0007` said the family's ingredient apparatus fits us better than
it fits most siblings and that `vendor/sources.tsv` is already the pin file,
simply not wired up. It is now.

Renovate managers for `components/openssh/version` (with a `regex:`
versioning that keeps the `-mavericks.N`; the default coerces it away and the
pin then never moves again), `acidanthera/OpenCorePkg`, `Lilu` and
`VirtualSMC`. The last two need an `autoReplaceStringTemplate` because their
version appears **twice** in one URL, and a manager that rewrote only the
captured occurrence would leave a half-updated URL that 404s.

Six ingredients are deliberately untracked, each with its reason in
`INGREDIENTS.md`: audk's twelve submodules (bare commits with no ref for
`git-refs` to move), ocbuild's `efibuild.sh` (a raw URL, no tags, no
releases), Apple's `InstallESD.dmg` (one immutable build; 10.9.5 is 10.9.5
forever), QEMU (the host's, not ours), and the two Tier 2 reference blobs
(nothing ships them — `tier-check --strict` is what says so).

`bin/verify-changed-sources.sh` exists because of something that would
otherwise have been strictly worse than not tracking at all: **Renovate can
move a URL in `sources.tsv` but cannot compute the `sha256` beside it.** The
resulting PR is internally inconsistent, nothing else in the suite downloads
anything, so it is green — and the shared preset automerges green PRs. That
would turn "track the ingredient" into "break the ingredient automatically".
The check re-fetches only the lines that changed.

### The stale golden image, which is our problem and not the family's

Every sibling ships a built artifact, so an ingredient bump triggers a
repackage and the published thing is never stale for long. We ship a
**recipe**: our release contains no image, so a bump obsoletes nothing
published.

It does something quieter instead. **It silently invalidates every golden
image already on disk.** Renovate moves the OpenCore pin and a nine-gigabyte
golden built last week is something no commit here can reproduce. Nothing
fails, nothing goes red, the image keeps booting, and it simply stops meaning
what its manifest says.

So the manifest carries every pin — one `ingredient.<name>` line each plus an
`ingredients` digest — which makes `image/compare-images.sh` name the
ingredient that differs between two images for free, and
`bin/image-staleness.sh` answer "is this image still made of what the
repository is made of" for one manifest. A manifest with no ingredients
reports **"cannot be determined"**, which is deliberately not the same answer
as "fine": conflating those is exactly how a stale golden gets trusted.

Chosen over a staleness warning on `run`, which is the hot path and would be
ignored by the third boot. `repackage-on-ingredient-bump` does not apply to
us at all — there is no artifact to repackage — and `INGREDIENTS.md` says so
with the reason rather than omitting it.

### The check that is ours alone

`bin/no-apple-bytes.sh`: **a release must contain no Apple-derived bytes.**
It passes by construction, because the tool fetches Apple's media at runtime
on the user's machine — which is the reason to assert it, not a reason to
skip it. Satisfied-by-construction is precisely the condition under which a
rule quietly stops being true; a 6 GB `.dmg` committed "just for a minute" is
one `git add -A` away and looks like nothing in a large diff.

It checks names, magic numbers (`xar!`, `H+`/`HX`, `koly`, Mach-O) and size,
over the **tracked** tree, because a release is what `git archive` produces —
not the working directory, where an untracked `InstallESD.dmg` beside the
repo is how this project is meant to work. `tests/release.bats` fires it at a
planted violation of each kind, because a check nobody has seen fail is a
check nobody trusts.

### A second landmine: the guest that finished in 17 seconds and could not be reached

The third run installed, and then sat at the login window for 2640 s while
`image/build-image.sh` polled SSH and got `Connection timed out during
banner exchange`. It looked like `firstboot.sh` had wedged inside the
OpenSSH step.

It had not. Booting the resulting image afterwards and reading its own log:

```
13:47:02  starting on 10.9.5 build 13F34
13:47:06  openssh: requested=1 tag=10.5p1-mavericks.2
          installer: The install was successful.     (base)
          installer: The install was successful.     (system-replace)
13:47:17  openssh: OpenSSH_10.5p1, LibreSSL 4.3.2 is now the system ssh
13:47:17  remote login: Remote Login: On
13:47:19  done
```

**Seventeen seconds, start to finish, both packages included.** The guest
was complete and healthy; the host could not talk to it. `ifconfig en0` in
that guest showed link-local IPv6 and no IPv4 lease, and both QEMU logs are
full of `Slirp: Failed to send packet, ret: -1`. A DHCP/slirp hiccup, not a
payload failure — and the box was running another agent's multi-gigabyte
media experiment at the time, with its own QEMU microVMs and loop devices.

Worth knowing because the symptom is indistinguishable from a wedged
payload from the outside, and the diagnosis took a disk conversion and a
second boot. `stage_install`'s failure message could usefully say "the guest
may be up but unreachable; boot it and read /var/log/mqg-firstboot.log" —
that log is the thing that settles it in ten seconds.

### A third data point for G20, with a different symptom

Between the first full run and the second, the installer media stopped
booting. It got as far as launchd and stopped:

```
launchctl: Dubious ownership on file (skipping): /System/Library/LaunchDaemons/com.apple.installd.plist
...  (every daemon, ~60 lines)
launchctl: Dubious ownership on file (skipping): /System/Library/LaunchDaemons/ssh.plist
nothing found to load
```

The media was built at 08:47, booted and installed perfectly at 08:57, has
an mtime of **09:11:03** — during the first run's own pipeline — and at
09:15 no longer booted. `fix_media_ownership` had run when it was built;
the build log says so. Rebuilding the media took 77 s (every heavy
conversion is cached) and the next run installed normally.

This is **G20 again — a second writer to installer media — but with a
symptom worth recording separately**, because it is not data corruption.
`udisksctl` mounts HFS+ read-write with `uid=1000,gid=1000`, and the Linux
`hfsplus` driver writes those back into any inode it updates. Nothing on
the volume is damaged; every file simply stops being root-owned, and
launchd on a 10.9 installer refuses to load a plist it does not trust. A
checksum of the media's *contents* would not notice this at all: the bytes
are identical and only the ownership changed.

Supporting measurement: a deliberate **read-only** loop mount of the same
image, done by hand afterwards, left the mtime untouched at 09:11:03. So
`media/content-digest.sh`, which mounts the media to compute `mediacontent`
for the manifest and reads every file on it, is a candidate for the
writer — a cheap first move would be for it to mount read-only.

Consistent with the Task 34 entry above, which was being written in another
session at the same time this was hit.


### The experiment the margin theory deserved: ten builds at 128 MiB

The cheap decisive test, run on an idle host, one build at a time.

**Configuration: the failing era's, exactly.** `MQG_MEDIA_MARGIN_MIB=128`,
`--autoinstall`, which gives a 6375 MiB partition inside a 6,686,769,152-byte
image — the same number `d-install.log` reports as `disk1` — and leaves
117,092,352 bytes free on the finished volume against the **117,112,832**
the P4 notes recorded. Nothing in the write path had changed since.

**Verification: about twice as sensitive as the thing that found the bug.**
The build's own check looks at sixteen packages. Each of these was checked
again afterwards by a reader that mounts nothing, comparing **every file on
the media** against a manifest of the Mac-produced `InstallMavericks.iso`.

| run | build | mismatched files | common paths compared |
|---|---|---|---|
| 1 | ok, 80 s | 0 | 40,192 |
| 2 | ok, 78 s | 0 | 40,192 |
| 3 | ok, 80 s | 0 | 40,192 |
| 4 | **failed, 50 s** | 0 | 40,192 |
| 5 | ok, 77 s | 0 | 40,192 |
| 6 | ok, 76 s | 0 | 40,192 |
| 7 | ok, 74 s | 0 | 40,192 |
| 8 | ok, 76 s | 0 | 40,192 |
| 9 | ok, 86 s | 0 | 40,192 |
| 10 | ok, 88 s | 0 | 40,192 |

**401,920 file comparisons, zero mismatches.** `Essentials.pkg` came out
`a0609f3d…` — Apple's own bytes — ten times out of ten, in a single extent
every time.

**The 128 MiB margin does not reproduce the fault.** At the observed 3-in-6
rate, ten clean builds is a probability of about one in a thousand; even at
a generous 1-in-4 it is about one in eighteen. Whatever corrupted that
media in P4, the media build is not doing it, and the margin was never the
thing holding it off. Hypothesis 4 in the register above is dead by
experiment as well as by arithmetic.

**Run 4's failure was not corruption**, and is worth its own line because it
is exactly the kind of thing that gets mistaken for one. The media it built
compares clean; what failed was the verification's own mount:

```
mqg: error: loop-setup failed for .../installer-linux.img:
  Error creating loop device: Failed to associate the /dev/loop0 device
  with the file descriptor: Device or resource busy
```

A udisks loop-setup race, one build in ten, immediately after the privops
microVM released the same file. `lib/hfs.sh` already retries and settles
around udisks' asynchrony elsewhere; this path does not, and a build that
produced perfect media reported failure. Recorded rather than fixed here —
it is a separate defect from the one this task was about, and fixing it
inside a diagnosis is how the margin got believed in the first place.

---

## 2026-09-19 — the triangulation harness, and what Q1 now knows

Two jobs: build the thing the other hosts will run, and write down what a
live guest just told us about Apple's update servers.

### `bin/triangulate.sh`

The other hosts in `docs/test-hosts.md` belong to the user. They run this;
we read the report. Everything about the design follows from that — it
installs nothing, never asks for root, writes only under `$MQG_IMAGE_DIR`
plus a scratch directory it removes, and says what it removed and what it
left. `--probe` is the default because the safe thing should be what
happens when someone types the command with no arguments.

Three levels, cumulative: `--probe` (~2 min, touches nothing), `--build`
(~10 min, the boot stack and the media, no install), `--full` (~30 min,
an unattended install and an SSH check).

**The output is the deliverable, not the exit status.** The last section is
markdown rows for `docs/host-profile.md` section 4: one per ledger entry
this host can speak to, each CONFIRM, REFUTE or CANNOT-SAY, with what was
observed. `--json` emits the same thing for diffing hosts.

Measured here: a probe takes **4.5 seconds**, not two minutes, and its
output reproduces `docs/host-profile.md` section 1 fact for fact — which is
a check on both, since that section was written by hand in P0.

### Three things worth knowing about how it works

**The `-cpu` test is decisive rather than a warning in a log.** QEMU only
warns when a `+flag` cannot be provided; with `enforce` it refuses to
start. So the probe runs `-cpu Penryn,+ssse3,+sse4.1,+sse4.2,enforce`
against a paused VM with no disks, no network and no display and quits it
from the monitor — about a tenth of a second, nothing written anywhere.
On a Woodcrest Mac Pro 1,1 this should print `Host doesn't support
requested features` and say REFUTE against G3. The accelerator is part of
the observation, because **TCG implements SSE4.1 itself**: run under TCG,
a 2006 Xeon would pass this test and teach us nothing.

**"Reused" is not "ok".** `image/build-image.sh` is resumable on purpose
and "already there" is a success for it. For a triangulation run it is the
opposite: a host that reused media somebody else built has not shown it can
build media. The stage table says `reused`, and G20 and G5 say CANNOT-SAY
rather than claiming evidence the run does not have. This was a bug first:
the first `--build` run cheerfully reported G20 CONFIRM about media it had
not touched.

**CANNOT-SAY is a result.** G19 is permanently CANNOT-SAY from this script,
and says why: settling it means running two installs at once, which is the
thing the entry warns about.

### What is unexercised, and will stay that way until there is a second host

Only one host was available, so:

- **Every non-Linux path is unexercised.** The macOS branches (`sysctl`,
  `sw_vers`, `cp -c` for APFS clones, `kern.hv_support` for HVF), the
  NetBSD branches (`cpuctl identify`, `/dev/nvmm`), and the `mount(8)`
  parsing for both BSD-shaped and Linux-shaped output. They were written
  from the documented behaviour of those tools, not from a run.
- **Every REFUTE path is unexercised on real hardware.** This host confirms
  thirteen entries and cannot say about six, which is exactly what a
  primary host should do — and means no REFUTE row has ever been printed
  by a real probe. They are covered by unit tests in
  `tests/triangulate.bats` instead: `lib/triangulate.sh` is pure so the Mac
  Pro's predicted SSE4.1 failure can be tested today, on a Coffee Lake,
  without the hardware.
- **`--full` is unexercised.** A disposable guest was up on port 2223 while
  this was written, and G19 says one install per host. The stages it drives
  (`install`, `verify`, `manifest`) are the same ones P4 runs daily; what
  has never run is this script's orchestration of them, its guest-bus
  question for G16, and its cleanup of a finished image.
- `--build` **was** exercised, against a disposable `MQG_IMAGE_DIR` seeded
  with reflink copies so the real one was never written to. Every stage
  reported `reused` except `target`, which is the honest answer and the
  reason that distinction now exists.

### Two findings, recorded rather than smoothed over

**`image/build-image.sh --stage payload` was broken, and nothing had ever
run it.** `openssh_args` resolves the OpenSSH tag inside `< <(...)`, a
subshell, so the tag was fetched and discarded and the parent kept its
empty string. A full run never noticed because `stage_openssh` had already
resolved it minutes earlier in the parent shell. Fixed, with a test that
reads the script rather than needing Apple's media on disk.

**`image/build-image.sh --accel` accepts only `kvm|tcg`.** A macOS host
with HVF or a NetBSD host with NVMM cannot drive the pipeline as its own
accelerator today. `--build`/`--full` fall back to TCG and the report says
so, in the section listing every place the script had to know what kind of
host it was on. That section is not an apology; it is the portability work
this project still owes, and it is three lines long on day one.

While reading the pipeline for this, a third: **`stat -c %s` is GNU-only**
and `image/build-image.sh` uses it in four places. It will fail on macOS
and on the BSDs, where the spelling is `stat -f %z`. Not fixed here — it is
not in the triangulation path, and fixing it inside another task is how
diagnoses get believed without evidence.

### Q1: measured against Apple's servers, 2026

A live 10.9.5 guest (build 13F34) offers five updates, so **the servers
still serve 10.9** and Q1's first unknown is settled. See
`docs/open-questions.md` for the table and the detail; three things belong
here.

**The briefs are wrong about the last security update.** They say
2016-001. It is **2016-004**, 362,293 KiB, flagged for restart.

**That is the third undated inherited claim to come out wrong**, after the
`usb-tablet` kext and "DNS needs configuring in the guest". The pattern is
not about these three facts but about a class of source — undated
third-party write-ups, each correct when written, each carried forward
without a date, every one wrong in the same direction: describing a world
that was fixed years ago.

**The standalone packages exist**, which is what Q1's third unknown asked.
Apple's CDN serves them directly, over plain HTTP, with no account and no
`softwareupdate`:

```
$ curl -sSI http://swcdn.apple.com/content/downloads/63/01/\
041-88446-A_AI0EXM8N26/wlglj8xbhacww0zt8rtv5n1o9dkpl72ozq/\
SecUpd2016-004Mavericks.pkg
HTTP/1.1 200 OK
Content-Length: 370988463
Last-Modified: Tue, 01 Oct 2019 19:01:03 GMT
```

Fetched in full and hashed here:
`fd71517772928b35e773276b300ef30e0d264ed9d030bf3862625cab5513d1b5`. That is
already the form `vendor/sources.tsv` takes. Safari 9.1.3 (63,197,064
bytes) and iTunes 12.6.2 (five packages, 284,285,780 bytes) are there too,
and **every size matches the KiB figure the guest printed, exactly** —
which is how we know these are the same artifacts and not lookalikes.

A surprise worth keeping: **two of the five items are in no catalog we can
find.** `iBooksDelta-1.0.1` and `RemoteDesktopClient-3.8.4` do not appear
in `index-10.9.merged-1.sucatalog` — not in its package URLs, and not in
any of its 333 distribution files, all of which were fetched and searched.
The guest is being offered two things from a source that catalog does not
explain. The guest knows what it talked to; ask it before guessing.

**Q1 is not decided here.** Whether the image carries updates is the user's
call, and P5's baseline depends on it.


## 2026-09-20 — a compiler nobody pinned, and a verdict that blamed the wrong stage

`./bin/triangulate.sh --build` on `squirrel-zapper` (EndeavourOS, GCC
15-era) got through `esd` in 248 s and died in `opencore` at 111 s:

```
OpenCorePkg/Library/OcAppleImg4Lib/libDER_config.h:31:17: error: two or more data types in declaration specifiers
   31 | typedef BOOLEAN bool;
      |                 ^~~~
libDER_config.h:31:1: error: useless type name in empty declaration [-Werror]
cc1: all warnings being treated as errors
```

`bool` is a keyword in C23. GCC 15 defaults to `-std=gnu23`. EDK II sets no
`-std` at all and compiles with `-Werror`, so a `typedef` that was legal
for thirty years became a syntax error the moment the host compiler moved.
This host's GCC is 13.3.0, defaults to `gnu17`, and builds fine — which is
exactly why two phases went by without anyone seeing it.

### Reproduced here first, with a four-line shim

GCC 13 knows the same rules under the older name `-std=c2x`, so the failure
is reachable on this host. Two ways were tried and both are worth keeping.

The first was to inject `-std=c2x` into the build through EDK II's own flag
seam. That works — and it is how the *fix* gets in — but it is not a
faithful stand-in for a compiler whose **default** is C23, because it only
reaches the packages whose `.dsc` we touch.

The second is exact, and it is the one to use again:

```
mkdir -p /tmp/c23 && printf '#!/bin/sh\nexec /usr/bin/gcc -std=c2x "$@"\n' \
    > /tmp/c23/gcc && chmod +x /tmp/c23/gcc
PATH=/tmp/c23:$PATH ./boot/build-opencore.sh
```

A `gcc` that prepends `-std=c2x` **is** a C23-default compiler as far as
this build is concerned: an explicit `-std` later on the command line still
wins, exactly as it would against a real default. Nothing in the repository
or in the unpacked source tree is touched. The result was the same file,
the same line, the same two diagnostics:

```
OpenCorePkg/Library/OcAppleImg4Lib/libDER_config.h:31:17: error: two or more data types in declaration specifiers
OpenCorePkg/Library/OcAppleImg4Lib/libDER_config.h:31:1: error: useless type name in empty declaration [-Werror]
```

`BaseTools` — the host-side C that EDK II builds first — compiled clean
under the shim, which matches `squirrel-zapper` getting as far as it did.

### The narrow fix was tried and is disproved

The preference was `-std=gnu17` scoped to the one failing library. That was
done first: a `[BuildOptions]` section in `OcAppleImg4Lib.inf`. It fixes
libDER, and the build then dies somewhere else:

```
OpenCorePkg/Library/OcCompressionLib/zlib/adler32.c:63:15:
  error: old-style function definition [-Werror=old-style-definition]
```

C23 removed K&R function definitions too, and OpenCorePkg vendors zlib. The
breakage is not one file, it is "third-party C carried inside OpenCorePkg",
so the dialect is set for the platform. `-Werror` was never touched.

### The seam, which is upstream's own

`OpenCorePkg.dsc`'s `[BuildOptions]` expands `$(OCPKG_BUILD_OPTIONS)` into
every `CC_FLAGS` line and never defines it — upstream left the hook there on
purpose. `efibuild.sh` passes `$BUILD_ARGUMENTS` straight through to
`build`, and reads it from the environment, so

```
BUILD_ARGUMENTS="-D OCPKG_BUILD_OPTIONS=-std=gnu17" ./build_oc.tool
```

survives the `ARCHS`/`TOOLCHAINS`/`TARGETS`/`OFFLINE_MODE`/`EFIBUILD_SH`
invocation in `boot/build-opencore.sh` **without patching anything**. The
build prints its own flags, so the evidence is in the log:

```
Building OpenCorePkg/OpenCorePkg.dsc for X64 in RELEASE with GCC
and flags -D OCPKG_BUILD_OPTIONS=-std=gnu17 ...
```

Three things were checked and ruled out on the way: `build` has no
`--buildoptions` option at all (`BaseTools/Source/Python/build/buildoptions.py`
lists `-D/--define` and `-F/--flag`, and `-F` sets `BUILD_FLAGS`, not
`CC_FLAGS`); `tools_def.template` contains no `-std` anywhere, which is the
root of the whole problem; and `$(OCPKG_BUILD_OPTIONS)`, left undefined,
reaches the generated `GNUmakefile` *literally* and is expanded to nothing
by make — so it was already a live injection point, just an empty one.

### The quieter half: OVMF compiles fine and comes out different

The `opencore` stage fails first, so `squirrel-zapper` never reached the
`ovmf` stage and nobody knows what a GCC 15 would do to the firmware. Under
the shim, here, it builds **clean** — and produces different bytes:

| `OVMF_CODE.fd` | sha256 |
|---|---|
| gcc 13.3.0 default (`gnu17`) | `195c4dcff2abf2f5aea08c290f057432704a250eab56b0b887ac0f8503ee58d2` |
| same tree, same compiler, `-std=c2x` | `3373692a6739121bec67d458d09a60d602b40cf5235398f208d58f28db3306b8` |

That is worse than the OpenCore failure, because it is silent. A host with
a newer GCC would have shipped a firmware `decisions/0004` does not
describe, with a green build and a passing tier check. `OvmfPkgX64.dsc` has
no `$(...)` hook to borrow, so it gets
`boot/patches/0002-ovmf-pin-the-c-dialect.patch` — one line in its
`[BuildOptions]`, applied by `boot/build-ovmf.sh` the same way
`build_oc.tool` is patched, guarded by a grep and asserted afterwards.

### The checksums did not change

This is the thing to be loud about, and the answer is **no**.

Four cold builds (`rm -rf UDK/Build` before each), both packages each time:

| compiler default | fix | OpenCore | OVMF |
|---|---|---|---|
| `gnu17` (this host) | no | builds | builds, `195c4dcf…` |
| C23 (shim) | no | **fails**, `libDER_config.h:31` | builds, `3373692a…` |
| `gnu17` (this host) | yes | builds, identical | builds, `195c4dcf…` |
| C23 (shim) | yes | **builds, identical** | builds, `195c4dcf…` |

Every shipped artifact is byte-identical with the fix and without it,
because `-std=gnu17` is what GCC 13 was already doing — and, the row that
matters, a C23-default compiler with the fix produces **the same bytes as
this host does**. `OVMF_CODE.fd` is `195c4dcff2abf2f5aea08c290f057432704a250eab56b0b887ac0f8503ee58d2`
in three of the four rows and only moves in the one where the dialect is
unstated, which is the whole argument for stating it.

There is one exception to "identical", and it is **not** the fix's doing.

### `OpenCore.efi` embeds the build date

Comparing a cold rebuild against the 2026-09-17 checksums in
`decisions/0004`, `OpenCore.efi` differed — by exactly two bytes, at offset
358218:

```
2026-09-17 build:  ...0..2026f...0..09f...0..17...
2026-09-20 build:  ...0..2026f...0..09f...0..20...
```

The date is compiled in as immediate operands. The other four OpenCore
artifacts and all three OVMF images are identical across the three days. So
`decisions/0004`'s `OpenCore.efi` row means "these sources, built on that
date", and two hosts' checksums for it are only comparable if they built on
the same UTC day. Found while checking whether a flag had moved a checksum,
which is the argument for checking.

### What this exposes is bigger than a flag

`decisions/0004` defines Tier 0 as "built from pinned source". We pin
OpenCorePkg, `ocbuild`, `audk` and twelve submodules by commit and
checksum. **We do not pin, record or constrain the compiler** — and it is
not a neutral party: the same pinned sources give a working artifact on GCC
13, no artifact at all on GCC 15, and (for OVMF) a different artifact under
a different dialect.

Pinning the *dialect* removes the largest moving part. It does not close
the hole: GCC 13 and GCC 15 still emit different code from identical
sources and identical flags, and so does clang.

Three things now record the gap rather than paper over it:

- every image manifest carries a `compiler` line, next to `qemu`, from
  `boot/build-opencore.sh --compiler` — recorded, explicitly **not** a pin;
- `docs/host-profile.md` §4 has **G22**, and §1 finally says what this
  host's compiler is;
- `decisions/0004` has a section named "The compiler is not pinned — the
  hole in Tier 0", ending in the question for the user: record only, declare
  a supported range, or build in a pinned toolchain. **Not decided here.**
  P6 forces it, because a runner image's compiler moves without anyone
  choosing it.

### The second bug the same run exposed: a verdict that named the wrong thing

The same report printed:

```
| G20 | REFUTE | squirrel-zapper | media build or its post-unmount verification failed on this host -- the interesting case. Keep the log |
```

**The media stage never ran.** `opencore` failed first and the stage loop
stops at the first failure. `g20_verdict` was fed the run's overall
`build_ok`, so any failure anywhere became a failure of media — and G20 is
the entry about installer media being silently corrupted by a second
writer, so the verdict sent a reader hunting a filesystem bug that was not
there.

Judges now ask what *their own* stage did. `tri_stage_result` reads the
stage table the run already builds and distinguishes `ok`, `reused`,
`FAILED` and `not-run`; `tri_failed_stage` names the stage that stopped the
pipeline. G20 REFUTEs only when the media stage itself failed; otherwise it
says CANNOT-SAY and names the stage to go and look at. G5 got the same
treatment — missing firmware checksums after a failed `opencore` stage are
not "nothing built at this level" — and the final error now names the stage
instead of the level. Six tests, with `squirrel-zapper`'s actual stage table
as the fixture.

### Disproved or ruled out along the way

- **`--buildoptions` is not a thing.** The brief offered it as a candidate
  seam; `build` has no such option.
- **A per-library fix is not enough.** Tried, measured, moved the error.
- **`-Werror` did not need touching**, and was not.
- **Setting `OCPKG_BUILD_OPTIONS` as a plain environment variable** would
  also have worked, because the unexpanded `$(OCPKG_BUILD_OPTIONS)` reaches
  make. Rejected: `-D` bakes the literal flag into the generated makefile
  and into the build log, where it can be read back, instead of depending on
  make's environment inheritance.
- **OVMF was not assumed to be fine** because the failing run never reached
  it. It was built under the shim, and the finding above is why that
  mattered.

## 2026-09-20 — the compiler range: what is claimed, and what is merely expected

Answering the open question the previous entry left for the user:
`decisions/0004` now says **(b)** — declare a supported range, test the
edges, fail clearly outside it — and `lib/compiler.sh` is it.

Not (c). Pinning a toolchain is the only option that makes "the same
sources produce the same bytes" true, and it is the right answer the day
these images have to be independently verifiable. Nothing about that
changed. What has not happened is P6 saying what CI needs, and buying a
container or a bootstrapped GCC against a requirement nobody has written
down is a lot of machinery for a project whose other Tier 0 claim is that
it needs a shell and a package manager. (b) is the cheapest thing that
turns a silent break into a clear message, which is the specific harm the
`squirrel-zapper` run exposed.

### The range says which half of it is measured

**gcc 13 through 14, verified only at gcc 13.3.0.**

That phrasing is the whole point of the option and the easiest thing to get
wrong. What is actually known:

| | |
|---|---|
| gcc 13.3.0 | **verified** — this host, repeatedly, cold |
| gcc 13.x, 14.x | **expected, never tried** — same series, same dialect default |
| gcc 15 | **not verified, and therefore outside the range** |
| below 13 | **not tested** — which is not "known to fail" |

GCC 15 is the interesting one, and it is deliberately *above the ceiling*.
It is the version that motivated this entire piece of work; its C23 default
is what broke the OpenCore build; that failure is fixed. It is still
untested. The four cold builds in the previous entry were done with a `gcc`
wrapper prepending `-std=c2x`, which is a faithful stand-in for **the
dialect** and for nothing else — it says nothing about GCC 15's code
generation or about diagnostics it emits that GCC 13 does not, which under
EDK II's `-Werror` are build failures. The re-run on `squirrel-zapper` is
pending, and there is a row waiting for it in `decisions/0004` plus a note
in `lib/compiler.sh` saying which four places have to move together when it
lands.

This project has three times caught itself repeating an undated inherited
claim nobody had checked — the usb-tablet kext, "DNS needs configuration",
security update 2016-001 vs 2016-004. A range implying a tested GCC 15
would have been the fourth, in the same commit that congratulated itself
for catching the other three.

### Four outcomes, and why above-the-ceiling is not a failure

- **Inside** — one log line.
- **Below the floor** — fails, before the source tree is even looked for.
  Says what was found, what is required, and that the project has not
  tested it.
- **Above the ceiling** — **warns and proceeds.** Refusing would mean this
  project refuses to build on every new distribution, which is a worse
  failure than the one it prevents. But the warning has to say what kind of
  trouble this is, because up here *the failure mode is usually not an
  error*: OvmfPkg compiled clean under C23 and emitted different firmware
  bytes. A green build above the ceiling is not proof, and the warning says
  which checksums to compare.
- **Cannot tell** — warns, names what it could not parse, proceeds. This is
  the macOS case (`gcc` there is clang) and the `cc` case.

`MQG_COMPILER='<name> <version>'` replaces detection, in the shape
`MQG_PKG_MANAGER` established in `boot/prereqs.sh` and for the same reason:
a check fed by the environment is untestable without a seam, and installing
three GCCs to test a version comparison is not a reasonable price. All four
branches are tested on this one host through it. It moves nothing else —
`--compiler` still reports the real compiler — so an image built with the
check overridden has a manifest whose two compiler lines disagree in
public.

The manifest gained `compilerrange` beside `compiler`. The first says which
compiler; the second says whether the project claimed to support it **at
the time**, and cannot be reconstructed later: the range moves as evidence
arrives and the image does not. Without it, an image built above the
ceiling silently becomes a supported build the day the ceiling is raised.

### Two things that surprised me

**`IFS=$'\t' read -r a b c` silently drops empty fields.** Tab is an IFS
*whitespace* character, so a run of tabs collapses into one delimiter. The
parser emits `family\tversion\tbanner`, and an unparseable compiler has an
empty version — so the two adjacent tabs counted as one, the banner slid
left into `$version`, and the UNKNOWN branch reported "gcc is not on PATH"
for a compiler that had answered perfectly well. **The one case the
function exists to report was the one case it mis-reported**, and it took
running the unparseable test to see it. Explicit `${var%%"$tab"*}` has no
such rule. Non-whitespace delimiters (`:`) do not collapse, which is why
nobody hits this with `/etc/passwd`.

**Version parsing wants no per-vendor patterns at all.** Four banner
shapes — `gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0`, `gcc (GCC) 15.1.1
20250425`, `Apple clang version 17.0.0 (clang-1700.0.13.3)`, and the
override's bare `gcc 13.3.0` — are all handled by "the first field that is
a bare dotted number". Every one of them puts its packaging junk in a field
that is not a bare number. The `gcc (GCC) 15.1.1 20250425` case is the one
that looks like it needs special handling and does not: the build date is
also a bare number, but it comes second.

Test count 371 → 404.

### The cleanup deleted the evidence it had just asked for

`squirrel-zapper`, 2026-09-20, second `--build` run. The C23 dialect fix
worked: `opencore` built in 397 s on **gcc 16.2.1** — two majors above the
version that motivated the fix, and the stage that failed the first time.
Then `ovmf` failed in 26 s, and the run ended:

```
mqg: error: OVMF build failed -- see .../ovmf-build.log, and report the
     error rather than working around it
triangulate: removed /home/schmonz/.local/share/mavericks-qemu-guest
```

Those two lines are three seconds apart. The script asked for a log and
then deleted it, on a machine eleven minutes away from being able to
produce another one, belonging to someone else.

The report's 25-line stage tail ends exactly where the real error begins,
because the tail is what `build-image.sh` printed to the terminal and the
compiler diagnostics went to the log file.

**Fixed:** `salvage_logs()` copies `*.log` under 8 MB out of every tracked
directory into `$PWD/triangulate-logs-<host>-<stamp>/` before the EXIT trap
runs, and says so. Two tests: one asserts the call site exists rather than
only the function — a salvage routine nobody calls is the same as none —
and one asserts it copies logs and *not* everything, since the build trees
around them are gigabytes.

`--keep` already existed and is the wrong instrument: it keeps the whole
build tree, so the choice was between gigabytes and nothing. Logs are
kilobytes.

**The general rule:** a cleanup that runs on the failure path must not
remove the evidence of the failure. This one was worse than most, because
the same run printed an instruction to report an error whose only record
it was about to destroy.

Cost: one eleven-minute run on someone else's laptop, and the OVMF failure
is still undiagnosed.

Also now known: `gcc` on that host is **16.2.1**, not 15. The supported
range is gcc 13–14, so it warns and proceeds — correctly, and the warning
was visible in the output above the failure.

### The OVMF failure, diagnosed: upstream's `-Werror` and a warning GCC 16 invented

The salvage worked, which is how there is anything to read. From
`triangulate-logs-squirrel-zapper-20260920-025119/ovmf-build.log`:

```
MdeModulePkg/Library/CustomizedDisplayLib/CustomizedDisplayLib.c:435:18:
  error: variable 'Count' set but not used [-Werror=unused-but-set-variable=]
  435 |   UINTN          Count;
cc1: all warnings being treated as errors
```

Look at the diagnostic's name: `-Werror=unused-but-set-variable=`, with a
trailing `=`. GCC 16 gave that warning a level argument, so it is not even
spelled the way GCC 13 spells it. `Count` really is set and never read, in
`MdeModulePkg`, in code we did not write and have no standing to change.

**This is the second time, and that is the point.** The first was GCC 15's
C23 default, which is a change of *language* and got the right fix —
`-std=gnu17`, stated rather than inherited. This one is different in kind:
nothing about the code changed, nothing about the language changed, a
compiler simply learned to say something new, and `-Werror` turned it into
a build failure. **A new compiler invents new warnings. GCC 17 will bring
a third.**

`-Wno-unused-but-set-variable` would have made today's error go away and
taught nothing. So would patching `CustomizedDisplayLib.c` — worse,
actually: it would be the first hunk of a fork of EDK II we did not intend
to have, and it would grow by one hunk per compiler release forever.

#### Whose `-Werror` is it?

`-Werror` is on every `gcc` line this build runs, out of
`BaseTools/Conf/tools_def.template`. **It is upstream's discipline for
upstream's own development**, and it is a good one: a warning nobody is
allowed to ignore is a warning that gets fixed.

We are not upstream. We are a downstream consumer pinning one commit of
`acidanthera/audk` and one release of OpenCorePkg, compiled by whatever C
compiler the host distribution ships. **We cannot fix their warnings**, and
**a warning we cannot act on should not stop our build.** Upstream keeps
its discipline — nothing here changes what tianocore or acidanthera see —
and we stop inheriting a build failure from it.

So: `-Wno-error`, for the firmware builds only, through the same two seams
the dialect fix used.

| | how `-std=gnu17` got in | how `-Wno-error` gets in |
|---|---|---|
| OpenCorePkg | `$(OCPKG_BUILD_OPTIONS)`, upstream's own hook | same hook |
| OvmfPkg | `boot/patches/0002-ovmf-pin-the-c-dialect.patch` | `boot/patches/0003-firmware-drop-werror.patch` |

Both patches are applied by `boot/build-ovmf.sh`, each guarded by a grep so
a warm tree is not patched twice and asserted afterwards so a patch that
silently did nothing cannot pass for success.

#### The seam had room for one flag, and the separator is a tab

`efibuild.sh` reads `BUILD_ARGUMENTS` out of the environment and splits it:

```
IFS=', ' read -r -a BUILD_ARGUMENTS <<< "$BUILD_ARGUMENTS"
```

On spaces **and** commas. `-D OCPKG_BUILD_OPTIONS=-std=gnu17` is two
arguments and survives; `-D OCPKG_BUILD_OPTIONS="-std=gnu17 -Wno-error"` is
three, and `build` would reject the third. There is exactly one macro hook
in `OpenCorePkg.dsc` and `build` has no other way to append a flag, so the
two flags have to arrive as one argument.

A tab is not in that `IFS`. It survives the split as a single argument, and
`build.py` writes it back out as an ordinary space in the generated
`GNUmakefile`:

```
... -D DISABLE_NEW_DEPRECATED_INTERFACES -std=gnu17 -Wno-error -D OC_TARGET_RELEASE=1 ...
```

Written as `printf -- '-std=%s\t%s'` rather than as a literal tab, so it is
visible in the file and cannot be lost to a reformat — and **asserted after
the build**, not trusted: `boot/build-opencore.sh` now greps a generated
`GNUmakefile` for both flags and dies if either is missing. The
`GNUmakefile`s are rewritten on every build, warm or cold, which
`build.log` is not: a warm rebuild that compiles nothing has no `gcc` lines
in it.

#### The warnings are still printed

This is the half that would make the fix worthless if it were wrong. The
point is that upstream's warnings stop being **fatal**, not that they stop
**existing**. Shown rather than asserted, on this host's gcc 13.3.0, with
`squirrel-zapper`'s exact diagnostic reduced to one line of C:

```
$ printf 'int f(void){ int Count; Count = 1; return 0; }\n' > werror-demo.c

$ gcc -Wall -Werror -c werror-demo.c -o /dev/null
werror-demo.c:1:18: error: variable 'Count' set but not used [-Werror=unused-but-set-variable]
cc1: all warnings being treated as errors
exit=1

$ gcc -Wall -Werror -Wno-error -c werror-demo.c -o /dev/null
werror-demo.c:1:18: warning: variable 'Count' set but not used [-Wunused-but-set-variable]
exit=0
```

Same file, same line, same column, same diagnostic — `error` becomes
`warning` and the compiler stops failing. `-Wall` is untouched, `cc1` says
everything it said before, and all of it is still in `build.log` and
`ovmf-build.log`. A test asserts that the patch adds exactly one compiler
flag and that the flag is `-Wno-error` — not `-w`, not `-Wno-<anything>`.

**And it is firmware only.** `shellcheck`, `bin/tier-check.sh --strict` and
`bin/bash32-check.sh` all still fail the suite. The argument above is about
C we did not write and cannot change; it does not transfer to code we own,
and there is a test whose entire job is to say so where someone would look
for permission.

#### The checksums did not change — measured, not assumed

`decisions/0004`'s claim is that this boot stack is reproducible, so a flag
change that moved a checksum would matter more than the failure it fixed.
`-Werror` should not affect code generation — it decides whether a
diagnostic aborts the build, not what the compiler emits — but "should not"
is not evidence. Two cold builds, both packages, on the primary host, gcc
13.3.0, 2026-09-19, same UTC day so the `OpenCore.efi` build-date wrinkle
cannot confuse the comparison:

| artifact | before | after |
|---|---|---|
| `OVMF_CODE.fd` | `195c4dcff2abf2f5aea08c290f057432704a250eab56b0b887ac0f8503ee58d2` | identical |
| `OVMF_VARS.fd` | `5d2ac383371b408398accee7ec27c8c09ea5b74a0de0ceea6513388b15be5d1e` | identical |
| `OVMF.fd` | `e44f708330318e8963baea94c91ed265761794e565e6a48db8821e92e4cbda17` | identical |
| `BOOTx64.efi` | `eb05c27990e7162011b2ef5229d3e2b8be23a8e0bfd79d77c1891cee175e0094` | identical |
| `OpenCore.efi` | `a6e91a7a995f8792e987da25c2c7061e2dc7907f8c2eef7dec61ebd00ff3669a` | identical |
| `OpenRuntime.efi` | `d5bece452e5c2180b7f588b40b12c2fe64663548dbbe0de01038c3db45083a5d` | identical |
| `OpenPartitionDxe.efi` | `e0ee5f238725685eff2f423558b933497c5475c257f747aa281e2d88018723ea` | identical |
| `OpenHfsPlus.efi` | `93f491375fbd4c0541b55d64b8d4e2f01cafde4f66b7f520f943d3351a45040a` | identical |

All eight. If they had differed, something other than diagnostics had
changed and this would be a different entry.

#### The ceiling did not move, and that is deliberate

`squirrel-zapper` is gcc **16.2.1**, and after the dialect fix its
`opencore` stage built clean in 397 s — a real C23-default compiler, two
majors above the one that motivated that fix, completing the stage that
failed the first time. That is the only evidence anyone has about 15 or 16,
and it is **half a boot stack**.

The `-Werror` fix has not been run there. A fix that has not been run on
the host that exposed the bug is a hypothesis, and the failure the declared
range exists to warn about is not the loud one: it is a green build that
emits *different bytes*, which no compiler above 13.3.0 has ever been
checked for. So `MQG_CC_CEILING` stays at 14 and the `decisions/0004` table
gained a `16.2.1` row saying exactly how far that host got and what remains
unknown. **The user's next run is what moves it.**

Test count 407 → 415.

---

## 2026-09-20 — P4 — the privops backend on a host that is not Debian

`./bin/triangulate.sh --build` on `squirrel-zapper` (EndeavourOS, gcc
16.2.1, QEMU 11.1.1) got through the entire media build — 52,292 entries,
6,427,352,649 bytes, all sixteen of Apple's packages matching their pinned
checksums, install hooks and both OpenSSH packages injected — and then died
on the last step:

```
mqg: restoring root ownership (privops backend: qemu-linux)
mqg: error: privops backend 'qemu-linux' is not available on this host
```

Every firmware stage had passed. This was the only thing between that host
and a complete `--build`.

### What failed

Two defects, and the second cost more than the first.

`lib/privops.sh` decided availability with a four-way `&&`, whose last
clause was `[ -r "/boot/vmlinuz-$(uname -r)" ]`. Arch installs its kernel
as `/boot/vmlinuz-linux`; there is no `/boot/vmlinuz-<release>` there at
all. `lib/privops-qemu-linux.sh` passed the same string to `-kernel`, so
fixing only the predicate would have produced a check that passes and a
microVM that does not boot.

The four-way `&&` reported **one bit**. Four requirements, one "not
available", no indication which. On a machine belonging to someone else
each guess is a round trip; this one cost three.

### Why the Debian assumption survived this long

Because it is not a distro assumption to anyone who only has Debian. The
path is right on every host this project had ever run on — the primary host
is Mint 22.3 — so it was never a claim being tested, just a string that
worked. `docs/host-profile.md` §4 exists for exactly this class and had no
row for it: the ledger tracks assumptions about *hardware* and *firmware*
closely, and a filesystem path did not feel like an assumption. It is now
`G23`, struck as resolved, because the class is the finding: a path that
exists on the host you wrote it on is not a fact about Linux.

The same thinking hid a second requirement. The initramfs contains one
binary and no dynamic loader, so busybox must be **static** — the file's own
header said so and nothing checked. Debian ships `busybox` (dynamic) and
`busybox-static` (static) separately; the primary host had the right one by
luck of packaging. A dynamic busybox passes `command -v`, copies fine,
produces a well-formed cpio archive, and then panics on exec inside the
microVM with nothing pointing at busybox.

And `boot/prereqs.sh`, whose whole job is to answer "can this host do the
work" before the work starts, listed neither `busybox` nor `cpio`. It told
`squirrel-zapper` yes, and the host then spent an hour proving otherwise.

### What the fix does

`privops_qemu_linux_kernel` searches instead of assuming, most specific
first: `/boot/vmlinuz-<release>`, `/lib/modules/<release>/vmlinuz`,
`/boot/kernel-<release>`, then the generic `/boot/vmlinuz-linux`,
`/boot/vmlinuz`, `/boot/kernel-*`. **The ordering is a safety property, not
a preference.** The initramfs stages `hfsplus` and the `nls` modules out of
`/lib/modules/<running release>`; boot a generically-named kernel of some
other version and insmod rejects every one on version magic, the mount
fails, and the console says `MQG-PRIVOPS-MOUNT-FAILED` without a word about
why. A version-keyed path therefore wins over a generic one even when both
exist, `privops_run_qemu_linux` boots the path that was found, and a
non-keyed choice gets a warning saying what could go wrong.

`privops_backend_missing` replaces the one-bit answer with one line per
unmet requirement, and the caller prints them:

```
mqg: warning:   missing: busybox (not on PATH)
mqg: warning:   missing: a readable kernel image for 6.17.9-arch1-1 (looked
                for: /boot/vmlinuz-6.17.9-arch1-1 /lib/modules/6.17.9-arch1-1/vmlinuz ...)
mqg: error: privops backend 'qemu-linux' is not available on this host: 2
            requirement(s) above are unmet. Nothing here installs anything
```

`privops_backend_available` is still a silent predicate — it is now defined
in terms of the report rather than the other way round, because a predicate
that printed would print from `privops_describe` and from every test that
only wanted a yes or no, and a predicate with side effects is its own bug.
Backends supply `privops_<backend>_missing` alongside `privops_run_<backend>`;
that is the seam now.

Busybox linkage is checked with `ldd`, not `file`: `ldd` ships with the C
library (glibc and musl both), `file` is a package a host need not have and
this project does not require. The answer is read from ldd's *output*, not
its exit status, which is non-zero both for a static binary and for a file
it cannot parse. A dynamic busybox is reported as its own requirement —
"install busybox" is the wrong advice to somebody who has one.

`boot/prereqs.sh` gained `busybox` (Debian `busybox-static`, Arch
`busybox`) and `cpio`. Arch's `cpio` package name stays `?`: the tool was
already present on `squirrel-zapper`, so nobody had to name it, and this
table's rule is that a guessed name costs more than an honest blank.

Nothing installs anything. The job was to say what is needed and let a
human decide.

### What is still untested, and it is most of it

**Only the Debian path has ever been executed.** `/lib/modules/<release>/vmlinuz`,
`/boot/vmlinuz-linux`, `/boot/vmlinuz` and `/boot/kernel-*` are exercised by
fixtures in `tests/privops.bats` and by no real kernel. The search roots are
`MQG_PRIVOPS_BOOT_DIR`, `MQG_PRIVOPS_MODULES_DIR` and `MQG_PRIVOPS_KVER` so
that a Debian host can pose as Arch or Gentoo — the same move
`MQG_PKG_MANAGER` made for `prereqs.sh` — but a fixture proves the search
logic, not that Arch's `/boot/vmlinuz-linux` boots a microVM that mounts
HFS+. The dynamic-busybox report is likewise tested with a stand-in binary,
not with a dynamic busybox. **The next `--build` on `squirrel-zapper` is the
first real run of any of it.**

### G20 was misattributed again, one level finer

The same run printed:

```
| G20 | REFUTE | squirrel-zapper | media build or its post-unmount
| verification failed on this host -- the interesting case. Keep the log
```

G20 is *"a second writer to installer media corrupts it"*. The media had
just been built perfectly and the ownership step failed for want of a
backend: no second writer, no corruption, no verification attempted. An
earlier round fixed stage-level misattribution, where "the run failed" was
read as "the media stage failed"; this is the same class one level down,
where `media_built=no` was read as "G20 happened".

`tri_media_failure_kind` now recognises the post-unmount check
**positively**, by the message it dies with, and calls everything else
"other" — including the ESD check, whose nearly identical sentence is about
`dmg2img` and a source image rather than about media. G20 REFUTEs only on
"verification"; any other media-stage failure is CANNOT-SAY naming the
reason, lifted from the pipeline log by `tri_media_failure_reason`. A
verdict that misattributes is worse than no verdict: it sends someone
hunting a filesystem bug that is not there.

Test count 416 → 437.

### A 369-second silence: `set -e` ate the diagnostic, again

`squirrel-zapper`, 2026-09-20, two runs. The media stage failed after
369 s with this as its final log line:

```
mqg: running privileged operations in a QEMU microVM (no host root)
```

No error. No die message. Nothing on the terminal, nothing in
`pipeline.log`, nothing in the report's 25-line tail — because there was
nothing to find.

**Cause.** `lib/privops-qemu-linux.sh:250` read:

```sh
out=$(timeout 300 qemu-system-x86_64 ... 2>&1)
```

The microVM exceeded 300 s on that host, `timeout` returned 124, and
**a command substitution that fails in an assignment is fatal under
`set -e`** (`media/build-installer-img.sh:30` sets `-euo pipefail`). The
script died on that line — six lines above the `die "privileged
operations failed inside the microVM"` written to explain exactly this.

The arithmetic fits: 369 s ≈ time to reach the microVM, plus the 300 s
timeout.

**This project had already written this lesson down.** The
`screenshot.sh | head -1` entry above says it: *"a command substitution
that fails in an assignment is fatal under `set -e`"*, and *"progress
reporting must not be able to end the thing it is reporting on."* The
lesson was recorded and did not travel, the same way `prereqs.sh` had the
`${arr[@]+"${arr[@]}"}` guard while three other sites did not.

**Why 300 s was wrong anyway.** It is a wall-clock bound on someone
else's hardware. Fine on a 6-core Coffee Lake; expired on a 2-core
Broadwell doing identical work. A fixed number cannot know that.

**Fixed.** `rc` is captured (`&& rc=0 || rc=$?`), 124 is distinguished
from a guest that ran and failed — the remedies are unrelated, one being
a slower machine and the other a broken payload — the timeout is 900 s
and overridable via `MQG_PRIVOPS_TIMEOUT`, and the console tail is
printed either way.

**Cost.** Two 19-minute runs on someone else's laptop, and two of my own
round trips spent salvaging logs that never contained anything, because
the failure produced no output to salvage. The log-salvage work was
correct and still would not have helped here.

**Worth generalising:** every `x=$(...)` under `set -e` is a silent exit
waiting for its command to fail. This is the third instance in this
project. A check for bare command substitutions in assignments would find
the rest, and is a better use of effort than finding the fourth by hand.

### The microVM was never hanging: we were not collecting its output

Five runs on `squirrel-zapper`, two wrong diagnoses, and the machine was
innocent throughout.

**The symptom.** The media stage failed at the `privops` step with the
console section empty — first at a 300 s timeout, then at 900 s. Zero
bytes. I read that as "the guest never reached the serial port", which is
a reasonable reading and was wrong.

**The disproof.** Running QEMU by hand on that host, output going to a
pipe:

```
$ qemu-system-x86_64 -enable-kvm -m 512 -nographic -no-reboot -kernel …
SeaBIOS (version Arch Linux 1.17.0-2-2)
iPXE (http://ipxe.org) …
Booting from ROM...
```

Same host, same QEMU 11.1.1, same kernel. It prints. What differed was
that our code captured it:

```sh
out=$(timeout "$T" qemu-system-x86_64 … -nographic … 2>&1)
```

`-nographic` hands QEMU **both stdin and stdout**, and a command
substitution changes what those are. On this host the capture works; on
that one it yields nothing.

**Fixed** in both the backend and `bin/privops-selftest.sh`: stream to a
file, `</dev/null`, then read the file. A step that competes with its
caller for the terminal is its own bug.

**Two wrong turns, both worth naming.**

1. *Raising the timeout 300 → 900.* Treated a hang as slowness. Bought
   three times the wait for the same non-answer. The `set -e` half of that
   commit was a real fix; the number was not.
2. *Hunting the kernel image.* Six-path discovery, magic bytes, `MZ`,
   `/lib/modules` versus `/boot`. The kernel was correct from the first
   run.

**What made it survive five rounds.** "The microVM produced no output" and
"we did not collect the microVM's output" are the same observation. Every
tool I added — salvaging `report.txt`, salvaging `pipeline.log` — faithfully
preserved an emptiness that was manufactured at the point of capture.
Better evidence-keeping cannot fix evidence that was never created.

**The rule worth keeping:** a diagnostic must not share a failure mode
with the thing it diagnoses. `privops-selftest.sh` now streams for exactly
that reason, and it is the tool that should have existed before the first
remote run — it answers in seconds what the pipeline answers in twenty
minutes, because the backend depends on the host's kernel, busybox and
QEMU all at once and is therefore the part most likely to fail somewhere
new.

**Still unknown:** the precise mechanism by which command substitution
starves `-nographic` on that host and not this one. Recorded as unexplained
rather than guessed at. The fix does not depend on knowing.

## 2026-09-21 — Q2 — the NIC, measured: 140x, and a claim that held

`usb-net` was never chosen. P1 read it out of the UTM bundle because the
bundle demonstrably booted and the briefs' `e1000-82545em` was an undated
guess, and that was the right call for P1. Nobody had run the experiment
since. This is the experiment.

Everything below is one host — `pet-power-plant`, i7-8700B, QEMU 8.2.2,
`-accel kvm`, `-cpu Penryn,+ssse3,+sse4.1,+sse4.2`, 2 vCPU, 4096 MB — on
`vm/clone.sh` overlays, one changed `-device` line, slirp user networking
because that is what this project ships and a tap device would need root.

### Not over SSH

The first decision was what to measure with. OpenSSH 10.5p1 encrypting on
an emulated Penryn is CPU-bound, and an `scp` number would have been a
cipher benchmark with a NIC somewhere underneath it. So: a 40-line HTTP
server on the host that generates zeros from memory on `GET /zeros/<n>`
and drains a `PUT` to nothing, and `curl` in the guest reporting its own
`%{speed_download}` and `%{speed_upload}`. No TLS, no disk on either side
of the transfer, both directions named separately because they differ.
200 MB per transfer, three each way.

### The ordering trap, taken seriously and then failing to spring

The brief said to check whether `pmj/virtio-net-osx` is still required
before ranking anything, because four undated inherited claims have now
been wrong here — the `usb-tablet` kext, DNS-needs-configuring, Security
Update 2016-001, and `kvm.ignore_msrs`. The rule is right. This time the
claim survived it.

`-device virtio-net-pci` with no kext: no SSH after 420 s. The screenshot
is a fully drawn 10.9 login window, so the guest is fine and only the
network is absent — but a guest with no network cannot be asked why.

So the next boot had **three** NICs: `usb-net` (to have SSH),
`virtio-net-pci` and `e1000-82545em`, each on its own netdev. `ioreg`:

```
+-o S08@1  <class IOPCIDevice, registered, matched, active>
|     "name" = <"ethernet">
|     "compatible" = <"pci1af4,1","pci1af4,1000","pciclass,020000","S08">
                                            <- nothing below it

+-o S10@2  <class IOPCIDevice, registered, matched, active>
|     "compatible" = <"pci1af4,1100","pci8086,100f","pciclass,020000","S10">
| +-o AppleIntel8254XEthernet
|   +-o en1  <class IOEthernetInterface, registered, matched, active>
```

The virtio device is *enumerated* and unclaimed; the Intel NIC beside it in
the same boot is claimed and has an interface. `grep -rl 1af4` across every
`Info.plist` in `/System/Library/Extensions` finds nothing. There is no
virtio networking in 10.9 to re-test into existence. **The kext is still
required**, and the way that was established — two NICs in one guest, so
the failing device can be interrogated over the working one — is the part
worth keeping.

### The numbers

```
usb-net   down  1244668  1240753  1244742 B/s     168.5 s  169.0 s  168.5 s
usb-net   up    1269114  1268936  1269202 B/s     165.2 s  165.3 s  165.2 s
e1000     down  170921908  167376081  182956048   1.23 s   1.25 s   1.15 s
e1000     up     23072433   22873157   23813123   9.09 s   9.17 s   8.81 s
```

1.24 MB/s against 174 MB/s: **140x receive, 18x send.** What varied:
`usb-net` repeated to within 0.3%, `e1000` to 5%. The reason the CDC-ECM
numbers are so stable is printed by the guest itself:

```
en0: media: autoselect (10baseT/UTP <full-duplex>)      usb-net
en0: media: autoselect (1000baseT <full-duplex>)        e1000-82545em
```

1.24 MB/s is 9.9 Mbit/s. `usb-net` was running at exactly the speed it
said it was, and had been for the whole project. There was nothing to tune.

### The thing that is worth more than the benchmark

**Swapping the NIC under an installed guest does not work, in either
direction.** The e1000 run was supposed to be a clone of the same image
with one line changed. It never answered SSH — 420 s, login window on
screen. The two-NIC probe explains it: `en1` exists,
`AppleIntel8254XEthernet` is loaded, and `networksetup -getinfo Ethernet`
says *"Ethernet is not a recognized network service."* 10.9 writes the
interfaces it has seen into `/Library/Preferences/SystemConfiguration` and
creates *services* for them at that moment. A NIC it meets afterwards gets
a driver and a BSD interface and no service, so no DHCP, no route, no SSH.

A fresh `image/build-image.sh --nic e1000-82545em` — the flag added for
this — installed and answered SSH in 680 s, `en0`, DHCP, DNS, a service
called "Ethernet", `AppleIntel8254XEthernet 3.1.4b1` loaded. So the device
is fine; what is not fine is treating a NIC as a runtime knob.

Which reframes the whole question. **A NIC is a build-time input**, like
`--updates`: it goes in the manifest (`nic e1000-82545em`), and changing
the default migrates nothing. `vm/profiles/p4-approachb.args` and
`p4-linuxmedia.args` keep `usb-net` because the target disk they name was
installed with it, and they now carry the reason in a comment where
somebody would otherwise "fix" them.

### Reboot

Both working NICs survive. `en0` keeps its name, MAC, lease, DNS and route,
and throughput is unchanged afterwards, to within 0.02%:

```
                 before reboot            after reboot
e1000     down   170921908 B/s            170407892 B/s
e1000     up      23072433 B/s             22410107 B/s
usb-net   down     1244628 B/s              1244455 B/s
usb-net   up       1269186 B/s              1269195 B/s
```

Getting a reboot at all took three tries, and two of them went nowhere:

- `sudo shutdown -r now` — the account has **no password** by design
  (`firstboot.sh`: "the account is reached by SSH key"), so `sudo` refuses
  and an empty password does not satisfy it. The first e1000 run reported
  "sudo reboot refused" and then measured a *second* boot that was the same
  boot, which `uptime` would have caught and the harness did not ask. It
  asks now.
- `osascript ... to restart` — needs the GUI session, and `who` in the
  guest is empty over SSH.
- Monitor `system_reset` after an explicit `sync` — works, guest back in
  ~48 s. It is a power cycle rather than a shutdown, which is the same
  event `power_down_vm` already inflicts on every build, and the volume is
  journalled HFS+.

### Measurements that went nowhere, recorded because they were made

- **`e1000-82545em` on the `usb-net` image, 420 s, no SSH.** Read as "e1000
  does not work" for about ten minutes. It was the swap, not the device.
- **The first `usb-net` run's second boot.** Not a reboot. Discarded.
- **`virtio-net-pci` fresh install** was not attempted. The install stage
  waits for SSH, which needs a network the guest cannot have; it would have
  bought a 30-minute timeout and no new information.
- **`e1000e`, `vmxnet3`, the 82540em `e1000` alias** — not tested. Q2 named
  three candidates and one of them is 140x the incumbent.

### What would change the answer

A different QEMU. All of this is 8.2.2, and `squirrel-zapper` has 11.1.1 —
three major versions across all three device models. **G24** is that
hypothesis, and `bin/triangulate.sh` has a verdict function for it, added
in the same commit as the entry, because G21 sat in the ledger for a day
without one and the run that settled it printed nothing about it.

---

## 2026-09-21 — P4 — Task 37 — does Mavericks need SSE4.1?

The `-cpu` line has been `Penryn,+ssse3,+sse4.1,+sse4.2` since P1 copied it
out of a UTM bundle. Nobody had asked which part of it 10.9 requires.
`docs/test-hosts.md` had written the Mac Pro 1,1 off on that line — the only
Xeon in the fleet, and the only machine that can settle G14 — on a
prediction from CPU generations that nobody had ever run.

**Method.** A qcow2 overlay on the SSH-capable image
(`images/q2-e1000-fresh.qcow2`, built 2026-09-21 with e1000 and OpenSSH
10.5p1), one changed `-cpu` line, and `image/build-image.sh --stage verify`,
which boots without the installer media, waits for SSH, runs the verify
stage's own checks and powers the guest down. Overlay deleted after each
run; the source image's sha256 is byte-identical to its manifest afterwards
(`ff503395…`) and the golden was never opened at all.

**The golden itself could not be used**, and that is worth writing down: the
brief said to clone the golden, but `golden/p2-manual-install` is the P2
manual install — "no SSH", says its own `.meta`. It can only ever reach a
login window, which would not have answered the question. The SSH-capable
pipeline image was cloned instead, by the same overlay mechanism.

**The verify stage now asks the guest about its CPU.** `--cpu` names a QEMU
model; `machdep.cpu.*` is what the guest decided it got, and only the second
one settles anything. Added alongside the existing `diskbus` line, for the
same reason G16 has one: a fact read off a screen by hand once is not a
measurement, and a fact every build records is.

### Three boots, all green

```
vm/clone.sh (GOLDEN_DIR=images) q2-e1000-fresh cpu-<label>
image/build-image.sh --name cpu-<label> --stage verify --cpu <line> --ssh-port 229x
```

| `-cpu` | SSH | guest `machdep.cpu.features` | 64 MiB SHA-256 |
|---|---|---|---|
| `Penryn,+ssse3,+sse4.1,+sse4.2` | 20 s | `… SSE3 SSSE3 CX16 SSE4.1 SSE4.2 x2APIC VMM` | correct |
| `Penryn` | 20 s | `… SSE3 SSSE3 CX16 SSE4.1 x2APIC VMM` | correct |
| `Conroe` | 20 s | `… SSE3 SSSE3 x2APIC VMM` | correct |

All three: `10.9.5 (13F34)`, `hw=iMac14,2 2cpu`, OpenSSH 10.5p1 answering,
`diskbus=SATA`, `firstboot-daemon=removed`, and
`3b6a07d0d404fab4e23b6d34bc6696a6a312dd92821332385e5af7c01c421351` over 64
MiB of zeros — which is the right answer, so each guest did real work and
got it right rather than merely reaching a login window. `cpuextfeatures`
was `SYSCALL XD EM64T LAHF` and `leaf7_features` empty in all three.

**No panic, and therefore no panic screenshot.** The brief asked for one if
Conroe failed; it did not fail. The evidence here is the feature list the
guest printed, not the fact that it came up. (Noting for the next person
that `vm/screenshot.sh`'s colour count of 2 is white-on-black *text*, not a
blank screen — that misreading cost an hour in P3 and the script says so in
a comment now.)

### What it means

1. **10.9 does not require SSE4.1.** Conroe/Merom is SSSE3 without SSE4.1 —
   the Mac Pro 1,1's Woodcrest feature set — and the guest booted on it and
   said so itself. The floor is SSSE3, which is what was always cited. The
   SSE4.1 came from the bundle, not from the OS. **The Mac Pro is viable.**
2. **`+ssse3` and `+sse4.1` are redundant with `Penryn`; `+sse4.2` is not.**
   Bare `Penryn` reports SSSE3 and SSE4.1 already. QEMU's `Penryn-v1` has no
   SSE4.2 and should not — real Penryn had none, SSE4.2 arrived with Nehalem
   in 2008 — so the line asks for a feature the CPU it names never had.

**The default did not change**, and the reason is `decisions/0008`: a NIC
turned out to be *build-time state* in 10.9, so "booted with X" and
"installs with X" are demonstrably different claims in this guest. All three
boots above ran on an image *installed* under the default line. `lib/cpu.sh`
keeps VERIFIED and BOOTED apart for that reason and the default sits on the
only VERIFIED row. One `--cpu Conroe` full pipeline run is what would move
it.

### Measurements that went nowhere, recorded because they were made

- **`qemu64` refused under `enforce` on the primary host.** Not old
  hardware: QEMU's own `qemu64` model asks for `CPUID.80000001H:ECX.svm`,
  AMD's virtualization bit, on an Intel machine. Read as a host limitation
  for about a minute. The probe now prints the missing feature beside every
  rejection so nobody reads the next one that way — which is precisely the
  misreading that wrote the Mac Pro off.
- **`Nehalem`, `Westmere`, `SandyBridge`, `IvyBridge`, `Haswell-noTSX`,
  `host`, `qemu64` — not booted.** They are rows in `lib/cpu.sh` at NOT
  TESTED. The table would be worth nothing if it implied otherwise; this
  project has caught four inherited claims wrong and a fifth would be ours.
- **No install on anything but the default line.** Three boots, one install
  line. That gap is the whole reason the default did not move.
- **One QEMU, one host, KVM only.** All of it is 8.2.2 on Coffee Lake.
  Under TCG the emulator provides SSE4.1 whatever the host has, so a TCG run
  cannot distinguish any of this — which is why G25 reports CANNOT-SAY
  rather than CONFIRM when it was not run under a hardware accelerator.

### What would change the answer

The Mac Pro 1,1 itself. `bin/triangulate.sh --probe` now runs the `enforce`
test against a paused diskless VM for **every row of the table**, not just
the current line, and prints which ones the host can provide. That is two
minutes there with nothing installed. **G25** is the hypothesis and
`g25_verdict` in `lib/triangulate.sh` was written in the same commit as the
entry, because G21 sat in the ledger for a day without one and the run that
settled it printed nothing about it.

---

## 2026-09-21 — P4 — a stage is stale when its inputs moved

`image/build-image.sh` skipped a stage whenever its output file was
present. The failure that makes that wrong is the one this repository built
`bin/ingredient-fingerprint.sh` and `bin/image-staleness.sh` to prevent:
Renovate bumps the OpenCore pin in `vendor/sources.tsv`, the `opencore`
stage sees its `.efi` sitting there, skips, and the pipeline builds an image
out of stale firmware **without a word**. The staleness check answers that
question afterwards, per image, from the manifest; nothing asked it before
the image existed.

Each stage now writes what it consumed to `<output>.inputs` beside its
output and reruns when that record stops matching, naming what moved:

```
$ ./image/build-image.sh --freshness
esd       skip  inputs unchanged
opencore  run   inputs changed (source:opencorepkg-src)
ovmf      run   inputs changed (source:opencorepkg-src)
```

Not a second hashing scheme: `bin/ingredient-fingerprint.sh --stage <name>`
is the same list-and-digest one level down, and the half only the pipeline
knows — the checksum of what an earlier stage actually produced, the
accelerator, the SSH key fingerprint — is passed in as `key=value` and
folded into the same sorted list. The stamp holds the LIST rather than the
digest for the reason the manifest holds both: a digest says something
moved, a list says what.

Two decisions worth reading twice.

**`efi` and `install` name what they consume by its OUTPUT checksum**, not
by the pins that were supposed to produce it. `decisions/0004` says the
silent failure is a green build that emits different bytes; naming the pins
would miss exactly that.

**The installer media is the exception.** It is not byte-stable —
`mkfs.hfsplus` stamps the clock into the volume header, which is why the
manifest carries `mediacontent` separately — so `install` names it by the
digest of `media`'s *inputs*. Naming the file would reinstall a guest every
time the media was rebuilt from inputs that had not changed.

An output with no stamp is rebuilt rather than trusted: "I cannot tell" and
"it is fine" are different answers, the same distinction
`bin/image-staleness.sh` makes about a manifest with no ingredient lines.
That costs one rebuild per artifact that predates this, once.

`--freshness` is how every branch of the decision is tested in
milliseconds, including the one this exists for — a bumped pin in
`vendor/sources.tsv` reruns the firmware stages, names the pin, and leaves
`esd` alone.

Two knock-on fixes. `bin/triangulate.sh` asked the same question the
pipeline used to ask — is the output file there — and now asks
`--freshness` instead, because an output that is present but stale gets
rebuilt and reporting that as "reused" would credit a host with work it did
do. And `stage_payload` had no "already done" check at all; it has one now,
which is why the comment in `triangulate.sh` saying it never reuses is gone.

---

## 2026-09-21 — P4 — ccache for the firmware builds, and what the comparison found

`bin/triangulate.sh` exists to be run again, and the OpenCore and OVMF
builds are the expensive part of every run. EDK II shells out to the
compiler through generated makefiles and finds it on `PATH` — the GCC
toolchain runs `DEF(GCC_X64_PREFIX)gcc`, and `GCC_X64_PREFIX` is
`ENV(GCC_BIN)`, empty on a normal host — so a `gcc` on `PATH` that happens
to be `ccache gcc` is the whole mechanism. That seam is already ours: it is
where `-std=gnu17` and `-Wno-error` are injected.

### ccache is not installed here

`command -v ccache` on the primary host: nothing. So the comparison this
change deserves — a cache hit against a cold compile — **could not be run,
and is not claimed.** `lib/ccache.sh` is therefore off by default, in the
same shape and for the same reason as `MQG_CC_CEILING` in
`lib/compiler.sh`: the mechanism is complete, the switch is `MQG_CCACHE=1`,
and the file names the three places to update when somebody produces the
evidence. `MQG_CCACHE_BIN` is the test seam — a code path whose input is
"is this program installed" cannot be tested on a host that answers one
way, and installing a program to test a detection is not a reasonable
price.

### What *was* measured: the seam does not change the artifacts

Two cold boot-stack builds, both packages, primary host, gcc 13.3.0,
2026-09-21, **the same UTC day** so the `OpenCore.efi` build-date wrinkle
cannot confuse the comparison, and — see below — **the same build
directory**. One straight; one with `MQG_CCACHE=1` and a stand-in `ccache`
that does nothing but `exec "$@"`, which puts the shim, the `PATH` change
and the resolved-by-absolute-path wrapper in the way of every compile:

| artifact | no ccache | through the seam |
|---|---|---|
| `OVMF_CODE.fd` | `085eebf498d44ae55b6f26625ebc215259a0ed6eb2a895adc149522346754078` | identical |
| `OVMF_VARS.fd` | `5d2ac383371b408398accee7ec27c8c09ea5b74a0de0ceea6513388b15be5d1e` | identical |
| `OVMF.fd` | `f0994639dbe7354e1e6b4cced05dcd66005cc386cce17fc027490555c1b31007` | identical |
| `BOOTx64.efi` | `a351f1cd041526a99774ebc0df96453024b3cc0a83ed544b40964112b50b7bae` | identical |
| `OpenCore.efi` | `b6929f7cc5302c8bce2a3d08f311dd76cde22acde6ac705b9262e9a516b236e8` | identical |
| `OpenRuntime.efi` | `805d40c991921d1e445ff35f1adc86d360b40c5f3ca639f56f0a25332e56e1af` | identical |
| `OpenPartitionDxe.efi` | `593088f77c43a0341318f77806f8eecf9b97689f91f3d77218eedb4ecffdfa95` | identical |
| `OpenHfsPlus.efi` | `6ee1236cf1f992e61bac79bddbe6114326146adbc5b8afda6702503a02a6d2de` | identical |

All eight. 230 s and 236 s — the stand-in caches nothing, so equal times
are the expected result and not a disappointment.

That is evidence about the **shim**, which is the part this change
introduces, and about one thing that could have gone wrong quietly: a shim
first on `PATH` is also what `lib/compiler.sh` asks `--version`, and if it
had answered as anything but the compiler it wraps, turning ccache on would
have changed an image's recorded provenance *and* the stage input stamps
with it. It answered identically. It is **not** evidence about ccache
itself.

### The first attempt was wrong, and finding out why is the better half

The two sides were first built at two different directories —
`ccache-verify/a` and `ccache-verify/b` — and **seven of the eight
artifacts differed**, from a change that touches nothing. The one that
matched was `OVMF_VARS.fd`, which holds no code.

EDK II writes each module's debug-symbol path into the PE image it emits.
That is not news — it is exactly why `image/build-image.sh` refuses a
`MQG_BUILD_DIR` longer than about 120 characters, with a comment saying
EDK II enforces a 255-byte limit on debug symbol paths. What had not been
written down is the consequence: **`MQG_BUILD_DIR` is an input to the boot
stack.** Every checksum in `decisions/0004` means "this source set, built
on that date, under `$HOME/.local/share/mavericks-qemu-guest/build`", and a
second host comparing its numbers has to match the path as well as the
sources. A bullet now says so beside the `OpenCore.efi` build-date one,
which is the same kind of admission.

Worth noticing how this was caught: by running a comparison that was
*supposed* to produce eight "identical"s and getting eight differences
instead. A change that had been reasoned about rather than measured would
have shipped with "ccache does not affect the output" and no test anyone
could have run to doubt it.

### Where the cache goes

`$MQG_BUILD_DIR/ccache`, never the repository. The repo is NFS at 9–15 ms
per file create and a ccache directory is thousands of small files, so
caching there would be slower than not caching. Putting it in the build
tree also means one decision covers it: `bin/triangulate.sh --keep-build`
keeps the build tree and keeps the cache with it.

Every image manifest gains a `ccache` line saying whether the firmware was
compiled through it. The claim is that it changes nothing; an unverified
claim that leaves no trace is an unverifiable one. The stage input stamps
deliberately do **not** include it — installing ccache must not rebuild the
firmware, which would be the opposite of the point.

---

## 2026-09-21 — P4 — `triangulate.sh --keep-build`

`bin/triangulate.sh` tracked `$MQG_IMAGE_DIR` itself as created whenever
the run made it, so cleanup deleted the whole thing — the build tree with
it. That is a boot-stack rebuild on every run of a script whose entire
purpose is repeated runs on new hosts, and it is the same directory the
2026-09-20 log-salvage wound was about.

Leaving a host as it was found stays the default; this runs on other
people's machines and one of them is a Mac Pro serving files. `--keep-build`
is the middle setting: the build tree stays, everything else this run
created goes — so the gigabytes (images, target disks, installer media)
still leave, and a second run skips `opencore` and `ovmf`. The report now
has a "What stays on this host" section saying which of those happened and
what the next run will therefore skip, because a cleanup line that scrolls
past is not a report.

One trap on the way: `salvage_logs` found `build.log` and `ovmf-build.log`
by walking the created list, and `$MQG_IMAGE_DIR` was how the build tree
got onto it. Taking it off that list would have quietly undone the
2026-09-20 fix — a cleanup that runs on failure must not remove the
evidence of the failure — so the build tree is passed to `salvage_logs`
separately and a test says so.

Test count 470 → 497, across the three changes in this session: the stage
input stamps, ccache, and `--keep-build`.

## 2026-09-21 — P4 — the media build moves inside the microVM

`ap-juicer`, over SSH to a headless server:

```
loop-setup failed: org.freedesktop.UDisks2.Error.NotAuthorizedCanObtain
```

Every firmware stage had passed there. Only the media stage was blocked,
and it was blocked on udisks2's polkit policy, which grants `loop-setup`
to a user **at a seat**. `CanObtain` means polkit would allow it after an
interactive password prompt, which is no use to an unattended pipeline.

That is a property of the policy, not of that machine, so **every headless
host has it — including any CI runner P6 needs.** Two hosts never saw it
because both were desktops with someone logged in locally. A polkit rule
would fix it and is rejected: it needs root and is a permanent host
change, where the entire point of this path is needing neither.

### The data path, and why it costs nothing

The microVM already mounted HFS+ read-write and did privileged work
without host root; `privops_run` had been doing the ownership pass that
way since P4 began. The only thing it could not do was see more than one
disk.

So: `privops_run <target> <script> [ro:<img> | raw:<img>]...`. Extra
images are attached after the target as `/dev/vdb` onwards, `ro:` mounted
read-only and handed to the payload as `$MQG_SRC1`, `$MQG_SRC2`, `raw:`
handed over untouched as `$MQG_RAW<n>`.

**The source images are already files on this host, so QEMU maps them in
as more virtio disks. Nothing is copied in and nothing is copied out.**
That was the reason to prefer this over the alternatives considered:

* **9p or virtiofs.** Both need something the host may not have — `-virtfs`
  compiled in, or a `virtiofsd` binary and a daemon to run — and 9p needs
  guest kernel modules to stage. The whole task was removing host
  requirements.
* **Assembling into an image the host then never mounts.** That is what
  this is; the question was only how the guest reaches the sources.
* A second virtio disk carrying the source was the answer, and it is the
  cheapest one: the sources ARE disks already.

Roles are written into the initramfs rather than passed on the kernel
command line, for the same reason the module load order already was: order
is the point, a path with a space in it does not survive a cmdline, and
what the guest needs is the answer rather than the request.

### The one thing that could not move, and the way out

`BaseSystem.dmg` lives *inside* the ESD volume and is UDIF-compressed.
Only `dmg2img` can decode it, `dmg2img` runs on the host, and the host can
no longer read the ESD volume. Circular.

The way out is the only channel that exists between a guest and a host
that mounts nothing: **a raw disk.** The host creates a sparse file, the
guest `dd`s the one file onto it and prints the byte count and a SHA-256,
the host truncates to that length and checks its own read against the
digest before handing it to `dmg2img`. A short or torn write would
otherwise surface as a `dmg2img` failure that says nothing about where the
bytes went.

The same channel runs the other way for injection: the autoinstall hooks
and any `--firstboot-pkg`/`--extra-pkg` are staged into a directory, tarred
with the paths and modes they are to have, and extracted by the guest
straight onto the media. Straight onto the media, not into the initramfs
first, because the initramfs is RAM and the OpenSSH packages alone are
12 MB.

### The measurement, which is the part that decides it

Six runs on `pet-power-plant`, same InstallESD.dmg, warm cache, 6.4 GB
across 52,292 files:

| | before (udisks) | after (microVM) |
|---|---|---|
| `--autoinstall` | **78 s, 79 s** | **112 s, 117 s** |
| plus the payload and OpenSSH packages | — | 113 s |
| no `--autoinstall`, and with the test suite running beside it | — | 121 s |

**+38 s, 1.5x. Not twenty minutes.** And the whole of the difference is in
one place:

```
              host (rsync/coreutils)   guest (busybox)
BaseSystem     10 s                     15 s
Packages        5 s                      5 s
ESD check       9 s                     25 s
media check    11 s                     28 s
```

The copying is a wash — `cp -a` through virtio moves 4.83 GB of packages
in the same five seconds `rsync` did. **What costs the 38 s is busybox's
`sha256sum`, about 2.7x slower than coreutils' on this CPU** (193 MB/s
against 536 MB/s), run twice over Apple's packages. Worth knowing before
anyone optimises the copy, which is not the problem.

There is an obvious 25 s available — the ESD check only ever *attributes*
a failure the media check would find, so it could run only when the media
check fails — and it is deliberately not taken. G20 is why both checks
exist, and a check that runs only after something has already gone wrong
is a check nobody has evidence for on the runs that went right.

### The verification got stronger, not weaker

G20: three media builds in six wrote a corrupt `Essentials.pkg` while
`rsync` reported success, and the first version of the check passed on
that media because it read back through the mount that had just written
it — the page cache, not the disk.

The old check was a fresh *mount* on the same host. The new one is a
**fresh microVM**, booted after the writing guest has exited: a new
kernel, no page cache at all, every byte pulled through virtio off this
host's file. The guest prints `MQG-SUM-MEDIA <sha256>  <name>` and
`media/verify-installer-img.sh --check-sums` compares them against
`media/apple-packages.sha256` — still a constant, still Apple's own
values, still the one implementation in the script whose job that is.

All sixteen matched on all three runs of the new path, and the finished
media passes `verify-installer-img.sh` against the Mac-produced reference:
*"every path in the reference is in the build, and every required file is
present at the reference's size."*

The six setuid and setgid files survive. `cp -a` as uid 0 carries them
across, and `fix-ownership.sh` is unchanged: it still records the modes
before the chown that strips them and restores them after. One pleasant
side effect — the guest reads the ESD without udisks' `uid=`/`gid=`
overrides, so `ownership before: 0:0` now, where it used to say
`1000:1000`. The chown is no less necessary; the injected files still
arrive owned by the building user.

### What the reference comparison caught, which nothing else would have

The first assembled build was right in every file and wrong in five
directories: `System`, `System/Installation`, `System/Installation/Packages`,
`private` and `private/etc` came out `drwxrwxr-x` where Apple's are
`drwxr-xr-x`.

Cause: the injection tar carried **directory entries**, and a directory
entry in a tar sets the mode of the directory it lands on. Those five
already exist on the media; the tar had been built in a staging directory
created under this host's umask of 002, so extracting it carried 775 onto
Apple's 755. The fix is to archive files only (`find . ! -type d`), so tar
creates what is genuinely missing and leaves the rest alone.

Worth writing down because of *how* it was found: not by any test, and not
by the package checksums, which were perfect. `verify-installer-img.sh`
against the Mac-produced reference is the only thing in this project that
would have noticed, and it noticed on the first try.

### What this removes from a host, and what it adds

Adds: **nothing.** The microVM was already required and its requirements
are unchanged — QEMU, a static busybox, cpio, a readable kernel, and the
`hfsplus`/`nls_utf8` modules.

Removes: `udisks2`, `losetup`, `findmnt`, `lsblk`, **a desktop seat**, and
`rsync` — which nothing in the repository invokes any more, so
`boot/prereqs.sh`, `bin/triangulate.sh` and `bin/preconditions.sh` no
longer name it. It also removes the desktop-popup complaint at the root:
udisks mounted under `/run/media/$USER`, which is exactly where the
file-browser and notification handlers look, and nothing goes there now.

### What is untested

* **Every host that matters.** This ran on `pet-power-plant`, which is the
  one host that never had the problem. `ap-juicer` is where it should be
  tried next, and until it has been, G26 is resolved by construction
  rather than by measurement.
* **`media/content-digest.sh` still mounts through udisks** and so still
  needs a seat. It is a by-hand comparison tool, no stage calls it, and
  moving it would mean pushing 39,000 checksums through a serial console.
  Recorded rather than smoothed over.
* **The guest reads Apple partition maps by assuming the host kernel can.**
  `CONFIG_MAC_PARTITION=y` here; a kernel without it would see no
  partitions on the dmg2img output and the source mount would fail. It
  fails by name (`MQG-PRIVOPS-SOURCE-MOUNT-FAILED`) rather than as a
  target problem, which is the most that can be arranged from here.

Test count 505 → 517.

## 2026-09-21 — P4 — `--smbios`, and the G14 control that had never been run

`docs/host-profile.md` G14 has said since P1 that SMBIOS must not be
`MacPro5,1` **because** `AppleTyMCEDriver` panics on a non-Xeon CPU. The
"because" is mine, it is from P1, and it had never been tested. What was
actually observed was a panic on this host and its disappearance after the
SMBIOS changed; the causal story was reasoning.

The value lived at `boot/config/config.plist:367`, so asking the question
meant editing a tracked file and putting it back afterwards. Three phases
went by without anyone asking it.

### The parameter

`image/build-image.sh --smbios MODEL`, default unchanged, `lib/smbios.sh`
in `lib/cpu.sh`'s shape (VERIFIED / BOOTED / PANICKED / NOT-TESTED, with
the evidence for each, an unlisted value warned about rather than
refused), a manifest row beside `cpuline` and `compiler`, and
`bin/triangulate.sh --smbios` through to both pipeline call sites.
`docs/decisions/0010` has the reasoning and the table of what the flag
touches.

**It changes one field, `SystemProductName`, and leaves the serial, board
serial, ROM and UUID alone.** That is coherent because `PlatformInfo >
Automatic` is true: OpenCore derives the board id from the product name
out of its own Apple model database. The evidence is in P1's own panic
screen — it printed `Mac-F221BEC8`, a board id nobody in this project has
ever typed. The serials are deliberate placeholders and are not valid for
any Mac; minting realistic ones would be both pointless and wrong.

### Boot 1 — `MacPro5,1` on this non-Xeon host: it panics, exactly as in P1

An overlay on the `p2-manual-install` golden (`vm/clone.sh`, golden never
written), our own OVMF and our own OpenCore 1.0.7, no installer media, one
changed string. Panic on screen by 40 s and frozen there through 300 s:

```
AppleTyMCEDriver::start coreVIDPID = 0xffffffff Number of packages = 1 ...
panic(cpu 0 caller 0xffffff800032dc43e): Kernel trap at 0xffffff7f849116b7,
  type 13=general protection
  com.apple.driver.AppleTyMCEDriver :
  __ZN16AppleTyMCEDriver47enableInterruptForCorrectableMemoryCoreRegisterEPv
Mac OS version: 13F34
System model name: MacPro5,1 (Mac-F221BEC8)
```

`vm/screenshot.sh` verdict: `1280x800  2 colours  98764 lit px (9.64%) --
text (a menu or console)`. **Two colours is white-on-black TEXT**, which is
what a panic looks like; reading a low colour count as "blank screen" cost
an hour in P3 and would have cost this experiment its result.

This is P1's backtrace kext for kext, under a bootloader P1 never had, a
firmware P1 never had, and an **already-installed** guest rather than the
installer. So it is not stale, not an artifact of the reference OpenCore,
and not a property of Apple's installer.

### Boot 2 — the same overlay recipe with the default: Finder in 60 s

`185799 colours, 99.78% lit -- graphical`, the Mavericks desktop, dock and
all. Worth running and worth recording even though it proves nothing new:
without it, "the screen has text on it" would have been a claim about the
rig as much as about the SMBIOS. The only difference between the two boots
is one string in one plist.

### What this settles and what it does not

Settled: the observation. It survives three phases, two OpenCore versions,
two firmwares and installed-vs-installer, on a Coffee Lake i7.

**Not settled: why.** Every observation is still from one machine with one
non-Xeon CPU. The explanation — `AppleTyMCEDriver` loads because the model
names a Xeon machine and faults because the CPU is not one — is exactly as
untested as it was in P1. It is now labelled as untested in `lib/smbios.sh`,
in the ledger and in the ADR, which is the only thing that changed about
it.

The machine that can settle it is `ap-juicer`, and it is one command:

```
bin/triangulate.sh --full --cpu Conroe --smbios MacPro5,1
```

Installs and answers SSH → the explanation survives and G14 is
host-specific. Panics → the explanation is wrong and G14 keeps its advice
while losing its reason.

### `g14_verdict` says CANNOT-SAY for the interesting outcome, on purpose

A kernel panic is on the guest's SCREEN. It is not in the pipeline log,
not in QEMU's output and not in any exit status the harness can read — an
install that ends in a panic and one that ends in a timeout, a wedged disk
or a media problem are indistinguishable from there. So the verdict
function CONFIRMs or REFUTEs only when a guest actually INSTALLED with
`MacPro5,1`, and otherwise says CANNOT-SAY while naming the screenshots to
read and what each reading would mean. G21 sat a day with no verdict
function at all; `g26_verdict` printed a confident falsehood the day
before this. A misattributed verdict is worse than no verdict.

A new `guest_screen` fact carries `vm/screenshot.sh`'s own description of
the last thing the guest showed, so the CANNOT-SAY is at least concrete.

### Housekeeping

Both overlays, both NVRAM copies, the experimental EFI image and the
monitor sockets were removed afterwards; `/proc/*/exe` shows no QEMU left;
the golden still hashes to `05bce6f1…36f1`. The two QEMU logs and the
screenshots stay under `$MQG_IMAGE_DIR`, which is where the evidence for
the ADR came from.

Test count 517 → 545.

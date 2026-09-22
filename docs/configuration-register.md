# The configuration register

**Every knob this project sets, why it is set that way, how we know it is
doing its job, and what would have to be true to change it.**

Written 2026-09-21, after a day in which two explanations were refuted and
one inherited `sudo` step turned out never to have been needed.

## Why this document exists

`docs/host-profile.md` §4 is the **generalization ledger**: what is specific
to this host, and what a second host would have to do to falsify it. This is
the other axis. It asks of every setting, portable or not:

1. **What is it set to.**
2. **Why — and by whom.** Every row carries one of three words, and they are
   not interchangeable:
   - **MEASURED** — somebody here ran the experiment, and the entry says when
     and what came out.
   - **INHERITED** — it came from prior art, a bundle, or a guide. The source
     is named and dated. **Four inherited claims have been proven wrong in
     this project** (the `usb-tablet` kext, "DNS needs configuration",
     Security Update 2016-001, and `kvm.ignore_msrs=1`) and one right (no
     virtio-net in stock 10.9).
   - **REASONED** — derived from a property of the guest, the host or the
     spec, and never run. *A reasoned cause wearing the clothes of a
     measurement is the expensive kind of wrong*, which is why this word
     exists.
3. **How we know it is doing its job.** A test, a measurement, a ledger
   entry — or **nothing**, which is an honest and common answer and is
   written as "nothing" rather than smoothed over.
4. **What would have to be true to change it.** The falsifier, written
   before anybody tries. `docs/test-hosts.md` naming G14's falsifier in
   advance is the only reason 2026-09-21 was decisive; that is the standard
   every row is held to.

This register **cross-references the ledger, it does not duplicate it.** Where
a row says "G14" or "decisions/0009", that is where the argument lives.

## The count, and why it is not a table of numbers

An earlier draft of this document had a tidy tally here — so many MEASURED,
so many INHERITED, so many REASONED. **It was deleted, because it could not
be verified.** Most rows carry more than one of those words (a setting can be
inherited *and* since measured, or reasoned in one column and measured in
another), so any single number would have been a summary nobody could check
against the rows — which is the exact failure mode this register exists to
catch. **The word in each row is the authority.**

What can be said without counting anything:

- **Roughly half of what this project sets has never been tested.** Section
  12 ranks the half that matters.
- **Column three says "nothing" often enough that it is worth having.** The
  settings with no evidence behind them are not obscure ones — they include
  `vmport=off`, five `Booter` quirks, `vgamem_mb=64`, and the memory and CPU
  counts at install time.
- **The three most load-bearing settings are all measured**: the `-cpu` line,
  the SMBIOS model and the NIC each have an ADR, a table in `lib/`, and at
  least one full install behind them.

That is not a scandal — most untested settings are cheap to be wrong about —
but it is the reason for the cost ranking at the end.

---

## 1. Host state

| Knob | Value | Why — and by whom | How we know it is doing its job | What would change it |
|---|---|---|---|---|
| `kvm.ignore_msrs` | **`1` (`Y`) — and it should be turned off** | **INHERITED, and the inheritance was misread.** Applied 2026-09-17 on the authority of "Somlo and OSX-KVM" (`host-profile.md` §3) by a user `sudo`. Reading those sources on 2026-09-21 (`prior-art.md`, "Dated archaeology") shows Somlo's claim was about **MSR 0x199 on Yosemite 10.10, on kernels older than 4.7**, fixed upstream in **Linux 4.7 (2016-07-24)**. OSX-KVM has never given a reason in ten years. | **MEASURED, and the answer is that it is doing nothing for us.** G21 refuted on two hosts that run it OFF. Better: this host has `report_ignored_msrs=Y`, so every MSR it papers over is logged. Across 2.5 days of runs, the complete list of MSRs it has swallowed for a **macOS** guest is `0xe7`, `0xe8`, `0x300`, `0x3f8`, `0x3f9`, `0x3fa`, `0x60d`, `0x61d`, `0x621`, `0x690`, `0x6b0` — **every one of them a power/energy telemetry register**, read by `X86PlatformPlugin` after the system is already up. **`0x199` never appears. Nothing in the machine-check range appears.** | **Nothing. It is already falsified.** The remaining work is to stop asking users for the `sudo` step and to turn it off here — which is a host change and needs the user's say-so. **If it is ever proposed again**, the bar is a named MSR number in `dmesg` with `report_ignored_msrs=1`, and a demonstration that the guest misbehaves without it. |
| `kvm.report_ignored_msrs` | `Y` (distro default) | **Nobody chose it.** It is the kernel's default. | It is the only reason the row above could be answered with data instead of an argument. | **Leave it on.** OSX-KVM ships `report_ignored_msrs=0`; upstream (Bonzini, **2024-12-19**) calls that pair "not a supported configuration … the user has no clue that the guest is being lied to". Turning it off would delete this project's only instrument for the question. |

---

## 2. Accelerator, machine and CPU

| Knob | Value | Why — and by whom | How we know it is doing its job | What would change it |
|---|---|---|---|---|
| `-accel` | `kvm` | **REASONED**, and trivially: the host is x86 with VT-x (G2). `--accel tcg` exists for P6, where the host is Apple Silicon. | Every install and boot in this project. | Nothing — it is a property of the host, not a preference. The `tcg` path is the one that is **untested at full scale** here. |
| `-machine` | `q35` | **INHERITED** from the UTM bundle (`docs/utm-bundle-config.md`) and from Somlo's page (`-machine q35` from his 2014-05-16 revision). | **MEASURED, sideways**: G16 CONFIRMED on a second host — `ide-hd` on `ide.N` presents to the guest as **SATA/AHCI**, which the guest itself reports (`diskbus=SATA`). That is a q35 property; on `pc` it would be legacy IDE. | `pc` has never been booted here. It would need a full install, because the disk bus the OS was installed against is build-time state in this guest (see the NIC row). **Cost of being wrong: low** — nothing depends on q35 except the AHCI presentation, which works. |
| `vmport=off` | `off` | **INHERITED** from the reference config. | **Nothing.** Never tested with it on. | It suppresses VMware's backdoor I/O port. 10.9 has no VMware tools in it, so **REASONED** expectation is that it makes no difference either way. Flip it and boot; two minutes. Nobody has. |
| `-cpu` | `Penryn,+ssse3,+sse4.1,+sse4.2` | **INHERITED** from the UTM bundle in P1; **since MEASURED** (`decisions/0009`, `lib/cpu.sh`). Note the inheritance does *not* come from Somlo, whose `Penryn` hint is dated on his own page to "as of **Sierra**" (10.12) — three releases after our guest. | **MEASURED 2026-09-21**: full installs on two hosts and two QEMUs three major versions apart. Also measured: `+ssse3` and `+sse4.1` are **redundant** with the `Penryn` model, `+sse4.2` is not, and **10.9 does not require SSE4.1 at all** — `Conroe` installs. `lib/cpu.sh` keeps VERIFIED and BOOTED apart deliberately. | **A completed install on a shorter line.** `Conroe` is VERIFIED as of 2026-09-21 on `ap-juicer` and is the row to move to. The default stays only because it is the line with the most installs behind it. See G3, G25. |
| `-smp` | `2` | **INHERITED**, and the source does not support the claim. `vm/profiles/base-kvm.args` says "SMP is not optional here: Somlo reports that 10.9's first boot after install fails without it. Do not 'simplify' this to `-smp 1`." **That sentence has no citation and the archaeology did not find one.** Somlo's own command lines are `-smp 4,cores=2`, and only from his 2017 revision, which targets Sierra. | **MEASURED TODAY, and the ban is at least half wrong**: an installed 10.9.5 guest boots at `-smp 1`, answers SSH, reports `hw=iMac14,2 1cpu`, and computes the right SHA-256 over 64 MiB. It took 40 s to SSH against 20 s at `-smp 2`. **What is still untested is the specific claim**, which is about the *first boot after install*, not about a steady-state boot. | **A full unattended install at `--smp 1`.** That is ~20 minutes, not two. Until somebody runs it the warning should say what it actually rests on — an uncited claim about a different phase — rather than reading as a measured constraint. |

---

## 3. Memory and disk

| Knob | Value | Why — and by whom | How we know it is doing its job | What would change it |
|---|---|---|---|---|
| `-m` | `4096` | **INHERITED**: "memory/smp from the umbrella design's starting flags, themselves from the original bring-up brief's step 3" (`base-kvm.args`). Corroborated by an observation of Kostarelas's, not a measurement: 8 GB assigned, ~2.9 GB used at idle. | **MEASURED TODAY, and 4096 is not a floor**: the same installed guest boots and passes the verify stage's checks at **2048 MB** and at **1024 MB** (SSH at 40 s). | **What is untested is the install**, which is where memory actually gets used — Apple's installer unpacks into a ramdisk. A `--ram 2048` full install would settle it. The number matters for P6, whose CI budget is 7 GB total. **This is the cheapest untested row with the highest downstream leverage.** |
| `--disk-gb` | `60` | **REASONED.** Never justified in writing anywhere; 60 GB is a round number that comfortably holds a ~9 GB image. | **Nothing directly.** Indirectly: every built image is ~8.8–9.2 GB actual, so the allocation is ~7x headroom and qcow2 is sparse, so being generous costs nothing on disk. | It would have to start costing something. On a filesystem without sparse files, or in P6's 14 GB CI budget, the **virtual** size matters even when the actual size does not. Nobody has checked whether 10.9's installer cares about the target's size — the size guard in the install path exists because *choosing* the disk needed one, not because 60 was validated. |

---

## 4. SMBIOS

| Knob | Value | Why — and by whom | How we know it is doing its job | What would change it |
|---|---|---|---|---|
| `SystemProductName` | `iMac14,2` | **MEASURED, in the weakest useful sense**: P1 changed it away from the reference config's `MacPro5,1` because that panicked, and this was the first value that worked. Not a value shown to be best. | **MEASURED**: full unattended installs on **three** hosts, each then booting without installer media and answering SSH; the installed guest reports `hw.model=iMac14,2`, so the override reaches the installed system and not only the installer. | **Nothing needs to change it, and as of 2026-09-22 we know why the alternative fails** — see §11's G14 entry. `MacPro5,1` is not unusable "on a non-Xeon host"; it is unusable **under QEMU at all**, because QEMU never sets `MCG_CMCI_P` and the driver writes `IA32_MC0_CTL2`. The falsifier is a host kernel older than 6.0. |
| Identity fields | `SystemSerialNumber` `W00000000001`, `SystemUUID` all zeroes, `MLB` `M0000000000000001`, `ROM` `112233445566` — the sample's placeholders | **REASONED, and deliberately.** "Generating a plausible serial number is what you do when you want a VM to pass for a real Mac to Apple's servers; we want the opposite" (`boot/config/README.md`). | Three installs and three SSH-answering guests, so nothing in 10.9's boot path consults them. | Something in the guest would have to need a well-formed serial. Nothing does. **If a real-looking serial ever appears in a diff, that is the thing to question.** |
| `Automatic` | `true` | **REASONED**, and it is what makes the row above coherent: OpenCore derives the board id, firmware features and platform feature word from the product name. `Mac-F221BEC8` is the board id P1's panic printed **without anyone ever having typed it**. | That derivation is the measurement: the board id moved when the product name moved. | Nothing. It is why `--smbios` can be a one-variable experiment at all. |

---

## 5. Firmware and boot stack

| Knob | Value | Why — and by whom | How we know it is doing its job | What would change it |
|---|---|---|---|---|
| Firmware | **our own OVMF**, from the pinned `acidanthera/audk` tree | **MEASURED.** P3 Task 8: Debian's stock OVMF 2024.02 does not work with OpenCore here — OpenCore runs, renders nothing, never boots macOS — and it fails identically with khronokernel's reference OpenCore 0.6.6, so it is not our build. Task 9 replaced it and it worked immediately. | Every boot since P3. G5 was **retired** by this change rather than tested. | It is Tier 0 by design (`decisions/0004`). A stock firmware that worked would not change the decision, because the decision is about provenance, not about whether a shortcut exists. |
| Firmware wiring | split `pflash` CODE (ro) + VARS (rw) | **MEASURED.** P1 tried pflash once and got a black screen — but with the *reference* firmware, which is a complete `-bios` image, not the CODE half of a pair. Ours genuinely splits 3,653,632 + 540,672 = 4,194,304. | **MEASURED**: EFI variables persist across three power cycles, 0 → 24 variables, including ones macOS wrote. G15 resolved. | Nothing. `-bios` demonstrably loses variable persistence, which is a capability, not a preference. |
| `OpenHfsPlus.efi` | loaded, instead of Apple's `HfsPlusLegacy.efi` | **REASONED** from provenance (`decisions/0002`): Apple's driver is extracted from firmware, no source, Tier 2 by construction. Removing it is the entire reason P3 exists. | **MEASURED**: it costs **3.3 s** at boot, and Apple's driver *will not run* on our firmware at all — so the trade the decision anticipated turned out not to be a trade. | Nothing. The alternative does not work here. |
| Drivers loaded | `OpenRuntime`, `OpenPartitionDxe`, `OpenHfsPlus` | **REASONED** per driver, each with a stated job (`boot/config/README.md`). The sample's other 47 disabled examples are **removed rather than disabled**, so the list is the list. | Every boot since P3 Task 7. Nobody has removed one to see what breaks. | Each is falsifiable in one boot. `OpenPartitionDxe` is the one most likely to be redundant on our GPT-only layout — **nobody has tried**. |
| `Kernel > Add` | `Lilu.kext`, then `VirtualSMC.kext`, in that order | **MEASURED** (order) + **REASONED** (necessity). `VirtualSMC`'s `Info.plist` declares `OSBundleLibraries > as.vit9696.Lilu = 1.2.0`, so Lilu must come first. | **MEASURED**: `DSMOS has arrived` appears with OpenCore-injected kexts and **no `-device isa-applesmc` anywhere**, which is why this project needs no OSK string — unlike every guide it inherited from. | The kexts dropping 10.9 support. Checked concretely, not assumed: both declare `com.apple.kpi.* = 10.0.0` (Darwin 10 = 10.6) and 10.9 is Darwin 13, and neither Mach-O carries a stricter `LC_VERSION_MIN_MACOSX`. |
| `FakeSMC-32.kext` | **not shipped**, though the reference image has it | **MEASURED**: P3 answered Task 6's experiment — it was redundant. | The boot that works without it. | Nothing. |
| `Kernel > Block` | **empty**, deliberately | **MEASURED, negatively.** The reference ships a disabled block entry for `com.apple.driver.AppleTyMCEDriver`; P1 flipped it to `true` and **nothing changed** — same panic, same backtrace. Carrying it forward would be cargo cult and would confound the SMBIOS experiment. | The panic that did not go away. | **This is now a live question again.** See §7: the community's remedy for exactly this symptom is a personality-override kext, not a bundle-ID block — which would explain why the block did nothing. |

---

## 6. Devices

| Knob | Value | Why — and by whom | How we know it is doing its job | What would change it |
|---|---|---|---|---|
| USB controllers | `ich9-usb-ehci1` + three `ich9-usb-uhci` companions at `0x1d.*` | **MEASURED.** P1: 10.9's `AppleUSBXHCI` cannot drive QEMU's XHCI at all. | **CONFIRMED on a second host** (G13) under QEMU 11.1.1 — so the finding survives three major QEMU versions. One of the few findings here that generalizes unchanged. | A QEMU whose XHCI 10.9 can drive, or a newer guest OS. Neither is in scope. |
| Input | `usb-kbd` + `usb-mouse` | **INHERITED** ("OS X cannot use `usb-tablet`") — **and the inheritance is stale**: `usb-tablet` was fixed in QEMU in **2017**, by the very author whose workaround kext the briefs cite as evidence. | **Nothing.** `usb-mouse` works; `usb-tablet` has not been re-tried on a modern QEMU here. | One boot with `usb-tablet`. **Cost of being wrong: low** (a mouse that needs grabbing rather than one that does not), but it is the canonical example of an expired claim and it is still un-retested. |
| NIC | `e1000-82545em` | **MEASURED 2026-09-21** (`decisions/0008`, G24, Q2): one changed `-device` line, 200 MB of HTTP. `usb-net` is CDC-ECM and negotiates `10baseT` — 1.24 MB/s down, 1.27 up. This device negotiates `1000baseT` — **174 MB/s down, 23.3 up. 140x.** `virtio-net-pci` produces no interface at all, which confirms the one inherited claim that held. | The guest names the cause itself, so the *ranking* should be a property of the device models and portable; the *ceiling* is this host's slirp and is not. | A host whose QEMU cannot offer the device refutes the default outright — `triangulate.sh --probe` checks. **Note the constraint this row carries: a NIC is build-time state in 10.9.** The OS records interfaces in `/Library/Preferences/SystemConfiguration` and will not configure one it meets for the first time on an installed system — measured, in both directions. |
| `-netdev` | `user` (slirp) + `hostfwd` | **REASONED**: it needs no root and no host bridge, which is this project's whole posture. | Every SSH-answering guest. The inherited claim that "DNS needs pointing at 1.1.1.1" was **refuted** — DNS worked untouched. | Throughput. Every number in the NIC row went through slirp; a bridge or `passt` would raise the ceiling and would also need privileges this project refuses. |
| Display | `VGA,vgamem_mb=64` | **INHERITED** from the reference bundle's shape, and Kostarelas's observation that ~3 MB of VRAM made Chess and video into slideshows. | **MEASURED, partly**: P3 established that screen resolution is a **firmware setting, not a driver problem**. Nothing has measured what `vgamem_mb` buys. | The builds run `-display none`, so 64 MB of vgamem is being allocated for nobody on every pipeline run. **Nobody has tried the default 16.** Cheap to test but needs a code change, since the value is not a parameter. |
| `-display none` + monitor socket | headless | **MEASURED, as method.** P3: boot can be timed and screenshotted from the host without a window, and `vm/screenshot.sh` reads the framebuffer over the socket. | Every automated run. | Nothing. It is what makes the pipeline unattended. |

---

## 7. Storage attachment

| Knob | Value | Why — and by whom | How we know it is doing its job | What would change it |
|---|---|---|---|---|
| Target disk | `ide-hd,bus=ide.0` | **INHERITED** shape, **MEASURED** effect. | G16 **CONFIRMED** on a second host: the guest reports "Connection Bus: SATA". | A machine type other than q35. |
| OpenCore image | `usb-storage` | **MEASURED.** Under stock OVMF it was never enumerated over USB and needed an IDE workaround; **our** OVMF finds it over USB, like the reference firmware did. That was a firmware difference. | Every boot since P3 Task 9. | Nothing. |
| Installer media | `ide-hd`, **not** `ide-cd` | **MEASURED.** Our build is a GPT *disk* image; attaching it as a CD made OpenCore classify it ATAPI, which the tight `ScanPolicy` correctly excluded — "OCB: System has no boot entries". | The install that then worked. | Nothing. `ide-hd` is both the accurate device type and the permitted one. |
| `snapshot=on` | on the OpenCore image **and** the installer media | **MEASURED, and it was found by an instrument rather than by reasoning.** Without it every boot rewrote the bootloader image — builds `ba9eab36`, `7f4ce3aa`, `0ad83718`, `11c5ca9a` — so the manifest recorded a different `opencore` for two builds that used the same one. On the media, macOS mounted it read-write and `mds` wrote a `.Spotlight-V100` store with a fresh UUID, so two builds from one ESD recorded different `mediacontent` digests. | `image/compare-images.sh`, which is what it is for. And G20, **CONFIRMED PORTABLE** on a second host. | Nothing. An input a run modifies is not an input. G20 makes this one of three requirements for any host that boots media it also builds. |

---

## 8. OpenCore `config.plist`

**Every divergence from OpenCorePkg 1.0.7's `Docs/Sample.plist` is already
enumerated, with its evidence, in [`boot/config/README.md`](../boot/config/config.plist).**
That file is columns 1 and 2 done well. What it does not have is columns 3 and
4, so this section adds only those, and only where the answer is interesting.

| Setting | Value | How we know it is doing its job | What would change it |
|---|---|---|---|
| `Misc > Security > ScanPolicy` | `0` | Every picker that found the disk. An HFS+ volume on a USB-attached disk is exactly the layout the sample's `17760515` excludes — and the `ide-cd` failure above is a live demonstration of what a tight policy does. | Tightening it would be a **security** decision with a boot cost; nobody has proposed one. |
| `Misc > Security > SecureBootModel` | `Disabled` | **REASONED** from a property of 10.9 — Apple Secure Boot arrived with the T2 in 2018. Never tested at `Default`. | 10.9 would have to grow a notion of Secure Boot. It will not. **Cost of being wrong: zero.** |
| `Misc > Security > Vault` | `Optional` | **MEASURED, negatively**: with the sample's `Secure`, OpenCore refuses to boot at all without a `vault.plist`/`vault.sig` we do not produce. | Producing a vault. Note what `Optional` means: the config is **not tamper-evident**. It is reproducible instead — rebuild from this repo and compare. |
| `Misc > Debug > DisableWatchDog` | `true` | **REASONED** from `decisions/0002`: the watchdog would turn `OpenHfsPlus`-slow into reboots-forever. The slowness was then **measured at 3.3 s**, which is nowhere near a watchdog timeout. | **This row is a bring-up accommodation that has outlived its reason.** The measured cost is 3.3 s. Turning the watchdog back on is a one-boot experiment nobody has run, and leaving it off means a genuinely hung boot hangs forever instead of rebooting. |
| `Misc > Boot > HideAuxiliary` | `false` | **REASONED**: during bring-up an entry hidden behind a keystroke is indistinguishable from one OpenCore never found. | Bring-up ending. It is a diagnosability choice, and the pipeline is now unattended, so it buys less than it did. |
| `Misc > Boot > Timeout` | `5` | **MEASURED, and found defective**: with an empty NVRAM the picker's default is entry 1, the OpenCore disk itself, which re-enters `BOOTx64.efi`, fails `EFI_ALREADY_STARTED` and hangs. P4 fixed the automation; the config defect is still a config defect. | Setting a correct default entry. Recorded in `p3-full.args` with two traps for anyone automating it. |
| `Misc > Security > ExposeSensitiveData` | `6` (sample default, **kept on purpose**) | Bit `0x2` writes OpenCore's version into NVRAM, which is the only direct evidence of *which* bootloader ran. Task 7 used it to confirm our 1.0.7 and not an old 0.6.6 image. | Turning it off would delete that evidence. Do not. |
| `Booter > Quirks > AllowRelocationBlock` | `true` | **INHERITED from a 0.6.6 config on a different hypervisor (TCG on Apple Silicon), never re-tested on 1.0.7 under KVM.** So are the other four the reference enables. | **Nothing has tested any of the five.** Task 7's failure tree changes one quirk at a time *if* a boot misbehaves — and no boot has misbehaved, so the tree has never run. **This is the largest block of untested inherited settings in the project.** |
| `Booter > SetupVirtualMap`, `FixupAppleEfiImages` | sample defaults **kept over the reference's** | **REASONED**: the reference leaves `SetupVirtualMap` off, 1.0.7's sample has it on, and it is what OVMF-based setups generally use; `FixupAppleEfiImages` did not exist in 0.6.6 at all. | These are the **first two things to flip, one at a time,** if a boot ever fails in the booter. Written down before the failure, which is the point. |
| `Kernel > Emulate > DummyPowerManagement` | `true` | **INHERITED from the reference, corroborated by P1**: the boot log shows the expected consequence, `ACPI_SMC_PlatformPlugin::start - waitForService(AppleIntelCPUPowerManagement) timed out`. The quirk turns a panic into that harmless timeout. | Never tested off. Worth noting that the MSRs `ignore_msrs` swallows (§1) are exactly this subsystem's — so power management is the one area where the guest is demonstrably being lied to. |
| `Kernel > Quirks > PanicNoKextDump` | `true` | **MEASURED, as method**: P1's entire diagnosis rested on reading a backtrace off the screen, which a kext dump scrolls away. | Nothing. It is an instrument, and this project's instruments have earned their keep. |
| `UEFI > APFS > EnableJumpstart` | `false` | **REASONED** from a property of 10.9: it cannot mount APFS, so there is nothing to find. | Nothing. |
| `SetApfsTrimTimeout` | sample default `-1` (the reference **sets** it) | **REASONED**: 10.9 predates APFS by four years. `boot/config/README.md` names this as "the clearest example in this file of a reference setting that is *copied* rather than *chosen*" — and declines to copy it. | Nothing. Recorded because the reasoning is the transferable part. |
| `NVRAM boot-args` | `-v keepsyms=1` | **MEASURED, as method**: every P1 diagnosis came from reading boot text, and `keepsyms=1` is what makes a backtrace show symbol names. | A release build might want it quiet. Note `NVRAM > Delete` removes `boot-args` before adding it, which matters now that variables persist — a one-variable-per-experiment lab cannot have a stale `boot-args` outliving the config that set it. |
| `prev-lang:kbd` | `en-US:0` | Stops the first-boot language picker. Measured by the unattended install working. | A non-US guest. |
| `run-efi-updater` | `No` | **REASONED**: stops Apple's EFI updater trying to flash firmware that does not exist. Never tested without. | **Cost of being wrong: unknown**, and it is the one row in this section where the failure mode would be interesting rather than boring. |

---

## 9. Build toolchain

| Knob | Value | Why — and by whom | How we know it is doing its job | What would change it |
|---|---|---|---|---|
| C dialect | `-std=gnu17`, stated for both OpenCorePkg and OvmfPkg | **MEASURED, by a refutation.** G22: on a GCC-15-era host `--build` died with `libDER_config.h:31: typedef BOOLEAN bool; error: two or more data types in declaration specifiers`. `bool` is a keyword in C23, GCC 15 defaults to `-std=gnu23`, EDK II sets no `-std` and compiles with `-Werror`. Reproduced on the primary host with a `gcc` wrapper prepending `-std=c2x`. | The build that then worked — and, on a real GCC 16 host, an OpenCore stage that built clean in 397 s. | Nothing, but note what it is **not**: pinning a dialect is not pinning a compiler. The same sources still compile to different bytes on different GCCs — **measured**: `OvmfPkg` under C23 yields `3373692a…` where gnu17 yields `195c4dcf…`. |
| `-Wno-error` | applied to both firmware builds | **MEASURED, by a second refutation in the same run.** GCC 16 invented `-Werror=unused-but-set-variable=` and MdeModulePkg tripped it under EDK II's own `-Werror`. | The warnings are **still printed** — `-Wno-error` cancels the promotion, not the diagnostic. | Upstream fixing its own warnings. Until then, inheriting a stranger's `-Werror` means every new compiler warning is a build break in a component we do not maintain. |
| Compiler range | **gcc 13 through 14, VERIFIED only at 13.3.0** | **Honest mixture, and the file says which is which.** 13.3.0 is measured (every checksum in `decisions/0004`). 14 is **EXPECTED, never built**. 15 and 16 are deliberately **above the ceiling**. Below 13 is **NOT TESTED** and is a *refusal*, not a warning — "a version this project has never seen is not a version to guess about". | `lib/compiler.sh` gates both build scripts; `tests/compiler.bats` asserts the constants so the suite reminds you that you are changing a claim. | **A complete run above 14.** If it builds *and the artifact checksums match*, raise `MQG_CC_CEILING` and update `decisions/0004`, `INGREDIENTS.md` and G22 — all four, or the next reader gets a number with no evidence behind it. The failure mode that remains up there is the silent one: **a green build with different bytes.** |

---

## 10. Guest software

| Knob | Value | Why — and by whom | How we know it is doing its job | What would change it |
|---|---|---|---|---|
| Guest OpenSSH | the family's build, on by default | **MEASURED, twice over.** Stock 10.9 answers on OpenSSH 6.2p2, which cannot read an Ed25519 `authorized_keys` line and offers only host keys a 2026 client refuses. | Every verify stage: `ssh=OpenSSH_10.5p1, LibreSSL 4.3.2`. `--no-openssh` still builds the stock image and the manifest says which you got. | Nothing. Goal #1 is a guest usable for development, and SSH is the entire interface. |
| Host SSH key | RSA-4096 | **REASONED** from a property of the guest: 10.9's OpenSSH 6.2 predates Ed25519. | Every guest built here authorizes it. | The guest's own OpenSSH is now 10.5p1, so **this constraint may already be stale for the installed system** — but the key is authorized during install, when the stock sshd is what is running. Nobody has checked which half binds. |
| `--updates` | `none`, with one implemented value | **REASONED, as a deliberate non-answer.** Q1 asks whether images should carry post-10.9.5 updates and names P4 as its deadline. The pipeline does not answer it; it leaves it *answerable*, with a switch rather than the absence of a switch. | The switch exists and is recorded in the manifest. | Q1 being answered. Note that "Security Update 2016-001" is one of the four inherited claims already proven wrong here — it was the wrong update number. |

---

## 11. Today's measurements

Four one-variable boots, 2026-09-21, all against a qcow2 **overlay** on
`images/q2-e1000-fresh.qcow2` (the SSH-capable pipeline image), run through
`image/build-image.sh --stage verify`, which boots **without** installer media,
waits for SSH, runs the verify stage's own checks and powers the guest down.
Each overlay was deleted afterwards. **The golden was never opened** —
`golden/p2-manual-install.qcow2` is the P2 manual install, has no SSH by its
own `.meta`, and could only ever reach a login window.

| Changed line | SSH | Guest reported | 64 MiB SHA-256 |
|---|---|---|---|
| `--smp 1` | **40 s** | `hw=iMac14,2 1cpu 4294967296` | correct |
| `--ram 2048` | 40 s | `hw=iMac14,2 2cpu 2147483648` | correct |
| `--ram 1024` | 40 s | `hw=iMac14,2 2cpu 1073741824` | correct |
| `--cpu Nehalem` | 40 s | `cpubrand=Intel Core i7 9xx (Nehalem Class Core i7)`, `POPCNT` gained | correct |

All four also reported `diskbus=SATA`, `10.9.5 (13F34)`,
`firstboot-daemon=removed` and `ssh=OpenSSH_10.5p1`. The correct hash is
`3b6a07d0…c421351`, the same constant the CPU ladder used on 2026-09-21, so
each guest **did real work and got it right** rather than merely reaching a
login window.

`--smp 1` and `--ram 1024` both took 40 s to SSH where the default pair takes
20 s. Two data points, one host; not a scaling law.

### What these do and do not settle

- **`-smp 1` boots.** The ban in `base-kvm.args` cites Somlo for a claim about
  *first boot after install*; the archaeology found no such claim on his page
  in any revision, and what he actually runs is `-smp 4,cores=2` from 2017
  onward, for Sierra. **The steady-state half of the ban is now refuted.**
  The install half is untested and costs ~20 minutes to test.
- **1024 MB boots an installed guest.** It says nothing about the install,
  which is where Apple's installer builds a ramdisk.
- **`Nehalem` moves from NOT-TESTED to BOOTED** in `lib/cpu.sh`. That matters
  for G18 and `decisions/0005`: Nehalem is the first model with EPT, which is
  what VMware Fusion in the guest would need. The row existed precisely so
  that entry had somewhere to land.
- **None of them is an install**, so none of them may be written as VERIFIED.
  `lib/cpu.sh` keeps VERIFIED and BOOTED apart because `decisions/0008`
  demonstrated that "booted with X" and "installs with X" are different
  claims in this guest.

### And one measurement that was not cheap, but was decisive: G14

The register's SMBIOS row pointed at an open question — `MacPro5,1` panics,
and **three explanations had been refuted in a day, all three of them
reasoned rather than measured.** The falsifier `docs/test-hosts.md` and G14
had both named in advance was "read the panic's faulting address and compare
it against the `IA32_MCi_CTL2` range, or run the same image under TCG."

**The first half needed no new run. The answer was already on a screen
nobody had read.** macOS prints the CPU registers above the backtrace, and
the panic dump says:

```
panic(cpu 0 caller 0xffffff80098dc43e): Kernel trap at 0xffffff7f8aefc6b7,
    type 13=general protection, registers:
RAX: 0xffffff7f8aefc6ac, RBX: 0x0000000000000000, RCX: 0x0000000000000280, ...
RIP: 0xffffff7f8aefc6b7
...
com.apple.driver.AppleTyMCEDriver :
    __ZN16AppleTyMCEDriver47enableInterruptForCorrectableMemoryCoreRegisterEPv + 0xb
System model name: MacPro5,1 (Mac-F221BEC8)
```

**`RCX: 0x0000000000000280`.** RCX is the MSR index register for `rdmsr` and
`wrmsr`. `0x280` is `IA32_MC0_CTL2` — the first CMCI control register. The
faulting instruction is eleven bytes into a function called
"enable **I**nterrupt **F**or **C**orrectable **M**emory". There is no
inference left to make.

Reproduced from scratch on 2026-09-22 as a one-variable control on a fresh
overlay of the SSH-capable image — `SystemProductName` the only thing
changed, same firmware, same OpenCore build, same CPU line, same host: panic
at 40 s, no SSH in 180 s where the default answers in 20–40 s.

**Why `ignore_msrs` cannot help, and the date it stopped being able to.**
`ignore_msrs` suppresses the #GP *only* for handlers that return the
`KVM_MSR_RET_UNSUPPORTED` sentinel. A handler returning plain `1`
short-circuits before `ignore_msrs` is read, injects #GP, **and logs
nothing.** Since commit `281b5278` (author date **2022-06-10**, first release
**v6.0, 2022-10-02**) the whole range `0x280`–`0x29F` is dispatched to
`get_msr_mce`/`set_msr_mce`, which `return 1` when `MCG_CMCI_P` is clear —
and **QEMU never sets that bit** (`MCE_CAP_DEF = MCG_CTL_P|MCG_SER_P`;
`kvm.c` masks down, never up).

That also explains the one piece of evidence that looked unhelpful: with
`report_ignored_msrs=Y`, the panic run logged exactly **one** ignored MSR,
`0x300`, and **nothing in the `0x280` range**. The code says that is precisely
what a #GP there looks like, because that path emits no log line at all.

**The falsifier, written down before anyone tries:** before v6.0 the range
fell through to `default:` → `UNSUPPORTED`, where `ignore_msrs=1` *would*
have suppressed it and *would* have logged `ignored rdmsr: 0x280`. So **on a
host kernel older than 6.0 with `ignore_msrs=1`, `MacPro5,1` should boot here
without panicking.** No host in the fleet is old enough. If it panics there
anyway, this explanation is wrong too — which would make it four.

**And the second half of the falsifier was run, and it agrees.** The same
overlay, the same OpenCore image, the same firmware, the same `-cpu` line,
the same host — **one variable, `-accel tcg` instead of `-accel kvm`**:

| `-accel` | SMBIOS | Result |
|---|---|---|
| `kvm` | `iMac14,2` | SSH in 20–40 s |
| `kvm` | `MacPro5,1` | **panic at 40 s**, `RCX=0x280`, no SSH in 180 s |
| `tcg` | `MacPro5,1` | **SSH at 80 s**, guest reports `10.9.5` and `hw.model=MacPro5,1` |

TCG emulates the MSR rather than delegating it, and the panic does not
happen. So `MacPro5,1` is not "unusable on a non-Xeon host" — the Xeon
panicked too. **It is unusable under KVM and usable under TCG**, which is a
property of KVM's machine-check emulation rather than of Mavericks or of any
hardware we own. **P6 runs TCG**, which makes this more than a curiosity.

---

---

## 12. Where a wrong answer would cost most

Ranked by cost × likelihood of being wrong, not by either alone.

### 1. The five `Booter > Quirks`, inherited from OpenCore 0.6.6 under TCG

`AllowRelocationBlock`, `AvoidRuntimeDefrag`, `EnableWriteUnprotector`,
`ProvideCustomSlide`, `EnableSafeModeSlide`. **None has been tested on 1.0.7
under KVM.** They are the settings that decide whether `boot.efi` gets loaded
and relocated correctly, so a wrong one does not produce a warning — it
produces a hang or a panic that looks like something else entirely. They came
from a different bootloader major version on a different hypervisor on a
different CPU architecture, and they are the largest untested block in the
project. The failure tree that would change them one at a time exists and has
never run, because nothing has failed.

**Cost of being wrong: an unexplained boot failure on the next host, mistaken
for a hardware problem.** Exactly the shape of the year the Mac Pro 1,1 spent
written off.

### 2. `-m 4096` and `-smp 2` for the *install*

Both numbers came from a bring-up brief and neither has been tested at
install time. **P6's entire budget is 7 GB of RAM and 3 cores.** If 4096/2 is
a real floor, P6 has roughly one guest's worth of headroom and no margin; if
it is not — and the boots above suggest it is not — P6 has been planning
against a number nobody measured. This is the cheapest wrong answer to
*discover* (one 20-minute install) and one of the more expensive to carry
undiscovered into a phase that is budget-constrained by design.

### 3. The compiler above the ceiling

`lib/compiler.sh` declares 13–14 and has verified 13.3.0. The two known
failures above that are **fixed**, and neither fix has been tested up there.
The remaining failure mode is the silent one: **a green build that produces
different bytes.** It is already measured that C23 changes `OVMF_CODE.fd`, so
this is not hypothetical. A wrong answer here does not break a build; it
breaks the claim that the boot stack is reproducible, which is the claim P3
exists to support and the one `decisions/0004` is built on.

### Below the line, and why

`vmport=off`, `SecureBootModel`, `SetApfsTrimTimeout`, `EnableJumpstart`,
`--disk-gb 60`, `vgamem_mb=64`, `usb-tablet`: all untested, all cheap to be
wrong about. `usb-tablet` is worth one boot purely because it is this
project's canonical expired claim and it is *still* the only one of the four
that has not been re-run.

`run-efi-updater=No` sits oddly here: untested, and the failure mode if it is
wrong is the only boring-looking one that could be interesting.
